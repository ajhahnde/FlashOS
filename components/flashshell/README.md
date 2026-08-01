# FlashShell

[FlashOS](../../README.md) › FlashShell

FlashShell (`fsh`) is an innovative command shell and structured scripting language designed from first principles to make terminal workflows ergonomic, safe, and composable. Implemented entirely in safe Rust, it powers both interactive user logins and automated script execution within FlashOS. This guide serves as the component entry point for developers using, extending, or studying the shell engine.

## About

FlashShell bridges traditional Unix byte streams with modern typed pipelines. Conventional programs communicate via raw standard streams, while built-in commands exchange streams of typed, structured values without lossy string parsing or unverified serializations. The executable is named `fsh`, and standalone scripts use the `.fsh` file extension. Both interactive terminal sessions and scripts share an identical lexer, AST parser, and evaluation runtime to guarantee predictable behavior across environments.

## Design principles

FlashShell deliberately abandons legacy POSIX compatibility in favor of predictable expansion semantics and type safety:

```fsh
let name = "FlashShell"             # immutable binding
mut count = 0                       # mutable binding

echo "hello $name"                  # expansion, never splitting
let args = ["status", "--short"]
^git ...$args                       # ^ forces an external command; ... spreads a list

open users.json
    | from json
    | where {|user| user.active}
    | select name email
    | sort name

^build && echo success || echo failed
```

- **No implicit word splitting:** Variable expansion `$name` always yields exactly one argument. Lists expand into multiple argv elements only through an explicit `...$list` syntax spread.
- **No strings as code:** FlashShell omits unstructured string execution (`eval`). Command substitution (`(...)` / `$(...)`) captures output directly as structured values without reparsing strings as executable source code.
- **Direct execution:** External host executables invoke directly via operating system argument vectors without routing command strings through `/bin/sh`. The `^` operator explicitly mandates external binary invocation.
- **Typed pipelines:** External-to-external pipeline edges operate as standard binary byte streams, whereas built-in internal commands transfer streams of typed values. Ambiguous transitions generate runtime diagnostics suggesting explicit converters such as `from json`, `to json`, or `decode`.
- **Statuses, not exceptions:** A non-zero process termination code evaluates as a regular `Status` value; logical operators (`&&` and `||`) branch directly on status outcomes. The explicit `check` built-in converts unsuccessful status returns into catchable evaluation exceptions.
- **Explicit globbing:** Path matching requires explicit pattern invocation via `glob "src/**/*.rs"`; bare unannotated filenames containing asterisks are never expanded silently.
- **Lossless diagnostics:** Byte-accurate token source spans drive compile diagnostics, AST canonical formatters, syntax highlighting, and interactive autocompletions.

## Quick start and usage

Inside FlashOS, FlashShell acts as the standard console login shell (`/usr/bin/fsh`). To execute scripts on a host system or within QEMU:

```sh
fsh script.fsh
```

To launch an interactive session from a standard command prompt, execute the binary without positional arguments:

```sh
fsh
```

Interactive sessions feature context-aware completion, syntax highlighting, history autosuggestions, multiline continuation prompts, and searchable history persistence.

## Crate layout and boundaries

The implementation resides within a nested Cargo workspace composed of specialized internal crates:

```text
crates/flashshell-syntax/           spans, lexer, parser, AST, diagnostics, formatter
crates/flashshell-runtime/          values, scopes, evaluation
crates/flashshell-platform/         platform trait and portable process contracts
crates/flashshell-platform-posix/   macOS/Linux process, fd, signal, terminal adapter
crates/flashshell-cli/              the fsh binary
```

Internal dependency routing is strictly enforced as a unidirectional hierarchy:

```text
syntax ← runtime ← cli
```

Platform interfaces operate behind the modular `flashshell-platform` contract, insulating AST execution and value scopes from direct POSIX or host OS kernel bindings.

## Building and testing

When developing inside the component workspace (`components/flashshell/`), require the pinned toolchain defined in `rust-toolchain.toml` and execute standard Cargo verification commands:

```sh
cargo build                     # build fsh into target/debug
cargo run -p flashshell-cli -- --version
cargo test --workspace          # unit, integration, golden, and property tests
cargo fmt --check               # formatting gate
cargo clippy --workspace --all-targets --all-features -- -D warnings
./fuzz/run-smoke.sh             # bounded lexer/parser fuzz run
```

To generate complete API reference documentation for all internal crates locally without compiling external third-party dependency manuals:

```sh
cargo doc --workspace --no-deps
```

This command generates HTML developer documentation under `target/doc/` inside the component workspace. Note that build output directories (`target/`) are ignored by Git and should never be staged or committed to repository tracking.

## Documentation

Comprehensive guides exploring syntax grammar, execution semantics, internal interfaces, and test fixtures are curated in the component documentation directory:
- [FlashShell Documentation Index](docs/README.md) — Directory index and documentation roadmap.
- [Language Guide](docs/language-guide.md) — Core bindings, expansion semantics, operator rules, and typed pipeline pipelines.
- [Scripting and Execution](docs/scripting.md) — Process invocation, argument vectors, explicit boundaries, and job management.
- [Architecture and Crates](docs/architecture.md) — Crate boundaries, parser design, runtime scopes, and platform isolation.
- [Development and Testing](docs/development.md) — Detailed build instructions, test harness operations, golden corpora, and fuzz campaigns.

## License and attribution

FlashShell codebase crates and documentation under `components/flashshell/` are dual-licensed or provided under the [Apache License 2.0](LICENSE), preserving clear attribution and licensing separation from the root FlashOS MIT build automation.

---

[← Back to FlashOS Main README](../../README.md) · [FlashShell documentation](docs/README.md) · [Next: Documentation Index →](docs/README.md)
