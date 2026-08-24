# CI/CD Contracts

[FlashOS](../README.md) › CI/CD

The scripts under `ci/` and the workflows under `.github/workflows/` implement the automated checks used for FlashOS development, image builds, runtime testing, security checks, and releases.

This page focuses on how the pipeline is structured, how to run its checks locally, and where to start when something fails. The broader verification model is documented in [Verification and Testing](../docs/verification.md).

## On this page

- [Overview](#overview)
- [Pipeline](#pipeline)
- [Repository checks](#repository-checks)
- [QEMU runtime checks](#qemu-runtime-checks)
- [Hosted workflows](#hosted-workflows)
- [Artifacts and supply chain](#artifacts-and-supply-chain)
- [Running CI locally](#running-ci-locally)
- [Interpreting failures](#interpreting-failures)
- [Changing CI checks](#changing-ci-checks)
- [Sources of truth](#sources-of-truth)
- [Related documentation](#related-documentation)

## Overview

Product-specific checks live under `ci/` so they can be used both locally and from GitHub Actions. Workflow files handle hosted orchestration, permissions, caches, artifact transfer, and publication.

| Path                                                                                          | Purpose                                                                        |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| [`ci/check_profile.py`](check_profile.py)                                                     | Product profiles, release settings, branding, pinning, and workflow invariants |
| [`ci/check_developer_interface.py`](check_developer_interface.py)                             | Host command help, aliases, completion, and shell syntax                       |
| [`ci/check_flashos_platform.py`](check_flashos_platform.py)                                   | FlashOS target/toolchain baseline and built target artifacts                   |
| [`ci/check_flashos_capabilities.py`](check_flashos_capabilities.py)                           | Capability evidence inventory                                                  |
| [`ci/check_flashos_operation_map.py`](check_flashos_operation_map.py)                         | Flash operation mapping to Rust, relibc, and Redox interfaces                  |
| [`ci/check_flashos_capability_classification.py`](check_flashos_capability_classification.py) | Native/shimmed/unsupported capability classification                           |
| [`ci/check_flash_conformance.py`](check_flash_conformance.py)                                | Flash v1 executable host-conformance inventory and refusal-boundary audit       |
| [`ci/check_flash_release.py`](check_flash_release.py)                                        | Flash 1.0.0 version, evidence, claim, and candidate-workflow contract            |
| [`ci/check_coverage.py`](check_coverage.py)                                                   | LCOV report completeness                                                       |
| [`ci/classify_changes.py`](classify_changes.py)                                               | Fail-closed PR product and dependency-policy routing                            |
| [`ci/aggregate_ci.py`](aggregate_ci.py)                                                       | Stable aggregate result and classifier/job agreement                            |
| [`ci/check_candidate_qualification.py`](check_candidate_qualification.py)                     | Exact source-to-PR required/security evidence                                   |
| [`ci/release_candidate.py`](release_candidate.py)                                             | Candidate manifest, inventory, checksum, tree, and QEMU-byte validation         |
| [`ci/qemu_smoke.py`](qemu_smoke.py)                                                           | x86_64 serial runtime smoke tests                                              |
| [`ci/container/Dockerfile`](container/Dockerfile)                                             | Hosted image-build environment                                                 |
| [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)                                     | Main CI                                                                        |
| [`.github/workflows/coverage.yml`](../.github/workflows/coverage.yml)                         | Flash host coverage                                                            |
| [`.github/workflows/_image.yml`](../.github/workflows/_image.yml)                             | Reusable image build and QEMU qualification                                    |
| [`.github/workflows/security.yml`](../.github/workflows/security.yml)                         | Dependency and Cargo policy checks                                             |
| [`.github/workflows/candidate.yml`](../.github/workflows/candidate.yml)                       | Non-publishing release-candidate production                                    |
| [`.github/workflows/release.yml`](../.github/workflows/release.yml)                           | Exact candidate validation and publication                                     |
| [`flashos.sh`](../flashos.sh)                                                                 | Local helper commands                                                          |

If this document and an executable check disagree, the executable implementation wins.

## Pipeline

The candidate and protected-main path is:

```text
pull request
    │
    ├── change-classification
    │   └── fast or product lane; unknown paths fail closed
    │
    ├── repository-quality
    │   └── root checks + Python/product checks
    │
    ├── flash-quality
    │   └── fmt + Clippy + Flash host tests
    │
    └── image-and-runtime (product lane only)
        └── containerized producer → checksum handoff → QEMU consumer
                        ↓
                    CI / required
                        ↓
                  exact-tree merge
                        ↓
                  Main verified / verified
```

Draft pull requests stop after the source jobs. Ready pull requests take the
product lane unless every changed path belongs to the explicit documentation,
policy, reporting, or isolated host-tool allowlist. Unknown and mixed paths
fail closed into image and QEMU qualification. The `required` aggregate checks
that the jobs agree with the classifier. Protected-main verification
independently classifies the merged PR, proves exact tree identity, and checks
the successful `required` and `security-required` evidence instead of rerunning
the suite. Coverage is manual. Dependency policy runs when classified, weekly,
and on manual request.

Host tests, image construction, QEMU checks, and physical hardware testing are separate verification layers. See [Verification and Testing](../docs/verification.md) for their exact scope.

## Repository checks

### Flash v1 host conformance

Run the inventory and source-boundary check from the repository root:

```bash
python3 ci/check_flash_conformance.py
```

[`components/flash/conformance/v1.toml`](../components/flash/conformance/v1.toml)
maps each frozen host-v1 semantic family to enabled executable tests in the
locked Flash workspace. The checker requires the complete family and layer
inventory, verifies every test owner and platform contract path, confirms the
standard CI wiring and exact six-setting interactive config surface, and
rejects unclassified runtime refusal boundaries or source markers that imply
unfinished v1 behavior.

The checker validates ownership; `cargo test --workspace --locked` executes
every listed owner as part of the same `flash-quality` job. Passing both is the
host-v1 conformance signal. It does not establish Redox target compilation,
image integration, FlashOS runtime support, release readiness, or hardware
behavior.

### Flash 1.0.0 release contract

Run the release-boundary check from the repository root:

```bash
python3 ci/check_flash_release.py
```

[`components/flash/release/v1.toml`](../components/flash/release/v1.toml)
binds the component version to the frozen conformance and exhaustive exercise
contracts, retained host evidence, FlashOS capability report and target matrix,
public release claims, and the exact candidate-workflow commands. The checker
requires zero recorded release findings and zero unexamined inventory items.
The ready pull-request workflow then executes those owners and builds and boots
the exact in-tree package candidate; the record does not release a FlashOS
image or establish physical-hardware support.

### Product profile

Run:

```bash
python3 ci/check_profile.py
```

`check_profile.py` catches repository-level product errors before an image build starts. Among other things it checks:

- development and release profile composition;
- package and account configuration;
- `/usr/bin/fsh` as the configured shell;
- release root-account locking;
- FlashOS identity and version surfaces;
- release/image artifact naming and workflow wiring;
- immutable Git revisions for shipped Git-based packages;
- full commit pins for third-party GitHub Actions;
- branding patches and package-web source links;
- QEMU NVMe/USB smoke-test wiring.

`FLASHOS_RELEASE_VERSION` in [`versions.env`](../versions.env) is the central
FlashOS release version. Flash has an independent component version bound to
its release record. The exact package lists, denied values, and source
assertions are kept in the checker instead of being duplicated here.

Failures start with:

```text
profile contract:
```

### Platform baseline

Run:

```bash
python3 ci/check_flashos_platform.py
```

This compares the tracked FlashOS target record with the x86_64 profile, build toolchain, Rust compiler recipe, `relibc` recipe, and CI wiring.

After a clean image build has produced target package stages, artifact mode also checks the staged target compiler/configuration and ELF identity:

```bash
python3 ci/check_flashos_platform.py --artifacts
```

### Capability model

The current FlashOS capability data is checked with:

```bash
python3 ci/check_flashos_capabilities.py
python3 ci/check_flashos_operation_map.py
python3 ci/check_flashos_capability_classification.py
python3 ci/check_flashos_capability_report.py
python3 ci/check_flashos_target_matrix.py
```

These scripts keep the live `Capability` enum, evidence inventory, operation map, and architectural classification in sync.

The corresponding data files are:

- [`flashos-x86_64-capability-evidence.toml`](../components/flash/platforms/flashos-x86_64-capability-evidence.toml)
- [`flashos-x86_64-operation-map.toml`](../components/flash/platforms/flashos-x86_64-operation-map.toml)
- [`flashos-x86_64-capability-classification.toml`](../components/flash/platforms/flashos-x86_64-capability-classification.toml)
- [`flashos-x86_64-capability-report-v1.toml`](../components/flash/platforms/flashos-x86_64-capability-report-v1.toml)
- [`flashos-x86_64-runtime-fixtures-v1.toml`](../components/flash/platforms/flashos-x86_64-runtime-fixtures-v1.toml)
- [`flashos-x86_64-target-matrix-v1.toml`](../components/flash/platforms/flashos-x86_64-target-matrix-v1.toml)

The current classification records 41 operations as native and the three standard-directory operations as a FlashOS policy shim. Runtime qualification remains separate from that classification.

The versioned report records the adapter's current advertised set and keeps
each group connected to the bounded runtime fixtures that reach it. `Signals`
remains withheld. The checker also binds report versions to the Flash workspace
and FlashOS release, proves exact ordered capability coverage, verifies the
adapter bitset, and requires the QEMU runner to consume the same fixtures.
The linked target matrix assigns every advertised operation to one owning case,
covers the required startup, language, session, editor, job, and clean-exit
surfaces, and keeps the withheld `Signals` group outside the qualified set. Its
checker also requires both the automated and operator-observed consumers to
use the same ordered contract.

## QEMU runtime checks

[`ci/qemu_smoke.py`](qemu_smoke.py) boots an existing x86_64 image and tests the current serial interface. It does not build or modify the source image.

The interaction rows and expected markers live in
[`flashos-x86_64-runtime-fixtures-v1.toml`](../components/flash/platforms/flashos-x86_64-runtime-fixtures-v1.toml).
The exhaustive advertised-capability cases live in
[`flashos-x86_64-target-matrix-v1.toml`](../components/flash/platforms/flashos-x86_64-target-matrix-v1.toml).
The QEMU harness consumes both versioned suites directly. To render either
ordered contract for an operator-observed target without claiming that it was
run, use:

```bash
python3 ci/flashos_runtime_fixtures.py
python3 ci/flashos_target_matrix.py
```

The host needs Python 3, QEMU, compatible x86_64 OVMF/edk2 firmware, and an existing image.

The harness uses one TCG virtual CPU so scheduler timing does not make the
product-behavior assertions nondeterministic. This runtime gate does not
qualify SMP or multicore behavior.

Example:

```bash
python3 ci/qemu_smoke.py \
  --image /path/to/harddrive.img \
  --ovmf /path/to/OVMF_CODE.fd
```

Without `--ovmf`, the script searches its configured Linux and Homebrew locations.

### Options

| Option                  | Purpose                                 |
| ----------------------- | --------------------------------------- |
| `--image PATH`          | Image to boot                           |
| `--qemu PATH`           | QEMU executable                         |
| `--ovmf PATH`           | Explicit firmware file                  |
| `--log PATH`            | Full serial log                         |
| `--timeout SECONDS`     | Initial boot-marker timeout             |
| `--fixtures PATH`       | Versioned target-runtime fixture suite  |
| `--target-matrix PATH`  | Versioned target capability matrix      |
| `--disk-interface nvme` | Attach through emulated NVMe            |
| `--disk-interface usb`  | Attach as USB mass storage              |
| `--expect-root-locked`  | Also test the release root-login policy |

The VM runs headless using OVMF, TCG, snapshot-backed image attachment, an emulated USB keyboard, and HDA audio with a null host backend.

### What is tested

| Area                     | Check                                                                 |
| ------------------------ | --------------------------------------------------------------------- |
| Boot                     | FlashOS boot/startup markers appear                                   |
| Services                 | Expected framebuffer-debug and audio-driver markers appear            |
| Login                    | The unprivileged user can log in                                      |
| Bounded smoke            | Prompt, editing, directories, scripts, pipelines, and waits work      |
| Advertised capabilities  | Every required target-matrix surface completes in its declared order  |
| Withheld capability      | `Signals` remains outside the qualified set                           |
| Release root policy      | Root login is rejected when requested                                 |

The Flash editor redraws the input row while reading keystrokes, so the harness uses scoped output markers rather than treating a bare prompt as command completion. Prompt changes can therefore require a matching harness update.

Every live-editor submission fits within the emulated UART's 16-byte receive
boundary. Matrix scripts are streamed as exact bytes, in chunks no larger than
that boundary, to a foreground `head -cN` reader and then executed from the
resulting target-side file. This keeps transport mechanics separate from the
script behavior being qualified and avoids relying on a second readiness event
within one editor row.

The full serial stream is written to the requested log on success and failure.

```text
qemu smoke: FAILED:
qemu smoke: ok
```

The exact matrix covers target prompt recovery, history recall, completion,
multiline and Unicode editing, cancellation, configuration, typed capture,
structured errors, dynamic execution, globbing, supported jobs, and clean
exit. It does not cover inputs outside those cases, signal delivery,
stopped/continued/signaled child transitions, general hardware compatibility,
full networking, real audio I/O, framebuffer quality, suspend/resume,
performance, or complete Flash language behavior.

## Hosted workflows

### Standard CI

The candidate workflow is [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). It runs for pull requests and manual dispatch.

The classifier and two source-quality jobs are:

| Job                    | Checks                                                                        |
| ---------------------- | ----------------------------------------------------------------------------- |
| `change-classification` | Changed paths, selected lane, image requirement, and dependency-policy scope  |
| `repository-quality`   | Root formatting/tests, Ruff, Python tests, product checks, whitespace          |
| `flash-quality`        | Flash formatting, Clippy, v1 conformance inventory, and locked host tests      |

The source jobs remain required on every PR. Their Cargo downloads and build
outputs use separate toolchain/lockfile/profile keys. A manual `cold-cache` run
disables these caches so cached and clean results can be compared.

`image-and-runtime` calls `_image.yml` only when the classifier selects the
product lane and the PR is ready. Documentation, policy, reporting, and
isolated host-tool paths may select the fast lane. Product source, recipes,
profiles, image/QEMU tooling, CI orchestration, mixed changes, and unknown paths
select the product lane. Drafts defer the image even when it will be required
at ready-for-review.

The final `required` job combines these results into the stable status used by
repository rules. [`.github/workflows/main-qualification.yml`](../.github/workflows/main-qualification.yml)
then reports `verified` on the protected-main commit only after
[`check_main_qualification.py`](check_main_qualification.py) verifies the
associated pull request, exact Git-tree identity, independently recomputed path
classification, the appropriate successful or skipped image jobs, and
`security-required` evidence. This preserves a meaningful visible check on
`main` without executing the suite twice.

The aggregate decision table and selected-run/artifact rules are Python
contracts with negative unit tests, rather than untested shell branches that
exist only in workflow YAML.

### Coverage

[`.github/workflows/coverage.yml`](../.github/workflows/coverage.yml) is a
manually requested diagnostic that generates host-executable Flash coverage
using the pinned Flash toolchain and pinned `cargo-llvm-cov`.

Before upload, [`ci/check_coverage.py`](check_coverage.py) rejects a missing/empty report, reports without executed first-party lines, and reports that omit any of the workspace crates. There is no minimum percentage threshold.

Codecov upload uses GitHub OIDC rather than a persistent token. [`codecov.yml`](../codecov.yml) currently disables Codecov project/patch statuses, comments, and GitHub checks.

The percentage is Flash host coverage; it does not include target-only Redox code, image integration, QEMU behavior, the kernel, or physical hardware.

### Image build and runtime qualification

[`.github/workflows/_image.yml`](../.github/workflows/_image.yml) is shared by normal CI and releases.

Inputs:

| Input                   | Purpose                                                     |
| ----------------------- | ----------------------------------------------------------- |
| `artifact-name`         | Promoted image artifact name                                |
| `runtime-evidence-name` | QEMU logs/results artifact name                             |
| `retention-days`        | Artifact retention                                          |
| `config-name`           | x86_64 profile; defaults to `flashos`                       |
| `release-evidence`      | Also build/boot live media and generate the image SBOM      |
| `source-ref`            | Exact source commit                                         |
| `cold-cache`            | Disable BuildKit cache restore/save for a diagnostic run    |

The producer uses [`ci/container/Dockerfile`](container/Dockerfile) to build the
hard-drive image, validates target artifacts, creates and verifies
`SHA256SUMS`, and uploads the result. BuildKit layers are keyed by the pinned
container/toolchain inputs and Docker's actual layer input graph; cache export
failure is ignored. A cold-cache run adds `--no-cache`. Product outputs, final
images, candidate bundles, manifests, SBOMs, attestations, and QEMU results are
never restored as authoritative cache entries.

The candidate artifact contains:

```text
FlashOS-x86_64-harddrive.img
SHA256SUMS
```

Release-candidate qualification sets `release-evidence: true`. It additionally builds
and boots the live image over USB mass storage, collects staged target payloads,
generates the image CycloneDX SBOM, and carries the generated `cookbook.lock`
that resolved the exact build. The release profile also enables the root-lock
assertion.

Runtime jobs preserve available evidence on both success and failure:

```text
qemu-harddrive-smoke.log
qemu-harddrive-performance.json
qemu-live-usb-smoke.log
qemu-results.json
SHA256SUMS
```

The “clean-room” job name refers to the fresh hosted-runner/container boundary. It is not a bit-for-bit reproducibility claim.

Candidate and release images cook selected packages from tracked recipes. The
optional transitional binary feed remains available for local iteration but is
not an input to promoted-image qualification.

### Security

[`.github/workflows/security.yml`](../.github/workflows/security.yml) handles dependency review and Cargo policy.

For in-scope pull requests, dependency review rejects newly introduced dependencies at or above the configured high-severity threshold.

The root and Flash workspaces are also checked against their respective `deny.toml` files for:

```text
advisories
bans
licenses
sources
```

`security-required` is the stable aggregate used by repository rules. The
underlying gates run for classified dependency inputs, every Monday, and manual
dispatch; other PRs receive a controlled skip. Security reports should follow
the [Security Policy](../.github/SECURITY.md).

### Release candidates and publication

[`.github/workflows/candidate.yml`](../.github/workflows/candidate.yml) is a
manual, non-publishing producer. It accepts a full source commit, the exact
`versions.env` version, reviewed release notes, and an optional cold-cache
diagnostic. Before building it verifies that the source is a reviewable PR head
or an exact-tree merged PR result with successful `required` and
`security-required` evidence.

The candidate reuses `_image.yml` with:

```text
config-name: flashos-release
release-evidence: true
```

It builds the raw release-profile disk and live images once. Separate QEMU
consumers boot those exact raw bytes on the NVMe and USB paths on their first
attempt. Packaging verifies the handoff, compresses those same bytes, creates
the source SBOM, promotes the image SBOM, carries the reviewed notes and QEMU
evidence, writes `SHA256SUMS`, and creates `candidate-manifest.json`.

```text
FlashOS-<version>-x86_64-harddrive.img.zst
FlashOS-<version>-x86_64-live.iso.zst
FlashOS-<version>-source.cdx.json
FlashOS-<version>-image.cdx.json
FlashOS-<version>-release-notes.md
cookbook.lock
candidate-manifest.json
qemu-results.json and logs
SHA256SUMS
```

The manifest binds the repository, producer run and attempt, source commit and
tree, version, release profile, required/security run IDs, tracked input graph,
generated cookbook resolution, allowlisted inventory, every candidate digest,
raw image digests, and both QEMU results. Re-running the producer creates a
distinct artifact identity.

[`.github/workflows/release.yml`](../.github/workflows/release.yml) is a manual
consumer of an exact existing tag and candidate run ID. Its default dry run
validates the repository/workflow/run/attempt, artifact expiry, tag/version,
tag-tree/candidate-tree equality, inventory, checksums, decompressed image
digests, and release absence. Publication repeats validation in the protected
`production` environment and uploads the candidate files without building,
compressing, generating, attesting, or substituting anything.

## Artifacts and supply chain

The normal image handoff is:

```text
repository revision
    ↓
source/product checks
    ↓
containerized image producer
    ↓
hard-drive image + SHA256SUMS
    ↓
workflow artifact
    ↓
separate runtime consumer
    ↓
checksum verification
    ↓
NVMe QEMU test
```

Release packaging and publication preserve one candidate byte chain:

```text
exact source + successful required/security evidence
    ↓
once-built raw release images
    ↓
separate NVMe/USB QEMU consumers
    ↓
compressed bytes + SBOMs + notes + QEMU evidence
    ↓
checksums + manifest + provenance attestations
    ↓
exact candidate run ID + exact tag/tree validation
    ↓
publication without rebuild
```

| Artifact               | Contents                                                                  |
| ---------------------- | ------------------------------------------------------------------------- |
| PR image               | Raw hard-drive image and checksums                                        |
| Release image evidence | Raw disk, raw live image, image SBOM, and checksums                       |
| QEMU evidence          | Both serial logs, target performance JSON, result record, raw digests     |
| Release candidate      | Compressed images, SBOMs, notes, QEMU evidence, checksums, manifest        |

The pipeline also uses pinned Rust toolchains, Cargo lockfiles/policies, immutable Git recipe revisions, full commit pins for third-party Actions, a digest-pinned CI base image, checksum verification of the Rust installer, and SHA-256 verification across artifact handoffs.

Every release-candidate file receives GitHub provenance attestation in the
producer run. Publication creates no replacement attestation.

The pipeline does not currently perform two independent builds and compare their output bytes, so it should not be described as a reproducible-build verifier.

## Running CI locally

### Host checks

From the repository root:

```bash
source ./flashos.sh
flashos check ci
```

This runs the local source-quality collection: helper interface checks,
product/profile checks, whitespace validation, root formatting/tests, Flash
formatting/Clippy/tests, Ruff, and the offline Python unit tests.

### Direct checks

```bash
python3 ci/check_developer_interface.py
python3 ci/check_profile.py
python3 ci/check_flashos_platform.py
python3 ci/check_flashos_capabilities.py
python3 ci/check_flashos_operation_map.py
python3 ci/check_flashos_capability_classification.py

ruff check ci/
python3 -m unittest discover -s ci/tests -p 'test_*.py'
```

Validate an existing LCOV report with:

```bash
python3 ci/check_coverage.py coverage/flash.lcov
```

### QEMU smoke tests

Development profile:

```bash
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/harddrive.img \
  --disk-interface nvme \
  --log build/x86_64/flashos/qemu-harddrive-smoke.log

python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/redox-live.iso \
  --disk-interface usb \
  --log build/x86_64/flashos/qemu-live-usb-smoke.log
```

Release profile:

```bash
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos-release/harddrive.img \
  --disk-interface nvme \
  --log build/x86_64/flashos-release/qemu-harddrive-smoke.log \
  --expect-root-locked \
  --expect-passwordless-user

python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos-release/redox-live.iso \
  --disk-interface usb \
  --log build/x86_64/flashos-release/qemu-live-usb-smoke.log \
  --expect-root-locked \
  --expect-passwordless-user
```

Add `--ovmf` if the firmware is not found automatically.

### Full local qualification

```bash
flashos profile dev       # or: flashos profile release
flashos qualify all
```

This runs the local checks, builds both selected-profile images, and smoke-tests them.

Local qualification does not reproduce every hosted step such as artifact upload/download, hosted SBOM generation, dependency review, provenance attestation, or GitHub Release publication.

### Flash target compilation

Target compilation is separate from `flashos check ci`:

```bash
flashos check target
```

or:

```bash
cd components/flash
redoxer build -p flash-cli --bin fsh
```

Run it when a change affects Flash code selected for the Redox target.

## Interpreting failures

Start with the first failing layer.

| Failure point                  | First place to look                                                |
| ------------------------------ | ------------------------------------------------------------------ |
| Root formatting/tests          | Reported file/test, root toolchain, lockfile                       |
| Flash formatting/Clippy/tests  | Reported crate, warning, test, fixture                             |
| Ruff/Python tests              | Reported `ci/` file and diagnostic                                 |
| Coverage                       | Test output, LCOV contents, workspace members, OIDC upload         |
| Product profile                | Exact `profile contract:` message and owning file                  |
| Platform/capability checks     | Target record or referenced evidence/map/classification entry      |
| Container build                | Base image, packages, installer download/checksum                  |
| Image build                    | Recipe source, target toolchain, build log, storage                |
| Image SBOM                     | Staged payload, recipe metadata, scanner output                    |
| Checksum verification          | Staging/transfer mismatch or incomplete artifact                   |
| Boot timeout                   | Serial log before the missing marker, firmware, QEMU configuration |
| Interactive QEMU check         | Serial bytes around the failed interaction                         |
| Root-lock check                | Release profile, account database, login behavior                  |
| Dependency review/Cargo policy | Dependency diff, advisory, relevant `deny.toml`                    |
| Release version                | Tag and `versions.env`                                             |
| Packaging/attestation          | Downloaded candidate, job permissions, OIDC context                |
| Publication                    | Tag, environment, permissions, checksums, existing release         |

For QEMU failures, keep the complete serial log before rebuilding or rerunning.

## Changing CI checks

When an intentional product or pipeline change breaks a check:

1. update the implementation and the check that owns the rule;
2. update workflow wiring if orchestration, permissions, or artifact flow changed;
3. run the relevant local checks;
4. rebuild and smoke-test the affected image/profile paths;
5. update this page if the developer-facing procedure changed.

Update [Verification and Testing](../docs/verification.md) only when the broader evidence model or public qualification claim changes.

Artifact-name or SBOM-scope changes usually need matching changes in the producer, consumer, checksums, release packaging, and `check_profile.py`.

Keep third-party Actions pinned to full commit SHAs and external Git package sources pinned to immutable revisions.

## Sources of truth

| Concern                   | Primary source                                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------ |
| Verification model        | [Verification and Testing](../docs/verification.md)                                        |
| Development workflow      | [Development](../docs/development.md)                                                      |
| Local helpers             | [`flashos.sh`](../flashos.sh)                                                              |
| Developer interface check | [`check_developer_interface.py`](check_developer_interface.py)                             |
| Product/profile checks    | [`check_profile.py`](check_profile.py)                                                     |
| Platform baseline         | [`check_flashos_platform.py`](check_flashos_platform.py)                                   |
| Capability evidence       | [`check_flashos_capabilities.py`](check_flashos_capabilities.py)                           |
| Operation map             | [`check_flashos_operation_map.py`](check_flashos_operation_map.py)                         |
| Capability classification | [`check_flashos_capability_classification.py`](check_flashos_capability_classification.py) |
| Capability report         | [`check_flashos_capability_report.py`](check_flashos_capability_report.py)                 |
| Target capability matrix  | [`check_flashos_target_matrix.py`](check_flashos_target_matrix.py)                         |
| Change classification     | [`classify_changes.py`](classify_changes.py)                                               |
| Required aggregate        | [`aggregate_ci.py`](aggregate_ci.py)                                                       |
| QEMU runtime checks       | [`qemu_smoke.py`](qemu_smoke.py)                                                           |
| Main qualification        | [`check_main_qualification.py`](check_main_qualification.py)                               |
| Candidate evidence        | [`check_candidate_qualification.py`](check_candidate_qualification.py)                     |
| Candidate manifest        | [`release_candidate.py`](release_candidate.py)                                             |
| Coverage validation       | [`check_coverage.py`](check_coverage.py)                                                   |
| Hosted build environment  | [`container/Dockerfile`](container/Dockerfile)                                             |
| Standard CI               | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)                                  |
| Protected-main status     | [`.github/workflows/main-qualification.yml`](../.github/workflows/main-qualification.yml)  |
| Coverage                  | [`.github/workflows/coverage.yml`](../.github/workflows/coverage.yml)                      |
| Image build/runtime       | [`.github/workflows/_image.yml`](../.github/workflows/_image.yml)                          |
| Security                  | [`.github/workflows/security.yml`](../.github/workflows/security.yml)                      |
| Candidate production      | [`.github/workflows/candidate.yml`](../.github/workflows/candidate.yml)                    |
| Release publication       | [`.github/workflows/release.yml`](../.github/workflows/release.yml)                        |
| Root Cargo policy         | [`deny.toml`](../deny.toml)                                                                |
| Flash Cargo policy        | [`components/flash/deny.toml`](../components/flash/deny.toml)                              |
| Product version           | [`versions.env`](../versions.env)                                                          |
| Development profile       | [`config/x86_64/flashos.toml`](../config/x86_64/flashos.toml)                              |
| Release profile           | [`config/x86_64/flashos-release.toml`](../config/x86_64/flashos-release.toml)              |
| Security reporting        | [Security Policy](../.github/SECURITY.md)                                                  |
| Release history           | [Changelog](../CHANGELOG.md)                                                               |

## Related documentation

- [Verification and Testing](../docs/verification.md) — Evidence layers and qualification boundaries.
- [Development](../docs/development.md) — Repository setup, image builds, profiles, and local helper usage.
- [Flash Development](../components/flash/docs/development.md) — Flash workspace checks, tests, performance budgets, scheduling stress, fuzzing, target compilation, and package integration.
- [Flash Performance Benchmarks](../components/flash/benchmarks/README.md) — Versioned measurements, retained evidence, environment-specific budget derivation, and regression evaluation.
- [Flash Scheduling Stress](../components/flash/scheduling/README.md) — Seeded host pipeline-cancellation and job-control campaigns, retained results, and exact replay.
- [Architecture](../docs/architecture.md) — System layers, profile composition, package boundaries, and image construction.
- [Security Policy](../.github/SECURITY.md) — Private vulnerability-reporting instructions and supported security scope.
- [Changelog](../CHANGELOG.md) — Published project and release changes.

---

[← Previous: Flash Development](../components/flash/docs/development.md) · [Documentation index](../docs/README.md) · [Next: Changelog →](../CHANGELOG.md)
