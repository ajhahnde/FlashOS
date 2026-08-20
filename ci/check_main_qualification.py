#!/usr/bin/env python3
"""Transfer exact candidate qualification evidence to a merged main tree."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

API_VERSION = "2022-11-28"
CANDIDATE_WORKFLOW = "ci.yml"
SECURITY_WORKFLOW = "security.yml"
CANDIDATE_JOBS = {
    "repository-quality",
    "flash-quality",
    "image-and-runtime / docker-clean-room-build",
    "image-and-runtime / qemu-artifact-consumer",
    "required",
}
SECURITY_JOBS = {"security-required"}


class QualificationError(RuntimeError):
    """Raised when a main commit lacks exact successful candidate evidence."""


@dataclass(frozen=True)
class QualificationEvidence:
    pull_number: int
    candidate_sha: str
    tree_sha: str
    candidate_run_url: str
    security_run_url: str


class GitHubClient:
    """Small read-only GitHub API client with bounded infrastructure retries."""

    def __init__(self, api_url: str, token: str, attempts: int = 3) -> None:
        self.api_url = api_url.rstrip("/")
        self.token = token
        self.attempts = attempts

    def get(self, path: str, params: dict[str, str] | None = None) -> Any:
        query = ""
        if params:
            query = "?" + urllib.parse.urlencode(params)
        request = urllib.request.Request(
            f"{self.api_url}{path}{query}",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": API_VERSION,
                "User-Agent": "FlashOS-main-qualification",
            },
        )
        for attempt in range(1, self.attempts + 1):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    return json.load(response)
            except urllib.error.HTTPError as error:
                retryable = error.code == 429 or error.code >= 500
                if not retryable or attempt == self.attempts:
                    detail = error.read().decode(errors="replace")
                    raise QualificationError(
                        f"GitHub API {path} failed with HTTP {error.code}: {detail}"
                    ) from error
            except (TimeoutError, urllib.error.URLError) as error:
                if attempt == self.attempts:
                    raise QualificationError(
                        f"GitHub API {path} remained unavailable: {error}"
                    ) from error
            time.sleep(attempt)
        raise AssertionError("bounded GitHub API loop did not return or raise")


def _single_merged_pull(client: GitHubClient, repository: str, main_sha: str) -> dict:
    pulls = client.get(f"/repos/{repository}/commits/{main_sha}/pulls")
    matches = [
        pull
        for pull in pulls
        if pull.get("merged_at")
        and pull.get("base", {}).get("ref") == "main"
    ]
    if len(matches) != 1:
        raise QualificationError(
            f"main commit {main_sha} must identify exactly one merged pull request; "
            f"found {len(matches)}"
        )
    pull = matches[0]
    if pull.get("draft"):
        raise QualificationError(
            f"merged pull request #{pull['number']} is still marked draft"
        )
    return pull


def _tree_sha(client: GitHubClient, repository: str, commit_sha: str) -> str:
    commit = client.get(f"/repos/{repository}/git/commits/{commit_sha}")
    tree_sha = commit.get("tree", {}).get("sha")
    if not tree_sha:
        raise QualificationError(f"commit {commit_sha} did not expose a Git tree")
    return tree_sha


def _successful_run(
    client: GitHubClient,
    repository: str,
    workflow: str,
    candidate_sha: str,
    pull_number: int,
    required_jobs: set[str],
) -> dict:
    payload = client.get(
        f"/repos/{repository}/actions/workflows/{workflow}/runs",
        {
            "event": "pull_request",
            "head_sha": candidate_sha,
            "status": "success",
            "per_page": "100",
        },
    )
    runs = [
        run
        for run in payload.get("workflow_runs", [])
        if run.get("event") == "pull_request"
        and run.get("head_sha") == candidate_sha
        and run.get("conclusion") == "success"
    ]
    runs.sort(
        key=lambda run: (run.get("run_attempt", 0), run.get("id", 0)),
        reverse=True,
    )
    for run in runs:
        jobs_payload = client.get(
            f"/repos/{repository}/actions/runs/{run['id']}/jobs",
            {"filter": "latest", "per_page": "100"},
        )
        successful_jobs = {
            job.get("name")
            for job in jobs_payload.get("jobs", [])
            if job.get("conclusion") == "success"
        }
        if required_jobs <= successful_jobs:
            return run
    missing = ", ".join(sorted(required_jobs))
    raise QualificationError(
        f"pull request #{pull_number} head {candidate_sha} has no successful "
        f"{workflow} run containing the required jobs: {missing}"
    )


def qualify_main(
    client: GitHubClient, repository: str, main_sha: str
) -> QualificationEvidence:
    pull = _single_merged_pull(client, repository, main_sha)
    candidate_sha = pull.get("head", {}).get("sha")
    if not candidate_sha:
        raise QualificationError(f"pull request #{pull['number']} has no head commit")

    main_tree = _tree_sha(client, repository, main_sha)
    candidate_tree = _tree_sha(client, repository, candidate_sha)
    if main_tree != candidate_tree:
        raise QualificationError(
            f"main tree {main_tree} differs from qualified candidate tree "
            f"{candidate_tree}"
        )

    candidate_run = _successful_run(
        client,
        repository,
        CANDIDATE_WORKFLOW,
        candidate_sha,
        pull["number"],
        CANDIDATE_JOBS,
    )
    security_run = _successful_run(
        client,
        repository,
        SECURITY_WORKFLOW,
        candidate_sha,
        pull["number"],
        SECURITY_JOBS,
    )
    return QualificationEvidence(
        pull_number=pull["number"],
        candidate_sha=candidate_sha,
        tree_sha=main_tree,
        candidate_run_url=candidate_run["html_url"],
        security_run_url=security_run["html_url"],
    )


def _write_summary(evidence: QualificationEvidence) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    summary = (
        "## FlashOS main qualification\n\n"
        f"- merged pull request: #{evidence.pull_number}\n"
        f"- qualified candidate: `{evidence.candidate_sha}`\n"
        f"- exact Git tree: `{evidence.tree_sha}`\n"
        f"- [candidate qualification]({evidence.candidate_run_url})\n"
        f"- [dependency policy]({evidence.security_run_url})\n"
    )
    with Path(summary_path).open("a", encoding="utf-8") as summary_file:
        summary_file.write(summary)


def main() -> int:
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    main_sha = os.environ.get("GITHUB_SHA", "")
    token = os.environ.get("GITHUB_TOKEN", "")
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    if not repository or not main_sha or not token:
        print(
            "main qualification: GITHUB_REPOSITORY, GITHUB_SHA, and "
            "GITHUB_TOKEN are required",
            file=sys.stderr,
        )
        return 2
    try:
        evidence = qualify_main(GitHubClient(api_url, token), repository, main_sha)
    except QualificationError as error:
        print(f"main qualification: FAILED: {error}", file=sys.stderr)
        return 1
    _write_summary(evidence)
    print(
        "main qualification: ok: "
        f"PR #{evidence.pull_number} tree {evidence.tree_sha}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
