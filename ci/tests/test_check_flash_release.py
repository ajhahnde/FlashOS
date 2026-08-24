from __future__ import annotations

import copy
import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/check_flash_release.py"
SPEC = importlib.util.spec_from_file_location("check_flash_release", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
release_check = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release_check
SPEC.loader.exec_module(release_check)


class FlashReleaseTests(unittest.TestCase):
    def test_release_record_matches_versions_contracts_claims_and_ci(self) -> None:
        release_check.validate(release_check.load_release())

    def test_the_released_version_cannot_return_to_candidate_status(self) -> None:
        document = copy.deepcopy(release_check.load_release())
        document["status"] = "candidate"
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            release_check.validate(document)

    def test_a_release_finding_blocks_the_release(self) -> None:
        document = copy.deepcopy(release_check.load_release())
        document["release_findings"] = ["critical-runtime-finding"]
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            release_check.validate(document)

    def test_an_unexamined_inventory_item_blocks_the_release(self) -> None:
        document = copy.deepcopy(release_check.load_release())
        document["unexamined_inventory_items"] = ["missing-user-path"]
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            release_check.validate(document)

    def test_the_flashos_product_release_cannot_be_claimed_by_flash(self) -> None:
        document = copy.deepcopy(release_check.load_release())
        document["limitations"][0] = "FlashOS is also released."
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            release_check.validate(document)


if __name__ == "__main__":
    unittest.main()
