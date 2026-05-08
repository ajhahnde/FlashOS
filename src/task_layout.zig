// Canonical extern-struct layouts shared between kernel modules.
//
// Before this file existed, TaskStruct / CoreContext / MmStruct / UserPage /
// KeRegs were duplicated as private mirrors across sched.zig, sys.zig,
// fork.zig, mm_user.zig, utilc.zig, and trace/utils.zig. The mirrors had
// already drifted (mm_user/utilc/trace were missing the `parent` and
// `pid` fields), which is exactly the silent layout-drift bug the
// per-file `extern struct` discipline was meant to prevent.
//
// This module is the single source of truth. Every kernel module that
// needs any of these layouts `@import`s and aliases — never redeclares.
// Default values are set so `Foo{}` literals work; consumers that need
// non-default fields override at the construction site.
//
// The .S files (sched.S, entry.S, irq.S) consume these layouts through
// raw offsets. If you reorder fields here, audit the asm side too.

pub const MAX_PAGE_COUNT: usize = 16;

// Process state values (mirrored from sched.zig consumers).
pub const TASK_RUNNING: i64 = 0;
pub const TASK_ZOMBIE: i64 = 1;
pub const TASK_INTERRUPTIBLE: i64 = 2;

// Task `flags` bits.
pub const KTHREAD: u64 = 1;
pub const UTHREAD: u64 = 0;

pub const CoreContext = extern struct {
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    fp: u64 = 0,
    sp: u64 = 0,
    lr: u64 = 0,
};

pub const UserPage = extern struct {
    pa: u64 = 0,
    uva: u64 = 0,
};

pub const MmStruct = extern struct {
    pgd: u64 = 0,
    user_pages: [MAX_PAGE_COUNT]UserPage = [_]UserPage{.{}} ** MAX_PAGE_COUNT,
    kernel_pages: [MAX_PAGE_COUNT]u64 = [_]u64{0} ** MAX_PAGE_COUNT,
};

pub const TaskStruct = extern struct {
    core_context: CoreContext = .{},
    state: i64 = 0,
    counter: i64 = 0,
    priority: i64 = 1,
    preempt_count: i64 = 0,
    flags: u64 = 0,
    mm: MmStruct = .{},
    // Parent pointer for sys_wait. init_task has no parent.
    // Appended last (after mm) so sched.S — which only reads
    // core_context at offset 0 — is unaffected.
    parent: ?*TaskStruct = null,
    // Monotonic pid, decoupled from the task[] slot index now that
    // do_wait frees slots and copy_process reuses them. Required so
    // sys_kill(pid) can't race a reap+reuse and target the wrong
    // process.
    pid: i32 = 0,
};

pub const KeRegs = extern struct {
    regs: [31]u64 = [_]u64{0} ** 31,
    sp: u64 = 0,
    elr: u64 = 0,
    pstate: u64 = 0,
};
