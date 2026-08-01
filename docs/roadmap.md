<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/flashos_logo_dark.png">
    <img src="../assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Roadmap and Future Direction</h1>

<p>
    <a href="../README.md"><b>README</b></a> ·
    <a href="README.md"><b>Documentation</b></a> ·
    <a href="hardware.md"><b>Hardware</b></a> ·
    <b>Roadmap</b> ·
    <a href="../ci/README.md"><b>CI/CD</b></a> ·
    <a href="../LICENSE"><b>License</b></a>
  </p>

</div>

---

This document summarizes the public future development direction of FlashOS as established in the technical documentation. This document is part of the ongoing public documentation restructuring; detailed initiative scheduling and milestones remain actively developed.

## 1. Permanent System Boundary and Kernel Evolution

FlashOS currently bootstraps from more of the Redox OS system than it intends to keep permanently. The intended long-term borrowed boundary is the kernel only.

- **Kernel Freedom:** The kernel may later be patched, forked, or vendored for FlashOS. If that work makes later Redox kernel updates impractical, update compatibility is optional.
- **Transitional Infrastructure:** Names such as `x86_64-unknown-redox`, `redoxer`, `relibc`, and inherited package identifiers remain during the bootstrap phase where they describe a real ABI or tool interface. Compatibility names disappear only when FlashOS owns a working replacement.
- **Base Package Pruning:** The inherited `base` package still carries functions that the minimal image may not need, including a development daemon. These are tracked as pruning candidates, while preserving required console display, input, audio, storage, and hardware-enumeration paths.

## 2. Hardware Qualification Goals

Physical hardware validation progresses systematically beyond initial USB boot:

- **Primary Device Qualification:** Full driver, pipeline, and shutdown qualification on primary target hardware (such as the Sony VAIO VPCEB4L1E) remains ongoing future work.
- **Secondary Targets:** Additional target systems (such as the 21.5-inch iMac) remain secondary targets after primary validation is complete.

## 3. Production Readiness and Security

- **Credential Lifecycle:** The passwordless evaluation account in current development images will be replaced by a credential set at first boot before FlashOS is presented as production software.

---

[← Back to Documentation Index](README.md)
