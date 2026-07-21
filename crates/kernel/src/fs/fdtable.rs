//! Per-task file-descriptor table.
//!
//! Each `TaskStruct` owns a fixed `[FdSlot; FD_TABLE_SIZE]` array. A slot tags
//! its payload pointer with a [`Kind`]; `install`/`get`/`dup2`/`close` and the
//! bulk `dupAll`/`closeAll` dispatch reference-count changes to the right
//! backend (pipe or open file) by that tag. Console and empty slots hold no
//! refcount.
//!
//! The table is only ever touched in EL1 syscall, fork, and exit context on the
//! single kernel core; no IRQ path reaches it. Every access is a raw-pointer
//! operation so no Rust reference is formed to a task the scheduler may also
//! own.

use core::ffi::c_void;
use core::ptr::{addr_of_mut, null_mut};

pub use flashos_kernel_abi::task::{FdSlot, TaskStruct, FD_TABLE_SIZE};

use crate::file::{self, File};
use crate::pipe::{self, Pipe};

/// Backend tag stored in `FdSlot.kind`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum Kind {
    None = 0,
    Console = 1,
    Pipe = 2,
    File = 3,
}

impl Kind {
    #[inline]
    pub fn from_u8(value: u8) -> Kind {
        match value {
            1 => Kind::Console,
            2 => Kind::Pipe,
            3 => Kind::File,
            _ => Kind::None,
        }
    }
}

