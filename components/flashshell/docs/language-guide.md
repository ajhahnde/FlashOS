# FlashShell Language Guide

This document introduces the language concepts, core syntax, and typed values in FlashShell. This document is part of the ongoing public documentation restructuring.

## Core Concepts

FlashShell deliberately does not aim for POSIX compatibility. Its semantics are based on typed values, explicit conversions, and predictable expansion rules.

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

## Syntax Rules and Guarantees

- **No implicit word splitting:** `$name` expands to exactly one argument. A list expands to multiple arguments only through an explicit `...$list` spread.
- **Typed pipelines:** External-to-external pipelines remain ordinary byte streams, while built-in commands exchange streams of typed values. Ambiguous boundaries are rejected with a suggested explicit converter, such as `from json` or `to json`.
- **Explicit globbing:** `glob "src/**/*.rs"` is an expression. A bare `*.rs` pattern is never expanded implicitly.
- **Precise diagnostics:** Lossless lexing and byte-accurate source spans power every diagnostic and the canonical formatter. There are no competing tokenizers.

---

[← Back to FlashShell Documentation Index](README.md) · [Next: Scripting and Execution →](scripting.md)
