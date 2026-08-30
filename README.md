<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="420">
  </picture>

  <p>
    <strong>A keyboard-first operating system with one structured language for commands and automation.</strong>
  </p>

  <p>
    <a href="https://github.com/ajhahnde/FlashOS/actions/workflows/main-qualification.yml">
      <img src="https://github.com/ajhahnde/FlashOS/actions/workflows/main-qualification.yml/badge.svg?branch=main&amp;event=push" alt="Main verified">
    </a>
    <img src="https://img.shields.io/badge/Version-0.2.0-f59e0b?style=square" alt="FlashOS 0.2.0">
    <img src="https://img.shields.io/badge/Status-pre--alpha-f59e0b?style=square" alt="Pre-alpha">
    <img src="https://img.shields.io/badge/Target-x86__64--unknown--redox-lightgrey?style=square" alt="x86_64-unknown-redox">
  </p>

  <p>
    <a href="docs/README.md"><strong>Product Guide</strong></a> ·
    <a href="docs/getting-started.md"><strong>Getting Started</strong></a> ·
    <a href="components/flash/docs/by-example.md"><strong>Flash by Example</strong></a> ·
    <a href="docs/aboutme.md"><strong>About Me</strong></a> ·
    <a href="CONTRIBUTING.md"><strong>Contributing</strong></a> ·
    <a href="https://github.com/ajhahnde/FlashOS/releases"><strong>Releases</strong></a> ·
    <a href=".github/SECURITY.md"><strong>Security</strong></a>
  </p>
</div>

FlashOS is an experimental, terminal-first operating system for x86_64. Its shell is [Flash](components/flash/README.md), a non-POSIX language used both at the prompt and in `.fsh` automation. Commands and scripts share the same syntax, values, process handling, statuses, and jobs.

External programs still exchange bytes. Flash makes the transition to structured values visible:

```fsh
^printf '[{"name":"build","active":true},{"name":"deploy","active":false}]' \
| from json array \
| where {|item| $item.active} \
| select name \
| collect \
| to json \
| ^cat
```

This is the checked-in [`json-boundary.fsh`](components/flash/examples/json-boundary.fsh) example. It prints `[{"name":"build"}]`. The conversion steps matter: Flash does not quietly treat bytes, text, values, and source code as the same thing.

## What ships today

| Area | Current boundary |
| --- | --- |
| Architecture | x86_64 |
| Target ABI | `x86_64-unknown-redox` |
| User environment | Keyboard-first, text-based interface |
| Primary interface | Flash at `/usr/bin/fsh` |
| Flash contract | Flash 1.0 component release; availability in a FlashOS version or image is qualified separately |
| System API | Experimental schema 1 `system.describe` query through `/usr/bin/flashos-system` |
| Evaluation baseline | QEMU `q35` with UEFI firmware; physical results are device- and artifact-specific |
| Maturity | Pre-alpha evaluation software, without production security or support guarantees |

FlashOS currently uses the Redox kernel and other parts of the Redox ecosystem. The product configuration, Flash integration, documentation, tests, and roadmap are maintained here. FlashOS is not an official Redox OS distribution and is not affiliated with or endorsed by the Redox OS nonprofit.

## Why Flash belongs in the system

Flash keeps structured values intact until a program asks for a conversion. External executables receive arguments directly; Flash does not translate its source through another shell. A nonzero exit remains a normal `Status`, while `check` turns that status into an error where failure should stop the current flow.

The result is one language for exploring the system interactively and for writing automation that can be checked into the repository. FlashOS uses it as the login shell and, where `fsh` is already available, for public project automation.

FlashOS now has one deliberately small experimental system API query and a
structured Flash consumer. It is not yet a stable system API, service
interface, or dedicated TUI. [FlashOS System API](docs/system-api.md) documents
the shipped boundary, [Flash and FlashOS](docs/flash.md) explains the broader
idea, and the [Roadmap](docs/roadmap.md) shows what remains future work.

## Quick start

From an existing clone, review the planned host changes, run the repository setup, and verify the environment:

```bash
./setup.sh --plan
./setup.sh
./setup.sh --check
```

Build and boot the development image:

```bash
./build.fsh -c flashos all
./build.fsh -c flashos qemu
```

The [Getting Started Guide](docs/getting-started.md) covers host requirements, configuration, image files, login details, live images, troubleshooting, and writing an image to physical media.

## Product guide

- [Getting Started](docs/getting-started.md) — Build, boot, log in, and diagnose the first QEMU session.
- [Flash and FlashOS](docs/flash.md) — Understand the shipped system integration and future interaction direction.
- [FlashOS System API](docs/system-api.md) — Query the experimental local system contract from Flash or another local consumer.
- [Flash by Example](components/flash/docs/by-example.md) — Run small checked programs, then continue to the complete [Flash documentation](components/flash/docs/README.md).
- [Architecture](docs/architecture.md) — Follow the current build-to-boot layers and ownership boundaries.
- [Roadmap](docs/roadmap.md) — See what is being finished now and what may follow.
- [About Me](docs/aboutme.md) — Personal background, motivation, and the working approach behind FlashOS.
- [Contributing](CONTRIBUTING.md) — Report issues, discuss proposals, prepare changes, and run reproducible checks.
- [Complete Documentation Index](docs/README.md) — Find every guide, policy, record, and focused technical reference.

## Verification and evidence

Different checks answer different questions. Source checks do not prove target behavior, target compilation does not prove that an image works, and a QEMU run says nothing about a particular physical machine. CI selects checks based on the files changed. Release candidates also record the source, images, manifests, checksums, SBOMs, provenance, and runtime results that belong together.

Start with [Verification and Testing](docs/verification.md). [CI/CD Contracts](ci/README.md) documents the scripts and hosted workflows in detail. Results from physical machines are recorded in [Hardware Compatibility](docs/hardware.md).

## Issues and security

The [contributor guide](CONTRIBUTING.md) links to templates for bugs, documentation problems, hardware reports, and proposals. This is a one-person project, so response, review, acceptance, and release times cannot be guaranteed.

Do not disclose suspected vulnerabilities in a public issue. Follow the private reporting instructions and evaluation limits in the [Security Policy](.github/SECURITY.md).

## License and attribution

Original FlashOS material is available under the primary [FlashOS MIT License](LICENSE) unless a file or component states otherwise. Flash carries a [component-local license](components/flash/LICENSE); inherited Redox infrastructure, the kernel, packages, and other third-party material retain their applicable licenses and notices.

For attribution and project-name details, see [NOTICE](NOTICE), the [Trademark and Project Identity Policy](TRADEMARK.md), and [Upstream References](docs/upstream/README.md).
