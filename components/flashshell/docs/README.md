# FlashShell Documentation Index

[FlashOS](../../../README.md) › [FlashShell](../README.md) › [Documentation](README.md) › Index

Welcome to the detailed technical documentation index for FlashShell (`fsh`), a modern command shell and structured scripting language written in Rust. This directory provides comprehensive language guides, architectural breakdowns, and testing manuals for developers working on or embedding the shell. It serves as the authoritative technical reference for all components under `components/flashshell/`.

## Overview and scope

These guides focus exclusively on the mechanics, syntax, runtime semantics, and crate architecture of FlashShell. While FlashShell serves as the official console login shell for FlashOS, its core evaluation engine functions independently of any single operating system and can be compiled, tested, and utilized on standard POSIX host systems (macOS and Linux).

## Documentation map

```text
components/flashshell/
├── README.md
└── docs/
    ├── README.md
    ├── language-guide.md
    ├── scripting.md
    ├── architecture.md
    └── development.md
```

## Core documentation topics

- [Language Guide](language-guide.md) — Comprehensive explanation of core syntax rules, immutable/mutable bindings, predictable expansion semantics, explicit globbing, expressions, and typed value streams.
- [Scripting and Execution](scripting.md) — Standalone `.fsh` scripting, symmetry between interactive prompts and scripts, direct external process execution (`^`), command substitution, job lifecycle management, and non-exceptional status handling.
- [Architecture and Crates](architecture.md) — Detailed internal layout covering `syntax`, `runtime`, `platform`, `platform-posix`, and `cli` crate boundaries, dependency flow, and platform abstraction layers.
- [Development and Testing](development.md) — Host toolchain setup, Cargo build workflows, unit and integration suites, rustdoc generation, golden grammar manifests, and libFuzzer campaigns.

## Verification resources

Specialized test harnesses and normative corpora maintain focused technical READMEs directly inside their verification subdirectories:
- [Fuzz Targets](../fuzz/README.md) — Guidance on executing bounded smoke campaigns (`./fuzz/run-smoke.sh`) for grammar and lexer fuzz targets.
- [End-to-End Tests](../tests/e2e/README.md) — Black-box and pseudoterminal (PTY) interactive shell execution fixtures.
- [Test Fixtures](../tests/fixtures/README.md) — Dedicated shell-free Rust child helper programs used during POSIX adapter and process interaction tests.
- [Grammar Golden Corpus](../tests/golden/grammar/README.md) — Normative inventory and tab-delimited classification manifest for v0.1 grammar testing.
- [Lexical Golden Corpus](../tests/golden/lexical/README.md) — Normative inventory and manifest defining complete, incomplete, and invalid lexical contracts.

## Relationship to FlashOS documentation

When exploring system integration beyond standard shell parsing and execution:
- To see how `fsh` builds into the operating system image, consult the [FlashOS Architecture Guide](../../../docs/architecture.md) and the packaging recipe at [`recipes/terminal/flashshell/recipe.toml`](../../../recipes/terminal/flashshell/recipe.toml).
- For complete OS disk building and virtual machine evaluation, return to [FlashOS Getting Started](../../../docs/getting-started.md).

---

[← Back to FlashShell Overview](../README.md) · [FlashShell documentation](README.md) · [Next: Language Guide →](language-guide.md)
