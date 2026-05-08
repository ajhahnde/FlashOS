#include "asm_defs.inc"

.macro kernel_entry, el
    sub sp, sp,   #S_FRAME_SIZE
    stp x0, x1,   [sp, #16 * 0]
    stp x2, x3,   [sp, #16 * 1]
    stp x4, x5,   [sp, #16 * 2]
    stp x6, x7,   [sp, #16 * 3]
    stp x8, x9,   [sp, #16 * 4]
    stp x10, x11, [sp, #16 * 5]
    stp x12, x13, [sp, #16 * 6]
    stp x14, x15, [sp, #16 * 7]
    stp x16, x17, [sp, #16 * 8]
    stp x18, x19, [sp, #16 * 9]
    stp x20, x21, [sp, #16 * 10]
    stp x22, x23, [sp, #16 * 11]
    stp x24, x25, [sp, #16 * 12]
    stp x26, x27, [sp, #16 * 13]
    stp x28, x29, [sp, #16 * 14]

    /*
     * we have to save sp_el0 on the kernel stack because
     * we may context switch
     */
    .if  \el == 0
    mrs x21, sp_el0
    .else
    add x21, sp, #S_FRAME_SIZE
    .endif /* \el == 0 */

    mrs x22, elr_el1
    mrs x23, spsr_el1

    stp x30, x21, [sp, #16 * 15]
    stp x22, x23, [sp, #16 * 16]
.endm

.macro kernel_exit, el
    ldp x22, x23, [sp, #16 * 16]
    ldp x30, x21, [sp, #16 * 15]

    /*
     * we don't have to restore sp if el == 1 because
     * core_switch_to helps us with that
     */
    .if  \el == 0
    msr sp_el0, x21
    .endif /* \el == 0 */

    msr elr_el1, x22
    msr spsr_el1, x23

    ldp x0, x1,   [sp, #16 * 0]
    ldp x2, x3,   [sp, #16 * 1]
    ldp x4, x5,   [sp, #16 * 2]
    ldp x6, x7,   [sp, #16 * 3]
    ldp x8, x9,   [sp, #16 * 4]
    ldp x10, x11, [sp, #16 * 5]
    ldp x12, x13, [sp, #16 * 6]
    ldp x14, x15, [sp, #16 * 7]
    ldp x16, x17, [sp, #16 * 8]
    ldp x18, x19, [sp, #16 * 9]
    ldp x20, x21, [sp, #16 * 10]
    ldp x22, x23, [sp, #16 * 11]
    ldp x24, x25, [sp, #16 * 12]
    ldp x26, x27, [sp, #16 * 13]
    ldp x28, x29, [sp, #16 * 14]
    add sp, sp,   #S_FRAME_SIZE
    eret
.endm

.macro  ventry  label
.align  7
    b \label
.endm

.align 11
.globl vectors
vectors:
    ventry sync_invalid_el1t
    ventry irq_invalid_el1t
    ventry fiq_invalid_el1t
    ventry serror_invalid_el1t

    ventry sync_invalid_el1h
    ventry handle_irq_el1h
    ventry fiq_invalid_el1h
    ventry serror_invalid_el1h

    ventry handle_sync_el0_64
    ventry handle_irq_el0_64
    ventry fiq_invalid_el0_64
    ventry serror_invalid_el0_64

    ventry sync_invalid_el0_32
    ventry irq_invalid_el0_32
    ventry fiq_invalid_el0_32
    ventry serror_invalid_el0_32

.macro handle_invalid_entry el, type
    kernel_entry \el
    mov x0, #\type
    mrs x1, esr_el1
    mrs x2, elr_el1
    bl show_invalid_entry_raw
    b err_hang
.endm

sync_invalid_el1t:
    handle_invalid_entry 1, SYNC_INVALID_EL1t

irq_invalid_el1t:
    handle_invalid_entry 1, IRQ_INVALID_EL1t

fiq_invalid_el1t:
    handle_invalid_entry 1, FIQ_INVALID_EL1t

serror_invalid_el1t:
    handle_invalid_entry 1, SERROR_INVALID_EL1t

sync_invalid_el1h:
    handle_invalid_entry 1, SYNC_INVALID_EL1h

irq_invalid_el1h:
    handle_invalid_entry 1, IRQ_INVALID_EL1h

fiq_invalid_el1h:
    handle_invalid_entry 1, FIQ_INVALID_EL1h

serror_invalid_el1h:
    handle_invalid_entry 1, SERROR_INVALID_EL1h

sync_invalid_el0_64:
    handle_invalid_entry 0, SYNC_INVALID_EL0_64

irq_invalid_el0_64:
    handle_invalid_entry 0, IRQ_INVALID_EL0_64

fiq_invalid_el0_64:
    handle_invalid_entry 0, FIQ_INVALID_EL0_64

serror_invalid_el0_64:
    handle_invalid_entry 0, SERROR_INVALID_EL0_64

sync_invalid_el0_32:
    handle_invalid_entry 0, SYNC_INVALID_EL0_32

irq_invalid_el0_32:
    handle_invalid_entry 0, IRQ_INVALID_EL0_32

fiq_invalid_el0_32:
    handle_invalid_entry 0, FIQ_INVALID_EL0_32

serror_invalid_el0_32:
    handle_invalid_entry 0, SERROR_INVALID_EL0_32

handle_irq_el1h:
    kernel_entry 1
    bl handle_irq
    kernel_exit 1

handle_irq_el0_64:
    kernel_entry 0
    bl handle_irq
    kernel_exit 0

handle_sync_el0_64:
    kernel_entry 0
    /* check esr_el1 if it is svc or da */
    mrs x25, esr_el1
    lsr x24, x25, #ESR_ELx_EC_SHIFT
    cmp x24, #ESR_ELx_EC_SVC64
    b.eq el0_svc
    cmp x24, #ESR_ELx_EC_DA_LOW
    b.eq el0_da
    handle_invalid_entry 0, SYNC_ERROR

/*
 * x25 = NR_SYSCALLS
 * x26 = syscall number
 * x27 = sys_call_table
 */

el0_svc:
    adr x27, sys_call_table
    /* zero extend the syscall number */
    uxtw x26, w8
    mov x25, #NR_SYSCALLS
    bl irq_enable
    cmp x26, x25
    /* branch if syscall number >= NR_SYSCALLS */
    b.hs invalid_syscall_num
    /* call syscall */
    ldr x16, [x27, x26, lsl #3]
    blr x16
    b ret_from_syscall

invalid_syscall_num:
    handle_invalid_entry 0, SYSCALL_ERROR

ret_from_syscall:
    bl irq_disable
    /*
     * store the return value of the syscall on the stack so
     * kernel_exit will pop it back to x0
     */
    str x0, [sp, 0]
    kernel_exit 0

el0_da:
    bl irq_enable
    mrs x0, far_el1
    mrs x1, esr_el1
    bl do_data_abort
    cmp x0, 0
    b.eq 1f
    handle_invalid_entry 0, DATA_ABORT_ERROR
1:
    bl irq_disable
    kernel_exit 0

.globl ret_from_fork
ret_from_fork:
    bl preempt_enable
    /* x19 == 0 means we're cloning */
    cbz x19, ret_to_user
    mov x0, x20
    blr x19

ret_to_user:
    bl irq_disable
    kernel_exit 0

.globl err_hang
err_hang: b err_hang

/* show_invalid_entry_raw — pure-assembly fault diagnostic.
 *
 * Inputs (set up by `handle_invalid_entry`):
 *   x0 = typ (0..18, see asm_defs.inc SYNC_INVALID_EL1t..DATA_ABORT_ERROR)
 *   x1 = ESR_EL1
 *   x2 = ELR_EL1
 *
 * Writes one line — "E <typ:16h> <esr:16h> <elr:16h>\r\n" — to the
 * Mini-UART by direct MMIO and falls through to `err_hang`. No stack
 * use beyond what `kernel_entry` already pushed; no `bl`; no memory
 * loads other than the MMIO LSR poll. Goal: one fault produces one
 * complete readable line, eliminating the recursive ERROR-CAUGHT
 * loop that was hiding the real EL1h fault.
 *
 * MMIO addresses in the kernel's high-mem linear map are board-
 * specific:
 *   * Pi 4 (rpi4b) — BCM2711 mini-UART:
 *       AUX_MU_IO_REG  = 0xfe215040 + LINEAR_MAP_BASE  (data)
 *       AUX_MU_LSR_REG = 0xfe215054 + LINEAR_MAP_BASE  (status,
 *                        bit5 = TX empty → poll until set, `tbz`)
 *   * QEMU virt — PL011:
 *       DR  = 0x09000000 + LINEAR_MAP_BASE  (data)
 *       FR  = 0x09000018 + LINEAR_MAP_BASE  (flags,
 *             bit5 = TXFF → poll until clear, `tbnz`)
 * The address materialisation and TX-ready polling are abstracted
 * behind three macros (err_uart_load_io / err_uart_load_lsr /
 * err_uart_wait_tx_ready) defined per-board in board_asm_defs.inc.
 * Pi expansion is byte-identical to the previous hard-coded form.
 */
.globl show_invalid_entry_raw
show_invalid_entry_raw:
    /* Build MMIO addresses with movz/movk to avoid any literal-pool load. */
    err_uart_load_io  x9
    err_uart_load_lsr x10

    /* "E " marker. */
    mov w15, #'E'
    err_uart_wait_tx_ready w11, x10, 1
    str w15, [x9]
    mov w15, #' '
    err_uart_wait_tx_ready w11, x10, 2
    str w15, [x9]

    /* typ as 16 hex nibbles, MSB first. */
    mov x3, x0
    mov x12, #60
3:  lsr x14, x3, x12
    and x14, x14, #0xf
    cmp x14, #9
    add x14, x14, #'0'
    b.ls 4f
    add x14, x14, #('a' - '0' - 10)
    err_uart_wait_tx_ready w11, x10, 4
    str w14, [x9]
    subs x12, x12, #4
    b.pl 3b

    mov w15, #' '
    err_uart_wait_tx_ready w11, x10, 5
    str w15, [x9]

    /* esr as 16 hex nibbles. */
    mov x3, x1
    mov x12, #60
6:  lsr x14, x3, x12
    and x14, x14, #0xf
    cmp x14, #9
    add x14, x14, #'0'
    b.ls 7f
    add x14, x14, #('a' - '0' - 10)
    err_uart_wait_tx_ready w11, x10, 7
    str w14, [x9]
    subs x12, x12, #4
    b.pl 6b

    mov w15, #' '
    err_uart_wait_tx_ready w11, x10, 8
    str w15, [x9]

    /* elr as 16 hex nibbles. */
    mov x3, x2
    mov x12, #60
9:  lsr x14, x3, x12
    and x14, x14, #0xf
    cmp x14, #9
    add x14, x14, #'0'
    b.ls 10f
    add x14, x14, #('a' - '0' - 10)
    err_uart_wait_tx_ready w11, x10, 10
    str w14, [x9]
    subs x12, x12, #4
    b.pl 9b

    /* CR LF, then halt. */
    mov w15, #'\r'
    err_uart_wait_tx_ready w11, x10, 11
    str w15, [x9]
    mov w15, #'\n'
    err_uart_wait_tx_ready w11, x10, 12
    str w15, [x9]

    b err_hang