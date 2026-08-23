from __future__ import annotations

import copy
import importlib.util
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/flashos_runtime_fixtures.py"
SPEC = importlib.util.spec_from_file_location("flashos_runtime_fixtures", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
runtime_fixtures = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runtime_fixtures
SPEC.loader.exec_module(runtime_fixtures)


class FlashOSRuntimeFixtureTests(unittest.TestCase):
    def test_tracked_suite_is_valid_and_renderable_for_real_systems(self) -> None:
        suite = runtime_fixtures.load_fixture_suite()

        self.assertEqual(suite.consumers, ("qemu", "real-system"))
        rendered = runtime_fixtures.render_real_system_instructions(suite)
        for fixture in suite.fixtures:
            self.assertIn(fixture.identifier, rendered)
        self.assertIn("Enter: pwz<Backspace>d", rendered)

    def test_interactions_must_fit_the_target_serial_boundary(self) -> None:
        document = copy.deepcopy(
            runtime_fixtures.load_toml(runtime_fixtures.FIXTURE_PATH)
        )
        document["fixture"][0]["step"][0]["input_hex"] = "61" * 16

        with self.assertRaises(runtime_fixtures.FixtureContractError):
            runtime_fixtures.parse_fixture_suite(document)

    def test_fixture_ids_must_be_unique(self) -> None:
        document = copy.deepcopy(
            runtime_fixtures.load_toml(runtime_fixtures.FIXTURE_PATH)
        )
        document["fixture"][1]["id"] = document["fixture"][0]["id"]

        with self.assertRaises(runtime_fixtures.FixtureContractError):
            runtime_fixtures.parse_fixture_suite(document)

    def test_waited_jobs_leave_a_real_system_observation_window(self) -> None:
        suite = runtime_fixtures.load_fixture_suite()
        fixtures = {fixture.identifier: fixture for fixture in suite.fixtures}
        patterns = {
            "background-child": rb"\^sleep ([0-9]+)&",
            "background-supervisor": rb"\^sleep ([0-9]+)&&true&",
        }

        for identifier, pattern in patterns.items():
            fixture = fixtures[identifier]
            match = re.fullmatch(pattern, fixture.steps[0].payload)
            self.assertIsNotNone(match)
            assert match is not None
            self.assertGreaterEqual(int(match.group(1)), 9)
            self.assertTrue(fixture.steps[1].payload.startswith(b"wait %"))


if __name__ == "__main__":
    unittest.main()
