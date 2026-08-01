# Roadmap

[FlashOS](../README.md) › [Documentation](README.md) › Roadmap

This document summarizes the public development direction, architectural priorities, and long-term evolutionary milestones for FlashOS. It is intended for evaluators, developers, and contributors seeking to understand project trajectory and upcoming engineering initiatives. Note that as an independent solo project, this roadmap reflects strategic targets and intended technical outcomes rather than guaranteed release dates or contractual timelines.

## Current focus

Our primary immediate focus centers on solidifying the independent FlashOS product architecture and simplifying repository workflows:
- **Documentation and workflow maturity:** Establishing rigorous public documentation skeletons, unifying navigation structures, and publishing reproducible verification guidelines across all system layers.
- **TUI profile baseline enforcement:** Ensuring that the active x86_64 system profile strictly adheres to a clean, keyboard-driven terminal user interface without inherited graphical desktop dependencies.
- **Automated verification parity:** Maintaining separation between host quality gates, clean-room container builds, immutable release artifact promotion, and automated headless QEMU serial smoke testing.

## Next priorities

As current architectural foundations stabilize, immediate engineering efforts will shift toward deepening runtime quality and interface capabilities:
- **FlashShell runtime and evaluation depth:** Expanding structured values, robust pipeline streaming, job control semantics, and interactive terminal line editing within `fsh`.
- **Primary hardware qualification:** Advancing physical bare-metal testing on primary validated systems (such as the Sony VAIO VPCEB4L1E) beyond initial USB boot to encompass comprehensive driver checks, external pipeline execution, and clean ACPI shutdown qualification.
- **System utility refinement:** Ensuring core terminal utilities (`coreutils` and `extrautils`) operate predictably with FlashShell's explicit execution and byte stream contracts.

## Longer-term direction

Over the longer term, FlashOS seeks to mature from evaluation software into a distinct, minimal operating system tailored for ergonomic terminal workflows:
- **Production credential bootstrapping:** Replacing intentional passwordless evaluation accounts and blank user credentials in live USB images with secure, mandatory credential establishment during initial system boot.
- **Secondary hardware target qualification:** Extending bare-metal testing and qualification protocols to secondary reference hardware targets, including modern EFI architectures.

## System-boundary evolution

FlashOS currently leverages Redox OS toolchains, userspace packaging, and boot utilities as a transitional bootstrap foundation. Our long-term architectural goal is to refine this relationship until the borrowed boundary is restricted exclusively to the operating system kernel:
- **Base package pruning:** Systematically pruning unused services and legacy development daemons from the inherited base closure while strictly preserving necessary console display, keyboard input, audio driver (`IHDA`), and block storage enumeration paths.
- **Kernel independence:** Preserving the freedom to independently patch, fork, or vendor the borrowed kernel to serve FlashOS requirements. Should future kernel customizations diverge from upstream Redox architecture, continuous update compatibility will remain optional rather than mandatory.
- **Transitional infrastructure replacement:** Replacing technical compatibility identifiers (`redoxer`, `x86_64-unknown-redox`, and inherited artifact naming) only when native, fully verified FlashOS tooling alternatives are implemented and proven.

## Hardware direction

Physical hardware validation progresses systematically through verified empirical evidence rather than broad compatibility assertions:
- We prioritize deep, reproducible qualification on a small set of primary physical reference devices over wide, superficial boot trials.
- Driver support expectations are validated against exact live USB memory execution (`redox-live.iso`), ensuring consistent behavior across diverse storage controllers and physical consoles.

## FlashShell direction

As the hallmark user interface of FlashOS, FlashShell engineering prioritizes safe, composable execution over syntax legacy:
- **Structured data composition:** Broadening support for typed internal pipelines and explicit byte conversion filters (`from json`, `to json`, structured record streaming) alongside traditional byte stream programs.
- **Robust interactive ergonomics:** Refining multiline raw terminal input editing, context-aware command completion, searchable history persistence, and precise source span diagnostics.
- **Predictable scripting symmetry:** Preserving absolute behavior parity between interactive console sessions and standalone `.fsh` script execution without falling back on implicit string evaluation or POSIX word-splitting rules.

## Non-goals

To preserve project clarity and manageable maintainer scope, several strategic directions are permanently established as non-goals:
- **No graphical windowing stacks:** Developing or supporting graphical desktop environments, window managers (Orbital, COSMIC, X11, Wayland), graphical installers, or GUI client applications is permanently out of scope.
- **No POSIX shell compliance:** We deliberately reject POSIX compatibility in FlashShell in favor of typed values, explicit expansion spreads, and non-exceptional status branching.
- **No guaranteed timeline commitments:** As an independent project, we avoid claiming artificial release deadlines or unverified hardware driver compatibility promises.

## How this roadmap is maintained

This public roadmap represents the synthesized technical direction established in verifiable codebase implementations and published design invariants. It is curated directly by the repository maintainer during significant documentation updates and major version milestones. Detailed scheduling, internal experimentation notes, and fine-grained initiative mechanics remain managed independently to preserve public clarity and focus.

---

[← Previous: Hardware Compatibility](hardware.md) · [Back to Documentation Index →](README.md)
