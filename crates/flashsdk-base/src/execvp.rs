//! Bare-name program resolution on top of the exec syscall.
//!
//! Linux's `execvp` consults `$PATH`; FlashOS has no environment yet, so a single
//! search prefix is hard-wired: a bare name `foo` resolves to `/bin/foo`. A name that
//! already contains a slash -- absolute `/usr/bin/foo` or relative `tools/foo` -- skips
//! the prefix and is handed to the kernel verbatim, which joins relative paths against
//! the task's working directory.
//!
//! The path build in [`resolve`] is pure and host-tested; only [`execvp`], which traps
//! into the kernel, is target-gated.
//!
//! Path budget: [`PATH_MAX`] matches the kernel's working-directory ceiling and is the
//! stack buffer the shell hands in. The resolver reports overflow instead of
//! truncating, so a caller surfaces a clean `-1` rather than execing a wrong binary.

/// Maximum resolved path length handed to the exec syscall. Sized to match the
/// kernel's working-directory budget: the kernel already handles paths up to that
/// ceiling, so widening here would only invite a later kernel-side rejection.
pub const PATH_MAX: usize = 256;

const BIN_PREFIX: &[u8] = b"/bin/";

/// Resolve a program name into an absolute (or already-slashed) path laid out in
/// `out`. The rules are:
///
///   * an empty `name` yields `None`;
///   * a `name` containing `'/'` is copied verbatim, letting the kernel do the
///     absolute or cwd-relative resolution;
///   * a bare `name` becomes `/bin/` + `name`;
///   * an `out` too small for the result plus its terminator yields `None`, so the
///     caller gets `-1` rather than a silently truncated binary path.
///
/// On success the returned slice is the path bytes, and a NUL is written into `out`
/// one past its end: the returned slice's pointer is a valid C string for the exec
/// syscall. Pure -- no syscalls, no allocator.
pub fn resolve<'a>(name: &[u8], out: &'a mut [u8]) -> Option<&'a mut [u8]> {
    if name.is_empty() {
        return None;
    }

    let mut has_slash = false;
    for &c in name {
        if c == b'/' {
            has_slash = true;
            break;
        }
    }

    if has_slash {
        if name.len() + 1 > out.len() {
            return None;
        }
        out[..name.len()].copy_from_slice(name);
        out[name.len()] = 0;
        return Some(&mut out[..name.len()]);
    }

    let total = BIN_PREFIX.len() + name.len();
    if total + 1 > out.len() {
        return None;
    }
    out[..BIN_PREFIX.len()].copy_from_slice(BIN_PREFIX);
    out[BIN_PREFIX.len()..total].copy_from_slice(name);
    out[total] = 0;
    Some(&mut out[..total])
}

