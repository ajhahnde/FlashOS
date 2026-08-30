# Upstream References

[FlashOS](../../README.md) › [Product Guide](../README.md) › Upstream References

This directory keeps reference copies from Redox OS, which still provides much of FlashOS's technical foundation. They are useful for upstream context and attribution. They do not define current FlashOS behavior, dependency versions, hardware support, overall licensing, or project policy.

## On this page

- [Purpose and scope](#purpose-and-scope)
- [Retained references](#retained-references)
- [Snapshot status](#snapshot-status)
- [How to interpret upstream material](#how-to-interpret-upstream-material)
- [Current upstream boundary](#current-upstream-boundary)
- [Finding active dependencies](#finding-active-dependencies)
- [Hardware boundary](#hardware-boundary)
- [Trademark and identity boundary](#trademark-and-identity-boundary)
- [Maintaining these references](#maintaining-these-references)
- [Licensing and attribution](#licensing-and-attribution)
- [Related documentation](#related-documentation)

## Purpose and scope

FlashOS is an independent operating-system project. It is not an official Redox OS distribution, subproject, or product endorsed by the Redox OS nonprofit.

The current FlashOS implementation nevertheless relies on parts of the Redox ecosystem, including the kernel, target ABI, toolchain, libc, boot components, system services, package recipes, filesystem tooling, installer, and image-building infrastructure.

This directory exists to:

- preserve useful upstream context inside the repository;
- make the origin of selected inherited documentation visible;
- help developers investigate possible upstream hardware and driver behavior;
- keep Redox trademark guidance accessible when describing the relationship between the projects;
- prevent upstream observations from being silently presented as FlashOS evidence.

It is not:

- a complete inventory of FlashOS dependencies;
- the source of the revisions used by a FlashOS image;
- a substitute for current upstream documentation;
- a FlashOS hardware-support matrix;
- a FlashOS trademark policy;
- a software license or attribution notice;
- a promise that every documented upstream capability is available in FlashOS.

## Retained references

| File                                       | Upstream subject                                                    | Appropriate use                                                                                            | Not authoritative for                                                            |
| ------------------------------------------ | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| [`REDOX_HARDWARE.md`](REDOX_HARDWARE.md)   | Redox OS physical-device reports and upstream hardware observations | Identifying possible driver paths, known controller limitations, and candidate devices for FlashOS testing | FlashOS hardware qualification, current package selection, or support guarantees |
| [`REDOX_TRADEMARK.md`](REDOX_TRADEMARK.md) | Use of Redox OS names, logos, and related marks                     | Understanding the upstream project's stated trademark expectations                                         | FlashOS project identity, software licensing, or permission to use FlashOS marks |

The corresponding current files in the Redox OS repository can be consulted through its public mirror:

- [Current Redox hardware file](https://github.com/redox-os/redox/blob/master/HARDWARE.md)
- [Current Redox trademark file](https://github.com/redox-os/redox/blob/master/TRADEMARK.md)

The Redox OS repository and these reference files remain controlled by their respective upstream maintainers. FlashOS does not determine their terminology, status categories, policies, or update schedule.

## Snapshot status

The files in this directory are repository-local reference copies. They are not automatically synchronized with the Redox OS repository.

Consequently:

- the retained copy may be older than the current upstream file;
- an embedded date describes the upstream document, not the FlashOS release containing the copy;
- an upstream hardware entry may refer to a different kernel, bootloader, package set, desktop profile, or image;
- an upstream policy may have been revised after the copy was retained;
- a link or contribution instruction may refer to the Redox OS project rather than FlashOS.

Before relying on a time-sensitive upstream statement, compare the retained copy with the current upstream source.

The retained files also do not identify the source revisions used to build
FlashOS. External revisions are recorded in package recipes and dependency
lockfiles; the in-tree Flash package is bound to the current FlashOS checkout
through its workspace recipe.

## How to interpret upstream material

Apply the following rules when reading or citing an upstream reference.

### Upstream behavior is not FlashOS behavior

A successful Redox OS test demonstrates behavior of the recorded Redox image and configuration. It does not demonstrate behavior of a FlashOS image.

FlashOS can differ in:

- pinned source revisions;
- local patches;
- installed packages;
- startup configuration;
- account and permission policy;
- shell and user interface;
- image construction;
- runtime verification;
- supported architecture and hardware scope.

### Source availability is not image inclusion

A driver, service, utility, library, or architecture may exist in an upstream repository without being selected by the active FlashOS profiles.

To determine what enters a FlashOS image, inspect the active configuration and its resolved recipe dependencies rather than an upstream feature list.

### The upstream default branch is not the shipped revision

External Git-based packages selected for FlashOS images use explicit source
revisions. The current content of an upstream default branch may therefore
differ from the code used by a particular FlashOS image. Flash is maintained in
this repository and is selected from the same exact checkout through its
filtered workspace source.

When investigating behavior, begin with the revision in the relevant `recipe.toml`, not the latest upstream commit.

### A local patch does not transfer full ownership

FlashOS applies local patches to selected inherited components, including visible branding and product-specific integration changes.

Such a patch makes the modification a FlashOS responsibility. It does not make the complete upstream kernel, bootloader, installer, service, or utility a FlashOS-native implementation.

### Upstream desktop references do not change FlashOS scope

The retained hardware file may refer to Orbital, graphical variants, or other Redox desktop behavior.

FlashOS currently provides a text-based environment without a graphical desktop stack. An upstream graphical result does not establish equivalent FlashOS console behavior and does not change that product boundary.

### Upstream architecture support does not establish a FlashOS target

An upstream component may contain code for architectures other than x86_64. FlashOS supports an architecture publicly only when it has an active product profile, build artifact, runtime contract, and appropriate hardware evidence.

### Upstream project language remains upstream-specific

Terms such as “official,” “recommended,” “supported,” or “contribution guidelines” inside a retained file refer to the Redox OS project unless the surrounding text explicitly says otherwise.

They do not establish FlashOS governance, acceptance criteria, response commitments, or support levels.

## Current upstream boundary

The following table summarizes the present relationship without replacing the detailed system model in [Architecture](../architecture.md).

| Area                           | Current FlashOS relationship                                                | Primary repository evidence                                                                |
| ------------------------------ | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Kernel                         | Pinned Redox kernel source with local FlashOS patches                       | [`recipes/core/kernel/`](../../recipes/core/kernel/)                                       |
| Bootloader                     | Pinned Redox bootloader source with local FlashOS patches                   | [`recipes/core/bootloader/`](../../recipes/core/bootloader/)                               |
| Target ABI and libc            | Redox target ABI and `relibc` compatibility boundary                        | [`mk/prefix.mk`](../../mk/prefix.mk), [`recipes/core/relibc/`](../../recipes/core/relibc/) |
| System services and utilities  | Selected inherited packages built through repository recipes                | [`config/flashos-base.toml`](../../config/flashos-base.toml), [`recipes/`](../../recipes/) |
| Package and image construction | Inherited and adapted Cookbook, installer, RedoxFS, and Make infrastructure | [`Makefile`](../../Makefile), [`mk/`](../../mk/), [`src/`](../../src/)                     |
| System profile and identity    | Maintained by FlashOS                                                       | [`config/`](../../config/)                                                                 |
| Primary shell                  | FlashOS-owned Flash component                                               | [`components/flash/`](../../components/flash/)                                             |
| Verification and releases      | Maintained by FlashOS                                                       | [`ci/`](../../ci/), [`.github/workflows/`](../../.github/workflows/)                       |

This is an architectural summary, not a complete software bill of materials. Individual images can also include third-party packages that are neither developed by FlashOS nor part of the Redox OS project.

## Finding active dependencies

Use the repository's executable inputs when determining what a particular FlashOS revision builds.

| Question                                                       | Source of truth                                                                                                                      |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Which packages are declared for the product image?             | [`config/flashos-base.toml`](../../config/flashos-base.toml) and the selected profile under [`config/x86_64/`](../../config/x86_64/) |
| Where does a package's source come from?                       | Its `recipe.toml` under [`recipes/`](../../recipes/)                                                                                 |
| Which Git revision is used?                                    | The recipe's `[source].rev` value                                                                                                    |
| Which local patches are applied?                               | The recipe's `[source].patches` list and adjacent patch files                                                                        |
| Which additional recipe dependencies are resolved?             | Cookbook recipe metadata and dependency-tree inspection described in [Development](../development.md)                                |
| Which Rust dependency versions are selected?                   | The applicable committed `Cargo.lock`                                                                                                |
| How is the target toolchain assembled?                         | [`mk/prefix.mk`](../../mk/prefix.mk)                                                                                                 |
| How are packages and images assembled?                         | [`mk/repo.mk`](../../mk/repo.mk) and [`mk/disk.mk`](../../mk/disk.mk)                                                                |
| Which product invariants are checked statically?               | [`ci/check_profile.fsh`](../../ci/check_profile.fsh)                                                                                 |
| Which artifact contents were recorded for a release candidate? | The release's image SBOM, source SBOM, checksums, and provenance evidence                                                            |

The product-profile contract requires shipped Git-based recipes covered by that contract to use immutable commit revisions. This helps bind an image configuration to identified source inputs, but it does not make the retained files in this directory a dependency lock.

## Hardware boundary

[`REDOX_HARDWARE.md`](REDOX_HARDWARE.md) can provide useful investigation leads, such as:

- a controller family that may have an upstream driver;
- a firmware path that has previously reached a Redox boot stage;
- an upstream failure that may help explain a FlashOS result;
- a device that may be useful for a future FlashOS test.

It cannot establish that the same behavior exists in FlashOS because the tested source revision, package selection, image profile, user interface, and verification method may differ.

Do not copy an upstream device or status into the FlashOS hardware matrix without testing an identified FlashOS artifact on that physical device.

The only authoritative public location for FlashOS physical-device evidence is [Hardware Compatibility](../hardware.md). Its status model and evidence requirements take precedence over the categories used by the upstream reference.

QEMU results remain a separate emulated evidence class and do not convert an upstream or untested physical machine into a qualified device.

## Trademark and identity boundary

Redox OS, its logo, and related marks belong to the Redox OS nonprofit. References to Redox in FlashOS documentation identify technical origin, compatibility, or dependency boundaries and must not imply official status or endorsement.

Use the two policy documents for different purposes:

| Policy                                     | Scope                                                                                     |
| ------------------------------------------ | ----------------------------------------------------------------------------------------- |
| [`REDOX_TRADEMARK.md`](REDOX_TRADEMARK.md) | Upstream guidance concerning Redox OS names, logos, and related marks                     |
| [`TRADEMARK.md`](../../TRADEMARK.md)       | FlashOS project identity and the repository's description of its relationship to Redox OS |

Because upstream trademark guidance can change, compare the retained copy with the current upstream policy before making a new use of a Redox mark.

A software license does not automatically grant trademark rights. Conversely, a trademark policy does not replace the software licenses that govern source code and binaries.

## Maintaining these references

The retained reference documents are not ordinary FlashOS guides.

When maintaining this directory:

1. keep FlashOS interpretation and disclaimers in this `README.md`;
2. do not rewrite upstream statements as FlashOS statements;
3. do not insert FlashOS hardware results into the upstream hardware table;
4. do not alter upstream policy language to express FlashOS preferences;
5. correct a repository-local link only when necessary and without changing the upstream meaning;
6. compare any refreshed copy with an identifiable upstream source;
7. record the upstream revision or retrieval date in the associated change history where practical;
8. review this index when the set or purpose of retained references changes.

A selective rewrite can produce a document that is neither a faithful upstream reference nor a valid FlashOS contract. When an upstream copy requires substantive replacement, preserve the upstream text as a coherent reference and keep project-specific commentary outside it.

Updates to current FlashOS behavior belong in the responsible FlashOS documentation, configuration, recipe, test, or policy file rather than in these retained copies.

## Licensing and attribution

The files in this directory are only part of the repository's attribution structure.

The primary repository references are:

- [`NOTICE`](../../NOTICE) — project relationship and high-level attribution;
- [`LICENSE`](../../LICENSE) — primary MIT license for original FlashOS material;
- [`components/flash/LICENSE`](../../components/flash/LICENSE) — Mozilla Public License 2.0 for Flash;
- [`LICENSES/REDOX-BUILD-SYSTEM-MIT`](../../LICENSES/REDOX-BUILD-SYSTEM-MIT) — retained MIT license and copyright notice for the inherited Redox build-system code;
- [`LICENSES/REDOX-KERNEL-MIT`](../../LICENSES/REDOX-KERNEL-MIT) — retained MIT license and copyright notice for the incorporated Redox kernel;
- [`TRADEMARK.md`](../../TRADEMARK.md) — FlashOS identity and use of Redox references.

Third-party packages and inherited components retain their own licenses and copyright notices. The primary FlashOS license must not be interpreted as relicensing every dependency, package, or separately licensed component in the repository.

For an exact release artifact, use its accompanying source and image inventories together with the licenses and notices of the included components. This index is not a complete license report and does not modify any applicable license or trademark policy.

## Related documentation

- [Architecture](../architecture.md) — Current ownership, dependency, image, and compatibility boundaries
- [Development](../development.md) — Recipe inspection, source updates, patches, and package iteration
- [Verification and Testing](../verification.md) — Evidence layers and the limits of build and runtime results
- [Hardware Compatibility](../hardware.md) — Authoritative FlashOS physical-device evidence
- [Roadmap](../roadmap.md) — Intended evolution of transitional dependencies
- [Root README](../../README.md#what-ships-today) — Public project relationship summary
- [Attribution Notice](../../NOTICE) — Legal and project-origin attribution
- [Trademark and Project Identity](../../TRADEMARK.md) — FlashOS identity policy

---

[← Previous: Contributing](../../CONTRIBUTING.md) · [Documentation index](../README.md) · [Next: Flash Overview →](../../components/flash/README.md)
