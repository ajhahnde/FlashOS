# Development and Testing

[FlashOS](../../../README.md) › [FlashShell](../README.md) › [Documentation](README.md) › Development

This guide outlines toolchain prerequisites, build operations, automated test suites, golden corpora management, and fuzzing methodologies for developing FlashShell. It is intended for contributors actively hacking on syntax parsers, evaluation scopes, built-in commands, or terminal line editing features inside `components/flashshell/`. For root operating system disk compilation and package recipe integration, refer to the root FlashOS development guides.

## On this page

- [Toolchain and prerequisites](#toolchain-and-prerequisites)
- [Core build workflows](#core-build-workflows)
- [Rustdoc generation](#rustdoc-generation)
- [Test suites and verification layers](#test-suites-and-verification-layers)
- [Golden corpora and manifests](#golden-corpora-and-manifests)
- [Test fixtures](#test-fixtures)
- [End-to-end tests](#end-to-end-tests)
- [Fuzz targets](#fuzz-targets)
- [Continuous integration alignment](#continuous-integration-alignment)
- [Related documentation](#related-documentation)

## Toolchain and prerequisites

FlashShell requires the standard Rust compiler toolchain pinned directly within `components/flashshell/rust-toolchain.toml`. When executing Cargo commands inside this workspace, `rustup` detects the pinned toolchain file and provisions the required host compiler automatically. Running advanced libFuzzer smoke test targets requires an optional nightly toolchain alongside the `cargo-fuzz` utility.

## Core build workflows

When iterating on FlashShell crates locally, navigate into the component workspace and utilize standard Cargo developer workflows:

```sh
cd components/flashshell
cargo build                     # build fsh into target/debug
cargo run -p flashshell-cli -- --version
cargo test --workspace          # unit, integration, golden, and property tests
cargo fmt --check               # formatting gate
cargo clippy --workspace --all-targets --all-features -- -D warnings
```

Executing `cargo test --workspace` evaluates unit tests, grammar assertions, and integration suites across all workspace crates simultaneously.

## Rustdoc generation

To synthesize comprehensive local HTML developer API documentation covering all public structs, traits, syntax parsers, and runtime evaluation functions across internal workspace crates:

```sh
cd components/flashshell
cargo doc --workspace --no-deps
```

This command evaluates workspace documentation comments without attempting to compile extensive manual pages for external third-party crates. Generated HTML documentation files are emitted into:

```text
components/flashshell/target/doc/
```

Open `target/doc/flashshell_cli/index.html` in your web browser to navigate the rendered documentation tree. Note that build output directories (`target/`) are ignored by Git; never stage or commit generated documentation artifacts into repository version control.

## Test suites and verification layers

FlashShell enforces quality reliability through a comprehensive multi-layered testing strategy:
- **Unit and grammar tests:** Verify lexical rules, parser AST generation, and precise span boundaries inside `flashshell-syntax`.
- **Property and integration tests:** Evaluate scope shadowing, type transformations, and pipeline execution inside `flashshell-runtime`.
- **Golden corpora:** Compare parser and lexer outputs against normative, immutable manifest inventories.
- **PTY and end-to-end tests:** Validate interactive console behavior, prompt printing, job control, and signal handling inside `flashshell-cli`.
- **Fuzzing campaigns:** Bombard lexical and grammar parsers with randomized bytes to ensure absolute memory safety and graceful error handling.

## Golden corpora and manifests

The syntax verification engine evaluates AST production and lexical boundaries against formal golden source inventories:
- [Grammar Golden Corpus](../tests/golden/grammar/README.md) — Governs normative v0.1 grammar rules via `manifest.tsv`. Each record assigns an expected syntax classification (`complete`, `incomplete`, or `invalid`), source path, and grammatical justification.
- [Lexical Golden Corpus](../tests/golden/lexical/README.md) — Establishes normative v0.1 tokenization contracts via `manifest.tsv`. Validates character scanning, multi-line comment boundaries, and quote completion.

When extending language syntax, register corresponding test `.fsh` scripts within these directories and update the respective tab-delimited manifests; automated parser tests consume these manifests directly during `cargo test`.

## Test fixtures

To test POSIX platform process control, pipeline file descriptor passing, and exit status mapping without invoking host shell dependencies or introducing unsafe test code, the workspace provides shared Rust child programs under [Test Fixtures](../tests/fixtures/README.md):
- **`process_observer.rs`:** Writes length-prefixed binary diagnostic reports detailing target working directory, environment visibility, argument vectors, and inherited file descriptor states.
- **`status.rs`:** Simulates deterministic process termination outcomes, accepting instructions for ordinary code completion (`exit CODE`) or abrupt signal aborts (`signal` triggering `SIGABRT`).
- **`stream.rs`:** Provides deterministic stream generation and consumption (`source`, `relay`, `sink`, `both`, and `both-closed`) to verify broken pipe handling, EOF propagation, and multi-stage pipeline flow.

## End-to-end tests

Interactive terminal prompt mechanics, line cancellation (`Ctrl-C`), session shutdown (`Ctrl-D`), and background job control are qualified through dedicated pseudoterminal (PTY) and black-box harnesses documented in [End-to-End Tests](../tests/e2e/README.md). These tests execute against the compiled binary entrypoint via the CLI crate's `tests/e2e.rs` target during workspace test runs.

## Fuzz targets

To guarantee that arbitrary or malformed input bytes never induce panic loops, memory leaks, or parser crashes, the repository maintains dedicated libFuzzer targets documented in [Fuzz Targets](../fuzz/README.md). Because libFuzzer requires compiler instrumentation, the fuzz testing bench is isolated inside a separate workspace requiring a nightly toolchain and `cargo-fuzz`.

To run a bounded smoke campaign across both `lexer` and `parser` targets directly from the repository root:

```sh
./fuzz/run-smoke.sh
```

By default, the runner executes 1,000 fuzzer iterations per target using golden corpus files as canonical mutation seeds, writing writable fuzzer scratch corpora into temporary directories. To adjust the run duration, pass an explicit execution count parameter:

```sh
./fuzz/run-smoke.sh 10000
```

## Continuous integration alignment

The host commands detailed above form the mandatory quality foundation executed by automated GitHub Actions during pull request integration and candidate releases. Hosted verification workflows enforce strict parity with local toolchains: syntax formatting lints (`cargo fmt --check`), clippy evaluation (`-D warnings`), complete workspace test execution, and downstream QEMU runtime smoke testing all execute automatically against every proposed code modification.

## Related documentation

- [Architecture and Crates](architecture.md) — Software modularity, crate dependency hierarchy, and POSIX adapter boundaries.
- [Scripting and Execution](scripting.md) — Process invocation semantics, pipeline behavior, and interactive safe mode.
- [FlashOS Development Guide](../../../docs/development.md) — Instructions for root operating system compilation and target recipe rebuilding.

---

[← Previous: Architecture and Crates](architecture.md) · [FlashShell documentation](README.md) · [Back to FlashShell Overview →](../README.md)
