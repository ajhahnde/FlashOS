# Source of Truth

[FlashOS](../README.md) › [Documentation](README.md) › Source of Truth

This page is the public routing register for FlashOS claims that are likely to
change as the project develops. It identifies what owns each fact, why the
public claim is justified, and what event requires it to be reviewed.

It is not a second configuration file. Values that can be derived from source,
configuration, Git, or release artifacts remain authoritative there. This page
owns the routing between those sources and the public documentation. It owns a
claim directly only when that claim is a deliberate public classification or
policy without a narrower executable owner.

## How authority works

Use the narrowest applicable source in this order:

1. **Executable state** — tracked configuration, manifests, source, recipes,
   scripts, and workflows define what the current tree builds or enforces.
2. **Recorded evidence** — immutable tags and release assets, successful checks,
   and device-specific test records define what was actually released or
   qualified.
3. **Public policy** — this register, the security policy, and the roadmap define
   classifications, support boundaries, and intended direction that cannot be
   inferred from implementation alone.
4. **Descriptive guides** — the README and guides explain the sources above.
   When they disagree with a narrower authority, correct the guide rather than
   changing implementation to preserve stale prose.

Historical release notes, tags, assets, and hardware observations remain facts
about their exact recorded baseline. A newer result adds new evidence; it does
not silently rewrite old evidence.

## Identity, version, and maturity

| Public fact                                                                                        | Authoritative source                                              | Why the claim is justified                                                                                                                                                                                     | Review trigger                                        |
| -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| The product and repository are FlashOS.                                                            | `Cargo.toml`, active image profiles, `TRADEMARK.md`, and `NOTICE` | Build metadata, image identity, and the public identity policy agree on the product name.                                                                                                                      | Identity or repository-boundary decision              |
| FlashOS is an independent solo project, not an official Redox OS distribution.                     | `TRADEMARK.md` and `NOTICE`                                       | These files own the public relationship and attribution boundary; technical reuse does not transfer project ownership.                                                                                         | Ownership, affiliation, or trademark-policy change    |
| The current release version is the value resolved from `versions.env`.                             | `versions.env` and immutable `v<version>` Git tags                | The product-profile check binds Cargo metadata, image identity, README badges, and release delivery to that value. A tag records a published identity; changing the variable alone does not publish a release. | Version change, release candidate, or tag publication |
| FlashOS is pre-alpha software without compatibility, production-readiness, or delivery guarantees. | This register and [`.github/SECURITY.md`](../.github/SECURITY.md) | The current security, interface, hardware, and release limitations do not satisfy a stable or production support contract.                                                                                     | Deliberate maturity or support-policy decision        |
| Shipped history and pending public changes are separated.                                          | Immutable FlashOS tags and [`CHANGELOG.md`](../CHANGELOG.md)      | Released changelog sections describe published baselines; `[Unreleased]` describes the pending public delta and is not itself a release.                                                                       | Every user-visible change and release                 |

## Product and platform boundary

| Public fact                                                                                                                                                         | Authoritative source                                                                                         | Why the claim is justified                                                                                                                                                 | Review trigger                                                    |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| The active product architecture is x86_64 with the `x86_64-unknown-redox` target ABI.                                                                               | `config/x86_64/`, active recipes, Cargo configuration, and image workflows                                   | The tracked product profiles, package builds, and qualification jobs select that architecture and ABI. Historical or intended architectures do not create current support. | Profile, target, toolchain, or architecture change                |
| The product environment is TUI-only; framebuffer display, input, networking, storage, and audio remain in scope while graphical desktop stacks remain out of scope. | `config/flashos-base.toml`, `config/x86_64/flashos.toml`, and `ci/check_profile.py`                          | The active package and permission closure retains terminal-relevant facilities and rejects graphical product paths.                                                        | Package, permission, interface, or product-scope change           |
| Flash at `/usr/bin/fsh` is the primary interface and the configured login shell.                                                                                    | `config/x86_64/flashos.toml`, `recipes/terminal/flash/recipe.toml`, and `ci/check_profile.py`                | Both product accounts select the installed Flash executable, and the product-profile contract checks that binding.                                                         | Account, shell, recipe, or executable-path change                 |
| The Flash image package comes from the current in-tree component checkout rather than a self-referential commit pin.                                                | `recipes/terminal/flash/recipe.toml`, `src/cook/fetch.rs`, and `ci/check_profile.py`                         | The filtered snapshot includes tracked and non-ignored component inputs, excludes generated targets, and binds clean CI/release builds to the same outer FlashOS checkout. | Workspace-source, component-path, or cleanliness-policy change    |
| FlashOS currently uses the Redox kernel and additional transitional Redox ecosystem layers; the intended long-term borrowed boundary is the kernel.                 | [`docs/architecture.md`](architecture.md), active manifests and recipes, and [`docs/roadmap.md`](roadmap.md) | The current dependency graph proves present reuse; the roadmap owns the intended transition and must not be presented as already implemented.                              | Dependency replacement, fork, vendoring, or architecture decision |
| A feature documented for the intended Flash v1 contract is not automatically available in the current binary or image.                                              | [`components/flash/README.md`](../components/flash/README.md), current Flash source, CLI help, and tests     | The component overview distinguishes current implementation from the v1 design; code and executable evidence decide current availability.                                  | Every coherent Flash feature slice or release                     |

