[BITS 16]
CPU 186
ORG 0X0000


; Conservatively use MAX_HPC = 16 to produce a 504M limit
; It may be possible to use MAX_HPC of 255 and get an 8Gb limit, but it's likely this will
; require device repartition/reformat if it was set up with a 504M geometry.

MAX_SPT equ 63
MAX_HPC equ 16
MAX_CYL equ 1024

; Set to 1 if you want the CH376S errors dumped to the screen.
%assign DISPLAY_CH376S_ERRORS 1

; Overwrite the default INT19 handler if enabled.
%assign INJECT_INT19_HANDLER 1

; Experimental: Re-enable interrupts inside INT13 code.  Likely to reduce timer-distortion but risky.
%assign ALLOW_INTS 1

; SUPER-Experimental.  If your card or board maps the data port in a way where it's accessible by two adjacent numbers (E0/E1, for example)
; you can turn this on to try to use faster "staged 16 bit" reads/writes in V20/188 mode.  May do horrible and surprising things if
; you actually have a 16-bit-wide bus.
%assign DOUBLE_WIDE 1

%assign SHADOW 0

; Define the port numbers for the "primary" CH37x unit.  If this one doesn't load, we quit
COMMAND_PORT equ 0x7E4
DATA_PORT equ 0x7E0

; Experimental:  Second device.  Leave as zero if only using one CH37X device.
COMMAND_PORT_2 equ 0
DATA_PORT_2 equ 0

; Number of "ticks" to wait after some time-sensitive activity.  May need tweaking for optimal compatibility.
WAIT_LEVEL equ 10


; Maybe try command 29 - RD_USB_DATA and specifying a different endpoint 0, 1, 2, etc. to see if we can get the result from the probing?
; Define CH376S commands by name for improved legibility
CH376S_GET_IC_VER 	equ		0x01
CH376S_RESET_ALL 	equ		0x05
CH376S_CHECK_EXIST 	equ		0x06
CH376S_SET_USB_MODE equ 	0x15
CH376S_GET_STATUS 	equ		0x22
CH376S_RD_USB_DATA0 equ		0x27		; CH375 Convention (28 for RD_USB_DATA) Seems to work on 376 but weirdly.
CH376S_WR_USB_DATA	equ		0x2C
CH375_WR_USB_DATA7	equ		0x2B
CH376S_WR_REQ_DATA	equ		0x2D
CH375_DISK_INIT 	equ		0x51		; CH375 convention - actually DISK_INIT
CH375_DISK_INQUIRY  equ		0x58		; CH375 convention - actually DISK_INQUIRY
CH375_DISK_SIZE 	equ		0x53		; CH375 convention - actually DISK_SIZE
CH376S_DISK_READ 	equ		0x54
CH376S_DISK_RD_GO 	equ		0x55
CH376S_DISK_WRITE 	equ		0x56
CH376S_DISK_WR_GO 	equ		0x57
CH376S_DISK_R_SENSE equ 	0X5A


CH376S_USB_INT_SUCCESS equ  	0x14
CH376S_USB_INT_DISCONNECT equ	0x16
CH376S_USB_INT_BUF_OVER equ		0x17
CH376S_USB_INT_DISK_READ equ	0x1D
CH376S_USB_INT_DISK_WRITE equ	0x1E
CH376S_USB_INT_DISK_ERR equ 	0x1F

CH376S_CMD_RET_SUCCESS equ  	0x51


;Header so it's recognized as an option card

DB 0x55
DB 0xAA

; Uses 12 512-byte pages.  Expand if this grows over 6kb.
DB 0x0C

; Code starts here.  Save everything before we start.

PUSHF
PUSH AX
PUSH BX
PUSH CX
PUSH DX
PUSH SI
PUSH DI



INITIALIZE_CH376S_0XE0:
    MOV BX, MSG_SIGNATURE
    CALL WRITE_MESSAGE

	MOV BX, MSG_SEGMENT
	CALL WRITE_MESSAGE
	MOV AX, CS
	CALL WRITE_AX

	CALL GET_VECTOR_FOR_CPU
	CMP DX, INT13
	JE .DISP_186
	MOV BX, MSG_8086_TEXT
	CALL WRITE_MESSAGE
	JMP .AFTER_CPU_DISPLAY
.DISP_186:
	MOV BX, MSG_186_TEXT
	CALL WRITE_MESSAGE
.AFTER_CPU_DISPLAY:
	%if DOUBLE_WIDE = 1
    	MOV BX, MSG_DOUBLE_WIDE_TEXT
    	CALL WRITE_MESSAGE;
	%endif

	%if DISPLAY_CH376S_ERRORS = 1
    MOV BX, MSG_DEBUG
    CALL WRITE_MESSAGE;
	%endif

	%if INJECT_INT19_HANDLER = 1
	MOV BX, MSG_ADDED_INJECT_WARNING
	CALL WRITE_MESSAGE
	%endif



	MOV SI, 1			; Main reset body-- does reset, check for existence, mode switch, and disk init.
	MOV AX, COMMAND_PORTS[0]
	PUSH AX
	MOV AX, DATA_PORTS[0]
	PUSH AX
	CALL WRITE_PORTS
	CALL MAIN_RESET
	CMP AX, 0xBB
	JE NO_DISC_FOUND
	CMP AX, 0x99
	JE NO_MODULE_FOUND
	; Print IC version and learn if we're going to need CH375 or 376 specific handlers.
	CALL DISPLAY_MODULE_INFO
	CALL DISPLAY_DRIVE_INFO

	CMP AL, 0XFF
	JE NO_DISC_FOUND
	POP CX	; Remove the saved ports
	POP CX
	MOV DI, 1	; Assume one drive system


%if COMMAND_PORT_2 != 0
	MOV AX, COMMAND_PORTS[2]
	PUSH AX
	MOV AX, DATA_PORTS[2]
	PUSH AX
	CALL WRITE_PORTS
	CALL MAIN_RESET
	CMP AX, 0xBB
	JE NO_DISC_2_FOUND
	CMP AX, 0x99
	JE NO_MODULE_2_FOUND
	; Print IC version and learn if we're going to need CH375 or 376 specific handlers.
	CALL DISPLAY_MODULE_INFO
	CALL DISPLAY_DRIVE_INFO
	CMP AL, 0XFF
	JE SKIP_DISK_2
	INC DI				; Tag it as a two-drive system if we didn't discard disc number 2
SKIP_DISK_2:
	POP CX	; Remove the saved ports
	POP CX
%endif
	
	
CALL END_OF_LINE



; Prepare to load the appropriate vector for the CPU type.
	CALL GET_VECTOR_FOR_CPU		; DX = INT13 or INT13_8086
	PUSH DS
	XOR AX, AX
    MOV DS, AX
	; Vector migration logic based on examples at https://www.bttr-software.de/forum/board_entry.php?id=11433
	; Save old vector to INT 0x40 - this is reported as where old BIOSes really moved INT 0x13 to.
	MOV AX, DS:0x004C
	MOV DS:0x0100, AX
	MOV AX, DS:0x004E
	MOV DS:0x0102, AX
	
	; write our new vector into place

    MOV WORD DS:0x004C, DX
    MOV WORD DS:0x004E, CS



	; write the drive data table to INT 0x41 and 0x46
	MOV WORD DS:0x0104, DISK_1_TABLE
	MOV WORD DS:0x0106, CS
	MOV WORD DS:0x0118, DISK_2_TABLE
	MOV WORD DS:0x0120, CS
	MOV AX, DI
	MOV BYTE DS:0x0475, AL	; BIOS data area flags: 01 discs at 0475.  Other bytes are used by some controllers, but not all.

%if INJECT_INT19_HANDLER = 1
	MOV WORD DS:0x0064, INT19
	MOV WORD DS:0x0066, CS
%endif
    POP DS


END_STARTUP:
	POP DI
	POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    POPF
	RETF			;RETURN

; Leaves either "INT13" or "INT13_8086" location in DX
; Clobbers AX
GET_VECTOR_FOR_CPU:
	PUSH CX
; V20/30/40 will not set the zero flag on multiply.  Treat as 186
	
	XOR AL, AL
	MOV AL, 0x40
	MUL AL
	JZ .HAS_186

; As suggested in https://board.flatassembler.net/topic.php?t=7204
; 186+ will only look at the last four bits of CL for shifts
; so 0x20 becomes 0 shifts right, and  AX is preserved.
	MOV CL, 0x20
	MOV AX, 1
	SHR AX, CL
	CMP AX, 0
	JNE .HAS_186
    MOV DX, INT13_8086	; Worst case, assume 8086
	JMP .CPU_DECIDED

.HAS_186:
	MOV DX, INT13
	JMP .CPU_DECIDED
.CPU_DECIDED:
	POP CX
    RET

; Expects the ports to be on the last two stack entries (BP+6 and BP+4)
WRITE_PORTS:
	PUSH BP
	MOV BP, SP
	MOV BX, MSG_PORTS
	CALL WRITE_MESSAGE
	MOV AX, [SS:BP+6]
	CALL WRITE_AX

	MOV BX, MSG_DATA_PORT
	CALL WRITE_MESSAGE
	MOV AX, [SS:BP+4]
	CALL WRITE_AX
	%if DOUBLE_WIDE = 1
	MOV BX, MSG_PLUS
	CALL WRITE_MESSAGE
	INC AX
	CALL WRITE_AX
	%endif
	POP BP
	RET

NO_MODULE_FOUND:
	POP CX	; called with port info on the stack, discard it since we're heading straight for an exit
	POP CX
    MOV BX, MSG_NO_MODULE
    CALL WRITE_MESSAGE
	JMP END_STARTUP

NO_DISC_FOUND:
	POP CX	; called with port info on the stack, discard it since we're heading straight for an exit
	POP CX
    MOV BX, MSG_NO_DISC
    CALL WRITE_MESSAGE
	JMP END_STARTUP

%if COMMAND_PORT_2 != 0
NO_MODULE_2_FOUND:
	; Here, the main code will be responsible for popping off the old ports
	MOV BX, MSG_NO_MODULE
    CALL WRITE_MESSAGE
	JMP SKIP_DISK_2

NO_DISC_2_FOUND:
	; Here, the main code will be responsible for popping off the old ports
	MOV BX, MSG_NO_DISC
    CALL WRITE_MESSAGE
	JMP SKIP_DISK_2
%endif


MSG_PLUS:
	DB ' + ', 0

MSG_NO_MODULE:
	DB 0x0d, 0x0a, '[', 0x84, 'F', 0x84, 'A', 0x84, 'T', 0x84, 'A', 0x84, 'L ] Module not detected.  Skipping install.', 0x0D, 0x0A, 0

MSG_NO_DISC:
	DB 0x0d, 0x0a, '[', 0x84, 'F', 0x84, 'A', 0x84, 'T', 0x84, 'A', 0x84, 'L ] No drive found.  Skipping install.', 0x0D, 0x0A, 0

MSG_SIGNATURE:
    DB '[', 0x84, 3, 0x86, 3, 0x8E, 3,0x82, 3,0x81, 3,0x85, 3, '] Standalone CH37X Firmware', 0x0D, 0x0A, '[VER   ] 0.95 - 2022-09-19', 0x0D, 0x0A, 0


