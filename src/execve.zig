// execve: path-resolved ELF loader. Streams PT_LOAD segments from an open
// VFS file into a kernel buffer, then hands off to the ELF loader in
// src/fork.zig. There is no per-image size cap beyond MAX_EXEC_BYTES and
// no double-copy. Argv strings + pointer array live in the eagerly-mapped
// top stack page; entry contract is x0 = argc, x1 = argv (AAPCS64).
//
// Wired into sys.zig via execve_impl + the SYS_EXECVE dispatch slot.
// execve_impl resolves the path through the VFS shim, streams the ELF
// into a static kernel buffer, encodes argv, and hands off to the
// argv-aware loader in src/fork.zig. The kernel body sits behind a
// comptime is_kernel guard so the host-test build compiles only the pure
// encodeArgvBlock (build.zig wires this file with no kernel imports).

const std = @import("std");
const builtin = @import("builtin");

// The real execve_impl body runs only on the freestanding kernel; the
// host-test build compiles encodeArgvBlock alone. A comptime-known guard
// keeps the kernel-only branch — and therefore the kernel-only imports
// and externs below — out of host analysis: Zig only analyses the taken
// branch of a comptime if, so execveKernel and its dependencies are never
// referenced (and never resolved) when is_kernel is false.
const is_kernel = builtin.target.os.tag == .freestanding;

// Kernel-only imports. Referenced solely inside execveKernel, so on the
// host build they are never analysed and need not resolve.
const task_layout = @import("task_layout");
const vfs = @import("vfs");
const user_layout = @import("user_layout");
const path_mod = @import("path");
// Permission gate: exec-intent check + the shared EACCES
// constant. Same lazy-analysis posture as the imports above.
const perm = @import("perm");
const defs = @import("syscall_defs");

// Kernel-only externs (same lazy-analysis posture as the imports).
extern var current: ?*task_layout.TaskStruct;
extern fn free_page(p: u64) void;
extern fn copy_from_user(kbuf: [*]u8, uva: u64, len: u64) i32;
extern fn preempt_disable() void;
extern fn preempt_enable() void;
// C-ABI trampoline into the argv-aware ELF loader (src/fork.zig). A leaf
// module cannot import the root kernel_mod where prepare_move_to_user_elf_argv
// lives, so fork.zig exports this thin shim. argv_block_ptr is a kernel
// pointer to an ArgvBlock, or 0 for the no-argv path.
extern fn move_to_user_elf_argv(blob_addr_kva: u64, blob_size: u64, argv_block_ptr: u64) i32;
// OOM-after-teardown diagnostics. A loader -1 past the point of no return
// cannot return to userland (the caller's pgd is gone), so it emits this
// marker and zombies the task, mirroring do_data_abort's fault-context OOM.
extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn exit_process() void;
const MU: i32 = 0;

// Largest ELF the path-resolved loader will stream in. Sits well above
// PAGE_SIZE (the retired blob loader's cap) so multi-page programs load;
// argv_echo.elf is ~4.5 KiB, fsh will stay under 16 KiB. A larger file
// resolves to a clean -1 rather than a silent clamp. Baseline-neutral:
// exec_buf lives in kernel .bss (below MALLOC_START), not the page pool.
pub const MAX_EXEC_BYTES: usize = 0x10000;

// One exec at a time (uniprocessor; a future SMP release revisits, same posture as
// argv_scratch). exec_buf snapshots the whole ELF contiguously so the
// loader's per-PT_LOAD memcpy walks a single blob (get_free_page would
// hand back non-contiguous pages); arg_storage holds the copied-in argv
// strings before encodeArgvBlock serialises them.
var exec_buf: [MAX_EXEC_BYTES]u8 = undefined;
var arg_storage: [MAX_ARGV_BYTES]u8 = undefined;

// execveKernel frame relief. These were execveKernel stack
// locals; they moved up here — same one-exec-at-a-time posture as
// exec_buf / arg_storage — because the per-task kernel stack shares its
// 4 KiB page with TaskStruct (~2.4 KiB usable above KeRegs) and this
// ~1.8 KiB of path / join / argv-slice buffers pushed the frame past it.
// The overflow lands in the TaskStruct tail: it had been silently
// clipping the unused tail of `cwd[]` all along, and the appended
// credential fields (added after cwd) made it visible as garbage
// euid/gid right after an exec. Container-level analysis is lazy, so the
// host-test build (which never analyses execveKernel) never sees these.
// exec_join_buf is sized to task_layout.CWD_SIZE; the comptime check in
// execveKernel keeps the literal honest without importing task_layout
// at container scope (the host build has no task_layout module).
var exec_kpath: [1024]u8 = undefined;
var exec_join_buf: [256]u8 = undefined;
var exec_argv_slices: [MAX_ARGV][]const u8 = undefined;

