//! Task-side layouts shared by the kernel and the exception assembly.
//!
//! Ported from `src/task_layout.flash`, which holds the same structs and the
//! same field order. `sched.S`, `entry.S`, and `irq.S` reach into `TaskStruct`
//! by raw offset, so the field order here is an ABI, not a style choice: every
//! field added since the .S files were written was appended at the end
//! precisely so `core_context` stays at offset 0.

use core::ffi::c_void;
use core::mem::{align_of, offset_of, size_of};

/// Per-task slot budget for both `mm.user_pages` (mapped UVA pages) and
/// `mm.kernel_pages` (PGD/PUD/PMD/PTE tables).
pub const MAX_PAGE_COUNT: usize = 32;

/// Per-task fd-table slot count, covering pipes, files, and console slots.
pub const FD_TABLE_SIZE: usize = 8;

/// Per-task working-directory byte budget. Fixed-size (no heap allocator),
/// NUL-terminated C-string layout.
pub const CWD_SIZE: usize = 256;

/// Per-task kernel-stack page size. `KeRegs` sits in its top `size_of::<KeRegs>()`
/// bytes; fork and context switch resolve the frame at `THREAD_SIZE - 272`.
pub const THREAD_SIZE: u64 = 4096;

// Process states.
pub const TASK_RUNNING: i64 = 0;
pub const TASK_ZOMBIE: i64 = 1;
pub const TASK_INTERRUPTIBLE: i64 = 2;

// `TaskStruct.flags` bits.
pub const KTHREAD: u64 = 1;
pub const UTHREAD: u64 = 0;

/// Callee-saved register set swapped by `cpu_switch_to` (sched.S).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CoreContext {
    pub x19: u64,
    pub x20: u64,
    pub x21: u64,
    pub x22: u64,
    pub x23: u64,
    pub x24: u64,
    pub x25: u64,
    pub x26: u64,
    pub x27: u64,
    pub x28: u64,
    pub fp: u64,
    pub sp: u64,
    pub lr: u64,
}

/// One mapped user page: physical address, the UVA it is mapped at, and the
/// descriptor flags it was stamped with.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct UserPage {
    pub pa: u64,
    pub uva: u64,
    pub flags: u64,
}

/// Per-task memory descriptor: the PGD, the pages mapped into it, and the heap
/// break.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MmStruct {
    pub pgd: u64,
    pub user_pages: [UserPage; MAX_PAGE_COUNT],
    pub kernel_pages: [u64; MAX_PAGE_COUNT],
    /// Top of the demand-allocated heap region. Seeded with `user::HEAP_BASE`
    /// so an empty heap is the legal `addr == brk` no-op state.
    pub brk: u64,
}

impl Default for MmStruct {
    fn default() -> Self {
        Self {
            pgd: 0,
            user_pages: [UserPage::default(); MAX_PAGE_COUNT],
            kernel_pages: [0; MAX_PAGE_COUNT],
            brk: 0,
        }
    }
}

/// One fd-table slot: a tagged pointer to a `Pipe`, a `File`, or nothing
/// (console). `kind == 0` is a free slot.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FdSlot {
    pub ptr: *mut c_void,
    pub kind: u8,
    pub _pad: [u8; 7],
}

impl Default for FdSlot {
    fn default() -> Self {
        Self {
            ptr: core::ptr::null_mut(),
            kind: 0,
            _pad: [0; 7],
        }
    }
}

/// Open-file handle. Layout-only: the lifetime helpers (alloc / ref / unref) and
/// the `FType` tag live with the VFS and are ported in their own stage.
///
/// `sb` is an opaque pointer, not a typed `*mut SuperBlock`, for the same reason
/// the Flash original used `?*anyopaque`: the VFS depends on this record, so this
/// record must not depend on the VFS.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct File {
    pub ftype: u8,
    pub _pad: [u8; 3],
    pub refs: u32,
    pub offset: u64,
    /// Backend-private datum. For an initramfs file: the kernel-VA pointer to
    /// the entry's data bytes.
    pub private: u64,
    pub size: u64,
    /// Backing superblock, for VFS vtable dispatch.
    pub sb: *mut c_void,
    // Permission metadata copied from the open result, so the per-write check
    // has the owning ids without a fresh VFS lookup.
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
    // On-disk directory-entry location. FAT32 write() rewrites the entry's
    // first-cluster and file_size through it; re-walking by first cluster is
    // ambiguous (0 is not unique across empty files). 0 = unset.
    pub dirent_lba: u32,
    pub dirent_off: u32,
}

