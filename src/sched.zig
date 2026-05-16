// Scheduler — round-robin with priority counters.
// All extern-struct layouts (TaskStruct, CoreContext, MmStruct, UserPage,
// KeRegs) live in src/task_layout.zig as the single source of truth.
// The .S files (sched.S, entry.S) consume those layouts via raw offsets.

const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;
const TASK_RUNNING = layout.TASK_RUNNING;
const TASK_ZOMBIE = layout.TASK_ZOMBIE;
const TASK_INTERRUPTIBLE = layout.TASK_INTERRUPTIBLE;
const KTHREAD = layout.KTHREAD;
const MAX_PAGE_COUNT = layout.MAX_PAGE_COUNT;

// Pipe fd-table cleanup on reap. Kernel-only consumer; do_wait_impl
// calls pipe.closeAll(zombie) before the mm-page free loop so that
// any fds the zombie didn't close itself drop their refs and free
// their backing pages.
const pipe_mod = @import("pipe");
// File fd-table cleanup on reap (v0.4.0). Same posture as
// pipe_mod.closeAll above — initramfs fds the zombie left open drop
// their refs and return the File page to the allocator before the
// mm-page sweep so the free-page baseline reflects both legs of the
// per-process resource lifecycle.
const file_mod = @import("file");

const NR_TASKS: usize = 64;

extern fn core_switch_to(prev: *TaskStruct, next: *TaskStruct) void;
extern fn set_pgd(pgd: u64) void;
extern fn irq_enable() void;
extern fn irq_disable() void;
extern fn free_page(p: u64) void;
extern fn free_kernel_page(kp: u64) void;

// Internal callers (schedule, timer_tick) reach _schedule_impl through
// the patchable trampoline `_schedule` defined in
// src/trace/patchable_trampolines.S. Routing in-file calls via the
// trampoline is what allows tracing to fire on every scheduler entry,
// not just from cross-module callers.
extern fn _schedule() void;

var init_task: TaskStruct = .{
    .priority = 1,
    .flags = KTHREAD,
};

export var current: ?*TaskStruct = null;
export var task: [NR_TASKS]?*TaskStruct = .{null} ** NR_TASKS;
export var nr_tasks: i32 = 1;
// Monotonic pid allocator. init_task occupies pid 0; first user fork is pid 1.
export var next_pid: i32 = 1;

export fn preempt_disable() void {
    current.?.preempt_count += 1;
}

export fn preempt_enable() void {
    current.?.preempt_count -= 1;
}

/// Index of the RUNNING task with the highest `counter`, or null if no
/// task is RUNNING. Ties broken by lower index (strict `>` means the
/// first equal-counter slot wins). Pure: walks the slice as-is, no
/// mutation, no extern calls — host-testable.
pub fn pick_next_running(tasks: []const ?*TaskStruct) ?usize {
    var best: ?usize = null;
    var best_c: i64 = -1;
    var i: usize = 0;
    while (i < tasks.len) : (i += 1) {
        if (tasks[i]) |p| {
            if (p.state == TASK_RUNNING and p.counter > best_c) {
                best_c = p.counter;
                best = i;
            }
        }
    }
    return best;
}

/// Refill every non-null task's counter to `(counter >> 1) + priority`.
/// Called when the highest-counter RUNNING task has counter == 0 (round-
/// end). `counter` is i64 — `>>` is arithmetic, so an over-decremented
/// counter halves toward zero without flipping sign.
pub fn refill_counters(tasks: []const ?*TaskStruct) void {
    var i: usize = 0;
    while (i < tasks.len) : (i += 1) {
        if (tasks[i]) |p| {
            p.counter = (p.counter >> 1) + p.priority;
        }
    }
}

/// Flip `t` to ZOMBIE and wake an INTERRUPTIBLE parent. Caller must
/// hold preempt_disable. Pure state mutation — no scheduling, no page
/// frees. Shared between sys_kill (target-task) and exit_process (self).
pub fn zombify_and_wake_parent(t: *TaskStruct) void {
    t.state = TASK_ZOMBIE;
    if (t.parent) |p| {
        if (p.state == TASK_INTERRUPTIBLE) p.state = TASK_RUNNING;
    }
}

