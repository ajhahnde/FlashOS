# Changelog

[FlashOS](README.md) › Changelog

All notable changes to the current FlashOS source tree are recorded in this document. It serves as the chronological source of truth for public releases and significant system updates. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The `0.9.0` and older tags inherited with the Redox OS source history are upstream tags, not FlashOS releases. The former AArch64 FlashOS release history remains available in the archived `FlashOS-old` repository.

## [Unreleased]

### Changed

- Flash now executes `command NAME [ARG...]` through the same resolved external
  stage contract as `^NAME`. Dynamically selected commands preserve native
  argv, byte pipelines, redirections, status, capture, callables, conditional
  execution, and background supervision while continuing to bypass the
  internal-command namespace without reparsing text.
- Candidate and release image builders now pin their source-package header
  generator and cook selected packages from tracked recipes instead of
  combining the pinned source-built kernel with a moving binary userland feed.
  Platform artifact validation binds the staged `relibc` source identity to
  its configured revision; capability claims remain unchanged and QEMU still
  owns runtime qualification.
- Made dependency policy merge-blocking through a stable security aggregate:
  every pull request now reports the gate, while dependency review and Cargo
  policy run only for relevant manifests, lockfiles, policy, Dependabot, or
  workflow changes and controlled skips remain inexpensive.
- Focused hosted CI on one reliable product signal. Draft pull requests run
  source feedback, while every ready candidate builds and boots the canonical
  hard-drive image. Protected `main` receives a visible check by proving that
  its merged tree exactly matches the candidate that passed product and
  dependency qualification, without rerunning flaky host tests. Live-media
  qualification, image SBOM generation, and provenance remain release gates;
  coverage and recurring drift work no longer compete with the product badge.
  The image container remains unprivileged, selected packages are cooked from
  tracked sources, routine dependency updates remain grouped, and published
  release assets cannot be overwritten by a rerun.

### Added

- Added a machine-checked Flash v1 host-conformance inventory. Every recovered
  language, runtime, checker, formatter, language-server, interactive, job,
  completion, portable-editor, and platform-route family now names executable
  owners in the locked workspace suite. CI also rejects unclassified runtime
  refusal boundaries and locks the intentional six-setting interactive config
  surface while keeping target compilation, image integration, and FlashOS
  runtime qualification as separate evidence.
- Added grammar-aware Flash path completion. Bounded, cancellable, generation-
  stamped host snapshots now cover recursive cwd paths without following
  directory symlinks, while the parser-derived completion engine handles bare,
  quoted, interpolated, executable, redirection, and explicit `glob(...)`
  positions. Insertions preserve wildcard spelling and reversible escaping,
  omit unrepresentable native names, reject stale snapshots, and perform no
  source execution or implicit argument expansion.
- Added portable Flash interactive behavior across the host and target editor
  source paths. The shared contract now covers grapheme/display-cell editing,
  editable multiline submissions, in-flight resize, completion, highlighting,
  hints, persistent history, configurable prompts, and background notices that
  redraw without losing typed input. FlashOS image runtime qualification remains
  a separate gate.
- Added structured Flash error handling. `try { ... } catch error { ... }`
  catches runtime errors into an immutable queryable `Error`, while `throw`
  raises a source-anchored string error or rethrows an existing error without
  losing its source, labels, frames, cause, or status. Catching restores the
  pre-try language state without claiming rollback of output, files, or child
  effects, and cancellation, exit, stopped jobs, fatal host failures, and
  ordinary unsuccessful statuses remain distinct.
- Added typed Flash command capture. `$(bytes: chain)` now preserves exact
  bounded output as a `Bytes` value, including NUL and non-UTF-8 data, while
  `$(text: chain)` explicitly selects the existing strict UTF-8 and trailing-
  newline behavior and `$(chain)` remains its shorthand. Both modes share
  status, cancellation, cleanup, redirection, and transactional execution;
  byte results cannot be inserted into command words implicitly.
