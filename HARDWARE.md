<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Hardware Compatibility</h1>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="ci/README.md"><b>CI/CD</b></a> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE"><b>License</b></a>
  </p>

</div>

---

This document tracks machines tested with the minimal x86_64 FlashOS image.
Upstream Redox OS reports remain useful for driver expectations but do not
count as FlashOS qualification.

## Validation levels

The physical release gate for v0.1.0 requires a successful live USB boot,
working display and keyboard input, login, and the `>> ` prompt.

A machine is fully qualified when it additionally:

- runs an external-to-external pipeline;
- reports the expected storage, input/display, and audio drivers without a
  fatal startup error;
- shuts down or exits the session without corrupting the image.

Use `redox-live.iso` for removable USB qualification. Its live bootloader
copies the filesystem into memory before kernel startup. `harddrive.img` is
qualified as a virtual or installed-disk image and is not an early-root USB
image.

## Results

| Machine | Firmware | Status | Notes |
|---|---|---|---|
| QEMU x86_64 (`q35`, UEFI) | edk2 | Qualified | Harddrive/NVMe and live/USB paths reach login, FlashShell, an external pipeline, and IHDA startup. |
| Sony VAIO VPCEB4L1E | BIOS/UEFI to be confirmed | Validated for v0.1.0 | `redox-live.iso` boots from USB with working display and keyboard, permits login, and reaches FlashShell. Full driver, pipeline, and shutdown qualification remains future work. |
| 21.5-inch iMac (2017) | EFI | Not tested | Secondary target after the Sony qualification. |

The inherited Redox OS compatibility list is retained as an
[upstream reference](docs/upstream/REDOX_HARDWARE.md).

## Reporting

Include the exact FlashOS revision, image date, firmware mode, storage
interface, keyboard path, display result, and any relevant boot log. Before
writing an image, identify the destination device by model, size, and current
mounts. Never select a device from its name alone.
