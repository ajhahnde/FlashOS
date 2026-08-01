# Security Policy

[FlashOS](../README.md) › Security

This document details the security policy, vulnerability reporting workflow, supported versions, and known evaluation limitations for FlashOS. It is intended for security researchers, evaluators, and contributors needing to report or understand system vulnerabilities.

## Supported versions

Only the most recent published release receives security evaluation and fixes. Earlier tags and legacy branches are historical artifacts and are not patched.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Any earlier release | No |

## Security scope

The following components and repository surfaces are officially in scope for vulnerability evaluations:
- FlashShell (`components/flashshell/`) — parsing, evaluation, process execution, redirection, and terminal handling.
- The FlashOS image profile, product contract, and release pipeline (`config/`, `ci/`, `.github/workflows/`).
- FlashOS-authored system packages and patches under `recipes/`.

## Reporting a vulnerability

Report suspected security vulnerabilities privately through GitHub's private vulnerability reporting mechanism on this repository: navigate to **Security → Report a vulnerability**. Do not open a public issue or submit a standard pull request for an unfixed security defect.

## Information to include

When filing a private vulnerability report, please provide:
- The exact FlashOS revision, commit SHA, or release tag.
- The built image format and firmware mode used during testing.
- Step-by-step reproduction instructions.
- A clear analysis of what an attacker gains or compromises.
- Any relevant serial console output, panic dumps, or boot logs that demonstrate the failure.

## What to expect

When you submit a qualified private vulnerability report:
- An initial acknowledgement within 14 days.
- An assessment of severity and architectural scope once the reported behavior is reproduced locally.
- Public credit in the release changelog entry for the fix, unless you request anonymity.

Because FlashOS is a single-maintainer pre-alpha project, developing and validating a proper fix may take considerably longer than the initial acknowledgement. If a report cannot be reproduced or falls outside the project scope, that decision will be communicated clearly rather than leaving the report unresolved.

## Coordinated disclosure

We follow a coordinated disclosure process. Private reports remain confidential between the reporter and the maintainer while investigation and remediation are underway. Once a fix is verified and packaged in a public release or changelog update, public disclosure may follow. We ask researchers not to publicize vulnerability details until remediation or official assessment is finalized.

## Known pre-alpha limitations

FlashOS is pre-alpha evaluation software built by a solo maintainer. It currently provides no guaranteed production security SLAs, no verified memory-safe kernel isolation guarantees beyond the underlying Redox baseline, and no long-term support branches.

Furthermore, published evaluation images contain known design properties that are documented rather than silently concealed (these are intentional evaluation characteristics, not reportable vulnerabilities):
- The regular `user` account has no password and belongs to the `sudo` group. Console access to an unmodified image is therefore unauthenticated, and `sudo` will escalate to root without requiring a credential.
- No network login service is installed by default, limiting this unauthenticated exposure to local console access.
- Published release images are built from a profile that locks the root account, preventing direct root login. However, evaluation images intentionally retain a passwordless `user` account so evaluators booting from removable media can reach a prompt immediately. Proper credential bootstrapping will be introduced before FlashOS targets production environments.
- Note: The historical v0.1.0 release predates the release profile and additionally contained a root account with a well-known default password. Treat all current published evaluation images as unauthenticated systems.

## Out-of-scope reports

The following components and issues are explicitly out of scope for FlashOS vulnerability reports:
- The borrowed Redox kernel, relibc, bootloader, and inherited third-party userspace packages. These are transitional dependencies; report defects in them directly to the upstream Redox OS project, and optionally open a non-sensitive FlashOS tracking issue if it affects runtime stability.
- Any vulnerability that requires an attacker to already hold root privileges on the target machine.
- The documented evaluation credentials and pre-alpha limitations listed above.
- Denial of service via normal command exhaustion or simple physical console interference.

## Safe testing

Published images are intended solely for evaluation in virtual machines (such as QEMU) or on disposable physical hardware. Never execute FlashOS evaluation images on production machines holding valuable data, and never attach an unauthenticated evaluation instance to an untrusted public network.

---

[← Back to Main README](../README.md) · [Documentation index](../docs/README.md)
