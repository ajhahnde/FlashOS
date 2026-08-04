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
# typed text would sit between the prompt and the carriage return. The prompt
# texts mirror DEFAULT_PRIMARY_PROMPT and DEFAULT_CONTINUATION_PROMPT in the
# shell's editor module; a change there surfaces here as a timeout.
EMPTY_PROMPT_ROW = b"\x1b[K>> \r"
EMPTY_CONTINUATION_ROW = b"\x1b[K...> \r"

# How long the interactive assertions may take once the image has booted. Kept
# separate from the boot budget so a slow boot and a failing assertion cannot
# produce the same diagnostic.
INTERACTIVE_TIMEOUT = 180


def submit_line(payload: bytes, row: bytes) -> int:
    """Type `payload`, wait for the editor to draw `row`, then submit it.

    The editor renders at the top of its loop, before reading each byte, so the
    awaited row is the last thing drawn before the guest blocks on input. That
    makes this a synchronisation point as well as an assertion: Enter is sent
    only once the row has arrived, and the returned offset scopes the caller's
    assertion to what happens afterwards — the command result rather than the
    echo.

    Whether the row itself proves anything depends on the payload. One carrying
    control bytes, as the editing and recall assertions do, is editor-specific:
    a canonical console would echo the raw bytes instead. One made of plain
    characters would be echoed identically by a cooked terminal, so those calls
    rely on the assertion that follows the returned offset.
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
    collect_until(b"username:")
    login_start = len(captured)
    send(b"user\r")
    collect_until(b"password:", login_start)
    send(b"user\r")
    collect_until(b"Login successful!", login_start)
    collect_until(b">> ", login_start)
    shell_start = len(captured)
    send(b"printf 'hallo\\nwelt\\n' | head -n 1\r")
    collect_until(b"hallo", shell_start)
    collect_until(EMPTY_PROMPT_ROW, shell_start)

    # Boot is done. Re-arm the deadline so the assertions below get their own
    # budget: sharing one with the boot would report a merely slow boot as a
    # failure of the first interactive marker, which is the same signature as
    # an image that does not carry the editor at all.
    deadline = time.monotonic() + INTERACTIVE_TIMEOUT

    # Interactive editing. This is the only place the raw-mode editor is proven
    # on the real image: its selection is compiled for the target only, so no
    # host test can reach it.
    edit_mark = submit_line(b"echo hallo\x7f\x7fx", b">> echo halx")
    collect_until(b"halx", edit_mark)
    collect_until(EMPTY_PROMPT_ROW, edit_mark)

    recall_mark = submit_line(b"\x1b[A", b">> echo halx")
    collect_until(b"halx", recall_mark)
    collect_until(EMPTY_PROMPT_ROW, recall_mark)

    # A block spans three physical lines, so the continuation prompt has to
    # appear between them and the lines have to reach the parser joined. The two
    # mark-scoped continuation waits are what prove the join: an unjoined body
    # line would be a complete statement on its own and would re-prompt with
    # `>> `. The absence of a diagnostic then proves the joined source was
    # accepted rather than merely reassembled. The body is an assignment because
    # a block reaches the pure evaluator, which rejects command execution — and
    # a diagnostic reprints its own source line, so no marker may be a word that
    # was typed.
    opening_mark = submit_line(b"if true {", b">> if true {")
    collect_until(EMPTY_CONTINUATION_ROW, opening_mark)
    body_mark = submit_line(b"let joined = 1", b"...> let joined = 1")
    collect_until(EMPTY_CONTINUATION_ROW, body_mark)
    block_mark = submit_line(b"}", b"...> }")
    collect_until(EMPTY_PROMPT_ROW, block_mark)
    # Open-ended from the opening line, which is safe only while this assertion
    # precedes the permission boundary below — that one provokes a diagnostic
    # deliberately. Moving it after would trip this guard.
    if b"error[" in captured[opening_mark:]:
        raise AssertionError("the joined block did not evaluate cleanly")

    # Ctrl-C abandons the line without running it. The editor owns this in raw
    # mode: the terminal's own interrupt handling is switched off for the read.
    cancel_start = len(captured)
    send(b"echo never")
    collect_until(b">> echo never", cancel_start)
    abandon_mark = len(captured)
    send(b"\x03")
    collect_until(EMPTY_PROMPT_ROW, abandon_mark)
    # The prompt alone does not separate an abandoned line from an executed
    # one. A shell writes its output before it re-prompts, so by the time the
    # empty row arrives an execution would already be in the capture.
    if b"never" in captured[abandon_mark:]:
        raise AssertionError("Ctrl-C ran the line instead of abandoning it")

    # Exit status reaches the || branch. Host tests cover the semantics; this
    # proves the status survives a real process spawn through relibc.
    status_mark = submit_line(
        b"^false || echo fellback", b">> ^false || echo fellback"
    )
    collect_until(b"fellback", status_mark)
    collect_until(EMPTY_PROMPT_ROW, status_mark)

    # RedoxFS write, read back, and remove, as the unprivileged user. Each step
    # is asserted by its own observable: a returning prompt would follow a
    # failed removal just as readily as a successful one.
    write_mark = submit_line(
        b"echo persisted > /home/user/smoke.txt",
        b">> echo persisted > /home/user/smoke.txt",
    )
    collect_until(EMPTY_PROMPT_ROW, write_mark)
    read_mark = submit_line(
        b"cat /home/user/smoke.txt", b">> cat /home/user/smoke.txt"
    )
    collect_until(b"persisted", read_mark)
    collect_until(EMPTY_PROMPT_ROW, read_mark)
    remove_mark = submit_line(
        b"rm /home/user/smoke.txt", b">> rm /home/user/smoke.txt"
    )
    collect_until(EMPTY_PROMPT_ROW, remove_mark)
    gone_mark = submit_line(
        b"cat /home/user/smoke.txt || echo removed",
        b">> cat /home/user/smoke.txt || echo removed",
    )
    collect_until(b"removed", gone_mark)
    collect_until(EMPTY_PROMPT_ROW, gone_mark)

    # A direct non-zero external completion must return through the managed
    # foreground path rather than relying on a conditional chain's synchronous
    # wait. This is the real-image regression for a missing-file `cat` printing
    # its diagnostic and then stranding the prompt on Redox.
    missing_mark = submit_line(
        b"cat /home/user/definitely-missing",
        b">> cat /home/user/definitely-missing",
    )
    collect_until(b"No such file or directory", missing_mark)
    collect_until(EMPTY_PROMPT_ROW, missing_mark)

    # The unprivileged user must not be able to write outside its home. A
    # failed redirection is a shell error, not a command status, so it cannot
    # activate `||` — the boundary is asserted by the read that follows, whose
    # non-zero exit status does.
    denied_start = len(captured)
    send(b"echo nope > /etc/smoke.txt")
    collect_until(b">> echo nope > /etc/smoke.txt", denied_start)
    written_mark = len(captured)
    send(b"\r")
    collect_until(EMPTY_PROMPT_ROW, written_mark)
    absent_mark = submit_line(
        b"cat /etc/smoke.txt || echo denied",
        b">> cat /etc/smoke.txt || echo denied",
    )
    collect_until(b"denied", absent_mark)
    collect_until(EMPTY_PROMPT_ROW, absent_mark)

    if args.expect_root_locked:
        # Only the release profile locks root. `locked = true` writes an
        # unmatchable hash, so the attempt below must land back on the login
        # prompt; reaching a shell here is a security regression in the image,
        # not a test problem.
        logout_start = len(captured)
        send(b"\x04")
        collect_until(b"username:", logout_start)
        attempt_start = len(captured)
        send(b"root\r")
        collect_until(b"assword", attempt_start)
        rejected_start = len(captured)
        send(b"password\r")
        collect_until(b"username:", rejected_start)
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
    "Flash pipeline",
    "IHDA audio driver",
    "interactive editing",
    "exit status",
    "filesystem read/write",
    "permission boundary",
]
if args.expect_root_locked:
    verified.append("locked root account")
print(f"verified: {', '.join(verified)}")
