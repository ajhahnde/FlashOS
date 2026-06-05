#!/usr/bin/env python3
# boot_demo_typing.py — replays the captured FlashOS boot (boot.log) for
# the VHS recorder that renders assets/boot_demo.gif.
#
# The kernel boot and in-kernel test harness stream by at a readable
# rate; the interactive fsh session at the tail is then re-emitted with a
# typewriter cadence — each shell command is printed key-by-key, then its
# real captured output appears — so the demo reads as a live session.
#
# Every byte is from the real capture: the firmware/kernel/harness from a
# Raspberry Pi 4B Mini-UART trace, the fsh session transcribed from a
# real USB-C console session. Nothing here is synthesized; only the
# pacing is. Live keystroke capture into the guest is not possible under
# QEMU (the guest console receives no host stdin), so the cadence is
# reproduced on replay instead.
#
# Timing is the only effect: boot at ~2400 B/s, commands at ~55 ms/key.

import sys, time, re

BOOT_RATE = 2400.0        # bytes/sec for the boot + harness scroll
KEY = 0.055               # seconds per typed command character
AFTER_PROMPT = 0.35       # pause after a prompt before the command types
AFTER_CMD = 0.45          # pause after a command line, before its output
LINE = 0.12               # pause after an output line

BOOT_END = "[PASS] login"  # last harness line before the interactive tail

# Lines whose typed part should animate: a prompt prefix + the text typed
# at it. Password is intentionally excluded (login suppresses its echo).
TYPED = re.compile(r'^(login: |\$ |# )(\S.*)$')


def out(s):
    sys.stdout.write(s)
    sys.stdout.flush()


def main():
    with open("boot.log", "rb") as f:
        data = f.read().decode("utf-8", "replace")

    end = data.find(BOOT_END)
    if end < 0:
        out(data)
        return
    nl = data.find("\n", end)
    boot, tail = data[:nl + 1], data[nl + 1:]

    # Boot + harness: stream at a fixed byte rate (readable scroll).
    delay = 1.0 / BOOT_RATE
    for ch in boot:
        out(ch)
        time.sleep(delay)

    # Interactive tail: typewriter cadence on the commands.
    for raw in tail.split("\n"):
        line = raw.rstrip("\r")
        m = TYPED.match(line)
        if m:
            out(m.group(1))                 # prompt, instant
            time.sleep(AFTER_PROMPT)
            for ch in m.group(2):           # command, key by key
                out(ch)
                time.sleep(KEY)
            out("\r\n")
            time.sleep(AFTER_CMD)
        else:
            out(line + "\r\n")              # output / debug / blank
            time.sleep(LINE)

    # Hold the final `login:` frame so the recording ends on it rather
    # than on the host shell prompt the script returns to on exit.
    time.sleep(3.5)


if __name__ == "__main__":
    main()
