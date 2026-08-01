# FlashOS Documentation

[FlashOS](../README.md) › Documentation

Welcome to the central documentation index for FlashOS. This guide serves as the top-level directory for understanding system architecture, establishing build workflows, running quality verifications, and reviewing hardware compatibility. It is intended for all users, developers, and evaluators navigating the project repository.

## Start here

If you are new to FlashOS, choose your starting point based on your immediate goal:
- **Try out FlashOS:** Follow [Getting Started](getting-started.md) to install dependencies, compile your first disk image, and boot into a live QEMU terminal session.
- **Understand the system:** Read [Architecture](architecture.md) to understand the TUI-only project scope, current Redox kernel boundaries, and image configuration layers.
- **Develop on the project:** Consult [Development](development.md) for workspace layout details, compilation wrappers, and daily developer practices.
- **Check quality and hardware status:** Visit [Verification and Testing](verification.md) and [Hardware Compatibility](hardware.md) to learn how release candidates and physical machines are validated.

## Documentation paths

| Goal | Start with |
|---|---|
| Build and run FlashOS | [Getting Started](getting-started.md) |
| Understand the system | [Architecture](architecture.md) |
| Work on the repository | [Development](development.md) |
| Reproduce quality checks | [Verification](verification.md) |
| Check hardware support | [Hardware Compatibility](hardware.md) |

## Documentation map

```text
README.md
└── docs/README.md
    ├── getting-started.md
    ├── architecture.md
    ├── development.md
    ├── verification.md
    ├── hardware.md
    ├── roadmap.md
    └── upstream/README.md
```

## General FlashOS guides

- [Getting Started](getting-started.md) — Prerequisites, repository setup, build configuration, QEMU boot instructions, and initial login verification.
- [Architecture](architecture.md) — Architectural goals, system context layers, build-to-boot workflow, FlashShell integration, and long-term boundary definitions.
- [Development](development.md) — Local developer tools, source layout, target compilation commands, generated disk artifacts, and documentation rules.
- [Verification and Testing](verification.md) — Layered testing methodology, CI-equivalent local python gates, QEMU smoke execution, and GitHub Actions alignment.
- [Hardware Compatibility](hardware.md) — Verification criteria, testing validation levels, physical device test matrix, and reporting templates.
- [Roadmap](roadmap.md) — Public product evolution, permanent kernel boundaries, TUI package pruning goals, and production security direction.

## Component documentation

Specialized subsystems and automated testing contracts maintain independent documentation indices:
- [FlashShell Overview](../components/flashshell/README.md) — Product introduction and design principles for the primary terminal interface.
- [FlashShell Documentation Index](../components/flashshell/docs/README.md) — Deep technical reference covering language grammar, scripting rules, runtime AST evaluation, and workspace testing.
- [CI/CD Contracts](../ci/README.md) — Technical details of automated verification boundaries, Docker clean-room compilation, and python smoke test scripts.

## Project and policy documents

- [Security Policy](../.github/SECURITY.md) — Coordinated vulnerability disclosure, evaluation credential limits, and supported release tags.
- [Changelog](../CHANGELOG.md) — Complete release note history and tracked repository modifications.
- [Upstream Attribution Notice](../NOTICE) and [Trademark Policy](../TRADEMARK.md) — Licensing and legal guidelines.

## Upstream references

- [Upstream Reference Documentation](upstream/README.md) — Preserved historical documents from the Redox OS origin, retained for driver insights and attribution without serving as active FlashOS support promises.

## Legacy compatibility paths

To preserve compatibility with existing bookmarks and external documentation references, short forwarding files remain in the project root:
- [Legacy Documentation Forwarder](../DOCUMENTATION.md)
- [Legacy Setup Forwarder](../SETUP.md)
- [Legacy Hardware Forwarder](../HARDWARE.md)

These files serve purely as redirection endpoints and should not be used as normal starting points for new documentation searches.

---

[← Back to Main README](../README.md) · [Documentation index](README.md) · [Next: Getting Started →](getting-started.md)
