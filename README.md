<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt=".flashOS" width="420">
  </picture>

<h3>UNIX-like AArch64 bare-metal kernel & operating system for the RPi 4B and QEMU <code>-M raspi4b</code></h3>

<p>
    <a href="https://github.com/ajhahnde/FlashOS/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/ajhahnde/FlashOS/test.yml?branch=main&style=flat-square&label=ci" alt="CI"></a>
    <a href="https://codecov.io/gh/ajhahnde/FlashOS"><img src="https://img.shields.io/codecov/c/github/ajhahnde/FlashOS?style=flat-square&label=coverage" alt="Coverage"></a>
    <img src="https://img.shields.io/badge/version-v0.8.0-lightgrey?style=flat-square" alt="Version">
    <img src="https://img.shields.io/badge/flash-v1.4.1-f59e0b?style=flat-square" alt="Flash">
    <img src="https://img.shields.io/badge/target-aarch64--elf-lightgrey?style=flat-square" alt="aarch64-elf">
    <img src="https://img.shields.io/badge/license-Apache--2.0-lightgrey?style=flat-square" alt="License">
  </p>

<p>
    <b>README</b> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="PORT.md"><b>Port</b></a> ·
    <a href="VERSIONING.md"><b>Versioning</b></a> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE.md"><b>License</b></a>
  </p>

</div>

---

<p align="center">
  <img src="assets/boot_demo.gif" alt="FlashOS booting on a Raspberry Pi into the fsh shell" width="780">
</p>

> The boot above is a replicate of FlashOS booting on
> Raspberry Pi 4B hardware to the `login:` prompt.

## About

FlashOS is a bare-metal AArch64 kernel that boots on Raspberry Pi 4B
hardware and under QEMU. The kernel core is written in
[Flash](https://github.com/ajhahnde/Flash) (a systems language built with
`LLVM IR`) with the boot path, exception vectors, and context
switch in AArch64 assembly. The build is driven entirely by
`build.flash`, which compiles the `.flash` modules through
a pinned `flashc`.
The current release ships with a complete uniprocessor process
lifecycle (`fork`, `exec`, `exit`, `wait`, `kill`), leak-free across
stress cycles, exercised by an in-kernel `[TEST]/[PASS]/[FAIL]`
harness and a host-side unit test suite.

## Specs

|                  |                                                                                        |
| :--------------- | :------------------------------------------------------------------------------------- |
| **Hardware**     | Raspberry Pi 4 Model B (BCM2711)                                                       |
| **Architecture** | AArch64 (ARMv8-A)                                                                      |
| **Languages**    | Flash, Zig + AArch64 assembly                                                          |
| **Toolchain**    | `flashc` (pinned) + Zig 0.16.0 + `aarch64-elf` binutils                                |
| **Targets**      | RPi 4B hardware, `qemu-system-aarch64 -M raspi4b`, _and_ `qemu-system-aarch64 -M virt` |

