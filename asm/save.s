; SMB3+ : save game to the cartridge EEPROM (24CL128, I2C address $50)
;
; Stage 1: START on the world map writes slot 0 and verifies it by reading it back.
;   - sound SND_MAPINVENTORYFLIP = saved and verified
;   - sound SND_MAPDENY          = EEPROM did not answer, or verify failed
;
; I2C bus: SDA = VIA1 PA0, SCL = VIA1 PA1 (the same bus as the SMC / RTC).
; The lines are only ever driven low (DDRA bit set) or released (DDRA bit
; cleared, the pull-up makes them high).  Interrupts are disabled while the bus
; is in use, because the KERNAL talks to the SMC on this bus from its IRQ handler.

.ifdef X16

.include "../inc/macros.inc"
.include "../inc/defines.inc"
.include "../inc/x16.inc"

.importzp Temp_Var1, Temp_Var2, Temp_Var3, Temp_Var4, Temp_Var5, Temp_Var6, Temp_Var7, Temp_Var8
.importzp Temp_Var9, Temp_Var10, Temp_Var11, Temp_Var12, Temp_Var13, Temp_Var14, Temp_Var15, Temp_Var16
.importzp World_Map_Move, World_Map_Y, Controller1Press, Horz_Scroll, Horz_Scroll_Hi, Graphics_Queue
.importzp Map_IntBoxErase, Map_StarsState
.import Map_Intro_CurStripe
.import Map_Operation, Sound_QMap, Player_Current, World_EnterState
.import Map_Completions, Inventory_Coins2, Player_Lives, World_Num, Total_Players
.import Map_Got13Warp, Map_Previous_Y, World_Map_Power, Map_Prev_XOff, Map_Prev_XHi, Map_Prev_XOff2, Map_Prev_XHi2, Map_Previous_Dir
.import Map_NSpadeMatches, Card_ActiveSet, Map_NSpade_NextScore
.import Map_Entered_Y, Save_LoadEntry, Map_Objects_Y, Map_Objects_Itm, Map_Airship_Dest, Map_Airship_Trav, BigQBlock_GotIt
.import Graphics_Buffer, Graphics_BufCnt, Sprite_RAM, PAGE_A000
.import Map_IntroAttrSave, Map_Intro_Erase1Strip
.import Video_Do_Update, GraphicsBuf_Prep_And_WaitVSync, Sprite_RAM_Clear

SDA_BIT   = $01
SCL_BIT   = $02
EE_ADDR_W = $A0              ; device $50, write
EE_ADDR_R = $A1              ; device $50, read
SAVE_BASE_HI = $00           ; EEPROM address (high byte) of slot 0.  Slot n = SAVE_BASE_HI + 2*n, 512 bytes each
IMG_PAGES = 8                ; 8 pages of 64 bytes = 512 bytes per slot
NUM_SLOTS = 3

; zero page scratch (Temp_Var1..12 are scratch; only used inside one call, never kept between frames)
gen_ptr   = Temp_Var1        ; 2 bytes
gen_rem   = Temp_Var3
gen_idx   = Temp_Var4
chk       = Temp_Var5
cnt       = Temp_Var6
slot_hi   = Temp_Var7
expect    = Temp_Var8        ; expected byte while verifying
shift     = Temp_Var9        ; I2C shift register
poll      = Temp_Var10       ; 2 bytes, ack polling counter
gen_total = Temp_Var12       ; bytes handed out by the generator
skip      = Temp_Var11       ; (gen_seek only, 2 bytes with skip_hi)
gen_hi    = Temp_Var13       ; high byte of gen_total
skip_hi   = Temp_Var14
pg_hi     = Temp_Var15       ; EEPROM address (high byte) of the page being accessed
chk_hi    = Temp_Var16       ; high byte of chk (index of the byte being read)

; ---------------------------------------------------------------------------
; Menu state (RAM $7D00-$7D3F is unused by the game, see smb3-x16.cfg)
; ---------------------------------------------------------------------------
.segment "SAVEBSS"
sm_cursor:   .res 1          ; 0..2
sm_action:   .res 1          ; 0 = LOAD, 1 = WRITE, 2 = DELETE
sm_dirty:    .res 1          ; bit n = interior row 9+n has to be redrawn
sm_conf:     .res 1          ; delete confirmation pending for slot (n+1), 0 = none
sm_tick:     .res 1
sm_blink:    .res 1
sm_c0:       .res 1          ; NT column of the box's left border: 8 or 24
sm_oldst:    .res 1
sm_oldstars: .res 1
sm_slot:     .res 1
sm_row:      .res 1
sm_col:      .res 1
sm_n1:       .res 1
sm_valid:    .res NUM_SLOTS
sm_world:    .res NUM_SLOTS
sm_lives:    .res NUM_SLOTS
sm_job:      .res 1          ; 1 = checksum, 2..9 = write page, 10..17 = verify page, 20..27 = LOAD check page, 28..35 = LOAD apply page
sm_chk:      .res 1          ; checksum of the image being saved
sm_mode:     .res 1          ; 1 = the running job is a LOAD
sm_try:      .res 1          ; header read attempts left
sm_retry:    .res 1          ; bit n = header of slot n must be read again
sm_sp:       .res 1          ; stack pointer when the menu was entered
sm_scr:      .res 2          ; scroll position (Horz_Scroll, Horz_Scroll_Hi) at save time
sm_hdr:      .res 9
sm_line:     .res 14

