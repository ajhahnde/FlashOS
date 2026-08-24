#!/usr/bin/env python3
"""Validate Flash's exhaustive v1 user-path exercise contract."""

from __future__ import annotations

import importlib.util
import json
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
FLASH_ROOT = ROOT / "components/flash"
CONTRACT_PATH = FLASH_ROOT / "exercises/v1.toml"
TARGET_MATRIX_PATH = FLASH_ROOT / "platforms/flashos-x86_64-target-matrix-v1.toml"
CAPABILITY_REPORT_PATH = (
    FLASH_ROOT / "platforms/flashos-x86_64-capability-report-v1.toml"
)

EXPECTED_ENVIRONMENTS = [
    "host-posix",
    "flashos-qemu-x86_64",
    "physical-flashos-x86_64",
]
EXPECTED_CATEGORIES = {
    "language",
    "intrinsic",
    "builtin",
    "frontend",
    "config",
    "lsp",
    "editor",
    "process",
    "platform",
    "documentation",
}
EXPECTED_INTRINSICS = ["env", "float", "glob", "int"]
EXPECTED_BUILTINS = [
    "bg",
    "cd",
    "check",
    "collect",
    "command",
    "decode",
    "each",
    "encode",
    "exit",
    "fg",
    "first",
    "from",
    "get",
    "help",
    "jobs",
    "kill",
    "last",
    "length",
    "lines",
    "ls",
    "open",
    "pwd",
    "save",
    "select",
    "sort",
    "to",
    "update",
    "wait",
    "where",
    "which",
]
EXPECTED_CONFIG = [
    "pipefail",
    "capture_limit",
    "completion",
    "history",
    "prompt",
    "continuation_prompt",
]
EXPECTED_CAPABILITIES = [
    "environment",
    "working-directory",
    "file-actions",
    "pipes",
    "process-spawn",
    "process-groups",
    "foreground-terminal",
    "signals",
    "terminal-info",
    "monotonic-clock",
    "standard-directories",
    "directory-read",
    "shell-executable",
    "hangup-disposition",
]
COMPATIBILITY_MARKERS = ("legacy", "compatibility", "deprecated_since")


@dataclass(frozen=True)
class DocumentationBlock:
    path: str
    ordinal: int
    language: str
    source: str