- Added `fsh plan [--] SOURCE` for deterministic inspection of one exact Flash
  command pipeline. It shares canonical parsing, static analysis, ordinary
  expansion and PATH resolution, structural preflight, and complete escaped-
  native plan rendering while refusing substitution and broader script shapes
  without opening redirections, mutating session state, starting processes, or
  accessing config, history, or a terminal.
- Added live Flash interactive session configuration and completion snapshots.
  Trusted startup config can transactionally set `pipefail`, command-capture
  limits, completion, and history without leaking its temporary setting
  bindings into scripts or the prompt; safe mode and opt-out flags restore
  clean defaults. Host completion now refreshes at each prompt from live scope,
  cwd, child `PATH`, and bounded UTF-8 executable/path snapshots while keeping
  host I/O outside the keypress callback.
- Added a dedicated FlashOS platform adapter for Flash. The adapter keeps the
  classified Rust and `relibc` routes behind the portable platform contract and
  adds native-path-preserving home, configuration, cache, and state selection
  with deterministic FlashOS fallbacks. It is compiled by the Redox-target
  `fsh` build but remains unselected with no advertised capabilities until the
  later target-runtime qualification and bring-up work.
- Added a checked FlashOS x86_64 platform classification for Flash. All 44
  required operations and all 14 capability groups now have explicit native,
  shimmed, deliberately unsupported, or separately authorized kernel-work
  verdicts. The current result is 41 native operations plus a three-operation
  FlashOS standard-directory policy shim, with no deliberately unsupported or
  kernel-work verdicts; target-runtime qualification remains pending.
- Added a checked per-operation FlashOS x86_64 platform map for Flash. Every
  portable capability requirement now resolves to its current Flash-internal,
  Rust standard-library, direct `relibc`, or unrouted boundary. The map
  preserves the unknown target compiler source commit and the configured
  `relibc` source revision, and it keeps
  support classification and runtime qualification explicitly deferred.
- Added a checked FlashOS x86_64 capability-evidence inventory for Flash. It
  compares all 14 current portable capability groups with the selected Redox
  executable and adapter source paths and with the behavior already observed by
  the QEMU smoke contract. Source declarations, runtime observations, and
  evidence gaps remain distinct, and support classification is explicitly
  deferred instead of being inferred from the Unix target family, adapter
  methods, or successful builds.
- Added a machine-readable FlashOS x86_64 platform baseline for Flash. It
  records the configured Rust and `relibc` inputs alongside observed compiler,
  source-built package, dynamic-linker, and ELF identity, with source checks in
  ordinary CI and artifact checks in the clean-room image path. The baseline
  establishes the adapter target without claiming capability support or runtime
  qualification.
- Added arbitrary alternating mixed-pipeline execution. Maximal internal
  segments stream concurrently across external byte stages without whole-stream
  capture or cross-thread structured carriers, while source-ordered
  preparation, status leaves, `pipefail`, deferred `check`, transactional
  session state, closure-delta merging, explicit exit, local descriptor
  override, child cleanup, and interactive/script/background parity remain
  deterministic.
- Added `/usr/bin/flash-language-server`, a separate stdio-only Language Server
  Protocol executable with full-text versioned overlays for absolute `file:`
  URIs. It publishes deterministic shared module diagnostics and provides
  completion, hover, signature help, definition, references, and canonical
  whole-document formatting with cancellation and stale-generation barriers.
  The adapter shares Flash syntax and semantic analysis but has no CLI,
  platform, terminal, session, configuration, history, executable-probe, or
  execution capability; effectful open source is analyzed without being run.
- Added the complete Flash module-initializer effect contract. Named
  dependencies share logical cwd, child environment, status, output, process,
  and job state in deterministic initialization order; successful completion
  and whole-program initializer `exit` commit the final child environment,
  while runtime or output failure does not. Output, filesystem, and process
  effects remain immediate and non-transactional, and every exit route joins
  program jobs with ordered background-failure precedence. Canonical module
  programs now expose source-spanned direct and named-dependency-folded
  host-free summaries for working-directory, environment, status, output,
  filesystem, process, job, exit, and opaque external effects. Load-only
  modules remain dormant in transitive summaries, known callables fold their
  bodies, and valid effectful modules add no checker diagnostic.