> The validated target is `-Dboard=rpi4b`. The QEMU `-M virt` board has not been
> CI-gated since **[v0.5.0](https://github.com/ajhahnde/FlashOS/releases/tag/v0.5.0)**

## Features

- **Two-stage boot.** EL3 armstub configures the GIC and `eret`s into
  the kernel at EL1 (Pi). On QEMU `-M virt`, `boot.S` does the EL3→EL1
  drop itself.
- **Dual-target build.** `-Dboard=rpi4b` or `-Dboard=virt` switches
  the per-board driver bag (`uart`, `gpio`, `timer`, `irq`), the
  linker script, and the boot quirks at comptime.
- **Four-level MMU.** Identity map for early bring-up, linear-high
  map for the kernel, demand-allocated user pages with per-region
  flags (text RX, data/heap/stack RW+UXN).
- **Priority round-robin scheduler** with timer-driven preemption.
- **Process lifecycle.** `fork` / `exec` / `exit` / `wait` / `kill`,
  zombie reap path, leak-free across stress cycles.
- **ELF64 loader.** `sys_execve` resolves a path through the VFS,
  streams each PT_LOAD segment into a freshly built address space with
  the right permissions, and eagerly maps the top stack page before
  copying the argv block onto the new user stack.
- **Userland mini-libc (`flibc`).** SVC wrappers, `printf` over
  `sys_writeConsole`, bump allocator over `brk` / `sbrk`,
  `fork` / `wait` / `exit` / `execve`. Linked into ELF demos by the
  build, kept under `user_space/lib/flibc/`.
- **Heap via `sys_brk` / `sys_sbrk`.** Pages are demand-allocated by
  the page-fault path inside `[HEAP_BASE, brk)`; shrinks unmap and
  free.
- **Region-aware page-fault dispatch.** `do_data_abort` classifies
  by user VA region (heap / stack / stack-guard / text / wild) and
  panics-and-zombies on out-of-region access; the parent's
  `sys_wait` reaps the offender so the harness keeps running.
- **Stack guard.** A 1-page unmapped region below the legal stack
  range turns runaway recursion into a `[KERN] stack overflow`
  diagnostic instead of memory corruption.
- **Unified file descriptors.** A single tagged `fds` table per task
  (`console` / `pipe` / `file`) behind one
  `read` / `write` / `close` / `dup2` ABI; fd 0/1/2 are pre-installed
  console slots, `fork` inherits the table and `execve` preserves it,
  so a shell can hand a child redirected stdio. Anonymous pipes
  (`sys_pipe`) ride the same table.
- **Interactive shell (`fsh`).** A userland REPL at `/bin/fsh` over the
  mini-libc (`flibc`): a `readline` line editor with TAB completion
  (double-TAB lists candidates), a tokenizer with a single `|` pipe stage,
  in-process built-ins (`cd` / `pwd` / `exit` / `logout` / `help` / `free` /
  `whoami` / `reboot`), a Unix-style `#`/`$` privilege prompt, and
  `fork` + `execvp` for externals. The `/bin` coreutils — `echo`, `cat`,
  `ls`, `grep`, `cp`, `mv`, `rm`, `meminfo`, `forkbomb`, `sysinfo`,
  `cpuinfo`, `uptime`, `dmesg`, `less`, `edit`, `clear`, `passwd` — link the same
  flibc; each is documented per-tool in
  [Documentation §4](DOCUMENTATION.md#4-process-management--scheduling).
  Reads `/etc/fshrc` at startup; `sys_chdir` gives each task a working
  directory.
- **Process identity, login & permissions.** Every task carries
  real + effective uid/gid (inherited across `fork`, preserved across
  `execve`) behind a `getuid`/`setuid`-family ABI, and every file carries
  mode/uid/gid metadata enforced at the open/write/exec syscall boundary
  (`-EACCES`, root bypasses). Boot runs `/bin/login` as a session
  supervisor: the kernel verifies the password with PBKDF2-HMAC-SHA256 +
  a constant-time compare (`sys_authenticate` — the KDF never leaves the
  kernel), then login forks a child that drops privilege and execs the
  user's shell; `exit` returns to the `login:` prompt. Passwords live in
  a writable `/mnt/shadow` on the SD card (protected to `0600 root:root`
  by a FAT32 permission overlay, with the read-only initramfs seed as the
  always-bootable fallback) and are changed with `passwd` /
  `sys_passwd` — fresh kernel-minted salt, splice-safe in-place rewrite.
  Password echo is suppressed through `SYS_SET_CONSOLE_MODE`. The seed
  accounts use fixed public salts (build reproducibility); rotated
  records get random salts.
- **Syscalls** dispatched via `svc` and an indexed table — see
  [Documentation §5](DOCUMENTATION.md#5-syscalls--exceptions).
- **USB-C gadget console.** The Pi's USB-C port enumerates as a
  CDC-ACM serial device (BCM2711 DWC2 OTG — Full-Speed, polled,
  slave/PIO): a single C-to-C cable to a Mac carries both power and
  the interactive `fsh` console (`/dev/tty.usbmodem…`, no driver
  install). User/shell output switches to USB when enumerated and
  falls back to the Mini-UART otherwise.
- **Two UARTs.** Mini-UART (UART1) for the console fallback + kernel
  diagnostics, dedicated PL011 for an out-of-band trace channel.
- **Kernel symbol table** generated by a two-pass `populate-syms` step
  and consumed by the function-entry tracer (runtime intact, but
  currently inert — Zig has no `-fpatchable-function-entry=2`
  equivalent yet).
- **In-kernel test harness** (`[TEST]/[PASS]/[FAIL]` + tally, 30
  scenarios) plus a host-side `zig build test` suite (464 host
  tests across 41 modules).

## Quick start

Install the toolchain:

```bash
brew install aarch64-elf-binutils qemu
```

FlashOS's source modules are written in
[Flash](https://github.com/ajhahnde/Flash) and compiled by `flashc`.
Build the pinned compiler once — `build.flash` looks for it at `~/Flash/flash-out/bin/flashc`
bydefault (override with `-Dflashc=<path>`):

```bash
git clone https://github.com/ajhahnde/Flash.git ~/Flash
git -C ~/Flash checkout "$(grep -oE '[0-9a-f]{40}' flash-toolchain.lock)"
( cd ~/Flash && flash build )
```

Build everything for the Pi:

```bash
flash build                   # default: -Dboard=rpi4b
```

Or build for QEMU `-M virt` (no armstub):

```bash
flash build -Dboard=virt
```

Run the kernel under QEMU:

```bash
flash build -Dboard=rpi4b run        # raspi4b machine (Pi 4 model)
```

```bash
flash build -Dboard=virt  run-virt   # generic ARMv8 virt machine
```

Run host-side unit tests (page allocator + ELF parser):

```bash
flash build test
```

For the full hardware flow (two-pass build with symbol-table population),
source the shell helpers and run the `build` function; add `-d` to also
deploy the artefacts to the SD card:

```bash
source flashos.zsh
build        # two-pass build only
build -d     # two-pass build + deploy to the SD card
```

See [Setup](SETUP.md) for the SD-card layout, firmware files, and
serial-console setup.

## Build steps

| Build step                             | Explanation                                                    |
| :------------------------------------- | :------------------------------------------------------------- |
| `flash build` (or `-Dboard=rpi4b`)     | Default — Pi: `kernel8.img` + `armstub8.bin`                   |
| `flash build -Dboard=virt`             | virt: `kernel8.img` only (no armstub)                          |
| `flash build kernel`                   | Kernel image only                                              |
| `flash build armstub` (rpi4b only)     | Armstub only                                                   |
| `flash build populate-syms`            | Regenerate `src/symbol_area.S` from the linked ELF             |
| `flash build deploy` (rpi4b only)      | Copy artefacts + RPi firmware to `$SD_BOOT`                    |
| `flash build -Dboard=rpi4b run`        | Boot under `qemu-system-aarch64 -M raspi4b`                    |
| `flash build -Dboard=virt run-virt`    | Boot under `qemu-system-aarch64 -M virt`                       |
| `flash build -Dboard=virt test-virt`   | Boot virt, watchdog asserts the boot reaches the fsh prompt    |
| `flash build -Dboard=rpi4b test-rpi4b` | Boot raspi4b, watchdog asserts the boot reaches the fsh prompt |
| `flash build -Dboard=virt iso`         | Build a GRUB-EFI rescue ISO (virt only)                        |
| `flash build test`                     | Host-side unit tests (`464 tests`, `41 modules`)               |
| `flash build clean`                    | Remove cache and build output                                  |

> The default optimisation mode is `ReleaseSmall`. Override with
> `-Doptimize=ReleaseSafe` (or `Debug`, `ReleaseFast`).

## Repository layout

```text
arch/aarch64/               AArch64 ISA core (boot, vectors, context switch)
src/                        kernel core (modules + drivers)
src/board/<name>/           per-board driver bag (rpi4b / virt) + linker script
user_space/                 PID 1 image + in-kernel test harness
user_space/lib/flibc/       userland mini-libc for ELF demos
lib/                        shared kernel↔user constants (syscall IDs)
tools/                      hand-rolled ELF demos (hello, stackbomb, UNIX utils etc.)
tests/                      host-side unit tests
armstub/                    EL3 → EL1 bootstrap shim (Pi only)
scripts/                    symbol-table generation, iso, QEMU test watchdog,
                            Pi-baseline verifier
assets/                     logo and visual assets
build.flash                 the only build entry point
flashos.zsh                 shell helpers incl. the two-pass `build` orchestrator
flash-toolchain.lock        pinned flashc revision (the Flash compiler)
config.txt                  RPi 4 firmware configuration
```

A deeper walk-through of each subsystem is in
[Documentation](DOCUMENTATION.md).

## See also

- **[Flash](https://github.com/ajhahnde/Flash)** — the operating system written in Flash.
- **[FlashOS Tour →](https://ajhahn.de/flashos/)**
- **[Flash Tour →](https://ajhahn.de/flash/)**

---

[Next: Documentation →](DOCUMENTATION.md)
