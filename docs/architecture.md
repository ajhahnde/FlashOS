# Architecture

[FlashOS](../README.md) › [Documentation](README.md) › Architecture

This document describes the current FlashOS system layers, image composition, build-to-boot path, and boundaries between project-owned components and inherited infrastructure. It is intended for developers and evaluators who need to understand how the x86_64 product profile is assembled without treating every capability present in the wider repository or upstream Redox ecosystem as a supported FlashOS feature.

## On this page

- [Architectural scope](#architectural-scope)
- [System context](#system-context)
- [Ownership and dependency model](#ownership-and-dependency-model)
- [Current system layers](#current-system-layers)
- [Image configuration](#image-configuration)
- [Build-to-image flow](#build-to-image-flow)
- [Boot-to-shell flow](#boot-to-shell-flow)
- [Flash integration](#flash-integration)
- [Verification boundaries](#verification-boundaries)
- [What this architecture does not imply](#what-this-architecture-does-not-imply)
- [Sources of truth](#sources-of-truth)

## Architectural scope

The current FlashOS product architecture is defined by the following boundaries:

| Area                        | Current boundary                     |
| --------------------------- | ------------------------------------ |
| Product architecture        | x86_64                               |
| Target ABI                  | `x86_64-unknown-redox`               |
| Primary environment         | Text-based console interface         |
| Primary user interface      | Flash at `/usr/bin/fsh`              |
| Primary evaluation platform | QEMU `q35` with x86_64 UEFI firmware |
| System maturity             | Pre-alpha                            |

The repository retains inherited build-system branches and recipes that refer to architectures other than x86_64. Their presence does not establish a FlashOS product profile, tested image, release target, or hardware-support commitment for those architectures.

The current product profiles are located under [`config/x86_64/`](../config/x86_64/). Hardware qualification is documented separately in [Hardware Compatibility](hardware.md), while future architectural direction belongs in the [Roadmap](roadmap.md).

## System context

FlashOS spans two distinct execution environments: the host-side build system and the target system contained in the generated image.

```text
Host environment
┌──────────────────────────────────────────────────────────────┐
│ Local configuration                                         │
│        ↓                                                     │
│ Make and container orchestration                             │
│        ↓                                                     │
│ Cross-toolchain and target sysroot                           │
│        ↓                                                     │
│ Cookbook recipes and package repository                      │
│        ↓                                                     │
│ Installer and filesystem tooling                             │
└───────────────────────────┬──────────────────────────────────┘
                            ↓
                  Bootable image artifact
                            ↓
Target environment
┌──────────────────────────────────────────────────────────────┐
│ Firmware                                                     │
│        ↓                                                     │
│ Bootloader                                                   │
│        ↓                                                     │
│ Kernel                                                       │
│        ↓                                                     │
│ Drivers, schemes, and system services                        │
│        ↓                                                     │
│ Console login                                                │
│        ↓                                                     │
│ Flash and external userspace commands                   │
└──────────────────────────────────────────────────────────────┘
```

The host environment produces an image for the target environment. Host-side utilities, container dependencies, and development-only Flash integrations are not automatically part of the generated operating-system image.

## Ownership and dependency model

FlashOS currently combines project-owned product components with inherited and external infrastructure. These categories must remain distinguishable.

| Category                               | Meaning                                                                                    | Examples                                                            |
| -------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| **FlashOS-owned component**            | Source or configuration maintained as a direct FlashOS product responsibility              | Image profiles, Flash, documentation, CI contracts                  |
| **Pinned upstream component**          | External source fetched at a specific revision and built as part of the image              | Kernel, bootloader, `relibc`, base services, utilities              |
| **Locally patched upstream component** | Pinned upstream source modified by repository-maintained patches                           | Kernel, bootloader, installer, and login branding or policy changes |
| **Inherited build infrastructure**     | Repository-local orchestration derived from the Redox build system and adapted for FlashOS | Root Cargo build crate, `Makefile`, `mk/`, Cookbook integration     |
| **Compatibility interface**            | A technical name that remains because the active ABI or tool still uses it                 | `x86_64-unknown-redox`, `relibc`, `redox_installer`, RedoxFS        |

A local patch does not convert the complete upstream component into a FlashOS-native implementation. For example, the kernel recipe applies FlashOS-specific visible branding to a pinned Redox kernel revision, but the kernel architecture, system-call model, driver framework, and most implementation code remain upstream dependencies.

Similarly, preserving an inherited technical identifier does not determine project identity. Names such as `x86_64-unknown-redox` describe active compatibility contracts and must remain until the corresponding interface is replaced, not merely renamed.

### Component origin and product ownership

A FlashOS-owned component does not necessarily originate entirely within the
FlashOS project. Existing open-source projects may be imported or forked when
they provide a suitable technical foundation.

Once adopted as part of the FlashOS user environment, such components may be
substantially modified in behavior, interface, architecture, and visual design.
FlashOS then assumes responsibility for the resulting product experience and
for maintaining its project-specific changes.

The Redox kernel is the deliberate exception. FlashOS intends to keep the
kernel close to upstream and modify or extend it only when concrete product,
hardware, or platform requirements make such changes necessary.

## Current system layers

### Host build orchestration

The root [`Makefile`](../Makefile) and files under [`mk/`](../mk/) coordinate:

- local configuration resolution;
- containerized or native build execution;
- cross-toolchain provisioning;
- package fetching and compilation;
- filesystem-tool compilation;
- image assembly;
- QEMU execution.

The default local path uses Podman, while hosted image qualification uses a dedicated container workflow. Containerization isolates many host dependencies, but it is a build boundary rather than a runtime feature of FlashOS.

### Cross-toolchain and target ABI

The build system targets:

```text
x86_64-unknown-redox
```

The prefix stage supplies the Rust, GCC, Clang, linker, runtime-library, and sysroot components needed to compile target packages. `relibc`, target support libraries, and the target triple remain part of the inherited Redox compatibility boundary.

The target ABI is therefore not a FlashOS-designed ABI. Code that compiles for a general Unix-like host does not automatically compile or behave identically on the FlashOS target.

### Bootloader and kernel

The bootloader and kernel are fetched through pinned recipes:

- [`recipes/core/bootloader/`](../recipes/core/bootloader/)
- [`recipes/core/kernel/`](../recipes/core/kernel/)

Both apply local patches for FlashOS-visible identity. The bootloader provides BIOS and UEFI outputs for architectures supported by its upstream recipe, but the active FlashOS product path uses the x86_64 UEFI output.

The kernel provides the low-level process, memory, scheme, interrupt, and hardware-driver foundation. FlashOS does not currently maintain an independent kernel implementation.

### Base system and services

The `base` and `userutils` packages provide inherited system initialization, login, and service infrastructure. The active profile supplements these packages with FlashOS-owned configuration for:

- console initialization;
- system hostname and release identity;
- login shells;
- scheme permissions;
- filesystem layout;
- development-network defaults.

Runtime drivers and services are selected through the package set and initialized by the installed system scripts. Their presence in an upstream source tree is not sufficient to classify them as active or qualified FlashOS functionality.

### Userspace utilities

The active image selects a small console-oriented userspace. It includes a mixture of Redox utilities, uutils-based commands, networking support, runtime libraries, and Flash.

These programs remain separate processes. Flash coordinates command execution but does not reimplement every external utility included in the image.

### Flash

Flash is the primary FlashOS-owned user-facing component. The package installs
the `fsh` shell and the separate `flash-language-server` protocol executable.
The active system profiles assign `/usr/bin/fsh` as the login shell for both
configured accounts; the language server is an editor-launched, non-executing
stdio service rather than a login interface.

Flash is a userspace process. It does not replace the kernel, system initialization, authentication service, filesystem, package manager, or external command implementations.

## Image configuration

FlashOS image composition is defined by three central configuration files:

| File                                                                          | Responsibility                        |
| ----------------------------------------------------------------------------- | ------------------------------------- |
| [`config/flashos-base.toml`](../config/flashos-base.toml)                     | Shared TUI-oriented system foundation |
| [`config/x86_64/flashos.toml`](../config/x86_64/flashos.toml)                 | Development image profile             |
| [`config/x86_64/flashos-release.toml`](../config/x86_64/flashos-release.toml) | Release image profile                 |

### Shared base profile

`flashos-base.toml` is a standalone base configuration rather than an extension of a graphical desktop profile. It defines the common package selection, filesystem structure, scheme access, networking defaults, and sudo-group membership used by both x86_64 profiles.

The declared base package set includes:

```text
base
bootloader
kernel
libgcc
libstdcxx
netdb
netutils
relibc
userutils
uutils
```

The base profile retains interfaces needed by the current console system, including framebuffer display, input, networking, audio, terminals, processes, and files. It does not grant the unprivileged account access to the Orbital scheme and does not recreate the inherited `/ui` compatibility path.

### Product-specific profile

The development and release profiles add:

```text
flash
coreutils
extrautils
```

They also define:

- the x86_64 filesystem size;
- the `flashos` hostname;
- FlashOS release identity files;
- console startup through `inputd` and `getty`;
- `/usr/bin/fsh` as the configured login shell.

These names are the packages explicitly selected by the image manifests. Cookbook may resolve additional recipe dependencies required to build and install them.

### Development and release variants

The development and release profiles are required to remain identical in their general settings, package selection, and installed files. Their intentional difference is the credential model.

The development profile contains convenience credentials for local evaluation. The release profile locks direct root login and removes the development passwords. This separation is enforced by the product-profile check, but it is not yet a complete first-boot account-provisioning system or a claim of production-ready access control.

Credential details belong in [Getting Started](getting-started.md) and the [Security Policy](../.github/SECURITY.md), rather than being duplicated throughout the architecture documentation.

## Build-to-image flow

The normal image build follows these stages:

1. **Configuration resolution**
   `.config`, command-line Make variables, and [`mk/config.mk`](../mk/config.mk) select the architecture, product profile, output directory, package-source policy, and container behavior.

2. **Cross-toolchain provisioning**
   [`mk/prefix.mk`](../mk/prefix.mk) prepares the compilers, linkers, runtime libraries, and target sysroot for `x86_64-unknown-redox`.

3. **Recipe resolution**
   The selected filesystem configuration is passed to the repository build tool. Cookbook resolves the explicitly selected packages and their recipe dependencies.

4. **Package construction or retrieval**
   Recipes fetch pinned source revisions, apply local patches where declared, and compile or retrieve target package artifacts.

5. **Host filesystem tools**
   The build compiles the host-side installer and RedoxFS tools used to create and populate the target image.

6. **Image assembly**
   [`mk/disk.mk`](../mk/disk.mk) creates a temporary image, invokes the installer with the selected configuration, and moves the completed temporary file to its final artifact path only after installation succeeds.

7. **Artifact output**
   The principal outputs are:

   ```text
   build/x86_64/<profile>/harddrive.img
   build/x86_64/<profile>/redox-live.iso
   ```

The installed disk and live image share the same product configuration but use different bootloader paths. The live-image target invokes the installer in live mode with the live bootloader, while the ordinary disk image is assembled as the persistent development or release disk.

The `.iso` suffix in `redox-live.iso` is an inherited build-interface name. It should not be renamed independently of the build, verification, and release contracts that consume it.

## Boot-to-shell flow

For the primary x86_64 path, the runtime sequence is:

```text
x86_64 UEFI firmware
→ FlashOS-branded bootloader
→ pinned Redox kernel with local branding patch
→ schemes, drivers, and init services
→ framebuffer console and input service
→ getty and login
→ /usr/bin/fsh
→ Flash built-ins or external userspace processes
```

The current QEMU configuration uses the `q35` machine model and normally exposes the main disk through an emulated NVMe interface. The live-image qualification path exposes the live artifact as USB mass storage.

After the kernel starts, installed initialization scripts launch the required services and console login process. Authentication reads the configured user data and starts the shell path associated with the selected account.

This sequence is verified automatically for the defined QEMU configurations. It does not establish equivalent behavior on arbitrary physical hardware.

## Flash integration

Flash source is maintained as a nested Cargo workspace under [`components/flash/`](../components/flash/). The workspace separates syntax processing, runtime evaluation, platform contracts, platform adaptation, and the `fsh` command-line binary.

The system-image package is defined by:

```text
recipes/terminal/flash/recipe.toml
```

That recipe:

- snapshots tracked and non-ignored files from `components/flash/` in the
  current checkout;
- selects `crates/flash-cli` inside that snapshot;
- builds the binary named `fsh`;
- installs the resulting package into the target image.

In a clean CI or release checkout, the package input is therefore the Flash
tree belonging to that exact outer FlashOS revision. A local build also includes
tracked modifications and non-ignored untracked files under `components/flash/`
so component changes can be tested before commit. Ignored outputs such as Cargo
`target/` directories are never copied into the recipe source. Updating Flash
does not require a self-referential follow-up recipe SHA.

Flash also distinguishes host and target integrations at compile time. macOS and Linux development builds use host-oriented configuration, history, and line-editing integrations, while the Redox target selects its target terminal editor path. A feature demonstrated in a host build must therefore not be documented as available inside FlashOS until the target path and image have been checked.

Detailed language behavior and internal crate design belong in the [Flash Documentation](../components/flash/docs/README.md) and [Flash Architecture](../components/flash/docs/architecture.md).

## Verification boundaries

Architecture, build success, runtime qualification, and hardware support are separate claims.

### Product-profile contract

[`ci/check_profile.py`](../ci/check_profile.py) statically verifies repository-level product invariants, including:

- the exact declared package set;
- inclusion of the shared base profile;
- exclusion of selected graphical-stack identifiers;
- Flash login-shell paths;
- development and release profile alignment;
- release credential restrictions;
- required framebuffer, terminal, and audio scheme access;
- absence of Orbital and `/ui` profile paths;
- version alignment;
- the exact in-tree Flash workspace source and immutable revisions for shipped
  external Git recipes;
- post-package installation of the final FlashOS identity files;
- presence of required local branding patches without inherited Redox product
  identity additions.

This check validates configuration and repository structure. It does not boot an image.

### Runtime contract

[`ci/qemu_smoke.py`](../ci/qemu_smoke.py) boots an already-built image and checks the observable x86_64 QEMU path. Its assertions cover firmware and bootloader progress, kernel startup, selected driver initialization, the exact versioned FlashOS login identity, login, the Flash prompt, external pipelines, and target-side interactive editing behavior. The login assertion also rejects inherited Redox product-branding strings while retaining technical identifiers such as RedoxFS.

The smoke test consumes image bytes in snapshot mode and does not use a successful boot as permission to modify the promoted artifact.

### Artifact and release evidence

Ready-candidate workflows build and checksum the canonical hard-drive image,
then pass it to a separate NVMe QEMU consumer. Release workflows additionally
build and boot the live image, generate the image inventory, and package and
attest the qualified release candidate. Protected `main` receives its visible
qualification status by verifying exact tree identity with that pre-merge
candidate rather than by rerunning source tests.

These mechanisms provide traceability and evidence for specific artifacts. They should not be described as a blanket guarantee that every local build on every host is bit-for-bit identical.

The overall evidence model is documented in [Verification and Testing](verification.md), while exact script and workflow contracts belong in [CI/CD Contracts](../ci/README.md).

## What this architecture does not imply

### Other repository architectures are supported FlashOS targets

They are not. Generic inherited code paths for other architectures remain in the build system, but the current FlashOS profiles, CI qualification, public scope, and release path are x86_64-specific.

### Every upstream Redox feature is available

It is not. An upstream driver, package, architecture, or documented behavior becomes a FlashOS capability only when it is selected by the active profile and supported by appropriate FlashOS evidence.

### FlashOS has an independent kernel and userspace stack

It does not. The project currently owns its product profile, identity, Flash, documentation, verification contracts, and selected patches while relying extensively on pinned upstream kernel, ABI, library, service, utility, packaging, and image-building components.

### Branding patches replace technical dependencies

They do not. Branding patches change selected user-visible strings and identifiers. They do not by themselves alter the ownership or underlying architecture of the patched component.

### TUI-only means no display, input, or audio support

It does not. The active profile excludes graphical desktop and windowing stacks while retaining the framebuffer console, keyboard input, terminal, networking, and audio paths required by the current product contract.

### Flash is POSIX shell compatible

It is not intended to be a drop-in implementation of Bash or `/bin/sh`. Scripts and commands must follow the syntax and execution model documented for Flash.

### A successful QEMU boot qualifies physical hardware

It does not. Physical-machine support requires device-specific evidence maintained in [Hardware Compatibility](hardware.md).

## Sources of truth

Use the following files when evaluating or changing an architectural contract:

| Concern                        | Primary source                                                                    |
| ------------------------------ | --------------------------------------------------------------------------------- |
| Public product scope           | [`README.md`](../README.md)                                                       |
| Documentation responsibilities | [`docs/README.md`](README.md)                                                     |
| Shared image foundation        | [`config/flashos-base.toml`](../config/flashos-base.toml)                         |
| Development image profile      | [`config/x86_64/flashos.toml`](../config/x86_64/flashos.toml)                     |
| Release image profile          | [`config/x86_64/flashos-release.toml`](../config/x86_64/flashos-release.toml)     |
| Build-variable resolution      | [`mk/config.mk`](../mk/config.mk)                                                 |
| Cross-toolchain and sysroot    | [`mk/prefix.mk`](../mk/prefix.mk)                                                 |
| Package construction           | [`mk/repo.mk`](../mk/repo.mk) and package recipes under [`recipes/`](../recipes/) |
| Image assembly                 | [`mk/disk.mk`](../mk/disk.mk)                                                     |
| QEMU device model              | [`mk/qemu.mk`](../mk/qemu.mk)                                                     |
| Flash source architecture      | [`components/flash/`](../components/flash/)                                       |
| Flash image package            | [`recipes/terminal/flash/recipe.toml`](../recipes/terminal/flash/recipe.toml)     |
| Product-profile invariants     | [`ci/check_profile.py`](../ci/check_profile.py)                                   |
| Runtime qualification          | [`ci/qemu_smoke.py`](../ci/qemu_smoke.py)                                         |
| Release version                | [`versions.env`](../versions.env)                                                 |
| Hardware evidence              | [Hardware Compatibility](hardware.md)                                             |
| Future direction               | [Roadmap](roadmap.md)                                                             |
| Upstream reference material    | [Upstream References](upstream/README.md)                                         |

When these sources disagree, configuration, recipes, executable checks, and current code take precedence over descriptive text. The documentation should then be corrected without treating an outdated statement as an implemented system contract.

---

[← Previous: Getting Started](getting-started.md) · [Documentation index](README.md) · [Next: Development →](development.md)
