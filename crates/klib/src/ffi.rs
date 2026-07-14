//! The C-ABI seam between the remaining Flash kernel and the Rust modules.
//!
//! Every function here exists only because two languages currently share one
//! kernel image. Flash cannot see Rust slices, so each entry point takes an
//! explicit pointer/length pair, and each is re-wrapped on the Flash side into
//! the slice-shaped signature its callers already use. When a Flash caller ports,
//! its shim here goes with it; when the last one ports, this module is deleted.
//!
//! Rules for anything added here: `extern "C"`, `#[no_mangle]`, no panic may
//! cross the boundary, and no Rust type without a fixed representation.

use flashos_kernel::{path, perm, sha256, shadow};

const NONE: usize = usize::MAX;

/// Offset-based representation of a parsed shadow entry. The slices all point
/// into the input line, so only their offsets and lengths cross the ABI.
#[derive(Clone, Copy)]
#[repr(C)]
pub struct FosShadowEntry {
    user_offset: usize,
    user_len: usize,
    iterations: u32,
    salt_offset: usize,
    salt_len: usize,
    hash_offset: usize,
    hash_len: usize,
}

unsafe extern "C" {
    /// The kernel's panic (`src/utilc.flash`): prints the message and halts.
    pub unsafe fn panic(msg: *const u8) -> !;
}

/// PBKDF2-HMAC-SHA256 over caller-owned buffers.
///
/// SAFETY (caller's obligation, checked by the Flash wrapper's slice types):
/// `password`/`salt` point to `password_len`/`salt_len` readable bytes, and
/// `out` to `out_len` writable bytes; none of the three overlap.
///
/// # Safety
/// See above.
#[no_mangle]
pub unsafe extern "C" fn fos_pbkdf2_hmac_sha256(
    password: *const u8,
    password_len: usize,
    salt: *const u8,
    salt_len: usize,
    iterations: u32,
    out: *mut u8,
    out_len: usize,
) {
    // SAFETY: the caller guarantees each pointer/length pair describes a live,
    // non-overlapping region; a zero length yields an empty slice, for which the
    // pointer is never dereferenced (it must still be non-null and aligned, which
    // holds for every Flash slice, including empty ones taken from real arrays).
    let password = unsafe { slice_from_raw(password, password_len) };
    let salt = unsafe { slice_from_raw(salt, salt_len) };
    let out = unsafe { core::slice::from_raw_parts_mut(out, out_len) };
    sha256::pbkdf2_hmac_sha256(password, salt, iterations, out);
}

/// Constant-time byte-slice equality. Returns 1 on equal, 0 otherwise — a plain
/// byte, not a Rust `bool`, so the value crossing the boundary is one both
/// languages agree on.
///
/// # Safety
/// `a`/`b` point to `a_len`/`b_len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn fos_ct_eql(a: *const u8, a_len: usize, b: *const u8, b_len: usize) -> u8 {
    // SAFETY: as documented above; both regions are read-only and may overlap.
    let a = unsafe { slice_from_raw(a, a_len) };
    let b = unsafe { slice_from_raw(b, b_len) };
    u8::from(sha256::ct_eql(a, b))
}

/// Normalize a path into `out`, returning its length or `usize::MAX` on error.
///
/// # Safety
/// Each pointer describes a live region of the accompanying length. `out`
/// must be writable and must not overlap either input.
#[no_mangle]
pub unsafe extern "C" fn fos_path_join_resolve(
    cwd: *const u8,
    cwd_len: usize,
    rel: *const u8,
    rel_len: usize,
    out: *mut u8,
    out_len: usize,
) -> usize {
    let cwd = unsafe { slice_from_raw(cwd, cwd_len) };
    let rel = unsafe { slice_from_raw(rel, rel_len) };
    let out = unsafe { mut_slice_from_raw(out, out_len) };
    path::join_resolve(cwd, rel, out).map_or(NONE, |resolved| resolved.len())
}

/// Check one Unix permission intent. Invalid intent tags fail closed.
#[no_mangle]
pub extern "C" fn fos_perm_check_access(
    mode: u32,
    file_uid: u32,
    file_gid: u32,
    euid: u32,
    egid: u32,
    want: u8,
) -> u8 {
    let want = match want {
        0 => perm::Access::Read,
        1 => perm::Access::Write,
        2 => perm::Access::Exec,
        _ => return 0,
    };
    u8::from(perm::check_access(
        mode, file_uid, file_gid, euid, egid, want,
    ))
}