- Added non-executing `fsh check [--] SOURCE` analysis for one root and its
  recursively discovered canonical import closure. The checker accumulates
  deterministic module, name, signature, and `PIP001`-`PIP004` pipeline-carrier
  diagnostics through shared runtime analysis, accepts canonical symlink
  aliases to regular UTF-8 source, and reports silent status-0 success,
  stderr-only status-1 analysis failure, and status-2 invocation misuse. Static
  carrier classification uses built-in contracts without expanding words,
  probing executables, initializing modules, mutating session state, applying
  redirections, or executing source.
- Added explicit `fsh format --check [--] PATH...` and
  `fsh format --write [--] PATH...` launcher modes. Ordered checks report
  anchored `FMT001` diagnostics without writes; write mode preflights the full
  explicit-file batch and atomically replaces changed files through synchronized
  same-directory temporaries while preserving permission bits. The frontend
  rejects directories, final symlinks, duplicate canonical targets, invalid or
  incomplete source, and stale preflight data without loading imports,
  initializing a session, or executing source.
- Added Flash documentation comments and inspection-only language help.
  Consecutive complete-line `##` blocks attach to immediately following named
  functions and normalize into the same resolved metadata retained by module
  analysis and runtime callables. `help [NAME]` snapshots documented built-ins
  and visible named functions during planning, renders deterministic UTF-8 byte
  output, preserves distinct built-in/function namespaces and lexical
  shadowing, and never runs the inspected body or probes an executable.
- Added ordered script arguments to Flash. `fsh [OPTIONS] SCRIPT [ARGUMENT]...`
  preserves empty, Unicode, and option-like operands as immutable root-only
  `$args: List[String]` data without splitting or reparsing. Non-UTF-8 script
  arguments fail before source loading, and dependency modules receive no
  ambient caller arguments.
- Added resolved type annotations and named-function signatures to canonical
  Flash programs. The closed built-in namespace includes exact scalar,
  collection, callable, and `Any` contracts; known local and imported calls are
  checked conservatively before execution, while declarations, assignments,
  dynamic calls, closure parameters, and named-function results retain exact
  runtime enforcement with recursive `List[T]` matching and cross-file
  diagnostics.
- Added host-free lexical-reference resolution to every loaded Flash module.
  Canonical module programs now expose deterministic source-spanned references
  to local bindings and complete import/declaration/export provenance for
  cross-file reads. Resolution mirrors source-ordered evaluator scopes,
  callable capture, parameters, recursive functions, loops, match arms, and
  shadowing before execution; unknown reads and same-scope duplicate bindings
  now fail program construction with `MOD009` and `MOD010`. Load-only modules
  are fully analyzed while remaining dormant at runtime.
- Added Flash's first explicit module-name analysis. Top-level
  `export { name }` lists make local declarations or functions visible, while
  `import { name } from '<path>'` requests only named target exports and never
  creates wildcard ambient access. Canonical module programs now expose
  deterministic export/import tables and diagnose unknown, private, duplicate,
  and colliding names without evaluation. At runtime, named dependencies now
  initialize once per canonical module in deterministic dependency-first order.
  Each module receives an isolated lexical root whose imported values are
  immutable snapshots of completed target exports, while ordinary session state
  remains shared. Imported callables retain their defining source, including in
  grouped cross-file runtime diagnostics, and load-only dependencies remain
  dormant.
- Added Flash's first source-level module declaration and recursive analysis
  loader. A top-level `import '<path>'` records an exact static dependency;
  injected canonicalization and source-loading capabilities build one acyclic
  graph and stable source registry, parse canonical aliases only once, and
  preserve cross-file resolution, read, UTF-8, syntax, and cycle diagnostics
  without executing source. Non-interactive `fsh <script>` execution now uses
  the real filesystem adapter, renders grouped source excerpts for cross-file
  diagnostics. Load-only imports remain non-executing during script execution;
  explicit named imports use the initialization and binding behavior above.
