// Syscall dispatch table and handlers
// Layouts (TaskStruct etc.) come from src/task_layout.zig — the single
// source of truth shared with sched.zig / fork.zig / mm_user.zig.

const layout = @import("task_layout.zig");
const TaskStruct = layout.TaskStruct;
const TASK_RUNNING = layout.TASK_RUNNING;
const TASK_ZOMBIE = layout.TASK_ZOMBIE;
const TASK_INTERRUPTIBLE = layout.TASK_INTERRUPTIBLE;
const UTHREAD = layout.UTHREAD;
const MAX_PAGE_COUNT = layout.MAX_PAGE_COUNT;

const MU: i32 = 0;
const NR_TASKS: usize = 64;
const PAGE_SIZE: u64 = 1 << 12;

extern var current: ?*TaskStruct;
extern var task: [NR_TASKS]?*TaskStruct;
extern fn preempt_disable() void;
extern fn preempt_enable() void;

extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn copy_process(clone_flags: u64, fn_ptr: u64, arg: u64) i32;
extern fn exit_process() void;
extern fn do_wait() i32;
extern fn dump_free_count() u64;
extern fn get_free_page() u64;
extern fn free_page(p: u64) void;
extern fn memcpy(dst: [*]u64, src: [*]const u64, bytes: u64) void;
extern fn prepare_move_to_user(start_addr: u64, size: u64, fn_offset: u64) i32;

// Syscalls run at EL1h with TTBR0 holding the *user* pgd (set by
// prepare_move_to_user). To survive the dispatch we route through TTBR1
// by ORing each function pointer with LINEAR_MAP_BASE so the `blr` in
// el0_svc lands in the kernel's high-mem mapping. This replaces the
// previous (broken) `cur + &_start` formula, which doubled the address
// off into .bss.
const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

// SYS CALL PROCESS CONTROL
export fn sys_fork() i32 {
    return copy_process(UTHREAD, 0, 0);
}
// Replace the current task's address space with `blob_size` bytes copied from
// user-VA `blob_addr` (must reach into the OLD user pgd while it's still
// installed in TTBR0). Steps:
//   1. Snapshot the blob into a kernel-owned page. get_free_page zeroes
//      pages, so freeing first and reading later would race the new pgd's
//      sub-table allocations clobbering the bytes we still need.
//   2. Free old user_pages[*].pa and kernel_pages[*] (mirrors do_wait's
//      cleanup). Zero current.mm so allocate_user_page rebuilds pgd + tables
//      from scratch on the next call.
//   3. prepare_move_to_user allocates a fresh user page at uva 0, memcpys
//      the snapshot in, set_pgd's TTBR0 to the new pgd (with TLB flush),
//      and overwrites the syscall's KeRegs frame so kernel_exit erets to
//      elr=0 / pstate=EL0t / sp=USER_SP_INIT_POS in EL0.
//   4. Free the snapshot page. Net page balance is identical to before exec.
// Returns 0 on success (the caller's PC after svc is unreachable; eret jumps
// to the new uva 0). Returns -1 on bad args or alloc failure.
export fn sys_exec(blob_addr: u64, blob_size: u64) i32 {
    if (blob_size == 0 or blob_size > PAGE_SIZE) return -1;
    const c = current orelse return -1;

    const buf_pa = get_free_page();
    if (buf_pa == 0) return -1;
    const buf_kva = buf_pa | LINEAR_MAP_BASE;
    memcpy(@ptrFromInt(buf_kva), @ptrFromInt(blob_addr), blob_size);

    var i: usize = 0;
    while (i < MAX_PAGE_COUNT) : (i += 1) {
        const pa = c.mm.user_pages[i].pa;
        if (pa != 0) free_page(pa);
        c.mm.user_pages[i] = .{};
    }
    i = 0;
    while (i < MAX_PAGE_COUNT) : (i += 1) {
        const kp = c.mm.kernel_pages[i];
        if (kp != 0) free_page(kp);
        c.mm.kernel_pages[i] = 0;
    }
    c.mm.pgd = 0;

    const ret = prepare_move_to_user(buf_kva, blob_size, 0);
    free_page(buf_pa);
    return ret;
}
export fn sys_wait() i32 {
    return do_wait();
}
export fn sys_exit() void {
    exit_process();
}
// Walk task[] under preempt_disable for a matching .pid. On hit: flip to
// TASK_ZOMBIE and wake any TASK_INTERRUPTIBLE parent (mirrors exit_process
// in sched.zig). The slot stays occupied; the parent's existing do_wait
// reaps it (frees user/kernel pages + the kernel page itself). Returns 0
// on hit, -1 on miss. Self-kill is rejected — the running task is its own
// kernel page; sys_exit is the safe self-cancel path.
export fn sys_kill(pid: i32) i32 {
    if (current) |c| {
        if (c.pid == pid) return -1;
    }

    preempt_disable();
    var i: usize = 0;
    while (i < NR_TASKS) : (i += 1) {
        if (task[i]) |t| {
            if (t.pid == pid) {
                t.state = TASK_ZOMBIE;
                if (t.parent) |p| {
                    if (p.state == TASK_INTERRUPTIBLE) p.state = TASK_RUNNING;
                }
                preempt_enable();
                return 0;
            }
        }
    }
    preempt_enable();
    return -1;
}
export fn sys_dump_free() u64 {
    return dump_free_count();
}

