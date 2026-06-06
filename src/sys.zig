// sys: syscall dispatch table and handlers.
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
const fdtable = @import("fdtable");
const path_mod = @import("path");
const klog_ring = @import("klog_ring");
const sha256 = @import("sha256");
const shadow = @import("shadow");
const perm = @import("perm");
const pwfile = @import("pwfile");
// Kernel entropy source (salt minting for sys_passwd). Path import —
// hwrng.zig shares the kernel root module (start.zig force-includes it
// for the exported hwrng_init), same pattern as board.zig below.
const hwrng = @import("hwrng.zig");
// USB-C gadget console: board bag, for the console_tx mux below.
// Path-import — sys.zig shares the kernel root module with board.zig
// (kernel.zig imports it the same way). No cycle: board's driver modules
// reach the kernel via `extern fn main_output`, they never @import sys.
const board = @import("board.zig");
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
// Body lives in src/execve.zig; sys_execve below is the dispatch-table
// wrapper. Activates the real path-resolve → stream-PT_LOAD →
// encode-argv flow.
extern fn execve_impl(path_ptr: u64, argv_ptr: u64) i32;
extern fn unmap_user_range(t: *TaskStruct, start_uva: u64, end_uva: u64) void;
extern fn set_pgd(pgd: u64) void;
extern fn check_and_prefault_user_range(uva: u64, len: u64) i32;
extern fn copy_from_user(kbuf: [*]u8, uva: u64, len: u64) i32;
extern fn copy_to_user(uva: u64, kbuf: [*]const u8, len: u64) i32;

const builtin = @import("builtin");

// Syscalls run at EL1h with TTBR0 holding the *user* pgd (set by
// prepare_move_to_user_elf). Each function pointer is ORed with
// LINEAR_MAP_BASE so the `blr` in el0_svc lands in the kernel's
// high-mem mapping. Replaces the earlier broken `cur + &_start`
// formula, which doubled the address into .bss.
const LINEAR_MAP_BASE: u64 = if (builtin.target.os.tag == .freestanding) 0xFFFF000000000000 else 0;

// Console echo flags. Default off preserves the historical
// split — the kernel never echoes, userland readline owns echo (so fsh is
// unaffected). SYS_SET_CONSOLE_MODE flips them; when echo is on,
// readConsoleBytes echoes drained printable bytes, and when mask is on it
// echoes a '*' per printable byte instead (password masking). /bin/login
// turns echo on for the username prompt and mask on for the password, then
// leaves both off before exec'ing the shell.
var console_echo: bool = false;
var console_mask: bool = false;

// SYS CALL PROCESS CONTROL
export fn sys_fork() i32 {
    return copy_process(UTHREAD, 0, 0);
}
// Path-resolved ELF loader. Thin wrapper over execve_impl
// in src/execve.zig — keeps the dispatch-table binding adjacent to
// the other process-control syscalls. x0 = path_ptr (NUL-terminated
// absolute UVA), x1 = argv_ptr (UVA of NULL-terminated argv array).
// Returns 0 (does-not-return on success — eret jumps to e_entry),
// -1 on resolve / parse / alloc / argv-fault failure.
export fn sys_execve(path_ptr: u64, argv_ptr: u64) i32 {
    return execve_impl(path_ptr, argv_ptr);
}
export fn sys_wait() i32 {
    return do_wait();
}
export fn sys_exit() void {
    exit_process();
}
// SYS_REBOOT — reset the board. board.power.reboot() is the per-board
// reset (PSCI SYSTEM_RESET on virt, the BCM2711 watchdog on rpi4b) and
// never returns, so neither does this handler: el0_svc never reaches the
// eret back to the caller. EL0 cannot do this itself (privileged SMC /
// MMIO), which is why it is a syscall. No privilege gate yet.
export fn sys_reboot() noreturn {
    board.power.reboot();
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
// File access dispatches through the VFS layer: sys_openFile
// resolves the path via vfs.vfs_open and stashes the backing superblock
// in File.sb; seek and the unified read/write/close re-cast that opaque
// pointer (vfsSb) and call through the backend vtable. The per-backend
// arithmetic (initramfs's pointer walk, FAT32's cluster chains) lives
// in the backend modules — these handlers are thin dispatchers.
//
// User pointers (path / buf) reach the kernel through copy_from_user /
// copy_to_user. A wild UVA returns -1 to the caller via the soft path
// in mm_user.check_and_prefault_user_range; the task does NOT zombify.

// Re-type File.sb (an `?*anyopaque`, opaque to break the vfs<->file
// import cycle) back to `*vfs.SuperBlock` for vtable dispatch.
inline fn vfsSb(f: *file_mod.File) ?*vfs.SuperBlock {
    const raw = f.sb orelse return null;
    return @ptrCast(@alignCast(raw));
}

// sys_openFile + joinResolve form the deepest kernel-stack chain on the
// syscall path. The two path scratch buffers live as preempt-guarded
// module statics rather than ~1.3 KiB of stack locals: the kernel stack
// grows down toward the TaskStruct credential tail in the same page, so a
// stack-heavy open could descend into uid/gid/euid/egid and a timer IRQ
// taken in that window would save its register frame straight over the
// credentials. Keeping the buffers off the stack bounds the frame well
// clear of the creds. preempt_disable serialises the shared statics across
// the whole resolve + open; the defer covers every early-return error path.
var open_path_buf: [1024]u8 = undefined;
var open_join_buf: [layout.CWD_SIZE]u8 = undefined;

export fn sys_openFile(path_ptr: u64) i32 {
    const c = current orelse return -1;

    preempt_disable();
    defer preempt_enable();

    var i: usize = 0;
    while (i < 1023) : (i += 1) {
        var b: u8 = 0;
        if (copy_from_user(@ptrCast(&b), path_ptr + i, 1) < 0) return -1;
        open_path_buf[i] = b;
        if (b == 0) break;
    }
    open_path_buf[i] = 0;
    const raw_path = std.mem.span(@as([*:0]const u8, @ptrCast(&open_path_buf)));

    // Relative paths (no leading '/') are joined against current.cwd
    // and `.` / `..` collapsed into a kernel scratch buffer; absolute
    // paths pass straight through. The post-join slice is what vfs
    // (still absolute-only) sees. The pure helper is host-tested. Join
    // buffer is sized to one CWD_SIZE — over-long resolved paths
    // (cwd 256B + rel 256B before collapse) return -1.
    const resolved: []const u8 = if (raw_path.len > 0 and raw_path[0] == '/')
        raw_path
    else blk: {
        const cwd_slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&c.cwd)), 0);
        break :blk path_mod.joinResolve(cwd_slice, raw_path, &open_join_buf) orelse return -1;
    };

    var open_result: vfs.OpenResult = .{};
    const sb = vfs.vfs_open(resolved, &open_result);

    if (sb == null) return -1;

    // Permission gate: open is read-intent (this ABI has no
    // open flags — write permission is re-checked per write). A denied
    // read returns -EACCES, distinguishable from the -1 miss above, and
    // costs no File page since the check runs before the alloc.
    if (!perm.checkAccess(
        open_result.mode,
        open_result.uid,
        open_result.gid,
        c.euid,
        c.egid,
        .read,
    )) return -defs.EACCES;

    const f = file_mod.alloc() orelse return -1;
    f.refs = 1;
    f.private = open_result.private;
    f.size = open_result.size;
    f.offset = 0;
    f.sb = sb;
    // Carry the backend's permission metadata on the handle so the
    // per-write check in sys_write needs no fresh VFS lookup.
    f.mode = open_result.mode;
    f.uid = open_result.uid;
    f.gid = open_result.gid;
    // Directory-entry location: FAT32 write() rewrites the entry's
    // first-cluster / size through it. Only writable handles (this path)
    // need it; the read-only open sites below leave the alloc-zeroed
    // default, and non-FAT backends never set it.
    f.dirent_lba = open_result.dirent_lba;
    f.dirent_off = open_result.dirent_off;

    const fd = fdtable.install(c, .file, f);
    if (fd < 0) {
        file_mod.unref(f);
        return -1;
    }
    return fd;
}

