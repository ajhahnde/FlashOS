# Chapter 10: fsh — the Shell

Chapter 9 closed with an authenticated session handed to a shell binary.
This chapter is that binary: `fsh`, staged in the initramfs at
`/bin/fsh`, the program every interactive FlashOS session actually
lives in. It is a line-at-a-time REPL over the unified fd ABI — read a
line, tokenize it, dispatch — deliberately kept simple: exactly one pipe
stage, no redirection, no `$VAR`, no globbing. Richer parsing is
explicit future work, not an oversight.

## The prompt: a status line, not decoration

Every REPL iteration re-reads two things that can legitimately change
between commands — the working directory (`cd` moves it) and the
effective uid (a future in-shell privilege change) — and rebuilds the
prompt from them:

```flash
var cwd_buf [CWD_MAX]u8 = undefined
cn := flibc.sys.getcwd(&cwd_buf, cwd_buf.len)
cwd := if (cn > 0) cwd_buf[0..#intCast(cn)] else "?"
var prompt_buf [PROMPT_MAX]u8 = undefined
prompt := console_ui.renderPrompt(&prompt_buf, user, cwd, flibc.sys.geteuid() == 0)
```

*(excerpt from `user_space/fsh/fsh.flash` — not standalone-compilable)*

The login *name*, by contrast, is resolved once at REPL entry — a
session's uid never changes mid-run, so there is no reason to re-read
`/etc/passwd` on every prompt. Every ANSI escape in the prompt is
spelled in exactly one place, `console_ui.renderPrompt`, not scattered
across `fsh.flash` call sites: bold amber for the user name, a dim `@`
separator, plain white for the cwd, and an amber sigil — `#` for root,
`$` for everyone else, bold when root to flag the elevated privilege at
a glance. With color disabled every escape collapses to the empty
string and the bytes are the bare `user @ cwd # ` form — the same
single-source-of-truth pattern chapter 5 used for the boot log's
`[ OK ]` tags.

## readline: history and double-TAB over one buffer

fsh does not roll its own line editor — it drives flibc's `readlineEdit`
against a caller-owned line buffer and a small history ring:

```flash
var hist_slots [HIST_N]flibc.HistSlot = undefined
var hist = flibc.History.init(&hist_slots)
// …
switch flibc.readlineEdit(&line_buf, comp, &hist) {
    .eof => return, // ^D on an empty line / stream closed → logout
    .abandoned => emit(1, "\n"), // ^C
    .line => |l| {
        emit(1, "\n")
        dispatch(l)
        // …
    },
}
```

*(excerpt from `user_space/fsh/fsh.flash` — not standalone-compilable)*

`History` is a fixed ring — no allocator, its slots live on the REPL's
own stack frame — supporting Up/Down recall over the session's last
`HIST_N` lines. TAB completion walks two candidate sources depending on
cursor position: builtins plus `/bin` entries (via `sys_readdir`) for
the first token, or the filesystem for anything after. A single TAB
inserts the longest common extension of every matching candidate and
echoes it; a *second* TAB on an unchanged, still-ambiguous prefix lists
every candidate on a fresh line, then redraws the prompt and the
in-progress line so editing resumes exactly where it left off — the
double-TAB behavior a Bash user already expects.

## The tokenizer: one line in, at most one pipe out

`user_space/fsh/tokenize.flash` is a small, pure state machine — no
syscalls, no allocator — that fsh's dispatcher calls on every submitted
line:

```flash
pub fn tokenize(line []u8, argv *mut [MAX_ARGS]?[*:0]mut u8, buf []mut u8) Result {
    // …
    while i < line.len {
        // skip whitespace …
        if line[i] == '|' {
            pipes += 1
            if pipes > 1 { return .{ .err = .too_many_pipes } }
            pipe_at = argc
            argv[argc] = null
            argc += 1
            i += 1
            continue
        }
        // copy the token into buf, NUL-terminate, point argv[argc] at it …
    }
    // …
}
```

*(excerpt from `user_space/fsh/tokenize.flash` — not
standalone-compilable)*

