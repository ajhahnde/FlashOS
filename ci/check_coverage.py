#!/usr/bin/env python3
"""Reject empty or structurally incomplete Flash host-coverage reports."""

from __future__ import annotations

import argparse
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FLASH_ROOT = ROOT / "components/flash"
FLASH_MANIFEST = FLASH_ROOT / "Cargo.toml"
FLASH_CRATES = Path("components/flash/crates")


def fail(message: str) -> None:
    raise SystemExit(f"coverage contract: {message}")


def repository_path(raw_path: str) -> Path | None:
    path = Path(raw_path)
    candidates = [path] if path.is_absolute() else [ROOT / path, FLASH_ROOT / path]
    for candidate in candidates:
        resolved = candidate.resolve()
        try:
            return resolved.relative_to(ROOT)
        except ValueError:
            continue
    return None


def workspace_members() -> tuple[Path, ...]:
    with FLASH_MANIFEST.open("rb") as manifest_file:
        manifest = tomllib.load(manifest_file)
    members = manifest.get("workspace", {}).get("members", [])
    if not members or not all(isinstance(member, str) for member in members):
        fail("Flash workspace members are missing or invalid")
    return tuple(Path("components/flash") / member for member in members)


def validate(report: Path) -> None:
    if not report.is_file() or report.stat().st_size == 0:
        fail(f"report is missing or empty: {report}")

    covered_files: set[Path] = set()
    current_file: Path | None = None
    executable_lines = 0
    hit_lines = 0

    for line_number, line in enumerate(report.read_text().splitlines(), 1):
        if line.startswith("SF:"):
            current_file = repository_path(line.removeprefix("SF:"))
            if current_file is not None and current_file.is_relative_to(FLASH_CRATES):
                covered_files.add(current_file)
            else:
                current_file = None
            continue
        if not line.startswith("DA:") or current_file is None:
            continue
        fields = line.removeprefix("DA:").split(",")
        if len(fields) < 2:
            fail(f"invalid DA record at line {line_number}")
        try:
            count = int(fields[1])
        except ValueError:
            fail(f"invalid execution count at line {line_number}")
        executable_lines += 1
        if count > 0:
            hit_lines += 1

    if not covered_files or executable_lines == 0:
        fail("report contains no first-party executable Rust lines")
    if hit_lines == 0:
        fail("report contains no executed first-party Rust lines")

    members = workspace_members()
    missing_members = []
    for member in members:
        source_root = member / "src"
        if not any(path.is_relative_to(source_root) for path in covered_files):
            missing_members.append(str(member))
    if missing_members:
        fail("report omitted Flash workspace members: " + ", ".join(missing_members))

    percent = hit_lines * 100 / executable_lines
    print("coverage contract: ok")
    print(f"workspace members: {len(members)}")
    print(f"reported first-party files: {len(covered_files)}")
    print(f"host line coverage: {hit_lines}/{executable_lines} ({percent:.2f}%)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path, help="LCOV report to validate")
    args = parser.parse_args()
    validate(args.report.resolve())


if __name__ == "__main__":
    main()
