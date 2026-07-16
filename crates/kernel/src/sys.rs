//! Syscall handlers and the fixed dispatch table.
//!
//! Each handler is the EL1 body the `blr` in `el0_svc` reaches through the
//! dispatch table; the retained assembly owns the register frame, while the
//! table itself and the unmangled symbols the assembly binds live in
//! `crates/klib`. Handlers are thin: the work belongs to the module that owns
//! the state, so most of this file is argument marshalling and the error
//! sentinels the EL0 side already depends on.
//!
//! Two conventions here are load-bearing rather than stylistic. The path and
//! credential scratch are `static mut`, not locals: the per-task kernel stack
//! shares its page with the task record, and a frame large enough to hold them
//! would grow down into the credential tail. And a user pointer that does not
//! resolve is a soft `-1` to the caller, never a fault that zombifies the task.

use flashos_abi::syscall::{Dirent, CONSOLE_MODE_ECHO, CONSOLE_MODE_MASK, EACCES};
use flashos_abi::task::{File, TaskStruct, CWD_SIZE, UTHREAD};
use flashos_abi::user::{HEAP_BASE, PAGE_SIZE, STACK_BUDGET, STACK_TOP};

use crate::{console, fdtable, file, klog_ring, path, perm, pipe, sched, sha256, shadow, vfs};
use flashos_console_ui::tags;
use flashos_pwfile as pwfile;

/// Longest user path the syscall surface accepts, including the NUL.
const PATH_BUF_SIZE: usize = 1024;

/// Mini-UART interface id for the console fallback. Only the bare-metal seam
/// routes through it; the host seam records bytes instead of driving a UART.
#[cfg(target_os = "none")]
const MU: i32 = 0;

#[cfg(target_os = "none")]
mod seam {
    use super::TaskStruct;
    use crate::klog_ring;

    unsafe extern "C" {
        pub fn copy_from_user(kernel_buffer: *mut u8, uva: u64, len: u64) -> i32;
        pub fn copy_to_user(uva: u64, kernel_buffer: *mut u8, len: u64) -> i32;

        fn unmap_user_range(task: *mut TaskStruct, start_uva: u64, end_uva: u64);
        fn set_pgd(pgd: u64);

        fn copy_process(clone_flags: u64, fn_ptr: u64, arg: u64) -> i32;
        fn exit_process();
        fn do_wait() -> i32;
        fn execve_impl(path_ptr: u64, argv_ptr: u64) -> i32;
        fn dump_free_count() -> u64;
        fn mem_total_count() -> u64;
        fn uptime_seconds() -> u64;
        fn fos_klog_ring() -> *mut klog_ring::KlogRing;
        fn get_sys_count() -> u64;
        fn board_usb_enumerated() -> bool;
        fn board_usb_cdc_tx(ptr: *const u8, len: u64);
        fn main_output(interface: i32, string: *const u8);
        fn board_power_reboot() -> !;
        fn board_mailbox_temperature() -> u32;
        fn board_mailbox_cpu_clock() -> u32;
    }

    #[inline]
    pub unsafe fn unmap_range(task: *mut TaskStruct, start_uva: u64, end_uva: u64) {
        // SAFETY: forwarded live-task and range contract.
        unsafe { unmap_user_range(task, start_uva, end_uva) };
    }

    #[inline]
    pub unsafe fn install_pgd(pgd: u64) {
        // SAFETY: the caller supplies the live task's own PGD.
        unsafe { set_pgd(pgd) };
    }

    #[inline]
    pub unsafe fn clone_task(clone_flags: u64, fn_ptr: u64, arg: u64) -> i32 {
        // SAFETY: forwarded process-creation contract.
        unsafe { copy_process(clone_flags, fn_ptr, arg) }
    }

    #[inline]
    pub unsafe fn exit_current() {
        // SAFETY: the active task zombies itself from syscall context.
        unsafe { exit_process() };
    }

    #[inline]
    pub unsafe fn wait_for_child() -> i32 {
        // SAFETY: forwarded serialized syscall context.
        unsafe { do_wait() }
    }

    #[inline]
    pub unsafe fn execve(path_ptr: u64, argv_ptr: u64) -> i32 {
        // SAFETY: forwarded user-pointer contract.
        unsafe { execve_impl(path_ptr, argv_ptr) }
    }

    #[inline]
    pub unsafe fn free_count() -> u64 {
        // SAFETY: checkpoint callers serialize the bitmap scan.
        unsafe { dump_free_count() }
    }

    #[inline]
    pub unsafe fn total_count() -> u64 {
        // SAFETY: read after boot reservations completed.
        unsafe { mem_total_count() }
    }

    #[inline]
    pub unsafe fn uptime() -> u64 {
        // SAFETY: architectural counter access is available at EL1.
        unsafe { uptime_seconds() }
    }

    #[inline]
    pub unsafe fn reboot() -> ! {
        // SAFETY: the board reset never returns.
        unsafe { board_power_reboot() }
    }

    /// Fill caller-owned bytes from the kernel entropy fallback. The mixer and
    /// its self-test live in `crate::hwrng`; only the architectural counter it
    /// needs comes from assembly.
    #[inline]
    pub unsafe fn hwrng_fill(buffer: &mut [u8]) {
        // SAFETY: reading CNTPCT_EL0 is side-effect-free at EL1; the caller
        // serializes the mixer in syscall context after bring-up.
        let _ = unsafe { crate::hwrng::fill(buffer, || get_sys_count()) };
    }

    #[inline]
    pub unsafe fn klog_ring() -> *mut klog_ring::KlogRing {
        // SAFETY: the Flash module's getter returns its BSS-resident ring.
        unsafe { fos_klog_ring() }
    }

    #[inline]
    pub unsafe fn usb_enumerated() -> bool {
        // SAFETY: reads the gadget's enumeration flag in kernel context.
        unsafe { board_usb_enumerated() }
    }

    #[inline]
    pub unsafe fn usb_cdc_tx(ptr: *const u8, len: u64) {
        // SAFETY: forwarded pointer/length contract.
        unsafe { board_usb_cdc_tx(ptr, len) };
    }

    #[inline]
    pub unsafe fn mini_uart_out(string: *const u8) {
        // SAFETY: `string` is NUL-terminated and not retained.
        unsafe { main_output(super::MU, string) };
    }

    #[inline]
    pub unsafe fn mailbox_temperature() -> u32 {
        // SAFETY: the caller holds preemption exclusion over the shared prop_buf.
        unsafe { board_mailbox_temperature() }
    }

    #[inline]
    pub unsafe fn mailbox_cpu_clock() -> u32 {
        // SAFETY: same shared-prop_buf exclusion as the temperature read.
        unsafe { board_mailbox_cpu_clock() }
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    use core::sync::atomic::{AtomicBool, AtomicU64, Ordering};

    #[cfg(test)]
    use core::sync::atomic::AtomicUsize;
    #[cfg(test)]
    use std::sync::Mutex;

    /// Host builds have no user address space. The copy helpers move bytes to
    /// and from a test-published buffer so the marshalling logic itself — the
    /// byte-at-a-time NUL scan, the truncation bound, the fault sentinel — keeps
    /// a host oracle. `FAULT` makes the next copy fail like a wild UVA does.
    static FAULT: AtomicBool = AtomicBool::new(false);
    static mut USER_BYTES: [u8; 4096] = [0; 4096];

    #[cfg(test)]
    pub fn set_fault(value: bool) {
        FAULT.store(value, Ordering::Relaxed);
    }

    /// Publish `bytes` at user address 0 for the copy helpers to read back.
    ///
    /// # Safety
    /// The host suite serializes access to this shared buffer.
    #[cfg(test)]
    pub unsafe fn set_user_bytes(bytes: &[u8]) {
        // SAFETY: callers hold the module's test lock.
        unsafe {
            let base = core::ptr::addr_of_mut!(USER_BYTES).cast::<u8>();
            core::ptr::write_bytes(base, 0, 4096);
            core::ptr::copy_nonoverlapping(bytes.as_ptr(), base, bytes.len().min(4096));
        }
    }

    /// # Safety
    /// `kernel_buffer` is writable for `len` bytes.
    pub unsafe fn copy_from_user(kernel_buffer: *mut u8, uva: u64, len: u64) -> i32 {
        if FAULT.load(Ordering::Relaxed) || uva as usize + len as usize > 4096 {
            return -1;
        }
        // SAFETY: the bound above keeps the read inside the published buffer.
        unsafe {
            let base = core::ptr::addr_of!(USER_BYTES)
                .cast::<u8>()
                .add(uva as usize);
            core::ptr::copy_nonoverlapping(base, kernel_buffer, len as usize);
        }
        0
    }

    /// # Safety
    /// `kernel_buffer` is readable for `len` bytes.
    pub unsafe fn copy_to_user(uva: u64, kernel_buffer: *mut u8, len: u64) -> i32 {
        if FAULT.load(Ordering::Relaxed) || uva as usize + len as usize > 4096 {
            return -1;
        }
        // SAFETY: the bound above keeps the write inside the published buffer.
        unsafe {
            let base = core::ptr::addr_of_mut!(USER_BYTES)
                .cast::<u8>()
                .add(uva as usize);
            core::ptr::copy_nonoverlapping(kernel_buffer, base, len as usize);
        }
        0
    }

    /// Host builds have no page tables. The brk path's *duty* — unmap the
    /// released range on shrink, then reinstall the pgd to flush the TLB — is
    /// still observable, so record the calls instead of discarding them.
    #[cfg(test)]
    static UNMAPPED: Mutex<Option<(u64, u64)>> = Mutex::new(None);
    #[cfg(test)]
    static PGD_INSTALLS: AtomicUsize = AtomicUsize::new(0);

    #[cfg(test)]
    pub fn reset_vm_log() {
        *UNMAPPED.lock().unwrap_or_else(|e| e.into_inner()) = None;
        PGD_INSTALLS.store(0, Ordering::Relaxed);
    }

    #[cfg(test)]
    pub fn unmapped_range() -> Option<(u64, u64)> {
        *UNMAPPED.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[cfg(test)]
    pub fn pgd_installs() -> usize {
        PGD_INSTALLS.load(Ordering::Relaxed)
    }

    pub unsafe fn unmap_range(_task: *mut super::TaskStruct, start_uva: u64, end_uva: u64) {
        #[cfg(test)]
        {
            *UNMAPPED.lock().unwrap_or_else(|e| e.into_inner()) = Some((start_uva, end_uva));
        }
        #[cfg(not(test))]
        {
            let _ = (start_uva, end_uva);
        }
    }

    pub unsafe fn install_pgd(_pgd: u64) {
        #[cfg(test)]
        PGD_INSTALLS.fetch_add(1, Ordering::Relaxed);
    }

    /// Host builds have no UART and no USB gadget. Record what the console mux
    /// emitted so the echo/mask filter and the chunking keep a host oracle.
    #[cfg(test)]
    static TX: Mutex<std::vec::Vec<u8>> = Mutex::new(std::vec::Vec::new());
    #[cfg(test)]
    static ENUMERATED: AtomicBool = AtomicBool::new(false);

    #[cfg(test)]
    pub fn reset_tx() {
        TX.lock().unwrap_or_else(|e| e.into_inner()).clear();
        ENUMERATED.store(false, Ordering::Relaxed);
    }

    #[cfg(test)]
    pub fn set_enumerated(value: bool) {
        ENUMERATED.store(value, Ordering::Relaxed);
    }

    /// Read back what the copy helpers wrote into the published user buffer.
    #[cfg(test)]
    pub fn user_bytes() -> std::vec::Vec<u8> {
        // SAFETY: callers hold the module's test lock.
        unsafe { core::slice::from_raw_parts(core::ptr::addr_of!(USER_BYTES).cast::<u8>(), 4096) }
            .to_vec()
    }

    #[cfg(test)]
    pub fn tx_bytes() -> std::vec::Vec<u8> {
        TX.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Host stand-in for the Flash-owned BSS ring. Same record, same
    /// arithmetic — only the storage differs.
    static mut KLOG: crate::klog_ring::KlogRing = crate::klog_ring::KlogRing::new();

    pub unsafe fn klog_ring() -> *mut crate::klog_ring::KlogRing {
        &raw mut KLOG
    }

    /// Host stand-in: a deterministic counter, so the salt mint is exercised
    /// without pretending to be entropy.
    pub unsafe fn hwrng_fill(buffer: &mut [u8]) {
        static COUNTER: AtomicU64 = AtomicU64::new(1);
        // SAFETY: the mixer only reads the counter closure.
        let _ = unsafe {
            crate::hwrng::fill(buffer, || COUNTER.fetch_add(0x9E37_79B9, Ordering::Relaxed))
        };
    }

    pub unsafe fn usb_enumerated() -> bool {
        #[cfg(test)]
        {
            ENUMERATED.load(Ordering::Relaxed)
        }
        #[cfg(not(test))]
        false
    }

    /// The length-framed USB bulk path.
    pub unsafe fn usb_cdc_tx(_ptr: *const u8, _len: u64) {
        #[cfg(test)]
        {
            // SAFETY: the caller supplies `_len` readable bytes.
            let bytes = unsafe { core::slice::from_raw_parts(_ptr, _len as usize) };
            TX.lock()
                .unwrap_or_else(|e| e.into_inner())
                .extend_from_slice(bytes);
        }
    }

    /// The Mini-UART fallback: a NUL-terminated C-string walker, which is why
    /// an embedded NUL truncates its chunk.
    pub unsafe fn mini_uart_out(_string: *const u8) {
        #[cfg(test)]
        {
            let mut len = 0;
            // SAFETY: the caller guarantees NUL termination.
            while unsafe { _string.add(len).read() } != 0 {
                len += 1;
            }
            // SAFETY: `len` bytes precede the terminator.
            let bytes = unsafe { core::slice::from_raw_parts(_string, len) };
            TX.lock()
                .unwrap_or_else(|e| e.into_inner())
                .extend_from_slice(bytes);
        }
    }

    pub unsafe fn clone_task(_clone_flags: u64, _fn_ptr: u64, _arg: u64) -> i32 {
        0
    }
    pub unsafe fn exit_current() {}
    pub unsafe fn wait_for_child() -> i32 {
        0
    }
    pub unsafe fn execve(_path_ptr: u64, _argv_ptr: u64) -> i32 {
        0
    }
    pub unsafe fn free_count() -> u64 {
        0
    }
    pub unsafe fn total_count() -> u64 {
        0
    }
    pub unsafe fn uptime() -> u64 {
        0
    }
    pub unsafe fn reboot() -> ! {
        panic!("host build has no board reset")
    }
    pub unsafe fn mailbox_temperature() -> u32 {
        0
    }
    pub unsafe fn mailbox_cpu_clock() -> u32 {
        0
    }
}

/// Find the occupied slot holding `pid`.
///
/// Split out of [`sys_kill`] so the table walk itself carries a host oracle:
/// the caller supplies the scheduler's task array, which only the kernel build
/// can name.
///
/// # Safety
/// `tasks` points to `len` readable slots, each null or a live task, and the
/// caller holds preemption exclusion.
pub unsafe fn find_task_by_pid(
    tasks: *const *mut TaskStruct,
    len: usize,
    pid: i32,
) -> Option<usize> {
    let mut index = 0;
    while index < len {
        // SAFETY: the caller proves every slot in range is readable.
        let slot = unsafe { tasks.add(index).read() };
        if !slot.is_null() {
            // SAFETY: a non-null slot is a live task record.
            if unsafe { (*slot).pid } == pid {
                return Some(index);
            }
        }
        index += 1;
    }
    None
}

/// SYS_FORK — clone the active task as a user thread.
///
/// # Safety
/// Called from serialized syscall context with a live current task.
pub unsafe fn sys_fork() -> i32 {
    // SAFETY: forwarded syscall context.
    unsafe { seam::clone_task(UTHREAD, 0, 0) }
}

/// SYS_EXECVE — replace the active task's user image.
///
/// `path_ptr` is a NUL-terminated absolute UVA and `argv_ptr` the UVA of a
/// NULL-terminated argv array. Returns -1 on resolve, parse, alloc, or
/// argv-fault failure and does not return on success: the eret lands at the new
/// image's entry point.
///
/// # Safety
/// Both pointers are user virtual addresses owned by the active task.
pub unsafe fn sys_execve(path_ptr: u64, argv_ptr: u64) -> i32 {
    // SAFETY: forwarded user-pointer contract.
    unsafe { seam::execve(path_ptr, argv_ptr) }
}

/// SYS_WAIT — block until a child is reapable.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_wait() -> i32 {
    // SAFETY: forwarded syscall context.
    unsafe { seam::wait_for_child() }
}

/// SYS_EXIT — zombie the active task.
///
/// # Safety
/// Called by the active task from syscall context.
pub unsafe fn sys_exit() {
    // SAFETY: forwarded syscall context.
    unsafe { seam::exit_current() };
}

/// SYS_REBOOT — reset the board.
///
/// The per-board reset (PSCI SYSTEM_RESET on virt, the BCM2711 watchdog on
/// rpi4b) never returns, so neither does this handler: `el0_svc` never reaches
/// the eret back to the caller. EL0 cannot do this itself (privileged SMC and
/// MMIO), which is why it is a syscall. No privilege gate yet.
///
/// # Safety
/// Called from syscall context; the board reset never returns.
pub unsafe fn sys_reboot() -> ! {
    // SAFETY: forwarded syscall context.
    unsafe { seam::reboot() }
}

/// SYS_KILL — zombie a target task by pid and wake its parent.
///
/// The slot stays occupied: the parent's existing `do_wait` reaps it and frees
/// the user, page-table, and kernel pages. Self-kill is rejected — the running
/// task is its own kernel page, and `sys_exit` is the safe self-cancel path.
/// Returns 0 on a hit, -1 on a miss or a self-kill attempt.
///
/// # Safety
/// Called from serialized syscall context with a live current task.
pub unsafe fn sys_kill(pid: i32) -> i32 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let current = unsafe { sched::current_task() };
    if !current.is_null() {
        // SAFETY: a non-null current is a live task record.
        if unsafe { (*current).pid } == pid {
            return -1;
        }
    }

    // SAFETY: the walk and the state transition must not race a task switch.
    unsafe { sched::preempt_disable() };
    let tasks = sched::task_base();
    // SAFETY: preemption exclusion is held and the array holds NR_TASKS slots.
    let found = unsafe { find_task_by_pid(tasks, sched::NR_TASKS, pid) };
    let result = match found {
        Some(index) => {
            // SAFETY: the slot was non-null under the same exclusion.
            unsafe {
                sched::zombify_and_wake_parent(tasks.add(index).read());
            }
            0
        }
        None => -1,
    };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };
    result
}

