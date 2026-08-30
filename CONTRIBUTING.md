# Contributing to FlashOS

[FlashOS](README.md) › [Product Guide](docs/README.md) › Contributing

FlashOS welcomes focused bug reports, documentation corrections, reproducible hardware observations, design discussion, and reviewable pull requests. It is an independent pre-alpha project maintained by one person, so response, review, acceptance, and release timelines are not guaranteed.

## Choose the right place

- Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) when something reproducibly behaves incorrectly.
- Use the [documentation template](.github/ISSUE_TEMPLATE/documentation.md) for unclear, stale, missing, or contradictory public guidance.
- Use the [hardware report template](.github/ISSUE_TEMPLATE/hardware_report.md) for results from a named FlashOS image and device.
- Use the [proposal template](.github/ISSUE_TEMPLATE/proposal.md) to discuss a product, language, documentation, or platform change.
- Report suspected vulnerabilities privately through the [Security Policy](.github/SECURITY.md), never in a public issue.

Search existing issues before opening a new one. Include the smallest reproduction that still shows the problem, the exact revision or release, the environment, what happened, and what you expected. Remove credentials, tokens, private paths, serial numbers you do not intend to publish, and unrelated logs.

## Good places to start

Useful starter work includes:

- correcting a verified documentation error or broken navigation path;
- improving a runnable example without changing the language contract;
- adding a focused regression test for already-understood behavior;
- clarifying diagnostics or user-facing help together with their tests; and
- removing duplicate documentation while keeping one page authoritative.

Kernel work, job-control semantics, `unsafe` platform code, release automation, security, credentials, and physical-device writing are not starter tasks. Please discuss those areas first: a small-looking patch can have wide safety or compatibility effects.

## Discuss large changes first

Open a proposal before investing in a large feature, incompatible language change, new platform, long-lived dependency, or major interface change. A useful proposal explains:

- the user problem and concrete outcome;
- what ships now and what the proposal would change;
- compatibility, security, and platform concerns;
- the smallest useful version of the change; and
- how the result can be tested without relying on private project knowledge.

The [Roadmap](docs/roadmap.md) is not a promise that an unsolicited implementation will be accepted. A proposal may be narrowed, deferred, or rejected when its maintenance and testing cost outweighs the value it adds.

## Prepare a change

Start from current `main` and keep the pull request focused on one result. Do not mix unrelated cleanup into a feature, fix, or documentation change. Preserve existing behavior unless changing it is the point of the pull request.

Use the repository setup and development guides:

```bash
./setup.sh --plan
./setup.sh
./setup.sh --check
```

- [Getting Started](docs/getting-started.md) builds and boots the system for the first time.
- [FlashOS Development](docs/development.md) covers repository-wide workflows.
- [Flash Development](components/flash/docs/development.md) covers the language and runtime workspace.
- [Verification and Testing](docs/verification.md) explains what each check proves.

## Run the checks that match the change

Run the smallest documented set of checks that fully covers the change, then report the commands and results. Documentation work usually begins with:

```bash
source flashos.sh
flashos check docs
flashos check profile
```

If you change an example, run it through the real `fsh` binary. Flash implementation changes need the formatter, tests, Clippy, and any affected target or image checks. Product-profile, package, runtime, or image changes need the broader checks documented for those areas. A host test cannot stand in for a target or image test.

Do not write a physical device as part of an ordinary contribution workflow. Hardware testing must follow the identification, approval, and safety procedure in [Hardware Compatibility](docs/hardware.md).

## Submit a pull request

A reviewable pull request:

- explains the user-visible result and any important limits;
- links the issue or proposal when one exists;
- contains only related changes;
- lists exact verification commands and results;
- updates public documentation when behavior or a promise changes; and
- says when target, image, or hardware tests were not available.

Review may ask for a smaller change, stronger tests, compatibility fixes, clearer attribution, or a simpler implementation. The amount of work already invested does not determine whether a change is accepted.

## Licensing contributions

Unless explicitly agreed otherwise in writing, a contribution intentionally
submitted for inclusion is provided under the license that governs the files
it changes. Flash contributions under `components/flash/` are provided under
the [Mozilla Public License 2.0](components/flash/LICENSE); other original
FlashOS material remains under its applicable repository license. Third-party
material retains its own terms and notices. Submit only work that you have the
right to provide under those terms.

## Documentation standards

Write public documentation in English for readers who only know the public repository. Separate what works now from current limitations and future ideas. Explain a topic fully in one place and link to it elsewhere instead of repeating the same warning on every page.

Every command example must identify its environment and be executed where practical. Keep local links, anchors, breadcrumbs, indexes, and previous/index/next navigation correct. Do not publish credentials, private operational records, unsupported personal claims, or unverified capability and maintenance promises.

## Community expectations

Be specific, patient, and respectful. Critique the work, not the person. Do not pressure maintainers or contributors for private information, unpaid deadlines, or an immediate review. Spam, harassment, exposed credentials, and unsafe device instructions are not acceptable.

---

[← Previous: About Me](docs/aboutme.md) · [Documentation index](docs/README.md) · [Next: Upstream References →](docs/upstream/README.md)
