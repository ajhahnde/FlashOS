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

use flashos_kernel::{elf, klog_ring, mailbox, path, perm, sdhci_cmd, sha256, shadow};

const NONE: usize = usize::MAX;

fn elf_error_code(error: elf::ParseError) -> u32 {
    match error {
        elf::ParseError::BadMagic => 1,
        elf::ParseError::NotElf64 => 2,
        elf::ParseError::NotLittleEndian => 3,
        elf::ParseError::NotExecutable => 4,
        elf::ParseError::NotAarch64 => 5,
        elf::ParseError::BadVersion => 6,
        elf::ParseError::BadEntry => 7,
        elf::ParseError::EntryOutOfBounds => 8,
        elf::ParseError::PhoffOutOfBounds => 9,
        elf::ParseError::TooManyPhdrs => 10,
        elf::ParseError::MemszOverflow => 11,
        elf::ParseError::VaddrOutOfBounds => 12,
    }
}

/// Parse an ELF header into the ABI-owned output record. Zero means success.
///
/// # Safety
/// `blob` points to `blob_len` readable bytes and `output` points to one
/// writable, aligned `Ehdr` record.
#[no_mangle]
pub unsafe extern "C" fn fos_elf_parse_ehdr(
    blob: *const u8,
    blob_len: usize,
    output: *mut elf::Ehdr,
) -> u32 {
    if blob_len < core::mem::size_of::<elf::Ehdr>() {
        return elf_error_code(elf::ParseError::BadMagic);
    }
    let blob = unsafe { core::slice::from_raw_parts(blob, blob_len) };
    match elf::parse_ehdr(blob) {
        Ok(header) => {
            unsafe { output.write(header) };
            0
        }
        Err(error) => elf_error_code(error),
    }
}

/// Parse one ELF program header at `cursor`. Zero means success.
///
/// # Safety
/// `blob` points to `blob_len` readable bytes and `output` points to one
/// writable, aligned `Phdr` record.
#[no_mangle]
pub unsafe extern "C" fn fos_elf_parse_phdr(
    blob: *const u8,
    blob_len: usize,
    cursor: u64,
    output: *mut elf::Phdr,
) -> u32 {
    let blob = unsafe { core::slice::from_raw_parts(blob, blob_len) };
    match elf::parse_phdr_at(blob, cursor) {
        Ok(header) => {
            unsafe { output.write(header) };
            0
        }
        Err(error) => elf_error_code(error),
    }
}

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

/// Return the number of bytes retained by a shared-layout kernel log ring.
///
/// # Safety
/// `ring` points to a live `KlogRing` with the fixed layout asserted by Rust
/// and declared as an `extern struct` by the Flash adapter.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_available(ring: *const klog_ring::KlogRing) -> u64 {
    unsafe { klog_ring::available(ring) }
}

/// Read one absolute monotone position from the shared kernel log ring.
///
/// # Safety
/// `ring` satisfies [`fos_klog_available`]'s contract.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_byte_at(ring: *const klog_ring::KlogRing, position: u64) -> u8 {
    unsafe { klog_ring::byte_at(ring, position) }
}

/// Append one byte to the shared kernel log ring.
///
/// # Safety
/// `ring` points to a live writable `KlogRing`.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_push(ring: *mut klog_ring::KlogRing, byte: u8) {
    unsafe { klog_ring::push(ring, byte) }
}

/// Append a NUL-terminated string to the shared kernel log ring.
///
/// # Safety
/// `ring` points to a live writable `KlogRing`; `string` points to a readable,
/// NUL-terminated byte sequence.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_push_str(ring: *mut klog_ring::KlogRing, string: *const u8) {
    unsafe { klog_ring::push_c_str(ring, string) }
}

/// Snapshot the newest retained bytes into caller-owned storage.
///
/// # Safety
/// `ring` points to a live `KlogRing`; `dst` points to `dst_len` writable
/// bytes and does not overlap the ring.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_snapshot(
    ring: *const klog_ring::KlogRing,
    dst: *mut u8,
    dst_len: usize,
) -> usize {
    unsafe { klog_ring::snapshot(ring, dst, dst_len) }
}

