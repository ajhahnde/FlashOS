/*
 * Assembly-only macros for armstub8.S.
 */

#ifndef ARMSTUB_ASM_DEFS_INC
#define ARMSTUB_ASM_DEFS_INC

#define BIT(x) (1 << (x))

/* ---- secure-mode setup (sysregs) ---- */
#define SCR_RW              BIT(10)
#define SCR_HCE             BIT(8)
#define SCR_SMD             BIT(7)
#define SCR_RES1_5          BIT(5)
#define SCR_RES1_4          BIT(4)
#define SCR_NS              BIT(0)
#define SCR_VAL \
    (SCR_RW | SCR_HCE | SCR_SMD | SCR_RES1_5 | SCR_RES1_4 | SCR_NS)

#define ACTLR_VAL \
    (BIT(0) | BIT(1) | BIT(4) | BIT(5) | BIT(6))

#define CPUECTLR_EL1        S3_1_C15_C2_1
#define CPUECTLR_EL1_SMPEN  BIT(6)

#define SPSR_EL3_D          BIT(9)
#define SPSR_EL3_A          BIT(8)
#define SPSR_EL3_I          BIT(7)
#define SPSR_EL3_F          BIT(6)
#define SPSR_EL3_MODE_EL1H  5
#define SPSR_EL3_VAL \
    (SPSR_EL3_D | SPSR_EL3_A | SPSR_EL3_I | SPSR_EL3_F | SPSR_EL3_MODE_EL1H)

#define L2CTLR_EL1          S3_1_C11_C0_2

#define SCTLR_EL1_RESERVED          (3 << 28) | (3 << 22) | (1 << 20) | (1 << 11)
#define SCTLR_EL1_EE_LITTLE_ENDIAN  (0 << 25)
#define SCTLR_EL1_EOE_LITTLE_ENDIAN (0 << 24)
#define SCTLR_EL1_I_CACHE_DISABLED  (0 << 12)
#define SCTLR_EL1_D_CACHE_DISABLED  (0 << 2)
#define SCTLR_EL1_MMU_DISABLED      (0 << 0)
#define SCTLR_EL1_VAL_MMU_DISABLED \
    (SCTLR_EL1_RESERVED | SCTLR_EL1_EE_LITTLE_ENDIAN \
    | SCTLR_EL1_I_CACHE_DISABLED | SCTLR_EL1_D_CACHE_DISABLED \
    | SCTLR_EL1_MMU_DISABLED)

#define HCR_EL2_RW          BIT(31)
#define HCR_EL2_VAL         HCR_EL2_RW

#define CPACR_EL1_FPEN      BIT(21) | BIT(20)
#define CPACR_EL1_ZEN       BIT(17) | BIT(16)
#define CPACR_EL1_VAL       (CPACR_EL1_FPEN | CPACR_EL1_ZEN)

/* ---- mmu (only what armstub references) ---- */
#define MATTR_DEVICE_nGnRnE        0x0
#define MATTR_NORMAL_NC            0x44
#define MATTR_DEVICE_nGnRnE_INDEX  0
#define MATTR_NORMAL_NC_INDEX      1
#define MAIR_EL1_VAL \
    ((MATTR_NORMAL_NC << (8 * MATTR_NORMAL_NC_INDEX)) \
    | MATTR_DEVICE_nGnRnE << (8 * MATTR_DEVICE_nGnRnE_INDEX))

#define TCR_TG1_4K     (2 << 30)
#define TCR_T1SZ       ((64 - 48) << 16)
#define TCR_TG0_4K     (0 << 14)
#define TCR_T0SZ       (64 - 48)
#define TCR_EL1_VAL    (TCR_TG1_4K | TCR_T1SZ | TCR_TG0_4K | TCR_T0SZ)

#endif /* ARMSTUB_ASM_DEFS_INC */
