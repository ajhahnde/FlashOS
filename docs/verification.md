# Verification and Testing

[FlashOS](../README.md) › [Documentation](README.md) › Verification

This guide establishes the verification methodology, multi-layered testing model, local qualification scripts, and automated CI/CD alignment for FlashOS. It is intended for developers and release evaluators needing to prove code correctness and runtime image stability before proposing code changes or publishing artifacts. Technical script internals and GitHub Actions workflows are documented separately.

## On this page

- [Verification principles](#verification-principles)
- [Verification layers](#verification-layers)
- [Local quality checks](#local-quality-checks)
- [Product-profile verification](#product-profile-verification)
- [QEMU runtime qualification](#qemu-runtime-qualification)
- [Physical hardware qualification](#physical-hardware-qualification)
- [CI/CD alignment](#cicd-alignment)
- [Release evidence](#release-evidence)
- [Interpreting failures](#interpreting-failures)
- [Related documentation](#related-documentation)

## Verification principles

FlashOS enforces a rigorous distinction between code compilation and operational verification. In an agentic and solo-maintained operating system repository, a change is never assumed to be functional simply because it compiles without compiler errors. True verification mandates proving behavior across distinct execution boundaries:
- **Compiled:** Source code satisfies compiler borrow checkers and type rules on the host machine.
- **Package built:** A component cross-compiles cleanly for the target ABI (`x86_64-unknown-redox`) within an isolated sysroot.
- **Image built:** Package recipe outputs integrate cleanly into an assembled, bootable disk partition image without dependency conflicts.
- **Image booted:** The compiled filesystem successfully negotiates UEFI firmware and kernel initialization in a virtual machine without panicking.
- **Runtime behavior checked:** Automated interactive sessions log into the console, verify terminal shell initialization (`fsh`), assert pipeline communication, and prove audio driver startup.
- **Physical hardware checked:** Real-world machines confirm bare-metal USB boot, physical keyboard interaction, framebuffer output, and system power cycle stability.

## Verification layers

To enforce these principles systematically, quality verification progresses through an ordered hierarchy of test layers:

```text
host checks
→ target compilation
→ package recipe
→ image construction
→ product profile
→ QEMU runtime
→ physical hardware
→ release evidence
```

A downstream validation layer should only be engaged once all prerequisite upstream layers have completed without error.

## Local quality checks

When developing code changes locally, execute host-level quality gates before attempting long image compilations. To verify root build-system support crates:

```sh
cargo check --locked
```

When modifying FlashShell inside `components/flashshell/`, execute standard workspace unit tests and lint evaluations:

```sh
cd components/flashshell
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
redoxer build -p flashshell-cli --bin fsh
```

For specialized guidance on grammar test benches, property suites, and fuzz campaigns, consult the [FlashShell Development Guide](../components/flashshell/docs/development.md).

## Product-profile verification

Before initiating containerized image building, verify that repository configurations and package selections satisfy FlashOS product invariants:

```sh
python3 ci/check_profile.py
```

This gate ensures the active image remains strictly TUI-only, confirms `/usr/bin/fsh` is assigned as the default login shell, validates required audio scheme availability, and asserts version string lockstep across manifest files.

## QEMU runtime qualification

After building system images (`make CONFIG_NAME=flashos all`), verify runtime stability by executing the local headless QEMU smoke contracts:

```sh
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/harddrive.img \
  --disk-interface nvme \
  --log build/x86_64/flashos/qemu-harddrive-smoke.log
```

To verify removable USB booting and memory-cached root filesystem detachment, test the standalone live ISO image:

```sh
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/redox-live.iso \
  --disk-interface usb \
  --log build/x86_64/flashos/qemu-live-usb-smoke.log
```

These automated scripts control serial stdio execution, validating firmware boot, user login, prompt readiness (`>> `), external pipeline execution, and guest `IHDA` audio driver initialization (using a null host audio backend for compatibility with headless systems).

## Physical hardware qualification

Testing compiled operating system images on physical bare-metal hardware represents an advanced qualification stage. Physical hardware verification occurs strictly after all local unit tests, package recipes, image compilations, and automated QEMU runtime smoke gates have passed cleanly.

Consult [Hardware Compatibility](hardware.md) for official validation levels, device identification mandates, read-only drive selection rules, and practical bare-metal testing instructions. Never write raw disk images to physical storage media without rigorous prerequisite testing and explicit device target confirmation.

## CI/CD alignment

The testing commands executed during local developer workflows mirror the exact automation enforced by GitHub Actions. Hosted CI pipelines implement a strict producer/consumer model: containerized compile jobs synthesize and promote checksummed disk images, which subsequent independent test runners download and qualify over NVMe and USB emulation.

For detailed boundary definitions, script responsibilities, and workflow orchestrations, refer to [CI/CD Contracts](../ci/README.md).

## Release evidence

Published FlashOS releases are bound to strict cryptographic and operational release evidence. Because GitHub Actions shares identical reusable workflows between standard pull request integration and tag-driven delivery, releases cannot bypass standard QEMU runtime qualification.

Every valid release candidate automatically synthesizes and publishes:
- Verified `harddrive.img` (NVMe disk format) and `redox-live.iso` (removable live format) image artifacts.
- Complete serial stdio QEMU smoke boot and pipeline execution logs.
- Immutable SHA-256 cryptographic image digests.
- Standardized CycloneDX Software Bill of Materials (SBOM) manifests covering both source dependencies and final compiled image closures.
- Verified cryptographic build-provenance attestations bound to the publishing GitHub release.

## Interpreting failures

When verification steps encounter errors, use this troubleshooting decision hierarchy to isolate root causes without guessing:
- **Host test failed:** Look for syntax errors, failing assertions in unit tests, or Clippy warning violations inside Rust source files.
- **Target build failed:** Indicates a cross-compilation linking error, missing target dependency in `Cargo.toml`, or ABI mismatch when running `redoxer`.
- **Image build failed:** Points to syntax errors in TOML package recipes, missing compiler prefix tools, or exhausted disk space inside Podman container VMs.
- **Product contract failed:** `ci/check_profile.py` detected an forbidden graphical dependency (SDL, OpenGL, Xfce), a mismatched login shell path, or out-of-sync release version numbering.
- **QEMU boot failed:** Suggests missing host UEFI firmware (`edk2`), an incompatible machine flag, or an early kernel/relibc initialization panic before getty console startup.

## Related documentation

- [Development](development.md) — Comprehensive developer workflows and workspace configuration instructions.
- [Hardware Compatibility](hardware.md) — Validation criteria and safety rules for physical bare-metal machine testing.
- [CI/CD Contracts](../ci/README.md) — Technical deep dive into automated python scripts and pipeline stage separation.

---

[← Previous: Development](development.md) · [Documentation index](README.md) · [Next: Hardware Compatibility →](hardware.md)