## Images, verification, and releases

| Public fact                                                                                                                                            | Authoritative source                                                                 | Why the claim is justified                                                                                                                                         | Review trigger                                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| FlashOS has installed-disk and live-image build paths.                                                                                                 | Active profiles, `Makefile`, `mk/`, and `.github/workflows/_image.yml`               | The clean-room workflow produces both forms from one selected source/profile baseline. A documented command alone does not prove a successful build.               | Image layout, build target, profile, or workflow change                   |
| Source checks, target compilation, image construction, QEMU execution, physical hardware tests, and release publication are different evidence layers. | [`docs/verification.md`](verification.md), `ci/`, and active workflows               | Each layer proves a narrower contract and cannot substitute for a later layer.                                                                                     | Gate, assertion, job graph, or evidence-policy change                     |
| The public coverage badge reports host-executable Flash lines only.                                                                                    | `.github/workflows/coverage.yml`, `ci/check_coverage.py`, and `codecov.yml`          | The workflow instruments the Flash host suite and structurally validates its LCOV report; target, image, QEMU, kernel, and hardware paths are outside that report. | Coverage scope, generator, workspace, or reporting-policy change          |
| Exact CI job names, artifact flow, runtime assertions, and release mechanics come from executable automation.                                          | `.github/workflows/`, `ci/`, and [`ci/README.md`](../ci/README.md)                   | Workflows and scripts execute the contract; CI documentation explains it and must follow implementation changes.                                                   | Any workflow or `ci/` behavior change                                     |
| A published release is identified by an immutable matching tag and its exact assets, checksums, SBOMs, provenance, and release notes where provided.   | `versions.env`, `.github/workflows/release.yml`, Git tags, and GitHub release assets | These bind source identity to distributed bytes. A successful branch build or version edit does not constitute publication.                                        | Release workflow, artifact set, version, candidate, or publication change |
| Current security eligibility and evaluation limitations are policy claims, not implications of a passing security workflow.                            | [`.github/SECURITY.md`](../.github/SECURITY.md)                                      | Automated checks inspect selected source and dependency properties; the policy defines reporting scope, supported lines, and unqualified risks.                    | Security-boundary, credential, support, or reporting-policy change        |

## Hardware, licensing, and direction

| Public fact                                                                                                                             | Authoritative source                                                                                  | Why the claim is justified                                                                                                                                     | Review trigger                                                  |
| --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Public hardware claims apply only to an exact recorded artifact, device, and observation.                                               | [`docs/hardware.md`](hardware.md)                                                                     | Driver presence, upstream results, QEMU, and unperformed plans are not physical-device evidence.                                                               | New physical test or qualification-policy change                |
| The inherited root build infrastructure and Flash are MIT-licensed under separate copyright notices; third-party terms remain separate. | `LICENSE`, `components/flash/LICENSE`, `NOTICE`, Cargo metadata, and both dependency-license policies | License texts and notices define grants and ownership boundaries; automated policy checks validate declared package licenses without relicensing dependencies. | Relicensing, ownership, dependency-license, or notice change    |
| Current public priority and longer-term direction come from the public roadmap, not from commit count or elapsed time.                  | [`docs/roadmap.md`](roadmap.md)                                                                       | The roadmap records deliberate sequencing and completion criteria while excluding volatile task state and release promises.                                    | Initiative completion, ordering, platform, or boundary decision |

## Maintenance contract

When an authoritative source changes:

1. update the source that owns the behavior or decision;
2. run the checks appropriate to that source;
3. update this register if the claim, owner, rationale, or trigger changed;
4. update every descriptive public surface that projects the changed fact;
5. preserve old release and device evidence as dated history;
6. record user-visible changes in `CHANGELOG.md` `[Unreleased]`.

`ci/check_profile.py` enforces selected machine-readable relationships and the
presence of this register in the public navigation. Other claims require
evidence-aware review because a simplistic text comparison could turn intended
design, historical evidence, or policy into a false implementation contract.

---

[← Previous: Documentation Index](README.md) · [Documentation index](README.md) · [Next: Getting Started →](getting-started.md)