// Post-lookup body for file reads. The VFS vtable walks
// chunks of <=512 bytes and copies them to the caller's UVA. Returns
// total bytes copied, -1 on copy_to_user fault with no progress so
// far. Reached through the unified sys_read dispatcher.
fn readFileBacked(f: *file_mod.File, sb: *vfs.SuperBlock, buf_uva: u64, len: u64) i64 {
    var total_copied: u64 = 0;
    while (total_copied < len) {
        var kbuf: [512]u8 = undefined;
        const take = @min(len - total_copied, @as(u64, @intCast(kbuf.len)));
        preempt_disable();
        const n = vfs.vfs_read(sb, f, &kbuf, take);
        preempt_enable();
        if (n < 0) return if (total_copied > 0) @intCast(total_copied) else -1;
        if (n == 0) break;
        if (copy_to_user(buf_uva + total_copied, &kbuf, @intCast(n)) < 0) return -1;
        total_copied += @intCast(n);
        if (n < take) break;
    }
    return @intCast(total_copied);
}

// Post-lookup body for file writes. Pulls up to 512 bytes
// per iteration through copy_from_user and pushes them via the
// backend's vfs_write vtable. Initramfs returns -1 (EROFS); FAT32
// honours the write via writeBack. Reached through the unified
// sys_write dispatcher.
fn writeFileBacked(f: *file_mod.File, sb: *vfs.SuperBlock, buf_uva: u64, len: u64) i64 {
    var total_pushed: u64 = 0;
    while (total_pushed < len) {
        var kbuf: [512]u8 = undefined;
        const take = @min(len - total_pushed, @as(u64, @intCast(kbuf.len)));
        if (copy_from_user(&kbuf, buf_uva + total_pushed, take) < 0) return -1;
        preempt_disable();
        const n = vfs.vfs_write(sb, f, &kbuf, take);
        preempt_enable();
        if (n < 0) return if (total_pushed > 0) @intCast(total_pushed) else -1;
        if (n == 0) break;
        total_pushed += @intCast(n);
        if (n < take) break;
    }
    return @intCast(total_pushed);
}

