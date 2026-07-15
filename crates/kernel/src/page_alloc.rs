//! Physical-page bitmap allocator for kernel memory.
//!
//! FlashOS is single-core. Bring-up initializes and reserves the bitmap before
//! scheduling starts, and no interrupt handler allocates pages. Runtime callers
//! therefore serialize through the existing kernel/preemption control flow.
//! Raw pointers are used for the global state so Rust never claims an exclusive
//! reference that could outlive one allocator operation.

use core::cell::UnsafeCell;

pub const PAGE_SIZE: u64 = 1 << 12;
pub const MALLOC_START: u64 = 0x4000_0000;
pub const MALLOC_END: u64 = 0xFC00_0000;
pub const MALLOC_SIZE: u64 = MALLOC_END - MALLOC_START;
pub const MALLOC_PAGES: usize = (MALLOC_SIZE / PAGE_SIZE) as usize;

const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;

const fn pa_to_kva(pa: u64) -> u64 {
    pa.wrapping_add(LINEAR_MAP_BASE)
}

const fn kva_to_pa(kva: u64) -> u64 {
    kva.wrapping_sub(LINEAR_MAP_BASE)
}

struct Global<T>(UnsafeCell<T>);

// SAFETY: the module-level exclusion contract above serializes every mutation.
unsafe impl<T> Sync for Global<T> {}

// Keep the all-zero bitmap separate so the linker can retain its original BSS
// placement instead of materializing it in the raw image beside POOL_TOTAL.
static MEM_MAP: Global<[u8; MALLOC_PAGES]> = Global(UnsafeCell::new([0; MALLOC_PAGES]));
static POOL_TOTAL: Global<u64> = Global(UnsafeCell::new(MALLOC_PAGES as u64));

/// Reset the bitmap and allocatable-pool total.
///
/// # Safety
/// Called on core 0 before any allocator consumer, or by a serialized host test.
pub unsafe fn mem_map_init() {
    let map = MEM_MAP.0.get().cast::<u8>();
    let mut i = 0usize;
    while i < MALLOC_PAGES {
        // SAFETY: `i` is in the sole static bitmap and the caller owns mutation.
        unsafe { map.add(i).write(0) };
        i += 1;
    }
    // SAFETY: the caller exclusively owns bring-up/test initialization.
    unsafe { POOL_TOTAL.0.get().write(MALLOC_PAGES as u64) };
}

/// Reserve every allocator page below `end_pa`.
///
/// # Safety
/// Boot-only after [`mem_map_init`], before runtime allocation begins.
pub unsafe fn mem_map_reserve_below(end_pa: u64) {
    if end_pa <= MALLOC_START {
        return;
    }
    let map = MEM_MAP.0.get().cast::<u8>();
    let total = POOL_TOTAL.0.get();
    let mut i = 0usize;
    while i < MALLOC_PAGES {
        let pa = MALLOC_START + i as u64 * PAGE_SIZE;
        if pa >= end_pa {
            break;
        }
        // SAFETY: `i` is in bounds and boot-time exclusion owns the state.
        let slot = unsafe { map.add(i) };
        // SAFETY: `slot` points into the live bitmap.
        if unsafe { slot.read() } == 0 {
            // SAFETY: `total` belongs to the same exclusively owned state.
            unsafe { total.write(total.read() - 1) };
        }
        // SAFETY: `slot` is the selected live bitmap byte.
        unsafe { slot.write(1) };
        i += 1;
    }
}

/// Reserve every allocator page at or above `start_pa`.
///
/// # Safety
/// Boot-only after [`mem_map_init`], before runtime allocation begins.
pub unsafe fn mem_map_reserve_above(start_pa: u64) {
    if start_pa >= MALLOC_END {
        return;
    }
    let map = MEM_MAP.0.get().cast::<u8>();
    let total = POOL_TOTAL.0.get();
    let mut i = 0usize;
    while i < MALLOC_PAGES {
        let pa = MALLOC_START + i as u64 * PAGE_SIZE;
        if pa >= start_pa {
            // SAFETY: `i` is in bounds and boot-time exclusion owns the state.
            let slot = unsafe { map.add(i) };
            // SAFETY: `slot` points into the live bitmap.
            if unsafe { slot.read() } == 0 {
                // SAFETY: `total` belongs to the same exclusively owned state.
                unsafe { total.write(total.read() - 1) };
            }
            // SAFETY: `slot` is the selected live bitmap byte.
            unsafe { slot.write(1) };
        }
        i += 1;
    }
}

