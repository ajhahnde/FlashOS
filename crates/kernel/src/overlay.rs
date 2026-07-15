//! FAT32 permission-overlay parser.
//!
//! FAT32 has no native owner or mode fields, so the root-level `PERMS.TAB`
//! supplies fixed metadata for selected 8.3 basenames. Parsing is allocation
//! free and rejects a malformed file wholesale: a partial policy is
//! indistinguishable from corruption, and the backend must fall back to its
//! protected defaults instead.

pub const MAX_ENTRIES: usize = 16;
pub const MAX_NAME: usize = 12;

/// One parsed `NAME MODE UID GID` row retained in the backend's fixed table.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Entry {
    pub name_buf: [u8; MAX_NAME],
    pub name_len: u8,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
}

const _: () = assert!(core::mem::size_of::<Entry>() == 28);
const _: () = assert!(core::mem::align_of::<Entry>() == 4);
const _: () = assert!(core::mem::offset_of!(Entry, name_buf) == 0);
const _: () = assert!(core::mem::offset_of!(Entry, name_len) == 12);
const _: () = assert!(core::mem::offset_of!(Entry, mode) == 16);
const _: () = assert!(core::mem::offset_of!(Entry, uid) == 20);
const _: () = assert!(core::mem::offset_of!(Entry, gid) == 24);

impl Entry {
    pub fn name(&self) -> &[u8] {
        &self.name_buf[..usize::from(self.name_len)]
    }
}

/// Parse an overlay into `out`, returning the populated prefix length.
///
/// Empty and comment-only files are valid. Any malformed non-comment line or
/// capacity overflow rejects the complete input.
pub fn parse(content: &[u8], out: &mut [Entry]) -> Option<usize> {
    let mut count = 0usize;
    let mut line_start = 0usize;
    let mut i = 0usize;
    while i <= content.len() {
        if i == content.len() || content[i] == b'\n' {
            let mut line = &content[line_start..i];
            line_start = i.saturating_add(1);
            if line.last() == Some(&b'\r') {
                line = &line[..line.len() - 1];
            }
            let trimmed = trim(line);
            if !trimmed.is_empty() && trimmed[0] != b'#' {
                let mut fields = [&[][..]; 4];
                let mut field_count = 0usize;
                let mut cursor = 0usize;
                while cursor < trimmed.len() {
                    while cursor < trimmed.len() && is_space(trimmed[cursor]) {
                        cursor += 1;
                    }
                    if cursor >= trimmed.len() {
                        break;
                    }
                    let start = cursor;
                    while cursor < trimmed.len() && !is_space(trimmed[cursor]) {
                        cursor += 1;
                    }
                    if field_count == fields.len() {
                        return None;
                    }
                    fields[field_count] = &trimmed[start..cursor];
                    field_count += 1;
                }
                if field_count != fields.len() {
                    return None;
                }

                let name = fields[0];
                if name.is_empty() || name.len() > MAX_NAME {
                    return None;
                }
                let mode = parse_octal_u32(fields[1])?;
                if mode > 0o777 {
                    return None;
                }
                let uid = parse_decimal_u32(fields[2])?;
                let gid = parse_decimal_u32(fields[3])?;
                let slot = out.get_mut(count)?;
                let mut name_buf = [0; MAX_NAME];
                name_buf[..name.len()].copy_from_slice(name);
                *slot = Entry {
                    name_buf,
                    name_len: name.len() as u8,
                    mode,
                    uid,
                    gid,
                };
                count += 1;
            }
        }
        i += 1;
    }
    Some(count)
}

/// Return the first case-insensitive basename match.
pub fn lookup(entries: &[Entry], name: &[u8]) -> Option<Entry> {
    entries
        .iter()
        .copied()
        .find(|entry| name_eql(entry.name(), name))
}

/// FAT32 8.3 names compare case-insensitively over ASCII bytes.
pub fn name_eql(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len()
        && a.iter()
            .zip(b)
            .all(|(&left, &right)| lower(left) == lower(right))
}

fn is_space(byte: u8) -> bool {
    byte == b' ' || byte == b'\t'
}

fn trim(mut bytes: &[u8]) -> &[u8] {
    while bytes.first().is_some_and(|&byte| is_space(byte)) {
        bytes = &bytes[1..];
    }
    while bytes.last().is_some_and(|&byte| is_space(byte)) {
        bytes = &bytes[..bytes.len() - 1];
    }
    bytes
}

fn lower(byte: u8) -> u8 {
    if byte.is_ascii_uppercase() {
        byte + (b'a' - b'A')
    } else {
        byte
    }
}

fn parse_octal_u32(bytes: &[u8]) -> Option<u32> {
    parse_u32(bytes, 8, b'7')
}

fn parse_decimal_u32(bytes: &[u8]) -> Option<u32> {
    parse_u32(bytes, 10, b'9')
}

