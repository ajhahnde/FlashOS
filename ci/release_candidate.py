#!/usr/bin/env python3
"""Create and validate an immutable FlashOS release-candidate manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

SCHEMA = 1
WORKFLOW = "candidate.yml"
PROFILE = "flashos-release"
HEX_OID = re.compile(r"[0-9a-f]{40}")
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?")


class CandidateError(RuntimeError):
    """Raised when candidate identity or contents are incomplete."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_oid(value: str, label: str) -> str:
    if HEX_OID.fullmatch(value) is None:
        raise CandidateError(f"{label} must be a full lowercase Git object ID")
    return value


def _require_version(value: str) -> str:
    if SEMVER.fullmatch(value) is None:
        raise CandidateError(
            "version must be semantic and must not include a leading v"
        )
    return value


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CandidateError(f"cannot read JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise CandidateError(f"{path} must contain a JSON object")
    return value


def _positive(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise CandidateError(f"{label} must be positive")
    return value


def _input_identity(root: Path) -> dict[str, Any]:
    required = (
        "Cargo.lock",
        "components/flash/Cargo.lock",
        "components/flash/rust-toolchain.toml",
        "config/flashos-base.toml",
        "config/x86_64/flashos-release.toml",
        "ci/container/Dockerfile",
        "cookbook.lock",
        "rust-toolchain.toml",
    )
    files: dict[str, str] = {}
    for relative in required:
        path = root / relative
        if not path.is_file():
            raise CandidateError(f"candidate input is missing: {relative}")
        files[relative] = sha256(path)

    recipes = sorted((root / "recipes").glob("**/recipe.toml"))
    if not recipes:
        raise CandidateError("candidate recipe graph is empty")
    recipe_digest = hashlib.sha256()
    for path in recipes:
        relative = path.relative_to(root).as_posix()
        recipe_digest.update(relative.encode())
        recipe_digest.update(b"\0")
        recipe_digest.update(path.read_bytes())
        recipe_digest.update(b"\0")
    return {
        "files": files,
        "recipe_graph_sha256": recipe_digest.hexdigest(),
        "recipe_count": len(recipes),
    }


def _validate_qemu(
    path: Path, source_commit: str
) -> tuple[dict[str, Any], dict[str, str]]:
    qemu = _load_json(path)
    if qemu.get("schema") != 1 or qemu.get("source_commit") != source_commit:
        raise CandidateError("QEMU results do not match the candidate source")
    raw_images: dict[str, str] = {}
    for name in ("harddrive", "live"):
        result = qemu.get(name)
        if not isinstance(result, dict):
            raise CandidateError(f"QEMU results are missing {name}")
        if result.get("result") != "success" or result.get("attempt") != 1:
            raise CandidateError(
                f"QEMU {name} must succeed on the first attempt for a candidate"
            )
        digest = result.get("sha256")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise CandidateError(f"QEMU {name} has an invalid image digest")
        raw_images[name] = digest
    return qemu, raw_images


def _parse_checksums(path: Path) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/]+)", line)
        if match is None:
            raise CandidateError(f"invalid SHA256SUMS line {line_number}")
        digest, name = match.groups()
        if name in checksums:
            raise CandidateError(f"duplicate checksum entry: {name}")
        checksums[name] = digest
    return checksums


def _expected_payload(version: str) -> set[str]:
    return {
        f"FlashOS-{version}-x86_64-harddrive.img.zst",
        f"FlashOS-{version}-x86_64-live.iso.zst",
        f"FlashOS-{version}-source.cdx.json",
        f"FlashOS-{version}-image.cdx.json",
        f"FlashOS-{version}-release-notes.md",
        "qemu-harddrive-performance.json",
        "qemu-harddrive-smoke.log",
        "qemu-live-usb-smoke.log",
        "qemu-results.json",
    }


