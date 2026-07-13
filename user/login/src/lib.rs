//! `/bin/login` -- interactive credential gate + session supervisor.
//!
//! PID 1 execs login instead of the shell. login prompts for a username (echoed) and
//! a password (masked with `*`), asks the kernel to verify it against the active
//! shadow database (the KDF lives in the kernel), looks the account up in
//! `/etc/passwd` for its uid / gid / shell, and then runs the session as a CHILD
//! process: the child drops privilege (setgid, then setuid) and execs the shell;
//! login itself stays root, waits, reaps, and prompts again. `exit` in the shell
//! therefore returns to the `login:` prompt instead of ending the boot.
//!
//! The privilege drop MUST live in the child: setuid is one-way for a non-root
//! process, so a login that dropped itself could never authenticate a second session.
//! The parent staying root is what makes it a supervisor.
//!
//! `argv[1]` (optional) is a decimal session limit: login exits cleanly after that
//! many completed sessions. The `[TEST]` auth scenario drives a full
//! login->shell->exit->login cycle through this real binary with limit `2` and then
//! reaps it for the free-page baseline check. No argv (the real boot) means loop
//! forever; a non-numeric `argv[1]` is ignored.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::{
    console_sink, fork,
    readline::{self, Action, Outcome, State},
    sys, wait,
};
#[cfg(target_os = "none")]
use flashos_user_rt::{arg, entry, Argv};

#[cfg(target_os = "none")]
const PASSWD_PATH: &[u8] = b"/etc/passwd\0";

/// Largest `/etc/passwd` login reads: the seed database is two lines, and the file is
/// build-time-immutable, so a fixed frame buffer needs no growth path.
#[cfg(target_os = "none")]
const PASSWD_MAX: usize = 512;

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    let mut user_buf = [0u8; 64];
    let mut pass_buf = [0u8; 128];
    let mut pw_buf = [0u8; PASSWD_MAX];
    let mut shell_buf = [0u8; 64];

    // login mints a session by dropping privilege from root, and setuid is one-way --
    // so a login that is not already root can only ever re-grant the euid it
    // inherited. Run as a normal command from a privilege-dropped shell it would
    // still authenticate (the kernel verifier does not gate on the caller's uid) and
    // only then fail the drop with a misleading "cannot drop privilege". Refuse up
    // front: minting sessions is the PID-1 supervisor's job, reached as root via
    // initramfs exec. The proper user-switch is `logout` back to that supervisor,
    // then log in as the other account.
    if sys::geteuid() != 0 {
        console_sink(b"login: must be root\n");
        return 0;
    }

    // Optional session limit (argv[1], decimal). 0 = loop forever.
    let mut max_sessions: u32 = 0;
    if argc >= 2 {
        if let Some(a) = unsafe { arg(argv, 1) } {
            if let Some(n) = parse_u32(a) {
                max_sessions = n;
            }
        }
    }
    let mut sessions_done: u32 = 0;

    // Blank line before the first `login:` prompt, separating it from the kernel's
    // last boot status line (or the boot-selftest tally).
    console_sink(b"\n");

    loop {
        // Username -- echo off so login owns the echo through flibc's line editor: it
        // echoes each byte and rubs out a backspace, so a typo is correctable. The
        // kernel's raw echo could not erase a mistake, which made a single slip
        // uncorrectable.
        sys::set_console_mode(0);
        console_sink(b"login: ");
        let ulen = match readline::readline(&mut user_buf) {
            Outcome::Line(l) => l.len(),
            Outcome::Eof | Outcome::Abandoned => 0,
        };
        console_sink(b"\n");

        // A bare Enter / empty username re-prompts silently, getty-style: no password
        // challenge, no "Login incorrect". This also absorbs a stray newline left in
        // the console RX at boot, so the first real prompt is a clean `login:` instead
        // of a phantom failed attempt.
        if ulen == 0 {
            continue;
        }

        // Password -- still echo off; read_masked owns the echo, printing one `*` per
        // accepted byte and rubbing it out on backspace, so the secret stays hidden on
        // the serial console yet a typo is correctable. The console stays echo-off
        // straight into the shell, where fsh's own readline owns the echo.
        console_sink(b"Password: ");
        let plen = read_masked(&mut pass_buf);
        console_sink(b"\n");

        let verdict =
            unsafe { sys::authenticate(user_buf.as_ptr(), ulen, pass_buf.as_ptr(), plen) };
        if verdict != 0 {
            console_sink(b"Login incorrect\n");
            continue;
        }

        // uid / gid / shell from /etc/passwd, read fresh per session.
        let Some(pn) = slurp_passwd(&mut pw_buf) else {
            console_sink(b"login: /etc/passwd missing\n");
            continue;
        };
        let Some(entry) = flashos_pwfile::lookup_by_name(&pw_buf[..pn], &user_buf[..ulen]) else {
            console_sink(b"login: no passwd entry\n");
            continue;
        };
        let (uid, gid) = (entry.uid, entry.gid);

        // Copy + NUL-terminate the shell path for execve.
        if entry.shell.is_empty() || entry.shell.len() >= shell_buf.len() {
            console_sink(b"login: bad shell\n");
            continue;
        }
        shell_buf[..entry.shell.len()].copy_from_slice(entry.shell);
        shell_buf[entry.shell.len()] = 0;

        // Blank line separating the password prompt from the shell's homescreen, which
        // the session child execs into next.
        console_sink(b"\n");

        if !run_session(uid, gid, shell_buf.as_ptr()) {
            continue;
        }

        // Logout: the session child has been reaped. Honour the session limit (the
        // `[TEST]` auth hook), then fall through to re-prompt.
        sessions_done += 1;
        if max_sessions != 0 && sessions_done >= max_sessions {
            return 0;
        }
    }
}

