#!/usr/bin/env python3
"""Validate the FlashOS product profile independently of the build tooling."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "config/x86_64/flashos.toml"
RELEASE_PROFILE_PATH = ROOT / "config/x86_64/flashos-release.toml"
BASE_PATH = ROOT / "config/flashos-base.toml"

# Passwords that must never reach a published image. An empty password is
# handled separately: it is still permitted for the unprivileged account until
# first-boot credential provisioning exists, and is documented in SECURITY.md.
WELL_KNOWN_PASSWORDS = {
    "123456",
    "admin",
    "flashos",
    "password",
    "redox",
    "root",
    "toor",
    "user",
}

EXPECTED_PACKAGES = {
    "base",
    "bootloader",
    "coreutils",
    "extrautils",
    "flash",
    "kernel",
    "libgcc",
    "libstdcxx",
    "netdb",
    "netutils",
    "relibc",
    "userutils",
    "uutils",
}

FORBIDDEN_GUI_TOKENS = {
    "cosmic",
    "orbital",
    "wayland",
    "weston",
    "x11",
    "xorg",
}


def fail(message: str) -> None:
    print(f"profile contract: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path: Path) -> dict:
    with path.open("rb") as source:
        return tomllib.load(source)


def release_version() -> str:
    for line in (ROOT / "versions.env").read_text().splitlines():
        if line.startswith("FLASHOS_RELEASE_VERSION="):
            return line.split("=", 1)[1]
    fail("FLASHOS_RELEASE_VERSION is missing from versions.env")
    raise AssertionError("unreachable")


profile = load(PROFILE_PATH)
release_profile = load(RELEASE_PROFILE_PATH)
base = load(BASE_PATH)
version = release_version()
root_manifest = load(ROOT / "Cargo.toml")
flash_manifest = load(ROOT / "components/flash/Cargo.toml")

if root_manifest.get("package", {}).get("version") != version:
    fail("root Cargo package version drifted from versions.env")
flash_version = flash_manifest.get("workspace", {}).get("package", {}).get("version")
if flash_version != version:
    fail("Flash workspace version drifted from versions.env")

if profile.get("include") != ["../flashos-base.toml"]:
    fail("the x86_64 profile must include only ../flashos-base.toml")

if profile.get("general", {}).get("create_xdg_user_dirs") is not False:
    fail("graphical XDG home directories must remain disabled")

packages = set(base.get("packages", {})) | set(profile.get("packages", {}))
if packages != EXPECTED_PACKAGES:
    missing = sorted(EXPECTED_PACKAGES - packages)
    unexpected = sorted(packages - EXPECTED_PACKAGES)
    fail(f"package closure drifted (missing={missing}, unexpected={unexpected})")

for package in packages:
    lowered = package.lower()
    if any(token in lowered for token in FORBIDDEN_GUI_TOKENS):
        fail(f"GUI package selected: {package}")

for account in ("root", "user"):
    shell = profile.get("users", {}).get(account, {}).get("shell")
    if shell != "/usr/bin/fsh":
        fail(f"{account} shell is {shell!r}, expected /usr/bin/fsh")

# The release profile must differ from the development profile in credentials
# and in nothing else. Anything else diverging is drift, not policy.
for section in ("general", "packages", "files"):
    if profile.get(section) != release_profile.get(section):
        fail(f"release profile drifted from the development profile: [{section}]")

release_users = release_profile.get("users", {})
if set(release_users) != set(profile.get("users", {})):
    fail("release profile defines a different account set")

# Root must be unreachable in a published image. A locked account carries an
# unmatchable hash, so no password verifies against it; sudo is unaffected
# because it authenticates the invoking user before switching to uid 0.
if release_users.get("root", {}).get("locked") is not True:
    fail("the release profile must lock the root account")
if "password" in release_users.get("root", {}):
    fail("a locked account must not also carry a password")

for account, settings in sorted(release_users.items()):
    password = settings.get("password")
    if password is None:
        continue
    if password.lower() in WELL_KNOWN_PASSWORDS:
        fail(f"release account {account} uses a well-known password")

login_file = next(
    (
        item
        for item in base.get("files", [])
        if item.get("path") == "/etc/login_schemes.toml"
    ),
    None,
)
if login_file is None:
    fail("/etc/login_schemes.toml is missing")

login_schemes = tomllib.loads(login_file["data"])
user_schemes = login_schemes["user_schemes"]["user"]["schemes"]
for required in ("audio", "display*", "event", "pty"):
    if required not in user_schemes:
        fail(f"required TUI/runtime scheme is missing: {required}")
if "orbital" in user_schemes:
    fail("Orbital scheme access must not be present")

configured_paths = {
    item.get("path", "") for item in base.get("files", []) + profile.get("files", [])
}
if any(path == "/ui" or path.startswith("/ui/") for path in configured_paths):
    fail("legacy /ui compatibility path returned")

if (ROOT / "docs/de").exists():
    fail("German docs are intentionally deferred and must not be restored yet")

os_release_file = next(
    (
        item
        for item in profile.get("files", [])
        if item.get("path") == "/usr/lib/os-release" and not item.get("append")
    ),
    None,
)
if os_release_file is None:
    fail("/usr/lib/os-release is missing")
for expected in (
    f'PRETTY_NAME="FlashOS {version}"',
    f'VERSION_ID="{version}"',
    f'VERSION="{version}"',
):
    if expected not in os_release_file["data"]:
        fail(f"os-release version drifted from versions.env: {expected}")

issue_file = next(
    (
        item
        for item in profile.get("files", [])
        if item.get("path") == "/etc/issue" and not item.get("append")
    ),
    None,
)
if issue_file is None or issue_file.get("data") != f"FlashOS {version}\n":
    fail("/etc/issue version drifted from versions.env")

readme = (ROOT / "README.md").read_text()
if f"FlashOS {version}" not in readme or f"Version-{version}-" not in readme:
    fail("README version drifted from versions.env")

for expected in (
    "actions/workflows/ci.yml/badge.svg",
    "actions/workflows/security.yml/badge.svg",
    "https://img.shields.io/codecov/c/github/ajhahnde/FlashOS",
    "label=Coverage",
    f"Version-{version}-",
    "Status-pre--alpha-",
    "Target-x86__64--unknown--redox-",
):
    if expected not in readme:
        fail(f"README badge contract is missing: {expected}")

readme_header_links = (
    '<a href="docs/README.md"><strong>Documentation</strong></a>',
    '<a href="docs/source_of_truth.md"><strong>Source of Truth</strong></a>',
    '<a href="docs/getting-started.md"><strong>Getting Started</strong></a>',
)
readme_header_positions = tuple(readme.find(link) for link in readme_header_links)
if -1 in readme_header_positions or readme_header_positions != tuple(
    sorted(readme_header_positions)
):
    fail(
        "README header must route Documentation -> Source of Truth -> "
        "Getting Started"
    )

source_of_truth_path = ROOT / "docs/source_of_truth.md"
if not source_of_truth_path.is_file():
    fail("public source-of-truth register is missing")

source_of_truth = source_of_truth_path.read_text()
for expected in (
    "`versions.env`",
    "`config/x86_64/flashos.toml`",
    "`config/flashos-base.toml`",
    "`components/flash/README.md`",
    "`docs/hardware.md`",
    "`docs/roadmap.md`",
    "`ci/check_profile.py`",
):
    if expected not in source_of_truth:
        fail(f"source-of-truth authority is missing: {expected}")

public_navigation = {
    "README.md": readme,
    ".github/SECURITY.md": (ROOT / ".github/SECURITY.md").read_text(),
    "CHANGELOG.md": (ROOT / "CHANGELOG.md").read_text(),
    "TRADEMARK.md": (ROOT / "TRADEMARK.md").read_text(),
    "ci/README.md": (ROOT / "ci/README.md").read_text(),
    "components/flash/README.md": (
        ROOT / "components/flash/README.md"
    ).read_text(),
    "docs/README.md": (ROOT / "docs/README.md").read_text(),
    "docs/architecture.md": (ROOT / "docs/architecture.md").read_text(),
    "docs/development.md": (ROOT / "docs/development.md").read_text(),
    "docs/getting-started.md": (ROOT / "docs/getting-started.md").read_text(),
    "docs/hardware.md": (ROOT / "docs/hardware.md").read_text(),
    "docs/roadmap.md": (ROOT / "docs/roadmap.md").read_text(),
    "docs/upstream/README.md": (ROOT / "docs/upstream/README.md").read_text(),
    "docs/verification.md": (ROOT / "docs/verification.md").read_text(),
}
for path, content in public_navigation.items():
    if "source_of_truth.md" not in content:
        fail(f"{path} does not route readers to source_of_truth.md")

release_workflow = (ROOT / ".github/workflows/release.yml").read_text()
for expected in (
    'expected="v${FLASHOS_RELEASE_VERSION}"',
    "FlashOS-${VERSION}-x86_64-harddrive.img.zst",
    "FlashOS-${VERSION}-x86_64-live.iso.zst",
    # A release must never be built from the profile that carries the
    # development logins.
    "config-name: flashos-release",
    # Both SBOMs must ship, and each must be named for what it describes. A
    # single unqualified document previously covered only the source workspace.
    "FlashOS-${{ steps.version.outputs.version }}-source.cdx.json",
    "FlashOS-${{ steps.version.outputs.version }}-image.cdx.json",
    "SYFT_SOURCE_NAME: FlashOS-source",
    "SYFT_SOURCE_VERSION: ${{ steps.version.outputs.version }}",
):
    if expected not in release_workflow:
        fail(f"release workflow contract is missing: {expected}")

image_workflow = (ROOT / ".github/workflows/_image.yml").read_text()
for expected in (
    "build/x86_64/${CONFIG_NAME}/harddrive.img",
    "build/x86_64/${CONFIG_NAME}/redox-live.iso",
    "FlashOS-x86_64-harddrive.img",
    "FlashOS-x86_64-live.iso",
    # The image SBOM is produced beside the image it describes, from the staged
    # package payload rather than from the repository working tree.
    "FlashOS-x86_64-image.cdx.json",
    "dist/payload",
    # The container runs as root over a runner-owned bind mount. Git must
    # trust exactly that mount for the in-tree Flash workspace snapshot.
    "GIT_CONFIG_COUNT=1",
    "GIT_CONFIG_KEY_0=safe.directory",
    "GIT_CONFIG_VALUE_0=/workspace",
    "--disk-interface nvme",
    "--disk-interface usb",
):
    if expected not in image_workflow:
        fail(f"image workflow contract is missing: {expected}")

security_workflow = (ROOT / ".github/workflows/security.yml").read_text()
if not security_workflow.startswith("name: Security\n"):
    fail("security workflow name must preserve the Security badge label")

coverage_workflow = (ROOT / ".github/workflows/coverage.yml").read_text()
for expected in (
    "name: Coverage",
    "id-token: write",
    "rustup component add llvm-tools-preview",
    "tool: cargo-llvm-cov@0.8.7",
    "fallback: none",
    "python3 ../../ci/check_coverage.py ../../coverage/flash.lcov",
    "use_oidc: true",
    "version: v11.3.1",
    "files: coverage/flash.lcov",
    "disable_search: true",
    "fail_ci_if_error: true",
):
    if expected not in coverage_workflow:
        fail(f"coverage workflow contract is missing: {expected}")

ci_workflow = (ROOT / ".github/workflows/ci.yml").read_text()
if "python3 -m unittest discover -s ci/tests -p 'test_*.py'" not in ci_workflow:
    fail("standard CI must run the coverage-contract unit tests")

codecov_config = (ROOT / "codecov.yml").read_text()
for expected in (
    "project: off",
    "patch: off",
    "comment: false",
    "github_checks: false",
):
    if expected not in codecov_config:
        fail(f"informational Codecov policy is missing: {expected}")

# Flash is maintained in this repository, so its source is the current
# checkout's tracked/non-ignored component snapshot. This avoids a circular
# self-SHA pin while keeping image source identity bound to the outer checkout.
flash_recipe = load(ROOT / "recipes/terminal/flash/recipe.toml")
if flash_recipe.get("source") != {"workspace": "components/flash"}:
    fail("Flash recipe must use the in-tree components/flash workspace source")
flash_build = flash_recipe.get("build", {})
if flash_build.get("template") != "cargo" or flash_build.get("cargopath") != (
    "crates/flash-cli"
):
    fail("Flash workspace recipe must build crates/flash-cli with Cargo")

# Every external Git package that reaches the image retains an explicit
# revision. Without one, the same FlashOS tag could build whatever the
# repository's default branch happened to contain later.
RECIPE_ROOTS = ("core", "libs", "terminal")
for package in sorted(packages):
    recipe_paths = [
        ROOT / "recipes" / section / package / "recipe.toml" for section in RECIPE_ROOTS
    ]
    recipe_path = next((path for path in recipe_paths if path.is_file()), None)
    if recipe_path is None:
        continue

    source = load(recipe_path).get("source")
    if source is None or "git" not in source:
        continue

    revision = source.get("rev")
    if revision is None or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        fail(
            "shipped recipe is not pinned to an immutable revision: "
            f"{recipe_path.relative_to(ROOT)}"
        )

qemu_smoke = (ROOT / "ci/qemu_smoke.py").read_text()
for expected in ('choices=("nvme", "usb")', "snapshot=on"):
    if expected not in qemu_smoke:
        fail(f"QEMU immutability/bus contract is missing: {expected}")

uses_pattern = re.compile(r"^\s*(?:-\s+)?uses:\s+([^\s#]+)")
for workflow_path in sorted((ROOT / ".github/workflows").glob("*.yml")):
    for line_number, line in enumerate(workflow_path.read_text().splitlines(), 1):
        match = uses_pattern.match(line)
        if match is None:
            continue

        action = match.group(1)
        if action.startswith("./"):
            continue

        _, separator, revision = action.rpartition("@")
        if separator != "@" or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            fail(
                "GitHub Action is not pinned to an immutable commit: "
                f"{workflow_path.relative_to(ROOT)}:{line_number}: {action}"
            )

required_branding_patches = (
    ROOT / "recipes/core/bootloader/flashos-branding.patch",
    ROOT / "recipes/core/installer/flashos-branding.patch",
    ROOT / "recipes/core/kernel/flashos-branding.patch",
    ROOT / "recipes/core/userutils/flashos-branding.patch",
)
missing_patches = [
    str(path.relative_to(ROOT))
    for path in required_branding_patches
    if not path.is_file()
]
if missing_patches:
    fail(f"branding patches are missing: {missing_patches}")

print("profile contract: ok")
print(f"release: {version}")
print(f"packages: {', '.join(sorted(packages))}")
print("interface: TUI-only; framebuffer/input/audio retained")
