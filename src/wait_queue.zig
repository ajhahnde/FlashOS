// Minimum-viable wait queue for blocking syscalls — single source of
// truth for the v0.3.0 IPC and (Phase 5) signal/do_wait migration.
//
// Discipline:
//   * Wait-side links the running task at head, flips state to
//     INTERRUPTIBLE, drops preempt, then schedules. The wake-side
//     reverses both (pop + flip to RUNNING + clear wq_next).
//   * `wq_next` lives in TaskStruct (src/task_layout.zig) — a task can
//     only be on one queue at a time, mirroring Linux's wq_node.
//   * Single-core: `preempt_disable` around the head mutation is enough
//     because no two callers can race on the same queue. Phase 5
//     migrates wake/wait to spinlocks (which disable IRQs on acquire);
//     the API surface stays identical.
//   * IRQ callers (Schritt 1.3 mini-UART RX) are fine on single-core
//     because the entry path masks IRQs and there is no concurrent
//     mutator from EL1h.

// Named module — see build.zig (`task_layout_mod`). Required because
// wait_queue.zig is itself a named module; if it pulled task_layout.zig
// in via relative import while a sibling named module (pipe.zig) did
// the same, Zig 0.16 would diagnose "file exists in two modules".
const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;
const TASK_RUNNING = layout.TASK_RUNNING;
const TASK_INTERRUPTIBLE = layout.TASK_INTERRUPTIBLE;

extern var current: ?*TaskStruct;
extern fn preempt_disable() void;
extern fn preempt_enable() void;
extern fn schedule() void;

pub const WaitQueue = extern struct {
    head: ?*TaskStruct = null,

    pub fn wait(self: *WaitQueue) void {
        preempt_disable();
        const c = current.?;
        c.wq_next = self.head;
        self.head = c;
        c.state = TASK_INTERRUPTIBLE;
        // preempt_enable BEFORE schedule — otherwise the task enters
        // _schedule_impl with preempt_count > 0 and stalls the chosen-
        // next loop. Same pattern as sys_kill in src/sys.zig.
        preempt_enable();
        schedule();
    }

    pub fn wake_one(self: *WaitQueue) void {
        preempt_disable();
        if (self.head) |t| {
            self.head = t.wq_next;
            t.wq_next = null;
            t.state = TASK_RUNNING;
        }
        preempt_enable();
    }

    pub fn wake_all(self: *WaitQueue) void {
        preempt_disable();
        var node = self.head;
        self.head = null;
        while (node) |t| {
            const nxt = t.wq_next;
            t.wq_next = null;
            t.state = TASK_RUNNING;
            node = nxt;
        }
        preempt_enable();
    }
};

// ---- Host tests ----
//
// `schedule` is a no-op stub on the host (see tests/host_stubs.zig); we
// build the queue and exercise the wake-side directly instead of routing
// through `WaitQueue.wait`. Coverage of the wait-side blocking path comes
// from the in-kernel pipe scenario.

const std = @import("std");

test "wake_one pops in LIFO order (head-insert)" {
    var t1: TaskStruct = .{};
    var t2: TaskStruct = .{};
    var t3: TaskStruct = .{};
    var q: WaitQueue = .{};

    // Manual head-insert mirrors what WaitQueue.wait does, just without
    // the schedule round-trip.
    t1.wq_next = null;
    q.head = &t1;
    t2.wq_next = q.head;
    q.head = &t2;
    t3.wq_next = q.head;
    q.head = &t3;

    t1.state = TASK_INTERRUPTIBLE;
    t2.state = TASK_INTERRUPTIBLE;
    t3.state = TASK_INTERRUPTIBLE;

    q.wake_one();
    try std.testing.expectEqual(&t2, q.head.?);
    try std.testing.expectEqual(@as(?*TaskStruct, null), t3.wq_next);
    try std.testing.expectEqual(TASK_RUNNING, t3.state);
    try std.testing.expectEqual(TASK_INTERRUPTIBLE, t2.state);
}

test "wake_one on empty queue is a noop" {
    var q: WaitQueue = .{};
    q.wake_one();
    try std.testing.expectEqual(@as(?*TaskStruct, null), q.head);
}

test "wake_all drains every entry and resets state + wq_next" {
    var t1: TaskStruct = .{};
    var t2: TaskStruct = .{};
    var t3: TaskStruct = .{};
    var q: WaitQueue = .{};

    t1.wq_next = null;
    q.head = &t1;
    t2.wq_next = q.head;
    q.head = &t2;
    t3.wq_next = q.head;
    q.head = &t3;

    t1.state = TASK_INTERRUPTIBLE;
    t2.state = TASK_INTERRUPTIBLE;
    t3.state = TASK_INTERRUPTIBLE;

    q.wake_all();
    try std.testing.expectEqual(@as(?*TaskStruct, null), q.head);
    try std.testing.expectEqual(@as(?*TaskStruct, null), t1.wq_next);
    try std.testing.expectEqual(@as(?*TaskStruct, null), t2.wq_next);
    try std.testing.expectEqual(@as(?*TaskStruct, null), t3.wq_next);
    try std.testing.expectEqual(TASK_RUNNING, t1.state);
    try std.testing.expectEqual(TASK_RUNNING, t2.state);
    try std.testing.expectEqual(TASK_RUNNING, t3.state);
}

test "wake_all on empty queue is a noop" {
    var q: WaitQueue = .{};
    q.wake_all();
    try std.testing.expectEqual(@as(?*TaskStruct, null), q.head);
}
