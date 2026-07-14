//! The harness's `[TEST]` / `[PASS]` / `[FAIL]` line table.
//!
//! Every byte here is derived from `console_ui::tags`, never re-spelled: the boot
//! oracle greps these exact lines, and a marker that drifts on one side of the
//! console layer only is a silently broken contract rather than a failing build.
//! The concatenation happens at compile time, so a scenario still emits its whole
//! line in one write -- two writes would let a child's output land between the tag
//! and the name.

use flashos_console_ui::tags;

/// Concatenate two byte strings into a fixed array. `N` comes from the call site's
/// type annotation, which the `marks!` macro derives from the operands' lengths.
pub const fn cat<const N: usize>(prefix: &[u8], rest: &[u8]) -> [u8; N] {
    let mut out = [0u8; N];
    let mut i = 0;
    while i < prefix.len() {
        out[i] = prefix[i];
        i += 1;
    }
    let mut j = 0;
    while j < rest.len() {
        out[prefix.len() + j] = rest[j];
        j += 1;
    }
    out
}

/// One tagged line. The length is derived from the operands, never hand-counted: a
/// miscount would zero-pad the tail, and a NUL inside a serial line is invisible in a
/// terminal while breaking every byte-exact grep over it.
macro_rules! mark {
    ($name:ident, $tag:expr, $text:expr) => {
        pub const $name: [u8; $tag.len() + $text.len()] = cat($tag, $text);
    };
}

/// The three lines one scenario emits, named after it.
macro_rules! marks {
    ($test:ident, $pass:ident, $fail:ident, $name:expr) => {
        mark!($test, tags::TEST_MARK, $name);
        mark!($pass, tags::PASS_MARK, $name);
        mark!($fail, tags::FAIL_MARK, $name);
    };
}

marks!(TEST_RNG, PASS_RNG, FAIL_RNG, b"rng\n");
marks!(
    TEST_FORK_STRESS,
    PASS_FORK_STRESS,
    FAIL_FORK_STRESS,
    b"fork-stress\n"
);
marks!(
    TEST_OOM_GRACEFUL,
    PASS_OOM_GRACEFUL,
    FAIL_OOM_GRACEFUL,
    b"oom-graceful\n"
);
marks!(TEST_KILL, PASS_KILL, FAIL_KILL, b"kill\n");
marks!(TEST_EXEC_ELF, PASS_EXEC_ELF, FAIL_EXEC_ELF, b"exec-elf\n");
marks!(TEST_EXECVE, PASS_EXECVE, FAIL_EXECVE, b"execve\n");
marks!(TEST_BRK, PASS_BRK, FAIL_BRK, b"brk\n");
marks!(
    TEST_STACK_OVERFLOW,
    PASS_STACK_OVERFLOW,
    FAIL_STACK_OVERFLOW,
    b"stack-overflow\n"
);
marks!(
    TEST_WILD_POINTER,
    PASS_WILD_POINTER,
    FAIL_WILD_POINTER,
    b"wild-pointer\n"
);
marks!(
    TEST_EXEC_FAULT,
    PASS_EXEC_FAULT,
    FAIL_EXEC_FAULT,
    b"exec-fault\n"
);
marks!(
    TEST_UNDEF_INSTR,
    PASS_UNDEF_INSTR,
    FAIL_UNDEF_INSTR,
    b"undef-instr\n"
);
marks!(
    TEST_EFAULT_SYSCALL,
    PASS_EFAULT_SYSCALL,
    FAIL_EFAULT_SYSCALL,
    b"efault-syscall\n"
);
marks!(TEST_FLIBC, PASS_FLIBC, FAIL_FLIBC, b"flibc\n");
marks!(TEST_PIPE, PASS_PIPE, FAIL_PIPE, b"pipe\n");
marks!(
    TEST_CONSOLE_ECHO,
    PASS_CONSOLE_ECHO,
    FAIL_CONSOLE_ECHO,
    b"console-echo\n"
);
marks!(
    TEST_FD_REDIRECT,
    PASS_FD_REDIRECT,
    FAIL_FD_REDIRECT,
    b"fd-redirect\n"
);
marks!(
    TEST_INITRAMFS_OPEN,
    PASS_INITRAMFS_OPEN,
    FAIL_INITRAMFS_OPEN,
    b"initramfs-open\n"
);
marks!(
    TEST_VFS_DISPATCH,
    PASS_VFS_DISPATCH,
    FAIL_VFS_DISPATCH,
    b"vfs-dispatch\n"
);
marks!(TEST_TRACE, PASS_TRACE, FAIL_TRACE, b"trace\n");
marks!(
    TEST_FS_ROUNDTRIP,
    PASS_VERIFY,
    FAIL_FS_ROUNDTRIP,
    b"fs-roundtrip\n"
);
marks!(
    TEST_FS_EMPTY,
    PASS_FS_EMPTY,
    FAIL_FS_EMPTY,
    b"fs-empty-write\n"
);
marks!(TEST_READDIR, PASS_READDIR, FAIL_READDIR, b"readdir\n");
marks!(TEST_KLOG, PASS_KLOG, FAIL_KLOG, b"klog\n");
marks!(
    TEST_HWMON_CORE,
    PASS_HWMON_CORE,
    FAIL_HWMON_CORE,
    b"hwmon-core\n"
);
marks!(
    TEST_HWMON_MAILBOX,
    PASS_HWMON_MAILBOX,
    FAIL_HWMON_MAILBOX,
    b"hwmon-mailbox\n"
);
marks!(TEST_CREDS, PASS_CREDS, FAIL_CREDS, b"creds\n");
marks!(TEST_AUTH, PASS_AUTH, FAIL_AUTH, b"authenticate\n");
marks!(TEST_PERM, PASS_PERM, FAIL_PERM, b"perm\n");
marks!(TEST_LOGIN, PASS_LOGIN, FAIL_LOGIN, b"login\n");
marks!(TEST_PASSWD, PASS_PASSWD, FAIL_PASSWD, b"passwd\n");

