from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/check_flashos_platform.py"
SPEC = importlib.util.spec_from_file_location("check_flashos_platform", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
platform_check = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = platform_check
SPEC.loader.exec_module(platform_check)


class FlashOSPlatformContractTests(unittest.TestCase):
    def test_tracked_sources_match_the_platform_baseline(self) -> None:
        baseline = platform_check.load_toml(platform_check.BASELINE_PATH)
        platform_check.validate_source_contract(baseline)

    def test_rustc_version_output_keeps_release_and_llvm_identity(self) -> None:
        output = """rustc 1.98.0-dev
binary: rustc
commit-hash: unknown
release: 1.98.0-dev
LLVM version: 21.1.2
"""
        self.assertEqual(
            platform_check.parse_version_output(output),
            {
                "binary": "rustc",
                "commit-hash": "unknown",
                "release": "1.98.0-dev",
                "LLVM version": "21.1.2",
            },
        )

    def test_rustc_cfg_output_preserves_target_identity(self) -> None:
        output = """target_arch="x86_64"
target_endian="little"
target_env="relibc"
target_family="unix"
target_os="redox"
target_pointer_width="64"
"""
        self.assertEqual(
            platform_check.parse_cfg_output(output),
            {
                "target_arch": "x86_64",
                "target_endian": "little",
                "target_env": "relibc",
                "target_family": "unix",
                "target_os": "redox",
                "target_pointer_width": "64",
            },
        )


if __name__ == "__main__":
    unittest.main()
