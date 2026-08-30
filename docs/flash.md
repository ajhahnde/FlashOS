# Flash and FlashOS

[FlashOS](../README.md) › [Product Guide](README.md) › Flash and FlashOS

Flash is the FlashOS shell and scripting language. The same rules for values, processes, statuses, and jobs apply at the prompt and in `.fsh` files. This page describes the integration that exists today, then sketches the terminal interface planned for later.

## What ships now

The current x86_64 FlashOS profiles install Flash as `/usr/bin/fsh` and select it as the login shell for the configured users. Flash 1.0 provides:

- the same non-POSIX language at the prompt and in `.fsh` programs;
- structured runtime values and pipelines;
- direct external-process calls and visible byte/value conversions;
- normal `Status` values separate from runtime errors, with `check` when a failed command should raise an error;
- modules, static checking, formatting, non-executing inspection of one pipeline, help, completion, and language-server support;
- structured job inspection and the job-control features tested for the active platform; and
- Flash-based project automation where `fsh` is already available.

For a quick introduction, open the [Flash overview](../components/flash/README.md) or try [Flash by Example](../components/flash/docs/by-example.md). The [Flash documentation index](../components/flash/docs/README.md) links to the full language, scripting, architecture, and development guides.

## Moving between values and bytes

External programs exchange bytes. Flash's internal stages exchange declared value carriers. A conversion is visible in the pipeline:

```text
external process → ByteStream → from json → ValueStream → to json → ByteStream
```

Flash does not treat bytes, text, structured values, and source code as interchangeable. You can see where a conversion happens, and an external program's text format does not quietly become part of the language.

Runtime strings also stay data instead of being reparsed as Flash source. External commands receive an argument list and are started through the platform adapter, without a hidden POSIX shell in between.

## Status and errors

A process that exits with a nonzero code still completed, so Flash returns a `Status`. Parser, planner, runtime, I/O, and platform failures take a different path instead of collapsing everything into a generic false value.

Use `check` where unsuccessful process completion must become a catchable runtime error:

```text
^build | check
```

This lets each script decide which unsuccessful commands should interrupt its flow. See [Statuses and failures](../components/flash/docs/scripting.md#statuses-and-failures) for the full behavior.

## Jobs, processes, and services

Jobs belong to an interactive or script session. `jobs` returns records, while `wait`, `bg`, `fg`, and `kill` work with job IDs on platforms that support those operations. Operating-system processes are separate and are started through the platform adapter.

Flash does not yet provide one interface for persistent system services. Bringing jobs, processes, and services into a shared, inspectable model is a later goal, not a service-management API available today.

## What varies by platform

The language itself lives in platform-independent crates. Process, filesystem, descriptor, signal, clock, directory, and terminal operations go through a platform interface. The FlashOS adapter only reports groups that have been tested for the current target.

A successful Linux or macOS run therefore does not prove the same behavior inside FlashOS. Target compilation, package integration, image assembly, QEMU tests, and physical-machine tests are checked separately.

## Where the interface may go next

The longer-term idea is to let commands and interactive terminal views use the same system actions and structured data.

```text
             shared semantic action / system API
                    /                 \
                 Flash              View
```

The principle is: **every action has a command; every command can have a view.** Higher-level views should make common work easier without hiding the command language.

The first narrow piece is available: the experimental
[`system.describe`](system-api.md) query and its explicit Flash typed pipeline.
FlashOS does not yet ship the dedicated TUI, a stable system API, shared
Shell/View mutations, a general service interface, controlled apply, secret
handling, a cloud SDK, or an infrastructure state engine. The current `plan`
command can inspect one pipeline without running it; it is not a general-purpose
dry run.

## Relationship to other structured shells

Flash shares ideas with other structured shells: typed values, table-oriented commands, closures, external commands, and pipeline transforms. Its role is more specific. Flash is being built as the shell and automation language for FlashOS and, later, as one part of the operating system's terminal interface.

It is not a drop-in replacement for POSIX shells, Nushell, PowerShell, Terraform, OpenTofu, Kubernetes, provider state engines, or cloud SDKs. Only the behavior documented and tested in this repository is claimed.

## Redox relationship

FlashOS currently uses the Redox kernel and substantial parts of the Redox ecosystem as technical foundations. Flash and the FlashOS product profile, documentation, validation contracts, and development direction are maintained independently. FlashOS is not an official Redox OS distribution and is not affiliated with or endorsed by the Redox OS nonprofit.

See [Architecture](architecture.md) for how the current system is assembled and the [Roadmap](roadmap.md) for planned work.

---

[← Previous: Getting Started](getting-started.md) · [Documentation index](README.md) · [Next: Architecture →](architecture.md)