.segment "PRG010"

;---------------------------------------------------------------------------
; Called once per frame at the start of Map_DoMap.
; START of player 1 (unused on the map) opens the save menu.
;---------------------------------------------------------------------------
.export Save_Poll
.proc Save_Poll
	lda Map_Operation
	cmp #$0d
	bne @done			; only on the map, when it is idle
	lda World_Map_Move
	bne @done			; (mario is not walking)
	ldx Player_Current
	lda World_Map_Move,x
	bne @done
	lda Controller1Press		; player 1: START pressed this frame
	and #PAD_START
	beq @done
	jmp Save_Modal			; (MAIN-resident driver, returns here with bank 10 mapped)
@done:
	rts
.endproc


;---------------------------------------------------------------------------
; Saving is done in bursts, one EEPROM page (64 bytes) per video frame, right
; after the vertical blank.  Keeping the interrupts off for only about 7 ms
; at a time leaves the map's raster effects alone, so the screen stays clean.
; One call of Job_Run does one burst.  Carry set = failed.
;   job 1      : checksum of the image (no I2C)
;   job 2..5   : write page 0..3
;   job 6..9   : read page 0..3 back and compare
;---------------------------------------------------------------------------
; A = slot 0..2 -> slot_hi.  One player games use slots 0..2 of the EEPROM, two player games 3..5.
.proc slot_calc
	ldy Total_Players
	cpy #2
	bcc :+
	clc
	adc #3
:	asl a
	clc
	adc #SAVE_BASE_HI
	sta slot_hi
	rts
.endproc

.proc Job_Run
	lda sm_cursor
	jsr slot_calc
	lda sm_job
	cmp #20
	bcs @load
	cmp #1
	bne @notsum
	lda Horz_Scroll			; the scroll position travels in the image too
	sta sm_scr
	lda Horz_Scroll_Hi
	sta sm_scr+1
	jsr gen_reset
	stz sm_chk
	ldx #255			; (gen_next uses Y, so X counts) 255 + 256 = 511 bytes
	jsr @sum
	ldx #0
	jsr @sum
	inc sm_job
	clc
	rts
@sum:	jsr gen_next
	clc
	adc sm_chk
	sta sm_chk
	dex
	bne @sum
	rts
@notsum:
	cmp #10
	bcs @verify
	sec				; ---- write page (job-2)
	sbc #2
	jsr Job_WritePage
	bcs @fail
	inc sm_job
	clc
	rts
@verify:
	sec
	sbc #10
	jsr Job_VerifyPage
	bcs @fail
	inc sm_job
	lda sm_job
	cmp #18
	bne @more
	stz sm_job			; all done
@more:	clc
	rts
@fail:	stz sm_job
	sec
	rts
@load:
	cmp #28
	bcs @apply
	sec				; ---- LOAD, pass 1: check the sum of the slot (job-20)
	sbc #20
	jsr Job_CheckPage
	bcs @fail
	inc sm_job
	clc
	rts
@apply:
	sec				; ---- LOAD, pass 2: copy the slot into the game (job-28)
	sbc #28
	jsr Job_ApplyPage
	bcs @fail
	inc sm_job
	lda sm_job
	cmp #36
	bne @amore
	stz sm_job			; done
@amore:	clc
	rts
.endproc

; A = page 0..7: sets cnt = low byte of the page offset (0,64,128,192),
; pg_hi = EEPROM address high byte, chk/chk_hi = index (0..511) of the page's first byte
.proc page_setup
	pha
	and #3
	asl a
	asl a
	asl a
	asl a
	asl a
	asl a
	sta cnt
	sta chk
	pla
	lsr a
	lsr a				; A = 0 or 1: which 256 byte half
	sta chk_hi
	clc
	adc slot_hi
	sta pg_hi
	rts
.endproc

; begin reading page A (0..7) of the slot: carry set = failed
.proc ee_read_begin
	jsr page_setup
	jsr ee_wait_ready
	bcs @fail
	jsr i2c_start
	lda #EE_ADDR_W
	jsr i2c_send
	bcs @fail
	lda pg_hi
	jsr i2c_send
	bcs @fail
	lda cnt
	jsr i2c_send
	bcs @fail
	jsr i2c_start			; repeated start
	lda #EE_ADDR_R
	jsr i2c_send
	bcs @fail
	clc
	rts
@fail:	jsr i2c_stop
	sec
	rts
.endproc

; read one byte; Y = bytes left in the burst (NACK on the last one); returns A
.proc ee_read_byte
	cpy #1
	clc
	bne :+
	sec
:	phy
	jsr i2c_recv
	ply
	rts
.endproc

; A = page.  Adds the bytes to sm_chk; the last byte of the image (index 511) must equal the sum.
.proc Job_CheckPage
	php
	sei
	jsr ee_read_begin
	bcs @fail0
	ldy #64
