<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Changelog</h1>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="MIGRATION.md"><b>Migration</b></a> ·
    <a href="VERSIONING.md"><b>Versioning</b></a> ·
    <b>Changelog</b> ·
    <a href="LICENSE.md"><b>License</b></a>
  </p>
</div>

---

All notable changes to FlashOS are recorded in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
(see [VERSIONING.md](VERSIONING.md)). Per-tag notes also appear on the
[releases page](https://github.com/ajhahnde/FlashOS/releases).

## [Unreleased]

## [v0.1.0] - 2026-06-05

First public release. FlashOS was developed privately before this
release, so v0.1.0 already ships a substantial feature set; the
highlights are below.

### Added

- **Bare-metal AArch64 kernel** for the Raspberry Pi 4B and QEMU
  `-M virt`. Two-stage boot to EL1 (an EL3 armstub sets up the GIC and
  `eret`s down on the Pi; `src/boot.S` drops straight from EL3 to EL1
  under QEMU), then a four-level 4 KiB-page MMU brings up the identity
  map, the linear-high kernel map, and demand-allocated user pages.
- **Scheduler and processes.** Priority round-robin with timer-driven
  preemption, and the full `fork` / `exec` / `exit` / `wait` / `kill`
  lifecycle over an indexed syscall table. Zombies are reaped, and the
  scheduler stays leak-free across stress cycles.
- **ELF loader and a small userland libc** to run programs from user
  space, with bounds checks on the segment ranges so a malformed binary
  cannot map over the kernel or the stack guard.
- **Filesystem.** An initramfs plus a FAT32 backend, backed by the SD
  card on the Pi and a disk image under QEMU. A write/verify roundtrip
  test runs during boot.
- **Interactive shell (`fsh`)** over a unified file-descriptor ABI, with
  pipes, console RX, and tracing. Memory pressure is handled gracefully.
- **USB-C gadget console.** The Pi enumerates as a USB CDC serial device,
  so `fsh` runs over the same C-to-C cable that powers the board; no
  separate serial adapter is required for normal use.
- **Logins.** A small identity/auth layer: a `login:` prompt,
  PBKDF2-hashed passwords in a shadow file, and `passwd` to change them.
  The accounts are build-time and public; the security model and its
  limitations are documented.
- **Opt-in profiler** behind `-Dtrace`: samples the interrupted PC each
  timer tick and prints a symbolized trace on the Mini-UART. Off by
  default, zero footprint when off (the default image is byte-identical).
- **Tests.** An in-kernel `[TEST]` harness (27 EL0 scenarios / 31
  checkpoints, each with a free-page baseline check) that runs on every
  boot on both targets, plus a host-side `zig build test` suite (361
  tests across 35 modules) for the pure-logic pieces. CI runs the boot
  path on every push.
- **Dual-target build** — `-Dboard=rpi4b` / `-Dboard=virt` swaps the
  per-board driver set, linker script, and boot quirks at comptime. Both
  targets boot cleanly.
- **Kernel symbol table** generated from the linked ELF by a two-pass
  build step, so panics and the profiler can print real names.

[Unreleased]: https://github.com/ajhahnde/FlashOS/compare/v0.1.0...HEAD
[v0.1.0]: https://github.com/ajhahnde/FlashOS/releases/tag/v0.1.0

---

[← Prev: Versioning](VERSIONING.md) · [Next: License →](LICENSE.md)
</content>
