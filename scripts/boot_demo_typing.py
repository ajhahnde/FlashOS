#!/usr/bin/env python3
# boot_demo_typing.py — replays the FlashOS boot (boot.log) for the VHS
# recorder that renders assets/boot_demo.gif.
#
# The kernel boot streams by at a readable rate; the interactive fsh
# session at the tail is then re-emitted line by line — each shell command
# line appears whole, then its output — so the demo reads as a real
# console session focused on the shell.
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
# Timing: the whole replay is paced per line — no per-character streaming
# (that reads as a typewriter); boot/status lines a touch slower than
# command output.

import sys, time, re

BOOT_LINE = 0.18          # pause after a boot/status line
AFTER_CMD = 0.45          # pause after a command line, before its output
LINE = 0.12               # pause after an output line

BOOT_END = "Reached target Userspace."  # last boot line before the login prompt

# Command lines (a prompt prefix + a command): given the longer AFTER_CMD
# pause so the command/result rhythm reads naturally. The password line is
# excluded (login suppresses its echo).
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

    # Boot: whole lines (no per-character streaming — that reads as a
    # typewriter effect; the real console emits status lines at once).
    boot_lines = boot.split("\n")
    if boot_lines and boot_lines[-1] == "":
        boot_lines.pop()
    for raw in boot_lines:
        out(raw.rstrip("\r") + "\r\n")
        time.sleep(BOOT_LINE)

    # Interactive tail: whole lines (the real console emits lines, not
    # keystrokes — no typewriter effect).
    for raw in tail.split("\n"):
        line = raw.rstrip("\r")
        out(line + "\r\n")
        time.sleep(AFTER_CMD if TYPED.match(line) else LINE)

    # Hold the final `login:` frame so the recording ends on it rather
    # than on the host shell prompt the script returns to on exit.
    time.sleep(3.5)


if __name__ == "__main__":
    main()
