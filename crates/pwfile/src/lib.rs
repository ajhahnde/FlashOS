//! `/etc/passwd` line parser.
//!
//! Pure and allocation-free: it borrows the caller's slurped file and hands back
//! slices into it, so a lookup costs no copy and no buffer of its own. One parser
//! for the account database, shared by every consumer that would otherwise roll
//! its own:
//!
//!   * `/bin/login` -- name -> {uid, gid, shell} for the privilege drop
//!   * `/bin/passwd` -- uid -> name, to target the caller's own record
//!   * `/bin/sysinfo` -- uid -> name, for the summary's `user` row
//!
//! Line format: `user:uid:gid:home:shell` (exactly five colon-delimited fields).
//! `/etc/passwd` itself stays an initramfs file -- the account LIST is
//! build-time-immutable; only passwords (`/etc/shadow`, `/mnt/shadow`) are mutable
//! state. The tests below pin the format against `rootfs/etc/passwd`.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

/// One parsed account record. Every field borrows the passwd buffer it was parsed
/// from, which is what keeps the parser allocation-free -- the buffer must outlive
/// the entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Entry<'a> {
    pub user: &'a [u8],
    pub uid: u32,
    pub gid: u32,
    pub home: &'a [u8],
    pub shell: &'a [u8],
}

/// Find the entry whose login name equals `name`. Returns `None` when absent or when
/// the matching line is malformed.
pub fn lookup_by_name<'a>(content: &'a [u8], name: &[u8]) -> Option<Entry<'a>> {
    lines(content)
        .filter_map(parse_line)
        .find(|e| e.user == name)
}

/// Find the entry whose uid equals `uid`. First match wins -- uids are unique in the
/// seed database.
pub fn lookup_by_uid(content: &[u8], uid: u32) -> Option<Entry<'_>> {
    lines(content).filter_map(parse_line).find(|e| e.uid == uid)
}

/// Split one passwd line (no trailing newline) into its five fields. Returns `None` on
/// a missing or extra field, an empty login name, or a non-decimal uid/gid.
pub fn parse_line(line: &[u8]) -> Option<Entry<'_>> {
    let mut fields: [&[u8]; 5] = [b""; 5];
    let mut nf = 0usize;
    let mut start = 0usize;

    for j in 0..=line.len() {
        if j == line.len() || line[j] == b':' {
            if nf == 5 {
                return None; // a sixth field is malformed
            }
            fields[nf] = &line[start..j];
            nf += 1;
            start = j + 1;
        }
    }
    if nf != 5 || fields[0].is_empty() {
        return None;
    }

    Some(Entry {
        user: fields[0],
        uid: parse_decimal_u32(fields[1])?,
        gid: parse_decimal_u32(fields[2])?,
        home: fields[3],
        shell: fields[4],
    })
}

/// Split `content` on newlines, tolerating CRLF the way the overlay parser does. The
/// final line needs no terminator.
fn lines(content: &[u8]) -> impl Iterator<Item = &[u8]> {
    content.split(|&b| b == b'\n').map(|line| {
        if let [head @ .., b'\r'] = line {
            head
        } else {
            line
        }
    })
}

/// Exact decimal `u32` parse: no sign, no whitespace, no overflow.
fn parse_decimal_u32(s: &[u8]) -> Option<u32> {
    if s.is_empty() {
        return None;
    }
    let mut v: u64 = 0;
    for &c in s {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v * 10 + u64::from(c - b'0');
        if v > u64::from(u32::MAX) {
            return None;
        }
    }
    Some(v as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Mirrors `rootfs/etc/passwd`.
    const FIXTURE: &[u8] = b"root:0:0:/root:/bin/fsh\nflash:1000:1000:/home/flash:/bin/fsh\n";

    #[test]
    fn lookup_by_name_finds_root_and_flash() {
        let root = lookup_by_name(FIXTURE, b"root").unwrap();
        assert_eq!(root.uid, 0);
        assert_eq!(root.gid, 0);
        assert_eq!(root.shell, b"/bin/fsh");

        let flash = lookup_by_name(FIXTURE, b"flash").unwrap();
        assert_eq!(flash.uid, 1000);
        assert_eq!(flash.home, b"/home/flash");
    }

    #[test]
    fn lookup_by_name_misses_an_absent_user() {
        assert_eq!(lookup_by_name(FIXTURE, b"anton"), None);
        // A prefix of an existing name must not match.
        assert_eq!(lookup_by_name(FIXTURE, b"fla"), None);
    }

    #[test]
    fn lookup_by_uid_finds_the_right_record() {
        assert_eq!(lookup_by_uid(FIXTURE, 1000).unwrap().user, b"flash");
        assert_eq!(lookup_by_uid(FIXTURE, 0).unwrap().user, b"root");
    }

    #[test]
    fn lookup_by_uid_misses_an_absent_uid() {
        assert_eq!(lookup_by_uid(FIXTURE, 4711), None);
    }

    #[test]
    fn parse_line_rejects_missing_extra_fields_and_bad_numbers() {
        assert_eq!(parse_line(b"flash:1000:1000:/home/flash"), None);
        assert_eq!(
            parse_line(b"flash:1000:1000:/home/flash:/bin/fsh:extra"),
            None
        );
        assert_eq!(parse_line(b"flash:10x0:1000:/home/flash:/bin/fsh"), None);
        assert_eq!(parse_line(b":0:0:/root:/bin/fsh"), None);
        assert_eq!(parse_line(b""), None);
    }

    #[test]
    fn lookups_skip_malformed_lines_instead_of_failing_the_file() {
        let mixed: &[u8] = b"# not a passwd line at all\nroot:0:0:/root:/bin/fsh\n";
        assert_eq!(lookup_by_name(mixed, b"root").unwrap().uid, 0);
    }

    #[test]
    fn crlf_line_endings_are_tolerated() {
        let crlf: &[u8] = b"root:0:0:/root:/bin/fsh\r\nflash:1000:1000:/home/flash:/bin/fsh\r\n";
        let flash = lookup_by_name(crlf, b"flash").unwrap();
        assert_eq!(flash.uid, 1000);
        assert_eq!(flash.shell, b"/bin/fsh");
    }
}