#[cfg(target_os = "none")]
mod seam {
    unsafe extern "C" {
        pub fn preempt_disable();
        pub fn preempt_enable();
        pub fn free_page(page: u64);
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    pub unsafe fn preempt_disable() {}
    pub unsafe fn preempt_enable() {}
    pub unsafe fn free_page(_page: u64) {}
}

#[cfg(target_os = "none")]
const FREESTANDING: bool = true;
#[cfg(not(target_os = "none"))]
const FREESTANDING: bool = false;

#[inline]
unsafe fn slot_ptr(task: *mut TaskStruct, index: usize) -> *mut FdSlot {
    // SAFETY: caller proves `index < FD_TABLE_SIZE` and owns this task's fds.
    unsafe { addr_of_mut!((*task).fds).cast::<FdSlot>().add(index) }
}

#[inline]
unsafe fn slot(task: *mut TaskStruct, index: usize) -> FdSlot {
    // SAFETY: forwarded slot contract; `FdSlot` is `Copy`.
    unsafe { slot_ptr(task, index).read() }
}

#[inline]
fn kind_of(s: FdSlot) -> Kind {
    Kind::from_u8(s.kind)
}

/// Complete file ref: the kernel-crate mirror of klib's assembly-visible
/// `fos_file_ref` facade.
#[inline]
unsafe fn file_take_ref(f: *mut File) {
    // SAFETY: `f` is a live file; the preempt window is the exclusion `add_ref`
    // requires.
    unsafe {
        seam::preempt_disable();
        file::add_ref(f);
        seam::preempt_enable();
    }
}

/// Complete file unref: mirror of klib's `fos_file_unref` — drop under the
/// preempt window, free the backing page on the last reference.
#[inline]
unsafe fn file_drop_ref(f: *mut File) {
    // SAFETY: `f` is a live file with at least one reference.
    unsafe {
        seam::preempt_disable();
        let last = file::drop_ref(f);
        seam::preempt_enable();
        if last {
            seam::free_page(file::page_pa(f as u64, FREESTANDING));
        }
    }
}

#[inline]
unsafe fn unref_slot(s: FdSlot) {
    // SAFETY: the slot's tag matches its payload pointer by construction.
    unsafe {
        match kind_of(s) {
            Kind::Pipe => pipe::unref(s.ptr as *mut Pipe),
            Kind::File => file_drop_ref(s.ptr as *mut File),
            Kind::Console | Kind::None => {}
        }
    }
}

#[inline]
unsafe fn ref_slot(s: FdSlot) {
    // SAFETY: the slot's tag matches its payload pointer by construction.
    unsafe {
        match kind_of(s) {
            Kind::Pipe => pipe::pipe_ref(s.ptr as *mut Pipe),
            Kind::File => file_take_ref(s.ptr as *mut File),
            Kind::Console | Kind::None => {}
        }
    }
}

/// Install `ptr` under `kind` in the first free slot. Returns the fd, or -1 when
/// the table is full.
///
/// # Safety
/// `task` points to a live task owned by the caller; single kernel core.
pub unsafe fn install(task: *mut TaskStruct, kind: Kind, ptr: *mut c_void) -> i32 {
    // SAFETY: indices stay in `0..FD_TABLE_SIZE`.
    unsafe {
        let mut i = 0usize;
        while i < FD_TABLE_SIZE {
            if kind_of(slot(task, i)) == Kind::None {
                slot_ptr(task, i).write(FdSlot {
                    ptr,
                    kind: kind as u8,
                    _pad: [0; 7],
                });
                return i as i32;
            }
            i += 1;
        }
        -1
    }
}

/// Return the occupied slot for `fd`, or `None` when out of range or free.
///
/// # Safety
/// `task` points to a live task owned by the caller.
pub unsafe fn get(task: *mut TaskStruct, fd: i32) -> Option<FdSlot> {
    if fd < 0 {
        return None;
    }
    let index = fd as usize;
    if index >= FD_TABLE_SIZE {
        return None;
    }
    // SAFETY: `index` is in range.
    let s = unsafe { slot(task, index) };
    if kind_of(s) == Kind::None {
        None
    } else {
        Some(s)
    }
}

/// Resolve `fd` to a pipe, or `None` if it is not a pipe.
///
/// # Safety
/// `task` points to a live task owned by the caller.
pub unsafe fn get_pipe(task: *mut TaskStruct, fd: i32) -> *mut Pipe {
    // SAFETY: forwarded task contract.
    unsafe {
        match get(task, fd) {
            Some(s) if kind_of(s) == Kind::Pipe => s.ptr as *mut Pipe,
            _ => null_mut(),
        }
    }
}

/// Resolve `fd` to an open file, or `None` if it is not a file.
///
/// # Safety
/// `task` points to a live task owned by the caller.
pub unsafe fn get_file(task: *mut TaskStruct, fd: i32) -> *mut File {
    // SAFETY: forwarded task contract.
    unsafe {
        match get(task, fd) {
            Some(s) if kind_of(s) == Kind::File => s.ptr as *mut File,
            _ => null_mut(),
        }
    }
}

/// Whether `fd` is a console slot.
///
/// # Safety
/// `task` points to a live task owned by the caller.
pub unsafe fn is_console(task: *mut TaskStruct, fd: i32) -> bool {
    // SAFETY: forwarded task contract.
    unsafe {
        match get(task, fd) {
            Some(s) => kind_of(s) == Kind::Console,
            None => false,
        }
    }
}

/// Close `fd`: clear the slot and drop its backend reference. Returns -1 for an
/// already-free fd.
///
/// # Safety
/// `task` points to a live task owned by the caller.
pub unsafe fn close(task: *mut TaskStruct, fd: i32) -> i32 {
    // SAFETY: forwarded task contract.
    unsafe {
        let s = match get(task, fd) {
            Some(s) => s,
            None => return -1,
        };
        slot_ptr(task, fd as usize).write(FdSlot::default());
        unref_slot(s);
        0
    }
}

/// Duplicate `oldfd` onto `newfd`, closing any prior occupant. Returns `newfd`
/// or -1.
///
/// # Safety
/// `task` points to a live task owned by the caller.
pub unsafe fn dup2(task: *mut TaskStruct, oldfd: i32, newfd: i32) -> i32 {
    // SAFETY: bounds are checked before any slot access.
    unsafe {
        let src = match get(task, oldfd) {
            Some(s) => s,
            None => return -1,
        };
        if newfd < 0 || newfd as usize >= FD_TABLE_SIZE {
            return -1;
        }
        if oldfd == newfd {
            return newfd;
        }
        let dst = slot(task, newfd as usize);
        if kind_of(dst) != Kind::None {
            unref_slot(dst);
        }
        slot_ptr(task, newfd as usize).write(src);
        ref_slot(src);
        newfd
    }
}

/// Copy every occupied slot from `src` into `dst`, bumping each backend ref.
///
/// # Safety
/// Both pointers are live, distinct tasks owned by the caller; `dst` is an
/// unpublished child during fork.
pub unsafe fn dup_all(src: *mut TaskStruct, dst: *mut TaskStruct) {
    // SAFETY: indices stay in range; both tasks are exclusively owned here.
    unsafe {
        let mut i = 0usize;
        while i < FD_TABLE_SIZE {
            let s = slot(src, i);
            if kind_of(s) != Kind::None {
                slot_ptr(dst, i).write(s);
                ref_slot(s);
            }
            i += 1;
        }
    }
}

/// Close every occupied slot, dropping backend references.
///
/// # Safety
/// `task` points to a live task owned by the caller.
pub unsafe fn close_all(task: *mut TaskStruct) {
    // SAFETY: indices stay in range; the task is exclusively owned here.
    unsafe {
        let mut i = 0usize;
        while i < FD_TABLE_SIZE {
            let s = slot(task, i);
            if kind_of(s) != Kind::None {
                slot_ptr(task, i).write(FdSlot::default());
                unref_slot(s);
            }
            i += 1;
        }
    }
}

// ---- Host tests ----
#[cfg(test)]
mod tests {
    use super::*;
    use core::ptr::addr_of;
    use flashos_kernel_abi::task::File as AbiFile;

