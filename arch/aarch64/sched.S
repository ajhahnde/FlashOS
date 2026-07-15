#include "asm_defs.inc"

.globl core_switch_to
core_switch_to:
    mov x10, #CORE_CONTEXT_OFFSET
    add x8, x0, x10
    mov x9, sp
    /* save context into prev->core_context */
    stp x19, x20, [x8], #16
    stp x21, x22, [x8], #16
    stp x23, x24, [x8], #16
    stp x25, x26, [x8], #16
    stp x27, x28, [x8], #16
    stp x29, x9,  [x8], #16
    str x30, [x8]
    /* restore context from next->core_context */
    add x8, x1, x10
    ldp x19, x20, [x8], #16
    ldp x21, x22, [x8], #16
    ldp x23, x24, [x8], #16
    ldp x25, x26, [x8], #16
    ldp x27, x28, [x8], #16
    ldp x29, x9,  [x8], #16
    ldr x30, [x8]
    mov sp, x9
    ret

.globl set_pgd
set_pgd:
    msr ttbr0_el1, x0
    /* Synchronise the TTBR0 switch before the TLB flush. Without this
     * ISB the write to TTBR0_EL1 is not yet in effect, so a speculative
     * table walk of the low user VA range can still use the *old* base —
     * the boot id_pg_dir, which maps VA 0..16 MiB as UXN kernel 2 MiB
     * blocks that shadow the entire low user address space — and re-cache
     * a stale block into the TLB *after* the TLBI below clears it. The
     * eret to EL0 then fetches VA 0 through that kernel block and takes an
     * EL0 instruction permission fault (ESR IFSC 0x0e, level 2). The
     * failure is layout-sensitive: whether the speculative walk lands in
     * the unsynchronised window depends on surrounding code timing, so it
     * surfaced only after an unrelated image-size shift. */
    isb
    /* tlb invalidate, vm all el1 inner sharable */
    tlbi vmalle1is
    /* data sync inner sharable */
    dsb ish
    /* instruction sync barrier, flushes pipeline */
    isb
    ret
