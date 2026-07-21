//! Allocation-free `/etc/shadow` parsing and in-place rewriting.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Entry<'a> {
    pub user: &'a [u8],
    pub iterations: u32,
    pub salt_hex: &'a [u8],
    pub hash_hex: &'a [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LineSpan {
    pub start: usize,
    pub end: usize,
}

pub fn parse_line(line: &[u8]) -> Option<Entry<'_>> {
    let c1 = index_of(line, b':')?;
    let user = &line[..c1];
    let rest1 = &line[c1 + 1..];
    let c2 = index_of(rest1, b':')?;
    let iterations_bytes = &rest1[..c2];
    let rest2 = &rest1[c2 + 1..];
    let c3 = index_of(rest2, b':')?;
    let salt_hex = &rest2[..c3];
    let hash_hex = &rest2[c3 + 1..];

    if hash_hex.contains(&b':')
        || user.is_empty()
        || iterations_bytes.is_empty()
        || salt_hex.is_empty()
        || hash_hex.is_empty()
    {
        return None;
    }
    let iterations = parse_decimal_u32(iterations_bytes)?;
    if iterations == 0 {
        return None;
    }
    Some(Entry {
        user,
        iterations,
        salt_hex,
        hash_hex,
    })
}

pub fn hex_decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    if !input.len().is_multiple_of(2) {
        return None;
    }
    let count = input.len() / 2;
    if out.len() < count {
        return None;
    }
    for i in 0..count {
        let hi = hex_nibble(input[2 * i])?;
        let lo = hex_nibble(input[2 * i + 1])?;
        out[i] = (hi << 4) | lo;
    }
    Some(count)
}

pub fn hex_encode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let count = input.len().checked_mul(2)?;
    if out.len() < count {
        return None;
    }
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    for (i, byte) in input.iter().copied().enumerate() {
        out[2 * i] = DIGITS[(byte >> 4) as usize];
        out[2 * i + 1] = DIGITS[(byte & 0x0f) as usize];
    }
    Some(count)
}

pub fn find_user_line(content: &[u8], user: &[u8]) -> Option<LineSpan> {
    let mut line_start = 0;
    let mut i = 0;
    while i <= content.len() {
        if i == content.len() || content[i] == b'\n' {
            let line = &content[line_start..i];
            let span_start = line_start;
            line_start = i + 1;
            if !line.is_empty() {
                if let Some(entry) = parse_line(line) {
                    if entry.user == user {
                        return Some(LineSpan {
                            start: span_start,
                            end: i,
                        });
                    }
                }
            }
        }
        i += 1;
    }
    None
}

pub fn rewrite_line_in_place(
    content: &mut [u8],
    user: &[u8],
    new_salt_hex: &[u8],
    new_hash_hex: &[u8],
) -> bool {
    let span = match find_user_line(content, user) {
        Some(span) => span,
        None => return false,
    };
    let iterations = match parse_line(&content[span.start..span.end]) {
        Some(entry) => entry.iterations,
        None => return false,
    };
    let new_len = match user
        .len()
        .checked_add(1)
        .and_then(|n| n.checked_add(decimal_len(iterations)))
        .and_then(|n| n.checked_add(1))
        .and_then(|n| n.checked_add(new_salt_hex.len()))
        .and_then(|n| n.checked_add(1))
        .and_then(|n| n.checked_add(new_hash_hex.len()))
    {
        Some(len) => len,
        None => return false,
    };
    if new_len != span.end - span.start {
        return false;
    }

    let mut write = span.start;
    content[write..write + user.len()].copy_from_slice(user);
    write += user.len();
    content[write] = b':';
    write += 1;
    write += write_decimal(&mut content[write..span.end], iterations);
    content[write] = b':';
    write += 1;
    content[write..write + new_salt_hex.len()].copy_from_slice(new_salt_hex);
    write += new_salt_hex.len();
    content[write] = b':';
    write += 1;
    content[write..write + new_hash_hex.len()].copy_from_slice(new_hash_hex);
    write += new_hash_hex.len();
    write == span.end
}

fn decimal_len(value: u32) -> usize {
    let mut count = 1;
    let mut rest = value / 10;
    while rest != 0 {
        count += 1;
        rest /= 10;
    }
    count
}

fn write_decimal(out: &mut [u8], value: u32) -> usize {
    let count = decimal_len(value);
    let mut rest = value;
    let mut i = count;
    while i > 0 {
        i -= 1;
        out[i] = b'0' + (rest % 10) as u8;
        rest /= 10;
    }
    count
}

fn index_of(bytes: &[u8], needle: u8) -> Option<usize> {
    bytes.iter().position(|byte| *byte == needle)
}

fn parse_decimal_u32(bytes: &[u8]) -> Option<u32> {
    let mut value = 0u64;
    for byte in bytes.iter().copied() {
        if !byte.is_ascii_digit() {
            return None;
        }
        value = value.checked_mul(10)?.checked_add(u64::from(byte - b'0'))?;
        if value > u64::from(u32::MAX) {
            return None;
        }
    }
    Some(value as u32)
}

fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{find_user_line, hex_decode, hex_encode, parse_line, rewrite_line_in_place};

    const REWRITE_FIXTURE: &[u8] = concat!(
        "root:4096:",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
        "flash:4096:",
        "cccccccccccccccccccccccccccccccc:",
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\n"
    )
    .as_bytes();

    #[test]
    fn parse_line_accepts_a_well_formed_line() {
        let entry = parse_line(b"flash:4096:0011aabb:deadbeef").unwrap();
        assert_eq!(entry.user, b"flash");
        assert_eq!(entry.iterations, 4096);
        assert_eq!(entry.salt_hex, b"0011aabb");
        assert_eq!(entry.hash_hex, b"deadbeef");
    }
    #[test]
    fn parse_line_rejects_missing_fields() {
        assert!(parse_line(b"flash:4096:0011aabb").is_none());
        assert!(parse_line(b"flash:4096").is_none());
        assert!(parse_line(b"flash").is_none());
        assert!(parse_line(b"").is_none());
    }
    #[test]
    fn parse_line_rejects_a_fifth_field() {
        assert!(parse_line(b"a:1:bb:cc:extra").is_none());
    }
    #[test]
    fn parse_line_rejects_empty_user_non_decimal_and_zero_iterations() {
        assert!(parse_line(b":4096:bb:cc").is_none());
        assert!(parse_line(b"flash:40x6:bb:cc").is_none());
        assert!(parse_line(b"flash:0:bb:cc").is_none());
    }
    #[test]
    fn parse_line_rejects_iteration_overflow_past_u32() {
        assert!(parse_line(b"flash:99999999999:bb:cc").is_none());
    }
    #[test]
    fn hex_decode_round_trips_bytes() {
        let mut out = [0u8; 4];
        let count = hex_decode(b"0011aabb", &mut out).unwrap();
        assert_eq!(count, 4);
        assert_eq!(&out[..count], &[0x00, 0x11, 0xaa, 0xbb]);
    }
    #[test]
    fn hex_decode_accepts_uppercase() {
        let mut out = [0u8; 2];
        let count = hex_decode(b"DEAD", &mut out).unwrap();
        assert_eq!(&out[..count], &[0xde, 0xad]);
    }
    #[test]
    fn hex_decode_rejects_odd_length_bad_digit_and_small_output() {
        let mut out = [0u8; 4];
        assert!(hex_decode(b"abc", &mut out).is_none());
        assert!(hex_decode(b"zz", &mut out).is_none());
        assert!(hex_decode(b"aabb", &mut out[..1]).is_none());
    }
    #[test]
    fn hex_encode_lowercase_round_trips_with_decode() {
        let bytes = [0x00, 0x11, 0xaa, 0xbb, 0xde, 0xad];
        let mut hex = [0u8; 12];
        let count = hex_encode(&bytes, &mut hex).unwrap();
        assert_eq!(&hex[..count], b"0011aabbdead");
        let mut back = [0u8; 6];
        let decoded = hex_decode(&hex[..count], &mut back).unwrap();
        assert_eq!(&back[..decoded], &bytes);
    }
    #[test]
    fn hex_encode_rejects_an_undersized_output_buffer() {
        let mut small = [0u8; 3];
        assert!(hex_encode(&[1, 2], &mut small).is_none());
    }
    #[test]
    fn find_user_line_locates_first_last_and_absent_users() {
        let root = find_user_line(REWRITE_FIXTURE, b"root").unwrap();
        assert_eq!(root.start, 0);
        assert_eq!(
            parse_line(&REWRITE_FIXTURE[root.start..root.end])
                .unwrap()
                .user,
            b"root"
        );
        let flash = find_user_line(REWRITE_FIXTURE, b"flash").unwrap();
        assert_eq!(
            parse_line(&REWRITE_FIXTURE[flash.start..flash.end])
                .unwrap()
                .user,
            b"flash"
        );
        assert_eq!(REWRITE_FIXTURE[flash.end], b'\n');
        assert!(find_user_line(REWRITE_FIXTURE, b"anton").is_none());
        assert!(find_user_line(REWRITE_FIXTURE, b"fla").is_none());
    }
    #[test]
    fn find_user_line_works_without_a_trailing_newline() {
        let fixture = b"root:4096:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        assert_eq!(find_user_line(fixture, b"root").unwrap().end, fixture.len());
    }
    #[test]
    fn same_length_rewrite_keeps_neighbours_and_size_intact() {
        let mut content = REWRITE_FIXTURE.to_vec();
        let root = find_user_line(&content, b"root").unwrap();
        let root_before = content[root.start..root.end].to_vec();
        let salt = b"0123456789abcdef0123456789abcdef";
        let hash = [b'f'; 64];
        assert!(rewrite_line_in_place(&mut content, b"flash", salt, &hash));
        let flash = find_user_line(&content, b"flash").unwrap();
        let entry = parse_line(&content[flash.start..flash.end]).unwrap();
        assert_eq!(entry.iterations, 4096);
        assert_eq!(entry.salt_hex, salt);
        assert_eq!(entry.hash_hex, &hash);
        assert_eq!(&content[root.start..root.end], root_before);
        assert_eq!(content.len(), REWRITE_FIXTURE.len());
    }
    #[test]
    fn rewrite_round_trips_through_fresh_values_twice() {
        let mut content = REWRITE_FIXTURE.to_vec();
        assert!(rewrite_line_in_place(
            &mut content,
            b"flash",
            &[b'1'; 32],
            &[b'2'; 64]
        ));
        assert!(rewrite_line_in_place(
            &mut content,
            b"flash",
            &[b'c'; 32],
            &[b'd'; 64]
        ));
        assert_eq!(content, REWRITE_FIXTURE);
    }
    #[test]
    fn rewrite_refuses_absent_user_and_diverging_lengths() {
        let mut content = REWRITE_FIXTURE.to_vec();
        assert!(!rewrite_line_in_place(
            &mut content,
            b"anton",
            &[b'a'; 32],
            &[b'b'; 64]
        ));
        assert!(!rewrite_line_in_place(
            &mut content,
            b"flash",
            &[b'a'; 16],
            &[b'b'; 64]
        ));
        assert!(!rewrite_line_in_place(
            &mut content,
            b"flash",
            &[b'a'; 32],
            &[b'b'; 66]
        ));
        assert_eq!(content, REWRITE_FIXTURE);
    }
}
