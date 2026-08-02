# FlashShell Documentation

[FlashOS](../../../README.md) › [FlashShell](../README.md) › Documentation

This page is the central index for the public FlashShell documentation. It directs users, script authors, and component developers to the appropriate guide; system-wide FlashOS build, image, verification, and hardware documentation remains under the main [FlashOS documentation](../../../docs/README.md).

> **Project status:** FlashOS as a complete operating system remains pre-alpha software. However, these FlashShell component guides describe the intended stable FlashShell v1.0 contract. Note that not every v1 feature is automatically available in every current FlashOS image or on every target platform, and successful execution on a Linux or macOS development host is not automatic proof of FlashOS target support.

## Guides

| Goal                           | Guide                               | Scope                                                                                                                 |
| ------------------------------ | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Learn the FlashShell language  | [Language Guide](language-guide.md) | Source structure, values, bindings, expressions, commands, expansion rules, and the pipeline model                    |
| Create and run `.fsh` programs | [Scripting](scripting.md)           | Script execution, command-line modes, external processes, redirections, statuses, jobs, and portability boundaries    |
| Understand the implementation  | [Architecture](architecture.md)     | Workspace crates, dependency direction, parser and runtime responsibilities, platform interfaces, and CLI integration |
| Modify and verify FlashShell   | [Development](development.md)       | Toolchain setup, build commands, formatting, linting, tests, golden corpora, fuzzing, and local Rustdoc generation    |

Readers who are new to FlashShell should begin with the [component overview](../README.md), continue with the [Language Guide](language-guide.md), and then use the [Scripting Guide](scripting.md) for practical program execution. Developers changing the implementation should also read the [Architecture](architecture.md) and [Development](development.md) guides.

## Documentation boundaries

Each guide has a distinct responsibility:

- The [FlashShell overview](../README.md) introduces the component, its role in FlashOS, its implementation boundaries, and the available documentation.
- The [Language Guide](language-guide.md) documents language concepts and evaluation semantics. It is not the primary reference for build procedures or internal crate organization.
- The [Scripting Guide](scripting.md) covers practical `.fsh` execution and interaction with external programs. It does not duplicate the complete language reference.
- The [Architecture Guide](architecture.md) explains internal component boundaries and data flow rather than general FlashOS system architecture.
- The [Development Guide](development.md) owns component-specific build and verification procedures. Repository-wide verification layers remain documented in [FlashOS Verification](../../../docs/verification.md).

When documentation and implementation appear to disagree, inspect the current source, tests, and configuration before relying on a behavior or changing a public claim.

## Supporting technical references

Focused implementation and verification areas maintain narrower README files beside the corresponding source or fixtures:

- [Cargo workspace manifest](../Cargo.toml) — Workspace membership and shared package metadata.
- [Fuzz targets](../fuzz/README.md) — Lexer and parser fuzz inputs, smoke campaigns, and corpus handling.
- [End-to-end tests](../tests/e2e/README.md) — Location of black-box and pseudoterminal test fixtures.
- [Test fixtures](../tests/fixtures/README.md) — Rust child programs used to observe process, descriptor, status, and stream behavior.
- [Grammar golden corpus](../tests/golden/grammar/README.md) — Parser fixture inventory and expected classifications.
- [Lexical golden corpus](../tests/golden/lexical/README.md) — Lexer fixture inventory and completeness classifications.

These references document specific test or implementation contracts. The [Development Guide](development.md) remains the main entry point for deciding which checks to run and what their results establish.

## Related FlashOS documentation

FlashShell is developed as a component of FlashOS, but several integration topics belong to the system-wide documentation:

- [Getting Started](../../../docs/getting-started.md) — Build a FlashOS image, boot it in QEMU, and reach the initial shell session.
- [FlashOS Architecture](../../../docs/architecture.md) — Understand system layers, image configuration, package integration, and component boundaries.
- [FlashOS Development](../../../docs/development.md) — Work with the repository, build system, configuration profiles, and general development workflow.
- [Verification and Testing](../../../docs/verification.md) — Distinguish host checks, target compilation, package and image construction, QEMU qualification, and physical hardware evidence.

---

[← Back to FlashShell Overview](../README.md) · [Next: Language Guide →](language-guide.md)
