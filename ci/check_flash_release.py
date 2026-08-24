#!/usr/bin/env python3
"""Validate the Flash 1.0.0 release identity and qualification contract."""

from __future__ import annotations

import datetime as dt
import sys
import tomllib
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
FLASH_ROOT = ROOT / "components/flash"
RELEASE_PATH = FLASH_ROOT / "release/v1.toml"
WORKSPACE_PATH = FLASH_ROOT / "Cargo.toml"
LOCK_PATH = FLASH_ROOT / "Cargo.lock"
FUZZ_LOCK_PATH = FLASH_ROOT / "fuzz/Cargo.lock"
CHANGELOG_PATH = FLASH_ROOT / "CHANGELOG.md"
WORKFLOW_PATH = ROOT / ".github/workflows/ci.yml"

FLASH_PACKAGES = {
    "flash-cli",
    "flash-lsp",
    "flash-platform",
    "flash-platform-flashos",
    "flash-platform-posix",
    "flash-runtime",
    "flash-syntax",
}
REQUIRED_CHECKS = [
    "python3 ci/check_flashos_capability_report.py",
    "python3 ci/check_flashos_target_matrix.py",
    "python3 ../../ci/check_flash_conformance.py",
    "python3 ../../ci/check_flash_v1_exercises.py",
    "python3 ../../ci/check_flash_release.py",
    "python3 exercises/run.py --profile ci --no-build",
]
CLAIM_DOCUMENTS = [
    "components/flash/README.md",
    "components/flash/docs/README.md",
    "components/flash/docs/architecture.md",
    "components/flash/docs/development.md",
    "components/flash/docs/language-guide.md",
    "components/flash/docs/scripting.md",
    "docs/roadmap.md",
]
FORBIDDEN_RELEASE_CLAIMS = (
    "Flash v1.0 has not yet been released",
    "entering the v1 release candidate",
    "Now: Complete and qualify Flash v1",
    "one contiguous internal island",
    "remain required for Flash v1",
)
REQUIRED_LIMITATIONS = [
    "FlashOS product versions, images, tags, and publication remain separate "
    "release boundaries.",
    "Physical FlashOS hardware remains outside this component release and "
    "requires separately recorded, approval-gated evidence.",
]


def fail(message: str) -> NoReturn:
    print(f"Flash release: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_toml(path: Path) -> dict:
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {path.relative_to(ROOT)}: {error}")


def load_release(path: Path = RELEASE_PATH) -> dict:
    return load_toml(path)


def require_keys(table: dict, expected: set[str], label: str) -> None:
    actual = set(table)
    if actual != expected:
        fail(f"{label} fields are {sorted(actual)!r}, expected {sorted(expected)!r}")


def require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    return value


def require_string_list(value: object, label: str, *, nonempty: bool) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item.strip() for item in value
    ):
        fail(f"{label} must be a list of non-empty strings")
    if nonempty and not value:
        fail(f"{label} must not be empty")
    if len(value) != len(set(value)):
        fail(f"{label} contains duplicates")
    return value


def safe_file(value: str, label: str) -> Path:
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        fail(f"{label} must stay inside the repository")
    path = ROOT / relative
    if not path.is_file():
        fail(f"{label} does not name a file: {value}")
    return path


def flash_file(value: str, label: str) -> Path:
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        fail(f"{label} must stay inside components/flash")
    path = FLASH_ROOT / relative
    if not path.is_file():
        fail(f"{label} does not name a file: {value}")
    return path


