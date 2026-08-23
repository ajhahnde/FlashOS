#!/usr/bin/env python3
"""Load and render the exhaustive FlashOS target-capability matrix."""

from __future__ import annotations

import argparse
import string
import tomllib
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MATRIX_PATH = ROOT / "components/flash/platforms/flashos-x86_64-target-matrix-v1.toml"


class TargetMatrixContractError(ValueError):
    """A target-matrix document violates its machine-readable contract."""


@dataclass(frozen=True)
class TargetMatrixStep:
    """One exact editor input and its ordered target observations."""

    payload: bytes
    send: str
    rendered: bytes | None
    expected: tuple[bytes, ...]
    manual: str


@dataclass(frozen=True)
class TargetMatrixCase:
    """One ordered target behavior and capability case."""

    identifier: str
    summary: str
    surfaces: tuple[str, ...]
    capabilities: tuple[str, ...]
    operation_ids: tuple[str, ...]
    rejected: tuple[bytes, ...]
    steps: tuple[TargetMatrixStep, ...]


@dataclass(frozen=True)
class TargetMatrix:
    """The complete target matrix consumed by runtime observers."""

    matrix_version: int
    scope: str
    consumers: tuple[str, ...]
    primary_prompt: bytes
    continuation_prompt: bytes
    configured_prompt: bytes
    terminator: bytes
    max_interaction_bytes: int
    script_transport_chunk_bytes: int
    required_surfaces: tuple[str, ...]
    withheld_capabilities: tuple[str, ...]
    cases: tuple[TargetMatrixCase, ...]


def load_toml(path: Path) -> dict:
    """Read one TOML matrix document."""
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise TargetMatrixContractError(f"cannot read {path}: {error}") from error


def _require_keys(table: dict, expected: set[str], label: str) -> None:
    actual = set(table)
    if actual != expected:
        raise TargetMatrixContractError(
            f"{label} fields are {sorted(actual)!r}, expected {sorted(expected)!r}"
        )


def _require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise TargetMatrixContractError(f"{label} must be a non-empty string")
    return value


def _require_string_list(
    value: object,
    label: str,
    *,
    nonempty: bool,
) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item.strip() for item in value
    ):
        raise TargetMatrixContractError(f"{label} must be a list of non-empty strings")
    if nonempty and not value:
        raise TargetMatrixContractError(f"{label} must not be empty")
    if len(value) != len(set(value)):
        raise TargetMatrixContractError(f"{label} contains duplicates")
    return value


def _decode_hex(value: object, label: str) -> bytes:
    encoded = _require_string(value, label)
    if len(encoded) % 2 or any(
        character not in string.hexdigits for character in encoded
    ):
        raise TargetMatrixContractError(
            f"{label} must contain complete hexadecimal bytes"
        )
    return bytes.fromhex(encoded)


def _encode_text(value: object, label: str) -> bytes:
    return _require_string(value, label).encode()


def _parse_step(record: object, case_label: str, index: int) -> TargetMatrixStep:
    label = f"{case_label}.step[{index}]"
    if not isinstance(record, dict):
        raise TargetMatrixContractError(f"{label} must be a table")
    allowed = {"input", "input_hex", "send", "rendered", "expect", "manual"}
    actual = set(record)
    if not actual <= allowed:
        raise TargetMatrixContractError(
            f"{label} has unknown fields {sorted(actual - allowed)!r}"
        )
    required = {"send", "expect", "manual"}
    if not required <= actual:
        raise TargetMatrixContractError(
            f"{label} is missing {sorted(required - actual)!r}"
        )
    input_fields = actual & {"input", "input_hex"}
    if len(input_fields) != 1:
        raise TargetMatrixContractError(f"{label} must contain exactly one input field")
    payload = (
        _encode_text(record["input"], f"{label}.input")
        if "input" in record
        else _decode_hex(record["input_hex"], f"{label}.input_hex")
    )
    send = _require_string(record.get("send"), f"{label}.send")
    if send not in {"line", "keys", "script"}:
        raise TargetMatrixContractError(
            f"{label}.send must be 'line', 'keys', or 'script'"
        )
    rendered = (
        _encode_text(record["rendered"], f"{label}.rendered")
        if "rendered" in record
        else None
    )
    if send == "line" and rendered is None:
        raise TargetMatrixContractError(f"{label}.rendered is required for line input")
    expected = tuple(
        item.encode()
        for item in _require_string_list(
            record.get("expect"), f"{label}.expect", nonempty=True
        )
    )
    manual = _require_string(record.get("manual"), f"{label}.manual")
    return TargetMatrixStep(payload, send, rendered, expected, manual)


