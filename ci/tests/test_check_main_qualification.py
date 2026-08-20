import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_main_qualification", ROOT / "ci/check_main_qualification.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


MAIN_SHA = "1" * 40
HEAD_SHA = "2" * 40
TREE_SHA = "3" * 40


class FakeClient:
    def __init__(self, responses):
        self.responses = responses

    def get(self, path, params=None):
        key = (path, tuple(sorted((params or {}).items())))
        return self.responses[key]


def responses(*, candidate_tree=TREE_SHA, candidate_jobs=None, security_jobs=None):
    pull = {
        "number": 47,
        "merged_at": "2026-08-20T18:48:00Z",
        "merge_commit_sha": MAIN_SHA,
        "draft": False,
        "base": {"ref": "main"},
        "head": {"sha": HEAD_SHA},
    }
    run_query = (
        ("event", "pull_request"),
        ("head_sha", HEAD_SHA),
        ("per_page", "100"),
        ("status", "success"),
    )
    jobs_query = (("filter", "latest"), ("per_page", "100"))
    if candidate_jobs is None:
        candidate_jobs = MODULE.CANDIDATE_JOBS
    if security_jobs is None:
        security_jobs = MODULE.SECURITY_JOBS
    return {
        (f"/repos/example/flashos/commits/{MAIN_SHA}/pulls", ()): [pull],
        (f"/repos/example/flashos/git/commits/{MAIN_SHA}", ()): {
            "tree": {"sha": TREE_SHA}
        },
        (f"/repos/example/flashos/git/commits/{HEAD_SHA}", ()): {
            "tree": {"sha": candidate_tree}
        },
        ("/repos/example/flashos/actions/workflows/ci.yml/runs", run_query): {
            "workflow_runs": [
                {
                    "id": 10,
                    "event": "pull_request",
                    "head_sha": HEAD_SHA,
                    "conclusion": "success",
                    "run_attempt": 1,
                    "pull_requests": [],
                    "html_url": "https://example.test/candidate",
                }
            ]
        },
        ("/repos/example/flashos/actions/runs/10/jobs", jobs_query): {
            "jobs": [
                {"name": name, "conclusion": "success"}
                for name in candidate_jobs
            ]
        },
        ("/repos/example/flashos/actions/workflows/security.yml/runs", run_query): {
            "workflow_runs": [
                {
                    "id": 11,
                    "event": "pull_request",
                    "head_sha": HEAD_SHA,
                    "conclusion": "success",
                    "run_attempt": 1,
                    "pull_requests": [],
                    "html_url": "https://example.test/security",
                }
            ]
        },
        ("/repos/example/flashos/actions/runs/11/jobs", jobs_query): {
            "jobs": [
                {"name": name, "conclusion": "success"}
                for name in security_jobs
            ]
        },
    }


class QualificationTests(unittest.TestCase):
    def test_accepts_the_exact_tree_with_complete_candidate_evidence(self):
        evidence = MODULE.qualify_main(
            FakeClient(responses()), "example/flashos", MAIN_SHA
        )

        self.assertEqual(evidence.pull_number, 47)
        self.assertEqual(evidence.candidate_sha, HEAD_SHA)
        self.assertEqual(evidence.tree_sha, TREE_SHA)

    def test_rejects_a_main_tree_that_differs_from_the_candidate(self):
        with self.assertRaisesRegex(MODULE.QualificationError, "differs"):
            MODULE.qualify_main(
                FakeClient(responses(candidate_tree="4" * 40)),
                "example/flashos",
                MAIN_SHA,
            )

    def test_rejects_candidate_success_without_product_qualification(self):
        incomplete = MODULE.CANDIDATE_JOBS - {
            "image-and-runtime / qemu-artifact-consumer"
        }
        with self.assertRaisesRegex(MODULE.QualificationError, "required jobs"):
            MODULE.qualify_main(
                FakeClient(responses(candidate_jobs=incomplete)),
                "example/flashos",
                MAIN_SHA,
            )

    def test_rejects_missing_security_qualification(self):
        with self.assertRaisesRegex(MODULE.QualificationError, "required jobs"):
            MODULE.qualify_main(
                FakeClient(responses(security_jobs={"dependency-scope"})),
                "example/flashos",
                MAIN_SHA,
            )


if __name__ == "__main__":
    unittest.main()
