// Syscall dispatch table and handlers
// Layouts (TaskStruct etc.) come from src/task_layout.zig — the single
// source of truth shared with sched.zig / fork.zig / mm_user.zig.
// Syscall IDs come from lib/syscall_defs.zig — the single source of
// truth shared with user_space/kernel_tests.zig.

const layout = @import("task_layout.zig");
const defs = @import("syscall_defs");
const user_layout = @import("user_layout");
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
extern fn prepare_move_to_user_elf(blob_addr_kva: u64, blob_size: u64) i32;
extern fn unmap_user_range(t: *TaskStruct, start_uva: u64, end_uva: u64) void;
extern fn set_pgd(pgd: u64) void;

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
// `blob_addr` (must reach into either the OLD user pgd via TTBR0 for blob
// callers, or TTBR1 for kernel-staged ELFs — both work because EL1 walks
// both halves). Steps:
//   1. Snapshot the blob into a kernel-owned page. get_free_page zeroes
//      pages, so freeing first and reading later would race the new pgd's
//      sub-table allocations clobbering the bytes we still need.
//   2. Free old user_pages[*].pa and kernel_pages[*] (mirrors do_wait's
//      cleanup). Zero current.mm so allocate_user_page rebuilds pgd + tables
//      from scratch on the next call.
//   3. Sniff the snapshot for ELF magic. If present, dispatch to
//      prepare_move_to_user_elf (parses + maps PT_LOAD segments + stack,
//      sets elr=e_entry / sp=STACK_TOP). Otherwise fall through to the
//      historical blob path (single page at uva 0, sp=USER_SP_INIT_POS).
//      Either way set_pgd installs the new pgd in TTBR0 with a TLB flush
//      and overwrites the syscall's KeRegs frame so kernel_exit erets
//      into the new image.
//   4. Free the snapshot page. Net page balance is identical to before exec.
// Returns 0 on success (the caller's PC after svc is unreachable; eret jumps
// to the new entry). Returns -1 on bad args, alloc failure, or ELF parse
// rejection.
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

    const buf_bytes: [*]const u8 = @ptrFromInt(buf_kva);
    const is_elf = blob_size >= 4 and
        buf_bytes[0] == 0x7f and
        buf_bytes[1] == 'E' and
        buf_bytes[2] == 'L' and
        buf_bytes[3] == 'F';

    const ret: i32 = if (is_elf)
        prepare_move_to_user_elf(buf_kva, blob_size)
    else
        prepare_move_to_user(buf_kva, blob_size, 0);

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

// Set the heap break to `addr` (rounded up to the next page boundary).
// Returns the new break, or the current break if `addr == 0`. Returns
// -1 on out-of-range requests (below HEAP_BASE, or above
// STACK_TOP - STACK_BUDGET — the latter is the stack-budget upper
// bound shared with mm_user.zig's do_data_abort guard logic).
//
// No pages are eagerly allocated on grow — touching a page in the new
// range faults through do_data_abort and demand-allocates. On shrink
// the released pages MUST be freed here (the per-process do_wait reap
// loop only runs at process exit, so a long-lived process that grows
// then shrinks would leak otherwise); unmap_user_range walks
// `mm.user_pages` for entries in [new_brk, old_brk) and clears the
// PTE + frees the PA + zeros the slot. set_pgd at the tail flushes the
// TLB so a re-grow re-faults cleanly.
export fn sys_brk(addr: u64) i64 {
    const c = current orelse return -1;
    if (addr == 0) return @bitCast(c.mm.brk);

    const new_brk: u64 = (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    if (new_brk < user_layout.HEAP_BASE) return -1;
    if (new_brk > user_layout.STACK_TOP - user_layout.STACK_BUDGET) return -1;

    const old_brk: u64 = c.mm.brk;
    if (new_brk < old_brk) {
        unmap_user_range(c, new_brk, old_brk);
        // Re-install the same pgd to drive the full-TLB-flush path
        // in set_pgd (sched.S). Targeted `tlbi vae1is` would be the
        // surgical option; the heap-shrink path is rare enough that
        // the existing big hammer is fine.
        set_pgd(c.mm.pgd);
    }
    c.mm.brk = new_brk;
    return @bitCast(new_brk);
}

// Convenience wrapper: brk(current_break + delta), returns the previous
// break. Negative `delta` shrinks. The sys_brk path itself enforces
// bounds (HEAP_BASE / STACK_TOP - user_layout.STACK_BUDGET); sbrk only
// guards against signed-overflow on the addition.
export fn sys_sbrk(delta: i64) i64 {
    const c = current orelse return -1;
    const cur_brk: u64 = c.mm.brk;
    const cur_signed: i64 = @bitCast(cur_brk);
    const new_signed = @addWithOverflow(cur_signed, delta);
    if (new_signed[1] != 0) return -1;
    if (new_signed[0] < 0) return -1;
    const target: u64 = @bitCast(new_signed[0]);
    const ret = sys_brk(target);
    if (ret < 0) return -1;
    return @bitCast(cur_brk);
}

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
/// Slots 0..6 are the user-facing ABI; their slot ↔ constant binding is
/// compiler-enforced via the indexed `t[defs.SYS_*]` writes below — a
/// renumbering in lib/syscall_defs.zig propagates here automatically and
/// any duplicate id would overwrite (and any gap would leave a null that
/// still traps cleanly through the unreachable kernel code path). The
/// upper dispatch bound is NR_SYSCALLS in src/asm_defs_common.inc (`b.hs`
/// in entry.S); keep it in lockstep with the highest user-facing id +1.
/// Anything past index 6 is unreachable today and reserved for future
/// syscalls — those slots stay positional until they get their own
/// SYS_* constant in lib/syscall_defs.zig.
export var sys_call_table = blk: {
    var t = [_]?*const anyopaque{null} ** 27;

    t[defs.SYS_WRITE]     = @ptrCast(&sys_writeConsole);
    t[defs.SYS_FORK]      = @ptrCast(&sys_fork);
    t[defs.SYS_EXIT]      = @ptrCast(&sys_exit);
    t[defs.SYS_WAIT]      = @ptrCast(&sys_wait);
    t[defs.SYS_DUMP_FREE] = @ptrCast(&sys_dump_free);
    t[defs.SYS_EXEC]      = @ptrCast(&sys_exec);
    t[defs.SYS_KILL]      = @ptrCast(&sys_kill);

    t[7]  = @ptrCast(&sys_openFile);
    t[8]  = @ptrCast(&sys_readFile);
    t[9]  = @ptrCast(&sys_writeFile);
    t[10] = @ptrCast(&sys_seek);
    t[11] = @ptrCast(&sys_closeFile);

    t[defs.SYS_BRK]  = @ptrCast(&sys_brk);
    t[defs.SYS_SBRK] = @ptrCast(&sys_sbrk);
    t[14] = @ptrCast(&sys_mmap);
    t[15] = @ptrCast(&sys_munmap);
    t[16] = @ptrCast(&sys_mlock);
    t[17] = @ptrCast(&sys_munlock);

    t[18] = @ptrCast(&sys_pipe);
    t[19] = @ptrCast(&sys_socket);
    t[20] = @ptrCast(&sys_msgget);
    t[21] = @ptrCast(&sys_semget);
    t[22] = @ptrCast(&sys_shmget);

    t[23] = @ptrCast(&sys_openConsole);
    t[24] = @ptrCast(&sys_readConsole);
    t[25] = @ptrCast(&sys_setConsoleMode);
    t[26] = @ptrCast(&sys_closeConsole);

    break :blk t;
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