/// Build a get-clock-rate property message.
///
/// # Safety
/// `message` points to eight writable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_build_get_clock_rate(message: *mut u32, clock_id: u32) {
    unsafe { store_mailbox_message(message, mailbox::build_get_clock_rate(clock_id)) }
}

/// Build a set-GPIO-state property message.
///
/// # Safety
/// `message` points to eight writable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_build_set_gpio_state(
    message: *mut u32,
    gpio: u32,
    state: u32,
) {
    unsafe { store_mailbox_message(message, mailbox::build_set_gpio_state(gpio, state)) }
}

/// Build a set-power-state property message.
///
/// # Safety
/// `message` points to eight writable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_build_set_power_state(
    message: *mut u32,
    device_id: u32,
    state: u32,
) {
    unsafe { store_mailbox_message(message, mailbox::build_set_power_state(device_id, state)) }
}

/// Build a get-temperature property message.
///
/// # Safety
/// `message` points to eight writable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_build_get_temperature(message: *mut u32, temp_id: u32) {
    unsafe { store_mailbox_message(message, mailbox::build_get_temperature(temp_id)) }
}

/// Check the overall property response code.
///
/// # Safety
/// `message` points to eight readable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_check_response(message: *const u32) -> u8 {
    let message = unsafe { load_mailbox_message(message) };
    u8::from(mailbox::check_response(&message))
}

/// Parse a clock-rate response, returning 0 on malformed input.
///
/// # Safety
/// `message` points to eight readable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_parse_clock_rate(message: *const u32, clock_id: u32) -> u32 {
    let message = unsafe { load_mailbox_message(message) };
    mailbox::parse_clock_rate(&message, clock_id).unwrap_or(0)
}

/// Parse a temperature response, returning 0 on malformed input.
///
/// # Safety
/// `message` points to eight readable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_parse_temperature(message: *const u32, temp_id: u32) -> u32 {
    let message = unsafe { load_mailbox_message(message) };
    mailbox::parse_temperature(&message, temp_id).unwrap_or(0)
}

/// Parse a power-state response. Plain integer booleans cross the ABI.
///
/// # Safety
/// `message` points to eight readable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_parse_power_state(
    message: *const u32,
    device_id: u32,
    want_on: u8,
) -> u8 {
    let message = unsafe { load_mailbox_message(message) };
    u8::from(mailbox::parse_power_state(
        &message,
        device_id,
        want_on != 0,
    ))
}

#[no_mangle]
pub extern "C" fn fos_mailbox_doorbell(buffer_address: u32, channel: u32) -> u32 {
    mailbox::doorbell(buffer_address, channel)
}

#[no_mangle]
pub extern "C" fn fos_sdhci_clock_divisor(base_hz: u32, target_hz: u32) -> u32 {
    sdhci_cmd::clock_divisor(base_hz, target_hz)
}

#[no_mangle]
pub extern "C" fn fos_sdhci_control1_clock_bits(divisor: u32) -> u32 {
    sdhci_cmd::control1_clock_bits(divisor)
}

/// Parse four controller response words, returning zero for an unsupported CSD.
#[no_mangle]
pub extern "C" fn fos_sdhci_parse_csd_v2(
    response0: u32,
    response1: u32,
    response2: u32,
    response3: u32,
) -> u64 {
    sdhci_cmd::parse_csd_v2([response0, response1, response2, response3])
        .map_or(0, |csd| csd.capacity_blocks)
}

/// Copy a local message to firmware-visible storage with volatile word writes.
///
/// # Safety
/// `destination` points to eight writable, suitably aligned `u32` words.
unsafe fn store_mailbox_message(destination: *mut u32, message: mailbox::Msg) {
    let mut index = 0usize;
    while index < message.len() {
        unsafe { destination.add(index).write_volatile(message[index]) };
        index += 1;
    }
}

/// Snapshot firmware-visible storage with volatile word reads.
///
/// # Safety
/// `source` points to eight readable, suitably aligned `u32` words.
unsafe fn load_mailbox_message(source: *const u32) -> mailbox::Msg {
    let mut message = [0; 8];
    let mut index = 0usize;
    while index < message.len() {
        message[index] = unsafe { source.add(index).read_volatile() };
        index += 1;
    }
    message
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