// sys_open_file + join_resolve form the deepest kernel-stack chain on the
// syscall path. The two path scratch buffers live as preempt-guarded module
// statics rather than ~1.3 KiB of stack locals: the kernel stack grows down
// toward the TaskStruct credential tail in the same page, so a stack-heavy open
// could descend into uid/gid/euid/egid, and a timer IRQ taken in that window
// would save its register frame straight over the credentials. Keeping the
// buffers off the stack bounds the frame well clear of the creds. The
// preemption exclusion serialises the shared statics across the whole
// resolve + open, and covers every early-return error path.
static mut OPEN_PATH_BUF: [u8; PATH_BUF_SIZE] = [0; PATH_BUF_SIZE];
static mut OPEN_JOIN_BUF: [u8; CWD_SIZE] = [0; CWD_SIZE];

// Second path scratch for sys_rename — its two paths must be resolved and live
// simultaneously, so the new-path copy/join cannot reuse the old-path buffers.
// Off-stack for the same stack-tail reason.
static mut RENAME_NEW_BUF: [u8; PATH_BUF_SIZE] = [0; PATH_BUF_SIZE];
static mut RENAME_NEW_JOIN: [u8; CWD_SIZE] = [0; CWD_SIZE];

/// Copy a NUL-terminated user path into `raw_buf`, then resolve it against the
/// caller's cwd into `join_buf`: an absolute path passes straight through, a
/// relative one is `.`/`..`-collapsed by the host-tested `join_resolve`.
///
/// Returns the resolved span, or `None` on a copy fault or an over-long
/// resolved path. Every buffer is caller-supplied and off-stack, which is what
/// keeps these handlers' frames clear of the TaskStruct credential tail.
///
/// # Safety
/// The caller holds preemption exclusion over the shared buffers, `task` is the
/// live current task, and both buffers are exclusively owned for the call.
unsafe fn copy_resolve_path<'a>(
    task: *mut TaskStruct,
    path_ptr: u64,
    raw_buf: *mut u8,
    join_buf: *mut u8,
) -> Option<&'a [u8]> {
    let mut index = 0;
    while index < PATH_BUF_SIZE - 1 {
        let mut byte = 0u8;
        // SAFETY: one byte of writable kernel storage per iteration; a wild UVA
        // reports the soft fault rather than zombifying the task.
        if unsafe { seam::copy_from_user(&raw mut byte, path_ptr + index as u64, 1) } < 0 {
            return None;
        }
        // SAFETY: the caller supplies PATH_BUF_SIZE writable bytes and `index`
        // stays below the terminator slot.
        unsafe { raw_buf.add(index).write(byte) };
        if byte == 0 {
            break;
        }
        index += 1;
    }
    // SAFETY: `index` addresses the reserved terminator slot at worst.
    unsafe { raw_buf.add(index).write(0) };
    let raw_len = index;

    if raw_len > 0 && unsafe { raw_buf.read() } == b'/' {
        // SAFETY: `raw_len` bytes were just written and stay live in the
        // caller's buffer for the whole preemption-guarded window.
        return Some(unsafe { core::slice::from_raw_parts(raw_buf, raw_len) });
    }

    // SAFETY: the live task's cwd is a NUL-terminated fixed array.
    let cwd = unsafe { c_str_span(core::ptr::addr_of!((*task).cwd).cast::<u8>(), CWD_SIZE) };
    // SAFETY: the caller supplies live, non-overlapping buffers of the stated
    // sizes; the slices are derived from raw pointers rather than from the
    // statics themselves, so no `&mut` to shared kernel state is manufactured.
    let resolved_len = unsafe {
        let raw = core::slice::from_raw_parts(raw_buf, raw_len);
        let join = core::slice::from_raw_parts_mut(join_buf, CWD_SIZE);
        path::join_resolve(cwd, raw, join)?.len()
    };
    // SAFETY: join_resolve wrote `resolved_len` bytes into the caller's buffer.
    Some(unsafe { core::slice::from_raw_parts(join_buf, resolved_len) })
}

/// Span of a NUL-terminated byte array, capped at `max`.
///
/// # Safety
/// `ptr` points to `max` readable bytes.
unsafe fn c_str_span<'a>(ptr: *const u8, max: usize) -> &'a [u8] {
    let mut len = 0;
    // SAFETY: the caller guarantees `max` readable bytes.
    while len < max && unsafe { ptr.add(len).read() } != 0 {
        len += 1;
    }
    // SAFETY: `len` bytes are readable and precede the terminator.
    unsafe { core::slice::from_raw_parts(ptr, len) }
}

/// Re-type `File.sb` (an opaque pointer, so the vfs/file import cycle stays
/// broken) back to a superblock for vtable dispatch.
///
/// # Safety
/// `file` points to a live `File`.
unsafe fn vfs_sb(file: *mut File) -> *mut vfs::SuperBlock {
    // SAFETY: forwarded live-record contract.
    unsafe {
        core::ptr::addr_of!((*file).sb)
            .read()
            .cast::<vfs::SuperBlock>()
    }
}

/// Publish an opened backend result on a fresh handle and install it in the
/// caller's fd table. Consumes the handle: on a full table the `File` is
/// unref'd before returning -1.
///
/// # Safety
/// `task` is the live current task and the caller holds preemption exclusion.
unsafe fn install_open_result(
    task: *mut TaskStruct,
    sb: *mut vfs::SuperBlock,
    result: &vfs::OpenResult,
    uid: u32,
    gid: u32,
) -> i32 {
    // SAFETY: the allocator exclusion is held by the caller.
    let handle = unsafe { file::alloc() };
    if handle.is_null() {
        return -1;
    }
    // SAFETY: the fresh handle is exclusively owned until it is installed.
    unsafe {
        (*handle).refs = 1;
        (*handle).private = result.private;
        (*handle).size = result.size;
        (*handle).offset = 0;
        (*handle).sb = sb.cast();
        // Carry the backend's permission metadata on the handle so the per-write
        // check needs no fresh VFS lookup.
        (*handle).mode = result.mode;
        (*handle).uid = uid;
        (*handle).gid = gid;
        // Directory-entry location: FAT32 write() rewrites the entry's
        // first-cluster / size through it. Non-FAT backends never set it.
        (*handle).dirent_lba = result.dirent_lba;
        (*handle).dirent_off = result.dirent_off;
    }

    // SAFETY: the live task owns its fd table under the caller's exclusion.
    let fd = unsafe { fdtable::install(task, fdtable::Kind::File, handle.cast()) };
    if fd < 0 {
        // SAFETY: the handle never became reachable; drop the only reference.
        unsafe { file::unref(handle) };
        return -1;
    }
    fd
}

/// SYS_OPEN_FILE — resolve `path` and return a read-intent fd.
///
/// Returns -1 on a fault, an over-long path, a miss, or an exhausted fd table,
/// and `-EACCES` when the permission gate denies the read. The gate runs before
/// the allocation, so a denied open costs no `File` page.
///
/// # Safety
/// `path_ptr` is a user virtual address owned by the active task.
pub unsafe fn sys_open_file(path_ptr: u64) -> i32 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }

    // SAFETY: guards the shared path scratch across the whole resolve + open.
    unsafe { sched::preempt_disable() };
    let result = unsafe { open_file_locked(task, path_ptr) };
    // SAFETY: pairs with the preempt_disable above; covers every error path.
    unsafe { sched::preempt_enable() };
    result
}

/// [`sys_open_file`]'s body, run under the caller's preemption exclusion.
///
/// # Safety
/// `task` is live and the caller holds the exclusion over the shared buffers.
unsafe fn open_file_locked(task: *mut TaskStruct, path_ptr: u64) -> i32 {
    // SAFETY: the statics are exclusively ours under the caller's exclusion.
    let (raw_buf, join_buf) = (
        (&raw mut OPEN_PATH_BUF).cast::<u8>(),
        (&raw mut OPEN_JOIN_BUF).cast::<u8>(),
    );
    // SAFETY: forwarded task and buffer contract.
    let Some(resolved) = (unsafe { copy_resolve_path(task, path_ptr, raw_buf, join_buf) }) else {
        return -1;
    };

    let mut result = vfs::OpenResult::default();
    // SAFETY: the resolved span is live kernel storage for the call.
    let sb = unsafe { vfs::open(resolved, &raw mut result) };
    if sb.is_null() {
        return -1;
    }

    // Open is read-intent: this ABI has no open flags, so write permission is
    // re-checked per write.
    // SAFETY: the live task carries the effective ids.
    let (euid, egid) = unsafe { ((*task).euid, (*task).egid) };
    if !perm::check_access(
        result.mode,
        result.uid,
        result.gid,
        euid,
        egid,
        perm::Access::Read,
    ) {
        return -EACCES;
    }

    // SAFETY: forwarded task and exclusion contract.
    unsafe { install_open_result(task, sb, &result, result.uid, result.gid) }
}

/// SYS_CREATE — creat(): make a new empty file and return a writable fd.
///
/// The deepest-stack twin of [`sys_open_file`], sharing its off-stack scratch.
/// The new file is caller-owned (uid/gid = the caller's effective ids); the
/// backend supplies the 0644 mode baseline. `/mnt` is the only writable mount,
/// so a create elsewhere fails closed through the initramfs EROFS vtable stub.
///
/// # Safety
/// `path_ptr` is a user virtual address owned by the active task.
pub unsafe fn sys_create(path_ptr: u64) -> i32 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }

    // SAFETY: guards the shared path scratch across the whole resolve + create.
    unsafe { sched::preempt_disable() };
    let result = unsafe { create_locked(task, path_ptr) };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };
    result
}

/// [`sys_create`]'s body, run under the caller's preemption exclusion.
///
/// # Safety
/// `task` is live and the caller holds the exclusion over the shared buffers.
unsafe fn create_locked(task: *mut TaskStruct, path_ptr: u64) -> i32 {
    // SAFETY: the statics are exclusively ours under the caller's exclusion.
    let (raw_buf, join_buf) = (
        (&raw mut OPEN_PATH_BUF).cast::<u8>(),
        (&raw mut OPEN_JOIN_BUF).cast::<u8>(),
    );
    // SAFETY: forwarded task and buffer contract.
    let Some(resolved) = (unsafe { copy_resolve_path(task, path_ptr, raw_buf, join_buf) }) else {
        return -1;
    };

    let mut result = vfs::OpenResult::default();
    // SAFETY: the resolved span is live kernel storage for the call.
    let sb = unsafe { vfs::create(resolved, &raw mut result) };
    if sb.is_null() {
        return -1;
    }

    // Caller-owned: stamp the creating user's effective ids over the backend's
    // root baseline so the per-write check lets the owner write the file it just
    // made. Persistence is a known ceiling — a reboot reverts to the overlay
    // default.
    // SAFETY: the live task carries the effective ids.
    let (euid, egid) = unsafe { ((*task).euid, (*task).egid) };
    // SAFETY: forwarded task and exclusion contract.
    unsafe { install_open_result(task, sb, &result, euid, egid) }
}

/// SYS_UNLINK — remove the file at `path`.
///
/// The backend tombstones the entry and frees its chain. Returns 0 on success,
/// -1 on a missing file, a read-only mount, or a fault.
///
/// # Safety
/// `path_ptr` is a user virtual address owned by the active task.
pub unsafe fn sys_unlink(path_ptr: u64) -> i32 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }

    // SAFETY: guards the shared path scratch across resolve + dispatch.
    unsafe { sched::preempt_disable() };
    // SAFETY: the statics are exclusively ours under that exclusion.
    let (raw_buf, join_buf) = (
        (&raw mut OPEN_PATH_BUF).cast::<u8>(),
        (&raw mut OPEN_JOIN_BUF).cast::<u8>(),
    );
    // SAFETY: forwarded task and buffer contract.
    let result = match unsafe { copy_resolve_path(task, path_ptr, raw_buf, join_buf) } {
        // SAFETY: the resolved span is live kernel storage for the call.
        Some(resolved) => unsafe { vfs::unlink(resolved) },
        None => -1,
    };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };
    result
}

/// SYS_RENAME — rename `old` to `new` within the same directory.
///
/// Both paths are copied and resolved into separate off-stack buffers (both must
/// be live for the dispatch) and handed to the VFS, which rejects a cross-mount
/// pair before the backend sees it. Returns 0 on success, -1 on a missing
/// source, a cross-directory or cross-mount move, a bad name, or a fault.
///
/// # Safety
/// Both pointers are user virtual addresses owned by the active task.
pub unsafe fn sys_rename(old_ptr: u64, new_ptr: u64) -> i32 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }

    // SAFETY: guards both shared path scratch pairs across the dispatch.
    unsafe { sched::preempt_disable() };
    let result = unsafe { rename_locked(task, old_ptr, new_ptr) };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };
    result
}

/// [`sys_rename`]'s body, run under the caller's preemption exclusion.
///
/// # Safety
/// `task` is live and the caller holds the exclusion over the shared buffers.
unsafe fn rename_locked(task: *mut TaskStruct, old_ptr: u64, new_ptr: u64) -> i32 {
    // The two scratch pairs are distinct statics, so both resolved spans stay
    // live and non-overlapping for the dispatch below.
    // SAFETY: forwarded task and buffer contract; the statics are exclusively
    // ours under the caller's preemption exclusion.
    let Some(old_resolved) = (unsafe {
        copy_resolve_path(
            task,
            old_ptr,
            (&raw mut OPEN_PATH_BUF).cast::<u8>(),
            (&raw mut OPEN_JOIN_BUF).cast::<u8>(),
        )
    }) else {
        return -1;
    };
    // SAFETY: same contract, against the second scratch pair.
    let Some(new_resolved) = (unsafe {
        copy_resolve_path(
            task,
            new_ptr,
            (&raw mut RENAME_NEW_BUF).cast::<u8>(),
            (&raw mut RENAME_NEW_JOIN).cast::<u8>(),
        )
    }) else {
        return -1;
    };

    // SAFETY: both spans are live kernel storage for the call.
    unsafe { vfs::rename(old_resolved, new_resolved) }
}

