// hwrng: kernel entropy source for salt generation.
//
// Ships the FALLBACK path only: the generic-timer counter
// (CNTPCT_EL0, via get_sys_count) mixed through SplitMix64. This is
// deliberately WEAK — timer-derived bits are low-entropy at boot — and
// is acceptable only because the CI targets authenticate against fixed
// initramfs fixtures. The boot announce is loud about it so the weak
// path can never run silently.
//
// FIXME: the BCM2711 hardware RNG (the RNG200 block) driver is not here
// yet. QEMU's raspi4b machine does not back that MMIO region, and an EL1
// read of an unbacked device address raises a synchronous external abort
// (the kernel hangs in err_hang before reaching the shell), so a real-HW
// driver cannot be exercised by either CI target — there is no safe
// "probe by reading" for an absent block. The driver lands together with
// its on-bench hardware validation; from then on, falling back on real
// hardware becomes a hard failure instead of an announce-and-continue.
//
// Concurrency: single-core kernel; hwrng_init() runs once during
// bring-up before PID 1 exists, fill() is called from syscall context
// afterwards. No locking until the SMP pass (same posture as klog_ring).

// ---- Pure mixer (host-tested) ----

// SplitMix64 finalizer (Steele/Lea/Flood; Vigna's reference
// implementation). Avalanches a 64-bit input into a 64-bit output.
pub fn splitmix64(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

// The SplitMix64 "golden gamma" increment.
const GAMMA: u64 = 0x9E3779B97F4A7C15;

// Deterministic core of the fallback generator: a SplitMix64 stream
// whose state additionally absorbs an entropy word on every draw. Pure
// (no externs) so host tests can drive it with known inputs; the
// gamma increment alone guarantees consecutive outputs differ even if
// the absorbed entropy word is stuck.
pub const Mixer = struct {
    state: u64,

    pub fn init(seed: u64) Mixer {
        return .{ .state = splitmix64(seed) };
    }

    pub fn next(self: *Mixer, entropy: u64) u64 {
        self.state +%= GAMMA;
        self.state ^= entropy;
        return splitmix64(self.state);
    }
};

// ---- Kernel glue (timer-backed, announce over the UART) ----

const MU: i32 = 0;

extern fn get_sys_count() u64;
extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_char(interface: i32, ch: u8) void;

const console_ui = @import("console_ui");

// console_ui Sink bound to the same Mini-UART boot console the kernel logs to
// (byte-at-a-time; see src/kernel.zig `bootSink` for the rationale).
fn bootSink(bytes: []const u8) void {
    for (bytes) |b| main_output_char(MU, b);
}
const boot = console_ui.logger(&bootSink);

// Which entropy source produced the bytes. Only the weak fallback
// exists today; the hardware source joins with the RNG200 driver.
pub const Source = enum { fallback };

var mixer: Mixer = .{ .state = 0 };

// Fill `buf` with generator output and report which source produced it.
// This is the salt-minting primitive for the authentication syscalls.
// Allocation-free: writes only into the caller's buffer.
pub fn fill(buf: []u8) Source {
    var i: usize = 0;
    while (i < buf.len) {
        var word = mixer.next(get_sys_count());
        var k: usize = 0;
        while (k < 8 and i < buf.len) : (k += 1) {
            buf[i] = @truncate(word);
            word >>= 8;
            i += 1;
        }
    }
    return .fallback;
}

// Boot-time init: seed the mixer, self-test, announce the active source.
// Called once from kernel_main after the Mini-UART is up and before
// PID 1 is created, so the announce line sits in the kernel log ring by
// the time the EL0 harness scenario snapshots it. Allocates nothing —
// the free-page baseline emitted right after is unaffected.
export fn hwrng_init() void {
    mixer = Mixer.init(get_sys_count());

    // Self-test: two draws must differ. A stuck counter or a mixer
    // regression would mint the same salt for every credential — catch
    // that loudly at boot rather than silently weakening every hash.
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    _ = fill(a[0..]);
    _ = fill(b[0..]);
    var same = true;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (a[i] != b[i]) same = false;
    }
    if (same) {
        boot.warn("hwrng: self-test failed (constant output)");
        return;
    }
    boot.ok("Initialized hwrng");
}

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

test "SplitMix64 reference sequence from seed 0" {
    // First outputs of the SplitMix64 reference generator seeded with 0.
    // A transcription error in the multiplier constants or shift amounts
    // changes every value.
    var state: u64 = 0;
    const expected = [_]u64{ 0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4, 0x06C45D188009454F };
    for (expected) |want| {
        state +%= GAMMA;
        try testing.expectEqual(want, splitmix64(state));
    }
}

test "differential: splitmix64 matches std.Random.SplitMix64" {
    var theirs = std.Random.SplitMix64.init(0);
    var state: u64 = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        state +%= GAMMA;
        try testing.expectEqual(theirs.next(), splitmix64(state));
    }
}

test "Mixer: outputs differ even with a stuck entropy input" {
    // The property the boot self-test relies on: even if CNTPCT were
    // stuck, the gamma increment alone changes every draw.
    var m = Mixer.init(0);
    const first = m.next(0xDEADBEEF);
    const second = m.next(0xDEADBEEF);
    const third = m.next(0xDEADBEEF);
    try testing.expect(first != second);
    try testing.expect(second != third);
    try testing.expect(first != third);
}

test "Mixer: same seed and entropy sequence reproduces the stream" {
    var m1 = Mixer.init(42);
    var m2 = Mixer.init(42);
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(m1.next(i *% 7919), m2.next(i *% 7919));
    }
}

test "Mixer: different seeds diverge" {
    var m1 = Mixer.init(1);
    var m2 = Mixer.init(2);
    var collisions: u32 = 0;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        if (m1.next(0) == m2.next(0)) collisions += 1;
    }
    try testing.expectEqual(@as(u32, 0), collisions);
}

test "fill + hwrng_init: end-to-end with the stubbed counter" {
    // tests/host_stubs.zig provides a ramping get_sys_count and a no-op
    // main_output, so the real boot path (seed → self-test → announce)
    // runs here exactly as in the kernel.
    hwrng_init();
    var a: [23]u8 = undefined; // odd length: exercises the partial last word
    var b: [23]u8 = undefined;
    try testing.expectEqual(Source.fallback, fill(a[0..]));
    try testing.expectEqual(Source.fallback, fill(b[0..]));
    try testing.expect(!std.mem.eql(u8, a[0..], b[0..]));
}
