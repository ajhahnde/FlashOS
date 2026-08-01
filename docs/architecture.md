# Architecture

[FlashOS](../README.md) › [Documentation](README.md) › Architecture

This document describes the structural architecture of FlashOS, including system layers, build-to-boot execution sequencing, image profiles, and technical boundaries between FlashOS and inherited upstream components. It is intended for software architects, developers, and maintainers working across system components and packaging layers. The former AArch64 implementation is preserved separately in the archived `FlashOS-old` repository and does not apply to this architecture.

## On this page

- [Architectural goals](#architectural-goals)
- [System context](#system-context)
- [Current system layers](#current-system-layers)
- [Component boundaries](#component-boundaries)
- [Image configuration](#image-configuration)
- [Build-to-boot flow](#build-to-boot-flow)
- [FlashShell integration](#flashshell-integration)
- [Compatibility and upstream boundaries](#compatibility-and-upstream-boundaries)
- [Architectural non-goals](#architectural-non-goals)
- [Sources of truth](#sources-of-truth)

## Architectural goals

FlashOS engineering centers around four core architectural tenets:
- **Small, compact TUI system:** Providing an efficient, keyboard-driven operating environment free from visual windowing overhead.
- **Clear component ownership and boundaries:** Explicitly distinguishing FlashOS-owned user surface, configuration, and shell implementations from transitional build-system infrastructure.
- **Verifiable image compilation:** Producing reproducible disk and live memory images backed by cryptographic SBOMs, SHA-256 digests, and automated runtime qualification.
- **FlashShell as the primary interface:** Deploying `fsh` as the exclusive console command language and execution engine for all interactive and automated logins.

## System context

At a high level, the FlashOS engineering workflow traverses six sequential stages from compilation to interactive operational readiness:

```text
build host
→ image build system
→ bootable FlashOS image
→ kernel and system services
→ console login
→ FlashShell
```

The host toolchain processes recipes inside a clean container to generate bootable disk artifacts; once launched on virtual or physical machine hardware, underlying kernel and system daemons initialize terminal consoles, prompting user authentication before launching FlashShell.

## Current system layers

During the current bootstrap phase, FlashOS utilizes proven Redox OS system infrastructure while steadily expanding independent project ownership:

| Layer | Current implementation | FlashOS ownership | Long-term direction |
|---|---|---|---|
| **Kernel** | Redox OS kernel baseline | Borrowed dependency | Retain as a borrowed kernel; an independent FlashOS fork may eventually diverge |
| **Target ABI and libc** | `x86_64-unknown-redox` target and `relibc` | Borrowed compatibility layer | Transitional compatibility boundary during system bootstrap |
| **Boot and image tooling** | Inherited Redox bootloader and installer | Transitional infrastructure | Transitional foundation for assembling bootable filesystem images |
| **System profile and identity** | FlashOS x86_64 manifests (`flashos.toml`) | Fully owned | Permanent independent FlashOS user and configuration domain |
| **Interactive shell** | FlashShell (`/usr/bin/fsh`) | Fully owned | Permanent core FlashOS command execution language and interface |

## Component boundaries

Each operational subsystem maintains defined organizational responsibilities within the repository structure:
- **Kernel (`recipes/core/kernel/`):** Establishes basic hardware virtualization, process scheduling, system calls, and device drivers.
- **Target ABI and libc (`prefix/`):** Provides the standard C library runtime (`relibc`) and compiler target specifications required to cross-compile userspace binaries.
- **Boot and image tooling (`mk/`, `scripts/`):** Drives disk formatting, live ISO staging, RedoxFS partition assembly, and UEFI bootloader installation.
- **System profile (`config/`):** Declares required userspace package sets, user accounts, networking schemes, and console initialization rules.
- **Userspace (`recipes/`):** Contains essential GNU/Linux terminal utility replacements (`coreutils`, `extrautils`) and system libraries.
- **FlashShell (`components/flashshell/`):** Implements language syntax, parsing ASTs, pipeline execution, and terminal line editing.
- **CI verification (`ci/`, `.github/workflows/`):** Guards architecture invariants by running strict profile lints and headless QEMU serial smoke tests.

## Image configuration

The active system image is driven by two FlashOS-owned configuration files that replace graphical desktop defaults:
- [`config/flashos-base.toml`](../config/flashos-base.toml) defines the foundational TUI baseline. It preserves essential framebuffer display, input keyboard, audio controller, networking, and standard filesystem access while strictly stripping out `orbital` display scheme permissions and legacy `/ui` graphical compatibility symlinks.
- [`config/x86_64/flashos.toml`](../config/x86_64/flashos.toml) inherits the TUI base and specifies the exact package closure and runtime identity.

The configured package set is minimal by design, excluding all windowing toolkits and GUI clients:
- `flashshell`
- `coreutils`
- `extrautils`

When compiled, the installer applies independent project branding and configuration directly into the filesystem:
- Configures `/usr/bin/fsh` as the exclusive login shell for both `root` and `user`.
- Writes system hostname `/etc/hostname` as `flashos`.
- Populates `/usr/lib/os-release` and `/etc/issue` with version 0.1.0 identity strings.
- Sets up console init daemons to launch interactive terminal login prompts (`getty`).

## Build-to-boot flow

The operational transition from host build compilation to an active terminal prompt follows a clear execution sequence:
1. Local variables or root `.config` specify `ARCH=x86_64` and `CONFIG_NAME=flashos`.
2. The compiler prefix stage builds or restores the `x86_64-unknown-redox` cross-compiler and target sysroot.
3. The package cookbook cooks or fetches binary artifacts for FlashShell and selected core utilities.
4. The image installer constructs the RedoxFS partition, installs package binaries, and configures users and system identity files.
5. Make produces `build/x86_64/flashos/harddrive.img` (installed disk format) and `build/x86_64/flashos/redox-live.iso` (self-contained removable media format).
6. When launched via QEMU or physical firmware, UEFI executes the bootloader, loading the operating system kernel into memory.
7. Kernel initialization triggers console service startup; authentication at the login prompt launches `/usr/bin/fsh` and displays the `>> ` prompt.

Detailed building commands and troubleshooting steps remain focused inside [Getting Started](getting-started.md).

## FlashShell integration

FlashShell is developed directly inside the repository tree as an independent Cargo workspace located at [`components/flashshell/`](../components/flashshell/). Its architectural separation of syntax parsing, runtime evaluation, and platform interfaces is thoroughly documented in the [FlashShell Documentation Index](../components/flashshell/docs/README.md).

To embed the shell into the operating system image, the target package recipe at [`recipes/terminal/flashshell/recipe.toml`](../recipes/terminal/flashshell/recipe.toml) builds the executable from `components/flashshell/crates/flashshell-cli` and installs it to `/usr/bin/fsh`.

Developers maintain a clear separation between host-level component validation and cross-target system compilation:

```sh
cd components/flashshell
cargo test -p flashshell-cli
cargo clippy -p flashshell-cli --all-targets -- -D warnings
redoxer build -p flashshell-cli --bin fsh
```

The standard `cargo` commands confirm core language logic and safety on the host, while `redoxer build` verifies target ABI binary compilation against the Redox sysroot.

## Compatibility and upstream boundaries

While user-facing identity, network boot filenames, QEMU window titles, and documentation strictly reflect the FlashOS brand, specific technical identifiers inherited from Redox OS are preserved deliberately:

| Name | Why it remains |
|---|---|
| `x86_64-unknown-redox` | Represents the actual cross-compiler target triple and compiled toolchain ABI |
| `redoxer` | Identifies the containerized cross-compilation execution wrapper |
| `relibc` and `redox_*` crates | Designates required underlying C standard libraries and kernel interface bindings |
| Selected `redox-*` artifact names | Identifies inherited filesystem tools, Disk layouts, or live ISO branding scripts |
| `upstream` remote | Facilitates proper legal attribution, diff comparisons, and optional kernel syncing |

Attempting to rename an active binary interface or target triple without engineering an independent replacement would obscure technical dependencies rather than remove them. Compatibility identifiers remain until FlashOS implements native architectural substitutes.

## Architectural non-goals

To protect the maintainer model and preserve operational clarity, several features are explicitly rejected as architectural non-goals:
- **No graphical desktop environment:** Desktop environments, window managers (Orbital, COSMIC, X11, Wayland), and GUI client software are permanently out of scope.
- **No POSIX shell compliance:** FlashShell prioritizes predictable, typed value streams and structured job control over backward compatibility with POSIX or `/bin/sh` word-splitting syntax.
- **No unverified hardware expansion:** We avoid making broad, generalized physical device support claims without exact read-only identification, live testing, and published qualification evidence.

## Sources of truth

When inspecting or extending system contracts, rely directly on the primary source-of-truth configuration files:
- **TUI Base Configuration:** [`config/flashos-base.toml`](../config/flashos-base.toml)
- **Active Image Profile:** [`config/x86_64/flashos.toml`](../config/x86_64/flashos.toml)
- **FlashShell Workspace:** [`components/flashshell/`](../components/flashshell/)
- **FlashShell Recipe:** [`recipes/terminal/flashshell/recipe.toml`](../recipes/terminal/flashshell/recipe.toml)
- **Kernel Boundary Recipe:** [`recipes/core/kernel/`](../recipes/core/kernel/)

---

[← Previous: Getting Started](getting-started.md) · [Documentation index](README.md) · [Next: Development →](development.md)
