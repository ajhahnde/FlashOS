// User-space virtual address layout — single source of truth for the
// regions the ELF loader will populate and the page-fault path will
// classify. Imported by src/fork.zig (prepare_move_to_user) and
// src/mm_user.zig (do_data_abort + map_page) so both sides agree on
// where text/data/heap/stack live.
//
// Region map (matches DOCUMENTATION.md §3 "User virtual layout"):
//
//   0x0000_0000_0000_0000  text    (R-X)
//   0x0000_0000_0010_0000  data    (RW-)
//   0x0000_0000_0020_0000  heap    (RW-, grows up via brk)
//   0x0000_0FFF_FFFF_F000  stack   (RW-, grows down, guard below)
//
// The layout is documented above and region flags are plumbed
// through map_page; the blob path (PID 1 / non-ELF sys_exec inline)
// keeps stamping the combined-permission default bag, while
// ELF-loaded tasks get per-region attributes via
// prepare_move_to_user_elf.

pub const PAGE_SIZE: u64 = 1 << 12;

pub const TEXT_BASE: u64 = 0x0000_0000_0000_0000;
pub const DATA_BASE: u64 = 0x0000_0000_0010_0000;
pub const HEAP_BASE: u64 = 0x0000_0000_0020_0000;
pub const STACK_TOP: u64 = 0x0000_0FFF_FFFF_F000;

// Stack budget: largest legal stack VA range is [STACK_LOW, STACK_TOP).
// prepare_move_to_user_elf eagerly maps the top page; do_data_abort
// demand-allocates the rest within the budget. Below STACK_LOW sits a
// 1-page guard region [STACK_GUARD_LOW, STACK_GUARD_HIGH) that
// do_data_abort treats as a stack-overflow signal — it prints a
// diagnostic and zombies the offending task (the parent's sys_wait
// reaps as usual). 64 KiB matches sys_brk's upper-bound check, so the
// heap can't grow into either the stack or its guard.
pub const STACK_BUDGET: u64 = 16 * PAGE_SIZE;
pub const STACK_LOW: u64 = STACK_TOP - STACK_BUDGET;
pub const STACK_GUARD_PAGES: u64 = 1;
pub const STACK_GUARD_HIGH: u64 = STACK_LOW;
pub const STACK_GUARD_LOW: u64 = STACK_LOW - STACK_GUARD_PAGES * PAGE_SIZE;

// Stage-1 page-descriptor bit 54: UXN (Unprivileged eXecute Never),
// AArch64 ARM D5-2750. PXN (privileged XN) is bit 53; user data/heap/
// stack pages set UXN to forbid EL0 execution. User text clears it.
pub const TD_USER_XN: u64 = 1 << 54;

// MMU descriptor sub-flags shared with src/mm_user.zig. Kept here so
// the assembled per-region bags (TEXT/DATA/...) below can be derived
// in one place; mm_user.zig keeps its own copies for the page-table-
// walk internals (table flags etc.) that the loader does not stamp.
const TD_VALID: u64 = 1 << 0;
const TD_PAGE: u64 = 1 << 1;
const TD_USER_PERMS: u64 = 1 << 6;
const TD_INNER_SHARABLE: u64 = 3 << 8;
const TD_ACCESS: u64 = 1 << 10;

// Default user-page permission bag — the historical
// TD_USER_PAGE_FLAGS from src/mm_user.zig. Used by every existing call
// site (blob path, demand-allocation in do_data_abort, copy_virt_memory)
// until the ELF loader starts choosing per-region flags. Identical
// value to the pre-existing constant — acceptance is "blob path
// keeps working unchanged".
pub const TD_USER_PAGE_FLAGS_DEFAULT: u64 =
    TD_ACCESS | TD_INNER_SHARABLE | TD_USER_PERMS | TD_PAGE | TD_VALID;