// Maximum argv string count surfaced to userland. Bounded by the top
// stack page (one PAGE_SIZE for strings + pointer array).
pub const MAX_ARGV: usize = 32;

// Maximum total argv byte budget — strings + pointer array combined.
// Picked under PAGE_SIZE so the eagerly-mapped top stack page holds
// the whole block with headroom for the initial sp alignment.
pub const MAX_ARGV_BYTES: usize = 3072;

// Encoded argv-on-stack image. encodeArgvBlock fills `bytes` against a
// kernel-side scratch buffer; prepare_move_to_user_elf copies it into
// the top stack page's KVA alias and writes argc/argv/sp into the
// task's saved register frame before eret.
pub const ArgvBlock = struct {
    sp: u64,
    argv_uva: u64,
    argc: u64,
    bytes: []u8,
};

export fn execve_impl(path_ptr: u64, argv_ptr: u64) i32 {
    if (comptime is_kernel) {
        return execveKernel(path_ptr, argv_ptr);
    } else {
        return -1; // host: only encodeArgvBlock is exercised
    }
}

// Real path-resolve → copy-argv → stream-PT_LOAD → set-regs flow. Every
// user copy and validation happens BEFORE the address-space teardown
// ("point of no return"), so a wild path/argv UVA soft-fails to -1 with
// the caller intact — the same contract gate-4's [TEST] efault-syscall
// proves for sys_openFile.
fn execveKernel(path_ptr: u64, argv_ptr: u64) i32 {
    const c = current orelse return -1;

    // Serialise the WHOLE of execveKernel. It fills, then much later consumes,
    // a pile of shared kernel statics (exec_kpath / exec_join_buf /
    // exec_argv_slices, arg_storage, argv_scratch, exec_buf — the "one exec at
    // a time" posture at exec_buf's decl). The final consume is
    // move_to_user_elf_argv, which memcpys out of BOTH exec_buf and
    // argv_scratch — long after the fill — so a timer preempt anywhere from the
    // first static write down to that consume could schedule a second task
    // through execveKernel, clobber the buffers, and leave this task loading a
    // corrupted image. preempt_count is per-task and timer_tick honours
    // preempt_count > 0 (src/sched.zig), so this one disable defers
    // rescheduling across the entire body; the defer re-balances on every
    // return. (The OOM branch calls noreturn exit_process without running the
    // defer, but exit_process zombifies this task and voluntary _schedule
    // switches away regardless of preempt_count, so the leaked count is inert —
    // the next `current` carries its own.) The inner open/fill/close guards
    // below now nest harmlessly under this. NB this supersedes the earlier
    // fill-only guard, which re-enabled preemption BEFORE the consume and so
    // left the buffer clobberable in the gap between fill and load.
    preempt_disable();
    defer preempt_enable();

    // The static join buffer must stay in lockstep with the cwd budget
    // (see the container-scope comment at exec_join_buf).
    comptime {
        if (exec_join_buf.len != task_layout.CWD_SIZE) {
            @compileError("exec_join_buf must match task_layout.CWD_SIZE");
        }
    }

    // 1. Copy the path in (byte loop, soft-fail on a wild UVA — mirrors
    //    sys_openFile:195-204). No teardown yet → the child survives a fault.
    const kpath = &exec_kpath;
    var pi: usize = 0;
    while (pi < kpath.len - 1) : (pi += 1) {
        var b: u8 = 0;
        if (copy_from_user(@ptrCast(&b), path_ptr + pi, 1) < 0) return -1;
        kpath[pi] = b;
        if (b == 0) break;
    } else return -1; // not NUL-terminated within the buffer
    const raw_path = std.mem.span(@as([*:0]const u8, @ptrCast(kpath)));

    // Relative paths (no leading '/') are joined against current.cwd
    // and `.` / `..` collapsed via the host-tested helper in
    // src/path.zig; absolute paths pass through. Still pre-teardown
    // (the VFS open below is the next failable step), so an oversize
    // join returns -1 with the caller intact.
    const path: []const u8 = if (raw_path.len > 0 and raw_path[0] == '/')
        raw_path
    else blk: {
        const cwd_slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&c.cwd)), 0);
        break :blk path_mod.joinResolve(cwd_slice, raw_path, &exec_join_buf) orelse return -1;
    };

    // 2. Copy argv in: walk the NULL-terminated user pointer array, copy
    //    each NUL-terminated string into arg_storage, build kernel slices.
    //    Bounded by MAX_ARGV count and MAX_ARGV_BYTES total; any
    //    fault/overflow → -1 (still pre-teardown).
    const slices = &exec_argv_slices;
    var argc: usize = 0;
    var store_off: usize = 0;
    if (argv_ptr != 0) {
        while (true) : (argc += 1) {
            if (argc >= MAX_ARGV) return -1;
            var p: u64 = 0;
            if (copy_from_user(@ptrCast(&p), argv_ptr + argc * 8, 8) < 0) return -1;
            if (p == 0) break;
            const start = store_off;
            while (true) {
                var b: u8 = 0;
                if (copy_from_user(@ptrCast(&b), p + (store_off - start), 1) < 0) return -1;
                if (b == 0) break;
                if (store_off >= MAX_ARGV_BYTES) return -1;
                arg_storage[store_off] = b;
                store_off += 1;
            }
            slices[argc] = arg_storage[start..store_off];
        }
    }

    // 3. Serialise the argv block (lands in argv_scratch, a static that
    //    survives the teardown below). Soft-fail → -1.
    const blk = encodeArgvBlock(user_layout.STACK_TOP, argc, slices) orelse return -1;

    // 4. Resolve the path through the VFS shim (preempt-guarded like
    //    sys_openFile:208-210). Backend miss → -1.
    var open_result: vfs.OpenResult = .{};
    preempt_disable();
    const sb_opt = vfs.vfs_open(path, &open_result);
    preempt_enable();
    const sb = sb_opt orelse return -1;

    // Permission gate: exec-intent check against the caller's
    // effective ids. Still pre-teardown, so a denied exec soft-fails to
    // -EACCES with the caller's address space intact — same contract as
    // the path/argv faults above. (A check after the teardown would
    // zombie the task instead of returning.)
    if (!perm.checkAccess(
        open_result.mode,
        open_result.uid,
        open_result.gid,
        c.euid,
        c.egid,
        .exec,
    )) return -defs.EACCES;

    if (open_result.size > MAX_EXEC_BYTES) return -1;

    // 5. Stream the whole file into exec_buf via a local stack File (no
    //    file_mod.alloc → no page → baseline-neutral). preempt-guard per
    //    read on the unified read path; EOF (n == 0) ends the loop.
    var f: task_layout.File = .{};
    f.private = open_result.private;
    f.size = open_result.size;
    f.offset = 0;
    var off: usize = 0;
    // Hold preemption disabled across the ENTIRE fill, not per chunk:
    // exec_buf is a shared kernel static, so a timer preempt between
    // chunks could schedule a second task into execveKernel that
    // overwrites the same buffer mid-stream → corrupted image. preempt is
    // a counter, so every exit path below re-balances exactly once.
    preempt_disable();
    while (off < MAX_EXEC_BYTES) {
        const take: u64 = MAX_EXEC_BYTES - off;
        const n = vfs.vfs_read(sb, &f, exec_buf[off..].ptr, take);
        if (n < 0) {
            preempt_enable();
            return -1;
        }
        if (n == 0) break;
        off += @intCast(n);
    }
    preempt_enable();
    const file_size: u64 = off;

    // ELF magic gate: reject a non-ELF file. Still pre-teardown.
    const is_elf = file_size >= 4 and
        exec_buf[0] == 0x7F and exec_buf[1] == 'E' and
        exec_buf[2] == 'L' and exec_buf[3] == 'F';
    if (!is_elf) return -1;

    // vfs_close is inert for initramfs but call it for backend symmetry.
    preempt_disable();
    vfs.vfs_close(sb, &f);
    preempt_enable();

    // 6. POINT OF NO RETURN — tear down the caller's address space.
    //    Nothing below can soft-fail.
    //    c.fds is deliberately NOT touched: POSIX execve preserves the
    //    fd table so a shell can hand a child its redirected stdio.
    //    c.uid/gid/euid/egid are likewise preserved (the same TaskStruct
    //    survives the image swap), so a privilege drop done in /bin/login
    //    before execve carries into the shell. Only mm pages + pgd go away.
    var i: usize = 0;
    while (i < task_layout.MAX_PAGE_COUNT) : (i += 1) {
        const pa = c.mm.user_pages[i].pa;
        if (pa != 0) free_page(pa);
        c.mm.user_pages[i] = .{};
    }
    i = 0;
    while (i < task_layout.MAX_PAGE_COUNT) : (i += 1) {
        const kp = c.mm.kernel_pages[i];
        if (kp != 0) free_page(kp);
        c.mm.kernel_pages[i] = 0;
    }
    c.mm.pgd = 0;

    // 7. Hand off to the argv-aware loader: PT_LOAD map + eager stack +
    //    argv memcpy + x0/x1/sp + set_pgd. Returns 0 (eret jumps to
    //    e_entry, so the caller's post-svc PC is unreachable) or -1. blk is
    //    a stack local — the trampoline derefs it by value immediately, and
    //    blk.bytes points into argv_scratch (static).
    const rc = move_to_user_elf_argv(@intFromPtr(&exec_buf), file_size, @intFromPtr(&blk));
    if (rc < 0) {
        // Past the point of no return: the address space is already torn
        // down (pgd == 0), so the caller cannot resume. A loader -1 here is
        // OOM (allocate_user_page exhausted mid-PT_LOAD / stack). Emit the
        // marker and zombie the task. exit_process never returns.
        main_output(MU, "[KERN] OOM\n");
        exit_process();
    }
    // Success: the eret jumps to e_entry, so this "return value" is never
    // read by the (now-replaced) caller. Instead ret_from_syscall
    // (src/entry.S) does `str x0, [sp, 0]` AFTER the loader runs, storing
    // this value into the saved-x0 slot — which becomes the new program's
    // x0. The AAPCS64 entry contract is x0 = argc, so success MUST return
    // argc: the loader's `regs.regs[0] = argc` frame write is otherwise
    // clobbered by that str (x1 = argv survives — ret_from_syscall touches
    // only x0). argc <= MAX_ARGV (32), so the i32 cast cannot truncate.
    return @intCast(argc);
}

