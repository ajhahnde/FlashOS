/*
 * Bridge include for boot.S, entry.S, sched.S etc.: pulls in the
 * board-independent macros plus the active board's memory-layout
 * constants. The board file is found via the per-board include
 * path set in build.zig (src/board/<board>/).
 */

#ifndef ASM_DEFS_INC
#define ASM_DEFS_INC

#include "asm_defs_common.inc"
#include "board_asm_defs.inc"

#endif /* ASM_DEFS_INC */
