# Security Policy

[FlashOS](../README.md) › Security Policy

This policy explains which FlashOS versions and components are eligible for security review, how to report suspected vulnerabilities privately, and which limitations apply to current evaluation images. It is intended for security researchers, evaluators, and contributors. FlashOS is pre-alpha software and does not provide production security guarantees, long-term support, or response and remediation service-level agreements.

## On this page

- [Supported versions](#supported-versions)
- [Security scope](#security-scope)
- [Known evaluation limitations](#known-evaluation-limitations)
- [Reporting a vulnerability](#reporting-a-vulnerability)
- [Information to include](#information-to-include)
- [Report handling and disclosure](#report-handling-and-disclosure)
- [Safe testing](#safe-testing)
- [Public issue reporting](#public-issue-reporting)

## Supported versions

| Version or source line                   | Security status                            |
| ---------------------------------------- | ------------------------------------------ |
| Most recent published FlashOS release    | Eligible for security assessment and fixes |
| Earlier FlashOS releases                 | Not maintained                             |
| Inherited Redox tags and branches        | Not maintained by FlashOS                  |
| Archived or legacy FlashOS product lines | Not maintained by this repository          |

“Eligible” means that an in-scope report may be investigated and addressed. It does not guarantee acknowledgement, reproduction, a fix, a release, or any particular timeline.

Security fixes are normally delivered through the active source tree and a later release. Historical image assets are not silently replaced or retroactively qualified.

## Security scope

### In scope

Reports are in scope when they concern a security boundary owned or materially changed by FlashOS, including:

- Flash under [`components/flash/`](../components/flash/), including parsing, evaluation, command expansion, process execution, pipelines, redirections, job control, and terminal handling.
- FlashOS-authored build support, image profiles, configuration, installation behavior, CI contracts, and release automation.
- FlashOS-authored package recipes and patches where FlashOS changes the behavior or security properties of a shipped component.
- Integration vulnerabilities caused by how FlashOS configures, combines, packages, or exposes inherited components.
- Release-artifact integrity problems involving FlashOS checksums, SBOMs, provenance, profile selection, or publication workflow.

### Normally reported upstream

Defects that exist entirely within an inherited Redox component and are not introduced or materially changed by FlashOS should normally be reported to the appropriate upstream project. This includes upstream-only defects in the Redox kernel, relibc, bootloader, toolchain, drivers, and inherited userspace packages.

A non-sensitive FlashOS issue may later track the effect of an upstream defect on this project. Do not create that public issue while it would reveal an unfixed vulnerability.

When the responsible boundary is unclear, submit the report privately to FlashOS first. Triage can determine whether the issue belongs here, upstream, or in both projects.

### Not security vulnerabilities by themselves

The following observations are not treated as FlashOS vulnerabilities unless they demonstrate an additional, unexpected security-boundary failure:

- The documented evaluation credentials and local-access model described below.
- The expected consequences of already having unrestricted root access on the same FlashOS instance.
- Physical interruption, reset, removal of storage, or ordinary console interference by a person who controls the machine.
- Resource exhaustion caused only by intentionally consuming the resources available to an unrestricted local process.
- Missing production hardening or functionality that the project does not claim to provide.

## Known evaluation limitations

FlashOS images are evaluation artifacts, not hardened production systems.

### Current release-profile source

The current release image profile:

- locks the root account against direct password login;
- leaves the regular `user` account without a password;
- places that account in the `sudo` group.

The local console must therefore be treated as unauthenticated. A person who reaches the regular account can obtain administrative access through the configured privilege-escalation path.

Root locking prevents direct root login; it does not make the evaluation user or the local console a security boundary.

### Published `v0.1.0` images

The published `v0.1.0` images predate the locked-root release profile and contain documented development credentials, including a directly accessible root account.

Treat those images as unauthenticated historical evaluation systems. Any related security improvement would be delivered through a later release rather than by treating the original image as secure.

### General limitations

FlashOS does not currently claim:

- production-ready authentication or first-boot credential provisioning;
- a complete security audit of the inherited kernel, ABI, drivers, userspace, or toolchain;
- long-term security maintenance branches;
- a guaranteed vulnerability-response or patch timeline;
- qualification for exposure to untrusted networks;
- protection of valuable data on a production machine;
- that automated dependency, image, or QEMU checks prove the absence of vulnerabilities.

Do not use a current FlashOS image to protect sensitive information or as a security boundary between mutually untrusted users.

## Reporting a vulnerability

Report suspected vulnerabilities through GitHub’s private vulnerability reporting mechanism for this repository:

1. Open the repository’s **Security and quality** tab.
2. Select **Advisories** under **Reporting**.
3. Choose **Report a vulnerability**.

Do not disclose an unfixed vulnerability through:

- a public GitHub issue;
- a pull request;
- a discussion;
- a commit message;
- a public forum or social-media post.

Use a private report even when you are uncertain whether the behavior is exploitable or belongs to an upstream dependency.

## Information to include

Provide enough information to reproduce and assess the report:

- The exact FlashOS release tag or commit SHA.
- The image type and build profile, such as the installed-disk or live-image form.
- The artifact checksum when testing a published or CI-produced image.
- The execution environment, including QEMU or physical hardware, firmware mode, and relevant device configuration.
- The attacker’s required access and preconditions.
- Minimal, step-by-step reproduction instructions.
- The expected behavior and the observed behavior.
- The resulting security impact or boundary that can be crossed.
- Relevant serial logs, panic output, diagnostics, or crash traces.
- A minimal proof of concept when one can be shared safely.
- Whether the issue has already been disclosed or reported elsewhere.

Remove unrelated personal data, credentials, access tokens, private keys, and third-party confidential information before attaching evidence.

## Report handling and disclosure

FlashOS is maintained by one person. Reports are reviewed as maintainer capacity permits, and no acknowledgement, assessment, fix, or release deadline is guaranteed.

During triage, the maintainer may:

- request additional reproduction details;
- test the issue against another revision or image profile;
- determine that the behavior is already documented;
- determine that the issue is outside the FlashOS-owned boundary;
- refer an upstream-only defect to the responsible project;
- prepare a source change, release fix, advisory, or documentation correction.

Please keep technical details private while reproduction and remediation are being discussed. Disclosure timing is handled per report rather than through a fixed embargo period.

A confirmed issue may be documented in a security advisory, release note, or changelog entry. Reporter attribution is included only with the reporter’s agreement; anonymity may be requested.

## Safe testing

Perform security research only on systems and accounts that you own or are explicitly authorized to test.

Prefer:

- a disposable virtual machine;
- QEMU snapshot operation;
- a copy of an image rather than the only copy;
- isolated networking;
- non-sensitive test data;
- the minimum activity necessary to demonstrate impact.

Do not:

- expose an unauthenticated FlashOS instance to an untrusted public network;
- test against third-party systems or services without authorization;
- retain access after the issue has been demonstrated;
- access, modify, or disclose data that is not necessary for the report;
- intentionally disrupt infrastructure belonging to another person or organization;
- publish exploit details before coordinated disclosure.

This policy does not grant authorization to test systems outside the FlashOS images and infrastructure that you control.

## Public issue reporting

Public GitHub issues remain appropriate for:

- ordinary functional bugs;
- documentation errors;
- build failures without a confidentiality concern;
- reproducible hardware observations;
- feature requests;
- already-public upstream defects whose security-sensitive details have been addressed.

When a report might reveal a vulnerability, privilege boundary failure, credential exposure, or artifact-integrity weakness, use private vulnerability reporting first.

## Related documentation

- [CI/CD Contracts](../ci/README.md) — Automated dependency, profile, image, checksum, SBOM, and release contracts.
- [Verification and Testing](../docs/verification.md) — Evidence levels and the limits of automated qualification.
- [Hardware Compatibility](../docs/hardware.md) — Published physical-device evidence.
- [Changelog](../CHANGELOG.md) — Public release history and security-relevant changes.
- [Flash Architecture](../components/flash/docs/architecture.md) — Flash trust and platform boundaries.

---

[← Previous: Changelog](../CHANGELOG.md) · [Documentation index](../docs/README.md) · [Source of Truth](../docs/source_of_truth.md) · [Next: Trademark Policy →](../TRADEMARK.md)
