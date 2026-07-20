//! Strict-align-safe freestanding memory and C-string helpers.
//!
//! The precompiled `compiler_builtins` for FlashOS's target does not export the
//! C `mem*` family. LLVM may still lower ordinary Rust copies to those symbols,
//! so EL0 owns byte-loop implementations just as the old flibc runtime did.

use core::slice;

/// Copy `n` bytes from `src` to non-overlapping storage at `dst`.
///
/// # Safety
///
/// Both regions must be valid for `n` bytes and must not overlap.
#[cfg_attr(target_os = "none", no_mangle)]
pub unsafe extern "C" fn memcpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    let mut i = 0;
    while i < n {
        unsafe { *dst.add(i) = *src.add(i) };
        i += 1;
    }
    dst
}

/// Fill `n` bytes at `dst` with the low byte of `value`.
///
/// # Safety
///
/// `dst` must be valid for writes of `n` bytes.
#[cfg_attr(target_os = "none", no_mangle)]
pub unsafe extern "C" fn memset(dst: *mut u8, value: i32, n: usize) -> *mut u8 {
    let mut i = 0;
    while i < n {
        unsafe { *dst.add(i) = value as u8 };
        i += 1;
    }
    dst
}

/// Copy `n` bytes between regions that may overlap.
///
/// # Safety
///
/// Both regions must be valid for `n` bytes.
#[cfg_attr(target_os = "none", no_mangle)]
pub unsafe extern "C" fn memmove(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    if (dst as usize) <= (src as usize) {
        let mut i = 0;
        while i < n {
            unsafe { *dst.add(i) = *src.add(i) };
            i += 1;
        }
    } else {
        let mut i = n;
        while i != 0 {
            i -= 1;
            unsafe { *dst.add(i) = *src.add(i) };
        }
    }
    dst
}

/// Lexicographically compare two `n`-byte regions.
///
/// # Safety
///
/// Both pointers must be valid for reads of `n` bytes.
#[cfg_attr(target_os = "none", no_mangle)]
pub unsafe extern "C" fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    let mut i = 0;
    while i < n {
        let (left, right) = unsafe { (*a.add(i), *b.add(i)) };
        if left != right {
            return left as i32 - right as i32;
        }
        i += 1;
    }
    0
}

/// Return the byte length of a NUL-terminated string.
///
/// # Safety
///
/// `s` must point to a readable sequence terminated by a NUL byte.
#[cfg_attr(target_os = "none", no_mangle)]
pub unsafe extern "C" fn strlen(s: *const u8) -> usize {
    let mut n = 0;
    while unsafe { *s.add(n) } != 0 {
        n += 1;
    }
    n
}

/// Return the byte length of a NUL-terminated string.
///
/// # Safety
///
/// `s` must satisfy [`strlen`]'s contract.
pub unsafe fn cstr_len(s: *const u8) -> usize {
    unsafe { strlen(s) }
}

/// Borrow the non-NUL bytes of a C string as a slice.
///
/// # Safety
///
/// `s` must point to a readable NUL-terminated sequence that remains valid for
/// the returned lifetime.
pub unsafe fn cstr_bytes<'a>(s: *const u8) -> &'a [u8] {
    let len = unsafe { cstr_len(s) };
    unsafe { slice::from_raw_parts(s, len) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_fill_and_compare_are_byte_exact() {
        let src = *b"strict-align";
        let mut dst = [0u8; 12];
        unsafe { memcpy(dst.as_mut_ptr(), src.as_ptr(), src.len()) };
        assert_eq!(dst, src);
        assert_eq!(unsafe { memcmp(dst.as_ptr(), src.as_ptr(), src.len()) }, 0);

        unsafe { memset(dst.as_mut_ptr().add(6), b'X' as i32, 3) };
        assert_eq!(&dst, b"strictXXXign");
        assert!(unsafe { memcmp(dst.as_ptr(), src.as_ptr(), src.len()) } > 0);
    }

    #[test]
    fn memmove_handles_overlap_in_both_directions() {
        let mut right = *b"abcdef";
        unsafe { memmove(right.as_mut_ptr().add(1), right.as_ptr(), 5) };
        assert_eq!(&right, b"aabcde");

        let mut left = *b"abcdef";
        unsafe { memmove(left.as_mut_ptr(), left.as_ptr().add(1), 5) };
        assert_eq!(&left, b"bcdeff");
    }

    #[test]
    fn c_string_helpers_exclude_the_terminator() {
        let s = b"hello\0ignored";
        assert_eq!(unsafe { cstr_len(s.as_ptr()) }, 5);
        assert_eq!(unsafe { cstr_bytes(s.as_ptr()) }, b"hello");
    }
}
