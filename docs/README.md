# FlashOS Documentation

[FlashOS](../README.md) › Documentation

This page is the central index for the public FlashOS documentation. It directs users, developers, and evaluators to the appropriate system-wide guide; component-specific details for FlashShell and CI are maintained in their own documentation areas.

## General guides

| Goal                                      | Guide                                                  | Scope                                                                                                          |
| ----------------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| Build and boot FlashOS for the first time | [Getting Started](getting-started.md)                  | Host requirements, repository setup, image building, QEMU execution, and initial session checks                |
| Understand how the system is structured   | [Architecture](architecture.md)                        | System layers, image configuration, build-to-boot flow, component ownership, and upstream boundaries           |
| Work on the repository                    | [Development](development.md)                          | Development environment, repository layout, common workflows, build operations, and documentation rules        |
| Verify changes and built images           | [Verification and Testing](verification.md)            | Verification layers, local qualification steps, QEMU testing, and the relationship between local checks and CI |
| Review physical hardware evidence         | [Hardware Compatibility](hardware.md)                  | Recorded hardware results, validation levels, test methodology, reporting guidance, and media-writing safety   |
| Review the project direction              | [Roadmap](roadmap.md)                                  | Current priorities, longer-term direction, system-boundary evolution, and explicit non-goals                   |
| Interpret inherited upstream material     | [Upstream Reference Documentation](upstream/README.md) | Preserved Redox OS reference documents and the limits of applying upstream observations to FlashOS             |

## Component and automation documentation

Some areas maintain separate documentation because their responsibilities extend beyond the general operating-system guides:

- [FlashShell Overview](../components/flashshell/README.md) — Entry point for FlashShell (`fsh`), its design, usage, and component documentation.
- [FlashShell Documentation Index](../components/flashshell/docs/README.md) — Language, scripting, internal architecture, development, and testing guides for FlashShell.
- [CI/CD Contracts](../ci/README.md) — Technical contracts implemented by the local CI scripts and their integration with hosted workflows.

## Project records and policies

- [Changelog](../CHANGELOG.md) — Public release history and notable changes to the FlashOS source tree.
- [Security Policy](../.github/SECURITY.md) — Supported versions, vulnerability reporting, security scope, and known pre-alpha limitations.
- [License](../LICENSE) — License text covering the root build infrastructure.
- [Notice](../NOTICE) — Upstream attribution and licensing boundaries for inherited and separately licensed components.
- [Trademark and Project Identity](../TRADEMARK.md) — Use of the FlashOS identity and its relationship to upstream names and marks.

## Legacy paths

The following root-level files remain as forwarding pages for existing links and bookmarks:

- [Legacy documentation path](../DOCUMENTATION.md)
- [Legacy setup path](../SETUP.md)
- [Legacy hardware path](../HARDWARE.md)

New documentation should link directly to the current guides listed above rather than to these forwarding files.

---

[← Back to FlashOS](../README.md) · [Next: Getting Started →](getting-started.md)
