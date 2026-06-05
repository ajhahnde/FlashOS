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

### Added

- **FAT32 subdirectory path traversal.** Files below the mount root
  (`/mnt/dir/file`, and deeper) now open. Previously the mount backend
  encoded the whole mount-relative path as a single 8.3 name, so any
  `/`-separated path was rejected and only files in the mount root were
  reachable. The open hook now walks the path one component at a time,
  descending into each subdirectory entry. Directory *listing*
  (`readdir`) stays root-only for now — opening a known path works.
- **FAT32 write to an empty file.** Writing to a file whose directory
  entry has no data cluster yet (`first_cluster == 0`, the on-disk shape
  of a 0-byte file) now allocates its first cluster, links it, and
  records it in the directory entry, instead of failing closed. The
  write path now identifies the file by its directory-entry location
  (stashed at open) rather than an ambiguous re-walk by first cluster, so
  file growth works for subdirectory files too. Covered by host tests and
  a Pi-only `[TEST] fs-empty-write` in-kernel scenario; the boot contract
  moves to **28 in-kernel scenarios / 32 per-scenario checkpoints** (was
  27 / 31). Create-if-missing for a *non-existent* path and crash-atomic
  writes remain future work.
- **`-Dboot-selftest` build option (default off).** Gates the in-kernel
  test harness: a normal `zig build run-virt` / `deploy` now boots
  straight to the `login:` prompt with no test output, while CI and
  validation builds pass `-Dboot-selftest=true` to run the full
  in-kernel scenario suite. The EMMC2 smoke test and the free-page
  checkpoint dump are gated the same way.

### Changed

- **Boot output restyled to systemd-style status lines.** The kernel,
  init, login, and fsh now print `[ OK ]` / `[SKIP]` / `[WARN]` lines
  instead of `[Debug]` noise. The two success markers were renamed —
  `[Debug] login OK` → `[ OK ] Authenticated.` and
  `[Debug] fsh init OK` → `[ OK ] Reached target Shell.` — so any log
  parser keying on the old strings must be updated. The boot-contract
  checkpoint and session counts are unchanged by the restyle.
- **Diagnostic output suppressed by default.** EMMC2 and USB bring-up
  traces and hwrng chatter are now gated behind in-file flags
  (`DIAG`, `TRACE_VERBOSE`) that default off, keeping the boot log clean.

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
