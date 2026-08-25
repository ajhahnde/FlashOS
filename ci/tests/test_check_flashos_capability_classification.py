from __future__ import annotations

import copy
import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/check_flashos_capability_classification.py"
classification_check = None
if SCRIPT.is_file():
    SPEC = importlib.util.spec_from_file_location(
        "check_flashos_capability_classification", SCRIPT
    )
    assert SPEC is not None and SPEC.loader is not None
    classification_check = importlib.util.module_from_spec(SPEC)
    sys.modules[SPEC.name] = classification_check
    SPEC.loader.exec_module(classification_check)


@unittest.skipUnless(
    classification_check is not None,
    "the Python capability-classification validator has migrated to Flash",
)
class FlashOSCapabilityClassificationTests(unittest.TestCase):
    def test_tracked_sources_match_the_classification(self) -> None:
        document = classification_check.load_toml(
            classification_check.CLASSIFICATION_PATH
        )
        classification_check.validate(document)

    def test_classification_covers_every_mapped_operation_in_order(self) -> None:
        document = classification_check.load_toml(
            classification_check.CLASSIFICATION_PATH
        )
        operation_map = classification_check.load_toml(classification_check.MAP_PATH)
        expected = [
            (operation["id"], operation["capability"])
            for operation in operation_map["operation"]
        ]
        actual = [
            (operation["id"], operation["capability"])
            for operation in document["operation"]
        ]
        self.assertEqual(actual, expected)

    def test_unrouted_operation_cannot_be_native(self) -> None:
        document = copy.deepcopy(
            classification_check.load_toml(classification_check.CLASSIFICATION_PATH)
        )
        operation = next(
            item
            for item in document["operation"]
            if item["id"] == "directories-discover"
        )
        operation["classification"] = "native"
        operation["basis"] = "existing-rust-std-route"
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            classification_check.validate(document)

    def test_capability_verdict_must_aggregate_operation_verdicts(self) -> None:
        document = copy.deepcopy(
            classification_check.load_toml(classification_check.CLASSIFICATION_PATH)
        )
        capability = next(
            item
            for item in document["capability"]
            if item["name"] == "standard-directories"
        )
        capability["classification"] = "native"
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            classification_check.validate(document)

    def test_target_qualification_cannot_advance_in_classification(self) -> None:
        document = copy.deepcopy(
            classification_check.load_toml(classification_check.CLASSIFICATION_PATH)
        )
        document["capability"][0]["target_qualification"] = "qualified"
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            classification_check.validate(document)

    def test_evidence_and_map_must_remain_deferred(self) -> None:
        document = copy.deepcopy(
            classification_check.load_toml(classification_check.CLASSIFICATION_PATH)
        )
        operation_map = copy.deepcopy(
            classification_check.load_toml(classification_check.MAP_PATH)
        )
        operation_map["classification"] = "complete"
        original_loader = classification_check.load_toml

        def load_with_changed_map(path: Path) -> dict:
            if path.name == classification_check.MAP_PATH.name:
                return operation_map
            return original_loader(path)

        classification_check.load_toml = load_with_changed_map
        try:
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                classification_check.validate(document)
        finally:
            classification_check.load_toml = original_loader


if __name__ == "__main__":
    unittest.main()