export fn sys_seek(fd: i32, off: i64, whence: i32) i64 {
    const c = current orelse return -1;
    const f = fdtable.getFile(c, fd) orelse return -1;
    const sb = vfsSb(f) orelse return -1;

    preempt_disable();
    const ret = vfs.vfs_seek(sb, f, off, whence);
    preempt_enable();

    return ret;
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
        // Re-install the same pgd to drive the full-TLB-flush path in
        // set_pgd (sched.S). Targeted `tlbi vae1is` would be surgical;
        // the heap-shrink path is rare enough that a full flush is fine.
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
// Anonymous-pipe ABI. Slot map in lib/syscall_defs.zig.
// `sys_pipe` returns both fds in a single i64: low 32 bits = read fd,
// high 32 bits = write fd. Negative on out-of-fds / alloc-failure.
// Compact ABI keeps the user-side wrapper to one register and avoids
// a copy_to_user for the pair.
//
// `buf` reaches the kernel through copy_from_user / copy_to_user; a
// wild UVA returns -1 to the caller without zombifying the task.
export fn sys_pipe() i64 {
    const c = current orelse return -1;
    const p = pipe_mod.alloc() orelse return -1;
    p.refs = 2; // one ref per fd installed below

    const rfd = fdtable.install(c, .pipe, p);
    if (rfd < 0) {
        // Two unrefs: refs was set to 2 above before either fd was
        // installed; the page leaks otherwise.
        pipe_mod.unref(p);
        pipe_mod.unref(p);
        return -1;
    }
    const wfd = fdtable.install(c, .pipe, p);
    if (wfd < 0) {
        // close() clears the read-end slot and drops its ref; one more
        // unref drops the write-end ref that was never installed.
        _ = fdtable.close(c, rfd);
        pipe_mod.unref(p);
        return -1;
    }
    return (@as(i64, wfd) << 32) | (@as(i64, rfd) & 0xFFFF_FFFF);
}

// Post-lookup body for pipe reads. One 512-byte kbuf-bounded drain
// per call (POSIX short-read for pipes); the blocking is inside
// pipe_mod.read. Reached through the unified sys_read dispatcher.
fn readPipeBacked(p: *pipe_mod.Pipe, buf_uva: u64, len: u64) i64 {
    var kbuf: [512]u8 = undefined;
    const n = @min(len, @as(u64, @intCast(kbuf.len)));
    const copied = pipe_mod.read(p, &kbuf, n);
    if (copied > 0) {
        if (copy_to_user(buf_uva, &kbuf, @intCast(copied)) < 0) return -1;
    }
    return copied;
}

// Post-lookup body for pipe writes. Mirrors readPipeBacked:
// 512-byte kbuf, single push per call (no loop — caller iterates if
// it has more data than fits the ring). Reached through the unified
// sys_write dispatcher.
fn writePipeBacked(p: *pipe_mod.Pipe, buf_uva: u64, len: u64) i64 {
    var kbuf: [512]u8 = undefined;
    const n = @min(len, @as(u64, @intCast(kbuf.len)));
    if (copy_from_user(&kbuf, buf_uva, n) < 0) return -1;
    return pipe_mod.write(p, &kbuf, n);
}

export fn sys_socket() void {}
export fn sys_msgget() void {}
export fn sys_semget() void {}
export fn sys_shmget() void {}

// Device Management
//
// Console ABI. The unified (fd,buf,len) ABI at slots 32..35 routes
// console fds through the same tagged `fds` table as pipes and files;
// the post-lookup readConsoleBytes / writeConsoleBytes helpers below
// back the sys_read / sys_write dispatchers. fd 0/1/2 are pre-installed
// as console slots at PID-1 bring-up (src/kernel.zig:kernel_process),
// so user code reaches stdin/stdout/stderr without an explicit open.

// Post-lookup body for console reads. Console reads are short by
// design — see src/console.zig:console_read for the blocking and
// POSIX-TTY semantics. Reached through the unified sys_read
// dispatcher.
fn readConsoleBytes(buf_uva: u64, len: u64) i64 {
    var kbuf: [256]u8 = undefined;
    const n = @min(len, @as(u64, @intCast(kbuf.len)));
    const copied = console.console_read(&kbuf, n);
    if (copied > 0) {
        if (copy_to_user(buf_uva, &kbuf, @intCast(copied)) < 0) return -1;
        // Cooked-style echo/mask when enabled: printable bytes only,
        // one NUL-terminated byte at a time through the console mux. Control
        // bytes (CR/LF, and the [TEST] console-echo 0xC0..0xC7 injects) are
        // never emitted, so with both flags off (the default) this filter
        // leaves every existing scenario's serial output byte-identical; with
        // mask on, each printable byte is echoed as '*' instead of itself.
        if (console_echo or console_mask) {
            var j: i64 = 0;
            while (j < copied) : (j += 1) {
                const ch = kbuf[@intCast(j)];
                if (ch >= 0x20 and ch < 0x7F) {
                    // mask wins over echo: show '*' instead of the secret.
                    const out: u8 = if (console_mask) '*' else ch;
                    var one = [2]u8{ out, 0 };
                    console_tx(@ptrCast(&one), 1);
                }
            }
        }
    }
    return copied;
}

// Console-output sink (USB-C gadget console). Only the *user*
// console-write path is muxed here: once the DWC2 CDC-ACM gadget is
// enumerated on the host, fsh / user output streams out the bulk-IN
// endpoint (board.usb.cdc_tx); otherwise it falls back to the Mini-UART
// (main_output(MU, …)). This is a "switch", not a tee — the device-side
// trace already gives a parallel debug channel on the MU.
//
// Kernel [Debug] traces keep calling main_output(MU, …) directly and are
// deliberately NOT routed here, so boot diagnostics stay on the UART
// regardless of USB state (they share main_output with the user path, so
// the mux must live here, not inside main_output's MU case).
//
// `s` must be NUL-terminated at s[len] — the MU fallback is a C-string
// walker; `len` carries the true byte count for the length-framed USB
// bulk path. On virt, enumerated() is always false → MU fallback, so CI
// over QEMU is unaffected.
fn console_tx(s: [*:0]const u8, len: u64) void {
    if (board.usb.enumerated()) {
        board.usb.cdc_tx(s[0..len]);
    } else {
        main_output(MU, s);
    }
}

// Post-lookup body for console writes. Pulls bytes from
// the user buffer in 255-byte chunks, NUL-terminates each chunk in
// the kernel scratch buffer, and hands it to console_tx via the
// existing C-string contract. Returns total bytes pushed. Reached
// through the unified sys_write dispatcher.
//
// Limitation: embedded NULs in the payload truncate the affected
// chunk because main_output dispatches to mini_uart_send_string /
// pl011_uart_send_string, both NUL-terminated walkers. The
// fd-redirect coverage is text-only; binary console output is future
// work alongside a length-aware UART send path.
fn writeConsoleBytes(buf_uva: u64, len: u64) i64 {
    var kbuf: [256]u8 = undefined;
    var done: u64 = 0;
    while (done < len) {
        const take = @min(len - done, @as(u64, @intCast(kbuf.len - 1)));
        if (copy_from_user(&kbuf, buf_uva + done, take) < 0) {
            return if (done > 0) @intCast(done) else -1;
        }
        kbuf[take] = 0;
        console_tx(@ptrCast(&kbuf), take);
        done += take;
    }
    return @intCast(done);
}

// SYS_SET_CONSOLE_MODE (slot 25) — sets the
// kernel console echo/mask flags. CONSOLE_MODE_ECHO on => readConsoleBytes
// echoes drained printable bytes (cooked-style); CONSOLE_MODE_MASK on =>
// it echoes a '*' per printable byte instead (password masking); neither
// (the default) keeps the historical split where the kernel never echoes and
// userland readline owns echo. /bin/login uses ECHO to show the typed
// username and MASK to acknowledge the password without revealing it. Full
// termios / line discipline is still future work. SYS_CLOSE_CONSOLE stays
// inert (the unified ABI absorbs the close side via SYS_CLOSE on a console fd).
export fn sys_setConsoleMode(mode: u64) i64 {
    console_echo = (mode & defs.CONSOLE_MODE_ECHO) != 0;
    console_mask = (mode & defs.CONSOLE_MODE_MASK) != 0;
    return 0;
}
export fn sys_closeConsole() void {}

// Debug-only — not part of the stable ABI.
// Pushes one byte into the kernel RX ring as if it had arrived on
// the UART. Powers deterministic [TEST] console-echo coverage on
// QEMU where there is no external input driver. Document as debug-only
// in DOCUMENTATION.md §5 and remove once a real host-input driver lands.
export fn sys_console_inject(byte: u64) void {
    console.console_test_push(@truncate(byte));
}

// Retired ABI slots. The numbers stay reserved forever — a stale binary
// invoking one gets a clean -1, never a silently different syscall.
export fn sys_retired() i64 {
    return -1;
}

// ---- Unified fd-table ABI ----
//
// SYS_READ / SYS_WRITE / SYS_CLOSE / SYS_DUP2 dispatch by the fd's
// kind tag in current.fds and route through the post-lookup backend
// helpers (readConsoleBytes / writeConsoleBytes / readPipeBacked /
// writePipeBacked / readFileBacked / writeFileBacked) — one code path
// per backend. This is the sole entry point for all console / pipe /
// file I/O; the legacy per-kind shims that once shared these helpers
// were retired (see the retired-slots note at sys_retired).

export fn sys_read(fd: i32, buf_uva: u64, len: u64) i64 {
    const c = current orelse return -1;
    const s = fdtable.get(c, fd) orelse return -1;
    return switch (@as(fdtable.Kind, @enumFromInt(s.kind))) {
        .console => readConsoleBytes(buf_uva, len),
        .pipe => readPipeBacked(@ptrCast(@alignCast(s.ptr.?)), buf_uva, len),
        .file => blk: {
            const f: *file_mod.File = @ptrCast(@alignCast(s.ptr.?));
            const sb = vfsSb(f) orelse break :blk @as(i64, -1);
            break :blk readFileBacked(f, sb, buf_uva, len);
        },
        .none => -1,
    };
}

export fn sys_write(fd: i32, buf_uva: u64, len: u64) i64 {
    const c = current orelse return -1;
    const s = fdtable.get(c, fd) orelse return -1;
    return switch (@as(fdtable.Kind, @enumFromInt(s.kind))) {
        .console => writeConsoleBytes(buf_uva, len),
        .pipe => writePipeBacked(@ptrCast(@alignCast(s.ptr.?)), buf_uva, len),
        .file => blk: {
            const f: *file_mod.File = @ptrCast(@alignCast(s.ptr.?));
            const sb = vfsSb(f) orelse break :blk @as(i64, -1);
            // Permission gate: write-intent check against the
            // metadata carried on the File since open. Open is read-
            // intent only in this ABI, so a readable-but-not-writable
            // file (0644 root, non-root caller) opens fine and fails
            // here with -EACCES instead of a backend -1.
            if (!perm.checkAccess(f.mode, f.uid, f.gid, c.euid, c.egid, .write))
                break :blk @as(i64, -defs.EACCES);
            break :blk writeFileBacked(f, sb, buf_uva, len);
        },
        .none => -1,
    };
}

// Unified close. File fds need an extra step before the slot is
// cleared: vfs_close runs the backend's flush (FAT32 cluster /
// dir-entry / FSInfo writeback; initramfs no-op). Pipe and console
// slots route straight through fdtable.close — refcount handles the
// pipe-page free, console is refcount-exempt.
export fn sys_close(fd: i32) i32 {
    const c = current orelse return -1;
    if (fdtable.getFile(c, fd)) |f| {
        if (vfsSb(f)) |sb| {
            preempt_disable();
            vfs.vfs_close(sb, f);
            preempt_enable();
        }
    }
    return fdtable.close(c, fd);
}

export fn sys_dup2(oldfd: i32, newfd: i32) i32 {
    const c = current orelse return -1;
    return fdtable.dup2(c, oldfd, newfd);
}

// Working-directory ABI. Stores a NUL-terminated,
// `.` / `..`-collapsed absolute path into current.cwd. Relative
// arguments are joined against the existing cwd and then collapsed;
// absolute arguments are collapsed in place. No backend existence
// check — sys_readdir lands the directory probe; until
// then `chdir` is a pure store the open/execve boundary trusts.
// Returns 0 on success, -1 on a wild user pointer / un-NUL-terminated
// input / oversize composition / oversize resolved path.
export fn sys_chdir(path_ptr: u64) i32 {
    const c = current orelse return -1;

    var kpath: [layout.CWD_SIZE]u8 = undefined;
    var i: usize = 0;
    while (i < kpath.len - 1) : (i += 1) {
        var b: u8 = 0;
        if (copy_from_user(@ptrCast(&b), path_ptr + i, 1) < 0) return -1;
        kpath[i] = b;
        if (b == 0) break;
    } else return -1;

    const rel = std.mem.span(@as([*:0]const u8, @ptrCast(&kpath)));
    const cwd_slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&c.cwd)), 0);

    // Resolve into a fresh scratch buffer first, then swap into the
    // task slot only after a successful normalisation — keeps `cwd`
    // intact on overflow / overlong-collapse failure.
    var resolved_buf: [layout.CWD_SIZE]u8 = undefined;
    // Leave one byte for the trailing NUL in cwd[].
    const resolved = path_mod.joinResolve(cwd_slice, rel, resolved_buf[0 .. layout.CWD_SIZE - 1]) orelse return -1;

    @memcpy(c.cwd[0..resolved.len], resolved);
    c.cwd[resolved.len] = 0;
    return 0;
}

