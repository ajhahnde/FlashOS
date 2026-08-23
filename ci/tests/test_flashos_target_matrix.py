from __future__ import annotations

import copy
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/flashos_target_matrix.py"
SPEC = importlib.util.spec_from_file_location("flashos_target_matrix", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
target_matrix = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = target_matrix
SPEC.loader.exec_module(target_matrix)


class FlashOSTargetMatrixTests(unittest.TestCase):
    def test_tracked_matrix_is_valid_and_renderable(self) -> None:
        matrix = target_matrix.load_target_matrix()

        self.assertEqual(matrix.consumers, ("qemu", "operator-observed-target"))
        rendered = target_matrix.render_operator_checklist(matrix)
        for case in matrix.cases:
            self.assertIn(case.identifier, rendered)
        self.assertIn("<Ctrl-C>", rendered)
        self.assertIn("<Tab>", rendered)
        self.assertIn("<Up>", rendered)
        self.assertIn("á界", rendered)
        self.assertIn("     | echo config-created", rendered)

    def test_case_ids_must_be_unique(self) -> None:
        document = copy.deepcopy(target_matrix.load_toml(target_matrix.MATRIX_PATH))
        document["case"][1]["id"] = document["case"][0]["id"]

        with self.assertRaises(target_matrix.TargetMatrixContractError):
            target_matrix.parse_target_matrix(document)

    def test_line_steps_require_a_rendered_row(self) -> None:
        document = copy.deepcopy(target_matrix.load_toml(target_matrix.MATRIX_PATH))
        del document["case"][0]["step"][0]["rendered"]

        with self.assertRaises(target_matrix.TargetMatrixContractError):
            target_matrix.parse_target_matrix(document)

    def test_script_transport_stays_within_the_uart_interaction_limit(self) -> None:
        source = "echo 界\n".encode()
        chunks = target_matrix.script_transport_chunks(source, 7)

        self.assertEqual(b"".join(chunks), source)
        self.assertTrue(all(len(chunk) <= 7 for chunk in chunks))

    def test_external_output_markers_remain_visible_after_prompt_redraw(self) -> None:
        matrix = target_matrix.load_target_matrix()
        argv_case = next(
            case
            for case in matrix.cases
            if case.identifier == "argv-environment-pipelines-and-redirections"
        )
        argv_step = argv_case.steps[0]
        glob_case = next(
            case
            for case in matrix.cases
            if case.identifier == "directory-glob-and-grammar-completion"
        )
        glob_step = glob_case.steps[0]

        self.assertIn(b"^printf '<%s>\\n' 'argv ok'", argv_step.payload)
        self.assertIn(b"^printf 'two\\n' >> matrix.txt", argv_step.payload)
        self.assertIn(b"<argv ok>\r\r\n", argv_step.expected)
        self.assertIn(b"onetwo\r\r\n", argv_step.expected)
        self.assertIn(b"^echo glob-done", glob_step.payload)
        self.assertIn(b"glob-done\r\r\n", glob_step.expected)


if __name__ == "__main__":
    unittest.main()
