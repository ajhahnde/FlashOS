#!/usr/bin/env python3
"""Validate the FlashOS platform-capability evidence inventory."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_PATH = (
    ROOT / "components/flash/platforms/flashos-x86_64-capability-evidence.toml"
)
BASELINE_PATH = ROOT / "components/flash/platforms/flashos-x86_64.toml"
CONTRACT_PATH = ROOT / "components/flash/crates/flash-platform/src/lib.rs"
TARGET = "x86_64-unknown-redox"


def fail(message: str) -> NoReturn:
    print(f"FlashOS capability evidence: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_toml(path: Path) -> dict:
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {path.relative_to(ROOT)}: {error}")


def parse_capability_variants(source: str) -> list[str]:
    match = re.search(
        r"pub enum Capability \{(?P<body>.*?)\n\}\n\nimpl Capability",
        source,
        re.DOTALL,
    )
    if match is None:
        fail("cannot locate the Capability enum")
    return re.findall(r"^    ([A-Z][A-Za-z0-9]+),$", match.group("body"), re.MULTILINE)


def require_keys(table: dict, expected: set[str], label: str) -> None:
    actual = set(table)
    if actual != expected:
        fail(
            f"{label} fields are {sorted(actual)!r}, expected {sorted(expected)!r}"
        )


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


def validate_evidence_records(
    records: object,
    label: str,
    root: Path,
) -> dict[str, dict]:
    if not isinstance(records, list) or not records:
        fail(f"{label} must be a non-empty array of tables")
    indexed: dict[str, dict] = {}
    for index, record in enumerate(records):
        item = f"{label}[{index}]"
        if not isinstance(record, dict):
            fail(f"{item} must be a table")
        require_keys(record, {"id", "path", "markers", "observation"}, item)
        identifier = require_string(record.get("id"), f"{item}.id")
        if identifier in indexed:
            fail(f"duplicate {label} id {identifier!r}")
        relative = Path(require_string(record.get("path"), f"{item}.path"))
        if relative.is_absolute() or ".." in relative.parts:
            fail(f"{item}.path must stay inside the repository")
        path = root / relative
        try:
            source = path.read_text()
        except OSError as error:
            fail(f"cannot read {relative}: {error}")
        markers = require_string_list(
            record.get("markers"), f"{item}.markers", nonempty=True
        )
        for marker in markers:
            if marker not in source:
                fail(f"{item} marker is absent from {relative}: {marker!r}")
        require_string(record.get("observation"), f"{item}.observation")
        indexed[identifier] = record
    return indexed


def validate(document: dict, root: Path = ROOT) -> None:
    top_fields = {
        "schema_version",
        "platform",
        "architecture",
        "target",
        "platform_baseline",
        "contract_source",
        "selected_adapter",
        "classification",
        "source_evidence",
        "runtime_evidence",
        "capability",
    }
    require_keys(document, top_fields, "document")
    expected_scalars = {
        "schema_version": 1,
        "platform": "flashos",
        "architecture": "x86_64",
        "target": TARGET,
        "platform_baseline": "flashos-x86_64.toml",
        "contract_source": "components/flash/crates/flash-platform/src/lib.rs",
        "selected_adapter": "flash-platform-flashos::FlashOsPlatform",
        "classification": "deferred",
    }
    for field, expected in expected_scalars.items():
        if document.get(field) != expected:
            fail(f"{field} is {document.get(field)!r}, expected {expected!r}")

    baseline = load_toml(root / "components/flash/platforms/flashos-x86_64.toml")
    if baseline.get("architecture") != document["architecture"]:
        fail("architecture does not match the platform baseline")
    target = baseline.get("target")
    if not isinstance(target, dict) or target.get("triple") != document["target"]:
        fail("target does not match the platform baseline")

    source_records = validate_evidence_records(
        document.get("source_evidence"), "source_evidence", root
    )
    runtime_records = validate_evidence_records(
        document.get("runtime_evidence"), "runtime_evidence", root
    )

    capabilities = document.get("capability")
    if not isinstance(capabilities, list) or not capabilities:
        fail("capability must be a non-empty array of tables")
    capability_fields = {
        "name",
        "rust_variant",
        "requirements",
        "source_evidence",
        "runtime_evidence",
        "source_observation",
        "runtime_observation",
        "classification",
    }
    variants: list[str] = []
    names: list[str] = []
    used_source: set[str] = set()
    used_runtime: set[str] = set()
    for index, capability in enumerate(capabilities):
        label = f"capability[{index}]"
        if not isinstance(capability, dict):
            fail(f"{label} must be a table")
        require_keys(capability, capability_fields, label)
        name = require_string(capability.get("name"), f"{label}.name")
        variant = require_string(
            capability.get("rust_variant"), f"{label}.rust_variant"
        )
        require_string_list(
            capability.get("requirements"), f"{label}.requirements", nonempty=True
        )
        source_ids = require_string_list(
            capability.get("source_evidence"),
            f"{label}.source_evidence",
            nonempty=True,
        )
        runtime_ids = require_string_list(
            capability.get("runtime_evidence"),
            f"{label}.runtime_evidence",
            nonempty=False,
        )
        for identifier in source_ids:
            if identifier not in source_records:
                fail(f"{label} references unknown source evidence {identifier!r}")
        for identifier in runtime_ids:
            if identifier not in runtime_records:
                fail(f"{label} references unknown runtime evidence {identifier!r}")
        require_string(
            capability.get("source_observation"), f"{label}.source_observation"
        )
        require_string(
            capability.get("runtime_observation"), f"{label}.runtime_observation"
        )
        if capability.get("classification") != "deferred":
            fail(f"{label}.classification must remain 'deferred'")
        names.append(name)
        variants.append(variant)
        used_source.update(source_ids)
        used_runtime.update(runtime_ids)

    if len(names) != len(set(names)):
        fail("capability names contain duplicates")
    if len(variants) != len(set(variants)):
        fail("capability rust_variant values contain duplicates")
    contract_source = (root / document["contract_source"]).read_text()
    contract_variants = parse_capability_variants(contract_source)
    if variants != contract_variants:
        fail(
            f"manifest variants are {variants!r}, "
            f"contract declares {contract_variants!r}"
        )
    if used_source != set(source_records):
        fail(
            "unreferenced source evidence ids: "
            f"{sorted(set(source_records) - used_source)!r}"
        )
    if used_runtime != set(runtime_records):
        fail(
            "unreferenced runtime evidence ids: "
            f"{sorted(set(runtime_records) - used_runtime)!r}"
        )

    workflow = (root / ".github/workflows/ci.yml").read_text()
    if "python3 ci/check_flashos_capabilities.py" not in workflow:
        fail("standard CI does not validate the capability evidence inventory")


def main() -> None:
    document = load_toml(EVIDENCE_PATH)
    validate(document)
    print(
        "FlashOS capability evidence: source/runtime comparison contract passed "
        f"for {TARGET}"
    )


if __name__ == "__main__":
    main()
