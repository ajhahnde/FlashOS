---
name: Bug report
about: Report reproducible incorrect FlashOS or Flash behavior
title: "bug: "
labels: bug
assignees: ""
---

## Revision or release

Give the Git commit, FlashOS release, or image filename you used. For Flash problems, also include `fsh --version`.

## Environment

Describe the host or FlashOS environment, architecture, and image profile. Say whether this happened on a host, in QEMU, or on physical hardware.

## Reproduction

Include the shortest complete commands or source that still reproduces the problem. Remove credentials, private paths, and unrelated logs.

## Expected behavior

What did you expect? If documentation describes that behavior, link it here.

## Actual behavior

Include the status, stdout, stderr, or other behavior you observed.

## Verification attempted

List the checks you ran and whether each passed or failed. Keep host, target, image, and hardware results separate.

## Safety and security

Do not include secrets. Do not report suspected vulnerabilities here; follow the [Security Policy](../SECURITY.md). Do not perform a new physical-device write solely to complete this report.
