<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/flashos_logo_dark.png">
    <img src="../assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>CI/CD</h1>

<p>
    <a href="../README.md"><b>README</b></a> ·
    <a href="../DOCUMENTATION.md"><b>Documentation</b></a> ·
    <a href="../SETUP.md"><b>Setup</b></a> ·
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
| Clean-room build | Build the x86_64 disk in a FlashOS-owned Docker image | OCI image layer history and build log |
| Promotion | Upload one checksummed disk image | GitHub immutable workflow artifact |
| Runtime qualification | Download and boot that exact artifact without rebuilding | `qemu_smoke.py` and serial log |
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
  --log build/x86_64/flashos/qemu-smoke.log
```

The QEMU test exposes an emulated HDA controller with a null host backend. That
proves the guest audio driver still starts without requiring audio hardware on
a headless CI runner.

---

[← Back: Setup](../SETUP.md) · [Next: Changelog →](../CHANGELOG.md)
