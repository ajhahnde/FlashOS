//! Raw EL0-to-EL1 syscall transport and the minimal process I/O surface.

#[cfg(target_os = "none")]
use flashos_abi::syscall::Dirent;
#[cfg(any(target_os = "none", test))]
use flashos_abi::syscall::{
    SYS_CHDIR, SYS_CLOSE, SYS_CPU_FREQ, SYS_CPU_TEMP, SYS_CREATE, SYS_DUMP_FREE, SYS_EXECVE,
    SYS_EXIT, SYS_FORK, SYS_KLOG_READ, SYS_MEMTOTAL, SYS_OPEN_FILE, SYS_READ, SYS_READDIR,
    SYS_RENAME, SYS_SBRK, SYS_UNLINK, SYS_UPTIME, SYS_WAIT, SYS_WRITE,
};

pub const STDIN: i32 = 0;
pub const STDOUT: i32 = 1;
pub const STDERR: i32 = 2;

/// The AArch64 register image consumed by `arch/aarch64/entry.S:el0_svc`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Registers {
    pub x: [u64; 6],
    pub x8: u64,
}

/// Place a syscall number and up to six arguments in the kernel ABI registers.
pub const fn place(number: u64, args: [u64; 6]) -> Registers {
    Registers {
        x: args,
        x8: number,
    }
}

/// Trap into the FlashOS kernel and return `x0`.
///
/// # Safety
///
/// The caller must satisfy the pointed-to memory and lifetime contract of the
/// selected syscall. The transport itself does not validate user pointers.
#[cfg(target_os = "none")]
pub unsafe fn raw(number: u64, args: [u64; 6]) -> i64 {
    let regs = place(number, args);
    let mut x0 = regs.x[0];
    unsafe {
        core::arch::asm!(
            "svc #0",
            inlateout("x0") x0,
            in("x1") regs.x[1],
            in("x2") regs.x[2],
            in("x3") regs.x[3],
            in("x4") regs.x[4],
            in("x5") regs.x[5],
            in("x8") regs.x8,
            options(nostack),
        );
    }
    x0 as i64
}

/// Write bytes to a unified file descriptor.
#[cfg(target_os = "none")]
pub fn write(fd: i32, bytes: &[u8]) -> i64 {
    unsafe {
        raw(
            SYS_WRITE,
            [
                fd as u64,
                bytes.as_ptr() as u64,
                bytes.len() as u64,
                0,
                0,
                0,
            ],
        )
    }
}

/// Write the complete slice, stopping on the first kernel error or zero write.
#[cfg(target_os = "none")]
pub fn write_all(fd: i32, mut bytes: &[u8]) -> Result<(), i64> {
    while !bytes.is_empty() {
        let written = write(fd, bytes);
        if written <= 0 {
            return Err(written);
        }
        let written = written as usize;
        if written > bytes.len() {
            return Err(-1);
        }
        bytes = &bytes[written..];
    }
    Ok(())
}

/// Terminate the current task. The current kernel ignores `status`, but it is
/// placed in x0 so the userspace ABI need not change when status propagation is
/// added later.
#[cfg(target_os = "none")]
pub fn exit(status: i32) -> ! {
    let _ = unsafe { raw(SYS_EXIT, [status as u64, 0, 0, 0, 0, 0]) };
    loop {
        unsafe { core::arch::asm!("wfe", options(nomem, nostack)) };
    }
}

/// Read up to `buf.len()` bytes from a unified file descriptor. Returns the byte
/// count, `0` on clean end-of-input, or `-1`. A console read blocks until a byte
/// arrives; there is no timeout.
#[cfg(target_os = "none")]
pub fn read(fd: i32, buf: &mut [u8]) -> i64 {
    unsafe {
        raw(
            SYS_READ,
            [
                fd as u64,
                buf.as_mut_ptr() as u64,
                buf.len() as u64,
                0,
                0,
                0,
            ],
        )
    }
}

