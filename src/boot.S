#include "asm_defs.inc"

/* changes tmp1, tmp2 only */
.macro create_table_entry, tbl, ntbl, va, shift, flags, tmp1, tmp2
    /* get entry index in tmp1 */
    lsr \tmp1, \va, #\shift
    and \tmp1, \tmp1, #ENTRIES_PER_TABLE - 1
    /* tmp2 = entry value */
    mov \tmp2, \ntbl
    orr \tmp2, \tmp2, #\flags
    /* install entry */
    str \tmp2, [\tbl, \tmp1, lsl #3]
.endm

/* changes vstart, vend, pa, tmp1 */
/* vstart and vend must differ by at least one block. */
/* `flags_label` is a PC-relative label in .text.boot.literals — the
 * literal table is kept out of .text.boot.late so that section stays
 * 4-byte aligned and the linker does not pad before it. */
.macro create_block_map, pmd, vstart, vend, pa, flags_label, tmp1
    /* turn vstart, vend into indices */
    lsr \vstart, \vstart, #SECTION_SHIFT
    and \vstart, \vstart, #ENTRIES_PER_TABLE - 1
    lsr \vend, \vend, #SECTION_SHIFT
    /* minus one to handle the last entry */
    sub \vend, \vend, #1
    and \vend, \vend, #ENTRIES_PER_TABLE - 1
    /* loop init, pa = pa | flags */
    lsr \pa, \pa, #SECTION_SHIFT
    lsl \pa, \pa, #SECTION_SHIFT
    ldr \tmp1, \flags_label
    orr \pa, \pa, \tmp1
    /* loop */
    /* pmd[vstart] = pa */
2:
    str \pa, [\pmd, \vstart, lsl #3]
    /* pa += section size */
    add \pa, \pa, #SECTION_SIZE
    /* vstart += 1 */
    add \vstart, \vstart, #1
    cmp \vstart, \vend
    b.le 2b
.endm

.section ".text.boot"

.globl _start
.globl _start_real
_start:
_start_real:
    /* only core 0 starts here */
    /* On virt the Linux arm64 image header (board/virt/image_header.S)
     * lives in .text.boot.header at the image base and branches here
     * via `_start_real`; on Pi the firmware enters at offset 0, which
     * is `_start` itself. Both labels alias the same instruction so
     * Pi kernel8.img stays byte-identical. */
    b master
    /* unreachable */
    b proc_hang

master: /* entry point of the primary core */
    /* Save the DTB physical address that UEFI / QEMU `-kernel` hand
     * off in x0 (Linux arm64 boot protocol) — must happen before any
     * `bl` that might clobber x0. The macro is board-specific:
     * virt stores into the `.bss` global `dtb_pa`; Pi expands to
     * nothing because no firmware on Pi 4 hands off a DTB pointer. */
    save_dtb_pa x0
    bl drop_to_el1
    /* Board-specific FP/SIMD enable at EL1 — virt sets
     * CPACR_EL1.FPEN, Pi inlines to nothing (armstub already did
     * it at EL3 and Pi's Zig binary contains no NEON). Must run
     * before any Zig code, so before the jump into kernel_main. */
    enable_fp_simd_el1
    /* Board-specific stack init — Pi expands to `mov sp, #LOW_MEMORY`
     * (single 4-byte instruction, baseline-identical); virt expands
     * to `ldr x9, =LOW_MEMORY; mov sp, x9` because its LOW_MEMORY
     * does not fit the immediate field. */
    mov_sp_low_memory x9
    /* adr is load address */
    adr x0, bss_begin
    adr x1, bss_end
    sub x1, x1, x0
    /* clear out the bss section */
    bl memzero
    bl map_identity
    bl map_high
    bl wake_up_cores
    /* save kernel pa base */
    adr x0, _start
    adr x1, KERNEL_PA_BASE
    str x0, [x1]
    /* set ttbr's */
    adrp x0, id_pg_dir
    msr ttbr0_el1, x0
    adrp x0, high_pg_dir
    msr ttbr1_el1, x0
    /* QEMU's -kernel shim does NOT init these EL1 sysregs;
     * armstub does on real Pi 4. Re-writing the same values is harmless
     * on HW and required for QEMU to translate the first fetch after
     * MMU enable. */
    /* Most literals (MAIR/LINEAR_MAP_BASE/HCR/SPSR) get GAS-optimised to
     * inline `movz` so they emit no pool entry. The two values that do
     * end up in the pool — TCR_EL1_VAL and SCTLR_EL1_VAL_MMU_ENABLED —
     * are routed through explicit labels in `.text.boot.literals`, which
     * keeps boot.S `.text.boot` literal-pool-free and stops GAS from
     * dumping a pool between el1_entry and the board's boot_quirks. */
    ldr x0, =MAIR_EL1_VAL
    msr mair_el1, x0
    ldr x0, .Ltcr_el1_val
    msr tcr_el1, x0
    adr x0, vectors
    msr vbar_el1, x0
    isb
    /* turn on the mmu */
    ldr x0, .Lsctlr_mmu_enabled
    msr sctlr_el1, x0
    isb
    /* prepare jumping to high mem */
    ldr x2, =LINEAR_MAP_BASE
    add sp, sp, x2
    adr x1, kernel_main
    add x1, x1, x2
    /* core 0 */
    mov x0, #0
    /* jump to high mem */
    blr x1
    /* unreachable */
    b proc_hang

.globl app
app: /* entry point of the secondary cores */
    bl drop_to_el1
    /* setup stack */
    mrs x0, mpidr_el1
    and x0, x0, #0xFF
    mov x1, #SECTION_SIZE
    mul x1, x1, x0
    /* Board-specific add of LOW_MEMORY (see master:'s comment). */
    add_low_memory x1, x1, x9
    mov sp, x1
    bl kernel_main

drop_to_el1:
    /* Three valid entry paths reach this routine:
     *   * armstub8.bin runs first (real Pi 4 hardware): EL3 with
     *     SPSR_EL3 pre-loaded for the EL1h drop.
     *   * QEMU `-M raspi4b -kernel` shim hands off at EL2 with no
     *     SPSR setup.
     *   * QEMU `-M virt -kernel` (and UEFI/GRUB chain) hands off
     *     directly at EL1.
     * CurrentEL discriminates: the EL1 case is matched by the
     * board macro, EL2 by the b.eq below, EL3 falls through. */
    mrs x0, CurrentEL
    check_el1_already x0
    cmp x0, #(2 << 2)
    b.eq drop_from_el2

    /* EL3 path: armstub already wrote SPSR_EL3 / HCR_EL2 / SCR_EL3
     * etc. Eret to el1_entry. */
    adr x0, el1_entry
    msr ELR_EL3, x0
    eret

drop_from_el2:
    /* EL2 path: replicate the bits of armstub's setup that matter for
     * dropping to EL1. Both values fit in a single movz, so GAS keeps
     * them inline — no pool entry, no boundary shift. */
    ldr x0, =HCR_EL2_VAL
    msr HCR_EL2, x0
    ldr x0, =SPSR_EL3_VAL
    msr SPSR_EL2, x0
    adr x0, el1_entry
    msr ELR_EL2, x0
    eret

el1_entry:
    ret

/* Board-specific wake_up_cores lives in
 * src/board/<board>/boot_quirks.S; the linker concatenates its
 * ".text.boot" between this file's ".text.boot" and
 * ".text.boot.late" below, preserving the original layout. */

.section ".text.boot.late"

map_identity:
    /* save return address */
    mov x29, x30
    adrp x0, id_pg_dir
    mov x1, #ID_MAP_TABLE_SIZE
    /* clear id page tables */
    bl memzero
    adrp x0, id_pg_dir
    /* x1 = address of id map pud */
    add x1, x0, #PAGE_SIZE

    /* Board-specific PUD/PMD setup. `.macro map_identity_regions` is
     * defined in src/board/<board>/board_asm_defs.inc — Pi maps PA
     * 0..0x1000000 via PUD index 0; virt maps PA
     * 0x40000000..0x41000000 via PUD index 1 so the kernel image at
     * PA 0x40080000 stays addressable across the MMU-enable point.
     * The macro expands inline; rpi4b output is byte-identical. */
    map_identity_regions

    /* restore return address */
    mov x30, x29
    ret

map_high:
    /* save return address */
    mov x29, x30
    adrp x0, high_pg_dir
    mov x1, #HIGH_MAP_TABLE_SIZE
    /* clear high page tables */
    bl memzero
    adrp x0, high_pg_dir
    /* x1 = address of high map pud */
    add x1, x0, #PAGE_SIZE
    /* x4 = address of the mapped va (pgd) */
    ldr x4, =LINEAR_MAP_BASE
    /* install PGD entry */
    create_table_entry x0, x1, x4, PGD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    /* goto next level */
    add x0, x0, #PAGE_SIZE
    add x1, x1, #PAGE_SIZE

    /* Board-specific PUD/PMD setup + create_block_map calls.
     * `.macro map_high_regions` is defined in
     * src/board/<board>/board_asm_defs.inc — Pi 4 fans out to four
     * 1 GiB PUD slots with a 64 MiB device window in the last PMD;
     * other boards adapt freely.  The macro expands inline, so the
     * emitted bytes for rpi4b stay byte-identical to the previous
     * unrolled form. */
    map_high_regions

    /* restore return address */
    mov x30, x29
    ret

proc_hang:
    /* wait for event */
    wfe
    b proc_hang

/* Explicit literal table — kept out of .text.boot.late so that section
 * stays 4-byte aligned (no 8-byte data inside ⇒ no padding before it
 * when ld concatenates it after .text.boot). Order matches the GAS
 * literal-pool encounter order pre-split, so the table is layout-
 * identical to the single-section baseline. Only values that GAS
 * could not movz-fold into a single inline instruction live here:
 * 32+-bit non-single-chunk values (TCR, SCTLR, HIGH_MAP_*_END,
 * HIGH_MAP_SECOND_START, TD_*_BLOCK_FLAGS, HIGH_MAP_DEVICE_END).
 * linker.ld places .text.boot.literals right after .text.boot.late
 * inside the output .text.boot section. */
.section ".text.boot.literals"

.Ltcr_el1_val:
    .quad TCR_EL1_VAL
.Lsctlr_mmu_enabled:
    .quad SCTLR_EL1_VAL_MMU_ENABLED
.Ltd_kernel_block_flags:
    .quad TD_KERNEL_BLOCK_FLAGS
.Lhigh_map_first_end:
    .quad HIGH_MAP_FIRST_END
.Lhigh_map_second_start:
    .quad HIGH_MAP_SECOND_START
.Lhigh_map_second_end:
    /* same value as HIGH_MAP_THIRD_START; one entry, two consumers */
    .quad HIGH_MAP_SECOND_END
.Lhigh_map_third_end:
    /* same value as HIGH_MAP_FOURTH_START */
    .quad HIGH_MAP_THIRD_END
.Lhigh_map_fourth_end:
    /* same value as HIGH_MAP_DEVICE_START */
    .quad HIGH_MAP_FOURTH_END
.Lhigh_map_device_end:
    .quad HIGH_MAP_DEVICE_END
.Ltd_device_block_flags:
    .quad TD_DEVICE_BLOCK_FLAGS

