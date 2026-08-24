from __future__ import annotations

import copy
import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/check_flash_v1_exercises.py"
SPEC = importlib.util.spec_from_file_location("check_flash_v1_exercises", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
exercise_check = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = exercise_check
SPEC.loader.exec_module(exercise_check)


class FlashV1ExerciseContractTests(unittest.TestCase):
    def test_complete_contract_matches_live_sources(self) -> None:
        exercise_check.validate(exercise_check.load_contract())

    def test_a_closed_namespace_member_cannot_disappear(self) -> None:
        document = copy.deepcopy(exercise_check.load_contract())
        builtins = next(
            surface
            for surface in document["surface"]
            if surface["id"] == "standard-builtins"
        )
        builtins["members"].pop()
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            exercise_check.validate(document)

    def test_a_documentation_block_cannot_lose_its_owner(self) -> None:
        document = copy.deepcopy(exercise_check.load_contract())
        document["documentation_rule"][-1]["last_block"] -= 1
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            exercise_check.validate(document)

    def test_a_compatibility_path_cannot_lose_its_classification(self) -> None:
        document = copy.deepcopy(exercise_check.load_contract())
        document["compatibility"] = [
            record
            for record in document["compatibility"]
            if record["id"] != "namespace-evolution-machinery"
        ]
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            exercise_check.validate(document)

    def test_every_contract_case_requires_an_executable_owner(self) -> None:
        document = copy.deepcopy(exercise_check.load_contract())
        document["surface"][0]["exercise_case"] = "missing-owner"
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            exercise_check.validate(document)

    def test_every_flashos_owner_must_resolve(self) -> None:
        document = copy.deepcopy(exercise_check.load_contract())
        document["surface"][0]["flashos_owner"] = "target-matrix:not-a-case"
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            exercise_check.validate(document)

    def test_host_evidence_must_match_the_candidate(self) -> None:
        document = copy.deepcopy(exercise_check.load_contract())
        document["suite_version"] = 2
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            exercise_check.validate(document)


if __name__ == "__main__":
    unittest.main()
