/*
 * QEMU virt has no Pi-style spin-table. Secondary cores are brought
 * up via PSCI `CPU_ON` SMC calls, so for the single-core baseline
 * `wake_up_cores` is a no-op.
 *
 * Section is ".text.boot" — keeps the function in the same output
 * section the rpi4b boot_quirks contributes to, so boot.S's
 * `bl wake_up_cores` resolves whichever board's symbol is linked.
 */

.section ".text.boot"

.globl wake_up_cores
wake_up_cores:
    ret

/* DTB physical address handed off in x0 at kernel entry. Written by
 * the `save_dtb_pa` macro from boot.S `master`; reserved for the
 * frozen virt DTB handoff. Lives in .bss so it doesn't inflate
 * kernel8.img. */
.section ".bss"
.balign 8
.globl dtb_pa
dtb_pa:
    .quad 0