MSG_SEGMENT:
    DB '[ROMSEG] ', 0

MSG_PORTS:
    DB 0x0d, 0x0a, '[PORT ',1,'] C:', 0

MSG_DATA_PORT:
    DB ' / D:', 0

MSG_DEBUG:
	DB ', Verbose CH37x Errors',  0

MSG_INIT:
    DB 0x0d, 0x0a, '[INIT ',1,']  ', 0	; Leave one extra space that will be clobbered by the spinning pipe

MSG_CH375_NAME:
	DB 'CH375 rev. ', 0

MSG_CH376_NAME:
	DB 'CH376 rev. ', 0

MSG_DEVINFO:
	DB 0x0D, 0x0A, '[DRIVE',1,'] ', 0

MSG_OVERSIZE:
	DB ' - limited to ', 0

MSG_BELOW_TABLE_SIZE:
	DB 0x0D, 0x0A, '[', 0x84,'D', 0x84, 'A', 0x84, 'N', 0x84, 'G', 0x84, 'E', 0x84,'R','] Device smaller than ROM parameter table.  Suggested cylinder count: 0x', 0


MSG_8086_TEXT:
	DB 0x0D, 0x0A, '[OPTION] 8086/8088', 0

MSG_186_TEXT:
	DB 0x0D, 0x0A, '[OPTION] NEC/186+', 0

MSG_DOUBLE_WIDE_TEXT:
	DB ', 16-bit I/O', 0

MSG_ADDED_INJECT_WARNING:
	DB ', Bootloader', 0

MSG_INT19_SIGNATURE:
	DB '[BOOT  ] Minimal Boot Handler: trying floppy, then HDD...', 0x0D, 0x0A,0

MSG_BOOT_FAIL:
	DB '[', 0x84, 'E', 0x84, 'R', 0x84, 'R', 0x84,'O', 0x84,'R ] Could not boot USB disc.', 0x0D, 0x0A, 0

MSG_SHADOW:
	DB '[SHADOW] Stealing 6Kb of conventional RAM for BIOS at ', 0
MSG_SHADOW_2:
	DB 0x0D, 0x0A, 0

MSG_DETECT_DONE:
	DB 8, 'Active!  ', 0		; Leading backspace to clear old pipe,  one trailing space for format, then one for the pipe

MSG_MODE_DONE:
	DB 8, 'Mode set!  ', 0	; Same here.

MSG_COMPLETE:
	DB 8, 'Ready: ', 0				; No pipe here, but clear the pipe.

MSG_IO_ERROR:
	DB 0X0D, 0X0A, 'CH37X ERROR/FUNC: ', 0

GET_CORRECT_WRITE_COMMAND_PORTED: ; Clobbers CX.  Returns desired write command in CH.  Expects the BP to be set up so that command port is BP-24 and data port is BP-26
	PUSH DX
	PUSH AX
    MOV AL, CH376S_GET_IC_VER	;GET IC Version
	MOV DX, [SS:BP-24] ; Command port pulled in from before
	OUT DX, AL		;OUT COMMAND PORT
	MOV DX, [SS:BP-26]
	IN AL, DX			;READ IN STATUS DATA PORT
	AND AL, 0x80
	JZ .IS_376
	MOV CH, CH375_WR_USB_DATA7
	POP AX
	POP DX
	RET
.IS_376:
	MOV CH, CH376S_WR_USB_DATA
	POP AX
	POP DX
	RET

; Gimmick:  If you give it a 0x01 character, it will check SS:BP+6 to see if it's COMMAND_PORT_2
; and if so, change it into a "2", otherwise "1".  This should dovetail with being called inside functions
; that expect the command and data ports to be passed before the call, then BP is set to SP at the start of the call
; like the MAIN_RESET or DISPLAY_MODULE_INFO.
; Characters over 0x80 will print a blank space with the lowest 4 bits to set colour, to preload a coloured character space.
WRITE_MESSAGE:
    PUSH AX
	PUSH CX
	MOV CX, 1
    MOV AH, 0x0E
.WRITE_LOOP:
    MOV AL, [BX]
	CMP AL, 0
	JE .WRITING_DONE
	CMP AL, 0x80
	JB .WRITE_ONE_CHAR
	PUSH BX
	MOV BL, AL
	AND BL, 0x7F
	MOV BH, 00
	MOV AX, 0x0920
	INT 0x10
	MOV AH, 0x0E
	POP BX
	INC BX
	JMP .WRITE_LOOP
.WRITE_ONE_CHAR:
	CMP AL, 1
	JNE .ACTUAL_CHAR
	CMP WORD [SS:BP+6], COMMAND_PORT_2
	JNE .DRIVE_1
	MOV AL, '2'
	JMP .ACTUAL_CHAR
.DRIVE_1:
	MOV AL, '1'
.ACTUAL_CHAR:
    INT 0x10
    INC BX
	JMP .WRITE_LOOP
.WRITING_DONE:
	POP CX
    POP AX
    RET


INT19:
	sti					; Enable interrupts
	PUSH CS
	POP DS
	MOV BX, MSG_INT19_SIGNATURE
	CALL WRITE_MESSAGE
	%if SHADOW = 1
	MOV BX, MSG_SHADOW
	CALL WRITE_MESSAGE
	CALL INSTALL_SHADOW
	MOV BX, MSG_SHADOW_2
	CALL WRITE_MESSAGE
	%endif

	xor	dx, dx				; Assume floppy drive (0)
TRY_BOOT:
	PUSH DX
	mov	ah, 0
	int	13h				; Reset drive
	jb	FAIL_BOOT
	POP DX
	xor	ax, ax
	mov	es, ax				; Segment 0
	mov	ax, 0201h			; One sector read
	mov	bx, 7C00h			;   offset  7C00
	mov	cl, 1				;   sector 1
	mov	ch, 0				;   track  0
	int	13h

	jb	FAIL_BOOT
	JMP 0:0x7C00			; Launch the sector we loaded

FAIL_BOOT:
	CMP DX, 0x80			; If this is the second go round, failing on 0x80, we're out of drives.
	JE FAILED_ALL_BOOT
	MOV DX, 0x80
	JMP TRY_BOOT
FAILED_ALL_BOOT:
	MOV BX, MSG_BOOT_FAIL
	CALL WRITE_MESSAGE
	INT 0x18			; Fall back to "NO ROM BASIC - SYSTEM HALTED" style error.

INSTALL_SHADOW:
	PUSH DS
	PUSH ES
	PUSH CX
	PUSH BX
	PUSH DX
	PUSH AX
	
	XOR AX, AX
	MOV DS, AX

	MOV WORD AX, DS:0x0413	; Steal 6K of memory
	SUB AX, 6
	MOV DS:0x0413, AX
	MOV CL, 6
	SHL AX, CL	; Target segment for shadowing

	CALL WRITE_AX

	PUSH AX
	CALL GET_VECTOR_FOR_CPU ; Clobbers AX; most places we use it don't need AX, but here we do.
	POP AX
	; Move all the INT13 and INT41/46 vectors to the new segment
	; We assume the old "migrate old segment to INT40" is still in place.
    MOV WORD DS:0x004C, DX
    MOV WORD DS:0x004E, AX



	; write the drive data table to INT 0x41 and 0x46
	MOV WORD DS:0x0104, DISK_1_TABLE
	MOV WORD DS:0x0106, AX
	MOV WORD DS:0x0118, DISK_2_TABLE
	MOV WORD DS:0x0120, AX

	MOV CX, CS
	MOV DS, CX
	MOV ES, AX

	XOR BX, BX
.SHADOW_LOOP:
	MOV WORD AX, DS:BX
	MOV WORD ES:BX, AX
	INC BX
	INC BX
	CMP BX,0x1800	; 6K size
	JAE .SHADOWING_DONE
	LOOP .SHADOW_LOOP
.SHADOWING_DONE:
	POP AX
	POP DX
	POP BX
	POP CX
	POP ES
    POP DS
	RET

	



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;INT 0X13 SOFTWARE DISK INTERRUPTS
;DONT FORGET HARDWARE INTERRUPTS ARE DISABLED WHEN SOFTWARE INTERRUPTS ARE CALLED
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;	
INT13:
	PUSHF
	CMP DL, 0X80		;CHECK FOR DISK NUMBER BEING REQUESTED 
	JE .START_INT13		;JMP IF 0X80 C:
%if COMMAND_PORT_2 != 0
	CMP DL, 0x81
	JE .START_INT13
%endif
	JNE NOT_A_DRIVE	;JMP IF NOT C: NOT A DRIVE IN THE SYSTEM
  .START_INT13:	
	POPF				; we don't need the pushed flags, so discard them.
	%if ALLOW_INTS = 1
	STI					;Restore interrupts to prevent time dilation.  This could be brittle as I doubt the hardware is reentrant-ready
	%endif
	CMP AH, 0X00
	JE RESET_DISK_SYSTEM 			;RESET DISK
	CMP AH, 0X0D
	JE RESET_DISK_SYSTEM 			;RESET DISK
	CMP AH, 0X01
	JE GET_STATUS_LAST_OPERATION	;GET STATUS OF LAST OPERATION 
	CMP AH, 0X02	
	JE DISK_OP						;READ DISK CHS
	CMP AH, 0X03
	JE DISK_OP						;WRITE DISK CHS
	CMP AH, 0X08
	JE PARAMETERS					;GET DISK PARAMETERS
	CMP AH, 0X15
	JE GET_DISK_TYPE				;GET DISK TYPE
	CMP AH, 0X10
	JE PLACEHOLDER_RETURN			;Test if ready
	CMP AH, 0X11
	JE PLACEHOLDER_RETURN			;Calibrate Drive
	CMP AH, 0X05
	JE DISK_OP						;FORMAT TRACK
	CMP AH, 0X06
	JE PLACEHOLDER_RETURN			;FORMAT TRACK/MARK BAD
	CMP AH, 0X04
	JE PLACEHOLDER_RETURN			;VERIFY
	CMP AH, 0X0C
	JE SEEK							;Seek to cylinder
	CMP AH, 0X12
	JE PLACEHOLDER_RETURN			;Controller Diagnostic
	CMP AH, 0X13
	JE PLACEHOLDER_RETURN			;Drive Diagnostic
	CMP AH, 0X14
	JE PLACEHOLDER_RETURN			;Internal Diagnostic
	CMP AH, 0X16
	JE PLACEHOLDER_RETURN			;Disc change detection
	CMP AH, 0X09					
	JE PLACEHOLDER_RETURN			;Initialize format to disk table

									;FUNCTION NOT FOUND
	MOV AH, 0X01					;INVALID FUNCTION IN AH
	STC								;SET CARRY FLAG 	
	JMP INT13_END_WITH_CARRY_FLAG


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;INT 0X13 SOFTWARE DISK INTERRUPTS
;DONT FORGET HARDWARE INTERRUPTS ARE DISABLED WHEN SOFTWARE INTERRUPTS ARE CALLED
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;	
INT13_8086:
	PUSHF
	CMP DL, 0X80		;CHECK FOR DISK NUMBER BEING REQUESTED 
	JE .START_INT13		;JMP IF 0X80 C:
