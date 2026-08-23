#!/usr/bin/env python3
"""Shared schema, summary, and validation support for Flash benchmarks."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import statistics
import tomllib
from pathlib import Path
from typing import Any

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
BENCHMARK_ROOT = REPOSITORY_ROOT / "components/flash/benchmarks"
CONTRACT_PATH = BENCHMARK_ROOT / "contract-v1.toml"
BUDGET_PATH = BENCHMARK_ROOT / "budgets-v1.toml"
RESULT_SCHEMA = "flash-performance-result-v1"
EXPECTED_SURFACES = {
    "startup",
    "first_prompt",
    "command_overhead",
    "pipeline_throughput",
    "structured_stream_memory",
    "completion_latency",
}
RESULT_UNITS = {
    "elapsed_ns": "ns",
    "elapsed_ns_per_command": "ns/command",
    "bytes_per_second": "bytes/second",
    "peak_rss_bytes": "bytes",
}


class BenchmarkContractError(ValueError):
    """The benchmark contract, evidence, or budget data is inconsistent."""


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_contract(path: Path = CONTRACT_PATH) -> dict[str, Any]:
    try:
        document = tomllib.loads(path.read_text())
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise BenchmarkContractError(
            f"cannot load benchmark contract: {error}"
        ) from error
    if document.get("schema_version") != 1 or document.get("suite_version") != 1:
        raise BenchmarkContractError(
            "benchmark contract must use schema and suite version 1"
        )
    if document.get("result_schema") != RESULT_SCHEMA:
        raise BenchmarkContractError("benchmark contract names the wrong result schema")
    supported_host_os = document.get("supported_host_os")
    if (
        not isinstance(supported_host_os, list)
        or not supported_host_os
        or len(set(supported_host_os)) != len(supported_host_os)
        or any(name not in {"linux", "macos"} for name in supported_host_os)
    ):
        raise BenchmarkContractError("benchmark contract has invalid host OS support")
    profiles = document.get("profiles")
    if not isinstance(profiles, dict) or set(profiles) != {"smoke", "qualification"}:
        raise BenchmarkContractError(
            "benchmark contract must define smoke and qualification"
        )
    for name, profile in profiles.items():
        if not isinstance(profile, dict):
            raise BenchmarkContractError(f"profile {name!r} must be a table")
        for field in (
            "warmups",
            "samples",
            "command_iterations",
            "pipeline_bytes",
            "stream_items",
        ):
            value = profile.get(field)
            if not isinstance(value, int) or value < (0 if field == "warmups" else 1):
                raise BenchmarkContractError(f"profile {name!r} has invalid {field!r}")
        if name == "qualification":
            for field in (
                "target_warmups",
                "target_samples",
                "target_pipeline_bytes",
            ):
                value = profile.get(field)
                if not isinstance(value, int) or value < 1:
                    raise BenchmarkContractError(
                        f"profile {name!r} has invalid {field!r}"
                    )
    cases = document.get("cases")
    if not isinstance(cases, list) or not cases:
        raise BenchmarkContractError("benchmark contract must define cases")
    identifiers: set[str] = set()
    surfaces: set[str] = set()
    for case in cases:
        if not isinstance(case, dict):
            raise BenchmarkContractError("every benchmark case must be a table")
        identifier = case.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise BenchmarkContractError("every benchmark case needs an id")
        if identifier in identifiers:
            raise BenchmarkContractError(f"benchmark case {identifier!r} is repeated")
        identifiers.add(identifier)
        surface = case.get("surface")
        if surface not in EXPECTED_SURFACES:
            raise BenchmarkContractError(
                f"benchmark case {identifier!r} has unknown surface"
            )
        surfaces.add(surface)
        if case.get("environment") not in {"host", "flashos-qemu-tcg"}:
            raise BenchmarkContractError(
                f"benchmark case {identifier!r} has unknown environment"
            )
        if case.get("direction") not in {"minimum", "maximum"}:
            raise BenchmarkContractError(
                f"benchmark case {identifier!r} has unknown direction"
            )
        if case.get("sample_class") not in {"cold", "warm"}:
            raise BenchmarkContractError(
                f"benchmark case {identifier!r} has unknown sample class"
            )
    if surfaces != EXPECTED_SURFACES:
        missing = sorted(EXPECTED_SURFACES - surfaces)
        raise BenchmarkContractError(
            f"benchmark contract omits surfaces: {', '.join(missing)}"
        )
    return document


def contract_sha256() -> str:
    load_contract()
    return sha256(CONTRACT_PATH)


def nearest_rank(values: list[int], percentile: int = 95) -> int:
    if not values:
        raise BenchmarkContractError("cannot summarize an empty sample set")
    ordered = sorted(values)
    rank = max(1, math.ceil(len(ordered) * percentile / 100))
    return ordered[min(rank, len(ordered)) - 1]


def summarize(values: list[int]) -> dict[str, int]:
    if not values or any(not isinstance(value, int) or value <= 0 for value in values):
        raise BenchmarkContractError("benchmark samples must be positive integers")
    return {
        "minimum": min(values),
        "median": int(statistics.median(values)),
        "p95": nearest_rank(values),
        "maximum": max(values),
    }


def validate_result(
    document: dict[str, Any],
    contract: dict[str, Any] | None = None,
) -> None:
    contract = contract or load_contract()
    if document.get("schema") != RESULT_SCHEMA:
        raise BenchmarkContractError("benchmark result has the wrong schema")
    if document.get("suite_version") != contract["suite_version"]:
        raise BenchmarkContractError("benchmark result has the wrong suite version")
    if document.get("contract_sha256") != sha256(CONTRACT_PATH):
        raise BenchmarkContractError(
            "benchmark result does not bind the current contract"
        )
    environment = document.get("environment")
    if not isinstance(environment, dict):
        raise BenchmarkContractError("benchmark result has no environment table")
    kind = environment.get("kind")
    if kind not in {"host", "flashos-qemu-tcg"}:
        raise BenchmarkContractError("benchmark result has an unknown environment kind")
    if kind == "host" and environment.get("os") not in contract["supported_host_os"]:
        raise BenchmarkContractError("benchmark result has an unsupported host OS")
    case_environment = kind
    expected_cases = {
        case["id"]: case
        for case in contract["cases"]
        if case["environment"] == case_environment
    }
    expected = set(expected_cases)
    profile_name = document.get("profile")
    if profile_name not in contract["profiles"]:
        raise BenchmarkContractError("benchmark result has an unknown profile")
    if kind == "flashos-qemu-tcg" and profile_name != "qualification":
        raise BenchmarkContractError(
            "target benchmark results must be qualification runs"
        )
    profile = contract["profiles"][profile_name]
    parameters = document.get("parameters")
    if not isinstance(parameters, dict):
        raise BenchmarkContractError("benchmark result has no parameters")
    expected_parameters = (
        {
            "warmups": profile["target_warmups"],
            "samples": profile["target_samples"],
            "pipeline_bytes": profile["target_pipeline_bytes"],
        }
        if kind == "flashos-qemu-tcg"
        else {
            field: profile[field]
            for field in (
                "warmups",
                "samples",
                "command_iterations",
                "pipeline_bytes",
                "stream_items",
            )
        }
    )
    for field, value in expected_parameters.items():
        if parameters.get(field) != value:
            raise BenchmarkContractError(
                f"benchmark result parameter {field!r} does not match its profile"
            )
    artifact_hash_field = "binary_sha256" if kind == "host" else "image_sha256"
    artifact_hash = document.get(artifact_hash_field)
    if not isinstance(artifact_hash, str) or not re.fullmatch(
        r"[0-9a-f]{64}", artifact_hash
    ):
        raise BenchmarkContractError(
            f"benchmark result has an invalid {artifact_hash_field}"
        )
    measurements = document.get("measurements")
    if not isinstance(measurements, list):
        raise BenchmarkContractError("benchmark result has no measurements")
    observed: set[str] = set()
    for measurement in measurements:
        if not isinstance(measurement, dict):
            raise BenchmarkContractError("benchmark measurement must be an object")
        identifier = measurement.get("case_id")
        if identifier in observed:
            raise BenchmarkContractError(f"benchmark result repeats {identifier!r}")
        observed.add(identifier)
        case = expected_cases.get(identifier)
        if case is None:
            raise BenchmarkContractError(
                f"benchmark result has unknown case {identifier!r}"
            )
        if measurement.get("unit") != RESULT_UNITS[case["metric"]]:
            raise BenchmarkContractError(
                f"benchmark result {identifier!r} has wrong unit"
            )
        samples = measurement.get("samples")
        if not isinstance(samples, list):
            raise BenchmarkContractError(
                f"benchmark result {identifier!r} has no samples"
            )
        if measurement.get("summary") != summarize(samples):
            raise BenchmarkContractError(
                f"benchmark result {identifier!r} summary drifted"
            )
        warmups = measurement.get("warmup_samples")
        if not isinstance(warmups, list) or any(
            not isinstance(value, int) or value <= 0 for value in warmups
        ):
            raise BenchmarkContractError(
                f"benchmark result {identifier!r} has invalid warmups"
            )
        if case["sample_class"] == "cold":
            expected_samples = 1
            expected_warmups = 0
        elif kind == "host":
            expected_samples = profile["samples"]
            expected_warmups = profile["warmups"]
        else:
            expected_samples = profile["target_samples"]
            expected_warmups = profile["target_warmups"]
        if len(samples) != expected_samples or len(warmups) != expected_warmups:
            raise BenchmarkContractError(
                f"benchmark result {identifier!r} has wrong sample counts"
            )
    if observed != expected:
        missing = sorted(expected - observed)
        extra = sorted(observed - expected)
        raise BenchmarkContractError(
            f"benchmark result case coverage drifted; missing={missing}, extra={extra}"
        )


def load_result(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkContractError(
            f"cannot load benchmark result {path}: {error}"
        ) from error
    if not isinstance(document, dict):
        raise BenchmarkContractError(f"benchmark result {path} must be an object")
    validate_result(document)
    return document


def budget_policy(case: dict[str, Any], environment_kind: str) -> tuple[str, int, int]:
    if case["direction"] == "minimum":
        statistic = "median"
    elif (
        case["sample_class"] == "cold" or case["surface"] == "structured_stream_memory"
    ):
        statistic = "maximum"
    else:
        statistic = "p95"
    numerator = (
        4 if environment_kind == "host" and case["sample_class"] == "cold" else 3
    )
    return statistic, numerator, 1


def validate_budgets() -> dict[str, Any]:
    try:
        document = tomllib.loads(BUDGET_PATH.read_text())
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise BenchmarkContractError(
            f"cannot load benchmark budgets: {error}"
        ) from error
    if document.get("schema_version") != 1:
        raise BenchmarkContractError("benchmark budgets must use schema version 1")
    if document.get("contract_sha256") != contract_sha256():
        raise BenchmarkContractError(
            "benchmark budgets do not bind the current contract"
        )
    environments = document.get("environments")
    budgets = document.get("budgets")
    if not isinstance(environments, list) or not isinstance(budgets, list):
        raise BenchmarkContractError("benchmark budgets need environments and budgets")
    evidence_by_environment: dict[str, dict[str, Any]] = {}
    expected_budget_keys: set[tuple[str, str]] = set()
    for environment in environments:
        identifier = environment.get("id")
        relative = environment.get("evidence")
        if not isinstance(identifier, str) or not isinstance(relative, str):
            raise BenchmarkContractError("budget environment needs id and evidence")
        evidence_path = BENCHMARK_ROOT / relative
        if environment.get("evidence_sha256") != sha256(evidence_path):
            raise BenchmarkContractError(
                f"budget environment {identifier!r} evidence drifted"
            )
        if identifier in evidence_by_environment:
            raise BenchmarkContractError(
                f"budget environment {identifier!r} is repeated"
            )
        evidence = load_result(evidence_path)
        environment_match = environment.get("match")
        if not isinstance(environment_match, dict) or not environment_match:
            raise BenchmarkContractError(
                f"budget environment {identifier!r} needs match fields"
            )
        for field, value in environment_match.items():
            if evidence["environment"].get(field) != value:
                raise BenchmarkContractError(
                    f"budget environment {identifier!r} mismatches evidence "
                    f"field {field!r}"
                )
        evidence_by_environment[identifier] = evidence
        expected_budget_keys.update(
            (identifier, measurement["case_id"])
            for measurement in evidence["measurements"]
        )
    seen: set[tuple[str, str]] = set()
    case_by_id = {case["id"]: case for case in load_contract()["cases"]}
    for budget in budgets:
        environment_id = budget.get("environment")
        case_id = budget.get("case_id")
        key = (environment_id, case_id)
        if key in seen:
            raise BenchmarkContractError(f"benchmark budget repeats {key!r}")
        seen.add(key)
        evidence = evidence_by_environment.get(environment_id)
        if evidence is None or case_id not in case_by_id:
            raise BenchmarkContractError(
                f"benchmark budget {key!r} has unknown ownership"
            )
        measurement = next(
            (item for item in evidence["measurements"] if item["case_id"] == case_id),
            None,
        )
        if measurement is None:
            raise BenchmarkContractError(f"benchmark budget {key!r} has no evidence")
        case = case_by_id[case_id]
        expected_statistic, expected_numerator, expected_denominator = budget_policy(
            case, evidence["environment"]["kind"]
        )
        statistic = budget.get("statistic")
        if statistic != expected_statistic:
            raise BenchmarkContractError(
                f"benchmark budget {key!r} violates the statistic policy"
            )
        baseline = measurement["summary"][statistic]
        if budget.get("baseline") != baseline:
            raise BenchmarkContractError(f"benchmark budget {key!r} baseline drifted")
        numerator = budget.get("factor_numerator")
        denominator = budget.get("factor_denominator")
        if (numerator, denominator) != (expected_numerator, expected_denominator):
            raise BenchmarkContractError(
                f"benchmark budget {key!r} violates the tolerance policy"
            )
        direction = case["direction"]
        derived = (
            math.ceil(baseline * numerator / denominator)
            if direction == "maximum"
            else math.floor(baseline * denominator / numerator)
        )
        if budget.get("limit") != derived:
            raise BenchmarkContractError(
                f"benchmark budget {key!r} limit is not derived"
            )
    if seen != expected_budget_keys:
        missing = sorted(expected_budget_keys - seen)
        extra = sorted(seen - expected_budget_keys)
        raise BenchmarkContractError(
            f"benchmark budget coverage drifted; missing={missing}, extra={extra}"
        )
    return document


def evaluate_document(
    result: dict[str, Any],
    environment_id: str,
    budgets: dict[str, Any] | None = None,
) -> None:
    validate_result(result)
    if result.get("profile") != "qualification":
        raise BenchmarkContractError("only qualification results can be budgeted")
    budgets = budgets or validate_budgets()
    environment = next(
        (item for item in budgets["environments"] if item.get("id") == environment_id),
        None,
    )
    if environment is None:
        raise BenchmarkContractError(f"unknown budget environment {environment_id!r}")
    for field, value in environment["match"].items():
        if result["environment"].get(field) != value:
            raise BenchmarkContractError(
                f"result does not match {environment_id!r} field {field!r}"
            )
    measurements = {
        measurement["case_id"]: measurement for measurement in result["measurements"]
    }
    cases = {case["id"]: case for case in load_contract()["cases"]}
    regressions = []
    for budget in budgets["budgets"]:
        if budget["environment"] != environment_id:
            continue
        case_id = budget["case_id"]
        observed = measurements[case_id]["summary"][budget["statistic"]]
        limit = budget["limit"]
        direction = cases[case_id]["direction"]
        failed = observed > limit if direction == "maximum" else observed < limit
        if failed:
            regressions.append(
                f"{case_id}: observed {observed}, required "
                f"{'at most' if direction == 'maximum' else 'at least'} {limit}"
            )
    if regressions:
        raise BenchmarkContractError(
            "performance regressions: " + "; ".join(regressions)
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result", action="append", type=Path, default=[])
    parser.add_argument("--contract-only", action="store_true")
    parser.add_argument("--evaluate", type=Path)
    parser.add_argument("--environment")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    load_contract()
    for result in args.result:
        load_result(result)
    if args.contract_only and (args.evaluate or args.environment):
        raise BenchmarkContractError("--contract-only cannot evaluate a budget")
    if bool(args.evaluate) != bool(args.environment):
        raise BenchmarkContractError(
            "--evaluate and --environment must be used together"
        )
    if not args.contract_only:
        budgets = validate_budgets()
        if args.evaluate:
            evaluate_document(load_result(args.evaluate), args.environment, budgets)
    print("Flash benchmark contract: ok")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkContractError as error:
        raise SystemExit(f"Flash benchmark contract: FAILED: {error}") from error
