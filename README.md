# FlashOS

An x86_64 operating system based on the Redox kernel

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="420">
  </picture>
</div>

[Documentation](docs/README.md) · [Getting Started](docs/getting-started.md) · [CI/CD](ci/README.md) · [Changelog](CHANGELOG.md) · [License](LICENSE)

> **Status:** FlashOS is pre-alpha software. Interfaces, package boundaries, and disk formats may change without compatibility guarantees.

## About

FlashOS is a small, independent x86_64 operating-system project based on the Redox kernel. It produces a minimal image focused entirely on a keyboard-first terminal user interface (TUI) and uses [FlashShell](components/flashshell/README.md) (`fsh`) as the login shell for both regular and root accounts. FlashOS is a solo project with its own identity, roadmap, decisions, and releases; it is not an official Redox OS distribution and is not affiliated with or endorsed by the Redox OS nonprofit.

## Current status

| Attribute               | Current baseline                                     |
| ----------------------- | ---------------------------------------------------- |
| **Version**             | 0.1.0                                                |
| **Development status**  | Pre-alpha                                            |
| **Architecture**        | x86_64                                               |
| **Target ABI**          | `x86_64-unknown-redox`                               |
| **Primary test system** | QEMU `q35` with UEFI                                 |
| **Login shell**         | FlashShell at `/usr/bin/fsh`                         |
| **Image profile**       | TUI-only system without a GUI or desktop environment |

Device-specific physical hardware validation is maintained separately in [Hardware Compatibility](docs/hardware.md).

## Project principles

- **TUI-first and TUI-only:** FlashOS concentrates exclusively on a powerful terminal interface without the overhead of graphical desktop stacks.
- **Independent project identity:** Hostname, console issue, release metadata, image names, and system profiles are strictly owned by FlashOS.
- **Verifiable system boundaries:** Changes are verified across distinct quality, target compilation, package cooking, image assembly, QEMU runtime, and physical hardware gates.
- **FlashShell as the primary interface:** The command environment is built around `fsh`, providing safe execution and typed pipelines.
- **Evidence-driven claims:** No support promises or release schedules are claimed without verifiable testing and code evidence.

## Current capabilities

- Minimal x86_64 image containing FlashShell, `coreutils`, and `extrautils`.
- FlashShell (`fsh`) established as the default `/usr/bin/fsh` login shell for all sessions.
- UEFI boot and interactive terminal execution verified in QEMU `q35`.
- Audio driver support (`IHDA`) retained and qualified during runtime tests.
- Self-contained live USB image (`redox-live.iso`) alongside standard installed-disk outputs (`harddrive.img`).
- Fully automated CI/CD pipeline separating host quality gates, containerized clean-room builds, QEMU boot qualification, and SBOM generation.

## Quick start

Ensure you have Git, Make, Podman, and QEMU installed as outlined in [Getting Started](docs/getting-started.md). Then, build the default development disk from the repository root:

```sh
make CONFIG_NAME=flashos all
```

Start the interactive session in QEMU:

```sh
make CONFIG_NAME=flashos qemu
```

For the complete installation guide, live image building, and troubleshooting, consult the [Getting Started Guide](docs/getting-started.md).

## Documentation

The project documentation is organized into focused, specialized guides:

- [General FlashOS documentation](docs/README.md) — System architecture, getting started, local development, verification, hardware compatibility, and public roadmap.
- [FlashShell](components/flashshell/README.md) — The core command shell, scripting language guide, execution rules, and component architecture.
- [CI/CD](ci/README.md) — Automated contracts, local runtime smoke verification, clean-room building, and release delivery.
- [Security](.github/SECURITY.md) — Security policy, supported versions, known evaluation limitations, and vulnerability reporting.
- [Changelog](CHANGELOG.md) — Chronological release notes and public change history.
- [Legal and attribution](NOTICE) — Upstream attribution notices, trademark policy, and project licensing.

## Repository overview

```text
config/             FlashOS TUI base configuration and active x86_64 image profile
components/         In-tree FlashShell Cargo workspace
recipes/            Package recipes including FlashShell, the kernel boundary, and inherited core utilities
ci/                 Python verification contracts and QEMU runtime smoke automation
mk/ and Makefile    Image, package, and emulator build orchestration
src/                Root build-system support crate
docs/               General public project documentation
```

## Project boundaries and upstream relationship

FlashOS is an independent project that currently leverages Redox OS infrastructure as a transitional build foundation. While FlashOS currently consumes the Redox kernel, target toolchain, relibc, and packaging utilities during this bootstrap phase, the intended permanent borrowed boundary is the operating-system kernel exclusively.

Compatibility identifiers such as `x86_64-unknown-redox`, `redoxer`, and `relibc` remain unaltered where they denote an active ABI or technical tool contract. The local `upstream` Git remote tracks [`redox-os/redox`](https://github.com/redox-os/redox) for attribution and comparison. FlashOS may modify its kernel independently and may eventually choose to diverge from upstream kernel updates. For historical reference documents, see [Upstream References](docs/upstream/README.md).

## Contributing and security

FlashOS is developed as an independent solo project. Because of its targeted architectural direction and solo maintainer model, we do not maintain open contribution workflows or require a formal contributing guide. If you are evaluating the operating system or reviewing its implementation, please consult our security guidelines and verification model:

- [Security Policy](.github/SECURITY.md)
- [Verification and Testing](docs/verification.md)

## License and attribution

The root build infrastructure is available under the [MIT License](LICENSE). FlashShell is available under the [Apache License 2.0](components/flashshell/LICENSE). Fetched third-party packages retain their own open-source licenses.

- [Upstream Attribution and Notice](NOTICE)
- [Trademark and Project Identity Policy](TRADEMARK.md)

---

[Documentation index](docs/README.md) · [Next: Getting Started →](docs/getting-started.md)