/// Clone the current process. Returns the child's pid in the parent, `0` in the
/// child, and `-1` on failure (task slots exhausted, out of memory).
#[cfg(target_os = "none")]
pub fn fork() -> i32 {
    unsafe { raw(SYS_FORK, [0; 6]) as i32 }
}

/// Block until any child terminates and reap it. Returns the reaped child's pid,
/// or `-1` if the caller has no children.
#[cfg(target_os = "none")]
pub fn wait() -> i32 {
    unsafe { raw(SYS_WAIT, [0; 6]) as i32 }
}

/// Path-resolved exec. `path` is a NUL-terminated user pointer and `argv` a
/// NULL-terminated vector of NUL-terminated pointers. On success the kernel does
/// not return here: it erets to the new entry point with `x0 = argc`, `x1 = argv`.
/// Returns `-1` on failure with the caller's address space untouched.
///
/// # Safety
///
/// `path` must be NUL-terminated and `argv` must be a NULL-terminated vector of
/// NUL-terminated pointers; the kernel walks both to their terminators.
#[cfg(target_os = "none")]
pub unsafe fn exec_path(path: *const u8, argv: *const *const u8) -> i32 {
    unsafe { raw(SYS_EXECVE, [path as u64, argv as u64, 0, 0, 0, 0]) as i32 }
}

/// Replace the calling task's working directory with the joined + collapsed form
/// of `path`. Returns `0` on success, `-1` on a wild pointer or oversize result.
///
/// # Safety
///
/// `path` must point at a NUL-terminated string the kernel may read.
#[cfg(target_os = "none")]
pub unsafe fn chdir(path: *const u8) -> i32 {
    unsafe { raw(SYS_CHDIR, [path as u64, 0, 0, 0, 0, 0]) as i32 }
}

/// Move the program break by `delta` bytes and return the *previous* break, or a
/// negative value if the kernel rejects the new break.
#[cfg(target_os = "none")]
pub fn sbrk(delta: i64) -> i64 {
    unsafe { raw(SYS_SBRK, [delta as u64, 0, 0, 0, 0, 0]) }
}

/// Read the `index`-th entry of the directory at `path` into `out`. Returns `0` when
/// an entry was filled and non-zero once the directory is exhausted, so a caller
/// walks it by counting up until it stops returning `0`.
///
/// # Safety
///
/// `path` must point at a NUL-terminated string readable by the kernel.
#[cfg(target_os = "none")]
pub unsafe fn readdir(path: *const u8, index: u64, out: *mut Dirent) -> i32 {
    unsafe { raw(SYS_READDIR, [path as u64, index, out as u64, 0, 0, 0]) as i32 }
}

// ---- the file surface -------------------------------------------------------
//
// Slot 7 is the lone survivor of the legacy file ABI: there is no unified open,
// so a path becomes a file fd here and is then read, written, and closed through
// the same unified slots a console or a pipe fd uses.

/// Resolve `path` through the VFS and install a file descriptor for it. Relative
/// paths join against the task's working directory. Returns the new fd, or a
/// negative errno-shaped value: `-EACCES` when the file exists but the caller may
/// not have it, `-1` on every other failure.
///
/// # Safety
///
/// `path` must point at a NUL-terminated string readable by the kernel.
#[cfg(target_os = "none")]
pub unsafe fn open(path: *const u8) -> i32 {
    unsafe { raw(SYS_OPEN_FILE, [path as u64, 0, 0, 0, 0, 0]) as i32 }
}

/// Create an empty file at `path` and return a writable fd for it. Fails closed on
/// a name collision -- there is no clobber -- and on a name that does not fit 8.3,
/// a full or read-only volume, or an exhausted fd table.
///
/// # Safety
///
/// `path` must point at a NUL-terminated string readable by the kernel.
#[cfg(target_os = "none")]
pub unsafe fn create(path: *const u8) -> i32 {
    unsafe { raw(SYS_CREATE, [path as u64, 0, 0, 0, 0, 0]) as i32 }
}

