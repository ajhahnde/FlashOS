/*
 * Board-specific memory layout for RPi4 (BCM2711).
 * Picked up via the per-board include path set in build.zig.
 */

#ifndef BOARD_ASM_DEFS_INC
#define BOARD_ASM_DEFS_INC

#define LOW_MEMORY          (2 * SECTION_SIZE)

#define HIGH_MAP_PAGES      6
#define HIGH_MAP_TABLE_SIZE (HIGH_MAP_PAGES * PAGE_SIZE)
#define ID_MAP_TABLE_SIZE   (ID_MAP_PAGES * PAGE_SIZE)
#define ID_MAP_SIZE         (8 * SECTION_SIZE)
#define PUD_ENTRY_MAP_SIZE  (1 << PUD_SHIFT)

#define HIGH_MAP_FIRST_START   (0x0 + LINEAR_MAP_BASE)
#define HIGH_MAP_FIRST_END     (0x3B400000 + LINEAR_MAP_BASE)
#define HIGH_MAP_SECOND_START  (0x40000000 + LINEAR_MAP_BASE)
#define HIGH_MAP_SECOND_END    (0x80000000 + LINEAR_MAP_BASE)
#define HIGH_MAP_THIRD_START   (0x80000000 + LINEAR_MAP_BASE)
#define HIGH_MAP_THIRD_END     (0xC0000000 + LINEAR_MAP_BASE)
#define HIGH_MAP_FOURTH_START  (0xC0000000 + LINEAR_MAP_BASE)
#define HIGH_MAP_FOURTH_END    (0xFC000000 + LINEAR_MAP_BASE)
#define HIGH_MAP_DEVICE_START  (0xFC000000 + LINEAR_MAP_BASE)
#define HIGH_MAP_DEVICE_END    (0x100000000 + LINEAR_MAP_BASE)

#define FIRST_START   (0x0)
#define FIRST_END     (0x3B400000)
#define SECOND_START  (0x40000000)
#define SECOND_END    (0x80000000)
#define THIRD_START   (0x80000000)
#define THIRD_END     (0xC0000000)
#define FOURTH_START  (0xC0000000)
#define FOURTH_END    (0xFC000000)
#define DEVICE_START  (0xFC000000)
#define DEVICE_END    (0x100000000)

/* BCM2711 oscillator: armstub uses 54 MHz for Pi 4. QEMU does not
 * preset CNTFRQ_EL0, so the generic timer would otherwise read 0. */
#define BOOT_OSC_FREQ       54000000

/* Pi 4 enters at EL3 (armstub) or EL2 (raspi4b QEMU) — never at
 * EL1 — so drop_to_el1 has no EL1 fast path. Empty macro keeps
 * boot.S byte-identical to baseline. */
.macro check_el1_already el_reg
.endm

/* Pi-specific identity-map population: 1 PGD + 1 PUD + 1 PMD,
 * mapping VA 0..ID_MAP_SIZE → PA 0..ID_MAP_SIZE (16 MiB at index 0).
 * Body matches the previous inline form in boot.S map_identity, so
 * the macro expansion produces byte-identical output. Entry contract
 * matches boot.S map_identity: x0 = PGD page, x1 = PUD page. */
.macro map_identity_regions
    eor x4, x4, x4
    create_table_entry x0, x1, x4, PGD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    add x0, x0, #PAGE_SIZE
    add x1, x1, #PAGE_SIZE
    create_table_entry x0, x1, x4, PUD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    mov x0, x1
    eor x2, x2, x2
    ldr x3, =ID_MAP_SIZE
    eor x4, x4, x4
    create_block_map x0, x2, x3, x4, .Ltd_kernel_block_flags, x5
.endm

/* Board-specific stack-base setup. Pi 4's LOW_MEMORY (0x400000)
 * fits the AArch64 `mov sp, #imm12, lsl shift` and
 * `add Xd, Xn, #imm12, lsl shift` immediate forms, so each macro
 * expands to a single instruction — byte-identical to the
 * pre-macro inline form. virt's larger LOW_MEMORY (0x40800000)
 * needs an explicit `ldr` first, hence the second template lives
 * in src/board/virt/board_asm_defs.inc. */
.macro mov_sp_low_memory tmp
    mov sp, #LOW_MEMORY
.endm

.macro add_low_memory dst, src, tmp
    add \dst, \src, #LOW_MEMORY
.endm

/* Board-specific high-memory mapping. Called from boot.S map_high
 * after the PGD entry for the linear-map base has been installed.
 *
 * Expects on entry:
 *   x0 = address of the PUD page in high_pg_dir
 *   x1 = address of the first PMD page in high_pg_dir
 *
 * Pi 4 layout: four 1 GiB PUD slots covering 0..0x100000000, with
 * the last PMD shared between the upper RAM block and the BCM2711
 * device window at 0xFC000000..0x100000000. Five create_block_map
 * invocations (4 RAM + 1 device) populate the four PMDs.
 *
 * Literal labels (.Lhigh_map_*_end, .Ltd_kernel_block_flags,
 * .Ltd_device_block_flags) live in boot.S .text.boot.literals and
 * are resolved by the linker; they exist for both the inline use
 * inside boot.S and inside this macro expansion. */
