#!/usr/bin/env python3
"""Validate the FlashOS platform capability classification."""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
CLASSIFICATION_PATH = (
    ROOT
    / "components/flash/platforms/flashos-x86_64-capability-classification.toml"
)
BASELINE_PATH = ROOT / "components/flash/platforms/flashos-x86_64.toml"
EVIDENCE_PATH = (
    ROOT / "components/flash/platforms/flashos-x86_64-capability-evidence.toml"
)
MAP_PATH = ROOT / "components/flash/platforms/flashos-x86_64-operation-map.toml"
TARGET = "x86_64-unknown-redox"
VERDICTS = {"native", "shimmed", "deliberately-unsupported", "kernel-work"}
PRECEDENCE = {
    "native": 0,
    "shimmed": 1,
    "deliberately-unsupported": 2,
    "kernel-work": 3,
}
NATIVE_BASIS = {
    "flash-internal": "existing-flash-route",
    "rust-std": "existing-rust-std-route",
    "libc-abi": "existing-libc-abi-route",
}
NON_NATIVE_BASIS = {
    "shimmed": "flashos-policy-shim",
    "deliberately-unsupported": "deliberate-policy",
    "kernel-work": "missing-kernel-primitive",
}


def fail(message: str) -> NoReturn:
    print(f"FlashOS capability classification: {message}", file=sys.stderr)
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


