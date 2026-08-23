#!/usr/bin/env python3
"""Validate the versioned FlashOS capability report and runtime fixtures."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path
from typing import NoReturn

from flashos_runtime_fixtures import (
    FixtureContractError,
    RuntimeFixtureSuite,
    load_fixture_suite,
)

ROOT = Path(__file__).resolve().parents[1]
REPORT_PATH = (
    ROOT
    / "components/flash/platforms/flashos-x86_64-capability-report-v1.toml"
)
EVIDENCE_PATH = (
    ROOT / "components/flash/platforms/flashos-x86_64-capability-evidence.toml"
)
CLASSIFICATION_PATH = (
    ROOT
    / "components/flash/platforms/flashos-x86_64-capability-classification.toml"
)
ADAPTER_PATH = ROOT / "components/flash/crates/flash-platform-flashos/src/lib.rs"
WORKSPACE_PATH = ROOT / "components/flash/Cargo.toml"
TARGET = "x86_64-unknown-redox"


def fail(message: str) -> NoReturn:
    print(f"FlashOS capability report: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_toml(path: Path) -> dict:
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {path.relative_to(ROOT)}: {error}")


def require_keys(table: dict, expected: set[str], label: str) -> None:
    actual = set(table)
    if actual != expected:
        fail(f"{label} fields are {sorted(actual)!r}, expected {sorted(expected)!r}")


def require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    return value


def require_string_list(
    value: object,
    label: str,
    *,
    nonempty: bool,
) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item.strip() for item in value
    ):
        fail(f"{label} must be a list of non-empty strings")
    if nonempty and not value:
        fail(f"{label} must not be empty")
    if len(value) != len(set(value)):
        fail(f"{label} contains duplicates")
    return value


def release_version(root: Path) -> str:
    for line in (root / "versions.env").read_text().splitlines():
        if line.startswith("FLASHOS_RELEASE_VERSION="):
            return line.split("=", 1)[1]
    fail("FLASHOS_RELEASE_VERSION is missing")


def withheld_variant(source: str) -> str:
    match = re.search(
        r"const QUALIFIED_CAPABILITIES: Capabilities\s*=\s*"
        r"Capabilities::full_without\(Capability::(?P<variant>[A-Za-z]+)\);",
        source,
    )
    if match is None:
        fail("selected adapter capability declaration has an unknown shape")
    return match.group("variant")


def validate_fixtures(
    suite: RuntimeFixtureSuite,
    capability_names: set[str],
    withheld_name: str,
) -> None:
    used_capabilities: set[str] = set()
    for fixture in suite.fixtures:
        unknown = set(fixture.capabilities) - capability_names
        if unknown:
            fail(
                f"fixture {fixture.identifier!r} references unknown capabilities "
                f"{sorted(unknown)!r}"
            )
        used_capabilities.update(fixture.capabilities)
    advertised_names = capability_names - {withheld_name}
    if used_capabilities != advertised_names:
        missing = sorted(advertised_names - used_capabilities)
        extra = sorted(used_capabilities - advertised_names)
        fail(
            "runtime fixtures must cover every advertised capability exactly as a "
            f"set; missing={missing!r}, extra={extra!r}"
        )


def validate(document: dict, root: Path = ROOT) -> None:
    top_fields = {
        "schema_version",
        "report_version",
        "platform",
        "architecture",
        "target",
        "flash_language_major",
        "flash_workspace_version",
        "flashos_release",
        "platform_baseline",
        "capability_evidence",
        "capability_classification",
        "runtime_fixtures",
        "target_matrix",
        "contract_source",
        "selected_adapter",
        "qualification",
        "semantics",
        "capability",
    }
    require_keys(document, top_fields, "document")
    workspace = load_toml(root / "components/flash/Cargo.toml")
    workspace_version = workspace.get("workspace", {}).get("package", {}).get(
        "version"
    )
    expected_scalars = {
        "schema_version": 1,
        "report_version": 1,
        "platform": "flashos",
        "architecture": "x86_64",
        "target": TARGET,
        "flash_language_major": 1,
        "flash_workspace_version": workspace_version,
        "flashos_release": release_version(root),
        "platform_baseline": "flashos-x86_64.toml",
        "capability_evidence": "flashos-x86_64-capability-evidence.toml",
        "capability_classification": (
            "flashos-x86_64-capability-classification.toml"
        ),
        "runtime_fixtures": "flashos-x86_64-runtime-fixtures-v1.toml",
        "target_matrix": "flashos-x86_64-target-matrix-v1.toml",
        "contract_source": "components/flash/crates/flash-platform/src/lib.rs",
        "selected_adapter": "flash-platform-flashos::FlashOsPlatform",
        "qualification": "bounded",
    }
    for field, expected in expected_scalars.items():
        if document.get(field) != expected:
            fail(f"{field} is {document.get(field)!r}, expected {expected!r}")

    semantics = document.get("semantics")
    if not isinstance(semantics, dict):
        fail("semantics must be a table")
    require_keys(semantics, {"advertised", "withheld", "scope"}, "semantics")
    for name, value in semantics.items():
        require_string(value, f"semantics.{name}")

    evidence = load_toml(
        root / "components/flash/platforms" / document["capability_evidence"]
    )
    classification = load_toml(
        root / "components/flash/platforms" / document["capability_classification"]
    )
    for field in (
        "platform",
        "architecture",
        "target",
        "platform_baseline",
        "contract_source",
        "selected_adapter",
    ):
        if evidence.get(field) != document[field]:
            fail(f"{field} does not match the capability evidence")
        if classification.get(field) != document[field]:
            fail(f"{field} does not match the capability classification")

    evidenced = evidence.get("capability")
    classified = classification.get("capability")
    reported = document.get("capability")
    if not isinstance(evidenced, list) or not evidenced:
        fail("capability evidence has no capability array")
    if not isinstance(classified, list) or len(classified) != len(evidenced):
        fail("capability classification does not cover the evidence")
    if not isinstance(reported, list) or len(reported) != len(evidenced):
        fail("report must cover every capability exactly once")

    try:
        suite = load_fixture_suite(
            root / "components/flash/platforms" / document["runtime_fixtures"]
        )
    except FixtureContractError as error:
        fail(str(error))
    fixture_by_id = {fixture.identifier: fixture for fixture in suite.fixtures}
    capability_names = {
        require_string(item.get("name"), f"evidence capability[{index}].name")
        for index, item in enumerate(evidenced)
        if isinstance(item, dict)
    }
    if len(capability_names) != len(evidenced):
        fail("evidence capability names contain duplicates or invalid records")
    omitted_variant = withheld_variant(
        (root / "components/flash/crates/flash-platform-flashos/src/lib.rs").read_text()
    )
    variant_to_name = {
        item["rust_variant"]: item["name"]
        for item in evidenced
        if isinstance(item, dict)
    }
    omitted_name = variant_to_name.get(omitted_variant)
    if omitted_name is None:
        fail(f"selected adapter withholds unknown capability {omitted_variant!r}")
    validate_fixtures(suite, capability_names, omitted_name)
    capability_fields = {
        "name",
        "rust_variant",
        "classification",
        "advertised",
        "qualification",
        "fixture_ids",
        "summary",
        "limitations",
    }
    used_fixtures: set[str] = set()
    for index, (record, evidence_record, classification_record) in enumerate(
        zip(reported, evidenced, classified, strict=True)
    ):
        label = f"capability[{index}]"
        if not all(
            isinstance(item, dict)
            for item in (record, evidence_record, classification_record)
        ):
            fail(f"{label} and its source records must be tables")
        require_keys(record, capability_fields, label)
        name = require_string(record.get("name"), f"{label}.name")
        variant = require_string(record.get("rust_variant"), f"{label}.rust_variant")
        if name != evidence_record.get("name") or variant != evidence_record.get(
            "rust_variant"
        ):
            fail(f"{label} does not match the ordered capability evidence")
        if name != classification_record.get(
            "name"
        ) or variant != classification_record.get("rust_variant"):
            fail(f"{label} does not match the ordered capability classification")
        if record.get("classification") != classification_record.get("classification"):
            fail(f"{label}.classification does not match the route classification")
        require_string(record.get("summary"), f"{label}.summary")
        require_string_list(
            record.get("limitations"), f"{label}.limitations", nonempty=True
        )

        advertised = record.get("advertised")
        if not isinstance(advertised, bool):
            fail(f"{label}.advertised must be a boolean")
        expected_advertised = variant != omitted_variant
        if advertised != expected_advertised:
            fail(
                f"{label}.advertised is {advertised!r}, expected "
                f"{expected_advertised!r} from the selected adapter"
            )
        expected_qualification = "bounded" if advertised else "withheld"
        if record.get("qualification") != expected_qualification:
            fail(
                f"{label}.qualification must be {expected_qualification!r}"
            )
        fixture_ids = require_string_list(
            record.get("fixture_ids"),
            f"{label}.fixture_ids",
            nonempty=advertised,
        )
        if not advertised and fixture_ids:
            fail(f"{label}.fixture_ids must be empty while the capability is withheld")
        for identifier in fixture_ids:
            fixture = fixture_by_id.get(identifier)
            if fixture is None:
                fail(f"{label} references unknown fixture {identifier!r}")
            if name not in fixture.capabilities:
                fail(f"fixture {identifier!r} does not declare capability {name!r}")
        used_fixtures.update(fixture_ids)

    if used_fixtures != set(fixture_by_id):
        fail(
            "unreferenced runtime fixtures: "
            f"{sorted(set(fixture_by_id) - used_fixtures)!r}"
        )

    qemu_source = (root / "ci/qemu_smoke.py").read_text()
    for marker in (
        "load_fixture_suite(args.fixtures)",
        "for fixture in runtime_suite.fixtures:",
        "for step in fixture.steps:",
    ):
        if marker not in qemu_source:
            fail(f"QEMU runner does not consume the fixture contract: {marker}")
    workflow = (root / ".github/workflows/ci.yml").read_text()
    if "python3 ci/check_flashos_capability_report.py" not in workflow:
        fail("standard CI does not validate the versioned capability report")


def main() -> None:
    document = load_toml(REPORT_PATH)
    validate(document)
    print(f"FlashOS capability report: bounded contract passed for {TARGET}")


if __name__ == "__main__":
    main()