// Directory enumeration. Stateless index walk: fill
// the `index`-th entry of the directory at `path` into the caller's
// Dirent and return 0; return -1 at end-of-directory, a bad/unmounted
// path, or a wild user pointer. There is no fd cursor — see
// lib/syscall_defs.zig SYS_READDIR for the stateless-ABI rationale. The
// path reaches the kernel through the soft copy_from_user (a wild UVA
// returns -1 with no zombification); relative paths join against
// current.cwd exactly as sys_openFile does, since vfs.resolve is still
// absolute-only. Allocates nothing — a future OOM audit inherits no
// new site from readdir (the core reason the ABI is stateless).
export fn sys_readdir(path_ptr: u64, index: u64, dirent_uva: u64) i32 {
    const c = current orelse return -1;

    var kpath: [layout.CWD_SIZE]u8 = undefined;
    var i: usize = 0;
    while (i < kpath.len - 1) : (i += 1) {
        var b: u8 = 0;
        if (copy_from_user(@ptrCast(&b), path_ptr + i, 1) < 0) return -1;
        kpath[i] = b;
        if (b == 0) break;
    } else return -1;
    const raw_path = std.mem.span(@as([*:0]const u8, @ptrCast(&kpath)));

    var join_buf: [layout.CWD_SIZE]u8 = undefined;
    const resolved: []const u8 = if (raw_path.len > 0 and raw_path[0] == '/')
        raw_path
    else blk: {
        const cwd_slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&c.cwd)), 0);
        break :blk path_mod.joinResolve(cwd_slice, raw_path, &join_buf) orelse return -1;
    };

    var dirent: defs.Dirent = .{};
    preempt_disable();
    const r = vfs.vfs_readdir(resolved, index, &dirent);
    preempt_enable();
    if (r < 0) return -1;

    if (copy_to_user(dirent_uva, std.mem.asBytes(&dirent), @sizeOf(defs.Dirent)) < 0) return -1;
    return 0;
}

