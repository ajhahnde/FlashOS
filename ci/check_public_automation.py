#!/usr/bin/env python3
"""Fail closed when a public automation surface lacks a reviewed disposition."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from collections import Counter
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "ci/public_automation.json"
TOOL_CONTRACT_PATH = ROOT / "ci/automation-tools.json"


def load_expanded_contract(path: Path = CONTRACT_PATH) -> dict[str, object]:
    document = json.loads(path.read_text(encoding="utf-8"))
    expected_keys = {
        "baseline_commit",
        "denominator",
        "exceptions",
        "migrations",
        "minimum_migrations",
        "schema",
        "shared_modules",
    }
    if set(document) != expected_keys:
        fail(f"expanded contract keys drifted: {sorted(document)!r}")
    return document


EXPANDED_CONTRACT = load_expanded_contract()


def load_tool_contract(path: Path = TOOL_CONTRACT_PATH) -> dict[str, object]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if set(document) != {"schema", "tools"}:
        fail(f"automation tool contract keys drifted: {sorted(document)!r}")
    return document


TOOL_CONTRACT = load_tool_contract()
BASELINE_COMMIT = str(EXPANDED_CONTRACT["baseline_commit"])
BASELINE_TREE = "6c4a3645e7ac1c019411eb8f1de620a5a5028cb0"
BASELINE_RUST_TOOLCHAIN = "1.97.1"
FLASH_V1_VERSION = "fsh 1.0.0"
MAX_RUNTIME_CAPTURE = 1024 * 1024
MIGRATION_BASELINE = frozenset(str(path) for path in EXPANDED_CONTRACT["migrations"])
RETAINED_BASELINE = {
    str(path): str(reason)
    for path, reason in dict(EXPANDED_CONTRACT["exceptions"]).items()
}
MIGRATION_TARGETS = {
    source: str(PurePosixPath(source).with_suffix(".fsh"))
    for source in MIGRATION_BASELINE
}
SHARED_FLASH_MODULES = frozenset(
    str(path) for path in EXPANDED_CONTRACT["shared_modules"]
)

EXPECTED_TOOL_CONTRACT = {
    "schema": 1,
    "tools": {
        "jq": {
            "accepted_version_outputs": ["jq-1.7.1", "jq-1.7.1-apple"],
            "assets": {
                "darwin-aarch64": {
                    "sha256": (
                        "0bbe619e663e0de2c550be2fe0d240d076799d6f8a652b70"
                        "fa04aea8a8362e8a"
                    ),
                    "url": "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64",
                },
                "linux-x86_64": {
                    "sha256": (
                        "5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93"
                        "d7c58b81d19c8ff5"
                    ),
                    "url": "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64",
                },
            },
            "environment": "FLASH_AUTOMATION_JQ",
            "version": "1.7.1",
        },
        "rg": {
            "assets": {
                "darwin-aarch64": {
                    "sha256": (
                        "3750b2e93f37e0c692657da574d7019a101c0084da05a790"
                        "c83fd335bad973e4"
                    ),
                    "url": "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz",
                },
                "linux-x86_64": {
                    "sha256": (
                        "33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e7"
                        "6aa6a585d1e7b149c"
                    ),
                    "url": "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz",
                },
            },
            "environment": "FLASH_AUTOMATION_RG",
            "version": "15.2.0",
        },
        "taplo": {
            "assets": {
                "darwin-aarch64": {
                    "sha256": (
                        "713734314c3e71894b9e77513c5349835eefbd52908445a0"
                        "d73b0c7dc469347d"
                    ),
                    "url": "https://github.com/tamasfe/taplo/releases/download/0.10.0/taplo-darwin-aarch64.gz",
                },
                "linux-x86_64": {
                    "sha256": (
                        "8fe196b894ccf9072f98d4e1013a180306e17d244830b039"
                        "86ee5e8eabeb6156"
                    ),
                    "url": "https://github.com/tamasfe/taplo/releases/download/0.10.0/taplo-linux-x86_64.gz",
                },
            },
            "environment": "FLASH_AUTOMATION_TAPLO",
            "version": "0.10.0",
        },
    },
}

BANNED_EXTERNAL_POLICY_MARKERS = (
    "def fail(",
    "keys_are(",
    "nonempty_string(",
    "string_list(",
    "valid_hex(",
    " or error(",
    " or fail(",
)

TRANSITIONAL_NON_FLASH = {
    "ci/check_public_automation.py",
    "ci/tests/test_check_public_automation.py",
}

BOOTSTRAP_ADAPTER = {"install-flash.sh"}

NATIVE_FLASH = {
    "recipes/groups/auto-test/auto-test.fsh",
    "recipes/tests/acid/acid-runner.fsh",
    "recipes/tests/os-test-bins/os-test-runner.fsh",
    "recipes/tests/relibc-tests-bins/relibc-tests-runner.fsh",
}

HOST_INTERFACE = {
    "bin/aarch64-unknown-redox-llvm-config",
    "bin/aarch64-unknown-redox-pkg-config",
    "bin/i586-unknown-redox-llvm-config",
    "bin/i586-unknown-redox-pkg-config",
    "bin/i686-unknown-redox-pkg-config",
    "bin/riscv64-unknown-redox-pkg-config",
    "bin/x86_64-unknown-redox-llvm-config",
    "bin/x86_64-unknown-redox-pkg-config",
    "components/flash/benchmarks/run.py",
    "components/flash/exercises/run.py",
    "components/flash/fuzz/run-campaign.sh",
    "components/flash/fuzz/run-smoke.sh",
    "components/flash/scheduling/run-campaign.sh",
    "flashos.ipxe",
    "flashos.sh",
    "flashos.zsh",
    "install-flash.sh",
    "native_bootstrap.sh",
    "podman/rustinstall.sh",
    "podman_bootstrap.sh",
    "recipes/terminal/bash/etc/bash.bashrc",
    "recipes/terminal/bash/etc/profile",
    "recipes/terminal/bash/etc/skel/.bashrc",
    "recipes/terminal/bash/etc/skel/.profile",
    "scripts/backtrace.sh",
    "scripts/cargo-update.sh",
    "scripts/category.sh",
    "scripts/changelog.sh",
    "scripts/commit-hash.sh",
    "scripts/dual-boot.sh",
    "scripts/executables.sh",
    "scripts/fetch-changed.sh",
    "scripts/find-recipe.sh",
    "scripts/include-recipes.sh",
    "scripts/mount-redoxfs.sh",
    "scripts/network-boot.sh",
    "scripts/pkg-size.sh",
    "scripts/print-recipe.sh",
    "scripts/recipe-match.sh",
    "scripts/recipe-path.sh",
    "scripts/relibc-doc.sh",
    "scripts/show-package.sh",
    "scripts/ventoy.sh",
}

TEST_DATA = {
    "recipes/tests/hello-redox/files/test.js",
    "recipes/tests/hello-redox/files/test.lua",
    "recipes/tests/hello-redox/files/test.py",
}

NOT_A_SCRIPT = {"recipes/data/shared-mime-info/recipe.toml"}

SCRIPT_SUFFIXES = {
    ".bashrc",
    ".fsh",
    ".ion",
    ".ipxe",
    ".js",
    ".lua",
    ".profile",
    ".py",
    ".sh",
    ".zsh",
}

EXPECTED_EMBEDDED = {
    "cookbook-shell-body": 164,
    "docker-command": 1,
    "make-target": 23,
    "workflow-run-body": 84,
}

EXPECTED_INSTALLED_NON_FLASH = {
    (
        "recipes/text/helix/recipe.toml",
        "echo '#!/usr/bin/env bash' > \"${COOKBOOK_STAGE}/usr/bin/hx\"",
    )
}

NATIVE_INSTALLS = {
    "recipes/groups/auto-test/recipe.toml": (
        "auto-test.fsh",
        '"flash"',
    ),
    "recipes/tests/acid/recipe.toml": (
        "acid-runner.fsh",
        'dependencies = ["flash", "rust"]',
    ),
    "recipes/tests/os-test-bins/recipe.toml": (
        "os-test-runner.fsh",
        '    "flash",',
    ),
    "recipes/tests/relibc-tests-bins/recipe.toml": (
        "relibc-tests-runner.fsh",
        'dependencies = ["flash", "gnu-make"]',
    ),
}


@dataclass(frozen=True)
class Inventory:
    dispositions: Counter[str]
    embedded: dict[str, int]
    installed_non_flash: set[tuple[str, str]]


def fail(message: str) -> None:
    print(f"public automation contract: {message}", file=sys.stderr)
    raise SystemExit(1)


def repository_files(root: Path = ROOT) -> tuple[str, ...]:
    process = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        fail(process.stderr.decode(errors="replace").strip() or "git ls-files failed")
    return tuple(
        sorted(
            raw.decode("utf-8")
            for raw in process.stdout.split(b"\0")
            if raw and (root / raw.decode("utf-8")).is_file()
        )
    )


def is_test_data(path: str) -> bool:
    return path in TEST_DATA or (
        path.startswith("components/flash/tests/golden/") and path.endswith(".fsh")
    )


def disposition(path: str) -> str | None:
    if path in MIGRATION_BASELINE:
        return "migration-pending"
    if path in MIGRATION_TARGETS.values():
        return "migrated-flash"
    if path in RETAINED_BASELINE:
        return "reviewed-exception"
    if path in TRANSITIONAL_NON_FLASH:
        return "transitional-non-flash"
    if path in BOOTSTRAP_ADAPTER:
        return "bootstrap-adapter"
    if path in NATIVE_FLASH:
        return "native-flash"
    if path in SHARED_FLASH_MODULES:
        return "shared-flash-module"
    if is_test_data(path):
        return "generated-or-test-data"
    if path in NOT_A_SCRIPT:
        return "not-a-script"
    if path in HOST_INTERFACE:
        return "host-or-tool-interface"
    return None


def is_standalone_surface(path: str, source: bytes, executable: bool) -> bool:
    suffix = PurePosixPath(path).suffix
    first = source.splitlines()[0] if source.splitlines() else b""
    interpreter = first.startswith(b"#!/") or first == b"#!ipxe"
    return executable or interpreter or suffix in SCRIPT_SUFFIXES


def scan(root: Path = ROOT) -> Inventory:
    dispositions: Counter[str] = Counter()
    unclassified: list[str] = []
    recipe_bodies = 0
    workflow_bodies = 0
    make_targets = 0
    docker_commands = 0
    installed_non_flash: set[tuple[str, str]] = set()

    for path in repository_files(root):
        absolute = root / path
        source = absolute.read_bytes()
        executable = bool(absolute.stat().st_mode & 0o111)
        if is_standalone_surface(path, source, executable):
            selected = disposition(path)
            if selected is None:
                unclassified.append(path)
            else:
                dispositions[selected] += 1

        text = source.decode("utf-8", errors="replace")
        if path.endswith("/recipe.toml"):
            recipe_bodies += sum(
                bool(re.match(r'^script\s*=\s*"""', line)) for line in text.splitlines()
            )
            for line in text.splitlines():
                stripped = line.strip()
                if stripped.startswith("#!") or re.search(r"echo\s+['\"]#!", stripped):
                    installed_non_flash.add((path, stripped))
        elif path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml")):
            workflow_bodies += sum(
                bool(re.match(r"^\s+run:\s*", line)) for line in text.splitlines()
            )
        elif PurePosixPath(path).name == "Makefile":
            make_targets += sum(
                bool(re.match(r"^[A-Za-z0-9_.%/ -]+:(?:[^=]|$)", line))
                for line in text.splitlines()
            )
        elif PurePosixPath(path).name == "Dockerfile":
            docker_commands += sum(
                bool(re.match(r"^(?:RUN|CMD|ENTRYPOINT)\b", line))
                for line in text.splitlines()
            )

    if unclassified:
        fail(f"unclassified standalone surfaces: {unclassified!r}")

    return Inventory(
        dispositions,
        {
            "cookbook-shell-body": recipe_bodies,
            "docker-command": docker_commands,
            "make-target": make_targets,
            "workflow-run-body": workflow_bodies,
        },
        installed_non_flash,
    )


def baseline_sources(root: Path = ROOT) -> frozenset[str]:
    process = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", BASELINE_COMMIT],
        cwd=root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if process.returncode != 0:
        fail(process.stderr.strip() or f"cannot read baseline {BASELINE_COMMIT}")
    return frozenset(
        path for path in process.stdout.splitlines() if path.endswith((".sh", ".py"))
    )


