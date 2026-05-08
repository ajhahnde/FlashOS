// Scheduler — round-robin with priority counters.
// All extern-struct layouts (TaskStruct, CoreContext, MmStruct, UserPage,
// KeRegs) live in src/task_layout.zig as the single source of truth.
// The .S files (sched.S, entry.S) consume those layouts via raw offsets.

const layout = @import("task_layout.zig");
const TaskStruct = layout.TaskStruct;
const TASK_RUNNING = layout.TASK_RUNNING;
const TASK_ZOMBIE = layout.TASK_ZOMBIE;
const TASK_INTERRUPTIBLE = layout.TASK_INTERRUPTIBLE;
const KTHREAD = layout.KTHREAD;
const MAX_PAGE_COUNT = layout.MAX_PAGE_COUNT;

const NR_TASKS: usize = 64;

extern fn core_switch_to(prev: *TaskStruct, next: *TaskStruct) void;
extern fn set_pgd(pgd: u64) void;
extern fn irq_enable() void;
extern fn irq_disable() void;
extern fn free_page(p: u64) void;
extern fn free_kernel_page(kp: u64) void;

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

export fn _schedule() void {
    preempt_disable();
    var next: usize = 0;
    var c: i64 = 0;

    outer: while (true) {
        c = -1;
        next = 0;
        var i: usize = 0;
        while (i < NR_TASKS) : (i += 1) {
            if (task[i]) |p| {
                if (p.state == TASK_RUNNING and p.counter > c) {
                    c = p.counter;
                    next = i;
                }
            }
        }
        if (c != 0) break :outer;
        i = 0;
        while (i < NR_TASKS) : (i += 1) {
            if (task[i]) |p| {
                p.counter = (p.counter >> 1) + p.priority;
            }
        }
    }
    switch_to(task[next].?);
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
    preempt_disable();
    current.?.state = TASK_ZOMBIE;
    // Wake a parent that's blocked in sys_wait; reaping itself is unsafe
    // here because the kernel page IS the running task's stack + TaskStruct.
    if (current.?.parent) |p| {
        if (p.state == TASK_INTERRUPTIBLE) p.state = TASK_RUNNING;
    }
    preempt_enable();
    schedule();
}

// Walk task[] for any child of `current`. If a zombie is found, free its
// resources and return its pid. If children exist but none are zombies,
// block (TASK_INTERRUPTIBLE) and retry on wake. Returns -1 if no children.
export fn do_wait() i32 {
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
