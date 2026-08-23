#!/usr/bin/env python3
"""Validate the FlashOS per-operation ABI and userland seam map."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
MAP_PATH = ROOT / "components/flash/platforms/flashos-x86_64-operation-map.toml"
BASELINE_PATH = ROOT / "components/flash/platforms/flashos-x86_64.toml"
EVIDENCE_PATH = (
    ROOT / "components/flash/platforms/flashos-x86_64-capability-evidence.toml"
)
CONTRACT_PATH = ROOT / "components/flash/crates/flash-platform/src/lib.rs"
TARGET = "x86_64-unknown-redox"


def fail(message: str) -> NoReturn:
    print(f"FlashOS operation map: {message}", file=sys.stderr)
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


def validate_seams(records: object, libc_revision: str, root: Path) -> dict[str, dict]:
    if not isinstance(records, list) or not records:
        fail("abi_seam must be a non-empty array of tables")
    expected_fields = {
        "id",
        "provider",
        "revision",
        "tracked_path",
        "tracked_markers",
        "paths",
        "interfaces",
        "symbols",
        "observation",
    }
    seams: dict[str, dict] = {}
    for index, record in enumerate(records):
        label = f"abi_seam[{index}]"
        if not isinstance(record, dict):
            fail(f"{label} must be a table")
        require_keys(record, expected_fields, label)
        identifier = require_string(record.get("id"), f"{label}.id")
        if identifier in seams:
            fail(f"duplicate abi_seam id {identifier!r}")
        provider = require_string(record.get("provider"), f"{label}.provider")
        revision = require_string(record.get("revision"), f"{label}.revision")
        tracked_relative = Path(
            require_string(record.get("tracked_path"), f"{label}.tracked_path")
        )
        if tracked_relative.is_absolute() or ".." in tracked_relative.parts:
            fail(f"{label}.tracked_path must stay inside the repository")
        tracked_path = root / tracked_relative
        try:
            tracked_source = tracked_path.read_text()
        except OSError as error:
            fail(f"cannot read {tracked_relative}: {error}")
        tracked_markers = require_string_list(
            record.get("tracked_markers"),
            f"{label}.tracked_markers",
            nonempty=True,
        )
        for marker in tracked_markers:
            if marker not in tracked_source:
                fail(
                    f"{label} marker is absent from {tracked_relative}: {marker!r}"
                )
        paths = require_string_list(
            record.get("paths"), f"{label}.paths", nonempty=False
        )
        require_string_list(
            record.get("interfaces"), f"{label}.interfaces", nonempty=True
        )
        symbols = require_string_list(
            record.get("symbols"), f"{label}.symbols", nonempty=False
        )
        require_string(record.get("observation"), f"{label}.observation")
        if provider == "rust-std":
            if revision != "unknown" or paths or symbols:
                fail(
                    f"{label} must preserve the unknown Rust source boundary "
                    "without source paths or inferred libc symbols"
                )
        elif provider == "relibc":
            if revision != libc_revision or not paths or not symbols:
                fail(
                    f"{label} must use the configured relibc revision with "
                    "non-empty source paths and ABI symbols"
                )
            for path_value in paths:
                path = Path(path_value)
                if path.is_absolute() or ".." in path.parts:
                    fail(f"{label}.paths must stay inside the relibc repository")
        else:
            fail(f"{label}.provider is {provider!r}, expected 'rust-std' or 'relibc'")
        seams[identifier] = record
    return seams


def validate(document: dict, root: Path = ROOT) -> None:
    top_fields = {
        "schema_version",
        "platform",
        "architecture",
        "target",
        "platform_baseline",
        "capability_evidence",
        "contract_source",
        "selected_adapter",
        "classification",
        "compiler_source",
        "libc_source",
        "abi_seam",
        "operation",
    }
    require_keys(document, top_fields, "document")
    expected_scalars = {
        "schema_version": 2,
        "platform": "flashos",
        "architecture": "x86_64",
        "target": TARGET,
        "platform_baseline": "flashos-x86_64.toml",
        "capability_evidence": "flashos-x86_64-capability-evidence.toml",
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

    compiler = baseline.get("compiler")
    compiler_source = document.get("compiler_source")
    if not isinstance(compiler, dict) or not isinstance(compiler_source, dict):
        fail("compiler source tables are missing")
    require_keys(
        compiler_source,
        {"repository", "selector_kind", "selector", "revision", "mapping_scope"},
        "compiler_source",
    )
    compiler_expected = {
        "repository": compiler.get("source"),
        "selector_kind": compiler.get("source_selector_kind"),
        "selector": compiler.get("source_selector"),
        "revision": compiler.get("commit"),
        "mapping_scope": "public-std-api",
    }
    if compiler_source != compiler_expected:
        fail("compiler_source does not preserve the platform baseline identity")

    libc = baseline.get("libc")
    libc_source = document.get("libc_source")
    if not isinstance(libc, dict) or not isinstance(libc_source, dict):
        fail("libc source tables are missing")
    require_keys(
        libc_source,
        {"repository", "mapping_revision", "mapping_scope"},
        "libc_source",
    )
    libc_expected = {
        "repository": libc.get("source"),
        "mapping_revision": libc.get("configured_revision"),
        "mapping_scope": "configured-source",
    }
    if libc_source != libc_expected:
        fail("libc_source does not preserve the configured source identity")

    evidence = load_toml(
        root / "components/flash/platforms/flashos-x86_64-capability-evidence.toml"
    )
    if evidence.get("classification") != "deferred":
        fail("capability evidence classification must remain deferred")
    evidence_sources = evidence.get("source_evidence")
    if not isinstance(evidence_sources, list):
        fail("capability evidence has no source_evidence array")
    source_ids = {
        item.get("id")
        for item in evidence_sources
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }

    capabilities = evidence.get("capability")
    if not isinstance(capabilities, list) or not capabilities:
        fail("capability evidence has no capability array")
    variants = [entry.get("rust_variant") for entry in capabilities]
    contract_source = (root / document["contract_source"]).read_text()
    if variants != parse_capability_variants(contract_source):
        fail("capability evidence no longer matches the live contract enum")
    expected_operations: list[tuple[str, str]] = []
    for index, capability in enumerate(capabilities):
        if not isinstance(capability, dict):
            fail(f"capability evidence entry {index} must be a table")
        name = require_string(capability.get("name"), f"capability[{index}].name")
        requirements = require_string_list(
            capability.get("requirements"),
            f"capability[{index}].requirements",
            nonempty=True,
        )
        expected_operations.extend((name, requirement) for requirement in requirements)

    seams = validate_seams(
        document.get("abi_seam"), libc_source["mapping_revision"], root
    )
    operations = document.get("operation")
    if not isinstance(operations, list) or not operations:
        fail("operation must be a non-empty array of tables")
    operation_fields = {
        "id",
        "capability",
        "requirement",
        "source_evidence",
        "abi_seams",
        "boundary",
        "mapping_observation",
        "classification",
    }
    seen_ids: set[str] = set()
    actual_operations: list[tuple[str, str]] = []
    used_seams: set[str] = set()
    for index, operation in enumerate(operations):
        label = f"operation[{index}]"
        if not isinstance(operation, dict):
            fail(f"{label} must be a table")
        require_keys(operation, operation_fields, label)
        identifier = require_string(operation.get("id"), f"{label}.id")
        if identifier in seen_ids:
            fail(f"duplicate operation id {identifier!r}")
        seen_ids.add(identifier)
        capability = require_string(operation.get("capability"), f"{label}.capability")
        requirement = require_string(
            operation.get("requirement"), f"{label}.requirement"
        )
        evidence_ids = require_string_list(
            operation.get("source_evidence"),
            f"{label}.source_evidence",
            nonempty=True,
        )
        for evidence_id in evidence_ids:
            if evidence_id not in source_ids:
                fail(f"{label} references unknown source evidence {evidence_id!r}")
        seam_ids = require_string_list(
            operation.get("abi_seams"), f"{label}.abi_seams", nonempty=False
        )
        for seam_id in seam_ids:
            if seam_id not in seams:
                fail(f"{label} references unknown ABI seam {seam_id!r}")
        boundary = require_string(operation.get("boundary"), f"{label}.boundary")
        if boundary in {"flash-internal", "unrouted"}:
            if seam_ids:
                fail(f"{label} boundary {boundary!r} must not name an ABI seam")
        elif boundary == "rust-std":
            has_rust_seam = any(
                seams[item]["provider"] == "rust-std" for item in seam_ids
            )
            if not seam_ids or not has_rust_seam:
                fail(
                    f"{label} rust-std boundary must name a Rust "
                    "standard-library seam"
                )
        elif boundary == "libc-abi":
            has_libc_seam = any(
                seams[item]["provider"] == "relibc" for item in seam_ids
            )
            if not seam_ids or not has_libc_seam:
                fail(f"{label} libc-abi boundary must name a relibc seam")
        else:
            fail(f"{label}.boundary is not a mapping boundary")
        require_string(
            operation.get("mapping_observation"), f"{label}.mapping_observation"
        )
        if operation.get("classification") != "deferred":
            fail(f"{label}.classification must remain 'deferred'")
        actual_operations.append((capability, requirement))
        used_seams.update(seam_ids)

    if actual_operations != expected_operations:
        fail("operation sequence does not exactly cover capability requirements")
    if used_seams != set(seams):
        fail(f"unreferenced ABI seam ids: {sorted(set(seams) - used_seams)!r}")

    workflow = (root / ".github/workflows/ci.yml").read_text()
    if "python3 ci/check_flashos_operation_map.py" not in workflow:
        fail("standard CI does not validate the FlashOS operation map")


def main() -> None:
    document = load_toml(MAP_PATH)
    validate(document)
    print(f"FlashOS operation map: mapping contract passed for {TARGET}")


if __name__ == "__main__":
    main()