def validate_expanded_contract(
    root: Path = ROOT, *, allow_incomplete: bool = False
) -> tuple[int, tuple[str, ...]]:
    schema = EXPANDED_CONTRACT["schema"]
    denominator = EXPANDED_CONTRACT["denominator"]
    minimum = EXPANDED_CONTRACT["minimum_migrations"]
    if schema != 1 or denominator != 68 or minimum != 51:
        fail(
            "expanded quantitative contract drifted: "
            f"schema={schema!r}, denominator={denominator!r}, minimum={minimum!r}"
        )

    declared = MIGRATION_BASELINE | RETAINED_BASELINE.keys()
    observed_baseline = baseline_sources(root)
    if declared != observed_baseline:
        fail(
            "expanded baseline paths drifted: "
            f"missing={sorted(observed_baseline - declared)!r}, "
            f"extra={sorted(declared - observed_baseline)!r}"
        )
    if len(MIGRATION_BASELINE) != 60 or len(RETAINED_BASELINE) != 8:
        fail(
            "expanded disposition counts drifted: "
            f"migrations={len(MIGRATION_BASELINE)}, exceptions={len(RETAINED_BASELINE)}"
        )
    if len(MIGRATION_BASELINE) < int(minimum):
        fail("expanded migration plan fell below the 75% floor")
    if len(set(MIGRATION_TARGETS.values())) != len(MIGRATION_TARGETS):
        fail("two baseline sources select the same Flash migration target")
    if len(SHARED_FLASH_MODULES) != 5:
        fail(
            "shared Flash module contract drifted: "
            f"observed={sorted(SHARED_FLASH_MODULES)!r}"
        )
    for module in sorted(SHARED_FLASH_MODULES):
        path = root / module
        if not path.is_file():
            fail(f"shared Flash module is missing: {module}")
        if path.stat().st_mode & 0o111:
            fail(f"shared Flash module must not be executable: {module}")
        if path.read_bytes().startswith(b"#!"):
            fail(f"shared Flash module must not declare an interpreter: {module}")
    if TOOL_CONTRACT != EXPECTED_TOOL_CONTRACT:
        fail(f"automation tool contract drifted: {TOOL_CONTRACT!r}")

    flash_sources = [
        *(root / module for module in sorted(SHARED_FLASH_MODULES)),
        *(
            root / target
            for target in sorted(MIGRATION_TARGETS.values())
            if (root / target).is_file()
        ),
    ]
    for path in flash_sources:
        source = path.read_text(encoding="utf-8")
        markers = [
            marker for marker in BANNED_EXTERNAL_POLICY_MARKERS if marker in source
        ]
        if markers:
            fail(
                "external parser owns migrated policy: "
                f"{path.relative_to(root)} contains {markers!r}"
            )

    migrated: list[str] = []
    pending: list[str] = []
    for source in sorted(MIGRATION_BASELINE):
        target = MIGRATION_TARGETS[source]
        source_exists = (root / source).is_file()
        target_exists = (root / target).is_file()
        if source_exists and target_exists:
            if allow_incomplete:
                pending.append(source)
                continue
            fail(
                f"migration keeps both original and Flash target: {source} -> {target}"
            )
        if not source_exists and not target_exists:
            fail(
                f"migration has neither original nor Flash target: {source} -> {target}"
            )
        if target_exists:
            migrated.append(source)
        else:
            pending.append(source)

    for source in sorted(RETAINED_BASELINE):
        if not (root / source).is_file():
            fail(f"reviewed exception is no longer present: {source}")

    transitional = sorted(
        path for path in TRANSITIONAL_NON_FLASH if (root / path).is_file()
    )
    incomplete = len(migrated) < int(minimum) or bool(pending) or bool(transitional)
    if incomplete and not allow_incomplete:
        fail(
            "expanded migration is incomplete: "
            f"migrated={len(migrated)}/60, pending={len(pending)}, "
            f"transitional_non_flash={transitional!r}"
        )
    return len(migrated), tuple(pending)


def validate(
    inventory: Inventory,
    root: Path = ROOT,
    *,
    allow_incomplete: bool = False,
) -> None:
    expanded_total = sum(
        inventory.dispositions[name]
        for name in ("migration-pending", "migrated-flash", "reviewed-exception")
    )
    coexistence = sum(
        (root / source).is_file() and (root / target).is_file()
        for source, target in MIGRATION_TARGETS.items()
    )
    expected_total = 68 + (coexistence if allow_incomplete else 0)
    if expanded_total != expected_total:
        fail(
            "expanded standalone inventory drifted: "
            f"observed={expanded_total}, expected={expected_total}"
        )
    if inventory.dispositions["reviewed-exception"] != 8:
        fail(
            "reviewed exception count drifted: "
            f"observed={inventory.dispositions['reviewed-exception']}, expected=8"
        )
    if inventory.dispositions["bootstrap-adapter"] != 1:
        fail(
            "bootstrap adapter count drifted: "
            f"observed={inventory.dispositions['bootstrap-adapter']}, expected=1"
        )
    validate_expanded_contract(root, allow_incomplete=allow_incomplete)
    if inventory.embedded != EXPECTED_EMBEDDED:
        fail(
            f"embedded surface counts drifted: observed={inventory.embedded!r}, "
            f"expected={EXPECTED_EMBEDDED!r}"
        )
    if inventory.installed_non_flash != EXPECTED_INSTALLED_NON_FLASH:
        fail(
            "installed non-Flash script exceptions drifted: "
            f"{sorted(inventory.installed_non_flash)!r}"
        )

    for relative in NATIVE_FLASH:
        source = (root / relative).read_text(encoding="utf-8")
        if not source.startswith("#!/usr/bin/fsh\n"):
            fail(f"native target script lacks stable interpreter: {relative}")
    for relative, required in NATIVE_INSTALLS.items():
        text = (root / relative).read_text(encoding="utf-8")
        for marker in required:
            if marker not in text:
                fail(f"{relative} lacks native install contract {marker!r}")

    attributes = (root / ".gitattributes").read_text(encoding="utf-8").splitlines()
    if "*.fsh linguist-language=Shell" not in attributes:
        fail(".gitattributes does not classify .fsh as Shell")

    installer = root / "install-flash.sh"
    installer_source = installer.read_text(encoding="utf-8")
    if not os.access(installer, os.X_OK) or not installer_source.startswith(
        "#!/usr/bin/env bash\n"
    ):
        fail("install-flash.sh must be an executable Bash bootstrap adapter")
    for marker in (
        "cargo install",
        "--locked",
        "--path crates/flash-cli",
        "--bin fsh",
        "fsh 1.0.0",
        'install -m 0755 "$runtime" "$prefix/bin/fsh"',
    ):
        if marker not in installer_source:
            fail(f"install-flash.sh lacks acquisition contract {marker!r}")
    for forbidden in ("build.fsh", "make ", "ARCH", "CONFIG_NAME", "FILESYSTEM_CONFIG"):
        if forbidden in installer_source:
            fail(f"install-flash.sh owns forbidden build policy {forbidden!r}")

    qemu_source = (root / "ci/qemu_smoke.py").read_text(encoding="utf-8")
    for relative in NATIVE_FLASH:
        if relative not in qemu_source:
            fail(f"QEMU does not load exact native source: {relative}")
    for marker in ("AUTOMATION-CARGO", "AUTOMATION-RELIBC", "AUTOMATION-OS"):
        if marker not in qemu_source:
            fail(f"QEMU public automation marker is missing: {marker}")


def run_process(
    command: list[str | Path],
    *,
    cwd: Path = ROOT,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(item) for item in command],
        cwd=cwd,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )


def checked_runtime_process(
    command: list[str | Path],
    *,
    label: str,
    cwd: Path = ROOT,
    environment: dict[str, str] | None = None,
    input_text: str | None = None,
    timeout_seconds: int = 30,
) -> subprocess.CompletedProcess[str]:
    try:
        process = subprocess.run(
            [str(item) for item in command],
            cwd=cwd,
            env=environment,
            input=input_text,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
            timeout=timeout_seconds,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"{label} could not be observed safely: {error}")
    captured = len(process.stdout.encode()) + len(process.stderr.encode())
    if captured > MAX_RUNTIME_CAPTURE:
        fail(
            f"{label} exceeded the {MAX_RUNTIME_CAPTURE}-byte capture limit: "
            f"observed={captured}"
        )
    return process


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def candidate_source_digest(root: Path = ROOT) -> str:
    paths = run_process(["git", "ls-files", "-co", "--exclude-standard"], cwd=root)
    if paths.returncode != 0:
        fail(f"cannot enumerate candidate sources: {paths.stderr.strip()}")
    digest = hashlib.sha256()
    for relative in sorted(filter(None, paths.stdout.splitlines())):
        if relative.startswith("components/flash/target/"):
            continue
        if relative == "components/flash/exercises/evidence/host-v1.json":
            continue
        path = root / relative
        if not path.is_file():
            continue
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def validate_runtime_binary(runtime: Path, *, label: str) -> Path:
    if runtime.is_symlink():
        fail(f"{label} must not be a symlink: {runtime}")
    runtime = runtime.resolve()
    if not runtime.is_file():
        fail(f"{label} does not exist: {runtime}")
    if not os.access(runtime, os.X_OK):
        fail(f"{label} is not executable: {runtime}")

    version = checked_runtime_process([runtime, "--version"], label=f"{label} version")
    require_process(
        version,
        code=0,
        stdout=f"{FLASH_V1_VERSION}\n",
        stderr="",
        label=f"{label} version",
    )
    with tempfile.TemporaryDirectory(prefix="flash-runtime-refusal-") as raw:
        invalid = Path(raw) / "invalid.fsh"
        invalid.write_text("let invalid = 1 < 2 < 3\n", encoding="utf-8")
        refusal = checked_runtime_process(
            [runtime, invalid],
            label=f"{label} invalid-source refusal",
        )
    if (
        refusal.returncode != 1
        or refusal.stdout
        or "comparison operators are non-associative" not in refusal.stderr
    ):
        fail(
            f"{label} accepted or corrupted a known invalid source: "
            f"observed={(refusal.returncode, refusal.stdout, refusal.stderr)!r}"
        )
    return runtime


def validate_bootstrap_runtime(runtime: Path, root: Path = ROOT) -> Path:
    runtime = validate_runtime_binary(runtime, label="Flash bootstrap runtime")
    manifest_path = runtime.parent / "manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        fail(f"Flash bootstrap manifest is missing or unsafe: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_keys = {
        "binary_sha256",
        "rust_toolchain",
        "schema",
        "source_commit",
        "source_tree",
        "version",
    }
    if set(manifest) != expected_keys:
        fail(f"Flash bootstrap manifest keys drifted: {sorted(manifest)!r}")
    if (
        manifest["schema"] != 1
        or manifest["source_commit"] != BASELINE_COMMIT
        or manifest["source_tree"] != BASELINE_TREE
        or manifest["rust_toolchain"] != BASELINE_RUST_TOOLCHAIN
        or manifest["version"] != FLASH_V1_VERSION
    ):
        fail(f"Flash bootstrap manifest identity drifted: {manifest!r}")
    observed_digest = sha256_file(runtime)
    if manifest["binary_sha256"] != observed_digest:
        fail(
            "Flash bootstrap binary digest differs: "
            f"manifest={manifest['binary_sha256']!r}, observed={observed_digest!r}"
        )
    tree = run_process(["git", "rev-parse", f"{BASELINE_COMMIT}^{{tree}}"], cwd=root)
    require_process(
        tree,
        code=0,
        stdout=f"{BASELINE_TREE}\n",
        stderr="",
        label="Flash bootstrap baseline tree",
    )
    return runtime


def require_process(
    process: subprocess.CompletedProcess[str],
    *,
    code: int,
    stdout: str,
    stderr: str,
    label: str,
) -> None:
    observed = (process.returncode, process.stdout, process.stderr)
    expected = (code, stdout, stderr)
    if observed != expected:
        fail(f"{label} parity differs: observed={observed!r}, expected={expected!r}")


def read_report(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def write_probe(path: Path) -> None:
    source = f"""#!{sys.executable}
import json
import os
import pathlib
import sys

name = pathlib.Path(sys.argv[0]).name
record = {{
    "argv": sys.argv,
    "cwd": os.getcwd(),
    "name": name,
    "rust_backtrace": os.environ.get("RUST_BACKTRACE"),
}}
with open(os.environ["PUBLIC_AUTOMATION_REPORT"], "a", encoding="utf-8") as out:
    out.write(json.dumps(record, sort_keys=True) + "\\n")
print(f"stdout:{{name}}")
print(f"stderr:{{name}}", file=sys.stderr)
codes = json.loads(os.environ["PUBLIC_AUTOMATION_CODES"])
raise SystemExit(codes.get(name, 0))
"""
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def runtime_environment(
    directory: Path,
    report: Path,
    codes: dict[str, int],
) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": str(directory),
            "PUBLIC_AUTOMATION_CODES": json.dumps(codes, sort_keys=True),
            "PUBLIC_AUTOMATION_REPORT": str(report),
        }
    )
    environment.pop("RUST_BACKTRACE", None)
    return environment


def write_host_probe(directory: Path, command: str) -> None:
    source = f"""#!{sys.executable}
import json
import os
import pathlib
import sys

name = pathlib.Path(sys.argv[0]).name
scenario = json.loads(os.environ.get("PUBLIC_AUTOMATION_SCENARIO", "{{}}"))
report = pathlib.Path(os.environ["PUBLIC_AUTOMATION_REPORT"])
record = {{
    "argv": sys.argv[1:],
    "cases": os.environ.get("FLASH_PTY_STRESS_CASES"),
    "cwd": os.getcwd(),
    "name": name,
    "seed": os.environ.get("FLASH_PTY_STRESS_CAMPAIGN_SEED"),
}}
with report.open("a", encoding="utf-8") as output:
    output.write(json.dumps(record, sort_keys=True) + "\\n")

codes = scenario.get("codes", {{}})
if name == "rustup":
    if codes.get(name, 0) == 0:
        print(pathlib.Path(os.environ["PUBLIC_AUTOMATION_PROBE_DIR"]) / "cargo")
    raise SystemExit(codes.get(name, 0))
if name == "cargo":
    if sys.argv[1:] == ["--version"]:
        if codes.get("cargo-version", 0) == 0:
            print("cargo 1.98.0-test")
        raise SystemExit(codes.get("cargo-version", 0))
    cargo_runs = 0
    for line in report.read_text(encoding="utf-8").splitlines():
        item = json.loads(line)
        if item["name"] == "cargo" and item["argv"] != ["--version"]:
            cargo_runs += 1
    sys.stdout.write(scenario.get("cargo_stdout", ""))
    sys.stderr.write(scenario.get("cargo_stderr", ""))
    if cargo_runs == scenario.get("cargo_fail_call"):
        raise SystemExit(scenario.get("cargo_fail_code", 1))
    raise SystemExit(codes.get(name, 0))
if name == "date":
    value = (
        "20260825T120000Z"
        if "+%Y%m%dT%H%M%SZ" in sys.argv
        else "2026-08-25T12:00:00Z"
    )
    if codes.get(name, 0) == 0:
        print(value)
    raise SystemExit(codes.get(name, 0))
if name == "uname":
    if codes.get(name, 0) == 0:
        print("FlashOS-test-host")
    raise SystemExit(codes.get(name, 0))
if name == "rustc":
    if codes.get(name, 0) == 0:
        print("rustc 1.97.1-test")
    raise SystemExit(codes.get(name, 0))
if name == "od":
    if codes.get(name, 0) == 0:
        print(scenario.get("seed", "123456789"))
    raise SystemExit(codes.get(name, 0))
raise SystemExit(codes.get(name, 0))
"""
    path = directory / command
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def write_build_make_probe(path: Path) -> None:
    source = f"""#!{sys.executable}
import json
import os
import pathlib
import sys

scenario = json.loads(os.environ.get("PUBLIC_AUTOMATION_SCENARIO", "{{}}"))
report = pathlib.Path(os.environ["PUBLIC_AUTOMATION_REPORT"])
record = {{
    "argv": sys.argv[1:],
    "arch": os.environ.get("ARCH"),
    "config_name": os.environ.get("CONFIG_NAME"),
    "cwd": os.getcwd(),
    "filesystem_config": os.environ.get("FILESYSTEM_CONFIG"),
}}
with report.open("a", encoding="utf-8") as output:
    output.write(json.dumps(record, sort_keys=True) + "\\n")

effect = scenario.get("effect")
if effect:
    destination = pathlib.Path(os.environ["PUBLIC_AUTOMATION_EFFECT_ROOT"]) / effect
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(scenario.get("effect_text", "effect\\n"), encoding="utf-8")
sys.stdout.write(scenario.get("stdout", ""))
sys.stderr.write(scenario.get("stderr", ""))
raise SystemExit(scenario.get("code", 0))
"""
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def build_probe_environment(
    directory: Path,
    report: Path,
    effect_root: Path,
    scenario: dict[str, object],
) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": os.pathsep.join([str(directory), environment.get("PATH", "")]),
            "PUBLIC_AUTOMATION_EFFECT_ROOT": str(effect_root),
            "PUBLIC_AUTOMATION_REPORT": str(report),
            "PUBLIC_AUTOMATION_SCENARIO": json.dumps(scenario, sort_keys=True),
        }
    )
    for name in ("ARCH", "CONFIG_NAME", "FILESYSTEM_CONFIG"):
        environment.pop(name, None)
    return environment


