# 10. `fsh`: The Current Recovery-Capable Shell

`user/fsh/` contains the Rust shell shipped in the current Rust-port image. It
is the current interactive session after login and is intentionally retained
as a tested recovery shell when the future UI stack arrives.

## Read, parse, dispatch

`crates/flibc/src/readline.rs` provides line editing, history, cursor movement,
and completion. `user/fsh/src/tokenize.rs` splits the command line and supports
one pipeline separator.

The shell then chooses between:

- an in-process built-in;
- an external program resolved as `/bin/<name>`;
- a single two-process pipeline connected with `pipe` and `dup2`.

There is no environment-variable or general `PATH` implementation yet.

```text
input line
   ↓
tokenize and optional pipe split
   ↓
built-in ── or ── fork + execve(/bin/name)
                         ↓
                       wait
```

## File descriptors make pipelines small

Every task has eight tagged descriptor slots. On a pipeline, the parent creates
a pipe, each child redirects one end onto standard input or output with
`dup2`, closes unused descriptors, and execs its command. The kernel's shared
descriptor ownership ensures that the backing pipe page is released after the
last reference closes.

## Startup configuration

The checked-in startup seed is `rootfs/fsh/fshrc`; the build stages it as
`/etc/fshrc`. It is data, not a source directory. User programs themselves
live under `user/`.

## Built-ins and external tools

Process-local operations such as changing the shell's current directory must
be built-ins. Programs such as `ls`, `cat`, `grep`, `cp`, `mv`, `rm`, `less`,
`edit`, `passwd`, and system-information tools are separate Rust ELF payloads
under `user/`.

## What the future names mean

The current `/bin/fsh` is not the separate FlashShell product. After the
Rust-port release:

1. FlashSDK is planned to define and activate the narrow public ABI/runtime;
2. FlashShell becomes its first product consumer and provides an embeddable
   shell engine;
3. FlashUI becomes the second consumer, embeds FlashShell, and later becomes
   the post-login native TUI.

Those are future integration steps, not current capabilities. FlashUI is not a
framebuffer desktop; it is planned as a terminal UI. The recovery `/bin/fsh`
path remains available through the cutover.

## Boot success marker

The homescreen tail `type 'help' for commands` is part of the watchdog
contract. The unattended boot expects it three times because the selftest image
drives two test login sessions and then reaches the final real login session.

> [!TIP]
> Shell parser tests are ordinary crate-local host tests. End-to-end pipeline,
> descriptor, exec, login, and prompt behavior is checked by the runtime
> harness and watchdog.

Next, we look below shell paths at the two filesystem backends.