%if COMMAND_PORT_2 != 0
	CMP DL, 0x81
	JE .START_INT13
%endif
	JNE NOT_A_DRIVE		;JMP IF NOT C: NOT A DRIVE IN THE SYSTEM
  .START_INT13:	
	POPF				; we don't need the pushed flags, so discard them.
	%if ALLOW_INTS = 1
		STI					; Restore interrupts to prevent time dilation
	%endif

;CALL DUMP_REGS
	CMP AH, 0X00
	JE RESET_DISK_SYSTEM 			;RESET DISK
	CMP AH, 0X0D
	JE RESET_DISK_SYSTEM 			;RESET DISK
	CMP AH, 0X01
	JE GET_STATUS_LAST_OPERATION	;GET STATUS OF LAST OPERATION 
	CMP AH, 0X02	
	JE DISK_OP_8086
	CMP AH, 0X03
	JE DISK_OP_8086				;WRITE DISK CHS
	CMP AH, 0X08
	JE PARAMETERS					;GET DISK PARAMETERS
	CMP AH, 0X15
	JE GET_DISK_TYPE				;GET DISK TYPE
	CMP AH, 0X10
	JE PLACEHOLDER_RETURN			;Test if ready
	CMP AH, 0X11
	JE PLACEHOLDER_RETURN			;Calibrate Drive
	CMP AH, 0X05
	JE DISK_OP						;FORMAT TRACK
	CMP AH, 0X06
	JE PLACEHOLDER_RETURN			;FORMAT TRACK/MARK BAD
	CMP AH, 0X04
	JE PLACEHOLDER_RETURN			;VERIFY
	CMP AH, 0X0C
	JE SEEK					;Seek to cylinder
	CMP AH, 0X12
	JE PLACEHOLDER_RETURN			;Controller Diagnostic
	CMP AH, 0X13
	JE PLACEHOLDER_RETURN			;Drive Diagnostic
	CMP AH, 0X14
	JE PLACEHOLDER_RETURN			;Internal Diagnostic
	CMP AH, 0X16
	JE PLACEHOLDER_RETURN			;Disc change detection
	CMP AH, 0X09					
	JE PLACEHOLDER_RETURN			;Initialize format to disk table

									;FUNCTION NOT FOUND
	MOV AH, 0X01					;INVALID FUNCTION IN AH
	STC								;SET CARRY FLAG 	
	JMP INT13_END_WITH_CARRY_FLAG


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PLACEHOLDER FOR FUNCTIONS THAT DON'T APPLY/WORK
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;		
PLACEHOLDER_RETURN:	
	MOV AH, 0X00		;STATUS 0X00 SUCCESSFULL
	CLC					;CLEAR CARRY FLAG SUCCESFUL	
	JMP INT13_END_WITH_CARRY_FLAG


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;RESET DISK 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;		
RESET_DISK_SYSTEM:
	PUSH SI
	XOR SI, SI
	PUSH DI
	MOV DI, DX				; Convert DL (80/81) to port offset (0/2)
	AND DI, 1
	SHL DI, 1
	MOV CX, CS:COMMAND_PORTS[DI]
	PUSH CX					; Desired Command Port, BP-22
	MOV CX, CS:DATA_PORTS[DI]
	PUSH CX					; Desired Data Port, BP-24

	CALL MAIN_RESET
	POP SI		; The unwanted ports
	POP SI		; The unwanted ports
	POP DI		; Restore saved DI
	POP SI		;Restore actual
	CMP AL, 0
	JNE .RESET_WENT_WRONG
	MOV AH, 0X00		;STATUS 0X00 SUCCESSFULL
	CLC					;CLEAR CARRY FLAG SUCCESFUL	
	JMP INT13_END_WITH_CARRY_FLAG
.RESET_WENT_WRONG:
	MOV AH, AL			; Return error in AH
	STC
	JMP INT13_END_WITH_CARRY_FLAG

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;STATUS OF LAST OPERATION  
;THIS PROABLY WILL NEED WORK
;THE CH376 ERROR STATUS NUMBERS DO NOT MATCH PC COMPATABLE NUMBERS
;STATUS 0X14 IS SUCCESS AND INTERPRETED TO RETURN 0X00
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;		
GET_STATUS_LAST_OPERATION:	
	PUSH DX
	PUSH DI
	MOV DI, DX				; Convert DL (80/81) to port offset (0/2)
	AND DI, 1
	SHL DI, 1
	MOV DX, CS:COMMAND_PORTS[DI]
	MOV AL, CH376S_GET_STATUS			;GET_STATUS OF INT
	OUT DX, AL				;OUT COMMAND PORT				
	MOV DX, CS:DATA_PORTS[DI]
	IN AL, DX					;READ IN STATUS DATA PORT
	POP DI
	POP DX
	CMP AL, CH376S_USB_INT_SUCCESS		;CHECK FOR USB_INT_SUCCESS
	JNE STATUS_DISK_ERROR				;IF USB_INT_SUCCESS
	
	MOV AH, 0X00						;STATUS 0X00 SUCCESSFULL
	CLC									;CLEAR CARRY FLAG SUCCESFUL	
	JMP INT13_END_WITH_CARRY_FLAG
	
STATUS_DISK_ERROR:
	; Instead of returning the CH376S status code in AL,
	; map some of them to BIOS-friendly codes
	CMP AL, CH376S_USB_INT_DISCONNECT		; DISC DISCONNECTED
	JNE .NOT_0X16
	MOV AH, 0xAA							; BIOS CODE AA
	JMP .STATUS_SELECTED

.NOT_0X16:
	CMP AL, CH376S_USB_INT_BUF_OVER			; DATA ERROR OR BUFFER OVERFLOW
	JNE .NOT_0X17
	MOV AH, 0x10							; BIOS CODE 10
	JMP .STATUS_SELECTED
.NOT_0X17:
	CMP AL, CH376S_USB_INT_DISK_ERR			; STORAGE DEVICE FAILURE
	JNE .NOT_0X1F
	MOV AH, 0x20							; BIOS CODE 20
	JMP .STATUS_SELECTED
.NOT_0X1F:	
	CMP AL, 0x99							; NOT a normal CH376S error
	JNE .NOT_0x99							; AL = 0x99 / DL = 0x99 means we detected a request off the end of the disc
	CMP DL, 0x99
	JNE .NOT_0x99
	MOV AH, 0x0B							; BIOS CODE 0B
	MOV DL, 0x80							; Restore sane DL=0x80
	JMP .STATUS_SELECTED
.NOT_0x99:
	MOV AH, 0xBB							; BIOS CODE BB as catch all

.STATUS_SELECTED:
	MOV AL, 0								; After a failure, claim 0 sectors read/written
	STC										;SET CARRY FLAG 	
	JMP INT13_END_WITH_CARRY_FLAG
	

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;READ DISK SECTOR	
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;LBA = (C × HPC + H) × SPT + (S − 1)
;MAX NUMBERS C = 0X3FF, H = 0XFF, S = 0X3F
;AH = 02h
;AL = number of sectors to read (must be nonzero)
;CH = low eight bits of cylinder number
;CL = sector number 1-63 (bits 0-5)
;high two bits of cylinder (bits 6-7, hard disk only)
;DH = head number
;DL = drive number (bit 7 set for hard disk)
;ES:BX -> data buffer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;WRITE DISK SECTOR(S)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;LBA = (C × HPC + H) × SPT + (S − 1)
;MAX NUMBERS C = 0X3FF, H = 0XFF, S = 0X3F
;AH = 03h
;AL = number of sectors to read (must be nonzero)
;CH = low eight bits of cylinder number
;CL = sector number 1-63 (bits 0-5)
;high two bits of cylinder (bits 6-7, hard disk only)
;DH = head number
;DL = drive number (bit 7 set for hard disk)
;ES:BX -> data buffer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;FORMAT A TRACK
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;LBA = (C × HPC + H) × SPT + (S − 1)
;MAX NUMBERS C = 0X3FF, H = 0XFF, S = 0X3F
;AH = 05h
;AL = Interleave value (ignored)
;CH = low eight bits of cylinder number
;CL = Low six bits ignored
;high two bits of cylinder (bits 6-7, hard disk only)
;DH = head number
;DL = drive number (bit 7 set for hard disk)
;ES:BX -> data buffer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

DISK_OP:
	; Store registers so we can access them at BP offsets

	PUSH BP
	MOV BP, SP
	PUSH DS					; BP-2
	PUSH ES					; BP-4
	PUSH DI					; BP-6
	PUSH SI					; BP-8
	PUSH DX					; BP-10
	PUSH CX					; BP-12
	PUSH BX					; BP-14
	PUSH AX					; BP-16	
	XOR CX, CX
	PUSH CX					; Retry Counter, BP-18
	PUSH CX					; Main Operation Command, BP-20
							; USB-write Command Command, BP-19
	PUSH CX					; Expected success, BP-22
							; Expected continue operation, BP-21
	MOV DI, DX				; Convert DL (80/81) to port offset (0/2)
	AND DI, 1
	SHL DI, 1
	MOV CX, CS:COMMAND_PORTS[DI]
	PUSH CX					; Desired Command Port, BP-24
	MOV CX, CS:DATA_PORTS[DI]
	PUSH CX					; Desired Data Port, BP-26
	
	CLD						; needed for bulk operations
	MOV CX, ES				; Write operations expect buffer at ES:BX
	MOV DS, CX				; but bulk operations expect it DS:BX
	
	CMP BYTE [SS:BP-15], 0x02	; Original AH, action type
	JE .READ_CONFIG				; Write and format need special handling for CH375/6 dichotomy
	CALL GET_CORRECT_WRITE_COMMAND_PORTED
	MOV CL, CH376S_DISK_WRITE
	MOV WORD [SS:BP-20], CX
	MOV BYTE [SS:BP-22], CH376S_USB_INT_DISK_WRITE
	MOV BYTE [SS:BP-21], CH376S_DISK_WR_GO
	JMP .CONFIG_DONE
.READ_CONFIG:
	MOV BYTE [SS:BP-19], CH376S_RD_USB_DATA0
	MOV BYTE [SS:BP-20], CH376S_DISK_READ
	MOV BYTE [SS:BP-22], CH376S_USB_INT_DISK_READ
	MOV BYTE [SS:BP-21], CH376S_DISK_RD_GO
	


.CONFIG_DONE:
	CALL DISK_IN_BOUND		; Clobbers disk number if outside of range
	CMP DL, 0x99
	JNE .REQUESTED_DETAILS_SANE
	MOV AL, 0x99
	JMP DISK_OP_ERROR
