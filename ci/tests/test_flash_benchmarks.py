from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/flash_benchmarks.fsh"
RUNTIME = os.environ.get("FLASH_AUTOMATION_RUNTIME")


@unittest.skipUnless(RUNTIME, "Flash automation runtime is not selected")
class FlashBenchmarkContractTests(unittest.TestCase):
    def run_checker(self, *arguments: object) -> subprocess.CompletedProcess[str]:
        assert RUNTIME is not None
        return subprocess.run(
            [RUNTIME, SCRIPT, *(str(argument) for argument in arguments)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_passes(self, *arguments: object) -> subprocess.CompletedProcess[str]:
        process = self.run_checker(*arguments)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, "")
        return process

    def test_tracked_contract_results_and_budgets_are_valid(self) -> None:
        process = self.assert_passes()
        self.assertEqual(process.stdout, "Flash benchmark contract: ok\n")

        evidence = ROOT / "components/flash/benchmarks/evidence"
        for result in (
            evidence / "host-darwin-arm64-v1.json",
            evidence / "flashos-qemu-tcg-v1.json",
        ):
            with self.subTest(result=result.name):
                self.assert_passes("--result", result)

    def test_contract_boundary_is_versioned_and_digest_bound(self) -> None:
        process = self.assert_passes("--contract-json-v1")
        document = json.loads(process.stdout)
        self.assertEqual(document["boundary_schema"], 1)
        self.assertEqual(document["kind"], "flash-benchmark-contract")
        self.assertEqual(document["result_schema"], "flash-performance-result-v1")
        self.assertEqual(len(document["contract_sha256"]), 64)

    def test_result_rejects_summary_drift(self) -> None:
        source = (
            ROOT
            / "components/flash/benchmarks/evidence/host-darwin-arm64-v1.json"
        )
        document = json.loads(source.read_text(encoding="utf-8"))
        document["measurements"][0]["summary"]["p95"] += 1
        with tempfile.TemporaryDirectory(prefix="flash-benchmark-test-") as raw:
            result = Path(raw) / "result.json"
            result.write_text(json.dumps(document), encoding="utf-8")
            process = self.run_checker("--result", result)
        self.assertEqual(process.returncode, 1)
        self.assertIn("summary drifted", process.stderr)

    def test_budget_evaluation_rejects_a_regression(self) -> None:
        source = (
            ROOT
            / "components/flash/benchmarks/evidence/host-darwin-arm64-v1.json"
        )
        document = json.loads(source.read_text(encoding="utf-8"))
        measurement = document["measurements"][0]
        measurement["samples"] = [10**18]
        measurement["summary"] = {
            "minimum": 10**18,
            "median": 10**18,
            "p95": 10**18,
            "maximum": 10**18,
        }
        with tempfile.TemporaryDirectory(prefix="flash-benchmark-test-") as raw:
            result = Path(raw) / "result.json"
            result.write_text(json.dumps(document), encoding="utf-8")
            process = self.run_checker(
                "--evaluate",
                result,
                "--environment",
                "host-darwin-arm64",
            )
        self.assertEqual(process.returncode, 1)
        self.assertIn("performance regressions", process.stderr)

    def test_missing_result_argument_is_a_usage_error(self) -> None:
        process = self.run_checker("--result")
        self.assertEqual(process.returncode, 2)
        self.assertIn("argument --result: expected one argument", process.stderr)


if __name__ == "__main__":
    unittest.main()
