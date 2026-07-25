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

## Qualification gate

A machine is qualified when it:

- boots the FlashOS image;
- accepts keyboard input;
- permits login and reaches the `fsh> ` prompt;
- runs an external-to-external pipeline;
- shuts down or exits the session without corrupting the image.

## Results

| Machine | Firmware | Status | Notes |
|---|---|---|---|
| QEMU x86_64 (`q35`, UEFI) | edk2 | Qualified | Login, FlashShell prompt, and external pipeline verified. |
| Sony VAIO VPCEB4L1E | BIOS/UEFI to be confirmed | Pending | Physical test begins after the repository migration and local image gates are complete. |
| 21.5-inch iMac (2017) | EFI | Not tested | Secondary target after the Sony qualification. |

The inherited Redox OS compatibility list is retained as an
[upstream reference](docs/upstream/REDOX_HARDWARE.md).

## Reporting

Include the exact FlashOS revision, image date, firmware mode, storage
interface, keyboard path, display result, and any relevant boot log. Before
writing an image, identify the destination device by model, size, and current
mounts. Never select a device from its name alone.
