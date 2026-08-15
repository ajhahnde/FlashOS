# Development

[FlashOS](../README.md) › [Documentation](README.md) › Development

This guide describes the repository-wide workflow for modifying FlashOS system profiles, build infrastructure, packages, and component integration. It assumes that the host environment and first development image already work as described in [Getting Started](getting-started.md); detailed verification contracts and Flash-internal development procedures are documented separately.

## On this page

- [Development boundaries](#development-boundaries)
- [Prepare the workspace](#prepare-the-workspace)
- [Repository layout](#repository-layout)
- [Choose the correct development path](#choose-the-correct-development-path)
- [Daily development loop](#daily-development-loop)
- [Build and run images](#build-and-run-images)
- [Develop packages and recipes](#develop-packages-and-recipes)
- [Modify system profiles](#modify-system-profiles)
- [Modify the build infrastructure](#modify-the-build-infrastructure)
- [Develop Flash](#develop-flash)
- [Manage generated state](#manage-generated-state)
- [Maintain versions and pinned sources](#maintain-versions-and-pinned-sources)
- [Update documentation](#update-documentation)
- [Before requesting review](#before-requesting-review)

## Development boundaries

FlashOS development spans several distinct layers:

| Layer                  | Primary paths                                 | Typical result                                                                 |
| ---------------------- | --------------------------------------------- | ------------------------------------------------------------------------------ |
| Product configuration  | `config/`                                     | Changes to installed packages, users, files, services, or permissions          |
| Package integration    | `recipes/`                                    | Target packages consumed by the image                                          |
| Build orchestration    | `Makefile`, `mk/`, `src/`, `podman/`          | Changes to package cooking, toolchains, image assembly, or container execution |
| Flash                  | `components/flash/`                           | Changes to the primary interactive and scripting interface                     |
| Verification contracts | `ci/`, `.github/workflows/`                   | Changes to repository, image, or runtime qualification                         |
| Public documentation   | `README.md`, `docs/`, component documentation | Changes to public usage and technical guidance                                 |

These layers do not provide equivalent evidence. A host-side unit test does not prove target behavior, a successfully cooked package does not prove image integration, and a QEMU boot does not establish physical hardware support.

Read [Architecture](architecture.md) before changing system boundaries. Use [Verification and Testing](verification.md) to determine which evidence is required after a change.

## Prepare the workspace

Complete the setup in [Getting Started](getting-started.md) before beginning repository development.

The standard local configuration is:

```make
PODMAN_BUILD?=1
ARCH?=x86_64
CONFIG_NAME?=flashos
```

Store these values in the repository-root `.config` file. The file is ignored by Git and must not be committed.

Inspect the effective configuration with:

```bash
make CONFIG_NAME=flashos setenv
```

The active product path should resolve to:

```text
ARCH=x86_64
CONFIG_NAME=flashos
BUILD=build/x86_64/flashos
```

### Optional development helpers

Bash and Zsh users may load the repository helper interface:

```bash
source ./flashos.sh
```

For Zsh-specific loading and completion support:

```zsh
source ./flashos.zsh
```

Useful orientation commands include:

```bash
flashos status
flashos doctor
flashos env
flashos help
```

The helpers delegate to the repository's Make, Cargo, Python, Git, and QEMU
interfaces. Normal build, inspection, and qualification commands do not commit
changes, push branches, create tags, or write physical media. The explicit
`flashos commit` command is a maintainer-facing exception: it can create a Git
commit and can push only when `--push` is requested and separately confirmed.

The helper maintains its selected architecture and profile in the current shell session:

```bash
flashos profile
flashos profile dev
```

### Repository question and commit helpers

Two optional commands use the Gemini Interactions API:

```bash
flashos ask "Where is external process execution handled?"
flashos ask --line-numbers "Where is the Flash image source selected?"
flashos commit "docs: clarify the host workflow"
flashos commit --generate
```

Set `GEMINI_API_KEY` or store it in the macOS Keychain under the service name
`GEMINI_API_KEY`. `flashos ask` sends the question, the tracked searchable-path
inventory, bounded repository excerpts, and the public project context to
Gemini. It excludes untracked and ignored files. `flashos commit --generate`
sends staged filenames, the staged diff, and the public commit context. Inspect
the relevant repository state before using either command.

`flashos commit` accepts only the repository house style: one English
Conventional Commit subject, at most 72 characters, and no trailing period.
Scope selection is deterministic rather than decorative:

- use `type(flash):` when Flash owns the primary effect;
- use `type(tools):` when the host developer tools own the primary effect;
- use an unscoped `type:` for pure CI, root build-system, release,
  repository-wide, or mixed-area effects;
- never repeat a type as a scope: use `ci:`, not `ci(ci):`.

`flash` and `tools` are the only accepted scopes. Thus
`build(flash): use the in-tree workspace source` and
`ci: trust the mounted workspace in image builds` follow the same rule.
Generated subjects are validated locally, require confirmation, and are
abandoned if the staged index changes before commit creation. A requested push
requires a second confirmation.

The normal development profile is `flashos`. The `flashos-release` profile exists for release-image qualification and should not replace the development profile during routine interactive work.

## Repository layout

The main development paths are:

```text
.config
    Local build configuration; ignored by Git

Makefile
mk/
    Root build orchestration and Make modules

src/
Cargo.toml
Cargo.lock
rust-toolchain.toml
    Host-side build-system support crate and pinned root Rust toolchain

config/
    Shared and architecture-specific image profiles

recipes/
    Package recipes, fetched source trees, patches, and package build rules

components/flash/
    Independent Flash Cargo workspace and component documentation

ci/
    Executable local product and runtime contracts

.github/workflows/
    Hosted quality, image, security, and release workflows

podman/
podman_bootstrap.sh
    Container build environment and host dependency bootstrap

docs/
    General public FlashOS documentation

versions.env
    Central FlashOS release-version value
```

The root Rust package, `flashos_build`, supports package and image construction. It is not the operating-system kernel.

Flash is an independent Cargo workspace under `components/flash/`. It has its own lockfile, Rust toolchain, package metadata, tests, and development documentation.

## Choose the correct development path

Before modifying files, identify the layer that owns the intended behavior.

### Change the installed system

Edit the relevant profile under `config/` when the change concerns:

- package inclusion;
- installed files or symlinks;
- users and login shells;
- service startup;
- scheme permissions;
- filesystem size;
- hostname or operating-system identity.

Do not modify an unrelated package recipe to compensate for a product-profile problem.

### Change how a package is obtained or built

Edit the relevant directory under `recipes/` when the change concerns:

- an upstream source URL or revision;
- a package build template;
- build flags;
- package dependencies;
- local patches;
- installed package contents.

A recipe describes package construction. It does not by itself place the package in a FlashOS image; the active profile must select the package directly or through a required dependency.

### Change image or toolchain construction

Edit `Makefile`, `mk/`, `src/`, or `podman/` when the change concerns:

- configuration resolution;
- Podman execution;
- cross-toolchain provisioning;
- Cookbook orchestration;
- host filesystem tools;
- disk or live-image assembly;
- QEMU invocation.

These paths are inherited build infrastructure adapted for FlashOS. Preserve active compatibility interfaces unless the change deliberately replaces the corresponding dependency.

### Change Flash behavior

Edit `components/flash/` when the change concerns:

- syntax or parsing;
- runtime evaluation;
- built-in commands;
- process execution;
- platform adapters;
- terminal input or line editing;
- the `fsh` command-line interface.

Use the component-specific [Flash Development Guide](../components/flash/docs/development.md) for its internal workflow.

### Change a verification requirement

Edit `ci/` or `.github/workflows/` when the intended product contract itself changes.

Do not weaken an executable check merely to make an unrelated implementation change pass. Determine whether the implementation violates an existing invariant or whether the invariant has genuinely changed, then update code, configuration, documentation, and verification together.

## Daily development loop

Use a progressive workflow so that inexpensive failures are found before a full image build.

1. **Start from the intended integration revision.**
   Create a focused working branch and verify that unrelated local changes are not present. Define the branch around one coherent review and rollback outcome, not around one commit, work session, implementation step, or checklist item.

2. **Inspect the owning configuration or code.**
   Check adjacent tests, recipes, profile entries, patches, and documentation before editing.

3. **Make the smallest coherent change.**
   Keep product configuration, implementation, tests, and documentation synchronized. Multiple dependent checkpoints may stay on the same branch until the complete outcome is ready to merge.

4. **Run the narrowest relevant host checks.**
   Format and test the workspace or script that was modified.

5. **Run product-profile validation when applicable.**
   Changes to profiles, package policy, identity, credentials, versions, or pinned recipe sources can affect the product contract.

6. **Build the affected package or image.**
   Use focused recipe iteration where possible, then rebuild the complete image when integration may have changed.

7. **Test the produced target artifact.**
   Use an interactive QEMU session during development and the defined smoke workflow when runtime evidence is required.

8. **Review the final diff.**
   Remove generated files, accidental formatting changes, debugging output, and local configuration.

Use a draft pull request when incomplete work benefits from hosted source
feedback. A complete, locally green change may open directly for review and
run its applicable candidate gates once. The full clean image and QEMU path
runs for ready changes that can affect produced artifacts or their runtime
qualification, and reruns after later candidate updates. Explicitly isolated
documentation, policy, reporting, and host-tool changes retain the stable
source aggregate without rebuilding the operating-system images. Protected
`main` relies on the exact-head checks enforced before merge and does not
repeat ordinary qualification afterward; weekly clean-room CI separately
detects hosted-environment drift.

The helper interface provides a concise view of the working tree:

```bash
flashos changes status
flashos changes diff
flashos changes stat
```

Equivalent Git commands may be used directly.

## Build and run images

### Development disk

Build the standard development disk:

```bash
make CONFIG_NAME=flashos all
```

Or use the helper:

```bash
flashos build disk
```

The resulting artifact is:

```text
build/x86_64/flashos/harddrive.img
```

Run it interactively:

```bash
make CONFIG_NAME=flashos qemu
```

Or:

```bash
flashos run disk
```

### Live image

Build the live image:

```bash
make CONFIG_NAME=flashos live
```

Or:

```bash
flashos build live
```

The resulting artifact is:

```text
build/x86_64/flashos/redox-live.iso
```

Run the live artifact through the configured QEMU path:

```bash
flashos run live
```

### Build both image forms

```bash
flashos build both
```

### Reassemble a stale image

When package repository state or generated image artifacts no longer reflect the selected configuration, use:

```bash
flashos build rebuild
```

The underlying `rebuild` target removes the current repository marker and both image artifacts before rebuilding the development disk. It does not perform a complete deletion of all toolchains, fetched sources, and container state.

Use broad cleanup only when narrower rebuilding cannot resolve the problem.

### Inspect generated artifacts

```bash
flashos artifacts list
flashos artifacts path disk
flashos artifacts path live
flashos artifacts hash all
```

Checksums produced locally identify the current files only. They do not by themselves establish that an artifact passed the project's qualification workflow.

## Develop packages and recipes

The repository build tool resolves recipes through Cookbook. Recipe names, source trees, build outputs, and image contents are related but separate.

### Inspect recipe resolution

Locate a recipe:

```bash
flashos recipe find flash
```

Show the configured cook tree:

```bash
flashos recipe tree
```

Show the dependency tree for a specific recipe:

```bash
flashos recipe tree flash
```

Inspect what would be pushed into the image:

```bash
flashos recipe image-tree flash
```

These commands are useful before changing package dependencies or assuming that a package is part of the active profile.

### Build a recipe

Cook a package without first cleaning its existing build output:

```bash
flashos recipe build flash
```

Clean and cook it again:

```bash
flashos recipe rebuild flash
```

Multiple recipe names may be supplied as a comma-separated list where the underlying recipe command supports it:

```bash
flashos recipe rebuild kernel,bootloader
```

Use a clean rebuild after changing:

- build flags;
- source revisions;
- patches;
- generated bindings;
- dependency rules;
- files that an incremental build may not detect.

### Remove recipe state

Clean compiled output while retaining fetched source:

```bash
flashos recipe clean flash
```

Remove fetched source:

```bash
flashos recipe unfetch flash
```

Unfetching is broader than cleaning. Use it when changing a source URL, revision, archive, or patch input that requires the recipe to fetch a fresh source tree.

### Push a package into an existing image

A built package can be pushed into an existing development disk:

```bash
flashos recipe push flash
```

Build and push in one operation:

```bash
flashos recipe build-push flash
```

Clean, rebuild, and push:

```bash
flashos recipe rebuild-push flash
```

> **Warning:** Stop QEMU before pushing packages into an image. Modifying an image while QEMU is using it can corrupt the filesystem.

A push is an iteration aid. It does not prove that a clean image build will contain the same result. Before treating an integration change as complete, rebuild the image from its declared profile and recipe inputs.

Filesystem mounting and package pushing also depend on the host's available filesystem tools and FUSE configuration. When image mutation is unavailable on a host, use a clean image rebuild instead.

### Use direct Make recipe targets

The helper commands map to the repository's compact Make targets:

| Helper command                     | Make target      |
| ---------------------------------- | ---------------- |
| `flashos recipe find NAME`         | `make find.NAME` |
| `flashos recipe build NAME`        | `make r.NAME`    |
| `flashos recipe rebuild NAME`      | `make cr.NAME`   |
| `flashos recipe clean NAME`        | `make c.NAME`    |
| `flashos recipe unfetch NAME`      | `make u.NAME`    |
| `flashos recipe push NAME`         | `make p.NAME`    |
| `flashos recipe build-push NAME`   | `make rp.NAME`   |
| `flashos recipe rebuild-push NAME` | `make crp.NAME`  |

Prefer the descriptive helper commands for ordinary work. Use direct targets when debugging Make behavior or when a repository script specifically invokes them.

## Modify system profiles

The active image configuration is divided between:

```text
config/flashos-base.toml
config/x86_64/flashos.toml
config/x86_64/flashos-release.toml
```

### Shared configuration

Place behavior in `config/flashos-base.toml` when it must be shared by both development and release images, such as:

- common packages;
- filesystem layout;
- system configuration files;
- scheme permissions;
- network defaults;
- shared service or group configuration.

Do not add a graphical dependency or legacy interface merely because it exists in an inherited upstream profile. The FlashOS base profile is an independent text-oriented product configuration.

### Development and release profiles

The two x86_64 product profiles are expected to remain aligned in:

- included base profile;
- package selection;
- installed files;
- filesystem settings;
- user shell paths;
- visible system identity.

Their intentional difference is the credential model.

When changing either profile, run:

```bash
python3 ci/check_profile.py
```

The check validates repository-level invariants including profile alignment, package policy, credentials, shell paths, version identity, selected permissions, branding patches, and pinned shipped recipe sources.

A failure should be resolved by determining which contract is correct. Do not copy a development credential into the release profile or bypass a product restriction merely to silence the check.

### Package changes

When adding, removing, or replacing an image package:

1. confirm that the package is required by the product profile;
2. inspect its full recipe dependency tree;
3. check whether it introduces unwanted graphical or unrelated dependencies;
4. update both product profiles where their package sets must remain aligned;
5. update the product-profile contract when the intended package policy has changed;
6. rebuild the complete image;
7. verify the resulting runtime behavior.

The existence of a recipe does not establish that its package is supported by FlashOS.

### Permissions and startup changes

Changes to scheme permissions, login configuration, or startup scripts can affect basic console operation and security boundaries.

After such a change, verify at minimum that:

- the system reaches the console;
- keyboard input is available;
- the configured account can log in as intended;
- `/usr/bin/fsh` starts;
- required external commands execute;
- the change does not unintentionally grant access to excluded schemes or services.

The exact automated runtime assertions are documented in [Verification and Testing](verification.md) and [CI/CD Contracts](../ci/README.md).

## Modify the build infrastructure

The root build system consists of Make modules and a host-side Rust package.

### Make modules

The root `Makefile` includes modules for:

- environment and configuration resolution;
- host dependency checks;
- Podman execution;
- host filesystem tools;
- cross-toolchain construction;
- package repository management;
- image assembly;
- QEMU execution.

Keep variable ownership clear. A new option should have:

- one documented default;
- a clear command-line or `.config` override path;
- consistent behavior inside and outside Podman where both modes are supported;
- no accidental dependence on a developer's absolute local path.

Inspect the effective values after changing configuration logic:

```bash
make CONFIG_NAME=flashos setenv
```

### Root Rust package

The root Cargo package builds host-side repository and Cookbook support tools.

Run its formatting and test checks from the repository root:

```bash
cargo fmt --all --check
cargo test --locked
```

The root workspace uses the toolchain selected by the root `rust-toolchain.toml`. Do not assume that it uses the same compiler channel as Flash.

### Podman behavior

With `PODMAN_BUILD=1`, package and toolchain work is normally delegated into the configured Podman environment. The repository is mounted into the container, and generated state remains in repository-local ignored paths.

Non-interactive invocations omit Podman's TTY allocation and set a CI-oriented environment so that package construction uses plain log output instead of its interactive terminal interface.

Changes to container definitions or Podman invocation should be tested both:

- from an interactive terminal;
- from a non-interactive command or script.

Do not place credentials, personal host paths, or machine-specific secrets in container definitions or tracked configuration.

### Image assembly

Disk assembly writes to a temporary `.partial` file and promotes it to the final artifact path only after installer success.

Preserve this behavior when changing image generation. A failed assembly must not silently replace a previously complete artifact with a partial image.

## Develop Flash

Flash is maintained in:

```text
components/flash/
```

Its workspace currently separates syntax, runtime, portable platform contracts,
shared Unix-like operations, FlashOS-specific adaptation, the `fsh` client, and
the language-server executable.

Run the standard host checks with:

```bash
flashos shell all
```

Equivalent component-local commands are:

```bash
cd components/flash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --locked
```

A target build requires `redoxer`:

```bash
flashos shell target
```

Or from the component workspace:

```bash
redoxer build -p flash-cli --bin fsh
```

Host success does not prove target success. Flash selects platform-specific terminal and process integrations, so behavior demonstrated on Linux or macOS must be checked separately on the Redox target and in the FlashOS image where applicable.

For parser fixtures, golden corpora, fuzzing, runtime tests, and crate responsibilities, use the [Flash Development Guide](../components/flash/docs/development.md).

### Image integration of Flash

The image package is controlled by:

```text
recipes/terminal/flash/recipe.toml
```

That recipe snapshots the in-tree Flash workspace and builds:

```text
crates/flash-cli
```

The snapshot includes tracked files and non-ignored untracked files under
`components/flash/`. It excludes ignored generated state such as `target/` and
`fuzz/target/`. A clean CI or release checkout is bound to its exact Flash tree;
a local recipe build can consume intentional uncommitted component edits for
testing.

When integrating a Flash change into an image:

1. complete the component-level checks;
2. confirm the target build where required;
3. inspect the workspace snapshot inputs with `git status`;
4. rebuild the recipe and image from the intended checkout;
5. run target-side runtime verification;
6. commit the component and integration changes together.

Do not replace the workspace source with a floating remote branch. A tagged or
otherwise identified image must build Flash from the same checkout that defines
the image.

## Manage generated state

The repository ignores generated state including:

```text
.config
build/
prefix/
repo/
web/
cookbook.toml
cookbook.lock
source/
target/
```

Generated state can also appear beneath individual recipe and component directories.

Do not force-add:

- disk images;
- live images;
- cross-toolchains;
- target sysroots;
- package repositories;
- fetched recipe source trees;
- Cargo target directories;
- local `.config` files;
- smoke-test logs;
- editor or operating-system metadata.

Inspect ignored and untracked files before committing:

```bash
git status --short
```

### Narrow cleanup

Clean a single recipe:

```bash
flashos recipe clean NAME
```

Remove its fetched source only when necessary:

```bash
flashos recipe unfetch NAME
```

### Repository cleanup scopes

The helper requires an explicit cleanup scope:

```bash
flashos clean build
flashos clean recipes
flashos clean fetches
flashos clean container
flashos clean dist
```

Their effects differ:

| Scope       | Purpose                                                               |
| ----------- | --------------------------------------------------------------------- |
| `build`     | Remove generated image, prefix, repository, and filesystem-tool state |
| `recipes`   | Clean compiled recipe targets                                         |
| `fetches`   | Remove fetched recipe inputs                                          |
| `container` | Remove the local build-container state                                |
| `dist`      | Remove fetched and generated build state broadly                      |

Use `dist` only when a clean reconstruction is intentional. It can require substantial refetching and recompilation.

Never delete or clean directories whose purpose is unclear merely because they are large. First identify whether they contain fetched source, package output, the cross-toolchain, image artifacts, or container state.

## Maintain versions and pinned sources

### Release version

The central public release version is stored in:

```text
versions.env
```

The same value is reflected in system identity files, public project metadata, and release workflow expectations.

Do not update only one visible version string. After a version change, run:

```bash
python3 ci/check_profile.py
```

The check detects drift between the central value and the repository locations that must remain aligned.

Historical release information belongs in [CHANGELOG.md](../CHANGELOG.md), not in duplicated current-status sections throughout the documentation.

### Recipe source identity

Shipped external Git-based recipes must use immutable revisions. The in-tree
Flash recipe instead uses `workspace = "components/flash"`, whose clean source
identity is derived from the component tree in the current FlashOS checkout.
This avoids an impossible self-SHA while preserving exact release provenance.

When updating a pinned component:

1. review the upstream changes between the old and new revisions;
2. confirm the source license and attribution requirements;
3. update the recipe revision;
4. reapply or revise local patches;
5. rebuild the recipe from clean state;
6. rebuild the complete image;
7. run the relevant product and runtime checks;
8. update public documentation only where observable behavior or boundaries changed.

A local patch does not make the complete upstream component FlashOS-owned. Keep ownership and attribution language consistent with [Architecture](architecture.md).

### Lockfiles

Retain and update the appropriate lockfile for the workspace being changed:

```text
Cargo.lock
components/flash/Cargo.lock
```

Use `--locked` for checks intended to reproduce the committed dependency resolution. Do not regenerate unrelated lockfile entries without reviewing the resulting dependency changes.

## Update documentation

Public documentation changes must follow the repository's documentation tree and source-of-truth boundaries.

### Use the owning document

Place detailed information in its primary location:

| Topic                        | Primary document                                                    |
| ---------------------------- | ------------------------------------------------------------------- |
| First build and boot         | [Getting Started](getting-started.md)                               |
| System layers and boundaries | [Architecture](architecture.md)                                     |
| Repository workflow          | This document                                                       |
| Verification model           | [Verification and Testing](verification.md)                         |
| Exact CI behavior            | [CI/CD Contracts](../ci/README.md)                                  |
| Hardware evidence            | [Hardware Compatibility](hardware.md)                               |
| Future direction             | [Roadmap](roadmap.md)                                               |
| Flash details                | [Flash Documentation](../components/flash/docs/README.md)           |

Other documents should provide a short summary and link to the primary source rather than duplicating a full procedure.

### Verify every example

Before documenting a command, path, syntax form, or runtime claim:

- confirm that the path exists;
- inspect the implementing code or configuration;
- run the command where practical;
- check whether the behavior is host-only or target-supported;
- distinguish current behavior from planned work;
- avoid turning inherited upstream behavior into a FlashOS support claim.

Flash examples require particular care because it is not a POSIX shell and uses platform-specific integrations.

### Preserve navigation

Central documentation files should retain:

- exactly one H1 heading;
- the correct breadcrumb;
- valid relative links;
- an introduction stating purpose and audience;
- closing navigation that follows the documented order.

Do not link new content to the root compatibility forwarders when a canonical document exists.

### Keep public and local information separate

Do not publish:

- absolute local paths;
- private task or project-management notes;
- internal handover material;
- personal names or contact details without a public need;
- private hardware or security information;
- tool-generation notes;
- temporary debugging instructions;
- unsupported commitments or response timelines.

## Before requesting review

Run checks appropriate to the files that changed.

### Every change

```bash
git status --short
git diff --check
git diff
```

Confirm that the diff contains no generated output, local configuration, unrelated formatting, or temporary debugging changes.

### Root build-system Rust changes

```bash
cargo fmt --all --check
cargo test --locked
```

### Flash changes

```bash
flashos shell all
```

Run the target build as well when the changed code can affect Redox-specific compilation or behavior:

```bash
flashos shell target
```

### Product-profile, package-policy, version, or recipe-source changes

```bash
python3 ci/check_profile.py
```

### Image-affecting changes

Build the development image:

```bash
flashos build disk
```

Then follow the relevant runtime procedure in [Verification and Testing](verification.md).

A successful local check is evidence for the specific layer it exercises. It is not a guarantee of review, acceptance, release, physical-device compatibility, or production readiness.

---

[← Previous: Architecture](architecture.md) · [Documentation index](README.md) · [Next: Verification →](verification.md)
