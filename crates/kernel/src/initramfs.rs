//! Pure parser for the embedded `newc` CPIO archive.

const HEADER_SIZE: usize = 110;
const HEADER_MAGIC: &[u8] = b"070701";
const TRAILER: &[u8] = b"TRAILER!!!";

const OFF_MODE: usize = 6 + 8;
const OFF_UID: usize = 6 + 8 * 2;
const OFF_GID: usize = 6 + 8 * 3;
const OFF_FILESIZE: usize = 6 + 8 * 6;
const OFF_NAMESIZE: usize = 6 + 8 * 11;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParseError {
    InvalidHex,
    BadMagic,
    ShortArchive,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Entry<'a> {
    pub name: &'a [u8],
    pub data: &'a [u8],
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
}

pub struct Iterator<'a> {
    archive: &'a [u8],
    cursor: usize,
}

impl<'a> Iterator<'a> {
    pub const fn new(archive: &'a [u8]) -> Self {
        Self { archive, cursor: 0 }
    }

    pub fn next_entry(&mut self) -> Result<Option<Entry<'a>>, ParseError> {
        let header_end = self
            .cursor
            .checked_add(HEADER_SIZE)
            .ok_or(ParseError::ShortArchive)?;
        let header = self
            .archive
            .get(self.cursor..header_end)
            .ok_or(ParseError::ShortArchive)?;
        if header.get(..6) != Some(HEADER_MAGIC) {
            return Err(ParseError::BadMagic);
        }

        let mode = parse_hex8(field(header, OFF_MODE)?)?;
        let uid = parse_hex8(field(header, OFF_UID)?)?;
        let gid = parse_hex8(field(header, OFF_GID)?)?;
        let file_size = parse_hex8(field(header, OFF_FILESIZE)?)? as usize;
        let name_size = parse_hex8(field(header, OFF_NAMESIZE)?)? as usize;
        if name_size == 0 {
            return Err(ParseError::ShortArchive);
        }

        let name_start = header_end;
        let name_with_nul_end = name_start
            .checked_add(name_size)
            .ok_or(ParseError::ShortArchive)?;
        let raw_name = self
            .archive
            .get(name_start..name_with_nul_end - 1)
            .ok_or(ParseError::ShortArchive)?;
        let name = raw_name
            .strip_prefix(b".")
            .filter(|rest| rest.starts_with(b"/"));
        let name = name.unwrap_or(raw_name);

        let data_start = align4(name_with_nul_end).ok_or(ParseError::ShortArchive)?;
        let data_end = data_start
            .checked_add(file_size)
            .ok_or(ParseError::ShortArchive)?;
        let data = self
            .archive
            .get(data_start..data_end)
            .ok_or(ParseError::ShortArchive)?;
        self.cursor = align4(data_end).ok_or(ParseError::ShortArchive)?;

        if name == TRAILER {
            return Ok(None);
        }
        Ok(Some(Entry {
            name,
            data,
            mode,
            uid,
            gid,
        }))
    }
}

pub fn locate<'a>(archive: &'a [u8], path: &[u8]) -> Result<Option<Entry<'a>>, ParseError> {
    let mut iterator = Iterator::new(archive);
    while let Some(entry) = iterator.next_entry()? {
        if entry.name == path {
            return Ok(Some(entry));
        }
    }
    Ok(None)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DirectChild<'a> {
    pub child: &'a [u8],
    pub is_dir: bool,
}

pub fn direct_entry<'a>(name: &'a [u8], prefix: &[u8]) -> Option<DirectChild<'a>> {
    if name.len() <= prefix.len() || !name.starts_with(prefix) {
        return None;
    }
    let rest = &name[prefix.len()..];
    match rest.iter().position(|byte| *byte == b'/') {
        Some(slash) => Some(DirectChild {
            child: &rest[..slash],
            is_dir: true,
        }),
        None => Some(DirectChild {
            child: rest,
            is_dir: false,
        }),
    }
}

fn field(header: &[u8], offset: usize) -> Result<&[u8; 8], ParseError> {
    header
        .get(offset..offset + 8)
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or(ParseError::ShortArchive)
}

fn parse_hex8(bytes: &[u8; 8]) -> Result<u32, ParseError> {
    let mut value = 0u32;
    for byte in bytes {
        value <<= 4;
        value |= match byte {
            b'0'..=b'9' => u32::from(byte - b'0'),
            b'A'..=b'F' => u32::from(byte - b'A' + 10),
            b'a'..=b'f' => u32::from(byte - b'a' + 10),
            _ => return Err(ParseError::InvalidHex),
        };
    }
    Ok(value)
}

