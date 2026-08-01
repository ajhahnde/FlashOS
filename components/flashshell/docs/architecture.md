# Architecture and Crates

[FlashOS](../../../README.md) › [FlashShell](../README.md) › [Documentation](README.md) › Architecture

This document details the software architecture, modular crate decomposition, dependency direction, and operating system platform boundaries of FlashShell. It is intended for systems architects, core maintainers, and developers extending parsers, built-in commands, or platform abstraction adapters. For practical compilation steps and test harness usage, refer to the development guide.

## On this page

- [Design goals](#design-goals)
- [Workspace structure](#workspace-structure)
- [Syntax crate](#syntax-crate)
- [Runtime crate](#runtime-crate)
- [Platform interfaces and POSIX adapter](#platform-interfaces-and-posix-adapter)
- [CLI and shell front end](#cli-and-shell-front-end)
- [Dependency direction and isolation](#dependency-direction-and-isolation)
- [Integration into FlashOS](#integration-into-flashos)
- [Related documentation](#related-documentation)

## Design goals

The structural architecture of FlashShell focuses on three core software engineering goals:
- **Strict modular isolation:** Decoupling lexical tokenization and abstract syntax tree (AST) grammar from evaluation state and operating system execution mechanics.
- **Memory safety and robustness:** Implemented entirely in safe Rust, preventing buffer overflow vulnerabilities and undefined behavior across pipeline streaming and signal handling.
- **Portable OS abstraction:** Isolating platform process spawning, file descriptors, and terminal management behind clear trait definitions to facilitate cross-OS compilation and clean test mocking.

## Workspace structure

FlashShell lives as an isolated Cargo workspace rooted at `components/flashshell/`. The workspace divides responsibilities across five foundational crates:

```text
components/flashshell/crates/
├── flashshell-syntax/           spans, lexer, parser, AST, diagnostics, formatter
├── flashshell-runtime/          values, scopes, evaluation engine, internal built-ins
├── flashshell-platform/         platform trait and portable process contracts
├── flashshell-platform-posix/   macOS/Linux process, fd, signal, terminal adapter
└── flashshell-cli/              the fsh binary, interactive line editing, prompt state
```

## Syntax crate

The `flashshell-syntax` crate manages all frontend linguistic processing:
- Implements lossless UTF-8 lexical scanning and recursive AST parsing.
- Maintains byte-accurate source span tracking (`Span`) across all syntax nodes and literal tokens.
- Generates rich compiler-grade diagnostic reports for grammar failures.
- Drives the canonical code formatter from identical AST structures without maintaining competing tokenizers or secondary grammars.

## Runtime crate

The `flashshell-runtime` crate encapsulates core command evaluation and memory state:
- Manages variable lexical scoping, value bindings, closure capture environments, and execution status tracking.
- Implements first-class data representation types (strings, integers, booleans, lists, records, and pipeline stream carriers).
- Contains internal typed pipeline command implementations (`ls`, `where`, `select`, `each`, `from json`, `decode`), processing data lazily without serializing text across stages.

## Platform interfaces and POSIX adapter

To ensure runtime evaluation remains platform-independent, system interaction divides across an interface abstraction:
- **`flashshell-platform`:** Defines portable asynchronous execution traits, standard descriptor abstractions, and job lifecycle completion records.
- **`flashshell-platform-posix`:** Provides concrete implementations for macOS and Linux host environments. It utilizes modern underlying system bindings (such as `rustix` and `fd-lock`) to handle process group creation, signal blocking (`SIGINT`, `SIGTSTP`), file descriptor manipulation, and terminal foreground ownership transfer (`tcsetpgrp`).

## CLI and shell front end

The `flashshell-cli` crate synthesizes the underlying crates into the executable terminal interface (`fsh`):
- Coordinates command-line flag parsing (`--no-config`, `--no-history`, script file invocation).
- Integrates interactive terminal line editing and prompt presentation using `reedline` and `crossterm`.
- Manages transactional startup user configuration loading, gracefully retreating into a clean safe mode prompt upon discovering evaluation errors in startup configuration scripts.
- Handles persistent searchable history storage, multiline continuation prompts, and autocompletion rendering.

## Dependency direction and isolation

Internal workspace dependency architecture enforces a strict unidirectional hierarchy to prevent cyclical logic or evaluation abstraction leakage:

```text
syntax ← runtime ← cli
```

The syntax parsing engine remains completely ignorant of evaluation runtimes or operating system primitives. The evaluation runtime communicates with execution infrastructure solely through `flashshell-platform` contracts, while `flashshell-cli` binds concrete POSIX platform adapters during binary link assembly.

## Integration into FlashOS

While developed in-tree as an independent standalone workspace, FlashShell integrates seamlessly into the compiled FlashOS system image:
- The operating system package recipe located at [`recipes/terminal/flashshell/recipe.toml`](../../../recipes/terminal/flashshell/recipe.toml) cross-compiles `flashshell-cli` using the `x86_64-unknown-redox` toolchain.
- The assembled binary is promoted to `/usr/bin/fsh` inside the root filesystem.
- FlashOS TUI configuration profiles (`config/flashos-base.toml` and `config/x86_64/flashos.toml`) establish `/usr/bin/fsh` as the mandatory default login shell for all authentication sessions.

## Related documentation

- [Development and Testing](development.md) — Comprehensive guide covering workspace compilation, test harnesses, rustdoc generation, and fuzz targets.
- [Scripting and Execution](scripting.md) — Deep dive into job control semantics, pipeline streaming, and process group lifecycle handling.
- [FlashOS Architecture Guide](../../../docs/architecture.md) — Root operating system design principles and build-to-boot sequencing.

---

[← Previous: Scripting and Execution](scripting.md) · [FlashShell documentation](README.md) · [Next: Development and Testing →](development.md)
