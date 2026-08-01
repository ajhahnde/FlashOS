# Hardware Compatibility

[FlashOS](../README.md) › [Documentation](README.md) › Hardware

This document records the official physical hardware verification matrix, testing methodology, validation hierarchy, and safety rules for running FlashOS on bare-metal systems. It is intended for hardware testers, developers, and evaluators determining device compatibility or preparing physical boot media. Note that FlashOS is pre-alpha evaluation software; compatibility observations reflect specific tested revisions and carry no universal broad support guarantees.

## On this page

- [Qualification policy](#qualification-policy)
- [Validation levels](#validation-levels)
- [Test method](#test-method)
- [Current results](#current-results)
- [Device notes](#device-notes)
- [Known limitations](#known-limitations)
- [Testing FlashOS on another machine](#testing-flashos-on-another-machine)
- [Hardware report template](#hardware-report-template)
- [Upstream compatibility information](#upstream-compatibility-information)
- [Safety notes](#safety-notes)

## Qualification policy

To maintain rigorous engineering integrity, FlashOS distinguishes explicitly between theoretical software compatibility and verified bare-metal testing evidence. We categorize device expectations according to five strict evaluation tiers:
- **Upstream report:** A third-party observation recorded in the upstream Redox OS compatibility database. Suggests potential hardware compatibility but provides zero FlashOS qualification value.
- **Theoretical driver expectation:** Based on source code presence (e.g., AHCI, NVMe, or IHDA driver crates present in the package closure). Requires empirical proof before claiming function.
- **FlashOS start attempt:** An initial boot trial where firmware executes the live image bootloader, regardless of whether system completion or terminal interaction succeeds.
- **Validated device:** A machine that successfully boots a compiled FlashOS image to an interactive terminal, confirming working framebuffer display, keyboard input, account login, and basic FlashShell prompt access (`>> `).
- **Fully qualified device:** A verified system that extends validation by proving external pipeline execution, stable storage and audio driver initialization without fatal startup defects, and clean session shutdown or power-off without disk corruption.

## Validation levels

The status of every tracked test system is mapped cleanly to standardized validation terms:

| Validation Level | Definition |
|---|---|
| **Not tested** | Designated target hardware that has not yet undergone empirical FlashOS boot verification. |
| **Boot observed** | Firmware executes the FlashOS bootloader and commences kernel initialization, but session login or interactive input is unconfirmed. |
| **Interactive** | Terminal session boots and permits character input, but full login shell execution or baseline pipeline checks remain incomplete. |
| **Validated** | Satisfies initial product release gates (such as the v0.1.0 baseline): successful live USB boot, functional display and keyboard input, console login, and active FlashShell prompt. |
| **Qualified** | Passes all verification criteria: reaches login, executes external-to-external pipelines, confirm driver initializations, and shuts down cleanly. |

## Test method

Physical hardware verification separates removable media evaluations from fixed installed disk evaluations:
- Use `redox-live.iso` exclusively for removable USB qualification. Its integrated live bootloader copies the entire compressed root filesystem directly into system RAM before kernel startup, decoupling active OS execution from slow or volatile removable USB storage buses.
- Use `harddrive.img` solely for virtual machine NVMe execution or fixed internal disk installation testing. It requires continuous early-root block device availability and should never be written to removable USB thumb drives.

## Current results

The single source of truth for current tested FlashOS hardware compatibility is summarized below. Where individual hardware subsystem tests have not been formally conducted, status is recorded neutrally as `Not tested` or `Unknown`:

| Device | Firmware | FlashOS revision | Boot | Display/input | FlashShell | Storage | Audio | Shutdown | Overall status | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| **QEMU x86_64 (`q35`)** | edk2 UEFI | v0.1.0 / Live | Passed | Passed | Passed | Passed (NVMe/USB) | Passed (IHDA null backend) | Passed | **Qualified** | Harddrive/NVMe and live/USB paths reach login, FlashShell, an external pipeline, and IHDA startup. |
| **Sony VAIO VPCEB4L1E** | BIOS/UEFI to be confirmed | v0.1.0 | Passed (USB live) | Passed (Keyboard & LCD) | Passed | Not tested | Not tested | Not tested | **Validated for v0.1.0** | `redox-live.iso` boots from USB with working display and keyboard, permits login, and reaches FlashShell. Full driver, pipeline, and shutdown qualification remains future work. |
| **21.5-inch iMac (2017)** | Apple EFI | v0.1.0 / Live | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | **Not tested** | Secondary target after the Sony qualification. |

## Device notes

- **Sony VAIO VPCEB4L1E:** Served as the physical validation machine for the v0.1.0 milestone release. Booting `redox-live.iso` from a USB mass-storage drive achieved full terminal console presentation, reliable built-in keyboard interaction, account authentication, and interactive FlashShell prompt operation. Verification of deep storage throughput, built-in audio playback, and ACPI shutdown sequences represents scheduled future work.
- **21.5-inch iMac (2017):** Retained as an official secondary hardware evaluation target. Empirical boot testing under Apple EFI firmware will initiate following completion of primary Sony laptop qualification.
- **QEMU x86_64 (`q35`):** Serves as the primary continuous integration and developer test bench, undergoing automated serial testing across both NVMe harddrive and USB mass-storage emulation paths.

## Known limitations

- **TUI-Only profile:** FlashOS contains no graphical X11, Wayland, or Orbital desktop servers. Hardware graphics card acceleration (NVIDIA, AMD, Intel GPU 3D rendering) is unused and unnecessary; display relies on standard framebuffer console drivers.
- **Evaluation account security:** Current published evaluation images contain passwordless user accounts and unauthenticated sudo privileges designed for frictionless local live media evaluation. Never connect test systems to untrusted networks.
- **Memory requirements:** Because `redox-live.iso` clones the operating system filesystem into RAM before boot, target physical machines require sufficient available system memory (minimum 2GB recommended) to accommodate the live image payload and runtime sysroot.

## Testing FlashOS on another machine

If you are evaluating FlashOS on unlisted physical hardware:
1. Ensure your host build environment has compiled a fresh, verified `redox-live.iso` image following [Getting Started](getting-started.md).
2. Perform exact read-only block device identification before committing image bytes to removable USB media.
3. Insert the live USB drive into the target machine, access system boot firmware, and select UEFI or legacy USB mass-storage booting.
4. Document observable boot events, serial logs, console initialization, keyboard responsiveness, and login completion.
5. If terminal access is achieved, test FlashShell pipeline execution (`^ls | ^wc -l`) and record observed audio or storage driver messages.

## Hardware report template

When submitting a qualified hardware compatibility report to the maintainer or opening an evaluation tracking issue, structure your testing evidence using this public reporting template:

```text
- Device Model: [Exact manufacturer and model number, e.g., Lenovo ThinkPad T480]
- CPU Architecture & Model: [e.g., Intel Core i5-8250U, x86_64]
- Firmware Mode: [UEFI / Legacy BIOS / Apple EFI]
- Tested FlashOS Artifact: [redox-live.iso / harddrive.img]
- Revision / Commit SHA: [e.g., v0.1.0 or exact Git commit hash]
- Boot Medium: [USB mass-storage / NVMe / SATA / Network iPXE]
- Observed Results:
  - Bootloader execution: [Passed / Failed]
  - Display & Framebuffer: [Passed / Failed / Text-only]
  - Keyboard & Input: [Passed / Failed]
  - Login & FlashShell: [Passed / Failed]
  - Pipeline Execution: [Passed / Failed / Not tested]
  - Audio Initialization: [Passed / Failed / Not tested]
  - Clean Shutdown: [Passed / Failed / Not tested]
- Serial Logs / Screenshots: [Attach clean serial boot logs or clear console output]
- Untested / Incomplete Functions: [Specify any hardware subsystems not checked]
```

## Upstream compatibility information

The historical hardware test tables compiled by the upstream Redox OS community are preserved in this repository at [Upstream Hardware Reference](upstream/REDOX_HARDWARE.md). These records offer valuable diagnostic clues regarding which networking, storage, and audio controller chipsets carry driver support within the borrowed kernel. However, upstream reports never substitute for empirical FlashOS testing and do not confer official qualification status.

## Safety notes

> **Caution:** Writing operating system disk images directly to raw physical block devices is an inherently destructive operation that irreversibly overwrites target disk structures.

To prevent accidental data destruction or filesystem corruption:
- Always execute read-only verification commands (such as `lsblk`, `diskutil list`, or equivalent OS tools) to positively verify device models, serial numbers, and storage capacities before executing write tools.
- Never rely on memorized or assumed device node labels (`/dev/sdX` or `/dev/diskN`), as operating systems dynamically assign device numbers upon boot or hardware insertion.
- Confirm that all partitions on the target USB storage device are fully unmounted before writing.
- Never write evaluation images to primary systems or drives holding critical personal data.

---

[← Previous: Verification](verification.md) · [Documentation index](README.md) · [Next: Roadmap →](roadmap.md)