def fail(message: str) -> NoReturn:
    print(f"Flash v1 exercises: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_contract(path: Path = CONTRACT_PATH) -> dict:
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
    if (
        not isinstance(value, list)
        or not value
        or not all(isinstance(item, str) and item.strip() for item in value)
    ):
        fail(f"{label} must be a non-empty list of non-empty strings")
    if len(value) != len(set(value)):
        fail(f"{label} contains duplicates")
    return value


def safe_file(root: Path, value: str, label: str) -> Path:
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        fail(f"{label} must stay inside {root.relative_to(ROOT)}")
    path = root / relative
    if not path.is_file():
        fail(f"{label} does not name a file: {value}")
    return path


def documentation_blocks(path: Path) -> list[DocumentationBlock]:
    relative = path.relative_to(FLASH_ROOT).as_posix()
    blocks: list[DocumentationBlock] = []
    language: str | None = None
    lines: list[str] = []
    for line in path.read_text().splitlines():
        if not line.startswith("```"):
            if language is not None:
                lines.append(line)
            continue
        if language is None:
            language = line[3:]
            lines = []
        else:
            blocks.append(
                DocumentationBlock(
                    relative, len(blocks) + 1, language, "\n".join(lines)
                )
            )
            language = None
            lines = []
    if language is not None:
        fail(f"{relative} contains an unclosed code block")
    return blocks


def rust_array(source: str, declaration: str, variant_prefix: str) -> list[str]:
    match = re.search(declaration + r"(?P<body>.*?)\];", source, flags=re.DOTALL)
    if match is None:
        fail(f"cannot find source array {declaration!r}")
    return re.findall(re.escape(variant_prefix) + r"([A-Za-z]+)", match.group("body"))


def kebab_variant(value: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "-", value).lower()


def validate_closed_namespaces(surfaces: dict[str, dict]) -> None:
    intrinsic_source = (
        FLASH_ROOT / "crates/flash-runtime/src/intrinsic.rs"
    ).read_text()
    intrinsics = [
        name.lower()
        for name in rust_array(
            intrinsic_source,
            r"pub const ALL: \[Self; 4\] = \[",
            "Self::",
        )
    ]
    if intrinsics != EXPECTED_INTRINSICS:
        fail(
            "expression intrinsics are "
            f"{intrinsics!r}, expected {EXPECTED_INTRINSICS!r}"
        )
    if surfaces["expression-intrinsics"]["members"] != intrinsics:
        fail("expression-intrinsics does not match ExpressionIntrinsic::ALL")

    builtin_source = (FLASH_ROOT / "crates/flash-runtime/src/builtin.rs").read_text()
    builtins = sorted(
        set(
            re.findall(
                r'CommandSignature::(?:new|passthrough)\(\s*"([a-z]+)"', builtin_source
            )
        )
    )
    if builtins != EXPECTED_BUILTINS:
        fail(f"standard built-ins are {builtins!r}, expected {EXPECTED_BUILTINS!r}")
    if surfaces["standard-builtins"]["members"] != builtins:
        fail("standard-builtins does not match the standard registry")

    config_source = (FLASH_ROOT / "crates/flash-cli/src/config.rs").read_text()
    config = re.findall(
        r'^const [A-Z][A-Z0-9_]*_SETTING: &str = "([a-z][a-z0-9_]*)";$',
        config_source,
        flags=re.MULTILINE,
    )
    if config != EXPECTED_CONFIG:
        fail(f"config settings are {config!r}, expected {EXPECTED_CONFIG!r}")
    if surfaces["configuration"]["members"] != config:
        fail("configuration does not match the settings implementation")

    platform_source = (FLASH_ROOT / "crates/flash-platform/src/lib.rs").read_text()
    capabilities = [
        kebab_variant(name)
        for name in rust_array(
            platform_source,
            r"pub const ALL: \[Capability; 14\] = \[",
            "Capability::",
        )
    ]
    if capabilities != EXPECTED_CAPABILITIES:
        fail(
            "platform capabilities are "
            f"{capabilities!r}, expected {EXPECTED_CAPABILITIES!r}"
        )
    if surfaces["platform-capabilities"]["members"] != capabilities:
        fail("platform-capabilities does not match Capability::ALL")


def validate_case_owners(surfaces: dict[str, dict]) -> None:
    runner_path = FLASH_ROOT / "exercises/run.py"
    specification = importlib.util.spec_from_file_location(
        "flash_v1_exercise_runner", runner_path
    )
    if specification is None or specification.loader is None:
        fail("cannot load the host exercise runner")
    runner = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = runner
    specification.loader.exec_module(runner)

    required = {
        surface[field]
        for surface in surfaces.values()
        for field in ("exercise_case", "negative_case")
        if field in surface
    }
    owned = set(runner.CASE_OWNERS)
    if owned != required:
        fail(
            "host case ownership does not match the contract; "
            f"missing={sorted(required - owned)!r}, "
            f"extra={sorted(owned - required)!r}"
        )
    executable = {
        case.identifier
        for case in (
            runner.assembled_exercises(Path("fsh"), Path("fixtures"))
            + runner.command_exercises()
        )
    }
    selected = set(runner.CASE_OWNERS.values())
    if not selected <= executable:
        fail(f"host case owners are not executable: {sorted(selected - executable)!r}")


def validate_flashos_owners(surfaces: dict[str, dict]) -> None:
    with TARGET_MATRIX_PATH.open("rb") as source:
        matrix = tomllib.load(source)
    matrix_cases = {case["id"] for case in matrix["case"]}
    with CAPABILITY_REPORT_PATH.open("rb") as source:
        report = tomllib.load(source)
    report_scope = report.get("qualification")
    valid = {f"target-matrix:{identifier}" for identifier in matrix_cases}
    valid.add(f"capability-report:{report_scope}")
    for identifier, surface in surfaces.items():
        owner = surface["flashos_owner"]
        if owner not in valid:
            fail(f"surface {identifier!r} has unknown FlashOS owner {owner!r}")


def load_runner():
    runner_path = FLASH_ROOT / "exercises/run.py"
    specification = importlib.util.spec_from_file_location(
        "flash_v1_evidence_runner", runner_path
    )
    if specification is None or specification.loader is None:
        fail("cannot load the host exercise runner for evidence validation")
    runner = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = runner
    specification.loader.exec_module(runner)
    return runner


def validate_host_evidence(document: dict) -> None:
    evidence_path = safe_file(FLASH_ROOT, document["host_evidence"], "host_evidence")
    try:
        evidence = json.loads(evidence_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read host evidence: {error}")
    require_keys(
        evidence,
        {
            "schema_version",
            "suite_version",
            "candidate",
            "environment",
            "profile",
            "contract_cases",
            "results",
            "limitations",
        },
        "host evidence",
    )
    if evidence["schema_version"] != 1:
        fail("host evidence schema_version must be 1")
    if evidence["suite_version"] != document["suite_version"]:
        fail("host evidence suite_version does not match the contract")
    if evidence["profile"] not in {"ci", "full"}:
        fail("host evidence must record the complete ci or full profile")

    candidate = evidence.get("candidate")
    if not isinstance(candidate, dict):
        fail("host evidence candidate must be a table")
    require_keys(
        candidate,
        {"commit", "tree", "source_sha256", "worktree"},
        "host evidence candidate",
    )
    for field in ("commit", "tree", "source_sha256", "worktree"):
        require_string(candidate.get(field), f"host evidence candidate.{field}")

    environment = evidence.get("environment")
    if not isinstance(environment, dict) or environment.get("id") != "host-posix":
        fail("host evidence must identify the host-posix environment")
    runner = load_runner()
    if candidate["source_sha256"] != runner.source_digest():
        fail("host evidence does not match the current candidate source digest")
    if evidence.get("contract_cases") != runner.CASE_OWNERS:
        fail("host evidence contract-case ownership is stale")

    results = evidence.get("results")
    if not isinstance(results, list) or not results:
        fail("host evidence results must be a non-empty array")
    result_ids = [result.get("id") for result in results if isinstance(result, dict)]
    expected_ids = [
        case.identifier
        for case in (
            runner.assembled_exercises(Path("fsh"), Path("fixtures"))
            + runner.command_exercises()
        )
    ]
    if result_ids != expected_ids:
        fail("host evidence does not contain every executable case in order")
    for index, result in enumerate(results):
        if result.get("result") != "pass":
            fail(f"host evidence result {index} is not a pass")
        require_keys(
            result,
            {"id", "summary", "action", "input", "expected", "observed", "result"},
            f"host evidence result[{index}]",
        )
    limitations = evidence.get("limitations")
    if not isinstance(limitations, list) or len(limitations) < 2:
        fail("host evidence must record target and physical-hardware limitations")


def validate_documentation(document: dict) -> None:
    roots = require_string_list(
        document.get("documentation_roots"), "documentation_roots"
    )
    blocks: dict[str, list[DocumentationBlock]] = {}
    for index, root in enumerate(roots):
        path = safe_file(FLASH_ROOT, root, f"documentation_roots[{index}]")
        blocks[root] = documentation_blocks(path)

    rules = document.get("documentation_rule")
    if not isinstance(rules, list) or not rules:
        fail("documentation_rule must be a non-empty array")
    covered: set[tuple[str, int]] = set()
    for index, rule in enumerate(rules):
        label = f"documentation_rule[{index}]"
        if not isinstance(rule, dict):
            fail(f"{label} must be a table")
        require_keys(
            rule,
            {"path", "first_block", "last_block", "classification", "evidence_owner"},
            label,
        )
        path = require_string(rule.get("path"), f"{label}.path")
        require_string(rule.get("classification"), f"{label}.classification")
        require_string(rule.get("evidence_owner"), f"{label}.evidence_owner")
        if path not in blocks:
            fail(f"{label}.path is not a documentation root: {path}")
        first = rule.get("first_block")
        last = rule.get("last_block")
        if (
            not isinstance(first, int)
            or not isinstance(last, int)
            or not (1 <= first <= last)
        ):
            fail(f"{label} has an invalid block interval")
        if last > len(blocks[path]):
            fail(f"{label} ends at block {last}, but {path} has {len(blocks[path])}")
        for ordinal in range(first, last + 1):
            key = (path, ordinal)
            if key in covered:
                fail(f"documentation block {path}#{ordinal} has multiple owners")
            covered.add(key)
    expected = {
        (path, block.ordinal)
        for path, path_blocks in blocks.items()
        for block in path_blocks
    }
    if covered != expected:
        fail(
            "documentation ownership is incomplete; "
            f"missing={sorted(expected - covered)!r}, "
            f"extra={sorted(covered - expected)!r}"
        )


def validate_compatibility(document: dict) -> None:
    records = document.get("compatibility")
    if not isinstance(records, list) or not records:
        fail("compatibility must be a non-empty array")
    owned: set[tuple[str, str]] = set()
    for index, record in enumerate(records):
        label = f"compatibility[{index}]"
        if not isinstance(record, dict):
            fail(f"{label} must be a table")
        require_keys(record, {"id", "path", "marker", "classification", "owner"}, label)
        for field in ("id", "path", "marker", "classification", "owner"):
            require_string(record.get(field), f"{label}.{field}")
        path = safe_file(FLASH_ROOT, record["path"], f"{label}.path")
        if record["marker"] not in path.read_text():
            fail(f"{label}.marker is absent from {record['path']}")
        key = (record["path"], record["marker"])
        if key in owned:
            fail(f"duplicate compatibility owner for {key!r}")
        owned.add(key)

    production = sorted((FLASH_ROOT / "crates").glob("*/src/*.rs"))
    unowned: list[str] = []
    for path in production:
        relative = path.relative_to(FLASH_ROOT).as_posix()
        production_source = path.read_text().split("#[cfg(test)]", maxsplit=1)[0]
        for number, line in enumerate(production_source.splitlines(), start=1):
            lowered = line.lower()
            if not any(marker in lowered for marker in COMPATIBILITY_MARKERS):
                continue
            if not any(
                owner_path == relative and marker in line
                for owner_path, marker in owned
            ):
                # Generic present-day interoperability wording and error names
                # are not old behavior. Only explicit legacy/lifecycle routes
                # require individual compatibility ownership.
                if "legacy" in lowered or "compatibility lifecycle" in lowered:
                    unowned.append(f"{relative}:{number}")
    if unowned:
        fail(f"unowned production compatibility markers: {unowned!r}")


def validate(document: dict) -> None:
    require_keys(
        document,
        {
            "schema_version",
            "suite_version",
            "language_major",
            "host_runner",
            "host_evidence",
            "target_matrix",
            "target_fixtures",
            "compatibility_decision",
            "documentation_roots",
            "environment",
            "surface",
            "documentation_rule",
            "compatibility",
        },
        "document",
    )
    expected_scalars = {
        "schema_version": 1,
        "suite_version": 1,
        "language_major": 1,
        "host_runner": "exercises/run.py",
        "host_evidence": "exercises/evidence/host-v1.json",
        "target_matrix": "platforms/flashos-x86_64-target-matrix-v1.toml",
        "target_fixtures": "platforms/flashos-x86_64-runtime-fixtures-v1.toml",
    }
    for field, expected in expected_scalars.items():
        if document.get(field) != expected:
            fail(f"{field} is {document.get(field)!r}, expected {expected!r}")
    require_string(document.get("compatibility_decision"), "compatibility_decision")
    for field in ("host_runner", "target_matrix", "target_fixtures"):
        safe_file(FLASH_ROOT, document[field], field)

    environments = document.get("environment")
    if not isinstance(environments, list):
        fail("environment must be an array")
    environment_ids: list[str] = []
    for index, environment in enumerate(environments):
        label = f"environment[{index}]"
        if not isinstance(environment, dict):
            fail(f"{label} must be a table")
        require_keys(
            environment, {"id", "availability", "evidence_owner", "limitations"}, label
        )
        environment_ids.append(require_string(environment.get("id"), f"{label}.id"))
        for field in ("availability", "evidence_owner", "limitations"):
            require_string(environment.get(field), f"{label}.{field}")
    if environment_ids != EXPECTED_ENVIRONMENTS:
        fail(
            "environment ids are "
            f"{environment_ids!r}, expected {EXPECTED_ENVIRONMENTS!r}"
        )

    surface_records = document.get("surface")
    if not isinstance(surface_records, list) or not surface_records:
        fail("surface must be a non-empty array")
    surfaces: dict[str, dict] = {}
    all_members: set[tuple[str, str]] = set()
    categories: set[str] = set()
    for index, surface in enumerate(surface_records):
        label = f"surface[{index}]"
        if not isinstance(surface, dict):
            fail(f"{label} must be a table")
        required_fields = {
            "id",
            "category",
            "members",
            "exercise_case",
            "flashos_owner",
        }
        actual_fields = set(surface)
        if not required_fields <= actual_fields:
            fail(f"{label} is missing {sorted(required_fields - actual_fields)!r}")
        if not actual_fields <= required_fields | {"negative_case"}:
            fail(
                f"{label} has unknown fields "
                f"{sorted(actual_fields - required_fields - {'negative_case'})!r}"
            )
        identifier = require_string(surface.get("id"), f"{label}.id")
        if not re.fullmatch(r"[a-z][a-z0-9-]*", identifier) or identifier in surfaces:
            fail(f"{label}.id is invalid or duplicated: {identifier!r}")
        category = require_string(surface.get("category"), f"{label}.category")
        categories.add(category)
        members = require_string_list(surface.get("members"), f"{label}.members")
        for member in members:
            key = (category, member)
            if key in all_members:
                fail(f"surface member {category}:{member} has multiple owners")
            all_members.add(key)
        for field in ("exercise_case", "flashos_owner"):
            require_string(surface.get(field), f"{label}.{field}")
        if "negative_case" in surface:
            require_string(surface.get("negative_case"), f"{label}.negative_case")
        surfaces[identifier] = surface
    if categories != EXPECTED_CATEGORIES:
        fail(
            f"surface categories are {sorted(categories)!r}, "
            f"expected {sorted(EXPECTED_CATEGORIES)!r}"
        )
    validate_closed_namespaces(surfaces)
    validate_case_owners(surfaces)
    validate_flashos_owners(surfaces)
    validate_host_evidence(document)
    validate_documentation(document)
    validate_compatibility(document)

    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    for command in (
        "python3 ../../ci/check_flash_v1_exercises.py",
        "python3 exercises/run.py --profile ci --no-build",
    ):
        if workflow.count(command) != 1:
            fail(f"CI workflow must contain exactly one {command!r}")


def main() -> None:
    validate(load_contract())
    print("Flash v1 exercises: exhaustive contract passed")


if __name__ == "__main__":
    main()
