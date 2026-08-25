from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from collections import Counter
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/check_public_automation.py"
SPEC = importlib.util.spec_from_file_location("check_public_automation", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
automation = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = automation
SPEC.loader.exec_module(automation)


class PublicAutomationTests(unittest.TestCase):
    def write_fake_runtime(
        self, directory: Path, body: str, *, executable: bool = True
    ) -> Path:
        runtime = directory / "fsh"
        runtime.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        runtime.chmod(0o755 if executable else 0o644)
        return runtime

    def assert_runtime_rejected(self, runtime: Path, expected: str) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(SystemExit):
            automation.validate_runtime_binary(runtime, label="test runtime")
        self.assertIn(expected, stderr.getvalue())

    def test_repository_inventory_is_complete(self) -> None:
        inventory = automation.scan()
        automation.validate(inventory, allow_incomplete=True)
        migrated, pending = automation.validate_expanded_contract(allow_incomplete=True)
        self.assertEqual(migrated, 25)
        self.assertEqual(migrated + len(pending), 60)
        self.assertEqual(inventory.dispositions["reviewed-exception"], 8)
        self.assertEqual(inventory.dispositions["bootstrap-adapter"], 1)

    def test_expanded_gate_stays_red_until_real_migrations_exist(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(SystemExit):
            automation.validate(automation.scan())
        self.assertRegex(
            stderr.getvalue(),
            r"expanded standalone inventory drifted|migration keeps both|"
            r"expanded migration is incomplete",
        )

    def test_unknown_script_is_not_silently_excepted(self) -> None:
        self.assertIsNone(automation.disposition("future/tool.sh"))

    def test_only_declared_flash_roots_are_native(self) -> None:
        self.assertEqual(
            Counter(map(automation.disposition, automation.NATIVE_FLASH)),
            Counter({"native-flash": 4}),
        )

    def test_shared_modules_and_external_tools_are_exact(self) -> None:
        self.assertEqual(
            Counter(map(automation.disposition, automation.SHARED_FLASH_MODULES)),
            Counter({"shared-flash-module": 5}),
        )
        self.assertEqual(automation.TOOL_CONTRACT, automation.EXPECTED_TOOL_CONTRACT)
        self.assertIn("def fail(", automation.BANNED_EXTERNAL_POLICY_MARKERS)

    def test_fixture_and_host_boundaries_are_distinct(self) -> None:
        self.assertEqual(
            automation.disposition(
                "components/flash/tests/golden/grammar/complete/commands.fsh"
            ),
            "generated-or-test-data",
        )
        self.assertEqual(
            automation.disposition("ci/check_profile.py"),
            "migration-pending",
        )

    def test_exact_matrix_has_no_ceiling_below_all_60_candidates(self) -> None:
        self.assertEqual(len(automation.MIGRATION_BASELINE), 60)
        self.assertEqual(len(automation.RETAINED_BASELINE), 8)
        self.assertEqual(
            automation.MIGRATION_BASELINE | automation.RETAINED_BASELINE.keys(),
            automation.baseline_sources(),
        )
        self.assertEqual(automation.EXPANDED_CONTRACT["minimum_migrations"], 51)

    def test_build_entry_bootstrap_is_separate_and_narrow(self) -> None:
        self.assertEqual(automation.disposition("build.fsh"), "migrated-flash")
        self.assertEqual(
            automation.disposition("install-flash.sh"), "bootstrap-adapter"
        )
        installer = (ROOT / "install-flash.sh").read_text(encoding="utf-8")
        self.assertNotIn("build.fsh", installer)
        self.assertNotIn("make ", installer)
        automation.check_install_flash_adapter()

    def test_runtime_trust_probe_rejects_false_success_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flash-runtime-probes-") as raw:
            directory = Path(raw)
            self.assert_runtime_rejected(directory / "absent", "does not exist")

            runtime = self.write_fake_runtime(directory, "exit 0\n", executable=False)
            self.assert_runtime_rejected(runtime, "not executable")

            cases = (
                ("printf 'fsh 0.9.0\\n'\n", "version parity differs"),
                ("exit 9\n", "version parity differs"),
                (
                    'if [ "$1" = --version ]; then '
                    "printf 'fsh 1.0.0\\n'; fi\nexit 0\n",
                    "accepted or corrupted a known invalid source",
                ),
                ("printf 'fsh 1.0.0\\ncorrupt\\n'\n", "version parity differs"),
            )
            for body, expected in cases:
                with self.subTest(expected=expected):
                    runtime = self.write_fake_runtime(directory, body)
                    self.assert_runtime_rejected(runtime, expected)

            overflow = directory / "overflow"
            overflow_count = automation.MAX_RUNTIME_CAPTURE + 1
            overflow.write_text(
                f"#!{sys.executable}\nprint('x' * {overflow_count})\n",
                encoding="utf-8",
            )
            overflow.chmod(0o755)
            self.assert_runtime_rejected(overflow, "capture limit")

    def test_bootstrap_manifest_binds_identity_and_binary_digest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flash-bootstrap-manifest-") as raw:
            directory = Path(raw)
            runtime = self.write_fake_runtime(
                directory,
                'if [ "$1" = --version ]; then\n'
                "  printf 'fsh 1.0.0\\n'\n"
                "  exit 0\n"
                "fi\n"
                "printf 'comparison operators are non-associative\\n' >&2\n"
                "exit 1\n",
            )
            manifest = {
                "schema": 1,
                "source_commit": automation.BASELINE_COMMIT,
                "source_tree": automation.BASELINE_TREE,
                "rust_toolchain": automation.BASELINE_RUST_TOOLCHAIN,
                "version": automation.FLASH_V1_VERSION,
                "binary_sha256": automation.sha256_file(runtime),
            }
            (directory / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            self.assertEqual(
                automation.validate_bootstrap_runtime(runtime), runtime.resolve()
            )

            manifest["binary_sha256"] = "0" * 64
            (directory / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            stderr = io.StringIO()
            with redirect_stderr(stderr), self.assertRaises(SystemExit):
                automation.validate_bootstrap_runtime(runtime)
            self.assertIn("binary digest differs", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
