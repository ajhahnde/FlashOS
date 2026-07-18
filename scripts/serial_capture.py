#!/usr/bin/env python3
"""Capture a serial stream while keeping its controlling descriptor open."""

import argparse
import fcntl
import os
import select
import signal
import struct
import sys
import termios
import time
import tty


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--logfile", required=True)
    parser.add_argument(
        "--assert-dtr",
        action="store_true",
        help="keep DTR and RTS asserted for USB CDC consoles",
    )
    parser.add_argument(
        "--probe-cr",
        action="store_true",
        help="send CR once per second so an idle prompt becomes visible",
    )
    return parser.parse_args()


def open_serial(device, baud, assert_dtr):
    fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(fd)
    attrs = termios.tcgetattr(fd)
    speed = getattr(termios, f"B{baud}", None)
    if speed is None:
        os.close(fd)
        raise ValueError(f"unsupported baud rate: {baud}")
    attrs[4] = speed
    attrs[5] = speed
    attrs[2] |= termios.CLOCAL | termios.CREAD
    if hasattr(termios, "CRTSCTS"):
        attrs[2] &= ~termios.CRTSCTS
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    if assert_dtr:
        bits = struct.pack("I", termios.TIOCM_DTR | termios.TIOCM_RTS)
        fcntl.ioctl(fd, termios.TIOCMBIS, bits)

    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    return fd


def main():
    args = parse_args()
    running = True

    def stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    fd = None
    try:
        fd = open_serial(args.device, args.baud, args.assert_dtr)
        next_probe = time.monotonic()
        with open(args.logfile, "ab", buffering=0) as logfile:
            while running:
                ready, _, _ = select.select([fd], [], [], 0.2)
                if ready:
                    chunk = os.read(fd, 4096)
                    if not chunk:
                        raise OSError("serial device reached end of stream")
                    logfile.write(chunk)

                now = time.monotonic()
                if args.probe_cr and now >= next_probe:
                    os.write(fd, b"\r")
                    next_probe = now + 1.0
    except (OSError, ValueError) as error:
        print(f"serial capture failed: {error}", file=sys.stderr, flush=True)
        return 1
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
