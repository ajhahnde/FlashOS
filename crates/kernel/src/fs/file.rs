//! Open-file lifetime helpers.
//!
//! The fixed `File` record lives in `flashos-kernel-abi` because task and fd-table
//! layouts embed pointers to it. This module owns the record's lifecycle and
//! its type tag. Allocation and preemption primitives are supplied through the
//! small kernel ABI wrapper in `crates/klib`.

pub use flashos_kernel_abi::task::{File, TaskStruct, FD_TABLE_SIZE};

/// `File.ftype` tag values. Only the initramfs backend has a distinct tag
/// today; FAT32 uses the same generic file dispatch through `File.sb`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FType {
    InitramfsFile = 0,
}

const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;

/// Convert an allocator-returned physical page to the address the running
/// high-half kernel uses. Host tests pass `false` and keep their native pointer.
pub const fn page_kva(page_pa: u64, freestanding: bool) -> u64 {
    if freestanding {
        page_pa | LINEAR_MAP_BASE
    } else {
        page_pa
    }
}

/// Convert a live `File` address back to the physical page returned by the
/// allocator.
pub const fn page_pa(file_kva: u64, freestanding: bool) -> u64 {
    if freestanding {
        file_kva & !LINEAR_MAP_BASE
    } else {
        file_kva
    }
}

/// Zero-initialize one `File` in caller-provided storage.
///
/// # Safety
/// `file` must be non-null, aligned, writable storage for one `File`, and no
/// other access may race this initialization.
pub unsafe fn initialize(file: *mut File) {
    // SAFETY: guaranteed by the caller. `write` initializes without reading the
    // old page contents and does not manufacture an aliasing reference.
    unsafe { file.write(File::default()) };
}

/// Increment one live handle's reference count. The bridge holds the existing
/// preemption exclusion around this operation.
///
/// # Safety
/// `file` points to a live, writable `File` whose reference count is nonzero.
pub unsafe fn add_ref(file: *mut File) {
    // SAFETY: the caller supplies an exclusive preemption window and a live
    // record. Raw field access avoids a `&mut` that could overstate uniqueness.
    let refs = unsafe { core::ptr::read(core::ptr::addr_of!((*file).refs)) };
    unsafe { core::ptr::write(core::ptr::addr_of_mut!((*file).refs), refs + 1) };
}

/// Drop one reference, returning whether the caller must free the backing page.
///
/// # Safety
/// Same contract as [`add_ref`]. The count must be at least one.
pub unsafe fn drop_ref(file: *mut File) -> bool {
    // SAFETY: guaranteed by the caller.
    let refs = unsafe { core::ptr::read(core::ptr::addr_of!((*file).refs)) };
    let next = refs - 1;
    unsafe { core::ptr::write(core::ptr::addr_of_mut!((*file).refs), next) };
    next == 0
}

#[cfg(target_os = "none")]
mod seam {
    unsafe extern "C" {
        pub fn get_free_page() -> u64;
        pub fn free_page(page: u64);
        pub fn preempt_disable();
        pub fn preempt_enable();
    }

    pub const FREESTANDING: bool = true;
}

// Host seam: a leaking bump arena, matching the pipe module's. Atomic bump so
// parallel test threads never hand out the same page.
#[cfg(not(target_os = "none"))]
mod seam {
    use core::sync::atomic::{AtomicUsize, Ordering};

    pub const FREESTANDING: bool = false;

    const PAGE_SIZE: usize = 4096;
    const PAGES: usize = 64;