@r:	jsr ee_read_byte
	sta expect
	lda chk_hi
	beq @add
	lda chk
	cmp #255
	beq @last
@add:	lda expect
	clc
	adc sm_chk
	sta sm_chk
	bra @next
@last:	lda expect
	cmp sm_chk
	bne @fail
@next:	inc chk
	bne :+
	inc chk_hi
:	dey
	bne @r
	jsr i2c_stop
	plp
	clc
	rts
@fail:	jsr i2c_stop
@fail0:	plp
	sec
	rts
.endproc

; A = page.  Copies the image bytes into the game variables.
.proc Job_ApplyPage
	php
	sei
	pha
	jsr ee_read_begin
	pla
	bcs @fail0
	pha
	lda cnt				; image offset = page * 64
	ldy chk_hi
	jsr gen_seek
	pla
	ldy #64
@r:	jsr ee_read_byte
	sta expect
	lda chk_hi
	bne @hi
	lda chk
	cmp #4
	bcc @skip			; the first 4 bytes (magic) are never copied
@put:	phy
	jsr gen_put
	ply
	bra @next
@hi:	lda chk
	cmp #255
	bcs @next			; (index 511 = the checksum itself)
	bra @put
@skip:	phy
	jsr gen_next
	ply
@next:	inc chk
	bne :+
	inc chk_hi
:	dey
	bne @r
	jsr i2c_stop
	plp
	clc
	rts
@fail0:	plp
	sec
	rts
.endproc

; A = page 0..7
.proc Job_WritePage
	jsr page_setup			; cnt = offset in the 256 byte half, pg_hi = its EEPROM address
	php
	sei
	jsr ee_wait_ready		; the previous page may still be burning
	bcs @fail
	lda cnt
	ldy chk_hi
	jsr gen_seek
	jsr i2c_start
	lda #EE_ADDR_W
	jsr i2c_send
	bcs @fail
	lda pg_hi
	jsr i2c_send
	bcs @fail
	lda cnt
	jsr i2c_send
	bcs @fail
	ldy #64
@b:	phy
	jsr next_image_byte
	jsr i2c_send
	ply
	bcs @fail
	dey
	bne @b
	jsr i2c_stop
	plp
	clc
	rts
@fail:	jsr i2c_stop
	plp
	sec
	rts
.endproc

; A = page 0..7
.proc Job_VerifyPage
	jsr page_setup
	php
	sei
	jsr ee_wait_ready
	bcs @fail
	lda cnt
	ldy chk_hi
	jsr gen_seek
	jsr i2c_start
	lda #EE_ADDR_W
	jsr i2c_send
	bcs @fail
	lda pg_hi
	jsr i2c_send
	bcs @fail
	lda cnt
	jsr i2c_send
	bcs @fail
	jsr i2c_start			; repeated start
	lda #EE_ADDR_R
	jsr i2c_send
	bcs @fail
	ldy #64
@r:	phy
	jsr next_image_byte
	sta expect
	ply
	cpy #1				; last byte of the burst: NACK
	clc
	bne :+
	sec
:	phy
	jsr i2c_recv
	ply
	cmp expect
	bne @fail
	dey
	bne @r
	jsr i2c_stop
	plp
	clc
	rts
@fail:	jsr i2c_stop
	plp
	sec
	rts
.endproc

;---------------------------------------------------------------------------
; Read the header (9 bytes, takes about 1 ms) of slot X into
; sm_valid / sm_world / sm_lives.  The checksum of the whole slot is NOT
; checked here, because reading all 256 bytes keeps the interrupts off for
; about 28 ms, which garbles the screen.  (It is checked when loading.)
;---------------------------------------------------------------------------
; One short attempt (about 1 ms with interrupts off) to read the header of slot X.
; sm_valid,x is set.  Carry set = the read failed or gave garbage, trying again may help.
.proc Slot_ReadInfo
	stx sm_slot
	txa
	jsr slot_calc
	php
	sei
	jsr i2c_start
	lda #EE_ADDR_W
	jsr i2c_send
	bcs @bad
	lda slot_hi
	jsr i2c_send
	bcs @bad
	lda #0
	jsr i2c_send
	bcs @bad
	jsr i2c_start			; repeated start
	lda #EE_ADDR_R
	jsr i2c_send
	bcs @bad
	stz cnt
@rd:
	lda cnt
	cmp #8
	clc
	bne :+
	sec				; last byte: NACK
:	jsr i2c_recv
	ldx cnt
	sta sm_hdr,x
	inc cnt
	lda cnt
	cmp #9
	bne @rd
	jsr i2c_stop
	plp
	; the header must be "S3",1,0
	lda sm_hdr+0
	cmp #$53
	bne @inval
	lda sm_hdr+1
	cmp #$33
	bne @inval
	lda sm_hdr+2
	cmp #4				; image format version
	bne @inval
	lda sm_hdr+3
	bne @inval
	ldx sm_slot
	lda #1
	sta sm_valid,x
	lda sm_hdr+5			; World_Num (0 based)
	inc a
	sta sm_world,x
	ldy sm_hdr+4			; Player_Current
	cpy #2
	bcc :+
	ldy #0
