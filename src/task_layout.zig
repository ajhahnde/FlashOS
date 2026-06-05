// task_layout: canonical extern-struct layouts shared across kernel
// modules.
//
// Single source of truth. These structs were previously duplicated as
// per-file mirrors that drifted (mm_user / utilc / trace lacked the
// `parent` and `pid` fields) — the layout-drift bug the per-file
// `extern struct` discipline failed to prevent.
//
// Every kernel module that needs a layout `@import`s and aliases it,
// never redeclares. Defaults are set so `Foo{}` literals work;
// consumers override non-default fields at the construction site.
//
// The .S files (sched.S, entry.S, irq.S) consume these layouts via
// raw offsets. Reordering fields here requires auditing the asm side.

// Per-task slot budget for both `mm.user_pages` (mapped UVA pages) and
// `mm.kernel_pages` (PGD/PUD/PMD/PTE tables). 16 was tight enough that
// the brk test (1 inherited UVA-0 page + 16 heap pages = 17) overflowed
// user_pages on the 17th map_page call. 32 leaves headroom for future
// tests without inflating TaskStruct beyond the 4 KiB kernel-stack page
// (TaskStruct ≈ CoreContext + scalars + MmStruct + parent + pid +
// wq_next + fd_table + open_files = ~104 + 40 + (8 + 32*16 + 32*8 + 8)
// + 8 + 4 + 8 + 8*8 + 8*8 + cwd 256 + creds 16 = ~1328 bytes; KeRegs
// sits in the top 272 bytes of the same page, leaving ~2.4 KiB of stack
// — still ample).
// The user_space/kernel_tests.zig brk test holds the canary comptime
// assert that catches NUM_BRK_PAGES overflowing this budget.
pub const MAX_PAGE_COUNT: usize = 32;

// Per-task fd-table slot count. Covers pipes, files, and console slots
// in the unified tagged-pointer fd-table.
pub const FD_TABLE_SIZE: usize = 8;

// Per-task working-directory byte budget. Fixed-size,
// rule-1 (no heap allocator). 256 bytes — sys_chdir's copy-from-user
// loop and the syscall-boundary relative-path join (src/path.zig)
// both honour this ceiling. NUL-terminated C-string layout; the
// active span is `std.mem.sliceTo(&task.cwd, 0)`.
pub const CWD_SIZE: usize = 256;

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
    flags: u64 = 0,
};

pub const MmStruct = extern struct {
    pgd: u64 = 0,
    user_pages: [MAX_PAGE_COUNT]UserPage = [_]UserPage{.{}} ** MAX_PAGE_COUNT,
    kernel_pages: [MAX_PAGE_COUNT]u64 = [_]u64{0} ** MAX_PAGE_COUNT,
    // Heap break — top of the demand-allocated heap region. Initial
    // value (HEAP_BASE) is set by prepare_move_to_user_elf so an
    // empty heap is the legal `addr == brk` no-op state. Mutated by
    // sys_brk / sys_sbrk; read by the region-aware do_data_abort
    // dispatch. Field appended last so the .S consumers
    // that key off CoreContext (offset 0) stay byte-identical.
    brk: u64 = 0,
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
    // Singly-linked-list pointer for WaitQueue chains. Null = not on
    // any queue. Per-task because a task can only be on one queue at
    // a time (mirrors Linux's task.wq_node). Appended after `pid` so
    // the .S consumers that key off CoreContext (offset 0) stay
    // byte-identical.
    wq_next: ?*TaskStruct = null,
    // Fd table slots. Unified tagged-pointer fd-table covering pipes,
    // files, and console. Null slots are indicated by kind=0 (none).
    fds: [FD_TABLE_SIZE]FdSlot = [_]FdSlot{.{}} ** FD_TABLE_SIZE,
    // Per-task working directory. NUL-terminated,
    // C-string layout; sys_chdir + the syscall-boundary relative-path
    // join (src/path.zig) read/write it. Defaults to "/" so init_task
    // (declared as `TaskStruct.{}` in sched.zig) and forked children
    // come up with a sane root. Appended last — after `fds` — so the
    // raw-offset .S consumers (sched.S/entry.S/irq.S key off
    // CoreContext at offset 0) stay byte-identical.
    cwd: [CWD_SIZE]u8 = blk: {
        var c: [CWD_SIZE]u8 = .{0} ** CWD_SIZE;
        c[0] = '/';
        break :blk c;
    },
    // Process credentials. Real + effective uid/gid for the
    // login/auth flow: sys_get/setuid/gid read and mutate these,
    // copy_process_impl copies them parent→child, and execve preserves
    // them (the same TaskStruct survives the image swap) so a privilege
    // drop in /bin/login carries into the shell it execs. Default 0 =
    // root — correct for init_task (declared as `TaskStruct{}` in
    // sched.zig) and overwritten for forked children. Appended last —
    // after `cwd` — so the raw-offset .S consumers (sched.S/entry.S/irq.S
    // key off CoreContext at offset 0) stay byte-identical.
    uid: u32 = 0,
    gid: u32 = 0,
    euid: u32 = 0,
    egid: u32 = 0,
    // Kernel-stack page base. The per-task kernel stack lives in
    // its OWN page, decoupled from this TaskStruct page, so a deep syscall
    // plus a nested timer-IRQ register save can never descend out of the
    // stack into the credential tail that sits just above it. 0 = no
    // separate page: init_task / the boot context run on the boot stack.
    // Appended last — after the creds — so the raw-offset .S consumers
    // (sched.S/entry.S/irq.S key off CoreContext at offset 0) stay
    // byte-identical.
    kstack: u64 = 0,
};