impl Default for File {
    fn default() -> Self {
        Self {
            ftype: 0,
            _pad: [0; 3],
            refs: 0,
            offset: 0,
            private: 0,
            size: 0,
            sb: core::ptr::null_mut(),
            mode: 0,
            uid: 0,
            gid: 0,
            dirent_lba: 0,
            dirent_off: 0,
        }
    }
}

/// The EL1 exception frame. `entry.S` reserves exactly `S_FRAME_SIZE` bytes for
/// it and fills it field by field; the size assertion below is the other half of
/// that contract.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct KeRegs {
    pub regs: [u64; 31],
    pub sp: u64,
    pub elr: u64,
    pub pstate: u64,
}

/// The task control block. Field order is fixed by the .S files: they key off
/// `core_context` at offset 0.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TaskStruct {
    pub core_context: CoreContext,
    pub state: i64,
    pub counter: i64,
    pub priority: i64,
    pub preempt_count: i64,
    pub flags: u64,
    pub mm: MmStruct,
    /// Parent, for `sys_wait`. Null for `init_task`.
    pub parent: *mut TaskStruct,
    /// Monotonic pid, decoupled from the `task[]` slot index so `sys_kill(pid)`
    /// cannot race a reap+reuse and hit the wrong process.
    pub pid: i32,
    /// Wait-queue chain link. Null = not queued. Per-task because a task can be
    /// on at most one queue at a time.
    pub wq_next: *mut TaskStruct,
    pub fds: [FdSlot; FD_TABLE_SIZE],
    /// Working directory, NUL-terminated. Defaults to "/".
    pub cwd: [u8; CWD_SIZE],
    // Process credentials. Inherited across fork and preserved across execve, so
    // the privilege drop /bin/login performs survives the shell exec. 0 = root.
    pub uid: u32,
    pub gid: u32,
    pub euid: u32,
    pub egid: u32,
    /// Base of the task's own kernel-stack page. The stack lives in a page of its
    /// own so a deep syscall plus a nested timer-IRQ save cannot descend out of
    /// the stack into the credential tail above it. 0 = none (init_task and the
    /// boot context run on the boot stack).
    pub kstack: u64,
}

impl Default for TaskStruct {
    fn default() -> Self {
        let mut cwd = [0u8; CWD_SIZE];
        cwd[0] = b'/';
        Self {
            core_context: CoreContext::default(),
            state: TASK_RUNNING,
            counter: 0,
            priority: 1,
            preempt_count: 0,
            flags: 0,
            mm: MmStruct::default(),
            parent: core::ptr::null_mut(),
            pid: 0,
            wq_next: core::ptr::null_mut(),
            fds: [FdSlot::default(); FD_TABLE_SIZE],
            cwd,
            uid: 0,
            gid: 0,
            euid: 0,
            egid: 0,
            kstack: 0,
        }
    }
}

// ---------------------------------------------------------------------------
// Layout assertions. The numbers are the pre-port build's, dumped from the
// Flash/Zig side rather than hand-derived.
// ---------------------------------------------------------------------------

