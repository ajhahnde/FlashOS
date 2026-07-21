<div align="center">

<h1>FlashUI</h1>

<h3>A native terminal user interface and session frontend for FlashOS, written in Rust.</h3>

<p>
  <img src="https://img.shields.io/badge/version-PLANNED-f59e0b?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/rust-1.97.1-dea584?style=flat-square" alt="Rust 1.97.1">
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

FlashUI provides the interactive environment of a FlashOS session. It handles terminal rendering, user input, command history, transcripts, slash commands and foreground applications while using [FlashShell](../flashshell) as its embedded shell engine.

> **Development Status:** FlashUI is currently in an early development and architecture phase.

## Architecture

FlashUI keeps the responsibilities of the user interface, shell and operating system clearly separated:

```text
FlashUI    → interface and session management
FlashShell → shell syntax, state and command execution
FlashOS    → processes, filesystems, pipes, terminals and syscalls
```

FlashUI does not implement its own shell language. Normal command input is forwarded to FlashShell, while registered slash commands are handled directly by the user interface.

```text
login
  └── flashui
        ├── TUI and rendering
        ├── input and history
        ├── transcript and scrollback
        ├── slash-command router
        ├── FlashShell runtime
        └── FlashOS platform adapter
```

## Planned Features

- Terminal-based user interface
- Command input, history and scrollback
- Structured stdout, stderr and diagnostic output
- Searchable slash-command palette
- Embedded FlashShell sessions
- Foreground terminal applications
- Native FlashOS platform integration
- Linux host frontend for development and testing

## Workspace

The project is planned as a Cargo workspace containing separate crates for the application core, terminal renderer, shell integration and platform abstraction.

```text
crates/
├── flashui-core/
├── flashui-tui/
├── flashui-shell/
├── flashui-platform/
└── flashui-host/
```

The core crates are designed for `no_std + alloc`. The host frontend may use `std`.

## Development

Run the host frontend on Linux:

```bash
cargo run -p flashui-host
```

The first development milestone is a functional host-based TUI with input handling, transcript rendering and a static slash-command palette.

## Project Goals

FlashUI is designed to remain independently versioned, testable without QEMU and portable across platform backends while serving as the default interactive session environment for FlashOS.

## See also

- **[FlashOS](https://github.com/ajhahnde/FlashOS)** — an AArch64 bare-metal kernel, written in Flash.
- **[FlashOS Tour →](https://ajhahn.de/flashos/)**
