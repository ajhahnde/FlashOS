// Pure AAPCS64 frame-pointer chain walker — the decode math behind the
// -Dtrace sampler (src/trace/sampler.zig), factored out with no kernel
// dependencies so it can be host-tested deterministically (the live timer
// sampler only fires on real Pi, where async ticks interrupt the kernel).
//
// On AArch64 a standard frame record is two words at the frame pointer:
//   [fp + 0] = caller's frame pointer (the next link in the chain)
//   [fp + 8] = the return address (saved LR) into the caller
// walkChain follows that chain, collecting the saved LRs, bounded by the
// stack page and a set of guards that make a garbage pointer terminate the
// walk instead of running off into unmapped memory:
//   * fp must stay inside [base, base + page) with room for both words,
//   * fp must be 16-byte aligned (AAPCS64 requires it),
//   * the chain must climb monotonically (next > fp) — a stale or self-
//     referential record stops the walk rather than looping forever,
//   * the caller-supplied `out` slice caps the depth.
//
// `mem` is a flat view of the stack page whose first byte is virtual
// address `base`; reads go through the slice (not raw pointers) so the same
// code runs unchanged on the host under test.

const std = @import("std");

/// Follow the frame-pointer chain starting at `start_fp`, writing each
/// frame's saved LR into `out`. Returns the number of LRs written.
pub fn walkChain(mem: []const u8, base: u64, start_fp: u64, out: []u64) usize {
    const top = base +% @as(u64, mem.len);
    var fp = start_fp;
    var n: usize = 0;
    while (n < out.len and
        fp >= base and
        // Room for both words, computed wrap-safe: a near-u64-max fp must not
        // slip through by `fp +% 16` wrapping past `top` (which would make
        // fp - base a giant offset and fault on the read). `fp <= top` first
        // keeps `top - fp` from underflowing.
        fp <= top and top - fp >= 16 and
        (fp & 0xF) == 0)
    {
        const off: usize = @intCast(fp - base);
        out[n] = std.mem.readInt(u64, mem[off + 8 ..][0..8], .little); // saved LR
        n += 1; // count the frame we just decoded before any early-out
        const next = std.mem.readInt(u64, mem[off..][0..8], .little); // caller FP
        if (next <= fp) break; // monotonic guard: chain must climb the stack
        fp = next; // a next that leaves the page ends the walk via the loop cond
    }
    return n;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

// Lay a frame record (caller-fp, saved-lr) into `mem` at virtual address
// `fp_va`, given the page base.
fn putFrame(mem: []u8, base: u64, fp_va: u64, next_fp: u64, lr: u64) void {
    const off: usize = @intCast(fp_va - base);
    std.mem.writeInt(u64, mem[off..][0..8], next_fp, .little);
    std.mem.writeInt(u64, mem[off + 8 ..][0..8], lr, .little);
}

test "walks a well-formed three-deep chain" {
    const base: u64 = 0x4000;
    var page = [_]u8{0} ** 0x200;
    // Three frames climbing the stack: 0x4040 -> 0x4080 -> 0x40C0.
    putFrame(&page, base, 0x4040, 0x4080, 0xAAAA);
    putFrame(&page, base, 0x4080, 0x40C0, 0xBBBB);
    putFrame(&page, base, 0x40C0, base + 0x200, 0xCCCC); // next == top: walk ends
    var out: [8]u64 = undefined;
    const n = walkChain(&page, base, 0x4040, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u64, 0xAAAA), out[0]);
    try testing.expectEqual(@as(u64, 0xBBBB), out[1]);
    try testing.expectEqual(@as(u64, 0xCCCC), out[2]);
}

test "stops on a non-monotonic (self/back) link" {
    const base: u64 = 0x4000;
    var page = [_]u8{0} ** 0x200;
    putFrame(&page, base, 0x4040, 0x4080, 0x1111);
    putFrame(&page, base, 0x4080, 0x4080, 0x2222); // points to itself -> stop
    var out: [8]u64 = undefined;
    const n = walkChain(&page, base, 0x4040, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 0x1111), out[0]);
    try testing.expectEqual(@as(u64, 0x2222), out[1]);
}

test "rejects a misaligned start fp without reading" {
    const base: u64 = 0x4000;
    var page = [_]u8{0} ** 0x200;
    var out: [8]u64 = undefined;
    try testing.expectEqual(@as(usize, 0), walkChain(&page, base, 0x4044, &out));
}

test "rejects an out-of-page start fp" {
    const base: u64 = 0x4000;
    var page = [_]u8{0} ** 0x200;
    var out: [8]u64 = undefined;
    // Below the page and flush against the top (no room for two words).
    try testing.expectEqual(@as(usize, 0), walkChain(&page, base, 0x3000, &out));
    try testing.expectEqual(@as(usize, 0), walkChain(&page, base, base + 0x200 - 8, &out));
}

test "rejects a wrapping near-u64-max start fp without faulting" {
    const base: u64 = 0x4000;
    var page = [_]u8{0} ** 0x200;
    var out: [8]u64 = undefined;
    // fp is 16-aligned and within 16 of u64::MAX, so a naive `fp +% 16 <= top`
    // guard wraps to ~0 and accepts it, then fp - base is a giant offset that
    // faults on the read. The wrap-safe bound must reject it outright.
    try testing.expectEqual(@as(usize, 0), walkChain(&page, base, 0xFFFFFFFFFFFFFFF0, &out));
}

test "depth is capped by the out slice" {
    const base: u64 = 0x4000;
    var page = [_]u8{0} ** 0x400;
    // A long climbing chain; only the first two should be captured.
    var fp: u64 = 0x4040;
    while (fp + 0x40 < base + 0x400) : (fp += 0x40) {
        putFrame(&page, base, fp, fp + 0x40, fp); // lr = fp for easy checking
    }
    var out: [2]u64 = undefined;
    const n = walkChain(&page, base, 0x4040, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 0x4040), out[0]);
    try testing.expectEqual(@as(u64, 0x4080), out[1]);
}
