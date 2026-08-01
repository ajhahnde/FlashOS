<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/flashos_logo_dark.png">
    <img src="../assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>CI/CD</h1>

<p>
    <a href="../README.md"><b>README</b></a> ·
    <a href="../docs/README.md"><b>Documentation</b></a> ·
    <a href="../docs/getting-started.md"><b>Getting Started</b></a> ·
    <b>CI/CD</b> ·
    <a href="../CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="../LICENSE"><b>License</b></a>
  </p>

</div>

---

This directory contains the product-specific contracts used by GitHub
Actions. The workflow YAML only orchestrates; checks that can run locally live
here.

## Pipeline boundaries

| Boundary | Responsibility | Evidence |
| :-- | :-- | :-- |
| Quality | Rust formatting/tests and FlashShell lint/tests | GitHub job results |
| Product contract | Exact package closure, TUI-only policy, FlashShell login, retained audio | `check_profile.py` |
| Clean-room build | Build the x86_64 disk and live images in a FlashOS-owned Docker image | OCI image layer history and build log |
| Promotion | Upload both checksummed images | GitHub immutable workflow artifact |
| Runtime qualification | Boot the exact disk over NVMe and live image over USB without rebuilding | `qemu_smoke.py` and serial logs |
| Security | Dependency review and Cargo policy | scheduled and pull-request security workflow |
| Candidate | Compress, checksum, SBOM, and attest every release dry run | release workflow and GitHub attestations |
| Delivery | Publish an already qualified and attested tagged candidate | GitHub release |

The stages are intentionally separated so a successful compile cannot stand
in for a successful boot, and a boot test cannot quietly rebuild different
bytes. Docker isolates the inherited cross-toolchain; QEMU consumes only the
promoted image.

Tagged delivery is additionally bound to `versions.env`; a tag that does not
match the live FlashOS version fails before packaging.

## Local contracts

```sh
python3 ci/check_profile.py
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/harddrive.img \
  --disk-interface nvme \
  --log build/x86_64/flashos/qemu-harddrive-smoke.log
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/redox-live.iso \
  --disk-interface usb \
  --log build/x86_64/flashos/qemu-live-usb-smoke.log
```

The QEMU tests expose an emulated HDA controller with a null host backend.
That proves the guest audio driver still starts without requiring audio
hardware on a headless CI runner. The USB run also proves the live bootloader
can detach startup from removable mass storage before the kernel takes over.

---

[← Back: Getting Started](../docs/getting-started.md) · [Next: Changelog →](../CHANGELOG.md)
