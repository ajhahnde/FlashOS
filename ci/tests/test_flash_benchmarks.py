from __future__ import annotations

import sys
import unittest
from pathlib import Path

CI_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CI_ROOT))

import flash_benchmarks as benchmarks  # noqa: E402


class FlashBenchmarkContractTests(unittest.TestCase):
    def result(self, kind: str) -> dict[str, object]:
        contract = benchmarks.load_contract()
        environment = "host" if kind == "host" else "flashos-qemu-tcg"
        profile_name = "smoke" if kind == "host" else "qualification"
        profile = contract["profiles"][profile_name]
        measurements = []
        for index, case in enumerate(contract["cases"], start=1):
            if case["environment"] != environment:
                continue
            if case["sample_class"] == "cold":
                samples = [index]
                warmups = []
            elif kind == "host":
                samples = [index] * profile["samples"]
                warmups = [index] * profile["warmups"]
            else:
                samples = [index] * profile["target_samples"]
                warmups = [index] * profile["target_warmups"]
            measurements.append(
                {
                    "case_id": case["id"],
                    "unit": benchmarks.RESULT_UNITS[case["metric"]],
                    "warmup_samples": warmups,
                    "samples": samples,
                    "summary": benchmarks.summarize(samples),
                }
            )
        parameters = (
            {
                "warmups": profile["warmups"],
                "samples": profile["samples"],
                "command_iterations": profile["command_iterations"],
                "pipeline_bytes": profile["pipeline_bytes"],
                "stream_items": profile["stream_items"],
            }
            if kind == "host"
            else {
                "warmups": profile["target_warmups"],
                "samples": profile["target_samples"],
                "pipeline_bytes": profile["target_pipeline_bytes"],
            }
        )
        return {
            "schema": benchmarks.RESULT_SCHEMA,
            "suite_version": contract["suite_version"],
            "profile": profile_name,
            "contract_sha256": benchmarks.sha256(benchmarks.CONTRACT_PATH),
            "binary_sha256" if kind == "host" else "image_sha256": "0" * 64,
            "environment": {
                "kind": kind,
                **({"os": "linux"} if kind == "host" else {}),
            },
            "parameters": parameters,
            "measurements": measurements,
        }

    def test_contract_covers_every_required_surface(self) -> None:
        contract = benchmarks.load_contract()
        self.assertEqual(
            {case["surface"] for case in contract["cases"]},
            benchmarks.EXPECTED_SURFACES,
        )

    def test_host_and_target_results_require_exact_case_coverage(self) -> None:
        benchmarks.validate_result(self.result("host"))
        benchmarks.validate_result(self.result("flashos-qemu-tcg"))

        missing = self.result("host")
        missing["measurements"].pop()
        with self.assertRaisesRegex(benchmarks.BenchmarkContractError, "coverage"):
            benchmarks.validate_result(missing)

    def test_result_rejects_summary_and_contract_drift(self) -> None:
        summary_drift = self.result("host")
        summary_drift["measurements"][0]["summary"]["p95"] += 1
        with self.assertRaisesRegex(benchmarks.BenchmarkContractError, "summary"):
            benchmarks.validate_result(summary_drift)

        contract_drift = self.result("host")
        contract_drift["contract_sha256"] = "0" * 64
        with self.assertRaisesRegex(benchmarks.BenchmarkContractError, "contract"):
            benchmarks.validate_result(contract_drift)

    def test_result_rejects_nonpositive_samples(self) -> None:
        result = self.result("host")
        result["measurements"][0]["samples"][0] = 0
        with self.assertRaisesRegex(benchmarks.BenchmarkContractError, "positive"):
            benchmarks.validate_result(result)

    def test_nearest_rank_is_stable_for_small_and_even_sets(self) -> None:
        self.assertEqual(benchmarks.nearest_rank([5]), 5)
        self.assertEqual(benchmarks.nearest_rank([1, 2, 3, 4]), 4)
        self.assertEqual(benchmarks.summarize([1, 2, 3, 4])["median"], 2)

    def test_budget_policy_distinguishes_cold_warm_and_throughput(self) -> None:
        contract = benchmarks.load_contract()
        cases = {case["id"]: case for case in contract["cases"]}
        self.assertEqual(
            benchmarks.budget_policy(cases["host-startup-cold"], "host"),
            ("maximum", 4, 1),
        )
        self.assertEqual(
            benchmarks.budget_policy(cases["host-startup-warm"], "host"),
            ("p95", 3, 1),
        )
        self.assertEqual(
            benchmarks.budget_policy(
                cases["flashos-pipeline-throughput-warm"], "flashos-qemu-tcg"
            ),
            ("median", 3, 1),
        )

    def test_tracked_baselines_satisfy_their_derived_budgets(self) -> None:
        budgets = benchmarks.validate_budgets()
        for environment in budgets["environments"]:
            result = benchmarks.load_result(
                benchmarks.BENCHMARK_ROOT / environment["evidence"]
            )
            benchmarks.evaluate_document(result, environment["id"], budgets)

    def test_budget_evaluation_rejects_a_regression(self) -> None:
        budgets = benchmarks.validate_budgets()
        environment = budgets["environments"][0]
        result = benchmarks.load_result(
            benchmarks.BENCHMARK_ROOT / environment["evidence"]
        )
        result["measurements"][0]["samples"] = [10**18]
        result["measurements"][0]["summary"] = benchmarks.summarize([10**18])
        with self.assertRaisesRegex(benchmarks.BenchmarkContractError, "regressions"):
            benchmarks.evaluate_document(result, environment["id"], budgets)


if __name__ == "__main__":
    unittest.main()