.REQUESTED_DETAILS_SANE:
							; Restore in case we're retrying:
	MOV BX,	[SS:BP-14]		; Original start of request
	MOV CX, [SS:BP-12]		; Used in LBA calculation
	MOV DX, [SS:BP-10]		; Sector count and action type in AX is pulled in later.

	CALL CONVERT_CHS_TO_LBA

	PUSH DX					;STORE LBA UPPER
	PUSH AX					;STORE LBA LOWER


	MOV DX, [SS:BP-24]
	MOV AL, [SS:BP-20]	;DISK_READ/Write
	OUT DX, AL			;OUT COMMAND PORT

	MOV DX, [SS:BP-26]

	POP AX				;GET LOWER LBA
	OUT DX, AL			;OUT DATA PORT
	MOV AL, AH			;NEXT BYTE
	OUT DX, AL			;OUT DATA PORT
	POP AX				;GET UPPER LBA
	OUT DX, AL			;OUT DATA PORT
	MOV AL, AH			;NEXT BYTE
	OUT DX, AL			;OUT DATA PORT
	
	CMP BYTE [SS:BP-15], 0x05	; Original AH -- 0x05 is "format track"
	JNE .HAS_NORMAL_SECTOR_COUNT
	MOV AL, MAX_SPT
	JMP .SEND_SECTOR_COUNT
.HAS_NORMAL_SECTOR_COUNT:
	MOV BYTE AL, [SS:BP-16]		;Original AX - AL is number of sectors
.SEND_SECTOR_COUNT:
	OUT DX, AL			;OUT DATA PORT

.SECTOR_ACTION:
	CALL AWAIT_INTERRUPT_PORTED
	CMP AX, 0XFFFF
	JE .RETRY_ACTION 					; We didn't get a response, so retrigger the command
	MOV DX, [SS:BP-24]					; Command port
	MOV AL, CH376S_GET_STATUS			;GET_STATUS
	OUT DX, AL							;OUT COMMAND port
	MOV DX, [SS:BP-26]					; Data port
	IN AL, DX							;READ IN STATUS DATA PORT

	CMP AL, CH376S_USB_INT_SUCCESS		;CHECK FOR USB_INT_SUCCESS COMPLETED READING
	JE DISK_OP_SUCCESS					;IF USB_INT_SUCCESS
	CMP AL, [SS:BP-22]					;COMPARE TO USB_INT_DISK_READ
%if DISPLAY_CH376S_ERRORS = 1
	JNE NOT_EXPECTED_STATUS						;IF NOT USB_INT_DISK_READ
%else
	JNE DISK_OP_ERROR
%endif
	; Send actual read/write to USB command
	MOV DX, [SS:BP-24]
	MOV AL, [SS:BP-19]		;RD_USB_DATA0/WR_USB_DATA/etc.
	OUT DX, AL			;OUT COMMAND port

	; Followup varies by operation type.
	CMP BYTE[SS:BP-15], 0x02
	JNE .NOT_READ_OPERATION
	
	; Read followup
	MOV DX, [SS:BP-26]
	IN AL, DX						;READ NUMBER OF BYTES FROM DATA PORT 
	MOV AH, 0X00					;CLEAR AH
	MOV CX, AX						;SET CX TO NUMBER OF BYTES
	MOV DI, BX						;SET TARGET DESTINATION
%if DOUBLE_WIDE = 1
	SHR CX, 1
	REP INSW						;BULK LOAD
%else
	REP INSB
%endif
	ADD BX, AX						;Bump BX one batch over
	JMP .NEXT_64
.NOT_READ_OPERATION:
	CMP BYTE[SS:BP-15], 0x03
	JNE .MUST_BE_FORMAT
	; Write followup
	MOV DX, [SS:BP-26]				; Send "0x40" to data port to imply 64 bytes coming
	MOV AX, 0x40
	OUT DX, AL						
	MOV CX, AX						;SET CX TO NUMBER OF BYTES
	MOV SI, BX						;SET Source location
%if DOUBLE_WIDE = 1
	SHR CX, 1
	REP OUTSW						;BULK LOAD
%else
	REP OUTSB
%endif
	ADD BX, AX						;Bump BX one batch over
	JMP .NEXT_64
.MUST_BE_FORMAT:
	; Format followup
	MOV DX, [SS:BP-26]				; Send "0x40" to data port to imply 64 bytes coming
	MOV AX, 0x40
	OUT DX, AL						
	MOV CX, AX						;SET CX TO NUMBER OF BYTES
	MOV AL, 0
.FORMAT_BYTE:
	OUT DX, AL
	LOOP .FORMAT_BYTE
.NEXT_64:
	MOV DX, [SS:BP-24]
	MOV AL, [SS:BP-21]				;DISK_RD_GO/DISK_WR_GO for NEXT 64 BYTES
	OUT DX, AL						;OUT COMMAND PORT
	JMP .SECTOR_ACTION				;LOOP UNTIL DONE

.RETRY_ACTION:
	; The items we need for a retry are on the stack right now
	INC WORD [SS:BP-18]
	CMP WORD [SS:BP-18], 3
	JA .DIDNT_RECOVER
	XOR SI, SI
	CALL MAIN_RESET
	CMP AX, 0
	JNE .DIDNT_RECOVER
	JMP .REQUESTED_DETAILS_SANE
.DIDNT_RECOVER:
	JMP DISK_OP_ERROR



DISK_OP_8086:
	; Store registers so we can access them at BP offsets

	PUSH BP
	MOV BP, SP
	PUSH DS					; BP-2
	PUSH ES					; BP-4
	PUSH DI					; BP-6
	PUSH SI					; BP-8
	PUSH DX					; BP-10
	PUSH CX					; BP-12
	PUSH BX					; BP-14
	PUSH AX					; BP-16	
	XOR CX, CX
	PUSH CX					; Retry Counter, BP-18
	PUSH CX					; Main Operation Command, BP-20
							; USB-write Command Command, BP-19
	PUSH CX					; Expected success, BP-22
							; Expected continue operation, BP-21
	MOV DI, DX				; Convert DL (80/81) to port offset (0/2)
	AND DI, 1
	SHL DI, 1
	MOV CX, CS:COMMAND_PORTS[DI]
	PUSH CX					; Desired Command Port, BP-24
	MOV CX, CS:DATA_PORTS[DI]
	PUSH CX					; Desired Data Port, BP-26
	
	CLD						; needed for bulk operations
	MOV CX, ES				; Write operations expect buffer at ES:BX
	MOV DS, CX				; but bulk operations expect it DS:BX
	
	CMP BYTE [SS:BP-15], 0x02	; Original AH, action type
	JE .READ_CONFIG				; Write and format need special handling for CH375/6 dichotomy
	CALL GET_CORRECT_WRITE_COMMAND_PORTED
	MOV CL, CH376S_DISK_WRITE
	MOV WORD [SS:BP-20], CX
	MOV BYTE [SS:BP-22], CH376S_USB_INT_DISK_WRITE
	MOV BYTE [SS:BP-21], CH376S_DISK_WR_GO
	JMP .CONFIG_DONE
.READ_CONFIG:
	MOV BYTE [SS:BP-19], CH376S_RD_USB_DATA0
	MOV BYTE [SS:BP-20], CH376S_DISK_READ
	MOV BYTE [SS:BP-22], CH376S_USB_INT_DISK_READ
	MOV BYTE [SS:BP-21], CH376S_DISK_RD_GO
	


.CONFIG_DONE:
	CALL DISK_IN_BOUND		; Clobbers disk number if outside of range
	CMP DL, 0x99
	JNE .REQUESTED_DETAILS_SANE
	MOV AL, 0x99
	JMP DISK_OP_ERROR
.REQUESTED_DETAILS_SANE:
							; Restore in case we're retrying:
	MOV BX,	[SS:BP-14]		; Original start of request
	MOV CX, [SS:BP-12]		; Used in LBA calculation
	MOV DX, [SS:BP-10]		; Sector count and action type in AX is pulled in later.

	CALL CONVERT_CHS_TO_LBA

	PUSH DX					;STORE LBA UPPER
	PUSH AX					;STORE LBA LOWER


	MOV DX, [SS:BP-24]
	MOV AL, [SS:BP-20]	;DISK_READ/Write
	OUT DX, AL			;OUT COMMAND PORT

	MOV DX, [SS:BP-26]

	POP AX				;GET LOWER LBA
	OUT DX, AL			;OUT DATA PORT
	MOV AL, AH			;NEXT BYTE
	OUT DX, AL			;OUT DATA PORT
	POP AX				;GET UPPER LBA
	OUT DX, AL			;OUT DATA PORT
	MOV AL, AH			;NEXT BYTE
	OUT DX, AL			;OUT DATA PORT
	
	CMP BYTE [SS:BP-15], 0x05	; Original AH -- 0x05 is "format track"
	JNE .HAS_NORMAL_SECTOR_COUNT
	MOV AL, MAX_SPT
	JMP .SEND_SECTOR_COUNT
.HAS_NORMAL_SECTOR_COUNT:
	MOV BYTE AL, [SS:BP-16]		;Original AX - AL is number of sectors
.SEND_SECTOR_COUNT:
	OUT DX, AL			;OUT DATA PORT

.SECTOR_ACTION:
	CALL AWAIT_INTERRUPT_PORTED
	CMP AX, 0XFFFF
	JE .RETRY_ACTION 					; We didn't get a response, so retrigger the command
	MOV DX, [SS:BP-24]					; Command port
	MOV AL, CH376S_GET_STATUS			;GET_STATUS
	OUT DX, AL							;OUT COMMAND port
	MOV DX, [SS:BP-26]					; Data port
	IN AL, DX							;READ IN STATUS DATA PORT

	CMP AL, CH376S_USB_INT_SUCCESS		;CHECK FOR USB_INT_SUCCESS COMPLETED READING
	JE DISK_OP_SUCCESS					;IF USB_INT_SUCCESS
	CMP AL, [SS:BP-22]					;COMPARE TO USB_INT_DISK_READ
%if DISPLAY_CH376S_ERRORS = 1
	JNE NOT_EXPECTED_STATUS						;IF NOT USB_INT_DISK_READ
%else
	JNE DISK_OP_ERROR
%endif
	; Send actual read/write to USB command
	MOV DX, [SS:BP-24]
	MOV AL, [SS:BP-19]		;RD_USB_DATA0/WR_USB_DATA/etc.
	OUT DX, AL			;OUT COMMAND port

	; Followup varies by operation type.
	CMP BYTE[SS:BP-15], 0x02
	JNE .NOT_READ_OPERATION
	
	; Read followup
	MOV DX, [SS:BP-26]
	IN AL, DX						;READ NUMBER OF BYTES FROM DATA PORT 
	MOV DI, BX						;SET TARGET DESTINATION
%if DOUBLE_WIDE = 1
%rep 32
	IN AX, DX					;Read a word at a time
	STOSW
%endrep
%else
%rep 64
	IN AL, DX	;An alternate approach-- loading two entries into AX and using STOSW, is less efficient because we get the low part
	STOSB		; then the high part in AL, so two XCHG or whatever are needed to correct it.
%endrep
%endif
	MOV BX, DI
	JMP .NEXT_64
.NOT_READ_OPERATION:
	; Write followup
	MOV DX, [SS:BP-26]				; Send "0x40" to data port to imply 64 bytes coming
	MOV AX, 0x40
	OUT DX, AL						
	MOV SI, BX
	%if DOUBLE_WIDE = 1
%rep 32
  	LODSW
	OUT DX, AX					;WRITE TO DATA PORT
