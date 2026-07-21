//! `fsh` — the FlashOS shell.
//!
//! A line-at-a-time REPL over the unified fd ABI: read a line with the full line
//! editor (fd 0), tokenize it (one optional `|`), dispatch built-ins in-process, and
//! fork + `execvp` external commands. Exactly one pipe stage is supported; richer
//! parsing (redirection, multi-stage pipelines, quoting, globbing, `$VAR`) is out of
//! scope here.
//!
//! Entry is the runtime's `_start` argc/argv shim; `main` ignores argv. Every buffer
//! is a stack local or a literal — no allocator, and no module-level mutable state: a
//! `static mut` would land in `.bss`, which the single R+X PT_LOAD
//! (`link/fsh_linker.ld`) cannot write. The line, argv, scratch, history, and fshrc
//! buffers all live on the 64 KiB user stack.
//!
//! The tokenizer is pure and host-tested next door in [`tokenize`]; this file is the
//! syscall-driving loop, exercised end to end by the PID-1 hand-off: init execs
//! `/bin/fsh` after the harness, and the boot watchdog treats the homescreen line the
//! shell prints at REPL entry (the stable `type 'help' for commands` tail) as the boot
//! success signal — reaching the prompt is the pass.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod tokenize;

#[cfg(target_os = "none")]
use flashos_console_ui::{homescreen, palette, render_prompt};
#[cfg(target_os = "none")]
use flashos_flibc::execvp::execvp;
#[cfg(target_os = "none")]
use flashos_flibc::readline::{readline_edit, Completion, HistSlot, History, Outcome};
#[cfg(target_os = "none")]
use flashos_flibc::{console_sink, err_sink, printf, sys, Part};
#[cfg(target_os = "none")]
use flashsdk_abi::syscall::Dirent;
#[cfg(target_os = "none")]
use flashsdk_rt::{cstr_bytes, entry, Argv};
#[cfg(target_os = "none")]
use tokenize::{Arg, MAX_ARGS};

/// The submitted-line buffer.
#[cfg(target_os = "none")]
const LINE_MAX: usize = 256;
/// Tokenizer scratch: the NUL-joined argv bytes the slots point into.
#[cfg(target_os = "none")]
const TOK_BUF: usize = 256;
/// The `/etc/fshrc` slurp.
#[cfg(target_os = "none")]
const FSHRC_MAX: usize = 512;
/// The `/etc/passwd` slurp, for `whoami` and the prompt's login name.
#[cfg(target_os = "none")]
const PASSWD_MAX: usize = 512;
/// Matches the kernel's working-directory ABI ceiling (`TaskStruct.cwd`).
#[cfg(target_os = "none")]
const CWD_MAX: usize = 256;
/// A login name, or the decimal-uid fallback when no account owns the uid.
#[cfg(target_os = "none")]
const USER_MAX: usize = 32;
/// User + cwd + the fixed glyphs and escapes the prompt renderer adds.
#[cfg(target_os = "none")]
const PROMPT_MAX: usize = CWD_MAX + USER_MAX + 64;
/// History depth. The ring's slots sit on the REPL's frame (no allocator, no `.bss`);
/// 16 slots is about 4.2 KiB, comfortable on the 64 KiB user stack. Raising it costs
/// only stack.
#[cfg(target_os = "none")]
const HIST_N: usize = 16;

#[cfg(target_os = "none")]
const AUTHOR: &[u8] = b"ajhahnde";

/// The project version, taken from the Cargo workspace version (the single source),
/// so no release literal is spelled here.
#[cfg(target_os = "none")]
const VERSION: &[u8] = env!("CARGO_PKG_VERSION").as_bytes();

/// Built-in names, offered alongside `/bin` for first-token TAB completion. They
/// dispatch in-process, so a directory listing alone would never surface them.
#[cfg(target_os = "none")]
const BUILTINS: [&[u8]; 8] = [
    b"cd", b"pwd", b"exit", b"logout", b"help", b"free", b"whoami", b"reboot",
];

/// Everything `help` prints after the bolded heading. The heading carries an escape, so
/// it is emitted separately rather than spliced into this literal.
#[cfg(target_os = "none")]
const HELP_BODY: &[u8] = b"\n  cd [dir]       change working directory\n  pwd            print working directory\n  free           show free page count\n  whoami         print the logged-in user\n  reboot         restart the machine\n  exit / logout  end the session\n  help           show this help\n\nRun a program:  <cmd> [args]    pipe:  <a> | <b>\nTAB completes commands + paths\n\n";

#[cfg(target_os = "none")]
entry!(main);

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    run_fshrc();
    repl();
    0
}

// ---- I/O ---------------------------------------------------------------------

