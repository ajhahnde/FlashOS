// passwd — interactive password change.
//
// With no argument it changes the calling user's own password (uid →
// login name via /etc/passwd); with an argument (`passwd <user>`) it
// targets that record — which only root may do for records other than
// its own (sys_passwd enforces this, the tool just passes it through).
// Prompts follow the Unix shape: the current password is skipped when
// the caller is root (root resets without proof), the new password is
// asked twice and must match. All password prompts run with kernel echo
// off.
//
// The KDF and the splice-safe shadow rewrite live in the kernel
// (sys_passwd, slot 46) — this tool only collects strings and reports
// the verdict. Without a writable FAT32 shadow (/mnt/shadow — absent on
// QEMU virt and on a freshly formatted card) the kernel answers -1 and
// the tool says so.
//
// Same coreutil recipe as login / dmesg (flibc _start shim, single
// PT_LOAD, no heap allocator — only fixed stack buffers).

const flibc = @import("flibc");
const defs = @import("syscall_defs");
const pwfile = @import("pwfile");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

const PASSWD_PATH: [*:0]const u8 = "/etc/passwd";

fn emit(s: []const u8) void {
    _ = flibc.sys.write_fd(1, s.ptr, s.len);
}

fn emitErr(s: []const u8) void {
    _ = flibc.sys.write_fd(2, s.ptr, s.len);
}

// Read one line from fd 0 (raw, one byte at a time) into `buf`, stopping
// at CR / LF or EOF. Returns the byte count, excluding the terminator.
// Echo of typed bytes is the kernel's job (the console echo flag) — this
// loop never echoes, which is exactly right for password input.
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

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

export fn main(argc: usize, argv: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    var user_buf: [64]u8 = undefined;
    var old_buf: [128]u8 = undefined;
    var new_buf: [128]u8 = undefined;
    var retype_buf: [128]u8 = undefined;
    var pw_buf: [512]u8 = undefined;

    const is_root = flibc.sys.geteuid() == 0;

    // Resolve the target user: argv[1], or the caller's own login name.
    var user_len: usize = 0;
    if (argc >= 2) {
        const arg = argv[1].?;
        const alen = strLen(arg);
        if (alen == 0 or alen > user_buf.len) {
            emitErr("passwd: bad user name\n");
            flibc.exit();
        }
        var i: usize = 0;
        while (i < alen) : (i += 1) user_buf[i] = arg[i];
        user_len = alen;
    } else {
        const uid_raw = flibc.sys.getuid();
        if (uid_raw < 0) {
            emitErr("passwd: cannot read uid\n");
            flibc.exit();
        }
        const fd = flibc.sys.open(PASSWD_PATH);
        if (fd < 0) {
            emitErr("passwd: cannot open /etc/passwd\n");
            flibc.exit();
        }
        var pn: usize = 0;
        while (pn < pw_buf.len) {
            const r = flibc.sys.read(fd, pw_buf[pn..].ptr, pw_buf.len - pn);
            if (r <= 0) break;
            pn += @intCast(r);
        }
        _ = flibc.sys.close(fd);
        const entry = pwfile.lookupByUid(pw_buf[0..pn], @intCast(uid_raw)) orelse {
            emitErr("passwd: no passwd entry for this uid\n");
            flibc.exit();
        };
        if (entry.user.len > user_buf.len) {
            emitErr("passwd: bad user name\n");
            flibc.exit();
        }
        var i: usize = 0;
        while (i < entry.user.len) : (i += 1) user_buf[i] = entry.user[i];
        user_len = entry.user.len;
    }

    emit("Changing password for ");
    emit(user_buf[0..user_len]);
    emit("\n");

    // Current password — skipped for root (sys_passwd does not require
    // it from euid 0; that is the forgotten-password recovery path).
    var old_len: usize = 0;
    if (!is_root) {
        _ = flibc.sys.set_console_mode(0);
        emit("Current password: ");
        old_len = readLine(&old_buf);
        emit("\n");
    }

    // New password, asked twice, echo off.
    _ = flibc.sys.set_console_mode(0);
    emit("New password: ");
    const new_len = readLine(&new_buf);
    emit("\n");
    emit("Retype new password: ");
    const retype_len = readLine(&retype_buf);
    emit("\n");

    if (new_len == 0) {
        emitErr("passwd: empty password not allowed\n");
        flibc.exit();
    }
    if (!bytesEqual(new_buf[0..new_len], retype_buf[0..retype_len])) {
        emitErr("passwd: passwords do not match\n");
        flibc.exit();
    }

    const ret = flibc.sys.passwd(&user_buf, user_len, &old_buf, old_len, &new_buf, new_len);
    if (ret == 0) {
        emit("passwd: password updated\n");
    } else if (ret == -defs.EACCES) {
        emitErr("passwd: authentication failure\n");
    } else {
        emitErr("passwd: cannot write shadow (read-only or missing)\n");
    }
    flibc.exit();
}