- Added informational host line-coverage reporting for all five Flash crates.
  A dedicated workflow generates one LCOV report with pinned Rust coverage
  tooling, rejects empty reports or reports that omit a workspace member, and
  authenticates the Codecov upload through GitHub OIDC. Coverage status checks
  and pull-request comments remain disabled while a new Rust baseline is
  established; the README badge explicitly represents Flash host coverage and
  does not claim Redox, QEMU, or hardware-path coverage.
- Added optional Gemini-backed host helpers for evidence-bounded repository
  location questions and locally validated commit subjects. Their public
  contexts define FlashOS terminology, evidence limits, privacy boundaries, and
  the one-line Conventional Commit house style.
- Added an optional sourceable Bash and Zsh helper layer for common image build,
  interactive QEMU, exact-artifact smoke, profile, Flash, Podman, and local
  quality commands. The wrappers keep the x86_64 FlashOS profile and artifact
  paths consistent without hiding the underlying tools or exposing Git and
  physical-device writes.
- Added interactive job control to Flash. Ctrl-C now interrupts the running
  command without ending the shell, while Ctrl-Z retains an exact external
  foreground command as an addressable job and returns the prompt. `jobs`
  exposes structured job state, `bg` and `fg` resume stopped work in the chosen
  placement, `wait` consumes selected completions, and `kill` signals explicit
  `%n` targets with termination as the default and forced termination available
  through `--kill`. Foreground handoff and restoration keep subsequent terminal
  input attached to the shell. A shell reading redirected input arranges no
  interactive signal handling and remains part of its existing foreground
  process group.
- Added a line editor to the console shell. `fsh` on the image read input in
  canonical mode, so a session had no in-line editing, no history recall, and no
  continuation prompt for an incomplete block. The shell now decodes keys
  itself, holds the terminal in raw mode for the duration of a single read, and
  redraws one physical row. It is selected only when standard input and standard
  output are both terminals, so a redirected session still reads plain lines
  instead of receiving cursor escapes.
- Added a release image profile that locks the root account, so a published
  image no longer carries a root password. Locking is expressed by a new
  `locked` user option in the image installer and writes an unmatchable hash;
  `sudo` is unaffected because it authenticates the invoking user before
  switching to uid 0.
- Added a security policy covering scope, supported versions, private
  vulnerability reporting, and the credential weaknesses that published images
  still carry.
- Added a second software bill of materials describing the operating-system
  image itself. Releases now publish a source document and an image document,
  each named for what it covers, with the image document bound to the SHA-256
  digests of the artifacts it describes.
- Added product-contract rules covering release credentials, parity between the
  development and release profiles, immutable revisions for every external Git
  recipe that reaches the image, and the in-tree Flash workspace source.
- Added a lint gate for the release-critical Python in `ci/`.

### Changed

- Clarified and tightened the commit-subject scope rule. `flash` and `tools`
  are now the only accepted scopes and are required when that named subproject
  owns the primary effect; pure CI, root build-system, release,
  repository-wide, and mixed-area subjects remain unscoped. The commit helper
  rejects invented scopes and redundant forms such as `ci(ci):`.
- Changed the Flash image recipe to snapshot the current in-tree
  `components/flash/` workspace instead of pinning the repository to its own
  commit SHA. Clean builds remain bound to the exact outer FlashOS checkout,
  while local component edits can be tested without a follow-up pin commit;
  ignored build outputs are excluded from the snapshot.
- Relicensed Flash from Apache-2.0 to MIT so the FlashOS-owned component and
  the inherited root build infrastructure use the same permissive license while
  retaining their separate copyright notices.
