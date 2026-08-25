from __future__ import annotations

import copy
import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/check_flash_conformance.py"
conformance_check = None
if SCRIPT.is_file():
    SPEC = importlib.util.spec_from_file_location("check_flash_conformance", SCRIPT)
    assert SPEC is not None and SPEC.loader is not None
    conformance_check = importlib.util.module_from_spec(SPEC)
    sys.modules[SPEC.name] = conformance_check
    SPEC.loader.exec_module(conformance_check)


@unittest.skipUnless(
    conformance_check is not None,
    "the Python conformance validator has migrated to Flash",
)
class FlashConformanceTests(unittest.TestCase):
    def test_tracked_inventory_matches_executable_owners_and_ci(self) -> None:
        conformance_check.validate(conformance_check.load_inventory())

    def test_a_required_family_cannot_be_removed(self) -> None:
        document = copy.deepcopy(conformance_check.load_inventory())
        document["family"].pop()
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            conformance_check.validate(document)

    def test_the_v1_contract_cannot_return_to_draft_status(self) -> None:
        document = copy.deepcopy(conformance_check.load_inventory())
        document["contract_status"] = "draft"
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            conformance_check.validate(document)

    def test_a_missing_or_ignored_test_cannot_own_conformance(self) -> None:
        document = copy.deepcopy(conformance_check.load_inventory())
        document["family"][0]["tests"][0] = (
            "crates/flash-syntax/tests/parser.rs::not_a_real_test"
        )
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            conformance_check.validate(document)

    def test_the_v1_config_setting_surface_cannot_expand_silently(self) -> None:
        document = copy.deepcopy(conformance_check.load_inventory())
        document["config_settings"].append("theme")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            conformance_check.validate(document)

    def test_every_audited_runtime_refusal_needs_a_classified_reason(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "components/flash/crates/flash-runtime/src"
            source.mkdir(parents=True)
            (source / "eval.rs").write_text(
                "fn gap() {\n"
                "    let _ = RuntimeErrorKind::Unsupported {\n"
                '        feature: "a hidden gap",\n'
                "    };\n"
                "}\n"
            )
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                conformance_check.validate_boundaries(root)

    def test_classified_runtime_refusals_and_invariants_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "components/flash/crates/flash-runtime/src"
            source.mkdir(parents=True)
            (source / "eval.rs").write_text(
                "fn refusal() {\n"
                "    // flash-v1-boundary(embedding-refusal): "
                "This API cannot run jobs.\n"
                "    let _ = RuntimeErrorKind::Unsupported {\n"
                '        feature: "effectful evaluation",\n'
                "    };\n"
                "}\n"
            )
            conformance_check.validate_boundaries(root)


if __name__ == "__main__":
    unittest.main()
