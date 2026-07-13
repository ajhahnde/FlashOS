//! Syscall IDs, the errno surface, and the types that cross the user/kernel
//! boundary by pointer.
//!
//! Ported from `lib/syscall_defs.flash`. The IDs index the kernel dispatch table
//! and are loaded into x8 by the EL0 wrappers; `NR_SYSCALLS` caps the dispatch
//! range via the `b.hs` in `entry.S`, so it must stay one past the highest slot.
//!
//! Retired slots — 0 (write_str), 5 (exec), 8 (readFile), 9 (writeFile),
//! 11 (closeFile), 23 (openConsole), 24 (readConsole), 27..29 (pipe read/write/
//! close) — are the legacy per-kind shims the unified fd ABI replaced. They stay
//! reserved: the dispatch table routes them to a -1 stub and they must never be
//! reassigned.

use core::mem::{align_of, offset_of, size_of};

pub const SYS_FORK: u64 = 1;
pub const SYS_EXIT: u64 = 2;
pub const SYS_WAIT: u64 = 3;
/// Public introspection ABI (stable).
pub const SYS_DUMP_FREE: u64 = 4;
pub const SYS_KILL: u64 = 6;

pub const SYS_OPEN_FILE: u64 = 7;
pub const SYS_SEEK: u64 = 10;
pub const SYS_BRK: u64 = 12;
pub const SYS_SBRK: u64 = 13;

// Slots 14..17 are reserved mm stubs (no-op handlers until v1.x).
pub const SYS_MMAP: u64 = 14;
pub const SYS_MUNMAP: u64 = 15;
pub const SYS_MLOCK: u64 = 16;
pub const SYS_MUNLOCK: u64 = 17;

pub const SYS_PIPE: u64 = 18;

// Slots 19..22 are reserved IPC stubs (no-op handlers until v1.x).
pub const SYS_SOCKET: u64 = 19;
pub const SYS_MSGGET: u64 = 20;
pub const SYS_SEMGET: u64 = 21;
pub const SYS_SHMGET: u64 = 22;

/// Toggles the kernel echo flag; see `CONSOLE_MODE_ECHO`. Full termios later.
pub const SYS_SET_CONSOLE_MODE: u64 = 25;
/// Inert by contract — fd-table teardown is not wired.
pub const SYS_CLOSE_CONSOLE: u64 = 26;

/// Echo on: the kernel echoes drained printable console bytes (cooked-style).
/// Off (the default) leaves echo to userland readline.
pub const CONSOLE_MODE_ECHO: u64 = 1;
/// Echo a single '*' per drained printable byte instead of the byte itself
/// (password masking). If both bits are set, MASK wins.
pub const CONSOLE_MODE_MASK: u64 = 2;

/// Debug-only, not part of the stable ABI: pushes one byte into the kernel RX
/// ring as if it had arrived on the UART, so console-echo coverage is
/// deterministic on QEMU where there is no external input driver.
pub const SYS_CONSOLE_INJECT: u64 = 30;

/// Path-resolved ELF loader; the sole exec entry point. Entry contract is
/// `x0 = argc`, `x1 = argv` (AAPCS64).
pub const SYS_EXECVE: u64 = 31;

// Unified fd-table ABI. Dispatches by the fd's kind tag (console / pipe / file)
// and is the sole entry point for all console, pipe, and file I/O.
pub const SYS_READ: u64 = 32;
pub const SYS_WRITE: u64 = 33;
pub const SYS_CLOSE: u64 = 34;
pub const SYS_DUP2: u64 = 35;

pub const SYS_CHDIR: u64 = 36;
/// Stateless index walk: fills the `index`-th entry of the directory at `path`,
/// or returns -1 at end-of-directory. No fd cursor, no opendir handle.
pub const SYS_READDIR: u64 = 37;
/// Snapshots the most-recent bytes of the kernel byte-ring, oldest-first.
/// Stateless and consume-free: every call sees the live log.
pub const SYS_KLOG_READ: u64 = 38;

// Process-credential ABI — the identity layer for the login/auth flow. set*
// mutate under a root-gated policy: euid 0 sets any id, a dropped process may
// only reset to an id it already holds, else -1.
pub const SYS_GETUID: u64 = 39;
pub const SYS_GETEUID: u64 = 40;
pub const SYS_GETGID: u64 = 41;
pub const SYS_GETEGID: u64 = 42;
pub const SYS_SETUID: u64 = 43;
pub const SYS_SETGID: u64 = 44;

/// PBKDF2-HMAC-SHA256 over the password against the active shadow database.
/// Returns 0 on match, -1 otherwise — userland never sees a salt or a hash.
pub const SYS_AUTHENTICATE: u64 = 45;
/// Rewrites a shadow record with a fresh kernel-minted salt and a re-hash. Root
/// may reset any record; everyone else only their own, and only with the correct
/// old password.
pub const SYS_PASSWD: u64 = 46;
/// Resets the board and does not return. Board-specific (PSCI SYSTEM_RESET on
/// virt, the BCM2711 watchdog on rpi4b) — EL0 cannot issue the SMC or touch the
/// power-manager MMIO.
pub const SYS_REBOOT: u64 = 47;
/// The readback half of `SYS_CHDIR`.
pub const SYS_GETCWD: u64 = 48;

