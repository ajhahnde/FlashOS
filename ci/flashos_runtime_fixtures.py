#!/usr/bin/env python3
"""Load and render the reusable FlashOS target-runtime smoke fixtures."""

from __future__ import annotations

import argparse
import string
import tomllib
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_PATH = (
    ROOT
    / "components/flash/platforms/flashos-x86_64-runtime-fixtures-v1.toml"
)


class FixtureContractError(ValueError):
    """A runtime fixture document violates its machine-readable contract."""


@dataclass(frozen=True)
class FixtureStep:
    """One submitted editor row and its optional evaluator-output marker."""

    payload: bytes
    rendered: bytes
    expected: bytes | None
    manual: str


@dataclass(frozen=True)
class RuntimeFixture:
    """One ordered target-runtime behavior fixture."""

    identifier: str
    summary: str
    capabilities: tuple[str, ...]
    rejected: tuple[bytes, ...]
    steps: tuple[FixtureStep, ...]


@dataclass(frozen=True)
class RuntimeFixtureSuite:
    """The complete versioned smoke suite consumed by target runners."""

    suite_version: int
    scope: str
    consumers: tuple[str, ...]
    prompt: bytes
    terminator: bytes
    max_interaction_bytes: int
    fixtures: tuple[RuntimeFixture, ...]


def load_toml(path: Path) -> dict:
    """Read one TOML fixture document."""
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise FixtureContractError(f"cannot read {path}: {error}") from error


def _require_keys(table: dict, expected: set[str], label: str) -> None:
    actual = set(table)
    if actual != expected:
        raise FixtureContractError(
            f"{label} fields are {sorted(actual)!r}, expected {sorted(expected)!r}"
        )


def _require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise FixtureContractError(f"{label} must be a non-empty string")
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
        raise FixtureContractError(f"{label} must be a list of non-empty strings")
    if nonempty and not value:
        raise FixtureContractError(f"{label} must not be empty")
    if len(value) != len(set(value)):
        raise FixtureContractError(f"{label} contains duplicates")
    return value


def _decode_hex(value: object, label: str) -> bytes:
    encoded = _require_string(value, label)
    if len(encoded) % 2 or any(
        character not in string.hexdigits for character in encoded
    ):
        raise FixtureContractError(f"{label} must contain complete hexadecimal bytes")
    return bytes.fromhex(encoded)


def _encode_text(value: object, label: str) -> bytes:
    return _require_string(value, label).encode()


def _parse_step(
    record: object,
    fixture_label: str,
    index: int,
    terminator: bytes,
    prompt: bytes,
    max_interaction_bytes: int,
) -> FixtureStep:
    label = f"{fixture_label}.step[{index}]"
    if not isinstance(record, dict):
        raise FixtureContractError(f"{label} must be a table")
    allowed = {"input", "input_hex", "rendered", "expect", "manual"}
    actual = set(record)
    if not actual <= allowed:
        raise FixtureContractError(
            f"{label} has unknown fields {sorted(actual - allowed)!r}"
        )
    required = {"rendered", "manual"}
    if not required <= actual:
        raise FixtureContractError(f"{label} is missing {sorted(required - actual)!r}")
    input_fields = actual & {"input", "input_hex"}
    if len(input_fields) != 1:
        raise FixtureContractError(f"{label} must contain exactly one input field")

    if "input" in record:
        payload = _encode_text(record["input"], f"{label}.input")
    else:
        payload = _decode_hex(record["input_hex"], f"{label}.input_hex")
    rendered = _encode_text(record["rendered"], f"{label}.rendered")
    manual = _require_string(record.get("manual"), f"{label}.manual")
    expected = (
        _encode_text(record["expect"], f"{label}.expect")
        if "expect" in record
        else None
    )
    if len(payload + terminator) > max_interaction_bytes:
        raise FixtureContractError(
            f"{label} exceeds the {max_interaction_bytes}-byte interaction limit"
        )
    if terminator in payload:
        raise FixtureContractError(f"{label} input must not contain its terminator")
    if not rendered.startswith(prompt):
        raise FixtureContractError(f"{label}.rendered must start with the suite prompt")
    return FixtureStep(payload, rendered, expected, manual)