- Renamed FlashShell to Flash across the source tree while preserving the
  `fsh` executable, `/usr/bin/fsh`, `.fsh` scripts, and prompt protocol. Added
  concrete fallback strategies for configuration and history:
  - Configuration paths: `<config_dir>/flash/config.fsh` and `<config_dir>/flashshell/config.fsh`.
  - History paths: `<state_dir>/flash/history` and `<state_dir>/flashshell/history`.
  - Fallback rules: if the new canonical path exists, it has exclusive priority; if only the legacy path exists, it continues to be used; if neither path exists, only the new canonical path is created or expected; invalid, incomplete, or unsafe files at the canonical path always fail as an error, with no fallback and no creation of replacement paths.
  - The shell helper `flashshell-check` is a deprecated compatibility alias for `flash-check`.
- Flash now observes jobs continued by an external process, reports their
  live running state, and removes the stale stopped notice at the next command
  boundary.
- Pinned every input the image is built from: the container base image by
  digest, the Rust toolchain and its installer by version and checksum, the
  build-system Git dependencies by revision, every package recipe that reaches
  the image by revision, and the host installer that writes the image. The same
  commit previously resolved to whatever the upstream default branches happened
  to be at build time, including the kernel and the shell.
- Corrected the build-support crate license to `MIT`, matching the root license
  file and the upstream origin of every file under `src/`.
- Changed the default build configuration from the inherited `desktop` profile
  to `flashos`, so an invocation without an explicit `CONFIG_NAME` builds the
  TUI-only product image instead of a graphical desktop image. The same default
  now applies to `build.sh` and to the `changelog`, `find-recipe`, and `ventoy`
  helper scripts.
- Declared the license and repository of the build-support crate and dropped
  its inherited author field, matching the Flash workspace metadata.
- Corrected two build-support paths that pointed at directories the recipe
  tree no longer uses.

### Fixed

- Corrected the final login banner so FlashOS no longer presents itself as an
  unofficial Redox OS distribution. Product identity files are now installed
  after packages, and the static and QEMU contracts reject inherited product
  branding in the resulting image.
- Corrected the package-repository web generator to link build scripts and
  commits to FlashOS by default, with an explicit source-URL override for
  alternate deployments.
- Replaced inherited Redox product wording in the Nix and bootstrap developer
  interfaces, updated maintenance scripts to refer to the FlashOS repository
  root and `main` branch, and restored the documented deprecated
  `flashshell-check` compatibility alias.

### Removed

- Removed every inherited image configuration that the product does not build:
  the desktop, Wayland, X11, server, minimal, development, and test profiles,
  the inherited base configuration they were layered on, and the configuration
  directories for the inactive `aarch64`, `i586`, and `riscv64gc`
  architectures. `config/` now contains only the FlashOS base configuration and
  the active `x86_64` product profile.
- Removed the unreferenced upstream build-server image, packaging, and
  toolchain targets, which built configurations that no longer exist and named
  their artefacts after the upstream project.
- Removed the inherited graphical client library and every package recipe that
  depends on it, transitively: the SDL 1 and SDL 2 families, the OpenGL and
  multimedia libraries built on them, the demo, game, emulator, and web-browser
  packages, and the desktop, X11, and Xfce package groups. The remaining recipe
  set no longer offers a graphical stack, matching the TUI-only product scope.
  The corresponding entries were also dropped from the static-clean target, the
  native bootstrap package list, and the Nix development shell.
- Removed an unreferenced maintenance script that checked package coverage
  against an image configuration that no longer exists.
- Removed the inherited work-in-progress recipe collection and the packages
  that depended on it, transitively: the X11 and desktop client libraries, the
  text and font shaping stack built on them, and the development, scripting,
  and test-suite convenience groups. The recipe set is now 226 packages
  covering the kernel, core system, terminal userspace, and their libraries.
- Removed an unreferenced toolchain package manifest that no build step read
  and that listed packages without recipes.
- Removed the inherited windowing system and its clients, together with the
  graphical toolkits, font, icon, and wallpaper data packages, and the
  two-dimensional rendering libraries that only served them. The recipe set is
  now 192 packages and contains no windowing stack.
- Removed the unreferenced VirtualBox emulator target. QEMU is the supported
  emulation path.
