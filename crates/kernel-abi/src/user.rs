//! Kernel-private user-page descriptor flags.
//!
//! The public user virtual-address layout (region bases, stack budget, guard
//! pages) now lives in the FlashSDK `flashsdk_abi::user` crate, which both the
//! kernel and EL0 consume. What stays here is the half EL0 never sees: the
//! AArch64 stage-1 descriptor bits the ELF loader and the fault path stamp onto
//! user pages. These are a kernel↔MMU contract, not a syscall-boundary fact.

/// Stage-1 descriptor bit 54: UXN (Unprivileged eXecute Never), AArch64 ARM
/// D5-2750. User data/heap/stack pages set it to forbid EL0 execution; user text
/// clears it.
pub const TD_USER_XN: u64 = 1 << 54;

// Descriptor sub-flags the per-region bag below is composed from. The
// page-table-walk internals (table flags etc.) that the loader does not stamp
// stay with the mm code.
const TD_VALID: u64 = 1 << 0;
const TD_PAGE: u64 = 1 << 1;
const TD_USER_PERMS: u64 = 1 << 6;
const TD_INNER_SHARABLE: u64 = 3 << 8;
const TD_ACCESS: u64 = 1 << 10;

/// Default user-page permission bag: the baseline the ELF loader ORs per-region
/// flags onto, the bag the fault path stamps on demand-allocated heap/stack
/// pages, and the attributes fork inherits.
pub const TD_USER_PAGE_FLAGS_DEFAULT: u64 =
    TD_ACCESS | TD_INNER_SHARABLE | TD_USER_PERMS | TD_PAGE | TD_VALID;

// ---------------------------------------------------------------------------
// Value assertions — the pre-port build's numbers.
// ---------------------------------------------------------------------------

const _: () = {
    assert!(TD_USER_PAGE_FLAGS_DEFAULT == 0x743);
    assert!(TD_USER_XN == 0x0040_0000_0000_0000);
};

#[cfg(test)]
mod tests {
    use super::*;

    /// The default bag is what every demand-allocated page is stamped with; it
    /// must be a valid, accessed, EL0-reachable page descriptor.
    #[test]
    fn the_default_page_bag_is_a_valid_user_page_descriptor() {
        assert_ne!(TD_USER_PAGE_FLAGS_DEFAULT & TD_VALID, 0);
        assert_ne!(TD_USER_PAGE_FLAGS_DEFAULT & TD_PAGE, 0);
        assert_ne!(TD_USER_PAGE_FLAGS_DEFAULT & TD_ACCESS, 0);
        assert_ne!(TD_USER_PAGE_FLAGS_DEFAULT & TD_USER_PERMS, 0);
        // Executability is a per-region decision, never a default.
        assert_eq!(TD_USER_PAGE_FLAGS_DEFAULT & TD_USER_XN, 0);
    }
}
