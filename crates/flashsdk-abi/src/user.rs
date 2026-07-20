//! User-space virtual address layout.
//!
//! Single source of truth for the regions
//! the ELF loader populates and the page-fault path classifies:
//!
//! ```text
//!   0x0000_0000_0000_0000  text    (RWX — writable; no read-only bit yet)
//!   0x0000_0000_0010_0000  data    (RW-)
//!   0x0000_0000_0020_0000  heap    (RW-, grows up via brk)
//!   0x0000_0FFF_FFFF_F000  stack   (RW-, grows down, guard below)
//! ```
//!
//! Only the public VA-layout facts live here. The kernel-private page-descriptor
//! (`TD_*`) constants and the default user-page permission bag remain in the
//! FlashOS `abi` crate: their sole consumers are the kernel fork and mm paths.

pub const PAGE_SIZE: u64 = 1 << 12;

pub const TEXT_BASE: u64 = 0x0000_0000_0000_0000;
pub const DATA_BASE: u64 = 0x0000_0000_0010_0000;
pub const HEAP_BASE: u64 = 0x0000_0000_0020_0000;
pub const STACK_TOP: u64 = 0x0000_0FFF_FFFF_F000;

/// Largest legal stack VA range is `[STACK_LOW, STACK_TOP)`. The loader eagerly
/// maps the top page; the fault path demand-allocates the rest within the budget.
/// 64 KiB matches the brk upper bound, so the heap cannot grow into the stack or
/// its guard.
pub const STACK_BUDGET: u64 = 16 * PAGE_SIZE;
pub const STACK_LOW: u64 = STACK_TOP - STACK_BUDGET;
pub const STACK_GUARD_PAGES: u64 = 1;
pub const STACK_GUARD_HIGH: u64 = STACK_LOW;
/// A fault in `[STACK_GUARD_LOW, STACK_GUARD_HIGH)` is a stack overflow: the
/// fault path prints a diagnostic and zombies the task.
pub const STACK_GUARD_LOW: u64 = STACK_LOW - STACK_GUARD_PAGES * PAGE_SIZE;

// ---------------------------------------------------------------------------
// Value assertions — the pre-port build's numbers.
// ---------------------------------------------------------------------------

const _: () = {
    assert!(STACK_TOP == 0x0FFF_FFFF_F000);
    assert!(STACK_LOW == 0x0FFF_FFFE_F000);
    assert!(STACK_GUARD_LOW == 0x0FFF_FFFE_E000);

    // The regions must stay ordered and page-aligned, or the fault path's
    // region classification silently mis-sorts an address.
    assert!(TEXT_BASE < DATA_BASE);
    assert!(DATA_BASE < HEAP_BASE);
    assert!(HEAP_BASE < STACK_GUARD_LOW);
    assert!(STACK_GUARD_LOW < STACK_LOW);
    assert!(STACK_LOW < STACK_TOP);
    assert!(STACK_TOP.is_multiple_of(PAGE_SIZE));
    assert!(HEAP_BASE.is_multiple_of(PAGE_SIZE));
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_guard_is_exactly_one_page_below_the_stack() {
        assert_eq!(STACK_GUARD_HIGH, STACK_LOW);
        assert_eq!(STACK_GUARD_HIGH - STACK_GUARD_LOW, PAGE_SIZE);
    }

    #[test]
    fn the_stack_budget_is_sixteen_pages() {
        assert_eq!((STACK_TOP - STACK_LOW) / PAGE_SIZE, 16);
    }
}