- Removed VirtualBox installation from the native and container bootstrap
  scripts, which offered to install an emulator the build system can no longer
  target.

## [0.1.0] - 2026-07-26

### Added

- Added the independent x86_64 FlashOS image profile at
  `config/x86_64/flashos.toml`.
- Defined FlashOS as a TUI-only product: no Orbital, COSMIC, X11, Wayland,
  GUI applications, or graphical installer is selected by the active profile.
- Added a FlashOS-owned TUI base configuration without Orbital scheme access
  or the inherited legacy `/ui` compatibility symlinks; audio remains in
  scope.
- Made graphical XDG home directories optional in the inherited installer and
  disabled their creation for the FlashOS image.
- Added FlashShell to the active source tree and installed `fsh` as the login
  shell for both development accounts.
- Added the FlashShell target recipe and target-build verification.
- Added FlashOS hostname, release metadata, console issue, QEMU title, network
  boot filename, and image build path.
- Restored the English documentation suite with the original FlashOS
  light/dark logo presentation and top navigation.
- Added public hardware, trademark, attribution, and upstream reference
  documents.
- Restored GitHub Actions as an x86_64-native CI/CD architecture with
  independent build-system, FlashShell, and TUI product-contract gates.
- Added a FlashOS-owned Docker clean-room build, immutable checksummed image
  promotion, and a separate QEMU consumer that verifies FlashOS identity,
  TUI login, FlashShell pipelines, and the IHDA audio driver.
- Added a self-contained live image for removable USB media and qualified its
  exact promoted bytes through an emulated USB mass-storage boot.
- Added scheduled dependency policy, Dependabot, tag-driven release
  packaging, CycloneDX SBOM generation, checksums, and build provenance.

### Changed

- Renamed the standalone repository and product from Redox to FlashOS.
- Renamed the default branch from `master` to `main`.
- Detached the GitHub repository from the Redox OS fork network while keeping
  `redox-os/redox` as the local `upstream` remote.
- Removed the inherited Redox GitLab pipeline and GitLab templates; GitHub
  Actions is the single active public automation surface.
- Archived the former AArch64 project separately as `FlashOS-old`.
- Renamed the root support crate from `redox_cookbook` to `flashos_build`.
- Defined the intended long-term borrowed boundary as the Redox OS kernel.
  Current Redox userspace, relibc, toolchain, installer, bootloader, package,
  and build dependencies remain transitional.
- Made future kernel divergence explicit: FlashOS may stop consuming Redox
  kernel updates when its kernel requirements differ.
- Extended the product contract to enforce release-version lockstep across
  the root crate, FlashShell workspace, README, `os-release`, console issue,
  and release artefact names.
- Moved build-provenance attestation into release-candidate packaging so a
  non-publishing dry run exercises the same attestation used by tagged
  delivery.
- Updated artifact downloads and pull-request dependency review to their
  Node 24 action runtimes.
- Kept the installed-disk and removable-media contracts distinct:
  `harddrive.img` is qualified over NVMe, while `redox-live.iso` is qualified
  over USB and included in release checksums and provenance.

### Verified

- FlashShell host tests and clippy checks.
- FlashShell target compilation for `x86_64-unknown-redox`.
- Root Cargo metadata and locked dependency check.
- FlashOS build-environment selection for `x86_64` and the `flashos` profile.
- QEMU boot, login to `>> `, and an external-to-external pipeline on the
  final rebranded image.
- Automated QEMU contract including the FlashOS bootloader, kernel identity,
  login prompt, FlashShell pipeline, and retained IHDA audio driver.
- Non-publishing release workflow: clean-room rebuild of both images, separate
  NVMe and USB QEMU qualification, compression, checksum verification,
  CycloneDX SBOM generation, and build-provenance attestation.
- Physical live USB boot, display, keyboard, login, and FlashShell validation
  on a Sony VAIO VPCEB4L1E.

---

[← Previous: CI/CD Contracts](ci/README.md) · [FlashOS README](README.md) · [Next: Security Policy →](.github/SECURITY.md)
