// fsh — the FlashOS shell. A line-at-a-time REPL over the unified fd
// ABI: read a line with flibc.readline (fd 0), tokenize it (one
// optional `|`), dispatch built-ins in-process, and fork + execvp
// external commands. Exactly one pipe stage is supported; richer
// parsing (redirection, multi-stage pipelines, quoting, globbing,
// `$VAR`, history) is the "fsh v2" bucket (future work).
//
// Entry is the flibc _start argc/argv shim (pulled in by the comptime
// import below); `main` ignores argv. All buffers are function-local
// (stack) or string literals — rule 1: no allocator, no module-level
// mutable state. Module-level `var` would land in .bss, which the
// single R+X PT_LOAD (tools/fsh_linker.ld) cannot write; keeping the
// line / argv / scratch / fshrc buffers on the 64 KiB user stack both
// honours the no-heap rule and keeps the ELF a single segment.
//
// The pure tokenizer lives in tokenize.zig and is host-tested in
// isolation; this file is the SVC-driving shell loop, exercised end to
// end by the PID-1 hand-off: init execs /bin/fsh after the harness, and
// the boot watchdog treats the homescreen line fsh prints at REPL entry
// (the stable `type 'help' for commands` tail) as the boot success signal
// (reaching the prompt = pass).

const flibc = @import("flibc");
const tok = @import("tokenize.zig");
const pwfile = @import("pwfile");
const console_ui = @import("console_ui");
const build_options = @import("build_options");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

const LINE_MAX: usize = 256; // readline buffer (one input line)
const TOK_BUF: usize = 256; // tokenizer scratch (NUL-joined argv bytes)
const FSHRC_MAX: usize = 512; // /etc/fshrc slurp buffer
const PASSWD_MAX: usize = 512; // /etc/passwd slurp buffer (whoami)
// Command-history depth. The ring's slots live on the REPL's stack frame
// (rule 1 — no allocator / no .bss); 16 × HistSlot ≈ 4.2 KiB, comfortable on
// the 64 KiB user stack. Bumping this only costs stack.
const HIST_N: usize = 16;

// Unix-style privilege prompt: `# ` for root (euid 0), `$ ` for
// everyone else. Selected per REPL iteration via geteuid so a future
// in-shell privilege change is reflected immediately.
const PROMPT_ROOT = "# ";
const PROMPT_USER = "$ ";
// Homescreen banner, emitted once when fsh reaches its interactive REPL —
// rendered by console_ui.homescreen() (see repl()), fed the project version
// from build.zig.zon via build_options, so no version literal lives here. It
// doubles as the boot-success marker: the QEMU watchdog (run_qemu_test.sh) and
// the picapture helper grep the stable "type 'help' for commands" tail
// (version-independent) as the pass signal — reaching the interactive prompt
// is a pass.
const AUTHOR = "ajhahnde";
const HELP_TEXT =
    "fsh built-ins: cd [dir]  exit/logout  help  free  whoami  reboot\n" ++
    "external: <cmd> [args]   one pipe: <cmd> | <cmd>\n" ++
    "TAB completes commands + paths\n";

// Built-in command names, offered alongside /bin for first-token TAB
// completion (these dispatch in-process, so they are not in /bin).
const BUILTINS = [_][]const u8{ "cd", "exit", "logout", "help", "free", "whoami", "reboot" };

export fn main(argc: usize, argv: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    _ = argc;
    _ = argv;
    runFshrc();
    repl();
    flibc.exit();
}

// ---- I/O helpers (unified fd ABI) ----

fn emit(fd: i32, s: []const u8) void {
    _ = flibc.sys.write_fd(fd, s.ptr, s.len);
}

// console_ui Sink bound to stdout (fd 1), so the shared renderers reach the
// shell's console.
fn consoleSink(bytes: []const u8) void {
    emit(1, bytes);
}

// ---- startup file ----