/// Allocate and zero one physical page, returning PA 0 on exhaustion.
///
/// # Safety
/// The caller satisfies the module exclusion contract. `zero` must accept the
/// mapped kernel alias and page length without retaining either value.
pub unsafe fn get_free_page(zero: unsafe extern "C" fn(u64, u64)) -> u64 {
    let map = MEM_MAP.0.get().cast::<u8>();
    let mut i = 0usize;
    while i < MALLOC_PAGES {
        // SAFETY: `i` is in the sole static bitmap.
        let slot = unsafe { map.add(i) };
        // SAFETY: the caller serializes access to the live slot.
        if unsafe { slot.read() } == 0 {
            // SAFETY: the caller owns the state transition from free to allocated.
            unsafe { slot.write(1) };
            let pa = MALLOC_START + i as u64 * PAGE_SIZE;
            // SAFETY: the claimed page is mapped, exclusive, and not published yet.
            unsafe { zero(pa_to_kva(pa), PAGE_SIZE) };
            return pa;
        }
        i += 1;
    }
    0
}

/// Return one physical page to the bitmap.
///
/// # Safety
/// `page` is either an allocator PA whose ownership the caller relinquishes or
/// an out-of-range value, which is ignored to preserve the existing contract.
pub unsafe fn free_page(page: u64) {
    let index = page.wrapping_sub(MALLOC_START) / PAGE_SIZE;
    if index < MALLOC_PAGES as u64 {
        let map = MEM_MAP.0.get().cast::<u8>();
        // SAFETY: the range check proves the index belongs to the bitmap.
        unsafe { map.add(index as usize).write(0) };
    }
}

/// Allocate a page and return its high-half kernel alias, preserving PA 0.
///
/// # Safety
/// Same contract as [`get_free_page`].
pub unsafe fn get_kernel_page(zero: unsafe extern "C" fn(u64, u64)) -> u64 {
    // SAFETY: forwarded from the caller.
    let page = unsafe { get_free_page(zero) };
    if page == 0 {
        0
    } else {
        pa_to_kva(page)
    }
}

/// Free a page previously returned by [`get_kernel_page`].
///
/// # Safety
/// `page` is a live allocator KVA whose ownership the caller relinquishes.
pub unsafe fn free_kernel_page(page: u64) {
    // SAFETY: the caller's KVA ownership maps to the corresponding allocator PA.
    unsafe { free_page(kva_to_pa(page)) };
}

/// Count currently free pages.
///
/// # Safety
/// The caller satisfies the module exclusion contract for the duration of the scan.
pub unsafe fn free_count() -> u64 {
    let map = MEM_MAP.0.get().cast::<u8>();
    let mut count = 0u64;
    let mut i = 0usize;
    while i < MALLOC_PAGES {
        // SAFETY: `i` is in bounds and the caller serializes bitmap access.
        if unsafe { map.add(i).read() } == 0 {
            count += 1;
        }
        i += 1;
    }
    count
}