:	lda sm_hdr+7,y			; Player_Lives[player]
	sta sm_lives,x
	lda sm_hdr+6			; Total_Players
	cmp #2
	bne @done
	lda #$FF			; $FF = two player game
	sta sm_lives,x
@done:	clc
	rts
@bad:
	jsr i2c_stop
	plp
	ldx sm_slot
	stz sm_valid,x
	sec				; bus error: worth another try
	rts
@inval:
	ldx sm_slot
	stz sm_valid,x
	lda sm_hdr+0			; erased or never written ($FF...): a sure answer
	and sm_hdr+1
	and sm_hdr+2
	and sm_hdr+3
	cmp #$FF
	beq @empty
	sec				; anything else is suspicious: try again
	rts
@empty:	clc
	rts
.endproc

;---------------------------------------------------------------------------
; Delete slot X: destroy its header (4 bytes of $FF), nothing else is needed.
; Carry set = failed.
;---------------------------------------------------------------------------
.proc Slot_Delete
	txa
	jsr slot_calc
	php
	sei
	jsr i2c_start
	lda #EE_ADDR_W
	jsr i2c_send
	bcs @fail
	lda slot_hi
	jsr i2c_send
	bcs @fail
	lda #0
	jsr i2c_send
	bcs @fail
	ldy #4
@b:	phy
	lda #$FF
	jsr i2c_send
	ply
	bcs @fail
	dey
	bne @b
	jsr i2c_stop
	jsr ee_wait_ready
	plp
	rts
@fail:
	jsr i2c_stop
	plp
	sec
	rts
.endproc

; image byte 511 is the checksum, the others come from the generator
.proc next_image_byte
	lda gen_hi
	beq @data
	lda gen_total
	cmp #255
	bcs @chk
@data:	inc gen_total
	bne :+
	inc gen_hi
:	jmp gen_next
@chk:
	lda sm_chk
	rts
.endproc

;---------------------------------------------------------------------------
; Image generator: walks the ranges table and pads with zeroes.
;---------------------------------------------------------------------------
.proc gen_reset
	stz gen_rem
	stz gen_idx
	stz gen_total
	stz gen_hi
	rts
.endproc

; position the generator on byte (Y*256 + A) of the image
.proc gen_seek
	sta gen_total
	sta skip
	sty gen_hi
	sty skip_hi
	ldx #0
@l:	lda SaveRanges+2,x
	beq @pad
	ldy skip_hi
	bne @over
	lda skip
	cmp SaveRanges+2,x
	bcc @inside
@over:	lda skip
	sec
	sbc SaveRanges+2,x
	sta skip
	lda skip_hi
	sbc #0
	sta skip_hi
	inx
	inx
	inx
	bra @l
@inside:
	lda SaveRanges,x
	clc
	adc skip
	sta gen_ptr
	lda SaveRanges+1,x
	adc #0
	sta gen_ptr+1
	lda SaveRanges+2,x
	sec
	sbc skip
	sta gen_rem
	inx
	inx
	inx
	stx gen_idx
	rts
@pad:	stx gen_idx
	stz gen_rem
	rts
.endproc

.proc gen_next
	lda gen_rem
	bne @have
	ldy gen_idx
	lda SaveRanges+2,y
	beq @pad
	sta gen_rem
	lda SaveRanges,y
	sta gen_ptr
	lda SaveRanges+1,y
	sta gen_ptr+1
	iny
	iny
	iny
	sty gen_idx
@have:
	dec gen_rem
	lda (gen_ptr)
	inc gen_ptr
	bne :+
	inc gen_ptr+1
:	rts
@pad:
	lda #0
	rts
.endproc

.proc gen_put
	lda gen_rem
	bne @have
	ldy gen_idx
	lda SaveRanges+2,y
	beq @pad
	sta gen_rem
	lda SaveRanges,y
	sta gen_ptr
	lda SaveRanges+1,y
	sta gen_ptr+1
	iny
	iny
	iny
	sty gen_idx
@have:
	dec gen_rem
	lda expect
	sta (gen_ptr)
	inc gen_ptr
	bne :+
	inc gen_ptr+1
:	rts
@pad:	rts
.endproc

