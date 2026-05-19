/*
 * Board-specific memory layout for QEMU's `-M virt` machine
 * (AArch64). Picked up via the per-board include path set in
 * build.zig.
 *
 * QEMU virt physical map (the slice we care about):
 *   0x00000000–0x40000000  device window — PL011, GIC, RTC,
 *                          virtio-mmio, fw_cfg, etc.
 *   0x40000000–0x80000000  RAM (UEFI loads the kernel at
 *                          0x40080000, the Linux arm64 entry
 *                          point on this machine).
 */

#ifndef BOARD_ASM_DEFS_INC
#define BOARD_ASM_DEFS_INC

/* Skip the first 4 sections (8 MiB at 2 MiB section size) of RAM
 * so the kernel image and its early data are not stomped by the
 * stack reserved for core 0. */
#define LOW_MEMORY          (0x40000000 + 4 * SECTION_SIZE)

/* High-map page count: 1 PGD + 1 PUD + 2 PMDs (one per 1 GiB
 * virtual chunk — Device + RAM). */
#define HIGH_MAP_PAGES      4
#define HIGH_MAP_TABLE_SIZE (HIGH_MAP_PAGES * PAGE_SIZE)
#define ID_MAP_TABLE_SIZE   (ID_MAP_PAGES * PAGE_SIZE)
#define ID_MAP_SIZE         (8 * SECTION_SIZE)
#define PUD_ENTRY_MAP_SIZE  (1 << PUD_SHIFT)

/* Real virt windows. */
#define HIGH_MAP_DEVICE_START  (0x0 + LINEAR_MAP_BASE)
#define HIGH_MAP_DEVICE_END    (0x40000000 + LINEAR_MAP_BASE)
#define HIGH_MAP_RAM_START     (0x40000000 + LINEAR_MAP_BASE)
#define HIGH_MAP_RAM_END       (0x80000000 + LINEAR_MAP_BASE)
#define DEVICE_START           0x0
#define DEVICE_END             0x40000000
#define RAM_START              0x40000000
#define RAM_END                0x80000000

/* boot.S `.text.boot.literals` declares
 *   .Lhigh_map_first_end ... .Lhigh_map_fourth_end
 *   FIRST_START ... FOURTH_START
 * via `.quad <constant>` regardless of board (those literals serve
 * the rpi4b 4-window scheme inside its `map_high_regions` macro).
 * virt's macro does not consume them, but the assembler still needs
 * each constant defined — alias them onto the real virt windows. */
#define HIGH_MAP_FIRST_START   HIGH_MAP_DEVICE_START
#define HIGH_MAP_FIRST_END     HIGH_MAP_DEVICE_END
#define HIGH_MAP_SECOND_START  HIGH_MAP_RAM_START
#define HIGH_MAP_SECOND_END    HIGH_MAP_RAM_END
#define HIGH_MAP_THIRD_START   HIGH_MAP_RAM_END
#define HIGH_MAP_THIRD_END     HIGH_MAP_RAM_END
#define HIGH_MAP_FOURTH_START  HIGH_MAP_RAM_END
#define HIGH_MAP_FOURTH_END    HIGH_MAP_RAM_END

#define FIRST_START   DEVICE_START
#define FIRST_END     DEVICE_END
#define SECOND_START  RAM_START
#define SECOND_END    RAM_END
#define THIRD_START   RAM_END
#define THIRD_END     RAM_END
#define FOURTH_START  RAM_END
#define FOURTH_END    RAM_END

/* QEMU sets CNTFRQ_EL0 itself before kernel entry, so virt does
 * not need a board-supplied oscillator constant. BOOT_OSC_FREQ is
 * defined to 0 so any common code that references it (today nothing
 * does, but the symbol is part of the rpi4b API surface) still
 * assembles. */
#define BOOT_OSC_FREQ          0

/* QEMU `-M virt -kernel` enters the kernel directly at EL1, so
 * drop_to_el1 must short-circuit to el1_entry instead of falling
 * through to the EL3 path that would `msr ELR_EL3` (UNDEFINED at
 * EL1). LR was set by master's `bl drop_to_el1`, so the el1_entry
 * `ret` returns to master normally. */
.macro check_el1_already el_reg
    cmp \el_reg, #(1 << 2)
    b.eq el1_entry
.endm

/* virt's identity map covers PA 0x40000000..0x41000000 (16 MiB at
 * the start of RAM), reachable through PUD entry 1 (VA bits 38..30
 * = 1). UEFI/QEMU loads the kernel at PA 0x40080000, so this region
 * includes both the kernel image and the early stack/BSS — required
 * because the next instruction after `msr sctlr_el1` (MMU enable)
 * still fetches at PA via TTBR0 until the jump to the linear-map VA.
 * `ldr x?, =0x4xxxxxxx` literals all fit in single movz (lsl 16),
 * so no GAS pool entries are emitted. */
.macro map_identity_regions
    /* PGD entry 0 → PUD (covers VA 0..512 GiB) */
    eor x4, x4, x4
    create_table_entry x0, x1, x4, PGD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    add x0, x0, #PAGE_SIZE
    add x1, x1, #PAGE_SIZE
    /* PUD entry 1 → PMD (VA 0x40000000..0x80000000) */
    ldr x4, =0x40000000
    create_table_entry x0, x1, x4, PUD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    mov x0, x1
    /* Map VA 0x40000000..0x41000000 → PA 0x40000000..0x41000000 */
    ldr x2, =0x40000000
    ldr x3, =0x41000000
    ldr x4, =0x40000000
    create_block_map x0, x2, x3, x4, .Ltd_kernel_block_flags, x5
