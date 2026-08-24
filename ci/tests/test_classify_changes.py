import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "classify_changes", ROOT / "ci/classify_changes.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ClassificationTests(unittest.TestCase):
    def test_documentation_policy_and_host_tools_use_the_fast_lane(self):
        result = MODULE.classify(
            [
                "docs/verification.md",
                "CHANGELOG.md",
                ".github/SECURITY.md",
                ".github/dependabot.yml",
                "tools/flashos/cli.py",
                "flashos.zsh",
                "components/flash/docs/reference.md",
            ]
        )
        self.assertEqual(result.lane, "fast")
        self.assertFalse(result.image_required)
        self.assertFalse(result.target_required)
        self.assertTrue(result.security_required)

    def test_source_adjacent_non_markdown_is_product_affecting(self):
        result = MODULE.classify(["components/flash/docs/generated.json"])
        self.assertEqual(result.lane, "product")
        self.assertTrue(result.image_required)

    def test_target_source_is_called_out_inside_the_product_lane(self):
        result = MODULE.classify(["components/flash/crates/flash-cli/src/main.rs"])
        self.assertEqual(result.lane, "product")
        self.assertTrue(result.image_required)
        self.assertTrue(result.target_required)

    def test_ci_and_unknown_paths_fail_closed(self):
        for path in (
            ".github/workflows/ci.yml",
            "ci/classify_changes.py",
            "future/subsystem/input.bin",
        ):
            with self.subTest(path=path):
                result = MODULE.classify([path])
                self.assertEqual(result.lane, "product")
                self.assertTrue(result.image_required)

    def test_empty_input_fails_closed_for_manual_dispatch(self):
        result = MODULE.classify([])
        self.assertEqual(result.lane, "product")
        self.assertTrue(result.image_required)
        self.assertTrue(result.target_required)

    def test_mixed_fast_and_product_paths_select_product(self):
        result = MODULE.classify(
            ["docs/verification.md", "recipes/core/kernel/recipe.toml"]
        )
        self.assertEqual(result.lane, "product")
        self.assertTrue(result.image_required)

    def test_dependency_manifests_select_security_policy(self):
        for path in (
            "Cargo.lock",
            "components/flash/crates/flash-cli/Cargo.toml",
            ".github/workflows/security.yml",
        ):
            with self.subTest(path=path):
                self.assertTrue(MODULE.classify([path]).security_required)
        self.assertFalse(MODULE.classify(["docs/verification.md"]).security_required)

    def test_paths_are_normalised_deduplicated_and_sorted(self):
        result = MODULE.classify(["./docs/z.md", "docs/a.md", "docs/a.md"])
        self.assertEqual(result.paths, ("docs/a.md", "docs/z.md"))

    def test_invalid_paths_are_rejected(self):
        for path in ("../outside", "/absolute"):
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    MODULE.classify([path])

    def test_cli_writes_machine_readable_github_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            summary = Path(directory) / "summary"
            with mock.patch.dict(
                os.environ,
                {"GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)},
                clear=False,
            ):
                self.assertEqual(MODULE.main(["docs/verification.md"]), 0)
            values = dict(
                line.split("=", 1) for line in output.read_text().splitlines()
            )
            self.assertEqual(values["lane"], "fast")
            self.assertEqual(values["image_required"], "false")
            self.assertEqual(json.loads(values["classification"])["schema"], 1)
            self.assertIn("lane: `fast`", summary.read_text())


if __name__ == "__main__":
    unittest.main()
