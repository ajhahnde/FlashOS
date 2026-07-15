//! The block-device vtable shared with the board and FAT32 layers.
//!
//! A single global instance (`sd_dev`, still owned by the Flash adapter during
//! the bridge) covers the current "exactly one SD card" assumption. This module
//! owns the fixed C layout that crosses the ABI and the high-alias relocation of
//! its callbacks; the board `emmc2` layer populates the vtable at boot and the
//! FAT32 backend reads/writes through it.

/// One block device's callback pair. `read_fn` fills a caller-owned 512-byte
/// buffer from a sector; `write_fn` stores one. Both are `null` until the board
/// layer wires them post-init. The layout is mirrored by an `extern struct` on
/// the Flash side and asserted below, so it must not be reordered or repacked.
#[repr(C)]
pub struct BlockDev {
    pub read_fn: Option<BlockReadFn>,
    pub write_fn: Option<BlockWriteFn>,
}

/// Read one 512-byte sector into the caller's buffer. Returns 0 on success, a
/// negative error otherwise.
pub type BlockReadFn = extern "C" fn(u32, *mut [u8; 512]) -> i32;

/// Write one 512-byte sector from the caller's buffer. Returns 0 on success, a
/// negative error otherwise.
pub type BlockWriteFn = extern "C" fn(u32, *const [u8; 512]) -> i32;

const _: () = assert!(core::mem::size_of::<BlockDev>() == 16);
const _: () = assert!(core::mem::align_of::<BlockDev>() == 8);
const _: () = assert!(core::mem::offset_of!(BlockDev, read_fn) == 0);
const _: () = assert!(core::mem::offset_of!(BlockDev, write_fn) == 8);

/// TTBR1 linear-map base. The kernel is linked at a low VA but executes from the
/// high half, so a low link-address callback must be folded into its high alias
/// before it can be called from EL1 while TTBR0 holds a user pgd. Mirrors
/// `vfs::relocate_ops` and the syscall-table relocation.
const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;

/// Fold a low link address into its high-half alias. Idempotent: the base bits
/// are already set on a second application, so `x | BASE == x`.
fn high_alias(address: u64) -> u64 {
    address | LINEAR_MAP_BASE
}

/// Re-point a block device's callbacks to their high-half (TTBR1) aliases.
///
/// File syscalls run at EL1 with TTBR0 holding the *user* pgd; an indirect call
/// through a low link-address pointer instruction-aborts because the user pgd
/// does not map kernel low memory as executable. `| BASE` is idempotent, so a
/// double call is harmless, and `null` callbacks are left untouched. The FAT32
/// backend calls this before its first mount so every later read/write — kernel
/// bring-up or syscall context — goes through the high alias.
///
/// # Safety
/// `dev` must point to a live, writable `BlockDev` for the duration of the call.
pub unsafe fn relocate(dev: *mut BlockDev) {
    // SAFETY: the caller guarantees a live, writable `dev`. Raw field pointers
    // avoid forming a `&mut` to a vtable the board layer and FAT32 backend also
    // reference.
    let read = unsafe { core::ptr::read(core::ptr::addr_of!((*dev).read_fn)) };
    if let Some(f) = read {
        let aliased = high_alias(f as usize as u64) as usize;
        // SAFETY: `aliased` is the TTBR1 image of a real code address (its low
        // half is a linked function), hence a valid, non-null code pointer once
        // TTBR1 is live. This is the Rust spelling of the old Flash
        // `#ptrFromInt(#intFromPtr(f) | BASE)`.
        let hi: BlockReadFn = unsafe { core::mem::transmute::<usize, BlockReadFn>(aliased) };
        // SAFETY: the field belongs to the live, writable `dev`.
        unsafe { core::ptr::write(core::ptr::addr_of_mut!((*dev).read_fn), Some(hi)) };
    }

    // SAFETY: as above, for the write callback.
    let write = unsafe { core::ptr::read(core::ptr::addr_of!((*dev).write_fn)) };
    if let Some(f) = write {
        let aliased = high_alias(f as usize as u64) as usize;
        // SAFETY: as for the read callback: a valid high-half code pointer.
        let hi: BlockWriteFn = unsafe { core::mem::transmute::<usize, BlockWriteFn>(aliased) };
        // SAFETY: the field belongs to the live, writable `dev`.
        unsafe { core::ptr::write(core::ptr::addr_of_mut!((*dev).write_fn), Some(hi)) };
    }
}

#[cfg(test)]
mod tests {
    use super::{high_alias, relocate, BlockDev, LINEAR_MAP_BASE};

    extern "C" fn dummy_read(_: u32, _: *mut [u8; 512]) -> i32 {
        0
    }
    extern "C" fn dummy_write(_: u32, _: *const [u8; 512]) -> i32 {
        0
    }

    #[test]
    fn high_alias_sets_the_base_and_is_idempotent() {
        let once = high_alias(0x8_0000);
        assert_eq!(once, 0xFFFF_0000_0008_0000);
        assert_eq!(high_alias(once), once);
    }

    #[test]
    fn relocate_ors_the_base_into_non_null_callbacks() {
        let mut dev = BlockDev {
            read_fn: Some(dummy_read),
            write_fn: Some(dummy_write),
        };
        let read_before = dev.read_fn.unwrap() as usize as u64;
        let write_before = dev.write_fn.unwrap() as usize as u64;
        // SAFETY: `dev` is a live stack value used exclusively on this thread.
        unsafe { relocate(&mut dev) };
        assert_eq!(
            dev.read_fn.unwrap() as usize as u64,
            read_before | LINEAR_MAP_BASE
        );
        assert_eq!(
            dev.write_fn.unwrap() as usize as u64,
            write_before | LINEAR_MAP_BASE
        );
    }

    #[test]
    fn relocate_leaves_null_callbacks_untouched() {
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        // SAFETY: live stack value used exclusively on this thread.
        unsafe { relocate(&mut dev) };
        assert!(dev.read_fn.is_none());
        assert!(dev.write_fn.is_none());
    }

    #[test]
    fn relocate_is_idempotent_across_two_calls() {
        let mut dev = BlockDev {
            read_fn: Some(dummy_read),
            write_fn: None,
        };
        let want = (dev.read_fn.unwrap() as usize as u64) | LINEAR_MAP_BASE;
        // SAFETY: live stack value used exclusively on this thread.
        unsafe { relocate(&mut dev) };
        // SAFETY: same live stack value; a second relocation must be a no-op.
        unsafe { relocate(&mut dev) };
        assert_eq!(dev.read_fn.unwrap() as usize as u64, want);
    }
}
