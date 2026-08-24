#!/usr/bin/env python3
"""Validate the public FlashOS host command interface without side effects."""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

COMMANDS = (
    "status",
    "doctor",
    "version",
    "versions",
    "profile",
    "env",
    "build",
    "run",
    "smoke",
    "qualify",
    "recipe",
    "artifacts",
    "logs",
    "changes",
    "check",
    "shell",
    "podman",
    "clean",
    "root",
    "list",
    "help",
)

DIRECT_HELPERS = (
    "flash-check",
    "flashos",
    "flashos-artifacts",
    "flashos-build",
    "flashos-changes",
    "flashos-check",
    "flashos-clean",
    "flashos-doctor",
    "flashos-env",
    "flashos-list",
    "flashos-logs",
    "flashos-podman",
    "flashos-profile",
    "flashos-qualify",
    "flashos-recipe",
    "flashos-run",
    "flashos-smoke",
    "flashos-status",
    "flashos-version",
    "flashos-versions",
    "fos",
)

REMOVED_COMMANDS = ("ask", "commit", "setup", "log", "change")
REMOVED_PATHS = (
    "tools/flashos/flashos-ask.py",
    "tools/flashos/flashos-commit.py",
    "tools/flashos/flashos_ai.py",
    "tools/flashos/contexts/flashos-ask-context.json",
    "tools/flashos/contexts/flashos-commit-context.json",
)


def fail(message: str) -> None:
    print(f"developer interface contract: {message}", file=sys.stderr)
    raise SystemExit(1)


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )


def require_success(command: list[str], label: str) -> str:
    process = run(command)
    if process.returncode != 0:
        details = process.stderr.strip() or process.stdout.strip()
        fail(f"{label} failed: {details or f'exit {process.returncode}'}")
    return process.stdout


def help_commands(output: str) -> tuple[str, ...]:
    return tuple(
        match.group(1)
        for line in output.splitlines()
        if (match := re.match(r"^  ([a-z][a-z-]*)(?:\s|\[|<)", line))
    )


def check_removed_surface() -> None:
    for relative in REMOVED_PATHS:
        if (ROOT / relative).exists():
            fail(f"removed helper still exists: {relative}")

    public_text = "\n".join(
        (ROOT / relative).read_text(encoding="utf-8")
        for relative in (
            "flashos.sh",
            "flashos.zsh",
            "docs/development.md",
            "docs/verification.md",
            ".github/workflows/ci.yml",
        )
    )
    for command in ("ask", "commit"):
        if f"flashos {command}" in public_text:
            fail(f"removed command remains documented or exposed: {command}")
    for marker in ("tools/flashos/", "flashshell-check"):
        if marker in public_text:
            fail(f"removed helper boundary remains exposed: {marker}")


def check_bash() -> None:
    require_success(["bash", "-n", "flashos.sh"], "Bash syntax check")

    help_output = require_success(
        ["bash", "-c", "source ./flashos.sh; flashos help"],
        "Bash help",
    )
    if help_commands(help_output) != COMMANDS:
        fail("Bash help command inventory drifted")

    alias_output = require_success(
        ["bash", "-c", "source ./flashos.sh; fos help"],
        "fos alias",
    )
    if alias_output != help_output:
        fail("fos help differs from flashos help")

    completion_output = require_success(
        [
            "bash",
            "-c",
            (
                "source ./flashos.sh; "
                'COMP_WORDS=(flashos ""); COMP_CWORD=1; '
                '_flashos_bash_completion; printf "%s\\n" "${COMPREPLY[@]}"'
            ),
        ],
        "Bash completion",
    )
    if tuple(completion_output.splitlines()) != COMMANDS:
        fail("Bash completion command inventory drifted")

    list_output = require_success(
        ["bash", "-c", "source ./flashos.sh; flashos list"],
        "direct helper list",
    )
    marker = "== Direct helper functions ==\n"
    if marker not in list_output:
        fail("direct helper list has no heading")
    listed = tuple(sorted(list_output.split(marker, 1)[1].splitlines()))
    if listed != DIRECT_HELPERS:
        fail("direct helper inventory drifted")

    removed = " ".join(REMOVED_COMMANDS)
    require_success(
        [
            "bash",
            "-c",
            (
                "source ./flashos.sh; "
                f"for name in {removed}; do "
                'if flashos "$name" >/dev/null 2>&1; then exit 1; fi; '
                "done"
            ),
        ],
        "removed command rejection",
    )

    no_argument_commands = "status doctor version root list help"
    require_success(
        [
            "bash",
            "-c",
            (
                "source ./flashos.sh; "
                f"for name in {no_argument_commands}; do "
                'if flashos "$name" unexpected >/dev/null 2>&1; then exit 1; fi; '
                "done; "
                "if flashos profile dev unexpected >/dev/null 2>&1; then exit 1; fi"
            ),
        ],
        "unexpected argument rejection",
    )

    legacy_modes = (
        "flashos profile development",
        "flashos build harddrive",
        "flashos run iso",
        "flashos smoke harddrive",
        "flashos artifacts path harddrive",
        "flashos logs iso",
    )
    require_success(
        [
            "bash",
            "-c",
            (
                "source ./flashos.sh; "
                + " ".join(
                    f"if {command} >/dev/null 2>&1; then exit 1; fi;"
                    for command in legacy_modes
                )
            ),
        ],
        "legacy alias rejection",
    )
    require_success(
        [
            "bash",
            "-c",
            (
                "source ./flashos.sh; podman() { :; }; "
                "if flashos podman list >/dev/null 2>&1; then exit 1; fi"
            ),
        ],
        "legacy Podman alias rejection",
    )


def check_zsh() -> None:
    zsh = shutil.which("zsh")
    zsh_text = (ROOT / "flashos.zsh").read_text(encoding="utf-8")
    static_commands = tuple(
        re.findall(r"^\s+'([a-z][a-z-]*):", zsh_text, flags=re.MULTILINE)
    )
    if static_commands != COMMANDS:
        fail("Zsh completion command inventory drifted")

    if zsh is None:
        print(
            "developer interface contract: zsh unavailable; runtime Zsh checks skipped",
            file=sys.stderr,
        )
        return

    require_success([zsh, "-n", "flashos.sh"], "Zsh shared syntax check")
    require_success([zsh, "-n", "flashos.zsh"], "Zsh entrypoint syntax check")

    help_output = require_success(
        [zsh, "-f", "-c", "source ./flashos.zsh; flashos help"],
        "Zsh help",
    )
    if help_commands(help_output) != COMMANDS:
        fail("Zsh help command inventory drifted")

    completion_output = require_success(
        [
            zsh,
            "-f",
            "-c",
            (
                "compdef() { :; }; source ./flashos.zsh; "
                '_describe() { local name="$4"; '
                'eval "print -rl -- \\${${name}[@]}"; }; '
                'CURRENT=2; words=(flashos ""); _flashos_zsh_completion'
            ),
        ],
        "Zsh completion",
    )
    completed = tuple(line.split(":", 1)[0] for line in completion_output.splitlines())
    if completed != COMMANDS:
        fail("Zsh runtime completion command inventory drifted")


def main() -> None:
    check_removed_surface()
    check_bash()
    check_zsh()
    print("developer interface contract: ok")


if __name__ == "__main__":
    main()
