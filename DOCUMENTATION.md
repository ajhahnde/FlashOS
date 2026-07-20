<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Documentation</h1>

<p>
    <a href="README.md"><b>README</b></a> ·
    <b>Documentation</b> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE.md"><b>License</b></a>
  </p>

</div>

---

This document describes the current Rust implementation. Historical source
layouts and retired build paths remain available through Git history and the
changelog; they are not active build instructions.

## Contents

1. [Source layout](#1-source-layout)
2. [Build and boot path](#2-build-and-boot-path)
3. [Memory management](#3-memory-management)
4. [Tasks, files, and userland](#4-tasks-files-and-userland)
5. [Syscalls and exceptions](#5-syscalls-and-exceptions)
6. [Kernel symbols and tracing](#6-kernel-symbols-and-tracing)
7. [Testing and release gates](#7-testing-and-release-gates)
8. [Build artefacts](#8-build-artefacts)

## 1. Source layout

The active implementation is split by responsibility rather than by language:

```text
arch/aarch64/                           AArch64 boot, vectors, IRQ entry, and switching
  boot.S                                reset entry, page tables, MMU enable
  entry.S                               exception vectors and syscall dispatch
  sched.S                               context-switch primitive
  irq.S, generic_timer.S                architectural IRQ/timer helpers
  asm_defs*.inc                         assembly-visible ABI constants

src/                                    retained low-level link inputs
  board/rpi4b/                          Pi assembly definitions and linker script
  board/virt/                           frozen virt assembly/linker inputs
  trace/                                function-entry trace trampolines and hook
  symbol_area.S                         generated fixed-size kernel symbol table

crates/abi/                             shared task, syscall, ELF, and EL0 layout ABI
crates/kernel/                          active Rust kernel implementation
  src/kmain.rs                          bring-up, PID 0, and PID 1 launch
  src/page_alloc.rs, mm_user.rs         physical and user virtual memory
  src/sched.rs, fork.rs, execve.rs      task lifecycle and ELF loading
  src/sys.rs                            syscall handlers and dispatch table
  src/vfs.rs, file.rs, fdtable.rs       VFS, open files, and descriptor ownership
  initramfs.rs, initramfs_backend.rs    read-only root filesystem
  fat32.rs, fat32_backend.rs            FAT32 parser and mutable /mnt backend
  rpi4b_*.rs                            active Pi drivers
  src/trace/                            symbol lookup, entry tracing, and sampling
crates/klib/                            static-link and C-ABI export seam
crates/flibc/                           userland engines (readline, pager, TUI)
crates/console-ui/                      shared boot/status rendering
crates/pwfile/                          shared /etc/passwd parser

user/                                   Rust EL0 executables
  pid1/                                 PID 1 and the 30-scenario runtime harness
  fsh/                                  interactive shell
  login/, passwd/                       authentication programs
  edit/, less/                          full-screen programs
  cat/, clear/, cp/, echo/, grep/
  ls/, mv/, rm/                         core utilities
  cpuinfo/, dmesg/, meminfo/
  sysinfo/, uptime/                     system-information tools
  argv-echo/, flibc-demo/, hello/
  forkbomb/, stackbomb/                 ABI, stress, and fault fixtures

rootfs/                                 checked-in filesystem seeds
  etc/passwd                            account database
  etc/perms.tab                         FAT32 permission overlay
  fsh/fshrc                             shell startup file

xtask/                                  native build, generation, and inspection driver
tools/                                  ELF linker scripts and initramfs embed assembly
armstub/                                Pi EL3-to-EL1 bootstrap
scripts/                                watchdog, disk image, hygiene, and baseline tools
firmware/                               bundled Raspberry Pi firmware inputs
Cargo.toml                              Rust workspace and release profile
versions.env                            live release, Rust, and QEMU version source
rust-toolchain.toml                     synchronized compiler pin, target, components
flashos.zsh                             build/run/deploy and Pi-console helpers
```

`src/` is not the kernel core. It contains the assembly and linker inputs that
remain outside Rust. The machine-independent kernel lives in `crates/kernel/`;
the shared assembly contract lives in `crates/abi/` and is checked by
`cargo xtask asm-defs --check`.

## 2. Build and boot path

### Native production build

`cargo xtask build --board rpi4b` performs the complete production link:

1. Cargo builds the kernel static library for
   `aarch64-unknown-none-softfloat`.
2. Every EL0 program is built, inspected, stripped, and staged.
3. `xtask` generates the deterministic `/etc/shadow` seed.
4. The sorted initramfs entry list is encoded as a deterministic newc CPIO.
5. Clang assembles the retained `.S` files.
6. `rust-lld` links `kernel8.elf` with the board linker script.
7. `llvm-objcopy` produces `kernel8.img`.
8. The build rejects undefined symbols, `core::fmt`, FP/SIMD instructions,
   duplicate memory providers, and artefacts outside their size budgets.

The Rust compiler, target, `rust-src`, and LLVM tools come from
`rust-toolchain.toml`. Clang is the only compiler outside the pinned Rust
toolchain. The build trace used by `cargo xtask guard --board rpi4b --full`
proves which subprocesses ran.

The `build` helper in `flashos.zsh` first rejects drift from `versions.env`,
then adds a clean start, source-hygiene checks, two-pass symbol generation,
symbol-layout convergence checking, and the Pi armstub. `run` applies the same
version preflight before every compile or test path. See [Setup](SETUP.md) for
exact commands.

### Raspberry Pi boot

1. The Pi firmware reads `config.txt`, loads `armstub8.bin` and
   `kernel8.img`, and starts the armstub at EL3.
2. `armstub/src/armstub8.S` establishes the EL3-to-EL1 hand-off.
3. `_start` in `arch/aarch64/boot.S` installs the early stack and page
   tables, clears BSS, programs the EL1 translation registers, enables the MMU,
   and branches through the high mapping to `kernel_main`.
4. `kernel_main_impl` in `crates/kernel/src/kmain.rs` runs on core 0.
   Secondary cores remain parked; FlashOS is currently single-core.
5. Bring-up initializes the page allocator, Mini-UART, PL011 trace UART,
   vectors, GIC, USB gadget, symbol table, syscall table, initramfs, EMMC2,
   optional FAT32 mount, entropy source, and generic timer.
6. The scheduler creates PID 1 as a kernel thread. It installs console
   descriptors 0, 1, and 2, locates `/sbin/init` in the initramfs, and loads
   its ELF image into EL0.
7. `user/pid1/src/lib.rs` runs the optional boot-selftest harness and then
   execs `/bin/login`. Login authenticates, forks a session child, drops its
   UID/GID, and execs the configured shell.

The normal deploy image does not run the selftest harness and stops at an
interactive login. The watchdog image adds both `--boot-selftest` and
`--ci-login-seed` so the same path can complete unattended.

The retained `virt` board input is frozen and deprioritized. The active
release gates are `rpi4b` under QEMU and the same `rpi4b` artefact on
Raspberry Pi hardware.

## 3. Memory management

### Kernel and physical memory

FlashOS uses 4 KiB pages and a four-level AArch64 translation regime. The boot
assembly creates an early identity map plus the high linear map beginning at
`0xffff000000000000`. Kernel code translates between a physical address and
its high alias with the helpers in `crates/kernel/src/mm_user.rs`.

The physical-page allocator in `crates/kernel/src/page_alloc.rs` owns the
range `0x40000000..0xfc000000`: 770,048 possible 4 KiB pages on the Pi.
Bring-up reserves pages below the linked kernel end and above the board's RAM
limit. Those reservations are a no-op for the current 4 GiB Pi layout because
the kernel sits below the pool and RAM reaches its end; they materially reduce
the frozen 1 GiB `virt` pool.

The allocator is a byte-per-page bitmap. Allocation returns a physical address
or zero; every consumer treats zero as OOM and must not map it. User-address
spaces track at most 32 user pages and 32 page-table pages per task.

### EL0 virtual layout

`crates/abi/src/user.rs` is the single source of truth:

| Region | Start / extent                        | Current mapping policy       |
| :----- | :------------------------------------ | :--------------------------- |
| Text   | `0x0000000000000000`                  | executable PT_LOAD pages     |
| Data   | `0x0000000000100000`                  | non-executable PT_LOAD pages |
| Heap   | `0x0000000000200000` upward to `brk`  | demand-mapped RW+XN          |
| Stack  | 16 pages below `0x00000ffffffff000`   | demand-mapped RW+XN          |
| Guard  | one page below the legal stack window | terminates the task          |

The ELF loader maps executable segments without XN and all other segments with
XN. The current descriptor set has no user read-only bit, so executable pages
are still writable; W^X is not yet enforced.

The loader eagerly maps the top stack page and lays out `argc`, `argv`, and
argument strings there. Remaining legal stack pages and heap pages are mapped
on translation faults. A fault in the guard page, text range, or any unrelated
EL0 range marks the task as a zombie with a diagnostic. The parent later reaps
its address space normally.

`copy_from_user` and `copy_to_user` first validate and prefault the complete
range. Bad or oversized user pointers return an error to the syscall rather
than turning a recoverable argument error into a kernel fault.

### Task memory and OOM

Each dynamically created task has:

- one page containing its `TaskStruct`;
- a separate 4 KiB kernel-stack page;
- a private page-table root and tracked page-table pages;
- copied or newly loaded user pages.

PID 0 keeps the boot stack rather than allocating this pair. Keeping every
created task's kernel stack separate from `TaskStruct` prevents a deep syscall
stack from reaching the credential fields. `KeRegs`, the 272-byte saved
exception frame, sits at the top of the dedicated stack page, leaving 3,824
bytes for the active call chain; a nested IRQ consumes part of that same budget.
Assembly-visible sizes and offsets are generated from `crates/abi/`.

Partial fork, page-table, pipe, file, and exec allocations have explicit
rollback paths. After exec has passed its point of no return, a load-time OOM
terminates the task instead of restoring the old image.

## 4. Tasks, files, and userland

### Scheduler and process lifecycle

`crates/kernel/src/sched.rs` owns a fixed table of 64 task pointers. The
scheduler is uniprocessor, preemptive, and priority-weighted: runnable tasks
spend a counter, and an exhausted round refills counters from priorities.
`arch/aarch64/sched.S` swaps callee-saved registers, SP, FP, LR, and the
translation base.

- `fork` allocates a task page and kernel stack, clones the user address
  space, inherits file descriptors, CWD, and credentials, then publishes the
  child.
- `exit` marks the current process as a zombie and wakes its parent.
- `wait` blocks until a child is reapable, then releases descriptors, user
  pages, page-table pages, kernel stack, and task page.
- `kill` applies the zombie transition to another process. Self-kill is
  rejected; a process exits itself through `exit`.
- `execve` resolves an ELF through the VFS, copies the executable and argv
  into bounded kernel scratch space, replaces the address space, and enters at
  the ELF entry point. PID, credentials, CWD, and descriptors survive exec.

### File descriptors, pipes, and console

Every task carries eight tagged descriptor slots. A slot is empty, console,
pipe, or file. The unified `read`, `write`, `close`, and `dup2` syscalls
dispatch by this tag.

Console descriptors refer to process-wide devices and carry no allocated
object. Pipes and open files are refcounted; fork increments their references,
close and reap drop them, and the last reference releases the backing page.
Pipe and console reads block on wait queues rather than polling in userland.

Mini-UART RX interrupts feed the 256-byte ring in
`crates/kernel/src/console.rs`. The USB CDC-ACM gadget feeds the same ring.
User output switches to USB when the gadget is configured and otherwise uses
Mini-UART. Kernel diagnostics remain on Mini-UART; function-entry trace output
uses PL011 on GPIO 8/9.

### VFS and initramfs

`crates/kernel/src/vfs.rs` owns two mount slots:

| Path                         | Backend                                             |
| :--------------------------- | :-------------------------------------------------- |
| everything except `/mnt/...` | read-only initramfs root                            |
| `/mnt/...`                   | FAT32, when EMMC2 and the volume mount successfully |

The prefix includes the trailing slash, so `/mnt2/file` stays on the
initramfs backend. There is no general mount syscall or longest-prefix mount
tree.

The deterministic initramfs contains:

- `/sbin/init`;
- the shell, login, passwd, editor, pager, and core utilities under `/bin`;
- `/etc/passwd`, `/etc/shadow`, and `/etc/fshrc`;
- four ELF fixtures under `/test`.

The newc encoder and its per-entry mode policy live in
`xtask/src/initramfs.rs` and `xtask/src/build.rs`. Regular programs are
`0755`, public configuration is `0644`, and shadow is `0600`, all owned
by root.

### FAT32

`crates/kernel/src/rpi4b_emmc2.rs` provides polled single-block I/O to the
BCM2711 Arasan controller. `crates/kernel/src/fat32.rs` parses the MBR, BPB,
FAT, and directory entries; `crates/kernel/src/fat32_backend.rs` exposes the
VFS operations.

The mutable surface supports regular-file open, read, write, seek, create,
unlink, rename, and indexed directory reads. Names are FAT 8.3 only; there is
no long-filename support. Create and unlink are file-only, and rename is
same-directory only.

QEMU's `raspi4b` machine does not provide a usable EMMC2/SD path. The FAT32
roundtrip and metadata mutation legs therefore skip under QEMU and are
hardware-only acceptance checks. The host suite covers the pure FAT32 logic
and an in-memory backend seam, but not physical EMMC2 timing.

FAT32 has no Unix ownership fields. FlashOS reads `PERMS.TAB` at mount and
overlays mode/UID/GID by basename. Missing entries default to `0666`
root:root; `SHADOW` is always floored at `0600` root:root even if the
overlay is missing or invalid.

### Identity and authentication

`/etc/passwd` uses `name:uid:gid:home:shell`.
`/etc/shadow` uses
`name:iterations:salt_hex:hash_hex`. The kernel performs
PBKDF2-HMAC-SHA256 and constant-time comparison; userland receives only the
pass/fail result.

The initramfs shadow is an immutable recovery seed. When available,
`/mnt/shadow` is the writable database. Password changes use a new
kernel-generated salt and an equal-length in-place record rewrite. Root may
reset any account; a non-root process may change only its own record and must
provide the old password.

The seed deliberately uses fixed public salts and a modest iteration count so
the production image remains reproducible and the boot test stays practical
under QEMU TCG. The current entropy provider is a timer-mixed fallback and
announces that limitation; a BCM2711 RNG200 driver is not implemented.

The permission check in `crates/kernel/src/perm.rs` applies classic
owner/group/other bits to open, write, and exec. Effective UID 0 bypasses the
check. There are no ACLs, supplementary groups, setuid bits, `chmod`,
`chown`, or open-mode flags yet.

### Userland

The FlashSDK `flashsdk-rt` crate provides the EL0 entry and SVC transport, and
`flashsdk-base` the formatted output, process wrappers, and bump heap; both are
consumed at one pinned revision. `crates/flibc/` adds the userland engines on
top: readline/history/completion, key decoding, pager and gap-buffer cores, and
TUI rendering.

`fsh` implements built-ins in-process and forks external commands. Bare
command names resolve to `/bin/<name>`; there is no environment or `PATH`
search. The parser accepts one pipeline stage and uses `pipe` plus `dup2`
to connect the two children.

`less` and `edit` use the alternate screen and raw key decoding in
userland. `edit` is the main heap consumer and saves by unlinking, creating,
and rewriting the destination because the current FAT32 write path does not
truncate an existing file.

The current production image ships `fsh`, the text-mode programs above, and
an internal Rust ABI in `crates/abi/`. After the Rust-port release, the planned
integration order is:

1. create and activate FlashSDK as the narrow public syscall/userspace ABI,
   EL0 runtime, base library, and target-and-link contract;
2. make FlashShell the first real FlashSDK product consumer; its source is
   already vendored in-tree as a nested workspace under `components/flashshell/`,
   built and tested by its own CI job under a pinned toolchain;
3. build FlashUI as the second consumer, a native TUI that embeds FlashShell;
4. cut the default session over to `PID 1 -> login -> flashui`, while retaining
   `/bin/fsh` as a tested recovery shell.

Kernel-private records such as `TaskStruct`, register frames, and VFS/fd
internals do not become public merely because they currently live beside
syscall types in `crates/abi/`. FlashSDK will version independently as a 0.x
contract; the FlashOS v1.0 stability cut is the first durable ABI promise.

## 5. Syscalls and exceptions

EL0 wrappers put the syscall number in `x8` and arguments in `x0..x5`,
then execute `svc #0`. `arch/aarch64/entry.S` saves a 272-byte
`KeRegs` frame, rejects `x8 >= 56`, and branches through the relocated
table owned by `crates/kernel/src/sys.rs`.

The active syscall groups are:

| Slots     | Surface                                                  |
| :-------- | :------------------------------------------------------- |
| 1–13      | process lifecycle, free-page debug, file open/seek, heap |
| 18        | anonymous pipe                                           |
| 25–26, 30 | console mode, reserved close, test-only input injection  |
| 31        | path-resolved ELF `execve`                               |
| 32–35     | unified `read`, `write`, `close`, `dup2`                 |
| 36–38, 48 | CWD, indexed `readdir`, kernel log, `getcwd`             |
| 39–47     | credentials, authentication, password change, reboot     |
| 49–52     | memory total, uptime, CPU temperature, CPU frequency     |
| 53–55     | FAT32 create, unlink, rename                             |

Slots 0, 5, 8, 9, 11, 23, 24, and 27–29 are retired and permanently return
an error. Slots 14–17 and 19–22 are reserved stubs. The ABI definitions,
`NR_SYSCALLS = 56`, `Dirent`, and `EACCES = 13` live in the FlashSDK
`flashsdk-abi` crate, consumed at one pinned revision.

Synchronous faults decode ESR and the fault address in the board IRQ/exception
path. Recoverable user translation faults are handled by
`crates/kernel/src/mm_user.rs`; terminal invalid entries print
`ERROR CAUGHT`, which the watchdog treats as a hard failure.

The kernel log is a 16 KiB overwrite-oldest byte ring. `main_output` tees
kernel messages into it, and `klog_read` returns a consume-free snapshot for
`/bin/dmesg`.

## 6. Kernel symbols and tracing

### Symbol table

The linked image reserves exactly 128 KiB for `_symbols`.
`xtask/src/syms.rs` encodes each filtered symbol as one 64-byte address/name
entry and appends a zero sentinel. It rejects overlong names and a table that
would exceed the fixed section.

The user-facing `build` helper performs:

1. a kernel link with the current placeholder or table;
2. `cargo xtask populate-syms --board rpi4b`, which relinks, reads
   `kernel8.elf` with the pinned `llvm-nm`, filters mapping and runtime
   aliases, and rewrites `src/symbol_area.S`;
3. a final link;
4. an `nm` comparison proving symbol addresses converged.

Keeping the section fixed-size means population cannot move later sections.

### Function-entry tracing

`src/trace/patchable_trampolines.S` provides two patchable NOPs for four
canonical entries: `kernel_main`, `_schedule`, `do_wait`, and
`copy_process`. Bring-up relocates their linker table and patches the first
slot to preserve LR and the second to branch to `hook`. The hook resolves the
entry through ksyms and writes its name to the PL011 trace UART.

This function-entry tracer is part of the normal kernel. The runtime
`trace` scenario drives fork, scheduling, exit, and wait through those
trampolines and checks the usual page-balance invariant.

### Statistical sampler

`cargo xtask build --board rpi4b --trace` additionally compiles the IRQ
sampler. The same flag defines `FLASHOS_TRACE` for `entry.S`, so IRQ entry
passes the saved `KeRegs` pointer in `x0`. The sampler emits at most one
Mini-UART backtrace per second, always includes the interrupted PC, and walks
only frame records that stay inside the current task's kernel-stack page.
Interrupts taken from EL0 are marked as user samples rather than walking an
untrusted user stack.

## 7. Testing and release gates

### Host tests

`cargo xtask test` runs the workspace host tests while excluding only the two
bare-metal static libraries that cannot link as host binaries. At the current
tree revision it discovers 746 Rust tests. The command's own output remains
the authoritative count.

Coverage includes:

- ABI layout and syscall bounds;
- page allocation, user faults, fork, scheduling, and wait queues;
- VFS, initramfs, FAT32, descriptors, pipes, console, and kernel log;
- ELF, path normalization, permissions, overlays, account and shadow parsing;
- SHA-256, HMAC, PBKDF2, entropy mixing, mailbox data, and USB helpers;
- shell tokenization, readline, completion, pager, gap buffer, and user tools;
- `xtask` generators, command parsing, and artefact guards.

### Runtime harness

With `--boot-selftest`, `user/pid1/src/harness.rs` runs exactly 30 EL0
scenarios:

| Area                 | Scenarios                                                                                                                     |
| :------------------- | :---------------------------------------------------------------------------------------------------------------------------- |
| Processes and memory | `fork-stress`, `oom-graceful`, `kill`, `brk`, `stack-overflow`, `wild-pointer`, `exec-fault`, `undef-instr`, `efault-syscall` |
| ELF and ABI          | `exec-elf`, `execve`, `flibc`, `trace`                                                                                        |
| I/O and filesystems  | `pipe`, `console-echo`, `fd-redirect`, `initramfs-open`, `vfs-dispatch`, `fs-roundtrip`, `fs-empty`, `readdir`, `klog`        |
| Hardware data        | `rng`, `hwmon-core`, `hwmon-mailbox`                                                                                          |
| Identity             | `creds`, `authenticate`, `perm`, `login`, `passwd`                                                                            |

Each scenario emits one `[TEST]` and one `[PASS]` or `[FAIL]`, then
checks the free-page baseline. FAT32-dependent legs emit explicit passing
skips when `/mnt` is unavailable.

### QEMU watchdog contract

`run watchdog rpi4b` builds with `--boot-selftest --ci-login-seed`,
creates `rust-out/test_sd.img`, and boots QEMU with a 720-second ceiling. A
green result requires:

- `30/30 passed`;
- no `[FAIL]` and no `ERROR CAUGHT`;
- 34 user checkpoints at `0xbbff1`;
- one pre-PID-1 boot checkpoint at `0xbc000`;
- one healthy entropy announcement and no entropy self-test failure;
- one exact `elf hello` marker;
- three `type 'help' for commands` shell markers.

The retained frozen `virt` matcher currently records `0x3be4f` for the
user checkpoint and `0x3be5e` for the boot checkpoint. Those values are not
an active release gate while `virt` remains frozen.

### Static gates

CI also runs:

- `cargo fmt --all --check`;
- workspace Clippy with warnings denied;
- `cargo xtask check-hygiene`;
- every shipped EL0 payload build and inspection;
- `cargo xtask asm-defs --check`;
- `cargo xtask census`;
- `cargo xtask guard --board rpi4b --full`;
- the rpi4b watchdog.

The full guard executes the production build behind rejecting command shims,
then checks its subprocess trace. Artefact inspection enforces zero undefined
symbols, zero `core::fmt`, and zero FP/SIMD instructions.

### Hardware-only acceptance

The exact release `kernel8.img` and `armstub8.bin` must also boot on a
Raspberry Pi 4B. Hardware acceptance covers:

- the login-to-shell path;
- EMMC2 block read/write;
- two-boot FAT32 roundtrip persistence;
- create/write/read/rename/unlink on the real card;
- USB-C CDC-ACM enumeration and console fallback;
- optional PL011 trace capture for a trace-feature image.

Flashing or overwriting an SD card is an explicit operator action; the build
does not deploy unless `build -d` is used.

## 8. Build artefacts

| Path                                    | Description                                    |
| :-------------------------------------- | :--------------------------------------------- |
| `rust-out/rpi4b/kernel8.img`            | raw production image loaded by Pi firmware     |
| `rust-out/rpi4b/kernel8.elf`            | unstripped linked kernel for inspection        |
| `rust-out/rpi4b/armstub8.bin`           | raw EL3-to-EL1 Pi armstub                      |
| `rust-out/rpi4b/armstub8.elf`           | linked armstub for inspection                  |
| `rust-out/initramfs-bin/initramfs.cpio` | deterministic newc archive                     |
| `rust-out/initramfs-stage/`             | exact filesystem tree encoded into the archive |
| `rust-out/user/*.unstripped.elf`        | unstripped EL0 artefacts                       |
| `rust-out/test_sd.img`                  | generated QEMU FAT32 fixture                   |

`target/` is Cargo's compilation cache; `rust-out/` is the assembled
product tree. `cargo xtask clean` removes both.

---

[← Prev: README](README.md) · [Next: Setup →](SETUP.md)
