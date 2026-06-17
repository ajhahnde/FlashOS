.globl get_sys_count
get_sys_count:
    mrs x0, CNTPCT_EL0
    ret

// Counter-timer frequency in Hz. The architectural source of truth for
// turning a CNTPCT delta into wall time — read at runtime rather than
// assuming the SYS_FREQ tick period, since the two need not agree (QEMU
// virt's counter frequency differs from the Pi's 54 MHz).
.globl get_sys_freq
get_sys_freq:
    mrs x0, CNTFRQ_EL0
    ret

.globl set_CNTP_TVAL
set_CNTP_TVAL:
    msr CNTP_TVAL_EL0, x0
    ret

.globl set_CNTP_CVAL
set_CNTP_CVAL:
    msr CNTP_CVAL_EL0, x0
    ret

.globl setup_CNTP_CTL
setup_CNTP_CTL:
    mov x9, 1
    msr CNTP_CTL_EL0, x9
    ret