/// Return the post-reservation pool size, independent of live allocations.
///
/// # Safety
/// Bring-up has initialized the state; runtime reads occur after reservations end.
pub unsafe fn mem_total_count() -> u64 {
    // SAFETY: the caller observes the live scalar under the module contract.
    unsafe { POOL_TOTAL.0.get().read() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> MutexGuard<'static, ()> {
        TEST_LOCK
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    unsafe extern "C" fn ignore_zero(_: u64, _: u64) {}

    unsafe fn reset() {
        // SAFETY: every test holds TEST_LOCK.
        unsafe { mem_map_init() };
    }

    unsafe fn mark_all_allocated() {
        let map = MEM_MAP.0.get().cast::<u8>();
        let mut i = 0usize;
        while i < MALLOC_PAGES {
            // SAFETY: every test holds TEST_LOCK and `i` is in bounds.
            unsafe { map.add(i).write(1) };
            i += 1;
        }
    }

    #[test]
    fn pa_to_kva_and_kva_to_pa_round_trip() {
        let pa = MALLOC_START + 7 * PAGE_SIZE;
        assert_eq!(kva_to_pa(pa_to_kva(pa)), pa);
    }

    #[test]
    fn mem_map_init_zeroes_the_bitmap() {
        let _guard = lock();
        // SAFETY: the test lock serializes direct state mutation.
        unsafe { mark_all_allocated() };
        // SAFETY: the test lock gives this test exclusive allocator access.
        unsafe { mem_map_init() };
        // SAFETY: the test lock serializes the scan.
        assert_eq!(unsafe { free_count() }, MALLOC_PAGES as u64);
    }

    #[test]
    fn get_free_page_returns_sequential_pages_from_malloc_start() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        // SAFETY: same serialized state and inert zero callback.
        let a = unsafe { get_free_page(ignore_zero) };
        // SAFETY: same serialized state and inert zero callback.
        let b = unsafe { get_free_page(ignore_zero) };
        // SAFETY: same serialized state and inert zero callback.
        let c = unsafe { get_free_page(ignore_zero) };
        assert_eq!(a, MALLOC_START);
        assert_eq!(b, MALLOC_START + PAGE_SIZE);
        assert_eq!(c, MALLOC_START + 2 * PAGE_SIZE);
    }

    #[test]
    fn free_page_reuses_the_slot_on_next_allocation() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        // SAFETY: same serialized state and inert zero callback.
        let a = unsafe { get_free_page(ignore_zero) };
        // SAFETY: same serialized state and inert zero callback.
        let _ = unsafe { get_free_page(ignore_zero) };
        // SAFETY: `a` is a live allocation relinquished by this test.
        unsafe { free_page(a) };
        // SAFETY: same serialized state and inert zero callback.
        assert_eq!(unsafe { get_free_page(ignore_zero) }, a);
    }

    #[test]
    fn free_count_tracks_allocations() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        // SAFETY: the test lock serializes the scan.
        assert_eq!(unsafe { free_count() }, MALLOC_PAGES as u64);
        for _ in 0..3 {
            // SAFETY: same serialized state and inert zero callback.
            let _ = unsafe { get_free_page(ignore_zero) };
        }
        // SAFETY: the test lock serializes the scan.
        assert_eq!(unsafe { free_count() }, MALLOC_PAGES as u64 - 3);
    }

    #[test]
    fn free_page_silently_ignores_above_range_pa() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        // SAFETY: the test lock serializes the scan.
        let before = unsafe { free_count() };
        // SAFETY: out-of-range values are explicitly accepted and ignored.
        unsafe { free_page(MALLOC_END + PAGE_SIZE) };
        // SAFETY: out-of-range values are explicitly accepted and ignored.
        unsafe { free_page(MALLOC_END + 1024 * PAGE_SIZE) };
        // SAFETY: the test lock serializes the scan.
        assert_eq!(unsafe { free_count() }, before);
    }

    #[test]
    fn get_kernel_page_returns_kva_of_a_free_physical_page() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        // SAFETY: same serialized state and inert zero callback.
        let kva = unsafe { get_kernel_page(ignore_zero) };
        assert!(kva >= LINEAR_MAP_BASE + MALLOC_START);
        // SAFETY: `kva` is the live allocation this test relinquishes.
        unsafe { free_kernel_page(kva) };
        // SAFETY: the test lock serializes the scan.
        assert_eq!(unsafe { free_count() }, MALLOC_PAGES as u64);
    }

    #[test]
    fn get_free_page_returns_zero_when_the_pool_is_exhausted() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        // SAFETY: the test lock serializes direct state mutation.
        unsafe { mark_all_allocated() };
        // SAFETY: same serialized state and inert zero callback.
        assert_eq!(unsafe { get_free_page(ignore_zero) }, 0);
    }

    #[test]
    fn get_kernel_page_propagates_zero_not_the_linear_map_base() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        // SAFETY: the test lock serializes direct state mutation.
        unsafe { mark_all_allocated() };
        // SAFETY: same serialized state and inert zero callback.
        assert_eq!(unsafe { get_kernel_page(ignore_zero) }, 0);
    }

    #[test]
    fn reserve_below_marks_the_kernel_image_prefix_allocated() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        let end_pa = MALLOC_START + 5 * PAGE_SIZE;
        // SAFETY: this serialized test models boot-time reservation.
        unsafe { mem_map_reserve_below(end_pa) };
        // SAFETY: the test lock serializes the scan.
        assert_eq!(unsafe { free_count() }, MALLOC_PAGES as u64 - 5);
        // SAFETY: same serialized state and inert zero callback.
        assert_eq!(unsafe { get_free_page(ignore_zero) }, end_pa);
    }

    #[test]
    fn reserve_below_is_a_noop_at_or_below_malloc_start() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        // SAFETY: this serialized test models boot-time reservation.
        unsafe { mem_map_reserve_below(MALLOC_START) };
        // SAFETY: the test lock serializes the scan.
        assert_eq!(unsafe { free_count() }, MALLOC_PAGES as u64);
        // SAFETY: this serialized test models the rpi4b linker address.
        unsafe { mem_map_reserve_below(0x8_0000) };
        // SAFETY: the test lock serializes the scan.
        assert_eq!(unsafe { free_count() }, MALLOC_PAGES as u64);
        // SAFETY: same serialized state and inert zero callback.
        assert_eq!(unsafe { get_free_page(ignore_zero) }, MALLOC_START);
    }

    #[test]
    fn reserve_above_caps_the_pool_at_the_ram_end() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        let ram_end = 0x8000_0000u64;
        // SAFETY: this serialized test models boot-time virt reservation.
        unsafe { mem_map_reserve_above(ram_end) };
        let in_ram_pages = ((ram_end - MALLOC_START) / PAGE_SIZE) as usize;
        // SAFETY: the test lock serializes the scan.
        assert_eq!(unsafe { free_count() }, in_ram_pages as u64);

        let map = MEM_MAP.0.get().cast::<u8>();
        let mut i = 0usize;
        while i < in_ram_pages - 1 {
            // SAFETY: the test lock serializes mutation and `i` is in bounds.
            unsafe { map.add(i).write(1) };
            i += 1;
        }
        // SAFETY: same serialized state and inert zero callback.
        assert_eq!(unsafe { get_free_page(ignore_zero) }, ram_end - PAGE_SIZE);
        // SAFETY: same serialized state and inert zero callback.
        assert_eq!(unsafe { get_free_page(ignore_zero) }, 0);
    }

    #[test]
    fn mem_total_count_is_post_reserve_and_ignores_allocations() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        // SAFETY: the test lock serializes the read.
        assert_eq!(unsafe { mem_total_count() }, MALLOC_PAGES as u64);
        // SAFETY: this serialized test models boot-time reservation.
        unsafe { mem_map_reserve_below(MALLOC_START + 5 * PAGE_SIZE) };
        // SAFETY: the test lock serializes the read.
        assert_eq!(unsafe { mem_total_count() }, MALLOC_PAGES as u64 - 5);
        // SAFETY: same serialized state and inert zero callback.
        let _ = unsafe { get_free_page(ignore_zero) };
        // SAFETY: same serialized state and inert zero callback.
        let _ = unsafe { get_free_page(ignore_zero) };
        // SAFETY: the test lock serializes the read.
        assert_eq!(unsafe { mem_total_count() }, MALLOC_PAGES as u64 - 5);
    }

    #[test]
    fn mem_total_count_counts_overlapping_reservations_once() {
        let _guard = lock();
        // SAFETY: the test lock serializes allocator access.
        unsafe { reset() };
        let ram_end = 0x8000_0000u64;
        // SAFETY: this serialized test models boot-time reservation.
        unsafe { mem_map_reserve_above(ram_end) };
        let above = MALLOC_PAGES as u64 - (ram_end - MALLOC_START) / PAGE_SIZE;
        // SAFETY: the test lock serializes the read.
        assert_eq!(unsafe { mem_total_count() }, MALLOC_PAGES as u64 - above);
        // SAFETY: the overlapping reservation is serialized under the test lock.
        unsafe { mem_map_reserve_below(ram_end + 10 * PAGE_SIZE) };
        let below = (ram_end - MALLOC_START) / PAGE_SIZE;
        // SAFETY: the test lock serializes the read.
        assert_eq!(
            unsafe { mem_total_count() },
            MALLOC_PAGES as u64 - above - below
        );
    }
}
