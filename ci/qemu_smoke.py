#!/usr/bin/env python3
"""Boot an immutable FlashOS disk image and verify its serial contract."""

from __future__ import annotations

import argparse
import os
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
    "4",
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


def collect_until(marker: bytes, start: int = 0) -> None:
    while marker not in captured[start:]:
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


# The raw-mode editor redraws its whole row on every keystroke, so the serial
# stream carries escape sequences and repeats the prompt constantly. Waiting for
# a bare prompt therefore proves nothing: it is already satisfied by the typing
# that precedes the key under test. An empty row is unambiguous, because any
# typed text would sit between the prompt and the carriage return.
EMPTY_PROMPT_ROW = b"\x1b[Kfsh> \r"


def submit_line(payload: bytes, row: bytes) -> int:
    """Type `payload`, prove the editor drew `row`, then submit it.

    A row carrying the prompt and the edited text contiguously is something
    only this editor produces; a canonical console echoes the raw bytes,
    backspaces and escape sequences included. Enter is sent only after that row
    arrives, and the returned offset scopes the caller's assertion to what
    happened afterwards — the command result rather than the echo.
    """
    row_start = len(captured)
    send(payload)
    collect_until(row, row_start)
    submitted = len(captured)
    send(b"\r")
    return submitted


failure: BaseException | None = None
try:
    collect_until(b"FlashOS Bootloader")
    collect_until(b"Arrow keys and enter select mode")
    send(b"\r")
    collect_until(b"FlashOS starting")
    collect_until(b"Starting framebuffer debug")
    collect_until(b'pcid-spawner: spawn "/usr/lib/drivers/ihdad"')
    collect_until(b"flashos login:")
    login_start = len(captured)
    send(b"user\r")
    collect_until(b"Welcome to FlashOS!", login_start)
    collect_until(b"fsh> ", login_start)
    shell_start = len(captured)
    send(b"printf 'hallo\\nwelt\\n' | head -n 1\r")
    collect_until(b"hallo", shell_start)
    collect_until(b"fsh> ", shell_start)

    # Interactive editing. This is the only place the raw-mode editor is proven
    # on the real image: its selection is compiled for the target only, so no
    # host test can reach it.
    edit_mark = submit_line(b"echo hallo\x7f\x7fx", b"fsh> echo halx")
    collect_until(b"halx", edit_mark)

    recall_mark = submit_line(b"\x1b[A", b"fsh> echo halx")
    collect_until(b"halx", recall_mark)

    # A block spans two physical lines, so the continuation prompt has to
    # appear between them and the two lines have to reach the parser joined.
    multiline_start = len(captured)
    send(b"if true {")
    collect_until(b"fsh> if true {", multiline_start)
    send(b"\r")
    collect_until(b"\x1b[K...> \r", multiline_start)
    block_mark = submit_line(b"}", b"...> }")
    collect_until(EMPTY_PROMPT_ROW, block_mark)

    # Ctrl-C abandons the line without running it. The editor owns this in raw
    # mode: the terminal's own interrupt handling is switched off for the read.
    cancel_start = len(captured)
    send(b"echo never")
    collect_until(b"fsh> echo never", cancel_start)
    abandon_mark = len(captured)
    send(b"\x03")
    collect_until(EMPTY_PROMPT_ROW, abandon_mark)

    # Exit status reaches the || branch. Host tests cover the semantics; this
    # proves the status survives a real process spawn through relibc.
    status_mark = submit_line(
        b"^false || echo fellback", b"fsh> ^false || echo fellback"
    )
    collect_until(b"fellback", status_mark)

    # RedoxFS write, read back, and remove, as the unprivileged user.
    write_mark = submit_line(
        b"echo persisted > /home/user/smoke.txt",
        b"fsh> echo persisted > /home/user/smoke.txt",
    )
    collect_until(EMPTY_PROMPT_ROW, write_mark)
    read_mark = submit_line(
        b"cat /home/user/smoke.txt", b"fsh> cat /home/user/smoke.txt"
    )
    collect_until(b"persisted", read_mark)
    remove_mark = submit_line(
        b"rm /home/user/smoke.txt", b"fsh> rm /home/user/smoke.txt"
    )
    collect_until(EMPTY_PROMPT_ROW, remove_mark)

    # The unprivileged user must not be able to write outside its home. A
    # failed redirection is a shell error, not a command status, so it cannot
    # activate `||` — the boundary is asserted by the read that follows, whose
    # non-zero exit status does.
    denied_start = len(captured)
    send(b"echo nope > /etc/smoke.txt")
    collect_until(b"fsh> echo nope > /etc/smoke.txt", denied_start)
    send(b"\r")
    absent_mark = submit_line(
        b"cat /etc/smoke.txt || echo denied",
        b"fsh> cat /etc/smoke.txt || echo denied",
    )
    collect_until(b"denied", absent_mark)

    if args.expect_root_locked:
        # Only the release profile locks root. `locked = true` writes an
        # unmatchable hash, so the attempt below must land back on the login
        # prompt; reaching a shell here is a security regression in the image,
        # not a test problem.
        logout_start = len(captured)
        send(b"\x04")
        collect_until(b"flashos login:", logout_start)
        attempt_start = len(captured)
        send(b"root\r")
        collect_until(b"assword", attempt_start)
        rejected_start = len(captured)
        send(b"password\r")
        collect_until(b"flashos login:", rejected_start)
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
    "FlashShell pipeline",
    "IHDA audio driver",
    "interactive editing",
    "exit status",
    "filesystem read/write",
    "permission boundary",
]
if args.expect_root_locked:
    verified.append("locked root account")
print(f"verified: {', '.join(verified)}")
