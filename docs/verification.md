<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/flashos_logo_dark.png">
    <img src="../assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Verification and Testing</h1>

<p>
    <a href="../README.md"><b>README</b></a> ·
    <a href="README.md"><b>Documentation</b></a> ·
    <a href="development.md"><b>Development</b></a> ·
    <b>Verification</b> ·
    <a href="../ci/README.md"><b>CI/CD</b></a> ·
    <a href="../LICENSE"><b>License</b></a>
  </p>

</div>

---

This document defines the testing layers, verification model, QEMU qualification checks, and CI/CD alignment for FlashOS.

## Contents

1. [Verification layers](#1-verification-layers)
2. [CI-equivalent local checks](#2-ci-equivalent-local-checks)
3. [CI/CD architecture](#3-cicd-architecture)

## 1. Verification layers

Changes are accepted in layers:

1. **Host shell** — FlashShell tests and clippy pass.
2. **Target shell** — `fsh` builds for `x86_64-unknown-redox`.
3. **Recipe** — the FlashShell package cooks from the intended source.
4. **Image** — the `flashos` image builds with the expected identity, package,
   user, and shell metadata.
5. **QEMU** — login reaches `>> ` and an external-to-external pipeline runs.
6. **Hardware** — a physical device is tested only after the migration and
   image gates are complete.

The physical qualification criteria and current matrix are maintained in
[Hardware Compatibility](hardware.md).

## 2. CI-equivalent local checks

You can reproduce the exact automated product and runtime contracts locally without relying on hosted runners.

Validate the active TUI product boundary:

```sh
python3 ci/check_profile.py
```

After building the image, run the same runtime contract used by CI:

```sh
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/harddrive.img \
  --disk-interface nvme \
  --log build/x86_64/flashos/qemu-smoke.log
```

Qualify the live image through an emulated USB mass-storage device:

```sh
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/redox-live.iso \
  --disk-interface usb \
  --log build/x86_64/flashos/qemu-live-usb.log
```

The automation uses a null host audio backend but keeps an HDA controller in
the virtual machine. The guest IHDA driver must start for the test to pass.
The Docker build boundary, artefact handoff, security automation, and release
flow are described in [CI/CD](../ci/README.md).

## 3. CI/CD architecture

The automation preserves a strict producer/consumer boundary:

1. root build-system and FlashShell checks run independently;
2. the active package, TUI, login-shell, and audio policy is checked without
   building an image;
3. a FlashOS-owned Docker environment performs the clean-room x86_64 disk and
   live-image build;
4. both images and their checksums are uploaded as one immutable workflow
   artefact;
5. a separate runner downloads those exact bytes and boots the disk over NVMe
   and the live image over USB;
6. the smoke test verifies FlashOS branding, the TUI login, FlashShell,
   an external pipeline, and the IHDA audio driver;
7. scheduled security automation evaluates advisories, licenses, dependency
   sources, and newly introduced pull-request dependencies;
8. a semantic-version tag rebuilds and qualifies the image, emits checksums
   and a CycloneDX SBOM, records build provenance, and publishes the release.

The reusable image workflow is shared by continuous integration and release
delivery. Releases therefore cannot bypass the same runtime qualification
used on `main`. See [CI/CD](../ci/README.md) for the boundary table and local
contract commands.

---

[← Back: Development](development.md) · [Next: Hardware Compatibility →](hardware.md)
