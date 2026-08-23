#!/usr/bin/env python3
"""Validate Flash's executable host-v1 conformance inventory and source audit."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
FLASH_ROOT = ROOT / "components/flash"
INVENTORY_PATH = FLASH_ROOT / "conformance/v1.toml"

REQUIRED_FAMILIES = [
    "syntax-values-and-expressions",
    "effectful-language-composition",
    "dynamic-status-environment-and-glob",
    "interactive-session-state",
    "execution-plan-inspection",
    "dynamic-external-execution",
    "typed-command-capture",
    "structured-language-errors",
    "static-contract-analysis",
    "complete-job-semantics",
    "grammar-aware-path-completion",
    "portable-interactive-behavior",
    "shared-developer-frontends",
    "flashos-platform-routes",
]
REQUIRED_LAYERS = {
    "syntax",
    "runtime",
    "cli",
    "repl",
    "checker",
    "formatter",
    "lsp",
    "platform",
}
REQUIRED_PLATFORM_CONTRACTS = [
    "ci/check_flashos_platform.py",
    "ci/check_flashos_capabilities.py",
    "ci/check_flashos_operation_map.py",
    "ci/check_flashos_capability_classification.py",
]
REQUIRED_CONFIG_SETTINGS = [
    "pipefail",
    "capture_limit",
    "completion",
    "history",
    "prompt",
    "continuation_prompt",
]
BOUNDARY_PATTERN = re.compile(
    r"// flash-v1-boundary\((?P<category>[a-z-]+)\): (?P<reason>\S.*\.)$"
)
BOUNDARY_CATEGORIES = {
    "carrier-refusal",
    "embedding-refusal",
    "executor-invariant",
    "platform-refusal",
}
AUDITED_CONSTRUCTORS = (
    "RuntimeErrorKind::Unsupported {",
    "Err(RuntimeErrorKind::ExecutionUnsupported)",
    "RuntimeError::new(RuntimeErrorKind::ExecutionUnsupported",
    "=> RuntimeErrorKind::ExecutionUnsupported",
    "self.error(RuntimeErrorKind::ExecutionUnsupported",
    'self.unsupported("',
)
FORBIDDEN_SOURCE_MARKERS = (
    "todo!()",
    "unimplemented!()",
    "not yet supported",
    "deferred to a later evaluation slice",
    "backend-only",
)


def fail(message: str) -> NoReturn:
    print(f"Flash v1 conformance: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_inventory(path: Path = INVENTORY_PATH) -> dict:
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


def safe_path(root: Path, value: str, label: str) -> Path:
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        fail(f"{label} must stay inside {root.relative_to(ROOT)}")
    path = root / relative
    if not path.is_file():
        fail(f"{label} does not name a file: {value}")
    return path


def validate_test_owner(owner: str, label: str, root: Path) -> None:
    try:
        relative, test_name = owner.split("::", 1)
    except ValueError:
        fail(f"{label} must use path::test_name syntax")
    if not re.fullmatch(r"[a-z][a-z0-9_]*", test_name):
        fail(f"{label} has an invalid Rust test name: {test_name!r}")
    path = safe_path(root / "components/flash", relative, f"{label} path")
    source = path.read_text()
    declaration = re.compile(
        rf"(?m)^#\[test\]\n(?:#\[[^\n]+\]\n)*fn {re.escape(test_name)}\(\) \{{"
    )
    match = declaration.search(source)
    if match is None:
        fail(f"{label} does not resolve to an enabled #[test]: {owner}")
    prefix = source[max(0, match.start() - 120) : match.start()]
    if "#[ignore" in prefix:
        fail(f"{label} resolves to an ignored test: {owner}")


def validate_boundaries(root: Path) -> None:
    source_root = root / "components/flash/crates/flash-runtime/src"
    for path in sorted(source_root.glob("*.rs")):
        lines = path.read_text().splitlines()
        for index, line in enumerate(lines):
            if not any(marker in line for marker in AUDITED_CONSTRUCTORS):
                continue
            nearby = lines[max(0, index - 3) : index]
            annotations = [BOUNDARY_PATTERN.fullmatch(item.strip()) for item in nearby]
            annotations = [match for match in annotations if match is not None]
            relative = path.relative_to(root)
            if len(annotations) != 1:
                fail(
                    f"{relative}:{index + 1} needs one nearby "
                    "flash-v1-boundary annotation"
                )
            category = annotations[0].group("category")
            if category not in BOUNDARY_CATEGORIES:
                fail(
                    f"{relative}:{index + 1} uses unknown boundary "
                    f"category {category!r}"
                )
        text = "\n".join(lines)
        for marker in FORBIDDEN_SOURCE_MARKERS:
            if marker in text:
                fail(f"{path.relative_to(root)} retains forbidden marker {marker!r}")


def validate_config_settings(root: Path) -> None:
    path = root / "components/flash/crates/flash-cli/src/config.rs"
    source = path.read_text()
    settings = re.findall(
        r'^const [A-Z][A-Z0-9_]*_SETTING: &str = "([a-z][a-z0-9_]*)";$',
        source,
        flags=re.MULTILINE,
    )
    if settings != REQUIRED_CONFIG_SETTINGS:
        fail(
            f"{path.relative_to(root)} config settings are {settings!r}, "
            f"expected {REQUIRED_CONFIG_SETTINGS!r}"
        )


def validate(document: dict, root: Path = ROOT) -> None:
    require_keys(
        document,
        {
            "schema_version",
            "language_major",
            "workspace_test_command",
            "ci_workflow",
            "family",
            "platform_contracts",
            "config_settings",
        },
        "document",
    )
    if document.get("schema_version") != 1:
        fail("schema_version must be 1")
    if document.get("language_major") != 1:
        fail("language_major must be 1")
    if document.get("workspace_test_command") != "cargo test --workspace --locked":
        fail("workspace_test_command must run the complete locked workspace suite")
    if document.get("ci_workflow") != ".github/workflows/ci.yml":
        fail("ci_workflow must name the standard candidate workflow")

    families = document.get("family")
    if not isinstance(families, list):
        fail("family must be an array of tables")
    identifiers: list[str] = []
    owners: list[str] = []
    covered_layers: set[str] = set()
    for index, family in enumerate(families):
        label = f"family[{index}]"
        if not isinstance(family, dict):
            fail(f"{label} must be a table")
        require_keys(family, {"id", "summary", "layers", "tests"}, label)
        identifier = require_string(family.get("id"), f"{label}.id")
        if not re.fullmatch(r"[a-z][a-z0-9-]*", identifier):
            fail(f"{label}.id is not a public kebab-case identifier")
        identifiers.append(identifier)
        require_string(family.get("summary"), f"{label}.summary")
        layers = require_string_list(family.get("layers"), f"{label}.layers")
        unknown_layers = set(layers) - REQUIRED_LAYERS
        if unknown_layers:
            fail(f"{label}.layers contains unknown values: {sorted(unknown_layers)!r}")
        covered_layers.update(layers)
        tests = require_string_list(family.get("tests"), f"{label}.tests")
        if len(tests) < 2:
            fail(f"{label}.tests must contain at least two executable owners")
        for test_index, owner in enumerate(tests):
            validate_test_owner(owner, f"{label}.tests[{test_index}]", root)
            owners.append(owner)
    if identifiers != REQUIRED_FAMILIES:
        fail(f"family ids are {identifiers!r}, expected {REQUIRED_FAMILIES!r}")
    if len(owners) != len(set(owners)):
        fail("test owners must not be reused across conformance families")
    if covered_layers != REQUIRED_LAYERS:
        fail(
            f"covered layers are {sorted(covered_layers)!r}, "
            f"expected {sorted(REQUIRED_LAYERS)!r}"
        )

    contracts = require_string_list(
        document.get("platform_contracts"), "platform_contracts"
    )
    if contracts != REQUIRED_PLATFORM_CONTRACTS:
        fail(
            f"platform_contracts are {contracts!r}, "
            f"expected {REQUIRED_PLATFORM_CONTRACTS!r}"
        )
    for index, contract in enumerate(contracts):
        safe_path(root, contract, f"platform_contracts[{index}]")

    settings = require_string_list(document.get("config_settings"), "config_settings")
    if settings != REQUIRED_CONFIG_SETTINGS:
        fail(
            f"config_settings are {settings!r}, "
            f"expected {REQUIRED_CONFIG_SETTINGS!r}"
        )
    validate_config_settings(root)

    workflow = safe_path(
        root, require_string(document.get("ci_workflow"), "ci_workflow"), "ci_workflow"
    ).read_text()
    required_workflow_fragments = [
        "python3 ../../ci/check_flash_conformance.py",
        document["workspace_test_command"],
    ]
    for fragment in required_workflow_fragments:
        if workflow.count(fragment) != 1:
            fail(f"CI workflow must contain exactly one {fragment!r}")

    validate_boundaries(root)


def main() -> None:
    validate(load_inventory())
    print("Flash v1 conformance: ok")


if __name__ == "__main__":
    main()
