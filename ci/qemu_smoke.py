#!/usr/bin/env python3
"""Boot an immutable FlashOS disk image and verify its serial contract."""

from __future__ import annotations

import argparse
import os
import re
import selectors
import subprocess
import sys
import time
from pathlib import Path

from flashos_runtime_fixtures import (
    FIXTURE_PATH,
    FixtureContractError,
    load_fixture_suite,
)
from flashos_target_matrix import (
    MATRIX_PATH,
    TargetMatrixContractError,
    load_target_matrix,
    script_transport_chunks,
)

DEFAULT_OVMF_PATHS = (
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/OVMF/OVMF_CODE_4M.fd",
    "/usr/share/edk2/ovmf/OVMF_CODE.fd",
    "/opt/homebrew/opt/qemu/share/qemu/edk2-x86_64-code.fd",
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]

# This gate qualifies deterministic product behavior, not SMP scheduling.
# Keeping TCG to one virtual CPU prevents scheduler timing from becoming an
# uncontrolled input; multicore behavior belongs in a dedicated runtime gate.
QUALIFICATION_VCPUS = 1


def release_version() -> str:
    for line in (REPOSITORY_ROOT / "versions.env").read_text().splitlines():
        if line.startswith("FLASHOS_RELEASE_VERSION="):
            return line.split("=", 1)[1]
    raise SystemExit("qemu smoke: FLASHOS_RELEASE_VERSION is missing")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--qemu", default="qemu-system-x86_64")
    parser.add_argument("--ovmf", type=Path)
    parser.add_argument("--log", type=Path, default=Path("qemu-smoke.log"))
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument(
        "--fixtures",
        type=Path,
        default=FIXTURE_PATH,
        help="Versioned FlashOS runtime fixture suite",
    )
    parser.add_argument(
        "--target-matrix",
        type=Path,
        default=MATRIX_PATH,
        help="Versioned exhaustive FlashOS target-capability matrix",
    )
    parser.add_argument(
        "--disk-interface",
        choices=("nvme", "usb"),
        default="nvme",
        help="Expose the image as an NVMe disk or USB mass-storage device",
    )
    parser.add_argument(
        "--expect-root-locked",
        action="store_true",
        help="Assert that the root account rejects a login attempt",
    )
    return parser.parse_args()


def resolve_ovmf(explicit: Path | None) -> Path:
    candidates = [explicit] if explicit else [Path(path) for path in DEFAULT_OVMF_PATHS]
    for candidate in candidates:
        if candidate and candidate.is_file():
            return candidate.resolve()
    raise SystemExit("qemu smoke: no OVMF/edk2 x86_64 firmware found")


args = parse_args()
version = release_version()
try:
    runtime_suite = load_fixture_suite(args.fixtures)
except FixtureContractError as error:
    raise SystemExit(f"qemu smoke: invalid runtime fixtures: {error}") from error
try:
    target_matrix = load_target_matrix(args.target_matrix)
except TargetMatrixContractError as error:
    raise SystemExit(f"qemu smoke: invalid target matrix: {error}") from error
image = args.image.resolve()
if not image.is_file():
    raise SystemExit(f"qemu smoke: image not found: {image}")

ovmf = resolve_ovmf(args.ovmf)
args.log.parent.mkdir(parents=True, exist_ok=True)

command = [
    args.qemu,
    "-name",
    "FlashOS x86_64 CI",
    "-machine",
    "q35,accel=tcg",
    "-cpu",
    "core2duo",
    "-smp",
    str(QUALIFICATION_VCPUS),
    "-m",
    "1024",
    "-drive",
    f"if=pflash,format=raw,unit=0,file={ovmf},readonly=on",
]

command.extend(["-drive", f"file={image},format=raw,if=none,id=drv0,snapshot=on"])
if args.disk_interface == "nvme":
    command.extend(["-device", "nvme,drive=drv0,serial=NVME_SERIAL"])

command.extend(["-device", "qemu-xhci,id=xhci"])
if args.disk_interface == "usb":
    command.extend(["-device", "usb-storage,drive=drv0,bus=xhci.0"])

command.extend(
    [
        "-device",
        "usb-kbd,bus=xhci.0",
        "-audiodev",
        "none,id=audio0",
        "-device",
        "ich9-intel-hda",
        "-device",
        "hda-output,audiodev=audio0",
        "-device",
        "e1000,netdev=net0,id=nic0",
        "-netdev",
        "user,id=net0",
        "-vga",
        "std",
        "-display",
        "none",
        "-chardev",
        "stdio,id=debug,signal=off,mux=on",
        "-serial",
        "chardev:debug",
        "-mon",
        "chardev=debug",
    ]
)

