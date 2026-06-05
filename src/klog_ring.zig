// klog_ring: kernel log byte-ring (overwrite-oldest) — the dmesg backend.
//
// A single static byte ring that main_output (src/utilc.zig) tees every
// emitted line into, so the boot log survives in RAM and a userland
// `dmesg` can read it back through sys_klog_read (slot 38). This makes the
// Mini-UART / FTDI adapter unnecessary for post-boot diagnosis over the
// USB-C console: the boot log becomes a syscall away.
//
// Pure data + pure logic — no MMIO, no extern — so it host-unit-tests with
// no hardware (mirrors src/usb_tx_ring.zig and src/console.zig's RX ring).
// The kernel imports this as the named module "klog_ring": src/utilc.zig
// pushes into `klog`, src/sys.zig snapshots out of it; both share the one
// instance because Zig analyses a named module once.
//
// Monotone u64 head/tail with modulo indexing, exactly as usb_tx_ring —
// with ONE deliberate inversion. usb_tx_ring is drop-NEWEST (push returns
// false when full: backpressure on a live TX path that must not lose the
// in-flight bytes). A log is the opposite: it always keeps the MOST RECENT
// bytes and lets the oldest scroll off. So push here never fails; when the
// window is full it advances `tail` to drop the oldest byte.
//
// Concurrency / memory-safety. main_output is called from kernel, syscall,
// AND IRQ context, and as early as boot.S before `current` exists — so the
// tee CANNOT take preempt_disable (which dereferences `current`). push() is
// therefore lock-free and best-effort: every buffer index is masked
// `% SIZE` and every read length is clamped to `available()`, so the worst
// an IRQ-interrupts-push interleaving can do is garble a byte or mis-count
// by one — never an out-of-bounds access, never a wild pointer. Torn UART
// output is already accepted here (mini_uart_send_string holds no lock
// either); torn klog bytes are the same posture. A future SMP/locking pass
// revisits, exactly as console.zig documents for its RX ring.

const defs = @import("syscall_defs");

// Ring capacity. Lives in lib/syscall_defs.zig because userland `dmesg`
// sizes its read buffer against the same number (an ABI-visible constant,
// like Dirent). Big enough to hold a full interactive boot log
// (firmware marker → `fsh init OK`); the much longer in-harness log wraps,
// which is fine — [TEST] klog only asserts a recent marker survives.
pub const SIZE: u64 = defs.KLOG_SIZE;

pub const KlogRing = struct {
    buf: [SIZE]u8 = [_]u8{0} ** SIZE,
    head: u64 = 0, // total bytes ever pushed (monotone)
    tail: u64 = 0, // start of the retained window; head - tail <= SIZE

    // Bytes currently retained (head/tail are monotone; -% wraps cleanly).
    pub fn available(self: *const KlogRing) u64 {
        return self.head -% self.tail;
    }

    // The byte at absolute monotone position `pos`, masked into the ring.
    // Only meaningful for pos in [tail, head); callers clamp to that.
    pub fn byteAt(self: *const KlogRing, pos: u64) u8 {
        return self.buf[pos % SIZE];
    }

    // Append one byte, overwriting the oldest when the ring is full.
    pub fn push(self: *KlogRing, byte: u8) void {
        self.buf[self.head % SIZE] = byte;
        self.head +%= 1;
        // Full → advance tail so the window never exceeds SIZE. A clamp
        // (not a decrement) so a racy double-push can never leave the
        // window larger than SIZE — it self-heals to exactly SIZE.
        if (self.head -% self.tail > SIZE) self.tail = self.head -% SIZE;
    }

    // Append a NUL-terminated string. The main_output tee. NOT recursive
    // and allocation-free, so it is safe to call from inside main_output
    // (no re-entry through main_output, no free-page perturbation).
    pub fn pushStr(self: *KlogRing, str: [*:0]const u8) void {
        var i: u64 = 0;
        while (str[i] != 0) : (i += 1) self.push(str[i]);
    }

    // Copy the most-recent min(dst.len, available) bytes into dst,
    // oldest-of-that-window first, and return the count. A snapshot: it
    // neither consumes nor blocks. dmesg passes a buffer >= SIZE to get
    // the whole retained log; a smaller buffer yields the most recent
    // tail — the sensible default for a log viewer. The kernel
    // sys_klog_read handler reproduces this windowing directly (it must
    // bounce through a 512-byte kernel buffer for copy_to_user), so this
    // method is the host-tested reference for that arithmetic.
    pub fn snapshot(self: *const KlogRing, dst: []u8) u64 {
        const n = @min(self.available(), @as(u64, dst.len));
        const start = self.head -% n; // most recent n bytes
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            dst[@intCast(i)] = self.byteAt(start +% i);
        }
        return n;
    }
};