    fn file_with_refs(refs: u32) -> AbiFile {
        AbiFile {
            refs,
            ..AbiFile::default()
        }
    }

    #[test]
    fn install_fills_first_free_slot_then_returns_minus_one() {
        unsafe {
            let mut t = TaskStruct::default();
            let p = pipe::alloc();
            assert!(!p.is_null());
            addr_of_mut!((*p).refs).write(1);
            let ptr = p as *mut c_void;

            assert_eq!(install(addr_of_mut!(t), Kind::Pipe, ptr), 0);
            assert_eq!(slot(addr_of_mut!(t), 0).ptr, ptr);
            assert_eq!(slot(addr_of_mut!(t), 0).kind, Kind::Pipe as u8);

            for _ in 1..FD_TABLE_SIZE {
                install(addr_of_mut!(t), Kind::Pipe, ptr);
            }
            assert_eq!(install(addr_of_mut!(t), Kind::Pipe, ptr), -1);
        }
    }

    #[test]
    fn get_pipe_get_file_is_console_dispatch_by_kind() {
        unsafe {
            let mut t = TaskStruct::default();
            let p = pipe::alloc();
            addr_of_mut!((*p).refs).write(1);
            let mut f = file_with_refs(1);
            let fp = addr_of_mut!(f);

            install(addr_of_mut!(t), Kind::Pipe, p as *mut c_void);
            install(addr_of_mut!(t), Kind::File, fp as *mut c_void);
            install(addr_of_mut!(t), Kind::Console, null_mut());

            assert_eq!(get_pipe(addr_of_mut!(t), 0), p);
            assert!(get_pipe(addr_of_mut!(t), 1).is_null());
            assert!(get_pipe(addr_of_mut!(t), 2).is_null());

            assert_eq!(get_file(addr_of_mut!(t), 1), fp);
            assert!(get_file(addr_of_mut!(t), 0).is_null());
            assert!(get_file(addr_of_mut!(t), 2).is_null());

            assert!(is_console(addr_of_mut!(t), 2));
            assert!(!is_console(addr_of_mut!(t), 0));
            assert!(!is_console(addr_of_mut!(t), 1));
        }
    }

    #[test]
    fn close_clears_slot_and_unrefs_then_double_close_returns_minus_one() {
        unsafe {
            let mut t = TaskStruct::default();
            let p = pipe::alloc();
            addr_of_mut!((*p).refs).write(2); // override alloc
            install(addr_of_mut!(t), Kind::Pipe, p as *mut c_void);

            assert_eq!(close(addr_of_mut!(t), 0), 0);
            assert_eq!(slot(addr_of_mut!(t), 0).kind, 0);
            assert_eq!(addr_of!((*p).refs).read(), 1);

            assert_eq!(close(addr_of_mut!(t), 0), -1);
        }
    }

    #[test]
    fn dup2_over_open_fd_unrefs_occupant_copies_slot_bumps_ref() {
        unsafe {
            let mut t = TaskStruct::default();
            let p1 = pipe::alloc();
            addr_of_mut!((*p1).refs).write(1);
            let p2 = pipe::alloc();
            addr_of_mut!((*p2).refs).write(1);

            install(addr_of_mut!(t), Kind::Pipe, p1 as *mut c_void); // fd 0
            install(addr_of_mut!(t), Kind::Pipe, p2 as *mut c_void); // fd 1

            assert_eq!(dup2(addr_of_mut!(t), 0, 1), 1);
            // p2 unref'd to 0, p1 ref'd to 2.
            assert_eq!(addr_of!((*p2).refs).read(), 0);
            assert_eq!(addr_of!((*p1).refs).read(), 2);
            assert_eq!(get_pipe(addr_of_mut!(t), 1), p1);

            // no-op
            assert_eq!(dup2(addr_of_mut!(t), 0, 0), 0);
            assert_eq!(addr_of!((*p1).refs).read(), 2);
        }
    }

    #[test]
    fn dup_all_and_close_all_dispatch_by_kind() {
        unsafe {
            let mut src = TaskStruct::default();
            let mut dst = TaskStruct::default();

            let p = pipe::alloc();
            addr_of_mut!((*p).refs).write(1);
            install(addr_of_mut!(src), Kind::Pipe, p as *mut c_void);
            install(addr_of_mut!(src), Kind::Console, null_mut());

            dup_all(addr_of_mut!(src), addr_of_mut!(dst));
            assert_eq!(addr_of!((*p).refs).read(), 2);
            assert_eq!(slot(addr_of_mut!(dst), 0).kind, Kind::Pipe as u8);
            assert_eq!(slot(addr_of_mut!(dst), 1).kind, Kind::Console as u8);

            close_all(addr_of_mut!(dst));
            assert_eq!(addr_of!((*p).refs).read(), 1);
            assert_eq!(slot(addr_of_mut!(dst), 0).kind, 0);
        }
    }
}
