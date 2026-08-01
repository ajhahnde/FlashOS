# FlashShell Development and Testing

This document guides local building, testing, linting, and verification of FlashShell.

## Building and Verification Commands

FlashShell requires the Rust toolchain pinned in `rust-toolchain.toml` (picked up automatically by `rustup`). When working inside `components/flashshell/`, run the following standard host workflows:

```sh
cargo build                     # build fsh into target/debug
cargo run -p flashshell-cli -- --version

cargo test --workspace          # unit, integration, golden, and property tests
cargo fmt --check               # formatting gate
cargo clippy --workspace --all-targets --all-features -- -D warnings

./fuzz/run-smoke.sh             # bounded lexer/parser fuzz run (needs nightly + cargo-fuzz)
```

## Test Suites and Fuzzing Resources

The FlashShell workspace contains structured test suites and canonical fuzzing targets. Detailed documentation for each verification component is available in their dedicated test directories:

- **[Fuzz Targets](../fuzz/README.md)** — Guidance on running bounded smoke campaigns for lexer and parser fuzz targets.
- **[End-to-End Tests](../tests/e2e/README.md)** — Black-box and PTY execution fixtures.
- **[Test Fixtures](../tests/fixtures/README.md)** — Shared shell-free Rust child programs used by POSIX adapter and runtime acceptance tests.
- **[Grammar Golden Corpus](../tests/golden/grammar/README.md)** — Normative inventory and manifest for the v0.1 parser grammar.
- **[Lexical Golden Corpus](../tests/golden/lexical/README.md)** — Normative inventory and manifest for the v0.1 lexical contract.

---

[← Back: Architecture](architecture.md) · [Back to FlashShell Documentation Index](README.md)
