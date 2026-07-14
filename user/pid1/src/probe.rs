//! The parts of the harness a host can execute: the paths it hands the kernel, the
//! kernel-emitted tokens it searches the log ring for, and the byte scans it does by
//! hand.
//!
//! Split out from the scenarios themselves so they can be asserted without a board. The
//! scenarios are syscall-driving by nature and have no host oracle at all -- QEMU and the
//! Pi are their only witnesses -- which is exactly why everything that *can* be proven on
//! the host is kept here rather than inlined into them.

// ---- paths ------------------------------------------------------------------
//
// NUL-terminated: a path-taking syscall gets a pointer and nothing else, so the
// terminator is the only length the kernel has.

pub const INIT_PATH: &[u8] = b"/sbin/init\0";
pub const HELLO_ELF_PATH: &[u8] = b"/test/hello.elf\0";
pub const ARGV_ECHO_PATH: &[u8] = b"/test/argv_echo.elf\0";
pub const STACKBOMB_ELF_PATH: &[u8] = b"/test/stackbomb.elf\0";
pub const FLIBC_DEMO_ELF_PATH: &[u8] = b"/test/flibc_demo.elf\0";
pub const LOGIN_BIN_PATH: &[u8] = b"/bin/login\0";
pub const SHADOW_PATH: &[u8] = b"/etc/shadow\0";
pub const ETC_PASSWD_PATH: &[u8] = b"/etc/passwd\0";
pub const BIN_DIR: &[u8] = b"/bin\0";
pub const MNT_MISSING_PATH: &[u8] = b"/mnt/this-does-not-exist\0";
pub const MNT_BARE_PATH: &[u8] = b"/mnt\0";
pub const MNT_SHADOW_PATH: &[u8] = b"/mnt/shadow\0";
// 8.3-safe basenames (at most 8 characters): a 9-character base is rejected by the FAT32
// name encoder, and every open of it would come back -1.
pub const ROUNDTRIP_DAT_PATH: &[u8] = b"/mnt/roundtr.dat\0";
pub const ROUNDTRIP_MAG_PATH: &[u8] = b"/mnt/roundtr.mag\0";
pub const CRUD_PATH_A: &[u8] = b"/mnt/crud.fl\0";
pub const CRUD_PATH_B: &[u8] = b"/mnt/crud2.fl\0";
pub const EMPTY_PATH: &[u8] = b"/mnt/empty.txt\0";

// ---- kernel-emitted tokens --------------------------------------------------
//
// Copies of the kernel's own wording, not the wording itself: this file is compiled into
// the PID 1 image, which cannot link the kernel-side modules that print these lines.
// Rewording either announce means updating the token here and the greps in
// `scripts/run_qemu_test.sh` in the same commit.

/// Emitted by the free-page dump straight through the kernel's own output path, so it is
/// teed into the log ring on every target regardless of console state.
pub const KLOG_MARKER: &[u8] = b"free_pages";
/// The entropy source announces itself during bring-up. The positive token matches any
/// announce; the negative one is printed only by a failed self-test and must be absent. The
/// two together assert that the announce ran *and* that it was healthy.
pub const HWRNG_MARKER: &[u8] = b"HWRNG";
pub const HWRNG_FAIL_MARKER: &[u8] = b"HWRNG: self-test failed";

/// What the empty-file scenario writes into a freshly-seeded zero-byte file.
pub const EMPTY_MARK: &[u8] = b"EMPTYOK\n";

// ---- byte scans -------------------------------------------------------------

/// True when a directory entry's NUL-terminated name equals `want` exactly -- the same
/// bytes, terminated right after.
pub fn name_eql(name: &[u8; 32], want: &[u8]) -> bool {
    if want.len() >= name.len() {
        return false; // no room left for the terminator
    }
    let mut i = 0;
    while i < want.len() {
        if name[i] != want[i] {
            return false;
        }
        i += 1;
    }
    name[want.len()] == 0
}

/// True when `needle` occurs anywhere in `hay`. Quadratic, which is fine for a snapshot of
/// a few kilobytes and keeps the harness free of a search library it cannot link.
pub fn find_sub(hay: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || needle.len() > hay.len() {
        return needle.is_empty();
    }
    let mut i = 0;
    while i + needle.len() <= hay.len() {
        let mut j = 0;
        while j < needle.len() && hay[i + j] == needle[j] {
            j += 1;
        }
        if j == needle.len() {
            return true;
        }
        i += 1;
    }
    false
}

/// The byte the persistence payload carries at offset `i`. Written on one boot and
/// recomputed on the next to compare against -- a formula rather than a second buffer, so
/// the verify leg costs no extra stack.
pub fn pattern_byte(i: usize) -> u8 {
    0xA0u8.wrapping_add((i & 0x1F) as u8)
}