// Kernel-side scratch buffer the encoder serialises into. Single-
// threaded exec path + sequential host tests, so a module-level buffer
// is safe; prepare_move_to_user_elf copies the returned slice into the
// top stack page before any reuse.
var argv_scratch: [MAX_ARGV_BYTES]u8 = undefined;

// Lay out the argv block (pointer array + NUL-terminated strings) for a
// fresh user stack, high → low inside the top stack page:
//
//   top_stack_uva          ← exclusive end of the mapped page
//   NULL guard       (8 B)
//   argv[argc-1] string … argv[0] string   (NUL-terminated, packed)
//   NULL terminator  (8 B, == argv[argc])
//   argv[argc-1] ptr … argv[0] ptr          (8 B each, UVA into strings)
//   ← sp == argv_uva == &argv[0]
//
// The returned `bytes` are the serialised image whose lowest byte lands
// at top_stack_uva - bytes.len; prepare_move_to_user_elf memcpys it into
// the page's KVA alias at offset PAGE_SIZE - bytes.len. Pointers are
// computed as user VAs against that final placement, so `top_stack_uva`
// must be the user VA of the top of the stack page (STACK_TOP), not the
// kernel alias. sp is 16-byte aligned per AAPCS64 (STACK_TOP is page-
// aligned, so aligning the total length to 16 suffices).
//
// Returns null on a soft fault: more than MAX_ARGV strings, or a total
// image larger than MAX_ARGV_BYTES (callers turn this into a clean -1
// rather than a half-built stack).
pub fn encodeArgvBlock(
    top_stack_uva: u64,
    argc: usize,
    kargv: [*]const []const u8,
) ?ArgvBlock {
    if (argc > MAX_ARGV) return null;

    // String bytes = each arg plus its NUL terminator. Bail early if the
    // strings alone blow the budget (guards against usize overflow on a
    // pathological length too).
    var str_bytes: usize = 0;
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        str_bytes += kargv[i].len + 1;
        if (str_bytes > MAX_ARGV_BYTES) return null;
    }

    // Region sizes. The pointer array is argc entries; argv[argc] NULL
    // terminator and the top NULL guard are 8 B each.
    const ptr_bytes = argc * 8;
    const core = ptr_bytes + 8 + str_bytes + 8;
    const total = std.mem.alignForward(usize, core, 16);
    if (total > MAX_ARGV_BYTES) return null;

    // scratch[0] is the lowest byte → final user VA top_stack_uva - total.
    const base_uva = top_stack_uva - total;
    @memset(argv_scratch[0..total], 0);

    // Pointer array at [0, ptr_bytes); argv[argc] NULL at [ptr_bytes,
    // ptr_bytes+8) is left zero. Strings packed ascending from there,
    // argv[0] lowest. Each pointer is the user VA of its string.
    var str_off: usize = ptr_bytes + 8;
    i = 0;
    while (i < argc) : (i += 1) {
        const s = kargv[i];
        std.mem.writeInt(u64, argv_scratch[i * 8 ..][0..8], base_uva + str_off, .little);
        @memcpy(argv_scratch[str_off..][0..s.len], s);
        argv_scratch[str_off + s.len] = 0;
        str_off += s.len + 1;
    }
    // [str_off, total) is the NULL guard + 16-byte alignment pad, already
    // zeroed by the memset above.

    return .{
        .sp = base_uva,
        .argv_uva = base_uva,
        .argc = argc,
        .bytes = argv_scratch[0..total],
    };
}

