#!/usr/bin/env python3
"""Classify changed paths for FlashOS hosted qualification.

The classifier is intentionally fail-closed: only small, explicit path sets may
skip product-image qualification. Everything else, including an unknown path,
selects the product lane.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath

SCHEMA = 1

# These files describe the repository or configure reporting without changing
# source, build, package, image, runtime, or release-candidate behavior.
LOW_RISK_FILES = {
    ".github/SECURITY.md",
    ".github/dependabot.yml",
    ".gitignore",
    "CODE_OF_CONDUCT.md",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "DOCUMENTATION.md",
    "HARDWARE.md",
    "LICENSE",
    "NOTICE",
    "README.md",
    "TRADEMARK.md",
    "codecov.yml",
}
LOW_RISK_PREFIXES = (
    ".github/ISSUE_TEMPLATE/",
    ".github/PULL_REQUEST_TEMPLATE/",
    "docs/",
    "LICENSES/",
)

# These helpers execute only on a development host. Their own tests remain in
# the fast lane; changing them does not alter assembled FlashOS bytes.
HOST_TOOL_FILES = {"flashos.sh", "flashos.zsh"}

# Markdown beside implementation may explain that implementation without
# changing it. Non-Markdown files under these trees remain product-affecting.
SOURCE_ADJACENT_DOC_PREFIXES = ("components/flash/docs/",)


@dataclass(frozen=True)
class Classification:
    schema: int
    lane: str
    image_required: bool
    target_required: bool
    security_required: bool
    reasons: tuple[str, ...]
    paths: tuple[str, ...]


def _normalise(path: str) -> str:
    value = path.strip().replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    candidate = PurePosixPath(value)
    if not value or candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError(f"invalid repository-relative path: {path!r}")
    return candidate.as_posix()


def _is_low_risk(path: str) -> bool:
    if path in LOW_RISK_FILES or path in HOST_TOOL_FILES:
        return True
    if path.startswith(LOW_RISK_PREFIXES):
        return True
    return path.endswith(".md") and path.startswith(SOURCE_ADJACENT_DOC_PREFIXES)


def _target_required(path: str) -> bool:
    return path.startswith(
        (
            "components/flash/",
            "config/",
            "recipes/terminal/flash/",
        )
    )


def _security_required(path: str) -> bool:
    if path in {
        ".github/dependabot.yml",
        ".github/workflows/security.yml",
        "Cargo.lock",
        "Cargo.toml",
        "deny.toml",
        "components/flash/Cargo.lock",
        "components/flash/Cargo.toml",
        "components/flash/deny.toml",
    }:
        return True
    parts = PurePosixPath(path).parts
    return (
        len(parts) >= 4
        and parts[:2] == ("components", "flash")
        and parts[-1] == "Cargo.toml"
    )


def classify(paths: Iterable[str]) -> Classification:
    normalised = tuple(sorted({_normalise(path) for path in paths if path.strip()}))
    if not normalised:
        return Classification(
            schema=SCHEMA,
            lane="product",
            image_required=True,
            target_required=True,
            security_required=True,
            reasons=("no changed paths were supplied; qualification fails closed",),
            paths=(),
        )

    product_paths = tuple(path for path in normalised if not _is_low_risk(path))
    security_required = any(_security_required(path) for path in normalised)
    if product_paths:
        target_paths = tuple(path for path in product_paths if _target_required(path))
        reasons = [
            "product or unknown paths require image and runtime qualification",
            *(f"product: {path}" for path in product_paths),
        ]
        if target_paths:
            reasons.append("target-affecting paths are compiled by the image producer")
        return Classification(
            schema=SCHEMA,
            lane="product",
            image_required=True,
            target_required=bool(target_paths),
            security_required=security_required,
            reasons=tuple(reasons),
            paths=normalised,
        )

    return Classification(
        schema=SCHEMA,
        lane="fast",
        image_required=False,
        target_required=False,
        security_required=security_required,
        reasons=(
            "every changed path is explicitly isolated documentation, policy, "
            "reporting, or host tooling",
        ),
        paths=normalised,
    )


def _write_output(name: str, value: str) -> None:
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with Path(output).open("a", encoding="utf-8") as destination:
            destination.write(f"{name}={value}\n")


def _write_summary(result: Classification) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary:
        return
    with Path(summary).open("a", encoding="utf-8") as destination:
        destination.write("## FlashOS change classification\n\n")
        destination.write(f"- lane: `{result.lane}`\n")
        destination.write(f"- image required: `{str(result.image_required).lower()}`\n")
        destination.write(
            f"- target-affecting paths: `{str(result.target_required).lower()}`\n"
        )
        destination.write(
            f"- dependency policy required: `{str(result.security_required).lower()}`\n"
        )
        destination.write("- reasons:\n")
        for reason in result.reasons:
            destination.write(f"  - {reason}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "paths",
        nargs="*",
        help="repository-relative changed paths; stdin is used when omitted",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON")
    parser.add_argument(
        "--null",
        action="store_true",
        help="read NUL-delimited paths from stdin",
    )
    args = parser.parse_args(argv)
    if args.paths:
        paths = args.paths
    elif args.null:
        paths = sys.stdin.read().split("\0")
    else:
        paths = [line.rstrip("\n") for line in sys.stdin]
    try:
        result = classify(paths)
    except ValueError as error:
        parser.error(str(error))

    payload = json.dumps(asdict(result), sort_keys=True, separators=(",", ":"))
    _write_output("lane", result.lane)
    _write_output("image_required", str(result.image_required).lower())
    _write_output("target_required", str(result.target_required).lower())
    _write_output("security_required", str(result.security_required).lower())
    _write_output("classification", payload)
    _write_summary(result)
    if args.json or not os.environ.get("GITHUB_OUTPUT"):
        print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
