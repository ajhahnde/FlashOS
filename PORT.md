<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt=".flashOS" width="280">
  </picture>

<h1>Port</h1>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <b>Port</b> ·
    <a href="VERSIONING.md"><b>Versioning</b></a> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE.md"><b>License</b></a>
  </p>
</div>

---

This page documents how the FlashOS source was ported from Zig to
[Flash](https://github.com/ajhahnde/Flash) — a self-hosted systems
language that transpiles to Zig. The OS-image modules now carry the
`.flash` extension; `flashc` lowers them to Zig at build time, which Zig
then compiles as before. The port preserved behaviour, not just source:
the boot contract's per-board free-page checkpoints held unchanged from
the first ported module to the last.

> **Historical scope.** This page records the v0.4 source migration and
> its former Zig-backend pipeline. Starting with v0.8, `build.flash` and
> `flash build` are authoritative; current build instructions live in
> [Setup](SETUP.md).

> **Lineage.** FlashOS began as a C bare-metal kernel by Wei-Lin Chang
> (rhythm16; see [License](LICENSE.md)), was rewritten in pure Zig +
> AArch64 assembly, and now carries its OS-image code in Flash. This page
> covers the Zig → Flash step: the _OS-image_ modules moved to Flash while
> the boot assembly, the host build tooling, and a small, documented set of
> modules stay Zig (see [§4](#4-what-stays-zig)).

## Contents

1. [Flash, and why](#1-flash-and-why)
2. [The toolchain pin](#2-the-toolchain-pin)
3. [What moved to Flash](#3-what-moved-to-flash)
4. [What stays Zig](#4-what-stays-zig)
5. [How the original build transpiled](#5-how-the-original-build-transpiled)
6. [Validation](#6-validation)

End state of the port:

- Every portable OS-image module — kernel core, board drivers, user
  space, and the in-kernel test harness — is written in Flash.
- The `.flash` file is the single source of truth; the Zig it lowers to
  lives only in the build cache and is never committed.
- The kernel image is behaviourally identical to the pre-port Zig build:
  both boot watchdogs assert the same 28-scenario / 32-checkpoint
  contract and the same free-page checkpoints, on both boards, with no
  re-capture across the entire port.

## 1. Flash, and why

[Flash](https://github.com/ajhahnde/Flash) is a systems language whose
compiler, `flashc`, emits Zig. A `.flash` module is lowered to a `.zig`
module at build time and then compiled by the ordinary Zig toolchain, so
Flash inherits Zig's backend, `comptime`, and `extern struct` ABI while
presenting its own surface syntax.

Because `flashc` lowers to the same Zig the project already compiled, the
port could proceed module by module against a live oracle: each `.flash`
module had to transpile to Zig that was behaviourally identical to the
`.zig` it replaced before the original was removed. The boot contract —
the free-page checkpoints the QEMU watchdog asserts — was the
byte-level witness that nothing drifted.

## 2. The toolchain pin

`flash-toolchain.lock` (repository root) pins the exact `flashc`
revision the tree is transpiled with — a version and a commit. Pinning
keeps the transpile reproducible: port progress never depends on a moving
compiler, and a clean checkout always lowers the same Flash to the same
Zig.

The build resolves the compiler binary through the `-Dflashc=<path>`
option, defaulting to `~/Flash/zig-out/bin/flashc`. Flash ships no
prebuilt binaries, so the pinned self-hosted `flashc` is built
from source at the pinned commit (`zig build`); see
[Setup §1](SETUP.md#1-host-toolchain). Bumping the pin is a deliberate,
isolated step — rebuild, then re-run both boot watchdogs — never folded
into an unrelated change.

## 3. What moved to Flash

The OS-image code — everything that ends up in the kernel image or the
PID-1 user image — was ported, leaves first, then their consumers:

| Layer            | Modules (representative)                                                                                                                                |
| :--------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Kernel core      | page allocator, user memory mapper, scheduler, fork, the path-resolved ELF loader and `execve`, the syscall dispatcher, pipes, wait queues, permissions |
| Filesystem       | the FAT32 driver and its block-device backend, the initramfs backend, the file-descriptor table, path resolution                                        |
| Board drivers    | per-board MMIO (UART, GPIO, timer, mailbox, power), the interrupt controllers, the SD-card (EMMC2) and USB drivers, the hardware RNG fallback           |
| Identity         | the shadow / password files and the SHA-256 used to verify logins                                                                                       |
| User space       | the PID-1 init image, the `fsh` shell, and the `flibc` userland syscall wrappers                                                                        |
| Shared constants | the syscall-number and task/user memory-layout definitions both the kernel and user side import                                                         |
| Test harness     | the in-kernel `[TEST]` suite, ported last so it stayed an independent oracle until the end                                                              |

The kernel symbol table (`src/symbol_area.S`) is regenerated once per
stage, not per module; its only churn from the port was symbol _renames_
as modules were promoted to named build modules, with the symbol count
and image addresses unchanged.

## 4. What stays Zig

Not everything is Flash, by design:

- **AArch64 assembly (`.S`) and linker scripts (`.ld`).** The boot path,
  exception vectors, context switch, and section layout are assembly and
  linker concerns, outside Flash's domain.
- **The tracing subsystem (`src/trace/`).** An opt-in profiler, not
  compiled into the default image. It was promoted to named build modules
  so the Flash drivers could import it language-agnostically, but its own
  source stays Zig.
- **The kernel boot trampoline (`src/start.zig`).** The force-link root
  that pulls in every module's exports; it hosts the build's module wiring
  and stays Zig.
- **Two kernel modules — the file-descriptor type registry and the
  virtual filesystem layer.** Both use a Flash language feature
  (non-exhaustive enums) the pinned compiler does not yet lower. They
  remain Zig, are consumed as language-agnostic named modules (so the rest
  of the tree is indifferent to their language), and are tracked for a
  follow-up once the toolchain gains the feature.
- **Host build infrastructure.** `build.zig`, the symbol-table and
  initramfs tooling under `scripts/`, and the host unit tests run on the
  developer's machine during the build, never in the OS image, and stay
  Zig.

## 5. How the original build transpiled

`build.zig` registers each `.flash` module through a transpile step that
invokes `flashc` to lower it to Zig in the build cache; that generated
Zig becomes the module's root source, wired into the same module graph
(imports, target, optimisation) the `.zig` module used. The transpile
step is marked as having side effects so the build cache always re-runs
it against the external compiler.

The `.flash` source is authoritative. The generated Zig is a build
artifact: it lives under the cache, is never committed, and is never
edited by hand. To inspect what a module lowers to, transpile it with the
pinned `flashc` and read the cache output.

## 6. Validation

Every module passed the same gates before its Zig original was removed:

1. **Transpile cleanly** — `flashc` lowers the `.flash` with no
   diagnostics.
2. **Review the lowering** — diff the generated Zig against the `.zig` it
   replaces; the bodies must be behaviourally identical (the port adds no
   features and fixes no bugs — improvements are deferred so the oracle
   stays honest).
3. **Host unit tests** — `zig build test`.
4. **Both boot watchdogs** — the QEMU `virt` and `rpi4b` runs assert the
   28-scenario / 32-checkpoint boot contract and the per-board free-page
   checkpoints. Unchanged hex is the proof the lowering preserved
   behaviour.
5. **Real hardware** — the hardware-touching drivers (SD-card, USB
   console, interrupt controller) were re-confirmed on a Raspberry Pi 4.

Across the whole port the free-page checkpoints never moved and no
contract re-capture was needed — the strongest available evidence that
Flash lowered to the same machine the project shipped before.

---

[← Prev: Setup](SETUP.md) · [Next: Versioning →](VERSIONING.md)
