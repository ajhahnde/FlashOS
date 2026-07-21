# 13. How FlashOS Tests Itself

FlashOS combines fast Rust host tests, an EL0 runtime harness, a strict QEMU
watchdog, static artefact gates, and real Raspberry Pi acceptance. No single
layer claims to cover the others.

## Host tests

```bash
cargo xtask test
```

At the current tree revision this discovers **751 Rust tests with 0 failures**.
The command's own output remains authoritative.

Coverage includes ABI layout, memory, scheduler, VFS/FAT32, descriptors,
crypto, account parsing, userland state machines, utilities, and `xtask`
generators and guards. Only the two bare-metal static libraries that cannot
link as host test binaries are excluded.

## Runtime harness

With `--boot-selftest`, `userland/init/pid1/src/harness.rs` runs exactly **30 EL0
scenarios**. They cover process/memory faults, ELF and ABI behavior, pipes,
console and filesystems, hardware-data parsing, credentials, login, and
password changes.

Every scenario emits `[TEST]` and then `[PASS]` or `[FAIL]`. It also checks the
physical free-page baseline after cleanup, turning leaked task, page-table,
pipe, file, or user pages into visible failures.

## QEMU watchdog contract

```bash
source flashos.zsh
run watchdog rpi4b
```

The live contract in `scripts/run_qemu_test.sh` requires:

- `30/30 passed`;
- no `[FAIL]` and no `ERROR CAUGHT`;
- **34** scenario/user checkpoints at `0xbbff1`;
- **one** boot-baseline checkpoint at `0xbc000`;
- a healthy entropy announcement;
- the exact ELF hello marker;
- three shell homescreen markers;
- completion inside 720 seconds.

The frozen `virt` matcher retains different checkpoint values, but is outside
the current release gate.

## Static gates

CI also runs formatting, Clippy with warnings denied,
`cargo xtask check-hygiene`, `asm-defs --check`, the zero-implementation
census, every user-payload inspection, and
`cargo xtask guard --board rpi4b --full`.

Artefact inspection rejects undefined symbols, `core::fmt`, FP/SIMD
instructions, duplicate memory providers, and size-budget violations. The full
guard performs the production build behind rejecting command shims and checks
the recorded subprocess trace.

## The CI pipeline

Every push and pull request replays this evidence chain on GitHub Actions
(`.github/workflows/ci.yml`). A `metadata` job derives the user-payload shard
matrix from `cargo xtask user --list`, so the workflow never hardcodes the
payload set. Five jobs then run in parallel: quality gates, host tests, the
contract guards, per-shard payload inspection, and the nested FlashShell
workspace's own checks under its pinned toolchain.

Only after all of them pass does a clean-room job perform the production
build, a second job stage a bootable test image from that exact artifact, and
`qemu-boot-test` boot it under the same watchdog contract described above —
uploading the serial log as a diagnostic artifact when a boot fails. A single
final `required` status aggregates the whole graph, giving branch protection
one stable name to pin. Two sibling workflows cover the rest: `security.yml`
reviews dependencies and enforces the cargo-deny policies (including
FlashShell's own), and `release.yml` packages and publishes tagged builds.

## Hardware acceptance

The exact release kernel and armstub must also pass on a Raspberry Pi 4B. Only
hardware can accept EMMC2 timing, two-boot FAT32 persistence, real metadata
mutation, and USB-C gadget enumeration/replug. QEMU remains the authoritative
inner-loop signal, not a substitute for those physical paths.

> [!IMPORTANT]
> Test counts are observations of a specific tree. Behavioral contracts—30
> scenarios, checkpoint counts, failure markers, and release gates—must be read
> from their live source when they change.

Next, we unpack the native build driver that produces the artefacts under test.
