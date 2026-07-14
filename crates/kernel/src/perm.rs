//! Unix discretionary-access checks.

/// The operation whose permission bit is being checked.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Access {
    Read = 0,
    Write = 1,
    Exec = 2,
}

/// Decide whether effective IDs may perform `want` on a file.
///
/// Root bypasses the mode bits. Otherwise the first matching owner, group, or
/// other triad is authoritative, and file-type bits above `0o777` are ignored.
pub fn check_access(
    mode: u32,
    file_uid: u32,
    file_gid: u32,
    euid: u32,
    egid: u32,
    want: Access,
) -> bool {
    if euid == 0 {
        return true;
    }

    let bits = mode & 0o777;
    let shift = if euid == file_uid {
        6
    } else if egid == file_gid {
        3
    } else {
        0
    };
    let bit = match want {
        Access::Read => 0o4,
        Access::Write => 0o2,
        Access::Exec => 0o1,
    };
    ((bits >> shift) & bit) != 0
}

#[cfg(test)]
mod tests {
    use super::{check_access, Access};

    #[test]
    fn root_bypasses_every_want_regardless_of_mode() {
        assert!(check_access(0, 0, 0, 0, 0, Access::Read));
        assert!(check_access(0, 0, 0, 0, 0, Access::Write));
        assert!(check_access(0, 0, 0, 0, 0, Access::Exec));
        assert!(check_access(0, 1000, 1000, 0, 0, Access::Read));
        assert!(check_access(0, 1000, 1000, 0, 1000, Access::Write));
    }

    #[test]
    fn owner_read_honours_the_owner_read_bit() {
        assert!(check_access(0o600, 1000, 1000, 1000, 1000, Access::Read));
        assert!(check_access(0o600, 1000, 1000, 1000, 1000, Access::Write));
        assert!(!check_access(0o600, 1000, 1000, 1000, 1000, Access::Exec));
    }

    #[test]
    fn owner_triad_wins_even_when_group_would_allow() {
        assert!(!check_access(0o060, 1000, 1000, 1000, 1000, Access::Read));
        assert!(!check_access(0o060, 1000, 1000, 1000, 1000, Access::Write));
    }

    #[test]
    fn group_triad_when_egid_matches_and_euid_does_not() {
        assert!(check_access(0o640, 0, 1000, 1000, 1000, Access::Read));
        assert!(!check_access(0o640, 0, 1000, 1000, 1000, Access::Write));
        assert!(!check_access(0o640, 0, 1000, 1000, 1000, Access::Exec));
    }

    #[test]
    fn other_triad_when_neither_id_matches() {
        assert!(check_access(0o644, 0, 0, 1000, 1000, Access::Read));
        assert!(!check_access(0o644, 0, 0, 1000, 1000, Access::Write));
        assert!(!check_access(0o644, 0, 0, 1000, 1000, Access::Exec));
    }

    #[test]
    fn exec_bit_gates_exec_independently_of_read() {
        assert!(!check_access(0o644, 0, 0, 1000, 1000, Access::Exec));
        assert!(check_access(0o755, 0, 0, 1000, 1000, Access::Exec));
        assert!(!check_access(0o755, 0, 0, 1000, 1000, Access::Write));
    }

    #[test]
    fn shadow_0600_denies_a_non_owner_non_root_reader() {
        assert!(!check_access(0o600, 0, 0, 1000, 1000, Access::Read));
        assert!(!check_access(0o600, 0, 0, 1000, 1000, Access::Write));
        assert!(check_access(0o600, 0, 0, 0, 0, Access::Read));
    }

    #[test]
    fn passwd_0644_allows_any_reader_but_denies_non_owner_write() {
        assert!(check_access(0o644, 0, 0, 1000, 1000, Access::Read));
        assert!(!check_access(0o644, 0, 0, 1000, 1000, Access::Write));
        assert!(check_access(0o644, 1000, 1000, 1000, 1000, Access::Write));
    }

    #[test]
    fn file_type_bits_above_0777_are_ignored() {
        assert!(check_access(0o100600, 1000, 1000, 1000, 1000, Access::Read));
        assert!(!check_access(0o100600, 0, 0, 1000, 1000, Access::Read));
        assert!(check_access(0o100755, 0, 0, 1000, 1000, Access::Exec));
        assert!(!check_access(0o100644, 0, 0, 1000, 1000, Access::Exec));
    }
}