// Hardware-monitoring ABI: four argument-free `() -> u64` reads. Each reports
// 0 = unknown on a board without the firmware (virt), which the tools render as
// `n/a`.
pub const SYS_MEMTOTAL: u64 = 49;
pub const SYS_UPTIME: u64 = 50;
pub const SYS_CPU_TEMP: u64 = 51;
pub const SYS_CPU_FREQ: u64 = 52;

// FAT32 metadata ABI. Files only, /mnt only.
pub const SYS_CREATE: u64 = 53;
pub const SYS_UNLINK: u64 = 54;
pub const SYS_RENAME: u64 = 55;

/// Highest slot + 1. Equals the `NR_SYSCALLS` literal in
/// `arch/aarch64/asm_defs_common.inc`, which caps the dispatch range;
/// `cargo xtask asm-defs --check` proves the two still agree.
pub const NR_SYSCALLS: usize = (SYS_RENAME + 1) as usize;

/// Kernel-log ring capacity in bytes. ABI-visible: the kernel sizes the ring to
/// it and `dmesg` sizes its read buffer to it, so both must agree.
pub const KLOG_SIZE: u64 = 16 * 1024;

/// Syscalls return the NEGATED value (`-EACCES == -13`). The numeric value
/// matches the conventional Unix errno so a future libc errno table needs no
/// remapping. EACCES is the only code besides the bare -1 any syscall reports.
pub const EACCES: i32 = 13;

// d_type values for `Dirent`. A flat two-value set: the cpio and FAT32 backends
// only ever surface regular files and directories.
pub const DT_REG: u8 = 0;
pub const DT_DIR: u8 = 1;

/// One directory entry, filled by `SYS_READDIR` and copied into the caller's
/// UVA, so the layout must be fixed and identical on both sides.
///
/// `name` is 32 bytes because initramfs basenames are full cpio names, not 8.3;
/// FAT32 fills at most 12 rendered 8.3 characters.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Dirent {
    /// NUL-terminated basename.
    pub name: [u8; 32],
    pub d_type: u8,
    pub _pad: [u8; 7],
}

impl Default for Dirent {
    fn default() -> Self {
        Self {
            name: [0; 32],
            d_type: DT_REG,
            _pad: [0; 7],
        }
    }
}

// ---------------------------------------------------------------------------
// Layout assertions — the pre-port build's numbers.
// ---------------------------------------------------------------------------

const _: () = {
    assert!(size_of::<Dirent>() == 40);
    assert!(align_of::<Dirent>() == 1);
    assert!(offset_of!(Dirent, name) == 0);
    assert!(offset_of!(Dirent, d_type) == 32);
    assert!(offset_of!(Dirent, _pad) == 33);

    assert!(NR_SYSCALLS == 56);
};

#[cfg(test)]
mod tests {
    use super::*;

    /// `entry.S` rejects `x8 >= NR_SYSCALLS` with a `b.hs`. Every live slot must
    /// therefore fall below the cap, and the cap must sit exactly one past the
    /// highest — a gap would silently open an out-of-range slot.
    #[test]
    fn every_syscall_id_is_within_the_dispatch_cap() {
        const HIGHEST: u64 = SYS_RENAME;
        for id in [
            SYS_FORK,
            SYS_EXIT,
            SYS_WAIT,
            SYS_DUMP_FREE,
            SYS_KILL,
            SYS_OPEN_FILE,
            SYS_SEEK,
            SYS_BRK,
            SYS_SBRK,
            SYS_MMAP,
            SYS_MUNMAP,
            SYS_MLOCK,
            SYS_MUNLOCK,
            SYS_PIPE,
            SYS_SOCKET,
            SYS_MSGGET,
            SYS_SEMGET,
            SYS_SHMGET,
            SYS_SET_CONSOLE_MODE,
            SYS_CLOSE_CONSOLE,
            SYS_CONSOLE_INJECT,
            SYS_EXECVE,
            SYS_READ,
            SYS_WRITE,
            SYS_CLOSE,
            SYS_DUP2,
            SYS_CHDIR,
            SYS_READDIR,
            SYS_KLOG_READ,
            SYS_GETUID,
            SYS_GETEUID,
            SYS_GETGID,
            SYS_GETEGID,
            SYS_SETUID,
            SYS_SETGID,
            SYS_AUTHENTICATE,
            SYS_PASSWD,
            SYS_REBOOT,
            SYS_GETCWD,
            SYS_MEMTOTAL,
            SYS_UPTIME,
            SYS_CPU_TEMP,
            SYS_CPU_FREQ,
            SYS_CREATE,
            SYS_UNLINK,
            SYS_RENAME,
        ] {
            assert!(id <= HIGHEST, "syscall {id} sits past the dispatch cap");
            assert!((id as usize) < NR_SYSCALLS);
        }
        assert_eq!(NR_SYSCALLS, (HIGHEST + 1) as usize);
    }

    /// A `Dirent` is memcpy'd into a user buffer, so its bytes are the ABI. Prove
    /// the name lands at byte 0 and the type tag at byte 32.
    #[test]
    fn dirent_serializes_to_the_documented_bytes() {
        let mut d = Dirent {
            d_type: DT_DIR,
            ..Default::default()
        };
        d.name[..3].copy_from_slice(b"etc");

        let bytes: [u8; 40] = unsafe { core::mem::transmute(d) };
        assert_eq!(&bytes[..3], b"etc");
        assert_eq!(bytes[3], 0, "basename stays NUL-terminated");
        assert_eq!(bytes[32], DT_DIR);
        assert_eq!(&bytes[33..], &[0u8; 7], "padding is zeroed, not garbage");
    }
}