def normalize_build_interface_output(value: str) -> str:
    return (
        value.replace("build.sh:      ", "build.fsh:     ")
        .replace("./build.sh", "./build.fsh")
        .replace(
            "\n                                 run it",
            "\n                                  run it",
        )
    )


def check_build_interface_parity(runtime: Path, root: Path) -> None:
    cases: tuple[tuple[str, list[str], dict[str, object]], ...] = (
        (
            "default environment and make failure",
            ["all", "FEATURE=value"],
            {
                "code": 7,
                "effect": "default/result.txt",
                "effect_text": "default effect\n",
                "stderr": "make stderr\n",
                "stdout": "make stdout\n",
            },
        ),
        ("explicit architecture and config", ["-A", "-c", "release", "qemu"], {}),
        (
            "filesystem-derived architecture and config",
            ["-c", "ignored", "-f", "config/aarch64/custom.toml", "live"],
            {},
        ),
        ("attached options", ["-Xcflashos", "all"], {"code": 3}),
        ("option boundary", ["--", "-R", "target"], {}),
        ("unsupported advertised option", ["-R", "all"], {}),
        ("missing option value", ["-c"], {}),
        ("first help", ["--help"], {}),
        ("combined help continues", ["-Xh", "all"], {}),
    )
    migrated = root / "build.fsh"
    for label, arguments, scenario in cases:
        with tempfile.TemporaryDirectory(prefix="flash-build-parity-") as raw:
            directory = Path(raw).resolve()
            oracle = directory / "build.sh"
            materialize_baseline_source("build.sh", oracle, root)
            write_build_make_probe(directory / "make")
            report = directory / "report.jsonl"
            report.write_text("", encoding="utf-8")
            effect_root = directory / "effects"
            environment = build_probe_environment(
                directory, report, effect_root, scenario
            )

            baseline = checked_runtime_process(
                [oracle, *arguments],
                cwd=directory,
                environment=environment,
                label=f"baseline build interface {label}",
            )
            baseline_records = read_report(report)
            baseline_effects = filesystem_snapshot(effect_root)

            shutil.rmtree(effect_root, ignore_errors=True)
            report.write_text("", encoding="utf-8")
            migrated_result = checked_runtime_process(
                [runtime, migrated, *arguments],
                cwd=directory,
                environment=environment,
                label=f"migrated build interface {label}",
            )
            migrated_records = read_report(report)
            migrated_effects = filesystem_snapshot(effect_root)
            observed = (
                migrated_result.returncode,
                migrated_result.stdout,
                migrated_result.stderr,
                migrated_records,
                migrated_effects,
            )
            expected = (
                baseline.returncode,
                normalize_build_interface_output(baseline.stdout),
                normalize_build_interface_output(baseline.stderr),
                baseline_records,
                baseline_effects,
            )
            if observed != expected:
                fail(
                    f"build interface materialized-oracle parity differs for {label}: "
                    f"observed={observed!r}, expected={expected!r}"
                )


def write_install_cargo_probe(path: Path) -> None:
    source = f"""#!{sys.executable}
import json
import os
import pathlib
import sys

scenario = json.loads(os.environ.get("PUBLIC_AUTOMATION_SCENARIO", "{{}}"))
report = pathlib.Path(os.environ["PUBLIC_AUTOMATION_REPORT"])
with report.open("a", encoding="utf-8") as output:
    record = {{"argv": sys.argv[1:], "cwd": os.getcwd()}}
    output.write(json.dumps(record, sort_keys=True) + "\\n")
code = scenario.get("cargo_code", 0)
if code:
    raise SystemExit(code)
arguments = sys.argv[1:]
root = pathlib.Path(arguments[arguments.index("--root") + 1])
runtime = root / "bin/fsh"
runtime.parent.mkdir(parents=True, exist_ok=True)
version = scenario.get("version", "fsh 1.0.0")
runtime.write_text(
    "#!/bin/sh\\n"
    "if [ \\\"$1\\\" = --version ]; then printf '%s\\n' "
    + json.dumps(version)
    + "; exit 0; fi\\nexit 0\\n",
    encoding="utf-8",
)
runtime.chmod(0o755)
"""
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def check_install_flash_adapter(root: Path = ROOT) -> None:
    cases: tuple[tuple[str, list[str], dict[str, object], int], ...] = (
        ("success", [], {}, 0),
        ("wrong version", [], {"version": "fsh 9.9.9"}, 1),
        ("cargo failure", [], {"cargo_code": 9}, 9),
        ("argument refusal", ["unexpected"], {}, 2),
    )
    for label, arguments, scenario, expected_code in cases:
        with tempfile.TemporaryDirectory(prefix="flash-install-parity-") as raw:
            directory = Path(raw).resolve()
            bin_directory = directory / "bin"
            bin_directory.mkdir()
            write_install_cargo_probe(bin_directory / "cargo")
            report = directory / "report.jsonl"
            report.write_text("", encoding="utf-8")
            prefix = directory / "prefix"
            environment = os.environ.copy()
            environment.update(
                {
                    "FLASH_INSTALL_PREFIX": str(prefix),
                    "PATH": os.pathsep.join(
                        [str(bin_directory), environment.get("PATH", "")]
                    ),
                    "PUBLIC_AUTOMATION_REPORT": str(report),
                    "PUBLIC_AUTOMATION_SCENARIO": json.dumps(
                        scenario, sort_keys=True
                    ),
                    "TMPDIR": str(directory),
                }
            )
            process = checked_runtime_process(
                [root / "install-flash.sh", *arguments],
                cwd=directory,
                environment=environment,
                label=f"install-flash adapter {label}",
            )
            if process.returncode != expected_code:
                observed = (process.returncode, process.stdout, process.stderr)
                fail(
                    f"install-flash adapter {label} status differs: "
                    f"observed={observed!r}, "
                    f"expected={expected_code}"
                )
            records = read_report(report)
            installed = prefix / "bin/fsh"
            if label == "success":
                expected_stdout = (
                    f"install-flash: installed fsh 1.0.0 at {installed}\n"
                )
                if process.stdout != expected_stdout or process.stderr:
                    fail(
                        "install-flash success output differs: "
                        f"observed={(process.stdout, process.stderr)!r}"
                    )
                if not installed.is_file() or not os.access(installed, os.X_OK):
                    fail("install-flash did not install an executable runtime")
            else:
                if installed.exists():
                    fail(f"install-flash {label} installed an unverified runtime")
            if label == "wrong version" and process.stderr != (
                "install-flash: incompatible runtime: fsh 9.9.9\n"
            ):
                fail(
                    "install-flash wrong-version refusal differs: "
                    f"observed={process.stderr!r}"
                )
            if label == "argument refusal":
                if process.stdout or process.stderr != "usage: ./install-flash.sh\n":
                    fail(
                        "install-flash argument refusal differs: "
                        f"observed={(process.stdout, process.stderr)!r}"
                    )
                if records:
                    fail("install-flash argument refusal invoked Cargo")
            else:
                if len(records) != 1:
                    fail(f"install-flash {label} Cargo invocation differs: {records!r}")
                expected_argv = [
                    "install",
                    "--locked",
                    "--path",
                    "crates/flash-cli",
                    "--bin",
                    "fsh",
                    "--root",
                ]
                if records[0]["argv"][:-1] != expected_argv:
                    fail(f"install-flash {label} Cargo arguments differ: {records!r}")
                expected_cwd = (root / "components/flash").resolve()
                if Path(str(records[0]["cwd"])).resolve() != expected_cwd:
                    fail(f"install-flash {label} Cargo cwd differs: {records!r}")


def host_probe_environment(
    directory: Path,
    report: Path,
    scenario: dict[str, object] | None = None,
) -> dict[str, str]:
    for command in ("cargo", "date", "od", "rustc", "rustup", "uname"):
        write_host_probe(directory, command)
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": os.pathsep.join([str(directory), environment.get("PATH", "")]),
            "PUBLIC_AUTOMATION_PROBE_DIR": str(directory),
            "PUBLIC_AUTOMATION_REPORT": str(report),
            "PUBLIC_AUTOMATION_SCENARIO": json.dumps(scenario or {}, sort_keys=True),
        }
    )
    return environment


def require_paths(paths: list[Path], *, present: bool, label: str) -> None:
    mismatched = [str(path) for path in paths if path.exists() != present]
    if mismatched:
        expectation = "present" if present else "absent"
        fail(f"{label} paths are not {expectation}: {mismatched!r}")