/// The shell's one console write, routed by fd through the flibc sinks, so every byte
/// fsh emits crosses the syscall boundary at a single adapter. Diagnostics are tinted
/// red here and nowhere else: no `fsh:`/`cd:` call site spells an escape. With colour
/// off the palette constants are empty and the bytes go out bare.
#[cfg(target_os = "none")]
fn emit(fd: i32, s: &[u8]) {
    if fd == 2 {
        err_sink(palette::RED);
        err_sink(s);
        err_sink(palette::RESET);
    } else {
        console_sink(s);
    }
}

// ---- startup file ------------------------------------------------------------

/// Read `/etc/fshrc` once and run each non-comment, non-blank line through the same
/// dispatcher the REPL uses. A missing file is not an error — the rc file is optional.
/// Deliberately runs nothing that reaches `dump_free`: that syscall is a counted
/// checkpoint in the boot contract, and an rc-time call would shift the CI baseline.
#[cfg(target_os = "none")]
fn run_fshrc() {
    let fd = unsafe { sys::open(b"/etc/fshrc\0".as_ptr()) };
    if fd < 0 {
        return;
    }
    let mut buf = [0u8; FSHRC_MAX];
    let n = sys::read(fd, &mut buf);
    sys::close(fd);
    if n <= 0 {
        return;
    }

    let content = &buf[..n as usize];
    let mut start = 0;
    for i in 0..=content.len() {
        if i == content.len() || content[i] == b'\n' {
            let line = trim(&content[start..i]);
            if !line.is_empty() && line[0] != b'#' {
                dispatch(line);
            }
            start = i + 1;
        }
    }
}

// ---- REPL --------------------------------------------------------------------

#[cfg(target_os = "none")]
fn repl() {
    let mut line_buf = [0u8; LINE_MAX];
    let mut hist_slots = [HistSlot::default(); HIST_N];
    let mut hist = History::new(&mut hist_slots);

    homescreen(console_sink, VERSION, AUTHOR);

    // The login name is resolved once: the shell never changes uid mid-session. The
    // cwd, by contrast, is re-read every iteration, because `cd` moves it.
    let mut user_buf = [0u8; USER_MAX];
    let user_len = resolve_user(&mut user_buf);
    let user: &[u8] = match user_len {
        Some(n) => &user_buf[..n],
        None => b"?",
    };

    loop {
        let mut cwd_buf = [0u8; CWD_MAX];
        let cn = sys::getcwd(&mut cwd_buf);
        let cwd: &[u8] = if cn > 0 {
            &cwd_buf[..cn as usize]
        } else {
            b"?"
        };

        let mut prompt_buf = [0u8; PROMPT_MAX];
        let prompt = render_prompt(&mut prompt_buf, user, cwd, sys::geteuid() == 0);
        emit(1, prompt);

        // The editor is handed the live prompt: its double-TAB candidate listing
        // reprints prompt + line after the list, so the cursor lands back on a faithful
        // prompt.
        let comp = Completion {
            builtins: &BUILTINS,
            bin_dir: b"/bin\0",
            prompt,
        };
        match readline_edit(&mut line_buf, comp, Some(&mut hist)) {
            // ^D on an empty line, or the stream closed: log out.
            Outcome::Eof => return,
            // ^C: the editor drew nothing, so the shell ends the line itself.
            Outcome::Abandoned => emit(1, b"\n"),
            Outcome::Line(l) => {
                emit(1, b"\n"); // the editor submits without echoing the CR
                dispatch(l);
                // A full-screen child may have left the kernel console raw, masked, or
                // in the alternate screen; reset it so the next prompt and the next line
                // edit behave.
                sys::set_console_mode(0);
                // A blank line after a real command's output, before the next prompt —
                // skipped on a bare Enter, so empty lines do not double up.
                if !trim(l).is_empty() {
                    emit(1, b"\n");
                }
            }
        }
    }
}

// ---- dispatch ----------------------------------------------------------------

#[cfg(target_os = "none")]
fn dispatch(line: &[u8]) {
    let mut argv: [Arg; MAX_ARGS] = [None; MAX_ARGS];
    let mut buf = [0u8; TOK_BUF];
    match tokenize::tokenize(line, &mut argv, &mut buf) {
        tokenize::Result::Empty => {}
        tokenize::Result::Err(tokenize::Err::TooManyPipes) => {
            emit(2, b"fsh: only one pipe supported\n")
        }
        tokenize::Result::Err(tokenize::Err::EmptySide) => {
            emit(2, b"fsh: missing command around |\n")
        }
        tokenize::Result::Single(argc) => run_single(&argv, argc),
        tokenize::Result::Piped(p) => run_piped(&argv, p),
    }
}

