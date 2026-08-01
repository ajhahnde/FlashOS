# FlashShell Scripting and Execution

This document explains script execution, process invocation, and command evaluation in FlashShell. This document is part of the ongoing public documentation restructuring.

## Scripts and Prompt Symmetry

The executable is `fsh`, and scripts use the `.fsh` extension. Scripts and the interactive prompt share the same parser and evaluator, ensuring identical behavior in both contexts.

## Execution Design

- **No strings as code:** FlashShell has no `eval`. Command substitution captures output as a value and never reparses it as source code.
- **Direct execution:** External commands are launched directly with an argument vector. FlashShell never routes command strings through `/bin/sh`. Using `^` explicitly forces execution of an external program (e.g., `^git`).
- **Statuses, not exceptions:** A nonzero exit code produces a normal `Status` value, and `&&` / `||` branch on that value. The `check` command explicitly converts an unsuccessful status into a catchable error. Process-spawning, redirection, and type failures are runtime errors with precise source spans.

---

[← Back: Language Guide](language-guide.md) · [Next: Architecture →](architecture.md)
