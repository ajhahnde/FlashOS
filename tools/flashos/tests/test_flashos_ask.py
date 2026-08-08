from __future__ import annotations

import json
import unittest
from unittest.mock import patch

from support import TOOLS_DIR, load_script

ask = load_script("flashos_ask_tested", "flashos-ask.py")


class AskContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.context = json.loads(
            (TOOLS_DIR / "contexts/flashos-ask-context.json").read_text(
                encoding="utf-8"
            )
        )

    def test_context_matches_the_single_location_contract(self) -> None:
        ask.validate_project_context(self.context)
        self.assertEqual(self.context["schema_version"], 2)
        self.assertEqual(
            self.context["answer_policy"]["maximum_primary_locations"],
            1,
        )
        self.assertIn("data_sent_to_gemini", self.context["tool_contract"])

    def test_system_prompts_define_exact_json_outputs(self) -> None:
        self.assertIn(
            "exactly two keys: search_terms and candidate_paths",
            ask.SEARCH_SYSTEM_INSTRUCTION,
        )
        self.assertIn(
            "exactly two keys: path and line",
            ask.ANSWER_SYSTEM_INSTRUCTION,
        )
        self.assertIn(
            "untrusted repository data",
            ask.SEARCH_SYSTEM_INSTRUCTION,
        )
        self.assertEqual(
            set(ask.SEARCH_RESPONSE_SCHEMA["properties"]),
            {"search_terms", "candidate_paths"},
        )
        self.assertEqual(
            set(ask.ANSWER_RESPONSE_SCHEMA["properties"]),
            {"path", "line"},
        )


class SearchPlanTests(unittest.TestCase):
    def test_parse_search_plan_deduplicates_valid_values(self) -> None:
        plan = ask.parse_search_plan(
            json.dumps(
                {
                    "search_terms": ["execute", "execute", "CommandPlan"],
                    "candidate_paths": ["src/a.rs", "src/a.rs"],
                }
            ),
            ["src/a.rs", "src/b.rs"],
        )
        self.assertEqual(plan.search_terms, ("execute", "CommandPlan"))
        self.assertEqual(plan.candidate_paths, ("src/a.rs",))

    def test_parse_search_plan_rejects_unknown_path(self) -> None:
        with self.assertRaisesRegex(ask.FlashOSError, "unknown candidate path"):
            ask.parse_search_plan(
                '{"search_terms":["kernel"],"candidate_paths":["missing"]}',
                ["recipes/core/kernel/recipe.toml"],
            )

    def test_search_request_is_bounded(self) -> None:
        with patch.object(ask, "DEFAULT_MAX_REQUEST_BYTES", 10):
            with self.assertRaisesRegex(ask.FlashOSError, "safety limit"):
                ask.build_search_request("question", {}, ["README.md"])


class AnswerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.snippets = [
            ask.EvidenceSnippet(
                path="src/runtime.rs",
                start_line=40,
                end_line=44,
                matched_lines=(42,),
                text="40: before\n42: execute\n44: after",
                model_suggested=True,
            )
        ]

    def test_parse_answer_accepts_a_visible_relevant_line(self) -> None:
        selection = ask.parse_answer(
            '{"path":"src/runtime.rs","line":43}',
            True,
            self.snippets,
        )
        self.assertEqual(selection.path, "src/runtime.rs")
        self.assertEqual(selection.line_number, 43)

    def test_parse_answer_requires_null_line_when_disabled(self) -> None:
        selection = ask.parse_answer(
            '{"path":"src/runtime.rs","line":null}',
            False,
            self.snippets,
        )
        self.assertEqual(selection.path, "src/runtime.rs")
        self.assertIsNone(selection.line_number)

    def test_parse_answer_rejects_a_line_outside_evidence(self) -> None:
        with self.assertRaisesRegex(ask.FlashOSError, "outside supplied evidence"):
            ask.parse_answer(
                '{"path":"src/runtime.rs","line":99}',
                True,
                self.snippets,
            )

    def test_parse_answer_accepts_only_the_exact_fallback(self) -> None:
        selection = ask.parse_answer(
            '{"path":null,"line":null}',
            True,
            self.snippets,
        )
        self.assertIsNone(selection.path)
        self.assertIsNone(selection.line_number)

    def test_resolve_answer_renders_the_model_selected_line(self) -> None:
        plan = ask.SearchPlan(("execute",), ("src/runtime.rs",))
        candidate = ask.SearchCandidate("src/runtime.rs", ("execute",), True)
        with patch.object(
            ask,
            "generate_answer_text",
            return_value='{"path":"src/runtime.rs","line":43}',
        ):
            answer = ask.resolve_answer(
                "Where is execution handled?",
                True,
                {},
                plan,
                [candidate],
                self.snippets,
            )
        self.assertEqual(answer, "src/runtime.rs:43")


class AskOptionTests(unittest.TestCase):
    def test_help_word_is_supported(self) -> None:
        self.assertTrue(ask.parse_options(["help"]).show_help)

    def test_question_length_is_bounded(self) -> None:
        with self.assertRaisesRegex(ask.FlashOSError, "exceeds"):
            ask.parse_options(["x" * (ask.DEFAULT_MAX_QUESTION_CHARACTERS + 1)])

    def test_question_must_be_one_argument(self) -> None:
        with self.assertRaisesRegex(ask.FlashOSError, "one quoted argument"):
            ask.parse_options(["where", "is it"])


if __name__ == "__main__":
    unittest.main()