export fn _schedule_impl() void {
    preempt_disable();
    var idx: usize = 0;

    outer: while (true) {
        if (pick_next_running(&task)) |i| {
            if (task[i].?.counter != 0) {
                idx = i;
                break :outer;
            }
        }
        refill_counters(&task);
    }
    switch_to(task[idx].?);
    preempt_enable();
}

export fn schedule() void {
    current.?.counter = 0;
    _schedule();
}

export fn switch_to(next: *TaskStruct) void {
    if (current == next) return;
    const prev = current.?;
    current = next;
    // Kernel threads (mm.pgd == 0) share the boot-time id_pg_dir for
    // TTBR0; writing 0 there would unmap low memory and instantly fault
    // on the next ret to a low-VA kernel function (e.g. ret_from_fork).
    if (next.mm.pgd != 0) set_pgd(next.mm.pgd);
    core_switch_to(prev, next);
}

export fn timer_tick() void {
    const cur = current.?;
    cur.counter -= 1;
    if (cur.counter > 0 or cur.preempt_count > 0) return;
    cur.counter = 0;
    irq_enable();
    _schedule();
    irq_disable();
}

export fn exit_process() void {
    // Self-reap is unsafe here — the kernel page IS the running task's
    // stack + TaskStruct; the parent's sys_wait does the page sweep.
    preempt_disable();
    zombify_and_wake_parent(current.?);
    preempt_enable();
    schedule();
}

// Walk task[] for any child of `current`. If a zombie is found, free its
// resources and return its pid. If children exist but none are zombies,
// block (TASK_INTERRUPTIBLE) and retry on wake. Returns -1 if no children.
export fn do_wait_impl() i32 {
    preempt_disable();
    while (true) {
        var have_children: bool = false;
        var i: usize = 0;
        while (i < NR_TASKS) : (i += 1) {
            if (task[i]) |c| {
                if (c.parent == current.?) {
                    have_children = true;
                    if (c.state == TASK_ZOMBIE) {
                        const pid: i32 = c.pid;
                        // Close any fds the zombie left open. unref
                        // drops the refcount on each Pipe and frees
                        // the backing page when refs hits zero. Runs
                        // BEFORE the mm-page sweep so a Pipe page
                        // (refcounted, not in user/kernel_pages) is
                        // never accidentally freed twice and so the
                        // free-page baseline reflects both legs of
                        // the per-process resource lifecycle.
                        pipe_mod.closeAll(c);
                        file_mod.closeAll(c);
                        // Free user-mapped physical pages.
                        var j: usize = 0;
                        while (j < MAX_PAGE_COUNT) : (j += 1) {
                            const pa = c.mm.user_pages[j].pa;
                            if (pa != 0) free_page(pa);
                        }
                        // Free page-table pages (PGD/PUD/PMD/PTE).
                        j = 0;
                        while (j < MAX_PAGE_COUNT) : (j += 1) {
                            const kp = c.mm.kernel_pages[j];
                            if (kp != 0) free_page(kp);
                        }
                        // Drop the slot before freeing the kernel page so
                        // a stale pointer can never be observed.
                        task[i] = null;
                        free_kernel_page(@intFromPtr(c));
                        preempt_enable();
                        return pid;
                    }
                }
            }
        }
        if (!have_children) {
            preempt_enable();
            return -1;
        }
        current.?.state = TASK_INTERRUPTIBLE;
        preempt_enable();
        schedule();
        preempt_disable();
    }
}

export fn sched_init() void {
    current = &init_task;
    task[0] = &init_task;
}

// ---------------------------------------------------------------------
// Host tests (v0.3.0). The pure helpers run against caller-
// owned TaskStruct fixtures + a local `tasks` slice, so the global
// `task` / `current` state is never touched and tests stay hermetic.
// ---------------------------------------------------------------------
const std = @import("std");

test "refill_counters: each non-null task gets (c>>1) + priority" {
    var t1: TaskStruct = .{ .priority = 4, .counter = 10 };
    var t2: TaskStruct = .{ .priority = 2, .counter = 0 };
    var tasks: [3]?*TaskStruct = .{ &t1, null, &t2 };
    refill_counters(&tasks);
    try std.testing.expectEqual(@as(i64, (10 >> 1) + 4), t1.counter);
    try std.testing.expectEqual(@as(i64, 0 + 2), t2.counter);
}

