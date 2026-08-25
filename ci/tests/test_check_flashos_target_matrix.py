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
SCRIPT = ROOT / "ci/check_flashos_target_matrix.py"
matrix_check = None
if SCRIPT.is_file():
    SPEC = importlib.util.spec_from_file_location("check_flashos_target_matrix", SCRIPT)
    assert SPEC is not None and SPEC.loader is not None
    matrix_check = importlib.util.module_from_spec(SPEC)
    sys.modules[SPEC.name] = matrix_check
    SPEC.loader.exec_module(matrix_check)


@unittest.skipUnless(
    matrix_check is not None,
    "the Python target-matrix validator has migrated to Flash",
)
class FlashOSTargetMatrixContractTests(unittest.TestCase):
    def test_tracked_sources_match_the_target_matrix(self) -> None:
        matrix_check.validate(matrix_check.load_target_matrix())

    def test_withheld_capability_cannot_enter_a_case(self) -> None:
        document = copy.deepcopy(matrix_check.load_toml(matrix_check.MATRIX_PATH))
        document["case"][0]["capabilities"].append("signals")
        parsed = __import__("flashos_target_matrix").parse_target_matrix(document)

        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            matrix_check.validate(parsed)

    def test_every_advertised_operation_requires_exactly_one_owner(self) -> None:
        document = copy.deepcopy(matrix_check.load_toml(matrix_check.MATRIX_PATH))
        document["case"][0]["operation_ids"].remove("cwd-startup-read")
        parsed = __import__("flashos_target_matrix").parse_target_matrix(document)

        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            matrix_check.validate(parsed)


if __name__ == "__main__":
    unittest.main()