const _: () = {
    assert!(size_of::<CoreContext>() == 104);
    assert!(align_of::<CoreContext>() == 8);

    assert!(size_of::<UserPage>() == 24);
    assert!(align_of::<UserPage>() == 8);

    assert!(size_of::<MmStruct>() == 1040);
    assert!(align_of::<MmStruct>() == 8);
    assert!(offset_of!(MmStruct, pgd) == 0);
    assert!(offset_of!(MmStruct, user_pages) == 8);
    assert!(offset_of!(MmStruct, kernel_pages) == 776);
    assert!(offset_of!(MmStruct, brk) == 1032);

    assert!(size_of::<FdSlot>() == 16);
    assert!(align_of::<FdSlot>() == 8);
    assert!(offset_of!(FdSlot, ptr) == 0);
    assert!(offset_of!(FdSlot, kind) == 8);

    assert!(size_of::<File>() == 64);
    assert!(align_of::<File>() == 8);
    assert!(offset_of!(File, ftype) == 0);
    assert!(offset_of!(File, refs) == 4);
    assert!(offset_of!(File, offset) == 8);
    assert!(offset_of!(File, private) == 16);
    assert!(offset_of!(File, size) == 24);
    assert!(offset_of!(File, sb) == 32);
    assert!(offset_of!(File, mode) == 40);
    assert!(offset_of!(File, uid) == 44);
    assert!(offset_of!(File, gid) == 48);
    assert!(offset_of!(File, dirent_lba) == 52);
    assert!(offset_of!(File, dirent_off) == 56);

    assert!(size_of::<KeRegs>() == 272);
    assert!(align_of::<KeRegs>() == 8);
    assert!(offset_of!(KeRegs, sp) == 248);
    assert!(offset_of!(KeRegs, elr) == 256);
    assert!(offset_of!(KeRegs, pstate) == 264);

    assert!(size_of::<TaskStruct>() == 1616);
    assert!(align_of::<TaskStruct>() == 8);
    // sched.S / entry.S / irq.S key off this being 0.
    assert!(offset_of!(TaskStruct, core_context) == 0);
    assert!(offset_of!(TaskStruct, state) == 104);
    assert!(offset_of!(TaskStruct, counter) == 112);
    assert!(offset_of!(TaskStruct, priority) == 120);
    assert!(offset_of!(TaskStruct, preempt_count) == 128);
    assert!(offset_of!(TaskStruct, flags) == 136);
    assert!(offset_of!(TaskStruct, mm) == 144);
    assert!(offset_of!(TaskStruct, parent) == 1184);
    assert!(offset_of!(TaskStruct, pid) == 1192);
    assert!(offset_of!(TaskStruct, wq_next) == 1200);
    assert!(offset_of!(TaskStruct, fds) == 1208);
    assert!(offset_of!(TaskStruct, cwd) == 1336);
    assert!(offset_of!(TaskStruct, uid) == 1592);
    assert!(offset_of!(TaskStruct, gid) == 1596);
    assert!(offset_of!(TaskStruct, euid) == 1600);
    assert!(offset_of!(TaskStruct, egid) == 1604);
    assert!(offset_of!(TaskStruct, kstack) == 1608);

    // The exception frame must still fit in the kernel-stack page with room to
    // spare — the syscall stack-tail constraint the port must not regress.
    assert!(size_of::<KeRegs>() < THREAD_SIZE as usize);
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_defaults_match_the_flash_originals() {
        let t = TaskStruct::default();
        assert_eq!(t.state, TASK_RUNNING);
        assert_eq!(t.priority, 1);
        assert_eq!(t.pid, 0);
        assert!(t.parent.is_null());
        assert!(t.wq_next.is_null());
        // init_task and every forked child come up rooted at "/".
        assert_eq!(t.cwd[0], b'/');
        assert_eq!(t.cwd[1], 0);
        // Default credentials are root, correct for init_task.
        assert_eq!((t.uid, t.gid, t.euid, t.egid), (0, 0, 0, 0));
        assert_eq!(t.kstack, 0);
    }

    #[test]
    fn free_fd_slots_are_kind_zero() {
        let t = TaskStruct::default();
        for slot in t.fds.iter() {
            assert_eq!(slot.kind, 0);
            assert!(slot.ptr.is_null());
        }
    }

    #[test]
    fn keregs_sits_in_the_tail_of_the_kernel_stack_page() {
        // fork and context switch both resolve the frame at this offset.
        assert_eq!(THREAD_SIZE as usize - size_of::<KeRegs>(), 3824);
    }

    /// The frame the assembly writes is a flat run of u64s; prove the Rust record
    /// reads it back field-for-field at the offsets `entry.S` uses.
    #[test]
    fn keregs_maps_onto_the_raw_exception_frame() {
        let mut raw = [0u64; 34];
        for (i, slot) in raw.iter_mut().enumerate() {
            *slot = i as u64;
        }
        let regs: KeRegs = unsafe { core::mem::transmute(raw) };
        assert_eq!(regs.regs[0], 0);
        assert_eq!(regs.regs[30], 30);
        assert_eq!(regs.sp, 31);
        assert_eq!(regs.elr, 32);
        assert_eq!(regs.pstate, 33);
    }
}