test "refill_counters: null slots are skipped" {
    var tasks: [4]?*TaskStruct = .{ null, null, null, null };
    refill_counters(&tasks);
}

test "refill_counters: negative counter halves via arithmetic shift" {
    // counter is i64 — `>>` on signed types is arithmetic in Zig. Guards
    // the long-standing assumption that an over-decremented counter (e.g.
    // a kill racing the timer tick) still refills sanely.
    var t: TaskStruct = .{ .priority = 5, .counter = -3 };
    var tasks: [1]?*TaskStruct = .{&t};
    refill_counters(&tasks);
    // -3 >> 1 == -2 (arithmetic shift), + 5 == 3
    try std.testing.expectEqual(@as(i64, 3), t.counter);
}

test "pick_next_running: returns index of highest-counter RUNNING task" {
    var t0: TaskStruct = .{ .state = TASK_RUNNING, .counter = 5 };
    var t1: TaskStruct = .{ .state = TASK_RUNNING, .counter = 9 };
    var t2: TaskStruct = .{ .state = TASK_RUNNING, .counter = 7 };
    var tasks: [3]?*TaskStruct = .{ &t0, &t1, &t2 };
    try std.testing.expectEqual(@as(?usize, 1), pick_next_running(&tasks));
}

test "pick_next_running: ignores ZOMBIE and INTERRUPTIBLE" {
    var t0: TaskStruct = .{ .state = TASK_ZOMBIE, .counter = 99 };
    var t1: TaskStruct = .{ .state = TASK_INTERRUPTIBLE, .counter = 50 };
    var t2: TaskStruct = .{ .state = TASK_RUNNING, .counter = 3 };
    var tasks: [3]?*TaskStruct = .{ &t0, &t1, &t2 };
    try std.testing.expectEqual(@as(?usize, 2), pick_next_running(&tasks));
}

test "pick_next_running: null when no RUNNING task exists" {
    var t0: TaskStruct = .{ .state = TASK_ZOMBIE };
    var tasks: [2]?*TaskStruct = .{ &t0, null };
    try std.testing.expectEqual(@as(?usize, null), pick_next_running(&tasks));
}

test "pick_next_running: first-match wins on counter ties" {
    var t0: TaskStruct = .{ .state = TASK_RUNNING, .counter = 5 };
    var t1: TaskStruct = .{ .state = TASK_RUNNING, .counter = 5 };
    var tasks: [2]?*TaskStruct = .{ &t0, &t1 };
    // Strict `>` — later-equal cannot displace earlier, so t0 wins.
    try std.testing.expectEqual(@as(?usize, 0), pick_next_running(&tasks));
}

test "zombify_and_wake_parent: child->ZOMBIE, INTERRUPTIBLE parent->RUNNING" {
    var parent: TaskStruct = .{ .state = TASK_INTERRUPTIBLE };
    var child: TaskStruct = .{ .state = TASK_RUNNING, .parent = &parent };
    zombify_and_wake_parent(&child);
    try std.testing.expectEqual(TASK_ZOMBIE, child.state);
    try std.testing.expectEqual(TASK_RUNNING, parent.state);
}

test "zombify_and_wake_parent: RUNNING parent stays RUNNING" {
    var parent: TaskStruct = .{ .state = TASK_RUNNING };
    var child: TaskStruct = .{ .state = TASK_RUNNING, .parent = &parent };
    zombify_and_wake_parent(&child);
    try std.testing.expectEqual(TASK_ZOMBIE, child.state);
    try std.testing.expectEqual(TASK_RUNNING, parent.state);
}

test "zombify_and_wake_parent: ZOMBIE parent stays ZOMBIE (orphan path)" {
    var parent: TaskStruct = .{ .state = TASK_ZOMBIE };
    var child: TaskStruct = .{ .state = TASK_RUNNING, .parent = &parent };
    zombify_and_wake_parent(&child);
    try std.testing.expectEqual(TASK_ZOMBIE, child.state);
    try std.testing.expectEqual(TASK_ZOMBIE, parent.state);
}

test "zombify_and_wake_parent: null parent does not crash" {
    var child: TaskStruct = .{ .state = TASK_RUNNING, .parent = null };
    zombify_and_wake_parent(&child);
    try std.testing.expectEqual(TASK_ZOMBIE, child.state);
}