fn parse_u32(bytes: &[u8], radix: u64, max_digit: u8) -> Option<u32> {
    if bytes.is_empty() {
        return None;
    }
    let mut value = 0u64;
    for &byte in bytes {
        if byte < b'0' || byte > max_digit {
            return None;
        }
        value = value * radix + u64::from(byte - b'0');
        if value > u64::from(u32::MAX) {
            return None;
        }
    }
    Some(value as u32)
}

#[cfg(test)]
mod tests {
    use super::{lookup, parse, Entry, MAX_ENTRIES};

    #[test]
    fn well_formed_multi_line_overlay() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        let content = b"PERMS.TAB 0600 0 0\nSHADOW 0600 0 0\nROUNDTR.DAT 0666 0 0\n";
        let count = parse(content, &mut table).unwrap();
        assert_eq!(count, 3);
        assert_eq!(table[0].name(), b"PERMS.TAB");
        assert_eq!(table[0].mode, 0o600);
        assert_eq!(table[0].uid, 0);
        assert_eq!(table[0].gid, 0);
        assert_eq!(table[1].name(), b"SHADOW");
        assert_eq!(table[2].mode, 0o666);
    }

    #[test]
    fn comments_blank_lines_and_surrounding_whitespace_are_skipped() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        let content = b"# FlashOS FAT32 permission overlay\n\n   \n  SHADOW   0600  0   0  \n# trailing comment\n";
        let count = parse(content, &mut table).unwrap();
        assert_eq!(count, 1);
        assert_eq!(table[0].name(), b"SHADOW");
    }

    #[test]
    fn crlf_line_endings_are_tolerated() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        let count = parse(b"SHADOW 0600 0 0\r\nPERMS.TAB 0600 0 0\r\n", &mut table).unwrap();
        assert_eq!(count, 2);
        assert_eq!(table[0].name(), b"SHADOW");
        assert_eq!(table[1].name(), b"PERMS.TAB");
    }

    #[test]
    fn last_line_needs_no_trailing_newline() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        assert_eq!(parse(b"SHADOW 0600 0 0", &mut table), Some(1));
    }

    #[test]
    fn empty_and_comment_only_files_are_valid() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        assert_eq!(parse(b"", &mut table), Some(0));
        assert_eq!(parse(b"# nothing here\n", &mut table), Some(0));
    }

    #[test]
    fn missing_field_rejects_the_whole_overlay() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        assert_eq!(parse(b"SHADOW 0600 0\n", &mut table), None);
        assert_eq!(parse(b"SHADOW 0600\n", &mut table), None);
        assert_eq!(parse(b"SHADOW\n", &mut table), None);
    }

    #[test]
    fn fifth_field_rejects_the_whole_overlay() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        assert_eq!(parse(b"SHADOW 0600 0 0 extra\n", &mut table), None);
    }

    #[test]
    fn one_malformed_line_rejects_the_whole_overlay() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        assert_eq!(
            parse(b"SHADOW 0600 0 0\nPERMS.TAB 9999 0 0\n", &mut table),
            None
        );
    }

    #[test]
    fn non_octal_and_overwide_modes_reject() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        assert_eq!(parse(b"SHADOW 08 0 0\n", &mut table), None);
        assert_eq!(parse(b"SHADOW abc 0 0\n", &mut table), None);
        assert_eq!(parse(b"SHADOW 1777 0 0\n", &mut table), None);
    }

    #[test]
    fn non_decimal_ids_reject() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        assert_eq!(parse(b"SHADOW 0600 root 0\n", &mut table), None);
        assert_eq!(parse(b"SHADOW 0600 0 0x0\n", &mut table), None);
    }

    #[test]
    fn overlong_name_rejects() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        assert_eq!(parse(b"ABCDEFGHI.TXT 0600 0 0\n", &mut table), None);
    }

    #[test]
    fn capacity_overflow_rejects() {
        let mut table = [empty_entry(); 2];
        assert_eq!(
            parse(b"A 0600 0 0\nB 0600 0 0\nC 0600 0 0\n", &mut table),
            None
        );
    }

    #[test]
    fn lookup_is_case_insensitive_and_can_miss() {
        let mut table = [empty_entry(); MAX_ENTRIES];
        let count = parse(b"SHADOW 0600 0 0\nPERMS.TAB 0600 0 0\n", &mut table).unwrap();
        assert_eq!(lookup(&table[..count], b"shadow").unwrap().mode, 0o600);
        assert_eq!(
            lookup(&table[..count], b"perms.tab").unwrap().name(),
            b"PERMS.TAB"
        );
        assert!(lookup(&table[..count], b"roundtr.dat").is_none());
    }

    #[test]
    fn empty_table_always_misses() {
        assert!(lookup(&[], b"shadow").is_none());
    }

    const fn empty_entry() -> Entry {
        Entry {
            name_buf: [0; 12],
            name_len: 0,
            mode: 0,
            uid: 0,
            gid: 0,
        }
    }
}
