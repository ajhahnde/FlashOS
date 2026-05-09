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