// ---- Host Tests ----
const testing = std.testing;

// Page-aligned top-of-stack user VA for layout assertions (the real
// call site passes user_layout.STACK_TOP, itself page-aligned).
const TEST_TOP: u64 = 0x0000_0FFF_FFFF_F000;
const TEST_PAGE: u64 = 1 << 12;

// Resolve argv[i] back to its string by walking the encoded image: the
// pointer is a user VA whose offset from base (== block start) indexes
// straight into `bytes`.
fn argAt(blk: ArgvBlock, i: usize) []const u8 {
    const p = std.mem.readInt(u64, blk.bytes[i * 8 ..][0..8], .little);
    const off: usize = @intCast(p - blk.sp);
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&blk.bytes[off])), 0);
}

test "execve: encodeArgvBlock lays out argc=3" {
    const kargv = [_][]const u8{ "argv_echo", "A", "B" };
    const blk = encodeArgvBlock(TEST_TOP, kargv.len, &kargv) orelse return error.UnexpectedNull;

    try testing.expectEqual(@as(u64, 3), blk.argc);
    try testing.expectEqual(blk.sp, blk.argv_uva);
    try testing.expectEqual(@as(u64, 0), blk.sp % 16);
    // Block sits entirely inside the top stack page and butts STACK_TOP.
    try testing.expectEqual(TEST_TOP, blk.sp + blk.bytes.len);
    try testing.expect(blk.sp >= TEST_TOP - TEST_PAGE);

    try testing.expectEqualStrings("argv_echo", argAt(blk, 0));
    try testing.expectEqualStrings("A", argAt(blk, 1));
    try testing.expectEqualStrings("B", argAt(blk, 2));

    // argv[argc] is the NULL terminator.
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, blk.bytes[3 * 8 ..][0..8], .little));
}

