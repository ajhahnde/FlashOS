<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Changelog</h1>

<p><i>All notable changes to FlashOS, release by release.</i></p>

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

## [v0.3.0] - 2026-06-07

### Added

- **Password masking at the login prompt.** `/bin/login` now echoes a
  `*` per typed password character instead of suppressing echo, via a new
  `CONSOLE_MODE_MASK` bit on `SYS_SET_CONSOLE_MODE`; typed secrets are
  acknowledged without being shown. The mode is restored to the default
  (kernel echo off) before the shell starts, so the mask never leaks into
  the session.
- **Shared `console_ui` terminal-look module (`lib/console_ui/`).** One
  freestanding source owns the status-tag taxonomy (`[ OK ]` / `[WARN]` /
  `[FAIL]` …), the ANSI palette, and the line/stage/banner renderers,
  compiled into both the kernel boot log and the userspace shell through a
  caller-supplied sink — the whole system restyles from a single file.
  Status tags tint only the inner word, systemd-style.
- **fsh homescreen banner.** The shell prints
  `FlashOS [v<version>] by ajhahnde - type 'help' for commands` at REPL
  entry, with the version single-sourced from `build.zig.zon` via
  `build_options` (no version literal in code).
- **TAB completion in the shell.** `fsh` completes on TAB via a new
  `readlineCompleting` line-editor path: the first token against `/bin`
  plus the in-process built-ins, a later token as a filesystem path; the
  buffer extends to the longest common prefix and a unique match appends a
  trailing space or `/`. `help` now also enumerates `/bin`, so a new tool
  advertises itself by existing.
- **`/bin/sysinfo`.** A print-and-exit coreutil rendering the FlashOS
  version, the logged-in user, and the free-page count as aligned
  key/value rows — the first consumer of the new screen-renderer module.
- **Shared screen-renderer + input seams.** New freestanding, host-tested
  modules: `lib/console_ui/screen.zig` (alternate-screen, cursor, box
  panels, key/value rows), `user_space/lib/flibc/keys.zig` (VT100 input
  decoder), and `user_space/lib/flibc/completion.zig` (tab-completion
  core). Allocator-free, with no kernel changes.
- **`reboot` and `logout` shell built-ins.** `fsh` gains `reboot`, which
  resets the board through a new `SYS_REBOOT` syscall (slot 47) — PSCI
  `SYSTEM_RESET` over the HVC conduit on QEMU `virt`, the BCM2711 watchdog
  full-reset on Raspberry Pi 4 — and `logout`, a synonym for `exit` that
  ends the session and returns to the `login:` prompt. Both join the
  shell's TAB completion and `help` listing.
- **Command history and in-line cursor editing in the shell.** `fsh`
  now decodes the VT100 arrow-key sequences in its line editor
  (`flibc.readlineEdit`) instead of echoing them as literal characters:
  Up/Down recall earlier commands from a per-session history ring, and
  Left/Right move the cursor so a keystroke inserts or backspaces at the
  cursor rather than only at the end of the line. History lives in a
  fixed, caller-owned ring (no allocator) and needs no new syscall.
- **`-Dtest-filter` for the host-test step.** `zig build test
  -Dtest-filter=<substr>` runs only host tests whose name contains the
  substring, for faster focused iteration; the default runs the full
  suite.
- **`/bin/less`.** A full-screen text pager — the first interactive
  consumer of the screen-renderer + input seams. It takes over the
  alternate screen, draws a titled panel, and scrolls a file with the
  arrow keys, `j`/`k`, space/`b` (page), and `g`/`G` (ends), quitting on
  `q` and restoring the shell view. Built on a new allocator-free,
  host-tested pager core (`flibc.Pager`); no new syscall.
- **`/bin/clear`.** A terminal-clear coreutil — the smallest consumer of
  the shared screen renderer. It emits the `console_ui.screen.clear`
  sequence (cursor home + erase) and exits, wiping the current screen in
  place; the escape bytes stay single-sourced in `console_ui` rather than
  hardcoded in the tool.
