# Security Policy

## Project maturity

FlashOS is pre-alpha software built by a single maintainer. It has no security
guarantees, no patch service-level agreement, and no long-term support branch.
Published images are intended for evaluation on disposable hardware or in a
virtual machine. Do not run FlashOS on a machine that holds data you care
about, and do not expose it to an untrusted network.

## Supported versions

Only the most recent published release receives fixes. Earlier tags are
historical artifacts and are not patched.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Any earlier release | No |

## Known weaknesses in published images

These are documented rather than silently shipped. They are properties of the
current image profile, not vulnerabilities to report:

- The `user` account has no password and belongs to the `sudo` group. Console
  access to an unmodified image is therefore unauthenticated, and `sudo` will
  escalate to root without a credential.
- No network login service is installed, so this exposure is local rather than
  remote.

Releases are built from a profile that locks the root account, so root cannot
be logged into directly. The passwordless `user` account is intentional while
FlashOS is evaluation software: an image you boot from a USB stick to try the
system should not stand between you and a prompt. It will be replaced by a
credential set at first boot before FlashOS is presented as production
software.

The v0.1.0 release predates the release profile. Its images additionally
contain a root account with a well-known password. Treat any published image
as an unauthenticated system.

## Scope

In scope:

- FlashShell (`components/flashshell/`) — parsing, evaluation, process
  execution, redirection, and terminal handling.
- The FlashOS image profile, product contract, and release pipeline
  (`config/`, `ci/`, `.github/workflows/`).
- FlashOS-authored patches under `recipes/`.

Out of scope, and better reported upstream:

- The Redox kernel, relibc, bootloader, and inherited userspace components.
  These are transitional dependencies; report defects in them to the Redox OS
  project, and feel free to open a FlashOS issue tracking the impact.
- Anything that requires the reporter to already hold root on the target.
- The known weaknesses listed above.

## Reporting a vulnerability

Report privately through GitHub's private vulnerability reporting on this
repository: **Security → Report a vulnerability**. Do not open a public issue
for an unfixed security defect.

Please include:

- the FlashOS revision or release tag,
- the image and firmware mode used,
- the exact steps to reproduce,
- what an attacker gains,
- any serial or boot log that shows the failure.

## What to expect

- An acknowledgement within 14 days.
- An assessment of severity and scope once the report is reproduced.
- Public credit in the changelog entry for the fix, unless you prefer
  otherwise.

Because this is a single-maintainer pre-alpha project, a fix may take
considerably longer than acknowledgement. If a report is not reproducible or
falls outside the scope above, that will be stated plainly rather than left
open.