;---------------------------------------------------------------------------
; What is saved (each entry: address, length <= 255).  Table ends with length 0.
; The first entry is a marker so that an empty slot is recognised.
;---------------------------------------------------------------------------
SaveRanges:
	.word SaveMagic			; offsets 0-3: "S3",1,0
	.byte 4
	.word Player_Current		; 4
	.byte 1
	.word World_Num			; 5
	.byte 1
	.word Total_Players		; 6
	.byte 1
	.word Player_Lives		; 7-8
	.byte 2
	.word Map_Completions		; completed levels + inventories, scores, coins
	.byte <(Inventory_Coins2 + 1 - Map_Completions)
	.word World_Map_Y		; Y, XHi, X on the map (Mario + Luigi, 6 bytes)
	.byte 6
	.word Map_Previous_Y		; Previous Y, XHi, X (where you go back to after a death)
	.byte 6
	.word Map_Got13Warp		; Got13Warp, Anchored, WhiteHouse, CoinShip
	.byte 4
	.word World_Map_Power		; power-up of each player on the map
	.byte 2
	.word Map_Prev_XOff		; scroll positions (Mario + Luigi)
	.byte 2
	.word Map_Prev_XHi
	.byte 2
	.word Map_Prev_XOff2
	.byte 2
	.word Map_Prev_XHi2
	.byte 2
	.word Map_Previous_Dir
	.byte 2
	.word sm_scr			; scroll position of the current player
	.byte 2
	.word Map_Objects_Y		; map objects: Y, XLo, XHi, ID (14 each)
	.byte 56
	.word Map_Objects_Itm		; item each object gives
	.byte 13
	.word Map_Airship_Dest
	.byte 1
	.word Map_Airship_Trav
	.byte 1
	.word BigQBlock_GotIt
	.byte 1
	.word Map_NSpadeMatches		; N-Spade card game: matches found + "game in progress"
	.byte 2
	.word Card_ActiveSet		; the cards (which are turned, which are matched)
	.byte 18
	.word Map_NSpade_NextScore	; score at which the next N-Spade appears
	.byte 3
	.byte 0,0,0			; terminator

SaveMagic:
	.byte $53, $33, 4, 0

;---------------------------------------------------------------------------
; EEPROM helpers
;---------------------------------------------------------------------------
; wait until the EEPROM answers again after a page write (ack polling)
.proc ee_wait_ready
	lda #<2000
	sta poll
	lda #>2000
	sta poll+1
@poll:
	jsr i2c_start
	lda #EE_ADDR_W
	jsr i2c_send
	php
	jsr i2c_stop
	plp
	bcc @ok
	lda poll
	bne :+
	dec poll+1
:	dec poll
	lda poll
	ora poll+1
	bne @poll
	sec
	rts
@ok:	clc
	rts
.endproc

;---------------------------------------------------------------------------
; Bit-banged I2C (about 100 kHz at 8 MHz)
;---------------------------------------------------------------------------
.macro sda_low
	lda #SDA_BIT
	tsb VIA1::Reg::DDRA
.endmacro
.macro sda_high
	lda #SDA_BIT
	trb VIA1::Reg::DDRA
.endmacro
.macro scl_low
	lda #SCL_BIT
	tsb VIA1::Reg::DDRA
.endmacro
.macro scl_high
	lda #SCL_BIT
	trb VIA1::Reg::DDRA
.endmacro

.proc i2c_delay
	nop
	nop
	nop
	nop
	nop
	nop
	rts
.endproc

.proc i2c_start
	sda_high
	scl_high
	jsr i2c_delay
	sda_low
	jsr i2c_delay
	scl_low
	jsr i2c_delay
	rts
.endproc

.proc i2c_stop
	sda_low
	jsr i2c_delay
	scl_high
	jsr i2c_delay
	sda_high
	jsr i2c_delay
	rts
.endproc

; send A, carry set on return = no ACK
.proc i2c_send
	sta shift
	ldx #8
@bit:
	asl shift
	bcs @one
	sda_low
	bra @clk
@one:
	sda_high
@clk:
	jsr i2c_delay
	scl_high
	jsr i2c_delay
	scl_low
	dex
	bne @bit
	sda_high			; release for the ACK
	jsr i2c_delay
	scl_high
	jsr i2c_delay
	lda VIA1::Reg::PA
	and #SDA_BIT			; 0 = ACK
	clc
	beq :+
	sec
:	php
	scl_low
	jsr i2c_delay
	plp
	rts
.endproc

; read a byte into A.  Carry set on entry = send NACK (last byte), clear = ACK
.proc i2c_recv
	php
	sda_high
	ldx #8
@bit:
	jsr i2c_delay
	scl_high
	jsr i2c_delay
	lda VIA1::Reg::PA
	and #SDA_BIT
	cmp #1				; carry = the bit
	rol shift
	scl_low
	dex
	bne @bit
	plp
	bcs @nack
	sda_low
	bra @ackclk
@nack:
	sda_high
@ackclk:
	jsr i2c_delay
	scl_high
	jsr i2c_delay
	scl_low
	sda_high
	jsr i2c_delay
	lda shift
	rts
.endproc


;===========================================================================
; The save menu.  It reuses the "GAME OVER" box of the game: same box, same
; way of erasing it afterwards.  Interior rows 9..14, 14 tiles wide:
;   row 9 : action (LOAD / WRITE / DELETE)  - LEFT/RIGHT to change
;   row 11-13 : slots 1..3                  - UP/DOWN to choose, A to do it
;   B or START closes.
;===========================================================================
.segment "PRG010"

TILE_BLANK = $FE
TILE_X     = $FB
TILE_0     = $F0

TxtWorld:  .byte $D8, $F0, $E9, $EC, $EE			; W O R L D
TxtNoGame: .byte $DB, $F0, $FE, $EB, $BC, $BA, $E8		; N O _ G A M E
TxtAction:
	.byte $FE, $EC, $F0, $BC, $EE, $FE, $FE			; LOAD
	.byte $D8, $E9, $FC, $EA, $E8, $FE, $FE			; WRITE
	.byte $EE, $E8, $EC, $E8, $EA, $E8, $FE			; DELETE