pub const FdSlot = extern struct {
    ptr: ?*anyopaque = null, // *Pipe | *File | null (console)
    kind: u8 = 0,            // Kind; `none` == free slot
    _pad: [7]u8 = .{0} ** 7,
};

// Open-file handle. Layout-only declaration; the lifetime helpers
// (alloc / unref / ref) and the FType tag enum live in src/file.zig
// (the fd-table proper lives in src/fdtable.zig). Defined here so TaskStruct
// can carry a typed `?*File` slot without a circular import on
// file.zig (file.zig imports task_layout for TaskStruct + File).
//
// `ftype = 0` is INITRAMFS_FILE — the only ftype populated today;
// FType in file.zig owns the tag→backend binding for future slots
// (FAT32, unified pipe).
pub const File = extern struct {
    ftype: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    refs: u32 = 0,
    offset: u64 = 0,
    // INITRAMFS_FILE: kernel-VA pointer to the entry's data bytes
    // (already TTBR1-mapped via the .initramfs section).
    private: u64 = 0,
    // Cached file size; saves re-walking the cpio on every read.
    size: u64 = 0,
    // Backing superblock for VFS vtable dispatch.
    // `?*anyopaque`, not `?*vfs.SuperBlock`, to break the import
    // cycle: vfs.zig imports file/task_layout for the File type, so
    // task_layout.zig must not import vfs. sys.zig @ptrCast's this
    // back to *vfs.SuperBlock at the read/seek/close dispatch sites —
    // the same opaque-pointer pattern as the `fd_table` slot above.
    sb: ?*anyopaque = null,
    // Permission metadata copied from OpenResult at open time.
    // Carried on the File so the per-write check in sys_write has the
    // owning ids + mode without a fresh VFS lookup. Defaults 0 =
    // root-owned / no permission bits (safe-deny for non-root callers).
    // Appended last; File is never referenced by raw offset from the
    // .S files (only TaskStruct is), so the append is layout-safe.
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    // On-disk directory-entry location, copied from OpenResult at open.
    // FAT32 write() uses it to rewrite the entry's first-cluster (when a
    // previously empty file gets its first data cluster) and file_size,
    // without an ambiguous re-walk by first cluster (0 is not unique
    // across empty files). dirent_off is the byte offset within the
    // dirent_lba sector. 0 = unset. Appended last; File is never
    // referenced by raw offset from the .S files, so the append is
    // layout-safe.
    dirent_lba: u32 = 0,
    dirent_off: u32 = 0,
};

pub const KeRegs = extern struct {
    regs: [31]u64 = [_]u64{0} ** 31,
    sp: u64 = 0,
    elr: u64 = 0,
    pstate: u64 = 0,
};

// ABI seam — the EL1 exception stub (src/entry.S) reserves exactly
// S_FRAME_SIZE bytes (src/asm_defs_common.inc) for the saved-register
// frame, and fork/context-switch resolve KeRegs at
// THREAD_SIZE - @sizeOf(KeRegs). The asm reservation and this struct MUST
// agree byte-for-byte; a field reorder or addition here would silently
// corrupt every context switch. Zig can't read the C #define, so pin the
// size and fail the build the moment it drifts.
comptime {
    if (@sizeOf(KeRegs) != 272) @compileError(
        "KeRegs size changed — update S_FRAME_SIZE in src/asm_defs_common.inc to match",
    );
}
