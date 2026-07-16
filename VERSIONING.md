<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Versioning Policy</h1>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="PORT.md"><b>Port</b></a> ·
    <b>Versioning</b> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE.md"><b>License</b></a>
  </p>
</div>

---

This document is the authoritative policy for how FlashOS is
versioned, released, supported, and retired. It is the contract every
release of FlashOS honours; a breach of any clause stated with **MUST**
is a bug, not a feature.

FlashOS is, at the time of writing, **pre-stability**. The most
important thing this document does is mark that line clearly and
describe what changes — and what does not — when the project crosses
it.

Companion documents:

- [`DOCUMENTATION.md`](DOCUMENTATION.md) — the architectural overview,
  including the modules whose behaviour is named below.
- [`PORT.md`](PORT.md) — the lineage record of the Zig-to-Flash port.
- [`CHANGELOG.md`](CHANGELOG.md) — the per-release human-readable log.

The keywords **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and
**MAY** in this document are to be interpreted as described in
[RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

## 1. Scope

This policy governs every artefact released under the
[`ajhahnde/FlashOS`](https://github.com/ajhahnde/FlashOS) GitHub
repository. It applies to every tag of the form `vMAJOR.MINOR.PATCH`,
including the pre-stability `v0.y.z` line, **with the explicit
caveats** stated in §2.1 below.

## 2. Grammar

FlashOS follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)
over the surface defined in §3. Until v1.0.0, the special pre-1.0
clause of SemVer (§4) applies; see §2.1.

A release version is `vMAJOR.MINOR.PATCH` (the leading `v` is preserved
on every git tag, GitHub Release, and CHANGELOG section header)
optionally followed by a pre-release identifier as defined in §6.

| Component | Trigger                                                                                                                                                                                               |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **MAJOR** | A breaking change to any item enumerated in §3 _(reserved; no MAJOR bump has been issued yet — the first MAJOR is v1.0.0, the stability-freeze release)_.                                             |
| **MINOR** | Under pre-1.0 (§2.1): any change, including a breaking change. Under post-1.0: an additive change to the public surface — a new boot option, a new syscall, a new test-harness output line.           |
| **PATCH** | A bug fix, performance improvement, documentation change, build-system fix, or internal refactor that does not alter the public surface. PATCH is **always** backwards-compatible, including pre-1.0. |

A change that fits more than one bucket MUST take the most disruptive
applicable bucket.

### 2.1 Pre-v1.0.0 (current line)

Under SemVer 2.0.0 §4 a major version of zero is for initial
development and "anything MAY change at any time". FlashOS adopts the
literal reading of that clause for its `v0.y.z` line:

- A **MINOR** bump (`v0.y.z` → `v0.(y+1).0`) MAY include a breaking
  change to the surface enumerated in §3. Any such breaking change
  MUST be called out in the CHANGELOG entry (under `### Changed`, with the
  migration path) per the project's no-silent-breaking-changes rule.
- A **PATCH** bump (`v0.y.z` → `v0.y.(z+1)`) MUST NOT include a
  breaking change to the surface enumerated in §3. PATCH is
  backwards-compatible even pre-1.0.
- **No support guarantee** is made for any pre-v1.0.0 release. Only
  the latest pre-v1.0.0 tag receives any further attention; once
  v1.0.0 ships, the entire pre-1.0 line enters the **Archived** tier
  of §8 permanently.

### 2.2 Post-v1.0.0 (future)

From v1.0.0 onward the standard SemVer interpretation applies without
the §2.1 carve-out: a breaking change MUST take a MAJOR bump. Hardware
support tiers (§4) and deprecation procedure (§9) become enforceable.

## 3. Public surface

The **frozen public surface** of FlashOS, once v1.0.0 ships, is the
union of:

- **Boot contract.** The MMIO addresses, the kernel-load address,
  and the conventions documented in [`DOCUMENTATION.md`](DOCUMENTATION.md)
  §Boot path: the calling state from firmware (`ARM_LOCAL`, `_start`
  entry, EL2/EL1 transition expectations) and the serial console
  baud / framing for the platforms in Tier 1.
- **Serial console output format.** The kernel banner, the
  in-kernel `[TEST]` / `[PASS]` / `[FAIL]` test-harness tally lines,
  and the panic-on-fault format documented in [`DOCUMENTATION.md`](DOCUMENTATION.md).
  A regression in these lines breaks the boot-replay tooling and
  third-party harnesses that key off them.
- **Syscall numbers and ABI.** The mapping of syscall numbers to
  syscall entry points and the calling convention for each. Once
  enumerated under v1.0.0 in [`DOCUMENTATION.md`](DOCUMENTATION.md),
  removal or renumbering is a MAJOR change.
- **Build-system entry points.** The top-level `build.flash` targets
  the [`SETUP.md`](SETUP.md) names (`flash build`, run targets,
  deployment, and `flash build test`). Adding a target is a MINOR;
  removing or renaming a target is a MAJOR.
- **Hardware support matrix.** The OS×board tiers defined in §4.

The following are **explicitly NOT** part of the public surface and
MAY change in any release:

- The kernel's internal source layout — scheduler internals, page-
  table layout, exception-vector implementation, driver-internal
  function signatures, memory-manager free-list shape.
- The boot-asset bundle layout under `assets/` — the demo GIF format,
  the screenlog encoding, the VHS tape script.
- The CI workflow file shapes under `.github/workflows/`.
- The test-harness internals — only the per-line output format under
  §3 is frozen; the order, count, and identity of individual tests
  MAY change in any release.

## 4. Hardware support tiers

FlashOS commits explicitly to which hardware it intends to run on.
The model follows the Mesa driver tier convention.

| Tier                      | Promise                                                                                                                                                                                        | Boards                                                                                                                                                                                                                       |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Tier 1 — guaranteed**   | Every tagged release MUST boot to the kernel banner and pass the in-kernel test harness on this hardware. CI MUST exercise the boot path for every PR. A regression here is a release blocker. | Raspberry Pi 4 Model B (BCM2711, AArch64, 4-core); QEMU `aarch64` `-M raspi4b` (the version pinned in [`SETUP.md`](SETUP.md)).                                                                                               |
| **Tier 2 — best-effort**  | Building, booting, and the test harness SHOULD work, but no PR is blocked on a regression here and no PATCH is issued for a Tier-2-only defect.                                                | Other Raspberry Pi models; QEMU `aarch64` `-M virt` (deprioritized since [v0.5.0](https://github.com/ajhahnde/FlashOS/releases/tag/v0.5.0), the last release verified to boot it; no longer CI-gated) and other QEMU boards. |
| **Tier 3 — experimental** | Actively being worked on. May break in any release without notice or CHANGELOG entry.                                                                                                          | Anything not in Tier 1 or Tier 2.                                                                                                                                                                                            |

A board MUST NOT be promoted from Tier 2 to Tier 1 in a PATCH; the
promotion is a feature-add and goes in a MINOR. A demotion from Tier 1
to Tier 2 — or removal of the board entirely — is a **breaking
change** and MUST take a MAJOR bump once the project is post-1.0.

## 5. Release cadence

| Bump      | Target cadence                                                                                                                                                                                                                         | Hard rule                                                                                                              |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **PATCH** | As-ready.                                                                                                                                                                                                                              | Never blocked on a feature. A confirmed defect on Tier-1 hardware (§4) SHOULD reach a tagged PATCH within **14 days**. |
| **MINOR** | As-ready pre-1.0; soft target of one per month post-1.0.                                                                                                                                                                               | Each MINOR MUST boot cleanly on every Tier-1 board (§4) under the CI matrix.                                           |
| **MAJOR** | As-needed (post-1.0 only). A MAJOR MUST be announced under `## [Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md) and on the GitHub Releases page **at least 60 days** before its tag. The announcement enumerates every breaking change. | An RC train (§6) MUST precede the GA tag of any post-1.0 MAJOR.                                                        |

The §1.0.0 stability-freeze release is the **single exception** to the
60-day announcement window: v1.0.0 may be cut from the last
pre-v1.0.0 release without a fresh 60-day signal, because every
pre-v1.0.0 release is itself a signal that v1.0.0 is approaching.

## 6. Pre-releases

A pre-release tag carries the suffix `-rc.N` (release candidate; `N`
is a strictly increasing non-negative integer starting at `0`).
`-alpha` and `-beta` pre-release identifiers are **not** used.

- The first `-rc.N` of the project MUST be cut against `v1.0.0` once
  the surface defined in §3 is judged ready to freeze.
- Post-1.0, an RC MUST be used for every MAJOR. It SHOULD be used for
  any MINOR that materially changes default behaviour or boot output.
- An RC MUST be published to GitHub Releases marked as **pre-release**.
- The RC train ends when the corresponding GA tag is cut from the same
  commit as the last RC, with no behaviour change between the two.

## 7. Branching and tagging

- The default branch is `main`. Every release tag is reachable from
  `main` at the moment of tagging.
- Pre-v1.0.0: only `main` exists. Post-v1.0.0, a MAJOR line that is
  still under any support tier (§8) MUST have a `stable-X.Y` branch
  where its PATCH fixes are prepared. The branch is force-push-
  protected.
- A release tag MUST match the regex `^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$`.
- A release tag MUST be annotated (`git tag -a`). GPG-signed tags are
  the **target**; the signing key fingerprint will be published in the
  release that introduces them.
- A release tag MUST NOT be deleted, force-moved, or re-pointed. A
  defective release is handled by an immediate follow-up PATCH (the
  same procedure §10 of [`eeco`'s VERSIONING.md`](https://github.com/ajhahnde/eeco/blob/main/VERSIONING.md)
  formalises for that project; FlashOS will adopt the equivalent yank
  procedure with the v1.0.0 freeze).

## 8. Support windows

Under the §2.1 pre-1.0 clause, **no support tier exists yet**: only
the latest pre-v1.0.0 tag is the supported release. There is no
backporting, no security maintenance window, no LTS.

The support model that takes effect at v1.0.0 is:

| Tier            | Receives                                                                                                                                                                                | Applies to                                                          | Ends                                        |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------- |
| **Active**      | Every bug fix, every applicable feature, every security fix.                                                                                                                            | The **current MAJOR**.                                              | When the next MAJOR's GA ships.             |
| **Maintenance** | **Security fixes** and **critical bug fixes** (boot regression on Tier-1 hardware, syscall-ABI regression, panic-format regression that breaks the test harness). No feature backports. | The **previous MAJOR**.                                             | **6 months after the next MAJOR's GA tag.** |
| **Archived**    | Nothing.                                                                                                                                                                                | Every MAJOR older than Maintenance, and the entire pre-v1.0.0 line. | Permanent.                                  |

The trailing-maintenance window of 6 months is deliberately shorter
than eeco's 12 months because FlashOS is a research kernel: the
expected user is running source-built tags against bare metal or QEMU
and can rebuild from any commit if needed. The window is intended to
buy migration time, not multi-year stability — an **LTS** tier will
be designated only if and when the user surface justifies it; a future
amendment to this document MAY introduce one with an explicit start
tag and end date.

## 9. Deprecation policy

Under §2.1 pre-1.0, no deprecation procedure applies — a breaking
change in a pre-1.0 MINOR is documented in the CHANGELOG entry (under
`### Changed`) and that is the entire policy.

The deprecation procedure that takes effect at v1.0.0:

### 9.1 Announce

- A `### Deprecated` section is added to the next release's CHANGELOG
  entry, naming each deprecated item, the replacement (if any), and
  the earliest version in which the item MAY be removed.
- The deprecated item, where it has a runtime presence (a syscall, a
  boot option, a `[TEST]`-line tag), SHOULD emit a one-line notice on
  the serial console at first use per boot beginning with
  `flashos: DEPRECATED: ` and naming the replacement.
- [`DOCUMENTATION.md`](DOCUMENTATION.md) MUST mark the item with a
  `*(deprecated since vX.Y.0; removed in vM.0.0 or later)*` annotation.

### 9.2 Wait

The minimum window between the deprecation MINOR and the removal
release MUST be the longer of:

- **2 MINOR releases**, and
- **6 months** of wall-clock time.

### 9.3 Remove

- Removal MUST happen in a MAJOR. A PATCH or MINOR MUST NOT remove a
  deprecated frozen-surface item.
- The release that removes the item MUST list it in the `### Removed`
  CHANGELOG section for the release.

## 10. Security release policy

Until v1.0.0, FlashOS publishes no separate `SECURITY.md` — security-
relevant defects on Tier-1 hardware are treated as ordinary bugs and
fixed in the next PATCH. A public GitHub issue is the reporting
channel.

From v1.0.0:

- A `SECURITY.md` MUST exist at the repository root, modelled on the
  GitHub Private Vulnerability Reporting flow.
- The default embargo window between report and tagged fix is
  **90 days**, in line with Project Zero industry practice. Hardware-
  specific issues that require a Tier-1 board firmware coordination
  MAY extend to **120 days** by negotiation on the advisory thread.
- A security PATCH MUST be issued to every MAJOR line currently in
  **Active** or **Maintenance** tier (§8) that carries the defect.
- The CHANGELOG entry for a security PATCH MUST link the advisory
  (GitHub Security Advisory; a CVE identifier when one is assigned).

## 11. Roadmap signalling

A breaking change MUST NOT be a surprise.

- Pre-v1.0.0: each pre-1.0 release that contains a breaking change
  MUST call it out under `### Changed` in the CHANGELOG entry,
  describing the migration path inline in that entry.
- Post-v1.0.0: every breaking change planned for the next MAJOR MUST
  be listed under `## [Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md)
  **before** the first RC of that MAJOR. The list is updated whenever
  a candidate breaking change is added or removed; the diff itself is
  the public signal.

## 12. Governance

FlashOS is currently maintained by a single operator. A release MUST
be cut by:

1. A commit on `main` (or on a `stable-X.Y` branch for a post-1.0
   Maintenance PATCH).
2. Verifying that the in-kernel test harness passes for every Tier-1
   board (§4) — CI MUST be green and a real Pi 4B boot SHOULD be
   captured in `screenlog.0` when the change touches the boot path,
   the early-init sequence, or any console-output convention.
3. Adding the release section to [`CHANGELOG.md`](CHANGELOG.md),
   including any breaking-change migration notes.
4. Tagging the commit `vX.Y.Z[-rc.N]` and pushing the tag.

This policy MAY be amended; an amendment MUST itself follow the
versioning of this repository — a substantive change to the contract
is announced under `## [Unreleased]` and lands together with the next
release. A clarifying edit (typo, link rot, formatting) MAY land at
any time.

---

[← Prev: Port](PORT.md) · [Next: Changelog →](CHANGELOG.md)
