// Shared syscall ID constants — single source of truth for the
// user/kernel ABI boundary.
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

pub const SYS_WRITE: u64 = 0;
pub const SYS_FORK: u64 = 1;
pub const SYS_EXIT: u64 = 2;
pub const SYS_WAIT: u64 = 3;
pub const SYS_DUMP_FREE: u64 = 4;
pub const SYS_EXEC: u64 = 5;
pub const SYS_KILL: u64 = 6;
// File-system ABI (v0.4.0). Slots 7..11 are symbolic
// constants so the dispatch-table writes in src/sys.zig become
// compiler-enforced (a renumber here propagates automatically).
//
// SYS_WRITE_FILE went live in v0.4.0 (FAT32 writeBack);
// the slot is now a stable ABI — (fd, buf, len) i64, bytes written
// or -1. The handler dispatches through vfs.vfs_write.
pub const SYS_OPEN_FILE: u64 = 7;
pub const SYS_READ_FILE: u64 = 8;
pub const SYS_WRITE_FILE: u64 = 9;
pub const SYS_SEEK: u64 = 10;
pub const SYS_CLOSE_FILE: u64 = 11;
pub const SYS_BRK: u64 = 12;
pub const SYS_SBRK: u64 = 13;
// Slots 14..17 stay reserved mm stubs (mmap/munmap/mlock/munlock).
// Slot 18 = SYS_PIPE; the other end-of-pipe ABI sits past the console
// reservation (slots 23..26) so the console can fill its slots
// without touching the pipe IDs. NR_SYSCALLS in src/asm_defs_common.inc
// must stay one past the highest slot.
pub const SYS_PIPE: u64 = 18;
// Slots 19..22 stay reserved IPC stubs (socket/msgget/semget/shmget).
// Console ABI (v0.3.0): slots 23..26.
//   * SYS_OPEN_CONSOLE      — synthetic fd for stdin/stdout
//   * SYS_READ_CONSOLE      — blocking, short reads, drains rx_ring
//   * SYS_SET_CONSOLE_MODE  — inert (mode flips not yet wired)
//   * SYS_CLOSE_CONSOLE     — inert (fd-table teardown not yet wired)
pub const SYS_OPEN_CONSOLE: u64 = 23;
pub const SYS_READ_CONSOLE: u64 = 24;
pub const SYS_SET_CONSOLE_MODE: u64 = 25;
pub const SYS_CLOSE_CONSOLE: u64 = 26;
pub const SYS_PIPE_READ: u64 = 27;
pub const SYS_PIPE_WRITE: u64 = 28;
pub const SYS_PIPE_CLOSE: u64 = 29;
// FIXME: debug-only — not part of the stable ABI.
// Pushes one byte into the kernel RX ring as if it had arrived on
// the UART. Powers deterministic console-echo coverage on QEMU
// where there is no external input driver. Symmetric to
// sys_dump_free in posture; remove once a real host-input driver
// lands.
pub const SYS_CONSOLE_INJECT: u64 = 30;
