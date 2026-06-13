<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Migration</h1>

<p><i>How a C bare-metal kernel became pure Zig + AArch64 assembly, phase by phase.</i></p>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <b>Migration</b> ·
    <a href="PORT.md"><b>Port</b></a> ·
    <a href="VERSIONING.md"><b>Versioning</b></a> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE.md"><b>License</b></a>
  </p>
</div>

---

This page documents how FlashOS was translated from
[`rhythm16/rpi4-bare-metal`](https://github.com/rhythm16/rpi4-bare-metal)
(a C bare-metal kernel for the Raspberry Pi 4) into a pure Zig +
AArch64-assembly project. Each phase lists the modules touched, the design choices made, and the gotchas encountered.

> **Note (post-migration evolution).** This document captures the
> *migration end-state*. Several files referenced below have since
> moved during the Phase-A dual-target port:
>
> - `src/uart.zig`, `src/gpio.zig`, `src/timer.zig`, `src/irq.zig`
>   were split into per-board copies under
>   `src/board/{rpi4b,virt}/`.
> - `src/asm_defs.inc` became a thin bridge header; the shared
>   board-independent macros now live in `src/asm_defs_common.inc`,
>   and per-board addresses live in
>   `src/board/{rpi4b,virt}/board_asm_defs.inc`.
> - `src/linker.ld` was likewise split into
>   `src/board/{rpi4b,virt}/linker.ld`.
>
> See [Documentation §1](DOCUMENTATION.md#1-source-layout) for the
> current source layout. The narrative below intentionally preserves
> the original (pre-port) paths so the migration recipe still
> reproduces against the rhythm16 baseline.

## Contents

0. [Starting point](#0-starting-point)
1. [Phase 1 — C baseline as the reference](#1-phase-1--c-baseline-as-the-reference)
2. [Phase 2 — Utilities, drivers, hardware glue](#2-phase-2--utilities-drivers-hardware-glue)
3. [Phase 3 — Memory management &amp; scheduling](#3-phase-3--memory-management--scheduling)
4. [Phase 4 — Tracing &amp; user space](#4-phase-4--tracing--user-space)
5. [Phase 5 — Headers, linker script, build system](#5-phase-5--headers-linker-script-build-system)
6. [Validation](#6-validation)

End state of the migration:

- Zero `.c` / `.h` files in the tree.
- `Makefile` removed; `build.zig` is the single source of truth.
- All ABI/contract types kept `extern struct` so they remain
  layout-compatible with the hand-written assembly entry points.

### 0. Starting point

`rhythm16/rpi4-bare-metal` is organised around a Makefile that
drives GCC (`aarch64-elf-gcc`) on a tree of C sources under `src/`
plus a few `.S` files. Headers in `include/` carry both runtime
declarations and constants used by assembly via `#include`. A
two-pass build embeds a kernel symbol table for tracing.

The migration kept the original directory layout, ABI, and assembly
entry points unchanged so each step could be validated incrementally.

### 1. Phase 1 — C baseline as the reference

- Imported the upstream sources verbatim and got the GCC build
  reproducing on the local toolchain (`/opt/homebrew/bin/aarch64-elf-*`).
- Confirmed the kernel boots on real hardware and a serial console
  prints the `pid 1 in user space` lines from `init.c`.
- This baseline became the oracle for every subsequent port: each
  Zig module had to produce a functionally identical object before
  the C one was deleted.

### 2. Phase 2 — Utilities, drivers, hardware glue

Order: leaves first, then anything they pull in.

| C source                | Zig replacement           | Notes                                                                                                            |
| :---------------------- | :------------------------ | :--------------------------------------------------------------------------------------------------------------- |
| `src/utilc.c`         | `src/utilc.zig`         | `memcpy`/`memset`/`panic`, `main_output*` helpers                                                        |
| `src/uart.c`          | `src/uart.zig`          | mini-UART driver, MMIO via `*volatile` `extern struct` (now `src/board/{rpi4b,virt}/uart.zig`)             |
| `src/gpio.c`          | `src/gpio.zig`          | pin function/enable, replaces `GpioRegs` from `peripherals/gpio.h` (now `src/board/{rpi4b,virt}/gpio.zig`) |
| `src/timer.c`         | `src/timer.zig`         | BCM2711 system timer 1 (now `src/board/{rpi4b,virt}/timer.zig`)                                                |
| `src/generic_timer.c` | `src/generic_timer.zig` | wraps `setup_CNTP_CTL`, `set_CNTP_TVAL`                                                                      |
| `src/irq.c`           | `src/irq.zig`           | GIC distributor + dispatcher (`handle_irq`) (now `src/board/{rpi4b,virt}/irq.zig`)                           |
| `src/sys.c`           | `src/sys.zig`           | syscall table + handlers                                                                                         |
| `src/page_alloc.c`    | `src/page_alloc.zig`    | physical page allocator (no scheduler dependency)                                                                |

Patterns adopted:

- MMIO blocks are declared as `extern struct` with raw `u32` fields
  and accessed via `*volatile T`. This matches the C
  `struct pl011_uart_regs` layout byte-for-byte without using a
  packed struct.
- Where C used preprocessor constants (`PA_TO_KVA`, `LINEAR_MAP_BASE`),
  the Zig modules redeclare `const` values locally so each file is
  self-contained — there is no shared `mm.zig` header analogue for
  numeric constants because each consumer needs only a small subset.
- Functions that interact with assembly entry points (`memzero`,
  `core_switch_to`, `set_pgd`, …) keep their original C linkage names
  via `export fn`.

### 3. Phase 3 — Memory management & scheduling

These modules have intricate dependencies on `task_struct`, the
exception-frame layout, and the assembly-defined boundary symbols
(`__start_patchable_functions`, `id_pg_dir`, `_start`).

| C source                  | Zig replacement                                                             |
| :------------------------ | :-------------------------------------------------------------------------- |
| remainder of `src/mm.c` | `src/mm_user.zig` (`map_page`, `copy_virt_memory`, `do_data_abort`) |
| `src/sched.c`           | `src/sched.zig` (priority round-robin, `_schedule`, `switch_to`)      |
| `src/fork.c`            | `src/fork.zig` (`copy_process`, `prepare_move_to_user_elf`)           |
| `src/kernel.c`          | `src/kernel.zig` (`kernel_main`, `kernel_process`)                    |

Key decisions:

- `task_struct`, `core_context`, `mm_struct`, `ke_regs` are mirrored
  as `extern struct` in **every** Zig module that touches them.
  Repetition is intentional: the C ABI is the contract that the `.S`
  files (`sched.S`, `entry.S`) and other modules rely on.
- `current`, `task[]`, `nr_tasks`, `init_task` are owned by
  `src/sched.zig` (`export var`) and consumed via `extern var`
  elsewhere.
- The placeholder `KERNEL_PA_BASE` symbol referenced from `boot.S`
  moved into `src/mm_user.zig`.

### 4. Phase 4 — Tracing & user space

The tracing subsystem and the PID-1 user image were the last C islands.

| C source                                                 | Zig replacement              |
| :------------------------------------------------------- | :--------------------------- |
| `src/trace/utils.c`                                    | `src/trace/utils.zig`      |
| `src/trace/trace_main.c` + `src/trace/traced_main.c` | `src/trace/trace_main.zig` |
| `src/trace/ksyms.c`                                    | `src/trace/ksyms.zig`      |
| `src/trace/pl011_uart.c`                               | `src/trace/pl011_uart.zig` |
| `user_space/init.c` + `user_space/sys.S`             | `user_space/init.zig`      |

Notes:

- Pointer arithmetic in `trace_modify_code` and
  `trace_calculate_offset` uses `@ptrFromInt`/`@intFromPtr` and
  explicit `i64`/`u64` casts; the signed offset is `@truncate`d to
  `i32` to fit the `bl` immediate.
- `__start_patchable_functions` / `__stop_patchable_functions` /
  `hook` / `ksyms` are declared as `extern var u64` so the linker
  script can supply their addresses.
- The user-space syscall ABI now lives directly in user-space Zig as
  inline assembly (`svc #0` with `x8` clobber). This eliminated
  `user_space/sys.S` entirely.

### 5. Phase 5 — Headers, linker script, build system

This was the destructive phase: remove every `.h` file and replace
`make` with `zig build`.

#### 5.1 Eliminating `include/`

The headers carried two distinct kinds of content:

1. Macros consumed only by `.S` files (page-table flags, exception
   constants, syscall numbers).
2. C function declarations and `struct` types — those became Zig.

For (1) the constants were consolidated into two assembler-only
include files:

- `src/asm_defs.inc` — used by `boot.S`, `entry.S`, `sched.S`, …
  (now a thin bridge: shared macros live in `src/asm_defs_common.inc`,
  per-board addresses in `src/board/{rpi4b,virt}/board_asm_defs.inc`)
- `armstub/src/asm_defs.inc` — armstub-specific macros.

The `.S` files had `#include "mm.h"` etc. rewritten to
`#include "asm_defs.inc"`. After that, `include/` was deleted in one
shot.

#### 5.2 User-image isolation

The original Makefile filtered user-space objects by build directory
(`user_build/*(.text)`) inside the linker script. Once everything is
built by Zig under `.zig-cache/`, that filter no longer works. Two
fixes:

- Compile `user_space/init.zig` as its **own** `addObject` named
  `user_init`, so the resulting object file ends in `user_init.o`.
- Each declaration in `user_space/init.zig` carries
  `linksection(".text.user")` / `.rodata.user` (defence in depth),
  and the kernel link script (`src/linker.ld`, now per-board under
  `src/board/{rpi4b,virt}/linker.ld`) uses
  `EXCLUDE_FILE(*user_init*.o)` to keep the user image out of the
  kernel's `.text`/`.rodata`/`.data`/`.bss` and routes its sections
  into the wrapper between `user_start` and `user_end`.

#### 5.3 `build.zig`

Single executable target:

- Root: `src/start.zig` — a one-line file that
  `comptime { _ = @import(...); }`s every kernel module so their
  `export fn` decls are emitted.
- `addAssemblyFile` for every `.S` file, including the placeholder
  `src/symbol_area.S`.
- `addObject(user_init)` to link the user image into the kernel ELF.
- `setLinkerScript` + `entry = .disabled` (the entry point lives in
  `boot.S`).
- A second tiny `addExecutable` for the armstub, with its own linker
  script (`armstub/src/linker.ld`) placing `.text` at address `0`.
- `aarch64-elf-objcopy -O binary` runs as a `b.addSystemCommand`
  child step to convert each ELF to the raw image the firmware
  expects.

Optional steps:

- `populate-syms` runs
  `aarch64-elf-nm | grep | zig run scripts/generate_syms.zig` to
  rewrite `src/symbol_area.S` from the linked ELF.
- `deploy` mirrors the old `make deploy` recipe.
- `clean` wipes `.zig-cache/` and `zig-out/`.

`build.sh` orchestrates the convergent two-pass workflow: build,
populate, build again, diff the symbol table.

#### 5.4 Symbol-area sizing

LLVM emits more symbols than GCC did (outlined functions, anonymous
helpers, mangled module names). The pre-allocated `_symbols` size in
`scripts/generate_syms.zig` was bumped from 16 KiB to 64 KiB to fit
~330 symbols at 64 bytes each. The linker script reserves the same
amount via `KEEP(*(_symbols))` so addresses do not shift between the
two passes.

### 6. Validation

Each phase was validated with the same checks:

1. `zig build` succeeds at every step.
2. `aarch64-elf-objdump -h` shows the expected sections in the
   expected order.
3. `aarch64-elf-nm -n` symbol counts before and after `populate-syms`
   match (i.e. the section size was reserved correctly).
4. `build.sh` runs end-to-end without manual intervention and reports
   an empty diff between pass 1 and pass 2.

---

[← Prev: Setup](SETUP.md) · [Next: Port →](PORT.md)
