<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="420">
  </picture>

<h3>A UNIX-like bare-metal OS for AArch64, built for the Raspberry Pi 4B and QEMU</h3>

<p>
    <a href="https://github.com/ajhahnde/FlashOS/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/ajhahnde/FlashOS/test.yml?branch=main&style=flat-square&label=ci" alt="CI"></a>
    <a href="https://codecov.io/gh/ajhahnde/FlashOS"><img src="https://img.shields.io/codecov/c/github/ajhahnde/FlashOS?style=flat-square&label=coverage" alt="Coverage"></a>
    <img src="https://img.shields.io/badge/version-v0.8.0-f59e0b?style=flat-square" alt="Version">
    <img src="https://img.shields.io/badge/rust-v1.97.0-dea584?style=flat-square" alt="Rust">
    <img src="https://img.shields.io/badge/target-aarch64--elf-lightgrey?style=flat-square" alt="aarch64-elf">
    <img src="https://img.shields.io/badge/license-apache--2.0-lightgrey?style=flat-square" alt="License">
  </p>

<p>
    <b>README</b> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
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

FlashOS is a bare-metal AArch64 kernel that runs on Raspberry Pi 4B
hardware and under QEMU. The kernel core is written in Rust,
while the boot path, exception vectors, and context-switching code
are implemented in AArch64 assembly.

The current release provides a complete uniprocessor process
lifecycle—including `fork`, `exec`, `exit`, `wait`, and `kill`—and
remains leak-free under repeated stress testing. Correctness is verified
through an in-kernel `[TEST]`/`[PASS]`/`[FAIL]` harness and a host-side
unit test suite.

Installation, build targets, QEMU commands, SD-card deployment, and
console setup are documented in **[Setup](SETUP.md)**.

> FlashOS is currently in pre-1.0 development; compatibility between
> releases is not guaranteed.

## Specs

**Hardware**: Raspberry Pi 4 Model B (BCM2711)
**Architecture**: AArch64 (ARMv8-A)
**Languages**: Rust 1.97.0 & AArch64 assembly
**Toolchain**: Cargo _and_ `aarch64-elf` binutils
**Targets**: RPi 4B hardware _and_ `qemu-system-aarch64 -M raspi4b`

## Features

- **Two-stage boot**. EL3 armstub enters the kernel at EL1 on Pi.
- **Four-level MMU**. Early identity mapping, a linear-high kernel map,
  and demand-allocated user pages with per-region permissions.
- **Priority round-robin scheduler** with timer-driven preemption.
- **Process lifecycle**. Leak-free `fork`, `exec`, `exit`, `wait`, and
  `kill`, including zombie reaping.
- **ELF64 loader**. `sys_execve` loads VFS-backed ELF segments into a
  fresh address space and prepares the user stack with `argv`.
- **Userland mini-libc (`flibc`)**. Syscall wrappers, formatted output,
  heap allocation, and process APIs for ELF programs.
- **Dynamic heap.** `sys_brk` and `sys_sbrk` grow pages on demand and
  release them when shrinking.
- **Region-aware page faults**. Faults are classified by virtual-memory
  region; invalid access terminates the offending process safely.
- **Stack guard**. An unmapped guard page detects stack overflows before
  they corrupt memory.
- **Unified file descriptors**. Console, pipe, and file descriptors share
  one API with inherited and redirectable standard I/O.
- **[FlashShell](https://github.com/ajhahnde/FlashShell)**. A command shell and scripting language, written
  in Rust — built to become the shell of FlashOS.
- **Users, login, and permissions**. UID/GID identity, Unix-style file
  modes, privilege dropping, PBKDF2-HMAC-SHA256 authentication, and
  protected password storage with a read-only fallback.
- **Syscalls** dispatched via `svc` and an indexed table.
- **USB-C gadget console**. CDC-ACM provides power and an interactive
  console over one cable, with automatic Mini-UART fallback.
- **Two UARTs**. Mini-UART handles diagnostics and fallback console I/O;
  PL011 provides an out-of-band trace channel.
- **Kernel symbol table**. A two-pass build generates symbols for the
  function-entry tracer.
- **Test suites**. An in-kernel `[TEST]`/`[PASS]`/`[FAIL]` harness plus
  427 host tests across 38 modules.

A deeper walk-through of each subsystem is in [Documentation](DOCUMENTATION.md).

## Repository layout

```text
arch/aarch64/               AArch64 ISA core (boot, vectors, context switch)
src/                        kernel core (modules + drivers)
src/board/<name>/           per-board driver bag (rpi4b / virt) + linker script
user/pid1/                  Rust PID 1 image + in-kernel test harness
crates/flibc/               Rust userland mini-libc for ELF programs
lib/                        shared kernel↔user constants (syscall IDs)
crates/user-rt/             Rust EL0 entry, syscall, panic, and memory runtime
user/hello/                 Rust /test/hello.elf exec fixture
tools/                      hand-rolled ELF programs (stackbomb, UNIX utils etc.)
tests/                      host-side unit tests
armstub/                    EL3 → EL1 bootstrap shim (Pi only)
scripts/                    symbol-table generation, iso, QEMU test watchdog,
                            Pi-baseline verifier
assets/                     logo and visual assets
build.zig                   production build graph (Flash/Zig/Rust bridge)
Cargo.toml                  Rust workspace
flashos.zsh                 shell helpers incl. the two-pass `build` orchestrator
flash-toolchain.lock        pinned flashc revision (the Flash compiler)
config.txt                  RPi 4 firmware configuration
```

## See also

- **[FlashOS Tour →](https://ajhahn.de/flashos/)**
- **[ajhahn.de →](https://ajhahn.de/)**

---

[Next: Documentation →](DOCUMENTATION.md)
