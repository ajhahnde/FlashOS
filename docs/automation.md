# Public Automation

[FlashOS](../README.md) › [Documentation](README.md) › Public Automation

Flash is the default language for public FlashOS automation when a usable
`fsh` can already exist at the execution boundary. Public non-Flash scripts
remain only where bootstrap, recovery, an external tool interface, or
independent correctness requires another interpreter.

## Native Flash programs

FlashOS installs these target programs from tracked `.fsh` source:

| Program | Source | Behavior preserved by the migration |
| --- | --- | --- |
| `auto-test` | `recipes/groups/auto-test/auto-test.fsh` | Exports full Rust backtraces, runs all three test suites in order even after an unsuccessful suite, and returns the last suite status |
| `acid-runner` | `recipes/tests/acid/acid-runner.fsh` | Enters `/home/user/acid`, runs `cargo test`, and returns its exact unsuccessful status without continuing |
| `relibc-tests-runner` | `recipes/tests/relibc-tests-bins/relibc-tests-runner.fsh` | Enters `/home/user/relibc-tests`, runs the Redox make target, and returns its exact unsuccessful status without continuing |
| `os-test-runner` | `recipes/tests/os-test-bins/os-test-runner.fsh` | Enters `/home/user/os-test`, builds the test reports, and returns its exact unsuccessful status without continuing |

Installed scripts use `#!/usr/bin/fsh`. Each owning package declares `flash`
as a runtime dependency; no script relies on interactive configuration or an
implicit POSIX-shell fallback. GitHub classifies tracked `.fsh` source as Shell
through `.gitattributes` while Flash remains the language and `.fsh` remains
its source extension.

## Expanded standalone migration gate

The fixed clean baseline contains 68 standalone `.sh` and `.py` sources. The
reviewed implementation route replaces 60 of them with genuine Flash programs
(88.24%) and retains eight exact files:

- `native_bootstrap.sh`, `podman_bootstrap.sh`, and `podman/rustinstall.sh`
  must work before Flash can exist;
- `flashos.sh` must run inside the caller's Bash or Zsh process;
- `scripts/network-boot.sh` needs guaranteed exit-time process-group cleanup
  that Flash 1.0 cannot yet express;
- `ci/qemu_smoke.py` retains incremental binary serial, deadline, and QEMU
  process observation;
- `components/flash/benchmarks/run.py` retains independent PTY, resource, and
  timing measurement of the candidate runtime; and
- `recipes/tests/hello-redox/files/test.py` is the deliberately Python program
  installed by that external-language example.

The percentage counts completed replacements, never planned paths, branch-local
additions, or the four target programs above. All 60 selected replacements now
exist. The Python public-automation checker and its focused unit test are two
additional reviewed independent-validation exceptions: they must reject a
missing, broken, or falsely successful candidate `fsh`, so implementing that
oracle in the runtime under test would make the trust boundary circular.

The two root legacy bootstrap paths contain no setup implementation; they are
pre-Flash compatibility redirects to `setup.sh`. `podman/rustinstall.sh`
remains the separate container/pre-Flash helper used inside the container
boundary and is not a general host setup path.

## Canonical setup boundary

`setup.sh` is the single documented operator-facing environment bootstrap. On
supported macOS arm64 and Linux x86_64 hosts it plans or installs the mapped
host packages, installs the distinct root and Flash Rust toolchains, invokes
the narrow Flash installer, acquires the byte-pinned automation tools, and
verifies the complete environment:

```bash
./setup.sh --plan
./setup.sh
./setup.sh --check
```

The plan is read-only and reports privileged package changes before elevation.
The apply path is idempotent. The check path is read-only and fails when any
required command, toolchain component, `fsh` version, tool manifest, or pinned
tool version is absent. The bootstrap never clones or updates Git, edits shell
startup files, starts an emulator, or accesses a physical device.

