// Syscall dispatch table and handlers
// Layouts (TaskStruct etc.) come from src/task_layout.zig — the single
// source of truth shared with sched.zig / fork.zig / mm_user.zig.
// Syscall IDs come from lib/syscall_defs.zig — the single source of
// truth shared with user_space/kernel_tests.zig.

const std = @import("std");
const layout = @import("task_layout");
const defs = @import("syscall_defs");
const user_layout = @import("user_layout");
const pipe_mod = @import("pipe");
const console = @import("console");
const sched = @import("sched");
const vfs = @import("vfs");
const file_mod = @import("file");
const TaskStruct = layout.TaskStruct;
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
                sched.zombify_and_wake_parent(t);
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
//
// All four handlers dispatch through the VFS shim (v0.4.0):
// sys_openFile resolves the path via vfs.vfs_open and stashes the
// backing superblock in File.sb; read/seek/close re-cast that opaque
// pointer and call through the backend vtable. The per-backend
// arithmetic (initramfs's pointer walk, FAT32's cluster chains) lives
// in the backend modules — these handlers are thin dispatchers.
//
// FIXME: no copy_from_user yet — same posture as
// sys_pipe_write (path/buf are dereferenced as kernel-walkable user
// pointers). A bad pointer faults into do_data_abort and zombies the
// task.

// Re-type File.sb (an `?*anyopaque`, opaque to break the vfs<->file
// import cycle) back to `*vfs.SuperBlock` for vtable dispatch.
inline fn vfsSb(f: *file_mod.File) ?*vfs.SuperBlock {
    const raw = f.sb orelse return null;
    return @ptrCast(@alignCast(raw));
}

export fn sys_openFile(path_ptr: u64) i32 {
    const c = current orelse return -1;

    const path_bytes: [*:0]const u8 = @ptrFromInt(path_ptr);
    // SMP-audit: slice borrows EL0 memory; no yield between span()
    // and the final use, so on single-core the backing UVA can't be
    // freed mid-walk. Revisit for the future SMP audit.
    const path = std.mem.span(path_bytes);

    var open_result: vfs.OpenResult = .{};
    const sb = vfs.vfs_open(path, &open_result) orelse return -1;

    const f = file_mod.alloc() orelse return -1;
    f.refs = 1;
    f.private = open_result.private;
    f.size = open_result.size;
    f.offset = 0;
    f.sb = sb;

    const fd = file_mod.fdAlloc(c, f);
    if (fd < 0) {
        file_mod.unref(f);
        return -1;
    }
    return fd;
}

export fn sys_readFile(fd: i32, buf: u64, len: u64) i64 {
    const c = current orelse return -1;
    const f = file_mod.fdGet(c, fd) orelse return -1;
    const sb = vfsSb(f) orelse return -1;
    return vfs.vfs_read(sb, f, @ptrFromInt(buf), len);
}

// FAT32 write — stable ABI (v0.4.0). Mirrors
// sys_readFile: resolve fd -> SuperBlock -> vfs.vfs_write. The
// backend's writeBack does the cluster-allocate / FAT-update /
// dir-entry-update / FSInfo-update; initramfs's vtable returns -1
// (EROFS). Returns bytes written, or -1 on bad fd / no backend /
// I/O error.
export fn sys_writeFile(fd: i32, buf: u64, len: u64) i64 {
    const c = current orelse return -1;
    const f = file_mod.fdGet(c, fd) orelse return -1;
    const sb = vfsSb(f) orelse return -1;
    return vfs.vfs_write(sb, f, @ptrFromInt(buf), len);
}

export fn sys_seek(fd: i32, off: i64, whence: i32) i64 {
    const c = current orelse return -1;
    const f = file_mod.fdGet(c, fd) orelse return -1;
    const sb = vfsSb(f) orelse return -1;
    return vfs.vfs_seek(sb, f, off, whence);
}

export fn sys_closeFile(fd: i32) i32 {
    const c = current orelse return -1;
    const f = file_mod.fdGet(c, fd) orelse return -1;
    if (vfsSb(f)) |sb| vfs.vfs_close(sb, f);
    return file_mod.fdClose(c, fd);
}

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
//
// Anonymous-pipe ABI (v0.3.0). Slot map in lib/syscall_defs.zig.
// `sys_pipe` returns both fds in a single i64: low 32 bits = read fd,
// high 32 bits = write fd. Negative on out-of-fds / alloc-failure.
// Compact ABI keeps the user-side wrapper to one register and avoids
// a copy_to_user for the pair.
//
// FIXME: no copy_from_user / copy_to_user yet — `buf` is
// dereferenced as a kernel-walkable user pointer (current TTBR0). A
// bad pointer faults through do_data_abort and zombies the task,
// which the parent's sys_wait reaps as usual; same behaviour as the
// other byte-level syscalls (sys_write etc.).
export fn sys_pipe() i64 {
    const c = current orelse return -1;
    const p = pipe_mod.alloc() orelse return -1;
    p.refs = 2; // one ref per fd installed below

    const rfd = pipe_mod.fdAlloc(c, p);
    if (rfd < 0) {
        // Two unrefs because we bumped refs to 2 above before either
        // fd was actually installed; the page leaks otherwise.
        pipe_mod.unref(p);
        pipe_mod.unref(p);
        return -1;
    }
    const wfd = pipe_mod.fdAlloc(c, p);
    if (wfd < 0) {
        c.fd_table[@intCast(rfd)] = null;
        pipe_mod.unref(p);
        pipe_mod.unref(p);
        return -1;
    }
    return (@as(i64, wfd) << 32) | (@as(i64, rfd) & 0xffff_ffff);
}

