#!/usr/bin/env python3
"""Validate the exhaustive FlashOS target-capability matrix."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path
from typing import NoReturn

from flashos_target_matrix import (
    TargetMatrix,
    TargetMatrixContractError,
    load_target_matrix,
)

ROOT = Path(__file__).resolve().parents[1]
MATRIX_PATH = ROOT / "components/flash/platforms/flashos-x86_64-target-matrix-v1.toml"
REPORT_PATH = (
    ROOT / "components/flash/platforms/flashos-x86_64-capability-report-v1.toml"
)
CLASSIFICATION_PATH = (
    ROOT / "components/flash/platforms/flashos-x86_64-capability-classification.toml"
)
ADAPTER_PATH = ROOT / "components/flash/crates/flash-platform-flashos/src/lib.rs"
REQUIRED_SURFACES = (
    "startup",
    "config-options",
    "script-execution",
    "builtins",
    "argv-environment",
    "working-directory",
    "pipelines",
    "redirections",
    "cancellation",
    "history",
    "completion",
    "structured-data",
    "typed-capture",
    "structured-errors",
    "dynamic-external",
    "status-conditions",
    "glob",
    "unicode-multiline-editing",
    "job-semantics",
    "clean-exit",
)


def fail(message: str) -> NoReturn:
    print(f"FlashOS target matrix: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_toml(path: Path) -> dict:
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {path.relative_to(ROOT)}: {error}")


def withheld_variant(source: str) -> str:
    match = re.search(
        r"const QUALIFIED_CAPABILITIES: Capabilities\s*=\s*"
        r"Capabilities::full_without\(Capability::(?P<variant>[A-Za-z]+)\);",
        source,
    )
    if match is None:
        fail("selected adapter capability declaration has an unknown shape")
    return match.group("variant")


def validate(matrix: TargetMatrix, root: Path = ROOT) -> None:
    if matrix.required_surfaces != REQUIRED_SURFACES:
        fail("required surfaces do not preserve the complete ordered target set")

    report = load_toml(root / "components/flash/platforms" / REPORT_PATH.name)
    classification = load_toml(
        root / "components/flash/platforms" / CLASSIFICATION_PATH.name
    )
    if report.get("target_matrix") != MATRIX_PATH.name:
        fail("capability report does not reference the selected target matrix")

    reported = report.get("capability")
    classified = classification.get("capability")
    operations = classification.get("operation")
    if not isinstance(reported, list) or not reported:
        fail("capability report has no capability array")
    if not isinstance(classified, list) or len(classified) != len(reported):
        fail("capability classification does not cover the report")
    if not isinstance(operations, list) or not operations:
        fail("capability classification has no operation array")

    omitted_variant = withheld_variant(
        (root / "components/flash/crates/flash-platform-flashos/src/lib.rs").read_text()
    )
    variant_to_name = {
        item["rust_variant"]: item["name"]
        for item in reported
        if isinstance(item, dict)
    }
    omitted_name = variant_to_name.get(omitted_variant)
    if omitted_name is None:
        fail(f"selected adapter withholds unknown capability {omitted_variant!r}")
    if matrix.withheld_capabilities != (omitted_name,):
        fail("withheld capabilities do not match the selected adapter")

    advertised = {
        item["name"]
        for item in reported
        if isinstance(item, dict) and item.get("advertised") is True
    }
    reported_withheld = {
        item["name"]
        for item in reported
        if isinstance(item, dict) and item.get("advertised") is False
    }
    if reported_withheld != {omitted_name}:
        fail("capability report and selected adapter disagree on the withheld set")

    operation_to_capability = {
        item["id"]: item["capability"] for item in operations if isinstance(item, dict)
    }
    expected_operations = [
        item["id"]
        for item in operations
        if isinstance(item, dict) and item.get("capability") in advertised
    ]
    seen_surfaces: set[str] = set()
    seen_capabilities: set[str] = set()
    seen_operations: list[str] = []
    for case in matrix.cases:
        unknown_surfaces = set(case.surfaces) - set(REQUIRED_SURFACES)
        if unknown_surfaces:
            fail(
                f"case {case.identifier!r} has unknown surfaces "
                f"{sorted(unknown_surfaces)!r}"
            )
        unknown_capabilities = set(case.capabilities) - advertised
        if unknown_capabilities:
            fail(
                f"case {case.identifier!r} has unadvertised capabilities "
                f"{sorted(unknown_capabilities)!r}"
            )
        for operation_id in case.operation_ids:
            capability = operation_to_capability.get(operation_id)
            if capability is None:
                fail(
                    f"case {case.identifier!r} references unknown operation "
                    f"{operation_id!r}"
                )
            if capability not in case.capabilities:
                fail(
                    f"case {case.identifier!r} operation {operation_id!r} belongs "
                    f"to undeclared capability {capability!r}"
                )
        seen_surfaces.update(case.surfaces)
        seen_capabilities.update(case.capabilities)
        seen_operations.extend(case.operation_ids)
        for step in case.steps:
            if step.send == "script":
                reader = f"^head -c{len(step.payload)}>m".encode()
                if len(reader) + len(matrix.terminator) > matrix.max_interaction_bytes:
                    fail(
                        f"case {case.identifier!r} script reader exceeds the "
                        "target UART boundary"
                    )
            if step.send == "line" and not step.rendered.startswith(
                (
                    matrix.primary_prompt,
                    matrix.continuation_prompt,
                    matrix.configured_prompt,
                )
            ):
                fail(
                    f"case {case.identifier!r} line rendering does not start with "
                    "a declared prompt"
                )
            interaction_bytes = len(step.payload)
            if step.send == "line":
                interaction_bytes += len(matrix.terminator)
            if (
                step.send in {"line", "keys"}
                and interaction_bytes > matrix.max_interaction_bytes
            ):
                fail(
                    f"case {case.identifier!r} interactive input exceeds the "
                    "target UART boundary"
                )

    if seen_surfaces != set(REQUIRED_SURFACES):
        fail(
            "matrix cases do not cover every required surface; "
            f"missing={sorted(set(REQUIRED_SURFACES) - seen_surfaces)!r}"
        )
    if seen_capabilities != advertised:
        fail(
            "matrix cases do not cover every advertised capability; "
            f"missing={sorted(advertised - seen_capabilities)!r}"
        )
    if set(seen_operations) != set(expected_operations) or len(seen_operations) != len(
        expected_operations
    ):
        missing = [item for item in expected_operations if item not in seen_operations]
        extra = [item for item in seen_operations if item not in expected_operations]
        duplicates = sorted(
            {item for item in seen_operations if seen_operations.count(item) > 1}
        )
        fail(
            "matrix operations must have complete single ownership; "
            f"missing={missing!r}, extra={extra!r}, duplicates={duplicates!r}"
        )

    qemu_source = (root / "ci/qemu_smoke.py").read_text()
    for marker in (
        "load_target_matrix(args.target_matrix)",
        "script_transport_chunks(",
        "for case in target_matrix.cases:",
        "for step in case.steps:",
    ):
        if marker not in qemu_source:
            fail(f"QEMU runner does not consume the target matrix: {marker}")
    workflow = (root / ".github/workflows/ci.yml").read_text()
    if "python3 ci/check_flashos_target_matrix.py" not in workflow:
        fail("standard CI does not validate the target matrix")


def main() -> None:
    try:
        matrix = load_target_matrix(MATRIX_PATH)
    except TargetMatrixContractError as error:
        fail(str(error))
    validate(matrix)
    print("FlashOS target matrix: advertised capability contract passed")


if __name__ == "__main__":
    main()