/// SYS_SEEK — reposition an open handle through its backend.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_seek(fd: i32, off: i64, whence: i32) -> i64 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: the live task owns its fd table.
    let handle = unsafe { fdtable::get_file(task, fd) };
    if handle.is_null() {
        return -1;
    }
    // SAFETY: an installed handle carries its backing superblock.
    let sb = unsafe { vfs_sb(handle) };
    if sb.is_null() {
        return -1;
    }

    // SAFETY: the backend dispatch must not race a task switch.
    unsafe { sched::preempt_disable() };
    let result = unsafe { vfs::seek(sb, handle, off, whence) };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };
    result
}

/// Post-lookup body for file reads. The VFS vtable walks chunks of <=512 bytes
/// and copies them to the caller's UVA. Returns total bytes copied, or -1 on a
/// `copy_to_user` fault with no progress so far.
///
/// # Safety
/// `handle` and `sb` are live records and `buf_uva` is owned by the active task.
pub unsafe fn read_file_backed(
    handle: *mut File,
    sb: *mut vfs::SuperBlock,
    buf_uva: u64,
    len: u64,
) -> i64 {
    let mut total_copied = 0u64;
    while total_copied < len {
        let mut kbuf = [0u8; 512];
        let take = (len - total_copied).min(kbuf.len() as u64);
        // SAFETY: the backend dispatch must not race a task switch.
        unsafe { sched::preempt_disable() };
        let n = unsafe { vfs::read(sb, handle, kbuf.as_mut_ptr(), take) };
        // SAFETY: pairs with the preempt_disable above.
        unsafe { sched::preempt_enable() };
        if n < 0 {
            return if total_copied > 0 {
                total_copied as i64
            } else {
                -1
            };
        }
        if n == 0 {
            break;
        }
        // SAFETY: `n` bytes of `kbuf` are initialized by the backend read.
        if unsafe { seam::copy_to_user(buf_uva + total_copied, kbuf.as_mut_ptr(), n as u64) } < 0 {
            return -1;
        }
        total_copied += n as u64;
        if (n as u64) < take {
            break;
        }
    }
    total_copied as i64
}

/// Post-lookup body for file writes. Pulls up to 512 bytes per iteration through
/// `copy_from_user` and pushes them via the backend's write vtable. Initramfs
/// returns -1 (EROFS); FAT32 honours the write.
///
/// # Safety
/// `handle` and `sb` are live records and `buf_uva` is owned by the active task.
pub unsafe fn write_file_backed(
    handle: *mut File,
    sb: *mut vfs::SuperBlock,
    buf_uva: u64,
    len: u64,
) -> i64 {
    let mut total_pushed = 0u64;
    while total_pushed < len {
        let mut kbuf = [0u8; 512];
        let take = (len - total_pushed).min(kbuf.len() as u64);
        // SAFETY: `take` bytes of writable kernel storage.
        if unsafe { seam::copy_from_user(kbuf.as_mut_ptr(), buf_uva + total_pushed, take) } < 0 {
            return -1;
        }
        // SAFETY: the backend dispatch must not race a task switch.
        unsafe { sched::preempt_disable() };
        let n = unsafe { vfs::write(sb, handle, kbuf.as_ptr(), take) };
        // SAFETY: pairs with the preempt_disable above.
        unsafe { sched::preempt_enable() };
        if n < 0 {
            return if total_pushed > 0 {
                total_pushed as i64
            } else {
                -1
            };
        }
        if n == 0 {
            break;
        }
        total_pushed += n as u64;
        if (n as u64) < take {
            break;
        }
    }
    total_pushed as i64
}

/// SYS_BRK — set the heap break to `addr`, rounded up to the next page.
///
/// Returns the new break, or the current break when `addr == 0`. Returns -1 on
/// an out-of-range request: below `HEAP_BASE`, or above
/// `STACK_TOP - STACK_BUDGET` (the stack-budget upper bound shared with the
/// data-abort guard logic).
///
/// No pages are eagerly allocated on grow — touching a page in the new range
/// faults through the data-abort path and demand-allocates. On shrink the
/// released pages MUST be freed here: the per-process reap loop only runs at
/// process exit, so a long-lived process that grows then shrinks would leak
/// otherwise. Reinstalling the same pgd drives the full-TLB-flush path so a
/// re-grow re-faults cleanly.
///
/// # Safety
/// Called from serialized syscall context with a live current task.
pub unsafe fn sys_brk(addr: u64) -> i64 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: the live task owns its mm.
    let old_brk = unsafe { (*task).mm.brk };
    if addr == 0 {
        return old_brk as i64;
    }

    let new_brk = (addr + PAGE_SIZE - 1) & !(PAGE_SIZE - 1);
    if new_brk < HEAP_BASE {
        return -1;
    }
    if new_brk > STACK_TOP - STACK_BUDGET {
        return -1;
    }

    if new_brk < old_brk {
        // SAFETY: the released range belongs to the live current task.
        unsafe { seam::unmap_range(task, new_brk, old_brk) };
        // Re-install the same pgd to drive the full-TLB-flush path. A targeted
        // `tlbi vae1is` would be surgical; heap shrink is rare enough that a
        // full flush is fine.
        // SAFETY: the task's own pgd is reinstalled unchanged.
        unsafe { seam::install_pgd((*task).mm.pgd) };
    }
    // SAFETY: the live task owns its mm.
    unsafe { (*task).mm.brk = new_brk };
    new_brk as i64
}

/// SYS_SBRK — `brk(current_break + delta)`, returning the previous break.
///
/// Negative `delta` shrinks. [`sys_brk`] enforces the range bounds; this only
/// guards against signed overflow on the addition.
///
/// # Safety
/// Called from serialized syscall context with a live current task.
pub unsafe fn sys_sbrk(delta: i64) -> i64 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: the live task owns its mm.
    let cur_brk = unsafe { (*task).mm.brk };

    let Some(target) = (cur_brk as i64).checked_add(delta) else {
        return -1;
    };
    if target < 0 {
        return -1;
    }
    // SAFETY: forwarded syscall context.
    if unsafe { sys_brk(target as u64) } < 0 {
        return -1;
    }
    cur_brk as i64
}

/// Reserved slots that were never implemented. They occupy their table entries
/// so the numbers stay claimed.
pub fn sys_mmap() {}
/// See [`sys_mmap`].
pub fn sys_munmap() {}
/// See [`sys_mmap`].
pub fn sys_mlock() {}
/// See [`sys_mmap`].
pub fn sys_munlock() {}
/// See [`sys_mmap`].
pub fn sys_socket() {}
/// See [`sys_mmap`].
pub fn sys_msgget() {}
/// See [`sys_mmap`].
pub fn sys_semget() {}
/// See [`sys_mmap`].
pub fn sys_shmget() {}

/// SYS_PIPE — create an anonymous pipe and return both fds in one i64.
///
/// Low 32 bits = read fd, high 32 bits = write fd. Negative on an exhausted fd
/// table or an allocation failure. The compact ABI keeps the user-side wrapper
/// to one register and avoids a `copy_to_user` for the pair.
///
/// # Safety
/// Called from serialized syscall context with a live current task.
pub unsafe fn sys_pipe() -> i64 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: the allocator seam yields a fresh page or null.
    let pipe_ptr = unsafe { pipe::alloc() };
    if pipe_ptr.is_null() {
        return -1;
    }
    // One reference per fd installed below.
    // SAFETY: the fresh pipe is exclusively owned until an fd is installed.
    unsafe { (*pipe_ptr).refs = 2 };

    // SAFETY: the live task owns its fd table.
    let rfd = unsafe { fdtable::install(task, fdtable::Kind::Pipe, pipe_ptr.cast()) };
    if rfd < 0 {
        // Two unrefs: refs was set to 2 above before either fd was installed;
        // the page leaks otherwise.
        // SAFETY: neither reference ever became reachable.
        unsafe {
            pipe::unref(pipe_ptr);
            pipe::unref(pipe_ptr);
        }
        return -1;
    }
    // SAFETY: the live task owns its fd table.
    let wfd = unsafe { fdtable::install(task, fdtable::Kind::Pipe, pipe_ptr.cast()) };
    if wfd < 0 {
        // close() clears the read-end slot and drops its ref; one more unref
        // drops the write-end ref that was never installed.
        // SAFETY: rfd is the installed read end.
        unsafe {
            fdtable::close(task, rfd);
            pipe::unref(pipe_ptr);
        }
        return -1;
    }
    ((wfd as i64) << 32) | (rfd as i64 & 0xFFFF_FFFF)
}

/// Post-lookup body for pipe reads. One 512-byte kbuf-bounded drain per call
/// (the POSIX short-read for pipes); the blocking lives inside `pipe::read`.
///
/// # Safety
/// `pipe_ptr` is live and `buf_uva` is owned by the active task.
pub unsafe fn read_pipe_backed(pipe_ptr: *mut pipe::Pipe, buf_uva: u64, len: u64) -> i64 {
    let mut kbuf = [0u8; 512];
    let n = len.min(kbuf.len() as u64);
    // SAFETY: forwarded pipe contract; kbuf is live writable kernel storage.
    let copied = unsafe { pipe::read(pipe_ptr, kbuf.as_mut_ptr(), n) };
    if copied > 0 {
        // SAFETY: `copied` bytes of kbuf are initialized by the drain.
        if unsafe { seam::copy_to_user(buf_uva, kbuf.as_mut_ptr(), copied as u64) } < 0 {
            return -1;
        }
    }
    copied
}

/// Post-lookup body for pipe writes. Mirrors [`read_pipe_backed`]: 512-byte
/// kbuf, a single push per call — the caller iterates if it has more data than
/// fits the ring.
///
/// # Safety
/// `pipe_ptr` is live and `buf_uva` is owned by the active task.
pub unsafe fn write_pipe_backed(pipe_ptr: *mut pipe::Pipe, buf_uva: u64, len: u64) -> i64 {
    let mut kbuf = [0u8; 512];
    let n = len.min(kbuf.len() as u64);
    // SAFETY: `n` bytes of writable kernel storage.
    if unsafe { seam::copy_from_user(kbuf.as_mut_ptr(), buf_uva, n) } < 0 {
        return -1;
    }
    // SAFETY: forwarded pipe contract; kbuf holds `n` readable bytes.
    unsafe { pipe::write(pipe_ptr, kbuf.as_ptr(), n) }
}

// ---- console ----
//
// The unified (fd, buf, len) ABI routes console fds through the same tagged fd
// table as pipes and files; the post-lookup helpers below back the read/write
// dispatchers. fd 0/1/2 are pre-installed as console slots at PID-1 bring-up,
// so user code reaches stdin/stdout/stderr without an explicit open.

/// Console echo flags. Default off preserves the historical split — the kernel
/// never echoes, userland readline owns echo, so `fsh` is unaffected.
/// `SYS_SET_CONSOLE_MODE` flips them: with echo on, the console read echoes
/// drained printable bytes; with mask on it echoes a `'*'` per printable byte
/// instead. `/bin/login` turns echo on for the username prompt and mask on for
/// the password, then leaves both off before exec'ing the shell.
static mut CONSOLE_ECHO: bool = false;
static mut CONSOLE_MASK: bool = false;

/// Console-output sink (USB-C gadget console).
///
/// Only the *user* console-write path is muxed here: once the DWC2 CDC-ACM
/// gadget is enumerated on the host, user output streams out the bulk-IN
/// endpoint; otherwise it falls back to the Mini-UART. This is a switch, not a
/// tee — the device-side trace already gives a parallel debug channel on the MU.
///
/// Kernel debug traces keep calling the output path directly and are
/// deliberately NOT routed here, so boot diagnostics stay on the UART
/// regardless of USB state.
///
/// `s` must be NUL-terminated at `s[len]`: the MU fallback is a C-string
/// walker, while `len` carries the true byte count for the length-framed USB
/// bulk path. On virt the gadget never enumerates, so CI over QEMU always takes
/// the MU fallback.
///
/// # Safety
/// `s` points to `len` readable bytes followed by a NUL.
unsafe fn console_tx(s: *const u8, len: u64) {
    // SAFETY: forwarded string contract.
    unsafe {
        if seam::usb_enumerated() {
            seam::usb_cdc_tx(s, len);
        } else {
            seam::mini_uart_out(s);
        }
    }
}

/// Post-lookup body for console reads. Console reads are short by design.
///
/// # Safety
/// `buf_uva` is owned by the active task.
pub unsafe fn read_console_bytes(buf_uva: u64, len: u64) -> i64 {
    let mut kbuf = [0u8; 256];
    let n = len.min(kbuf.len() as u64);
    // SAFETY: kbuf is live writable kernel storage.
    let copied = unsafe { console::console_read(kbuf.as_mut_ptr(), n) };
    if copied <= 0 {
        return copied;
    }
    // SAFETY: `copied` bytes of kbuf are initialized by the drain.
    if unsafe { seam::copy_to_user(buf_uva, kbuf.as_mut_ptr(), copied as u64) } < 0 {
        return -1;
    }

    // Cooked-style echo/mask when enabled: printable bytes only, one
    // NUL-terminated byte at a time through the console mux. Control bytes
    // (CR/LF, and the console-echo test injects) are never emitted, so with both
    // flags off — the default — this filter leaves every existing scenario's
    // serial output byte-identical.
    // SAFETY: the flags are single-core kernel state.
    let (echo, mask) = unsafe {
        (
            (&raw const CONSOLE_ECHO).read(),
            (&raw const CONSOLE_MASK).read(),
        )
    };
    if echo || mask {
        let mut index = 0i64;
        while index < copied {
            let ch = kbuf[index as usize];
            if (0x20..0x7F).contains(&ch) {
                // Mask wins over echo: show '*' instead of the secret.
                let out = if mask { b'*' } else { ch };
                let one = [out, 0];
                // SAFETY: `one` is NUL-terminated at index 1.
                unsafe { console_tx(one.as_ptr(), 1) };
            }
            index += 1;
        }
    }
    copied
}

/// Post-lookup body for console writes. Pulls bytes from the user buffer in
/// 255-byte chunks, NUL-terminates each chunk in the kernel scratch, and hands
/// it to the mux via the existing C-string contract. Returns total bytes pushed.
///
/// Limitation carried over unchanged: an embedded NUL in the payload truncates
/// its chunk, because the MU fallback is a NUL-terminated walker. Console
/// fd-redirect coverage is text-only; binary console output is future work
/// alongside a length-aware UART send path.
///
/// # Safety
/// `buf_uva` is owned by the active task.
pub unsafe fn write_console_bytes(buf_uva: u64, len: u64) -> i64 {
    let mut kbuf = [0u8; 256];
    let mut done = 0u64;
    while done < len {
        let take = (len - done).min(kbuf.len() as u64 - 1);
        // SAFETY: `take` stays below the NUL slot.
        if unsafe { seam::copy_from_user(kbuf.as_mut_ptr(), buf_uva + done, take) } < 0 {
            return if done > 0 { done as i64 } else { -1 };
        }
        kbuf[take as usize] = 0;
        // SAFETY: the chunk is NUL-terminated at `take`.
        unsafe { console_tx(kbuf.as_ptr(), take) };
        done += take;
    }
    done as i64
}

/// SYS_SET_CONSOLE_MODE — set the kernel console echo/mask flags.
///
/// Full termios / line discipline is still future work.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_set_console_mode(mode: u64) -> i64 {
    // SAFETY: the flags are single-core kernel state.
    unsafe {
        (&raw mut CONSOLE_ECHO).write((mode & CONSOLE_MODE_ECHO) != 0);
        (&raw mut CONSOLE_MASK).write((mode & CONSOLE_MODE_MASK) != 0);
    }
    0
}

/// SYS_CLOSE_CONSOLE — inert. The unified ABI absorbs the close side through
/// `SYS_CLOSE` on a console fd.
pub fn sys_close_console() {}

/// Debug-only — not part of the stable ABI. Pushes one byte into the kernel RX
/// ring as if it had arrived on the UART, powering deterministic console-echo
/// coverage on QEMU where there is no external input driver.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_console_inject(byte: u64) {
    // SAFETY: forwarded EL1-context contract.
    unsafe { console::console_test_push(byte as u8) };
}

