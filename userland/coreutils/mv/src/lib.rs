//! `/bin/mv` -- move or rename OLD to NEW.
//!
//!   mv OLD NEW
//!
//! First tries the kernel's same-directory rename, an in-place 8.3 name rewrite with
//! no data move -- the fast path. The kernel refuses a cross-directory rename (it
//! cannot move bytes between directories), so on failure mv falls back to
//! copy-then-unlink: create NEW, stream OLD into it, remove OLD. NEW must not exist
//! and its name must fit 8.3.
//!
//! The fallback is inlined rather than exec'ing /bin/cp, to keep mv one
//! self-contained program.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::{err_sink, sys};
#[cfg(target_os = "none")]
use flashsdk_rt::{arg_ptr, entry, Argv};

#[cfg(target_os = "none")]
const BUF_LEN: usize = 512;

/// Copy `src` to a freshly created `dst`. Returns whether the copy was clean.
///
/// # Safety
///
/// Both pointers must reference NUL-terminated strings.
#[cfg(target_os = "none")]
unsafe fn copy_file(src: *const u8, dst: *const u8) -> bool {
    let sfd = unsafe { sys::open(src) };
    if sfd < 0 {
        return false;
    }
    let dfd = unsafe { sys::create(dst) };
    if dfd < 0 {
        sys::close(sfd);
        return false;
    }
    let mut buf = [0u8; BUF_LEN];
    let mut ok = true;
    loop {
        let n = sys::read(sfd, &mut buf);
        if n <= 0 {
            break;
        }
        if sys::write(dfd, &buf[..n as usize]) != n {
            ok = false;
            break;
        }
    }
    sys::close(sfd);
    sys::close(dfd);
    ok
}

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    if argc < 3 {
        err_sink(b"usage: mv OLD NEW\n");
        return 0;
    }
    let (Some(old), Some(new)) = (unsafe { arg_ptr(argv, 1) }, unsafe { arg_ptr(argv, 2) }) else {
        return 0;
    };

    // Fast path: same-directory in-place rename.
    if unsafe { sys::rename(old, new) } == 0 {
        return 0;
    }

    // Fallback: cross-directory move via copy + unlink.
    if !unsafe { copy_file(old, new) } {
        err_sink(b"mv: cannot move\n");
        return 0;
    }
    if unsafe { sys::unlink(old) } < 0 {
        err_sink(b"mv: moved but could not remove source\n");
    }
    0
}

#[cfg(target_os = "none")]
entry!(main);
