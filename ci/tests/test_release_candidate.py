import hashlib
import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "release_candidate", ROOT / "ci/release_candidate.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

COMMIT = "1" * 40
TREE = "2" * 40
VERSION = "0.2.0"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.bundle = Path(self.temporary.name) / "bundle"
        self.bundle.mkdir()
        payloads = {
            f"FlashOS-{VERSION}-x86_64-harddrive.img.zst": b"disk",
            f"FlashOS-{VERSION}-x86_64-live.iso.zst": b"live",
            f"FlashOS-{VERSION}-source.cdx.json": b"{}\n",
            f"FlashOS-{VERSION}-image.cdx.json": b"{}\n",
            f"FlashOS-{VERSION}-release-notes.md": b"notes\n",
            "cookbook.lock": b"# generated build resolution\n",
            "qemu-harddrive-performance.json": b"{}\n",
            "qemu-harddrive-smoke.log": b"disk ok\n",
            "qemu-live-usb-smoke.log": b"live ok\n",
        }
        qemu = {
            "schema": 1,
            "source_commit": COMMIT,
            "harddrive": {
                "interface": "nvme",
                "result": "success",
                "attempt": 1,
                "sha256": "a" * 64,
                "log": "qemu-harddrive-smoke.log",
            },
            "live": {
                "interface": "usb",
                "result": "success",
                "attempt": 1,
                "sha256": "b" * 64,
                "log": "qemu-live-usb-smoke.log",
            },
        }
        payloads["qemu-results.json"] = (json.dumps(qemu) + "\n").encode()
        for name, data in payloads.items():
            (self.bundle / name).write_bytes(data)
        checksum_lines = [
            f"{digest(data)}  {name}" for name, data in sorted(payloads.items())
        ]
        (self.bundle / "SHA256SUMS").write_text("\n".join(checksum_lines) + "\n")

    def tearDown(self):
        self.temporary.cleanup()

    def create(self):
        return MODULE.create_manifest(
            root=ROOT,
            bundle=self.bundle,
            version=VERSION,
            repository="example/FlashOS",
            source_commit=COMMIT,
            source_tree=TREE,
            run_id=123,
            run_attempt=2,
            required_run_id=120,
            security_run_id=121,
        )

    def test_round_trip_binds_identity_inventory_and_qemu_results(self):
        self.create()
        manifest = MODULE.validate_bundle(
            self.bundle,
            repository="example/FlashOS",
            version=VERSION,
            source_commit=COMMIT,
            source_tree=TREE,
            run_id=123,
            run_attempt=2,
            tag="v0.2.0",
        )
        self.assertEqual(
            manifest["raw_images"], {"harddrive": "a" * 64, "live": "b" * 64}
        )
        self.assertGreater(manifest["inputs"]["recipe_count"], 0)
        self.assertIn("cookbook.lock", manifest["files"])

    def test_generated_cookbook_lock_is_required_and_bound(self):
        (self.bundle / "cookbook.lock").unlink()
        with self.assertRaisesRegex(MODULE.CandidateError, "not regular"):
            self.create()

        (self.bundle / "cookbook.lock").write_bytes(
            b"# generated build resolution\n"
        )
        self.create()
        (self.bundle / "cookbook.lock").write_bytes(b"tampered\n")
        with self.assertRaisesRegex(MODULE.CandidateError, "identity mismatch"):
            MODULE.validate_bundle(self.bundle)

    def test_tampering_is_rejected(self):
        self.create()
        (self.bundle / f"FlashOS-{VERSION}-x86_64-live.iso.zst").write_bytes(
            b"substitute"
        )
        with self.assertRaisesRegex(MODULE.CandidateError, "identity mismatch"):
            MODULE.validate_bundle(self.bundle)

    def test_missing_and_unexpected_assets_are_rejected(self):
        self.create()
        (self.bundle / "unexpected.txt").write_text("no")
        with self.assertRaisesRegex(MODULE.CandidateError, "inventory mismatch"):
            MODULE.validate_bundle(self.bundle)

    def test_checksum_failure_blocks_manifest_creation(self):
        path = self.bundle / "SHA256SUMS"
        path.write_text(path.read_text().replace(digest(b"disk"), "0" * 64))
        with self.assertRaisesRegex(MODULE.CandidateError, "checksum mismatch"):
            self.create()

    def test_second_attempt_qemu_success_is_not_a_candidate_pass(self):
        path = self.bundle / "qemu-results.json"
        qemu = json.loads(path.read_text())
        qemu["harddrive"]["attempt"] = 2
        data = (json.dumps(qemu) + "\n").encode()
        path.write_bytes(data)
        sums = self.bundle / "SHA256SUMS"
        lines = [
            f"{digest(data)}  qemu-results.json"
            if line.endswith("  qemu-results.json")
            else line
            for line in sums.read_text().splitlines()
        ]
        sums.write_text("\n".join(lines) + "\n")
        with self.assertRaisesRegex(MODULE.CandidateError, "first attempt"):
            self.create()

    def test_wrong_run_tag_tree_and_repository_are_rejected(self):
        self.create()
        cases = (
            ({"run_id": 999}, "run ID mismatch"),
            ({"tag": "v0.2.1"}, "tag does not match"),
            ({"source_tree": "3" * 40}, "source tree mismatch"),
            ({"repository": "other/FlashOS"}, "repository mismatch"),
        )
        for kwargs, message in cases:
            with self.subTest(kwargs=kwargs):
                with self.assertRaisesRegex(MODULE.CandidateError, message):
                    MODULE.validate_bundle(self.bundle, **kwargs)

    def test_compressed_bytes_must_match_the_qemu_raw_digests(self):
        self.create()
        with mock.patch.object(MODULE, "_decompressed_sha256", return_value="c" * 64):
            with self.assertRaisesRegex(MODULE.CandidateError, "QEMU-qualified"):
                MODULE.validate_bundle(self.bundle, verify_compressed=True)

    def test_symlink_substitution_is_rejected(self):
        self.create()
        target = self.bundle / f"FlashOS-{VERSION}-source.cdx.json"
        copy = Path(self.temporary.name) / "copy"
        shutil.copyfile(target, copy)
        target.unlink()
        target.symlink_to(copy)
        with self.assertRaisesRegex(MODULE.CandidateError, "not a regular file"):
            MODULE.validate_bundle(self.bundle)