// Read /etc/fshrc once and run each non-comment, non-blank line through
// the same dispatcher the REPL uses. Silently skips when the file is
// absent (open < 0) — the rc file is optional. Kept free of `free` /
// meminfo so it adds no sys_dump_free checkpoint (the CI baseline count
// must stay deterministic).
fn runFshrc() void {
    const fd = flibc.sys.open("/etc/fshrc");
    if (fd < 0) return;
    var buf: [FSHRC_MAX]u8 = undefined;
    const n = flibc.sys.read(fd, &buf, buf.len);
    _ = flibc.sys.close(fd);
    if (n <= 0) return;

    const content = buf[0..@intCast(n)];
    var start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n') {
            const line = trim(content[start..i]);
            if (line.len != 0 and line[0] != '#') dispatch(line);
            start = i + 1;
        }
    }
}

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and isSpace(s[a])) : (a += 1) {}
    while (b > a and isSpace(s[b - 1])) : (b -= 1) {}
    return s[a..b];
}

inline fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

// ---- REPL ----

fn repl() void {
    var line_buf: [LINE_MAX]u8 = undefined;
    // Caller-owned history ring (rule 1). Slots are written by readlineEdit
    // before they are read back, so `undefined` backing is valid here.
    var hist_slots: [HIST_N]flibc.HistSlot = undefined;
    var hist = flibc.History.init(&hist_slots);
    console_ui.homescreen(consoleSink, build_options.version, AUTHOR);
    while (true) {
        const prompt = if (flibc.sys.geteuid() == 0) PROMPT_ROOT else PROMPT_USER;
        emit(1, prompt);
        // Hand readline the live prompt so its double-TAB candidate listing can
        // reprint `prompt` + line after the list. align(16): the >16-byte
        // Completion is materialised on this frame and LLVM may SLP-store its
        // adjacent slice fields with a `str q` (16-byte NEON) that faults on an
        // 8-aligned slot under SCTLR_EL1.A — the strict-align vectorisation trap.
        const comp: flibc.Completion align(16) = .{ .builtins = &BUILTINS, .prompt = prompt };
        switch (flibc.readlineEdit(&line_buf, comp, &hist)) {
            .eof => return, // ^D on an empty line / stream closed → logout
            .abandoned => emit(1, "\n"), // ^C: readline drew nothing, fsh ends the line
            .line => |l| {
                emit(1, "\n"); // readline submits without echoing the CR
                dispatch(l);
                // A full-screen child (a future TUI tool) may have left the
                // kernel console in raw / masked / alt mode; reset it so the
                // next prompt + readline behave.
                _ = flibc.sys.set_console_mode(0);
                // Blank line after a real command's output, before the next
                // prompt; skipped on a bare Enter so empty lines don't double up.
                if (trim(l).len != 0) emit(1, "\n");
            },
        }
    }
}

// ---- dispatch ----

fn dispatch(line: []const u8) void {
    var argv: [tok.MAX_ARGS]?[*:0]u8 = undefined;
    var buf: [TOK_BUF]u8 = undefined;
    switch (tok.tokenize(line, &argv, &buf)) {
        .empty => {},
        .err => |e| switch (e) {
            .too_many_pipes => emit(2, "fsh: only one pipe supported\n"),
            .empty_side => emit(2, "fsh: missing command around |\n"),
        },
        .single => |n| runSingle(&argv, n),
        .piped => |p| runPiped(&argv, p),
    }
}

fn runSingle(argv: *[tok.MAX_ARGS]?[*:0]u8, argc: usize) void {
    const name = argv[0] orelse return;
    if (runBuiltin(name, argv, argc)) return;

    const pid = flibc.fork();
    if (pid == 0) {
        _ = flibc.execvp(name, @ptrCast(argv));
        emit(2, "fsh: command not found\n"); // execvp only returns on failure
        flibc.exit();
    } else if (pid > 0) {
        _ = flibc.wait();
    } else {
        emit(2, "fsh: fork failed\n");
    }
}