.export SaveUI_Init
.proc SaveUI_Init
	lda #1				; default action = WRITE
	sta sm_action
	stz sm_cursor
	stz sm_conf
	stz sm_tick
	stz sm_blink
	stz sm_job
	lda #8
	ldx Horz_Scroll
	beq :+
	lda #24
:	sta sm_c0
	lda #$3F
	sta sm_dirty
	stz sm_mode
	stz sm_retry
	lda #6				; background re-reads allowed
	sta sm_try
	ldx #0
@rd:	phx
	jsr Slot_ReadInfo		; one short attempt each, like before
	plx
	bcc :+
	lda Bit_Mask,x			; failed: it will be read again while the menu is open
	ora sm_retry
	sta sm_retry
:	inx
	cpx #NUM_SLOTS
	bne @rd
	rts
.endproc

; Background re-read of a header that failed when the menu opened: one short
; attempt per frame, no waiting, so nothing is delayed.
.proc Ui_Reread
	lda sm_retry
	beq @n
	lda sm_try
	beq @n
	dec sm_try
	ldx #0
:	lda sm_retry
	and Bit_Mask,x
	bne @go
	inx
	bra :-
@go:	phx
	jsr Slot_ReadInfo
	plx
	bcs @n				; still failing: leave it for the next frame
	lda Bit_Mask,x
	eor #$FF
	and sm_retry
	sta sm_retry
	lda Bit_Mask+2,x		; redraw its row (rows 11..13 = bits 2..4)
	ora sm_dirty
	sta sm_dirty
@n:	rts
.endproc

; build row sm_row (9..14) into sm_line and append it to the graphics buffer
.proc Ui_DrawRow
	sta sm_row
	ldx #13
	lda #TILE_BLANK
:	sta sm_line,x
	dex
	bpl :-
	lda sm_row
	cmp #9
	beq @action
	cmp #11
	bcc @emit			; row 10: blank
	cmp #14
	bcs @emit			; row 14: blank
	sec
	sbc #11
	jsr Ui_BuildSlot
	bra @emit
@action:
	lda sm_action			; * 7
	asl a
	asl a
	asl a
	sec
	sbc sm_action
	tax
	ldy #4
@a:	lda TxtAction,x
	sta sm_line,y
	inx
	iny
	cpy #11
	bne @a
@emit:
	jmp Ui_Emit
.endproc

; A = slot
.proc Ui_BuildSlot
	sta sm_slot
	lda sm_conf			; delete pending on this slot: blink
	beq @show
	dec a
	cmp sm_slot
	bne @show
	lda sm_blink
	bne @done
@show:
	ldy #1
	lda sm_slot
	clc
	adc #(TILE_0 + 1)
	sta sm_line,y
	iny
	iny
	ldx sm_slot
	lda sm_valid,x
	beq @empty
	ldx #0
@w:	lda TxtWorld,x
	sta sm_line,y
	iny
	inx
	cpx #5
	bne @w
	iny
	ldx sm_slot
	lda sm_world,x
	clc
	adc #TILE_0
	sta sm_line,y
	iny
	iny
	lda sm_lives,x
	cmp #$FF
	beq @two
	lda #TILE_X
	sta sm_line,y
	iny
	lda sm_lives,x
	ldx #0
@t:	cmp #10
	bcc @td
	sbc #10
	inx
	bra @t
@td:	pha
	txa
	clc
	adc #TILE_0
	sta sm_line,y
	iny
	pla
	clc
	adc #TILE_0
	sta sm_line,y
@done:	rts
@two:	lda #(TILE_0 + 2)		; "2P"
	sta sm_line,y
	iny
	lda #$D9
	sta sm_line,y
	rts
@empty:
	ldx #0
@e:	lda TxtNoGame,x
	sta sm_line,y
	iny
	inx
	cpx #7
	bne @e
	rts
.endproc

; append sm_line as video update entries for row sm_row (splits at the nametable wrap)
.proc Ui_Emit
	lda sm_c0
	inc a
	and #31
	sta sm_col
	lda #32
	sec
	sbc sm_col
	cmp #14
	bcc :+
	lda #14
:	sta sm_n1
	ldx Graphics_BufCnt
	ldy #0
	; --- part 1
	lda #$29
	sta Graphics_Buffer,x
	lda sm_row
	and #7
	asl a
	asl a
	asl a
	asl a
	asl a
	sta Temp_Var1			; row base (low byte)
	clc
	adc sm_col
	sta Graphics_Buffer+1,x
	lda sm_n1
	sta Graphics_Buffer+2,x
	inx
	inx
	inx
@c1:	lda sm_line,y
	sta Graphics_Buffer,x
	inx
	iny
	cpy sm_n1
	bne @c1
	; --- part 2 (wrapped to column 0)
	cpy #14
	beq @end
	lda #$29
	sta Graphics_Buffer,x
	lda Temp_Var1
	sta Graphics_Buffer+1,x
	lda #14
	sec
	sbc sm_n1
	sta Graphics_Buffer+2,x
	inx
	inx
	inx
@c2:	lda sm_line,y
	sta Graphics_Buffer,x
	inx
	iny
	cpy #14
	bne @c2
