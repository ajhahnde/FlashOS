#!/usr/bin/env python3
"""Validate and summarize the stable FlashOS CI aggregate."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path


class AggregateError(RuntimeError):
    """Raised when job results contradict required qualification."""


@dataclass(frozen=True)
class Results:
    event: str
    draft: bool
    scope: str
    lane: str
    image_required: bool
    target_required: bool
    root: str
    flash: str
    image: str
    reasons: tuple[str, ...]


def _boolean(value: str, label: str) -> bool:
    if value not in {"true", "false"}:
        raise AggregateError(f"{label} must be true or false")
    return value == "true"


def parse(environment: dict[str, str]) -> Results:
    try:
        classification = json.loads(environment["CLASSIFICATION"])
    except (KeyError, json.JSONDecodeError) as error:
        raise AggregateError(f"classification output is invalid: {error}") from error
    reasons = classification.get("reasons")
    if (
        classification.get("schema") != 1
        or not isinstance(reasons, list)
        or any(not isinstance(reason, str) or not reason for reason in reasons)
    ):
        raise AggregateError("classification schema or reasons are invalid")
    result = Results(
        event=environment.get("EVENT_NAME", ""),
        draft=_boolean(environment.get("PR_DRAFT", "false"), "PR_DRAFT"),
        scope=environment.get("SCOPE_RESULT", ""),
        lane=environment.get("LANE", ""),
        image_required=_boolean(
            environment.get("IMAGE_REQUIRED", ""), "IMAGE_REQUIRED"
        ),
        target_required=_boolean(
            environment.get("TARGET_REQUIRED", ""), "TARGET_REQUIRED"
        ),
        root=environment.get("ROOT_RESULT", ""),
        flash=environment.get("SHELL_RESULT", ""),
        image=environment.get("IMAGE_RESULT", ""),
        reasons=tuple(reasons),
    )
    expected = (
        classification.get("lane"),
        classification.get("image_required"),
        classification.get("target_required"),
    )
    observed = (result.lane, result.image_required, result.target_required)
    if expected != observed:
        raise AggregateError("job outputs disagree with the classification payload")
    return result


def enforce(result: Results) -> None:
    if result.scope != "success":
        raise AggregateError("change classification failed")
    if (result.lane, result.image_required, result.target_required) not in {
        ("fast", False, False),
        ("product", True, False),
        ("product", True, True),
    }:
        raise AggregateError("change classification selected an invalid lane")
    if result.root != "success" or result.flash != "success":
        raise AggregateError("one or more required source gates failed")
    if result.image == "success":
        if not result.image_required:
            raise AggregateError("image qualification ran contrary to classification")
        return
    if result.image == "skipped" and not result.image_required:
        return
    if (
        result.event == "pull_request"
        and result.draft
        and result.image_required
        and result.image == "skipped"
    ):
        return
    raise AggregateError("classification requires successful product qualification")


def markdown(result: Results) -> str:
    lines = [
        "## FlashOS CI",
        "",
        "| gate | result |",
        "|:--|:--|",
        f"| change classification | {result.scope} ({result.lane}) |",
        f"| repository + product contract | {result.root} |",
        f"| Flash | {result.flash} |",
        f"| Docker image + QEMU runtime | {result.image} |",
        "",
        f"Image required: `{str(result.image_required).lower()}`; "
        f"target-affecting paths: `{str(result.target_required).lower()}`.",
        "",
        "Classification reasons:",
        *(f"- {reason}" for reason in result.reasons),
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    try:
        result = parse(dict(os.environ))
        enforce(result)
    except AggregateError as error:
        print(f"CI aggregate: FAILED: {error}", file=sys.stderr)
        return 1
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a", encoding="utf-8") as destination:
            destination.write(markdown(result))
    print("CI aggregate: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