/// Retired ABI slots. The numbers stay reserved forever — a stale binary
/// invoking one gets a clean -1, never a silently different syscall.
pub fn sys_retired() -> i64 {
    -1
}

// ---- unified fd-table ABI ----
//
// SYS_READ / SYS_WRITE / SYS_CLOSE / SYS_DUP2 dispatch by the fd's kind tag and
// route through the post-lookup backend helpers — one code path per backend.
// This is the sole entry point for all console, pipe, and file I/O.

/// SYS_READ — read from a console, pipe, or file fd.
///
/// # Safety
/// `buf_uva` is owned by the active task.
pub unsafe fn sys_read(fd: i32, buf_uva: u64, len: u64) -> i64 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: the live task owns its fd table.
    let Some(slot) = (unsafe { fdtable::get(task, fd) }) else {
        return -1;
    };

    // SAFETY: each arm forwards the slot's own backend contract.
    unsafe {
        match fdtable::Kind::from_u8(slot.kind) {
            fdtable::Kind::Console => read_console_bytes(buf_uva, len),
            fdtable::Kind::Pipe => read_pipe_backed(slot.ptr.cast(), buf_uva, len),
            fdtable::Kind::File => {
                let handle: *mut File = slot.ptr.cast();
                let sb = vfs_sb(handle);
                if sb.is_null() {
                    return -1;
                }
                read_file_backed(handle, sb, buf_uva, len)
            }
            fdtable::Kind::None => -1,
        }
    }
}

/// SYS_WRITE — write to a console, pipe, or file fd.
///
/// The file arm carries a write-intent permission gate against the metadata the
/// handle has carried since open. Open is read-intent only in this ABI, so a
/// readable-but-not-writable file (0644 root, non-root caller) opens fine and
/// fails here with `-EACCES` instead of a backend -1.
///
/// # Safety
/// `buf_uva` is owned by the active task.
pub unsafe fn sys_write(fd: i32, buf_uva: u64, len: u64) -> i64 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: the live task owns its fd table.
    let Some(slot) = (unsafe { fdtable::get(task, fd) }) else {
        return -1;
    };

    // SAFETY: each arm forwards the slot's own backend contract.
    unsafe {
        match fdtable::Kind::from_u8(slot.kind) {
            fdtable::Kind::Console => write_console_bytes(buf_uva, len),
            fdtable::Kind::Pipe => write_pipe_backed(slot.ptr.cast(), buf_uva, len),
            fdtable::Kind::File => {
                let handle: *mut File = slot.ptr.cast();
                let sb = vfs_sb(handle);
                if sb.is_null() {
                    return -1;
                }
                let (mode, uid, gid) = ((*handle).mode, (*handle).uid, (*handle).gid);
                let (euid, egid) = ((*task).euid, (*task).egid);
                if !perm::check_access(mode, uid, gid, euid, egid, perm::Access::Write) {
                    return -i64::from(EACCES);
                }
                write_file_backed(handle, sb, buf_uva, len)
            }
            fdtable::Kind::None => -1,
        }
    }
}

/// SYS_CLOSE — close any fd kind.
///
/// File fds need an extra step before the slot is cleared: the VFS close runs
/// the backend's flush (FAT32 cluster / dir-entry / FSInfo writeback; initramfs
/// no-op). Pipe and console slots route straight through — the refcount handles
/// the pipe-page free, and console is refcount-exempt.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_close(fd: i32) -> i32 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: the live task owns its fd table.
    let handle = unsafe { fdtable::get_file(task, fd) };
    if !handle.is_null() {
        // SAFETY: an installed handle carries its backing superblock.
        let sb = unsafe { vfs_sb(handle) };
        if !sb.is_null() {
            // SAFETY: the backend flush must not race a task switch.
            unsafe {
                sched::preempt_disable();
                vfs::close(sb, handle);
                sched::preempt_enable();
            }
        }
    }
    // SAFETY: forwarded task contract.
    unsafe { fdtable::close(task, fd) }
}

/// SYS_DUP2 — duplicate `oldfd` onto `newfd`.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_dup2(oldfd: i32, newfd: i32) -> i32 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: forwarded task contract.
    unsafe { fdtable::dup2(task, oldfd, newfd) }
}

// ---- working directory, directory enumeration, kernel log ----

/// Copy a NUL-terminated user path into `kpath`, requiring the terminator.
///
/// Unlike [`copy_resolve_path`] the callers here keep their scratch on the
/// stack, matching the reference: these frames are far shallower than the
/// open/create chain, so they stay clear of the credential tail without the
/// shared statics — and avoiding the statics means they need no preemption
/// exclusion for scratch ownership.
///
/// Returns the path length, or `None` on a copy fault or a path with no NUL
/// inside the buffer.
///
/// # Safety
/// `path_ptr` is a user virtual address owned by the active task.
unsafe fn copy_c_path(path_ptr: u64, kpath: &mut [u8; CWD_SIZE]) -> Option<usize> {
    let mut index = 0;
    while index < CWD_SIZE - 1 {
        let mut byte = 0u8;
        // SAFETY: one byte of writable kernel storage per iteration.
        if unsafe { seam::copy_from_user(&raw mut byte, path_ptr + index as u64, 1) } < 0 {
            return None;
        }
        kpath[index] = byte;
        if byte == 0 {
            return Some(index);
        }
        index += 1;
    }
    // An un-terminated path is rejected rather than truncated: chdir and
    // readdir must never act on a silently different path.
    None
}

/// SYS_CHDIR — store a NUL-terminated, `.`/`..`-collapsed absolute path.
///
/// Relative arguments are joined against the existing cwd and then collapsed;
/// absolute arguments are collapsed in place. There is no backend existence
/// check — readdir lands the directory probe; until then `chdir` is a pure store
/// that the open/execve boundary trusts. Returns 0 on success, -1 on a wild user
/// pointer, an un-NUL-terminated input, or an oversize resolved path.
///
/// # Safety
/// `path_ptr` is a user virtual address owned by the active task.
pub unsafe fn sys_chdir(path_ptr: u64) -> i32 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }

    let mut kpath = [0u8; CWD_SIZE];
    // SAFETY: forwarded user-pointer contract.
    let Some(rel_len) = (unsafe { copy_c_path(path_ptr, &mut kpath) }) else {
        return -1;
    };

    // Resolve into a fresh scratch buffer first and swap into the task slot only
    // after a successful normalisation — this keeps `cwd` intact when the
    // collapse overflows.
    let mut resolved_buf = [0u8; CWD_SIZE];
    // SAFETY: the live task's cwd is a NUL-terminated fixed array.
    let cwd = unsafe { c_str_span(core::ptr::addr_of!((*task).cwd).cast::<u8>(), CWD_SIZE) };
    // Leave one byte for the trailing NUL in cwd[].
    let Some(resolved) =
        path::join_resolve(cwd, &kpath[..rel_len], &mut resolved_buf[..CWD_SIZE - 1])
    else {
        return -1;
    };
    let resolved_len = resolved.len();

    // SAFETY: `resolved_len` < CWD_SIZE, so the copy and its terminator fit.
    unsafe {
        let dst = core::ptr::addr_of_mut!((*task).cwd).cast::<u8>();
        core::ptr::copy_nonoverlapping(resolved_buf.as_ptr(), dst, resolved_len);
        dst.add(resolved_len).write(0);
    }
    0
}

/// SYS_GETCWD — copy the calling task's cwd into the user buffer.
///
/// Writes the path plus its terminator and returns the length excluding the NUL.
/// `cwd` is a plain TaskStruct field, so this allocates nothing and the
/// harness free-page baseline is untouched. Returns -1 on a wild buffer UVA or a
/// `len` too small for the path plus its NUL — a short buffer gets nothing,
/// never a truncated path.
///
/// # Safety
/// `buf_uva` is owned by the active task.
pub unsafe fn sys_getcwd(buf_uva: u64, len: u64) -> i64 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: the live task's cwd is a NUL-terminated fixed array.
    let cwd = unsafe { c_str_span(core::ptr::addr_of!((*task).cwd).cast::<u8>(), CWD_SIZE) };
    if len < cwd.len() as u64 + 1 {
        return -1;
    }
    // SAFETY: the span is live kernel storage for the copy.
    if unsafe { seam::copy_to_user(buf_uva, cwd.as_ptr().cast_mut(), cwd.len() as u64) } < 0 {
        return -1;
    }
    let mut nul = [0u8; 1];
    // SAFETY: one byte of readable kernel storage.
    if unsafe { seam::copy_to_user(buf_uva + cwd.len() as u64, nul.as_mut_ptr(), 1) } < 0 {
        return -1;
    }
    cwd.len() as i64
}

/// SYS_READDIR — fill the `index`-th entry of the directory at `path`.
///
/// A stateless index walk: there is no fd cursor. Returns 0 on a hit and -1 at
/// end-of-directory, on a bad or unmounted path, or on a wild user pointer.
/// Relative paths join against the cwd exactly as the open path does, since the
/// VFS resolve is still absolute-only. Allocates nothing, which is the core
/// reason the ABI is stateless — a future OOM audit inherits no new site here.
///
/// # Safety
/// `path_ptr` and `dirent_uva` are user virtual addresses owned by the task.
pub unsafe fn sys_readdir(path_ptr: u64, index: u64, dirent_uva: u64) -> i32 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }

    let mut kpath = [0u8; CWD_SIZE];
    // SAFETY: forwarded user-pointer contract.
    let Some(raw_len) = (unsafe { copy_c_path(path_ptr, &mut kpath) }) else {
        return -1;
    };

    let mut join_buf = [0u8; CWD_SIZE];
    let resolved_len = if raw_len > 0 && kpath[0] == b'/' {
        join_buf[..raw_len].copy_from_slice(&kpath[..raw_len]);
        raw_len
    } else {
        // SAFETY: the live task's cwd is a NUL-terminated fixed array.
        let cwd = unsafe { c_str_span(core::ptr::addr_of!((*task).cwd).cast::<u8>(), CWD_SIZE) };
        let mut resolved_buf = [0u8; CWD_SIZE];
        let Some(resolved) = path::join_resolve(cwd, &kpath[..raw_len], &mut resolved_buf) else {
            return -1;
        };
        let len = resolved.len();
        join_buf[..len].copy_from_slice(&resolved_buf[..len]);
        len
    };

    let mut dirent = Dirent::default();
    // SAFETY: the readdir walk must not race a task switch.
    unsafe { sched::preempt_disable() };
    let result = unsafe { vfs::readdir(&join_buf[..resolved_len], index, &raw mut dirent) };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };
    if result < 0 {
        return -1;
    }

    // SAFETY: `Dirent` is a fixed-layout record; its bytes are readable here.
    let bytes = (&raw mut dirent).cast::<u8>();
    // SAFETY: the record is live kernel storage for the copy.
    if unsafe { seam::copy_to_user(dirent_uva, bytes, core::mem::size_of::<Dirent>() as u64) } < 0 {
        return -1;
    }
    0
}

/// SYS_KLOG_READ — snapshot the newest `min(len, retained)` ring bytes.
///
/// Copies oldest-first and returns the count (0 on an empty ring). The window
/// head/tail are read once up front so a concurrent kernel-log push cannot move
/// `start` out from under the copy. The bytes bounce through a 512-byte kernel
/// buffer because the ring data wraps the modulo boundary and so is not
/// contiguous for a single copy. Allocates nothing — the ring is static BSS — so
/// the harness free-page baseline is untouched. A wild buffer UVA returns -1
/// through the soft copy path; the task does not zombify.
///
/// # Safety
/// `buf_uva` is owned by the active task.
pub unsafe fn sys_klog_read(buf_uva: u64, len: u64) -> i64 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    if unsafe { sched::current_task() }.is_null() {
        return -1;
    }
    // SAFETY: the seam yields the one kernel-wide ring.
    let ring = unsafe { seam::klog_ring() };

    // Snapshot the window bounds together: head/tail are monotone, so even if a
    // push lands mid-copy the indices stay masked and in-bounds, and reading them
    // as a pair keeps `start` consistent with `total`.
    // SAFETY: the ring is live kernel storage.
    let (head, tail) = unsafe {
        (
            core::ptr::addr_of!((*ring).head).read(),
            core::ptr::addr_of!((*ring).tail).read(),
        )
    };
    let total = len.min(head.wrapping_sub(tail));
    // The most recent `total` bytes.
    let start = head.wrapping_sub(total);

    let mut copied = 0u64;
    while copied < total {
        let mut kbuf = [0u8; 512];
        let take = (total - copied).min(kbuf.len() as u64);
        let mut index = 0u64;
        while index < take {
            // SAFETY: byte_at masks the position into the ring.
            kbuf[index as usize] =
                unsafe { klog_ring::byte_at(ring, start.wrapping_add(copied).wrapping_add(index)) };
            index += 1;
        }
        // SAFETY: `take` bytes of kbuf are initialized above.
        if unsafe { seam::copy_to_user(buf_uva + copied, kbuf.as_mut_ptr(), take) } < 0 {
            return if copied > 0 { copied as i64 } else { -1 };
        }
        copied += take;
    }
    copied as i64
}

// ---- process credentials ----
//
// The identity layer for the login/auth flow. Getters report the calling task's
// real / effective uid / gid (carried on TaskStruct, inherited by fork,
// preserved by execve). setuid / setgid apply a root-gated policy: an euid-0
// caller sets BOTH the real and effective id to any value; a dropped (non-root)
// caller may only reset to an id it already holds — so /bin/login (root) can
// drop to a user, but that user can never climb back. Failure returns -1
// (EPERM-lite); the i64 return makes the sentinel representable.

/// SYS_GETUID — the calling task's real uid.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_getuid() -> i64 {
    // SAFETY: current is always set in EL0 syscall context; the null check is
    // for the impossible case only.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: a non-null current is a live task record.
    i64::from(unsafe { (*task).uid })
}

/// SYS_GETEUID — the calling task's effective uid.
///
/// # Safety
/// See [`sys_getuid`].
pub unsafe fn sys_geteuid() -> i64 {
    // SAFETY: forwarded syscall context.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: a non-null current is a live task record.
    i64::from(unsafe { (*task).euid })
}

/// SYS_GETGID — the calling task's real gid.
///
/// # Safety
/// See [`sys_getuid`].
pub unsafe fn sys_getgid() -> i64 {
    // SAFETY: forwarded syscall context.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: a non-null current is a live task record.
    i64::from(unsafe { (*task).gid })
}

/// SYS_GETEGID — the calling task's effective gid.
///
/// # Safety
/// See [`sys_getuid`].
pub unsafe fn sys_getegid() -> i64 {
    // SAFETY: forwarded syscall context.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: a non-null current is a live task record.
    i64::from(unsafe { (*task).egid })
}

/// SYS_SETUID — root sets both ids; a dropped caller may only reset to an id it
/// already holds, so privilege drops but never climbs back.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_setuid(uid: u32) -> i64 {
    // SAFETY: forwarded syscall context.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: a non-null current is a live task record.
    unsafe {
        if (*task).euid == 0 {
            (*task).uid = uid;
            (*task).euid = uid;
            return 0;
        }
        if uid == (*task).uid || uid == (*task).euid {
            (*task).euid = uid;
            return 0;
        }
    }
    -1
}

/// SYS_SETGID — the gid twin of [`sys_setuid`], same root gate.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_setgid(gid: u32) -> i64 {
    // SAFETY: forwarded syscall context.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }
    // SAFETY: a non-null current is a live task record.
    unsafe {
        if (*task).euid == 0 {
            (*task).gid = gid;
            (*task).egid = gid;
            return 0;
        }
        if gid == (*task).gid || gid == (*task).egid {
            (*task).egid = gid;
            return 0;
        }
    }
    -1
}

// ---- authentication ----

/// The initramfs seed copy — read-only, baked into the kernel image, always
/// present. The recovery anchor of the anti-brick design.
const SHADOW_PATH: &[u8] = b"/etc/shadow";
/// The writable FAT32 copy — what `/bin/passwd` rewrites. Consulted first so
/// password changes take effect; absent on QEMU virt (no SD card) and on a
/// freshly formatted card, in which case auth falls back to the seed.
const MNT_SHADOW_PATH: &[u8] = b"/mnt/shadow";
/// The `/etc/passwd` account database (initramfs, read-only). The password
/// change reads it to map the caller's uid back to a login name. The account
/// LIST is build-time-immutable; only passwords are mutable state.
const PASSWD_PATH: &[u8] = b"/etc/passwd";

