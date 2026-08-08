from __future__ import annotations

import io
import json
import unittest
from datetime import UTC, datetime
from unittest.mock import patch

from support import load_script

ai = load_script("flashos_ai_tested", "flashos_ai.py")


class EnvironmentTests(unittest.TestCase):
    def test_integer_environment_enforces_bounds(self) -> None:
        with patch.dict("os.environ", {"FLASHOS_TEST_INTEGER": "4"}):
            self.assertEqual(
                ai.integer_environment(
                    "FLASHOS_TEST_INTEGER",
                    1,
                    minimum=1,
                    maximum=5,
                ),
                4,
            )

    def test_integer_environment_rejects_invalid_input(self) -> None:
        with patch.dict("os.environ", {"FLASHOS_TEST_INTEGER": "many"}):
            with self.assertRaisesRegex(ai.FlashOSAIError, "must be an integer"):
                ai.integer_environment("FLASHOS_TEST_INTEGER", 1)


class RetryTests(unittest.TestCase):
    def test_retry_after_supports_seconds(self) -> None:
        self.assertEqual(ai._retry_after_seconds("2.5"), 2.5)

    def test_retry_after_supports_http_date(self) -> None:
        now = datetime(2026, 8, 8, 12, 0, tzinfo=UTC)
        self.assertEqual(
            ai._retry_after_seconds(
                "Sat, 08 Aug 2026 12:00:09 GMT",
                now=now,
            ),
            9.0,
        )

    def test_google_retry_info_is_bounded(self) -> None:
        body = json.dumps(
            {
                "error": {
                    "details": [
                        {
                            "@type": "type.googleapis.com/google.rpc.RetryInfo",
                            "retryDelay": "75s",
                        }
                    ]
                }
            }
        ).encode()
        self.assertEqual(ai._retry_delay(1, raw=body), 60.0)


class ResponseTests(unittest.TestCase):
    def test_request_payload_uses_structured_output_without_storage(self) -> None:
        schema = {
            "type": "object",
            "properties": {"answer": {"type": "string"}},
            "required": ["answer"],
        }
        payload = json.loads(
            ai._request_payload(
                "prompt",
                "instruction",
                ai.GeminiConfig(model="model", response_schema=schema),
            )
        )
        self.assertFalse(payload["store"])
        self.assertEqual(payload["response_format"]["schema"], schema)
        self.assertEqual(
            payload["response_format"]["mime_type"],
            "application/json",
        )

    def test_response_reader_enforces_the_byte_limit(self) -> None:
        with self.assertRaisesRegex(ai.FlashOSAIError, "exceeds 3 bytes"):
            ai._read_response_bytes(io.BytesIO(b"four"), 3)

    def test_interaction_text_extracts_completed_output(self) -> None:
        result = ai.interaction_text(
            {
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [{"type": "text", "text": "result"}],
                    }
                ],
            }
        )
        self.assertEqual(result, "result")

    def test_interaction_text_reports_incomplete_usage(self) -> None:
        with self.assertRaisesRegex(ai.FlashOSAIError, "output=64"):
            ai.interaction_text(
                {
                    "status": "incomplete",
                    "usage": {"total_output_tokens": 64},
                }
            )


if __name__ == "__main__":
    unittest.main()