// Kernel-log read. Snapshots the most-recent min(len, retained)
// bytes of the kernel byte-ring (src/klog_ring.zig) into the caller's
// buffer, oldest-first, and returns the count (0 on an empty ring). The
// window head/tail are read once up front so a concurrent main_output
// push cannot move `start` out from under the copy; the bytes are bounced
// through a 512-byte kernel buffer — the ring data wraps the modulo
// boundary, so it is not contiguous for a single copy_to_user — exactly
// like readFileBacked. Allocates nothing (the ring is static BSS), so the
// harness free-page baseline is untouched. A wild buffer UVA returns -1
// via the soft copy_to_user path; the task does not zombify.
export fn sys_klog_read(buf_uva: u64, len: u64) i64 {
    _ = current orelse return -1;

    // Snapshot the window bounds together: head/tail are monotone, so even
    // if a push lands mid-copy the indices stay masked and in-bounds, and
    // reading them as a pair keeps `start` consistent with `total`.
    const head = klog_ring.klog.head;
    const tail = klog_ring.klog.tail;
    const total = @min(len, head -% tail);
    const start = head -% total; // most recent `total` bytes

    var copied: u64 = 0;
    while (copied < total) {
        var kbuf: [512]u8 = undefined;
        const take = @min(total - copied, @as(u64, @intCast(kbuf.len)));
        var i: u64 = 0;
        while (i < take) : (i += 1) {
            kbuf[@intCast(i)] = klog_ring.klog.byteAt(start +% copied +% i);
        }
        if (copy_to_user(buf_uva + copied, &kbuf, take) < 0) {
            return if (copied > 0) @intCast(copied) else -1;
        }
        copied += take;
    }
    return @intCast(copied);
}

// ---- Process credentials ----
//
// The identity layer for the login/auth flow. Getters report the calling
// task's real / effective uid / gid (carried on TaskStruct, inherited by
// fork, preserved by execve). setuid / setgid apply a root-gated policy:
// an euid-0 (root) caller sets BOTH the real and effective id to any
// value; a dropped (non-root) caller may only reset to an id it already
// holds — so /bin/login (root) can drop to a user, but that user can
// never climb back. Failure returns -1 (EPERM-lite); the i64 return makes
// the sentinel representable. `current` is always set in EL0 syscall
// context — the orelse -1 is for the impossible null only.
export fn sys_getuid() i64 {
    const c = current orelse return -1;
    return @intCast(c.uid);
}
export fn sys_geteuid() i64 {
    const c = current orelse return -1;
    return @intCast(c.euid);
}
export fn sys_getgid() i64 {
    const c = current orelse return -1;
    return @intCast(c.gid);
}
export fn sys_getegid() i64 {
    const c = current orelse return -1;
    return @intCast(c.egid);
}
export fn sys_setuid(uid: u32) i64 {
    const c = current orelse return -1;
    if (c.euid == 0) {
        c.uid = uid;
        c.euid = uid;
        return 0;
    }
    if (uid == c.uid or uid == c.euid) {
        c.euid = uid;
        return 0;
    }
    return -1;
}
export fn sys_setgid(gid: u32) i64 {
    const c = current orelse return -1;
    if (c.euid == 0) {
        c.gid = gid;
        c.egid = gid;
        return 0;
    }
    if (gid == c.gid or gid == c.egid) {
        c.egid = gid;
        return 0;
    }
    return -1;
}

// ---- Authentication ----

// The initramfs seed copy — read-only, baked into the kernel image, always
// present. The recovery anchor of the anti-brick design.
const SHADOW_PATH: []const u8 = "/etc/shadow";
// The writable FAT32 copy — what /bin/passwd rewrites. Consulted first so
// password changes take effect; absent on QEMU virt (no SD card) and on a
// freshly formatted card, in which case auth falls back to the seed.
const MNT_SHADOW_PATH: []const u8 = "/mnt/shadow";

// Auth working buffers — static, NOT stack. The per-task kernel stack
// shares its 4 KiB page with TaskStruct (~2.4 KiB usable above KeRegs),
// and the PBKDF2 / HMAC / SHA-256 call frames below already need a large
// share of that. Carrying another ~1.4 KiB of credential / file / digest
// buffers in sys_authenticate's own frame overflows the page and smashes
// the TaskStruct tail (fds table → wild vtable dispatch on the next
// sys_write). Statics sidestep that, exactly like execve.zig's exec_buf /
// argv_scratch. Same serialization argument too: single core, and the only
// callers are PID-1's [TEST] scenarios, /bin/login, and /bin/passwd — never
// concurrent. The password copy is overwritten by the next call; nothing
// here persists secrets beyond the syscall that wrote them.
var auth_scratch: struct {
    user: [64]u8,
    pass: [128]u8,
    fbuf: [1024]u8,
    salt: [64]u8,
    stored: [64]u8,
    derived: [32]u8,
} = undefined;

const ReadFileError = error{ OpenFailed, ReadFailed };