class CandidateSelectionTests(unittest.TestCase):
    def run_payload(self):
        return {
            "id": 123,
            "head_repository": {"full_name": "example/FlashOS"},
            "path": ".github/workflows/candidate.yml",
            "event": "workflow_dispatch",
            "status": "completed",
            "conclusion": "success",
            "run_attempt": 2,
        }

    def artifacts(self, *, expired=False, count=1):
        return {
            "artifacts": [
                {
                    "name": "flashos-release-candidate-123-2",
                    "expired": expired,
                }
                for _ in range(count)
            ]
        }

    def test_selects_one_unexpired_artifact_from_the_exact_run(self):
        result = MODULE.select_candidate_artifact(
            self.run_payload(),
            self.artifacts(),
            repository="example/FlashOS",
            run_id=123,
        )
        self.assertEqual(
            result,
            {
                "artifact_name": "flashos-release-candidate-123-2",
                "run_attempt": 2,
            },
        )

    def test_wrong_repository_workflow_or_result_is_rejected(self):
        changes = (
            ("head_repository", {"full_name": "other/FlashOS"}),
            ("path", ".github/workflows/ci.yml"),
            ("conclusion", "failure"),
        )
        for key, value in changes:
            with self.subTest(key=key):
                run = self.run_payload()
                run[key] = value
                with self.assertRaises(MODULE.CandidateError):
                    MODULE.select_candidate_artifact(
                        run,
                        self.artifacts(),
                        repository="example/FlashOS",
                        run_id=123,
                    )

    def test_expired_missing_or_ambiguous_artifact_is_rejected(self):
        cases = (
            self.artifacts(expired=True),
            self.artifacts(count=0),
            self.artifacts(count=2),
        )
        for artifacts in cases:
            with self.subTest(artifacts=artifacts):
                with self.assertRaisesRegex(MODULE.CandidateError, "expired"):
                    MODULE.select_candidate_artifact(
                        self.run_payload(),
                        artifacts,
                        repository="example/FlashOS",
                        run_id=123,
                    )


if __name__ == "__main__":
    unittest.main()