export fn sys_pipe_read(fd: i32, buf: u64, len: u64) i64 {
    const c = current orelse return -1;
    const p = pipe_mod.fdGet(c, fd) orelse return -1;
    return pipe_mod.read(p, @ptrFromInt(buf), len);
}

export fn sys_pipe_write(fd: i32, buf: u64, len: u64) i64 {
    const c = current orelse return -1;
    const p = pipe_mod.fdGet(c, fd) orelse return -1;
    return pipe_mod.write(p, @ptrFromInt(buf), len);
}

export fn sys_pipe_close(fd: i32) i32 {
    const c = current orelse return -1;
    return pipe_mod.fdClose(c, fd);
}

export fn sys_socket() void {}
export fn sys_msgget() void {}
export fn sys_semget() void {}
export fn sys_shmget() void {}

// Device Management
//
// Console ABI (v0.3.0). Pipe-fds and console-fds coexist
// separately until they're unified behind a single
// read(fd,buf,len) / write(fd,buf,len) dispatcher backed by the
// fd-table tagged-pointer scheme.
//
// FIXME: collapse the parallel console / pipe ABI families
// once the fd-table grows tagged pointers — sys_readConsole and
// sys_pipe_read should fold into a single dispatch keyed on the
// fd's type tag, same for write/close. Until then the user picks
// the right wrapper by hand.
//
// sys_openConsole returns a synthetic fd: 0 = stdin, 1 = stdout,
// negative on bad mode. Not installed in any fd_table — future
// work unifies. Until then user code passes the returned fd
// straight back into sys_readConsole / sys_writeConsole as a no-op
// hint (the kernel-side handlers don't look at it).
export fn sys_openConsole(mode: i32) i32 {
    return switch (mode) {
        0 => 0,
        1 => 1,
        else => -1,
    };
}

// Blocks until at least one byte is available, then drains up to
// `len` bytes (short reads — see src/console.zig:console_read).
// Returns the count copied. i64 return matches sys_pipe_read so a
// future unified `sys_read` can hand both ends through the same
// signature.
export fn sys_readConsole(buf: u64, len: u64) i64 {
    return console.console_read(@ptrFromInt(buf), len);
}

export fn sys_writeConsole(buf: [*:0]const u8) void {
    main_output(MU, buf);
}

// Inert stubs — future work wires real mode flips (line / raw /
// O_NONBLOCK) and fd-table teardown once the unified read/write
// dispatcher lands.
export fn sys_setConsoleMode() void {}
export fn sys_closeConsole() void {}

// FIXME: debug-only — not part of the stable ABI.
// Pushes one byte into the kernel RX ring as if it had arrived on
// the UART. Powers deterministic [TEST] console-echo coverage on
// QEMU where there is no external input driver, and remains
// permanently mounted as a debug surface analogous to
// sys_dump_free. Document as debug-only in DOCUMENTATION.md §5 and
// remove once a real host-input driver lands.
export fn sys_console_inject(byte: u64) void {
    console.console_test_push(@truncate(byte));
}

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
    var t = [_]?*const anyopaque{null} ** 31;

    t[defs.SYS_WRITE]     = @ptrCast(&sys_writeConsole);
    t[defs.SYS_FORK]      = @ptrCast(&sys_fork);
    t[defs.SYS_EXIT]      = @ptrCast(&sys_exit);
    t[defs.SYS_WAIT]      = @ptrCast(&sys_wait);
    t[defs.SYS_DUMP_FREE] = @ptrCast(&sys_dump_free);
    t[defs.SYS_EXEC]      = @ptrCast(&sys_exec);
    t[defs.SYS_KILL]      = @ptrCast(&sys_kill);

    t[defs.SYS_OPEN_FILE]  = @ptrCast(&sys_openFile);
    t[defs.SYS_READ_FILE]  = @ptrCast(&sys_readFile);
    t[defs.SYS_WRITE_FILE] = @ptrCast(&sys_writeFile);
    t[defs.SYS_SEEK]       = @ptrCast(&sys_seek);
    t[defs.SYS_CLOSE_FILE] = @ptrCast(&sys_closeFile);

    t[defs.SYS_BRK]  = @ptrCast(&sys_brk);
    t[defs.SYS_SBRK] = @ptrCast(&sys_sbrk);
    t[14] = @ptrCast(&sys_mmap);
    t[15] = @ptrCast(&sys_munmap);
    t[16] = @ptrCast(&sys_mlock);
    t[17] = @ptrCast(&sys_munlock);

    t[defs.SYS_PIPE] = @ptrCast(&sys_pipe);
    t[19] = @ptrCast(&sys_socket);
    t[20] = @ptrCast(&sys_msgget);
    t[21] = @ptrCast(&sys_semget);
    t[22] = @ptrCast(&sys_shmget);

    t[defs.SYS_OPEN_CONSOLE]      = @ptrCast(&sys_openConsole);
    t[defs.SYS_READ_CONSOLE]      = @ptrCast(&sys_readConsole);
    t[defs.SYS_SET_CONSOLE_MODE]  = @ptrCast(&sys_setConsoleMode);
    t[defs.SYS_CLOSE_CONSOLE]     = @ptrCast(&sys_closeConsole);

    t[defs.SYS_PIPE_READ]  = @ptrCast(&sys_pipe_read);
    t[defs.SYS_PIPE_WRITE] = @ptrCast(&sys_pipe_write);
    t[defs.SYS_PIPE_CLOSE] = @ptrCast(&sys_pipe_close);

    t[defs.SYS_CONSOLE_INJECT] = @ptrCast(&sys_console_inject);

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