// In-kernel whole-file read through the privileged VFS door (the
// execve.zig stack-File recipe: no file_mod.alloc → no page → the harness
// free-page baseline is untouched; preempt-guarded per VFS call). Returns
// the filled prefix of `buf`. OpenFailed = path does not resolve (not
// mounted / absent); ReadFailed = it resolved but a backend read errored
// (the corruption signal the fallback chain reports loudly).
fn readWholeFile(path: []const u8, buf: []u8) ReadFileError![]const u8 {
    var open_result: vfs.OpenResult = .{};
    preempt_disable();
    const sb_opt = vfs.vfs_open(path, &open_result);
    preempt_enable();
    const sb = sb_opt orelse return error.OpenFailed;

    var f: file_mod.File = .{};
    f.private = open_result.private;
    f.size = open_result.size;
    f.offset = 0;
    var off: usize = 0;
    var failed = false;
    while (off < buf.len) {
        const take: u64 = buf.len - off;
        preempt_disable();
        const got = vfs.vfs_read(sb, &f, buf[off..].ptr, take);
        preempt_enable();
        if (got < 0) {
            failed = true;
            break;
        }
        if (got == 0) break;
        off += @intCast(got);
    }
    preempt_disable();
    vfs.vfs_close(sb, &f);
    preempt_enable();
    if (failed) return error.ReadFailed;
    return buf[0..off];
}

// Outcome of checking one credential pair against one shadow database.
// The distinction between no_user and corrupt drives the fallback chain:
// a parseable file that simply lacks the user is an authoritative denial,
// while a file with nothing parseable in it (truncation, garbage, a
// half-finished rewrite) falls back to the initramfs seed.
const VerifyResult = enum { match, mismatch, no_user, corrupt };

// Walk `content` line by line and verify `password` against the first
// line whose user field equals `username`. Uses auth_scratch.salt /
// .stored / .derived as decode + KDF scratch (single-caller discipline,
// see auth_scratch above).
fn verifyAgainst(content: []const u8, username: []const u8, password: []const u8) VerifyResult {
    var any_parseable = false;
    var line_start: usize = 0;
    var k: usize = 0;
    while (k <= content.len) : (k += 1) {
        if (k != content.len and content[k] != '\n') continue;
        const line = content[line_start..k];
        line_start = k + 1;
        if (line.len == 0) continue;
        const entry = shadow.parseLine(line) orelse continue;
        any_parseable = true;
        // Demo-grade ceiling: PBKDF2 runs only after a username match, so
        // a miss returns sooner than a hit — a username-enumeration timing
        // oracle. Left unmitigated on purpose: the shipped accounts are
        // build-time public (named in the README), so the oracle reveals
        // nothing secret. If accounts ever become private, run a dummy KDF
        // on the miss path so a miss costs the same as a hit.
        if (!std.mem.eql(u8, entry.user, username)) continue;

        // A matching line with undecodable hex is corruption, not denial.
        const salt_n = shadow.hexDecode(entry.salt_hex, &auth_scratch.salt) orelse return .corrupt;
        const hash_n = shadow.hexDecode(entry.hash_hex, &auth_scratch.stored) orelse return .corrupt;
        if (hash_n == 0 or hash_n > 32) return .corrupt;

        sha256.pbkdf2HmacSha256(
            password,
            auth_scratch.salt[0..salt_n],
            entry.iterations,
            auth_scratch.derived[0..hash_n],
        );
        if (sha256.ctEql(auth_scratch.derived[0..hash_n], auth_scratch.stored[0..hash_n])) return .match;
        return .mismatch;
    }
    return if (any_parseable) .no_user else .corrupt;
}

// sys_authenticate — the kernel-owned credential verifier. /bin/login
// passes a username + plaintext password; the kernel reads the active
// shadow database, finds the matching line, runs PBKDF2-HMAC-SHA256 over
// the password with the stored salt + iteration count, and constant-time-
// compares the result to the stored verifier. Returns 0 on a match, -1 on
// anything else (no such user, malformed line, wild pointer, hash
// mismatch). Userland never sees a salt or hash — only pass/fail; the KDF
// lives here (the design intent committed in src/sha256.zig's header).
//
// Shadow source order: the writable FAT32 copy (/mnt/shadow) is
// authoritative when it is present and parseable — that is where
// sys_passwd writes. The initramfs seed (/etc/shadow) is the fallback for
// QEMU virt (no SD), a fresh card, or a corrupt FAT32 copy — the latter
// two announce themselves loudly (anti-brick: corruption never locks the
// operator out, it falls back to the baked-in seed credentials).
//
// The plaintext password crosses the user→kernel boundary exactly once,
// into a static scratch buffer that the next call overwrites.
export fn sys_authenticate(user_uva: u64, user_len: u64, pass_uva: u64, pass_len: u64) i64 {
    _ = current orelse return -1;

    // Scrub the plaintext password and the derived verifier on every exit
    // path. These live in static BSS (single-caller scratch), so
    // without this the last login's secret lingers until the next call happens
    // to overwrite it — a post-boot memory dump could lift it. Plain @memset
    // (not a volatile loop) suffices: auth_scratch's address escapes to the
    // extern copy_from_user below, so the stores are not dead-store-eliminable.
    // Mirrors execve.zig's argv_scratch scrub. Runs after the result is
    // computed, so pass/fail timing is unchanged.
    defer {
        @memset(&auth_scratch.pass, 0);
        @memset(&auth_scratch.derived, 0);
    }

    // Copy the credentials under hard caps. Soft-fail on overflow or a wild
    // UVA (same contract as sys_openFile — no zombify).
    if (user_len == 0 or user_len > auth_scratch.user.len) return -1;
    if (pass_len > auth_scratch.pass.len) return -1;
    if (copy_from_user(&auth_scratch.user, user_uva, user_len) < 0) return -1;
    if (pass_len > 0 and copy_from_user(&auth_scratch.pass, pass_uva, pass_len) < 0) return -1;
    const username = auth_scratch.user[0..user_len];
    const password = auth_scratch.pass[0..pass_len];

    // 1. The writable FAT32 shadow, when it exists and is intact.
    if (readWholeFile(MNT_SHADOW_PATH, &auth_scratch.fbuf)) |content| {
        switch (verifyAgainst(content, username, password)) {
            .match => return 0,
            .mismatch, .no_user => return -1,
            // Nothing parseable → announce + fall through to the seed.
            .corrupt => main_output(MU, "[Debug] /mnt/shadow corrupt - falling back to initramfs seed\n"),
        }
    } else |err| {
        // OpenFailed is the normal miss (virt / fresh card) → silent.
        // ReadFailed means the file is there but unreadable → announce.
        if (err == error.ReadFailed)
            main_output(MU, "[Debug] /mnt/shadow unreadable - falling back to initramfs seed\n");
    }

    // 2. The initramfs seed (always present, read-only).
    const content = readWholeFile(SHADOW_PATH, &auth_scratch.fbuf) catch return -1;
    return switch (verifyAgainst(content, username, password)) {
        .match => 0,
        else => -1,
    };
}