/// One authenticated session: fork; the child drops privilege and execs the user's
/// shell; the parent waits for it to exit (logout). Returns `true` when a session
/// actually ran -- a fork/exec failure returns `false`, so the caller does not count
/// it against the session limit.
///
/// # Safety
///
/// `shell_z` must point at a NUL-terminated path.
#[cfg(target_os = "none")]
fn run_session(uid: u32, gid: u32, shell_z: *const u8) -> bool {
    let pid = fork();
    if pid == 0 {
        // Child: drop privilege -- gid first, while still root, then uid -- and become
        // the shell. Credentials are inherited by everything the shell forks.
        if sys::setgid(gid) != 0 || sys::setuid(uid) != 0 {
            console_sink(b"login: cannot drop privilege\n");
            sys::exit(0);
        }
        let sh_argv: [*const u8; 2] = [shell_z, core::ptr::null()];
        unsafe { sys::exec_path(shell_z, sh_argv.as_ptr()) };
        // exec_path only returns on failure; the child must die, not loop.
        console_sink(b"login: exec failed\n");
        sys::exit(0);
    }
    if pid < 0 {
        console_sink(b"login: fork failed\n");
        return false;
    }
    // Parent (still root): the wait returning is the logout event.
    wait();
    true
}

/// Slurp `/etc/passwd` into `buf` and return the byte count, or `None` when the file
/// cannot be opened. A short read ends the slurp: the file is smaller than the buffer.
#[cfg(target_os = "none")]
fn slurp_passwd(buf: &mut [u8]) -> Option<usize> {
    let fd = unsafe { sys::open(PASSWD_PATH.as_ptr()) };
    if fd < 0 {
        return None;
    }
    let mut n = 0usize;
    while n < buf.len() {
        let r = sys::read(fd, &mut buf[n..]);
        if r <= 0 {
            break;
        }
        n += r as usize;
    }
    sys::close(fd);
    Some(n)
}

/// Read a masked secret from fd 0 into `buf`. Drives flibc's pure, host-tested line
/// editor so backspace actually pops a byte, but echoes one `*` per accepted byte and
/// the rubout on backspace instead of the byte itself -- the secret never reaches the
/// serial console. Submits on CR / LF, stops on EOF, drops the line on ^C. Returns the
/// byte count, excluding the terminator. The caller leaves the console echo-off, so
/// this loop is the only echo (no kernel double-echo).
#[cfg(target_os = "none")]
fn read_masked(buf: &mut [u8]) -> usize {
    let mut state = State::new(buf);
    loop {
        let Some(byte) = flashos_flibc::console_input() else {
            break;
        };
        match readline::step(&mut state, byte) {
            Action::Echo(_) => console_sink(b"*"),
            Action::Backspace => console_sink(b"\x08 \x08"),
            Action::Submit | Action::Eof => break,
            Action::Abandon => {
                state.replace_line(b"");
                break;
            }
            Action::None | Action::Complete => {}
        }
    }
    state.len()
}

/// Exact decimal `u32` parse -- no sign, no whitespace, no overflow.
#[cfg(target_os = "none")]
fn parse_u32(s: &[u8]) -> Option<u32> {
    if s.is_empty() {
        return None;
    }
    let mut v: u64 = 0;
    for &c in s {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v * 10 + u64::from(c - b'0');
        if v > u64::from(u32::MAX) {
            return None;
        }
    }
    Some(v as u32)
}

#[cfg(target_os = "none")]
entry!(main);
