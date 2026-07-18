//! Deterministic newc cpio encoder — the Rust owner of the initramfs image.
//!
//! Ports `scripts/build_initramfs.zig` byte-for-byte. The archive bytes are a
//! pure function of the entry list (name, mode, contents), never of host
//! filesystem state: mtime, uid, gid, nlink, dev, and the check field are all
//! fixed, and the inode counter is derived from list position. Two clean builds
//! therefore produce an identical `kernel8.img` sha256 — the property `bsdcpio`
//! could not give (it stamped the host clock into c_mtime and a fresh inode per
//! entry), which is why the encoder is owned in-tree.
//!
//! Each entry's archive name is `./<arc>` so it matches the cpio(1)
//! `find . -type f` layout the kernel's `src/initramfs.zig` parser already
//! canonicalises via its `./`-strip — `locate("/sbin/init")` then resolves.

const MAGIC: &[u8] = b"070701";
/// Fixed newc header length: magic + 13 eight-digit hex fields.
const HEADER_SIZE: usize = 110;

/// One staged file: its archive path (without the `./` prefix), its newc mode,
/// and its contents.
pub struct Entry {
    pub arc: String,
    pub mode: u32,
    pub data: Vec<u8>,
}

/// Encode `entries` into a complete newc cpio archive, trailer included.
///
/// The caller supplies `entries` already sorted the way the archive's entry
/// order — and therefore its sha256 — is defined; the encoder does not reorder.
pub fn encode(entries: &[Entry]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut ino: u32 = 1;
    for e in entries {
        emit_entry(&mut out, ino, &e.arc, e.mode, &e.data);
        ino += 1;
    }
    emit_trailer(&mut out, ino);
    out
}

fn emit_entry(out: &mut Vec<u8>, ino: u32, arc: &str, mode: u32, data: &[u8]) {
    // Name written into the archive is "./<arc>\0" (see module docs).
    let mut name = Vec::with_capacity(arc.len() + 3);
    name.extend_from_slice(b"./");
    name.extend_from_slice(arc.as_bytes());
    name.push(0);

    write_header(out, ino, mode, data.len() as u32, name.len() as u32);
    out.extend_from_slice(&name);
    pad_to_4(out, HEADER_SIZE + name.len());
    out.extend_from_slice(data);
    pad_to_4(out, data.len());
}

fn emit_trailer(out: &mut Vec<u8>, ino: u32) {
    let name = b"TRAILER!!!\x00";
    write_header(out, ino, 0, 0, name.len() as u32);
    out.extend_from_slice(name);
    pad_to_4(out, HEADER_SIZE + name.len());
}

fn write_header(out: &mut Vec<u8>, ino: u32, mode: u32, filesize: u32, namesize: u32) {
    out.extend_from_slice(MAGIC);
    write_hex8(out, ino);
    write_hex8(out, mode);
    write_hex8(out, 0); // uid
    write_hex8(out, 0); // gid
    write_hex8(out, 1); // nlink — GNU cpio writes 1 on the trailer too
    write_hex8(out, 0); // mtime
    write_hex8(out, filesize);
    write_hex8(out, 0); // devmajor
    write_hex8(out, 0); // devminor
    write_hex8(out, 0); // rdevmajor
    write_hex8(out, 0); // rdevminor
    write_hex8(out, namesize);
    write_hex8(out, 0); // check
}

/// Eight-digit uppercase zero-padded hex, the newc field format.
fn write_hex8(out: &mut Vec<u8>, v: u32) {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut buf = [0u8; 8];
    let mut x = v;
    let mut i = 8;
    while i > 0 {
        i -= 1;
        buf[i] = HEX[(x & 0xF) as usize];
        x >>= 4;
    }
    out.extend_from_slice(&buf);
}

/// Pad `out` with NUL up to the next 4-byte boundary, given that `n` bytes of
/// the field being aligned have been written. newc aligns both the name (after
/// the header) and the data.
fn pad_to_4(out: &mut Vec<u8>, n: usize) {
    let pad = (4 - (n & 3)) & 3;
    out.extend(std::iter::repeat_n(0u8, pad));
}

#[cfg(test)]
mod tests {
    use super::*;

    // Pin the byte offsets the kernel parser (src/initramfs.zig) reads: mode at
    // 14, uid at 22, gid at 30. A drift between this encoder and that parser is a
    // silent permission bypass, so the offsets are asserted against literal hex —
    // the same assertions the ported zig encoder carried.

    #[test]
    fn emit_entry_stamps_the_per_file_mode_into_the_newc_mode_field() {
        let mut out = Vec::new();
        emit_entry(&mut out, 1, "etc/shadow", 0o100600, b"x");
        assert_eq!(&out[0..6], b"070701");
        // 0o100600 == 0x8180; newc fields are 8-digit uppercase hex.
        assert_eq!(&out[14..22], b"00008180");
        assert_eq!(&out[22..30], b"00000000"); // uid root
        assert_eq!(&out[30..38], b"00000000"); // gid root
    }

    #[test]
    fn two_entries_get_distinct_modes() {
        let mut out = Vec::new();
        emit_entry(&mut out, 1, "bin/fsh", 0o100755, b"\x7fELF");
        let first_len = out.len();
        emit_entry(&mut out, 2, "etc/shadow", 0o100600, b"s");
        // 0o100755 == 0x81ED on the first header; 0x8180 on the second.
        assert_eq!(&out[14..22], b"000081ED");
        assert_eq!(&out[first_len + 14..first_len + 22], b"00008180");
    }

    #[test]
    fn header_and_data_are_padded_to_four_bytes() {
        // "./bin/x\0" is 8 bytes → namesize 8; header 110 + 8 = 118, pad 2 → 120.
        // One data byte → pad 3 → the whole entry is 4-aligned.
        let mut out = Vec::new();
        emit_entry(&mut out, 1, "bin/x", 0o100755, b"z");
        assert_eq!(out.len() % 4, 0);
        assert_eq!(&out[110..118], b"./bin/x\0");
        assert_eq!(&out[118..120], b"\0\0"); // the 2 pad bytes after the name
    }

    #[test]
    fn trailer_closes_the_archive() {
        let out = encode(&[]);
        assert_eq!(&out[110..121], b"TRAILER!!!\0");
        assert_eq!(out.len() % 4, 0);
        // Empty archive is exactly one trailer entry, name-padded.
        assert_eq!(out.len(), 124);
    }
}