def validate(document: dict, root: Path = ROOT) -> None:
    require_keys(
        document,
        {
            "schema_version",
            "release_version",
            "language_major",
            "status",
            "release_date",
            "conformance",
            "exercise_contract",
            "host_evidence",
            "capability_report",
            "target_matrix",
            "release_findings",
            "unexamined_inventory_items",
            "qualified_environments",
            "required_checks",
            "claim_documents",
            "limitations",
        },
        "document",
    )
    if document.get("schema_version") != 1:
        fail("schema_version must be 1")
    version = require_string(document.get("release_version"), "release_version")
    if version != "1.0.0":
        fail("release_version must be 1.0.0")
    if document.get("language_major") != 1:
        fail("language_major must be 1")
    if document.get("status") != "released":
        fail("status must be 'released'")
    release_date = require_string(document.get("release_date"), "release_date")
    try:
        dt.date.fromisoformat(release_date)
    except ValueError:
        fail("release_date must be an ISO calendar date")

    workspace = load_toml(root / WORKSPACE_PATH.relative_to(ROOT))
    workspace_version = workspace.get("workspace", {}).get("package", {}).get(
        "version"
    )
    if workspace_version != version:
        fail(f"workspace version is {workspace_version!r}, expected {version!r}")

    for lock_path, expected_packages in (
        (LOCK_PATH, FLASH_PACKAGES),
        (FUZZ_LOCK_PATH, {"flash-platform", "flash-runtime", "flash-syntax"}),
    ):
        lock = load_toml(root / lock_path.relative_to(ROOT))
        locked_flash = {
            package.get("name"): package.get("version")
            for package in lock.get("package", [])
            if isinstance(package, dict) and package.get("name") in expected_packages
        }
        if set(locked_flash) != expected_packages:
            fail(f"{lock_path.relative_to(ROOT)} does not contain every Flash package")
        stale = sorted(
            name for name, locked_version in locked_flash.items()
            if locked_version != version
        )
        if stale:
            fail(
                f"{lock_path.relative_to(ROOT)} retains pre-release Flash versions: "
                f"{stale!r}"
            )

    referenced = {
        "conformance": "conformance/v1.toml",
        "exercise_contract": "exercises/v1.toml",
        "host_evidence": "exercises/evidence/host-v1.json",
        "capability_report": "platforms/flashos-x86_64-capability-report-v1.toml",
        "target_matrix": "platforms/flashos-x86_64-target-matrix-v1.toml",
    }
    for field, expected in referenced.items():
        if document.get(field) != expected:
            fail(f"{field} is {document.get(field)!r}, expected {expected!r}")
        flash_file(expected, field)

    conformance = load_toml(FLASH_ROOT / document["conformance"])
    if conformance.get("language_major") != 1:
        fail("conformance language major does not match the release")
    if conformance.get("contract_status") != "frozen":
        fail("the released conformance contract is not frozen")
    exercises = load_toml(FLASH_ROOT / document["exercise_contract"])
    if exercises.get("language_major") != 1:
        fail("exercise language major does not match the release")
    report = load_toml(FLASH_ROOT / document["capability_report"])
    if report.get("flash_language_major") != 1:
        fail("capability-report language major does not match the release")
    if report.get("flash_workspace_version") != version:
        fail("capability-report workspace version does not match the release")
    if report.get("target_matrix") != Path(document["target_matrix"]).name:
        fail("capability report does not select the release target matrix")
    target_matrix = load_toml(FLASH_ROOT / document["target_matrix"])
    observed_versions = [
        marker
        for case in target_matrix.get("case", [])
        if isinstance(case, dict)
        for step in case.get("step", [])
        if isinstance(step, dict)
        for marker in step.get("expect", [])
        if isinstance(marker, str) and marker.startswith("fsh ")
    ]
    if observed_versions != [f"fsh {version}"]:
        fail("target matrix does not observe the exact released fsh version once")

    for field in ("release_findings", "unexamined_inventory_items"):
        if require_string_list(document.get(field), field, nonempty=False):
            fail(f"{field} must be empty")
    if require_string_list(
        document.get("qualified_environments"),
        "qualified_environments",
        nonempty=True,
    ) != ["host-posix", "flashos-qemu-x86_64"]:
        fail("qualified_environments must name the host and exact FlashOS candidate")

    checks = require_string_list(
        document.get("required_checks"), "required_checks", nonempty=True
    )
    if checks != REQUIRED_CHECKS:
        fail("required_checks do not preserve the release qualification set")
    workflow = (root / WORKFLOW_PATH.relative_to(ROOT)).read_text()
    for check in checks:
        if workflow.count(check) != 1:
            fail(f"candidate workflow must contain exactly one {check!r}")

    claims = require_string_list(
        document.get("claim_documents"), "claim_documents", nonempty=True
    )
    if claims != CLAIM_DOCUMENTS:
        fail("claim_documents do not preserve the complete release claim set")
    for index, claim in enumerate(claims):
        source = safe_file(claim, f"claim_documents[{index}]").read_text()
        for marker in FORBIDDEN_RELEASE_CLAIMS:
            if marker in source:
                fail(f"{claim} retains pre-release claim {marker!r}")

    changelog = (root / CHANGELOG_PATH.relative_to(ROOT)).read_text()
    heading = f"## [Unreleased]\n\n## [{version}] - {release_date}\n"
    if heading not in changelog:
        fail("component changelog does not promote the exact release and date")
    limitations = require_string_list(
        document.get("limitations"), "limitations", nonempty=True
    )
    if limitations != REQUIRED_LIMITATIONS:
        fail("limitations must preserve exact product-release and physical boundaries")


def main() -> None:
    validate(load_release())
    print("Flash release: 1.0.0 contract passed")


if __name__ == "__main__":
    main()
