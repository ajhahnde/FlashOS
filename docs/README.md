# FlashOS Product Guide

[FlashOS](../README.md) › Product Guide

Not sure where to begin? Pick a goal from the first table. The rest of this page is the full index for system guides, Flash references, policies, and project records.

## Start here

| Goal | Page | Covers |
| --- | --- | --- |
| Build and boot FlashOS | [Getting Started](getting-started.md) | Host setup, local configuration, image construction, QEMU, login, first checks, and troubleshooting |
| Understand how Flash fits | [Flash and FlashOS](flash.md) | The current shell integration, data and status handling, and the planned Shell/View design |
| Try the language | [Flash by Example](../components/flash/docs/by-example.md) | Small executable programs for structured values, external bytes, `check`, and `plan` |
| Learn Flash in depth | [Flash Documentation](../components/flash/docs/README.md) | Tutorials, the Flash 1.0 language reference, scripting, internals, and development |
| About Me | [About Me](aboutme.md) | Personal background, motivation, working approach, and project principles |
| Contribute | [Contributing](../CONTRIBUTING.md) | Issues, proposals, safe starter work, verification, documentation standards, and review expectations |

## Documentation map

The [FlashOS README](../README.md) is the front door. From there, the public documentation splits into these paths:

- **Main product guide:** [Product Guide](README.md) → [Getting Started](getting-started.md) → [Flash and FlashOS](flash.md) → [Architecture](architecture.md) → [Development](development.md) → [Public Automation](automation.md) → [Verification and Testing](verification.md) → [Hardware Compatibility](hardware.md) → [Roadmap](roadmap.md) → [About Me](aboutme.md) → [Contributing](../CONTRIBUTING.md) → [Upstream References](upstream/README.md).
- **Flash guide:** [Flash Overview](../components/flash/README.md) → [Flash Documentation](../components/flash/docs/README.md) → [Flash by Example](../components/flash/docs/by-example.md) → [Language Guide](../components/flash/docs/language-guide.md) → [Scripting Guide](../components/flash/docs/scripting.md) → [Flash Architecture](../components/flash/docs/architecture.md) → [Flash Development](../components/flash/docs/development.md) → [CI/CD Contracts](../ci/README.md).
- **Focused Flash references:** [Flash Changelog](../components/flash/CHANGELOG.md), [Performance Benchmarks](../components/flash/benchmarks/README.md), [Flash v1 Exercises](../components/flash/exercises/README.md), [Scheduling Stress](../components/flash/scheduling/README.md), [Fuzz Targets](../components/flash/fuzz/README.md), [End-to-end Tests](../components/flash/tests/e2e/README.md), [Test Fixtures](../components/flash/tests/fixtures/README.md), [Grammar Corpus](../components/flash/tests/golden/grammar/README.md), and [Lexical Corpus](../components/flash/tests/golden/lexical/README.md).
- **Project records and policies:** [CI/CD Contracts](../ci/README.md) → [Changelog](../CHANGELOG.md) → [Security Policy](../.github/SECURITY.md) → [Trademark and Project Identity](../TRADEMARK.md).
- **Compatibility redirects:** [Documentation](../DOCUMENTATION.md), [Setup](../SETUP.md), and [Hardware](../HARDWARE.md) keep older links working.
- **Issue routes:** [Bug Report](../.github/ISSUE_TEMPLATE/bug_report.md), [Documentation Issue](../.github/ISSUE_TEMPLATE/documentation.md), [Hardware Report](../.github/ISSUE_TEMPLATE/hardware_report.md), and [Proposal](../.github/ISSUE_TEMPLATE/proposal.md).
- **Retained Redox snapshots:** [Hardware](upstream/REDOX_HARDWARE.md) and [Trademark](upstream/REDOX_TRADEMARK.md) are historical upstream references reached through [Upstream References](upstream/README.md); they do not define FlashOS behavior or policy.

## FlashOS system guides

| Guide | Scope |
| --- | --- |
| [Architecture](architecture.md) | Current system layers, image profiles, build-to-boot flow, component ownership, and upstream boundaries |
| [Development](development.md) | Repository workflow, build operations, packages, profiles, generated state, and review preparation |
| [Public Automation](automation.md) | Flash-native programs, reviewed interpreter exceptions, setup boundary, and host tools |
| [Verification and Testing](verification.md) | Source, target, profile, image, QEMU, release, and physical-hardware evidence |
| [Hardware Compatibility](hardware.md) | Device-specific results, qualification vocabulary, safe testing, and reporting |
| [Roadmap](roadmap.md) | Work in progress, likely next steps, later ideas, and non-goals |

## Flash guides and technical references

- [Flash Overview](../components/flash/README.md) — Component role, v1 contract, implementation, tooling, and entry points.
- [Flash by Example](../components/flash/docs/by-example.md) — Curated executable examples.
- [Language Guide](../components/flash/docs/language-guide.md) — Frozen Flash 1.0 syntax, values, functions, modules, and pipelines.
- [Scripting Guide](../components/flash/docs/scripting.md) — Files, arguments, checking, formatting, processes, statuses, errors, and jobs.
- [Flash Architecture](../components/flash/docs/architecture.md) — Crates, analysis, planning, execution, platform capabilities, and lifecycle.
- [Flash Development](../components/flash/docs/development.md) — Component toolchains, tests, target work, fuzzing, benchmarks, and documentation maintenance.
- [Flash Changelog](../components/flash/CHANGELOG.md) — Component release history.
- [Flash Supporting References](../components/flash/docs/README.md#supporting-technical-references) — Exercises, benchmarks, scheduling stress, fuzzing, and test corpora.
- [CI/CD Contracts](../ci/README.md) — Exact local scripts, hosted workflows, classification, artifacts, and failure interpretation.

## Policies and project records

- [Changelog](../CHANGELOG.md) — FlashOS release history and current unreleased changes.
- [Security Policy](../.github/SECURITY.md) — Reporting, evaluation scope, supported-version policy, and pre-alpha limitations.
- [Trademark and Project Identity](../TRADEMARK.md) — FlashOS identity and upstream mark boundaries.
- [License](../LICENSE) and [Notice](../NOTICE) — Root licensing, third-party licenses, and attribution.
- [Upstream References](upstream/README.md) — Classification and interpretation of retained Redox reference snapshots.

## Compatibility paths

[Legacy documentation](../DOCUMENTATION.md), [setup](../SETUP.md), and
[hardware](../HARDWARE.md) files remain as redirects for old links and
bookmarks. New links should point here, to [Getting Started](getting-started.md),
or to [Hardware Compatibility](hardware.md).

---

[← Back to FlashOS](../README.md) · [Next: Getting Started →](getting-started.md)
