# FlashShell Architecture and Layout

This document details the internal layout, crate structure, and component boundaries of FlashShell. This document is part of the ongoing public documentation restructuring.

## Crate Layout

FlashShell is developed as a nested Cargo workspace under `components/flashshell/`. The primary crates separate syntax, runtime behavior, platform interfaces, POSIX integration, and the command-line entry point:

```text
crates/flashshell-syntax/           spans, lexer, parser, AST, diagnostics, formatter
crates/flashshell-runtime/          values, scopes, evaluation
crates/flashshell-platform/         platform trait and portable process contracts
crates/flashshell-platform-posix/   macOS/Linux process, fd, signal, terminal adapter
crates/flashshell-cli/              the fsh binary
```

## Dependency Direction and Boundaries

Dependency direction across the internal crates is strict:

```text
syntax ← runtime ← cli
```

Platform adapters are abstracted behind the platform contract, ensuring that core parsing and evaluation remain decoupled from OS-specific process, signal, and descriptor implementations.

---

[← Back: Scripting and Execution](scripting.md) · [Next: Development and Testing →](development.md)