fn align4(value: usize) -> Option<usize> {
    value.checked_add(3).map(|sum| sum & !3)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{format, vec::Vec};

    #[derive(Clone, Copy)]
    struct FixtureEntry<'a> {
        name: &'a [u8],
        data: &'a [u8],
        mode: u32,
        uid: u32,
        gid: u32,
    }

    fn push_hex8(out: &mut Vec<u8>, value: u32) {
        out.extend_from_slice(format!("{value:08X}").as_bytes());
    }

    fn push_entry(out: &mut Vec<u8>, entry: FixtureEntry<'_>) {
        out.extend_from_slice(HEADER_MAGIC);
        push_hex8(out, 1);
        push_hex8(out, entry.mode);
        push_hex8(out, entry.uid);
        push_hex8(out, entry.gid);
        push_hex8(out, 1);
        push_hex8(out, 0);
        push_hex8(out, entry.data.len() as u32);
        for _ in 0..4 {
            push_hex8(out, 0);
        }
        push_hex8(out, (entry.name.len() + 1) as u32);
        push_hex8(out, 0);
        out.extend_from_slice(entry.name);
        out.push(0);
        while out.len() & 3 != 0 {
            out.push(0);
        }
        out.extend_from_slice(entry.data);
        while out.len() & 3 != 0 {
            out.push(0);
        }
    }

    fn fixture(entries: &[FixtureEntry<'_>]) -> Vec<u8> {
        let mut out = Vec::new();
        for entry in entries {
            push_entry(&mut out, *entry);
        }
        push_entry(
            &mut out,
            FixtureEntry {
                name: TRAILER,
                data: b"",
                mode: 0,
                uid: 0,
                gid: 0,
            },
        );
        out
    }

    #[test]
    fn locate_hit_returns_name_data_mode_and_root_ownership() {
        let archive = fixture(&[FixtureEntry {
            name: b"hi",
            data: b"OK",
            mode: 0o100644,
            uid: 0,
            gid: 0,
        }]);
        let entry = locate(&archive, b"hi").unwrap().unwrap();
        assert_eq!(entry.name, b"hi");
        assert_eq!(entry.data, b"OK");
        assert_eq!(entry.mode, 0o100644);
        assert_eq!(entry.uid, 0);
        assert_eq!(entry.gid, 0);
    }

    #[test]
    fn locate_parses_uid_and_gid() {
        let archive = fixture(&[FixtureEntry {
            name: b"home",
            data: b"X",
            mode: 0o100600,
            uid: 1000,
            gid: 1000,
        }]);
        let entry = locate(&archive, b"home").unwrap().unwrap();
        assert_eq!((entry.mode, entry.uid, entry.gid), (0o100600, 1000, 1000));
    }

    #[test]
    fn locate_miss_returns_none() {
        let archive = fixture(&[FixtureEntry {
            name: b"/sbin/init",
            data: b"X",
            mode: 0o100755,
            uid: 0,
            gid: 0,
        }]);
        assert_eq!(locate(&archive, b"/nope"), Ok(None));
    }

    #[test]
    fn trailer_alone_terminates_iteration() {
        assert_eq!(Iterator::new(&fixture(&[])).next_entry(), Ok(None));
    }

    #[test]
    fn multi_entry_walk_preserves_order_and_padding() {
        let archive = fixture(&[
            FixtureEntry {
                name: b"a",
                data: b"AAA",
                mode: 0o100644,
                uid: 0,
                gid: 0,
            },
            FixtureEntry {
                name: b"bb",
                data: b"BB",
                mode: 0o100644,
                uid: 0,
                gid: 0,
            },
            FixtureEntry {
                name: b"ccc",
                data: b"C",
                mode: 0o100644,
                uid: 0,
                gid: 0,
            },
        ]);
        let mut it = Iterator::new(&archive);
        assert_eq!(it.next_entry().unwrap().unwrap().data, b"AAA");
        assert_eq!(it.next_entry().unwrap().unwrap().data, b"BB");
        assert_eq!(it.next_entry().unwrap().unwrap().data, b"C");
        assert_eq!(it.next_entry(), Ok(None));
    }

    #[test]
    fn bad_magic_is_rejected() {
        let mut archive = [0u8; HEADER_SIZE];
        archive[..6].copy_from_slice(b"999999");
        assert_eq!(
            Iterator::new(&archive).next_entry(),
            Err(ParseError::BadMagic)
        );
    }

    #[test]
    fn leading_dot_slash_canonicalizes_to_slash() {
        let archive = fixture(&[FixtureEntry {
            name: b"./sbin/init",
            data: b"\x7fELF",
            mode: 0o100755,
            uid: 0,
            gid: 0,
        }]);
        let entry = locate(&archive, b"/sbin/init").unwrap().unwrap();
        assert_eq!(entry.name, b"/sbin/init");
        assert_eq!(entry.data, b"\x7fELF");
    }

    #[test]
    fn short_header_is_rejected() {
        let mut archive = [0u8; 50];
        archive[..6].copy_from_slice(HEADER_MAGIC);
        assert_eq!(
            Iterator::new(&archive).next_entry(),
            Err(ParseError::ShortArchive)
        );
    }

    #[test]
    fn direct_leaf_under_its_directory() {
        assert_eq!(
            direct_entry(b"/bin/cat", b"/bin/"),
            Some(DirectChild {
                child: b"cat",
                is_dir: false
            })
        );
    }

    #[test]
    fn nested_file_contributes_a_synthetic_directory() {
        assert_eq!(
            direct_entry(b"/bin/cat", b"/"),
            Some(DirectChild {
                child: b"bin",
                is_dir: true
            })
        );
    }

    #[test]
    fn direct_entry_rejects_an_outside_name() {
        assert_eq!(direct_entry(b"/sbin/init", b"/bin/"), None);
    }

    #[test]
    fn directory_itself_contributes_nothing() {
        assert_eq!(direct_entry(b"/bin", b"/bin/"), None);
        assert_eq!(direct_entry(b"/bin/", b"/bin/"), None);
    }

    #[test]
    fn deeper_nesting_lists_only_the_first_segment() {
        assert_eq!(
            direct_entry(b"/usr/local/bin/x", b"/usr/"),
            Some(DirectChild {
                child: b"local",
                is_dir: true
            })
        );
    }
}