test "execve: encodeArgvBlock empty argv is a lone NULL" {
    const kargv = [_][]const u8{};
    const blk = encodeArgvBlock(TEST_TOP, 0, &kargv) orelse return error.UnexpectedNull;

    try testing.expectEqual(@as(u64, 0), blk.argc);
    try testing.expectEqual(blk.sp, blk.argv_uva);
    try testing.expectEqual(@as(u64, 0), blk.sp % 16);
    // argv[0] is immediately NULL: argc=0 + a NULL-terminated empty array.
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, blk.bytes[0..8], .little));
}

test "execve: encodeArgvBlock rejects more than MAX_ARGV strings" {
    var kargv: [MAX_ARGV + 1][]const u8 = undefined;
    for (&kargv) |*s| s.* = "x";
    try testing.expectEqual(@as(?ArgvBlock, null), encodeArgvBlock(TEST_TOP, kargv.len, &kargv));
}

test "execve: encodeArgvBlock rejects oversize byte budget" {
    const big: [MAX_ARGV_BYTES]u8 = undefined;
    const kargv = [_][]const u8{big[0..]};
    try testing.expectEqual(@as(?ArgvBlock, null), encodeArgvBlock(TEST_TOP, kargv.len, &kargv));
}

test "execve: encodeArgvBlock keeps sp 16-aligned for odd lengths" {
    // Lengths chosen so the unaligned `core` size is not a multiple of 16.
    const kargv = [_][]const u8{ "abc", "de" };
    const blk = encodeArgvBlock(TEST_TOP, kargv.len, &kargv) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u64, 0), blk.sp % 16);
    try testing.expectEqual(TEST_TOP, blk.sp + blk.bytes.len);
    try testing.expectEqualStrings("abc", argAt(blk, 0));
    try testing.expectEqualStrings("de", argAt(blk, 1));
}

test "execve: encodeArgvBlock pointers stay inside the stack page" {
    const kargv = [_][]const u8{ "one", "two", "three" };
    const blk = encodeArgvBlock(TEST_TOP, kargv.len, &kargv) orelse return error.UnexpectedNull;
    var i: usize = 0;
    while (i < blk.argc) : (i += 1) {
        const p = std.mem.readInt(u64, blk.bytes[i * 8 ..][0..8], .little);
        try testing.expect(p >= TEST_TOP - TEST_PAGE);
        try testing.expect(p < TEST_TOP);
    }
}
