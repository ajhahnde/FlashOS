#!/usr/bin/env python3
# boot_demo_typing.py — replays the FlashOS boot + fsh session for the VHS
# recorder that renders assets/boot_demo.gif.
#
# Three cadences, so the demo reads like a real console session:
#   * TYPED lines — what a user types at a prompt: the username at `login:`,
#     the masked password, and each `$ ` command (`help`, `ls`). The prompt
#     prints instantly, then the typed text appears key-by-key.
#   * COMMAND OUTPUT — a `$ ` command's result (the `help` text, the `ls`
#     listing): dumped as one BLOCK, the whole thing at once, the way a real
#     console paints command output — not line by line.
#   * PRINTED lines — boot `[ OK ]` status and the login/Password handshake:
#     emitted whole, one line at a time, as they scroll past at boot.
#
# Provenance: the boot block mirrors the current kernel's Mini-UART output
# (console_ui boot tags, `color` on — only the inner `OK` word is green, the
# brackets stay the default fg; no trailing periods on the `[ OK ]` lines).
# The post-login fsh session is RECONSTRUCTED from the programs' own byte
# output (login_elf's `login:` / masked `Password:`, fsh's homescreen banner
# + `help`, and `/bin/ls` of the initramfs root): the login gate blocks
# capturing the authenticated session under QEMU (the guest console receives
# no host stdin). Every byte emitted here is what those programs print — only
# the pacing and the green OK tint are added.
#
# The replayed content lives in scripts/boot_demo_session.txt (committed),
# not in boot.log: boot.log is gitignored and gets overwritten/truncated by
# each `picapture` run, which silently drops the reconstructed tail.

import sys, time, re, os

SESSION = os.path.join(os.path.dirname(__file__), "boot_demo_session.txt")

BOOT_LINE = 0.16        # pause after a printed boot/handshake line
AFTER_PROMPT = 0.30     # pause after a prompt prints, before typing starts
KEY = 0.06              # seconds per typed character
AFTER_CMD = 0.45        # pause after a typed command line, before its output
BLOCK_PAUSE = 0.55      # pause after a command's output block is dumped
HOLD = 5.0              # hold the final live-prompt frame at the end

# Boot status tags carry color in the real console (console_ui palette,
# `color` on): only the inner `OK` word is tinted green, the brackets keep
# the default fg. session.txt holds the plain `[ OK ]` text; the green is
# added here at emit time so the file stays readable and the escape is
# spelled once, mirroring console_ui.writeTag.
GREEN = "\x1b[32m"
RESET = "\x1b[0m"


def colorize(line):
    return line.replace("[ OK ]", "[ " + GREEN + "OK" + RESET + " ]")

# A line a user types: a prompt prefix + the typed text. `login: ` (the
# username), `Password: ` (the kernel masks each keystroke with '*', so the
# masked `*****` types out char-by-char), and each `$ ` command. A bare `# `
# line is cat/help output, not a prompt, so it is not matched.
TYPED = re.compile(r'^(login: |Password: |\$ )(\S.*)$')


def out(s):
    sys.stdout.write(s)
    sys.stdout.flush()


def is_comment(line):
    return line.lstrip().startswith("#")


def type_command(prompt, text):
    out(prompt)                         # prompt — instant
    time.sleep(AFTER_PROMPT)
    for ch in text:                     # typed text — key by key
        out(ch)
        time.sleep(KEY)
    out("\r\n")
    time.sleep(AFTER_CMD)


def main():
    with open(SESSION, "rb") as f:
        lines = [ln.rstrip("\r") for ln in
                 f.read().decode("utf-8", "replace").split("\n")]
    if lines and lines[-1] == "":
        lines.pop()

    # The trailing line is the live prompt waiting for input — the `$ ` shell
    # prompt after the last command, or a re-spawned `login:`. Print it
    # without a newline and hold, so the GIF ends on the live prompt (cursor
    # sitting on it) rather than scrolling past it.
    final = None
    if lines and lines[-1].rstrip() in ("login:", "$"):
        final = lines.pop()

    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        m = TYPED.match(line)
        if m:
            type_command(m.group(1), m.group(2))
            i += 1
            # A `$ ` command's output is everything up to the next typed
            # line. It paints in runs: consecutive comment (`#`) lines form
            # one block and the file's actual command lines (an rc's `cd /`)
            # form their own — so `cat`ing a commented file shows its
            # comment header at once, then each command line as its own
            # entry, instead of one glued blob; a plain listing (`ls`, with
            # no comments) stays a single block. The `login:` handshake
            # (m.group(1) != "$ ") is left to the line-by-line path below.
            if m.group(1) == "$ ":
                block = []
                while i < n and not TYPED.match(lines[i]):
                    block.append(lines[i])
                    i += 1
                k = 0
                while k < len(block):
                    is_c = is_comment(block[k])
                    j = k
                    while j < len(block) and is_comment(block[j]) == is_c:
                        j += 1
                    out("\r\n".join(block[k:j]) + "\r\n")
                    time.sleep(BLOCK_PAUSE)
                    k = j
        else:
            out(colorize(line) + "\r\n")  # boot / handshake — whole line, OK tinted
            time.sleep(BOOT_LINE)
            i += 1

    if final is not None:
        out(final + " ")                # waiting prompt, no newline
    time.sleep(HOLD)


if __name__ == "__main__":
    main()