%endrep
%else
%rep 32
  	lodsw			; Suggested optimization by FreddyV
	out dx,al
	xchg ah,al
	out dx,al
%endrep
%endif
	MOV BX, SI
.NEXT_64:
	MOV DX, [SS:BP-24]
	MOV AL, [SS:BP-21]				;DISK_RD_GO/DISK_WR_GO for NEXT 64 BYTES
	OUT DX, AL						;OUT COMMAND PORT
	JMP .SECTOR_ACTION				;LOOP UNTIL DONE

.RETRY_ACTION:
	; The items we need for a retry are on the stack right now
	INC WORD [SS:BP-18]
	CMP WORD [SS:BP-18], 3
	JA .DIDNT_RECOVER
	XOR SI, SI
	CALL MAIN_RESET
	CMP AX, 0
	JNE .DIDNT_RECOVER
	JMP .REQUESTED_DETAILS_SANE
.DIDNT_RECOVER:
	JMP DISK_OP_ERROR


NOT_EXPECTED_STATUS:							; DEBUG FEATURE: DISPLAY ERROR MESSAGE
											; We still have BP-related offsets
	PUSH AX
	PUSH DS
	MOV AX, CS						; GET CS 
	MOV DS, AX						; SET DS TO CS
	MOV BX, MSG_IO_ERROR	
	CALL WRITE_MESSAGE
	POP DS
	POP AX
	CALL WIRTE_AL_INT10_E			; AL has original error number
	MOV AX, 0x0E2F					; Write slash
	INT 0x10
	MOV AL, BYTE [SS:BP-15]			; Load original AH (Action type)
	CALL WIRTE_AL_INT10_E
	CALL END_OF_LINE
	JMP DISK_OP_ERROR



DISK_OP_SUCCESS:
	POP AX	; Data Port
	POP AX	; Command Port
	POP AX	; Secondary Command storage
	POP AX	; Retry counter
	POP AX	; Command storage
	POP AX	; Actual registers
	POP BX
	POP CX
	POP DX
	POP SI
	POP DI
	POP ES
	POP DS
	POP BP
	MOV AH, 0X00		;STATUS 0X00 SUCCESSFULL
	CLC					;CLEAR CARRY FLAG SUCCESFUL	
	JMP INT13_END_WITH_CARRY_FLAG

DISK_OP_ERROR:
	POP BX	; Data Port
	POP BX	; Command Port
	POP BX	; Secondary Command storage
	POP BX	; Retry counter
	POP BX	; Command storage
	POP BX	; Actual registers -- we don't want to restore AX
	POP BX
	POP CX
	POP DX
	POP SI
	POP DI
	POP ES
	POP DS
	POP BP
	JMP STATUS_DISK_ERROR

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;GET PARAMETERS	0X08
;RETURNS
;AH=STATUS 0X00 IS GOOD
;BL=DOES NOT APPLY 
;CH=CYLINDERS
;CL=0-5 SECTORS PER TRACK 6-7 UPPER 2 BITS CYLINDER
;DH=NUMBER OF HEADS / SIDES -1
;DL=NUMBER OF DRIVES
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;	
PARAMETERS:
	PUSH AX					;STORE AX
	PUSH BX					;STORE BX
	PUSH DI
	MOV DI, DX				; Convert DL (80/81) to port offset (0/2)
	AND DI, 1
	SHL DI, 1
	PUSH WORD CS:COMMAND_PORTS[DI]
	PUSH WORD CS:DATA_PORTS[DI]
	
	CALL GET_CAPACITY_PORTED
	POP BX
	POP BX
	; DX:AX now has sector count

	CMP AX, 0
	JNE .HAS_PARAMS
	CMP DX, 0
	JNE .HAS_PARAMS
	JMP .PARAMETERS_NOT_P

.HAS_PARAMS:
	; If we exceed (MAX_SPT * MAX_HPC * MAX_CYL)
	; just identify as the max amount
	CMP DX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	JB .SAFE_PARAMS
	CMP DX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	JA .USE_MAX_PARAMS
	CMP AX, (MAX_SPT * MAX_HPC * MAX_CYL) % 65536
	JBE .SAFE_PARAMS

.USE_MAX_PARAMS:
	MOV DX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	MOV AX, (MAX_SPT * MAX_HPC * MAX_CYL) % 65536

.SAFE_PARAMS:
	MOV CX, (MAX_SPT * MAX_HPC)
				     		
							; The cylinders and heads seem to be "maximum"
							; so on 1024 cylinders, 1023 is max
							; 16 heads, 15 is max
							; but 63 sectors per track the right answer is actually 63
	DIV CX					;DIV DX:AX / CX
	XOR DX, DX
	SUB AX, 1				; Max cylinder is number of cylinders minus one
	MOV CH, AL				;CH=0-7 CYLINDERS
	MOV CL, 6
	SHL AH,CL				; Always use 8086 instructions because
	MOV CL, MAX_SPT			;SECTORS PER TRACK
	AND CL, 0X3F			;CLEAR BITS 7-6
	ADD CL, AH				;ADD IN 8-9 BITS CYLINDER
	MOV DH, MAX_HPC - 1		;NUMBER OF HEADS / SIDES

; This is stupid.  It assumes if we specified two drives, they must exist.
; It would be nicer to rely on the drive count in the BIOS, but I don't trust that other disc systems won't monkey with it.
%if COMMAND_PORT_2 != 0
	MOV DL, 2
%else
	MOV DL, 0X01			;NUMBER OF DRIVES
%endif
	JMP .END_PARAMETERS

.END_PARAMETERS:

	POP DI
	POP BX				;RESTORE BX
	POP AX				;RESTORE AX
	
	MOV AH, 0X00		;STATUS 0X00 SUCCESSFULL
	CLC					;CLEAR CARRY FLAG SUCCESFUL	
	JMP INT13_END_WITH_CARRY_FLAG
	
.PARAMETERS_NOT_P:
	POP DI
	POP BX				;RESTORE BX
	POP AX				;RESTORE AX
	
	MOV AH, 0X01		;STATUS 0X01 UNSUCCESSFULL
	STC 				;SET CARRY FLAG	
	JMP INT13_END_WITH_CARRY_FLAG

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;GET DISK TYPE	0X15
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
GET_DISK_TYPE:
	PUSH BX						;STORE BX
	PUSH AX
	
	PUSH DI
	MOV DI, DX				; Convert DL (80/81) to port offset (0/2)
	AND DI, 1
	SHL DI, 1
	PUSH WORD CS:COMMAND_PORTS[DI]
	PUSH WORD CS:DATA_PORTS[DI]
	CALL GET_CAPACITY_PORTED
	POP BX
	POP BX
	; DX:AX now has sector count - move to where the output wants it.
	MOV CX, DX
	MOV DX, AX
	; CX:DX now has the sector count

	CMP CX, 0
	JNE .HAS_DISK_TYPE_PARAMS
	CMP DX, 0
	JNE .HAS_DISK_TYPE_PARAMS
	JMP .GET_DISK_TYPE_NOT_P

.HAS_DISK_TYPE_PARAMS:
	; If we exceed 0xFAC53F sectors (MAX_SPT * MAX_HPC * MAX_CYL)
	; just identify as FAC53F
	CMP CX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	JB .SAFE_DISK_TYPE_PARAMS
	CMP CX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	JA .USE_MAX_DISK_TYPE_PARAMS
	CMP DX, (MAX_SPT * MAX_HPC * MAX_CYL) % 65536
	JBE .SAFE_DISK_TYPE_PARAMS

.USE_MAX_DISK_TYPE_PARAMS:
	MOV CX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	MOV DX, (MAX_SPT * MAX_HPC * MAX_CYL) % 65536

.SAFE_DISK_TYPE_PARAMS:
	MOV AX, 0X0300			;AH=0X03 FIXED DISK AL=RETURN 0X00
	JMP .END_GET_DISK_TYPE	;END
	
.GET_DISK_TYPE_NOT_P:
	MOV AX, 0X0000			;AH=0X00 WHEN NOT PRESENT 
	JMP .END_GET_DISK_TYPE
	
.END_GET_DISK_TYPE:
	POP DI
	POP AX
	POP BX					;RESTORE BX
	CLC						;CLEAR CARRY FLAG SUCCESFUL	
	JMP INT13_END_WITH_CARRY_FLAG

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;SEEK DISK (0x0C)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
SEEK:
	PUSH CX
	PUSH AX
	MOV AL, 1				; Check if a 1-sector read at the start of track would blow up
	AND CL, 0b11000000
	CALL DISK_IN_BOUND		; Clobbers disk number if outside of range
	CMP DL, 0x99
	JNE .REQUESTED_DETAILS_SANE
	MOV AL, 0x99
	JMP SEEK_ERROR
  .REQUESTED_DETAILS_SANE:
	POP AX
	POP CX
	JMP PLACEHOLDER_RETURN

SEEK_ERROR:
	POP CX	; Read the old AX into CX because we don't want to clobber error code in AL
	POP CX
	JMP STATUS_DISK_ERROR

	
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;END INT 0X13 WITH UPDATED CARRY FLAG		
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  INT13_END_WITH_CARRY_FLAG:	;THIS IS HOW I RETURN THE CARRY FLAG
	PUSH AX						;STORE AX
	PUSHF						;STORE FLAGS
	POP AX						;GET AX = FLAGS
	PUSH BP						;STORE BP
	MOV BP, SP              	;Copy SP to BP for use as index
	ADD BP, 0X08				;offset 8
	AND WORD [BP], 0XFFFE		;CLEAR CF = ZER0
	AND AX, 0X0001				;ONLY CF 
	OR	WORD [BP], AX			;SET CF AX
	POP BP               		;RESTORE BASE POINTER
	POP AX						;RESTORE AX	
	IRET						;RETRUN

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; WHEN REQUEST IS NOT A VALID DRIVE NUMBER
; INVOKE OLD BIOS VECTOR AND RETURN
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
NOT_A_DRIVE:
  	POPF ; we want the flags we stored before the original compare
	INT 0x40
	PUSH BP
	MOV BP,SP
	PUSHF
	POP WORD [SS:BP+6]
	POP BP
	IRET
		
;;;;;;;;;;;;;;;;;;;;;;;
;WRITE TO SCREEN;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;

WRITE_AL_AS_DIGIT:
	MOV AH, 0x0E
	OR AL, 0x30
	INT 0x10
	RET

WRITE_AX:
	PUSH AX
	MOV AL, AH
	CALL WIRTE_AL_INT10_E
	POP AX
	CALL WIRTE_AL_INT10_E
	RET


WIRTE_AL_INT10_E:

	PUSH AX
	PUSH BX
	PUSH CX
	PUSH DX

	MOV BL, AL

	MOV DH, AL
	MOV CL, 0X04
	SHR DH, CL

	MOV AL, DH
	AND AL, 0X0F
	CMP AL, 0X09
	JA LETTER_HIGH

	ADD AL, 0X30
	JMP PRINT_VALUE_HIGH

	LETTER_HIGH:
	ADD AL, 0X37

	PRINT_VALUE_HIGH:
	MOV AH, 0X0E
	INT 0X10

	MOV AL, BL
	AND AL, 0X0F
	CMP AL, 0X09
	JA LETTER_LOW

	ADD AL, 0X30
	JMP PRINT_VALUE_LOW

	LETTER_LOW:
	ADD AL, 0X37

	PRINT_VALUE_LOW:
	MOV AH, 0X0E
	INT 0X10

	POP DX
	POP CX
	POP BX
	POP AX

	RET