.endm

/* virt's LOW_MEMORY (0x40800000) does not fit AArch64's
 * `mov sp, #imm` or `add Xd, Xn, #imm` immediate fields (those
 * accept 12-bit immediates with an optional 12-bit shift, max
 * 0xFFFFFF). Materialise the value through a scratch register;
 * GAS optimises `ldr =LOW_MEMORY` to a single `movz` because
 * 0x40800000 fits in a 16-bit-shifted-by-16 movz immediate. */
.macro mov_sp_low_memory tmp
    ldr \tmp, =LOW_MEMORY
    mov sp, \tmp
.endm

.macro add_low_memory dst, src, tmp
    ldr \tmp, =LOW_MEMORY
    add \dst, \src, \tmp
.endm

/* Board-specific high-memory mapping, called from boot.S map_high
 * after the PGD entry has been installed.  See the rpi4b version
 * for the entry-register contract.  virt has only two PUD slots:
 *   PUD 0 -> PMD covering Device  (0x00000000..0x40000000)
 *   PUD 1 -> PMD covering RAM     (0x40000000..0x80000000)
 *
 * The macro emits no GAS literal pool — every operand fits in a
 * single movz/movk pair so GAS keeps them inline.  TD flag labels
 * (.Ltd_kernel_block_flags / .Ltd_device_block_flags) are already
 * defined by boot.S `.text.boot.literals` and resolved by the linker. */
.macro map_high_regions
    /* x4 = address of va we map (pud) */
    ldr x4, =LINEAR_MAP_BASE
    ldr x5, =PUD_ENTRY_MAP_SIZE
    /* PUD 0 -> Device PMD */
    create_table_entry x0, x1, x4, PUD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3
    /* PUD 1 -> RAM PMD */
    add x1, x1, #PAGE_SIZE
    add x4, x4, x5
    create_table_entry x0, x1, x4, PUD_SHIFT, TD_KERNEL_TABLE_FLAGS, x2, x3

    /* Populate Device PMD (0x00000000..0x40000000 -> linear map) */
    add x0, x0, #PAGE_SIZE
    ldr x2, =HIGH_MAP_DEVICE_START
    ldr x3, =HIGH_MAP_DEVICE_END
    ldr x4, =DEVICE_START
    create_block_map x0, x2, x3, x4, .Ltd_device_block_flags, x5

    /* Populate RAM PMD (0x40000000..0x80000000 -> linear map) */
    add x0, x0, #PAGE_SIZE
    ldr x2, =HIGH_MAP_RAM_START
    ldr x3, =HIGH_MAP_RAM_END
    ldr x4, =RAM_START
    create_block_map x0, x2, x3, x4, .Ltd_kernel_block_flags, x5
.endm

/* Crash-stamp UART macros for entry.S `show_invalid_entry_raw`.
 * virt redirects them at the QEMU PL011 @ 0x09000000:
 *   DR @ +0x000  — write = TX byte
 *   FR @ +0x018  — bit 5 = TXFF (1 = TX FIFO full); poll until clear
 *                  with `tbnz` (inverted vs. Pi's mini-UART LSR). */
.macro err_uart_load_io reg
    movz \reg, #0x0900, lsl #16
    movk \reg, #0xffff, lsl #48
.endm

.macro err_uart_load_lsr reg
    movz \reg, #0x0018
    movk \reg, #0x0900, lsl #16
    movk \reg, #0xffff, lsl #48
.endm

.macro err_uart_wait_tx_ready scratch, lsr_reg, lbl
\lbl\(): ldr \scratch, [\lsr_reg]
    tbnz \scratch, #5, \lbl\()b
.endm

/* QEMU `-kernel` and UEFI / GRUB chain hand off the DTB physical
 * address in x0 per the Linux arm64 boot protocol. Save it before
 * the first `bl` in boot.S `master` clobbers it; src/board/virt/
 * boot_quirks.S declares `dtb_pa` as a `.bss` quad. adrp+:lo12: pair
 * gives ±4 GiB reach (a plain `adr` would not survive once the .bss
 * landed far from .text). */
.macro save_dtb_pa src
    adrp x9, dtb_pa
    str  \src, [x9, #:lo12:dtb_pa]
.endm

/* Enable FP+SIMD access at EL0/EL1 by setting CPACR_EL1.FPEN
 * (bits 21:20) to 0b11. virt enters at EL1 directly (QEMU `-kernel`)
 * or via UEFI handoff, neither of which configures CPACR like
 * armstub8 does on Pi 4. Zig's std.mem (pulled in by dtb.zig)
 * lowers to NEON instructions in ReleaseSmall, so without this
 * write the very first NEON `movi`/`stp q*` faults with EC=0x07
 * (Trapped FP/SIMD). Pi's macro is empty — armstub already wrote
 * the same bits at EL3 and Pi's binary contains zero NEON. */
.macro enable_fp_simd_el1
    mrs x0, CPACR_EL1
    orr x0, x0, #(3 << 20)
    msr CPACR_EL1, x0
    isb
.endm

#endif /* BOARD_ASM_DEFS_INC */
