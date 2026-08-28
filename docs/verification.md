# Verification and Testing

[FlashOS](../README.md) › [Product Guide](README.md) › Verification

Not every green check proves the same thing. This guide separates source checks, target compilation, profile validation, image construction, QEMU runs, physical hardware tests, and release evidence. For individual scripts and hosted workflows, see [CI/CD Contracts](../ci/README.md).

## On this page

- [Verification model](#verification-model)
- [Evidence layers](#evidence-layers)
- [Host and source checks](#host-and-source-checks)
- [Target compilation](#target-compilation)
- [Platform baseline verification](#platform-baseline-verification)
- [Product-profile verification](#product-profile-verification)
- [Image construction](#image-construction)
- [QEMU runtime qualification](#qemu-runtime-qualification)
- [Hosted CI and artifact promotion](#hosted-ci-and-artifact-promotion)
- [Host coverage reporting](#host-coverage-reporting)
- [Security checks](#security-checks)
- [Release evidence](#release-evidence)
- [Physical hardware qualification](#physical-hardware-qualification)
- [Local verification workflows](#local-verification-workflows)
- [Interpreting results and failures](#interpreting-results-and-failures)
- [Changing a verification contract](#changing-a-verification-contract)
- [Sources of truth](#sources-of-truth)

## Verification model

FlashOS treats every check as evidence for a bounded claim. Passing one layer does not imply that the later layers also pass.

| Layer                | Primary evidence                                                  | Supported claim                                                               | Not established                                          |
| -------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------- |
| Source quality       | Formatting, linting, and host tests                               | The checked source satisfies its host-side quality rules                      | Target compilation or image behavior                     |
| Host v1 conformance  | Checked Flash inventory plus locked workspace tests               | Every frozen host-v1 family has enabled executable owners that passed         | FlashOS target support or image behavior                  |
| Host coverage        | Validated Flash LCOV report                                       | Host tests executed the reported Flash source lines                           | Redox, QEMU, kernel, or hardware-path coverage           |
| Target compilation   | Redox-target build                                                | The selected component compiles for the current target ABI                    | Package installation or runtime behavior                 |
| Platform baseline    | Source and built-artifact baseline checks                         | The selected target, compiler, libc, dynamic linker, and ELF identity agree   | Capability availability or target runtime behavior       |
| Product profile      | `ci/check_profile.fsh`                                           | Declared profiles and selected repository contracts satisfy static invariants | Successful package or image construction                 |
| Package construction | Cookbook recipe build                                             | The selected recipe can produce its package output                            | Inclusion in a clean image                               |
| Image construction   | Completed disk or live artifact                                   | The selected profile can be assembled into an image                           | Successful boot or interactive behavior                  |
| QEMU runtime         | `ci/qemu_smoke.py`                                                | The tested image satisfies the defined emulated x86_64 runtime contract       | Physical hardware compatibility                          |
| Physical hardware    | Device-specific test record                                       | The tested image and revision reached the recorded state on that device       | Compatibility with other devices or revisions            |
| Release evidence     | Qualified artifacts, checksums, SBOMs, and provenance attestation | The published candidate is connected to a specific workflow and artifact set  | Formal security assurance or bit-for-bit reproducibility |

Verification should therefore be described precisely. Prefer statements such as:

```text
The image passed the NVMe QEMU smoke contract.
```

Do not replace them with broader statements such as:

```text
The operating system is fully stable.
```

FlashOS is pre-alpha software. Passing the current contracts means that the tested revision met the assertions encoded by those contracts, not that all behavior has been tested.

## Evidence layers

The normal progression for an image-affecting change is:

```text
source checks
→ target compilation where applicable
→ product-profile verification
→ package construction
→ image construction
→ QEMU runtime qualification
→ physical hardware qualification where required
→ release evidence
```

Not every change requires every layer. A documentation-only edit does not require an image build, while a kernel, profile, login, filesystem, driver, Flash target-integration, or image-assembly change normally requires downstream image and runtime evidence.

A later layer does not make earlier failures irrelevant. For example, an image that happens to boot does not justify ignoring a failed product-profile check.

## Host and source checks

Run inexpensive host-side checks before building packages or images.

### Root build-system workspace

From the repository root:

```bash
cargo fmt --all --check
cargo test --locked
```

These commands check the host-side `flashos_build` package and its committed dependency resolution. The root package supports the build system; it is not the FlashOS kernel.

### Flash workspace

From the repository root:

```bash
make flash-bootstrap
make flash-automation-tools
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flash_conformance.fsh
cargo fmt --manifest-path components/flash/Cargo.toml --all --check
cargo clippy --manifest-path components/flash/Cargo.toml --workspace --all-targets -- -D warnings
cargo test --manifest-path components/flash/Cargo.toml --workspace --locked
```

The conformance checker validates the complete host-v1 family inventory,
enabled executable owners, CI wiring, platform-contract coverage, and explicit
runtime-refusal classifications. The locked workspace suite then executes all
of those owners across syntax, runtime, CLI, REPL, checker, formatter,
language-server, and portable platform layers.

Host tests cannot reach every target-specific path. In particular, the FlashOS image selects target-side terminal and process integrations that require separate target compilation and runtime qualification.

Detailed Flash test organization belongs in the [Flash Development Guide](../components/flash/docs/development.md).

### FlashOS Python

The retained independent Python observers and the transitional public-
automation contract are linted and tested with:

```bash
ruff check ci/
python3 -m unittest discover -s ci/tests -p 'test_*.py'
```

The command requires Ruff to be available on the host. Hosted CI installs its configured version before running the check.

The migrated CI tests run through the public-automation qualification below.
That gate executes `ci/tests/test_classify_changes.fsh`,
`ci/tests/test_aggregate_ci.fsh`,
`ci/tests/test_check_coverage.fsh`,
`ci/tests/test_flash_benchmarks.fsh`,
`ci/tests/test_check_flash_conformance.fsh`,
`ci/tests/test_check_flash_release.fsh`,
`ci/tests/test_check_flash_v1_exercises.fsh`,
`ci/tests/test_check_flashos_capabilities.fsh`,
`ci/tests/test_check_flashos_capability_classification.fsh`,
`ci/tests/test_check_flashos_capability_report.fsh`,
`ci/tests/test_check_flashos_operation_map.fsh`,
`ci/tests/test_check_flashos_platform.fsh`,
`ci/tests/test_check_flashos_target_matrix.fsh`,
`ci/tests/test_check_main_qualification.fsh`,
`ci/tests/test_flashos_runtime_fixtures.fsh`,
`ci/tests/test_flashos_target_matrix.fsh`, and
`ci/tests/test_release_candidate.fsh` with both the immutable bootstrap and the
workspace candidate runtimes.

### Public automation

Validate that every public scripting and embedded-command surface is native
Flash or has one reviewed exception:

```bash
python3 ci/check_public_automation.py
```

This independent Python oracle also exercises the canonical `setup.sh`
clean-host plans for supported macOS and Linux package mappings, read-only
environment verification, idempotent reruns, separate pinned Rust toolchains,
the narrow Flash installer boundary, and pinned automation-tool selection.

After building the Flash workspace, acquire the immutable baseline runtime and
run the same contract through the trusted bootstrap before the workspace
candidate. This checks every native root plus ordered success and failure
behavior, cwd, argv, environment, output, and exit status:

```bash
make flash-bootstrap
python3 ci/check_public_automation.py \
  --bootstrap-runtime \
    build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh \
  --runtime components/flash/target/debug/fsh
```

The inventory-only command is a host-side package-wiring check. The paired
bootstrap-and-candidate command adds independent host execution parity. Neither
proves that a package was built, included
in an image, or executed on FlashOS; those remain downstream package, image,
and QEMU gates. See [Public Automation](automation.md) for the native programs
and retained interpreter boundaries.

### Public documentation

Run the public documentation check with:

```bash
source flashos.sh
flashos check docs
```

`ci/documentation.json` lists the public pages, their indexes, and the curated
examples. The command checks page structure, navigation, local links, and
anchors. It also formats, analyzes, and runs the examples with the fixed Flash
1.0 runtime. Editorial review, external links, rendered pages, and any target
or image claims still need separate checks.

### Shell helpers and whitespace

The public helper scripts can be syntax-checked with the shells available on the host:

```bash
bash -n flashos.sh
```

When Zsh is installed:

```bash
zsh -n flashos.sh
zsh -n flashos.zsh
```

Run the offline command, help, alias, and completion contract with:

```bash
make flash-bootstrap
make flash-automation-tools
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_developer_interface.fsh
```

Check the working-tree diff for whitespace errors:

```bash
git diff --check
```

These checks do not inspect Markdown links or prove the technical correctness of documentation claims.

### Consolidated helper command

After loading the repository helper:

```bash
source ./flashos.sh
```

Run the public host-side gate collection with:

```bash
flashos check ci
```

This command combines helper syntax checks, the product-profile contract, root workspace checks, Flash host checks, CI Python linting, and whitespace validation.

It does not:

- build Flash for the target ABI;
- build a package or system image;
- boot QEMU;
- reproduce the hosted Docker image workflow;
- run dependency-policy workflows.

## Target compilation

Changes that affect target-specific Flash code should also compile the `fsh` binary for the Redox target:

```bash
cd components/flash
redoxer build -p flash-cli --bin fsh
```

With the root helper loaded, the equivalent command is:

```bash
flashos check target
```

A successful target build proves that the selected binary compiles through the configured target toolchain. It does not prove that:

- the Flash recipe snapshots the tested in-tree workspace state;
- the binary is installed in an image;
- login starts the binary;
- external commands and terminal editing work inside FlashOS.

Those claims require recipe, image, and runtime evidence.

## Platform baseline verification

The tracked FlashOS platform baseline records the target identity used by
Flash without claiming that every abstract platform capability is implemented.
Run the source half from the repository root:

```bash
make flash-bootstrap
make flash-automation-tools
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_platform.fsh
```

This compares the baseline with the active image profile, root build
toolchain, Rust source selector, `relibc` source recipe, and CI wiring. After a
clean image build has populated target artifacts, run:

```bash
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_platform.fsh --artifacts
```

Artifact validation reads Cargo's recorded compiler queries, staged package
metadata, and the ELF headers of `fsh` and `libc.so`. It verifies the effective
compiler release, Rust target configuration, binary `relibc` revision, ELF
machine/class/endianness, dynamic linker, and required shared libraries.

A pass establishes that the source and built artifacts agree with the recorded
platform identity. It does not prove that argv, descriptors, processes,
signals, terminals, directories, or other platform capabilities behave
correctly. Those claims require their own adapter tests and target runtime
evidence.

The capability comparison is recorded separately in
[`components/flash/platforms/flashos-x86_64-capability-evidence.toml`](../components/flash/platforms/flashos-x86_64-capability-evidence.toml).
Validate its relationship to the live Flash contract and checked source/runtime
markers with:

```bash
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_capabilities.fsh
```

That pass proves that every current capability has an explicit requirement and
an internally consistent source/runtime evidence record. It does not prove the
recorded source operations work on FlashOS, promote an indirect QEMU
observation into full qualification, or classify an evidence gap as an
unsupported target feature. Those conclusions require operation mapping,
classification, and targeted runtime tests.

The per-operation map is recorded separately in
[`components/flash/platforms/flashos-x86_64-operation-map.toml`](../components/flash/platforms/flashos-x86_64-operation-map.toml).
Validate it with:

```bash
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_operation_map.fsh
```

That checker requires exact ordered coverage of every capability requirement
and validates each reference to the evidence inventory and mapped ABI seam. It
preserves the unknown Rust source commit by stopping standard-library routes at
their public APIs, maps direct adapter calls to the configured `relibc` source
revision and Redox userland paths, requires that revision in source-built image
packages, and records currently internal or unrouted operations
explicitly. A pass does not classify support, prove that a mapped symbol
behaves correctly, or replace target execution evidence.

The architectural route decision is recorded separately in
[`components/flash/platforms/flashos-x86_64-capability-classification.toml`](../components/flash/platforms/flashos-x86_64-capability-classification.toml).
Validate it with:

```bash
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_capability_classification.fsh
```

That checker requires exact ordered operation and capability coverage,
validates native routes against the operation map, rejects a native verdict for
an unrouted operation, and derives every capability verdict from its strongest
operation verdict. The current decision records 41 native operations and a
three-operation FlashOS standard-directory policy shim, with no deliberately
unsupported or kernel-work result. Target qualification remains pending and
requires later runtime evidence.

The bounded, versioned advertised-capability report is
[`components/flash/platforms/flashos-x86_64-capability-report-v1.toml`](../components/flash/platforms/flashos-x86_64-capability-report-v1.toml).
Validate its relationship to the current Flash workspace version, FlashOS
release, adapter bitset, route classification, and reusable target fixtures
with:

```bash
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_capability_report.fsh
```

The report records every advertised group plus explicit limitations and keeps
`Signals` withheld. The linked exhaustive target contract is
[`components/flash/platforms/flashos-x86_64-target-matrix-v1.toml`](../components/flash/platforms/flashos-x86_64-target-matrix-v1.toml).
Validate its complete advertised-capability, operation, and required-surface
coverage with:

```bash
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_target_matrix.fsh
```

The target matrix is not physical-hardware evidence or release qualification.

## Product-profile verification

Run the static FlashOS product contract from the repository root:

```bash
make flash-bootstrap
make flash-automation-tools
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_profile.fsh
```

The script reads the development profile, release profile, shared base configuration, selected manifests, recipes, workflow files, and related repository metadata.

Its current checks include:

- inclusion of the shared FlashOS base profile;
- the exact declared package set;
- exclusion of selected graphical-stack identifiers;
- disabled graphical XDG user-directory creation;
- `/usr/bin/fsh` as the configured shell for `root` and `user`;
- the in-tree Flash package recipe builds `fsh` and the separately staged and
  selected `flash.lsp` language-server package from the checkout-bound
  component workspace;
- the selected runtime excludes bootloader files, `libstdcxx`, `extrautils`,
  development headers/static libraries, kernel debug outputs, dead package
  configuration, and unqualified compatibility services;
- the build graph retains the bootloader media bytes, relibc development
  projection, kernel debug outputs, and separately packaged Flash language
  server;
- alignment of development and release profile structure;
- a locked root account in the release profile;
- rejection of well-known release-profile passwords;
- an exact reviewed init-service set with no selected remote-login daemon;
- required user access to the audio, display, event, and PTY schemes;
- exclusion of Orbital scheme access;
- absence of the legacy `/ui` configuration path;
- version alignment between `versions.env`, Cargo metadata, system identity, the root README, and release workflow contracts;
- post-package installation of the final FlashOS hostname, release metadata,
  console issue, and `/etc/os-release` link;
- presence of the expected image artifacts and image-oriented SBOM contract in the hosted workflow;
- NVMe and USB runtime paths;
- QEMU snapshot use;
- immutable Git revisions for shipped Git-based recipes;
- full commit pins for external GitHub Actions;
- presence of the required local branding patch files and rejection of added
  inherited product-identity strings in those patches.

After a package/image build, validate the staged runtime and supporting outputs with:

```bash
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_profile.fsh --artifacts
```

Artifact mode requires metadata for the exact eleven-package runtime closure,
including the language server's exact dependency on `flash`, rejects any other
uncollected runtime dependency, verifies the runtime/shared-library and boot
inputs, and proves that development, debug, Redoxer-daemon, and VirtualBox files
are staged outside the image or absent as intended. The release-image SBOM
collector consumes the same reported closure instead of all recipe stages, so
build-only packages do not appear as shipped components.

The script combines parsed TOML checks with selected repository-text and built-artifact assertions. Static mode does not:

- compile any Rust source;
- inspect built package payloads;
- apply or validate the behavior of a patch;
- build either image;
- execute a GitHub Actions workflow;
- boot FlashOS.

A successful result means that the repository satisfies the static invariants currently encoded by the script.

When a product rule intentionally changes, update the implementation, the contract, and the responsible documentation together. Do not weaken the script only to make an unrelated change pass.

## Image construction

### Development disk

Build the standard development disk:

```bash
./build.fsh -c flashos all
```

Expected artifact:

```text
build/x86_64/flashos/harddrive.img
```

### Live image

Build the corresponding live image:

```bash
./build.fsh -c flashos live
```

Expected artifact:

```text
build/x86_64/flashos/redox-live.iso
```

### Build both through the helper

With `flashos.sh` loaded:

```bash
flashos build both
```

An image build exercises more than ordinary host compilation. It requires the selected configuration, target toolchain, package repository, recipes, installer, filesystem tooling, and image-assembly path to complete together.

A successful build supports the claim that an artifact was assembled. It does not prove that the artifact:

- reaches the bootloader;
- starts the kernel successfully;
- reaches login;
- starts Flash;
- satisfies filesystem or permission expectations;
- behaves identically to a hosted clean-container build.

Local builds may reuse fetched sources, toolchains, compiled recipes, and other cached state. Hosted qualification therefore performs a separate containerized image build.

## QEMU runtime qualification

The executable runtime contract is:

```text
ci/qemu_smoke.py
```

It boots an existing x86_64 image through QEMU and evaluates the serial interaction produced by that exact input artifact.

### Requirements

The host must provide:

- Python 3;
- `qemu-system-x86_64`;
- compatible x86_64 OVMF or edk2 firmware;
- an already-built image.

The harness uses one TCG virtual CPU so scheduler timing does not make the
observable product-behavior checks nondeterministic. SMP and multicore behavior
require a separate runtime qualification gate.

The firmware path can be supplied explicitly:

```bash
python3 ci/qemu_smoke.py \
  --ovmf /path/to/OVMF_CODE.fd \
  --image /path/to/image
```

Use an actual firmware file on the current host. Do not commit host-specific absolute paths.

### Development disk over NVMe

```bash
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/harddrive.img \
  --disk-interface nvme \
  --log build/x86_64/flashos/qemu-harddrive-smoke.log
```

### Live image over USB mass storage

```bash
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/redox-live.iso \
  --disk-interface usb \
  --log build/x86_64/flashos/qemu-live-usb-smoke.log
```

The USB mode verifies the defined QEMU USB mass-storage boot path. It does not prove that a physical USB controller, storage device, firmware implementation, or computer can boot the image.

### Helper command

After both images have been built:

```bash
flashos smoke all
```

The helper selects:

| Image            | QEMU interface   | Default log                |
| ---------------- | ---------------- | -------------------------- |
| `harddrive.img`  | NVMe             | `qemu-harddrive-smoke.log` |
| `redox-live.iso` | USB mass storage | `qemu-live-usb-smoke.log`  |

When the selected profile is `flashos-release`, the helper also requests the locked-root assertion.

### Image immutability

The smoke harness attaches the input image with QEMU snapshot behavior. Guest writes therefore do not modify the source artifact.

This matters for two reasons:

1. both smoke modes begin from the supplied image bytes rather than state left by an earlier test;
2. runtime testing does not silently change the artifact whose checksum or provenance may later be evaluated.

For release profiles, both disk paths also hash the exact assembled init-directory listing after login. This complements package-stage inspection: it detects an init entry added or omitted during image assembly, while the source contract rejects unexpected services in every selected package. It does not prove that inherited service implementations are vulnerability-free or qualify network exposure.

The generated smoke log is diagnostic evidence from the session. It is not a replacement for the tested image or its checksum.

### Runtime assertions

The QEMU smoke contract checks observable markers and interactive behavior
across several general evidence classes. While
[CI/CD Contracts](../ci/README.md),
[`ci/qemu_smoke.py`](../ci/qemu_smoke.py), and the versioned
[`flashos-x86_64-runtime-fixtures-v1.toml`](../components/flash/platforms/flashos-x86_64-runtime-fixtures-v1.toml)
suite and the exhaustive advertised-capability
[`flashos-x86_64-target-matrix-v1.toml`](../components/flash/platforms/flashos-x86_64-target-matrix-v1.toml)
remain the authoritative sources for exact serial markers, assertion sequences,
parameters, and artifact paths. The qualification tests cover these interaction
categories:

| Category                             | Nature of tested interaction                                                                                                           |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| **Boot and kernel progress**         | Observable bootloader markers, serial boot submission, and kernel startup                                                              |
| **Service initialization**           | Driver spawn markers, such as guest audio driver (`ihdad`) initialization                                                              |
| **Authentication and basic access**  | Exact versioned FlashOS login banner, absence of inherited Redox product identity, successful unprivileged console login, and primary prompt display |
| **Interactive Flash session**        | Target-side byte editing, corrected-row submission, logical directory changes, and internal-command output                             |
| **Flash runtime paths**              | Script execution, stdout redirection, a two-member external byte pipeline, structured directory enumeration, and foreground return      |
| **Background execution**             | Addressable child launch/wait and conditional-chain supervisor re-execution without a runtime diagnostic                                |
| **Advertised capability matrix**      | Startup, configuration, scripts, built-ins, argv/environment, directories, pipelines, redirections, cancellation, history, completion, structured data, typed capture, structured errors, dynamic execution, statuses, globbing, Unicode/multiline editing, supported jobs, and clean exit |
| **Release root policy**              | Rejection of a root login attempt when the release-profile assertion is requested                                                       |

For the complete line-by-line runtime contract and serial synchronization rules, consult [CI/CD Contracts](../ci/README.md#qemu-runtime-checks).

The contract verifies those specific interactions. It does not currently establish:

- real audio playback or recording;
- visible framebuffer rendering quality;
- graphical desktop behavior;
- end-to-end networking;
- suspend, resume, reboot, or shutdown behavior;
- long-duration stability;
- package installation after boot;
- general performance characteristics outside the bounded Flash benchmark
  contract;
- inputs outside the exact target-matrix cases or general Flash language conformance;
- target signal delivery, stopped/continued/signaled child transitions, or stopped-job terminal-mode restoration;
- physical hardware compatibility.

Render the identical ordered inputs and observations as a real-system
checklist with:

```bash
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/flashos_runtime_fixtures.fsh
build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/flashos_target_matrix.fsh
```

The second command renders the exact startup, language, session, editor, job,
and clean-exit matrix used by QEMU. Rendering either checklist is not a target
observation or physical run. Hardware qualification still requires the
exact-device and explicit-approval workflow in
[Hardware Support](hardware.md).

The `ihdad` marker proves that the expected guest driver path began initialization under the emulated controller. It does not prove that sound was produced.

### Timeouts and logs

The smoke harness uses a boot timeout and a separate interactive-test budget. A timeout reports that an expected marker was not observed within the configured interval; it does not by itself identify the underlying cause.

Override the initial timeout when investigating a substantially slower host:

```bash
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/harddrive.img \
  --disk-interface nvme \
  --timeout 300 \
  --log build/x86_64/flashos/qemu-harddrive-smoke.log
```

Increasing a timeout can help distinguish a slow machine from an immediate failure. It must not be used to hide a repeatable hang.

The complete captured serial stream is written to the requested log even when an assertion fails.

When `--benchmark-output` is supplied, the same exact-image consumer runs the
bounded target-owned Flash performance cases after the runtime fixtures and
capability matrix, retains raw JSON, and evaluates it against the matching
one-vCPU TCG budget. This adds first-prompt, command, pipeline, and completion
observations; it does not turn the functional timeout into a performance
threshold or establish physical-hardware performance. See [Flash Performance
Benchmarks](../components/flash/benchmarks/README.md) for the measurement and
evidence boundary.

## Hosted CI and artifact promotion

The primary CI workflow separates source checks, static product validation, image production, and runtime consumption.

### Host-quality jobs

The standard CI workflow runs two independent jobs for:

- root workspace formatting and tests together with CI Python linting, Python
  tests, the product-profile contract, and whitespace validation;
- Flash formatting, Clippy, and host tests;

The workflow first classifies the exact changed paths. Draft pull requests stop
after source feedback. Ready pull requests skip the image only when every path
belongs to the explicit documentation, policy, reporting, or isolated host-tool
allowlist. Product source, target integration, recipes, profiles, image/QEMU
tooling, CI orchestration, mixed changes, and unknown paths fail closed into the
product lane. Manual CI defaults to the product lane.

The classifier is unit tested, its decision and reasons appear in the workflow
summary, and the stable `required` aggregate rejects any job result that does
not agree with that decision. Root and Flash Cargo downloads and build outputs
use separate toolchain/lockfile/profile cache identities. Manual `cold-cache`
runs provide the comparison path; cache hits never replace a validator or test.

Protected `main` requires the exact pull-request head to pass the stable CI and
Security aggregates before merge. The dedicated protected-main workflow then
finds the merged pull request, proves that its head and the protected-main
commit have the same Git tree, independently reclassifies the PR paths, and
verifies the appropriate image-job result plus successful stable CI and
dependency-policy aggregates. It publishes the visible `verified` check
without rerunning the source suite or product build.

### Clean-container image producer

For a ready candidate, the reusable image workflow:

1. restores safe BuildKit layers or explicitly starts cold, then builds the
   repository-owned CI container;
2. builds the x86_64 hard-drive image inside that container;
3. validates the produced target baseline;
4. records and verifies SHA-256 checksums;
5. uploads the files as one workflow artifact.

Release-candidate qualification enables the additional evidence path. It also builds
the live image, collects staged target package payloads, generates an
image-oriented CycloneDX SBOM, and binds both image digests into that inventory.

The hosted build uses a dedicated Docker environment and explicit Make
variables. It cooks selected image packages from their tracked recipes; the
optional moving binary feed is not a candidate or release input. A normal local
Podman build exercises related repository logic but is not an identical
execution environment.

BuildKit keys include the container definition and pinned root toolchain, while
Docker still validates each layer's actual input graph. Cache export failure is
non-fatal. Final images, staged release payload, candidate bundles, manifests,
SBOMs, attestations, and QEMU passes are never authoritative cache entries.

### Independent runtime consumer

A separate candidate job:

1. checks out the same repository revision;
2. installs QEMU and UEFI firmware;
3. downloads the promoted image artifact;
4. verifies its `SHA256SUMS`;
5. boots the downloaded disk image over NVMe.

Release-candidate qualification additionally boots the downloaded live image over USB
mass storage. The consumer never rebuilds either image before testing it.

The consumer does not rebuild the images before testing them. This connects runtime results to the checksummed bytes produced by the image job.

The candidate gate accepts only a first-attempt pass. A later diagnostic retry
cannot turn an initial release failure green. The workflow uploads the evidence
available on both success and failure:

```text
qemu-harddrive-smoke.log
qemu-harddrive-performance.json
qemu-live-usb-smoke.log
qemu-results.json
SHA256SUMS
```

### Rebuildability and reproducibility

The repository uses lockfiles, source-cooked selected image recipes, pinned
external recipe revisions, a checkout-bound in-tree Flash workspace snapshot,
pinned GitHub Actions,
checksums, and a controlled hosted build environment to reduce uncontrolled
drift and improve traceability.

The current workflow does not perform two independent builds and compare their output bytes. It therefore must not be described as proving bit-for-bit reproducible images.

A checksum proves the identity and integrity of a particular byte sequence. It does not prove how independently reproducible, correct, secure, or hardware-compatible that sequence is.

## Host coverage reporting

The manually dispatched Coverage workflow instruments the complete Flash host
test suite, validates one LCOV report, and uploads it to Codecov. Its structural
guard requires reported source from every Flash workspace crate and at least
one executed first-party line. Codecov statuses, comments, and GitHub checks
remain disabled, and Coverage is not part of the standard CI `required`
aggregate.

Coverage is an observation about lines compiled and executed on the host. It
does not measure target-selected Redox paths, image packaging, QEMU behavior,
the kernel, or physical hardware, so it is not used as the public product
qualification signal.

## Security checks

The security workflow is separate from the ordinary build and runtime pipeline,
but its stable `security-required` aggregate is part of merge qualification.

Its current jobs include:

- pull-request dependency review that rejects newly introduced dependencies at or above the configured severity threshold;
- Cargo advisory, license, ban, and source-policy checks for the root workspace;
- equivalent Cargo policy checks for the Flash workspace.

Every pull request reports the aggregate so repository rules can require it.
Dependency review and Cargo policy execute only when the changed paths include
dependency manifests, lockfiles, policy, Dependabot configuration, or the
workflow itself; the aggregate verifies a controlled skip otherwise. Manual
dispatch and a weekly run provide explicit dependency-policy audits without
turning advisory drift into a recurring status on unchanged `main`.
A passing dependency-policy workflow does not constitute a full security audit
of FlashOS, its upstream operating-system components, or produced images.

Security vulnerabilities must be handled through the process in the [Security Policy](../.github/SECURITY.md), not through public verification logs alone.

## Release evidence

Candidate production and release publication are separate manual workflows.
The candidate workflow never publishes; the publication workflow never builds,
compresses, generates, attests, or substitutes candidate files.

### Exact candidate input

Candidate production accepts:

- a full source commit SHA;
- a semantic version equal to `FLASHOS_RELEASE_VERSION`;
- a repository-relative reviewed Markdown release-notes path; and
- an optional cold-cache diagnostic flag.

Before image work begins, the workflow proves that the source is either the
head of one non-draft PR or the exact-tree merged result of one PR. It verifies
that PR's successful `required` and `security-required` runs and records their
run IDs. A draft, unrelated commit, unequal merged tree, stale successful run,
or ambiguous PR association is rejected.

The reusable producer then builds the `flashos-release` disk and live images
once. Separate consumers verify checksums and boot those exact raw bytes over
NVMe and USB. Both release QEMU paths must pass on attempt one.

### Candidate contents

After runtime qualification, the same candidate run:

- downloads the qualified disk, live image, image SBOM, and image checksums;
- verifies the incoming checksums;
- carries the generated `cookbook.lock` that resolved the qualified image build;
- compresses the exact QEMU-qualified disk and live bytes and verifies that
  decompression retains their raw digests;
- generates a source-oriented CycloneDX SBOM before promoted binaries enter
  the workspace;
- promotes the image-oriented SBOM produced with the images;
- includes reviewed release notes, both QEMU logs, the target performance
  record, and the machine-readable QEMU result;
- creates and verifies release-candidate SHA-256 checksums;
- writes `candidate-manifest.json` binding the repository, producer run and
  attempt, source commit/tree, version, profile, qualifying PR run IDs, pinned
  inputs, raw image digests, both QEMU results, exact filename allowlist, sizes,
  and digests;
- creates build-provenance attestations for every candidate file; and
- uploads the resulting candidate as a workflow artifact.

The artifact name includes the producer run ID and run attempt. Reruns do not
replace or masquerade as an earlier candidate. Expired artifacts are not
recoverable publication inputs; produce and qualify a new candidate instead.

The two SBOMs have different scopes:

| SBOM        | Intended scope                                                                               |
| ----------- | -------------------------------------------------------------------------------------------- |
| Source SBOM | The repository and source dependency view scanned before promoted binaries are downloaded    |
| Image SBOM  | Staged target package payloads and recipe metadata associated with the built image artifacts |

Neither document should be interpreted outside its stated scope. An SBOM is an inventory artifact, not proof that every component is vulnerability-free.

### Publication boundary

The publication workflow accepts an exact existing tag and candidate run ID.
Its default mode is a non-publishing dry run. It verifies the selected run is a
successful `candidate.yml` workflow in this repository, selects its exact run
attempt, rejects missing/ambiguous/expired artifacts, and then checks:

- tag equality with `v<FLASHOS_RELEASE_VERSION>`;
- candidate source commit/tree equality with the tag commit/tree;
- manifest schema and pinned input graph against the tag checkout;
- the exact allowlisted inventory, regular-file boundary, sizes, and digests;
- every `SHA256SUMS` entry;
- decompressed disk/live digests against the raw images QEMU consumed; and
- absence of an existing GitHub Release.

When publication is explicitly selected, the protected `production`
environment repeats the download and validation immediately before creating
the release. Existing releases are immutable and never overwritten.

The published assets consist of:

- compressed x86_64 disk image;
- compressed x86_64 live image;
- source SBOM;
- image SBOM;
- reviewed release notes;
- QEMU logs, result, and target performance evidence;
- generated cookbook resolution;
- candidate manifest;
- `SHA256SUMS`.

The build-provenance attestations are associated with candidate subjects
through GitHub's attestation mechanism. They record workflow provenance; they
do not prove bit-for-bit reproducibility or independent review of the resulting
operating system.

## Physical hardware qualification

QEMU qualification and physical hardware qualification are separate evidence classes.

Before testing physical media:

1. complete the relevant source, profile, image, and QEMU checks;
2. retain the exact image checksum and repository revision;
3. follow safe device-selection and image-writing procedures;
4. record only behavior actually observed on the identified machine.

Physical qualification belongs in [Hardware Compatibility](hardware.md), which defines the accepted status terms, required device information, current results, and reporting format.

The following do not qualify a device:

- an upstream Redox compatibility report by itself;
- the presence of a matching driver in source;
- a successful QEMU boot;
- a successful boot on a different model;
- an unrecorded personal test without an identifiable image revision.

## Local verification workflows

### Fast host-side gate

Use this before a package or image build:

```bash
source ./flashos.sh
flashos check ci
```

Add target compilation when target-specific Flash code changed:

```bash
flashos check target
```

### End-to-end development-profile qualification

Select the development profile:

```bash
flashos profile dev
```

Then run:

```bash
flashos qualify all
```

The helper performs its local quality checks, builds both selected-profile images, and smoke-tests the resulting disk and live artifacts.

### End-to-end release-profile qualification

Select the release profile:

```bash
flashos profile release
```

Then run:

```bash
flashos qualify all
```

For this profile, the smoke helper enables the locked-root assertion.

Return the current shell session to the development profile when finished:

```bash
flashos profile dev
```

### Scope of the helper

`flashos qualify all` is a local convenience workflow. It does not perform:

- the hosted Docker clean-container build;
- workflow artifact upload and download;
- hosted checksum promotion;
- SBOM generation;
- dependency-review jobs;
- provenance attestation;
- GitHub Release publication.

Use local qualification to find failures before pushing a change. Use the hosted workflow result as evidence for the hosted pipeline and promoted artifacts.

## Interpreting results and failures

A failure identifies the boundary at which an expected condition was not met. Start with that boundary rather than assuming a root cause.

| Failure point          | What is known                                                      | First investigation area                                                 |
| ---------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| Formatting             | Tracked source differs from formatter output                       | The reported files and workspace toolchain                               |
| Root tests             | A host-side build-system assertion failed                          | Test output, recent root workspace changes, lockfile                     |
| Flash Clippy or tests  | A host-side Flash quality rule failed                              | Reported crate, target, fixture, or warning                              |
| Target compilation     | The selected binary did not compile for the target                 | Target-only code, dependencies, ABI, `redoxer` environment               |
| Python lint            | A CI script violates the configured lint rules                     | Reported file and diagnostic                                             |
| Product contract       | A static repository invariant failed                               | Exact `profile contract:` message and owning configuration               |
| Recipe build           | A package could not be produced                                    | Recipe source, revision, patch, dependencies, toolchain                  |
| Image build            | Installer or image assembly did not complete                       | Build log, package repository, filesystem tools, available storage       |
| Checksum verification  | Downloaded or staged bytes differ from the recorded digest         | Artifact transfer, staging, file replacement, incomplete download        |
| Boot marker timeout    | The expected serial marker did not appear                          | Earlier serial output, firmware, QEMU command, kernel or service startup |
| Interactive assertion  | Boot progressed, but a tested interaction failed                   | The scoped smoke log near the failed marker                              |
| Release root assertion | The release image accepted or did not reject the tested root login | Release profile, installed account database, login implementation        |
| Physical test          | The recorded device did not reach the expected state               | Device-specific firmware, controller, driver, and boot observations      |

Common categories are diagnostic starting points, not automatic explanations. For example, an absent login prompt could result from an earlier kernel failure, a service configuration change, a serial-routing problem, or simply a timeout on a slow host.

Preserve the complete failing log before rebuilding. A subsequent successful run may overwrite or replace the most useful evidence.

## Changing a verification contract

Verification code defines current product expectations. Change it deliberately.

When an intended system change requires a contract update:

1. identify the exact old assertion and why it is no longer correct;
2. update the implementation or profile that owns the behavior;
3. update `ci/check_profile.fsh` or `ci/qemu_smoke.py`;
4. keep failure messages specific enough to identify the violated boundary;
5. update the hosted workflow when orchestration or artifact flow changes;
6. update [CI/CD Contracts](../ci/README.md) with exact script or workflow behavior;
7. update this guide when the overall evidence model or public procedure changes;
8. rebuild and test both affected image forms;
9. test both development and release profiles when their shared contract is affected.

A contract may be broadened only when the new assertion is supported by executable evidence. Planned functionality must not be added to a verification table as though it already passes.

Do not remove an assertion solely because a change fails it. First determine whether the implementation regressed or the product requirement genuinely changed.

## Sources of truth

| Concern                                  | Primary source                                                        |
| ---------------------------------------- | --------------------------------------------------------------------- |
| Overall verification model               | This document                                                         |
| General development workflow             | [Development](development.md)                                         |
| Static product-profile contract          | [`ci/check_profile.fsh`](../ci/check_profile.fsh)                     |
| Advertised capability report             | [`ci/check_flashos_capability_report.fsh`](../ci/check_flashos_capability_report.fsh) |
| Target capability matrix                 | [`ci/check_flashos_target_matrix.fsh`](../ci/check_flashos_target_matrix.fsh) |
| QEMU runtime contract                    | [`ci/qemu_smoke.py`](../ci/qemu_smoke.py)                             |
| Change classification                    | [`ci/classify_changes.fsh`](../ci/classify_changes.fsh)               |
| Required CI aggregation                  | [`ci/aggregate_ci.fsh`](../ci/aggregate_ci.fsh)                       |
| Protected-main evidence transfer         | [`ci/check_main_qualification.fsh`](../ci/check_main_qualification.fsh) |
| Candidate evidence resolution            | [`ci/check_candidate_qualification.fsh`](../ci/check_candidate_qualification.fsh) |
| Candidate manifest validation            | [`ci/release_candidate.fsh`](../ci/release_candidate.fsh)             |
| Public local helper behavior             | [`flashos.sh`](../flashos.sh)                                         |
| Standard hosted CI orchestration         | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)             |
| Protected-main status workflow           | [`.github/workflows/main-qualification.yml`](../.github/workflows/main-qualification.yml) |
| Informational host coverage              | [`.github/workflows/coverage.yml`](../.github/workflows/coverage.yml) |
| Coverage report completeness             | [`ci/check_coverage.fsh`](../ci/check_coverage.fsh)                   |
| Codecov reporting policy                 | [`codecov.yml`](../codecov.yml)                                       |
| Image production and runtime consumption | [`.github/workflows/_image.yml`](../.github/workflows/_image.yml)     |
| Dependency-policy workflow               | [`.github/workflows/security.yml`](../.github/workflows/security.yml) |
| Release-candidate production             | [`.github/workflows/candidate.yml`](../.github/workflows/candidate.yml) |
| Release publication                      | [`.github/workflows/release.yml`](../.github/workflows/release.yml)   |
| Exact CI and artifact contracts          | [CI/CD Contracts](../ci/README.md)                                    |
| Physical device evidence                 | [Hardware Compatibility](hardware.md)                                 |
| Security reporting                       | [Security Policy](../.github/SECURITY.md)                             |

When descriptive documentation conflicts with an executable script or active workflow, inspect the implementation and correct the outdated documentation. A passing check should be described only in terms of the behavior that the check actually observes.

---

[← Previous: Public Automation](automation.md) · [Documentation index](README.md) · [Next: Hardware Compatibility →](hardware.md)