`build.fsh` is the primary source-build interface and preserves the former
build command's option, default, environment, output, filesystem-effect, and
status behavior. It requires a compatible host `fsh`. A host without Flash may
run `./install-flash.sh`; that narrow Bash adapter acquires the Flash runtime
from the checked-out component source, verifies `fsh 1.0.0`, installs it under
`${FLASH_INSTALL_PREFIX:-$HOME/.local}/bin`, and stops. It does not select build
arguments, defaults, policy, or Make targets.

The build program declares `printf`, `cut`, `dirname`, `basename`, `sh`, and
GNU Make as host executables. Flash performs every build decision. Because
Flash 1.0 has no list-slice expression, one fixed `sh` command removes the
already parsed option prefix and immediately `exec`s Make with the untouched
target argv; it contains no build default, policy, or fallback implementation.

The device helpers are also native Flash programs:
`scripts/dual-boot.fsh` refuses anything that is not a block device before it
builds or invokes `sudo`; `scripts/mount-redoxfs.fsh` accepts only a block
device or regular image and preserves explicit mount/unmount ordering; and
`scripts/ventoy.fsh` refuses an absent Ventoy mount before building or copying.
These checks do not replace operator identification and approval for a real
device write. Their automated parity suite uses temporary files and command
probes only.

Embedded Cookbook, workflow, Make, Docker, and iPXE bodies remain inventoried
outside the percentage because their owning tools impose the interpreter.
Bash startup files and Zsh integration remain their own external interfaces;
fixtures remain visibly classified. None authorizes a general second public
scripting layer.

## Declared host tools

Host-side Flash programs use the exact external parsing and search tool
versions recorded in `ci/automation-tools.json`: Taplo 0.10.0, jq 1.7.1, and
ripgrep 15.2.0. `FLASH_AUTOMATION_TAPLO`, `FLASH_AUTOMATION_JQ`, and
`FLASH_AUTOMATION_RG` may select explicit binaries; every program rejects a
different version before reading project data. Taplo converts TOML to JSON,
jq performs bounded JSON projection and stable encoding, and ripgrep exposes
source matches. Flash still owns schemas, policy, ordering, diagnostics, and
status decisions.

Acquire the byte-pinned tools for the supported macOS arm64 or Linux x86_64
host before running migrated host programs:

```bash
make flash-automation-tools
```

The target writes only under `build/flash-automation-tools/`, verifies every
download before extraction, and rejects unsupported host combinations. Its
pre-Flash bootstrap boundary requires Python 3 only to project the pinned JSON
manifest plus `curl`, `gzip`, `tar`, and a SHA-256 utility for acquisition.

Reusable, non-executable imports under `ci/lib/` are declared separately by
the inventory contract. They are checked as frozen-v1 Flash source but do not
inflate the 68-file migration denominator or numerator.

## Verification

The fail-closed inventory covers executable modes, recognized script
extensions and shebangs, sourceable shell files, embedded recipe and workflow
commands, installed generated scripts, Make/Docker/iPXE entry points, and
Flash roots:

```bash
python3 ci/check_public_automation.py
```

After building the candidate Flash runtime, acquire the isolated immutable
Flash 1.0 bootstrap and execute source formatting, static checks, ordered
success/failure behavior, cwd, argv, environment, output, filesystem, and
status parity through both runtimes:

```bash
make flash-bootstrap
python3 ci/check_public_automation.py \
  --bootstrap-runtime \
    build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh \
  --runtime components/flash/target/debug/fsh
```

The bootstrap manifest binds the fixed source commit and tree, pinned Rust
toolchain, exact `fsh 1.0.0` version, and binary SHA-256. The harness refuses a
missing, non-executable, wrong-version, crashing, always-success,
corrupt-output, or capture-overflow runtime before trusting migration results.
For release-candidate policy it materializes the frozen Python predecessor and
compares manifest semantics plus creation, validation, selection, tampering,
symlink, inventory, identity, and compressed-image outcomes through each Flash
runtime.

Any new surface or changed disposition must update the implementation,
inventory contract, tests, and this document together. Target package/image
integration and the disk/NVMe and live/USB QEMU paths remain separate required
evidence.

---

[← Development](development.md) · [Verification and Testing →](verification.md)