def _decompressed_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        process = subprocess.Popen(
            ["zstd", "--decompress", "--stdout", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise CandidateError(f"cannot execute zstd: {error}") from error
    assert process.stdout is not None
    for chunk in iter(lambda: process.stdout.read(1024 * 1024), b""):
        digest.update(chunk)
    _, stderr = process.communicate()
    if process.returncode != 0:
        raise CandidateError(
            f"cannot decompress {path.name}: {stderr.decode(errors='replace')}"
        )
    return digest.hexdigest()


def select_candidate_artifact(
    run: dict[str, Any],
    artifacts: dict[str, Any],
    *,
    repository: str,
    run_id: int,
) -> dict[str, Any]:
    if run.get("id") != run_id:
        raise CandidateError("candidate run response has the wrong run ID")
    if run.get("head_repository", {}).get("full_name") != repository:
        raise CandidateError("candidate run belongs to another repository")
    if run.get("path") != ".github/workflows/candidate.yml":
        raise CandidateError("selected run is not candidate.yml")
    if (
        run.get("event") != "workflow_dispatch"
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
    ):
        raise CandidateError("selected candidate run is not successfully completed")
    attempt = _positive(run.get("run_attempt"), "candidate run attempt")
    expected_name = f"flashos-release-candidate-{run_id}-{attempt}"
    values = artifacts.get("artifacts")
    if not isinstance(values, list):
        raise CandidateError("candidate artifact response is invalid")
    matches = [
        artifact
        for artifact in values
        if isinstance(artifact, dict)
        and artifact.get("name") == expected_name
        and artifact.get("expired") is False
    ]
    if len(matches) != 1:
        raise CandidateError("candidate artifact is missing, ambiguous, or expired")
    return {"artifact_name": expected_name, "run_attempt": attempt}


def create_manifest(
    *,
    root: Path,
    bundle: Path,
    version: str,
    repository: str,
    source_commit: str,
    source_tree: str,
    run_id: int,
    run_attempt: int,
    required_run_id: int,
    security_run_id: int,
) -> dict[str, Any]:
    version = _require_version(version)
    _require_oid(source_commit, "source commit")
    _require_oid(source_tree, "source tree")
    if not repository or "/" not in repository:
        raise CandidateError("repository must use owner/name form")
    for value, label in (
        (run_id, "run ID"),
        (run_attempt, "run attempt"),
        (required_run_id, "required run ID"),
        (security_run_id, "security run ID"),
    ):
        _positive(value, label)

    qemu_path = bundle / "qemu-results.json"
    _, raw_images = _validate_qemu(qemu_path, source_commit)
    checksums_path = bundle / "SHA256SUMS"
    if not checksums_path.is_file():
        raise CandidateError("candidate is missing SHA256SUMS")
    checksums = _parse_checksums(checksums_path)

    expected_payload = _expected_payload(version)
    if set(checksums) != expected_payload:
        missing = sorted(expected_payload - set(checksums))
        unexpected = sorted(set(checksums) - expected_payload)
        raise CandidateError(
            f"checksum inventory mismatch; missing={missing}, unexpected={unexpected}"
        )

    file_records: dict[str, dict[str, Any]] = {}
    for name in sorted(expected_payload | {"SHA256SUMS"}):
        path = bundle / name
        if not path.is_file() or path.is_symlink():
            raise CandidateError(f"candidate file is missing or not regular: {name}")
        digest = sha256(path)
        if name in checksums and checksums[name] != digest:
            raise CandidateError(f"candidate checksum mismatch: {name}")
        file_records[name] = {"sha256": digest, "size": path.stat().st_size}

    manifest = {
        "schema": SCHEMA,
        "repository": repository,
        "workflow": {
            "name": WORKFLOW,
            "run_id": run_id,
            "run_attempt": run_attempt,
        },
        "source": {"commit": source_commit, "tree": source_tree},
        "version": version,
        "profile": PROFILE,
        "qualification": {
            "required_run_id": required_run_id,
            "security_run_id": security_run_id,
        },
        "inputs": _input_identity(root),
        "raw_images": raw_images,
        "qemu": {
            "results": "qemu-results.json",
            "harddrive": "success-first-attempt",
            "live": "success-first-attempt",
        },
        "files": file_records,
        "allowlisted_filenames": sorted(
            expected_payload | {"SHA256SUMS", "candidate-manifest.json"}
        ),
    }
    destination = bundle / "candidate-manifest.json"
    destination.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def validate_bundle(
    bundle: Path,
    *,
    root: Path | None = None,
    repository: str | None = None,
    version: str | None = None,
    source_commit: str | None = None,
    source_tree: str | None = None,
    run_id: int | None = None,
    run_attempt: int | None = None,
    tag: str | None = None,
    verify_compressed: bool = False,
) -> dict[str, Any]:
    manifest = _load_json(bundle / "candidate-manifest.json")
    if manifest.get("schema") != SCHEMA:
        raise CandidateError("unsupported candidate manifest schema")
    expected_keys = {
        "schema",
        "repository",
        "workflow",
        "source",
        "version",
        "profile",
        "qualification",
        "inputs",
        "raw_images",
        "qemu",
        "files",
        "allowlisted_filenames",
    }
    if set(manifest) != expected_keys:
        raise CandidateError("candidate manifest fields are missing or unexpected")
    if manifest.get("profile") != PROFILE:
        raise CandidateError("candidate profile is not flashos-release")
    manifest_version = manifest.get("version")
    if not isinstance(manifest_version, str):
        raise CandidateError("candidate version is missing")
    _require_version(manifest_version)
    source = manifest.get("source", {})
    _require_oid(source.get("commit", ""), "candidate source commit")
    _require_oid(source.get("tree", ""), "candidate source tree")
    workflow = manifest.get("workflow", {})
    if workflow.get("name") != WORKFLOW:
        raise CandidateError("candidate was not produced by candidate.yml")
    _positive(workflow.get("run_id", 0), "candidate run ID")
    _positive(workflow.get("run_attempt", 0), "candidate run attempt")
    qualification = manifest.get("qualification", {})
    _positive(qualification.get("required_run_id", 0), "required run ID")
    _positive(qualification.get("security_run_id", 0), "security run ID")
    if root is not None and manifest.get("inputs") != _input_identity(root):
        raise CandidateError("candidate input graph differs from the selected source")

    expectations = (
        (repository, manifest.get("repository"), "repository"),
        (version, manifest.get("version"), "version"),
        (source_commit, source.get("commit"), "source commit"),
        (source_tree, source.get("tree"), "source tree"),
        (run_id, workflow.get("run_id"), "run ID"),
        (run_attempt, workflow.get("run_attempt"), "run attempt"),
    )
    for expected, actual, label in expectations:
        if expected is not None and expected != actual:
            raise CandidateError(
                f"candidate {label} mismatch: {actual!r} != {expected!r}"
            )
    if tag is not None and tag != f"v{manifest.get('version')}":
        raise CandidateError("tag does not match the candidate version")

    allowlist = manifest.get("allowlisted_filenames")
    if not isinstance(allowlist, list) or any(
        not isinstance(name, str) for name in allowlist
    ):
        raise CandidateError("candidate filename allowlist is invalid")
    expected_allowlist = sorted(
        _expected_payload(manifest_version) | {"SHA256SUMS", "candidate-manifest.json"}
    )
    if sorted(allowlist) != expected_allowlist:
        raise CandidateError("candidate filename allowlist differs from the schema")
    inventory = sorted(path.name for path in bundle.iterdir())
    if inventory != sorted(allowlist) or len(inventory) != len(set(inventory)):
        raise CandidateError(
            f"candidate inventory mismatch; actual={inventory}, allowlist={allowlist}"
        )

    records = manifest.get("files")
    if not isinstance(records, dict) or set(records) != set(allowlist) - {
        "candidate-manifest.json"
    }:
        raise CandidateError("candidate file records do not match the allowlist")
    for name, record in records.items():
        path = bundle / name
        if path.is_symlink() or not path.is_file():
            raise CandidateError(f"candidate member is not a regular file: {name}")
        if record != {"sha256": sha256(path), "size": path.stat().st_size}:
            raise CandidateError(f"candidate file identity mismatch: {name}")

    checksums = _parse_checksums(bundle / "SHA256SUMS")
    if set(checksums) != set(records) - {"SHA256SUMS"}:
        raise CandidateError("SHA256SUMS inventory does not match candidate payload")
    for name, digest in checksums.items():
        if digest != records[name]["sha256"]:
            raise CandidateError(f"SHA256SUMS digest mismatch: {name}")

    _, raw_images = _validate_qemu(
        bundle / manifest["qemu"]["results"], manifest["source"]["commit"]
    )
    if raw_images != manifest.get("raw_images"):
        raise CandidateError("manifest raw-image digests differ from QEMU evidence")
    if verify_compressed:
        compressed = {
            "harddrive": bundle
            / f"FlashOS-{manifest_version}-x86_64-harddrive.img.zst",
            "live": bundle / f"FlashOS-{manifest_version}-x86_64-live.iso.zst",
        }
        for name, path in compressed.items():
            if _decompressed_sha256(path) != raw_images[name]:
                raise CandidateError(
                    f"compressed {name} bytes differ from the QEMU-qualified raw image"
                )
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--root", type=Path, default=Path("."))
    create.add_argument("--bundle", type=Path, required=True)
    create.add_argument("--version", required=True)
    create.add_argument("--repository", required=True)
    create.add_argument("--source-commit", required=True)
    create.add_argument("--source-tree", required=True)
    create.add_argument("--run-id", type=int, required=True)
    create.add_argument("--run-attempt", type=int, required=True)
    create.add_argument("--required-run-id", type=int, required=True)
    create.add_argument("--security-run-id", type=int, required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--bundle", type=Path, required=True)
    validate.add_argument("--root", type=Path, default=Path("."))
    validate.add_argument("--repository")
    validate.add_argument("--version")
    validate.add_argument("--source-commit")
    validate.add_argument("--source-tree")
    validate.add_argument("--run-id", type=int)
    validate.add_argument("--run-attempt", type=int)
    validate.add_argument("--tag")
    validate.add_argument("--verify-compressed", action="store_true")
    select = subparsers.add_parser("select")
    select.add_argument("--run", type=Path, required=True)
    select.add_argument("--artifacts", type=Path, required=True)
    select.add_argument("--repository", required=True)
    select.add_argument("--run-id", type=int, required=True)
    args = parser.parse_args(argv)

    try:
        if args.command == "create":
            create_manifest(
                root=args.root,
                bundle=args.bundle,
                version=args.version,
                repository=args.repository,
                source_commit=args.source_commit,
                source_tree=args.source_tree,
                run_id=args.run_id,
                run_attempt=args.run_attempt,
                required_run_id=args.required_run_id,
                security_run_id=args.security_run_id,
            )
        elif args.command == "validate":
            validate_bundle(
                args.bundle,
                root=args.root,
                repository=args.repository,
                version=args.version,
                source_commit=args.source_commit,
                source_tree=args.source_tree,
                run_id=args.run_id,
                run_attempt=args.run_attempt,
                tag=args.tag,
                verify_compressed=args.verify_compressed,
            )
        else:
            selection = select_candidate_artifact(
                _load_json(args.run),
                _load_json(args.artifacts),
                repository=args.repository,
                run_id=args.run_id,
            )
            print(json.dumps(selection, sort_keys=True, separators=(",", ":")))
            return 0
    except CandidateError as error:
        print(f"release candidate: FAILED: {error}", file=sys.stderr)
        return 1
    print("release candidate: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
