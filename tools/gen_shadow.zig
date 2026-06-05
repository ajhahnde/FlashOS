const std = @import("std");
const Io = std.Io;
const sha256 = @import("sha256");

// gen_shadow: build-time /etc/shadow generator.
//
// Host tool (runs on the build machine, not the target). Emits a
// deterministic /etc/shadow by running the SAME PBKDF2-HMAC-SHA256 the
// kernel verifies with (src/sha256.zig) over fixed, in-repo test
// credentials. Reusing the kernel's KDF guarantees the baked verifier
// matches what sys_authenticate recomputes at login — eliminating the
// stable-but-wrong-hash failure src/sha256.zig's header warns about.
//
// The salts are fixed, public 16-byte literals and the iteration count is
// modest (4096, well below modern OWASP guidance for PBKDF2-HMAC-SHA256):
// this is a hobby-OS demonstration of the auth flow, not a
// production secret store (documented as such). Random per-user salts
// arrive with a future `passwd` command drawing from the kernel hwrng.
// Output is a pure function of the constants below, so two clean builds
// are byte-identical — required for the Pi kernel-image hash baseline.
//
// build.zig invokes `gen_shadow <out_path>` (addOutputFileArg) and stages
// the result into the initramfs at /etc/shadow. Keep `accounts` in lockstep
// with user_space/etc/passwd, the PID-1 boot-injection creds in
// user_space/init_main.zig, and the [TEST] authenticate scenario.

const Account = struct {
    user: []const u8,
    password: []const u8,
    salt: []const u8, // 16 fixed, public bytes
    iterations: u32,
};

const accounts = [_]Account{
    .{ .user = "root", .password = "root", .salt = "FlashOS-rootSalt", .iterations = 4096 },
    .{ .user = "flash", .password = "flash", .salt = "FlashOS-userSalt", .iterations = 4096 },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) std.debug.panic("usage: gen_shadow <output.shadow>\n", .{});
    const out_path = args[1];

    var out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);

    var out_buf: [4096]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const w = &out_writer.interface;

    for (accounts) |acc| {
        var dk: [32]u8 = undefined;
        sha256.pbkdf2HmacSha256(acc.password, acc.salt, acc.iterations, dk[0..]);
        try w.writeAll(acc.user);
        try w.writeAll(":");
        try writeDecimal(w, acc.iterations);
        try w.writeAll(":");
        try writeHex(w, acc.salt);
        try w.writeAll(":");
        try writeHex(w, dk[0..]);
        try w.writeAll("\n");
    }

    try w.flush();
}

fn writeHex(w: *Io.Writer, bytes: []const u8) !void {
    const digits = "0123456789abcdef";
    var pair: [2]u8 = undefined;
    for (bytes) |b| {
        pair[0] = digits[b >> 4];
        pair[1] = digits[b & 0x0F];
        try w.writeAll(pair[0..]);
    }
}

fn writeDecimal(w: *Io.Writer, value: u32) !void {
    if (value == 0) {
        try w.writeAll("0");
        return;
    }
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        tmp[n] = '0' + @as(u8, @intCast(v % 10));
        n += 1;
    }
    var rev: [10]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) rev[i] = tmp[n - 1 - i];
    try w.writeAll(rev[0..n]);
}
