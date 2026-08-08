from __future__ import annotations

import json
import unittest
from unittest.mock import patch

from support import TOOLS_DIR, load_script

commit = load_script("flashos_commit_tested", "flashos-commit.py")


class CommitPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.context = json.loads(
            (TOOLS_DIR / "contexts/flashos-commit-context.json").read_text(
                encoding="utf-8"
            )
        )
        cls.policy = commit.validate_project_context(cls.context)

    def test_context_defines_the_current_house_style(self) -> None:
        self.assertEqual(self.context["schema_version"], 2)
        self.assertTrue(self.policy.conventional_scopes_allowed)
        self.assertEqual(self.policy.component_prefixes, ())
        self.assertIn("type(flash):", commit.SYSTEM_INSTRUCTION)
        self.assertIn("type(tools):", commit.SYSTEM_INSTRUCTION)

    def test_accepts_scoped_and_unscoped_house_style(self) -> None:
        self.assertEqual(
            commit.validate_commit_subject(
                "feat(tools): add repository question helper",
                self.policy,
            ),
            "feat(tools): add repository question helper",
        )
        self.assertEqual(
            commit.validate_commit_subject("docs: clarify setup", self.policy),
            "docs: clarify setup",
        )

    def test_structured_subject_response_is_exact(self) -> None:
        self.assertEqual(
            commit.parse_subject_response(
                '{"subject":"fix(tools): validate staged subjects"}'
            ),
            "fix(tools): validate staged subjects",
        )
        with self.assertRaisesRegex(commit.FlashOSError, "exactly 'subject'"):
            commit.parse_subject_response(
                '{"subject":"fix: valid","explanation":"extra"}'
            )

    def test_rejects_historical_or_inconsistent_styles(self) -> None:
        invalid = (
            "Add repository question helper",
            "Flash: add repository question helper",
            "feat(Tools): add repository question helper",
            "feat(tools): add repository question helper.",
            "feat(tools): add helper\nbody",
            "feat(tools): harden Gemini helpers",
        )
        for subject in invalid:
            with self.subTest(subject=subject):
                with self.assertRaises(commit.FlashOSError):
                    commit.validate_commit_subject(subject, self.policy)


class CommitOptionTests(unittest.TestCase):
    def test_help_examples_use_the_tools_house_scope(self) -> None:
        help_text = commit.usage(TOOLS_DIR)
        self.assertIn('feat(tools): add commit helper', help_text)
        self.assertIn('chore(tools): maintain repository helpers', help_text)

    def test_manual_and_generated_messages_are_exclusive(self) -> None:
        with self.assertRaisesRegex(commit.FlashOSError, "cannot be combined"):
            commit.parse_options(["--generate", "feat: change"])

    def test_long_options_are_supported(self) -> None:
        options = commit.parse_options(["--add-all", "--generate", "--push"])
        self.assertTrue(options.add_all)
        self.assertTrue(options.generate)
        self.assertTrue(options.push)


class StagedFingerprintTests(unittest.TestCase):
    def test_fingerprint_covers_status_and_diff(self) -> None:
        with patch.object(
            commit,
            "git_bytes",
            return_value=b"M\0tools/file.py\0",
        ):
            first = commit.staged_fingerprint(object(), b"diff-a")
            second = commit.staged_fingerprint(object(), b"diff-b")
        self.assertNotEqual(first, second)


class GenerationTests(unittest.TestCase):
    def test_generated_subject_uses_house_style_and_staged_fingerprint(self) -> None:
        response = {
            "status": "completed",
            "steps": [
                {
                    "type": "model_output",
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                '{"subject":"feat(tools): harden repository '
                                'helpers"}'
                            ),
                        }
                    ],
                }
            ],
        }
        with (
            patch.object(commit, "ensure_staged_changes"),
            patch.object(commit, "staged_diff", return_value=b"diff"),
            patch.object(commit, "staged_fingerprint", return_value="fingerprint"),
            patch.object(commit, "git_output", return_value="M\ttools/file.py\n"),
            patch.object(commit, "call_gemini", return_value=response),
            patch.object(commit, "api_attempts", return_value=1),
            patch.object(commit, "max_output_tokens", return_value=128),
        ):
            generated = commit.generate_commit_message(object(), TOOLS_DIR)

        self.assertEqual(
            generated.subject,
            "feat(tools): harden repository helpers",
        )
        self.assertEqual(generated.staged_fingerprint, "fingerprint")


if __name__ == "__main__":
    unittest.main()
