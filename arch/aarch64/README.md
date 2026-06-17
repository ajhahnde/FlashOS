# `arch/aarch64`

The CPU-architecture core for AArch64 (ARMv8-A). Everything in this directory
is ISA-specific: it touches system registers, the exception model, the MMU
translation regime, the generic timer, and the register-save layout that a
context switch depends on. Nothing here knows which board it runs on — that
boundary is owned by `src/board/<board>/`.

The rest of the kernel reaches this code by symbol, never by path. That makes
the set of symbols below a contract: a second architecture port would live in a
sibling `arch/<isa>/` directory and provide the same surface, leaving the
kernel core (`src/`) and the board layer (`src/board/`) unchanged.

## Files

| File | Role |
| ---- | ---- |
| `boot.S` | Reset entry (`_start`), EL transition, MAIR/TCR/SCTLR/TTBR setup, initial page tables, jump to the kernel main. |
| `entry.S` | Exception vector table, EL0/EL1 entry/exit save-restore, syscall dispatch, fork return path. |
| `sched.S` | Context switch (`core_switch_to`) and translation-base swap (`set_pgd`). |
| `irq.S` | IRQ vector install plus interrupt mask/unmask. |
| `generic_timer.S` | ARM generic timer: counter read and compare/control programming. |
| `utils.S` | Barriers, MMIO word accessors, current-EL/core reads, busy delay. |
| `mm.S` | Low-level memory primitives. |
| `asm_defs.inc` | ISA register and structure-offset definitions; bridges to the active board's `board_asm_defs.inc`. |
| `asm_defs_common.inc` | Definitions shared across the assembly sources. |

## Provided interface

The symbols this directory exports, grouped by concern:

- **Boot / CPU** — `_start`, `get_el`, `get_core`, `put32`, `get32`, `delay`
- **MMU / context** — `set_pgd`, `core_switch_to`, `memzero`
- **Exceptions** — `vectors`, `ret_from_fork`, `err_hang`, `show_invalid_entry_raw`
- **IRQ** — `irq_init_vectors`, `irq_enable`, `irq_disable`
- **Timer** — `get_sys_count`, `set_CNTP_TVAL`, `set_CNTP_CVAL`, `setup_CNTP_CTL`
- **Register layout** — the structure offsets in `asm_defs*.inc` that the save
  and restore paths share with the kernel's task structure.

## Required interface

The boot and exception paths call outward by symbol. These are supplied by the
machine-independent kernel (`src/`) and the board layer (`src/board/<board>/`):

- **Kernel entry** — `kernel_main` (first kernel code after MMU enable)
- **Memory** — `mem_map_init`, `mem_map_reserve_below`, `mem_map_reserve_above`,
  and the linker-emitted `_kernel_pa_end` marker
- **Scheduler** — `schedule`, `sched_init`, `current`, `copy_process`
- **Syscalls** — the syscall table and its relocation hook
- **Board bring-up** — interrupt controller init and per-board quirks, reached
  through the board trampolines

`board_asm_defs.inc`, included via the `asm_defs.inc` bridge, is the one
per-board input the assembly sources take at build time.

## Build wiring

`build.zig` assembles these sources for the kernel and adds this directory to
the assembler include path so the `asm_defs.inc` bridge resolves alongside the
active board's directory. The board-independent assembly that is *not* part of
the ISA core — the generated symbol table and the trace stubs — stays under
`src/`.