/// Parse one shadow line into offsets relative to that line.
///
/// # Safety
/// `line` is readable for `line_len` bytes and `out` points to writable,
/// properly aligned storage for one `FosShadowEntry`.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_parse_line(
    line: *const u8,
    line_len: usize,
    out: *mut FosShadowEntry,
) -> u8 {
    let line = unsafe { slice_from_raw(line, line_len) };
    let Some(entry) = shadow::parse_line(line) else {
        return 0;
    };
    let base = line.as_ptr() as usize;
    let result = FosShadowEntry {
        user_offset: entry.user.as_ptr() as usize - base,
        user_len: entry.user.len(),
        iterations: entry.iterations,
        salt_offset: entry.salt_hex.as_ptr() as usize - base,
        salt_len: entry.salt_hex.len(),
        hash_offset: entry.hash_hex.as_ptr() as usize - base,
        hash_len: entry.hash_hex.len(),
    };
    unsafe { out.write(result) };
    1
}

/// Decode hex, returning the byte count or `usize::MAX` on error.
///
/// # Safety
/// The input is readable and the output writable for their stated lengths;
/// the regions do not overlap.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_hex_decode(
    input: *const u8,
    input_len: usize,
    out: *mut u8,
    out_len: usize,
) -> usize {
    let input = unsafe { slice_from_raw(input, input_len) };
    let out = unsafe { mut_slice_from_raw(out, out_len) };
    shadow::hex_decode(input, out).unwrap_or(NONE)
}

/// Encode lowercase hex, returning the character count or `usize::MAX`.
///
/// # Safety
/// The input is readable and the output writable for their stated lengths;
/// the regions do not overlap.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_hex_encode(
    input: *const u8,
    input_len: usize,
    out: *mut u8,
    out_len: usize,
) -> usize {
    let input = unsafe { slice_from_raw(input, input_len) };
    let out = unsafe { mut_slice_from_raw(out, out_len) };
    shadow::hex_encode(input, out).unwrap_or(NONE)
}

/// Find a user's line, writing its byte span and returning 1 on success.
///
/// # Safety
/// Both input regions are readable for their stated lengths; `start` and
/// `end` point to writable, aligned `usize` values.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_find_user_line(
    content: *const u8,
    content_len: usize,
    user: *const u8,
    user_len: usize,
    start: *mut usize,
    end: *mut usize,
) -> u8 {
    let content = unsafe { slice_from_raw(content, content_len) };
    let user = unsafe { slice_from_raw(user, user_len) };
    let Some(span) = shadow::find_user_line(content, user) else {
        return 0;
    };
    unsafe {
        start.write(span.start);
        end.write(span.end);
    }
    1
}

/// Rewrite a shadow line in place, returning 1 on success.
///
/// # Safety
/// `content` is writable for its stated length; the other regions are
/// readable and do not overlap `content` or each other.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_rewrite_line_in_place(
    content: *mut u8,
    content_len: usize,
    user: *const u8,
    user_len: usize,
    salt: *const u8,
    salt_len: usize,
    hash: *const u8,
    hash_len: usize,
) -> u8 {
    let content = unsafe { mut_slice_from_raw(content, content_len) };
    let user = unsafe { slice_from_raw(user, user_len) };
    let salt = unsafe { slice_from_raw(salt, salt_len) };
    let hash = unsafe { slice_from_raw(hash, hash_len) };
    u8::from(shadow::rewrite_line_in_place(content, user, salt, hash))
}

/// `core::slice::from_raw_parts`, with the empty case made explicit rather than
/// trusting a possibly-dangling pointer that is never read.
///
/// # Safety
/// `ptr` points to `len` readable bytes, or `len` is 0.
unsafe fn slice_from_raw<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        return &[];
    }
    // SAFETY: the caller guarantees `len` readable bytes at `ptr`.
    unsafe { core::slice::from_raw_parts(ptr, len) }
}

/// Mutable counterpart of `slice_from_raw`.
///
/// # Safety
/// `ptr` points to `len` writable bytes, or `len` is 0.
unsafe fn mut_slice_from_raw<'a>(ptr: *mut u8, len: usize) -> &'a mut [u8] {
    if len == 0 {
        return &mut [];
    }
    // SAFETY: the caller guarantees `len` writable bytes at `ptr`.
    unsafe { core::slice::from_raw_parts_mut(ptr, len) }
}
