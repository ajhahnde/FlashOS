// Shared syscall ID constants + ABI types — single source of truth for
// the user/kernel ABI boundary.
//
// These IDs index sys_call_table in src/sys.zig (kernel side) and are
// loaded into x8 by the syscall wrappers in user_space/kernel_tests.zig
// (user side). Keeping the numbers here lets both sides import the same
// names so a renumbering becomes a single-file change with compiler
// enforcement, instead of paired edits coordinated by comments.
//
// NR_SYSCALLS in src/asm_defs_common.inc must stay in lockstep with the
// highest ID +1 (it caps the dispatch range via `b.hs` in entry.S).
//
// Pure compile-time constants: no code is emitted, no `linksection`
// attribute is needed, the user_init.o blob is unaffected in size and
// layout.

// Slot 0 is a retired slot — see the retired-slots note below.
pub const SYS_FORK: u64 = 1;
pub const SYS_EXIT: u64 = 2;
pub const SYS_WAIT: u64 = 3;
// Public introspection ABI (stable).
pub const SYS_DUMP_FREE: u64 = 4;
// Slot 5 is a retired slot — see the retired-slots note below.
pub const SYS_KILL: u64 = 6;
// File-system ABI. SYS_OPEN_FILE and SYS_SEEK are symbolic
// constants so the dispatch-table writes in src/sys.zig become
// compiler-enforced (a renumber here propagates automatically). The
// former per-kind read/write/close file shims (slots 8, 9, 11) are
// retired — see the retired-slots note below; file I/O now goes
// through the unified (fd, buf, len) ABI at slots 32..35.
pub const SYS_OPEN_FILE: u64 = 7;
pub const SYS_SEEK: u64 = 10;
pub const SYS_BRK: u64 = 12;
pub const SYS_SBRK: u64 = 13;
// Slots 14..17 are reserved mm stubs (no-op handlers until v1.x).
pub const SYS_MMAP: u64 = 14;
pub const SYS_MUNMAP: u64 = 15;
pub const SYS_MLOCK: u64 = 16;
pub const SYS_MUNLOCK: u64 = 17;
// Slot 18 = SYS_PIPE; the other end-of-pipe ABI sits past the console
// reservation (slots 23..26) so the console can fill its slots
// without touching the pipe IDs. NR_SYSCALLS in src/asm_defs_common.inc
// must stay one past the highest slot.
pub const SYS_PIPE: u64 = 18;
// Slots 19..22 are reserved IPC stubs (no-op handlers until v1.x).
pub const SYS_SOCKET: u64 = 19;
pub const SYS_MSGGET: u64 = 20;
pub const SYS_SEMGET: u64 = 21;
pub const SYS_SHMGET: u64 = 22;
// Console ABI: slots 23..26. The open/read slots (23, 24) are
// retired — see the retired-slots note below; console I/O now goes
// through the unified (fd, buf, len) ABI at slots 32..35, and fd 0/1/2
// are pre-installed at PID-1 bring-up. The two remaining slots are
// inert stubs by contract:
//   * SYS_SET_CONSOLE_MODE  — toggles the kernel echo flag;
//                             see CONSOLE_MODE_ECHO below. Full termios later.
//   * SYS_CLOSE_CONSOLE     — inert (fd-table teardown not yet wired)
pub const SYS_SET_CONSOLE_MODE: u64 = 25;
pub const SYS_CLOSE_CONSOLE: u64 = 26;
// Console mode bits for SYS_SET_CONSOLE_MODE. ECHO on => the
// kernel echoes drained printable console bytes (cooked-style); off
// (default) keeps echo in userland readline. /bin/login clears it around
// the password prompt to suppress echo. One bit for now; a full termios
// flag set is future work.
pub const CONSOLE_MODE_ECHO: u64 = 1;
// Debug-only — not part of the stable ABI.
// Pushes one byte into the kernel RX ring as if it had arrived on
// the UART. Powers deterministic console-echo coverage on QEMU
// where there is no external input driver. Remove once a real
// host-input driver lands.
pub const SYS_CONSOLE_INJECT: u64 = 30;
// Path-resolved ELF loader. Streams PT_LOAD segments from an
// open VFS file and lays an argv block on the new user stack; the sole
// exec entry point since the legacy blob loader (slot 5) was retired.
// Entry contract is `x0 = argc`, `x1 = argv` (AAPCS64).
pub const SYS_EXECVE: u64 = 31;

// Unified fd-table ABI. Slots 32..35 dispatch by the fd's
// kind tag in the unified `fds` table (console / pipe / file) and are
// the sole entry point for all console / pipe / file I/O. The legacy
// per-kind shims they replaced were retired — see the retired-slots
// note below.
pub const SYS_READ: u64 = 32;
pub const SYS_WRITE: u64 = 33;
pub const SYS_CLOSE: u64 = 34;
pub const SYS_DUP2: u64 = 35;

// Retired slots — legacy per-kind shims removed after the unified fd ABI
// (slots 31-35) replaced them: 0 (write_str), 5 (exec), 8 (readFile),
// 9 (writeFile), 11 (closeFile), 23 (openConsole), 24 (readConsole),
// 27 (pipe_read), 28 (pipe_write), 29 (pipe_close). The numbers stay
// reserved: the dispatch table routes them to a -1 stub, and they must
// never be reassigned to new syscalls.

// Working-directory ABI. Slot 36 — sys_chdir(path)
// normalises a path against the task's `cwd` (TaskStruct.cwd) and stores
// the result. Relative paths at the open/execve boundary are joined
// against `cwd` before vfs.resolve runs (still absolute-only). No real
// directory existence check — best-effort, deferred to sys_readdir.
pub const SYS_CHDIR: u64 = 36;

