/*
 * Pi-4 SMP wake-up via the BCM2711 spin-table at PA 0xe0/0xe8/0xf0.
 * Each secondary core spins on its slot until a non-zero value is
 * written, then jumps to that address. All three slots are pointed
 * at `app` (defined in src/boot.S). On QEMU `-M raspi4b` the same
 * convention is honoured by the machine model.
 *
 * Section is ".text.boot" — the linker stitches this object's
 * contribution between boot.S's ".text.boot" (early prologue,
 * up to el1_entry) and ".text.boot.late" (map_identity onwards),
 * so wake_up_cores keeps its original load offset.
 */

.section ".text.boot"

.globl wake_up_cores
wake_up_cores:
    sev
    mov x0, #0
    adr x0, app
    mov x1, #0xE0
    str x0, [x1]
    mov x1, #0xE8
    str x0, [x1]
    mov x1, #0xF0
    str x0, [x1]
    ret
