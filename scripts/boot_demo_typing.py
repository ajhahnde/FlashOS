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
# the pacing, the green OK tint, and the colored shell prompt are added.
#
# The replayed content lives in scripts/boot_demo_session.txt (committed),
# not in boot.log: boot.log is gitignored and gets overwritten/truncated by
# each `picapture` run, which silently drops the reconstructed tail.

import sys, time, re, os

SESSION = os.path.join(os.path.dirname(__file__), "boot_demo_session.txt")
ZON = os.path.join(os.path.dirname(__file__), "..", "build.zig.zon")

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

# The fsh homescreen banner and `help` output carry color in the real console
# too (console_ui.homescreen / fsh HELP_TEXT + listBin, `color` on). session.txt
# holds the plain text for readability; the escapes are spelled once here and
# added at emit time, mirroring those renderers byte-for-byte:
#   * banner  — amber `FlashOS`, grey version + author, marker in default fg
#               (console_ui.homescreen).
#   * help    — bold `Commands:` (fsh HELP_TEXT), then the `/bin` listing with
#               each program name in cyan (fsh listBin, palette.cyan).
GREY = "\x1b[90m"       # palette.grey (bright_black)
CYAN = "\x1b[36m"       # palette.cyan — the listBin program-name color
YELLOW = "\x1b[33m"     # palette.yellow — the amber product name / sigil
BOLD = "\x1b[1m"

# `FlashOS [v<version>] by <author><marker>` — the homescreen line. The marker
# tail (` - type 'help' for commands`) stays the default fg, exactly as
# homescreen() closes every color with reset before emitting it.
BANNER = re.compile(r"^FlashOS \[v(.+?)\] by (\S+)(.*)$")


def colorize(line):
    line = line.replace("[ OK ]", "[ " + GREEN + "OK" + RESET + " ]")
    m = BANNER.match(line)
    if m:
        version, author, tail = m.group(1), m.group(2), m.group(3)
        return (YELLOW + "FlashOS" + RESET + " [v" + GREY + version + RESET +
                "] by " + GREY + author + RESET + tail)
    if line == "Commands:":                 # fsh HELP_TEXT header, bold
        return BOLD + "Commands:" + RESET
    return line


def colorize_lines(lines):
    # Second pass over the emit-ready lines: colorize each in place, plus the
    # one line that needs its predecessor for context — the `/bin` names line
    # that follows `Programs in /bin:` gets every whitespace-delimited program
    # name tinted cyan (listBin colors the names, not the spacing).
    out_lines = []
    prev_bin_header = False
    for ln in lines:
        if prev_bin_header:
            out_lines.append(re.sub(r"\S+", lambda t: CYAN + t.group(0) + RESET, ln))
            prev_bin_header = False
            continue
        out_lines.append(colorize(ln))
        prev_bin_header = ln.startswith("Programs in /bin:")
    return out_lines

# The live `fsh` prompt carries color too (console_ui.renderPrompt, `color`
# on): `<user> @ <cwd> <sigil>` with a bold-amber user, a dimmed separator, a
# white cwd, and an amber sigil. session.txt holds the plain `$ ` sigil for
# readability; the full colored prompt is spelled once here and substituted at
# emit time, mirroring renderPrompt exactly. The demo runs as `flash` (non-
# root, so no bold sigil) from `/` — the root the `ls` block lists.
DIM = "\x1b[2m"         # palette.dim — the ` @ ` prompt separator
WHITE = "\x1b[37m"      # palette.white — the prompt cwd
SHELL_PROMPT = (BOLD + YELLOW + "flash" + RESET + DIM + " @ " + RESET +
                WHITE + "/" + RESET + " " + YELLOW + "$ " + RESET)

# A line a user types: a prompt prefix + the typed text. `login: ` (the
# username), `Password: ` (the kernel masks each keystroke with '*', so the
# masked `*****` types out char-by-char), and each `$ ` command. A bare `# `
# line is cat/help output, not a prompt, so it is not matched.
TYPED = re.compile(r'^(login: |Password: |\$ )(\S.*)$')


def zon_version():
    # Single-source the banner version from build.zig.zon (the one truth, the
    # same field fsh derives its homescreen version from via build_options) so
    # the demo's `FlashOS [v…]` line never drifts from the shipped release.
    with open(ZON, "r", encoding="utf-8") as f:
        m = re.search(r'\.version\s*=\s*"([^"]+)"', f.read())
    return m.group(1) if m else "?"


def out(s):
    sys.stdout.write(s)
    sys.stdout.flush()


def is_comment(line):
    return line.lstrip().startswith("#")


def type_command(prompt, text):
    if prompt == "$ ":                  # the shell sigil carries the live color
        prompt = SHELL_PROMPT
    out(prompt)                         # prompt — instant
    time.sleep(AFTER_PROMPT)
    for ch in text:                     # typed text — key by key
        out(ch)
        time.sleep(KEY)
    out("\r\n")
    time.sleep(AFTER_CMD)


def main():
    # Clear the screen (+ scrollback) and home the cursor before the first
    # boot byte, so the GIF opens on the boot output at the top-left — not on
    # the launch command the VHS tape typed (hidden) to start this replay.
    # It also gives the final `reboot` a clean loop seam: when the GIF wraps,
    # the screen is wiped just as a real machine reset would clear it.
    out("\x1b[2J\x1b[3J\x1b[H")
    with open(SESSION, "rb") as f:
        lines = [ln.rstrip("\r") for ln in
                 f.read().decode("utf-8", "replace").split("\n")]
    if lines and lines[-1] == "":
        lines.pop()
    version = zon_version()
    lines = [ln.replace("{{VERSION}}", version) for ln in lines]
    # Tint the emit-ready lines once (boot `OK`, banner, `help` output). Typed
    # command lines are left untouched, so TYPED still matches their raw text.
    lines = colorize_lines(lines)

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
            out(line + "\r\n")  # boot / handshake — whole line, already tinted
            time.sleep(BOOT_LINE)
            i += 1

    if final is not None:
        # The trailing live prompt: the colored shell prompt when it is the
        # `$` sigil, otherwise the raw text (a re-spawned `login:`) + a space.
        out(SHELL_PROMPT if final.rstrip() == "$" else final + " ")
    time.sleep(HOLD)


if __name__ == "__main__":
    main()
