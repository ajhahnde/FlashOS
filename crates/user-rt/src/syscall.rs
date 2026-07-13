//! Raw EL0-to-EL1 syscall transport and the minimal process I/O surface.

#[cfg(target_os = "none")]
use flashos_abi::syscall::Dirent;
#[cfg(any(target_os = "none", test))]
use flashos_abi::syscall::{
    SYS_CHDIR, SYS_EXECVE, SYS_EXIT, SYS_FORK, SYS_READ, SYS_READDIR, SYS_SBRK, SYS_WAIT, SYS_WRITE,
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
    fn chdir_and_sbrk_take_a_single_argument() {
        assert_eq!(place(SYS_CHDIR, [0x3000, 0, 0, 0, 0, 0]).x8, 36);
        let regs = place(SYS_SBRK, [(-32i64) as u64, 0, 0, 0, 0, 0]);
        assert_eq!(regs.x8, 13);
        // sbrk's delta is signed: a shrink must reach the kernel as a two's
        // complement negative, not a huge unsigned break request.
        assert_eq!(regs.x[0] as i64, -32);
    }
}
