<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/flashos_logo_dark.png">
    <img src="../assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Architecture</h1>

<p>
    <a href="../README.md"><b>README</b></a> ·
    <a href="README.md"><b>Documentation</b></a> ·
    <b>Architecture</b> ·
    <a href="development.md"><b>Development</b></a> ·
    <a href="verification.md"><b>Verification</b></a> ·
    <a href="../LICENSE"><b>License</b></a>
  </p>

</div>

---

This document describes the current x86_64 system architecture, component boundaries, layers, boot model, and image configuration. The former AArch64/Raspberry Pi implementation is preserved in the separately archived `FlashOS-old` repository and is not a contract for this source tree.

## Contents

1. [Project boundary](#1-project-boundary)
2. [Image configuration](#2-image-configuration)
3. [Build and boot path](#3-build-and-boot-path)
4. [FlashShell integration](#4-flashshell-integration)
5. [Identity and compatibility names](#5-identity-and-compatibility-names)

## 1. Project boundary

FlashOS is an independent solo project. Its repository, releases, product
identity, system configuration, roadmap, and shell are owned by FlashOS.

FlashOS is a TUI product. A framebuffer, display driver, keyboard driver, and
`fbcond` may be required to present a terminal on physical hardware; they are
not a desktop or GUI layer. Orbital, COSMIC, X11, Wayland, graphical
applications, and a graphical installer are outside the product scope.

The current source tree began as a Redox OS build-system baseline. During the
bootstrap phase it still consumes the Redox kernel, target toolchain, relibc,
bootloader, installer, userspace packages, recipes, and image tooling. This is
an implementation fact, not the intended permanent system boundary.

The long-term boundary is:

```text
Redox OS kernel lineage
        │
        ▼
FlashOS kernel boundary
        │
        ├── FlashOS system services and userspace
        ├── FlashOS packaging and image definition
        └── FlashShell product interface
```

The kernel may later be patched, forked, or vendored for FlashOS. If that work
makes later Redox kernel updates impractical, update compatibility is optional.
That future kernel split is a deliberate project step, not part of the current
repository migration.

## 2. Image configuration

[`config/x86_64/flashos.toml`](../config/x86_64/flashos.toml) is the source of
truth for the active image. It includes the inherited base profile, then
defines the FlashOS-specific package set and identity.

The active manifest includes
[`config/flashos-base.toml`](../config/flashos-base.toml), a FlashOS-owned
foundation that retains console display, input, audio, networking, and normal
filesystem paths without inheriting Orbital permissions or legacy `/ui`
symlinks.

The current package set is deliberately small and contains no GUI package:

- `flashshell`
- `coreutils`
- `extrautils`

The image creates `root` and `user`, with `/usr/bin/fsh` as the shell for both
accounts. It also writes:

- a TUI-oriented scheme policy without `orbital` access;
- `/etc/hostname` as `flashos`;
- `/usr/lib/os-release` with the FlashOS 0.1.0 identity;
- `/etc/issue` with the FlashOS version;
- the console init service used to start login sessions.

The root password and blank development-user password in this manifest are
not production credentials. They exist only for the current local image.

## 3. Build and boot path

The build is driven by Make and can run through Podman:

1. `.config` or command-line variables select `ARCH=x86_64` and
   `CONFIG_NAME=flashos`.
2. The prefix stage provides the `x86_64-unknown-redox` compiler and sysroot.
3. Cookbook builds or retrieves the packages selected by the FlashOS manifest.
4. The installer assembles the filesystem and applies FlashOS users and files.
5. The disk stage creates `build/x86_64/flashos/harddrive.img` for QEMU or an
   installed disk and `build/x86_64/flashos/redox-live.iso` for removable
   media.
6. QEMU starts a `q35` machine with UEFI and qualifies the installed-disk
   image over NVMe and the live image over USB mass storage.
7. The console service starts `getty`; login launches `/usr/bin/fsh`.

The current build foundation still has internal files and variables whose
names contain `redox`. They remain where they identify inherited tooling or
formats. User-visible FlashOS paths and titles use the FlashOS name.

The inherited `base` package still carries some functions that the minimal
image may not need, including a development daemon. These are tracked as
pruning candidates. Console display, input, audio, storage, and
hardware-enumeration paths must be retained until their product and physical
hardware dependencies have been verified. TUI-only does not mean audio-free.

## 4. FlashShell integration

FlashShell is developed in-tree at
[`components/flashshell/`](../components/flashshell/). Its primary crates separate
syntax, runtime behavior, platform interfaces, POSIX integration, and the CLI. For deep technical design and scripting references, see the [FlashShell Documentation Index](../components/flashshell/docs/README.md).

The target package recipe at
[`recipes/terminal/flashshell/recipe.toml`](../recipes/terminal/flashshell/recipe.toml)
builds the `fsh` binary from
`components/flashshell/crates/flashshell-cli`. The installed path is
`/usr/bin/fsh`, which matches the shell entries in the image manifest.

Host development and target integration are separate gates:

```sh
cd components/flashshell
cargo test -p flashshell-cli
cargo clippy -p flashshell-cli --all-targets -- -D warnings
redoxer build -p flashshell-cli --bin fsh
```

The first two commands validate the host implementation. The final command
validates the target ABI using the Redox-compatible sysroot.

## 5. Identity and compatibility names

FlashOS product identity is used in the image name, hostname, release files,
virtual-machine title, network boot file, documentation, and public project
surface.

Some names intentionally remain:

| Name | Why it remains |
| :-- | :-- |
| `x86_64-unknown-redox` | current compiler target and ABI |
| `redoxer` | current target build tool |
| `relibc` and `redox_*` crates | current system interfaces |
| selected `redox-*` artefact names | inherited build or disk formats |
| `upstream` remote | attribution, comparison, and optional kernel updates |

Renaming an active interface without replacing it would hide a dependency
rather than remove it. Compatibility names disappear only when FlashOS owns a
working replacement.

---

[← Back: Getting Started](getting-started.md) · [Next: Development →](development.md)
