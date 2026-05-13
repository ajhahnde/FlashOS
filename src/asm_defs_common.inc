/*
 * Common assembly-level constants — board-independent.
 * Memory-layout addresses live in board_asm_defs.inc per board.
 */

#ifndef ASM_DEFS_COMMON_INC
#define ASM_DEFS_COMMON_INC

/* ---- mm ---- */
#define PAGE_SHIFT          12
#define TABLE_SHIFT         9
#define SECTION_SHIFT       (PAGE_SHIFT + TABLE_SHIFT)
#define PAGE_SIZE           (1 << PAGE_SHIFT)
#define SECTION_SIZE        (1 << SECTION_SHIFT)

#define ID_MAP_PAGES        3
#define ENTRIES_PER_TABLE   512
#define PGD_SHIFT           (PAGE_SHIFT + 3 * TABLE_SHIFT)
#define PUD_SHIFT           (PAGE_SHIFT + 2 * TABLE_SHIFT)
#define PMD_SHIFT           (PAGE_SHIFT + TABLE_SHIFT)

#define LINEAR_MAP_BASE     0xffff000000000000

/* ---- mmu / translation table descriptors ---- */
#define TD_VALID            (1 << 0)
#define TD_BLOCK            (0 << 1)
#define TD_PAGE             (1 << 1)
#define TD_TABLE            (1 << 1)
#define TD_ACCESS           (1 << 10)
#define TD_KERNEL_PERMS     (1 << 54)
#define TD_USER_PERMS       (1 << 6)
#define TD_INNER_SHARABLE   (3 << 8)

#define MATTR_DEVICE_nGnRnE        0x0
#define MATTR_NORMAL_NC            0x44
#define MATTR_DEVICE_nGnRnE_INDEX  0
#define MATTR_NORMAL_NC_INDEX      1

#define TD_KERNEL_TABLE_FLAGS \
    (TD_TABLE | TD_VALID)
#define TD_KERNEL_BLOCK_FLAGS \
    (TD_ACCESS | TD_INNER_SHARABLE | TD_KERNEL_PERMS \
    | (MATTR_NORMAL_NC_INDEX << 2) | TD_BLOCK | TD_VALID)
#define TD_DEVICE_BLOCK_FLAGS \
    (TD_ACCESS | TD_INNER_SHARABLE | TD_KERNEL_PERMS \
    | (MATTR_DEVICE_nGnRnE_INDEX << 2) | TD_BLOCK | TD_VALID)

/* ---- sysregs (only what the kernel .S files reference) ---- */
#define SCTLR_EL1_MMU_ENABLED   (1 << 0)

/* TCR_EL1: 4 KB granule both halves, 48-bit VA, 40-bit PA, IS, WB-WA walks.
 * Pi armstub leaves TCR usable; QEMU's -kernel shim does not — boot.S must
 * write this before MMU enable or the first translation walk faults. */
#define TCR_T0SZ            (16)            /* bits [5:0]   48-bit VA */
#define TCR_IRGN0_WBWA      (1 << 8)
#define TCR_ORGN0_WBWA      (1 << 10)
#define TCR_SH0_IS          (3 << 12)
#define TCR_TG0_4K          (0 << 14)
#define TCR_T1SZ            (16 << 16)
#define TCR_IRGN1_WBWA      (1 << 24)
#define TCR_ORGN1_WBWA      (1 << 26)
#define TCR_SH1_IS          (3 << 28)
#define TCR_TG1_4K          (2 << 30)       /* TG1 4 KB encoding != TG0 */
#define TCR_IPS_40BIT       (2UL << 32)
#define TCR_EL1_VAL \
    (TCR_T0SZ | TCR_IRGN0_WBWA | TCR_ORGN0_WBWA | TCR_SH0_IS | TCR_TG0_4K \
    | TCR_T1SZ | TCR_IRGN1_WBWA | TCR_ORGN1_WBWA | TCR_SH1_IS | TCR_TG1_4K \
    | TCR_IPS_40BIT)
/* sanity: TCR_EL1_VAL == 0x2B5103510 */

/* MAIR_EL1: idx 0 = Device-nGnRnE, idx 1 = Normal-NC. Compose from the
 * MATTR_* bytes above; the indices already match TD_DEVICE_BLOCK_FLAGS
 * and TD_KERNEL_BLOCK_FLAGS. */
