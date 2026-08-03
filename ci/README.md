# CI/CD Contracts

[FlashOS](../README.md) › CI/CD

This document defines the executable CI/CD contracts implemented by the scripts under `ci/` and the GitHub Actions workflows under `.github/workflows/`. It is intended for developers and maintainers who need to reproduce a check, interpret a workflow failure, or change an automated product invariant; the broader meaning and limits of each evidence layer are documented in [Verification and Testing](../docs/verification.md).

## On this page

- [Responsibility and boundaries](#responsibility-and-boundaries)
- [Contract map](#contract-map)
- [Static product-profile contract](#static-product-profile-contract)
- [QEMU runtime contract](#qemu-runtime-contract)
- [Hosted workflow architecture](#hosted-workflow-architecture)
- [Standard CI workflow](#standard-ci-workflow)
- [Reusable image qualification](#reusable-image-qualification)
- [Security workflow](#security-workflow)
- [Release workflow](#release-workflow)
- [Artifact and evidence flow](#artifact-and-evidence-flow)
- [Supply-chain controls](#supply-chain-controls)
- [Running the contracts locally](#running-the-contracts-locally)
- [Interpreting failures](#interpreting-failures)
- [Changing a contract](#changing-a-contract)
- [Sources of truth](#sources-of-truth)

## Responsibility and boundaries

The CI implementation separates four responsibilities:

1. source and host-workspace quality;
2. static repository and product-profile validation;
3. image construction and runtime qualification;
4. security review and release delivery.

The executable scripts under `ci/` own product-specific assertions that must also be available outside GitHub Actions. Workflow files own hosted orchestration, permissions, artifact transfer, retention, and publication conditions.

This document does not redefine the overall FlashOS verification model. In particular:

- a host test does not establish target behavior;
- a successful image build does not establish successful boot;
- a QEMU result does not establish physical hardware compatibility;
- checksums establish the identity of particular bytes, not their correctness;
- SBOMs are inventory evidence, not proof that the listed components are secure;
- provenance attestation identifies a workflow and artifact relationship, not bit-for-bit reproducibility or independent review.

FlashOS remains pre-alpha software even when all current automated contracts pass.

## Contract map

| Path                                                                  | Responsibility                                                                                |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| [`ci/check_profile.py`](check_profile.py)                             | Validate static FlashOS product, profile, release, pinning, and workflow invariants           |
| [`ci/qemu_smoke.py`](qemu_smoke.py)                                   | Boot an existing x86_64 image and evaluate the current serial runtime contract                |
| [`ci/container/Dockerfile`](container/Dockerfile)                     | Define the hosted x86_64 image-build tool environment                                         |
| [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)             | Run ordinary source, product, image, and runtime gates                                        |
| [`.github/workflows/_image.yml`](../.github/workflows/_image.yml)     | Build, checksum, promote, download, and boot disk and live images                             |
| [`.github/workflows/security.yml`](../.github/workflows/security.yml) | Run dependency review and Cargo supply-chain policies                                         |
| [`.github/workflows/release.yml`](../.github/workflows/release.yml)   | Rebuild and qualify release images, package a candidate, attest it, and optionally publish it |
| [`flashos.sh`](../flashos.sh)                                         | Provide public local convenience commands around the underlying contracts                     |

When this document and an executable script or active workflow disagree, the executable implementation is authoritative and the documentation should be corrected.

## Static product-profile contract

Run the static product contract from the repository root:

```bash
python3 ci/check_profile.py
```

A successful execution prints a short profile summary and exits with status zero. A failed assertion writes a message beginning with:

```text
profile contract:
```

and exits nonzero.

### Inputs

The script reads or inspects repository state including:

- `versions.env`;
- the root and FlashShell Cargo manifests;
- `config/flashos-base.toml`;
- `config/x86_64/flashos.toml`;
- `config/x86_64/flashos-release.toml`;
- selected package recipes;
- release and image workflow source;
- the QEMU smoke script;
- the root README;
- required branding patches;
- every workflow file under `.github/workflows/`.

It combines parsed TOML checks with selected source-text assertions. The text assertions intentionally make critical artifact names, workflow inputs, and runtime paths part of the static repository contract.

### Profile and package invariants

The contract currently verifies that:

- the x86_64 development profile includes the expected shared base profile;
- graphical XDG user-directory creation remains disabled;
- the combined base and architecture profiles select exactly the package set encoded by the script;
- selected graphical desktop and window-system identifiers are absent from that package set;
- both configured system accounts use `/usr/bin/fsh`;
- the development and release profiles differ only in their account configuration where the script permits that difference;
- the release profile locks the root account;
- a locked release root account does not also carry a password;
- configured release passwords do not use the script's well-known-password denylist.

The exact allowed package set and denied tokens are maintained in `ci/check_profile.py` rather than duplicated here.

### Runtime permission and interface invariants

The shared login-scheme configuration must retain the capabilities required by the current text interface and shell runtime.

The contract checks for required user access to:

- audio;
- display schemes;
- events;
- pseudoterminals.

It also rejects:

- Orbital scheme access;
- the legacy `/ui` configuration path;
- restoration of the deferred `docs/de` tree;
- graphical XDG home-directory creation.

These are static configuration checks. They do not prove that every retained scheme or device works at runtime.

### Identity and version invariants

`FLASHOS_RELEASE_VERSION` in `versions.env` is the central release-version input.

The profile contract compares that version with selected public and installed identity surfaces, including:

- the root Cargo package;
- the FlashShell workspace package metadata;
- `/usr/lib/os-release`;
- `/etc/issue`;
- the root README;
- release artifact naming and tag-validation source.

A mismatch fails before an image is built.

### Release and image-workflow invariants

The script verifies the presence of selected release-critical workflow contracts, including:

- use of the `flashos-release` profile for release qualification;
- versioned compressed disk and live-image names;
- separate source and image CycloneDX documents;
- source-SBOM name and version metadata;
- expected raw disk, live-image, image-SBOM, and checksum paths;
- collection of staged package payloads;
- NVMe and USB runtime qualification paths.

These checks confirm that the workflow source contains the required contract elements. They do not execute the workflow or parse its complete semantics.

### Pinning and repository-integrity invariants

For shipped packages whose recipes use Git sources, the script requires an immutable full commit revision.

For third-party GitHub Actions, it requires a full commit SHA after `@`. Local actions and reusable workflows referenced through `./` remain tied to the same repository commit and are exempt from this external-action check.

The contract also verifies:

- QEMU snapshot attachment of tested image files;
- the supported NVMe and USB smoke interfaces;
- presence of required local branding patches.

### Limits of the static contract

A passing profile check does not:

- compile Rust source;
- run Clippy or tests;
- resolve and compare the full transitive installed package graph;
- apply a branding patch or prove its behavioral effect;
- build a package or image;
- execute GitHub Actions;
- generate or inspect an actual SBOM;
- boot FlashOS;
- establish that a configured password is strong;
- qualify hardware.

It means only that the checked repository satisfies the static invariants encoded by the current script.

## QEMU runtime contract

`ci/qemu_smoke.py` boots an already-built x86_64 image and evaluates its serial behavior.

The script does not build or modify the source image. It attaches the supplied image through QEMU snapshot behavior so guest writes are discarded when the virtual machine ends.

### Requirements

The host must provide:

- Python 3;
- `qemu-system-x86_64`, or another binary supplied with `--qemu`;
- compatible x86_64 OVMF or edk2 firmware;
- an existing disk or live image.

The firmware path may be supplied explicitly:

```bash
python3 ci/qemu_smoke.py \
  --image /path/to/harddrive.img \
  --ovmf /path/to/OVMF_CODE.fd
```

Without `--ovmf`, the script searches its configured common Linux and Homebrew firmware locations.

### Command-line interface

| Option                  | Contract                                               |
| ----------------------- | ------------------------------------------------------ |
| `--image PATH`          | Required image to boot                                 |
| `--qemu PATH`           | QEMU executable; defaults to `qemu-system-x86_64`      |
| `--ovmf PATH`           | Explicit x86_64 firmware file                          |
| `--log PATH`            | Full serial capture destination                        |
| `--timeout SECONDS`     | Initial boot-marker budget                             |
| `--disk-interface nvme` | Attach the image through the emulated NVMe path        |
| `--disk-interface usb`  | Attach the image as USB mass storage                   |
| `--expect-root-locked`  | Add the release-profile root-login rejection assertion |

The interactive assertions use a separate budget after boot has completed. This separates a slow boot from a failure in the interactive shell contract.

### Virtual-machine boundary

The current harness uses a headless x86_64 QEMU configuration with:

- OVMF firmware;
- TCG execution;
- an immutable snapshot-backed image attachment;
- NVMe or USB mass-storage presentation;
- an emulated USB keyboard;
- an emulated HDA controller with a null host audio backend;
- a serial and monitor channel multiplexed through standard input and output.

The presence of an emulated network device and display adapter in the QEMU command does not mean that the current smoke contract qualifies networking or visible framebuffer output.

### Runtime assertions

The smoke script waits for ordered markers and performs scoped serial interactions.

| Area                    | Current assertion                                                                  |
| ----------------------- | ---------------------------------------------------------------------------------- |
| Bootloader              | FlashOS bootloader identity and boot-selection markers appear                      |
| Kernel and service path | FlashOS startup, framebuffer-debug, and audio-driver spawn markers appear          |
| Login                   | The configured unprivileged account reaches a successful login                     |
| Shell startup           | The FlashShell primary prompt appears                                              |
| Pipeline                | `printf` feeds `head` and produces the expected first line                         |
| Editing                 | Backspace editing changes the submitted command as expected                        |
| History                 | The preceding command can be recalled                                              |
| Multiline input         | Continuation prompts join and evaluate a block                                     |
| Cancellation            | `Ctrl-C` abandons the current input without executing it                           |
| Exit status             | A failing external command activates the tested <code>&#124;&#124;</code> fallback          |
| User filesystem         | The unprivileged account can create, read, and remove a file in its home directory |
| Foreground completion   | A failing foreground command returns control to the prompt                         |
| Permission boundary     | The unprivileged account cannot create the tested file under `/etc`                |
| Release root policy     | When requested, a root login attempt returns to the login prompt                   |

The audio assertion observes the expected guest driver-spawn marker while an HDA device is present. It does not prove audible playback, recording, mixer behavior, or codec completeness.

### Serial synchronization

The FlashShell target editor redraws its input row while reading keystrokes. The smoke harness therefore does not treat the appearance of a bare prompt as sufficient proof that a command completed.

For interactive assertions, it waits for prompt rows and output markers scoped to offsets in the serial capture. This distinguishes command output from echoed input and reduces false success caused by terminal redraw sequences.

Prompt text used by the target editor is consequently part of the executable smoke contract. A deliberate prompt change requires a coordinated harness update.

### Logs and cleanup

The complete captured serial byte stream is written to the requested log path on both success and failure.

After the assertions, or after a failure, the script attempts to terminate QEMU cleanly through the monitor channel. It then escalates to process termination and finally process killing only when the earlier shutdown path does not complete within its bounded waits.

A failure is reported as:

```text
qemu smoke: FAILED:
```

A successful run prints:

```text
qemu smoke: ok
```

followed by a summary of the verified areas.

### What the smoke test does not establish

The current contract does not qualify:

- physical hardware;
- real audio playback or recording;
- visible framebuffer rendering quality;
- graphical desktop behavior;
- end-to-end networking;
- arbitrary USB controllers or physical removable media;
- suspend, resume, reboot, or shutdown;
- long-duration stability;
- package installation after boot;
- performance;
- complete FlashShell language conformance;
- all filesystem operations or security boundaries.

The USB mode qualifies the defined QEMU USB mass-storage path only.

## Hosted workflow architecture

The active workflow relationship is:

```text
ci.yml
├── build-system-quality
├── flashshell-quality
├── tui-product-contract
└── _image.yml
    ├── docker-clean-room-build
    │   └── promoted checksummed image artifact
    └── qemu-artifact-consumer
        └── boots the downloaded artifact
            ↓
        CI / required

security.yml
└── independent dependency-policy jobs

release.yml
├── _image.yml using flashos-release
├── package, checksum, SBOM, and attest
└── conditional GitHub Release publication
```

The reusable image workflow is shared by ordinary CI and release qualification. This prevents the release path from using a weaker image or runtime contract than the standard hosted path.

## Standard CI workflow

The ordinary workflow is defined in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

It runs on:

- pushes to `main`;
- pull requests;
- manual dispatch.

Runs for the same workflow and pull request or Git reference share a concurrency group. A newer run cancels an older in-progress run in that group.

The workflow's default token permission is read-only repository content.

### Host-quality jobs

The independent prerequisite jobs are:

| Job                    | Contract                                                                                  |
| ---------------------- | ----------------------------------------------------------------------------------------- |
| `build-system-quality` | Root workspace formatting and locked host tests                                           |
| `flashshell-quality`   | FlashShell formatting, Clippy with warnings denied, and locked workspace tests            |
| `tui-product-contract` | Ruff checks for `ci/`, the static product-profile contract, and Git whitespace validation |

The root and FlashShell workspaces use their own pinned toolchain files and separate Cargo caches.

The standard CI workflow does not run the FlashShell Redox target-build command as a separate job. Target compilation remains an additional evidence layer for changes that affect target-selected code.

### Image prerequisite

The `image-and-runtime` job invokes `_image.yml` only after all host-quality and product-contract jobs succeed.

For ordinary CI it uses:

- the `flashos` development profile;
- a workflow artifact name containing the tested commit SHA;
- the workflow's configured CI retention period.

### Aggregate required result

The final job is named `required`.

It runs after every ordinary gate, including when an earlier gate fails or is skipped. It writes a summary table and exits nonzero unless all of these results are `success`:

- root build-system quality;
- FlashShell quality;
- product contract;
- image and runtime qualification.

This provides one stable aggregate status that can be selected by repository branch-protection settings. Whether branch protection actually requires that status is a repository setting rather than a property of the workflow source.

## Reusable image qualification

The reusable workflow is defined in [`.github/workflows/_image.yml`](../.github/workflows/_image.yml).

Its inputs are:

| Input            | Purpose                                          |
| ---------------- | ------------------------------------------------ |
| `artifact-name`  | Required name for the promoted workflow artifact |
| `retention-days` | Artifact retention period                        |
| `config-name`    | x86_64 profile to build; defaults to `flashos`   |

Only recognized development and release profiles are accepted by the runtime-consumer logic. An unknown profile fails rather than silently omitting the release-only root assertion.

### Image producer

The `docker-clean-room-build` job:

1. checks out the selected repository revision;
2. builds the repository-owned image from `ci/container/Dockerfile`;
3. mounts the checked-out source into the container;
4. builds both the hard-drive image and live image for the selected x86_64 profile;
5. collects staged target package payloads;
6. generates an image-oriented CycloneDX SBOM;
7. stages the two raw images and the image SBOM;
8. binds image digests and recipe-derived component metadata into the SBOM;
9. creates and verifies `SHA256SUMS`;
10. uploads the staging directory as one workflow artifact.

The build uses explicit Make variables to disable nested container building and select the noninteractive hosted build path.

The job name includes “clean-room,” but the guarantee should be described narrowly: it runs in a fresh hosted-runner workspace through a repository-owned container boundary. It is not a formal hermetic-build or bit-for-bit-reproducibility proof.

### CI container

`ci/container/Dockerfile` wraps the inherited Redox cross-build environment in a FlashOS-owned OCI definition.

The container contract includes:

- a base image selected by digest rather than only by tag;
- a Rust installer downloaded from a versioned archive;
- checksum verification of that installer;
- a toolchain matching the root workspace pin;
- source mounted only when the container runs;
- build-control environment defaults used by the hosted image job.

The container contains build tools rather than a baked copy of the FlashOS source tree. This allows the tool boundary and tested repository revision to remain separately identifiable.

### Image SBOM

The image SBOM is generated from the staged target package payload rather than from the repository working tree.

The workflow supplements scanner output with recipe metadata because staged Redox binaries do not necessarily contain package manifests recognizable by the scanner. Components can therefore include:

- immutable Git recipe revisions;
- distribution URLs and recorded content hashes;
- toolchain-sysroot provenance where no independent recipe source exists.

The SBOM metadata also records SHA-256 values for the staged disk and live images.

This document describes the workflow's inventory procedure. It does not claim that the resulting SBOM independently reconstructs every transitive build input or security property of the images.

### Promoted image artifact

The regular promoted artifact contains:

```text
FlashOS-x86_64-harddrive.img
FlashOS-x86_64-live.iso
FlashOS-x86_64-image.cdx.json
SHA256SUMS
```

The checksum file covers both images and the image SBOM and is verified before upload.

### Independent runtime consumer

The `qemu-artifact-consumer` job runs on a separate hosted runner after the image producer succeeds.

It:

1. checks out the same repository revision;
2. installs QEMU and OVMF;
3. downloads the promoted artifact;
4. verifies `SHA256SUMS`;
5. boots the downloaded hard-drive image over NVMe;
6. boots the downloaded live image over USB mass storage.

The consumer does not rebuild either image. The runtime result therefore refers to the downloaded, checksummed bytes produced by the preceding job.

For the release profile, both smoke executions add the locked-root assertion.

### Failure diagnostics

When the runtime-consumer job fails, the workflow attempts to upload:

```text
qemu-harddrive-smoke.log
qemu-live-usb-smoke.log
SHA256SUMS
```

under a failure-diagnostic artifact name containing the commit SHA.

These files support investigation. They are not ordinary release assets and do not replace the tested image artifact.

## Security workflow

The supply-chain workflow is defined in [`.github/workflows/security.yml`](../.github/workflows/security.yml).

It runs on:

- pushes to `main`;
- pull requests;
- its configured weekly schedule;
- manual dispatch.

Runs for the same workflow and pull request or Git reference share a cancel-in-progress concurrency group.

### Dependency review

On pull requests, the workflow uses GitHub's dependency-review action to reject newly introduced dependencies at or above the configured high-severity threshold.

This job evaluates dependency changes visible to GitHub's dependency graph. It is not a source-code or image vulnerability audit.

### Cargo policies

Separate jobs run Cargo policy checks for:

- the root workspace;
- the nested FlashShell workspace.

Both evaluate the configured categories:

```text
advisories
bans
licenses
sources
```

The workspace-specific `deny.toml` files define the detailed accepted and rejected policy.

A passing Cargo policy run does not establish that:

- all upstream operating-system code has been audited;
- every image component is represented in a Cargo graph;
- no unknown vulnerability exists;
- the built image is secure.

Security reports must follow the process in the [Security Policy](../.github/SECURITY.md).

## Release workflow

The release workflow is defined in [`.github/workflows/release.yml`](../.github/workflows/release.yml).

It runs on:

- pushes of tags matching `v*`;
- manual dispatch.

Release runs use a concurrency group based on the Git reference and are not cancelled automatically by later runs.

### Release image qualification

The first release job reuses `_image.yml` with:

```text
config-name: flashos-release
```

The release profile is therefore rebuilt and must pass:

- containerized disk and live-image construction;
- image-SBOM generation;
- checksum promotion;
- NVMe QEMU qualification;
- USB mass-storage QEMU qualification;
- the locked-root login assertion.

Packaging does not begin until this reusable workflow succeeds.

### Version binding

The packaging job reads `FLASHOS_RELEASE_VERSION` from `versions.env`.

For a tagged run, the Git tag must equal:

```text
v<FLASHOS_RELEASE_VERSION>
```

A mismatched or syntactically invalid version fails before candidate packaging.

A manually dispatched branch run receives a development suffix. It can exercise qualification and candidate packaging but cannot publish a GitHub Release.

### Candidate packaging

After qualification, the package job:

1. downloads the promoted release-profile images and image SBOM;
2. verifies their incoming checksums;
3. compresses the hard-drive and live images with Zstandard;
4. generates a source-oriented CycloneDX SBOM from the repository;
5. promotes and version-renames the image-oriented SBOM;
6. generates a release-candidate `SHA256SUMS`;
7. verifies that checksum file;
8. requests build-provenance attestations for the candidate subjects;
9. uploads the complete release candidate as a workflow artifact.

The candidate contains:

```text
FlashOS-<version>-x86_64-harddrive.img.zst
FlashOS-<version>-x86_64-live.iso.zst
FlashOS-<version>-source.cdx.json
FlashOS-<version>-image.cdx.json
SHA256SUMS
```

The provenance attestation is associated with these subjects through GitHub's attestation service. It is not an additional file listed in the candidate directory.

### SBOM scopes

The two release SBOMs have deliberately different scopes:

| Document    | Scope                                                                                   |
| ----------- | --------------------------------------------------------------------------------------- |
| Source SBOM | Repository and source-dependency view scanned during release packaging                  |
| Image SBOM  | Staged target package payloads and recipe metadata associated with the qualified images |

Neither should be presented as a complete inventory outside its stated boundary.

### Publication boundary

The publish job runs only when the workflow is on a tag and either:

- the run was triggered by a tag push; or
- a manual tag dispatch explicitly enabled publication.

The job uses the `production` GitHub environment and receives repository-content write permission only for publication.

Before publishing, it:

1. downloads the packaged candidate;
2. verifies `SHA256SUMS` again;
3. creates the tagged GitHub Release or replaces the named assets on an existing release.

Normal published assets are the two compressed images, two SBOMs, and checksum file. QEMU serial logs are not part of the standard published set.

## Artifact and evidence flow

The hosted producer-and-consumer path is:

```text
repository revision
    ↓
host-quality and profile gates
    ↓
containerized image producer
    ↓
raw images + image SBOM + SHA256SUMS
    ↓ workflow artifact
independent runtime consumer
    ↓ checksum verification
NVMe and USB QEMU smoke qualification
    ↓
CI aggregate result
```

The release path continues from a separate release-profile rebuild:

```text
qualified release-profile image artifact
    ↓
incoming checksum verification
    ↓
compressed images + source SBOM + image SBOM
    ↓
candidate checksum verification
    ↓
provenance attestation
    ↓ workflow artifact
conditional tag publication
```

### Current hosted artifact classes

| Artifact class           | Purpose                                                                   | Normal contents                                 |
| ------------------------ | ------------------------------------------------------------------------- | ----------------------------------------------- |
| CI image artifact        | Transfer the development-profile build from producer to consumer          | Raw disk, raw live image, image SBOM, checksums |
| Release image artifact   | Transfer the release-profile build from producer to consumer and packager | Raw disk, raw live image, image SBOM, checksums |
| Release candidate        | Preserve the packaged and attested candidate before publication           | Compressed images, two SBOMs, checksums         |
| QEMU failure diagnostics | Preserve serial evidence after a failed hosted boot job                   | Smoke logs and image checksums                  |

Artifact names and retention periods are workflow-owned values. Read the active workflow when an exact hosted name or expiry is operationally important.

## Supply-chain controls

The current automation uses several independent drift and integrity controls:

- root and FlashShell Rust toolchains are pinned separately;
- Cargo lockfiles record the selected Rust dependency resolution;
- Cargo policies check advisories, licenses, bans, and sources;
- shipped Git-based package recipes require full immutable revisions;
- third-party GitHub Actions require full commit SHAs;
- the CI base image is selected by digest;
- the Rust installer used in the CI image is checksum-verified;
- promoted images and SBOMs are covered by SHA-256 files;
- the runtime consumer verifies promoted checksums before boot;
- release packaging verifies incoming and outgoing checksums;
- release candidates receive workflow provenance attestations.

These controls improve traceability and reduce uncontrolled drift. They do not prove bit-for-bit reproducibility.

The hosted pipeline does not currently perform two independent builds and compare their resulting bytes. It should therefore not be described as a reproducible-build verifier.

## Running the contracts locally

### Consolidated host-side checks

Load the public helper from the repository root:

```bash
source ./flashos.sh
```

Run the local host-quality collection:

```bash
flashos check ci
```

This command runs:

- Bash and available Zsh syntax checks for the public helpers;
- the static product-profile contract;
- whitespace validation;
- root workspace formatting and tests;
- FlashShell formatting, Clippy, and host tests;
- Ruff over `ci/`.

It does not build an image, boot QEMU, reproduce the hosted Docker handoff, generate SBOMs, run dependency review, or create attestations.

### Direct CI-script checks

Run the product contract directly:

```bash
python3 ci/check_profile.py
```

Lint the release-relevant Python scripts when Ruff is installed:

```bash
ruff check ci/
```

### Development-profile smoke qualification

After building both development-profile images:

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

### Release-profile smoke qualification

For images built from `flashos-release`, add the root-lock assertion:

```bash
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos-release/harddrive.img \
  --disk-interface nvme \
  --log build/x86_64/flashos-release/qemu-harddrive-smoke.log \
  --expect-root-locked

python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos-release/redox-live.iso \
  --disk-interface usb \
  --log build/x86_64/flashos-release/qemu-live-usb-smoke.log \
  --expect-root-locked
```

Supply `--ovmf` when the firmware is not in one of the script's default locations.

### End-to-end local helper

Select the desired profile:

```bash
flashos profile dev
```

or:

```bash
flashos profile release
```

Then run all local checks, build both selected-profile images, and smoke-test them:

```bash
flashos qualify all
```

The helper automatically enables the root-lock assertion for the release profile.

Local qualification is not identical to hosted qualification. It does not reproduce:

- the hosted Docker build environment;
- workflow artifact upload and download;
- hosted checksum promotion;
- image or source SBOM generation;
- dependency-review jobs;
- provenance attestation;
- GitHub Release publication.

### FlashShell target compilation

Target compilation is not part of `flashos check ci`. Run it separately when target-selected FlashShell code changes:

```bash
flashos check target
```

or:

```bash
cd components/flashshell
redoxer build -p flashshell-cli --bin fsh
```

A successful target build remains distinct from image and runtime qualification.

## Interpreting failures

Start with the failing contract boundary rather than assuming a cause.

| Failure point                   | What is known                                                         | First investigation area                                                    |
| ------------------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Root formatting                 | Root source differs from formatter output                             | Reported file and pinned root toolchain                                     |
| Root tests                      | A host-side build-system assertion failed                             | Test output, root workspace changes, lockfile                               |
| FlashShell formatting or Clippy | FlashShell source or lint policy failed                               | Reported crate, target, warning, or formatter output                        |
| FlashShell tests                | A host-side component test failed                                     | Test target, fixture, platform path, recent language or runtime change      |
| Ruff                            | A CI Python source rule failed                                        | Reported `ci/` file and diagnostic                                          |
| Product profile                 | A static repository invariant failed                                  | Exact `profile contract:` message and owning manifest or workflow           |
| Container build                 | The hosted tool boundary could not be constructed                     | Base image, package installation, installer download, checksum              |
| Image build                     | Package or image assembly did not complete                            | Container log, recipe source, target toolchain, storage                     |
| Staged payload                  | No qualifying package stage was found                                 | Recipe outputs and target stage directories                                 |
| Image SBOM                      | Inventory creation or metadata binding failed                         | Staged payload, recipe metadata, scanner output                             |
| Checksum verification           | Bytes differ from the recorded digest                                 | Staging, transfer, replacement, incomplete artifact                         |
| Boot-marker timeout             | An expected serial marker did not appear                              | Earlier serial log, firmware, QEMU configuration, kernel or service startup |
| Interactive assertion           | Boot progressed but a tested interaction failed                       | Captured serial bytes near the scoped assertion                             |
| Root-lock assertion             | The release image did not reject the tested root login                | Release profile, account database, login behavior                           |
| Dependency review               | A pull request introduces a dependency above the configured threshold | Dependency diff and advisory                                                |
| Cargo policy                    | A workspace violates advisory, license, ban, or source policy         | Applicable `deny.toml` and dependency graph                                 |
| Release version                 | Tag and `versions.env` do not match                                   | Selected tag and central release version                                    |
| Candidate packaging             | Qualified inputs could not be compressed or assembled                 | Downloaded image artifact and packaging log                                 |
| Attestation                     | GitHub could not attest one or more candidate subjects                | Job permissions, OIDC context, subject paths                                |
| Publication                     | Candidate verification or GitHub Release operation failed             | Tag context, environment, permissions, checksums, release state             |

A timeout reports that a marker was not observed within its budget. It does not identify whether the cause was a slow host, firmware problem, boot regression, serial-routing change, or an outdated expected marker.

Preserve the complete failing serial log before rebuilding or rerunning. A later successful run may replace the most useful diagnostic evidence.

## Changing a contract

Automated contracts encode current product expectations. Change them deliberately rather than weakening them solely because an unrelated modification fails.

When an intended system change requires a contract update:

1. identify the existing assertion and the claim it protects;
2. update the owning implementation, configuration, profile, or workflow;
3. update `ci/check_profile.py` for affected static invariants;
4. update `ci/qemu_smoke.py` for affected runtime behavior;
5. preserve specific, actionable failure messages;
6. update `_image.yml`, `ci.yml`, `security.yml`, or `release.yml` when orchestration, permissions, or artifact flow changes;
7. run Ruff and the static profile contract;
8. rebuild and smoke-test both affected image forms;
9. test development and release profiles when their shared contract changes;
10. update this document;
11. update [Verification and Testing](../docs/verification.md) only when the broader evidence model or public procedure changes;
12. update the responsible architecture, development, security, or release documentation when its public contract changed.

Do not add a planned assertion to a table as if it already passes. A public runtime claim should correspond to an observable check in the current harness.

When changing artifact names or SBOM scope, update the producer, consumer, checksum generation, release packaging, profile-contract source assertions, and documentation together.

When changing a third-party Action, preserve a full commit pin. When changing a shipped Git recipe source, preserve an immutable revision.

## Sources of truth

| Concern                               | Primary source                                                                |
| ------------------------------------- | ----------------------------------------------------------------------------- |
| Overall evidence model                | [Verification and Testing](../docs/verification.md)                           |
| General local development workflow    | [Development](../docs/development.md)                                         |
| Local helper commands                 | [`flashos.sh`](../flashos.sh)                                                 |
| Static product contract               | [`check_profile.py`](check_profile.py)                                        |
| QEMU serial runtime contract          | [`qemu_smoke.py`](qemu_smoke.py)                                              |
| Hosted build environment              | [`container/Dockerfile`](container/Dockerfile)                                |
| Ordinary CI orchestration             | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)                     |
| Image producer and runtime consumer   | [`.github/workflows/_image.yml`](../.github/workflows/_image.yml)             |
| Dependency-policy orchestration       | [`.github/workflows/security.yml`](../.github/workflows/security.yml)         |
| Release qualification and publication | [`.github/workflows/release.yml`](../.github/workflows/release.yml)           |
| Root Cargo policy                     | [`deny.toml`](../deny.toml)                                                   |
| FlashShell Cargo policy               | [`components/flashshell/deny.toml`](../components/flashshell/deny.toml)       |
| Product version                       | [`versions.env`](../versions.env)                                             |
| Development image profile             | [`config/x86_64/flashos.toml`](../config/x86_64/flashos.toml)                 |
| Release image profile                 | [`config/x86_64/flashos-release.toml`](../config/x86_64/flashos-release.toml) |
| Security reporting                    | [Security Policy](../.github/SECURITY.md)                                     |
| Public release history                | [Changelog](../CHANGELOG.md)                                                  |

## Related documentation

- [Verification and Testing](../docs/verification.md) — Evidence layers, qualification boundaries, and supported claims.
- [Development](../docs/development.md) — Repository setup, image building, profiles, and local helper usage.
- [FlashShell Development](../components/flashshell/docs/development.md) — FlashShell workspace checks, tests, fuzzing, target compilation, and package integration.
- [Architecture](../docs/architecture.md) — System layers, profile composition, package boundaries, and image construction.
- [Security Policy](../.github/SECURITY.md) — Private vulnerability-reporting instructions and supported security scope.
- [Changelog](../CHANGELOG.md) — Published project and release changes.

---

[← Previous: FlashShell Development](../components/flashshell/docs/development.md) · [Documentation index](../docs/README.md) · [Next: Changelog →](../CHANGELOG.md)