    // Alignment-only storage: the bytes are addressed through raw pointers, so
    // the field itself is never read by name.
    #[repr(align(4096))]
    struct Page(#[allow(dead_code)] [u8; PAGE_SIZE]);

    static mut ARENA: [Page; PAGES] = [const { Page([0; PAGE_SIZE]) }; PAGES];
    static NEXT: AtomicUsize = AtomicUsize::new(0);

    pub unsafe fn get_free_page() -> u64 {
        let index = NEXT.fetch_add(1, Ordering::Relaxed);
        if index >= PAGES {
            return 0;
        }
        // SAFETY: each index is handed out once, so the page is exclusive.
        unsafe { core::ptr::addr_of_mut!(ARENA).cast::<Page>().add(index) as u64 }
    }

    pub unsafe fn free_page(_page: u64) {}
    pub unsafe fn preempt_disable() {}
    pub unsafe fn preempt_enable() {}
}

/// Allocate and zero one `File`, or null when the allocator is exhausted.
///
/// The record occupies its own page: the allocator is the kernel's only
/// fixed-size supply, and `File` records are freed individually.
///
/// # Safety
/// The caller must satisfy the kernel's single-core allocator exclusion.
pub unsafe fn alloc() -> *mut File {
    // SAFETY: the allocator seam yields zero or one exclusively owned page.
    let page_pa = unsafe { seam::get_free_page() };
    if page_pa == 0 {
        return core::ptr::null_mut();
    }
    let file = page_kva(page_pa, seam::FREESTANDING) as *mut File;
    // SAFETY: the fresh page is aligned, writable, and exclusively owned.
    unsafe { initialize(file) };
    file
}

/// Drop one reference and free the backing page on the last one.
///
/// # Safety
/// `file` points to a live allocated `File` with at least one reference.
pub unsafe fn unref(file: *mut File) {
    // SAFETY: the count transition must not race the timer IRQ.
    unsafe { seam::preempt_disable() };
    let last = unsafe { drop_ref(file) };
    unsafe { seam::preempt_enable() };
    if last {
        let page_pa = page_pa(file as u64, seam::FREESTANDING);
        // SAFETY: the last reference owned the page; no alias survives.
        unsafe { seam::free_page(page_pa) };
    }
}

/// Take one reference under the module's preemption exclusion.
///
/// # Safety
/// `file` points to a live allocated `File`.
pub unsafe fn reference(file: *mut File) {
    // SAFETY: the count transition must not race the timer IRQ.
    unsafe { seam::preempt_disable() };
    unsafe { add_ref(file) };
    unsafe { seam::preempt_enable() };
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::mem::MaybeUninit;

    #[test]
    fn initialize_returns_a_zeroed_file() {
        let mut storage = MaybeUninit::<File>::uninit();
        // SAFETY: `storage` is aligned, writable, and exclusively owned here.
        unsafe { initialize(storage.as_mut_ptr()) };
        // SAFETY: initialize wrote a complete `File`.
        let file = unsafe { storage.assume_init() };
        assert_eq!(file.ftype, 0);
        assert_eq!(file.refs, 0);
        assert_eq!(file.offset, 0);
        assert_eq!(file.private, 0);
        assert_eq!(file.size, 0);
        assert!(file.sb.is_null());
        assert_eq!(file.mode, 0);
        assert_eq!(file.uid, 0);
        assert_eq!(file.gid, 0);
        assert_eq!(file.dirent_lba, 0);
        assert_eq!(file.dirent_off, 0);
    }

    #[test]
    fn ftype_tag_round_trips_through_the_abi_record() {
        let file = File {
            ftype: FType::InitramfsFile as u8,
            ..File::default()
        };
        assert_eq!(file.ftype, 0);
        assert_eq!(file.ftype, FType::InitramfsFile as u8);
    }

    #[test]
    fn refcount_reports_only_the_last_drop() {
        let mut file = File {
            refs: 1,
            ..File::default()
        };
        // SAFETY: exclusive live stack record.
        unsafe { add_ref(&raw mut file) };
        assert_eq!(file.refs, 2);
        // SAFETY: same record, count is nonzero.
        assert!(!unsafe { drop_ref(&raw mut file) });
        // SAFETY: same record, count is one.
        assert!(unsafe { drop_ref(&raw mut file) });
    }

    #[test]
    fn page_alias_conversion_matches_the_linear_map() {
        assert_eq!(page_kva(0x1234_5000, true), 0xFFFF_0000_1234_5000);
        assert_eq!(page_pa(0xFFFF_0000_1234_5000, true), 0x1234_5000);
        assert_eq!(page_kva(0x1234_5000, false), 0x1234_5000);
    }
}