/// The decimal rendering of a tally value: the digits, and how many of them. A value that
/// does not fit renders as `?` rather than as a wrong number.
pub fn digits(n: u32) -> ([u8; 2], usize) {
    if n > 99 {
        return ([b'?', 0], 1);
    }
    if n >= 10 {
        return ([b'0' + (n / 10) as u8, b'0' + (n % 10) as u8], 2);
    }
    ([b'0' + n as u8, 0], 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_eql_matches_only_a_whole_terminated_name() {
        let mut name = [0u8; 32];
        name[..3].copy_from_slice(b"fsh");
        assert!(name_eql(&name, b"fsh"));
        // A prefix is not a match, or the directory walk would find `ls` inside `lsblk`.
        assert!(!name_eql(&name, b"fs"));
        assert!(!name_eql(&name, b"fshx"));
        // A name filling the whole buffer has no room for a terminator, so it can never
        // match: the alternative is reading past the entry.
        assert!(!name_eql(&[b'a'; 32], &[b'a'; 32]));
    }

    #[test]
    fn find_sub_locates_a_marker_anywhere_in_the_snapshot() {
        assert!(find_sub(b"boot: free_pages: 0xbbff2", KLOG_MARKER));
        assert!(find_sub(b"abc", b"a"));
        assert!(find_sub(b"abc", b"c"));
        assert!(find_sub(b"abc", b"abc"));
        assert!(find_sub(b"abc", b""));
        assert!(!find_sub(b"ab", b"abc"));
    }

    #[test]
    fn a_healthy_announce_and_a_failed_one_are_distinguishable() {
        // This pair of tokens *is* the rng scenario's assertion: the positive one proves
        // the announce ran, the negative one proves it was not the failure line.
        let healthy: &[u8] = b"HWRNG: rndr ok";
        let failed: &[u8] = b"HWRNG: self-test failed";
        assert!(find_sub(healthy, HWRNG_MARKER));
        assert!(!find_sub(healthy, HWRNG_FAIL_MARKER));
        assert!(find_sub(failed, HWRNG_MARKER));
        assert!(find_sub(failed, HWRNG_FAIL_MARKER));
    }

    #[test]
    fn every_path_the_harness_hands_the_kernel_is_nul_terminated() {
        // Without the terminator the kernel reads whatever follows in rodata until it
        // happens across a zero.
        for path in [
            INIT_PATH,
            HELLO_ELF_PATH,
            ARGV_ECHO_PATH,
            STACKBOMB_ELF_PATH,
            FLIBC_DEMO_ELF_PATH,
            LOGIN_BIN_PATH,
            SHADOW_PATH,
            ETC_PASSWD_PATH,
            BIN_DIR,
            MNT_MISSING_PATH,
            MNT_BARE_PATH,
            MNT_SHADOW_PATH,
            ROUNDTRIP_DAT_PATH,
            ROUNDTRIP_MAG_PATH,
            CRUD_PATH_A,
            CRUD_PATH_B,
            EMPTY_PATH,
        ] {
            assert_eq!(*path.last().unwrap(), 0, "unterminated path");
        }
    }

    #[test]
    fn the_fat32_basenames_stay_inside_the_8_3_encoder() {
        // A basename over 8 characters is rejected outright by the name encoder, which
        // turns every open of that path into a -1 and the scenario into a false skip.
        for path in [
            ROUNDTRIP_DAT_PATH,
            ROUNDTRIP_MAG_PATH,
            CRUD_PATH_A,
            CRUD_PATH_B,
            EMPTY_PATH,
        ] {
            let text = &path[..path.len() - 1];
            let base = text.rsplit(|&b| b == b'/').next().unwrap();
            let stem = base.split(|&b| b == b'.').next().unwrap();
            assert!(stem.len() <= 8, "8.3 basename too long");
        }
    }

    #[test]
    fn the_roundtrip_pattern_repeats_every_32_bytes() {
        assert_eq!(pattern_byte(0), 0xA0);
        assert_eq!(pattern_byte(31), 0xBF);
        assert_eq!(pattern_byte(32), 0xA0);
        assert_eq!(pattern_byte(4095), 0xBF);
    }

    #[test]
    fn the_tally_renders_one_and_two_digit_values() {
        assert_eq!(digits(0), ([b'0', 0], 1));
        assert_eq!(digits(9), ([b'9', 0], 1));
        assert_eq!(digits(30), (*b"30", 2));
        // The suite would have to triple in size to reach this, and a wrong number is
        // worse than an obviously broken one.
        assert_eq!(digits(100), ([b'?', 0], 1));
    }
}