// Auth working buffers — static, NOT stack. The per-task kernel stack shares its
// 4 KiB page with TaskStruct (~2.4 KiB usable above KeRegs), and the
// PBKDF2 / HMAC / SHA-256 call frames below already need a large share of that.
// Carrying another ~1.4 KiB of credential / file / digest buffers in the auth
// handler's own frame overflows the page and smashes the TaskStruct tail (fds
// table -> wild vtable dispatch on the next write). Statics sidestep that,
// exactly like the execve staging buffers. Same serialization argument too:
// single core, and the only callers are PID-1's test scenarios, /bin/login, and
// /bin/passwd — never concurrent. The password copy is overwritten by the next
// call; nothing here persists secrets beyond the syscall that wrote them.
static mut AUTH_USER: [u8; AUTH_USER_LEN] = [0; AUTH_USER_LEN];
static mut AUTH_PASS: [u8; AUTH_PASS_LEN] = [0; AUTH_PASS_LEN];
static mut AUTH_FBUF: [u8; AUTH_FBUF_LEN] = [0; AUTH_FBUF_LEN];
static mut AUTH_SALT: [u8; AUTH_SALT_LEN] = [0; AUTH_SALT_LEN];
static mut AUTH_STORED: [u8; AUTH_STORED_LEN] = [0; AUTH_STORED_LEN];
static mut AUTH_DERIVED: [u8; AUTH_DERIVED_LEN] = [0; AUTH_DERIVED_LEN];

// Password-change working buffers — static for the same stack-budget and
// single-caller reasons. The shadow file content and the KDF decode/derive
// scratch live in the auth buffers above: the two handlers never run
// concurrently, so sharing them is free.
static mut PASSWD_USER: [u8; PASSWD_USER_LEN] = [0; PASSWD_USER_LEN];
static mut PASSWD_OLD: [u8; PASSWD_PASS_LEN] = [0; PASSWD_PASS_LEN];
static mut PASSWD_NEW: [u8; PASSWD_PASS_LEN] = [0; PASSWD_PASS_LEN];
static mut PASSWD_PWBUF: [u8; PASSWD_PWBUF_LEN] = [0; PASSWD_PWBUF_LEN];
static mut PASSWD_SALT_RAW: [u8; PASSWD_SALT_RAW_LEN] = [0; PASSWD_SALT_RAW_LEN];
static mut PASSWD_SALT_HEX: [u8; PASSWD_SALT_HEX_LEN] = [0; PASSWD_SALT_HEX_LEN];
static mut PASSWD_HASH_HEX: [u8; PASSWD_HASH_HEX_LEN] = [0; PASSWD_HASH_HEX_LEN];

/// Why an in-kernel whole-file read failed.
///
/// `OpenFailed` = the path does not resolve (not mounted / absent).
/// `ReadFailed` = it resolved but a backend read errored — the corruption
/// signal the fallback chain reports loudly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ReadFileError {
    OpenFailed,
    ReadFailed,
}

/// In-kernel whole-file read through the privileged VFS door.
///
/// The `File` lives on the stack: no allocation, so no page, so the harness
/// free-page baseline is untouched. Each VFS call is preempt-guarded. Returns
/// the filled prefix length of `buf`.
///
/// # Safety
/// Called from serialized syscall context.
unsafe fn read_whole_file(path: &[u8], buf: &mut [u8]) -> Result<usize, ReadFileError> {
    let mut open_result = vfs::OpenResult::default();
    // SAFETY: the resolve must not race a task switch.
    unsafe { sched::preempt_disable() };
    let sb = unsafe { vfs::open(path, &raw mut open_result) };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };
    if sb.is_null() {
        return Err(ReadFileError::OpenFailed);
    }

    let mut handle = File {
        private: open_result.private,
        size: open_result.size,
        offset: 0,
        ..File::default()
    };

    let mut off = 0usize;
    let mut failed = false;
    while off < buf.len() {
        let take = (buf.len() - off) as u64;
        // SAFETY: the backend read must not race a task switch.
        unsafe { sched::preempt_disable() };
        let got = unsafe { vfs::read(sb, &raw mut handle, buf.as_mut_ptr().add(off), take) };
        // SAFETY: pairs with the preempt_disable above.
        unsafe { sched::preempt_enable() };
        if got < 0 {
            failed = true;
            break;
        }
        if got == 0 {
            break;
        }
        off += got as usize;
    }
    // SAFETY: the flush must not race a task switch.
    unsafe { sched::preempt_disable() };
    unsafe { vfs::close(sb, &raw mut handle) };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };

    if failed {
        return Err(ReadFileError::ReadFailed);
    }
    Ok(off)
}

/// In-kernel whole-file overwrite through the privileged VFS door.
///
/// The caller guarantees `content.len()` equals the file's current size (the
/// same-length rewrite contract), so the write never grows the file and the
/// FAT32 dir-entry resize branch is never taken.
///
/// # Safety
/// Called from serialized syscall context.
unsafe fn write_whole_file(path: &[u8], content: &[u8]) -> bool {
    let mut open_result = vfs::OpenResult::default();
    // SAFETY: the resolve must not race a task switch.
    unsafe { sched::preempt_disable() };
    let sb = unsafe { vfs::open(path, &raw mut open_result) };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };
    if sb.is_null() {
        return false;
    }

    let mut handle = File {
        private: open_result.private,
        size: open_result.size,
        offset: 0,
        ..File::default()
    };

    let mut off = 0usize;
    let mut ok = true;
    while off < content.len() {
        // SAFETY: the backend write must not race a task switch.
        unsafe { sched::preempt_disable() };
        let n = unsafe {
            vfs::write(
                sb,
                &raw mut handle,
                content.as_ptr().add(off),
                (content.len() - off) as u64,
            )
        };
        // SAFETY: pairs with the preempt_disable above.
        unsafe { sched::preempt_enable() };
        if n <= 0 {
            ok = false;
            break;
        }
        off += n as usize;
    }
    // SAFETY: the flush must not race a task switch.
    unsafe { sched::preempt_disable() };
    unsafe { vfs::close(sb, &raw mut handle) };
    // SAFETY: pairs with the preempt_disable above.
    unsafe { sched::preempt_enable() };
    ok
}

/// Outcome of checking one credential pair against one shadow database.
///
/// The distinction between `NoUser` and `Corrupt` drives the fallback chain: a
/// parseable file that simply lacks the user is an authoritative denial, while a
/// file with nothing parseable in it (truncation, garbage, a half-finished
/// rewrite) falls back to the initramfs seed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerifyResult {
    Match,
    Mismatch,
    NoUser,
    Corrupt,
}

/// Verify `password` against the first line of `content` whose user field equals
/// `username`.
///
/// Uses the shared salt / stored / derived scratch (single-caller discipline).
///
/// # Safety
/// The caller owns the shared auth scratch for the duration of the call.
unsafe fn verify_against(content: &[u8], username: &[u8], password: &[u8]) -> VerifyResult {
    let mut any_parseable = false;
    let mut line_start = 0usize;
    let mut k = 0usize;
    while k <= content.len() {
        if k == content.len() || content[k] == b'\n' {
            let line = &content[line_start..k];
            line_start = k + 1;
            if !line.is_empty() {
                if let Some(entry) = shadow::parse_line(line) {
                    any_parseable = true;
                    // Demo-grade ceiling: PBKDF2 runs only after a username match, so a
                    // miss returns sooner than a hit — a username-enumeration timing
                    // oracle. Left unmitigated on purpose: the shipped accounts are
                    // build-time public, so the oracle reveals nothing secret. If
                    // accounts ever become private, run a dummy KDF on the miss path so
                    // a miss costs the same as a hit.
                    if entry.user == username {
                        // SAFETY: the caller owns the shared scratch; the slices are
                        // derived from raw pointers, so no `&mut` to the statics
                        // themselves is manufactured.
                        let (salt, stored, derived) = unsafe {
                            (
                                core::slice::from_raw_parts_mut(
                                    (&raw mut AUTH_SALT).cast::<u8>(),
                                    AUTH_SALT_LEN,
                                ),
                                core::slice::from_raw_parts_mut(
                                    (&raw mut AUTH_STORED).cast::<u8>(),
                                    AUTH_STORED_LEN,
                                ),
                                core::slice::from_raw_parts_mut(
                                    (&raw mut AUTH_DERIVED).cast::<u8>(),
                                    AUTH_DERIVED_LEN,
                                ),
                            )
                        };
                        // A matching line with undecodable hex is corruption, not denial.
                        let Some(salt_n) = shadow::hex_decode(entry.salt_hex, salt) else {
                            return VerifyResult::Corrupt;
                        };
                        let Some(hash_n) = shadow::hex_decode(entry.hash_hex, stored) else {
                            return VerifyResult::Corrupt;
                        };
                        if hash_n == 0 || hash_n > 32 {
                            return VerifyResult::Corrupt;
                        }

                        sha256::pbkdf2_hmac_sha256(
                            password,
                            &salt[..salt_n],
                            entry.iterations,
                            &mut derived[..hash_n],
                        );
                        if sha256::ct_eql(&derived[..hash_n], &stored[..hash_n]) {
                            return VerifyResult::Match;
                        }
                        return VerifyResult::Mismatch;
                    }
                }
            }
        }
        k += 1;
    }
    if any_parseable {
        VerifyResult::NoUser
    } else {
        VerifyResult::Corrupt
    }
}

/// Emit one `[Debug]`-tagged line on the Mini-UART.
///
/// Kernel diagnostics deliberately bypass the console mux so they stay on the
/// UART regardless of USB state. The mark and the text are emitted as two
/// C-strings, which puts the same bytes on the wire as one concatenated literal
/// while keeping the marker single-sourced.
///
/// # Safety
/// Both pointers are NUL-terminated static strings.
unsafe fn debug_line(text: *const u8) {
    // SAFETY: DEBUG_MARK is a static byte string; it carries no NUL, so it is
    // emitted through the NUL-terminated copy kept beside it.
    unsafe {
        seam::mini_uart_out(DEBUG_MARK_C.as_ptr());
        seam::mini_uart_out(text);
    }
}

/// NUL-terminated form of the frozen `[Debug] ` marker. The assertion below is
/// the single-source guard: if the marker ever changes, this fails to compile
/// rather than silently drifting from the boot-log contract.
const DEBUG_MARK_C: &[u8] = b"[Debug] \0";
const _: () = assert!(
    matches!(DEBUG_MARK_C.split_last(), Some((0, rest)) if rest.len() == tags::DEBUG_MARK.len())
);

/// SYS_AUTHENTICATE — the kernel-owned credential verifier.
///
/// `/bin/login` passes a username and plaintext password; the kernel reads the
/// active shadow database, finds the matching line, runs PBKDF2-HMAC-SHA256 over
/// the password with the stored salt and iteration count, and constant-time
/// compares the result to the stored verifier. Returns 0 on a match and -1 on
/// anything else (no such user, malformed line, wild pointer, hash mismatch).
/// Userland never sees a salt or hash — only pass/fail.
///
/// Shadow source order: the writable FAT32 copy is authoritative when present
/// and parseable — that is where the password change writes. The initramfs seed
/// is the fallback for QEMU virt (no SD), a fresh card, or a corrupt FAT32 copy;
/// the latter two announce themselves loudly (anti-brick: corruption never locks
/// the operator out, it falls back to the baked-in seed credentials).
///
/// The plaintext password crosses the user/kernel boundary exactly once, into a
/// static scratch buffer that the next call overwrites.
///
/// # Safety
/// The four user addresses are owned by the active task.
pub unsafe fn sys_authenticate(user_uva: u64, user_len: u64, pass_uva: u64, pass_len: u64) -> i64 {
    // SAFETY: forwarded syscall context.
    let result = unsafe { authenticate_inner(user_uva, user_len, pass_uva, pass_len) };
    // Scrub the plaintext password and the derived verifier on every exit path.
    // These live in static BSS (single-caller scratch), so without this the last
    // login's secret lingers until the next call happens to overwrite it — a
    // post-boot memory dump could lift it. Runs after the result is computed, so
    // pass/fail timing is unchanged.
    // SAFETY: single-core scratch owned by this call.
    unsafe {
        core::ptr::write_bytes((&raw mut AUTH_PASS).cast::<u8>(), 0, AUTH_PASS_LEN);
        core::ptr::write_bytes((&raw mut AUTH_DERIVED).cast::<u8>(), 0, AUTH_DERIVED_LEN);
    }
    result
}

const AUTH_USER_LEN: usize = 64;
const AUTH_SALT_LEN: usize = 64;
const AUTH_STORED_LEN: usize = 64;
const PASSWD_SALT_RAW_LEN: usize = 16;
const PASSWD_SALT_HEX_LEN: usize = 32;
const PASSWD_HASH_HEX_LEN: usize = 64;
const AUTH_PASS_LEN: usize = 128;
const AUTH_FBUF_LEN: usize = 1024;
const AUTH_DERIVED_LEN: usize = 32;
const PASSWD_USER_LEN: usize = 64;
const PASSWD_PASS_LEN: usize = 128;
const PASSWD_PWBUF_LEN: usize = 512;

/// [`sys_authenticate`]'s body. Split out so the scrub covers every return.
///
/// # Safety
/// See [`sys_authenticate`].
unsafe fn authenticate_inner(user_uva: u64, user_len: u64, pass_uva: u64, pass_len: u64) -> i64 {
    // SAFETY: current is always set in EL0 syscall context.
    if unsafe { sched::current_task() }.is_null() {
        return -1;
    }

    // Copy the credentials under hard caps. Soft-fail on overflow or a wild UVA
    // (same contract as the open path — no zombify).
    if user_len == 0 || user_len > AUTH_USER_LEN as u64 {
        return -1;
    }
    if pass_len > AUTH_PASS_LEN as u64 {
        return -1;
    }
    // SAFETY: the caps above bound both copies inside their static buffers.
    unsafe {
        if seam::copy_from_user((&raw mut AUTH_USER).cast::<u8>(), user_uva, user_len) < 0 {
            return -1;
        }
        if pass_len > 0
            && seam::copy_from_user((&raw mut AUTH_PASS).cast::<u8>(), pass_uva, pass_len) < 0
        {
            return -1;
        }
    }
    // SAFETY: single-core scratch owned by this call.
    let (username, password) = unsafe {
        (
            core::slice::from_raw_parts((&raw const AUTH_USER).cast::<u8>(), user_len as usize),
            core::slice::from_raw_parts((&raw const AUTH_PASS).cast::<u8>(), pass_len as usize),
        )
    };

    // 1. The writable FAT32 shadow, when it exists and is intact.
    // SAFETY: single-core scratch owned by this call.
    let fbuf = unsafe {
        core::slice::from_raw_parts_mut((&raw mut AUTH_FBUF).cast::<u8>(), AUTH_FBUF_LEN)
    };
    // SAFETY: forwarded syscall context.
    match unsafe { read_whole_file(MNT_SHADOW_PATH, fbuf) } {
        Ok(len) => {
            // SAFETY: the content and scratch are owned by this call.
            let content =
                unsafe { core::slice::from_raw_parts((&raw const AUTH_FBUF).cast::<u8>(), len) };
            match unsafe { verify_against(content, username, password) } {
                VerifyResult::Match => return 0,
                VerifyResult::Mismatch | VerifyResult::NoUser => return -1,
                // Nothing parseable -> announce + fall through to the seed.
                VerifyResult::Corrupt => unsafe {
                    debug_line(
                        c"/mnt/shadow corrupt - falling back to initramfs seed\n"
                            .as_ptr()
                            .cast(),
                    )
                },
            }
        }
        // OpenFailed is the normal miss (virt / fresh card) -> silent.
        // ReadFailed means the file is there but unreadable -> announce.
        Err(ReadFileError::ReadFailed) => unsafe {
            debug_line(
                c"/mnt/shadow unreadable - falling back to initramfs seed\n"
                    .as_ptr()
                    .cast(),
            )
        },
        Err(ReadFileError::OpenFailed) => {}
    }

    // 2. The initramfs seed (always present, read-only).
    // SAFETY: forwarded syscall context.
    let Ok(len) = (unsafe { read_whole_file(SHADOW_PATH, fbuf) }) else {
        return -1;
    };
    // SAFETY: the content and scratch are owned by this call.
    let content = unsafe { core::slice::from_raw_parts((&raw const AUTH_FBUF).cast::<u8>(), len) };
    match unsafe { verify_against(content, username, password) } {
        VerifyResult::Match => 0,
        _ => -1,
    }
}