/// The argv vector starting at `from`, in the form `execve` wants: a NULL-terminated
/// array of NUL-terminated pointers. [`Arg`] is `Option<NonNull<u8>>` precisely so the
/// in-memory terminator is a real null pointer — which makes this a cast, not a rebuild.
#[cfg(target_os = "none")]
fn argv_ptr(argv: &[Arg; MAX_ARGS], from: usize) -> *const *const u8 {
    argv[from..].as_ptr().cast()
}

#[cfg(target_os = "none")]
fn run_single(argv: &[Arg; MAX_ARGS], argc: usize) {
    let Some(name) = argv[0] else { return };
    let name = name.as_ptr().cast_const();
    if run_builtin(name, argv, argc) {
        return;
    }

    let pid = sys::fork();
    if pid == 0 {
        unsafe { execvp(name, argv_ptr(argv, 0)) };
        emit(2, b"fsh: command not found\n"); // execvp only returns on failure
        sys::exit(0);
    } else if pid > 0 {
        sys::wait();
    } else {
        emit(2, b"fsh: fork failed\n");
    }
}

/// One pipe stage. Both argv vectors live back to back in the same array, separated by
/// the null the tokenizer wrote at the boundary: the left command starts at `0`, the
/// right at `left_argc + 1`. Wire the write end onto the left child's stdout and the
/// read end onto the right child's stdin, close both ends everywhere, and reap both.
#[cfg(target_os = "none")]
fn run_piped(argv: &[Arg; MAX_ARGS], p: tokenize::Piped) {
    let packed = sys::pipe();
    if packed < 0 {
        emit(2, b"fsh: pipe failed\n");
        return;
    }
    let (rfd, wfd) = sys::pipe_ends(packed);

    let lpid = sys::fork();
    if lpid == 0 {
        sys::dup2(wfd, 1);
        sys::close(rfd);
        sys::close(wfd);
        if let Some(name) = argv[0] {
            unsafe { execvp(name.as_ptr().cast_const(), argv_ptr(argv, 0)) };
        }
        sys::exit(0);
    }
    if lpid < 0 {
        // No child exists yet: close both ends, reap nothing.
        emit(2, b"fsh: fork failed\n");
        sys::close(rfd);
        sys::close(wfd);
        return;
    }

    let rpid = sys::fork();
    if rpid == 0 {
        sys::dup2(rfd, 0);
        sys::close(rfd);
        sys::close(wfd);
        if let Some(name) = argv[p.left_argc + 1] {
            unsafe { execvp(name.as_ptr().cast_const(), argv_ptr(argv, p.left_argc + 1)) };
        }
        sys::exit(0);
    }
    if rpid < 0 {
        // The left child is already running: close both ends, reap it once.
        emit(2, b"fsh: fork failed\n");
        sys::close(rfd);
        sys::close(wfd);
        sys::wait();
        return;
    }

    // The shell must hold neither end open, or the right child never sees EOF.
    sys::close(rfd);
    sys::close(wfd);
    sys::wait();
    sys::wait();
}

// ---- built-ins (in-process, no fork) -----------------------------------------

#[cfg(target_os = "none")]
fn run_builtin(name: *const u8, argv: &[Arg; MAX_ARGS], argc: usize) -> bool {
    let name = unsafe { cstr_bytes(name) };

    if name == b"exit" || name == b"logout" {
        sys::exit(0);
    }
    if name == b"reboot" {
        sys::reboot();
    }
    if name == b"help" {
        emit(1, palette::BOLD);
        emit(1, b"Commands:");
        emit(1, palette::RESET);
        emit(1, HELP_BODY);
        list_bin();
        return true;
    }
    if name == b"cd" {
        let target: *const u8 = match argv[1] {
            Some(p) if argc >= 2 => p.as_ptr().cast_const(),
            _ => b"/\0".as_ptr(),
        };
        if unsafe { sys::chdir(target) } < 0 {
            emit(2, b"cd: cannot change directory\n");
        }
        return true;
    }
    if name == b"pwd" {
        let mut buf = [0u8; CWD_MAX];
        let n = sys::getcwd(&mut buf);
        if n < 0 {
            emit(2, b"pwd: cannot read working directory\n");
        } else {
            emit(1, &buf[..n as usize]);
            emit(1, b"\n");
        }
        return true;
    }
    if name == b"free" {
        printf(&[
            Part::Str(b"free pages: "),
            Part::Udec(sys::dump_free()),
            Part::Str(b"\n"),
        ]);
        return true;
    }
    if name == b"whoami" {
        whoami();
        return true;
    }
    false
}