def parse_fixture_suite(document: dict) -> RuntimeFixtureSuite:
    """Validate and convert one decoded fixture document."""
    top_fields = {
        "schema_version",
        "suite_version",
        "scope",
        "platform",
        "architecture",
        "target",
        "capability_report",
        "consumers",
        "prompt",
        "terminator_hex",
        "max_interaction_bytes",
        "fixture",
    }
    _require_keys(document, top_fields, "document")
    expected_scalars = {
        "schema_version": 1,
        "suite_version": 1,
        "scope": "bounded",
        "platform": "flashos",
        "architecture": "x86_64",
        "target": "x86_64-unknown-redox",
        "capability_report": "flashos-x86_64-capability-report-v1.toml",
        "prompt": ">> ",
        "terminator_hex": "0d",
        "max_interaction_bytes": 16,
    }
    for field, expected in expected_scalars.items():
        if document.get(field) != expected:
            raise FixtureContractError(
                f"{field} is {document.get(field)!r}, expected {expected!r}"
            )
    consumers = _require_string_list(
        document.get("consumers"), "consumers", nonempty=True
    )
    if consumers != ["qemu", "real-system"]:
        raise FixtureContractError(
            "consumers must preserve the qemu and real-system contract"
        )
    terminator = _decode_hex(document.get("terminator_hex"), "terminator_hex")
    prompt = _encode_text(document.get("prompt"), "prompt")
    max_interaction_bytes = document["max_interaction_bytes"]

    records = document.get("fixture")
    if not isinstance(records, list) or not records:
        raise FixtureContractError("fixture must be a non-empty array of tables")
    fixtures: list[RuntimeFixture] = []
    identifiers: list[str] = []
    for index, record in enumerate(records):
        label = f"fixture[{index}]"
        if not isinstance(record, dict):
            raise FixtureContractError(f"{label} must be a table")
        _require_keys(
            record,
            {"id", "summary", "capabilities", "reject", "step"},
            label,
        )
        identifier = _require_string(record.get("id"), f"{label}.id")
        summary = _require_string(record.get("summary"), f"{label}.summary")
        capabilities = _require_string_list(
            record.get("capabilities"), f"{label}.capabilities", nonempty=True
        )
        rejected = tuple(
            item.encode()
            for item in _require_string_list(
                record.get("reject"), f"{label}.reject", nonempty=False
            )
        )
        steps = record.get("step")
        if not isinstance(steps, list) or not steps:
            raise FixtureContractError(f"{label}.step must not be empty")
        fixtures.append(
            RuntimeFixture(
                identifier,
                summary,
                tuple(capabilities),
                rejected,
                tuple(
                    _parse_step(
                        step,
                        label,
                        step_index,
                        terminator,
                        prompt,
                        max_interaction_bytes,
                    )
                    for step_index, step in enumerate(steps)
                ),
            )
        )
        identifiers.append(identifier)
    if len(identifiers) != len(set(identifiers)):
        raise FixtureContractError("fixture ids contain duplicates")

    return RuntimeFixtureSuite(
        document["suite_version"],
        document["scope"],
        tuple(consumers),
        prompt,
        terminator,
        max_interaction_bytes,
        tuple(fixtures),
    )


def load_fixture_suite(path: Path = FIXTURE_PATH) -> RuntimeFixtureSuite:
    """Load the tracked FlashOS runtime fixture suite."""
    return parse_fixture_suite(load_toml(path))


def render_real_system_instructions(suite: RuntimeFixtureSuite) -> str:
    """Render the exact fixture inputs as a physical-system checklist."""
    lines = [
        f"FlashOS runtime smoke fixtures v{suite.suite_version} ({suite.scope})",
        "Log in as user, wait for the Flash prompt, and run these fixtures in order.",
    ]
    for fixture in suite.fixtures:
        lines.extend(("", f"{fixture.identifier}: {fixture.summary}"))
        for number, step in enumerate(fixture.steps, start=1):
            lines.append(f"  {number}. Enter: {_render_payload(step.payload)}")
            lines.append(f"     Observe: {step.manual}")
            if step.expected is not None:
                lines.append(
                    f"     Expect: {step.expected.decode(errors='backslashreplace')!r}"
                )
        for rejected in fixture.rejected:
            lines.append(
                f"  Reject any transcript containing: "
                f"{rejected.decode(errors='backslashreplace')!r}"
            )
    return "\n".join(lines)


def _render_payload(payload: bytes) -> str:
    rendered: list[str] = []
    for byte in payload:
        if byte == 0x7F:
            rendered.append("<Backspace>")
        elif 0x20 <= byte <= 0x7E:
            rendered.append(chr(byte))
        else:
            rendered.append(f"<0x{byte:02X}>")
    return "".join(rendered)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Render the tracked FlashOS smoke fixtures for a real system"
    )
    parser.add_argument("--fixtures", type=Path, default=FIXTURE_PATH)
    args = parser.parse_args()
    try:
        suite = load_fixture_suite(args.fixtures)
    except FixtureContractError as error:
        raise SystemExit(f"FlashOS runtime fixtures: {error}") from error
    print(render_real_system_instructions(suite))


if __name__ == "__main__":
    main()
