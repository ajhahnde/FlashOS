# Roadmap

[FlashOS](../README.md) › [Documentation](README.md) › Roadmap

This roadmap describes the intended public development direction for FlashOS, from the current pre-alpha system toward a more complete terminal-native operating environment. It communicates priorities and completion criteria rather than release dates, internal task tracking, or guarantees that every listed initiative will ship unchanged.

> **Project status:** FlashOS as a complete operating system remains pre-alpha software. While FlashShell component documentation describes the intended stable FlashShell v1.0 contract, not every v1 feature is automatically available in every current FlashOS image or on every target platform, and successful execution on a Linux or macOS development host is not automatic proof of FlashOS target support.

## On this page

- [How to read this roadmap](#how-to-read-this-roadmap)
- [Current foundation](#current-foundation)
- [Development sequence](#development-sequence)
- [Now: Complete FlashShell](#now-complete-flashshell)
- [Next: Qualify the next release](#next-qualify-the-next-release)
- [Next: Expand the terminal environment](#next-expand-the-terminal-environment)
- [Later: Reduce transitional dependencies](#later-reduce-transitional-dependencies)
- [Later: Broaden hardware and platform evidence](#later-broaden-hardware-and-platform-evidence)
- [Security and production direction](#security-and-production-direction)
- [Architectural non-goals](#architectural-non-goals)
- [How this roadmap is maintained](#how-this-roadmap-is-maintained)

## How to read this roadmap

The horizons used here express dependency and priority:

| Horizon   | Meaning                                                                                          |
| --------- | ------------------------------------------------------------------------------------------------ |
| **Now**   | The primary product initiative currently expected to receive focused development effort          |
| **Next**  | Work that depends on the current initiative or becomes the primary focus after it                |
| **Later** | Direction that remains part of the intended architecture but is not an active release commitment |

They are not calendar estimates.

FlashOS is maintained as an independent pre-alpha project. Priorities may change when implementation evidence, security findings, upstream changes, hardware results, or maintainer capacity reveal a better sequence.

This file intentionally does not contain:

- internal milestone numbers;
- private task lists;
- commit-by-commit progress;
- planned release dates;
- an exhaustive feature backlog;
- promises of support, review, or delivery.

Implemented and released changes belong in [CHANGELOG.md](../CHANGELOG.md). Current architecture, verification, hardware, and security claims remain authoritative in their respective documents.

## Current foundation

The roadmap begins from the following established product boundaries:

- FlashOS targets x86_64.
- The user environment is text-based and does not include a graphical desktop stack.
- FlashShell is installed as `/usr/bin/fsh` and serves as the primary interactive and scripting interface.
- Development and live images are built through separate persistent-disk and removable-media paths.
- Both image forms have automated x86_64 QEMU qualification contracts.
- Physical hardware claims are limited to individually recorded evidence.
- Release artifacts can be accompanied by checksums, separate source and image SBOMs, and build-provenance evidence.
- The current kernel, ABI, libc, boot, package, installer, and build foundations still depend substantially on the Redox ecosystem.
- The intended long-term borrowed boundary is the kernel, but replacement of other dependencies remains incremental rather than immediate.

These boundaries describe the starting point, not a claim that the operating system or FlashShell is complete.

For the exact current state, consult:

- [Architecture](architecture.md)
- [Verification and Testing](verification.md)
- [Hardware Compatibility](hardware.md)
- [FlashShell Documentation](../components/flashshell/docs/README.md)
- [Changelog](../CHANGELOG.md)

## Development sequence

The intended high-level sequence is:

```text
complete FlashShell as a coherent product
                ↓
qualify and publish an exact release candidate
                ↓
expand the FlashOS-owned terminal environment
                ↓
replace transitional system dependencies incrementally
                ↓
broaden physical hardware and architecture evidence
```

Some supporting work, such as documentation, dependency maintenance, security review, and hardware investigation, may occur throughout this sequence. The sequence indicates which product initiative should remain primary rather than requiring every supporting activity to stop.

## Now: Complete FlashShell

FlashShell is the defining user-facing component of FlashOS. The current priority is to complete it as a maintainable interactive shell and scripting language before beginning another major user-interface component in parallel.

Existing functionality such as direct external execution, explicit argument expansion, byte-stream pipelines, structured values, target-side line editing, history, multiline input, status branching, and interactive job control forms the baseline for this work.

### Multi-file scripts and modules

Planned work includes:

- canonical module loading;
- explicit imports and exports;
- cycle detection with useful diagnostics;
- script arguments;
- typed function signatures;
- stable name and signature resolution across files;
- clear separation between module scope and ambient shell state.

Module loading should not introduce wildcard mutation of unrelated scopes or rely on implicit execution of strings as source code.

### Discoverability and static checks

FlashShell should make nontrivial scripts understandable without requiring their execution.

The planned tooling direction includes:

- documentation comments;
- discoverable help for built-ins, functions, and signatures;
- formatter check and write modes;
- a non-executing `fsh check` path;
- parse, name, signature, and pipeline diagnostics;
- exit and error reporting suitable for CI use;
- stable source spans for editors and automated tools.

A language server is part of the intended FlashShell v1 toolchain. It should be built on stable parser and runtime-facing APIs rather than duplicating language behavior inside individual editor integrations.

### Runtime and target consistency

Interactive sessions and `.fsh` scripts should share the same language and evaluation rules wherever their input models permit it.

Work in this area includes:

- preserving exact argument-vector semantics;
- preserving explicit structured-to-byte conversion boundaries;
- aligning host and FlashOS behavior without hiding unsupported target capabilities;
- keeping redirected, non-interactive, and terminal-attached sessions distinct where the operating system requires it;
- validating configuration, history, cancellation, redirection, process lifetime, and terminal restoration on the target system.

Host behavior must not be presented as FlashOS behavior until the target build and image path have been exercised.

### Hardening toward a stable language release

While FlashShell component documentation describes the intended stable FlashShell v1.0 contract, before FlashShell can declare a completed v1 runtime release across all target platforms, the project intends to:

- expand lexer, parser, formatter, and evaluator fuzzing;
- stress pipelines, cancellation, jobs, and terminal transitions;
- audit NUL handling, non-UTF-8 paths, environment handling, command lookup, redirection order, descriptor ownership, and close-on-exec behavior;
- audit configuration and history ownership and permissions;
- document invariants around platform-specific `unsafe` code;
- execute public documentation examples in CI where practical;
- define evidence-based performance budgets;
- freeze the v1 grammar and public runtime contracts only after implementation and documentation agree.

### Completion criteria

FlashShell can move from the primary implementation initiative when:

- maintainable multi-file scripts can be loaded, checked, formatted, and documented;
- the claimed host and FlashOS feature matrices are explicit;
- the language server and other required v1 tooling operate against stable language APIs;
- host, target-build, QEMU, fuzzing, and security-relevant gates cover the supported surface;
- no known critical command-injection, descriptor-lifetime, terminal-corruption, process-lifetime, or data-loss defect remains open;
- public language and scripting documentation matches executable behavior.

This is a product-completion boundary, not a promise that FlashShell will stop evolving after v1.

## Next: Qualify the next release

After the active FlashShell scope reaches a coherent release boundary, FlashOS should qualify one exact candidate rather than treating independently rebuilt artifacts as interchangeable.

### Candidate definition

The release process should establish:

- one explicit source revision;
- one selected version and release scope;
- an immutable package and dependency input set;
- one installed-disk artifact;
- one live removable-media artifact;
- checksums generated immediately for those artifacts;
- source and image SBOMs with clearly stated scopes;
- provenance tied to the candidate artifacts;
- release notes describing observable changes and accepted limitations.

Version selection should follow the user-visible and architectural change set. It should not be chosen solely from elapsed time, commit count, or an internal milestone name.

### Qualification sequence

The exact candidate should pass the applicable layers in order:

1. source formatting, linting, and tests;
2. FlashShell target compilation;
3. product-profile and credential contracts;
4. clean-container image construction;
5. checksum and artifact-inventory verification;
6. installed-disk QEMU qualification over the defined NVMe path;
7. live-image QEMU qualification over the defined USB mass-storage path;
8. release-relevant security review;
9. physical hardware testing for every device claim included in the release;
10. final inspection of the downloadable candidate.

Downstream qualification should consume the promoted candidate bytes rather than rebuilding an unverified substitute.

### Release completion criteria

A candidate is ready for publication only when:

- source identity, version metadata, image identity, and release notes agree;
- checksums verify after every artifact handoff;
- the qualifying runtime tests consumed the candidate being published;
- SBOM and provenance subjects match the released artifacts;
- supported hardware claims are backed by the same candidate;
- known limitations are visible and consistent across the changelog, hardware documentation, and security policy;
- publication is an explicit maintainer decision.

A successful evaluation release does not imply production readiness, long-term support, or complete hardware compatibility.

## Next: Expand the terminal environment

After FlashShell completion, the next major product workstream is the broader FlashOS-owned terminal environment.

The objective is not to add a graphical desktop. It is to make the text interface feel like a coherent operating environment rather than a shell placed on top of an inherited collection of utilities.

### Shared terminal interface foundations

Potential work includes:

- reusable text-interface layout and input primitives;
- consistent keyboard navigation;
- common rendering and terminal-restoration behavior;
- predictable error, help, and confirmation patterns;
- accessibility within the limits of text terminals;
- support for narrow terminals and serial consoles;
- reusable test harnesses for terminal interaction.

Any shared interface layer should be designed for the actual FlashOS terminal path and should not assume that a Linux or macOS terminal library behaves identically on the target.

### Core terminal workflows

The intended direction includes improving terminal-native workflows for:

- navigating and inspecting files;
- viewing and editing text;
- examining processes and jobs;
- inspecting system and hardware state;
- managing configuration;
- reviewing logs and diagnostics;
- performing safe package or image-related operations where such interfaces become supported.

The preferred model is a small set of composable, keyboard-driven tools rather than a large collection of unrelated applications.

### Utility integration

Inherited `coreutils`, `extrautils`, and other terminal programs should continue to be tested against FlashShell's execution model.

Priority should be given to:

- exact argument behavior;
- standard input and output streaming;
- exit status handling;
- non-UTF-8 and binary data where supported;
- useful diagnostics;
- operation through serial and framebuffer consoles;
- predictable interaction with FlashShell pipelines and job control.

Replacing a utility is justified by a concrete FlashOS requirement, not by branding alone.

### Completion criteria

The terminal environment can be considered established when:

- common workflows are possible without relying on undocumented host assumptions;
- shared text-interface behavior is target-tested;
- utilities compose predictably through FlashShell;
- failure and recovery behavior is documented;
- the environment remains usable over the supported console paths;
- the package and dependency cost of each application is understood.

## Later: Reduce transitional dependencies

FlashOS currently depends on inherited Redox userspace, libraries, toolchains, package recipes, boot components, installer code, filesystem tools, and build orchestration.

The long-term direction is to narrow that dependency boundary deliberately. This is not a single migration project or a requirement to rewrite working infrastructure immediately.

### Incremental replacement order

Candidate areas include:

- unused packages and services;
- FlashOS-facing system utilities;
- package metadata and repository workflows;
- build orchestration;
- image assembly and installer behavior;
- boot configuration and tooling;
- runtime libraries or ABI-facing adapters where a concrete product need exists.

Each change should have an independently testable reason and exit criterion.

A replacement should not be accepted solely because it changes an inherited name. It should provide a measurable improvement in at least one relevant area, such as:

- product control;
- maintainability;
- target support;
- security;
- diagnosability;
- reproducibility;
- interface stability;
- package size or dependency reduction.

### Compatibility identifiers

Identifiers such as:

```text
x86_64-unknown-redox
redoxer
relibc
redox_installer
redoxfs
redox-live.iso
```

should remain wherever they describe active technical contracts.

They should be replaced only when the underlying ABI, tool, format, or artifact contract has actually been replaced and the new path has equivalent build and runtime evidence.

### Kernel boundary

The Redox kernel remains the intended borrowed kernel foundation.

FlashOS may maintain additional patches, vendor a revision, or diverge from upstream when a concrete FlashOS requirement cannot be met through the existing relationship. Continuous synchronization with every upstream kernel change is not an architectural requirement.

An independent kernel rewrite is not part of the current roadmap. Kernel divergence should begin only from a specific product or hardware need and must preserve a usable system throughout the transition.

### Completion criteria for a replaced dependency

A transitional component should be considered replaced only when:

- its responsibility and replacement boundary are documented;
- active profiles no longer depend on the old path;
- clean image construction succeeds without it;
- relevant runtime contracts pass;
- licenses and attribution remain correct;
- rollback or migration behavior is understood;
- public documentation no longer describes the removed component as active.

## Later: Broaden hardware and platform evidence

Hardware work should prioritize depth and reproducibility over the number of listed machines.

### Primary physical reference system

The existing Sony VAIO evidence should be deepened beyond the currently recorded interactive console baseline.

Useful additional evidence includes:

- exact artifact and firmware identification;
- repeated live-image boots;
- external FlashShell pipeline execution;
- home-directory write, read, and removal;
- internal storage-controller observation without destructive testing;
- network-controller detection and configuration;
- audio driver and audible playback testing as separate claims;
- clean shutdown and reboot behavior;
- failure recovery and image integrity after repeated sessions.

Only completed tests should be promoted into the hardware matrix.

### Secondary x86_64 reference system

After the primary physical path is repeatable, a second EFI-based x86_64 system can be used to expose assumptions tied to one firmware, storage controller, display path, or input implementation.

The purpose of a second system is not to create a broad compatibility list. It is to test whether the product contracts remain meaningful across materially different x86_64 hardware.

### AArch64

AArch64 remains a later platform initiative.

Any future AArch64 work should:

- start from the current Redox-kernel-based FlashOS architecture;
- define a new active image profile and qualification contract;
- avoid treating the archived former FlashOS implementation as a current platform contract;
- identify the target board and firmware path explicitly;
- establish target compilation, image construction, emulation where useful, and physical evidence separately;
- avoid weakening the x86_64 product while the second platform is introduced.

AArch64 support exists only when a current profile, artifact, runtime contract, and hardware evidence exist. Historical source or prior project releases do not satisfy those conditions.

### Completion criteria

A hardware or architecture target may enter the supported public scope only when:

- the exact target is named;
- an active profile and artifact exist;
- the build and runtime path is repeatable;
- subsystem results are recorded individually;
- untested behavior remains explicitly unclaimed;
- the documentation identifies the revision and artifact to which the evidence applies.

## Security and production direction

FlashOS evaluation images are intentionally easier to access than a production system. The current release profile locks direct root login, but the regular evaluation account remains passwordless and can obtain elevated privileges.

Before FlashOS can make a production-oriented or unattended-installation claim, it requires a stronger lifecycle for identity, installation, and recovery.

### Credential establishment

The intended direction includes:

- mandatory credential setup during first boot or installation;
- removal of universal evaluation credentials from production-oriented images;
- explicit recovery behavior;
- separation between live evaluation and installed-system policies;
- protection against accidental reuse of development credentials in release artifacts;
- documented handling of account creation, password changes, and privilege escalation.

### Installation and persistence

Production-oriented work also requires clear contracts for:

- installation to persistent storage;
- partition and data-loss safety;
- upgrades or image replacement;
- configuration persistence;
- failure recovery;
- filesystem integrity;
- shutdown and reboot;
- withdrawal or replacement of a defective release.

A bootable live image alone does not establish these properties.

### Security maturity

Future security work should include:

- a concise threat model;
- a maintained record of accepted security debt;
- review of FlashShell input, process, descriptor, history, and configuration boundaries;
- review of artifact substitution and dependency replacement risks;
- regression tests for reproducible findings;
- least-privilege release automation;
- clear disclosure and corrected-release procedures.

No production-security, isolation, or long-term-support claim should be made before the corresponding design, implementation, and evidence exist.

## Architectural non-goals

The following directions are outside the current roadmap.

### Graphical desktop and application stack

FlashOS does not plan to provide:

- X11 or Wayland;
- Orbital or COSMIC;
- a graphical window manager;
- a graphical desktop environment;
- a graphical installer;
- a general GUI application collection;
- a FlashOS-developed graphical terminal emulator.

Framebuffer use for the text console does not change this boundary.

### POSIX shell source compatibility

FlashShell does not aim to become a drop-in implementation of `/bin/sh`, Bash, or another POSIX shell.

The roadmap does not include:

- implicit word splitting;
- implicit wildcard expansion;
- `eval` or another general string-as-code interface;
- token-rewriting aliases;
- compatibility with every external program's terminal-specific behavior.

POSIX operating-system concepts may still inform process, descriptor, terminal, and job-control behavior where relevant.

### Bulk replacement of the inherited system

FlashOS does not plan to replace the entire Redox-derived stack in one rewrite.

Such a migration would combine too many independent risks:

- toolchain;
- ABI;
- libraries;
- userspace;
- package management;
- filesystem;
- installer;
- boot;
- drivers;
- kernel.

Each boundary should move only when the replacement can be built, tested, and maintained independently.

### Unqualified hardware breadth

The roadmap does not target a large compatibility table based on:

- upstream reports;
- driver source presence;
- vendor similarity;
- a successful QEMU boot;
- one successful boot on a related device.

A small set of deeply tested reference systems is preferred.

### Artificial release deadlines

FlashOS does not publish guaranteed release dates or feature-delivery deadlines.

A release is selected when its scope and evidence form a coherent candidate, not when a predetermined date arrives.

### Immediate kernel independence

The roadmap does not include a from-scratch kernel or a kernel fork created solely for project identity.

Kernel changes should follow concrete operating-system requirements.

## How this roadmap is maintained

This roadmap should be updated when:

- a major initiative becomes complete;
- the priority order changes;
- a new architecture or reference-hardware target is deliberately selected;
- a transitional dependency is formally replaced;
- a security or implementation finding changes the product direction;
- a release establishes a materially different baseline.

It should not be updated for every internal task or intermediate implementation step.

The following files own the current facts behind this direction:

| Concern                        | Primary source                                                      |
| ------------------------------ | ------------------------------------------------------------------- |
| Shipped and unreleased changes | [CHANGELOG.md](../CHANGELOG.md)                                     |
| Current system boundaries      | [Architecture](architecture.md)                                     |
| Development workflow           | [Development](development.md)                                       |
| Verification model             | [Verification and Testing](verification.md)                         |
| Physical hardware evidence     | [Hardware Compatibility](hardware.md)                               |
| FlashShell behavior            | [FlashShell Documentation](../components/flashshell/docs/README.md) |
| Release and evaluation limits  | [Security Policy](../.github/SECURITY.md)                           |
| Technical CI contracts         | [CI/CD Contracts](../ci/README.md)                                  |

Detailed scheduling, experiments, rejected implementation approaches, and volatile task state remain outside the public roadmap.

General proposals and reproducible implementation problems may be submitted through the issue route described in the [root README](../README.md#issues-and-security). Their submission does not guarantee adoption, review, or inclusion in a release.

---

[← Previous: Hardware Compatibility](hardware.md) · [Documentation index](README.md) · [Next: Upstream References →](upstream/README.md)
