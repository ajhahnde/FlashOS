import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ci"))
SPEC = importlib.util.spec_from_file_location(
    "check_main_qualification", ROOT / "ci/check_main_qualification.py"
)
MODULE = None
if (ROOT / "ci/check_main_qualification.py").is_file():
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


def responses(
    *,
    candidate_tree=TREE_SHA,
    candidate_jobs=None,
    security_jobs=None,
    changed_paths=None,
    changed_files=None,
):
    pull = {
        "number": 47,
        "merged_at": "2026-08-20T18:48:00Z",
        "merge_commit_sha": MAIN_SHA,
        "draft": False,
        "base": {"ref": "main"},
        "head": {"sha": HEAD_SHA},
        "state": "open",
    }
    run_query = (
        ("event", "pull_request"),
        ("head_sha", HEAD_SHA),
        ("per_page", "100"),
        ("status", "success"),
    )
    jobs_query = (("filter", "latest"), ("per_page", "100"))
    if candidate_jobs is None:
        candidate_jobs = MODULE.CANDIDATE_JOBS | MODULE.IMAGE_JOBS
    if security_jobs is None:
        security_jobs = MODULE.SECURITY_JOBS
    if changed_paths is None:
        changed_paths = ["src/lib.rs"]
    if changed_files is None:
        changed_files = [{"filename": path} for path in changed_paths]
    return {
        (f"/repos/example/flashos/commits/{MAIN_SHA}/pulls", ()): [pull],
        (f"/repos/example/flashos/git/commits/{MAIN_SHA}", ()): {
            "tree": {"sha": TREE_SHA}
        },
        (f"/repos/example/flashos/git/commits/{HEAD_SHA}", ()): {
            "tree": {"sha": candidate_tree}
        },
        (
            "/repos/example/flashos/pulls/47/files",
            (("page", "1"), ("per_page", "100")),
        ): changed_files,
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
            "jobs": [{"name": name, "conclusion": "success"} for name in candidate_jobs]
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
            "jobs": [{"name": name, "conclusion": "success"} for name in security_jobs]
        },
    }


@unittest.skipUnless(
    MODULE is not None,
    "the Python hosted qualification pair has migrated to Flash",
)
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
        with self.assertRaisesRegex(
            MODULE.QualificationError, "image jobs are missing"
        ):
            MODULE.qualify_main(
                FakeClient(responses(candidate_jobs=incomplete)),
                "example/flashos",
                MAIN_SHA,
            )

    def test_accepts_a_classified_fast_lane_without_image_jobs(self):
        evidence = MODULE.qualify_main(
            FakeClient(
                responses(
                    candidate_jobs=MODULE.CANDIDATE_JOBS,
                    changed_paths=["docs/verification.md"],
                )
            ),
            "example/flashos",
            MAIN_SHA,
        )
        self.assertEqual(evidence.lane, "fast")
        self.assertFalse(evidence.image_required)

    def test_rejects_image_work_for_a_classified_fast_lane(self):
        with self.assertRaisesRegex(MODULE.QualificationError, "image jobs ran"):
            MODULE.qualify_main(
                FakeClient(responses(changed_paths=["docs/verification.md"])),
                "example/flashos",
                MAIN_SHA,
            )

    def test_rename_from_product_source_to_docs_still_requires_image_work(self):
        evidence = MODULE.qualify_main(
            FakeClient(
                responses(
                    changed_files=[
                        {
                            "status": "renamed",
                            "filename": "docs/old-source.md",
                            "previous_filename": "src/old-source.rs",
                        }
                    ]
                )
            ),
            "example/flashos",
            MAIN_SHA,
        )
        self.assertTrue(evidence.image_required)

    def test_rejects_missing_security_qualification(self):
        with self.assertRaisesRegex(MODULE.QualificationError, "required jobs"):
            MODULE.qualify_main(
                FakeClient(responses(security_jobs={"dependency-scope"})),
                "example/flashos",
                MAIN_SHA,
            )

    def test_dependency_change_requires_the_underlying_security_jobs(self):
        with self.assertRaisesRegex(MODULE.QualificationError, "dependency policy"):
            MODULE.qualify_main(
                FakeClient(
                    responses(
                        candidate_jobs=MODULE.CANDIDATE_JOBS,
                        changed_paths=[".github/dependabot.yml"],
                    )
                ),
                "example/flashos",
                MAIN_SHA,
            )

        evidence = MODULE.qualify_main(
            FakeClient(
                responses(
                    candidate_jobs=MODULE.CANDIDATE_JOBS,
                    security_jobs=MODULE.SECURITY_JOBS | MODULE.SECURITY_POLICY_JOBS,
                    changed_paths=[".github/dependabot.yml"],
                )
            ),
            "example/flashos",
            MAIN_SHA,
        )
        self.assertEqual(evidence.lane, "fast")

    def test_candidate_source_accepts_the_exact_reviewable_pr_head(self):
        payload = responses()
        payload[(f"/repos/example/flashos/commits/{HEAD_SHA}/pulls", ())] = payload[
            (f"/repos/example/flashos/commits/{MAIN_SHA}/pulls", ())
        ]
        evidence = MODULE.qualify_candidate_source(
            FakeClient(payload), "example/flashos", HEAD_SHA
        )
        self.assertEqual(evidence.candidate_sha, HEAD_SHA)
        self.assertEqual(evidence.tree_sha, TREE_SHA)
        self.assertEqual(evidence.candidate_run_id, 10)
        self.assertEqual(evidence.security_run_id, 11)

    def test_candidate_source_accepts_an_exact_tree_merged_commit(self):
        payload = responses()
        pull = payload[(f"/repos/example/flashos/commits/{MAIN_SHA}/pulls", ())][0]
        pull["state"] = "closed"
        evidence = MODULE.qualify_candidate_source(
            FakeClient(payload), "example/flashos", MAIN_SHA
        )
        self.assertEqual(evidence.candidate_sha, HEAD_SHA)
        self.assertEqual(evidence.tree_sha, TREE_SHA)


if __name__ == "__main__":
    unittest.main()
