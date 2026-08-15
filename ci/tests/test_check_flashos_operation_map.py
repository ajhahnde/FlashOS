from __future__ import annotations

import copy
import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/check_flashos_operation_map.py"
SPEC = importlib.util.spec_from_file_location("check_flashos_operation_map", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
operation_check = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = operation_check
SPEC.loader.exec_module(operation_check)


class FlashOSOperationMapTests(unittest.TestCase):
    def test_tracked_sources_match_the_operation_map(self) -> None:
        document = operation_check.load_toml(operation_check.MAP_PATH)
        operation_check.validate(document)

    def test_map_covers_every_capability_requirement_in_order(self) -> None:
        document = operation_check.load_toml(operation_check.MAP_PATH)
        evidence = operation_check.load_toml(operation_check.EVIDENCE_PATH)
        expected = [
            (capability["name"], requirement)
            for capability in evidence["capability"]
            for requirement in capability["requirements"]
        ]
        actual = [
            (operation["capability"], operation["requirement"])
            for operation in document["operation"]
        ]
        self.assertEqual(actual, expected)

    def test_classification_cannot_land_in_the_operation_map(self) -> None:
        document = copy.deepcopy(operation_check.load_toml(operation_check.MAP_PATH))
        document["operation"][0]["classification"] = "native"
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            operation_check.validate(document)

    def test_unknown_rust_source_cannot_grow_inferred_paths_or_symbols(self) -> None:
        document = copy.deepcopy(operation_check.load_toml(operation_check.MAP_PATH))
        document["abi_seam"][0]["symbols"] = ["getenv"]
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            operation_check.validate(document)

    def test_tracked_seam_markers_cannot_drift(self) -> None:
        document = copy.deepcopy(operation_check.load_toml(operation_check.MAP_PATH))
        document["abi_seam"][0]["tracked_markers"] = ["missing marker"]
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            operation_check.validate(document)

    def test_unrouted_operation_cannot_claim_an_abi_seam(self) -> None:
        document = copy.deepcopy(operation_check.load_toml(operation_check.MAP_PATH))
        operation = next(
            item for item in document["operation"] if item["boundary"] == "unrouted"
        )
        operation["abi_seams"] = ["rust-filesystem"]
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            operation_check.validate(document)


if __name__ == "__main__":
    unittest.main()
