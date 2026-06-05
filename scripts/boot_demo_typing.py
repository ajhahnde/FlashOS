#!/usr/bin/env python3
# boot_demo_typing.py — replays the FlashOS boot (boot.log) for the VHS
# recorder that renders assets/boot_demo.gif.
#
# The kernel boot streams by at a readable rate; the interactive fsh
# session at the tail is then re-emitted with a typewriter cadence — each
# shell command is printed key-by-key, then its output appears — so the
# demo reads as a live session focused on the shell.
#
# Provenance: the boot scroll (firmware + kernel `[ OK ]` lines up to the
# `login:` prompt) is a real Raspberry Pi 4B Mini-UART capture. The
# post-login fsh session is RECONSTRUCTED from the shell's own source
# behaviour (user_space/fsh + tools/{ls,cat,echo,login}_elf.zig), not a
# live capture: the login gate blocks capturing the authenticated session
# under QEMU (the guest console receives no host stdin). Every reconstructed
# line is the exact byte output those programs produce; only the pacing is
# added here.
#
# Timing: boot at ~180 B/s (the short boot stays readable), commands at
# ~55 ms/key.

import sys, time, re

BOOT_RATE = 180.0         # bytes/sec for the (short) boot scroll
KEY = 0.055               # seconds per typed command character
AFTER_PROMPT = 0.35       # pause after a prompt before the command types
AFTER_CMD = 0.45          # pause after a command line, before its output
LINE = 0.12               # pause after an output line

BOOT_END = "Reached target Userspace."  # last boot line before the login prompt

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