/// Remove the file at `path`. Returns `0` on success, `-1` on a missing file, a
/// directory, or a read-only volume.
///
/// # Safety
///
/// `path` must point at a NUL-terminated string readable by the kernel.
#[cfg(target_os = "none")]
pub unsafe fn unlink(path: *const u8) -> i32 {
    unsafe { raw(SYS_UNLINK, [path as u64, 0, 0, 0, 0, 0]) as i32 }
}

/// Rename `old` to `new` within one directory -- an in-place name rewrite with no
/// data move. A cross-directory move is refused (`-1`); that is the caller's
/// copy-then-unlink job.
///
/// # Safety
///
/// Both pointers must reference NUL-terminated strings readable by the kernel.
#[cfg(target_os = "none")]
pub unsafe fn rename(old: *const u8, new: *const u8) -> i32 {
    unsafe { raw(SYS_RENAME, [old as u64, new as u64, 0, 0, 0, 0]) as i32 }
}

/// Release `fd` from the calling task's table, flushing a file backend on the way
/// out. Returns `0`, or `-1` on a bad descriptor.
#[cfg(target_os = "none")]
pub fn close(fd: i32) -> i32 {
    unsafe { raw(SYS_CLOSE, [fd as u64, 0, 0, 0, 0, 0]) as i32 }
}

// ---- the reporting surface --------------------------------------------------

/// Pages currently free in the kernel's allocatable pool.
#[cfg(target_os = "none")]
pub fn dump_free() -> u64 {
    unsafe { raw(SYS_DUMP_FREE, [0; 6]) as u64 }
}

/// The frozen size of that pool, in pages.
#[cfg(target_os = "none")]
pub fn mem_total() -> u64 {
    unsafe { raw(SYS_MEMTOTAL, [0; 6]) as u64 }
}

/// Seconds since boot, off the architectural counter -- the same reading on
/// hardware and under QEMU.
#[cfg(target_os = "none")]
pub fn uptime() -> u64 {
    unsafe { raw(SYS_UPTIME, [0; 6]) as u64 }
}

/// SoC temperature in milli-degrees Celsius, or `0` when the board exposes no
/// firmware to ask. A caller renders the zero as unknown; it never fabricates one.
#[cfg(target_os = "none")]
pub fn cpu_temp() -> u64 {
    unsafe { raw(SYS_CPU_TEMP, [0; 6]) as u64 }
}

/// ARM core clock in Hz, `0` when unknown -- see [`cpu_temp`].
#[cfg(target_os = "none")]
pub fn cpu_freq() -> u64 {
    unsafe { raw(SYS_CPU_FREQ, [0; 6]) as u64 }
}

