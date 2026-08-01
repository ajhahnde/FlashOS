# Development

[FlashOS](../README.md) › [Documentation](README.md) › Development

This guide outlines the local developer environment, source tree structure, build operations, and documentation rules for modifying the FlashOS repository. It is intended for software engineers and maintainers actively extending build automation, system profiles, or userspace recipes. Subsystem testing suites and release verification gates are detailed in specialized accompanying guides.

## On this page

- [Development environment](#development-environment)
- [Repository layout](#repository-layout)
- [Typical workflow](#typical-workflow)
- [Build and maintenance commands](#build-and-maintenance-commands)
- [Generated artifacts and caches](#generated-artifacts-and-caches)
- [Working on system components](#working-on-system-components)
- [Working on FlashShell](#working-on-flashshell)
- [Documentation changes](#documentation-changes)
- [Before submitting changes](#before-submitting-changes)
- [Related guides](#related-guides)

## Development environment

Developing changes for FlashOS requires a host system provisioned with Git, Rustup, GNU Make, Podman, and QEMU as introduced in [Getting Started](getting-started.md). Ensure your container machine (`podman machine start`) is operational and that a local `.config` file is established in your repository root with `CONFIG_NAME?=flashos` and `ARCH?=x86_64` before compiling system images or invoking target package rebuilds.

## Repository layout

The FlashOS source repository is organized into distinct build, recipe, and code workspaces:

```text
config/
  flashos-base.toml               TUI foundation without Orbital or legacy /ui paths
  x86_64/flashos.toml             Active FlashOS image configuration profile
components/
  flashshell/                     In-tree FlashShell standalone Cargo workspace
recipes/
  core/kernel/                    Current operating-system kernel boundary recipe
  terminal/flashshell/            Target recipe compiling /usr/bin/fsh from source
  ...                             Transitional inherited core utilities and packaging
ci/                               Python product-profile lints and QEMU smoke tests
.github/workflows/                CI quality gates, container builds, and release flows
mk/ and Makefile                  Make build modules and root compilation entrypoint
scripts/ and podman/              Build helpers and clean-room container configurations
src/                              Root build-system support crate (`flashos_build`)
versions.env                      Live release version string for delivery gates
```

The root Cargo package (`flashos_build` under `src/`) functions exclusively as a build-system support utility for image processing; it is not the operating-system kernel. FlashShell maintains an isolated workspace under `components/flashshell/` with its own toolchain definitions and licensing.

## Typical workflow

When contributing code or modifying configuration profiles, structure your daily engineering loop around progressive quality verification:
1. Create a clean working branch off `main`.
2. Implement targeted modifications inside the appropriate component workspace or recipe directory.
3. Validate host unit tests and compiler linting on modified Rust code before launching long container builds.
4. Execute local CI contract checks (`python3 ci/check_profile.py`) to verify profile invariants.
5. Rebuild the x86_64 system image (`make CONFIG_NAME=flashos all`) and run an interactive QEMU session or automated serial smoke test (`python3 ci/qemu_smoke.py ...`).

## Build and maintenance commands

When executing root compilation and iteration tasks, rely on standard Make operations or the included shell wrapper scripts (`flashos.sh` / `flashos.zsh`):
- `cargo check --locked` — Verify root build-system support crate compilation and dependency lockstep.
- `make CONFIG_NAME=flashos all` — Assemble the complete default hard drive image in Podman.
- `make CONFIG_NAME=flashos build/x86_64/flashos/redox-live.iso` — Build the standalone live USB image.
- `make CONFIG_NAME=flashos qemu` — Launch the freshly built disk inside interactive QEMU UEFI emulation.
- `flashos recipe rebuild <NAME>` — Trigger focused package recompilation during iterative recipe debugging without tearing down cached toolchains.

## Generated artifacts and caches

Compiled output files, cross-toolchains, and intermediary caches are ignored by Git and written into isolated directories:

```text
build/x86_64/flashos/harddrive.img     Installed-disk and NVMe QEMU boot image
build/x86_64/flashos/redox-live.iso    Self-contained RAM-cached live USB image
build/x86_64/flashos/filesystem/       Staged directory filesystem during image assembly
build/x86_64/flashos/repo.tag          Package repository cache marker
prefix/x86_64-unknown-redox/           Cross-compiled target toolchain and sysroot
components/flashshell/target/          Host compiler artifacts for FlashShell
```

Never force-add or commit generated binaries, disk images, or compiled toolchain caches into repository git tracking.

## Working on system components

When modifying system packaging under `recipes/` or altering TUI profile rules in `config/`:
- Test package builds individually before executing a complete image rebuild.
- Confirm that new dependencies do not transitively drag in graphical client libraries (such as SDL, OpenGL, or windowing toolkits), as this will trigger failures in `ci/check_profile.py`.
- Preserve required audio drivers (`IHDA`) and terminal device enumeration paths.

## Working on FlashShell

FlashShell (`fsh`) is engineered as an independent workspace in `components/flashshell/`. When altering shell grammar, built-in commands, or terminal line editing:
- Follow the focused instructions in [FlashShell Development Guide](../components/flashshell/docs/development.md).
- Ensure all unit tests, property suites, canonical formatters, and golden grammar manifests succeed locally before initiating target recipe recompilation.

## Documentation changes

When creating or refining public markdown documentation in the repository, strictly follow these editorial rules:
- **Use relative links:** All internal markdown links and symbol references must use relative file paths pointing to valid repository targets. Never link to uncreated hosting websites or local `target/doc/` build folders.
- **Honor one Source of Truth:** Each technical topic has one primary document. Do not duplicate verbose command sequences or deep architectural tables; summarize briefly and link to the responsible topic guide.
- **Verify technical claims:** Every command, code snippet, syntax example, and hardware validation statement must reflect verified, demonstrable code or testing evidence.
- **Check links and headings:** Verify that every modified guide retains exactly one Level 1 (`#`) title and that no internal markdown links are broken or orphaned.
- **Separate public and private documentation:** Never mix internal management notes, personal timestamps, session identifiers, AI tooling notes, or private file paths into public docs.

## Before submitting changes

Before opening a pull request or requesting code review, confirm that your branch satisfies standard verification requirements:
- Run `git status --short` and `git diff --check` to catch unintended file modifications or trailing whitespace formatting errors.
- Ensure host tests and local Python CI contract checks pass cleanly.
- Re-read your commit history to ensure generated compilation artifacts, temporary scratch files, or local `.config` overrides remain uncommitted.

## Related guides

- [Getting Started](getting-started.md) — Initial host setup, toolchain requirements, and first-time image building.
- [Verification and Testing](verification.md) — Layered verification model, local Python test execution, and QEMU smoke automation.

---

[← Previous: Architecture](architecture.md) · [Documentation index](README.md) · [Next: Verification →](verification.md)
