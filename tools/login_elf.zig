// login — interactive credential gate + session supervisor.
//
// PID-1 execs /bin/login instead of the shell. login prompts for a
// username (echoed) and a password (echo suppressed via
// SYS_SET_CONSOLE_MODE), asks the kernel to verify the password against
// the active shadow database (sys_authenticate — the KDF lives in the
// kernel), looks the user up in /etc/passwd for the uid / gid / shell,
// and then runs the session as a CHILD process: the child drops
// privilege (setgid + setuid) and execs the shell; login itself stays
// root, waits, reaps, and prompts again. `exit` in the shell therefore
// returns to the `login:` prompt instead of ending the boot — the
// re-prompt lifecycle.
//
// The privilege drop MUST live in the child: setuid is one-way for a
// non-root process, so a login that dropped itself could never
// authenticate a second session. The parent staying root is what makes
// it a supervisor.
//
// argv[1] (optional) is a decimal session limit: login exits cleanly
// after that many completed sessions. The [TEST] auth scenario drives a
// full login→shell→exit→login cycle through this real binary with limit
// "2" and then reaps it for the free-page baseline check. No argv (the
// real boot) means loop forever. A non-numeric argv[1] is ignored.
//
// Under the CI boot watchdog PID-1 console-injects the test credentials
// so this real path authenticates unattended; on hardware the user types
// them. Same coreutil recipe as dmesg / ls (flibc _start shim, single
// PT_LOAD, no heap allocator — only fixed stack buffers).

const flibc = @import("flibc");
const defs = @import("syscall_defs");
const pwfile = @import("pwfile");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

const PASSWD_PATH: [*:0]const u8 = "/etc/passwd";

// Boot status prefix — mirrors src/kernel.zig's OK. The line emitted with it
// below is a boot-contract marker the watchdog counts; if you change this
// prefix, update the run_qemu_test.sh grep too.
const OK = "[ OK ] ";

fn emit(s: []const u8) void {
    _ = flibc.sys.write_fd(1, s.ptr, s.len);
}

// Read one line from fd 0 (raw, one byte at a time) into `buf`, stopping at
// CR / LF or EOF. Returns the byte count, excluding the terminator. Echo of
// the typed bytes is the kernel's job (the console echo flag), so this loop
// never echoes itself.
fn readLine(buf: []u8) usize {
    var n: usize = 0;
    while (n < buf.len) {
        var ch: [1]u8 = undefined;
        const r = flibc.sys.read(0, &ch, 1);
        if (r <= 0) break;
        if (ch[0] == '\n' or ch[0] == '\r') break;
        buf[n] = ch[0];
        n += 1;
    }
    return n;
}

fn strLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

fn parseU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 0xFFFF_FFFF) return null;
    }
    return @intCast(v);
}

// One authenticated session: fork; the child drops privilege and execs
// the user's shell; the parent waits for it to exit (logout). Returns
// true when a session actually ran (a fork/exec failure returns false so
// the caller does not count it against the session limit).
fn runSession(uid: u32, gid: u32, shell_z: [*:0]const u8) bool {
    const pid = flibc.fork();
    if (pid == 0) {
        // Child: drop privilege — gid first (while still root), then uid —
        // and become the shell. Credentials are inherited by everything
        // the shell forks.
        if (flibc.sys.setgid(gid) != 0 or flibc.sys.setuid(uid) != 0) {
            emit("login: cannot drop privilege\n");
            flibc.exit();
        }
        const sh_argv = [_:null]?[*:0]const u8{shell_z};
        _ = flibc.sys.exec_path(shell_z, &sh_argv);
        // exec_path only returns on failure; the child must die, not loop.
        emit("login: exec failed\n");
        flibc.exit();
    }
    if (pid < 0) {
        emit("login: fork failed\n");
        return false;
    }
    // Parent (still root): the wait returning is the logout event.
    _ = flibc.wait();
    return true;
}

export fn main(argc: usize, argv: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    var user_buf: [64]u8 = undefined;
    var pass_buf: [128]u8 = undefined;
    var pw_buf: [512]u8 = undefined;
    var shell_buf: [64]u8 = undefined;

    // Optional session limit (argv[1], decimal). 0 = loop forever.
    var max_sessions: u32 = 0;
    if (argc >= 2) {
        if (argv[1]) |arg| {
            if (parseU32(arg[0..strLen(arg)])) |n| max_sessions = n;
        }
    }
    var sessions_done: u32 = 0;

    // Blank line before the first `login:` prompt, separating it from the
    // kernel's last boot status line (or the -Dboot-selftest tally).
    emit("\n");

    while (true) {
        // Username — kernel echo on so the user sees what they type.
        _ = flibc.sys.set_console_mode(defs.CONSOLE_MODE_ECHO);
        emit("login: ");
        const ulen = readLine(&user_buf);
        emit("\n");

        // A bare Enter / empty username re-prompts silently, getty-style:
        // no password challenge, no "Login incorrect". This also absorbs a
        // stray newline left in the console RX at boot (e.g. a residual byte
        // from the [TEST] login scenario's scripted sessions), so the first
        // real prompt is a clean `login:` instead of a phantom failed attempt.
        if (ulen == 0) continue;

        // Password — kernel echo off.
        _ = flibc.sys.set_console_mode(0);
        emit("Password: ");
        const plen = readLine(&pass_buf);
        emit("\n");

        if (flibc.sys.authenticate(&user_buf, ulen, &pass_buf, plen) != 0) {
            emit("Login incorrect\n");
            continue;
        }

        // Pull uid / gid / shell from /etc/passwd (fresh read per session).
        const fd = flibc.sys.open(PASSWD_PATH);
        if (fd < 0) {
            emit("login: /etc/passwd missing\n");
            continue;
        }
        var pn: usize = 0;
        while (pn < pw_buf.len) {
            const r = flibc.sys.read(fd, pw_buf[pn..].ptr, pw_buf.len - pn);
            if (r <= 0) break;
            pn += @intCast(r);
        }
        _ = flibc.sys.close(fd);

        const entry = pwfile.lookupByName(pw_buf[0..pn], user_buf[0..ulen]) orelse {
            emit("login: no passwd entry\n");
            continue;
        };

        // Copy + NUL-terminate the shell path for execve.
        if (entry.shell.len == 0 or entry.shell.len >= shell_buf.len) {
            emit("login: bad shell\n");
            continue;
        }
        var si: usize = 0;
        while (si < entry.shell.len) : (si += 1) shell_buf[si] = entry.shell[si];
        shell_buf[si] = 0;
        const shell_z: [*:0]const u8 = @ptrCast(&shell_buf);

        // Boot marker proving the auth path ran — once per session.
        emit("\n" ++ OK ++ "Authenticated\n");

        if (!runSession(entry.uid, entry.gid, shell_z)) continue;

        // Logout: the session child has been reaped. Honour the session
        // limit (the [TEST] auth hook), then fall through to re-prompt.
        sessions_done += 1;
        if (max_sessions != 0 and sessions_done >= max_sessions) {
            flibc.exit();
        }
    }
}
