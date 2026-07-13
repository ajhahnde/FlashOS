//! Process glue -- fork / wait / exit / execve / chdir.
//!
//! Thin wrappers over the kernel syscall surface: fork, wait, exit, and chdir pass
//! straight through, and [`execve`] is the path-resolved form that goes through the
//! VFS.

#[cfg(target_os = "none")]
use flashos_user_rt::syscall;

/// Clone the current process. Returns the child's pid in the parent and `0` in the
/// child; `-1` on failure (task slots exhausted, out of memory).
#[cfg(target_os = "none")]
pub fn fork() -> i32 {
    syscall::fork()
}

/// Block until any child terminates and reap it. Returns the reaped child's pid, or
/// `-1` if the caller has no children.
#[cfg(target_os = "none")]
pub fn wait() -> i32 {
    syscall::wait()
}

/// Terminate the current process. The kernel flips the task to zombie; the parent's
/// [`wait`] reaps it, freeing every page tracked by its `mm`.
#[cfg(target_os = "none")]
pub fn exit(status: i32) -> ! {
    syscall::exit(status)
}

/// Path-resolved exec. `path` is a NUL-terminated string and `argv` a
/// NULL-terminated vector of NUL-terminated pointers. The kernel resolves `path`
/// through the VFS (relative paths join against the task's cwd), streams the
/// segments from the open file, and lays an argv block on the new user stack. On
/// success this does not return. Returns `-1` on failure, with the caller's address
/// space untouched.
///
/// # Safety
///
/// `path` must be NUL-terminated and `argv` must be a NULL-terminated vector of
/// NUL-terminated pointers, all readable by the kernel for the length of the call.
#[cfg(target_os = "none")]
pub unsafe fn execve(path: *const u8, argv: *const *const u8) -> i32 {
    unsafe { syscall::exec_path(path, argv) }
}

/// Replace the calling task's working directory with the joined + collapsed form of
/// `path`. The kernel performs the join and the `.`/`..` collapse. Returns `0` on
/// success, `-1` on a wild pointer, an unterminated string, or an oversize result.
///
/// # Safety
///
/// `path` must point at a NUL-terminated string readable by the kernel.
#[cfg(target_os = "none")]
pub unsafe fn chdir(path: *const u8) -> i32 {
    unsafe { syscall::chdir(path) }
}
