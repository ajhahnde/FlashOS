# Scripting and Execution

[FlashOS](../../../README.md) › [FlashShell](../README.md) › [Documentation](README.md) › Scripting

This document details script execution semantics, process invocation models, redirection mechanics, status handling, and interactive terminal job lifecycle management in FlashShell. It is intended for software engineers writing `.fsh` automation scripts or embedding the FlashShell runtime engine within external host environments. Basic language syntax and typed pipeline rules are documented in the companion language guide.

## On this page

- [Scripts versus prompt execution](#scripts-versus-prompt-execution)
- [External command execution](#external-command-execution)
- [Command substitution](#command-substitution)
- [Pipeline boundaries](#pipeline-boundaries)
- [Redirections and descriptors](#redirections-and-descriptors)
- [Statuses and error handling](#statuses-and-error-handling)
- [Job lifecycle and process groups](#job-lifecycle-and-process-groups)
- [Interactive sessions and safe mode](#interactive-sessions-and-safe-mode)
- [Portability considerations](#portability-considerations)
- [Related documentation](#related-documentation)

## Scripts versus prompt execution

FlashShell guarantees strict execution symmetry between interactive terminal sessions and automated scripts. The executable entry point is `fsh`, and script source files use the `.fsh` extension. Both execution contexts engage an identical parser, AST representation, and scoping evaluation runtime. A script statement executed via `fsh automation.fsh` behaves identically to submitting the same lines directly at an interactive `>> ` prompt.

## External command execution

External host operating system utilities are invoked directly via argument vectors without intermediary interpretation:
- **Direct process launch:** FlashShell constructs native operating system command structures and argument arrays immediately; command strings are never routed through `/bin/sh` or host default sub-shells.
- **Forcing external commands:** To execute an external system binary without ambiguity or potential shadowing by identically named internal shell commands, prefix the invocation with the caret operator (`^`):
  ```fsh
  ^ls -lh /var/log/
  ^git ...$args
  ```

## Command substitution

FlashShell prevents code injection vulnerabilities by treating command substitution outputs purely as structured data values:
- **No string evaluation:** The language deliberately omits dynamic string evaluation (`eval`).
- **Safe capture:** Executing command substitutions captures stdout execution bytes or internal typed stream outputs directly into variable bindings or pipeline parameters without reparsing captured strings as executable source syntax.

## Pipeline boundaries

Data streaming across pipelines adapts automatically based on stage composition and execution boundaries:
- **External byte streams:** External-to-external pipeline edges operate as direct, shell-free OS file descriptor pipes.
- **Mixed pipelines and pipefail:** When pipelines mix internal built-ins with external OS binaries, execution streams explicit byte boundaries across stages without intermediate buffering or text capture. Mixed pipelines preserve source-ordered stage statuses and honor strict `pipefail` semantics: if an external consumer terminates early or breaks a pipe, FlashShell immediately ceases pulling from internal producers without hanging or panicking.

## Redirections and descriptors

I/O redirections follow strict source-ordered evaluation syntax:
- Support standard input (`<`), output overwriting (`>`), output appending (`>>`), and error file descriptor routing (`2>`, `2>&1`).
- Redirection evaluation occurs sequentially as specified in source order before executing target child processes.
- If file opening, permission validation, or file descriptor duplication fails during redirection setup, execution halts immediately with a runtime error reporting precise source spans without launching the target executable.

## Statuses and error handling

Process termination and structural failures follow a strict operational separation:
- **Statuses, not exceptions:** An external command returning a non-zero exit code does not trigger an unhandled exception or abort script execution by default. Instead, exit codes transform into first-class `Status` values. Logical branching operators (`&&`, `||`) evaluate directly on these status results:
  ```fsh
  ^make all && echo "Build succeeded" || echo "Build failed with errors"
  ```
- **Explicit checking:** To convert a non-zero status return into a catchable runtime execution error that halts pipeline progress, pass the result through the explicit `check` built-in command.
- **Runtime errors:** Unlike process exit codes, structural faults—such as missing binaries, failing redirections, argument type mismatches, or invalid syntax—instantly emit fatal runtime errors with lossless compiler diagnostic spans.

## Job lifecycle and process groups

Process execution operates under a rigorous, checked job lifecycle foundation:
- **Stable job identity:** Every executed pipeline or background process receives a stable, unique shell job identification handle.
- **Startup barriers:** Multi-process pipelines utilize an all-members startup synchronization barrier before executing target binaries, preventing race conditions during pipeline assembly.
- **Process group isolation:** Every external stage of a single pipeline spawns inside a shared operating system process group, ensuring that signals (such as `SIGTSTP` or `SIGINT`), background stops, and foreground resumptions target the entire pipeline collectively rather than as fragmented processes.
- **Completion observations:** Per-process termination observations are retained securely and reported cleanly at prompt-safe boundaries until acknowledged and removed by the session user.

## Interactive sessions and safe mode

When invoked without script arguments (`fsh`), the engine initializes an interactive terminal console session:
- **Terminal ownership transfer:** During foreground job execution, FlashShell transfers terminal control (`tcsetpgrp`) to the active pipeline's process group for exactly the duration of execution, reclaiming control before printing the next continuation prompt. If job execution panics or fails abruptly, terminal ownership releases cleanly back to the shell.
- **Transactional configuration and safe mode:** Upon startup, interactive sessions load trusted user configuration scripts transactionally. If syntax errors or runtime faults fail configuration evaluation, FlashShell aborts modifications and enters a clearly visible **safe mode** prompt rather than crashing or stranding the user.
- **Session options and interruption:** Startup flags `--no-config` and `--no-history` allow operators to cleanly bypass configuration loading or history database recording. During interactive editing, pressing `Ctrl-C` cleanly cancels the current multiline input buffer, while pressing `Ctrl-D` on an empty command line shuts down the session.

## Portability considerations

The runtime engine decouples core language evaluation from operating system primitives through the `flashshell-platform` contract. While `flashshell-platform-posix` supplies full POSIX process group, terminal ownership, and signal handling implementations for macOS and Linux hosts, platforms lacking sophisticated process groups or terminal job transfer simply execute pipelines within the shell's own process group without failing execution contracts.

## Related documentation

- [Language Guide](language-guide.md) — Fundamental syntax rules, bindings, word expansion mechanics, and typed pipeline commands.
- [Architecture and Crates](architecture.md) — Workspace crate modularity, parser design, and platform trait boundaries.

---

[← Previous: Language Guide](language-guide.md) · [FlashShell documentation](README.md) · [Next: Architecture →](architecture.md)
