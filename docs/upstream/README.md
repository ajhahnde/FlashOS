# Upstream Reference Documentation

[FlashOS](../../README.md) › [Documentation](../README.md) › Upstream References

This directory preserves unchanged reference documents inherited from the Redox OS origin project. It provides transparency into upstream hardware compatibility observations and trademark guidelines without replacing independent FlashOS project contracts.

## Purpose of this directory

During its bootstrap phase, FlashOS utilizes the Redox OS kernel, target toolchain, relibc, and transitional package infrastructure. This directory hosts original reference material that helps developers understand underlying driver architectures, expected device support, and historical context.

## Available references

- [Upstream Hardware Reference](REDOX_HARDWARE.md) — Inherited reports and device testing tables collected by the Redox OS project.
- [Upstream Trademark Reference](REDOX_TRADEMARK.md) — Original trademark guidelines from the Redox OS origin repository.

## How to interpret these documents

These files represent historical or parallel observations from an independent upstream project:
- They describe Redox OS behavior and testing outcomes, not verified FlashOS product milestones.
- References to default graphical desktop interfaces or applications inside these files do not alter FlashOS's explicit TUI-only product focus.
- Do not modify or rewrite the content of these preserved reference documents to reflect FlashOS customizations.

## Relationship to FlashOS support claims

Information contained in upstream reference documents does not imply or guarantee hardware support in FlashOS:
- A device listed as functioning in `REDOX_HARDWARE.md` is considered a hint for theoretical driver availability, not a qualified FlashOS system.
- Official FlashOS hardware support requires exact-device identification, live USB boot validation, terminal interaction, and pipeline testing as defined in [Hardware Compatibility](../hardware.md).
- Similarly, the upstream trademark file does not substitute for FlashOS's own branding policy defined in [Trademark Policy](../../TRADEMARK.md).

## Upstream project and attribution

The FlashOS repository retains clear attribution to Redox OS and tracks the [`redox-os/redox`](https://github.com/redox-os/redox) repository via the optional `upstream` Git remote. Upstream technical reuse does not transfer project ownership, release governance, or roadmap authority to or from the Redox OS nonprofit. For complete legal attribution, refer to [NOTICE](../../NOTICE).

## Related FlashOS documentation

- [Architecture](../architecture.md) — Explanation of the transitional Redox infrastructure and long-term kernel boundaries.
- [Hardware Compatibility](../hardware.md) — The single source of truth for verified FlashOS physical hardware testing.
- [Trademark and Project Identity](../../TRADEMARK.md) — FlashOS name, logo, and identity guidelines.

---

[← Back to Documentation Index](../README.md) · [Documentation index](../README.md)