/// SYS_PASSWD — kernel-owned password change.
///
/// Rewrites `user`'s record in the writable FAT32 shadow with a fresh
/// kernel-minted salt and a PBKDF2 re-hash of the new password, in place and at
/// the same byte length (the splice-safety contract).
///
/// Authorization: root (euid 0) may change any record without the old password —
/// this is the recovery path. Everyone else may change only the record whose
/// login name maps to their own uid via `/etc/passwd`, and only with the correct
/// old password. Violations return `-EACCES`.
///
/// Returns 0 on success; `-EACCES` on an authorization failure; -1 when there is
/// no writable shadow (QEMU virt / fresh card — the FAT32 copy is the only
/// rewrite target, the initramfs seed is immutable), the target user has no
/// shadow record, the input is malformed, or the rewrite would change the record
/// length.
///
/// The salt source is the kernel entropy fallback (timer mix) — weak but fresh
/// per change; the RNG200 hardware source is a named carve-out.
///
/// # Safety
/// The six user addresses are owned by the active task.
pub unsafe fn sys_passwd(
    user_uva: u64,
    user_len: u64,
    old_uva: u64,
    old_len: u64,
    new_uva: u64,
    new_len: u64,
) -> i64 {
    // SAFETY: forwarded syscall context.
    let result = unsafe { passwd_inner(user_uva, user_len, old_uva, old_len, new_uva, new_len) };
    // Scrub both plaintexts and the derived verifier on every exit path (same
    // rationale as the auth handler). The salt/hash hex are public verifier
    // material, not secret, so they need no scrub.
    // SAFETY: single-core scratch owned by this call.
    unsafe {
        core::ptr::write_bytes((&raw mut PASSWD_OLD).cast::<u8>(), 0, PASSWD_PASS_LEN);
        core::ptr::write_bytes((&raw mut PASSWD_NEW).cast::<u8>(), 0, PASSWD_PASS_LEN);
        core::ptr::write_bytes((&raw mut AUTH_DERIVED).cast::<u8>(), 0, AUTH_DERIVED_LEN);
    }
    result
}

/// [`sys_passwd`]'s body. Split out so the scrub covers every return.
///
/// # Safety
/// See [`sys_passwd`].
unsafe fn passwd_inner(
    user_uva: u64,
    user_len: u64,
    old_uva: u64,
    old_len: u64,
    new_uva: u64,
    new_len: u64,
) -> i64 {
    // SAFETY: the scheduler publishes a live current task before EL0 runs.
    let task = unsafe { sched::current_task() };
    if task.is_null() {
        return -1;
    }

    // Copy all three strings under hard caps (same soft-fail contract).
    if user_len == 0 || user_len > PASSWD_USER_LEN as u64 {
        return -1;
    }
    if old_len > PASSWD_PASS_LEN as u64 {
        return -1;
    }
    if new_len == 0 || new_len > PASSWD_PASS_LEN as u64 {
        return -1;
    }
    // SAFETY: the caps above bound every copy inside its static buffer.
    unsafe {
        if seam::copy_from_user((&raw mut PASSWD_USER).cast::<u8>(), user_uva, user_len) < 0 {
            return -1;
        }
        if old_len > 0
            && seam::copy_from_user((&raw mut PASSWD_OLD).cast::<u8>(), old_uva, old_len) < 0
        {
            return -1;
        }
        if seam::copy_from_user((&raw mut PASSWD_NEW).cast::<u8>(), new_uva, new_len) < 0 {
            return -1;
        }
    }
    // SAFETY: single-core scratch owned by this call.
    let (username, old_password, new_password) = unsafe {
        (
            core::slice::from_raw_parts((&raw const PASSWD_USER).cast::<u8>(), user_len as usize),
            core::slice::from_raw_parts((&raw const PASSWD_OLD).cast::<u8>(), old_len as usize),
            core::slice::from_raw_parts((&raw const PASSWD_NEW).cast::<u8>(), new_len as usize),
        )
    };
    // SAFETY: a non-null current is a live task record.
    let (euid, uid) = unsafe { ((*task).euid, (*task).uid) };

    // Authorization for non-root callers: own record only.
    if euid != 0 {
        // SAFETY: single-core scratch owned by this call.
        let pwbuf = unsafe {
            core::slice::from_raw_parts_mut((&raw mut PASSWD_PWBUF).cast::<u8>(), PASSWD_PWBUF_LEN)
        };
        // SAFETY: forwarded syscall context.
        let Ok(pw_len) = (unsafe { read_whole_file(PASSWD_PATH, pwbuf) }) else {
            return -1;
        };
        // SAFETY: the content is owned by this call.
        let pw_content =
            unsafe { core::slice::from_raw_parts((&raw const PASSWD_PWBUF).cast::<u8>(), pw_len) };
        let Some(own) = pwfile::lookup_by_uid(pw_content, uid) else {
            return -i64::from(EACCES);
        };
        if own.user != username {
            return -i64::from(EACCES);
        }
    }

    // The rewrite target must exist and be readable: the FAT32 copy only. Its
    // absence is the graceful no-writable-shadow case (QEMU virt).
    // SAFETY: single-core scratch owned by this call.
    let fbuf = unsafe {
        core::slice::from_raw_parts_mut((&raw mut AUTH_FBUF).cast::<u8>(), AUTH_FBUF_LEN)
    };
    // SAFETY: forwarded syscall context.
    let Ok(content_len) = (unsafe { read_whole_file(MNT_SHADOW_PATH, fbuf) }) else {
        return -1;
    };
    // SAFETY: the content is owned by this call.
    let content =
        unsafe { core::slice::from_raw_parts((&raw const AUTH_FBUF).cast::<u8>(), content_len) };

    // The target record must exist and parse — its iteration count is kept by
    // the rewrite, which is half of the same-length contract.
    let Some(span) = shadow::find_user_line(content, username) else {
        return -1;
    };
    let Some(old_entry) = shadow::parse_line(&content[span.start..span.end]) else {
        return -1;
    };
    let iterations = old_entry.iterations;

    // Non-root callers must prove knowledge of the old password against the very
    // record being replaced.
    if euid != 0 {
        // SAFETY: the scratch is owned by this call.
        match unsafe { verify_against(content, username, old_password) } {
            VerifyResult::Match => {}
            VerifyResult::Mismatch | VerifyResult::NoUser => return -i64::from(EACCES),
            VerifyResult::Corrupt => return -1,
        }
    }

    // Mint the new verifier: fresh salt, PBKDF2 over the new password with the
    // record's existing iteration count, both hex-encoded at the fixed widths the
    // same-length contract relies on.
    // SAFETY: single-core scratch owned by this call.
    let (salt_raw, salt_hex, hash_hex, derived) = unsafe {
        (
            core::slice::from_raw_parts_mut(
                (&raw mut PASSWD_SALT_RAW).cast::<u8>(),
                PASSWD_SALT_RAW_LEN,
            ),
            core::slice::from_raw_parts_mut(
                (&raw mut PASSWD_SALT_HEX).cast::<u8>(),
                PASSWD_SALT_HEX_LEN,
            ),
            core::slice::from_raw_parts_mut(
                (&raw mut PASSWD_HASH_HEX).cast::<u8>(),
                PASSWD_HASH_HEX_LEN,
            ),
            core::slice::from_raw_parts_mut((&raw mut AUTH_DERIVED).cast::<u8>(), AUTH_DERIVED_LEN),
        )
    };
    // SAFETY: the entropy fallback is initialized during bring-up.
    unsafe { seam::hwrng_fill(salt_raw) };
    if shadow::hex_encode(salt_raw, salt_hex).is_none() {
        return -1;
    }
    sha256::pbkdf2_hmac_sha256(new_password, salt_raw, iterations, &mut derived[..32]);
    if shadow::hex_encode(&derived[..32], hash_hex).is_none() {
        return -1;
    }

    // Same-length in-place rewrite, then push the whole file back. The file
    // content is still in the shared buffer; rewrite it there.
    // SAFETY: the buffer is owned by this call and holds `content_len` bytes.
    let mut_content =
        unsafe { core::slice::from_raw_parts_mut((&raw mut AUTH_FBUF).cast::<u8>(), content_len) };
    if !shadow::rewrite_line_in_place(mut_content, username, salt_hex, hash_hex) {
        return -1;
    }

    // SAFETY: forwarded syscall context.
    if !unsafe { write_whole_file(MNT_SHADOW_PATH, mut_content) } {
        return -1;
    }
    0
}

/// SYS_DUMP_FREE — print and return the free-page count at a checkpoint.
///
/// # Safety
/// Called from serialized syscall context.
pub unsafe fn sys_dump_free() -> u64 {
    // SAFETY: forwarded checkpoint contract.
    unsafe { seam::free_count() }
}

/// SYS_MEMTOTAL — allocatable pool size in pages, frozen at boot.
///
/// A tool derives "used" as this minus SYS_DUMP_FREE, and "total bytes" as
/// pages << 12.
///
/// # Safety
/// Called from syscall context after boot reservations completed.
pub unsafe fn sys_mem_total() -> u64 {
    // SAFETY: forwarded pool contract.
    unsafe { seam::total_count() }
}

/// SYS_UPTIME — seconds since boot, from the architectural counter.
///
/// # Safety
/// Called from syscall context.
pub unsafe fn sys_uptime() -> u64 {
    // SAFETY: forwarded counter contract.
    unsafe { seam::uptime() }
}

/// SYS_CPU_TEMP — SoC temperature in milli-degrees Celsius (0 = unknown).
///
/// Runs a mailbox transaction over the shared prop_buf; the preemption
/// exclusion serialises that single-core-shared static against a task switch
/// landing mid-transaction.
///
/// # Safety
/// Called from syscall context.
pub unsafe fn sys_cpu_temp() -> u64 {
    // SAFETY: forwarded syscall context.
    unsafe {
        sched::preempt_disable();
        let milli = seam::mailbox_temperature();
        sched::preempt_enable();
        u64::from(milli)
    }
}