/// List `/bin`, so `help` advertises the external commands without a hardcoded
/// catalogue — a new tool shows up by existing (and TAB-completes too). The `Dirent` is
/// a stack local; a missing `/bin` simply lists nothing.
#[cfg(target_os = "none")]
fn list_bin() {
    emit(1, b"Programs in /bin:\n ");
    let mut d = Dirent::default();
    let mut i: u64 = 0;
    while unsafe { sys::readdir(b"/bin\0".as_ptr(), i, &mut d) } == 0 {
        let mut n = 0;
        while n < d.name.len() && d.name[n] != 0 {
            n += 1;
        }
        emit(1, b" ");
        emit(1, palette::CYAN);
        emit(1, &d.name[..n]);
        emit(1, palette::RESET);
        i += 1;
    }
    emit(1, b"\n");
}

/// The `whoami` built-in: print the real uid's login name. A thin wrapper over
/// [`resolve_user`], which the prompt shares, so the name is resolved one way only.
#[cfg(target_os = "none")]
fn whoami() {
    let mut buf = [0u8; USER_MAX];
    match resolve_user(&mut buf) {
        Some(n) => {
            emit(1, &buf[..n]);
            emit(1, b"\n");
        }
        None => emit(2, b"whoami: cannot read uid\n"),
    }
}

/// Resolve the real uid's login name into `out`, returning its length. The lookup goes
/// through the shared `/etc/passwd` parser — the same one the kernel and `/bin/login`
/// use. On a parser miss or an unreadable file the decimal uid is formatted instead, so
/// a uid without an account stays identifiable. `None` only when the uid syscall itself
/// fails.
#[cfg(target_os = "none")]
fn resolve_user(out: &mut [u8]) -> Option<usize> {
    let uid_raw = sys::getuid();
    if uid_raw < 0 {
        return None;
    }
    let uid = uid_raw as u32;

    let fd = unsafe { sys::open(b"/etc/passwd\0".as_ptr()) };
    if fd >= 0 {
        let mut buf = [0u8; PASSWD_MAX];
        let mut n = 0;
        while n < buf.len() {
            let r = sys::read(fd, &mut buf[n..]);
            if r <= 0 {
                break;
            }
            n += r as usize;
        }
        sys::close(fd);
        if let Some(entry) = flashos_pwfile::lookup_by_uid(&buf[..n], uid) {
            let take = core::cmp::min(entry.user.len(), out.len());
            out[..take].copy_from_slice(&entry.user[..take]);
            return Some(take);
        }
    }
    Some(fmt_u32(out, uid))
}

// ---- pure helpers ------------------------------------------------------------

// Pure, and reachable only from the target-gated shell above — so on the host they
// exist for their tests and nothing else.

/// Strip leading and trailing whitespace.
#[cfg(any(target_os = "none", test))]
fn trim(s: &[u8]) -> &[u8] {
    let mut a = 0;
    let mut b = s.len();
    while a < b && is_space(s[a]) {
        a += 1;
    }
    while b > a && is_space(s[b - 1]) {
        b -= 1;
    }
    &s[a..b]
}

#[cfg(any(target_os = "none", test))]
fn is_space(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\r' || c == b'\n'
}

/// Write `v` as decimal into `out` (clamped to its length) and return the digit count.
/// Local because the flibc formatter is fd-bound: the prompt and the `whoami` fallback
/// need the digits in a buffer, not on a descriptor.
#[cfg(any(target_os = "none", test))]
fn fmt_u32(out: &mut [u8], v: u32) -> usize {
    let mut tmp = [0u8; 10];
    let mut n = 0;
    let mut x = v;
    if x == 0 {
        tmp[0] = b'0';
        n = 1;
    }
    while x > 0 {
        tmp[n] = b'0' + (x % 10) as u8;
        n += 1;
        x /= 10;
    }
    let mut i = 0;
    while i < n && i < out.len() {
        out[i] = tmp[n - 1 - i];
        i += 1;
    }
    i
}

#[cfg(test)]
mod tests {
    use super::{fmt_u32, trim};

    #[test]
    fn trim_strips_both_ends_and_leaves_the_interior_alone() {
        assert_eq!(trim(b"  cd /mnt \t\r\n"), b"cd /mnt");
        assert_eq!(trim(b"   "), b"");
        assert_eq!(trim(b""), b"");
        assert_eq!(trim(b"a b"), b"a b");
    }

    #[test]
    fn fmt_u32_writes_decimal_digits_most_significant_first() {
        let mut out = [0u8; 10];
        let n = fmt_u32(&mut out, 0);
        assert_eq!(&out[..n], b"0");
        let n = fmt_u32(&mut out, 1000);
        assert_eq!(&out[..n], b"1000");
        let n = fmt_u32(&mut out, u32::MAX);
        assert_eq!(&out[..n], b"4294967295");
    }

    #[test]
    fn fmt_u32_clamps_to_the_buffer_rather_than_overrunning_it() {
        // The uid fallback writes into the prompt's name buffer; a short one truncates.
        let mut out = [0u8; 2];
        let n = fmt_u32(&mut out, 4242);
        assert_eq!(&out[..n], b"42");
    }
}
