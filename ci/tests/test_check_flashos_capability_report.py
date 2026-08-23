from __future__ import annotations

import copy
import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ci"))
SCRIPT = ROOT / "ci/check_flashos_capability_report.py"
SPEC = importlib.util.spec_from_file_location("check_flashos_capability_report", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
report_check = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = report_check
SPEC.loader.exec_module(report_check)


class FlashOSCapabilityReportTests(unittest.TestCase):
    def test_tracked_sources_match_the_versioned_report(self) -> None:
        document = report_check.load_toml(report_check.REPORT_PATH)
        report_check.validate(document)

    def test_report_preserves_capability_order(self) -> None:
        document = report_check.load_toml(report_check.REPORT_PATH)
        evidence = report_check.load_toml(report_check.EVIDENCE_PATH)

        expected = [item["rust_variant"] for item in evidence["capability"]]
        actual = [item["rust_variant"] for item in document["capability"]]
        self.assertEqual(actual, expected)

    def test_withheld_capability_cannot_be_advertised(self) -> None:
        document = copy.deepcopy(report_check.load_toml(report_check.REPORT_PATH))
        signals = next(
            item for item in document["capability"] if item["name"] == "signals"
        )
        signals["advertised"] = True
        signals["qualification"] = "bounded"
        signals["fixture_ids"] = ["background-child"]

        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            report_check.validate(document)

    def test_advertised_capability_requires_a_declared_fixture(self) -> None:
        document = copy.deepcopy(report_check.load_toml(report_check.REPORT_PATH))
        document["capability"][0]["fixture_ids"] = []

        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            report_check.validate(document)

    def test_workspace_version_drift_fails_the_report(self) -> None:
        document = copy.deepcopy(report_check.load_toml(report_check.REPORT_PATH))
        document["flash_workspace_version"] = "9.9.9"

        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            report_check.validate(document)


if __name__ == "__main__":
    unittest.main()
