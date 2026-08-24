#!/usr/bin/env python3
"""Resolve required PR evidence for an exact release-candidate source."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

from check_main_qualification import (
    GitHubClient,
    QualificationError,
    qualify_candidate_source,
)


def _output(name: str, value: str | int) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with Path(path).open("a", encoding="utf-8") as destination:
            destination.write(f"{name}={value}\n")


def main() -> int:
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    source_sha = os.environ.get("SOURCE_SHA", "")
    token = os.environ.get("GITHUB_TOKEN", "")
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    if not repository or not token or re.fullmatch(r"[0-9a-f]{40}", source_sha) is None:
        print(
            "candidate qualification: GITHUB_REPOSITORY, GITHUB_TOKEN, and a "
            "full lowercase SOURCE_SHA are required",
            file=sys.stderr,
        )
        return 2
    try:
        evidence = qualify_candidate_source(
            GitHubClient(api_url, token), repository, source_sha
        )
    except QualificationError as error:
        print(f"candidate qualification: FAILED: {error}", file=sys.stderr)
        return 1
    _output("source_tree", evidence.tree_sha)
    _output("pull_number", evidence.pull_number)
    _output("candidate_sha", evidence.candidate_sha)
    _output("required_run_id", evidence.candidate_run_id)
    _output("security_run_id", evidence.security_run_id)
    print(
        "candidate qualification: ok: "
        f"PR #{evidence.pull_number} tree {evidence.tree_sha}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