/// SYS_CPU_FREQ — ARM clock in Hz (0 = unknown).
///
/// Shares [`sys_cpu_temp`]'s prop_buf exclusion.
///
/// # Safety
/// Called from syscall context.
pub unsafe fn sys_cpu_freq() -> u64 {
    // SAFETY: forwarded syscall context.
    unsafe {
        sched::preempt_disable();
        let hz = seam::mailbox_cpu_clock();
        sched::preempt_enable();
        u64::from(hz)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::ptr::null_mut;
    use flashos_abi::task::{TASK_RUNNING, TASK_ZOMBIE};
    use std::sync::{Mutex, MutexGuard};

    /// The kill tests publish the scheduler's `current`/`task` globals, which
    /// the host suite shares across threads; serialize them the way the fork
    /// tests serialize their own state.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> MutexGuard<'static, ()> {
        TEST_LOCK
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn task_ptr(task: &mut TaskStruct) -> *mut TaskStruct {
        task as *mut TaskStruct
    }

    fn task_with_pid(pid: i32) -> TaskStruct {
        let mut task: TaskStruct = unsafe { core::mem::zeroed() };
        task.pid = pid;
        task
    }

    #[test]
    fn find_task_by_pid_locates_an_occupied_slot() {
        let mut first = task_with_pid(7);
        let mut second = task_with_pid(9);
        let tasks = [null_mut(), &raw mut first, &raw mut second];

        assert_eq!(
            unsafe { find_task_by_pid(tasks.as_ptr(), tasks.len(), 9) },
            Some(2)
        );
    }

    #[test]
    fn find_task_by_pid_skips_free_slots_and_misses() {
        let mut only = task_with_pid(3);
        let tasks = [null_mut(), &raw mut only, null_mut()];

        assert_eq!(
            unsafe { find_task_by_pid(tasks.as_ptr(), tasks.len(), 4) },
            None
        );
    }

    #[test]
    fn find_task_by_pid_returns_the_first_match() {
        let mut first = task_with_pid(5);
        let mut duplicate = task_with_pid(5);
        let tasks = [&raw mut first, &raw mut duplicate];

        assert_eq!(
            unsafe { find_task_by_pid(tasks.as_ptr(), tasks.len(), 5) },
            Some(0)
        );
    }

    #[test]
    fn find_task_by_pid_on_an_empty_table_misses() {
        let tasks: [*mut TaskStruct; 0] = [];

        assert_eq!(
            unsafe { find_task_by_pid(tasks.as_ptr(), tasks.len(), 1) },
            None
        );
    }

    /// Publish `task` as current with a heap break already at `brk`.
    ///
    /// # Safety
    /// The caller holds the module test lock.
    unsafe fn stage_brk(task: &mut TaskStruct, brk: u64) {
        task.mm.brk = brk;
        task.mm.pgd = 0xdead_0000;
        unsafe { sched::set_test_state(task as *mut TaskStruct, &[task as *mut TaskStruct]) };
        seam::reset_vm_log();
    }

    #[test]
    fn sys_brk_reports_the_current_break_for_zero() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE + 0x4000) };

        assert_eq!(unsafe { sys_brk(0) }, (HEAP_BASE + 0x4000) as i64);
        assert_eq!(task.mm.brk, HEAP_BASE + 0x4000);
        assert_eq!(seam::unmapped_range(), None);
    }

    #[test]
    fn sys_brk_rounds_up_to_the_next_page() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE) };

        assert_eq!(
            unsafe { sys_brk(HEAP_BASE + 1) },
            (HEAP_BASE + 0x1000) as i64
        );
        assert_eq!(task.mm.brk, HEAP_BASE + 0x1000);
    }

    /// A grow must not eagerly map or flush: the fault path demand-allocates.
    #[test]
    fn sys_brk_grow_neither_unmaps_nor_reinstalls_the_pgd() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE) };

        assert_eq!(
            unsafe { sys_brk(HEAP_BASE + 0x8000) },
            (HEAP_BASE + 0x8000) as i64
        );
        assert_eq!(seam::unmapped_range(), None);
        assert_eq!(seam::pgd_installs(), 0);
    }

    /// A shrink MUST free the released range here — the reap loop only runs at
    /// process exit, so a grow/shrink cycle would otherwise leak — and must
    /// reinstall the pgd so a re-grow re-faults cleanly.
    #[test]
    fn sys_brk_shrink_unmaps_the_released_range_and_flushes() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE + 0x8000) };

        assert_eq!(
            unsafe { sys_brk(HEAP_BASE + 0x2000) },
            (HEAP_BASE + 0x2000) as i64
        );
        assert_eq!(
            seam::unmapped_range(),
            Some((HEAP_BASE + 0x2000, HEAP_BASE + 0x8000))
        );
        assert_eq!(seam::pgd_installs(), 1);
        assert_eq!(task.mm.brk, HEAP_BASE + 0x2000);
    }

    #[test]
    fn sys_brk_rejects_below_the_heap_base() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE + 0x1000) };

        assert_eq!(unsafe { sys_brk(HEAP_BASE - 0x1000) }, -1);
        // A rejected request must not move the break or touch the mapping.
        assert_eq!(task.mm.brk, HEAP_BASE + 0x1000);
        assert_eq!(seam::unmapped_range(), None);
    }

    #[test]
    fn sys_brk_rejects_above_the_stack_budget_bound() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE) };

        assert_eq!(unsafe { sys_brk(STACK_TOP - STACK_BUDGET + 0x1000) }, -1);
        assert_eq!(task.mm.brk, HEAP_BASE);
    }

    /// The bound is inclusive: exactly `STACK_TOP - STACK_BUDGET` is allowed.
    #[test]
    fn sys_brk_accepts_exactly_the_stack_budget_bound() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE) };

        let bound = STACK_TOP - STACK_BUDGET;
        assert_eq!(unsafe { sys_brk(bound) }, bound as i64);
    }

    #[test]
    fn sys_sbrk_returns_the_previous_break_and_moves_it() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE + 0x1000) };

        assert_eq!(unsafe { sys_sbrk(0x2000) }, (HEAP_BASE + 0x1000) as i64);
        assert_eq!(task.mm.brk, HEAP_BASE + 0x3000);
    }

    #[test]
    fn sys_sbrk_shrinks_on_a_negative_delta() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE + 0x4000) };

        assert_eq!(unsafe { sys_sbrk(-0x2000) }, (HEAP_BASE + 0x4000) as i64);
        assert_eq!(task.mm.brk, HEAP_BASE + 0x2000);
        assert_eq!(
            seam::unmapped_range(),
            Some((HEAP_BASE + 0x2000, HEAP_BASE + 0x4000))
        );
    }

    /// sbrk's own guard is overflow only; the range bounds are brk's job.
    #[test]
    fn sys_sbrk_rejects_a_signed_overflow() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE) };

        assert_eq!(unsafe { sys_sbrk(i64::MAX) }, -1);
        assert_eq!(task.mm.brk, HEAP_BASE);
    }

    #[test]
    fn sys_sbrk_rejects_a_delta_below_zero() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_brk(&mut task, HEAP_BASE) };

        assert_eq!(unsafe { sys_sbrk(-(HEAP_BASE as i64) - 0x1000) }, -1);
        assert_eq!(task.mm.brk, HEAP_BASE);
    }

    /// The compact pipe ABI packs both fds into one register.
    #[test]
    fn sys_pipe_packs_the_write_fd_high_and_read_fd_low() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]) };

        let packed = unsafe { sys_pipe() };
        assert!(packed >= 0, "pipe allocation failed: {packed}");
        let rfd = (packed & 0xFFFF_FFFF) as i32;
        let wfd = (packed >> 32) as i32;
        assert_eq!(rfd, 0);
        assert_eq!(wfd, 1);
        // Both ends share one pipe, one reference each.
        let read_pipe = unsafe { fdtable::get_pipe(task_ptr(&mut task), rfd) };
        let write_pipe = unsafe { fdtable::get_pipe(task_ptr(&mut task), wfd) };
        assert!(!read_pipe.is_null());
        assert_eq!(read_pipe, write_pipe);
        assert_eq!(unsafe { (*read_pipe).refs }, 2);
    }

    /// Stage a console-backed fd 0 and a clean tx log.
    ///
    /// # Safety
    /// The caller holds the module test lock.
    unsafe fn stage_console(task: &mut TaskStruct) {
        unsafe {
            sched::set_test_state(task_ptr(task), &[task_ptr(task)]);
            fdtable::install(
                task_ptr(task),
                fdtable::Kind::Console,
                core::ptr::null_mut(),
            );
            sys_set_console_mode(0);
            seam::set_fault(false);
            seam::reset_tx();
        }
    }

    #[test]
    fn write_console_bytes_pushes_the_payload_to_the_mini_uart() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };
        unsafe { seam::set_user_bytes(b"hello") };

        assert_eq!(unsafe { sys_write(0, 0, 5) }, 5);
        assert_eq!(seam::tx_bytes(), b"hello".to_vec());
    }

    /// Once the gadget enumerates, user output switches to the USB bulk path.
    /// It is a switch, not a tee.
    #[test]
    fn write_console_bytes_switches_to_usb_when_enumerated() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };
        seam::set_enumerated(true);
        unsafe { seam::set_user_bytes(b"usb") };

        assert_eq!(unsafe { sys_write(0, 0, 3) }, 3);
        assert_eq!(seam::tx_bytes(), b"usb".to_vec());
        seam::set_enumerated(false);
    }

    /// The chunk bound is 255 payload bytes plus the NUL the C-string
    /// fallback requires, so a longer write must span chunks and still total.
    #[test]
    fn write_console_bytes_chunks_at_255_payload_bytes() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };
        let payload = std::vec::Vec::from_iter(core::iter::repeat_n(b'x', 300));
        unsafe { seam::set_user_bytes(&payload) };

        assert_eq!(unsafe { sys_write(0, 0, 300) }, 300);
        assert_eq!(seam::tx_bytes().len(), 300);
    }

    /// A fault with bytes already pushed reports the partial count, not -1 —
    /// the caller must be able to tell progress from total failure.
    #[test]
    fn write_console_bytes_reports_minus_one_only_without_progress() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };
        seam::set_fault(true);

        assert_eq!(unsafe { sys_write(0, 0, 10) }, -1);
        seam::set_fault(false);
    }

    /// Both flags off is the historical default: the kernel never echoes, so
    /// every existing scenario's serial output stays byte-identical.
    #[test]
    fn console_read_does_not_echo_by_default() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };
        unsafe { console::console_test_push(b'a') };

        assert_eq!(unsafe { sys_read(0, 0, 4) }, 1);
        assert_eq!(seam::tx_bytes(), std::vec::Vec::new());
    }

    #[test]
    fn console_read_echoes_printable_bytes_when_echo_is_on() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };
        unsafe { sys_set_console_mode(CONSOLE_MODE_ECHO) };
        unsafe {
            console::console_test_push(b'h');
            console::console_test_push(b'i');
        }

        assert_eq!(unsafe { sys_read(0, 0, 4) }, 2);
        assert_eq!(seam::tx_bytes(), b"hi".to_vec());
        unsafe { sys_set_console_mode(0) };
    }

    /// Mask wins over echo — the password must never reach the wire.
    #[test]
    fn console_read_masks_instead_of_echoing_when_both_are_on() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };
        unsafe { sys_set_console_mode(CONSOLE_MODE_ECHO | CONSOLE_MODE_MASK) };
        unsafe {
            console::console_test_push(b's');
            console::console_test_push(b'e');
            console::console_test_push(b'c');
        }

        assert_eq!(unsafe { sys_read(0, 0, 8) }, 3);
        assert_eq!(seam::tx_bytes(), b"***".to_vec());
        unsafe { sys_set_console_mode(0) };
    }

    /// Control bytes are never echoed, which is what keeps CR/LF and the
    /// test-inject bytes out of the serial log.
    #[test]
    fn console_read_never_echoes_control_bytes() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };
        unsafe { sys_set_console_mode(CONSOLE_MODE_ECHO) };
        unsafe {
            console::console_test_push(b'\r');
            console::console_test_push(b'\n');
            console::console_test_push(0xC3);
            console::console_test_push(b'z');
        }

        assert_eq!(unsafe { sys_read(0, 0, 8) }, 4);
        assert_eq!(seam::tx_bytes(), b"z".to_vec());
        unsafe { sys_set_console_mode(0) };
    }

    #[test]
    fn sys_set_console_mode_maps_each_flag_bit() {
        let _guard = lock();
        unsafe {
            assert_eq!(sys_set_console_mode(CONSOLE_MODE_ECHO), 0);
            assert!((&raw const CONSOLE_ECHO).read());
            assert!(!(&raw const CONSOLE_MASK).read());

            sys_set_console_mode(CONSOLE_MODE_MASK);
            assert!(!(&raw const CONSOLE_ECHO).read());
            assert!((&raw const CONSOLE_MASK).read());

            sys_set_console_mode(0);
            assert!(!(&raw const CONSOLE_ECHO).read());
            assert!(!(&raw const CONSOLE_MASK).read());
        }
    }

    /// Retired slots must answer -1 forever: a stale binary invoking one gets a
    /// clean failure, never a silently different syscall.
    #[test]
    fn sys_retired_always_reports_minus_one() {
        assert_eq!(sys_retired(), -1);
    }

    #[test]
    fn sys_read_and_write_reject_an_unopened_fd() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]) };

        assert_eq!(unsafe { sys_read(7, 0, 1) }, -1);
        assert_eq!(unsafe { sys_write(7, 0, 1) }, -1);
    }

    /// Pipe round-trip through the unified dispatchers: what the write fd takes
    /// in, the read fd gives back.
    #[test]
    fn unified_read_write_round_trips_a_pipe() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe {
            sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]);
            seam::set_fault(false);
        }

        let packed = unsafe { sys_pipe() };
        assert!(packed >= 0);
        let rfd = (packed & 0xFFFF_FFFF) as i32;
        let wfd = (packed >> 32) as i32;

        unsafe { seam::set_user_bytes(b"ping") };
        assert_eq!(unsafe { sys_write(wfd, 0, 4) }, 4);
        // Read back into a different user offset so the copy is observable.
        assert_eq!(unsafe { sys_read(rfd, 512, 4) }, 4);
    }

    #[test]
    fn sys_dup2_reports_the_new_fd() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };

        assert_eq!(unsafe { sys_dup2(0, 5) }, 5);
        assert!(unsafe { fdtable::is_console(task_ptr(&mut task), 5) });
    }

    #[test]
    fn sys_close_clears_the_slot() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_console(&mut task) };

        assert_eq!(unsafe { sys_close(0) }, 0);
        assert_eq!(unsafe { sys_read(0, 0, 1) }, -1);
        // A second close of a free fd is an error, not a silent success.
        assert_eq!(unsafe { sys_close(0) }, -1);
    }

    /// Publish `task` as current with cwd `cwd` and `path` at user address 0.
    ///
    /// # Safety
    /// The caller holds the module test lock.
    unsafe fn stage_cwd(task: &mut TaskStruct, cwd: &[u8], path: &[u8]) {
        task.cwd = [0; CWD_SIZE];
        task.cwd[..cwd.len()].copy_from_slice(cwd);
        unsafe {
            seam::set_fault(false);
            seam::set_user_bytes(path);
            sched::set_test_state(task_ptr(task), &[task_ptr(task)]);
        }
    }

    fn cwd_of(task: &TaskStruct) -> std::vec::Vec<u8> {
        let end = task.cwd.iter().position(|&b| b == 0).unwrap_or(CWD_SIZE);
        task.cwd[..end].to_vec()
    }

    #[test]
    fn sys_chdir_stores_an_absolute_path() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/", b"/mnt\0") };

        assert_eq!(unsafe { sys_chdir(0) }, 0);
        assert_eq!(cwd_of(&task), b"/mnt".to_vec());
    }

    #[test]
    fn sys_chdir_joins_a_relative_path_against_the_current_cwd() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/mnt", b"sub\0") };

        assert_eq!(unsafe { sys_chdir(0) }, 0);
        assert_eq!(cwd_of(&task), b"/mnt/sub".to_vec());
    }

    #[test]
    fn sys_chdir_collapses_dot_dot() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/mnt/sub", b"..\0") };

        assert_eq!(unsafe { sys_chdir(0) }, 0);
        assert_eq!(cwd_of(&task), b"/mnt".to_vec());
    }

    /// An un-NUL-terminated path is rejected, never truncated — acting on a
    /// silently different directory would be worse than failing.
    #[test]
    fn sys_chdir_rejects_an_unterminated_path() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        let unterminated = std::vec::Vec::from_iter(core::iter::repeat_n(b'a', 1024));
        unsafe { stage_cwd(&mut task, b"/mnt", &unterminated) };

        assert_eq!(unsafe { sys_chdir(0) }, -1);
        // The failure must leave the existing cwd untouched.
        assert_eq!(cwd_of(&task), b"/mnt".to_vec());
    }

    #[test]
    fn sys_chdir_reports_a_copy_fault_and_keeps_the_cwd() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/mnt", b"/tmp\0") };
        seam::set_fault(true);

        assert_eq!(unsafe { sys_chdir(0) }, -1);
        assert_eq!(cwd_of(&task), b"/mnt".to_vec());
        seam::set_fault(false);
    }

    /// The resolve lands in scratch first, so an overlong collapse leaves the
    /// existing cwd intact rather than half-written.
    #[test]
    fn sys_chdir_keeps_the_cwd_on_an_oversize_resolve() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        let mut long = std::vec::Vec::from_iter(core::iter::repeat_n(b'b', 250));
        long.push(0);
        unsafe { stage_cwd(&mut task, b"/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &long) };

        assert_eq!(unsafe { sys_chdir(0) }, -1);
        assert_eq!(cwd_of(&task), b"/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_vec());
    }

    #[test]
    fn sys_getcwd_reports_the_length_excluding_the_nul() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/mnt", b"\0") };

        assert_eq!(unsafe { sys_getcwd(0, 64) }, 4);
    }

    /// A short buffer gets nothing, never a truncated path.
    #[test]
    fn sys_getcwd_rejects_a_buffer_too_small_for_the_nul() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/mnt", b"\0") };

        // Exactly the path length is still one byte short of path + NUL.
        assert_eq!(unsafe { sys_getcwd(0, 4) }, -1);
        assert_eq!(unsafe { sys_getcwd(0, 5) }, 4);
    }

    #[test]
    fn sys_getcwd_reports_a_copy_fault() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/mnt", b"\0") };
        seam::set_fault(true);

        assert_eq!(unsafe { sys_getcwd(0, 64) }, -1);
        seam::set_fault(false);
    }

    #[test]
    fn sys_readdir_rejects_an_unterminated_path() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        let unterminated = std::vec::Vec::from_iter(core::iter::repeat_n(b'a', 1024));
        unsafe { stage_cwd(&mut task, b"/", &unterminated) };

        assert_eq!(unsafe { sys_readdir(0, 0, 512) }, -1);
    }

    #[test]
    fn sys_readdir_reports_an_unmounted_path_and_balances_preemption() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/", b"/nowhere\0") };

        assert_eq!(unsafe { sys_readdir(0, 0, 512) }, -1);
        assert_eq!(task.preempt_count, 0);
    }

    /// An empty ring reports 0, not -1: nothing to read is not an error.
    #[test]
    fn sys_klog_read_reports_zero_for_an_empty_ring() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/", b"\0") };
        unsafe {
            let ring = seam::klog_ring();
            (&raw mut (*ring).head).write(0);
            (&raw mut (*ring).tail).write(0);
        }

        assert_eq!(unsafe { sys_klog_read(0, 64) }, 0);
    }

    /// The newest bytes win when the request is shorter than the retained
    /// window, and they arrive oldest-first.
    #[test]
    fn sys_klog_read_returns_the_newest_bytes_oldest_first() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/", b"\0") };
        unsafe {
            let ring = seam::klog_ring();
            (&raw mut (*ring).head).write(0);
            (&raw mut (*ring).tail).write(0);
            for byte in b"abcdef" {
                klog_ring::push(ring, *byte);
            }
        }

        // Ask for fewer bytes than retained: expect the tail of the log.
        assert_eq!(unsafe { sys_klog_read(0, 3) }, 3);
        assert_eq!(&seam::user_bytes()[..3], b"def");
    }

    #[test]
    fn sys_klog_read_caps_at_the_retained_count() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/", b"\0") };
        unsafe {
            let ring = seam::klog_ring();
            (&raw mut (*ring).head).write(0);
            (&raw mut (*ring).tail).write(0);
            for byte in b"hi" {
                klog_ring::push(ring, *byte);
            }
        }

        // A generous len must not invent bytes.
        assert_eq!(unsafe { sys_klog_read(0, 4096) }, 2);
        assert_eq!(&seam::user_bytes()[..2], b"hi");
    }

    #[test]
    fn sys_klog_read_reports_a_copy_fault_without_progress() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_cwd(&mut task, b"/", b"\0") };
        unsafe {
            let ring = seam::klog_ring();
            (&raw mut (*ring).head).write(0);
            (&raw mut (*ring).tail).write(0);
            klog_ring::push(ring, b'x');
        }
        seam::set_fault(true);

        assert_eq!(unsafe { sys_klog_read(0, 16) }, -1);
        seam::set_fault(false);
    }

    fn creds(uid: u32, euid: u32, gid: u32, egid: u32) -> TaskStruct {
        let mut task = task_with_pid(1);
        task.uid = uid;
        task.euid = euid;
        task.gid = gid;
        task.egid = egid;
        task
    }

    #[test]
    fn credential_getters_report_the_task_ids() {
        let _guard = lock();
        let mut task = creds(1000, 1001, 2000, 2001);
        unsafe { sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]) };

        unsafe {
            assert_eq!(sys_getuid(), 1000);
            assert_eq!(sys_geteuid(), 1001);
            assert_eq!(sys_getgid(), 2000);
            assert_eq!(sys_getegid(), 2001);
        }
    }

    /// Root sets BOTH ids — this is how /bin/login drops into a user.
    #[test]
    fn sys_setuid_as_root_sets_both_ids() {
        let _guard = lock();
        let mut task = creds(0, 0, 0, 0);
        unsafe { sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]) };

        assert_eq!(unsafe { sys_setuid(1000) }, 0);
        assert_eq!(task.uid, 1000);
        assert_eq!(task.euid, 1000);
    }

    /// The security property: once dropped, a task can never climb back.
    #[test]
    fn sys_setuid_cannot_climb_back_to_root_after_dropping() {
        let _guard = lock();
        let mut task = creds(1000, 1000, 0, 0);
        unsafe { sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]) };

        assert_eq!(unsafe { sys_setuid(0) }, -1);
        assert_eq!(task.uid, 1000);
        assert_eq!(task.euid, 1000);
    }

    /// A non-root caller may reset only to an id it already holds.
    #[test]
    fn sys_setuid_lets_a_dropped_task_reset_to_an_id_it_holds() {
        let _guard = lock();
        let mut task = creds(1000, 1001, 0, 0);
        unsafe { sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]) };

        // Back to its own real uid: allowed, and only the effective id moves.
        assert_eq!(unsafe { sys_setuid(1000) }, 0);
        assert_eq!(task.uid, 1000);
        assert_eq!(task.euid, 1000);
    }

    #[test]
    fn sys_setgid_as_root_sets_both_ids_and_a_dropped_task_cannot_climb() {
        let _guard = lock();
        let mut root = creds(0, 0, 0, 0);
        unsafe { sched::set_test_state(task_ptr(&mut root), &[task_ptr(&mut root)]) };
        assert_eq!(unsafe { sys_setgid(50) }, 0);
        assert_eq!((root.gid, root.egid), (50, 50));

        let mut user = creds(1000, 1000, 100, 100);
        unsafe { sched::set_test_state(task_ptr(&mut user), &[task_ptr(&mut user)]) };
        assert_eq!(unsafe { sys_setgid(0) }, -1);
        assert_eq!((user.gid, user.egid), (100, 100));
    }

    /// Build a shadow line the real parser accepts, with a PBKDF2 verifier over
    /// `password`, so the auth path is exercised end to end rather than mocked.
    fn shadow_line(user: &str, password: &[u8], iterations: u32) -> std::string::String {
        use std::string::String;
        let salt = b"0123456789abcdef";
        let mut derived = [0u8; 32];
        sha256::pbkdf2_hmac_sha256(password, salt, iterations, &mut derived);
        let mut salt_hex = [0u8; 32];
        let mut hash_hex = [0u8; 64];
        shadow::hex_encode(salt, &mut salt_hex).unwrap();
        shadow::hex_encode(&derived, &mut hash_hex).unwrap();
        std::format!(
            "{user}:{iterations}:{}:{}",
            String::from_utf8(salt_hex.to_vec()).unwrap(),
            String::from_utf8(hash_hex.to_vec()).unwrap()
        )
    }

    fn verify(content: &str, user: &str, password: &[u8]) -> VerifyResult {
        unsafe { verify_against(content.as_bytes(), user.as_bytes(), password) }
    }

    #[test]
    fn verify_against_matches_a_correct_password() {
        let _guard = lock();
        let line = shadow_line("flash", b"flash", 1000);

        assert_eq!(verify(&line, "flash", b"flash"), VerifyResult::Match);
    }

    #[test]
    fn verify_against_reports_a_wrong_password_as_mismatch() {
        let _guard = lock();
        let line = shadow_line("flash", b"flash", 1000);

        assert_eq!(verify(&line, "flash", b"wrong"), VerifyResult::Mismatch);
    }

    /// A parseable file that simply lacks the user is an authoritative denial —
    /// it must NOT fall back to the seed.
    #[test]
    fn verify_against_reports_a_missing_user_as_no_user_not_corrupt() {
        let _guard = lock();
        let line = shadow_line("flash", b"flash", 1000);

        assert_eq!(verify(&line, "nobody", b"x"), VerifyResult::NoUser);
    }

    /// Nothing parseable — truncation, garbage, a half-finished rewrite — is the
    /// anti-brick trigger that falls back to the baked-in seed.
    #[test]
    fn verify_against_reports_garbage_as_corrupt() {
        let _guard = lock();

        assert_eq!(
            verify("not-a-shadow-file", "flash", b"x"),
            VerifyResult::Corrupt
        );
        assert_eq!(verify("", "flash", b"x"), VerifyResult::Corrupt);
    }

    /// A matching line whose hex will not decode is corruption, not denial.
    #[test]
    fn verify_against_reports_a_matching_line_with_bad_hex_as_corrupt() {
        let _guard = lock();
        // Parses fine — four fields, real iteration count — but the salt hex
        // will not decode, which must read as corruption rather than denial.
        let line = "flash:1000:zzzz:abcd";

        assert_eq!(verify(line, "flash", b"x"), VerifyResult::Corrupt);
    }

    /// The first matching line wins, and a later duplicate cannot override it.
    #[test]
    fn verify_against_uses_the_first_matching_line() {
        let _guard = lock();
        let first = shadow_line("flash", b"right", 1000);
        let second = shadow_line("flash", b"other", 1000);
        let content = std::format!("{first}\n{second}");

        assert_eq!(verify(&content, "flash", b"right"), VerifyResult::Match);
        assert_eq!(verify(&content, "flash", b"other"), VerifyResult::Mismatch);
    }

    #[test]
    fn verify_against_skips_blank_lines_and_reads_a_trailing_line() {
        let _guard = lock();
        let line = shadow_line("flash", b"flash", 1000);
        // No trailing newline: the final line must still be considered.
        let content = std::format!("\n\n{line}");

        assert_eq!(verify(&content, "flash", b"flash"), VerifyResult::Match);
    }

    /// The auth handler caps its copies; an oversize username or password is a
    /// soft -1, never a smash of the static scratch.
    #[test]
    fn sys_authenticate_rejects_oversize_credentials() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe {
            sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]);
            seam::set_fault(false);
        }

        unsafe {
            assert_eq!(sys_authenticate(0, 0, 0, 0), -1, "empty user");
            assert_eq!(
                sys_authenticate(0, AUTH_USER_LEN as u64 + 1, 0, 0),
                -1,
                "oversize user"
            );
            assert_eq!(
                sys_authenticate(0, 4, 0, AUTH_PASS_LEN as u64 + 1),
                -1,
                "oversize password"
            );
        }
    }

    #[test]
    fn sys_authenticate_reports_a_copy_fault() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]) };
        seam::set_fault(true);

        assert_eq!(unsafe { sys_authenticate(0, 4, 0, 4) }, -1);
        seam::set_fault(false);
    }

    /// The plaintext password must not outlive the call in the static scratch.
    #[test]
    fn sys_authenticate_scrubs_the_password_scratch_on_every_exit() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe {
            sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]);
            seam::set_fault(false);
            seam::set_user_bytes(b"secretpw");
        }

        // No VFS backend is mounted in the host suite, so this takes the
        // seed-read failure path — the scrub must still have run.
        let _ = unsafe { sys_authenticate(0, 4, 0, 8) };

        // SAFETY: single-threaded under the test lock.
        let pass = unsafe { (&raw const AUTH_PASS).read() };
        assert!(
            pass.iter().all(|&b| b == 0),
            "password scratch not scrubbed"
        );
        // SAFETY: same.
        let derived = unsafe { (&raw const AUTH_DERIVED).read() };
        assert!(
            derived.iter().all(|&b| b == 0),
            "derived verifier not scrubbed"
        );
    }

    #[test]
    fn sys_passwd_rejects_oversize_or_empty_inputs() {
        let _guard = lock();
        let mut task = creds(0, 0, 0, 0);
        unsafe {
            sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]);
            seam::set_fault(false);
        }

        unsafe {
            assert_eq!(sys_passwd(0, 0, 0, 0, 0, 4), -1, "empty user");
            assert_eq!(
                sys_passwd(0, PASSWD_USER_LEN as u64 + 1, 0, 0, 0, 4),
                -1,
                "oversize user"
            );
            // An empty new password is rejected: a change must set something.
            assert_eq!(sys_passwd(0, 4, 0, 0, 0, 0), -1, "empty new password");
            assert_eq!(
                sys_passwd(0, 4, 0, 0, 0, PASSWD_PASS_LEN as u64 + 1),
                -1,
                "oversize new password"
            );
        }
    }

    #[test]
    fn sys_passwd_scrubs_both_plaintexts_on_every_exit() {
        let _guard = lock();
        let mut task = creds(0, 0, 0, 0);
        unsafe {
            sched::set_test_state(task_ptr(&mut task), &[task_ptr(&mut task)]);
            seam::set_fault(false);
            seam::set_user_bytes(b"oldpwnewpw");
        }

        // Host has no writable shadow, so this fails at the read — the scrub
        // must still cover it.
        let _ = unsafe { sys_passwd(0, 4, 0, 5, 0, 5) };

        // SAFETY: single-threaded under the test lock.
        unsafe {
            assert!((&raw const PASSWD_OLD).read().iter().all(|&b| b == 0));
            assert!((&raw const PASSWD_NEW).read().iter().all(|&b| b == 0));
            assert!((&raw const AUTH_DERIVED).read().iter().all(|&b| b == 0));
        }
    }

    /// The scratch budget is the whole reason these buffers are statics: the
    /// kernel stack shares its page with TaskStruct's credential tail.
    #[test]
    fn auth_scratch_matches_the_size_contract() {
        assert_eq!(AUTH_USER_LEN, 64);
        assert_eq!(AUTH_PASS_LEN, 128);
        assert_eq!(AUTH_FBUF_LEN, 1024);
        assert_eq!(AUTH_DERIVED_LEN, 32);
        assert_eq!(PASSWD_PWBUF_LEN, 512);
        // ~1.4 KiB of auth scratch alone — far past the ~2.4 KiB usable stack.
        assert_eq!(
            AUTH_USER_LEN
                + AUTH_PASS_LEN
                + AUTH_FBUF_LEN
                + AUTH_SALT_LEN
                + AUTH_STORED_LEN
                + AUTH_DERIVED_LEN,
            1376
        );
    }

    /// The frozen boot-marker bytes must stay single-sourced from console-ui.
    #[test]
    fn debug_mark_c_matches_the_frozen_marker() {
        assert_eq!(&DEBUG_MARK_C[..DEBUG_MARK_C.len() - 1], tags::DEBUG_MARK);
        assert_eq!(DEBUG_MARK_C.last(), Some(&0));
    }

    #[test]
    fn sys_kill_rejects_self_kill() {
        let _guard = lock();
        let mut me = task_with_pid(11);
        unsafe { sched::set_test_state(&raw mut me, &[&raw mut me]) };

        assert_eq!(unsafe { sys_kill(11) }, -1);
    }

    #[test]
    fn sys_kill_misses_an_unknown_pid() {
        let _guard = lock();
        let mut me = task_with_pid(1);
        unsafe { sched::set_test_state(&raw mut me, &[&raw mut me]) };

        assert_eq!(unsafe { sys_kill(42) }, -1);
        // The miss path must leave the nesting count balanced.
        assert_eq!(me.preempt_count, 0);
    }

    /// Publish a task whose cwd is `cwd`, and `path` at user address 0.
    ///
    /// # Safety
    /// The caller holds the module test lock.
    unsafe fn stage_path(task: &mut TaskStruct, cwd: &[u8], path: &[u8]) {
        task.cwd[..cwd.len()].copy_from_slice(cwd);
        task.cwd[cwd.len()] = 0;
        unsafe {
            seam::set_fault(false);
            seam::set_user_bytes(path);
            sched::set_test_state(task as *mut TaskStruct, &[task as *mut TaskStruct]);
        }
    }

    fn resolve(task: &mut TaskStruct) -> Option<std::vec::Vec<u8>> {
        unsafe {
            copy_resolve_path(
                task as *mut TaskStruct,
                0,
                (&raw mut OPEN_PATH_BUF).cast::<u8>(),
                (&raw mut OPEN_JOIN_BUF).cast::<u8>(),
            )
            .map(|resolved| resolved.to_vec())
        }
    }

    #[test]
    fn copy_resolve_path_passes_an_absolute_path_through() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_path(&mut task, b"/mnt", b"/etc/shadow\0") };

        assert_eq!(resolve(&mut task).as_deref(), Some(&b"/etc/shadow"[..]));
    }

    #[test]
    fn copy_resolve_path_joins_a_relative_path_against_cwd() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_path(&mut task, b"/mnt", b"file.txt\0") };

        assert_eq!(resolve(&mut task).as_deref(), Some(&b"/mnt/file.txt"[..]));
    }

    #[test]
    fn copy_resolve_path_collapses_dot_dot_against_cwd() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_path(&mut task, b"/mnt/sub", b"../other.txt\0") };

        assert_eq!(resolve(&mut task).as_deref(), Some(&b"/mnt/other.txt"[..]));
    }

    #[test]
    fn copy_resolve_path_reports_a_copy_fault() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_path(&mut task, b"/mnt", b"file.txt\0") };
        seam::set_fault(true);

        assert_eq!(resolve(&mut task), None);
        seam::set_fault(false);
    }

    /// An unterminated user path must stop at the buffer bound rather than
    /// running off the end; the truncation is what keeps the scan finite.
    #[test]
    fn copy_resolve_path_truncates_an_unterminated_path() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        let mut absolute = std::vec::Vec::new();
        absolute.push(b'/');
        absolute.extend(core::iter::repeat_n(b'a', 4095));
        unsafe { stage_path(&mut task, b"/", &absolute) };

        let resolved = resolve(&mut task).expect("truncated path still resolves");
        assert_eq!(resolved.len(), PATH_BUF_SIZE - 1);
        assert_eq!(resolved[0], b'/');
    }

    /// The over-long relative case must fail closed rather than truncate into a
    /// different, valid path.
    #[test]
    fn copy_resolve_path_rejects_an_over_long_resolved_path() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        let long_cwd = [b'/'; 200];
        let mut relative = std::vec::Vec::new();
        relative.extend(core::iter::repeat_n(b'b', 300));
        relative.push(0);
        unsafe { stage_path(&mut task, &long_cwd[..200], &relative) };

        assert_eq!(resolve(&mut task), None);
    }

    /// The scratch buffers are statics precisely because ~1.3 KiB of stack
    /// locals here would descend into the TaskStruct credential tail. Nothing
    /// at runtime can prove "not on the stack" — that is the `static mut`
    /// declaration's job, and the stack-frame audit's. What is checkable is the
    /// size contract those frames were budgeted against.
    #[test]
    fn path_scratch_matches_the_size_contract() {
        assert_eq!(PATH_BUF_SIZE, 1024);
        assert_eq!(CWD_SIZE, 256);
        // Together: two live path pairs for rename, all of it off-stack.
        assert_eq!(2 * (PATH_BUF_SIZE + CWD_SIZE), 2560);
    }

    #[test]
    fn sys_open_file_reports_a_fault_without_a_live_backend() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_path(&mut task, b"/", b"/nothing\0") };
        seam::set_fault(true);

        assert_eq!(unsafe { sys_open_file(0) }, -1);
        assert_eq!(task.preempt_count, 0);
        seam::set_fault(false);
    }

    #[test]
    fn sys_unlink_balances_preemption_on_a_fault() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_path(&mut task, b"/", b"/nothing\0") };
        seam::set_fault(true);

        assert_eq!(unsafe { sys_unlink(0) }, -1);
        assert_eq!(task.preempt_count, 0);
        seam::set_fault(false);
    }

    #[test]
    fn sys_rename_balances_preemption_on_a_fault() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_path(&mut task, b"/", b"/nothing\0") };
        seam::set_fault(true);

        assert_eq!(unsafe { sys_rename(0, 0) }, -1);
        assert_eq!(task.preempt_count, 0);
        seam::set_fault(false);
    }

    #[test]
    fn sys_seek_rejects_an_unopened_fd() {
        let _guard = lock();
        let mut task = task_with_pid(1);
        unsafe { stage_path(&mut task, b"/", b"\0") };

        assert_eq!(unsafe { sys_seek(3, 0, 0) }, -1);
    }

    #[test]
    fn sys_kill_zombifies_a_live_target_and_balances_preemption() {
        let _guard = lock();
        let mut me = task_with_pid(1);
        let mut victim = task_with_pid(2);
        victim.state = TASK_RUNNING;
        unsafe { sched::set_test_state(&raw mut me, &[&raw mut me, &raw mut victim]) };

        assert_eq!(unsafe { sys_kill(2) }, 0);
        assert_eq!(victim.state, TASK_ZOMBIE);
        assert_eq!(me.preempt_count, 0);
    }
}