/// Resolve `name` (bare becomes `/bin/<name>`, slashed passes through) and exec the
/// result. Returns `-1` when resolution fails (empty or oversize name) or whatever the
/// exec syscall returns; on success the syscall does not return.
///
/// # Safety
///
/// `name` must point at a NUL-terminated string, and `argv` must be a NULL-terminated
/// vector of NUL-terminated pointers, all readable by the kernel for the length of the
/// call.
#[cfg(target_os = "none")]
pub unsafe fn execvp(name: *const u8, argv: *const *const u8) -> i32 {
    let mut path_buf = [0u8; PATH_MAX];
    let mut n: usize = 0;
    // SAFETY: the caller guarantees `name` is NUL-terminated, so the scan stops inside
    // the string's own allocation.
    while unsafe { *name.add(n) } != 0 {
        n += 1;
    }
    // SAFETY: `n` is the length measured above, and the bytes stay alive and unaliased
    // for the duration of this call.
    let bytes = unsafe { core::slice::from_raw_parts(name, n) };
    let resolved = match resolve(bytes, &mut path_buf) {
        Some(r) => r,
        None => return -1,
    };
    // SAFETY: `resolve` NUL-terminates the path one byte past `resolved`, and `argv`
    // carries the caller's terminator contract through unchanged.
    unsafe { crate::process::execve(resolved.as_ptr(), argv) }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The caller's buffer is uninitialized stack in the real call sites, so the
    /// tests hand in a poisoned one: a NUL assertion against a zeroed buffer would
    /// hold even if the resolver never wrote a terminator.
    const POISON: u8 = 0xaa;

    #[test]
    fn a_bare_name_maps_into_bin() {
        let mut buf = [POISON; 64];
        let r = resolve(b"fsh", &mut buf).expect("resolve returned None");
        assert_eq!(r, b"/bin/fsh");
        let len = r.len();
        assert_eq!(buf[len], 0);
    }

    #[test]
    fn a_single_char_bare_name_resolves() {
        let mut buf = [POISON; 16];
        let r = resolve(b"x", &mut buf).expect("resolve returned None");
        assert_eq!(r, b"/bin/x");
    }

    #[test]
    fn an_absolute_path_passes_through_verbatim() {
        let mut buf = [POISON; 64];
        let r = resolve(b"/usr/local/bin/foo", &mut buf).expect("resolve returned None");
        assert_eq!(r, b"/usr/local/bin/foo");
        let len = r.len();
        assert_eq!(buf[len], 0);
    }

    #[test]
    fn a_relative_path_with_a_slash_passes_through() {
        let mut buf = [POISON; 64];
        let r = resolve(b"tools/foo", &mut buf).expect("resolve returned None");
        assert_eq!(r, b"tools/foo");
    }

    #[test]
    fn a_leading_slash_bypasses_the_prefix_with_no_further_slash() {
        let mut buf = [POISON; 32];
        let r = resolve(b"/foo", &mut buf).expect("resolve returned None");
        assert_eq!(r, b"/foo");
    }

    #[test]
    fn an_empty_name_resolves_to_nothing() {
        let mut buf = [POISON; 64];
        assert!(resolve(b"", &mut buf).is_none());
    }

    #[test]
    fn an_oversize_bare_name_resolves_to_nothing() {
        // "/bin/foo" is 8 bytes plus a NUL: it cannot fit in 4.
        let mut tiny = [POISON; 4];
        assert!(resolve(b"foo", &mut tiny).is_none());
    }

    #[test]
    fn an_oversize_passthrough_resolves_to_nothing() {
        let mut tiny = [POISON; 4];
        assert!(resolve(b"/abcd", &mut tiny).is_none());
    }

    #[test]
    fn an_exact_fit_bare_name_succeeds() {
        // "/bin/x" is 6 bytes, and with the NUL that is 7: a 7-byte buffer fits.
        let mut buf = [POISON; 7];
        let r = resolve(b"x", &mut buf).expect("resolve returned None");
        assert_eq!(r, b"/bin/x");
        assert_eq!(buf[6], 0);
    }

    #[test]
    fn a_one_byte_short_bare_name_resolves_to_nothing() {
        // "/bin/x" needs 7 bytes once the NUL is counted.
        let mut buf = [POISON; 6];
        assert!(resolve(b"x", &mut buf).is_none());
    }

    #[test]
    fn an_exact_fit_passthrough_succeeds() {
        // "/foo" is 4 bytes plus the NUL: exactly 5.
        let mut buf = [POISON; 5];
        let r = resolve(b"/foo", &mut buf).expect("resolve returned None");
        assert_eq!(r, b"/foo");
        assert_eq!(buf[4], 0);
    }

    #[test]
    fn a_bare_name_resolves_in_a_path_max_buffer() {
        let mut buf = [POISON; PATH_MAX];
        let r = resolve(b"cat", &mut buf).expect("resolve returned None");
        assert_eq!(r, b"/bin/cat");
    }

    #[test]
    fn a_slash_mid_name_is_treated_as_a_path() {
        let mut buf = [POISON; 32];
        let r = resolve(b"a/b", &mut buf).expect("resolve returned None");
        assert_eq!(r, b"a/b");
    }
}