def parse_target_matrix(document: dict) -> TargetMatrix:
    """Validate and convert one decoded target-matrix document."""
    top_fields = {
        "schema_version",
        "matrix_version",
        "scope",
        "platform",
        "architecture",
        "target",
        "capability_report",
        "capability_classification",
        "runtime_fixtures",
        "consumers",
        "primary_prompt",
        "continuation_prompt",
        "configured_prompt",
        "terminator_hex",
        "max_interaction_bytes",
        "script_transport_chunk_bytes",
        "required_surfaces",
        "withheld_capabilities",
        "case",
    }
    _require_keys(document, top_fields, "document")
    expected_scalars = {
        "schema_version": 1,
        "matrix_version": 1,
        "scope": "advertised-capabilities",
        "platform": "flashos",
        "architecture": "x86_64",
        "target": "x86_64-unknown-redox",
        "capability_report": "flashos-x86_64-capability-report-v1.toml",
        "capability_classification": ("flashos-x86_64-capability-classification.toml"),
        "runtime_fixtures": "flashos-x86_64-runtime-fixtures-v1.toml",
        "primary_prompt": ">> ",
        "continuation_prompt": "...> ",
        "configured_prompt": "C> ",
        "terminator_hex": "0d",
        "max_interaction_bytes": 16,
        "script_transport_chunk_bytes": 16,
    }
    for field, expected in expected_scalars.items():
        if document.get(field) != expected:
            raise TargetMatrixContractError(
                f"{field} is {document.get(field)!r}, expected {expected!r}"
            )
    consumers = _require_string_list(
        document.get("consumers"), "consumers", nonempty=True
    )
    if consumers != ["qemu", "operator-observed-target"]:
        raise TargetMatrixContractError(
            "consumers must preserve qemu and operator-observed-target order"
        )
    required_surfaces = _require_string_list(
        document.get("required_surfaces"), "required_surfaces", nonempty=True
    )
    withheld = _require_string_list(
        document.get("withheld_capabilities"),
        "withheld_capabilities",
        nonempty=True,
    )
    records = document.get("case")
    if not isinstance(records, list) or not records:
        raise TargetMatrixContractError("case must be a non-empty array of tables")
    cases: list[TargetMatrixCase] = []
    identifiers: list[str] = []
    for index, record in enumerate(records):
        label = f"case[{index}]"
        if not isinstance(record, dict):
            raise TargetMatrixContractError(f"{label} must be a table")
        _require_keys(
            record,
            {
                "id",
                "summary",
                "surfaces",
                "capabilities",
                "operation_ids",
                "reject",
                "step",
            },
            label,
        )
        identifier = _require_string(record.get("id"), f"{label}.id")
        summary = _require_string(record.get("summary"), f"{label}.summary")
        surfaces = _require_string_list(
            record.get("surfaces"), f"{label}.surfaces", nonempty=True
        )
        capabilities = _require_string_list(
            record.get("capabilities"), f"{label}.capabilities", nonempty=True
        )
        operation_ids = _require_string_list(
            record.get("operation_ids"), f"{label}.operation_ids", nonempty=False
        )
        rejected = tuple(
            item.encode()
            for item in _require_string_list(
                record.get("reject"), f"{label}.reject", nonempty=False
            )
        )
        steps = record.get("step")
        if not isinstance(steps, list) or not steps:
            raise TargetMatrixContractError(f"{label}.step must not be empty")
        cases.append(
            TargetMatrixCase(
                identifier,
                summary,
                tuple(surfaces),
                tuple(capabilities),
                tuple(operation_ids),
                rejected,
                tuple(
                    _parse_step(step, label, step_index)
                    for step_index, step in enumerate(steps)
                ),
            )
        )
        identifiers.append(identifier)
    if len(identifiers) != len(set(identifiers)):
        raise TargetMatrixContractError("case ids contain duplicates")
    return TargetMatrix(
        document["matrix_version"],
        document["scope"],
        tuple(consumers),
        document["primary_prompt"].encode(),
        document["continuation_prompt"].encode(),
        document["configured_prompt"].encode(),
        _decode_hex(document["terminator_hex"], "terminator_hex"),
        document["max_interaction_bytes"],
        document["script_transport_chunk_bytes"],
        tuple(required_surfaces),
        tuple(withheld),
        tuple(cases),
    )


