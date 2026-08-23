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

command.extend(
    ["-drive", f"file={image},format=raw,if=none,id=drv0,snapshot=on"]
)
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


EDITOR_INTERACTION_LIMIT = 16


def send_editor_input(payload: bytes, terminator: bytes) -> None:
    """Queue one UART-FIFO-bounded interaction in the guest terminal.

    The portable editor drains one ready terminal chunk into its internal byte
    queue. The emulated 16550 receiver holds sixteen bytes, so keeping every
    complete interaction within that boundary proves the target path without
    depending on a second serial readiness notification.
    """
    interaction = payload + terminator
    if len(interaction) > EDITOR_INTERACTION_LIMIT:
        raise ValueError("editor interaction exceeds the emulated UART FIFO")
    send(interaction)


# How long the interactive assertions may take once the image has booted. Kept
# separate from the boot budget so a slow boot and a failing assertion cannot
# produce the same diagnostic.
INTERACTIVE_TIMEOUT = 180


def submit_line(payload: bytes, row: bytes) -> int:
    """Submit `payload` atomically and return its scoped transcript offset.

    The editor drains the text and Enter from one ready input chunk, while still
    rendering after every decoded key before it consumes the next. Matching the
    completed visible row proves editor behavior when the payload includes edit
    controls; the returned offset scopes the evaluator-output assertion.
    """
    row_start = len(captured)
    send_editor_input(payload, b"\r")
    # Highlighting may insert CSI style sequences within the visible row. Match
    # its terminal text so the assertion still proves the completed edit.
    collect_until(row, row_start, visible=True)
    return row_start


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
    collect_until(b">> ", login_start)

    # Interactive editing. This is the only place the raw-mode editor is proven
    # on the real image: its selection is compiled for the target only, so no
    # host test can reach it. Reaching the prompt also proves that the adapter's
    # FlashOS standard-directory policy initialized config and history.
    edit_mark = submit_line(b"pwz\x7fd", b">> pwd")
    collect_until(b"\r\n/home/user", edit_mark)

    # Select and validate a logical cwd, create a script through a redirected
    # external process, and execute it through the non-interactive fsh path.
    submit_line(b"cd /tmp", b">> cd /tmp")
    cwd_mark = submit_line(b"pwd", b">> pwd")
    collect_until(b"\r\n/tmp", cwd_mark)
    submit_line(b"^echo pwd>x", b">> ^echo pwd>x")
    script_mark = submit_line(b"^fsh x", b">> ^fsh x")
    collect_until(b"\r\n/tmp", script_mark)

    # A two-process byte pipeline proves descriptor ownership, process spawn,
    # multi-member group placement, waiting, and foreground terminal handoff.
    pipeline_mark = submit_line(b"^echo p|^cat", b">> ^echo p|^cat")
    collect_until(b"\r\np", pipeline_mark)

    # Structured directory enumeration remains in-process while consuming the
    # same FlashOS directory-read seam. The temporary directory contains only
    # the script created above, so the rendered length is deterministic.
    structured_mark = submit_line(b"ls|length", b">> ls|length")
    collect_until(b"\r\n1", structured_mark)

    # Exercise addressable background launch and waiting without claiming the
    # still-unqualified FlashOS signal/stop-transition capability. Every
    # interaction stays within the target editor's emulated UART FIFO limit.
    job_mark = len(captured)
    submit_line(b"^sleep 1&", b">> ^sleep 1&")
    collect_until(b"[4] ", job_mark)
    submit_line(b"wait %4", b">> wait %4")

    # A conditional background chain is re-executed through fsh's supervisor,
    # qualifying executable discovery and the supervisor hang-up disposition.
    submit_line(b"^sleep 1&&true&", b">> ^sleep 1&&true&")
    collect_until(b"[5] ", job_mark)
    submit_line(b"wait %5", b">> wait %5")
    completion_mark = submit_line(b"pwd", b">> pwd")
    collect_until(b"\r\n/tmp", completion_mark)
    job_transcript = bytes(captured[job_mark:])
    if b"error[RUN001]" in job_transcript:
        raise RuntimeError("FlashOS job-control bring-up produced a runtime error")
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
]
if args.expect_root_locked:
    verified.append("locked root account")
print(f"verified: {', '.join(verified)}")