def require_string_list(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(
        isinstance(item, str) and item.strip() for item in value
    ):
        fail(f"{label} must be a non-empty list of non-empty strings")
    if len(value) != len(set(value)):
        fail(f"{label} contains duplicates")
    return value


def validate_operation(
    record: object,
    mapped: dict,
    index: int,
) -> tuple[str, str, str]:
    label = f"operation[{index}]"
    if not isinstance(record, dict):
        fail(f"{label} must be a table")
    require_keys(
        record,
        {"id", "capability", "classification", "basis", "rationale"},
        label,
    )
    identifier = require_string(record.get("id"), f"{label}.id")
    capability = require_string(record.get("capability"), f"{label}.capability")
    verdict = require_string(record.get("classification"), f"{label}.classification")
    basis = require_string(record.get("basis"), f"{label}.basis")
    require_string(record.get("rationale"), f"{label}.rationale")
    if verdict not in VERDICTS:
        fail(f"{label}.classification is not a classification verdict")
    if identifier != mapped.get("id") or capability != mapped.get("capability"):
        fail(f"{label} does not match the ordered operation map")

    boundary = mapped.get("boundary")
    if verdict == "native":
        expected_basis = NATIVE_BASIS.get(boundary)
        if expected_basis is None:
            fail(f"{label} cannot classify an unrouted operation as native")
    else:
        expected_basis = NON_NATIVE_BASIS[verdict]
    if basis != expected_basis:
        fail(f"{label}.basis is {basis!r}, expected {expected_basis!r}")
    return identifier, capability, verdict


def validate(document: dict, root: Path = ROOT) -> None:
    top_fields = {
        "schema_version",
        "platform",
        "architecture",
        "target",
        "platform_baseline",
        "capability_evidence",
        "operation_map",
        "contract_source",
        "selected_adapter",
        "classification",
        "target_qualification",
        "semantics",
        "operation",
        "capability",
    }
    require_keys(document, top_fields, "document")
    expected_scalars = {
        "schema_version": 1,
        "platform": "flashos",
        "architecture": "x86_64",
        "target": TARGET,
        "platform_baseline": "flashos-x86_64.toml",
        "capability_evidence": "flashos-x86_64-capability-evidence.toml",
        "operation_map": "flashos-x86_64-operation-map.toml",
        "contract_source": "components/flash/crates/flash-platform/src/lib.rs",
        "selected_adapter": "flash-platform-posix::PosixPlatform",
        "classification": "complete",
        "target_qualification": "pending",
    }
    for field, expected in expected_scalars.items():
        if document.get(field) != expected:
            fail(f"{field} is {document.get(field)!r}, expected {expected!r}")

    semantics = document.get("semantics")
    if not isinstance(semantics, dict):
        fail("semantics must be a table")
    require_keys(
        semantics,
        {
            "native",
            "shimmed",
            "deliberately_unsupported",
            "kernel_work",
            "aggregation",
            "qualification",
        },
        "semantics",
    )
    for name, value in semantics.items():
        require_string(value, f"semantics.{name}")

    baseline = load_toml(root / "components/flash/platforms/flashos-x86_64.toml")
    if baseline.get("architecture") != document["architecture"]:
        fail("architecture does not match the platform baseline")
    target = baseline.get("target")
    if not isinstance(target, dict) or target.get("triple") != document["target"]:
        fail("target does not match the platform baseline")

    evidence = load_toml(
        root / "components/flash/platforms/flashos-x86_64-capability-evidence.toml"
    )
    operation_map = load_toml(
        root / "components/flash/platforms/flashos-x86_64-operation-map.toml"
    )
    if evidence.get("classification") != "deferred":
        fail("capability evidence classification must remain deferred")
    if operation_map.get("classification") != "deferred":
        fail("operation map classification must remain deferred")
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
        if operation_map.get(field) != document[field]:
            fail(f"{field} does not match the operation map")
    if operation_map.get("capability_evidence") != document["capability_evidence"]:
        fail("operation map does not reference the selected capability evidence")

    mapped_operations = operation_map.get("operation")
    operations = document.get("operation")
    if not isinstance(mapped_operations, list) or not mapped_operations:
        fail("operation map has no operation array")
    if not isinstance(operations, list) or len(operations) != len(mapped_operations):
        fail("classification must cover every mapped operation exactly once")

    actual_operations: list[tuple[str, str, str]] = []
    for index, (record, mapped) in enumerate(
        zip(operations, mapped_operations, strict=True)
    ):
        if not isinstance(mapped, dict):
            fail(f"mapped operation {index} must be a table")
        actual_operations.append(validate_operation(record, mapped, index))
    operation_ids = [item[0] for item in actual_operations]
    if len(operation_ids) != len(set(operation_ids)):
        fail("operation ids contain duplicates")
    verdict_by_id = {
        identifier: verdict for identifier, _, verdict in actual_operations
    }

    evidence_capabilities = evidence.get("capability")
    capabilities = document.get("capability")
    if not isinstance(evidence_capabilities, list) or not evidence_capabilities:
        fail("capability evidence has no capability array")
    if not isinstance(capabilities, list) or len(capabilities) != len(
        evidence_capabilities
    ):
        fail("classification must cover every capability exactly once")

    capability_fields = {
        "name",
        "rust_variant",
        "operation_ids",
        "classification",
        "target_qualification",
        "rationale",
    }
    used_operation_ids: list[str] = []
    for index, (record, evidenced) in enumerate(
        zip(capabilities, evidence_capabilities, strict=True)
    ):
        label = f"capability[{index}]"
        if not isinstance(record, dict) or not isinstance(evidenced, dict):
            fail(f"{label} must be a table")
        require_keys(record, capability_fields, label)
        name = require_string(record.get("name"), f"{label}.name")
        variant = require_string(record.get("rust_variant"), f"{label}.rust_variant")
        if name != evidenced.get("name") or variant != evidenced.get("rust_variant"):
            fail(f"{label} does not match the ordered capability evidence")
        ids = require_string_list(record.get("operation_ids"), f"{label}.operation_ids")
        expected_ids = [
            identifier
            for identifier, capability, _ in actual_operations
            if capability == name
        ]
        if ids != expected_ids:
            fail(f"{label}.operation_ids do not exactly cover the capability")
        used_operation_ids.extend(ids)
        verdict = require_string(
            record.get("classification"), f"{label}.classification"
        )
        if verdict not in VERDICTS:
            fail(f"{label}.classification is not a classification verdict")
        expected_verdict = max(
            (verdict_by_id[identifier] for identifier in ids),
            key=PRECEDENCE.__getitem__,
        )
        if verdict != expected_verdict:
            fail(
                f"{label}.classification is {verdict!r}, "
                f"expected aggregate {expected_verdict!r}"
            )
        if record.get("target_qualification") != "pending":
            fail(f"{label}.target_qualification must remain 'pending'")
        require_string(record.get("rationale"), f"{label}.rationale")

    if used_operation_ids != operation_ids:
        fail("capability operation lists do not preserve complete ordered coverage")

    workflow = (root / ".github/workflows/ci.yml").read_text()
    command = "python3 ci/check_flashos_capability_classification.py"
    if command not in workflow:
        fail("standard CI does not validate the FlashOS capability classification")


def main() -> None:
    document = load_toml(CLASSIFICATION_PATH)
    validate(document)
    print(f"FlashOS capability classification: contract passed for {TARGET}")


if __name__ == "__main__":
    main()
