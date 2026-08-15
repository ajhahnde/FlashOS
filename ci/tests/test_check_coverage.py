from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

CI_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CI_ROOT))

import check_coverage  # noqa: E402


class CoverageContractTests(unittest.TestCase):
    def validate(self, source_files: list[Path], count: int = 1) -> str:
        records = []
        for source_file in source_files:
            records.extend((f"SF:{source_file}", f"DA:1,{count}", "end_of_record"))
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "flash.lcov"
            report.write_text("\n".join(records) + "\n")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                check_coverage.validate(report)
            return output.getvalue()

    def member_roots(self) -> list[Path]:
        return [
            check_coverage.ROOT / member / "src/lib.rs"
            for member in check_coverage.workspace_members()
        ]

    def test_accepts_one_executed_source_from_every_workspace_member(self) -> None:
        output = self.validate(self.member_roots())
        self.assertIn("coverage contract: ok", output)
        self.assertIn("workspace members: 7", output)

    def test_rejects_a_report_that_omits_a_workspace_member(self) -> None:
        with self.assertRaisesRegex(SystemExit, "omitted Flash workspace members"):
            self.validate(self.member_roots()[:-1])

    def test_rejects_a_report_without_executed_first_party_lines(self) -> None:
        with self.assertRaisesRegex(SystemExit, "no executed first-party Rust lines"):
            self.validate(self.member_roots(), count=0)


if __name__ == "__main__":
    unittest.main()
