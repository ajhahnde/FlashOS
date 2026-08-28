# Roadmap

[FlashOS](../README.md) › [Product Guide](README.md) › Roadmap

This is a direction, not a release schedule. FlashOS is a solo-maintained pre-alpha project, so the order can change when testing, maintenance, or actual use points somewhere better.

## How to read it

- **Now** is work already under way.
- **Next** is the likely focus after that work lands.
- **Later** collects ideas that still need design and testing.
- **Not planned** records choices the project is deliberately avoiding.

For shipped behavior, rely on a release and its accompanying documentation and test evidence, not on this roadmap.

## What exists now

FlashOS currently provides an x86_64, keyboard-first, TUI-only evaluation environment built on the Redox kernel and a transitional Redox-derived userspace/build foundation. Flash is installed as `/usr/bin/fsh` and released at version 1.0 as a non-POSIX structured shell and automation language.

The usable scope is still narrow:

- QEMU is the primary repeatable evaluation environment;
- physical results apply only to an exact artifact and exact device;
- production security, broad hardware support, unattended installation, and long-term support are not claimed; and
- host, target, image, QEMU, and hardware evidence remain distinct.

## Now: finish a release people can trust

The immediate goal is a FlashOS release that someone outside the project can understand, build, test, and evaluate from the public repository alone.

That means finishing:

- fast source checks, with full image and runtime tests for changes that can affect the product;
- a small, documented set of developer commands and Flash-based project automation;
- a reviewed release file set and an honest pre-alpha security policy;
- one product guide, runnable examples, contributor instructions, and working navigation;
- disk and live images tied to checksums, SBOMs, provenance, manifests, QEMU results, and appropriately scoped hardware evidence; and
- publication of already-qualified candidate bytes followed by independent download and boot verification.

Before publication, the documentation, source revision, artifacts, and test results must all describe the same candidate. If a required check fails, the release waits or its claims are reduced.

## Next: build the terminal-native environment

After the evaluation release is in good shape, the next major piece is a dedicated FlashOS terminal interface built around Flash. The goal is not a graphical desktop, and not a loose collection of terminal programs.

The intended interaction model is:

```text
             shared semantic action / system API
                    /                 \
                 Flash              View
```

This work still needs designs and working implementations for:

- FlashOS-owned system actions and structured queries;
- keyboard-first views over those actions and values;
- a clear jobs/processes/services model;
- consistent permissions, errors, cancellation, and audit records; and
- the “Flash never disappears” principle: direct commands remain available when a higher-level view exists.

The dedicated TUI, stable system API, shared Shell/View actions, and service interface do not exist today.

## Later: take ownership where it helps

Some inherited userspace and build dependencies may change when doing so would improve the product, security, or maintenance. The right choice may be an upstream contribution, a small patch set, a maintained fork, a replacement, or no change at all.

The Redox kernel is expected to remain an upstream project. Taking responsibility for how a component behaves in FlashOS does not erase its origin, license, copyright, or attribution.

Later work may also broaden:

- networking, storage, USB/PCI, framebuffer/input, audio, and power-management evidence;
- supported physical systems after repeatable device qualification exists;
- additional architectures only after the x86_64 product and toolchain boundaries are sustainable; and
- security hardening and account lifecycle only when the implementation and release process can support honest claims.

These are possibilities, not delivery promises.

## Flash language direction

Flash 1.0 is the compatibility baseline for the language and runtime. Diagnostics, tooling, platform adapters, performance, and automation can improve without breaking it. Grammar or runtime changes that are incompatible with 1.0 would require a future major version.

Today, `plan` inspects one foreground pipeline without running it. Effect-aware planning, controlled apply, secret handling, typed cloud adapters, and persistent audit output are ideas for later. Flash is not presented as a replacement for Terraform, OpenTofu, Kubernetes, provider state engines, or established cloud SDKs.

## Not planned

The current roadmap does not include:

- a conventional graphical desktop or web browser as the product center;
- POSIX-shell compatibility for Flash;
- a bulk rewrite of the Redox kernel;
- production-security, broad-hardware, unattended-installation, or support guarantees before evidence exists;
- simultaneous expansion across many architectures; or
- replacement of mature external tools merely to maximize original code.

## When the roadmap changes

Testing, maintenance costs, security findings, user feedback, or upstream changes may reorder this page. A proposal is easier to evaluate when it names the user problem, separates current behavior from the requested change, and explains how the result could be tested. See [Contributing](../CONTRIBUTING.md).

---

[← Previous: Hardware Compatibility](hardware.md) · [Documentation index](README.md) · [Next: About Me →](aboutme.md)
