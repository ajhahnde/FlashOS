// Board-agnostic console RX layer (v0.3.0).
//
// 256-byte single-producer / single-consumer ring buffered between the
// board IRQ handler (mini-UART RX on Pi, PL011 RX on virt) and the
// sys_readConsole syscall. WaitQueue covers the empty-ring blocking
// path; the wake-side fires from console_push when the IRQ-handler
// delivers a byte. Read-side drains short — caller loops if it needs N>1
// bytes — matching POSIX TTY-read semantics and keeping the WaitQueue
// discipline spurious-wake-free in one edge.
//
// Push/read are single-producer / single-consumer by construction on
// single core: only the entry path enters console_push, only EL1
// syscall context enters console_read. Future work will bracket
// both sides in spinlocks once SMP and nested IRQs land; the API
// surface stays stable.
//
// Counter discipline mirrors src/pipe.zig: monotone u32 byte counters
// with modulo-indexed slot access, so is_full vs. is_empty are
// distinguishable without burning a slot. FIXME: u32 wraps after
// 4 GiB of RX traffic; the test injects KiB at most so the wrap is
// unreachable today.
//
// Echo policy lives in user space (future fsh) — console_push does
// NOT loop the byte back through the TX path.

const layout = @import("task_layout");
const wq_mod = @import("wait_queue");
const WaitQueue = wq_mod.WaitQueue;

extern fn preempt_disable() void;
extern fn preempt_enable() void;

pub const RX_RING_SIZE: u32 = 256;

var rx_ring: [RX_RING_SIZE]u8 = [_]u8{0} ** RX_RING_SIZE;
var rx_head: u32 = 0;
var rx_tail: u32 = 0;
var rx_wq: WaitQueue = .{};

fn count() u32 {
    return rx_head -% rx_tail;
}
fn is_empty() bool {
    return rx_head == rx_tail;
}
fn is_full() bool {
    return count() == RX_RING_SIZE;
}

// Called from board/{rpi4b,virt}/irq.zig with IRQs masked at the CPU
// level by the exception entry. Drops the byte silently if the ring
// is full — a future shell keeps up at human typing rate; the burst
// / stress case is future work once spinlocks discriminate the
// wait-side from the wake-side properly.
pub fn console_push(byte: u8) void {
    if (is_full()) return;
    rx_ring[rx_head % RX_RING_SIZE] = byte;
    rx_head +%= 1;
    rx_wq.wake_one();
}

// Block until at least one byte is available, then drain up to `len`
// bytes (no waiting for the full `len` — short reads are fine, the
// user wrapper loops if it wants more). Returns the number of bytes
// copied. POSIX TTY-style semantics: line / char-mode flags are
// future work.
pub fn console_read(buf: [*]u8, len: u64) i64 {
    if (len == 0) return 0;
    var copied: u64 = 0;
    while (copied == 0) {
        preempt_disable();
        if (!is_empty()) {
            while (copied < len and !is_empty()) {
                buf[copied] = rx_ring[rx_tail % RX_RING_SIZE];
                rx_tail +%= 1;
                copied += 1;
            }
            preempt_enable();
            break;
        }
        preempt_enable();
        rx_wq.wait();
    }
    return @intCast(copied);
}

// FIXME: debug-only sibling of console_push, reachable from
// EL1 syscall context (no IRQ-masking assumption). Identical wake
// path. Powers deterministic console-echo coverage on QEMU where
// there is no external input driver. Symmetric to sys_dump_free —
// permanent debug surface, not part of the stable ABI.
pub fn console_test_push(byte: u8) void {
    preempt_disable();
    if (!is_full()) {
        rx_ring[rx_head % RX_RING_SIZE] = byte;
        rx_head +%= 1;
    }
    preempt_enable();
    rx_wq.wake_one();
}

// ---- Host tests ----
//
// The blocking path through `console_read` exercises the WaitQueue
// `wait`; `schedule` is a host-side no-op (tests/host_stubs.zig), so
// blocking is not host-testable. Coverage lives in the kernel-side
// run_console_echo scenario. Here we drive push/read directly and
// assert ring bookkeeping + wake-side wq state transitions.

const std = @import("std");
const TaskStruct = layout.TaskStruct;
const TASK_RUNNING = layout.TASK_RUNNING;
const TASK_INTERRUPTIBLE = layout.TASK_INTERRUPTIBLE;

fn reset() void {
    rx_head = 0;
    rx_tail = 0;
    rx_wq = .{};
    var i: usize = 0;
    while (i < RX_RING_SIZE) : (i += 1) rx_ring[i] = 0;
}

test "push then read returns the byte" {
    reset();
    console_test_push(0x42);
    var buf: [1]u8 = undefined;
    const n = console_read(&buf, 1);
    try std.testing.expectEqual(@as(i64, 1), n);
    try std.testing.expectEqual(@as(u8, 0x42), buf[0]);
    try std.testing.expect(is_empty());
}

test "ring wraps cleanly when head crosses RX_RING_SIZE" {
    reset();
    // Seed near the wrap boundary so 8 pushes straddle modulo.
    rx_head = RX_RING_SIZE - 4;
    rx_tail = RX_RING_SIZE - 4;
    var i: u8 = 0;
    while (i < 8) : (i += 1) console_test_push(0xC0 + i);
    var buf: [8]u8 = undefined;
    const n = console_read(&buf, 8);
    try std.testing.expectEqual(@as(i64, 8), n);
    i = 0;
    while (i < 8) : (i += 1) {
        try std.testing.expectEqual(@as(u8, 0xC0 + i), buf[i]);
    }
}

test "is_full rejects further pushes silently" {
    reset();
    var i: u32 = 0;
    while (i < RX_RING_SIZE) : (i += 1) console_test_push(@truncate(i));
    try std.testing.expect(is_full());
    // Extra push must be a no-op — head stays put.
    const head_before = rx_head;
    console_test_push(0xFF);
    try std.testing.expectEqual(head_before, rx_head);
}

test "console_test_push wakes a fake waiter" {
    reset();
    var t: TaskStruct = .{};
    t.state = TASK_INTERRUPTIBLE;
    t.wq_next = null;
    rx_wq.head = &t;

    console_test_push(0x55);

    try std.testing.expectEqual(@as(?*TaskStruct, null), rx_wq.head);
    try std.testing.expectEqual(TASK_RUNNING, t.state);
    try std.testing.expectEqual(@as(?*TaskStruct, null), t.wq_next);
}

test "short read: drains what's there, returns even if < len" {
    reset();
    console_test_push(0xAA);
    console_test_push(0xBB);
    var buf: [8]u8 = undefined;
    const n = console_read(&buf, 8);
    try std.testing.expectEqual(@as(i64, 2), n);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), buf[1]);
}

test "empty after full drain restores is_empty == true" {
    reset();
    console_test_push(0x01);
    console_test_push(0x02);
    var buf: [2]u8 = undefined;
    _ = console_read(&buf, 2);
    try std.testing.expect(is_empty());
    try std.testing.expectEqual(@as(u32, 0), count());
}

test "len == 0 read returns 0 without blocking" {
    reset();
    var buf: [1]u8 = undefined;
    const n = console_read(&buf, 0);
    try std.testing.expectEqual(@as(i64, 0), n);
}