WRITE_SECTORS_IN_MB:
	; Assumes sectors in DX:ax
	; Likely to get confused on devices over 64Gb as the first div below
	; overflows.
	PUSH AX
	PUSH CX
	PUSH DX
	PUSH BX
	XOR BX, BX
	CMP DX, 2048 ; 2048 x 10000h + sectors will overflow the DIV
	JB CONVERT_TO_MB_GB
	MOV BL, 1 ; FLAG TO USE GB
	MOV AX, DX
	MOV DX, 0
			  ; Instead of dividing sectors (512 bytes) by 2048 to get MB
			  ; Divide 10000h-sectors (32Mb units) by 32 to get GB
	MOV CL, 5
	SHR AX,CL  ; This remains 8086 version because it's not performance critical
	JMP CONVERT_TO_DECIMAL


CONVERT_TO_MB_GB:
	MOV CX, 2048
	DIV CX

CONVERT_TO_DECIMAL:
	MOV DX, 0 ; Divide by 10000, take the digit and convert to ASCII, and print
	MOV CX, 10000
	DIV CX
	CALL WRITE_AL_AS_DIGIT

	MOV AX, DX	  ;  Take remainder, divide by 1000, repeat
	mov DX, 0
	MOV CX, 1000
	DIV CX
	CALL WRITE_AL_AS_DIGIT

	MOV AX, DX	  ;  Take remainder, divide by 100, repeat
	MOV DX, 0
	MOV CX, 100
	DIV CX
	CALL WRITE_AL_AS_DIGIT

	MOV AX, DX
	MOV DX, 0
	MOV CX, 10	  ;  Take remainder, divide by 10, repeat
	DIV CX
	CALL WRITE_AL_AS_DIGIT


	MOV AL, DL	  ; Last remainder is a single digit.
	CALL WRITE_AL_AS_DIGIT
	CMP BL, 1
	JNE DISPLAY_M
	MOV AX, 0E47H	; Display "G"
	INT 0x10
	JMP LEAVE_SECTOR_DISPLAY
DISPLAY_M:
	MOV AX, 0E4DH    ; Display "M"
	INT 0x10
	

LEAVE_SECTOR_DISPLAY: 
	POP BX
	POP DX
	POP CX
	POP AX
	RET


; CLOBBERS AX.
; Expects command port and data port to be the last two things on the stack.
; Will wait up to FFFE probes.  If AX returns as 1 to FFFE, it finished on time.  At FFFF we assume it never caught.
; Some real world testing seems to show most activities are finishing in < 0x100 probes, so if you're waiting hundreds of times longer, it's fair to call alarm.
AWAIT_INTERRUPT_PORTED:
	PUSH BP
	MOV BP, SP
	PUSH DX
	PUSH CX
	
	XOR CX, CX
	MOV DX, [SS:BP+6]
.INTERRUPT_LOOP:
	INC CX
	CMP CX, 0xFFFF
	JE .INTERRUPT_DONE
	IN AL, DX				; Loop waiting for the interrupt
	AND AL, 0x80
	JNZ .INTERRUPT_LOOP
.INTERRUPT_DONE:
	MOV AX, CX
	POP CX
	POP DX
	POP BP
	RET

; Expects CX to have cylinder/sector and DH to have head number
; Leaves sector count in DX:AX

CONVERT_CHS_TO_LBA:
	PUSH CX
	PUSH CX					;STORE CX / SECTOR NUMBER
	PUSH DX					;STORE DX / DH HEAD NUMBER

	XOR AX, AX
	MOV AL, CL				;Top two bits go in AL
	SHL AX, 1					; shunted to bottom of AH
	SHL AX, 1
	MOV AL, CH				; bottom 8 bits now in AL

	MOV CX, MAX_HPC			;NUMBER OF HEADS / SIDES (HPC)
	MUL CX					;AX = C X HPC
	POP CX					;GET HEAD NUMBER
	MOV CL, CH				;MOV HEAD NUMBER
	MOV CH, 0X00			;CLEAR CH
	ADD AX, CX				;ADD IN HEAD (C X HPC + H)
	MOV CX, MAX_SPT			;SECTORS PER TRACK	
	MUL CX					;DX:AX (C X HPC + H) X SPT
	POP CX					;GET SECTOR NUMBER
	AND CX, 0X003F			;CLEAR OUT CYLINDER
	DEC CX					;(S - 1)
	ADD AX, CX				;LBA = (C × HPC + H) × SPT + (S − 1)
	ADC DX, 0X00			;IF THERE IS A CARRY POSIBLE I DONT KNOW
	POP CX
	RET

; Does the CH376S lookup and reads sector count into DX:AX
; Assumes the last two items on the stack are control and data ports
GET_CAPACITY_PORTED:
	PUSH BP
	MOV BP, SP
	PUSH BX
	PUSH CX
	XOR CX, CX

.ASK_FOR_SIZE:
	INC CX
	CMP CX, 10		; Retry 10 times.  It seems normally, the first run through stalls with the device
					; returning error 82 ("ERROR_DISK_DISCON") the first time through but normal the second and on.
					; Some drives seem to get stuck at 82 forever, so we will fall through and assume max geometry
	JAE .DIDNT_GET_CAPACITY
	MOV DX, [SS:BP+6]
 	MOV AL, CH375_DISK_SIZE	; Get Disc Capacity
    OUT DX, AL
	PUSH WORD [SS:BP+6]
	PUSH WORD [SS:BP+4]
	CALL AWAIT_INTERRUPT_PORTED
	POP DX	; Discard ports after use
	POP DX
	CMP AX, 0xFFFF
	JE .ASK_FOR_SIZE
	MOV DX, [SS:BP+6]
	MOV AL, CH376S_GET_STATUS		;GET_STATUS AFTER WAITING
	OUT DX, AL			;OUT COMMAND PORT				
	MOV DX, [SS:BP+4]
	IN AL, DX				;READ IN STATUS DATA PORT

	CMP AL, CH376S_USB_INT_SUCCESS
	JE .SANE_RESPONSE
	MOV DX, [SS:BP+6]
	MOV AL, CH376S_DISK_R_SENSE	;Read error status.  Some old forum posts suggest this may be required for balky DISK_SIZE
	OUT DX, AL			;OUT COMMAND PORT				
	PUSH WORD [SS:BP+6]
	PUSH WORD [SS:BP+4]
	CALL AWAIT_INTERRUPT_PORTED		; Whether we timed out or not, we'll just start the probe again.  If it's truly borked, we'll run out of probes.
	POP DX
	POP DX
	JMP .ASK_FOR_SIZE
.SANE_RESPONSE:
	MOV DX, [SS:BP+6]
	MOV AL, CH376S_RD_USB_DATA0 	; Read device data
    OUT DX, AL
	MOV DX, [SS:BP+4]
	IN AL, DX		    			; count- should be eight; sometimes we have crud left over from previous steps
	CMP AL, 8
	JNE .ASK_FOR_SIZE
    IN AL, DX  			   			; highest byte -- DIFFERENT FROM CH376S DISK_CAPACITY, CH375 DISK_SIZE is big-endian
	mov BH, AL
	IN AL, DX 			   			; second highest
	MOV BL, AL

	PUSH BX
	IN AL, DX						; third
	MOV BH, AL
	IN AL, DX						; fourth
	MOV BL, AL

	PUSH BX
	IN AL, DX						; bytes 5-8 are of low value on CH375-compatible flow.  They represent sector size
	IN AL, DX						; but we'll assume 512. - 00 00 02 00 - to clear buffer
	IN AL, DX		
	IN AL, DX		
	

	POP AX							; DX:AX now contains sector count.
	POP DX
.SIZE_DONE:
	POP CX
	POP BX
	POP BP
	RET
.DIDNT_GET_CAPACITY:					; If the detection fails, let's fall back and assume a max-size device.
	MOV DX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	MOV AX,	(MAX_SPT * MAX_HPC * MAX_CYL) % 65536
	JMP .SIZE_DONE



END_OF_LINE:
	PUSH AX
	MOV AX, 0x0E0D		; Print a newline
    INT 0x10
    MOV AL, 0x0A		; and line feed
    INT 0x10
	POP AX
	RET;

DISK_IN_BOUND:
	PUSH CX
	PUSH BX
	PUSH DX
	PUSH AX
	PUSH SI

	PUSH DX					; We'll need DL (drive number) later
	PUSH AX					; We'll need AX (disc operation and sector count) later

	CALL CONVERT_CHS_TO_LBA ; DX:AX has requested LBA value for first sector
	POP BX
	CMP BH, 0x05	
	JNE NOT_IN_FORMAT
	MOV BL, MAX_SPT
NOT_IN_FORMAT:
	DEC BL
	MOV BH, 0
	ADD AX, BX				; Adding BL-1 (or MAX_SPT-1 for format) gives last sector read/wrote
	ADC DX, 0				; Make sure we get that carry

	POP SI					; SI contains original DX
	AND SI, 0xFF			; Trim to DL, should be 0x80 for drive 1, 0x81 for drive 2
	PUSH DX
	PUSH AX
	XOR DX, DX
	CMP SI, 0x80
	JNE .COMPARE_AGAINST_DISK_2
	MOV WORD AX, [CS:DISK_1_TABLE]
	MOV WORD CX, [CS:DISK_1_TABLE+2]
	MUL CX
	MOV BYTE CL, [CS:DISK_1_TABLE+0x0E]
	JMP .FINISH_LBA
.COMPARE_AGAINST_DISK_2:
	MOV WORD AX, [CS:DISK_2_TABLE]
	MOV WORD CX, [CS:DISK_2_TABLE+2]
	MUL CX
	MOV BYTE CL, [CS:DISK_2_TABLE+0x0E]
.FINISH_LBA:
	MOV CH, 0
	MUL CX					; DX:AX has ROM disc paramater max LBA
	
	POP CX		; CX = requested low word
	POP SI		; SI = requested high word

	CMP SI, DX	; High word less than max
	JB END_IN_BOUNDS
	JA END_OUT_OF_BOUNDS
	CMP CX, AX	; High words equal, make sure low word is less than max
	JBE END_IN_BOUNDS

END_OUT_OF_BOUNDS:
	POP SI		; Empty the stack, but clobber DL
	POP AX
	POP DX
	MOV DL, 0x99
	POP BX
	POP CX
	RET

END_IN_BOUNDS:
	POP SI
	POP AX
	POP DX
	POP BX
	POP CX
	RET

