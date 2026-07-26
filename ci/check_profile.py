#!/usr/bin/env python3
"""Validate the FlashOS product profile independently of the build tooling."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "config/x86_64/flashos.toml"
BASE_PATH = ROOT / "config/flashos-base.toml"

EXPECTED_PACKAGES = {
    "base",
    "bootloader",
    "coreutils",
    "extrautils",
    "flashshell",
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
base = load(BASE_PATH)
version = release_version()
root_manifest = load(ROOT / "Cargo.toml")
flashshell_manifest = load(ROOT / "components/flashshell/Cargo.toml")

if root_manifest.get("package", {}).get("version") != version:
    fail("root Cargo package version drifted from versions.env")
flashshell_version = (
    flashshell_manifest.get("workspace", {}).get("package", {}).get("version")
)
if flashshell_version != version:
    fail("FlashShell workspace version drifted from versions.env")

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
    item.get("path", "")
    for item in base.get("files", []) + profile.get("files", [])
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
if f"FlashOS {version}" not in readme or f"version-{version}-" not in readme:
    fail("README version drifted from versions.env")

release_workflow = (ROOT / ".github/workflows/release.yml").read_text()
for expected in (
    'expected="v${FLASHOS_RELEASE_VERSION}"',
    "FlashOS-${VERSION}-x86_64-harddrive.img.zst",
    "FlashOS-${{ steps.version.outputs.version }}.cdx.json",
    "SYFT_SOURCE_NAME: FlashOS",
    "SYFT_SOURCE_VERSION: ${{ steps.version.outputs.version }}",
):
    if expected not in release_workflow:
        fail(f"release workflow contract is missing: {expected}")

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
missing_patches = [str(path.relative_to(ROOT)) for path in required_branding_patches if not path.is_file()]
if missing_patches:
    fail(f"branding patches are missing: {missing_patches}")

print("profile contract: ok")
print(f"release: {version}")
print(f"packages: {', '.join(sorted(packages))}")
print("interface: TUI-only; framebuffer/input/audio retained")
