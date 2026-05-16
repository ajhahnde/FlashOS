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

// Per-task slot budget for both `mm.user_pages` (mapped UVA pages) and
// `mm.kernel_pages` (PGD/PUD/PMD/PTE tables). 16 was tight enough that
// the brk test (1 inherited UVA-0 page + 16 heap pages = 17) overflowed
// user_pages on the 17th map_page call. 32 leaves headroom for future
// tests without inflating TaskStruct beyond the 4 KiB kernel-stack page
// (TaskStruct ≈ CoreContext + scalars + MmStruct + parent + pid +
// wq_next + fd_table + open_files = ~104 + 40 + (8 + 32*16 + 32*8 + 8)
// + 8 + 4 + 8 + 8*8 + 8*8 = ~1056 bytes; KeRegs sits in the top 272
// bytes of the same page, leaving ~2.7 KiB of stack — still ample).
pub const MAX_PAGE_COUNT: usize = 32;

// Per-task fd-table slot count. Covers both `fd_table` (anonymous-pipe
// slots, v0.3.0) and `open_files` (initramfs/FAT32 file slots,
// v0.4.0). The two tables are parallel and indexed independently;
// future work unifies them behind a single tagged-pointer fd-table.
pub const FD_TABLE_SIZE: usize = 8;

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
    // Heap break — top of the demand-allocated heap region. Initial
    // value (HEAP_BASE) is set by prepare_move_to_user / _elf so an
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
    // Anonymous-pipe fd table. `?*anyopaque` instead of `?*Pipe` to
    // keep task_layout.zig free of a circular import on src/pipe.zig
    // — pipe.zig @ptrCast's at the lookup site. Null slots are free.
    fd_table: [FD_TABLE_SIZE]?*anyopaque = [_]?*anyopaque{null} ** FD_TABLE_SIZE,
    // Initramfs/FAT32 file fd table. Parallel to `fd_table` until
    // both are unified behind a single tagged-pointer fd-table.
    // `File` is the layout-only struct above; src/file.zig owns the
    // lifetime helpers. Null slots are free.
    open_files: [FD_TABLE_SIZE]?*File = [_]?*File{null} ** FD_TABLE_SIZE,
};

// Open-file handle. Layout-only declaration; the lifetime helpers
// (alloc / unref / fdAlloc / fdGet / fdClose / dupAll / closeAll) and
// the FType tag enum live in src/file.zig. Defined here so TaskStruct
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
    // Backing superblock for VFS vtable dispatch (v0.4.0).
    // `?*anyopaque`, not `?*vfs.SuperBlock`, to break the import
    // cycle: vfs.zig imports file/task_layout for the File type, so
    // task_layout.zig must not import vfs. sys.zig @ptrCast's this
    // back to *vfs.SuperBlock at the read/seek/close dispatch sites —
    // the same opaque-pointer pattern as the `fd_table` slot above.
    sb: ?*anyopaque = null,
};

pub const KeRegs = extern struct {
    regs: [31]u64 = [_]u64{0} ** 31,
    sp: u64 = 0,
    elr: u64 = 0,
    pstate: u64 = 0,
};
