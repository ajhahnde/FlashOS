from __future__ import annotations

import copy
import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/check_flashos_capabilities.py"
capability_check = None
if SCRIPT.is_file():
    SPEC = importlib.util.spec_from_file_location("check_flashos_capabilities", SCRIPT)
    assert SPEC is not None and SPEC.loader is not None
    capability_check = importlib.util.module_from_spec(SPEC)
    sys.modules[SPEC.name] = capability_check
    SPEC.loader.exec_module(capability_check)


@unittest.skipUnless(
    capability_check is not None,
    "the Python capability-evidence validator has migrated to Flash",
)
class FlashOSCapabilityEvidenceTests(unittest.TestCase):
    def test_tracked_sources_match_the_capability_inventory(self) -> None:
        document = capability_check.load_toml(capability_check.EVIDENCE_PATH)
        capability_check.validate(document)

    def test_inventory_covers_the_contract_enum_in_declaration_order(self) -> None:
        document = capability_check.load_toml(capability_check.EVIDENCE_PATH)
        source = capability_check.CONTRACT_PATH.read_text()
        expected = capability_check.parse_capability_variants(source)
        actual = [entry["rust_variant"] for entry in document["capability"]]
        self.assertEqual(actual, expected)

    def test_classification_cannot_land_in_the_evidence_inventory(self) -> None:
        document = copy.deepcopy(
            capability_check.load_toml(capability_check.EVIDENCE_PATH)
        )
        document["capability"][0]["classification"] = "native"
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            capability_check.validate(document)


if __name__ == "__main__":
    unittest.main()
