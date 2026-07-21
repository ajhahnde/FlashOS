<div align="center">

<h1>FlashShell</h1>

<h3>A command shell and scripting language, written in Rust — built to become the shell of FlashOS.</h3>

<p>
  <img src="https://img.shields.io/badge/version-v0.1.0-f59e0b?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/rust-1.97-f59e0b?style=flat-square" alt="Rust 1.97">
  <img src="https://img.shields.io/badge/license-Apache--2.0-lightgrey?style=flat-square" alt="License">
</p>

<p>
  <b>README</b> ·
  <a href="CHANGELOG.md"><b>Changelog</b></a> ·
  <a href="LICENSE"><b>License</b></a>
</p>

</div>

---

## About

FlashShell is a command shell and scripting language designed from first
principles for shell ergonomics, safety, and process composition. The binary
is `fsh`; scripts use the `.fsh` extension. Scripts and the interactive
prompt share one parser and one evaluator, so what a script does is what the
prompt does.

FlashShell composes ordinary Unix-style byte-stream programs and, alongside
them, built-in commands that exchange typed value streams — with every
crossing between structured values and external bytes made explicit. It is
deliberately not POSIX-compatible: variables are values rather than text
waiting to be reparsed, expansion never performs implicit whitespace
splitting, and no command output is ever reinterpreted as source code.

FlashShell is being built to become the shell of
[FlashOS](https://github.com/ajhahnde/FlashOS), an AArch64 bare-metal
kernel. Development happens on macOS and Linux first: the engine is written
in safe Rust behind a narrow platform contract, and FlashOS becomes the
product target once the host semantics are stable.

## Design

```fsh
let name = "FlashShell"      # immutable binding
mut count = 0                # mutable binding

echo "hello $name"           # expansion, never splitting
let args = ["status", "--short"]
^git ...$args                # ^ forces an external command; ... spreads a list

open users.json
    | from json
    | where {|user| user.active}
    | select name email
    | sort name

^build && echo success || echo failed
```

- **No implicit word splitting.** `$name` expands one scalar into exactly one
  argv entry. A list becomes multiple entries only through an explicit
  `...$list` spread.
- **No string-as-code.** There is no `eval`; command substitution captures
  output as a value, never as source to reparse.
- **Direct execution.** External commands run directly with argv. FlashShell
  never routes a command string through `/bin/sh`.
- **Typed pipelines.** External-to-external pipelines stay ordinary byte
  streams; internal commands exchange typed value streams; an ambiguous
  boundary is rejected with a suggested explicit converter (`from json`,
  `to json`, …).
- **Status, not exceptions.** A nonzero exit is a normal `Status` value.
  `&&`/`||` branch on it; `check` explicitly converts failure into a
  catchable error. Spawn, redirection, and type failures are runtime errors
  with source spans.
- **Explicit globbing.** `glob "src/**/*.rs"` is an expression; a bare `*.rs`
  is never silently expanded.
- **Precise diagnostics.** Lossless lexing and byte-accurate spans drive
  every error message, the canonical formatter, and (eventually)
  highlighting and completion — there are no competing tokenizers.

## Status

FlashShell is in early development and cannot execute commands yet. What
exists today, each part test-covered and CI-gated:

- the complete syntax layer: lossless lexer, structural
  complete/incomplete/invalid classification, a recursive-descent parser
  with multi-error recovery, source-spanned diagnostics, and a canonical
  idempotent formatter, backed by golden AST/diagnostic fixtures, property
  tests, and fuzz targets;
- the beginnings of the runtime: the immutable value model (null, bool,
  int, float, string, bytes, path, duration, byte size, list, record,
  status) and lexical scopes with immutable/mutable bindings and shadowing;
- a placeholder `fsh` CLI (`--version`, `--help`).

Expression evaluation, command planning, process execution, the interactive
editor, and structured built-ins come next, in that order.

## Building

Requires the Rust toolchain pinned in `rust-toolchain.toml` (rustup picks it
up automatically).

```sh
cargo build                     # build fsh into target/debug
cargo run -p flashshell-cli -- --version

cargo test --workspace          # unit, integration, golden, and property tests
cargo fmt --check               # formatting gate
cargo clippy --workspace --all-targets --all-features -- -D warnings

./fuzz/run-smoke.sh             # bounded lexer/parser fuzz run (needs nightly + cargo-fuzz)
```

## Layout

```text
crates/flashshell-syntax/           spans, lexer, parser, AST, diagnostics, formatter
crates/flashshell-runtime/          values, scopes, evaluation (in progress)
crates/flashshell-platform/         platform trait and portable process contracts
crates/flashshell-platform-posix/   macOS/Linux process, fd, signal, terminal adapter
crates/flashshell-cli/              the fsh binary
tests/golden/                       golden .fsh sources with expected ASTs and diagnostics
tests/fixtures/                     helper executables for execution tests
tests/e2e/                          black-box and PTY tests
fuzz/                               lexer/parser fuzz targets (separate workspace)
```

Dependency direction is strict: `syntax ← runtime ← cli`, with the platform
adapters behind the platform contract.

## See also

- **[FlashOS](https://github.com/ajhahnde/FlashOS)** — an AArch64 bare-metal kernel, written in Rust.
- **[FlashOS Tour →](https://ajhahn.de/flashos/)**