process = subprocess.Popen(
    command,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    bufsize=0,
)
assert process.stdin is not None
assert process.stdout is not None

selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
captured = bytearray()
deadline = time.monotonic() + args.timeout
CSI_SEQUENCE = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")


def collect_until(marker: bytes, start: int = 0, *, visible: bool = False) -> None:
    def observed() -> bytes:
        transcript = bytes(captured[start:])
        return CSI_SEQUENCE.sub(b"", transcript) if visible else transcript

    while marker not in observed():
        if process.poll() is not None:
            raise RuntimeError(
                f"QEMU exited with {process.returncode} before {marker!r}"
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {marker!r}")
        for key, _ in selector.select(min(1.0, remaining)):
            chunk = os.read(key.fd, 65536)
            if not chunk:
                continue
            captured.extend(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()


def send(data: bytes) -> None:
    process.stdin.write(data)
    process.stdin.flush()


EDITOR_INTERACTION_LIMIT = runtime_suite.max_interaction_bytes
EDITOR_INTERACTION_SETTLE = 0.05
SCRIPT_TRANSPORT_SETTLE = 0.05


def send_editor_input(
    payload: bytes,
    terminator: bytes,
) -> None:
    """Queue one UART-FIFO-bounded interaction in the guest terminal.

    The portable editor drains one ready terminal chunk into its internal byte
    queue. The emulated 16550 receiver holds sixteen bytes, so keeping every
    complete interaction within that boundary proves the target path without
    depending on another notification within the batch.
    """
    interaction = payload + terminator
    if len(interaction) > EDITOR_INTERACTION_LIMIT:
        raise ValueError("editor interaction exceeds the emulated UART FIFO")
    time.sleep(EDITOR_INTERACTION_SETTLE)
    send(interaction)


# How long the interactive assertions may take once the image has booted. Kept
# separate from the boot budget so a slow boot and a failing assertion cannot
# produce the same diagnostic.
INTERACTIVE_TIMEOUT = 180
TARGET_MATRIX_TIMEOUT = 900


def submit_line(
    payload: bytes,
    row: bytes,
) -> int:
    """Submit `payload` and return its scoped transcript offset.

    Each row uses one bounded UART batch because the target serial path does
    not guarantee a second readiness notification within one interaction.
    """
    if len(payload + runtime_suite.terminator) > EDITOR_INTERACTION_LIMIT:
        raise ValueError("editor interaction exceeds the emulated UART FIFO")
    row_start = len(captured)
    send_editor_input(payload, runtime_suite.terminator)
    # Highlighting may insert CSI style sequences within the visible row. Match
    # its terminal text so the assertion still proves the completed edit.
    collect_until(row, row_start, visible=True)
    return row_start


def materialize_matrix_script(source: bytes) -> None:
    """Stream exact source into a bounded foreground reader that creates `m`."""
    command = f"^head -c{len(source)}>m".encode()
    interaction = command + target_matrix.terminator
    if len(interaction) > target_matrix.max_interaction_bytes:
        raise ValueError("target matrix script reader exceeds the UART boundary")
    submit_line(command, target_matrix.primary_prompt + command)
    for chunk in script_transport_chunks(
        source, target_matrix.script_transport_chunk_bytes
    ):
        if len(chunk) > target_matrix.max_interaction_bytes:
            raise ValueError("target matrix script chunk exceeds the UART boundary")
        time.sleep(SCRIPT_TRANSPORT_SETTLE)
        send(chunk)


def collect_matrix_expectations(step, start: int) -> None:
    for expected in step.expected:
        if expected in {
            target_matrix.primary_prompt,
            target_matrix.continuation_prompt,
            target_matrix.configured_prompt,
        }:
            # The target console can defer a completed prompt until the next
            # input arrives. The following rendered row proves that transition;
            # all non-prompt observations remain scoped to this step.
            continue
        collect_until(expected, start, visible=True)


failure: BaseException | None = None
try:
    collect_until(b"FlashOS Bootloader")
    collect_until(b"Arrow keys and enter select mode")
    send(b"\r")
    collect_until(b"FlashOS starting")
    collect_until(b"Starting framebuffer debug")
    collect_until(b'pcid-spawner: spawn "/usr/lib/drivers/ihdad"')
    banner_start = len(captured)
    collect_until(b"username:", banner_start)
    banner = bytes(captured[banner_start:])
    expected_banner = f"FlashOS {version}".encode()
    if expected_banner not in banner:
        raise RuntimeError(f"login banner does not contain {expected_banner!r}")
    for forbidden_banner in (
        b"Redox OS distribution",
        b"Welcome to Redox OS",
        b"redox login:",
    ):
        if forbidden_banner in banner:
            raise RuntimeError(
                f"login banner contains inherited identity {forbidden_banner!r}"
            )

    # Boot is done. Re-arm the deadline so authentication and interactive
    # assertions get their own budget. The commands below exercise the selected
    # FlashOS adapter from its target-only editor through internal, external,
    # script, pipeline, and job-control paths.
    deadline = time.monotonic() + INTERACTIVE_TIMEOUT

    if args.expect_root_locked:
        # Only the release profile locks root. Test that policy before the
        # ordinary user session so it is independent of later editor behavior.
        attempt_start = len(captured)
        send(b"root\r")
        collect_until(b"assword", attempt_start)
        rejected_start = len(captured)
        send(b"password\r")
        collect_until(b"username:", rejected_start)
    login_start = len(captured)
    send(b"user\r")
    collect_until(b"password:", login_start)
    send(b"user\r")
    collect_until(b"Login successful!", login_start)
    collect_until(runtime_suite.prompt, login_start)

    # The same ordered, versioned suite is suitable for the automated QEMU
    # consumer and for manually observed real systems. Keeping the commands and
    # expected markers outside this transport harness prevents those two
    # evidence paths from drifting. The current suite remains deliberately
    # bounded; the exhaustive target matrix is a separate qualification gate.
    for fixture in runtime_suite.fixtures:
        fixture_start = len(captured)
        for step in fixture.steps:
            step_start = submit_line(step.payload, step.rendered)
            if step.expected is not None:
                collect_until(step.expected, step_start)
        fixture_transcript = bytes(captured[fixture_start:])
        for rejected in fixture.rejected:
            if rejected in fixture_transcript:
                raise RuntimeError(
                    f"FlashOS runtime fixture {fixture.identifier!r} "
                    f"observed rejected marker {rejected!r}"
                )

    # The exhaustive matrix deliberately follows the bounded fixtures. It
    # qualifies every advertised capability and required target surface while
    # retaining Signals as a separately withheld group. Long source cases are
    # materialized through bounded commands; live editor interactions remain
    # within the same proven UART boundary as the smoke fixtures.
    deadline = time.monotonic() + TARGET_MATRIX_TIMEOUT
    for case in target_matrix.cases:
        case_start = len(captured)
        for step in case.steps:
            if step.send == "line":
                assert step.rendered is not None
                observation_start = submit_line(step.payload, step.rendered)
                collect_matrix_expectations(step, observation_start)
            elif step.send == "script":
                materialize_matrix_script(step.payload)
                command = b"^fsh m"
                observation_start = submit_line(
                    command, target_matrix.primary_prompt + command
                )
                collect_matrix_expectations(step, observation_start)
            else:
                observation_start = len(captured)
                send_editor_input(step.payload, b"")
                if step.rendered is not None:
                    collect_until(step.rendered, observation_start, visible=True)
                collect_matrix_expectations(step, observation_start)
        case_transcript = bytes(captured[case_start:])
        for rejected in case.rejected:
            if rejected in case_transcript:
                raise RuntimeError(
                    f"FlashOS target matrix case {case.identifier!r} "
                    f"observed rejected marker {rejected!r}"
                )
except BaseException as error:
    failure = error
finally:
    args.log.write_bytes(captured)
    if process.poll() is None:
        try:
            send(b"\x01x")
            process.wait(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

if failure is not None:
    print(f"\nqemu smoke: FAILED: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("\nqemu smoke: ok")
verified = [
    "FlashOS identity",
    "TUI login",
    "Flash internal command",
    "Flash target runtime",
    "non-interactive Flash script",
    "external pipeline",
    "structured directory command",
    "foreground and background job execution",
    "IHDA audio driver",
    "interactive editing",
    f"runtime fixtures v{runtime_suite.suite_version}",
    f"target capability matrix v{target_matrix.matrix_version}",
]
if args.expect_root_locked:
    verified.append("locked root account")
print(f"verified: {', '.join(verified)}")
