<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="420">
  </picture>

<h3>An x86_64 operating system based on the Redox kernel</h3>

<p>
    <a href="https://github.com/ajhahnde/FlashOS/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ajhahnde/FlashOS/ci.yml?branch=main&style=flat-square&label=CI" alt="CI"></a>
    <a href="https://github.com/ajhahnde/FlashOS/actions/workflows/security.yml"><img src="https://img.shields.io/github/actions/workflow/status/ajhahnde/FlashOS/security.yml?branch=main&style=flat-square&label=security" alt="Security"></a>
    <img src="https://img.shields.io/badge/version-0.1.0-f59e0b?style=flat-square" alt="Version 0.1.0">
    <img src="https://img.shields.io/badge/status-pre--alpha-f59e0b?style=flat-square" alt="Pre-alpha">
    <img src="https://img.shields.io/badge/target-x86__64--unknown--redox-lightgrey?style=flat-square" alt="x86_64-unknown-redox">
    <img src="https://img.shields.io/badge/license-MIT%20%2B%20Apache--2.0-lightgrey?style=flat-square" alt="MIT and Apache-2.0">
  </p>

<p>
    <b>README</b> ·
    <a href="docs/README.md"><b>Documentation</b></a> ·
    <a href="docs/getting-started.md"><b>Getting Started</b></a> ·
    <a href="ci/README.md"><b>CI/CD</b></a> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE"><b>License</b></a>
  </p>

</div>

---

## About

FlashOS is a small, independent operating-system project. It produces a
minimal x86_64 image, starts a console session, and currently uses
[FlashShell](components/flashshell/) (`fsh`) as the login shell for both the
regular user and root.

FlashOS is a solo project with its own identity, roadmap, decisions, and
releases. It is not a Redox OS subproject or an official Redox OS
distribution, and it is not affiliated with or endorsed by the Redox OS
nonprofit.

> FlashOS is pre-alpha software. Interfaces, package boundaries, and disk
> formats may change without compatibility guarantees.

## Current system

|                                |                                                      |
| :----------------------------- | :--------------------------------------------------- |
| **Product**                    | FlashOS 0.1.0                                        |
| **Architecture**               | x86_64                                               |
| **Target ABI**                 | `x86_64-unknown-redox`                               |
| **Interface**                  | keyboard-first terminal user interface               |
| **Login shell**                | FlashShell at `/usr/bin/fsh`                         |
| **Image profile**              | TUI-only system without a GUI or desktop environment |
| **Current kernel baseline**    | Redox OS 0.9.0                                       |
| **Primary development target** | QEMU `q35` with UEFI                                 |

The QEMU gate covers both harddrive and live USB image paths, including login,
the `>> ` prompt, and external pipelines. Device-specific validation scope
and results are maintained in [Hardware Compatibility](docs/hardware.md).

## Architecture

FlashOS currently bootstraps from more of the Redox OS system than it intends
to keep permanently:

| Layer                                | Current state                  | Direction                                            |
| :----------------------------------- | :----------------------------- | :--------------------------------------------------- |
| Kernel                               | Redox OS kernel baseline       | Borrowed kernel; a FlashOS-specific fork may diverge |
| Target ABI and libc                  | Redox target and relibc        | Transitional compatibility boundary                  |
| Boot, installer, and package tooling | inherited Redox infrastructure | Transitional build foundation                        |
| System identity and image profile    | FlashOS-owned                  | FlashOS                                              |
| Interactive shell                    | FlashShell                     | FlashOS                                              |

The intended long-term borrowed boundary is the kernel only. Names such as
`x86_64-unknown-redox`, `redoxer`, `relibc`, and inherited package identifiers
remain where they describe a real ABI or tool interface. They are compatibility
names, not product branding.

## Features

- **FlashShell by default.** `fsh` is the login shell for the development
  accounts and the main product interface.
- **TUI-only product.** Orbital, COSMIC, X11, Wayland, GUI applications, and
  the graphical installer are outside the FlashOS product scope.
- **Minimal x86_64 image.** The active profile contains FlashShell,
  `coreutils`, and `extrautils` without a desktop stack.
- **UEFI QEMU workflow.** The primary development machine is QEMU `q35`
  with edk2 firmware.
- **Independent identity.** Hostname, release metadata, console issue, build
  paths, and virtual-machine names identify FlashOS.
- **Upstream traceability.** The Redox OS origin remains documented and
  available through the `upstream` Git remote.
- **Kernel freedom.** Future kernel changes do not have to preserve the
  ability to consume later Redox kernel updates.
- **Qualified delivery.** GitHub Actions separates host quality checks,
  containerized image construction, immutable artefact promotion, QEMU boot
  qualification, supply-chain policy, and tagged releases.

## Quick start

Install the platform dependencies and create the local build configuration as
described in [Getting Started](docs/getting-started.md), then build the FlashOS development disk:

```sh
make CONFIG_NAME=flashos all
```

Build the removable-media live image separately:

```sh
make CONFIG_NAME=flashos build/x86_64/flashos/redox-live.iso
```

The resulting images are:

```text
build/x86_64/flashos/harddrive.img   QEMU or installed-disk image
build/x86_64/flashos/redox-live.iso  self-contained USB live image
```

Start the development disk in QEMU:

```sh
make CONFIG_NAME=flashos qemu
```

Use the live image, not `harddrive.img`, when qualifying removable USB media.
The live bootloader copies the filesystem into memory before FlashOS starts.

The development image currently provides the `user` account with a blank
password. Its credentials are for local development only.

## Repository layout

```text
config/flashos-base.toml         TUI base without Orbital or legacy /ui paths
config/x86_64/flashos.toml       FlashOS image, identity, users, and services
components/flashshell/           FlashShell workspace
recipes/terminal/flashshell/     target recipe that installs /usr/bin/fsh
recipes/core/kernel/             current borrowed-kernel boundary
recipes/                         transitional system package recipes
ci/ and .github/workflows/       CI contracts, clean-room build, and delivery
mk/ and Makefile                 image, package, and emulator build logic
src/                             build-system support tools
docs/upstream/                   retained Redox OS reference documents
```

A deeper explanation of the system and build path is in
[Documentation](docs/README.md).

## Documentation and project links

- **[General FlashOS documentation](docs/README.md)**
  - [Getting Started](docs/getting-started.md)
  - [Architecture](docs/architecture.md)
  - [Development](docs/development.md)
  - [Verification](docs/verification.md)
  - [Hardware Compatibility](docs/hardware.md)
  - [Roadmap](docs/roadmap.md)
- **[FlashShell](components/flashshell/README.md)**
  - [FlashShell Documentation Index](components/flashshell/docs/README.md)
- **[CI and Verification](ci/README.md)**
- **Project governance and security**
  - [Changelog](CHANGELOG.md)
  - [Security Policy](.github/SECURITY.md)
- **Legal and attribution**
  - [License](LICENSE)
  - [Upstream Attribution (NOTICE)](NOTICE)
  - [Trademark and Project Identity](TRADEMARK.md)

## Upstream and license

The `upstream` Git remote tracks
[`redox-os/redox`](https://github.com/redox-os/redox) for attribution,
comparison, and optional kernel updates. FlashOS may modify its kernel
independently and may eventually stop accepting Redox kernel updates.

The inherited root build system is available under the
[MIT License](LICENSE). FlashShell is available under the
[Apache License 2.0](components/flashshell/LICENSE). Fetched packages retain
their own licenses. See [NOTICE](NOTICE) for attribution.

---

[Next: Documentation →](docs/README.md)