def materialize_baseline_source(relative: str, destination: Path, root: Path) -> None:
    process = subprocess.run(
        ["git", "show", f"{BASELINE_COMMIT}:{relative}"],
        cwd=root,
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        fail(
            f"cannot materialize baseline parity oracle {relative}: "
            f"{process.stderr.decode(errors='replace').strip()}"
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(process.stdout)
    mode = subprocess.run(
        ["git", "ls-tree", BASELINE_COMMIT, relative],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if mode.returncode != 0 or not mode.stdout.startswith("100"):
        fail(f"cannot read baseline mode for {relative}")
    destination.chmod(0o755 if mode.stdout.startswith("100755") else 0o644)


def filesystem_snapshot(directory: Path) -> list[tuple[str, str, int, str]]:
    snapshot: list[tuple[str, str, int, str]] = []
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        mode = path.stat().st_mode & 0o777
        if path.is_dir():
            snapshot.append((relative, "directory", mode, ""))
        elif path.is_file() and not path.is_symlink():
            snapshot.append((relative, "file", mode, sha256_file(path)))
        else:
            fail(f"parity oracle produced an unsafe filesystem entry: {path}")
    return snapshot


def check_baseline_oracle_parity(runtime: Path, root: Path) -> None:
    cases = (
        (
            "components/flash/fuzz/run-campaign.sh",
            root / "components/flash/fuzz/run-campaign.fsh",
            ["3", "{campaign}"],
            {},
        ),
        (
            "components/flash/scheduling/run-campaign.sh",
            root / "components/flash/scheduling/run-campaign.fsh",
            ["2", "{campaign}", "123"],
            {"cargo_stdout": "stress-output\n"},
        ),
    )
    for relative, migrated, arguments, scenario in cases:
        with tempfile.TemporaryDirectory(prefix="flash-baseline-parity-") as raw:
            # macOS exposes temporary directories through both /var and
            # /private/var. Resolve once so the shell oracle and Flash runner
            # receive one canonical path in argv, cwd, and generated output.
            fake_root = Path(raw).resolve()
            oracle = fake_root / relative
            materialize_baseline_source(relative, oracle, root)
            report = fake_root / "report.jsonl"
            report.write_text("", encoding="utf-8")
            environment = host_probe_environment(
                fake_root,
                report,
                scenario,
            )
            campaign = fake_root / "campaign"
            selected_arguments = [
                str(campaign) if item == "{campaign}" else item for item in arguments
            ]
            baseline = checked_runtime_process(
                [oracle, *selected_arguments],
                cwd=fake_root,
                environment=environment,
                label=f"baseline oracle {relative}",
            )
            baseline_records = read_report(report)
            baseline_files = filesystem_snapshot(campaign)

            shutil.rmtree(campaign)
            report.write_text("", encoding="utf-8")
            migrated_result = checked_runtime_process(
                [runtime, migrated, *selected_arguments],
                cwd=fake_root,
                environment=environment,
                label=f"migrated oracle parity {relative}",
            )
            migrated_records = read_report(report)
            migrated_files = filesystem_snapshot(campaign)
            observed = (
                migrated_result.returncode,
                migrated_result.stdout,
                migrated_result.stderr,
                migrated_records,
                migrated_files,
            )
            expected = (
                baseline.returncode,
                baseline.stdout,
                baseline.stderr,
                baseline_records,
                baseline_files,
            )
            if observed != expected:
                fail(
                    f"baseline oracle parity differs for {relative}: "
                    f"observed={observed!r}, expected={expected!r}"
                )


def normalized_smoke_records(
    records: list[dict[str, object]],
) -> list[dict[str, object]]:
    cargo = [record for record in records if record["name"] == "cargo"]
    work_directories = {
        str(Path(str(record["argv"][5])).parent)
        for record in cargo
        if isinstance(record.get("argv"), list) and len(record["argv"]) > 5
    }
    if len(work_directories) != 1:
        fail(f"fuzz smoke oracle temporary directory differs: {records!r}")
    work = work_directories.pop()
    encoded = json.dumps(records, sort_keys=True).replace(work, "<work>")
    return json.loads(encoded)


def check_smoke_baseline_oracle_parity(runtime: Path, root: Path) -> None:
    relative = "components/flash/fuzz/run-smoke.sh"
    migrated = root / "components/flash/fuzz/run-smoke.fsh"
    cases = (
        ([], {}),
        (["1"], {"cargo_fail_call": 2, "cargo_fail_code": 7}),
    )
    with tempfile.TemporaryDirectory(prefix="flash-smoke-oracle-") as raw:
        fake_root = Path(raw).resolve()
        oracle = fake_root / relative
        materialize_baseline_source(relative, oracle, root)
        report = fake_root / "report.jsonl"
        temporary = fake_root / "temporary"
        temporary.mkdir()
        for arguments, scenario in cases:
            report.write_text("", encoding="utf-8")
            environment = host_probe_environment(fake_root, report, scenario)
            environment["TMPDIR"] = str(temporary)
            baseline = checked_runtime_process(
                [oracle, *arguments],
                cwd=fake_root,
                environment=environment,
                label="baseline oracle fuzz smoke",
            )
            baseline_records = normalized_smoke_records(read_report(report))
            if list(temporary.iterdir()):
                fail("baseline fuzz smoke oracle did not clean its temporary corpus")

            report.write_text("", encoding="utf-8")
            migrated_result = checked_runtime_process(
                [runtime, migrated, *arguments],
                cwd=fake_root,
                environment=environment,
                label="migrated oracle fuzz smoke",
            )
            migrated_records = normalized_smoke_records(read_report(report))
            if list(temporary.iterdir()):
                fail("migrated fuzz smoke did not clean its temporary corpus")

            observed = (
                migrated_result.returncode,
                migrated_result.stdout,
                migrated_result.stderr,
                migrated_records,
            )
            expected = (
                baseline.returncode,
                baseline.stdout,
                baseline.stderr,
                baseline_records,
            )
            if observed != expected:
                fail(
                    "baseline oracle parity differs for "
                    f"{relative}: observed={observed!r}, expected={expected!r}"
                )


def check_fuzz_campaign_parity(runtime: Path, root: Path) -> None:
    script = root / "components/flash/fuzz/run-campaign.fsh"
    usage = (
        "usage: components/flash/fuzz/run-campaign.fsh [seconds [result-directory]]\n"
    )
    invalid_cases = (
        (("0",), "duration must be a positive integer number of seconds\n"),
        (("abc",), "duration must be a positive integer number of seconds\n"),
        (("1", ""), "result directory must not be empty\n"),
        (("1", "result", "extra"), usage),
    )
    for arguments, stderr in invalid_cases:
        process = checked_runtime_process(
            [runtime, script, *arguments],
            cwd=root,
            label=f"fuzz campaign invalid {arguments!r}",
        )
        require_process(
            process,
            code=2,
            stdout="",
            stderr=stderr,
            label=f"fuzz campaign invalid {arguments!r}",
        )

    with tempfile.TemporaryDirectory(prefix="flash-fuzz-parity-") as raw:
        directory = Path(raw)
        report = directory / "report.jsonl"
        report.write_text("", encoding="utf-8")
        environment = host_probe_environment(directory, report)
        campaign = directory / "success"
        process = checked_runtime_process(
            [runtime, script, "3", campaign],
            cwd=root,
            environment=environment,
            label="fuzz campaign success",
        )
        require_process(
            process,
            code=0,
            stdout=f"campaign directory: {campaign}\n",
            stderr="",
            label="fuzz campaign success",
        )
        targets = ("lexer", "parser", "expander")
        require_paths(
            [
                campaign / kind / target
                for kind in ("corpus", "artifacts")
                for target in targets
            ],
            present=True,
            label="fuzz campaign success",
        )
        records = read_report(report)
        cargo = [record for record in records if record["name"] == "cargo"]
        if [record["argv"][4] for record in cargo] != list(targets):
            fail(f"fuzz campaign target order differs: {cargo!r}")
        for record, target in zip(cargo, targets, strict=True):
            expected = [
                "fuzz",
                "run",
                "--fuzz-dir",
                str(root / "components/flash/fuzz"),
                target,
                str(campaign / "corpus" / target),
                str(root / "components/flash/tests/golden/grammar/complete"),
                str(root / "components/flash/tests/golden/grammar/incomplete"),
                str(root / "components/flash/tests/golden/grammar/invalid"),
                str(root / "components/flash/tests/golden/lexical/complete"),
                str(root / "components/flash/tests/golden/lexical/incomplete"),
                str(root / "components/flash/tests/golden/lexical/invalid"),
                "--",
                "-max_total_time=3",
                "-max_len=4096",
                "-timeout=10",
                "-rss_limit_mb=2048",
                f"-artifact_prefix={campaign / 'artifacts' / target}/",
            ]
            if record["argv"] != expected or Path(str(record["cwd"])) != root:
                fail(f"fuzz campaign Cargo boundary differs: {record!r}")

        report.write_text("", encoding="utf-8")
        failure = directory / "failure"
        environment = host_probe_environment(
            directory,
            report,
            {"cargo_fail_call": 2, "cargo_fail_code": 7},
        )
        process = checked_runtime_process(
            [runtime, script, "3", failure],
            cwd=root,
            environment=environment,
            label="fuzz campaign Cargo failure",
        )
        require_process(
            process,
            code=7,
            stdout=f"campaign directory: {failure}\n",
            stderr="",
            label="fuzz campaign Cargo failure",
        )
        cargo = [record for record in read_report(report) if record["name"] == "cargo"]
        if len(cargo) != 2:
            fail(f"fuzz campaign did not stop at the second Cargo failure: {cargo!r}")
        require_paths(
            [failure / kind / "expander" for kind in ("corpus", "artifacts")],
            present=False,
            label="fuzz campaign failure ordering",
        )


def check_fuzz_smoke_parity(runtime: Path, root: Path) -> None:
    script = root / "components/flash/fuzz/run-smoke.fsh"
    error = "run count must be a nonnegative integer\n"
    for argument in ("-1", "abc", "1.5"):
        process = checked_runtime_process(
            [runtime, script, argument],
            cwd=root,
            label=f"fuzz smoke invalid {argument!r}",
        )
        require_process(
            process,
            code=2,
            stdout="",
            stderr=error,
            label=f"fuzz smoke invalid {argument!r}",
        )

    targets = ("lexer", "parser", "expander")
    success_cases = (
        ((), "1000"),
        (("",), "1000"),
        (("0",), "0"),
        (("1",), "1"),
    )
    with tempfile.TemporaryDirectory(prefix="flash-fuzz-smoke-") as raw:
        directory = Path(raw).resolve()
        report = directory / "report.jsonl"
        for index, (arguments, expected_runs) in enumerate(success_cases):
            report.write_text("", encoding="utf-8")
            temporary = directory / f"temporary-{index}"
            temporary.mkdir()
            environment = host_probe_environment(directory, report)
            environment["TMPDIR"] = str(temporary)
            process = checked_runtime_process(
                [runtime, script, *arguments],
                cwd=root,
                environment=environment,
                label=f"fuzz smoke success {arguments!r}",
            )
            require_process(
                process,
                code=0,
                stdout="",
                stderr="",
                label=f"fuzz smoke success {arguments!r}",
            )
            records = read_report(report)
            rustup = [record for record in records if record["name"] == "rustup"]
            if len(rustup) != 1 or rustup[0]["argv"] != [
                "which",
                "--toolchain",
                "nightly",
                "cargo",
            ]:
                fail(f"fuzz smoke nightly Cargo selection differs: {rustup!r}")
            cargo = [record for record in records if record["name"] == "cargo"]
            if [record["argv"][4] for record in cargo] != list(targets):
                fail(f"fuzz smoke target order differs: {cargo!r}")
            work_directories = {Path(str(record["argv"][5])).parent for record in cargo}
            if len(work_directories) != 1:
                fail(f"fuzz smoke temporary corpus differs: {cargo!r}")
            work = work_directories.pop()
            if work.parent != temporary or not work.name.startswith("flash-fuzz."):
                fail(f"fuzz smoke temporary corpus location differs: {work}")
            for record, target in zip(cargo, targets, strict=True):
                expected = [
                    "fuzz",
                    "run",
                    "--fuzz-dir",
                    str(root / "components/flash/fuzz"),
                    target,
                    str(work / target),
                    str(root / "components/flash/tests/golden/grammar/complete"),
                    str(root / "components/flash/tests/golden/grammar/incomplete"),
                    str(root / "components/flash/tests/golden/grammar/invalid"),
                    str(root / "components/flash/tests/golden/lexical/complete"),
                    str(root / "components/flash/tests/golden/lexical/incomplete"),
                    str(root / "components/flash/tests/golden/lexical/invalid"),
                    "--",
                    f"-runs={expected_runs}",
                    "-max_len=4096",
                    "-timeout=10",
                    "-rss_limit_mb=2048",
                ]
                if record["argv"] != expected or Path(str(record["cwd"])) != root:
                    fail(f"fuzz smoke Cargo boundary differs: {record!r}")
            if work.exists() or list(temporary.iterdir()):
                fail("fuzz smoke did not clean its successful temporary corpus")

        report.write_text("", encoding="utf-8")
        temporary = directory / "temporary-failure"
        temporary.mkdir()
        environment = host_probe_environment(
            directory,
            report,
            {
                "cargo_fail_call": 2,
                "cargo_fail_code": 7,
                "cargo_stderr": "fuzz-failure\n",
            },
        )
        environment["TMPDIR"] = str(temporary)
        process = checked_runtime_process(
            [runtime, script, "1"],
            cwd=root,
            environment=environment,
            label="fuzz smoke Cargo failure",
        )
        require_process(
            process,
            code=7,
            stdout="",
            stderr="fuzz-failure\nfuzz-failure\n",
            label="fuzz smoke Cargo failure",
        )
        cargo = [record for record in read_report(report) if record["name"] == "cargo"]
        if len(cargo) != 2:
            fail(f"fuzz smoke did not stop at the second Cargo failure: {cargo!r}")
        work = Path(str(cargo[0]["argv"][5])).parent
        if work.exists() or list(temporary.iterdir()):
            fail("fuzz smoke did not clean its failed temporary corpus")


def check_scheduling_campaign_parity(runtime: Path, root: Path) -> None:
    script = root / "components/flash/scheduling/run-campaign.fsh"
    usage = (
        "usage: components/flash/scheduling/run-campaign.fsh "
        "[cases [result-directory [campaign-seed]]]\n"
    )
    invalid_cases = (
        (("0",), "case count must be a positive integer\n"),
        (("000",), "case count must be a positive integer\n"),
        (("abc",), "case count must be a positive integer\n"),
        (("4097",), "case count must not exceed 4096\n"),
        (("1", ""), "result directory must not be empty\n"),
        (("1", "result", "seed", "extra"), usage),
    )
    for arguments, stderr in invalid_cases:
        process = checked_runtime_process(
            [runtime, script, *arguments],
            cwd=root,
            label=f"scheduling campaign invalid {arguments!r}",
        )
        require_process(
            process,
            code=2,
            stdout="",
            stderr=stderr,
            label=f"scheduling campaign invalid {arguments!r}",
        )

    with tempfile.TemporaryDirectory(prefix="flash-scheduling-parity-") as raw:
        directory = Path(raw)
        report = directory / "report.jsonl"
        report.write_text("", encoding="utf-8")
        environment = host_probe_environment(
            directory,
            report,
            {"cargo_stdout": "stress-output\n"},
        )
        campaign = directory / "success"
        process = checked_runtime_process(
            [runtime, script, "2", campaign, "123"],
            cwd=root,
            environment=environment,
            label="scheduling campaign success",
        )
        expected_stdout = (
            f"campaign directory: {campaign}\n"
            "campaign seed: 123\n"
            "cases per scenario: 2\n"
            "stress-output\n"
            "campaign result: passed\n"
            f"manifest: {campaign / 'manifest.txt'}\n"
            f"complete output: {campaign / 'output.log'}\n"
        )
        require_process(
            process,
            code=0,
            stdout=expected_stdout,
            stderr="",
            label="scheduling campaign success",
        )
        replay = (
            "FLASH_PTY_STRESS_CAMPAIGN_SEED=123 FLASH_PTY_STRESS_CASES=2 "
            "cargo test -p flash-cli --test pty stress_ -- --nocapture "
            "--test-threads=1"
        )
        expected_manifest = (
            "Flash scheduling stress campaign\n"
            "started_utc=2026-08-25T12:00:00Z\n"
            "campaign_seed=123\n"
            "cases_per_scenario=2\n"
            "scenarios=4\n"
            "host=FlashOS-test-host\n"
            "rustc=rustc 1.97.1-test\n"
            "cargo=cargo 1.98.0-test\n"
            f"workspace={root / 'components/flash'}\n"
            f"replay={replay}\n"
            "finished_utc=2026-08-25T12:00:00Z\n"
            "result=passed\n"
        )
        if (campaign / "manifest.txt").read_text() != expected_manifest:
            fail("scheduling campaign manifest differs")
        if (campaign / "output.log").read_text() != "stress-output\n":
            fail("scheduling campaign complete output differs")
        records = read_report(report)
        cargo = [
            record
            for record in records
            if record["name"] == "cargo" and record["argv"] != ["--version"]
        ]
        expected_argv = [
            "test",
            "-p",
            "flash-cli",
            "--test",
            "pty",
            "stress_",
            "--",
            "--nocapture",
            "--test-threads=1",
        ]
        if len(cargo) != 1 or cargo[0] != {
            "argv": expected_argv,
            "cases": "2",
            "cwd": str(root / "components/flash"),
            "name": "cargo",
            "seed": "123",
        }:
            fail(f"scheduling campaign Cargo boundary differs: {cargo!r}")

        report.write_text("", encoding="utf-8")
        failure = directory / "failure"
        environment = host_probe_environment(
            directory,
            report,
            {
                "cargo_fail_call": 1,
                "cargo_fail_code": 101,
                "cargo_stderr": "stress-failure\n",
            },
        )
        process = checked_runtime_process(
            [runtime, script, "2", failure, "123"],
            cwd=root,
            environment=environment,
            label="scheduling campaign Cargo failure",
        )
        expected_stdout = (
            f"campaign directory: {failure}\n"
            "campaign seed: 123\n"
            "cases per scenario: 2\n"
            "stress-failure\n"
            "campaign result: failed\n"
            f"manifest: {failure / 'manifest.txt'}\n"
            f"complete output: {failure / 'output.log'}\n"
        )
        require_process(
            process,
            code=101,
            stdout=expected_stdout,
            stderr="",
            label="scheduling campaign Cargo failure",
        )
        if not (failure / "manifest.txt").read_text().endswith("result=failed\n"):
            fail("scheduling campaign failure manifest lacks the result footer")
        if (failure / "output.log").read_text() != "stress-failure\n":
            fail("scheduling campaign failure output differs")


def check_exercise_runner_parity(
    runtime: Path,
    bootstrap_runtime: Path,
    root: Path,
) -> None:
    script = root / "components/flash/exercises/run.fsh"
    inventory_path = root / "components/flash/exercises/host-cases-v1.json"
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory(prefix="flash-exercise-parity-") as raw:
        directory = Path(raw)
        record = directory / "record.json"
        environment = os.environ.copy()
        environment["FLASH_V1_BOOTSTRAP_FSH"] = str(bootstrap_runtime)
        process = checked_runtime_process(
            [runtime, script, "--profile", "smoke", "--no-build", "--record", record],
            cwd=root,
            environment=environment,
            label="Flash v1 native exercise smoke",
        )
        expected_stdout = (
            "".join(
                f"Flash v1 exercise: {identifier}\n"
                for identifier in inventory["smoke_cases"]
            )
            + "Flash v1 exercises: 15 assembled host cases passed\n"
        )
        require_process(
            process,
            code=0,
            stdout=expected_stdout,
            stderr="",
            label="Flash v1 native exercise smoke",
        )
        report = json.loads(record.read_text(encoding="utf-8"))
        result_ids = [result["id"] for result in report.get("results", [])]
        if result_ids != inventory["smoke_cases"]:
            fail(f"Flash v1 native exercise case order differs: {result_ids!r}")
        if any(result.get("result") != "pass" for result in report["results"]):
            fail("Flash v1 native exercise smoke contains an unsuccessful result")
        if report.get("contract_cases") != inventory["owners"]:
            fail("Flash v1 native exercise owner map differs")
        if report.get("environment", {}).get("flash") != FLASH_V1_VERSION:
            fail("Flash v1 native exercise report does not name its driving runtime")
        if report.get("candidate", {}).get("source_sha256") != candidate_source_digest(
            root
        ):
            fail("Flash v1 native exercise source digest differs")
        expected_limit = (
            "Flash v1 has no guaranteed scope-exit cleanup; interruption or a "
            "runtime adapter failure can leave the owned temporary directory "
            "for inspection."
        )
        if report.get("limitations", [])[-1:] != [expected_limit]:
            fail("Flash v1 native exercise cleanup limitation is missing")

    invalid = checked_runtime_process(
        [runtime, script, "--profile", "invalid"],
        cwd=root,
        label="Flash v1 native exercise invalid profile",
    )
    require_process(
        invalid,
        code=2,
        stdout="",
        stderr="run.fsh: invalid profile: invalid\n",
        label="Flash v1 native exercise invalid profile",
    )


CI_VALIDATOR_PAIRS = (
    ("ci/check_developer_interface.py", "ci/check_developer_interface.fsh"),
    ("ci/check_profile.py", "ci/check_profile.fsh"),
    ("ci/check_flash_conformance.py", "ci/check_flash_conformance.fsh"),
    ("ci/check_flash_release.py", "ci/check_flash_release.fsh"),
    ("ci/check_flashos_platform.py", "ci/check_flashos_platform.fsh"),
    ("ci/check_flashos_capabilities.py", "ci/check_flashos_capabilities.fsh"),
    (
        "ci/check_flashos_operation_map.py",
        "ci/check_flashos_operation_map.fsh",
    ),
    (
        "ci/check_flashos_capability_classification.py",
        "ci/check_flashos_capability_classification.fsh",
    ),
    (
        "ci/check_flashos_capability_report.py",
        "ci/check_flashos_capability_report.fsh",
    ),
    (
        "ci/check_flashos_target_matrix.py",
        "ci/check_flashos_target_matrix.fsh",
    ),
)

VALIDATOR_ORACLE_DEPENDENCIES = {
    "ci/check_flashos_capability_report.py": (
        "ci/flashos_runtime_fixtures.py",
    ),
    "ci/check_flashos_target_matrix.py": (
        "ci/flashos_target_matrix.py",
    ),
}

VALIDATOR_ORACLE_REWRITES = {
    "ci/check_profile.py": (
        (
            "python3 ci/check_candidate_qualification.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_candidate_qualification.fsh",
        ),
        (
            "python3 ci/check_main_qualification.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_main_qualification.fsh",
        ),
        (
            'ROOT / "ci/check_main_qualification.py"',
            'ROOT / "ci/lib/github_qualification.fsh"',
        ),
        (
            '    \'CANDIDATE_WORKFLOW = "ci.yml"\',',
            '    "\'ci.yml\'",',
        ),
        (
            '    \'SECURITY_WORKFLOW = "security.yml"\',',
            '    "\'security.yml\'",',
        ),
        (
            '    \'"change-classification"\',',
            '    "\'change-classification\'",',
        ),
        (
            '    \'"image-and-runtime / qemu-artifact-consumer"\',',
            '    "\'image-and-runtime / qemu-artifact-consumer\'",',
        ),
        (
            '    \'SECURITY_JOBS = {"security-required"}\',',
            '    "[\'security-required\']",',
        ),
        (
            '    \'SECURITY_POLICY_JOBS = {"dependency-review", "cargo-policy"}\',',
            '    "[\'cargo-policy\', \'dependency-review\']",',
        ),
        (
            '    "_pull_classification",',
            '    "select_main_pull",',
        ),
        (
            '    \'f"/repos/{repository}/commits/{main_sha}/pulls"\',',
            '    \'/commits/$source_sha/pulls\',',
        ),
        (
            "python3 ci/classify_changes.py --null",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/classify_changes.fsh --null",
        ),
        (
            "python3 ci/aggregate_ci.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/aggregate_ci.fsh",
        ),
        (
            "python3 ci/aggregate_ci.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/aggregate_ci.fsh",
        ),
        (
            'ROOT / "ci/aggregate_ci.py"',
            'ROOT / "ci/aggregate_ci.fsh"',
        ),
        (
            "python3 ci/check_flashos_platform.py --artifacts",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flashos_platform.fsh --artifacts",
        ),
        (
            "python3 ci/check_flashos_platform.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flashos_platform.fsh",
        ),
        (
            "python3 ci/check_developer_interface.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_developer_interface.fsh",
        ),
        (
            "python3 ../../ci/check_coverage.py ../../coverage/flash.lcov",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_coverage.fsh coverage/flash.lcov",
        ),
        (
            "python3 ci/release_candidate.py select",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/release_candidate.fsh select",
        ),
        (
            "python3 ci/release_candidate.py validate",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/release_candidate.fsh validate",
        ),
        (
            "python3 ci/release_candidate.py create",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/release_candidate.fsh create",
        ),
        (
            "python3 ci/release_candidate.py validate",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/release_candidate.fsh validate",
        ),
    ),
    "ci/check_flash_conformance.py": (
        (
            "python3 ../../ci/check_flash_conformance.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flash_conformance.fsh",
        ),
        (
            '"ci/check_flashos_platform.py"',
            '"ci/check_flashos_platform.fsh"',
        ),
        (
            '"ci/check_flashos_capabilities.py"',
            '"ci/check_flashos_capabilities.fsh"',
        ),
        (
            '"ci/check_flashos_operation_map.py"',
            '"ci/check_flashos_operation_map.fsh"',
        ),
        (
            '"ci/check_flashos_capability_classification.py"',
            '"ci/check_flashos_capability_classification.fsh"',
        ),
    ),
    "ci/check_flash_release.py": (
        (
            "python3 ci/check_flashos_capability_report.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flashos_capability_report.fsh",
        ),
        (
            "python3 ci/check_flashos_target_matrix.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flashos_target_matrix.fsh",
        ),
        (
            "python3 ../../ci/check_flash_conformance.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flash_conformance.fsh",
        ),
        (
            "python3 ../../ci/check_flash_v1_exercises.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flash_v1_exercises.fsh",
        ),
        (
            "python3 ../../ci/check_flash_release.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flash_release.fsh",
        ),
        (
            "python3 exercises/run.py --profile ci --no-build",
            "components/flash/target/debug/fsh components/flash/exercises/run.fsh "
            "--profile ci --no-build",
        ),
    ),
    "ci/check_flashos_platform.py": (
        (
            "python3 ci/check_flashos_platform.py --artifacts",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flashos_platform.fsh --artifacts",
        ),
        (
            "python3 ci/check_flashos_platform.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flashos_platform.fsh",
        ),
    ),
    "ci/check_flashos_capabilities.py": (
        (
            "python3 ci/check_flashos_capabilities.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flashos_capabilities.fsh",
        ),
    ),
    "ci/check_flashos_operation_map.py": (
        (
            "python3 ci/check_flashos_operation_map.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flashos_operation_map.fsh",
        ),
    ),
    "ci/check_flashos_capability_classification.py": (
        (
            "python3 ci/check_flashos_capability_classification.py",
            "build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
            "ci/check_flashos_capability_classification.fsh",
        ),
    ),
}


def resolved_automation_environment(runtime: Path) -> dict[str, str]:
    environment = os.environ.copy()
    environment["FLASH_AUTOMATION_RUNTIME"] = str(runtime.resolve())
    for name in (
        "FLASH_AUTOMATION_JQ",
        "FLASH_AUTOMATION_RG",
        "FLASH_AUTOMATION_TAPLO",
        "FLASH_AUTOMATION_READELF",
    ):
        selected = environment.get(name)
        if selected:
            environment[name] = str(Path(selected).resolve())
    return environment


def current_public_tree(destination: Path, root: Path) -> None:
    inventory = run_process(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"],
        cwd=root,
    )
    if inventory.returncode != 0:
        fail(f"cannot enumerate current parity tree: {inventory.stderr.strip()}")
    for raw_relative in filter(None, inventory.stdout.split("\0")):
        relative = PurePosixPath(raw_relative)
        source = root / relative
        if not source.is_file():
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def replace_occurrence(
    path: Path,
    needle: str,
    replacement: str,
    *,
    occurrence: int = 1,
) -> None:
    source = path.read_text(encoding="utf-8")
    offset = 0
    selected = -1
    for _ in range(occurrence):
        selected = source.find(needle, offset)
        if selected < 0:
            fail(f"parity mutation marker is absent from {path}: {needle!r}")
        offset = selected + len(needle)
    path.write_text(
        source[:selected] + replacement + source[selected + len(needle) :],
        encoding="utf-8",
    )


def validator_result(
    runtime: Path,
    root: Path,
    python_relative: str,
    flash_relative: str,
) -> tuple[subprocess.CompletedProcess[str], subprocess.CompletedProcess[str]]:
    environment = resolved_automation_environment(runtime)
    python = checked_runtime_process(
        [sys.executable, root / python_relative],
        label=f"Python validator {python_relative}",
        cwd=root,
        environment=environment,
    )
    flash = checked_runtime_process(
        [runtime, root / flash_relative],
        label=f"Flash validator {flash_relative}",
        cwd=root,
        environment=environment,
    )
    return python, flash


def require_validator_parity(
    runtime: Path,
    root: Path,
    python_relative: str,
    flash_relative: str,
    *,
    label: str,
) -> None:
    python, flash = validator_result(
        runtime,
        root,
        python_relative,
        flash_relative,
    )
    observed = (flash.returncode, flash.stdout, flash.stderr)
    expected = (python.returncode, python.stdout, python.stderr)
    if observed != expected:
        fail(f"{label} parity differs: observed={observed!r}, expected={expected!r}")


def coverage_result(
    runtime: Path,
    root: Path,
    report: Path,
) -> tuple[subprocess.CompletedProcess[str], subprocess.CompletedProcess[str]]:
    environment = resolved_automation_environment(runtime)
    python = checked_runtime_process(
        [sys.executable, root / "ci/check_coverage.py", report],
        label="Python coverage validator",
        cwd=root,
        environment=environment,
    )
    flash = checked_runtime_process(
        [runtime, root / "ci/check_coverage.fsh", report],
        label="Flash coverage validator",
        cwd=root,
        environment=environment,
    )
    return python, flash


def require_coverage_parity(
    runtime: Path,
    root: Path,
    report: Path,
    *,
    label: str,
) -> None:
    python, flash = coverage_result(runtime, root, report)
    observed = (flash.returncode, flash.stdout, flash.stderr)
    expected = (python.returncode, python.stdout, python.stderr)
    if observed != expected:
        fail(f"{label} parity differs: observed={observed!r}, expected={expected!r}")


def check_coverage_validator_parity(runtime: Path, root: Path) -> None:
    if not (root / "ci/check_coverage.fsh").is_file():
        return
    with tempfile.TemporaryDirectory(prefix="flash-coverage-parity-") as raw:
        candidate = Path(raw) / "repository"
        candidate.mkdir()
        current_public_tree(candidate, root)
        materialize_baseline_source(
            "ci/check_coverage.py",
            candidate / "ci/check_coverage.py",
            root,
        )

        flash_root = candidate / "components/flash"
        (flash_root / "Cargo.toml").write_text(
            '[workspace]\nmembers = ["crates/alpha", "crates/beta"]\n',
            encoding="utf-8",
        )
        sources = []
        for member in ("alpha", "beta"):
            source = flash_root / "crates" / member / "src/lib.rs"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(f"pub fn {member}() {{}}\n", encoding="utf-8")
            sources.append(source.resolve())

        alpha, beta = sources
        reports = candidate / "coverage-fixtures"
        reports.mkdir()
        cases: tuple[tuple[str, str | None], ...] = (
            (
                "positive",
                f"SF:{alpha}\nDA:1,1\nend_of_record\n"
                f"SF:{beta}\nDA:1,0\nend_of_record\n",
            ),
            (
                "unknown source records are ignored",
                "SF:/outside/unknown.rs\nDA:not,a-count\nend_of_record\n"
                f"SF:{alpha}\nDA:1,1\nend_of_record\n"
                f"SF:{beta}\nDA:1,1\nend_of_record\n",
            ),
            (
                "unknown sources cannot satisfy the contract",
                "SF:/outside/unknown.rs\nDA:1,1\nend_of_record\n",
            ),
            (
                "omitted workspace crate",
                f"SF:{alpha}\nDA:1,1\nend_of_record\n",
            ),
            (
                "zero executed first-party lines",
                f"SF:{alpha}\nDA:1,0\nend_of_record\n"
                f"SF:{beta}\nDA:1,0\nend_of_record\n",
            ),
            (
                "invalid first-party DA record",
                f"SF:{alpha}\nDA:1\nend_of_record\n",
            ),
            ("empty report", ""),
            ("missing report", None),
        )
        for index, (label, contents) in enumerate(cases):
            report = reports / f"case-{index}.lcov"
            if contents is not None:
                report.write_text(contents, encoding="utf-8")
            require_coverage_parity(
                runtime,
                candidate,
                report,
                label=f"coverage validator {label}",
            )


def check_ci_validator_parity(runtime: Path, root: Path) -> None:
    if not all((root / flash).is_file() for _, flash in CI_VALIDATOR_PAIRS):
        return
    with tempfile.TemporaryDirectory(prefix="flash-ci-validator-parity-") as raw:
        candidate = Path(raw) / "repository"
        candidate.mkdir()
        current_public_tree(candidate, root)
        oracle_markers: list[str] = []
        for python_relative, _ in CI_VALIDATOR_PAIRS:
            if (candidate / python_relative).is_file():
                continue
            materialize_baseline_source(
                python_relative,
                candidate / python_relative,
                root,
            )
            for needle, replacement in VALIDATOR_ORACLE_REWRITES.get(
                python_relative, ()
            ):
                replace_occurrence(
                    candidate / python_relative,
                    needle,
                    replacement,
                )
            oracle_markers.append(f"python3 {python_relative}")
            for dependency in VALIDATOR_ORACLE_DEPENDENCIES.get(
                python_relative, ()
            ):
                materialize_baseline_source(dependency, candidate / dependency, root)
        if oracle_markers:
            workflow = candidate / ".github/workflows/ci.yml"
            with workflow.open("a", encoding="utf-8") as destination:
                for marker in oracle_markers:
                    destination.write(f"\n# retained parity oracle: {marker}\n")

        for python_relative, flash_relative in CI_VALIDATOR_PAIRS:
            require_validator_parity(
                runtime,
                candidate,
                python_relative,
                flash_relative,
                label=f"CI validator positive {flash_relative}",
            )

        mutations = (
            (
                "ci/check_developer_interface.py",
                "ci/check_developer_interface.fsh",
                "docs/verification.md",
                "\nflashos ask\n",
                None,
                1,
            ),
            (
                "ci/check_profile.py",
                "ci/check_profile.fsh",
                "config/x86_64/flashos.toml",
                "create_xdg_user_dirs = false",
                "create_xdg_user_dirs = true",
                1,
            ),
            (
                "ci/check_flash_conformance.py",
                "ci/check_flash_conformance.fsh",
                "components/flash/conformance/v1.toml",
                'contract_status = "frozen"',
                'contract_status = "draft"',
                1,
            ),
            (
                "ci/check_flash_release.py",
                "ci/check_flash_release.fsh",
                "components/flash/release/v1.toml",
                'status = "released"',
                'status = "candidate"',
                1,
            ),
            (
                "ci/check_flashos_platform.py",
                "ci/check_flashos_platform.fsh",
                ".github/workflows/ci.yml",
                (
                    "build/flash-bootstrap/"
                    "134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
                    "ci/check_flashos_platform.fsh"
                ),
                (
                    "build/flash-bootstrap/"
                    "134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh "
                    "ci/check_flashos_platform_DISABLED.fsh"
                ),
                1,
            ),
            (
                "ci/check_flashos_capabilities.py",
                "ci/check_flashos_capabilities.fsh",
                "components/flash/platforms/flashos-x86_64-capability-evidence.toml",
                'classification = "deferred"',
                'classification = "native"',
                2,
            ),
            (
                "ci/check_flashos_operation_map.py",
                "ci/check_flashos_operation_map.fsh",
                "components/flash/platforms/flashos-x86_64-operation-map.toml",
                'classification = "deferred"',
                'classification = "native"',
                2,
            ),
            (
                "ci/check_flashos_capability_classification.py",
                "ci/check_flashos_capability_classification.fsh",
                (
                    "components/flash/platforms/"
                    "flashos-x86_64-capability-classification.toml"
                ),
                'target_qualification = "pending"',
                'target_qualification = "qualified"',
                2,
            ),
            (
                "ci/check_flashos_capability_report.py",
                "ci/check_flashos_capability_report.fsh",
                ("components/flash/platforms/flashos-x86_64-capability-report-v1.toml"),
                "fixture_ids = [",
                "fixture_ids = [] # parity mutation [",
                1,
            ),
            (
                "ci/check_flashos_target_matrix.py",
                "ci/check_flashos_target_matrix.fsh",
                "ci/qemu_smoke.py",
                "load_target_matrix(args.target_matrix)",
                "load_target_matrix_DISABLED(args.target_matrix)",
                1,
            ),
        )
        for (
            python_relative,
            flash_relative,
            mutated_relative,
            needle,
            replacement,
            occurrence,
        ) in mutations:
            path = candidate / mutated_relative
            original = path.read_bytes()
            try:
                if replacement is None:
                    path.write_text(
                        path.read_text(encoding="utf-8") + needle,
                        encoding="utf-8",
                    )
                else:
                    replace_occurrence(
                        path,
                        needle,
                        replacement,
                        occurrence=occurrence,
                    )
                require_validator_parity(
                    runtime,
                    candidate,
                    python_relative,
                    flash_relative,
                    label=f"CI validator failure {flash_relative}",
                )
            finally:
                path.write_bytes(original)


def check_ci_routing_parity(runtime: Path, root: Path) -> None:
    pairs = (
        ("ci/classify_changes.py", "ci/classify_changes.fsh"),
        ("ci/aggregate_ci.py", "ci/aggregate_ci.fsh"),
    )
    if not all((root / flash).is_file() for _, flash in pairs):
        return
    with tempfile.TemporaryDirectory(prefix="flash-ci-routing-parity-") as raw:
        candidate = Path(raw) / "repository"
        candidate.mkdir()
        current_public_tree(candidate, root)
        for python_relative, _ in pairs:
            if not (candidate / python_relative).is_file():
                materialize_baseline_source(
                    python_relative,
                    candidate / python_relative,
                    root,
                )
        classifier = candidate / "ci/classify_changes.py"
        source = classifier.read_text(encoding="utf-8")
        old_target_rule = "    return path.startswith(\n"
        new_target_rule = "    return path.endswith(\".fsh\") or path.startswith(\n"
        if new_target_rule not in source:
            replace_occurrence(classifier, old_target_rule, new_target_rule)

        environment = resolved_automation_environment(runtime)
        classifier_cases = (
            (
                [
                    "--json",
                    "docs/verification.md",
                    "CHANGELOG.md",
                    ".github/dependabot.yml",
                    "components/flash/docs/reference.md",
                ],
                None,
            ),
            (
                [
                    "--json",
                    "recipes/groups/auto-test/auto-test.fsh",
                    "ci/unknown.py",
                ],
                None,
            ),
            (["--json"], ""),
            (["--json", "--null"], "./docs/z.md\0docs/a.md\0docs/a.md\0"),
            (["--json", "../outside"], None),
            (["--json", "/absolute"], None),
        )
        for arguments, input_text in classifier_cases:
            python = checked_runtime_process(
                [sys.executable, "ci/classify_changes.py", *arguments],
                cwd=candidate,
                environment=environment,
                input_text=input_text,
                label="Python change classifier oracle",
            )
            flash = checked_runtime_process(
                [runtime, "ci/classify_changes.fsh", *arguments],
                cwd=candidate,
                environment=environment,
                input_text=input_text,
                label="Flash change classifier",
            )
            observed = (
                flash.returncode,
                flash.stdout,
                flash.stderr.replace("classify_changes.fsh", "classify_changes.py"),
            )
            expected = (python.returncode, python.stdout, python.stderr)
            if observed != expected:
                fail(
                    "change classifier materialized-oracle parity differs: "
                    f"arguments={arguments!r}, observed={observed!r}, "
                    f"expected={expected!r}"
                )

        oracle_output = candidate / "oracle-output"
        oracle_summary = candidate / "oracle-summary"
        flash_output = candidate / "flash-output"
        flash_summary = candidate / "flash-summary"
        oracle_environment = environment | {
            "GITHUB_OUTPUT": str(oracle_output),
            "GITHUB_STEP_SUMMARY": str(oracle_summary),
        }
        flash_environment = environment | {
            "GITHUB_OUTPUT": str(flash_output),
            "GITHUB_STEP_SUMMARY": str(flash_summary),
        }
        arguments = ["docs/verification.md", ".github/dependabot.yml"]
        python = checked_runtime_process(
            [sys.executable, "ci/classify_changes.py", *arguments],
            cwd=candidate,
            environment=oracle_environment,
            label="Python change classifier GitHub-output oracle",
        )
        flash = checked_runtime_process(
            [runtime, "ci/classify_changes.fsh", *arguments],
            cwd=candidate,
            environment=flash_environment,
            label="Flash change classifier GitHub output",
        )
        observed = (
            flash.returncode,
            flash.stdout,
            flash.stderr,
            flash_output.read_text(encoding="utf-8"),
            flash_summary.read_text(encoding="utf-8"),
        )
        expected = (
            python.returncode,
            python.stdout,
            python.stderr,
            oracle_output.read_text(encoding="utf-8"),
            oracle_summary.read_text(encoding="utf-8"),
        )
        if observed != expected:
            fail(
                "change classifier GitHub-output materialized-oracle parity "
                f"differs: observed={observed!r}, expected={expected!r}"
            )

        classification = json.dumps(
            {
                "schema": 1,
                "lane": "product",
                "image_required": True,
                "target_required": True,
                "reasons": ["test classification"],
            },
            separators=(",", ":"),
        )
        aggregate_base = environment | {
            "EVENT_NAME": "pull_request",
            "PR_DRAFT": "false",
            "SCOPE_RESULT": "success",
            "LANE": "product",
            "IMAGE_REQUIRED": "true",
            "TARGET_REQUIRED": "true",
            "CLASSIFICATION": classification,
            "ROOT_RESULT": "success",
            "SHELL_RESULT": "success",
            "IMAGE_RESULT": "success",
        }
        aggregate_cases = (
            {},
            {"PR_DRAFT": "true", "IMAGE_RESULT": "skipped"},
            {"SCOPE_RESULT": "failure"},
            {"IMAGE_RESULT": "skipped"},
            {"LANE": "fast"},
            {"PR_DRAFT": "invalid"},
        )
        for index, changes in enumerate(aggregate_cases):
            oracle_summary = candidate / f"aggregate-oracle-{index}"
            flash_summary = candidate / f"aggregate-flash-{index}"
            oracle_environment = aggregate_base | changes | {
                "GITHUB_STEP_SUMMARY": str(oracle_summary)
            }
            flash_environment = aggregate_base | changes | {
                "GITHUB_STEP_SUMMARY": str(flash_summary)
            }
            python = checked_runtime_process(
                [sys.executable, "ci/aggregate_ci.py"],
                cwd=candidate,
                environment=oracle_environment,
                label="Python CI aggregate oracle",
            )
            flash = checked_runtime_process(
                [runtime, "ci/aggregate_ci.fsh"],
                cwd=candidate,
                environment=flash_environment,
                label="Flash CI aggregate",
            )
            observed = (flash.returncode, flash.stdout, flash.stderr)
            expected = (python.returncode, python.stdout, python.stderr)
            if observed != expected:
                fail(
                    "CI aggregate materialized-oracle parity differs: "
                    f"changes={changes!r}, observed={observed!r}, "
                    f"expected={expected!r}"
                )
            observed_summary = (
                flash_summary.read_text(encoding="utf-8")
                if flash_summary.is_file()
                else ""
            )
            expected_summary = (
                oracle_summary.read_text(encoding="utf-8")
                if oracle_summary.is_file()
                else ""
            )
            if observed_summary != expected_summary:
                fail(
                    "CI aggregate summary materialized-oracle parity differs: "
                    f"changes={changes!r}, observed={observed_summary!r}, "
                    f"expected={expected_summary!r}"
                )


QUALIFICATION_MAIN_SHA = "1" * 40
QUALIFICATION_HEAD_SHA = "2" * 40
QUALIFICATION_TREE_SHA = "3" * 40
RELEASE_CANDIDATE_VERSION = "0.2.0"
RELEASE_CANDIDATE_COMMIT = "1" * 40
RELEASE_CANDIDATE_TREE = "2" * 40


def release_candidate_digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_release_candidate_checksums(bundle: Path) -> None:
    names = sorted(
        member.name
        for member in bundle.iterdir()
        if member.name not in {"SHA256SUMS", "candidate-manifest.json"}
    )
    lines = [
        f"{sha256_file(bundle / name)}  {name}"
        for name in names
    ]
    (bundle / "SHA256SUMS").write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8",
    )


def create_release_candidate_bundle(
    bundle: Path,
    *,
    compressed: bool = False,
    qualified_compression: bool = True,
) -> None:
    bundle.mkdir(parents=True)
    version = RELEASE_CANDIDATE_VERSION
    payloads = {
        f"FlashOS-{version}-x86_64-harddrive.img.zst": b"disk",
        f"FlashOS-{version}-x86_64-live.iso.zst": b"live",
        f"FlashOS-{version}-source.cdx.json": b"{}\n",
        f"FlashOS-{version}-image.cdx.json": b"{}\n",
        f"FlashOS-{version}-release-notes.md": b"notes\n",
        "cookbook.lock": b"# generated build resolution\n",
        "qemu-harddrive-performance.json": b"{}\n",
        "qemu-harddrive-smoke.log": b"disk ok\n",
        "qemu-live-usb-smoke.log": b"live ok\n",
    }
    qemu = {
        "schema": 1,
        "source_commit": RELEASE_CANDIDATE_COMMIT,
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
        (bundle / name).write_bytes(data)

    if compressed:
        for name, data in (("harddrive", b"disk"), ("live", b"live")):
            raw = bundle / f"{name}.raw"
            raw.write_bytes(data)
            filename = (
                f"FlashOS-{version}-x86_64-harddrive.img.zst"
                if name == "harddrive"
                else f"FlashOS-{version}-x86_64-live.iso.zst"
            )
            result = run_process(
                ["zstd", "--quiet", "--force", raw, "-o", bundle / filename]
            )
            require_process(
                result,
                code=0,
                stdout="",
                stderr="",
                label=f"release candidate {name} compression fixture",
            )
            raw.unlink()
            if qualified_compression:
                qemu[name]["sha256"] = release_candidate_digest(data)
        (bundle / "qemu-results.json").write_text(
            json.dumps(qemu) + "\n",
            encoding="utf-8",
        )
    write_release_candidate_checksums(bundle)


def release_candidate_command(
    runtime: Path | None,
    repository: Path,
    action: str,
    bundle: Path | None = None,
    extra: list[str] | None = None,
) -> list[str | Path]:
    if runtime is None:
        command: list[str | Path] = [
            sys.executable,
            repository / "ci/release_candidate.py",
        ]
    else:
        command = [runtime, repository / "ci/release_candidate.fsh"]
    command.append(action)
    if bundle is not None:
        command.extend(["--bundle", bundle, "--root", repository])
    if action == "create":
        command.extend(
            [
                "--version",
                RELEASE_CANDIDATE_VERSION,
                "--repository",
                "example/FlashOS",
                "--source-commit",
                RELEASE_CANDIDATE_COMMIT,
                "--source-tree",
                RELEASE_CANDIDATE_TREE,
                "--run-id",
                "123",
                "--run-attempt",
                "2",
                "--required-run-id",
                "120",
                "--security-run-id",
                "121",
            ]
        )
    elif action == "validate":
        command.extend(
            [
                "--repository",
                "example/FlashOS",
                "--version",
                RELEASE_CANDIDATE_VERSION,
                "--source-commit",
                RELEASE_CANDIDATE_COMMIT,
                "--source-tree",
                RELEASE_CANDIDATE_TREE,
                "--run-id",
                "123",
                "--run-attempt",
                "2",
                "--tag",
                "v0.2.0",
            ]
        )
    command.extend(extra or [])
    return command


def release_candidate_result(
    runtime: Path | None,
    repository: Path,
    action: str,
    bundle: Path | None = None,
    extra: list[str] | None = None,
) -> tuple[int, str, str]:
    process = checked_runtime_process(
        release_candidate_command(runtime, repository, action, bundle, extra),
        cwd=repository,
        environment=resolved_automation_environment(runtime or Path(sys.executable)),
        label=f"{'Python' if runtime is None else 'Flash'} release candidate {action}",
        timeout_seconds=90,
    )
    return process.returncode, process.stdout, process.stderr


def require_release_candidate_result(
    runtime: Path,
    repository: Path,
    label: str,
    action: str,
    python_bundle: Path | None = None,
    flash_bundle: Path | None = None,
    extra: list[str] | None = None,
) -> None:
    observed = release_candidate_result(
        runtime,
        repository,
        action,
        flash_bundle,
        extra,
    )
    expected = release_candidate_result(
        None,
        repository,
        action,
        python_bundle,
        extra,
    )
    if observed != expected:
        fail(
            f"release candidate materialized-oracle parity differs for {label}: "
            f"observed={observed!r}, expected={expected!r}"
        )


def check_release_candidate_parity(runtime: Path, root: Path) -> None:
    flash_source = root / "ci/release_candidate.fsh"
    if not flash_source.is_file():
        return
    runtime = runtime.resolve()
    with tempfile.TemporaryDirectory(prefix="flash-release-candidate-parity-") as raw:
        repository = Path(raw).resolve() / "repository"
        repository.mkdir()
        current_public_tree(repository, root)
        materialize_baseline_source(
            "ci/release_candidate.py",
            repository / "ci/release_candidate.py",
            root,
        )

        positive = repository / "positive"
        source_bundle = repository / "source-bundle"
        create_release_candidate_bundle(source_bundle)
        python_bundle = positive / "python"
        flash_bundle = positive / "flash"
        shutil.copytree(source_bundle, python_bundle)
        shutil.copytree(source_bundle, flash_bundle)
        require_release_candidate_result(
            runtime,
            repository,
            "manifest creation",
            "create",
            python_bundle,
            flash_bundle,
        )
        python_manifest = json.loads(
            (python_bundle / "candidate-manifest.json").read_text(encoding="utf-8")
        )
        flash_manifest = json.loads(
            (flash_bundle / "candidate-manifest.json").read_text(encoding="utf-8")
        )
        if flash_manifest != python_manifest:
            fail("release candidate created manifest semantics differ")
        require_release_candidate_result(
            runtime,
            repository,
            "manifest validation",
            "validate",
            python_bundle,
            flash_bundle,
        )

        for label, mutation in (
            ("missing required candidate member", "missing"),
            ("checksum mismatch during creation", "checksum"),
            ("second-attempt QEMU refusal", "attempt"),
        ):
            case = repository / f"create-failure-{mutation}"
            python_case = case / "python"
            flash_case = case / "flash"
            create_release_candidate_bundle(python_case)
            shutil.copytree(python_case, flash_case)
            if mutation == "missing":
                for bundle in (python_case, flash_case):
                    (bundle / "cookbook.lock").unlink()
            elif mutation == "checksum":
                for bundle in (python_case, flash_case):
                    sums = bundle / "SHA256SUMS"
                    sums.write_text(
                        sums.read_text(encoding="utf-8").replace(
                            release_candidate_digest(b"disk"),
                            "0" * 64,
                        ),
                        encoding="utf-8",
                    )
            else:
                for bundle in (python_case, flash_case):
                    qemu_path = bundle / "qemu-results.json"
                    qemu = json.loads(qemu_path.read_text(encoding="utf-8"))
                    qemu["harddrive"]["attempt"] = 2
                    qemu_path.write_text(
                        json.dumps(qemu) + "\n",
                        encoding="utf-8",
                    )
                    write_release_candidate_checksums(bundle)
            require_release_candidate_result(
                runtime,
                repository,
                label,
                "create",
                python_case,
                flash_case,
            )

        for label, mutation in (
            ("tampered payload", "tamper"),
            ("unexpected member", "unexpected"),
            ("source tree mismatch", "tree"),
            ("symlink substitution", "symlink"),
        ):
            case = repository / f"failure-{mutation}"
            python_case = case / "python"
            flash_case = case / "flash"
            shutil.copytree(python_bundle, python_case)
            shutil.copytree(flash_bundle, flash_case)
            if mutation == "tamper":
                for bundle in (python_case, flash_case):
                    filename = (
                        f"FlashOS-{RELEASE_CANDIDATE_VERSION}"
                        "-x86_64-live.iso.zst"
                    )
                    (bundle / filename).write_bytes(b"substitute")
            elif mutation == "unexpected":
                for bundle in (python_case, flash_case):
                    (bundle / "unexpected.txt").write_text("no", encoding="utf-8")
            elif mutation == "symlink":
                for bundle in (python_case, flash_case):
                    filename = (
                        f"FlashOS-{RELEASE_CANDIDATE_VERSION}-source.cdx.json"
                    )
                    member = bundle / filename
                    copy = bundle.parent / f"{bundle.name}-source-copy"
                    shutil.copyfile(member, copy)
                    member.unlink()
                    member.symlink_to(copy)
            extra = ["--source-tree", "3" * 40] if mutation == "tree" else None
            require_release_candidate_result(
                runtime,
                repository,
                label,
                "validate",
                python_case,
                flash_case,
                extra,
            )

        for qualified in (True, False):
            case = repository / f"compressed-{qualified}"
            python_case = case / "python"
            flash_case = case / "flash"
            create_release_candidate_bundle(
                python_case,
                compressed=True,
                qualified_compression=qualified,
            )
            shutil.copytree(python_case, flash_case)
            require_release_candidate_result(
                runtime,
                repository,
                f"compressed manifest creation ({qualified=})",
                "create",
                python_case,
                flash_case,
            )
            require_release_candidate_result(
                runtime,
                repository,
                f"compressed image verification ({qualified=})",
                "validate",
                python_case,
                flash_case,
                ["--verify-compressed"],
            )

        run_path = repository / "run.json"
        artifacts_path = repository / "artifacts.json"
        run_path.write_text(
            json.dumps(
                {
                    "id": 123,
                    "head_repository": {"full_name": "example/FlashOS"},
                    "path": ".github/workflows/candidate.yml",
                    "event": "workflow_dispatch",
                    "status": "completed",
                    "conclusion": "success",
                    "run_attempt": 2,
                }
            ),
            encoding="utf-8",
        )
        artifacts = {
            "artifacts": [
                {
                    "name": "flashos-release-candidate-123-2",
                    "expired": False,
                }
            ]
        }
        artifacts_path.write_text(json.dumps(artifacts), encoding="utf-8")
        selection = [
            "--run",
            str(run_path),
            "--artifacts",
            str(artifacts_path),
            "--repository",
            "example/FlashOS",
            "--run-id",
            "123",
        ]
        require_release_candidate_result(
            runtime,
            repository,
            "artifact selection",
            "select",
            extra=selection,
        )
        artifacts["artifacts"][0]["expired"] = True
        artifacts_path.write_text(json.dumps(artifacts), encoding="utf-8")
        require_release_candidate_result(
            runtime,
            repository,
            "expired artifact refusal",
            "select",
            extra=selection,
        )


def qualification_fixture_payload(
    path: str,
    scenario: dict[str, object],
) -> tuple[int, object]:
    repository = "/repos/example/flashos"
    source_sha = (
        QUALIFICATION_MAIN_SHA
        if scenario.get("candidate_source_main")
        else QUALIFICATION_HEAD_SHA
    )
    pull = {
        "number": 47,
        "merged_at": "2026-08-20T18:48:00Z",
        "merge_commit_sha": QUALIFICATION_MAIN_SHA,
        "draft": False,
        "base": {"ref": "main"},
        "head": {"sha": QUALIFICATION_HEAD_SHA},
        "state": "closed" if source_sha == QUALIFICATION_MAIN_SHA else "open",
    }
    if path in {
        f"{repository}/commits/{QUALIFICATION_MAIN_SHA}/pulls",
        f"{repository}/commits/{QUALIFICATION_HEAD_SHA}/pulls",
    }:
        pulls = [pull]
        if scenario.get("multiple_pulls"):
            duplicate = json.loads(json.dumps(pull))
            duplicate["number"] = 48
            pulls.append(duplicate)
        return 200, pulls
    if path == f"{repository}/git/commits/{QUALIFICATION_MAIN_SHA}":
        return 200, {"tree": {"sha": QUALIFICATION_TREE_SHA}}
    if path == f"{repository}/git/commits/{QUALIFICATION_HEAD_SHA}":
        tree = (
            "4" * 40
            if scenario.get("candidate_tree_mismatch")
            else QUALIFICATION_TREE_SHA
        )
        return 200, {"tree": {"sha": tree}}
    if path == f"{repository}/pulls/47/files":
        changed_paths = scenario.get("changed_paths", ["src/lib.rs"])
        assert isinstance(changed_paths, list)
        return 200, [{"filename": item} for item in changed_paths]

    candidate_runs = [
        {
            "id": 10,
            "event": "pull_request",
            "head_sha": QUALIFICATION_HEAD_SHA,
            "conclusion": "success",
            "run_attempt": 2,
            "html_url": "https://example.test/candidate",
        }
    ]
    if scenario.get("include_older_run"):
        candidate_runs.insert(
            0,
            {
                "id": 9,
                "event": "pull_request",
                "head_sha": QUALIFICATION_HEAD_SHA,
                "conclusion": "success",
                "run_attempt": 1,
                "html_url": "https://example.test/older-candidate",
            },
        )
    if path == f"{repository}/actions/workflows/ci.yml/runs":
        return 200, {"workflow_runs": candidate_runs}
    if path in {
        f"{repository}/actions/runs/9/jobs",
        f"{repository}/actions/runs/10/jobs",
    }:
        jobs = scenario.get(
            "candidate_jobs",
            [
                "change-classification",
                "repository-quality",
                "flash-quality",
                "required",
                "image-and-runtime / docker-clean-room-build",
                "image-and-runtime / qemu-artifact-consumer",
            ],
        )
        assert isinstance(jobs, list)
        return 200, {
            "jobs": [{"name": name, "conclusion": "success"} for name in jobs]
        }
    if path == f"{repository}/actions/workflows/security.yml/runs":
        return 200, {
            "workflow_runs": [
                {
                    "id": 11,
                    "event": "pull_request",
                    "head_sha": QUALIFICATION_HEAD_SHA,
                    "conclusion": "success",
                    "run_attempt": 1,
                    "html_url": "https://example.test/security",
                }
            ]
        }
    if path == f"{repository}/actions/runs/11/jobs":
        jobs = scenario.get("security_jobs", ["security-required"])
        assert isinstance(jobs, list)
        return 200, {
            "jobs": [{"name": name, "conclusion": "success"} for name in jobs]
        }
    return 404, {"message": f"unexpected qualification fixture path: {path}"}


def qualification_fixture_run(
    runtime: Path,
    root: Path,
    *,
    mode: str,
    implementation: str,
    scenario: dict[str, object],
) -> tuple[int, str, str, str, str, list[str]]:
    requests: list[str] = []
    counts: Counter[str] = Counter()
    retry_path = str(scenario.get("retry_path", ""))

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def do_GET(self) -> None:
            parsed = urlsplit(self.path)
            requests.append(self.path)
            counts[parsed.path] += 1
            expected_headers = {
                "Accept": "application/vnd.github+json",
                "Authorization": "Bearer fixture-token",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "FlashOS-main-qualification",
            }
            headers_differ = any(
                self.headers.get(name) != value
                for name, value in expected_headers.items()
            )
            if headers_differ:
                status, payload = 400, {"message": "qualification headers differ"}
            elif parsed.path == retry_path and counts[parsed.path] == 1:
                status, payload = 500, {"message": "transient fixture failure"}
            else:
                status, payload = qualification_fixture_payload(parsed.path, scenario)
            body = json.dumps(payload, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="flash-qualification-output-") as raw:
            directory = Path(raw)
            output = directory / "github-output"
            summary = directory / "github-summary"
            environment = resolved_automation_environment(runtime)
            for name in (
                "GITHUB_API_URL",
                "GITHUB_OUTPUT",
                "GITHUB_REPOSITORY",
                "GITHUB_SHA",
                "GITHUB_STEP_SUMMARY",
                "GITHUB_TOKEN",
                "SOURCE_SHA",
            ):
                environment.pop(name, None)
            environment.update(
                {
                    "GITHUB_API_URL": f"http://127.0.0.1:{server.server_port}",
                    "GITHUB_OUTPUT": str(output),
                    "GITHUB_REPOSITORY": "example/flashos",
                    "GITHUB_STEP_SUMMARY": str(summary),
                    "GITHUB_TOKEN": "fixture-token",
                }
            )
            if mode == "main":
                environment["GITHUB_SHA"] = QUALIFICATION_MAIN_SHA
                relative = "ci/check_main_qualification"
            else:
                environment["SOURCE_SHA"] = (
                    QUALIFICATION_MAIN_SHA
                    if scenario.get("candidate_source_main")
                    else QUALIFICATION_HEAD_SHA
                )
                relative = "ci/check_candidate_qualification"
            if implementation == "python":
                command: list[str | Path] = [sys.executable, f"{relative}.py"]
            else:
                command = [runtime, f"{relative}.fsh"]
            process = checked_runtime_process(
                command,
                cwd=root,
                environment=environment,
                label=f"{implementation} {mode} qualification fixture",
            )
            return (
                process.returncode,
                process.stdout,
                process.stderr,
                output.read_text(encoding="utf-8") if output.is_file() else "",
                summary.read_text(encoding="utf-8") if summary.is_file() else "",
                requests,
            )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def check_ci_qualification_parity(runtime: Path, root: Path) -> None:
    runtime = runtime.resolve()
    flash_paths = (
        "ci/check_main_qualification.fsh",
        "ci/check_candidate_qualification.fsh",
        "ci/lib/github_qualification.fsh",
    )
    if not all((root / relative).is_file() for relative in flash_paths):
        return
    with tempfile.TemporaryDirectory(prefix="flash-ci-qualification-parity-") as raw:
        candidate = Path(raw) / "repository"
        candidate.mkdir()
        current_public_tree(candidate, root)
        for relative in (
            "ci/classify_changes.py",
            "ci/check_main_qualification.py",
            "ci/check_candidate_qualification.py",
        ):
            materialize_baseline_source(relative, candidate / relative, root)

        repository = "/repos/example/flashos"
        required_jobs = [
            "change-classification",
            "repository-quality",
            "flash-quality",
            "required",
        ]
        cases = (
            (
                "main positive exact product evidence with retry and latest attempt",
                "main",
                {
                    "include_older_run": True,
                    "retry_path": (
                        f"{repository}/commits/{QUALIFICATION_MAIN_SHA}/pulls"
                    ),
                },
            ),
            ("candidate positive GitHub outputs", "candidate", {}),
            ("main rejects multiple merged pulls", "main", {"multiple_pulls": True}),
            (
                "main rejects a different candidate tree",
                "main",
                {"candidate_tree_mismatch": True},
            ),
            (
                "main rejects missing required evidence",
                "main",
                {"candidate_jobs": required_jobs[:-1]},
            ),
            (
                "main rejects missing product image evidence",
                "main",
                {"candidate_jobs": required_jobs},
            ),
            (
                "candidate rejects image work on the fast lane",
                "candidate",
                {"changed_paths": ["docs/verification.md"]},
            ),
            (
                "candidate rejects missing dependency policy evidence",
                "candidate",
                {"changed_paths": [".github/dependabot.yml"]},
            ),
            (
                "candidate rejects missing security aggregate evidence",
                "candidate",
                {"security_jobs": []},
            ),
            (
                "candidate rejects a different merged-source tree",
                "candidate",
                {
                    "candidate_source_main": True,
                    "candidate_tree_mismatch": True,
                },
            ),
        )
        for label, mode, scenario in cases:
            oracle = qualification_fixture_run(
                runtime,
                candidate,
                mode=mode,
                implementation="python",
                scenario=scenario,
            )
            flash = qualification_fixture_run(
                runtime,
                candidate,
                mode=mode,
                implementation="flash",
                scenario=scenario,
            )
            if flash != oracle:
                fail(
                    f"qualification materialized-oracle parity differs for {label}: "
                    f"observed={flash!r}, expected={oracle!r}"
                )


def check_activated_exercise_validator(
    runtime: Path,
    bootstrap_runtime: Path,
    root: Path,
) -> None:
    python_source = root / "ci/check_flash_v1_exercises.py"
    flash_source = root / "ci/check_flash_v1_exercises.fsh"
    if python_source.is_file() or not flash_source.is_file():
        return
    environment = resolved_automation_environment(runtime)
    environment["FLASH_V1_BOOTSTRAP_FSH"] = str(bootstrap_runtime.resolve())
    positive = checked_runtime_process(
        [runtime, flash_source],
        cwd=root,
        environment=environment,
        label="activated Flash v1 exercise validator",
    )
    require_process(
        positive,
        code=0,
        stdout="Flash v1 exercises: exhaustive contract passed\n",
        stderr="",
        label="activated Flash v1 exercise validator",
    )

    with tempfile.TemporaryDirectory(prefix="flash-exercise-validator-") as raw:
        candidate = Path(raw) / "repository"
        candidate.mkdir()
        current_public_tree(candidate, root)
        initialized = run_process(["git", "init", "--quiet"], cwd=candidate)
        require_process(
            initialized,
            code=0,
            stdout="",
            stderr="",
            label="exercise validator parity repository",
        )
        replace_occurrence(
            candidate / "components/flash/exercises/evidence/host-v1.json",
            '"flash": "fsh 1.0.0"',
            '"flash": "fsh 9.9.9"',
        )
        failure = checked_runtime_process(
            [runtime, candidate / "ci/check_flash_v1_exercises.fsh"],
            cwd=candidate,
            environment=environment,
            label="activated Flash v1 exercise validator failure",
        )
        require_process(
            failure,
            code=1,
            stdout="",
            stderr=(
                "Flash v1 exercises: host evidence must identify the "
                "Flash 1.0.0 driving runtime\n"
            ),
            label="activated Flash v1 exercise validator failure",
        )


def check_runtime_parity(
    runtime: Path,
    root: Path = ROOT,
    *,
    bootstrap_runtime: Path | None = None,
    runtime_label: str = "Flash runtime",
) -> None:
    runtime = runtime.resolve()
    if bootstrap_runtime is None:
        bootstrap_runtime = runtime
    bootstrap_runtime = bootstrap_runtime.resolve()

    flash_roots = set(NATIVE_FLASH)
    flash_roots.update(SHARED_FLASH_MODULES)
    flash_roots.update(
        target for target in MIGRATION_TARGETS.values() if (root / target).is_file()
    )
    native_paths = [root / relative for relative in sorted(flash_roots)]
    formatted = run_process([runtime, "format", "--check", "--", *native_paths])
    require_process(
        formatted,
        code=0,
        stdout="",
        stderr="",
        label=f"{runtime_label} format",
    )
    for source in native_paths:
        checked = run_process([runtime, "check", "--", source])
        require_process(
            checked,
            code=0,
            stdout="",
            stderr="",
            label=f"{runtime_label} check {source.relative_to(root)}",
        )

    if (root / "build.fsh").is_file():
        check_build_interface_parity(runtime, root)

    with tempfile.TemporaryDirectory(prefix="flashos-public-automation-") as raw:
        directory = Path(raw)
        report = directory / "report.jsonl"
        commands = (
            "acid-runner",
            "cargo",
            "make",
            "os-test-runner",
            "relibc-tests-runner",
        )
        for command in commands:
            write_probe(directory / command)

        auto_test = root / "recipes/groups/auto-test/auto-test.fsh"
        process = run_process(
            [runtime, auto_test, "ignored", "arguments"],
            environment=runtime_environment(
                directory,
                report,
                {"acid-runner": 7, "relibc-tests-runner": 8, "os-test-runner": 9},
            ),
        )
        require_process(
            process,
            code=9,
            stdout=(
                "stdout:acid-runner\n"
                "stdout:relibc-tests-runner\n"
                "stdout:os-test-runner\n"
            ),
            stderr=(
                "stderr:acid-runner\n"
                "stderr:relibc-tests-runner\n"
                "stderr:os-test-runner\n"
            ),
            label="auto-test ordered continuation",
        )
        auto_records = read_report(report)
        if [record["name"] for record in auto_records] != [
            "acid-runner",
            "relibc-tests-runner",
            "os-test-runner",
        ]:
            fail(f"auto-test runner order differs: {auto_records!r}")
        if any(record["rust_backtrace"] != "full" for record in auto_records):
            fail("auto-test does not export RUST_BACKTRACE=full to every runner")
        if any(len(record["argv"]) != 1 for record in auto_records):
            fail("auto-test unexpectedly forwards its own arguments")

        runner_cases = (
            (
                "recipes/tests/acid/acid-runner.fsh",
                "/home/user/acid",
                "cargo",
                ["cargo", "test"],
            ),
            (
                "recipes/tests/relibc-tests-bins/relibc-tests-runner.fsh",
                "/home/user/relibc-tests",
                "make",
                ["make", "run", "IS_REDOX=1"],
            ),
            (
                "recipes/tests/os-test-bins/os-test-runner.fsh",
                "/home/user/os-test",
                "make",
                ["make", "test", "html", "json"],
            ),
        )
        for relative, target_cwd, command, expected_argv in runner_cases:
            case_directory = directory / f"work-{PurePosixPath(relative).stem}"
            case_directory.mkdir()
            relocated = directory / f"relocated-{PurePosixPath(relative).name}"
            source = (root / relative).read_text(encoding="utf-8")
            if source.count(target_cwd) != 1:
                fail(f"{relative} working-directory contract drifted")
            relocated.write_text(
                source.replace(target_cwd, str(case_directory)),
                encoding="utf-8",
            )
            report.write_text("", encoding="utf-8")
            process = run_process(
                [runtime, relocated, "ignored"],
                environment=runtime_environment(directory, report, {command: 7}),
            )
            require_process(
                process,
                code=7,
                stdout=f"stdout:{command}\n",
                stderr=f"stderr:{command}\n",
                label=f"{relative} failure propagation",
            )
            records = read_report(report)
            if len(records) != 1:
                fail(f"{relative} did not execute exactly one program: {records!r}")
            record = records[0]
            observed_argv = record["argv"]
            argv_matches = (
                isinstance(observed_argv, list)
                and bool(observed_argv)
                and Path(str(observed_argv[0])).name == expected_argv[0]
                and observed_argv[1:] == expected_argv[1:]
            )
            cwd_matches = Path(str(record["cwd"])).resolve() == case_directory.resolve()
            if not argv_matches or not cwd_matches:
                fail(f"{relative} argv/cwd parity differs: {record!r}")

    if (root / "components/flash/fuzz/run-campaign.fsh").is_file():
        check_fuzz_campaign_parity(runtime, root)
    if (root / "components/flash/fuzz/run-smoke.fsh").is_file():
        check_fuzz_smoke_parity(runtime, root)
        check_smoke_baseline_oracle_parity(runtime, root)
    if (root / "components/flash/scheduling/run-campaign.fsh").is_file():
        check_scheduling_campaign_parity(runtime, root)
    if (root / "components/flash/exercises/run.fsh").is_file():
        check_exercise_runner_parity(runtime, bootstrap_runtime, root)
    if all(
        (root / path).is_file()
        for path in (
            "components/flash/fuzz/run-campaign.fsh",
            "components/flash/scheduling/run-campaign.fsh",
        )
    ):
        check_baseline_oracle_parity(runtime, root)
    check_coverage_validator_parity(runtime, root)
    check_ci_validator_parity(runtime, root)
    check_ci_routing_parity(runtime, root)
    check_ci_qualification_parity(runtime, root)
    check_release_candidate_parity(runtime, root)
    check_activated_exercise_validator(runtime, bootstrap_runtime, root)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--allow-incomplete",
        action="store_true",
        help=(
            "exercise the current migration set while the final 60-file gate stays red"
        ),
    )
    parser.add_argument(
        "--bootstrap-runtime",
        type=Path,
        help="first validate and execute parity with the immutable baseline fsh",
    )
    parser.add_argument(
        "--runtime",
        type=Path,
        help="then execute behavior and failure-path parity through this candidate fsh",
    )
    args = parser.parse_args(argv)
    inventory = scan()
    validate(inventory, allow_incomplete=args.allow_incomplete)
    check_install_flash_adapter()
    if args.runtime is not None and args.bootstrap_runtime is None:
        fail("--runtime requires the independently acquired --bootstrap-runtime")
    bootstrap: Path | None = None
    if args.bootstrap_runtime is not None:
        bootstrap = validate_bootstrap_runtime(args.bootstrap_runtime)
        check_runtime_parity(bootstrap, runtime_label="Flash bootstrap runtime")
    if args.runtime is not None:
        candidate = validate_runtime_binary(
            args.runtime,
            label="Flash candidate runtime",
        )
        assert bootstrap is not None
        if os.path.samefile(bootstrap, candidate):
            fail("Flash bootstrap and candidate runtimes must be distinct files")
        check_runtime_parity(
            candidate,
            bootstrap_runtime=bootstrap,
            runtime_label="Flash candidate runtime",
        )
    print(
        "public automation contract: ok "
        f"({sum(inventory.dispositions.values())} standalone, "
        f"{sum(inventory.embedded.values())} embedded, "
        f"{len(NATIVE_FLASH)} native Flash)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