Two design choices carry the rest of the shell. First, each token is
copied NUL-terminated into a scratch buffer and `argv` points *into*
that buffer — so the result is already an `execve`-ready
NULL-terminated vector, not a slice-based structure fsh would have to
convert. Second, a pipe boundary is marked the same way a NULL-terminated
`argv` ends: by writing a `null` into the `argv` slot at the split
point. That single trick means `argv[0..]` is the left command's ready
vector and `argv[left_argc + 1..]` is the right command's, with no
separate copy or second buffer. Overflow of either the argv array or the
scratch buffer truncates the line rather than erroring — matching
readline's own truncate-on-overflow policy — while a second `|` or a `|`
with an empty side on either side is a hard, reported error.

## Dispatch: builtins in-process, everything else forks

```flash
fn runSingle(argv *mut [tok.MAX_ARGS]?[*:0]mut u8, argc usize) {
    name := argv[0] orelse return
    if runBuiltin(name, argv, argc) {
        return
    }
    pid := flibc.fork()
    if pid == 0 {
        _ = flibc.execvp(name, #ptrCast(argv))
        emit(2, "fsh: command not found\n")
        flibc.exit()
    } else if pid > 0 {
        _ = flibc.wait()
    }
}
```

*(excerpt from `user_space/fsh/fsh.flash` — not standalone-compilable)*

Builtins — `cd`, `pwd`, `exit`/`logout`, `help`, `free`, `whoami`,
`reboot` — run in-process because they need to mutate the shell's own
state (`cd` changes *this* task's `cwd`, not a child's) or because
forking would be pure overhead for something that touches no other
process. Anything else forks and `execvp`s: bare names resolve to
`/bin/<name>` (no `$PATH` yet, no environment), a slashed name runs
verbatim. `help` derives its "Programs in /bin" listing from a live
`sys_readdir("/bin", …)` walk rather than a hardcoded catalog, so a new
coreutil shows up in `help` — and in TAB completion — by existing, with
no second place to update.

The one pipe stage wires `sys_pipe` + two forks + `dup2`: the left
child's stdout is redirected to the pipe's write end, the right child's
stdin to its read end, both ends are closed in the shell itself (so the
right child actually sees EOF once the left one exits), and the shell
reaps both children.

## Full-screen tools and the console-mode reset

Every command's output is followed by a line the reader might not
expect from a shell that never explicitly disables raw mode itself:

```flash
_ = flibc.sys.set_console_mode(0)
```

Chapter 12's full-screen tools (`less`, `edit`) take over the terminal —
alternate screen, raw keystroke mode — for the duration of their run.
`fsh` does not need to know any of that; it just resets the console
mode back to cooked/echo-on after every dispatched command,
unconditionally. That one line is what makes it safe for a full-screen
child to leave the console in whatever state it left it, and for the
next prompt to still behave correctly either way.

## Lab: a mini command tokenizer

fsh's real tokenizer copies bytes into a caller-owned scratch buffer and
threads pointers through `argv` slots — precise, but more machinery
than a first pass needs to demonstrate the idea. This Lab is a
simplified standalone version: split a command line on whitespace into
up to 8 argument slices (no pipe handling), and print each one.

```flash
// tokenize_dump.flash - split argv[0] on whitespace, print each token.
use flibc

link "flibc_start"

fn isSpace(c u8) bool {
    return c == ' ' || c == '\t'
}

export fn main(argc usize, argv argv) noreturn {
    if argc < 2 {
        flibc.exit()
    }
    line := argv[1].?
    var n usize = 0
    while line[n] != 0 {
        n += 1
    }
    const s = line[0..n]

    var i usize = 0
    while i < s.len {
        while i < s.len && isSpace(s[i]) {
            i += 1
        }
        if i >= s.len {
            break
        }
        start := i
        while i < s.len && !isSpace(s[i]) {
            i += 1
        }
        flibc.printf("%s\n", .{s[start..i]})
    }
    flibc.exit()
}
```

> [!NOTE]
> Real fsh NUL-terminates each token as it copies it, so `argv` slots
> point at independently terminated C strings. This Lab instead slices
> the single already-NUL-terminated `argv[1]` in place — enough to show
> the whitespace-splitting logic without fsh's buffer bookkeeping.

Compile it with the button below.

## What's next

fsh resolves every external command through the VFS and hands each
child a `cwd` it inherited or changed with `cd` — chapter 11 opens up
what that path resolution actually walks: the VFS shim, its two
backends, and the FAT32 filesystem mounted at `/mnt`.
