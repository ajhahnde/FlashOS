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
        automation.validate(inventory)
        migrated, pending = automation.validate_expanded_contract()
        self.assertEqual(migrated, 60)
        self.assertEqual(migrated + len(pending), 60)
        self.assertEqual(pending, ())
        self.assertEqual(inventory.dispositions["reviewed-exception"], 8)
        self.assertEqual(inventory.dispositions["bootstrap-adapter"], 1)
        self.assertEqual(inventory.dispositions["bootstrap-entrypoint"], 1)
        self.assertEqual(inventory.dispositions["independent-validation"], 2)

    def test_independent_checker_boundary_is_explicit(self) -> None:
        self.assertEqual(
            set(automation.INDEPENDENT_VALIDATION),
            {
                "ci/check_public_automation.py",
                "ci/tests/test_check_public_automation.py",
            },
        )
        self.assertEqual(
            Counter(map(automation.disposition, automation.INDEPENDENT_VALIDATION)),
            Counter({"independent-validation": 2}),
        )

    def test_unknown_script_is_not_silently_excepted(self) -> None:
        self.assertIsNone(automation.disposition("future/tool.sh"))

    def test_only_declared_flash_roots_are_native(self) -> None:
        self.assertEqual(
            Counter(map(automation.disposition, automation.NATIVE_FLASH)),
            Counter({"native-flash": 4}),
        )
        self.assertEqual(
            Counter(map(automation.disposition, automation.PUBLIC_EXAMPLES)),
            Counter({"public-example": 4}),
        )

    def test_documentation_inventory_navigation_and_links_are_complete(self) -> None:
        automation.check_documentation()
        contract = automation.load_documentation_contract()
        self.assertEqual(contract["schema"], 1)
        self.assertEqual(len(contract["documents"]), 45)
        self.assertEqual(
            {entry["path"] for entry in contract["examples"]},
            automation.PUBLIC_EXAMPLES,
        )

    def test_documentation_heading_levels_ignore_fenced_examples(self) -> None:
        source = "# Guide\n\n## Task\n\n```text\n### Not a heading\n```\n"
        self.assertEqual(automation.markdown_heading_levels(source), (1, 2))

    def test_documentation_forbidden_markers_are_detected(self) -> None:
        generated_marker = "AI" + "-generated"
        private_path = "ajhahn" + "de/governance/policy.md"
        source = f"{private_path}\n{generated_marker}\n"
        self.assertEqual(
            set(automation.documentation_forbidden_markers(source)),
            {private_path.removesuffix("policy.md"), generated_marker},
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
            automation.disposition(
                "components/flash/tests/v2-foundation/v2/source.fsh"
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

    def test_bootstrap_workflow_checkouts_preserve_primary_history(self) -> None:
        automation.check_bootstrap_workflow_checkouts()
        with tempfile.TemporaryDirectory(prefix="flash-workflow-history-") as raw:
            root = Path(raw)
            workflows = root / ".github/workflows"
            workflows.mkdir(parents=True)
            (workflows / "probe.yml").write_text(
                "jobs:\n"
                "  probe:\n"
                "    steps:\n"
                "      - name: Checkout current tooling\n"
                "        uses: actions/checkout@pinned\n"
                "        with:\n"
                "          fetch-depth: 0\n"
                "      - name: Checkout isolated tag source\n"
                "        uses: actions/checkout@pinned\n"
                "        with:\n"
                "          path: dist/tag-source\n"
                "          fetch-depth: 1\n"
                "      - name: Bootstrap\n"
                "        run: make flash-bootstrap\n",
                encoding="utf-8",
            )
            automation.check_bootstrap_workflow_checkouts(root)

            (workflows / "probe.yml").write_text(
                "jobs:\n"
                "  probe:\n"
                "    steps:\n"
                "      - name: Checkout current tooling\n"
                "        uses: actions/checkout@pinned\n"
                "      - name: Checkout isolated tag source\n"
                "        uses: actions/checkout@pinned\n"
                "        with:\n"
                "          path: dist/tag-source\n"
                "          fetch-depth: 0\n"
                "      - name: Bootstrap\n"
                "        run: make flash-bootstrap\n",
                encoding="utf-8",
            )
            stderr = io.StringIO()
            with redirect_stderr(stderr), self.assertRaises(SystemExit):
                automation.check_bootstrap_workflow_checkouts(root)
            self.assertIn(
                "primary checkout must fetch full history", stderr.getvalue()
            )

            (workflows / "probe.yml").write_text(
                "jobs:\n"
                "  probe:\n"
                "    steps:\n"
                "      - name: Checkout isolated tag source\n"
                "        uses: actions/checkout@pinned\n"
                "        with:\n"
                "          path: dist/tag-source\n"
                "          fetch-depth: 0\n"
                "      - name: Bootstrap\n"
                "        run: make flash-bootstrap\n",
                encoding="utf-8",
            )
            stderr = io.StringIO()
            with redirect_stderr(stderr), self.assertRaises(SystemExit):
                automation.check_bootstrap_workflow_checkouts(root)
            self.assertIn(
                "must have exactly one primary checkout", stderr.getvalue()
            )

            (workflows / "probe.yml").write_text(
                "jobs:\n"
                "  probe:\n"
                "    steps:\n"
                "      - uses: actions/checkout@pinned\n"
                "        with:\n"
                "          fetch-depth: 0\n"
                "      - name: Bootstrap\n"
                "        run: make flash-bootstrap\n"
                "      - uses: actions/checkout@pinned\n",
                encoding="utf-8",
            )
            stderr = io.StringIO()
            with redirect_stderr(stderr), self.assertRaises(SystemExit):
                automation.check_bootstrap_workflow_checkouts(root)
            self.assertIn(
                "must have exactly one primary checkout", stderr.getvalue()
            )

    def test_qemu_consumer_acquires_explicit_immutable_automation(self) -> None:
        workflow = (ROOT / ".github/workflows/_image.yml").read_text(
            encoding="utf-8"
        )
        _, consumer = workflow.split("  boot:\n", 1)
        runtime = (
            "${{ github.workspace }}/build/flash-bootstrap/"
            f"{automation.BASELINE_COMMIT}/fsh"
        )
        self.assertIn(f"FLASH_AUTOMATION_RUNTIME: {runtime}", consumer)
        tools = (
            "${{ github.workspace }}/build/flash-automation-tools/"
            "linux-x86_64/bin"
        )
        for variable, executable in (
            ("FLASH_AUTOMATION_TAPLO", "taplo"),
            ("FLASH_AUTOMATION_JQ", "jq"),
            ("FLASH_AUTOMATION_RG", "rg"),
        ):
            self.assertIn(f"{variable}: {tools}/{executable}", consumer)
        self.assertIn("fetch-depth: 0", consumer)
        self.assertIn(
            "- name: Acquire the immutable Flash 1.0 automation runtime",
            consumer,
        )
        self.assertIn("run: make flash-bootstrap", consumer)
        self.assertIn(
            "- name: Acquire the pinned public automation tools",
            consumer,
        )
        self.assertIn("run: make flash-automation-tools", consumer)
        self.assertEqual(
            consumer.count('--automation-runtime "$FLASH_AUTOMATION_RUNTIME"'),
            2,
        )

    def test_canonical_setup_entrypoint_is_complete_and_idempotent(self) -> None:
        self.assertEqual(
            automation.disposition("setup.sh"), "bootstrap-entrypoint"
        )
        automation.check_setup_entrypoint()
        automation.check_setup_documentation()

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