/// Snapshot the retained kernel log into `buf`, oldest byte first, and return the
/// byte count. Consume-free: the ring is left intact, so a second read re-sees the
/// same log plus whatever the kernel has since appended.
#[cfg(target_os = "none")]
pub fn klog_read(buf: &mut [u8]) -> i64 {
    unsafe {
        raw(
            SYS_KLOG_READ,
            [buf.as_mut_ptr() as u64, buf.len() as u64, 0, 0, 0, 0],
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn syscall_arguments_land_in_x0_through_x5_and_number_in_x8() {
        let regs = place(33, [10, 11, 12, 13, 14, 15]);
        assert_eq!(regs.x, [10, 11, 12, 13, 14, 15]);
        assert_eq!(regs.x8, 33);
    }

    #[test]
    fn write_uses_the_canonical_dispatch_slot() {
        let regs = place(SYS_WRITE, [STDOUT as u64, 0x1234, 7, 0, 0, 0]);
        assert_eq!(regs.x8, 33);
        assert_eq!(regs.x[..3], [1, 0x1234, 7]);
    }

    #[test]
    fn exit_uses_the_canonical_dispatch_slot() {
        let regs = place(SYS_EXIT, [9, 0, 0, 0, 0, 0]);
        assert_eq!(regs.x8, 2);
        assert_eq!(regs.x[0], 9);
    }

    #[test]
    fn read_places_fd_buffer_and_length_in_x0_through_x2() {
        let regs = place(SYS_READ, [STDIN as u64, 0xdead, 64, 0, 0, 0]);
        assert_eq!(regs.x8, 32);
        assert_eq!(regs.x[..3], [0, 0xdead, 64]);
    }

    #[test]
    fn the_argument_free_process_calls_pass_nothing() {
        // fork and wait take no arguments: a stale register left in x0 would be
        // read by the kernel as a syscall argument for a slot that has none.
        assert_eq!(place(SYS_FORK, [0; 6]).x8, 1);
        assert_eq!(place(SYS_WAIT, [0; 6]).x8, 3);
        assert_eq!(place(SYS_FORK, [0; 6]).x, [0; 6]);
    }

    #[test]
    fn exec_path_places_the_path_then_the_argv_vector() {
        let regs = place(SYS_EXECVE, [0x1000, 0x2000, 0, 0, 0, 0]);
        assert_eq!(regs.x8, 31);
        assert_eq!(regs.x[..2], [0x1000, 0x2000]);
    }

    #[test]
    fn readdir_places_the_path_index_and_entry_in_x0_through_x2() {
        let regs = place(SYS_READDIR, [0x4000, 3, 0x5000, 0, 0, 0]);
        assert_eq!(regs.x8, 37);
        assert_eq!(regs.x[..3], [0x4000, 3, 0x5000]);
    }

    #[test]
    fn the_path_taking_file_calls_place_their_path_in_x0() {
        assert_eq!(place(SYS_OPEN_FILE, [0x1000, 0, 0, 0, 0, 0]).x8, 7);
        assert_eq!(place(SYS_CREATE, [0x1000, 0, 0, 0, 0, 0]).x8, 53);
        assert_eq!(place(SYS_UNLINK, [0x1000, 0, 0, 0, 0, 0]).x8, 54);
        assert_eq!(place(SYS_CLOSE, [4, 0, 0, 0, 0, 0]).x8, 34);
        assert_eq!(place(SYS_OPEN_FILE, [0x1000, 0, 0, 0, 0, 0]).x[0], 0x1000);
    }

    #[test]
    fn rename_places_the_source_before_the_target() {
        // Swapping these silently renames in the wrong direction -- the kernel
        // cannot tell the two path pointers apart.
        let regs = place(SYS_RENAME, [0x1000, 0x2000, 0, 0, 0, 0]);
        assert_eq!(regs.x8, 55);
        assert_eq!(regs.x[..2], [0x1000, 0x2000]);
    }

    #[test]
    fn the_argument_free_monitors_pass_nothing() {
        for (nr, slot) in [
            (SYS_DUMP_FREE, 4),
            (SYS_MEMTOTAL, 49),
            (SYS_UPTIME, 50),
            (SYS_CPU_TEMP, 51),
            (SYS_CPU_FREQ, 52),
        ] {
            let regs = place(nr, [0; 6]);
            assert_eq!(regs.x8, slot);
            assert_eq!(regs.x, [0; 6]);
        }
    }

    #[test]
    fn klog_read_places_the_buffer_and_its_length_in_x0_and_x1() {
        let regs = place(SYS_KLOG_READ, [0x6000, 16 * 1024, 0, 0, 0, 0]);
        assert_eq!(regs.x8, 38);
        assert_eq!(regs.x[..2], [0x6000, 16 * 1024]);
    }

    #[test]
    fn chdir_and_sbrk_take_a_single_argument() {
        assert_eq!(place(SYS_CHDIR, [0x3000, 0, 0, 0, 0, 0]).x8, 36);
        let regs = place(SYS_SBRK, [(-32i64) as u64, 0, 0, 0, 0, 0]);
        assert_eq!(regs.x8, 13);
        // sbrk's delta is signed: a shrink must reach the kernel as a two's
        // complement negative, not a huge unsigned break request.
        assert_eq!(regs.x[0] as i64, -32);
    }
}
