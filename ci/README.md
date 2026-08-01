# CI/CD Contracts

[FlashOS](../README.md) › CI/CD

This document details the quality gates, local verification scripts, and automated GitHub Actions workflows that protect the FlashOS product contract. It is intended for developers and maintainers seeking to run CI-equivalent checks locally or understand test pipeline failures.

## On this page

- [Purpose and scope](#purpose-and-scope)
- [Workflow and local-contract boundary](#workflow-and-local-contract-boundary)
- [Pipeline overview](#pipeline-overview)
- [Product-profile contract](#product-profile-contract)
- [QEMU runtime contract](#qemu-runtime-contract)
- [Artifacts and evidence](#artifacts-and-evidence)
- [Running the contracts locally](#running-the-contracts-locally)
- [Understanding failures](#understanding-failures)
- [Changing a contract](#changing-a-contract)
- [Security and release workflows](#security-and-release-workflows)
- [Related documentation](#related-documentation)

## Purpose and scope

This directory covers the product-specific contracts and automated testing logic used by both local developers and GitHub Actions. The workflow YAML under `.github/workflows/` only orchestrates execution; the underlying verification checks and smoke test assertions are structured as standalone python scripts inside `ci/` so they can be run without relying on hosted runners.

## Workflow and local-contract boundary

The pipeline preserves a strict separation between code compilation, profile inspection, image construction, and runtime execution:

| Boundary | Responsibility | Evidence |
| :-- | :-- | :-- |
| Quality | Rust formatting/tests and FlashShell lint/tests | GitHub job results |
| Product contract | Exact package closure, TUI-only policy, FlashShell login, retained audio | `check_profile.py` |
| Clean-room build | Build the x86_64 disk and live images in a FlashOS-owned Docker image | OCI image layer history and build log |
| Promotion | Upload both checksummed images | GitHub immutable workflow artifact |
| Runtime qualification | Boot the exact disk over NVMe and live image over USB without rebuilding | `qemu_smoke.py` and serial logs |
| Security | Dependency review and Cargo policy | scheduled and pull-request security workflow |
| Candidate | Compress, checksum, SBOM, and attest every release dry run | release workflow and GitHub attestations |
| Delivery | Publish an already qualified and attested tagged candidate | GitHub release |

## Pipeline overview

The automation enforces a strict producer/consumer model across independent pipeline stages:
1. Root build-system support tools and FlashShell workspace checks execute in parallel.
2. The active package closure, TUI profile, login-shell path, and audio policy are validated without building an image.
3. A dedicated container environment performs clean-room compilation of the x86_64 hard drive disk and live ISO images.
4. Both generated images and their SHA-256 checksums are uploaded as a single immutable workflow artifact.
5. A distinct test consumer runner downloads those exact promoted bytes and initiates interactive boot sessions over NVMe and USB.
6. Automated serial parsing verifies system identity, TUI login, FlashShell pipeline execution, and audio controller initialization.
7. Tagged releases are strictly bound to `versions.env`; any tag diverging from the declared live version fails immediately before packaging.

## Product-profile contract

The product-profile script at `ci/check_profile.py` inspects the active system configuration (`config/x86_64/flashos.toml` and `config/flashos-base.toml`) and repository metadata. It enforces:
- Strict adherence to a TUI-only package closure without graphical windowing systems or desktop stacks.
- That FlashShell (`/usr/bin/fsh`) is explicitly set as the login shell for system user accounts.
- Retained audio driver and audio scheme access paths.
- Version parity across root manifests, release metadata, console issue banners, and delivery scripts.

## QEMU runtime contract

The runtime script at `ci/qemu_smoke.py` controls an automated QEMU instance over serial stdio. It asserts that the built image:
- Successfully boots through the firmware and kernel stages without early kernel panics.
- Exposes an emulated HDA audio controller and confirmed initialization of the guest `IHDA` audio driver (using a null host audio backend so tests succeed on headless runners).
- Reaches the console login prompt and logs into the account.
- Starts FlashShell (`>> `) and completes an external-to-external pipeline execution test before cleanly terminating.
- Verifies removable media detachment by testing `redox-live.iso` over an emulated USB mass-storage interface.

## Artifacts and evidence

During verification, automated tests generate concrete verification logs and outputs under `build/x86_64/flashos/`:
- `harddrive.img` and `redox-live.iso` — The exact compiled disk and live USB images.
- `qemu-harddrive-smoke.log` — Full serial stdio capture of the NVMe harddrive smoke test.
- `qemu-live-usb-smoke.log` — Full serial stdio capture of the live USB mass-storage smoke test.

## Running the contracts locally

You can execute the exact release verification contracts on your local development host:

```sh
python3 ci/check_profile.py
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/harddrive.img \
  --disk-interface nvme \
  --log build/x86_64/flashos/qemu-harddrive-smoke.log
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/redox-live.iso \
  --disk-interface usb \
  --log build/x86_64/flashos/qemu-live-usb-smoke.log
```

## Understanding failures

When an automated pipeline or local verification script fails, identify the point of failure along the contract dependency chain:
- **Profile contract failures (`check_profile.py`):** Indicate that an unpermitted graphical package was introduced, shell credentials or paths diverged, or release version numbers fell out of lockstep across configuration files.
- **Image compilation errors:** Reveal missing target sysroot dependencies, syntax failures in fetched recipes, or out-of-space container storage during `make all`.
- **QEMU boot timeouts:** Generally occur if UEFI firmware (`edk2`) cannot be resolved on the host, or if a recent kernel or sysroot modification caused an early boot lockup or panic.
- **Smoke prompt or pipeline errors (`qemu_smoke.py`):** Occur when FlashShell fails to launch, serial canonical mode or PTY routing broke, or the test external pipeline terminated with a nonzero status.

## Changing a contract

Verification scripts and workflow gates represent formal quality invariants. If a system architecture enhancement legitimately requires altering an automated check:
- Update the underlying python script (`ci/check_profile.py` or `ci/qemu_smoke.py`) cleanly, maintaining clear debugging error messages and strict typing.
- Run both the harddrive and live USB smoke qualification tests locally to confirm that the updated criteria pass against fresh disk images.
- Document the updated contract behavior in this guide and ensure corresponding system architecture documents reflect the new target state.

## Security and release workflows

In addition to standard PR quality gates, specialized workflows govern security audits and candidate delivery:
- **Security reviews (`security.yml`):** Evaluates dependency advisories, license compliance, and newly introduced Cargo dependencies on a scheduled basis and on pull requests.
- **Release promotion (`release.yml`):** Re-executes clean-room compilation, runs both NVMe and USB QEMU smoke verifications, generates CycloneDX Software Bill of Materials (SBOM) documents, computes SHA-256 digests, and binds cryptographic build provenance before publishing tagged releases.

## Related documentation

- [Verification and Testing](../docs/verification.md) — Primary guide explaining the overall testing architecture and local qualification steps.
- [Development](../docs/development.md) — General instructions for workspace configuration and building system images.
- [Security Policy](../.github/SECURITY.md) — Security policy and vulnerability disclosure instructions.

---

[← Back to Main README](../README.md) · [Documentation index](../docs/README.md)