; There's "theoretically" a BIOS-provided counter you can use at 0000:046C.  But it's dodgy: you have to turn on
; interrupts that wouldn't otherwise be on, and probably program the interrupt masks to allow the tick to work.
; It's less of a hassle and seem to work better to just use the other timer on the 8253-- normally used for sound-- 
; and poll it as a no-interrupt way to get a desired approximate countdown of 1/38 of a second (notes seem to imply
; the countdown is FFFF to 0 by twos with the square wave high, and then again with low, for a 1/19 second cycle)
REST_18TH:
	PUSH BX				; Used as "highest seen/initial value"
	PUSH CX				; Used to marshall recieved values
	PUSH DX				; Used to store flags on port 61 for easy toggling
	PUSH AX				
	PUSH SI				;used for counter
	
	MOV SI, AX

	IN AL, 0x61
	AND AL, 0b11111100	; Force counter and speaker off
	OUT 0x61, AL
	MOV DL, AL			; Save "speaker off" mode
	
	.WAIT_ONE_TICK:
	MOV BX, 0xFFFF			; Start with "highest seen" of 0xFFFF.  Once we lower it and see a value above, assume we've cycled.
	MOV AL, 0b10110110  	; Timer 2 in square-wave mode but expecting input.  This causes it to count down twice as fast
							; but might reduce weird noises left from mode changes when switching back out of this mode.
	OUT 0x43, AL
	MOV AL, 0xFF		; Just do FFFF tries.
	OUT 0x42, AL
	OUT 0x42, AL
	MOV AL, DL
	OR AL, 0b00000001	; Turn on counter but not speaker itself
	OUT 0x61, AL
	.WAIT_FOR_COUNTDOWN:
		MOV CX, 0x1000		; We don't want to be constantly bothering the timer to test, but we don't want to let it sit so long that it's wasting time.
		.SPIN_LOOP:
			LOOP .SPIN_LOOP

		MOV AL, 0b10000110 ; Latch counter for timer #2
		OUT 0x43, AL
		IN AL, 0x42			; Yes this is backwards, read LSB then MSB, but since we're looking for 0, it's equal.
		MOV CL, AL
		IN AL, 0x42
		
		MOV AH, AL
		MOV AL, CL
		CMP AX, 0000		
		JE .FINISHED_WAIT
		CMP AX, BX			; If AX exceeds the "lowest seen", we've passed zero.
		JA .FINISHED_WAIT	; Compare UNSIGNED values, or it decides 7FFF > FFFF
		MOV BX, AX			; AX <= BX, as expected, so update the new "lowest seen".
		JMP .WAIT_FOR_COUNTDOWN
	.FINISHED_WAIT:
		DEC SI
		CMP SI, 0
		JE .END_WAIT_GROUP		
		JMP .WAIT_ONE_TICK	
	.END_WAIT_GROUP:
		MOV AL, DL			; Restore control flags
		OUT 0x61, AL		
		POP SI
		POP AX
		POP DX
		POP CX
		POP BX
		RET

;IF SI=1, tries to do a busy-animation.
; Expects ports to be passed as command port, then data port on stack just before call
;CLOBBERS AX.  AX=0 implies successful reset, AX=FFFF means we can't reset and should panic.
MAIN_RESET:
PUSH BP
MOV BP, SP
PUSHF
PUSH BX
PUSH CX
PUSH DX
PUSH DI
	CMP SI, 0
	JE .DONT_START_DOTS	; If we're displaying messages (initial boot)
	MOV BX, MSG_INIT	; Write the INIT message here because we have
    CALL WRITE_MESSAGE	; ports in the right place on the stack to resolve the "#"
	XOR DI, DI
	CALL ADVANCE_SPINNER
.DONT_START_DOTS:
	MOV BX, 200			; Try to reset the thing 200 times
.RESET_ONCE:			
	CMP BX, 0
	JE .RESET_FAILED_MODULE
	MOV CX, 100
.SEND_RESET:
	MOV DX, [SS:BP+6]	; Command port on top of stack
	MOV AL, CH376S_RESET_ALL 		;COMMAND RESET
	OUT DX, AL			;OUT COMMAND PORT
	IN AL, DX			; Used in example for delay

	CMP SI, 0
	JE .NO_DOTS
	CALL ADVANCE_SPINNER
.NO_DOTS:
	LOOP .SEND_RESET
	MOV AX, WAIT_LEVEL
	CALL REST_18TH			; Let's use the timer to, well, time a delay.  The datasheet says 35ms, so 1/18 second should be plenty.

	MOV DX, [SS:BP+6]		; Command port from stack
	MOV AX, CH376S_CHECK_EXIST
	OUT DX, AL
	MOV DX, [SS:BP+4]		;Data port from inherited stack
	MOV AL, 0x57
	OUT DX, AL
	IN AL, DX
	CMP AL, 0xA8
	JE .RESET_DONE
	DEC BX
	JMP .RESET_ONCE
.RESET_DONE:
	CMP SI, 0
	JE .NO_DONE_MSG
	MOV BX, MSG_DETECT_DONE
	CALL WRITE_MESSAGE
	CALL ADVANCE_SPINNER
.NO_DONE_MSG:
	MOV BX, 0020
.MODE_SET:
	;Set the mode to 0x07 first (valid USB host/reset USB)
	;then to 0x06 (valid USB host, auto generate SOF packet)
	MOV CX, 0xFFFF
	MOV DX, [SS:BP+6]			; Command port from inherited stack
    MOV AL, CH376S_SET_USB_MODE 	; SET_USB_MODE
	OUT DX, AL			; OUT COMMAND PORT
	MOV DX, [SS:BP+4]			; Data port from inherited stack
    MOV AL, 0X07					; MODE 0X07
	OUT DX, AL				; OUT DATA PORT
	CMP SI, 0
	JE .WAIT_FOR_MODE_SWITCH_1
	CALL ADVANCE_SPINNER
.WAIT_FOR_MODE_SWITCH_1:
	DEC CX
	CMP CX, 0
	JE .NEXT_MODE_SET		; Give up after 0xFFFE waits with no success - the first subtraction happens before a load
	IN AL, DX						; DX is always DATA_PORT here
	CMP AL, CH376S_CMD_RET_SUCCESS	; 
	JNE .WAIT_FOR_MODE_SWITCH_1 ; If we have success, fall through to the second mode change


	MOV CX, 0xFFFF
    MOV AL, CH376S_SET_USB_MODE		; SET_USB_MODE
	MOV DX, [SS:BP+6]			; Command port from inherited stack
	OUT DX, AL			; OUT COMMAND PORT
    MOV AL, 0X06					; MODE 0X06
	MOV DX, [SS:BP+4]			; Data port from inherited stack
	OUT DX, AL				; OUT DATA PORT
	CMP SI, 0
	JE .WAIT_FOR_MODE_SWITCH_2
	CALL ADVANCE_SPINNER
.WAIT_FOR_MODE_SWITCH_2:
	DEC CX
	CMP CX, 0
	JE .NEXT_MODE_SET		; This decrements once before the first load, but after 0xFFFE loads, if we didn't get success, we'll restart the reset cycle.
	IN AL, DX						; DX is data port here.
	CMP AL, CH376S_CMD_RET_SUCCESS	; Once we have success, move on
	JE .RIGHT_MODE
	JMP .WAIT_FOR_MODE_SWITCH_2	; If we haven't gotten success yet, and haven't ran out of retries, load again to see if we got a success.

.NEXT_MODE_SET:				; If we didn't get the right responses the first time, do it again, up to 20 times.
	DEC BX
	CMP BX, 0
	JE .RESET_FAILED_MODULE
	JMP .MODE_SET

.RIGHT_MODE:

	CMP SI, 0
	JE .NO_RIGHT_MODE_MSG
	MOV BX, MSG_MODE_DONE
	CALL WRITE_MESSAGE
	CALL ADVANCE_SPINNER
.NO_RIGHT_MODE_MSG:
	MOV CX, 0
.CONNECT:
	; DISK_INIT seems to work and get us a live disc with the device name loaded on both 375 and 376.  This terrifies me, though because it's not in the spec.
	; DISK_INQUIRY seems to actually get the device name, so I'd rather run them seperately.
	CMP CX, 10
	JAE .RESET_FAILED 		; Failure for disc
    MOV AL, CH375_DISK_INIT	; ACTUALLY DISK_INIT
	MOV DX, [SS:BP+6]			; Command port from inherited stack
	OUT DX, AL					;OUT COMMAND PORT
	CMP SI, 0
	JE .NO_SPIN_ON_CONNECT
	CALL ADVANCE_SPINNER

.NO_SPIN_ON_CONNECT:
	MOV AX, WAIT_LEVEL
	CALL REST_18TH				; Wait a short tick instead and THEN wait for the interrupt.
	MOV AX, [SS:BP+6]			; Command port from inherited stack
	PUSH AX
	MOV AX,  [SS:BP+4]
	PUSH AX
	CALL AWAIT_INTERRUPT_PORTED
	POP BX						; Discard pushed ports
	POP BX
	CMP AX, 0xFFFF				; If we timed out waiting for the interrupt, retry the action.  Limit of 10 times before admitting defeat.
	JNE .POST_CONNECT_INT
	INC CX
	JMP .CONNECT

.POST_CONNECT_INT:
	MOV AL, CH376S_GET_STATUS		;GET_STATUS AFTER WAITING
	OUT DX, AL			;OUT COMMAND PORT				
	MOV DX, [SS:BP+4]			; Data port from inherited stack
	IN AL, DX				;READ IN STATUS DATA PORT
	INC CX
	CMP AL, CH376S_USB_INT_SUCCESS  ;CHECK FOR USB_INT_SUCCESS
	JNE .CONNECT
	
	MOV AX, WAIT_LEVEL
	CALL REST_18TH			; A wait seems to be needed to avoid some drives failing to activate.
	PUSH WORD [SS:BP+6]			; Command port from inherited stack
	PUSH WORD [SS:BP+4]			; Data port inherited from stack
	CALL GET_CAPACITY_PORTED		; This seems to do a good job of snapping some drives to attention.  Otherwise they just fail to boot.
	POP AX							; We don't actually want the response.
	POP AX
	CMP SI, 0
	JE .NO_COMPLETE_MSG
	MOV BX, MSG_COMPLETE
	CALL WRITE_MESSAGE
.NO_COMPLETE_MSG:
	MOV AX, 0					; Successful Reset
.FINISHED_WITH_RESET:
	POP DI
	POP DX
	POP CX
	POP BX
	POPF
	POP BP
	RET

; This creates a more nuanced response set when SI=1 (the initial reset) -- it will return 99 if it's a "module failure"  and BB
; otherwise.  But when SI=0, normal reset, both paths end up returning BB.
.RESET_FAILED_MODULE:
	MOV AX, 0xBB			; BIOS code for disc error in general
	CMP SI, 0
	JE .DONT_CLEAR_SPINNER_MODULE		; If we're in the initial reset, we likely have a spinner bar sitting here, clear it.
	CALL .DISPLAY_X
	MOV AX, 0x99
.DONT_CLEAR_SPINNER_MODULE:
	JMP .FINISHED_WITH_RESET


.RESET_FAILED:
	CMP SI, 0
	JE .DONT_CLEAR_SPINNER		; If we're in the initial reset, we likely have a spinner bar sitting here, clear it.
	CALL .DISPLAY_X