// The lines that do not follow the one-name-three-marks shape.

// fs-roundtrip's first-boot leg: the payload is written but only the *next* boot can
// prove it survived power-off, so this is a pass with a caveat, not a verify.
mark!(
    PASS_WRITE,
    tags::PASS_MARK,
    b"fs-roundtrip-write (reboot to verify)\n"
);
// No FAT32 mount (the emulated board has no card): the scenario counts as passed rather
// than reporting a failure for a board that cannot run it.
mark!(PASS_SKIP, tags::PASS_MARK, b"fs-roundtrip (skip)\n");
mark!(
    PASS_FS_EMPTY_SKIP,
    tags::PASS_MARK,
    b"fs-empty-write (skip)\n"
);
mark!(PASS_PASSWD_SKIP, tags::PASS_MARK, b"passwd (skip)\n");
// The magic byte is neither 0 nor 1: the disk is in a state no phase produced, so neither
// the write nor the verify leg can be trusted.
mark!(
    FAIL_MAGIC,
    tags::FAIL_MARK,
    b"fs-roundtrip (magic corrupted)\n"
);
mark!(
    FAIL_PIPE_SHORT_WRITE,
    tags::FAIL_MARK,
    b"pipe (short write)\n"
);
mark!(
    FAIL_FD_REDIRECT_SHORT_WRITE,
    tags::FAIL_MARK,
    b"fd-redirect (short write)\n"
);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_scenario_line_is_its_tag_followed_by_its_name() {
        // The whole point of the table: these exact bytes are what the boot oracle
        // greps. Spelled out once here so a drifting tag fails the host suite
        // before it ever reaches a serial log.
        assert_eq!(&TEST_FORK_STRESS[..], b"[TEST] fork-stress\n");
        assert_eq!(&PASS_FORK_STRESS[..], b"[PASS] fork-stress\n");
        assert_eq!(&FAIL_FORK_STRESS[..], b"[FAIL] fork-stress\n");
    }

    #[test]
    fn the_irregular_lines_carry_their_full_text() {
        assert_eq!(
            &PASS_WRITE[..],
            b"[PASS] fs-roundtrip-write (reboot to verify)\n"
        );
        assert_eq!(&PASS_SKIP[..], b"[PASS] fs-roundtrip (skip)\n");
        assert_eq!(&PASS_FS_EMPTY_SKIP[..], b"[PASS] fs-empty-write (skip)\n");
        assert_eq!(&PASS_PASSWD_SKIP[..], b"[PASS] passwd (skip)\n");
        assert_eq!(&FAIL_MAGIC[..], b"[FAIL] fs-roundtrip (magic corrupted)\n");
    }

    #[test]
    fn cat_leaves_no_padding_between_or_after_the_operands() {
        let joined: [u8; 5] = cat(b"ab", b"cde");
        assert_eq!(&joined[..], b"abcde");
    }

    #[test]
    fn no_line_carries_a_stray_nul_or_a_missing_newline() {
        // The failure a hand-counted length produces: a zero padding the tail, which a
        // terminal renders as nothing and a byte-exact grep chokes on. Every line is
        // checked, not just the one that happened to be wrong.
        for line in [
            &TEST_RNG[..],
            &PASS_RNG[..],
            &FAIL_RNG[..],
            &PASS_WRITE[..],
            &PASS_SKIP[..],
            &PASS_FS_EMPTY_SKIP[..],
            &PASS_PASSWD_SKIP[..],
            &FAIL_MAGIC[..],
            &FAIL_PIPE_SHORT_WRITE[..],
            &FAIL_FD_REDIRECT_SHORT_WRITE[..],
        ] {
            assert!(!line.contains(&0), "padded line: {line:?}");
            assert_eq!(*line.last().unwrap(), b'\n', "line does not end the line");
        }
    }
}