// SYS CALL FILE SYSTEM
export fn sys_openFile() void {}
export fn sys_readFile() void {}
export fn sys_writeFile() void {}
export fn sys_seek() void {}
export fn sys_closeFile() void {}

// MEMORY MANAGEMENT
export fn sys_brk() void {}
export fn sys_sbrk() void {}
export fn sys_mmap() void {}
export fn sys_munmap() void {}
export fn sys_mlock() void {}
export fn sys_munlock() void {}

// Interprocess Communication
export fn sys_pipe() void {}
export fn sys_socket() void {}
export fn sys_msgget() void {}
export fn sys_semget() void {}
export fn sys_shmget() void {}

// Device Management
export fn sys_openConsole() void {}
export fn sys_readConsole() void {}
export fn sys_writeConsole(buf: [*:0]const u8) void {
    main_output(MU, buf);
}
export fn sys_setConsoleMode() void {}
export fn sys_closeConsole() void {}

/// Syscall dispatch table — referenced from entry.S (`adr x27, sys_call_table`).
/// Indices 0..6 are the user-space ABI (write/fork/exit/wait/dump_free/exec/kill)
/// and must match SYS_*_NUM in user_space/init.zig and NR_SYSCALLS in
/// src/asm_defs.inc. Anything past index 6 is unreachable today
/// (NR_SYSCALLS=7 caps dispatch via `b.hs` in entry.S) and reserved for
/// future syscalls.
export var sys_call_table = [_]?*const anyopaque{
    // User-space ABI (entry.S checks against NR_SYSCALLS)
    @ptrCast(&sys_writeConsole), // 0 — SYS_WRITE_NUM
    @ptrCast(&sys_fork),         // 1 — SYS_FORK_NUM
    @ptrCast(&sys_exit),         // 2 — SYS_EXIT_NUM
    @ptrCast(&sys_wait),         // 3 — SYS_WAIT_NUM
    @ptrCast(&sys_dump_free),    // 4 — SYS_DUMP_FREE_NUM (debug instrumentation; powers the test harness's leak check)
    @ptrCast(&sys_exec),         // 5 — SYS_EXEC_NUM
    @ptrCast(&sys_kill),         // 6 — SYS_KILL_NUM

    @ptrCast(&sys_openFile),
    @ptrCast(&sys_readFile),
    @ptrCast(&sys_writeFile),
    @ptrCast(&sys_seek),
    @ptrCast(&sys_closeFile),

    @ptrCast(&sys_brk),
    @ptrCast(&sys_sbrk),
    @ptrCast(&sys_mmap),
    @ptrCast(&sys_munmap),
    @ptrCast(&sys_mlock),
    @ptrCast(&sys_munlock),

    @ptrCast(&sys_pipe),
    @ptrCast(&sys_socket),
    @ptrCast(&sys_msgget),
    @ptrCast(&sys_semget),
    @ptrCast(&sys_shmget),

    @ptrCast(&sys_openConsole),
    @ptrCast(&sys_readConsole),
    @ptrCast(&sys_setConsoleMode),
    @ptrCast(&sys_closeConsole),
};

const NR_SYSCALLS: usize = sys_call_table.len;

/// Map each syscall function pointer to its high-mem (TTBR1) alias so
/// el0_svc can `blr` through the table after the user pgd has been
/// installed in TTBR0.
export fn sys_call_table_relocate() void {
    var i: usize = 0;
    while (i < NR_SYSCALLS) : (i += 1) {
        const cur: u64 = @intFromPtr(sys_call_table[i]);
        sys_call_table[i] = @ptrFromInt(cur | LINEAR_MAP_BASE);
    }
}