#define MAIR_EL1_VAL \
    ((MATTR_NORMAL_NC << 8) | MATTR_DEVICE_nGnRnE)
/* sanity: MAIR_EL1_VAL == 0x4400 */

/* Self-sufficient EL3 → EL1 drop in boot.S. The values mirror what
 * armstub8.S sets up; redoing them in the kernel makes it bootable
 * directly from QEMU's `-kernel` (which enters at EL3 without running
 * armstub). On real hardware armstub has already written these, and
 * the second write of the same value is harmless. */
#define BIT(x) (1 << (x))

#define SCR_RW              BIT(10)
#define SCR_HCE             BIT(8)
#define SCR_SMD             BIT(7)
#define SCR_RES1_5          BIT(5)
#define SCR_RES1_4          BIT(4)
#define SCR_NS              BIT(0)
#define SCR_EL3_VAL \
    (SCR_RW | SCR_HCE | SCR_SMD | SCR_RES1_5 | SCR_RES1_4 | SCR_NS)

#define SPSR_EL3_D          BIT(9)
#define SPSR_EL3_A          BIT(8)
#define SPSR_EL3_I          BIT(7)
#define SPSR_EL3_F          BIT(6)
#define SPSR_EL3_MODE_EL1H  5
#define SPSR_EL3_VAL \
    (SPSR_EL3_D | SPSR_EL3_A | SPSR_EL3_I | SPSR_EL3_F | SPSR_EL3_MODE_EL1H)

#define HCR_EL2_RW          BIT(31)
#define HCR_EL2_VAL         HCR_EL2_RW

#define CPACR_EL1_FPEN      (BIT(21) | BIT(20))
#define CPACR_EL1_ZEN       (BIT(17) | BIT(16))
#define CPACR_EL1_VAL       (CPACR_EL1_FPEN | CPACR_EL1_ZEN)

#define SCTLR_EL1_RESERVED          ((3 << 28) | (3 << 22) | (1 << 20) | (1 << 11))
#define SCTLR_EL1_VAL_MMU_DISABLED  SCTLR_EL1_RESERVED
#define SCTLR_EL1_VAL_MMU_ENABLED   (SCTLR_EL1_RESERVED | SCTLR_EL1_MMU_ENABLED)

#define ESR_ELx_EC_SHIFT   26
#define ESR_ELx_EC_SVC64   0x15
#define ESR_ELx_EC_DA_LOW  0x24

/* ---- exception entry constants ---- */
#define SYNC_INVALID_EL1t       0
#define IRQ_INVALID_EL1t        1
#define FIQ_INVALID_EL1t        2
#define SERROR_INVALID_EL1t     3

#define SYNC_INVALID_EL1h       4
#define IRQ_INVALID_EL1h        5
#define FIQ_INVALID_EL1h        6
#define SERROR_INVALID_EL1h     7

#define SYNC_INVALID_EL0_64     8
#define IRQ_INVALID_EL0_64      9
#define FIQ_INVALID_EL0_64      10
#define SERROR_INVALID_EL0_64   11

#define SYNC_INVALID_EL0_32     12
#define IRQ_INVALID_EL0_32      13
#define FIQ_INVALID_EL0_32      14
#define SERROR_INVALID_EL0_32   15

#define SYNC_ERROR              16
#define SYSCALL_ERROR           17
#define DATA_ABORT_ERROR        18

#define S_FRAME_SIZE            272

/* ---- syscalls ---- */
/* Highest user-facing slot id +1 (entry.S `b.hs` cap). Slots 7..11 are
 * reserved file stubs that fall inside the dispatch range but return
 * immediately; brk/sbrk live at 12/13. The pipe ABI (v0.3.0 step 1.2)
 * lives at 18 + 27..29; the console ABI (v0.3.0 step 1.3) fills
 * slots 23..26, and the debug-only SYS_CONSOLE_INJECT lives at 30 —
 * the cap is therefore 31. See lib/syscall_defs.zig. */
#define NR_SYSCALLS  31

/* ---- sched ---- */
#define CORE_CONTEXT_OFFSET 0

#endif /* ASM_DEFS_COMMON_INC */