.macro map_high_regions
    /* x4 = address of va we map (pud) */
    ldr x4, =LINEAR_MAP_BASE
    ldr x5, =PUD_ENTRY_MAP_SIZE
    /* install first PUD entry */
    create_table_entry x0, x1, x4, PUD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    add x1, x1, #PAGE_SIZE
    add x4, x4, x5
    create_table_entry x0, x1, x4, PUD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    add x1, x1, #PAGE_SIZE
    add x4, x4, x5
    create_table_entry x0, x1, x4, PUD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    add x1, x1, #PAGE_SIZE
    add x4, x4, x5
    create_table_entry x0, x1, x4, PUD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    /* load some values */
    /* `=LIT` for values GAS movzs inline; explicit labels for the ones
     * that go in the pool. Where two source-level constants share a
     * value (HIGH_MAP_SECOND_END == HIGH_MAP_THIRD_START etc.), both
     * use the first label so GAS-style dedup is preserved. */
    ldr x10, =HIGH_MAP_FIRST_START
    ldr x11, .Lhigh_map_first_end
    ldr x12, .Lhigh_map_second_start
    ldr x13, .Lhigh_map_second_end
    ldr x14, .Lhigh_map_second_end
    ldr x15, .Lhigh_map_third_end
    ldr x16, .Lhigh_map_third_end
    ldr x17, .Lhigh_map_fourth_end
    ldr x18, .Lhigh_map_fourth_end
    ldr x19, .Lhigh_map_device_end
    ldr x20, =FIRST_START
    ldr x21, =SECOND_START
    ldr x22, =THIRD_START
    ldr x23, =FOURTH_START
    ldr x24, =DEVICE_START
    /* map first high part */
    add x0, x0, #PAGE_SIZE
    mov x2, x10
    mov x3, x11
    mov x4, x20
    create_block_map x0, x2, x3, x4, .Ltd_kernel_block_flags, x5
    /* map second high part */
    add x0, x0, #PAGE_SIZE
    mov x2, x12
    mov x3, x13
    mov x4, x21
    create_block_map x0, x2, x3, x4, .Ltd_kernel_block_flags, x5
    /* map third high part */
    add x0, x0, #PAGE_SIZE
    mov x2, x14
    mov x3, x15
    mov x4, x22
    create_block_map x0, x2, x3, x4, .Ltd_kernel_block_flags, x5
    /* map fourth high part */
    add x0, x0, #PAGE_SIZE
    mov x2, x16
    mov x3, x17
    mov x4, x23
    create_block_map x0, x2, x3, x4, .Ltd_kernel_block_flags, x5
    /* map device */
    mov x2, x18
    mov x3, x19
    mov x4, x24
    create_block_map x0, x2, x3, x4, .Ltd_device_block_flags, x5
.endm

/* Crash-stamp UART macros for entry.S `show_invalid_entry_raw`.
 * Pi expands them to the exact movz/movk/ldr/tbz sequences that the
 * pre-port routine had hard-coded against the BCM2711 mini-UART
 * (AUX_MU_IO_REG=0xfe215040, AUX_MU_LSR_REG=0xfe215054, LSR bit 5 =
 * TX-empty → poll until set with `tbz`). Byte-identity preserved. */
.macro err_uart_load_io reg
    movz \reg,  #0x5040
    movk \reg,  #0xfe21, lsl #16
    movk \reg,  #0xffff, lsl #48
.endm

.macro err_uart_load_lsr reg
    movz \reg, #0x5054
    movk \reg, #0xfe21, lsl #16
    movk \reg, #0xffff, lsl #48
.endm

.macro err_uart_wait_tx_ready scratch, lsr_reg, lbl
\lbl\(): ldr \scratch, [\lsr_reg]
    tbz \scratch, #5, \lbl\()b
.endm

/* Pi 4 firmware (GPU bootloader / armstub8) does not pass a DTB
 * pointer in x0 — the platform is fully described by the BCM2711
 * board files baked into the kernel. Empty macro keeps boot.S
 * byte-identical to baseline. */
.macro save_dtb_pa src
.endm

/* On real HW armstub8.S already writes CPACR_EL1 (FPEN + ZEN) before
 * dropping to EL1, but QEMU `-M raspi4b -kernel` skips armstub and
 * lands directly in the kernel — leaving CPACR with FPEN trapping.
 * The ELF magic check (ehdr.e_ident[0..4]) lets the Zig
 * compiler load 4 bytes via `ldr s0, [x0]`, which then traps with
 * EC=0x07 on QEMU. Re-writing CPACR is idempotent on the HW path
 * (armstub already set the same bits at EL3) and necessary on the
 * QEMU path. */
.macro enable_fp_simd_el1
    mrs x0, CPACR_EL1
    orr x0, x0, #(3 << 20)
    msr CPACR_EL1, x0
    isb
.endm

#endif /* BOARD_ASM_DEFS_INC */
