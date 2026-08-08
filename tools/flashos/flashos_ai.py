#!/usr/bin/env python3
"""Shared AI infrastructure for FlashOS command helpers."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any

GEMINI_INTERACTIONS_URL = (
    "https://generativelanguage.googleapis.com/v1/interactions"
)
RETRYABLE_HTTP_STATUSES = {429, 500, 502, 503, 504}
DEFAULT_MAX_RESPONSE_BYTES = 1_048_576

RetryNotice = Callable[[str], None]


class FlashOSAIError(Exception):
    """A user-facing failure in shared FlashOS AI infrastructure."""

    def __init__(self, message: str, *, exit_code: int = 1) -> None:
        super().__init__(message)
        self.exit_code = exit_code


@dataclass(frozen=True)
class GeminiConfig:
    """Configuration for one Gemini Interactions API request."""

    model: str
    attempts: int = 3
    timeout_seconds: float = 120.0
    max_output_tokens: int = 64
    max_response_bytes: int = DEFAULT_MAX_RESPONSE_BYTES
    response_schema: dict[str, Any] | None = None
    seed: int | None = 42
    thinking_level: str | None = "low"

    def validate(self) -> None:
        if not self.model:
            raise FlashOSAIError("Gemini model must not be empty")
        if self.attempts < 1 or self.attempts > 10:
            raise FlashOSAIError("Gemini API attempts must be between 1 and 10")
        if self.timeout_seconds <= 0:
            raise FlashOSAIError("Gemini timeout must be greater than zero")
        if self.max_output_tokens < 1:
            raise FlashOSAIError(
                "Gemini max_output_tokens must be a positive integer"
            )
        if self.max_response_bytes < 1:
            raise FlashOSAIError(
                "Gemini max_response_bytes must be a positive integer"
            )
        if self.response_schema is not None and not isinstance(
            self.response_schema, dict
        ):
            raise FlashOSAIError("Gemini response_schema must be an object")


def load_json_object(path: Path, *, label: str) -> dict[str, Any]:
    """Load a UTF-8 JSON file whose root value must be an object."""

    if not path.is_file():
        raise FlashOSAIError(f"{label} not found: {path}")
    if not os.access(path, os.R_OK):
        raise FlashOSAIError(f"{label} is not readable: {path}")

    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except json.JSONDecodeError as exc:
        raise FlashOSAIError(
            f"invalid {label} JSON at {path}:{exc.lineno}:{exc.colno}: {exc.msg}"
        ) from exc
    except OSError as exc:
        raise FlashOSAIError(f"unable to read {label}: {exc}") from exc

    if not isinstance(value, dict):
        raise FlashOSAIError(f"invalid {label}: the root value must be an object")
    return value


def integer_environment(
    name: str,
    default: int,
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    """Read and validate an integer-valued environment variable."""

    raw_value = os.environ.get(name) or str(default)
    try:
        value = int(raw_value, 10)
    except ValueError as exc:
        raise FlashOSAIError(f"{name} must be an integer") from exc

    if minimum is not None and value < minimum:
        if maximum is None:
            raise FlashOSAIError(f"{name} must be at least {minimum}")
        raise FlashOSAIError(
            f"{name} must be between {minimum} and {maximum}"
        )
    if maximum is not None and value > maximum:
        if minimum is None:
            raise FlashOSAIError(f"{name} must be at most {maximum}")
        raise FlashOSAIError(
            f"{name} must be between {minimum} and {maximum}"
        )
    return value


def _run_process(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError as exc:
        raise FlashOSAIError(f"unable to run {command[0]}: {exc}") from exc


def _keychain_account() -> str | None:
    account = os.environ.get("USER", "")
    if account:
        return account
    if shutil.which("id") is None:
        return None

    process = _run_process(["id", "-un"])
    if process.returncode != 0:
        return None
    account = process.stdout.strip()
    return account or None


def gemini_api_key() -> str:
    """Resolve the Gemini API key from the environment or macOS Keychain."""

    environment_key = os.environ.get("GEMINI_API_KEY")
    if environment_key:
        return environment_key

    if shutil.which("security") is not None:
        account = _keychain_account()
        if account:
            process = _run_process(
                [
                    "security",
                    "find-generic-password",
                    "-a",
                    account,
                    "-s",
                    "GEMINI_API_KEY",
                    "-w",
                ]
            )
            if process.returncode == 0 and process.stdout.strip():
                return process.stdout.strip()

    raise FlashOSAIError(
        "Gemini API key not found; set GEMINI_API_KEY or add it to "
        "the macOS keychain"
    )


def _http_error_message(exc: urllib.error.HTTPError, raw: bytes) -> str:
    try:
        details = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        details = None

    if isinstance(details, list):
        details = details[0] if details else {}
    if isinstance(details, dict):
        api_error = details.get("error")
        if isinstance(api_error, dict):
            message = api_error.get("message")
            if isinstance(message, str) and message:
                return message

    decoded = raw.decode("utf-8", errors="replace").strip()
    return decoded or str(exc)


def _duration_seconds(value: Any) -> float | None:
    """Parse a Google-style duration such as ``26.5s``."""
    if not isinstance(value, str):
        return None

    duration = value.strip()
    if not duration.endswith("s"):
        return None

    try:
        seconds = float(duration[:-1])
    except ValueError:
        return None

    if seconds < 0:
        return None
    return seconds


def _body_retry_delay(raw: bytes) -> float | None:
    """Return retryDelay from a Gemini JSON error response when present."""
    try:
        details = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None

    if not isinstance(details, dict):
        return None

    api_error = details.get("error")
    if not isinstance(api_error, dict):
        return None

    error_details = api_error.get("details")
    if isinstance(error_details, list):
        for detail in error_details:
            if not isinstance(detail, dict):
                continue
            detail_type = detail.get("@type")
            if (
                isinstance(detail_type, str)
                and detail_type.endswith("google.rpc.RetryInfo")
            ):
                seconds = _duration_seconds(detail.get("retryDelay"))
                if seconds is not None:
                    return seconds

    message = api_error.get("message")
    if isinstance(message, str):
        marker = "Please retry in "
        marker_index = message.rfind(marker)
        if marker_index >= 0:
            duration = message[marker_index + len(marker) :].split(None, 1)[0]
            seconds = _duration_seconds(duration.rstrip("."))
            if seconds is not None:
                return seconds

    return None


def _retry_delay(
    attempt: int,
    headers: Any = None,
    raw: bytes = b"",
) -> float:
    if headers is not None:
        retry_after = headers.get("Retry-After")
        if retry_after:
            parsed_delay = _retry_after_seconds(retry_after)
            if parsed_delay is not None:
                return min(parsed_delay, 60.0)

    body_delay = _body_retry_delay(raw)
    if body_delay is not None:
        return min(body_delay, 60.0)

    return min(float(2 ** (attempt - 1)), 8.0)


def _retry_after_seconds(
    value: Any,
    *,
    now: datetime | None = None,
) -> float | None:
    """Parse Retry-After seconds or an HTTP date."""
    if not isinstance(value, str) or not value.strip():
        return None

    retry_after = value.strip()
    try:
        seconds = float(retry_after)
    except ValueError:
        try:
            retry_at = parsedate_to_datetime(retry_after)
        except (TypeError, ValueError, OverflowError):
            return None
        if retry_at.tzinfo is None:
            retry_at = retry_at.replace(tzinfo=UTC)
        current = now or datetime.now(UTC)
        seconds = (retry_at - current).total_seconds()
    return max(seconds, 0.0)


def _read_response_bytes(response: Any, maximum_bytes: int) -> bytes:
    """Read one bounded HTTP response body."""
    raw = response.read(maximum_bytes + 1)
    if len(raw) > maximum_bytes:
        raise FlashOSAIError(
            f"Gemini response exceeds {maximum_bytes} bytes"
        )
    return raw


def _request_payload(
    prompt: str,
    system_instruction: str,
    config: GeminiConfig,
) -> bytes:
    generation_config: dict[str, Any] = {
        "max_output_tokens": config.max_output_tokens,
    }
    if config.seed is not None:
        generation_config["seed"] = config.seed
    if config.thinking_level is not None:
        generation_config["thinking_level"] = config.thinking_level

    payload = {
        "model": config.model,
        "store": False,
        "system_instruction": system_instruction,
        "input": prompt,
        "generation_config": generation_config,
    }
    if config.response_schema is not None:
        payload["response_format"] = {
            "type": "text",
            "mime_type": "application/json",
            "schema": config.response_schema,
        }
    return json.dumps(payload).encode("utf-8")


def call_gemini(
    prompt: str,
    *,
    system_instruction: str,
    config: GeminiConfig,
    retry_notice: RetryNotice | None = None,
) -> dict[str, Any]:
    """Call Gemini's Interactions API and return its decoded JSON object."""

    if not prompt:
        raise FlashOSAIError("Gemini prompt is empty")
    if not system_instruction:
        raise FlashOSAIError("Gemini system instruction is empty")

    config.validate()
    key = gemini_api_key()
    payload = _request_payload(prompt, system_instruction, config)

    for attempt in range(1, config.attempts + 1):
        request = urllib.request.Request(
            GEMINI_INTERACTIONS_URL,
            data=payload,
            headers={
                "x-goog-api-key": key,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=config.timeout_seconds,
            ) as response:
                raw = _read_response_bytes(response, config.max_response_bytes)
                data = json.loads(raw)
            if not isinstance(data, dict):
                raise FlashOSAIError("Gemini returned an invalid response")
            return data
        except urllib.error.HTTPError as exc:
            raw = exc.read(config.max_response_bytes + 1)
            if len(raw) > config.max_response_bytes:
                raise FlashOSAIError(
                    f"Gemini error response exceeds "
                    f"{config.max_response_bytes} bytes"
                ) from exc
            message = _http_error_message(exc, raw)
            if (
                exc.code in RETRYABLE_HTTP_STATUSES
                and attempt < config.attempts
            ):
                delay = _retry_delay(attempt, exc.headers, raw)
                if retry_notice is not None:
                    retry_notice(
                        f"Gemini API returned HTTP {exc.code}; "
                        f"retrying in {delay:.1f}s"
                    )
                time.sleep(delay)
                continue
            raise FlashOSAIError(f"Gemini API error: {message}") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            reason = getattr(exc, "reason", exc)
            if attempt < config.attempts:
                if retry_notice is not None:
                    retry_notice(f"Gemini request failed ({reason}); retrying")
                time.sleep(_retry_delay(attempt))
                continue
            raise FlashOSAIError(f"Gemini request failed: {reason}") from exc
        except (OSError, ValueError) as exc:
            raise FlashOSAIError(f"Gemini request failed: {exc}") from exc
        except KeyboardInterrupt as exc:
            raise FlashOSAIError(
                "Gemini request interrupted",
                exit_code=130,
            ) from exc

    raise FlashOSAIError("Gemini request failed")


def _status_detail(data: dict[str, Any]) -> str:
    details = data.get("incomplete_details")
    if isinstance(details, str) and details:
        return details
    if isinstance(details, dict):
        for key in ("reason", "message", "code"):
            value = details.get(key)
            if isinstance(value, str) and value:
                return value

    api_error = data.get("error")
    if isinstance(api_error, str) and api_error:
        return api_error
    if isinstance(api_error, dict):
        for key in ("message", "code"):
            value = api_error.get(key)
            if isinstance(value, str) and value:
                return value
    return ""


def _usage_detail(data: dict[str, Any]) -> str:
    usage = data.get("usage")
    if not isinstance(usage, dict):
        return ""

    labels = (
        ("total_output_tokens", "output"),
        ("total_thought_tokens", "thought"),
        ("total_tokens", "total"),
    )
    parts = [
        f"{label}={usage[key]}"
        for key, label in labels
        if isinstance(usage.get(key), int)
    ]
    return ", ".join(parts)


def interaction_text(data: dict[str, Any]) -> str:
    """Extract concatenated model text from a completed interaction."""

    status = data.get("status", "unknown")
    if status != "completed":
        message = f"Gemini interaction did not complete: {status}"
        detail = _status_detail(data)
        if detail:
            message += f" ({detail})"
        elif status == "incomplete":
            message += " (the output token budget may have been exhausted)"

        usage = _usage_detail(data)
        if usage:
            message += f"; usage: {usage}"
        raise FlashOSAIError(message)

    texts: list[str] = []
    steps = data.get("steps", [])
    if not isinstance(steps, list):
        raise FlashOSAIError("Gemini returned an invalid response")

    for step in steps:
        if not isinstance(step, dict) or step.get("type") != "model_output":
            continue
        content = step.get("content", [])
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict) or item.get("type") != "text":
                continue
            text = item.get("text", "")
            if isinstance(text, str):
                texts.append(text)

    result = "".join(texts).strip()
    if not result:
        raise FlashOSAIError("Gemini returned no text")
    return result