@end:	lda #0
	sta Graphics_Buffer,x
	stx Graphics_BufCnt
	rts
.endproc

; draw up to 3 dirty rows
.export SaveUI_Rows
.proc SaveUI_Rows
	lda #3
	sta Temp_Var2
	ldx #0
@n:	lda sm_dirty
	and Bit_Mask,x
	beq @skip
	lda sm_dirty
	eor Bit_Mask,x
	sta sm_dirty
	phx
	txa
	clc
	adc #9
	jsr Ui_DrawRow
	plx
	dec Temp_Var2
	beq @out
@skip:	inx
	cpx #6
	bne @n
@out:	rts
.endproc

Bit_Mask: .byte $01, $02, $04, $08, $10, $20

; one frame of the menu.  Returns A = 0 (keep going) or 1 (close)
.export SaveUI_Step
.proc SaveUI_Step
	lda sm_job
	beq @idle
	jsr Job_Run			; a save is going on: one burst, ignore the pad
	bcs @jobfail
	lda sm_job
	bne @busy
	lda sm_mode
	beq @saved
	lda #2				; LOAD finished: tell the driver
	rts
@saved:	; finished and verified
	ldx sm_cursor
	jsr Slot_ReadInfo
	stz sm_conf
	stz sm_blink
	jsr Ui_DirtyCursorRow
	lda #SND_MAPINVENTORYFLIP
	sta Sound_QMap
	bra @busy
@jobfail:
	stz sm_mode
	stz sm_conf
	stz sm_blink
	ldx sm_cursor
	jsr Slot_ReadInfo
	jsr Ui_DirtyCursorRow
	lda #SND_MAPDENY
	sta Sound_QMap
@busy:	jmp @na
@idle:
	jsr Ui_Reread
	lda Controller1Press
	and #(PAD_B | PAD_START)
	beq @nclose
	lda #SND_MAPPATHMOVE
	sta Sound_QMap
	lda #1
	rts

@nclose:
	; ---- UP / DOWN: choose the slot
	lda Controller1Press
	and #(PAD_UP | PAD_DOWN)
	beq @nud
	ldx sm_cursor
	lda Controller1Press
	and #PAD_UP
	beq @down
	dex
	bpl @setc
	ldx #(NUM_SLOTS - 1)
	bra @setc
@down:	inx
	cpx #NUM_SLOTS
	bcc @setc
	ldx #0
@setc:	stx sm_cursor
	jsr Ui_CancelDelete
	lda #SND_MAPPATHMOVE
	sta Sound_QMap
@nud:
	; ---- LEFT / RIGHT: choose the action
	lda Controller1Press
	and #(PAD_LEFT | PAD_RIGHT)
	beq @nlr
	ldx sm_action
	lda Controller1Press
	and #PAD_LEFT
	beq @right
	dex
	bpl @seta
	ldx #2
	bra @seta
@right:	inx
	cpx #3
	bcc @seta
	ldx #0
@seta:	stx sm_action
	lda sm_dirty
	ora #$01
	sta sm_dirty
	jsr Ui_CancelDelete
	lda #SND_MAPPATHMOVE
	sta Sound_QMap
@nlr:
	; ---- A: do the action on the chosen slot
	lda Controller1Press
	and #PAD_A
	beq @na
	jsr Ui_DoAction
@na:
	; ---- blinking of the slot being deleted
	lda sm_conf
	beq @noblink
	inc sm_tick
	lda sm_tick
	and #$07
	bne @noblink
	lda sm_blink
	eor #1
	sta sm_blink
	jsr Ui_DirtyCursorRow
@noblink:
	jsr SaveUI_Rows

	; ---- the cursor (same sprite the GAME OVER menu uses)
	lda sm_cursor
	asl a
	asl a
	asl a
	clc
	adc #$50
	sta Sprite_RAM+$94
	lda #$6f
	sta Sprite_RAM+$95
	lda #SPR_PAL0
	sta Sprite_RAM+$96
	lda #$48
	sta Sprite_RAM+$97
	; "<" and ">" around the action word: shows that LEFT/RIGHT change it
	lda #$40			; row 9
	sta Sprite_RAM+$98
	sta Sprite_RAM+$9C
	lda #$6f
	sta Sprite_RAM+$99
	sta Sprite_RAM+$9D
	lda #(SPR_PAL0 | $40)		; mirrored: points left
	sta Sprite_RAM+$9A
	lda #SPR_PAL0
	sta Sprite_RAM+$9E
	lda #$58
	sta Sprite_RAM+$9B
	lda #$A0
	sta Sprite_RAM+$9F
	lda #0
	rts
.endproc

; mark the row of the cursor's slot as needing redraw
.proc Ui_DirtyCursorRow
	ldx sm_cursor
	lda Bit_Mask+2,x		; rows 11..13 = bits 2..4
	ora sm_dirty
	sta sm_dirty
	rts
.endproc

.proc Ui_CancelDelete
	lda sm_conf
	beq @n
	stz sm_conf
	lda sm_dirty
	ora #$1C			; slot rows
	sta sm_dirty
@n:	stz sm_blink
	rts
.endproc