// ---- Password change ----

// The /etc/passwd account database (initramfs, read-only). sys_passwd
// reads it to map the caller's uid back to a login name for the
// "non-root may only change its own record" rule. The account LIST is
// build-time-immutable; only passwords are mutable state.
const PASSWD_PATH: []const u8 = "/etc/passwd";

// sys_passwd working buffers — static for the same stack-budget and
// single-caller reasons as auth_scratch above (the PBKDF2 frames plus
// these would smash the 2.4 KiB kernel stack). The shadow file content
// and the KDF decode/derive scratch live in auth_scratch (fbuf / salt /
// stored / derived) — sys_passwd and sys_authenticate never run
// concurrently, so sharing those buffers is free.
var passwd_scratch: struct {
    user: [64]u8,
    old_pass: [128]u8,
    new_pass: [128]u8,
    pwbuf: [512]u8,
    salt_raw: [16]u8,
    salt_hex: [32]u8,
    hash_hex: [64]u8,
} = undefined;

// In-kernel whole-file overwrite through the privileged VFS door. The
// caller guarantees content.len equals the file's current size (the
// same-length rewrite contract), so the write never grows the file and
// the FAT32 dir-entry resize branch is never taken.
fn writeWholeFile(path: []const u8, content: []const u8) bool {
    var open_result: vfs.OpenResult = .{};
    preempt_disable();
    const sb_opt = vfs.vfs_open(path, &open_result);
    preempt_enable();
    const sb = sb_opt orelse return false;

    var f: file_mod.File = .{};
    f.private = open_result.private;
    f.size = open_result.size;
    f.offset = 0;
    var off: usize = 0;
    var ok = true;
    while (off < content.len) {
        preempt_disable();
        const n = vfs.vfs_write(sb, &f, content[off..].ptr, content.len - off);
        preempt_enable();
        if (n <= 0) {
            ok = false;
            break;
        }
        off += @intCast(n);
    }
    preempt_disable();
    vfs.vfs_close(sb, &f);
    preempt_enable();
    return ok;
}

// sys_passwd — kernel-owned password change (slot 46). Rewrites `user`'s
// record in the writable FAT32 shadow with a fresh kernel-minted salt and
// a PBKDF2 re-hash of the new password, in place and at the same byte
// length (the splice-safety contract — see shadow.rewriteLineInPlace).
//
// Authorization:
//   * root (euid 0) — any record, old password not required (this is the
//     recovery path: root resets a forgotten user password).
//   * everyone else — only the record whose login name maps to the
//     caller's own uid via /etc/passwd, and only with the correct old
//     password. Violations return -EACCES.
//
// Returns 0 on success; -EACCES on an authorization failure; -1 when
// there is no writable shadow (QEMU virt / fresh card — /mnt/shadow is
// the only rewrite target, the initramfs seed is immutable), the target
// user has no shadow record, the input is malformed, or the rewrite
// would change the record length.
//
// The salt source is the kernel entropy fallback (timer mix) — weak but
// fresh per change; the RNG200 hardware source is a named carve-out.
export fn sys_passwd(user_uva: u64, user_len: u64, old_uva: u64, old_len: u64, new_uva: u64, new_len: u64) i64 {
    const c = current orelse return -1;

    // Scrub both plaintext passwords + the derived verifier on every exit
    // path (same rationale as sys_authenticate). The salt/hash hex are public
    // verifier material, not secret, so they need no scrub.
    defer {
        @memset(&passwd_scratch.old_pass, 0);
        @memset(&passwd_scratch.new_pass, 0);
        @memset(&auth_scratch.derived, 0);
    }

    // Copy all three strings under hard caps (sys_authenticate contract:
    // soft-fail on overflow or a wild UVA, no zombify).
    if (user_len == 0 or user_len > passwd_scratch.user.len) return -1;
    if (old_len > passwd_scratch.old_pass.len) return -1;
    if (new_len == 0 or new_len > passwd_scratch.new_pass.len) return -1;
    if (copy_from_user(&passwd_scratch.user, user_uva, user_len) < 0) return -1;
    if (old_len > 0 and copy_from_user(&passwd_scratch.old_pass, old_uva, old_len) < 0) return -1;
    if (copy_from_user(&passwd_scratch.new_pass, new_uva, new_len) < 0) return -1;
    const username = passwd_scratch.user[0..user_len];
    const old_password = passwd_scratch.old_pass[0..old_len];
    const new_password = passwd_scratch.new_pass[0..new_len];

    // Authorization for non-root callers: own record only.
    if (c.euid != 0) {
        const pw_content = readWholeFile(PASSWD_PATH, &passwd_scratch.pwbuf) catch return -1;
        const own = pwfile.lookupByUid(pw_content, c.uid) orelse return -defs.EACCES;
        if (!std.mem.eql(u8, own.user, username)) return -defs.EACCES;
    }

    // The rewrite target must exist and be readable: /mnt/shadow only.
    // Its absence is the graceful no-writable-shadow case (QEMU virt).
    const content = readWholeFile(MNT_SHADOW_PATH, &auth_scratch.fbuf) catch return -1;

    // The target record must exist and parse (we need its iteration count
    // — the rewrite keeps it, which is half of the same-length contract).
    const span = shadow.findUserLine(content, username) orelse return -1;
    const old_entry = shadow.parseLine(content[span.start..span.end]) orelse return -1;

    // Non-root callers must prove knowledge of the old password against
    // the very record being replaced.
    if (c.euid != 0) {
        switch (verifyAgainst(content, username, old_password)) {
            .match => {},
            .mismatch, .no_user => return -defs.EACCES,
            .corrupt => return -1,
        }
    }

    // Mint the new verifier: fresh salt, PBKDF2 over the new password with
    // the record's existing iteration count, both hex-encoded at the fixed
    // widths the same-length contract relies on.
    _ = hwrng.fill(&passwd_scratch.salt_raw);
    _ = shadow.hexEncode(&passwd_scratch.salt_raw, &passwd_scratch.salt_hex) orelse return -1;
    sha256.pbkdf2HmacSha256(
        new_password,
        &passwd_scratch.salt_raw,
        old_entry.iterations,
        auth_scratch.derived[0..32],
    );
    _ = shadow.hexEncode(auth_scratch.derived[0..32], &passwd_scratch.hash_hex) orelse return -1;

    // Same-length in-place rewrite, then push the whole file back.
    // auth_scratch.fbuf still holds the file content; rewrite it there.
    const mut_content = auth_scratch.fbuf[0..content.len];
    if (!shadow.rewriteLineInPlace(
        mut_content,
        username,
        &passwd_scratch.salt_hex,
        &passwd_scratch.hash_hex,
    )) return -1;

    if (!writeWholeFile(MNT_SHADOW_PATH, mut_content)) return -1;
    return 0;
}