// The one kernel-wide log ring. BSS-resident: zero-initialised at boot,
// never allocated, so teeing into it cannot perturb the free-page
// baseline the harness asserts.
pub var klog: KlogRing = .{};

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

// A small ring so wrap + overwrite are cheap to exercise. The host build
// reaches the SIZE-typed `KlogRing` via the kernel; the tests below build
// their own small TestRing so SIZE (16 KiB) need not be filled byte by
// byte. The arithmetic is identical — only the modulus differs.
fn TestRing(comptime size: u64) type {
    return struct {
        const Self = @This();
        buf: [size]u8 = [_]u8{0} ** size,
        head: u64 = 0,
        tail: u64 = 0,
        fn available(self: *const Self) u64 {
            return self.head -% self.tail;
        }
        fn push(self: *Self, byte: u8) void {
            self.buf[self.head % size] = byte;
            self.head +%= 1;
            if (self.head -% self.tail > size) self.tail = self.head -% size;
        }
        fn pushStr(self: *Self, s: []const u8) void {
            for (s) |b| self.push(b);
        }
        fn snapshot(self: *const Self, dst: []u8) u64 {
            const n = @min(self.available(), @as(u64, dst.len));
            const start = self.head -% n;
            var i: u64 = 0;
            while (i < n) : (i += 1) dst[@intCast(i)] = self.buf[(start +% i) % size];
            return n;
        }
    };
}

const Ring8 = TestRing(8);

test "push then snapshot round-trips bytes in order" {
    var r = Ring8{};
    try testing.expectEqual(@as(u64, 0), r.available());
    r.pushStr("abc");
    try testing.expectEqual(@as(u64, 3), r.available());
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(u64, 3), r.snapshot(buf[0..]));
    try testing.expectEqualStrings("abc", buf[0..3]);
    try testing.expectEqual(@as(u64, 3), r.available()); // snapshot did not consume
}

test "overwrite-oldest: a full ring keeps the most recent SIZE bytes" {
    var r = Ring8{};
    r.pushStr("0123456789"); // 10 bytes into an 8-byte ring → drop "01"
    try testing.expectEqual(@as(u64, 8), r.available());
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(u64, 8), r.snapshot(buf[0..]));
    try testing.expectEqualStrings("23456789", buf[0..8]); // oldest two scrolled off
}

test "snapshot caps to dst.len and returns the most recent tail" {
    var r = Ring8{};
    r.pushStr("ABCDE");
    var small: [3]u8 = undefined; // dst < available → most recent 3
    try testing.expectEqual(@as(u64, 3), r.snapshot(small[0..]));
    try testing.expectEqualStrings("CDE", small[0..3]);
}

test "snapshot on an empty ring copies nothing" {
    var r = Ring8{};
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(u64, 0), r.snapshot(buf[0..]));
}

test "snapshot clamps to available when dst is larger" {
    var r = Ring8{};
    r.pushStr("hi");
    var big: [8]u8 = undefined;
    try testing.expectEqual(@as(u64, 2), r.snapshot(big[0..]));
    try testing.expectEqualStrings("hi", big[0..2]);
}

test "a marker pushed last survives an overwrite and ends the snapshot" {
    // Mirrors the [TEST] klog assertion: flood the ring, then push a
    // marker, and confirm the marker is the tail of the snapshot.
    var r = Ring8{};
    var i: u8 = 0;
    while (i < 50) : (i += 1) r.push('.');
    r.pushStr("klog");
    var buf: [8]u8 = undefined;
    const n = r.snapshot(buf[0..]);
    try testing.expectEqualStrings("klog", buf[n - 4 .. n]);
}

test "counters stay correctly ordered across u64 wraparound" {
    var r = Ring8{};
    r.head = std.math.maxInt(u64) - 2;
    r.tail = std.math.maxInt(u64) - 2;
    try testing.expectEqual(@as(u64, 0), r.available());
    r.pushStr("XYZ"); // head crosses the u64 wrap
    try testing.expectEqual(@as(u64, 3), r.available());
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(u64, 3), r.snapshot(buf[0..]));
    try testing.expectEqualStrings("XYZ", buf[0..3]);
}

// The shipping KlogRing (SIZE = 16 KiB) shares the exact arithmetic; one
// direct test guards the real type + the overwrite boundary at SIZE.
test "KlogRing overwrites at exactly SIZE and keeps the newest byte" {
    var r = KlogRing{};
    var i: u64 = 0;
    while (i < SIZE) : (i += 1) r.push('a');
    try testing.expectEqual(SIZE, r.available());
    r.push('Z'); // one past full → oldest 'a' drops, window stays SIZE
    try testing.expectEqual(SIZE, r.available());
    var tail: [1]u8 = undefined;
    try testing.expectEqual(@as(u64, 1), r.snapshot(tail[0..]));
    try testing.expectEqual(@as(u8, 'Z'), tail[0]);
}
