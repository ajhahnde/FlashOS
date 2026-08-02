# FlashShell

[FlashOS](../../README.md) › FlashShell

FlashShell (`fsh`) is the primary interactive shell and scripting interface of FlashOS. It is a non-POSIX command language built around structured runtime values, explicit process invocation, and a shared syntax and execution core for interactive input and `.fsh` scripts. This page provides a component overview; detailed language, scripting, architecture, and development documentation is available under [`docs/`](docs/README.md).

> **Project status:** FlashShell is part of pre-alpha FlashOS. Language semantics, command-line behavior, platform capabilities, and internal interfaces may change without compatibility guarantees.

## On this page

- [Role in FlashOS](#role-in-flashos)
- [Design boundaries](#design-boundaries)
- [Current implementation](#current-implementation)
- [Using `fsh`](#using-fsh)
- [Development and verification](#development-and-verification)
- [Documentation](#documentation)
- [License](#license)

## Role in FlashOS

The FlashOS x86_64 image configuration includes the `flashshell` package and assigns `/usr/bin/fsh` as the login shell for the configured root and user accounts.

Running `fsh` without a script starts an interactive session. Passing a script path evaluates the UTF-8 source file as a FlashShell program; FlashShell scripts conventionally use the `.fsh` extension.

FlashShell provides the language and execution environment, but it does not replace the rest of the userspace. External commands remain separate executables supplied by the system image and are launched through the platform integration layer.

## Design boundaries

FlashShell intentionally does not claim compatibility with POSIX shells such as `sh` or Bash. POSIX shell scripts should not be expected to run as FlashShell programs, and FlashShell syntax should not be passed to another shell interpreter.

The component follows several implementation boundaries:

- Interactive input and script execution use the same syntax and runtime crates, but their front ends are not required to expose identical editing, history, or startup behavior on every target.
- Structured values belong to the FlashShell runtime. At an external process boundary, commands still use argument vectors, environment variables, working directories, file descriptors, and byte-oriented standard streams.
- External executables are launched directly through the platform interface rather than by translating FlashShell source into another shell language.
- Successful behavior on a macOS or Linux development host does not by itself establish equivalent behavior in a FlashOS image. Target compilation and image-level execution require separate verification.

## Current implementation

FlashShell is maintained as an independent Rust workspace inside the FlashOS repository.

| Path                                | Responsibility                                                                          |
| ----------------------------------- | --------------------------------------------------------------------------------------- |
| `crates/flashshell-syntax/`         | Source representation, lexical analysis, parsing, syntax trees, and diagnostics         |
| `crates/flashshell-runtime/`        | Runtime values, evaluation, built-ins, execution planning, sessions, and jobs           |
| `crates/flashshell-platform/`       | Platform capability contracts used by the runtime                                       |
| `crates/flashshell-platform-posix/` | Process, filesystem, descriptor, signal, and terminal integration for supported targets |
| `crates/flashshell-cli/`            | The `fsh` executable and its interactive and script entry points                        |

The separation between syntax, runtime, platform contracts, operating-system integration, and the command-line interface is intended to keep language semantics independent from target-specific terminal and process handling.

FlashShell is implemented in Rust. The CLI prohibits unsafe code, while the low-level platform adapter permits explicitly scoped unsafe sections for operations such as process-group, signal, and file-descriptor setup.

## Using `fsh`

On an installed FlashOS image, the executable is available as `/usr/bin/fsh`.

```sh
# Start an interactive session.
fsh

# Run a FlashShell script.
fsh program.fsh

# Show the supported command-line options.
fsh --help
```

Language syntax and runtime behavior are documented in the [Language Guide](docs/language-guide.md). Guidance for organizing and executing `.fsh` files belongs in the [Scripting Guide](docs/scripting.md).

## Development and verification

Run workspace checks from the FlashShell component directory:

```sh
cd components/flashshell
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

Target compilation is a separate check:

```sh
redoxer build -p flashshell-cli --bin fsh
```

These checks establish different properties:

- Host tests exercise portable syntax, runtime, and CLI behavior on the development system.
- A `redoxer` build verifies that the selected binary compiles for the Redox target environment.
- FlashOS image construction and QEMU execution verify package integration, installation, login-shell configuration, and behavior inside the assembled system.

For the component-specific workflow, test layout, and maintenance guidance, see [FlashShell Development](docs/development.md). For the repository-wide distinction between host checks, target checks, image validation, and runtime evidence, see [FlashOS Verification](../../docs/verification.md).

## Documentation

The FlashShell documentation is organized as follows:

- [FlashShell documentation index](docs/README.md) — entry point for the component documentation
- [Language Guide](docs/language-guide.md) — language concepts, syntax, values, commands, and evaluation behavior
- [Scripting Guide](docs/scripting.md) — practical creation and execution of `.fsh` programs
- [Architecture](docs/architecture.md) — internal crate boundaries, data flow, and platform abstractions
- [Development](docs/development.md) — workspace setup, tests, target builds, and maintenance workflow

For building and booting FlashOS as a complete system, begin with the [FlashOS Getting Started Guide](../../docs/getting-started.md).

## License

The FlashShell workspace is licensed under the [Apache License 2.0](LICENSE).

Other FlashOS components and incorporated third-party materials may be subject to separate terms. See the repository-level [NOTICE](../../NOTICE) and the applicable license files for attribution and licensing details.

---

[← Previous: Upstream References](../../docs/upstream/README.md) · [FlashOS README](../../README.md) · [Next: FlashShell Documentation →](docs/README.md)