// Directory-enumeration ABI. Slot 37 —
// sys_readdir(path, index, *Dirent) is a stateless index walk: it fills
// the `index`-th entry of the directory at `path` and returns 0, or -1
// at end-of-directory / bad path / wild pointer. No fd cursor, no
// opendir handle — the POSIX handle shape is a future portable-
// userland revisit. initramfs synthesises directories from path
// prefixes; FAT32 renders 8.3 root entries (Pi-only).
pub const SYS_READDIR: u64 = 37;

// Kernel-log ABI. Slot 38 — sys_klog_read(buf, len) snapshots
// the most-recent min(len, retained) bytes of the kernel byte-ring
// (src/klog_ring.zig) into the caller's UVA, oldest-first, and returns
// the count (0 when the ring is empty, -1 on a wild buffer). Stateless
// and consume-free: every call sees the live log; /bin/dmesg sizes its
// buffer to KLOG_SIZE to capture the whole retained log in one call.
pub const SYS_KLOG_READ: u64 = 38;

// Process-credential ABI. Slots 39..44 — the identity layer for
// the login/auth flow. get* report the calling task's real / effective
// uid / gid (the four ids now carried in TaskStruct); set* mutate them
// under a root-gated policy: euid 0 sets any id (real + effective), a
// dropped process may only reset to an id it already holds, else -1
// (EPERM-lite). i64 return so the failure sentinel is representable.
// Inherited across fork, preserved across execve, so the privilege drop
// /bin/login performs survives the shell exec.
pub const SYS_GETUID: u64 = 39;
pub const SYS_GETEUID: u64 = 40;
pub const SYS_GETGID: u64 = 41;
pub const SYS_GETEGID: u64 = 42;
pub const SYS_SETUID: u64 = 43;
pub const SYS_SETGID: u64 = 44;

// Authentication ABI. Slot 45 — sys_authenticate(user_ptr,
// user_len, pass_ptr, pass_len) reads the active shadow database
// in-kernel (/mnt/shadow first, the initramfs /etc/shadow seed as
// fallback), runs PBKDF2-HMAC-SHA256 over the password with the stored
// salt + iteration count, and constant-time-compares to the stored
// verifier. Returns 0 on match, -1 otherwise. The KDF lives in the
// kernel; userland (/bin/login) sees only pass/fail, never a salt or
// hash.
pub const SYS_AUTHENTICATE: u64 = 45;

// Password-change ABI. Slot 46 — sys_passwd(user_ptr, user_len,
// old_ptr, old_len, new_ptr, new_len) rewrites `user`'s record in the
// writable FAT32 shadow (/mnt/shadow) with a fresh kernel-minted salt and
// a PBKDF2 re-hash of the new password. Authorization: root (euid 0) may
// reset any record without the old password; everyone else only their own
// record (uid -> name via /etc/passwd) and only with the correct old
// password (-EACCES otherwise). Returns 0 on success, -1 when there is no
// writable shadow (QEMU virt / fresh card), the user is absent, or the
// rewrite would change the record length. Six register args (x0..x5).
pub const SYS_PASSWD: u64 = 46;

// Highest slot + 1; equals the `#define NR_SYSCALLS` literal in
// src/asm_defs_common.inc. Adding a new SYS_* constant past
// SYS_PASSWD bumps this automatically; the comptime guard in
// src/sys.zig catches divergence from the asm-side literal at build
// time.
pub const NR_SYSCALLS: usize = SYS_PASSWD + 1;

// Kernel-log ring capacity in bytes. Shared here because both
// the kernel ring (src/klog_ring.zig sizes `KlogRing` to it) and userland
// `dmesg` (sizes its read buffer to it) must agree — an ABI-visible
// constant, like Dirent. 16 KiB holds a full interactive boot log
// (firmware marker → `fsh init OK`); a longer in-harness log wraps,
// keeping the most recent 16 KiB.
pub const KLOG_SIZE: u64 = 16 * 1024;

// Errno surface. Historically every syscall failure returned a
// bare -1; the VFS permission layer needs a distinguishable code so a
// denied open / write / execve reads as "permission denied" rather than
// a generic miss. Syscalls return the NEGATED value (-EACCES == -13).
// Only EACCES exists so far — it is the lone failure any syscall reports
// besides -1. The numeric value matches the conventional Unix errno so a
// future libc errno table needs no remapping.
pub const EACCES: i32 = 13;

// ---- Shared ABI types ----
//
// Types (not IDs) that cross the user/kernel boundary by pointer, so
// both sides must import one definition. The first is the directory
// entry filled by sys_readdir (slot 37).

// d_type values for Dirent. A flat two-value set: the cpio and FAT32
// backends only ever surface regular files and directories — no
// symlinks, devices, or FIFOs to enumerate.
pub const DT_REG: u8 = 0; // regular file
pub const DT_DIR: u8 = 1; // directory

// One directory entry. extern struct because it crosses the
// sys_readdir vtable boundary by pointer and is copy_to_user'd into the
// caller's UVA — the layout must be fixed and identical both sides.
// `name` is 32 bytes because initramfs basenames are full cpio names
// (e.g. `flibc_demo.elf`), not 8.3; FAT32 fills <= 12 rendered 8.3
// chars. A `size` field is deferred to the `ls -l` fsh-v2 work. _pad
// keeps the struct 8-byte aligned at 40 bytes.
pub const Dirent = extern struct {
    name: [32]u8 = .{0} ** 32, // NUL-terminated basename
    d_type: u8 = DT_REG,
    _pad: [7]u8 = .{0} ** 7,
};
