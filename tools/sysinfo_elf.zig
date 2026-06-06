// sysinfo — one-shot system summary for /bin/sysinfo.
//
// The first consumer of the console_ui screen-layer kv() renderer and a proof
// that FlashOS's full-screen navigation scaffold is wired end to end: a
// print-and-exit coreutil that lays the available system
// facts out as aligned key/value rows. It shows only what the kernel can answer
// today — the FlashOS version (build_options, single-sourced from build.zig.zon),
// the logged-in user (getuid -> /etc/passwd via the shared pwfile parser), and
// the free-page count (sys_dump_free). The live metrics the goal's
// hardware-monitoring milestone adds — CPU temperature / clock, uptime — slot in
// as extra kv rows once the mailbox / timer syscalls land; sysinfo never
// fabricates them.
//
// Print-and-exit, so it needs neither the alt-screen buffer nor readKey (those
// serve the future live /bin/mon). Like meminfo it is kept out of the CI
// FSH_SCRIPT: the free-page value is non-deterministic and would break the
// baseline checkpoint count. Same coreutil recipe as ls / dmesg (flibc _start
// shim, flibc_mem, single R+X PT_LOAD, stack buffers only — rule 1).

const flibc = @import("flibc");
const pwfile = @import("pwfile");
const console_ui = @import("console_ui");
const build_options = @import("build_options");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

const PASSWD_MAX: usize = 512;

fn sink(bytes: []const u8) void {
    _ = flibc.sys.write_fd(1, bytes.ptr, bytes.len);
}

export fn main(_: usize, _: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    console_ui.banner(sink, "FlashOS system");

    console_ui.screen.kv(sink, "version", build_options.version);

    // user: getuid -> /etc/passwd via pwfile; the passwd slurp buffer is on
    // this frame so the returned login-name slice stays valid for kv().
    var pw_buf: [PASSWD_MAX]u8 = undefined;
    console_ui.screen.kv(sink, "user", currentUser(&pw_buf));

    // free: the live kernel free-page count, formatted into a stack buffer.
    var num_buf: [32]u8 = undefined;
    console_ui.screen.kv(sink, "free", freePages(&num_buf));

    flibc.exit();
}

// Resolve the real uid's login name into a slice backed by `buf`. Returns "?"
// when the uid can't be read, /etc/passwd is unreadable, or the uid has no
// entry — the kv renderer wants a value and a numeric fallback would need a
// formatter the proof tool does not warrant.
fn currentUser(buf: []u8) []const u8 {
    const uid_raw = flibc.sys.getuid();
    if (uid_raw < 0) return "?";
    const uid: u32 = @intCast(uid_raw);

    const fd = flibc.sys.open("/etc/passwd");
    if (fd < 0) return "?";
    var n: usize = 0;
    while (n < buf.len) {
        const r = flibc.sys.read(fd, buf[n..].ptr, buf.len - n);
        if (r <= 0) break;
        n += @intCast(r);
    }
    _ = flibc.sys.close(fd);

    if (pwfile.lookupByUid(buf[0..n], uid)) |entry| return entry.user;
    return "?";
}

// "<count> pages", the count formatted decimal into `buf`.
fn freePages(buf: []u8) []const u8 {
    var i = u64dec(buf, flibc.sys.dump_free());
    const suffix = " pages";
    for (suffix) |c| {
        buf[i] = c;
        i += 1;
    }
    return buf[0..i];
}

// Write `v` as decimal ASCII into `out` (>= 20 bytes for the u64 max),
// returning the byte count.
fn u64dec(out: []u8, v: u64) usize {
    if (v == 0) {
        out[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x != 0) : (x /= 10) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = tmp[n - 1 - i];
    return n;
}