.proc Ui_DoAction
	ldx sm_cursor
	lda sm_action
	beq @load
	cmp #2
	bne @confirm
	lda sm_valid,x			; DELETE needs a filled slot
	beq @deny
@confirm:
	lda sm_action
	cmp #1
	bne @ask
	lda sm_valid,x
	bne @ask			; (an empty slot is written at once, no confirmation)
	inx
	stx sm_conf			; keeps blinking while it works
	stz sm_tick
	stz sm_blink
	lda #1
	sta sm_job
	rts
@ask:
	lda sm_conf			; WRITE (over a used slot) and DELETE: press A twice on the same slot
	dec a
	cmp sm_cursor
	beq @really
	inx
	stx sm_conf			; slot + 1
	stz sm_tick
	stz sm_blink
	lda #SND_MAPPATHMOVE
	sta Sound_QMap
	rts
@really:
	lda sm_action
	cmp #1
	beq @write
	jsr Slot_Delete
	bcs @fail
	ldx sm_cursor
	stz sm_valid,x
	stz sm_conf
	stz sm_blink
	jsr Ui_DirtyCursorRow
	lda #SND_MAPPATHMOVE
	sta Sound_QMap
	rts
@write:
	lda #1				; start the burst save (the slot keeps blinking meanwhile)
	sta sm_job
	rts
@load:
	lda sm_valid,x
	beq @deny
	lda #1				; (keeps blinking while it works)
	sta sm_mode
	inx
	stx sm_conf
	stz sm_tick
	stz sm_blink
	stz sm_chk
	lda #20
	sta sm_job
	rts
@deny:
@fail:
	lda #SND_MAPDENY
	sta Sound_QMap
	rts
.endproc

;===========================================================================
; Driver, in the fixed memory (the game's drawing routines switch the RAM
; bank, so they can not be called from code that lives in bank 10).
; Called with bank 10 mapped (from Save_Poll), returns with bank 10 mapped.
;===========================================================================
.segment "X16BRIDGE"

.export Save_Modal
.proc Save_Modal
	tsx
	stx sm_sp
	lda World_EnterState
	sta sm_oldst
	lda Map_StarsState
	sta sm_oldstars

	lda #10
	sta X16::Reg::RAMBank
	jsr SaveUI_Init
	jsr Map_IntroAttrSave		; remember the attributes under the box
	lda PAGE_A000
	sta X16::Reg::RAMBank

	; draw the box (the same way the GAME OVER box is drawn) ...
	ldx #$12
	lda Horz_Scroll
	beq :+
	ldx #$13
:	txa
	jsr Video_Do_Update

	; ... then replace its text before the first frame is shown
	lda #10
	sta X16::Reg::RAMBank
	jsr SaveUI_Rows
	lda PAGE_A000
	sta X16::Reg::RAMBank
	lda #0
	jsr Video_Do_Update
	lda #10
	sta X16::Reg::RAMBank
	jsr SaveUI_Rows
	lda PAGE_A000
	sta X16::Reg::RAMBank
	lda #0
	jsr Video_Do_Update

@frame:
	stz Graphics_Queue
	jsr GraphicsBuf_Prep_And_WaitVSync
	jsr Sprite_RAM_Clear
	lda #10
	sta X16::Reg::RAMBank
	jsr SaveUI_Step
	tax
	lda PAGE_A000
	sta X16::Reg::RAMBank
	txa
	beq @frame
	cmp #2
	beq @loaded

	; erase the box, one strip per frame, like the game does after GAME OVER
	stz Map_IntBoxErase
	stz Map_Intro_CurStripe
	lda #2
	sta World_EnterState
@erase:
	stz Graphics_Queue
	jsr GraphicsBuf_Prep_And_WaitVSync
	jsr Sprite_RAM_Clear
	lda #10
	sta X16::Reg::RAMBank
	jsr Map_Intro_Erase1Strip
	lda PAGE_A000
	sta X16::Reg::RAMBank
	lda World_EnterState
	cmp #3
	bne @erase
	; the last strip is only pushed to the screen by the next frames
	ldx #3
@last:	phx
	stz Graphics_Queue
	jsr GraphicsBuf_Prep_And_WaitVSync
	jsr Sprite_RAM_Clear
	plx
	dex
	bne @last

	lda sm_oldst
	sta World_EnterState
	lda sm_oldstars
	sta Map_StarsState
	lda #10
	sta X16::Reg::RAMBank
	rts

	; The slot has been copied into the game.  Rebuild the map from it, the way
	; the game does when it comes back to the map from a level.
@loaded:
	ldx Player_Current		; scroll position of the loaded player
	lda sm_scr
	sta Map_Prev_XOff,x
	lda sm_scr+1
	sta Map_Prev_XHi,x
	ldx #5				; the map is rebuilt from the "entered" positions
:	lda World_Map_Y,x
	sta Map_Entered_Y,x
	dex
	bpl :-
	ldx sm_sp			; throw away what Map_DoMap and its callers pushed
	inx				; (the caller's RAM bank + 2 return addresses)
	inx
	inx
	inx
	inx
	txs
	jmp Save_LoadEntry
.endproc

.endif