/// Syscall dispatch table — referenced from entry.S (`adr x27, sys_call_table`).
/// Slot ↔ constant binding is compiler-enforced via the indexed
/// `t[defs.SYS_*]` writes below — a renumbering in lib/syscall_defs.zig
/// propagates here automatically and any duplicate id would overwrite
/// (and any gap would leave a null that still traps cleanly through the
/// unreachable kernel code path). The upper dispatch bound is
/// NR_SYSCALLS in src/asm_defs_common.inc (`b.hs` in entry.S); keep it
/// in lockstep with the highest user-facing id +1.
///
/// The unified ABI (slots 32..35) carries all console / pipe /
/// file I/O. The legacy per-kind shims at slots 0 / 5 / 8 / 9 / 11 /
/// 23 / 24 / 27..29 were retired: those slots route to sys_retired
/// (a clean -1) and their numbers are never reused.
export var sys_call_table = blk: {
    var t = [_]?*const anyopaque{null} ** defs.NR_SYSCALLS;

    t[defs.SYS_FORK] = @ptrCast(&sys_fork);
    t[defs.SYS_EXIT] = @ptrCast(&sys_exit);
    t[defs.SYS_WAIT] = @ptrCast(&sys_wait);
    t[defs.SYS_DUMP_FREE] = @ptrCast(&sys_dump_free);
    t[defs.SYS_KILL] = @ptrCast(&sys_kill);
    t[defs.SYS_EXECVE] = @ptrCast(&sys_execve);

    t[defs.SYS_OPEN_FILE] = @ptrCast(&sys_openFile);
    t[defs.SYS_SEEK] = @ptrCast(&sys_seek);

    t[defs.SYS_BRK] = @ptrCast(&sys_brk);
    t[defs.SYS_SBRK] = @ptrCast(&sys_sbrk);
    t[defs.SYS_MMAP] = @ptrCast(&sys_mmap);
    t[defs.SYS_MUNMAP] = @ptrCast(&sys_munmap);
    t[defs.SYS_MLOCK] = @ptrCast(&sys_mlock);
    t[defs.SYS_MUNLOCK] = @ptrCast(&sys_munlock);

    t[defs.SYS_PIPE] = @ptrCast(&sys_pipe);
    t[defs.SYS_SOCKET] = @ptrCast(&sys_socket);
    t[defs.SYS_MSGGET] = @ptrCast(&sys_msgget);
    t[defs.SYS_SEMGET] = @ptrCast(&sys_semget);
    t[defs.SYS_SHMGET] = @ptrCast(&sys_shmget);

    t[defs.SYS_SET_CONSOLE_MODE] = @ptrCast(&sys_setConsoleMode);
    t[defs.SYS_CLOSE_CONSOLE] = @ptrCast(&sys_closeConsole);

    t[defs.SYS_CONSOLE_INJECT] = @ptrCast(&sys_console_inject);

    t[defs.SYS_READ] = @ptrCast(&sys_read);
    t[defs.SYS_WRITE] = @ptrCast(&sys_write);
    t[defs.SYS_CLOSE] = @ptrCast(&sys_close);
    t[defs.SYS_DUP2] = @ptrCast(&sys_dup2);

    t[defs.SYS_CHDIR] = @ptrCast(&sys_chdir);
    t[defs.SYS_READDIR] = @ptrCast(&sys_readdir);

    t[defs.SYS_KLOG_READ] = @ptrCast(&sys_klog_read);

    t[defs.SYS_GETUID] = @ptrCast(&sys_getuid);
    t[defs.SYS_GETEUID] = @ptrCast(&sys_geteuid);
    t[defs.SYS_GETGID] = @ptrCast(&sys_getgid);
    t[defs.SYS_GETEGID] = @ptrCast(&sys_getegid);
    t[defs.SYS_SETUID] = @ptrCast(&sys_setuid);
    t[defs.SYS_SETGID] = @ptrCast(&sys_setgid);

    t[defs.SYS_AUTHENTICATE] = @ptrCast(&sys_authenticate);
    t[defs.SYS_PASSWD] = @ptrCast(&sys_passwd);
    t[defs.SYS_REBOOT] = @ptrCast(&sys_reboot);

    // Retired: legacy per-kind console / file / pipe / exec shims
    // (write_str, exec, readFile, writeFile, closeFile, openConsole,
    // readConsole, pipe_read, pipe_write, pipe_close). Slot numbers are
    // never reused; any caller gets -1.
    for ([_]usize{ 0, 5, 8, 9, 11, 23, 24, 27, 28, 29 }) |retired| {
        t[retired] = @ptrCast(&sys_retired);
    }

    break :blk t;
};

// Build-time guard: src/asm_defs_common.inc must declare
// `#define NR_SYSCALLS 48` to match. If you bump the highest SYS_*
// constant in lib/syscall_defs.zig, also bump the asm-side literal,
// then update this comptime check.
comptime {
    if (defs.NR_SYSCALLS != 48) {
        @compileError("NR_SYSCALLS drifted from src/asm_defs_common.inc — keep both in lockstep");
    }
}

/// Map each syscall function pointer to its high-mem (TTBR1) alias so
/// el0_svc can `blr` through the table after the user pgd has been
/// installed in TTBR0.
export fn sys_call_table_relocate() void {
    var i: usize = 0;
    while (i < defs.NR_SYSCALLS) : (i += 1) {
        const cur: u64 = @intFromPtr(sys_call_table[i]);
        sys_call_table[i] = @ptrFromInt(cur | LINEAR_MAP_BASE);
    }
}