.DONT_CLEAR_SPINNER:
	MOV AX, 0xBB			; BIOS code for disc error in general
	JMP .FINISHED_WITH_RESET

.DISPLAY_X:
	MOV AX, 0x0E08
	INT 0x10
	MOV AL, "X"					; Replace with an "X" to indicate we stopped here?
	INT 0x10
	RET

ADVANCE_SPINNER:
	PUSH AX
	MOV AX, 0x0E08
	INT 0x10;
	INC DI
	CMP DI, 4
	JB .SPINNER_ADVANCED
	XOR DI, DI
.SPINNER_ADVANCED:

	MOV AL, [DI + .SPINNER_CHARACTERS]
	INT 0x10
	POP AX
	RET

.SPINNER_CHARACTERS:
	db '-\|/'

; Uses a lot of space, so only enable when wanted for debugging.
;DUMP_REGS:
;	PUSH AX
;	MOV AH, 0x0e
;	MOV AL, 0x0d
;	INT 0x10
;	MOV AL, 0x0a
;	INT 0x10
;	MOV AL, 0x0d
;	INT 0x10
;	MOV AL, 0x0a
;	INT 0x10
;	
;	MOV AL, 'C'
;	INT 0x10
;	MOV AL, 'S'
;	INT 0x10
;	MOV AX, CS
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'D'
;	INT 0x10
;	MOV AL, 'S'
;	INT 0x10
;	MOV AX, DS
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'S'
;	INT 0x10
;	MOV AL, 'S'
;	INT 0x10
;	MOV AX, SS
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'E'
;	INT 0x10
;	MOV AL, 'S'
;	INT 0x10
;	MOV AX, ES
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'A'
;	INT 0x10
;	MOV AL, 'X'
;	INT 0x10
;	POP AX
;	PUSH AX
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'B'
;	INT 0x10
;	MOV AL, 'X'
;	INT 0x10
;	MOV AX, BX
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'C'
;	INT 0x10
;	MOV AL, 'X'
;	INT 0x10
;	MOV AX, CX
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;	
;	MOV AL, 'D'
;	INT 0x10
;	MOV AL, 'X'
;	INT 0x10
;	MOV AX, DX
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'S'
;	INT 0x10
;	MOV AL, 'P'
;	INT 0x10
;	MOV AX, SP
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'B'
;	INT 0x10
;	MOV AL, 'P'
;	INT 0x10
;	MOV AX, BP
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'S'
;	INT 0x10
;	MOV AL, 'I'
;	INT 0x10
;	MOV AX, SI
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, ' '
;	INT 0x10
;
;	MOV AL, 'D'
;	INT 0x10
;	MOV AL, 'I'
;	INT 0x10
;	MOV AX, DI
;	CALL WRITE_AX
;	MOV AH, 0x0e
;	MOV AL, 0x0d
;	INT 0x10
;	MOV AL, 0x0a
;	INT 0x10
;	MOV AL, 0x0d
;	INT 0x10
;	MOV AL, 0x0a
;	INT 0x10
;
;	POP AX
;	RET

DISPLAY_MODULE_INFO:
	; This is now at the end of the INIT line, so it doesn't need its own header.
	PUSH BP
	MOV BP, SP	; COMMAND PORT AT BP+6, DATA PORT AT BP+4
	
    MOV AL, CH376S_GET_IC_VER	;GET IC Version
	MOV DX, [SS:BP+6]
	OUT DX, AL					;OUT COMMAND PORT
	MOV DX, [SS:BP+4]
	IN AL, DX					;READ IN STATUS DATA PORT

	MOV AH, AL					;Copy for second use.
	AND AL, 0x80
	JZ .IS_ACTUALLY_CH376
    MOV BX, MSG_CH375_NAME
	JMP .IDENTIFICATION_DONE;
.IS_ACTUALLY_CH376:
    MOV BX, MSG_CH376_NAME
.IDENTIFICATION_DONE:
	CALL WRITE_MESSAGE
	
	MOV AL, AH				; Print actual revision number
	CALL WIRTE_AL_INT10_E
	


	POP BP
	RET

; Clobbers AX, BX, CX, DX
; Will return AX=0 if successful, AX=FF if weird status.
DISPLAY_DRIVE_INFO:
	PUSH BP
	MOV BP, SP	; COMMAND PORT AT BP+6, DATA PORT AT BP+4
	MOV CX, 0
.TRY_QUERY:						; Read the device name for the boot screen
	CMP CX, 10
	JAE .END_QUERY_FAIL ; GIVE UP
	MOV AL, CH375_DISK_INQUIRY	;Actually DISK_INQUIRY
	MOV DX, [SS:BP+6]
	OUT DX, AL		;OUT COMMAND PORT
	PUSH WORD [SS:BP+6]
	PUSH WORD [SS:BP+4]
	CALL AWAIT_INTERRUPT_PORTED
	POP DX
	POP DX
	CMP AX, 0xFFFF				; If we timed out waiting for the interrupt, retry the action.  We'll try 10 times.
	JNE .CONNECT_QUERY
	INC CX
	JMP .TRY_QUERY
.CONNECT_QUERY:
	MOV DX, [SS:BP+6]
	MOV AL, CH376S_GET_STATUS	; Try to get status for an interrupt.
	OUT DX, AL			;OUT COMMAND PORT				
	MOV DX, [SS:BP+4]
	IN AL, DX				;READ IN STATUS DATA PORT
	INC CX

	CMP AL, CH376S_USB_INT_SUCCESS  ;CHECK FOR USB_INT_SUCCESS
	JNE .TRY_QUERY

.MOUNT_FINISHED:

	; After the mount operation, the data port is stuffed with the device name.  
	; Let's show it so we have proof we're talking to the right drive
    MOV AL, CH376S_RD_USB_DATA0		; Read device data - the CH375 way?
	MOV DX, [SS:BP+6]
    OUT DX, AL
	MOV DX, [SS:BP+4]
    IN AL, DX				; READ IN STATUS DATA PORT
    MOV BL, AL						; The first byte is length of the name

	CMP AL, 0
	JE .END_QUERY_FAIL
	CMP AL, 0xE8 					; When it doesn't wake up right,
	JE .END_QUERY_FAIL				; it often returns E8 constantly

	
	; Print the "Device ID" string
	PUSH BX
	MOV BX, MSG_DEVINFO
    call WRITE_MESSAGE;			
	POP BX
	
	SUB BL, 8			; The first 8 characters of the response struct
	MOV CX, 8			; are not human readable.  Skip to vendor/product/Revision
.SKIP_HEADER:			
	IN AL, DX			; Still DATA_PORT
	LOOP .SKIP_HEADER

    MOV AH, 0x0E		; INT 0x10 operation for writing character
.NEXT_ID_CHAR:
    CMP BL, 0
    JE .AFTER_IDENT
    IN AL, DX	;Read and print BL-count characters from the DATA_PORT
	INT 0x10
	DEC BL
    JMP .NEXT_ID_CHAR
    .AFTER_IDENT:

	MOV AX, 0x0E20		; Write space
	INT 0x10
	MOV AL, 0x3A		; Write colon
	INT 0x10
	MOV AL, 0x20		; Write space
	INT 0x10

	PUSH WORD [SS:BP+6]
	PUSH WORD [SS:BP+4]
 	CALL GET_CAPACITY_PORTED
	POP BX
	POP BX
	CALL WRITE_SECTORS_IN_MB		; Display size on screen

	; Check if we're above the maximum size for the BIOS
	CMP DX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	JB .BELOW_SIZE
	CMP DX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	JA .ABOVE_SIZE
	CMP AX, (MAX_SPT * MAX_HPC * MAX_CYL) % 65536
	JBE .BELOW_SIZE

.ABOVE_SIZE:
    MOV BX, MSG_OVERSIZE
    CALL WRITE_MESSAGE;
	PUSH DX
	PUSH AX
	MOV DX, (MAX_SPT * MAX_HPC * MAX_CYL) / 65536
	MOV AX, (MAX_SPT * MAX_HPC * MAX_CYL) % 65536
	CALL WRITE_SECTORS_IN_MB
	POP AX
	POP DX
	JMP .END_QUERY_SUCCESS

.BELOW_SIZE:
	; If we have a device that's smaller than the dimensions in the disk table
	; we should warn the user to update the table.
	; or some detection software may assume the wrong dimensions.
	MOV CX, (MAX_SPT * MAX_HPC)
	DIV CX
	CMP AX, [CS:DISK_1_TABLE]
	JAE .END_QUERY_SUCCESS

	
    MOV BX, MSG_BELOW_TABLE_SIZE
	CALL WRITE_MESSAGE
	CALL WRITE_AX			; Will be sectors divided by heads and sectors per track (cylinders).
.END_QUERY_SUCCESS:
	MOV AX, 0X0
	POP BP
	RET
.END_QUERY_FAIL:
	MOV AX, 0xFF
	POP BP
	RET



COMMAND_PORTS:
	dw COMMAND_PORT, COMMAND_PORT_2
DATA_PORTS:
	dw DATA_PORT, DATA_PORT_2


; This is a cheat:  We put in the disc as the maximum specs we support, if anyone reads this vector
; it assumes a 504Mb drive.  Given that even dirt-cheap bulk drives are multiple gigabytes and we ignore most of it
; people using actual small drives may want to edit this to match the actual cylinder count.
; Since this is just a passive storage in memory, unlike int 0x13, function 8, we can't just calculate it on the fly
; unless we wanted to write it into RAM on boot.  We could locate it somewhere in the F0000 block but then we lose the
; "doesn't need to reserve any RAM for housekeeping" factor

	
DISK_1_TABLE:
	dw MAX_CYL  ; Cylinders
	dw MAX_HPC  ; Heads
	dw 0        ; Starts reduced write current cylinder
	dw 0		; Write precomp cylinder number
	db 0		; Max ECC Burst Length
	db 40h		; Control byte: Disable ECC retries, leave access retries, drive step speed 3ms
	db 0		; Standard Timeout
	db 0		; Formatting Timeout
	dw 0		; Landing Zone
	db MAX_SPT	; Sectors per track
	db 0		; reserved

%if COMMAND_PORT_2 != 0
DISK_2_TABLE:
	dw MAX_CYL  ; Cylinders
	dw MAX_HPC  ; Heads
	dw 0        ; Starts reduced write current cylinder
	dw 0		; Write precomp cylinder number
	db 0		; Max ECC Burst Length
	db 40h		; Control byte: Disable ECC retries, leave access retries, drive step speed 3ms
	db 0		; Standard Timeout
	db 0		; Formatting Timeout
	dw 0		; Landing Zone
	db MAX_SPT	; Sectors per track
	db 0		; reserved
%else
DISK_2_TABLE:
	dw 0        ; Cylinders
	dw 0        ; Heads
	dw 0        ; Starts reduced write current cylinder
	dw 0		; Write precomp cylinder number
	db 0		; Max ECC Burst Length
	db 0		; Control byte: Disable ECC retries, leave access retries, drive step speed 3ms
	db 0		; Standard Timeout
	db 0		; Formatting Timeout
	dw 0		; Landing Zone
	db 0     	; Sectors per track
	db 0		; reserved
%endif