def load_target_matrix(path: Path = MATRIX_PATH) -> TargetMatrix:
    """Load the tracked FlashOS target matrix."""
    return parse_target_matrix(load_toml(path))


def script_transport_chunks(source: bytes, chunk_bytes: int) -> tuple[bytes, ...]:
    """Split exact script bytes into UART-bounded foreground-input chunks."""
    if chunk_bytes <= 0:
        raise TargetMatrixContractError("script_transport_chunk_bytes must be positive")
    return tuple(
        source[index : index + chunk_bytes]
        for index in range(0, len(source), chunk_bytes)
    )


def render_operator_checklist(matrix: TargetMatrix) -> str:
    """Render the exact matrix as an operator-observed target checklist."""
    lines = [
        f"FlashOS target capability matrix v{matrix.matrix_version} ({matrix.scope})",
        "Log in as user, wait for the Flash prompt, and perform every case in order.",
        "Record observations against the exact image identity; rendering is not a run.",
    ]
    for case in matrix.cases:
        lines.extend(("", f"{case.identifier}: {case.summary}"))
        for number, step in enumerate(case.steps, start=1):
            action = {
                "line": "Enter",
                "keys": "Keys",
                "script": "Script",
            }[step.send]
            if step.send == "script":
                lines.append(f"  {number}. {action}:")
                lines.extend(
                    f"     | {source_line}"
                    for source_line in step.payload.decode().splitlines()
                )
            else:
                lines.append(f"  {number}. {action}: {_render_payload(step.payload)}")
            lines.append(f"     Observe: {step.manual}")
            for expected in step.expected:
                lines.append(
                    f"     Expect in order: "
                    f"{expected.decode(errors='backslashreplace')!r}"
                )
        for rejected in case.rejected:
            lines.append(
                "  Reject any case transcript containing: "
                f"{rejected.decode(errors='backslashreplace')!r}"
            )
    return "\n".join(lines)


def _render_payload(payload: bytes) -> str:
    rendered = payload.decode()
    for sequence, name in (
        ("\x1b[A", "<Up>"),
        ("\x1b[B", "<Down>"),
        ("\x1b[C", "<Right>"),
        ("\x1b[D", "<Left>"),
        ("\x03", "<Ctrl-C>"),
        ("\x09", "<Tab>"),
        ("\x0d", "<Enter>"),
        ("\x7f", "<Backspace>"),
    ):
        rendered = rendered.replace(sequence, name)
    return rendered


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Render the tracked FlashOS target capability matrix"
    )
    parser.add_argument("--matrix", type=Path, default=MATRIX_PATH)
    args = parser.parse_args()
    try:
        matrix = load_target_matrix(args.matrix)
    except TargetMatrixContractError as error:
        raise SystemExit(f"FlashOS target matrix: {error}") from error
    print(render_operator_checklist(matrix))


if __name__ == "__main__":
    main()
