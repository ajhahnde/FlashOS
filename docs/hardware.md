# Hardware Compatibility

[FlashOS](../README.md) › [Documentation](README.md) › Hardware Compatibility

This document records device-specific evidence from running FlashOS on physical x86_64 systems. It defines how hardware results are classified, tested, and reported without converting upstream driver availability, QEMU behavior, or unperformed test plans into FlashOS support claims.

## On this page

- [Evidence policy](#evidence-policy)
- [Status model](#status-model)
- [Emulated reference baseline](#emulated-reference-baseline)
- [Current physical results](#current-physical-results)
- [Identify the artifact and device](#identify-the-artifact-and-device)
- [Prepare a physical test safely](#prepare-a-physical-test-safely)
- [Run the baseline test](#run-the-baseline-test)
- [Evaluate individual subsystems](#evaluate-individual-subsystems)
- [Report a result](#report-a-result)
- [Interpret upstream information](#interpret-upstream-information)
- [Current limitations](#current-limitations)
- [Sources of truth](#sources-of-truth)

## Evidence policy

A hardware result applies only to the tested combination of:

- exact device model and relevant modifications;
- firmware mode and configuration;
- FlashOS image profile;
- release tag or commit revision;
- image checksum;
- boot medium and storage interface;
- tests that were actually performed.

Changing any of these inputs can change the result. A report for one laptop model, firmware revision, or FlashOS release must not be generalized to related models or later images without another test.

FlashOS uses the following evidence rules:

1. **Physical observation is required.**
   A source file, driver recipe, upstream report, or successful QEMU run does not qualify a physical device.

2. **Each subsystem is reported separately.**
   Reaching FlashShell does not prove networking, audio playback, internal storage, suspend, or shutdown.

3. **Unknown remains unknown.**
   A subsystem that was not tested is recorded as `Not tested`, not inferred as either working or broken.

4. **Failures are valid evidence.**
   A reproducible boot failure or missing device path is useful when tied to an exact artifact and device configuration.

5. **Qualification is revision-specific.**
   A result remains historical evidence for its recorded image. It does not create an indefinite support guarantee.

6. **QEMU and physical hardware remain separate.**
   Emulated NVMe, USB, display, input, networking, and audio devices do not represent every physical controller implementing a similar function.

This file is the primary source of truth for public FlashOS physical hardware results. The broader testing model belongs in [Verification and Testing](verification.md).

## Status model

The overall status summarizes the highest physical test stage supported by the recorded evidence.

| Status              | Required evidence                                                                                                                                                                                   |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Not tested**      | No physical FlashOS attempt has been recorded for the device and artifact combination.                                                                                                              |
| **Boot failed**     | Firmware attempted to load the image, but the FlashOS bootloader, kernel, or console path did not reach the next expected stage.                                                                    |
| **Boot observed**   | FlashOS bootloader or kernel output was observed, but a usable console session was not established.                                                                                                 |
| **Console reached** | A visible text console and at least one usable keyboard input path reached the login interface.                                                                                                     |
| **Interactive**     | Login succeeded, FlashShell started, and the prompt accepted an interactive command.                                                                                                                |
| **Validated**       | The interactive baseline, an external pipeline, a non-destructive home-directory write/read/remove cycle, and a recorded shutdown or reboot outcome all completed on the exact identified artifact. |

`Validated` is a console baseline, not a statement that every hardware subsystem works. Audio, networking, internal storage, pointing devices, power management, and other functions retain separate results.

A device may therefore be `Validated` while an optional subsystem is explicitly reported as unsupported. Conversely, a device that reaches FlashShell but lacks the remaining baseline evidence is classified conservatively as `Interactive`.

## Emulated reference baseline

The primary automated reference environment is QEMU on x86_64 with the `q35` machine model and UEFI firmware.

The hosted runtime workflow separately exercises:

| Artifact         | Emulated attachment |
| ---------------- | ------------------- |
| `harddrive.img`  | NVMe                |
| `redox-live.iso` | USB mass storage    |

The QEMU smoke contract checks observable boot, login, FlashShell, external-process, filesystem, permission, and selected driver-startup behavior. It attaches the tested image in snapshot mode so that guest writes do not change the supplied artifact.

These results establish the expected emulated baseline before physical testing. They do not qualify a physical motherboard, firmware implementation, USB controller, storage controller, display adapter, keyboard, or audio codec.

See [Verification and Testing](verification.md) for the current runtime assertions and [`ci/qemu_smoke.py`](../ci/qemu_smoke.py) for the executable contract.

## Current physical results

Only devices with recorded physical FlashOS evidence are listed in this section. Planned test targets and devices appearing solely in upstream documentation are intentionally omitted.

| Device              | FlashOS artifact           | Boot medium      | Recorded evidence                                                    | Not recorded                                                                                                | Overall status  |
| ------------------- | -------------------------- | ---------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | --------------- |
| Sony VAIO VPCEB4L1E | FlashOS `0.1.0` live image | USB mass storage | Physical boot, display output, keyboard input, login, and FlashShell | Firmware mode, image checksum, external pipeline, internal storage, networking, audio, shutdown, and reboot | **Interactive** |

### Sony VAIO VPCEB4L1E

The published FlashOS `0.1.0` record confirms that the live USB image:

- booted on the physical machine;
- produced usable display output;
- accepted keyboard input;
- reached the login interface;
- completed login;
- started FlashShell.

The public record does not identify the firmware mode or artifact checksum and does not document the remaining validated-baseline checks. The result is therefore classified as `Interactive` rather than extending it to unrecorded subsystems.

No claim is made about:

- every unit or hardware revision sold under the same model name;
- internal SATA or other fixed-disk operation;
- Ethernet or wireless networking;
- audio initialization or audible playback;
- touchpad or external mouse input;
- suspend, resume, shutdown, or reboot;
- later FlashOS revisions.

## Identify the artifact and device

A useful result must allow another evaluator to identify what was tested.

### Published release artifact

For a published image, record:

- the release tag;
- the complete artifact filename;
- the profile represented by the artifact;
- the SHA-256 value from the release `SHA256SUMS`;
- whether the downloaded checksum verification succeeded.

Do not report only that the “latest image” was tested. That description becomes ambiguous as soon as another release is published.

### Local artifact

For a locally built image, record the repository revision:

```bash
git rev-parse HEAD
```

Record whether the source tree contained uncommitted changes:

```bash
git status --short
```

Calculate the live-image checksum on a host providing GNU Coreutils:

```bash
sha256sum build/x86_64/flashos/redox-live.iso
```

On macOS, the equivalent system command is:

```bash
shasum -a 256 build/x86_64/flashos/redox-live.iso
```

A report from a modified working tree must describe the relevant changes. A commit identifier alone cannot reproduce an artifact that also contained uncommitted source, profile, recipe, or patch modifications.

### Device identity

Record at least:

- manufacturer and exact model;
- whether the machine is an original configuration or has modified components;
- CPU architecture and model;
- relevant motherboard or system identifier;
- firmware type and version where available;
- enabled firmware mode, such as UEFI or legacy boot;
- Secure Boot state;
- boot-device type and connection;
- relevant internal storage, network, audio, display, and input controllers where known.

For a custom desktop, identify the motherboard and CPU rather than reporting only a case manufacturer or an informal computer name.

## Prepare a physical test safely

> **Warning:** Writing a system image to a physical storage device destroys the existing partition table and data on the selected destination. Selecting the wrong device can erase an unrelated USB drive, external disk, or internal system disk.

Use physical FlashOS images only on disposable test hardware and removable media whose contents can be lost.

Before writing an image:

1. complete the corresponding QEMU image build and runtime checks;
2. back up any data that must be retained;
3. use an empty or disposable USB storage device;
4. disconnect unrelated removable storage where practical;
5. identify the destination using read-only system tools;
6. verify its manufacturer, model, and capacity;
7. unmount all mounted volumes belonging to that device;
8. verify the destination again immediately before approving the write;
9. use a trusted graphical or command-line imaging tool appropriate for the host;
10. wait for the tool and the operating system to finish flushing writes before removing the device.

Useful read-only identification tools include:

```bash
lsblk
```

on Linux and:

```bash
diskutil list
```

on macOS.

Do not rely solely on a remembered device node such as `/dev/sdX` or `/dev/diskN`. Device identifiers can change when hardware is connected, disconnected, or the host restarts.

This guide deliberately does not provide a generic raw-device write command. The correct destination syntax and safe unmount procedure depend on the host, and an example with a placeholder device name can still be copied incorrectly.

### Choose the image

For removable-media evaluation, use the x86_64 live image:

```text
build/x86_64/flashos/redox-live.iso
```

The installed-disk artifact:

```text
build/x86_64/flashos/harddrive.img
```

has a separate image and QEMU contract. A successful NVMe QEMU result does not establish that the disk image can safely replace an operating system on a physical internal drive.

Establish removable-media behavior before considering any fixed-disk experiment.

### Protect other systems and networks

FlashOS remains pre-alpha evaluation software. Published evaluation images permit unauthenticated access through the regular console account, and the user can obtain elevated privileges.

Therefore:

- do not use a production workstation;
- do not attach disks containing valuable data;
- do not expose the system to an untrusted network;
- do not use the image for sensitive work;
- do not assume that filesystem or shutdown failures cannot occur.

The exact credential and security limitations are maintained in the [Security Policy](../.github/SECURITY.md).

## Run the baseline test

Use this sequence for a new physical device.

### 1. Record the initial state

Before booting, record:

- device identity;
- firmware version and mode;
- Secure Boot state;
- image revision and checksum;
- USB storage model;
- whether internal storage was connected;
- any firmware options changed for the test.

Changing firmware settings can affect the result. Preserve both the original setting and the tested setting in the report.

### 2. Select the removable image

Insert the prepared USB device and open the machine's firmware boot menu.

Record:

- whether the USB device appears;
- the label or path selected;
- whether the FlashOS bootloader appears;
- any immediate firmware error;
- whether legacy and UEFI entries are presented separately.

Do not describe the device as failing to boot FlashOS when the firmware never recognized the USB medium. Record that as a firmware or media-detection result.

### 3. Observe boot progress

Record the last visible stage reached:

```text
firmware
→ FlashOS bootloader
→ kernel startup
→ driver and service initialization
→ console login
→ FlashShell
```

When a failure occurs, preserve:

- the exact last visible line;
- panic or error text;
- a clear photograph or serial capture where available;
- whether the machine stopped, rebooted, or continued without display output.

### 4. Check display and input

Confirm separately:

- whether console text is visible;
- whether the display mode is usable;
- whether the built-in keyboard responds;
- whether an external USB keyboard responds, when tested;
- whether input remains responsive after login.

A working keyboard does not establish touchpad or mouse support. Report each input path independently.

### 5. Log in

Use the account behavior documented for the exact image profile. Development images, current release-profile images, and the historical `0.1.0` release do not share the same credential policy.

See:

- [Getting Started](getting-started.md)
- [Security Policy](../.github/SECURITY.md)

Record whether:

- the login prompt appears;
- the username is accepted;
- the expected password behavior occurs;
- `Login successful!` appears;
- FlashShell reaches its `>> ` prompt.

Do not publish passwords other than credentials already documented as part of the public evaluation image.

### 6. Check an external pipeline

At the FlashShell prompt, run:

```fsh
printf 'hardware\ncheck\n' | head -n 1
```

Expected output:

```text
hardware
```

This checks that FlashShell can start two external processes, connect their byte streams, receive the first process's output, and return control to the prompt.

### 7. Check a non-destructive filesystem path

Use only the test account's home directory:

```fsh
echo hardware-check > /home/user/hardware-test.txt
cat /home/user/hardware-test.txt
rm /home/user/hardware-test.txt
```

Expected read-back output:

```text
hardware-check
```

Confirm that the prompt returns after removal.

This verifies the active session's filesystem path. On a live image, it does not establish persistent writes to the USB device or support for the machine's internal storage controller.

Do not use internal disks, existing partitions, or mounted personal data for this check.

### 8. Record shutdown or reboot behavior

Record whether the machine:

- shuts down cleanly;
- reboots cleanly;
- hangs during shutdown;
- produces an error or panic;
- requires a forced power-off.

Do not infer a clean shutdown from the disappearance of display output alone. Where practical, boot the test medium again afterward and confirm that the image still reaches the expected initial state.

Only use shutdown or reboot commands known to exist in the tested image. Do not invent or substitute commands from Linux, Bash, or another operating system.

## Evaluate individual subsystems

The baseline result and subsystem results should remain separate.

### Firmware and bootloader

Record:

- UEFI, legacy BIOS, or another firmware path;
- whether Secure Boot was enabled;
- whether the removable device was discovered;
- whether the bootloader menu rendered;
- whether boot selection accepted keyboard input;
- the last stage reached after selection.

A firmware entry appearing in the boot menu is not itself a successful FlashOS boot.

### Display

FlashOS currently uses a text-oriented framebuffer console. It does not provide an X11, Wayland, Orbital, or other graphical desktop environment.

Record:

- whether text is visible;
- approximate resolution or obvious scaling problems;
- clipping, corruption, flicker, or blank output;
- whether output remains present through login;
- whether external and built-in displays were tested separately.

A visible framebuffer console does not prove accelerated GPU support.

### Keyboard and other input

Record each tested path separately:

- built-in keyboard;
- PS/2 keyboard;
- USB keyboard;
- touchpad;
- USB mouse;
- other input device.

Report partial behavior precisely. For example, normal keys, function keys, arrows, Backspace, and control combinations may not all behave identically.

### Removable and internal storage

A live USB boot establishes only the observed removable-media path.

It does not establish:

- internal SATA operation;
- internal NVMe operation;
- filesystem support for existing non-FlashOS partitions;
- safe installation beside another operating system;
- persistent modification of the live image;
- storage performance or long-duration reliability.

Do not perform destructive internal-disk tests merely to complete a report. A subsystem may remain `Not tested`.

### Networking

The shared FlashOS profile currently installs network defaults intended for the QEMU development environment. Physical networking may require different addressing and controller support.

Record separately:

- controller detection;
- Ethernet link state;
- address configuration;
- local-network reachability;
- external-network reachability;
- DNS resolution;
- wireless hardware detection, when examined.

Do not connect an unauthenticated evaluation image to an untrusted public network. Absence of connectivity should be reported without assuming whether the cause is the controller driver, link negotiation, static configuration, routing, or DNS.

### Audio

Distinguish at least three different results:

| Result                  | Meaning                                                           |
| ----------------------- | ----------------------------------------------------------------- |
| Driver startup observed | A relevant driver process or initialization message appeared      |
| Device path available   | The operating system exposed the expected audio interface         |
| Playback confirmed      | Audible output was produced through an identified physical device |

A driver-startup message is not evidence of audible playback. Record the controller, codec, output connector, and test method when playback is checked.

### Power management

Record shutdown, reboot, suspend, and resume independently. Do not infer support for one operation from another.

A forced power-off after a hang should be reported explicitly because it may affect filesystem integrity and the reliability of subsequent boots.

### Additional hardware

Report additional subsystems only when actually tested, for example:

- touchpads and pointing devices;
- USB hubs and external storage;
- battery reporting;
- system clock;
- Ethernet;
- wireless devices;
- multiple displays;
- built-in speakers and headphone output.

The absence of a subsystem from the report means `Not tested`, not `Passed`.

## Report a result

Reproducible hardware observations may be submitted through the repository's GitHub Issues.

Use a concise title such as:

```text
Hardware report: Sony VAIO VPCEB4L1E — interactive
```

No review, response, acceptance, support, or release timeline is guaranteed.

Do not open a public issue for a suspected security vulnerability. Use the private process in the [Security Policy](../.github/SECURITY.md).

### Report template

```text
## Device

- Manufacturer:
- Exact model:
- Custom or replaced components:
- CPU architecture and model:
- Motherboard or system identifier:
- Relevant controller identifiers:

## Firmware

- Firmware type:
- Firmware version:
- Tested boot mode:
- Secure Boot state:
- Firmware settings changed for the test:

## FlashOS artifact

- Image type: redox-live.iso / harddrive.img
- Image profile:
- Release tag or commit SHA:
- SHA-256:
- Working tree clean: Yes / No / Not applicable
- Relevant local modifications:

## Boot medium

- Medium type and model:
- Connection:
- Imaging tool:
- Host used to prepare the medium:
- Checksum verified before writing: Yes / No
- Internal drives connected during testing: Yes / No

## Results

- USB medium detected by firmware: Passed / Failed / Not tested
- FlashOS bootloader: Passed / Failed / Not tested
- Kernel startup: Passed / Failed / Not tested
- Console display: Passed / Failed / Not tested
- Built-in keyboard: Passed / Failed / Not tested
- External keyboard: Passed / Failed / Not tested
- Login: Passed / Failed / Not tested
- FlashShell prompt: Passed / Failed / Not tested
- External pipeline: Passed / Failed / Not tested
- Home file write/read/remove: Passed / Failed / Not tested
- Internal storage: Passed / Failed / Not tested
- Ethernet: Passed / Failed / Not tested
- Wireless networking: Passed / Failed / Not tested
- Audio driver startup: Passed / Failed / Not tested
- Audible playback: Passed / Failed / Not tested
- Shutdown: Passed / Failed / Not tested
- Reboot: Passed / Failed / Not tested
- Other devices:

## Overall status

- Proposed status:
- Last successful stage:
- Reproducible across repeated boots: Yes / No / Not tested

## Evidence

- Exact error or panic text:
- Serial log, if available:
- Console photographs or screenshots:
- Additional observations:
```

Before submitting, remove:

- private usernames;
- wireless credentials;
- IP addresses that identify a private environment unnecessarily;
- device serial numbers that are not required for reproduction;
- unrelated personal information.

## Interpret upstream information

The repository preserves the original [Redox OS Hardware Compatibility reference](upstream/REDOX_HARDWARE.md) for technical context.

That file may help identify:

- hardware classes previously exercised with Redox OS;
- controller families that may have an upstream driver path;
- known upstream firmware or device limitations;
- machines that could be useful candidates for FlashOS testing.

It does not establish FlashOS compatibility because:

- FlashOS uses its own system profile and package selection;
- the pinned kernel, driver, bootloader, and userspace revisions may differ from the upstream report;
- FlashOS is TUI-only rather than an upstream desktop image;
- the tested image and configuration are different;
- a historical result may no longer apply;
- upstream reports do not exercise FlashShell or FlashOS release contracts.

Do not copy upstream devices into the FlashOS result table until a physical FlashOS artifact has been tested and the evidence has been recorded.

Similarly, the existence of an AHCI, NVMe, USB, network, display, or audio driver in source is only an implementation lead. It is not a device result.

## Current limitations

The public hardware evidence is currently subject to these boundaries:

- FlashOS product images and automated qualification target x86_64.
- Only one physical device has a published FlashOS test record.
- The existing physical record covers the console path but not a complete validated-baseline run.
- No physical internal-storage result is currently published.
- No physical networking result is currently published.
- No physical audio playback result is currently published.
- No physical shutdown, reboot, suspend, or resume result is currently published.
- No minimum physical memory requirement has been established by published FlashOS evidence.
- The graphical desktop, accelerated graphics, and graphical-application compatibility are outside the current TUI-only product scope.
- Published evaluation images are not suitable for production or sensitive systems.
- A successful boot does not guarantee filesystem integrity, security, performance, or long-duration stability.
- Upstream Redox hardware results remain reference material rather than FlashOS qualification.

These limitations should be updated only when new device-specific evidence is available. Planned testing belongs in the [Roadmap](roadmap.md), not in the current-results table.

## Sources of truth

| Concern                                                  | Primary source                                                |
| -------------------------------------------------------- | ------------------------------------------------------------- |
| Current physical-device matrix and reporting rules       | This document                                                 |
| Historical verification of a released device result      | [CHANGELOG.md](../CHANGELOG.md)                               |
| Overall evidence model                                   | [Verification and Testing](verification.md)                   |
| Executable QEMU runtime contract                         | [`ci/qemu_smoke.py`](../ci/qemu_smoke.py)                     |
| QEMU machine and emulated-device configuration           | [`mk/qemu.mk`](../mk/qemu.mk)                                 |
| Removable and installed image construction               | [`mk/disk.mk`](../mk/disk.mk)                                 |
| Active FlashOS system profile                            | [`config/x86_64/flashos.toml`](../config/x86_64/flashos.toml) |
| Shared networking, permissions, and system configuration | [`config/flashos-base.toml`](../config/flashos-base.toml)     |
| Physical-media preparation boundary                      | [Getting Started](getting-started.md)                         |
| Evaluation credential and safe-testing limits            | [Security Policy](../.github/SECURITY.md)                     |
| Future hardware-testing direction                        | [Roadmap](roadmap.md)                                         |
| Historical upstream observations                         | [Upstream Hardware Reference](upstream/REDOX_HARDWARE.md)     |
| General hardware-report issue route                      | [Root README](../README.md#issues-and-security)               |

When descriptive text conflicts with the current configuration, executable contracts, or a release record, correct the outdated description and preserve the narrower evidence claim.

---

[← Previous: Verification](verification.md) · [Documentation index](README.md) · [Next: Roadmap →](roadmap.md)
