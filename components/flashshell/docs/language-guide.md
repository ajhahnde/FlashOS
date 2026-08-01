# FlashShell Language Guide

[FlashOS](../../../README.md) › [FlashShell](../README.md) › [Documentation](README.md) › Language Guide

This document defines the core language syntax, value types, expansion rules, and typed pipeline mechanics of FlashShell. It is intended for script writers, system developers, and engineers constructing commands or complex data processing pipelines within `fsh`. For process invocation rules, exit code branching, and job control semantics, refer to the accompanying scripting guides.

## On this page

- [Core philosophy](#core-philosophy)
- [Lexical grammar and tokens](#lexical-grammar-and-tokens)
- [Bindings and scope](#bindings-and-scope)
- [Word expansion and spreading](#word-expansion-and-spreading)
- [Expressions and operators](#expressions-and-operators)
- [Built-in commands and typed pipelines](#built-in-commands-and-typed-pipelines)
- [Explicit byte-boundary handling](#explicit-byte-boundary-handling)
- [Diagnostic formatting and spans](#diagnostic-formatting-and-spans)
- [Examples](#examples)
- [Related documentation](#related-documentation)

## Core philosophy

FlashShell intentionally discards legacy POSIX and `/bin/sh` shell conventions to establish an expressive, predictable, and safe command language. Traditional shells treat almost all inputs, variables, and outputs as weakly formatted whitespace-delimited strings, which frequently invites implicit word-splitting bugs and injection vulnerabilities. FlashShell builds upon structured typed values, lossless lexing, explicit conversion boundaries, and strict scoping rules to make command-line evaluation robust and composable.

## Lexical grammar and tokens

The FlashShell lexical grammar processes UTF-8 source code through a lossless tokenization engine. Every comment, whitespace sequence, operator, and literal retains byte-accurate source span information:
- **Comments:** Standard single-line comments begin with `#` and extend to the next newline.
- **Literals:** Supports quoted strings (`"hello"`), integer numbers, booleans (`true`, `false`), and structured collections (lists `[1, 2]` and records).
- **Lexical completeness:** The scanner classifies input source into three normative states: `complete` (syntactically self-contained), `incomplete` (valid input requiring additional continuation tokens, such as unclosed delimiters), and `invalid` (malformed syntax rejected immediately).

## Bindings and scope

Variable bindings operate under strict lexical block scoping, preventing accidental modification of parent evaluation environments:
- **Immutable bindings:** Declared using `let`, binding a typed value immutably within the active execution scope:
  ```fsh
  let name = "FlashOS"
  let flags = ["--verbose", "--check"]
  ```
- **Mutable bindings:** Declared explicitly via `mut` when subsequent value assignment or modification is required:
  ```fsh
  mut attempt = 0
  ```

## Word expansion and spreading

A foundational guarantee of FlashShell is the total elimination of implicit word splitting during variable expansion:
- **Single-argument expansion:** Expanding a variable via `$name` always produces exactly one operational argument, even if the string contains spaces or special characters.
- **Explicit list spreading:** Expanding a list variable into multiple individual arguments requires the explicit expansion spread operator (`...$list`):
  ```fsh
  let args = ["status", "--short"]
  ^git ...$args
  ```
  Attempting to pass a list without spreading where an external command argument vector is expected produces a helpful typing diagnostic.

## Expressions and operators

In addition to command statements, FlashShell evaluates rich expressions with predictable operator precedence:
- **Explicit globbing:** Bare wildcard strings (such as `*.rs`) are never expanded implicitly by the shell engine. File matching requires explicit expression evaluation using the built-in `glob` keyword:
  ```fsh
  let sources = glob "src/**/*.rs"
  ```
- **Logical branching:** Operators `&&` and `||` chain execution based on evaluation statuses without generating unhandled structural exceptions during non-zero exits.
- **Closures:** Inline functional blocks are enclosed within curly brackets with explicit vertical-bar parameter lists, such as `{|item| item.active}`.

## Built-in commands and typed pipelines

While pipelines between external OS executables remain traditional byte streams, FlashShell built-in commands exchange streams of structured, typed values. Built-ins execute natively within the evaluation engine without rendering intermediate text or serializing string formats:
- **Collection modifiers:** Built-in generators and transformation filters include `ls`, `first`, `last`, `collect`, `length`, `lines`, `select`, `get`, and `sort`.
- **Closure evaluation:** Commands such as `each`, `where`, and `update` evaluate structured records dynamically using inline closures:
  ```fsh
  open users.json
      | from json
      | where {|user| user.active}
      | select name email
      | sort name
  ```

## Explicit byte-boundary handling

When transitioning between raw external binary output streams and typed internal pipeline commands, conversions must be explicit:
- **Text and encoding boundaries:** Built-ins `decode` and `encode` translate raw bytes to and from UTF-8 strings with strict or lossy recovery behaviors.
- **Structured serialization:** Commands `from` and `to` parse and synthesize formatted documents (such as JSON or line-oriented records).
- **Stream I/O:** Lazy `open` commands compose cleanly with byte-preserving `save` outputs, enforcing documented item and byte ceilings to protect system memory during infinite streaming failures.
- **Ambiguity rejection:** If an unparsed external byte stream flows into a built-in requiring structured records without a conversion step, evaluation halts with an actionable error suggesting appropriate explicit filters (`from json`, `decode`).

## Diagnostic formatting and spans

Because syntax parsing and AST evaluation retain complete source span provenance, runtime failures, command redirection syntax errors, and process launch failures print detailed compiler-style diagnostics. This unified tokenizer simultaneously powers the canonical formatter and syntax highlighting without relying on competing lexical engines.

## Examples

### Processing structured data and executing external builds
```fsh
# Read a system manifest, filter active packages, and launch cross-compilation
let config = open target_profile.json | from json
let active_modules = $config.modules | where {|m| m.enabled}

^echo "Compiling active system modules..."
$active_modules | each {|mod|
    let build_flags = ["-p", $mod.name, "--release"]
    ^cargo build ...$build_flags && echo "Successfully compiled $mod.name" || echo "Failed compiling $mod.name"
}
```

## Related documentation

- [Scripting and Execution](scripting.md) — Comprehensive overview of process spawning, command substitution, exit code mapping, and interactive terminal job control.
- [Architecture and Crates](architecture.md) — Architectural breakdown of syntax parsers, runtime evaluation scopes, and platform adapters.

---

[← Previous: Documentation Index](README.md) · [FlashShell documentation](README.md) · [Next: Scripting and Execution →](scripting.md)
