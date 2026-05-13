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
// Slots 7..11 are unused file/openConsole stubs in sys_call_table —
// they keep their positional binding without a SYS_* constant until
// implemented. brk/sbrk land at the historical positions reserved by
// the table so the existing slot ↔ id mapping stays stable.
pub const SYS_BRK: u64 = 12;
pub const SYS_SBRK: u64 = 13;
// Slots 14..17 stay reserved mm stubs (mmap/munmap/mlock/munlock).
// Slot 18 = SYS_PIPE; the other end-of-pipe ABI sits past the console
// reservation (slots 23..26) so phase-1.3 can fill the console slots
// without touching the pipe IDs. NR_SYSCALLS in src/asm_defs_common.inc
// must stay one past the highest slot.
pub const SYS_PIPE: u64 = 18;
// Slots 19..22 stay reserved IPC stubs (socket/msgget/semget/shmget).
// Console ABI (v0.3.0 step 1.3): slots 23..26.
//   * SYS_OPEN_CONSOLE      — synthetic fd for stdin/stdout
//   * SYS_READ_CONSOLE      — blocking, short reads, drains rx_ring
//   * SYS_SET_CONSOLE_MODE  — inert until phase 4
//   * SYS_CLOSE_CONSOLE     — inert until phase 4
pub const SYS_OPEN_CONSOLE: u64 = 23;
pub const SYS_READ_CONSOLE: u64 = 24;
pub const SYS_SET_CONSOLE_MODE: u64 = 25;
pub const SYS_CLOSE_CONSOLE: u64 = 26;
pub const SYS_PIPE_READ: u64 = 27;
pub const SYS_PIPE_WRITE: u64 = 28;
pub const SYS_PIPE_CLOSE: u64 = 29;
// FIXME(phase 4/8): debug-only — not part of the stable ABI.
// Pushes one byte into the kernel RX ring as if it had arrived on
// the UART. Powers deterministic console-echo coverage on QEMU
// where there is no external input driver. Symmetric to
// sys_dump_free in posture; remove when phase 4 lands a real
// host-input driver.
pub const SYS_CONSOLE_INJECT: u64 = 30;