- **Double-TAB candidate listing in the shell.** When TAB completion is
  ambiguous with nothing left to insert, a second consecutive TAB lists
  every matching command or path on a fresh line and redraws the prompt,
  so the choices are visible without abandoning the typed line. Built on a
  new pure, host-tested `completion.classify` helper; no new syscall.
- **`pwd` shell built-in.** `fsh` gains `pwd`, which prints the current
  working directory through a new `SYS_GETCWD` syscall (slot 48) — the
  readback half of the existing `cd` / `SYS_CHDIR` store, copying the
  per-task `cwd` out of the kernel. It joins the shell's TAB completion
  and `help` listing.

### Changed

- **`help` output restructured for readability.** The shell's `help` now
  lists each built-in with a one-line description in aligned columns under
  section headers (`Commands:` / `Run a program:` / `Programs in /bin:`),
  replacing the previous single-line blob. The `/bin` listing is still
  enumerated live, so new tools keep appearing automatically.
- **Boot-success marker moved to the fsh homescreen.** The QEMU watchdog
  and the `picapture` helper now key on the stable
  `type 'help' for commands` homescreen tail instead of the retired
  `[ OK ] Reached target Shell` / `[ OK ] Authenticated` markers. The
  kernel entropy announce is reworded from
  `hwrng: fallback (timer mix, weak) ok` to `Initialized hwrng`. These
  change the serial console output format (a breaking change to the boot
  contract).
- **virt boot-watchdog free-page checkpoints.** They move to `0x3be46`
  (per scenario) / `0x3be54` (boot baseline) because the larger `fsh`
  (TAB completion, history, the restructured `help`), the new `/bin/sysinfo`
  and `/bin/less` tools, and the `+strict-align` codegen grow the embedded
  initramfs and kernel image; rpi4b is unchanged (its reserve calls are
  no-ops).

### Removed

- **`[ OK ] Authenticated` login marker.** `/bin/login` no longer prints
  a per-session auth marker; a blank line separates the password prompt
  from the shell homescreen. Boot success is now the homescreen-marker
  count alone.

### Fixed

- **`/bin/less` alignment fault on real hardware.** The pager's by-value
  `Pager` return was vectorized into a misaligned 16-byte NEON store
  (`stur q` at struct offset 40), which faulted under `SCTLR_EL1.A` on real
  silicon (data abort, alignment fault) while passing QEMU's lenient TCG.
  Instead of another per-site `align(16)` / volatile dodge, the freestanding
  aarch64 build target now sets `+strict-align`, so LLVM never widens a copy
  or a by-value return into an unaligned NEON store — closing the class for
  the kernel and every userland tool at codegen. The virt boot-watchdog
  checkpoints shift one page as a result (see Changed).
- **Line editing at the `login:` and password prompt.** `/bin/login` read
  the username and password through a dumb byte loop that *appended* a
  backspace byte instead of erasing it, so a single mistype was
  uncorrectable and the attempt failed as "Login incorrect." Login now
  drives flibc's line editor in echo-off mode: the username gets full
  backspace editing, and the password reuses the same host-tested `step`
  core with masked echo — one `*` per byte, rubbed out on backspace. No
  kernel or syscall change.

## [v0.2.0] - 2026-06-06

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
  `[Debug] login OK` → `[ OK ] Authenticated` and
  `[Debug] fsh init OK` → `[ OK ] Reached target Shell` — so any log
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

[Unreleased]: https://github.com/ajhahnde/FlashOS/compare/v0.3.0...HEAD
[v0.3.0]: https://github.com/ajhahnde/FlashOS/compare/v0.2.0...v0.3.0
[v0.2.0]: https://github.com/ajhahnde/FlashOS/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/ajhahnde/FlashOS/releases/tag/v0.1.0

---

[← Prev: Versioning](VERSIONING.md) · [Next: License →](LICENSE.md)
</content>
