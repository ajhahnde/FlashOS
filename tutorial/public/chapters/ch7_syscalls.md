# Chapter 7: The Syscall Boundary

Chapter 6 ended on a question: the scheduler decides which task runs, but
how does a running userland program ever get the kernel's attention in
the first place? ARMv8 answers that with privilege levels. FlashOS runs
kernel code at EL1 and every userland program at EL0 — two separate
privilege rings, with EL0 code physically unable to touch EL1-only state
(the MMU tables, interrupt controller, or other tasks' memory). A
**syscall** is the one controlled doorway between the two: a userland
program cannot call kernel functions directly, but it can trap into EL1
through a well-defined instruction and ask the kernel to act on its
behalf.

## The ABI: x8, x0..x5, svc #0, x0

User-space invokes a syscall by placing the syscall number in `x8`,
arguments in `x0..x5`, and executing `svc #0`. The return value comes
back in `x0`:

```text
x8       syscall number
x0..x5   arguments (per syscall)
svc #0   trap into the kernel
x0       return value
```

`svc #0` is an AArch64 instruction whose entire job is to synchronously
trap from EL0 to EL1 at a fixed vector offset — it carries no other
side effect. Everything else about "what happens next" is a convention
the kernel and every userland caller agree on: which register holds the
syscall number, which hold the arguments, and which holds the result.

## Dispatch: vector table to sys_call_table

The trap lands in the exception vector table in `arch/aarch64/entry.S`,
which is loaded into `vbar_el1` at boot. Synchronous exceptions taken
from EL0 land in `handle_sync_el0_64`, which reads `esr_el1` to tell an
`svc` apart from a data or instruction abort and branches accordingly:

```text
handle_sync_el0_64:
    kernel_entry 0
    /* check esr_el1: svc, data abort, or instruction abort */
    mrs x25, esr_el1
    lsr x24, x25, #ESR_ELx_EC_SHIFT
    cmp x24, #ESR_ELx_EC_SVC64
    b.eq el0_svc
    cmp x24, #ESR_ELx_EC_DA_LOW
    b.eq el0_da
    cmp x24, #ESR_ELx_EC_IA_LOW
    b.eq el0_ia
    b el0_sync_other
```

*(excerpt from `arch/aarch64/entry.S` — not standalone-compilable)*

For the `svc` case, `el0_svc` zero-extends the syscall number out of
`w8`, range-checks it, and indexes into `sys_call_table`
(`src/sys.flash`):

```text
el0_svc:
    adr x27, sys_call_table
    /* zero extend the syscall number */
    uxtw x26, w8
    mov x25, #NR_SYSCALLS
    bl irq_enable
    cmp x26, x25
    /* branch if syscall number >= NR_SYSCALLS */
    b.hs invalid_syscall_num
    /* call syscall — guard against a null table slot. All NR_SYSCALLS slots
       are filled today; a future renumber that leaves a hole would otherwise
       `blr` to address 0 from EL1. cbz keeps that a clean -ENOSYS instead. */
    ldr x16, [x27, x26, lsl #3]
    cbz x16, invalid_syscall_num
    blr x16
    b ret_from_syscall
```

*(excerpt from `arch/aarch64/entry.S` — not standalone-compilable)*

`cmp` followed by `b.hs` ("branch if higher or same", the unsigned
greater-than-or-equal condition) is the range check: any syscall number
at or past `NR_SYSCALLS` falls through to `invalid_syscall_num` instead
of indexing off the end of the table. That constant is `#define
NR_SYSCALLS  56` in `arch/aarch64/asm_defs_common.inc` — confirmed
directly from that file, not recalled from a doc summary.

`56` only means anything if the assembly literal and the Flash-side
table agree on it, so `src/sys.flash` re-asserts the same value at
compile time:

```flash
comptime {
    if defs.NR_SYSCALLS != 56 {
        #compileError("NR_SYSCALLS drifted from arch/aarch64/asm_defs_common.inc — keep both in lockstep")
    }
}
```

*(excerpt from `src/sys.flash` — not standalone-compilable)*

If a future change adds a 57th syscall to `lib/syscall_defs.flash`
without also bumping the asm-side `#define`, this guard fails the build
instead of letting the two sides silently drift apart — one file
(`lib/syscall_defs.flash`) is authoritative, and both the kernel table
and the assembly range check are checked against it rather than each
other.

## A tour of the syscall surface

`lib/syscall_defs.flash` is the single source of truth for every `SYS_*`
constant: both the kernel dispatch table and userland's syscall wrappers
import the same names from it, so a renumbering is a one-file,
compiler-enforced change rather than paired edits kept in sync only by
comments. The full list runs to roughly forty live slots; rather than
reformat that whole reference here, this is a guided sample grouped by
theme — see `lib/syscall_defs.flash` itself for the complete, current
picture.

- **Process lifecycle** — `SYS_FORK` (1), `SYS_EXIT` (2), `SYS_WAIT` (3):
  the fork/exit/wait triad chapter 6 walked through from the kernel
  side.
- **Exec** — `SYS_EXECVE` (31), the path-resolved ELF loader and the
  sole exec entry point since the legacy blob loader was retired.
  Chapter 8 covers what a program looks like once this syscall has
  loaded it.
- **Unified fd I/O** — `SYS_READ` (32), `SYS_WRITE` (33), `SYS_CLOSE`
  (34), `SYS_DUP2` (35): one `(fd, buf, len)`-shaped ABI that dispatches
  by the fd's kind tag (console, pipe, or file) in a shared fd table,
  rather than separate read/write calls per kind.
- **Filesystem** — `SYS_OPEN_FILE` (7) opens a VFS path into an fd;
  `SYS_CREATE` (53), `SYS_UNLINK` (54), and `SYS_RENAME` (55) round out
  FAT32 metadata operations (create, remove, rename — files only).
- **Identity / auth** — `SYS_GETUID` (39) through `SYS_SETGID` (44)
  read and mutate the four credential ids `TaskStruct` carries;
  `SYS_AUTHENTICATE` (45) is the one call `/bin/login` uses to check a
  password against the shadow database — the kernel runs the KDF and
  returns pass/fail only, never a salt or hash, to userland.
- **Hardware info** — `SYS_MEMTOTAL` (49) through `SYS_CPU_FREQ` (52):
  four argument-free reads backing the `cpuinfo`/`sysinfo` tools, each
  reporting `0` (rendered as `n/a`) on a board without the underlying
  firmware.

## Retired slots: a concrete case for one source of truth

Ten slot numbers — 0, 5, 8, 9, 11, 23, 24, and 27 through 29 — are
permanently retired. They used to be legacy per-kind shims (`write_str`,
the old blob-loader `exec`, per-kind `readFile`/`writeFile`/`closeFile`,
`openConsole`/`readConsole`, and the three pipe shims) that were
replaced when file, console, and pipe I/O were unified onto the
`SYS_READ`/`SYS_WRITE`/`SYS_CLOSE`/`SYS_DUP2` ABI at slots 32–35. Rather
than reuse the freed numbers, the dispatch table routes them to a `-1`
stub and `lib/syscall_defs.flash` documents them as permanently
reserved — they must never be reassigned to a new syscall.

That reservation is exactly the kind of invariant a single shared
definitions file is good at holding: it lives as a doc comment next to
the constants it protects, and the comptime guard means a mismatch
between the asm-side count and the Flash-side table breaks the build
immediately rather than becoming a hard-to-reproduce dispatch bug
discovered later.

## What's next

The syscall boundary this chapter walked through has callers on the
other side of it — chapter 8 turns to userland itself: how an ELF binary
gets loaded by `SYS_EXECVE`, and how `flibc` wraps these raw
`x8`/`svc #0` mechanics into ordinary function calls a userland program
can make without ever writing inline assembly.
