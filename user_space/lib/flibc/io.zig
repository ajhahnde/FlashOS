// Console I/O layer of flibc — `puts` and a comptime-format `printf`
// on top of sys_writeConsole. The kernel exposes writeConsole as a
// null-terminated-string syscall (src/sys.zig:sys_writeConsole reads
// until '\0'), so `printf` builds its formatted output into a
// stack-resident 256-byte buffer, terminates with '\0', then makes a
// single syscall. Output longer than 255 bytes is silently truncated;
// the demo programs ship are well below that bound.
//
// Format spec is a deliberate subset of C printf:
//   %%       — literal '%'
//   %s       — null-terminated string ([*:0]const u8)
//   %d / %i  — signed decimal (any int that fits in i64)
//   %u       — unsigned decimal (any int that fits in u64)
//   %x       — lowercase hex (any int that fits in u64)
//   %c       — single byte
// Width / precision / padding are not supported — this is demoware-
// grade by design; richer formatting belongs to future fsh /
// coreutils work once a real userland exercises it.

const sys = @import("syscalls.zig");

const BUF_LEN: usize = 256;

/// puts — write a null-terminated string followed by a newline. Mirrors
/// the C library shape (line-buffered, sentinel-terminated input)
/// without the explicit '\n' append complication of sys.write.
pub fn puts(s: [*:0]const u8) void {
    sys.write(s);
    sys.write("\n");
}

/// write — write a null-terminated string verbatim, no trailing
/// newline. Sugar over sys.write so demo programs can stay one
/// `@import("flibc")` deep without dipping into the raw syscall layer.
pub fn write(s: [*:0]const u8) void {
    sys.write(s);
}

/// printf(fmt, .{args...}) — format and emit. The format string is
/// walked at comptime so the dispatch on each spec resolves to a
/// straight call into the matching `buf_put_*` helper at codegen time;
/// no runtime parser, no jump table.
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [BUF_LEN]u8 = undefined;
    var pos: usize = 0;

    @setEvalBranchQuota(8 * fmt.len + 1000);
    comptime var i: usize = 0;
    comptime var arg_idx: usize = 0;
    inline while (i < fmt.len) {
        const c = fmt[i];
        if (c == '%' and i + 1 < fmt.len) {
            const spec = fmt[i + 1];
            if (spec == '%') {
                buf_put_byte(&buf, &pos, '%');
            } else {
                emit_spec(&buf, &pos, spec, args[arg_idx]);
                arg_idx += 1;
            }
            i += 2;
        } else {
            buf_put_byte(&buf, &pos, c);
            i += 1;
        }
    }

    const term = if (pos < BUF_LEN) pos else BUF_LEN - 1;
    buf[term] = 0;
    sys.write(@ptrCast(&buf));
}

// Dispatch a single arg-consuming spec. Inline so each call site is
// resolved at the printf comptime walk — `spec` is comptime and only
// the matching arm contributes to runtime code generation. Wrapping
// the args[arg_idx] read in a separate inline fn (rather than a
// switch inside printf) keeps the comptime tuple index away from
// arg-less specs (`%%`, literals): if no arg-consuming spec runs in a
// given iteration, args is never indexed at all.
inline fn emit_spec(buf: *[BUF_LEN]u8, pos: *usize, comptime spec: u8, arg: anytype) void {
    switch (spec) {
        's' => buf_put_zstr(buf, pos, arg),
        'd', 'i' => buf_put_signed(buf, pos, @intCast(arg)),
        'u' => buf_put_unsigned(buf, pos, @intCast(arg)),
        'x' => buf_put_hex(buf, pos, @intCast(arg)),
        'c' => buf_put_byte(buf, pos, @intCast(arg)),
        else => @compileError("flibc.printf: unsupported %" ++ &[_]u8{spec}),
    }
}

// Saturating byte append — silently drops overflow past BUF_LEN-1 so
// the trailing slot stays free for the '\0' that printf writes before
// flushing. Truncating-on-overflow matches the demo-grade scope; the
// alternative (a syscall-per-flush mid-format) would push complexity
// disproportionate to the use case.
fn buf_put_byte(buf: *[BUF_LEN]u8, pos: *usize, c: u8) void {
    if (pos.* < BUF_LEN - 1) {
        buf[pos.*] = c;
        pos.* += 1;
    }
}

fn buf_put_zstr(buf: *[BUF_LEN]u8, pos: *usize, s: [*:0]const u8) void {
    var k: usize = 0;
    while (s[k] != 0) : (k += 1) {
        buf_put_byte(buf, pos, s[k]);
    }
}

fn buf_put_signed(buf: *[BUF_LEN]u8, pos: *usize, val: i64) void {
    if (val < 0) {
        buf_put_byte(buf, pos, '-');
        // i64.min would overflow `-val`; bitcast to u64 to recover the
        // magnitude in two's complement (-i64.min == i64.min reinterpret).
        // Branchless and avoids the IntegerOverflow runtime check.
        const mag: u64 = @bitCast(-(val +% 1));
        buf_put_unsigned(buf, pos, mag + 1);
    } else {
        buf_put_unsigned(buf, pos, @intCast(val));
    }
}

fn buf_put_unsigned(buf: *[BUF_LEN]u8, pos: *usize, val: u64) void {
    if (val == 0) {
        buf_put_byte(buf, pos, '0');
        return;
    }
    // u64.max is 20 decimal digits; 20 + slack rounds to the nearest
    // power-of-two stack slot.
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v > 0) : (v /= 10) {
        tmp[n] = @intCast('0' + (v % 10));
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        buf_put_byte(buf, pos, tmp[n]);
    }
}

fn buf_put_hex(buf: *[BUF_LEN]u8, pos: *usize, val: u64) void {
    if (val == 0) {
        buf_put_byte(buf, pos, '0');
        return;
    }
    const digits = "0123456789abcdef";
    var tmp: [16]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v > 0) : (v >>= 4) {
        tmp[n] = digits[@as(usize, @intCast(v & 0xf))];
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        buf_put_byte(buf, pos, tmp[n]);
    }
}