// One pipe stage. argv holds both vectors back to back, separated by the
// `null` the tokenizer wrote at the boundary: left = argv[0..], right =
// argv[left_argc + 1 ..]. Wire wfd→stdout in the left child, rfd→stdin
// in the right child, close both ends everywhere, and reap both.
fn runPiped(argv: *[tok.MAX_ARGS]?[*:0]u8, p: tok.Piped) void {
    const left: [*]const ?[*:0]const u8 = @ptrCast(argv);
    const right: [*]const ?[*:0]const u8 = @ptrCast(&argv[p.left_argc + 1]);

    const pipe_packed = flibc.sys.pipe();
    if (pipe_packed < 0) {
        emit(2, "fsh: pipe failed\n");
        return;
    }
    const up: u64 = @bitCast(pipe_packed);
    const rfd: i32 = @intCast(up & 0xffffffff);
    const wfd: i32 = @intCast(up >> 32);

    const lpid = flibc.fork();
    if (lpid == 0) {
        _ = flibc.sys.dup2(wfd, 1);
        _ = flibc.sys.close(rfd);
        _ = flibc.sys.close(wfd);
        _ = flibc.execvp(left[0].?, left);
        flibc.exit();
    }
    if (lpid < 0) {
        // No child exists yet: close both ends, do not reap.
        emit(2, "fsh: fork failed\n");
        _ = flibc.sys.close(rfd);
        _ = flibc.sys.close(wfd);
        return;
    }
    const rpid = flibc.fork();
    if (rpid == 0) {
        _ = flibc.sys.dup2(rfd, 0);
        _ = flibc.sys.close(rfd);
        _ = flibc.sys.close(wfd);
        _ = flibc.execvp(right[0].?, right);
        flibc.exit();
    }
    if (rpid < 0) {
        // Left child is already running: close both ends, reap it once.
        emit(2, "fsh: fork failed\n");
        _ = flibc.sys.close(rfd);
        _ = flibc.sys.close(wfd);
        _ = flibc.wait();
        return;
    }
    // Shell holds neither end open, else the right child never sees EOF.
    _ = flibc.sys.close(rfd);
    _ = flibc.sys.close(wfd);
    // Both pids are > 0 here, so reap both children unconditionally.
    _ = flibc.wait();
    _ = flibc.wait();
}

// ---- built-ins (in-process, no fork) ----

fn runBuiltin(name: [*:0]const u8, argv: *[tok.MAX_ARGS]?[*:0]u8, argc: usize) bool {
    if (streq(name, "exit") or streq(name, "logout")) flibc.exit();
    if (streq(name, "reboot")) flibc.sys.reboot();
    if (streq(name, "help")) {
        emit(1, HELP_TEXT);
        listBin();
        return true;
    }
    if (streq(name, "cd")) {
        const target: [*:0]const u8 = if (argc >= 2) argv[1].? else "/";
        if (flibc.chdir(target) < 0) emit(2, "cd: cannot change directory\n");
        return true;
    }
    if (streq(name, "free")) {
        flibc.printf("free pages: %u\n", .{flibc.sys.dump_free()});
        return true;
    }
    if (streq(name, "whoami")) {
        whoami();
        return true;
    }
    return false;
}

// List /bin so `help` advertises the external commands without a hardcoded
// catalog — a new tool shows up by existing (and TAB completes it too). The
// Dirent lives on the stack (rule 1); a missing /bin simply lists nothing.
fn listBin() void {
    emit(1, "in /bin:");
    var d: flibc.Dirent = .{};
    var i: u64 = 0;
    while (flibc.sys.readdir("/bin", i, &d) == 0) : (i += 1) {
        var n: usize = 0;
        while (n < d.name.len and d.name[n] != 0) : (n += 1) {}
        emit(1, " ");
        emit(1, d.name[0..n]);
    }
    emit(1, "\n");
}

// Print the login name matching the real uid, resolved against
// /etc/passwd through the shared pwfile parser (the same module the
// kernel and /bin/login use). Falls back to the numeric uid when the
// file is unreadable or the uid has no entry — a dropped uid without an
// account is still identifiable. Stack buffer only (rule 1).
fn whoami() void {
    const uid_raw = flibc.sys.getuid();
    if (uid_raw < 0) {
        emit(2, "whoami: cannot read uid\n");
        return;
    }
    const uid: u32 = @intCast(uid_raw);

    const fd = flibc.sys.open("/etc/passwd");
    if (fd >= 0) {
        var buf: [PASSWD_MAX]u8 = undefined;
        var n: usize = 0;
        while (n < buf.len) {
            const r = flibc.sys.read(fd, buf[n..].ptr, buf.len - n);
            if (r <= 0) break;
            n += @intCast(r);
        }
        _ = flibc.sys.close(fd);
        if (pwfile.lookupByUid(buf[0..n], uid)) |entry| {
            emit(1, entry.user);
            emit(1, "\n");
            return;
        }
    }
    flibc.printf("%u\n", .{@as(u64, uid)});
}

fn streq(a: [*:0]const u8, b: []const u8) bool {
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return a[b.len] == 0;
}
