//! User page-table walks, fault handling, and copy-user helpers.
//!
//! FlashOS is single-core. These routines may run with IRQs enabled and may be
//! preempted, but another task never mutates the active task's address space.
//! Page-table and task state stays behind raw pointers so Rust never claims a
//! reference across allocator, output, copy, exit, or scheduling-capable calls.

use core::ffi::c_void;

pub use flashos_abi::task::TaskStruct;
use flashos_abi::{
    task::{UserPage, MAX_PAGE_COUNT},
    user,
};

const PAGE_SHIFT: u32 = 12;
const TABLE_SHIFT: u32 = 9;
const PAGE_SIZE: u64 = 1 << PAGE_SHIFT;
const PAGE_MASK: u64 = 0xFFFF_FFFF_FFFF_F000;
const PGD_SHIFT: u32 = PAGE_SHIFT + 3 * TABLE_SHIFT;
const PUD_SHIFT: u32 = PAGE_SHIFT + 2 * TABLE_SHIFT;
const PMD_SHIFT: u32 = PAGE_SHIFT + TABLE_SHIFT;
const ENTRIES_PER_TABLE: u64 = 512;

#[cfg(target_os = "none")]
const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;
#[cfg(not(target_os = "none"))]
const LINEAR_MAP_BASE: u64 = 0;

const TD_VALID: u64 = 1 << 0;
const TD_TABLE: u64 = 1 << 1;
const TD_USER_TABLE_FLAGS: u64 = TD_TABLE | TD_VALID;

const MU: i32 = 0;

/// Retained kernel services used by the mixed-language bridge.
///
/// The callbacks are synchronous and retain none of their pointer arguments.
#[derive(Clone, Copy)]
pub struct Services {
    pub get_free_page: unsafe extern "C" fn() -> u64,
    pub free_page: unsafe extern "C" fn(u64),
    pub copy_memory: unsafe extern "C" fn(*mut c_void, *const c_void, u64) -> *mut c_void,
    pub output: unsafe extern "C" fn(i32, *const u8),
    pub output_u64: unsafe extern "C" fn(i32, u64),
    pub exit_process: unsafe extern "C" fn(),
}

const fn pa_to_kva(pa: u64) -> u64 {
    pa.wrapping_add(LINEAR_MAP_BASE)
}

unsafe fn pgd_ptr(task: *mut TaskStruct) -> *mut u64 {
    // SAFETY: callers supply a live TaskStruct pointer.
    unsafe { core::ptr::addr_of_mut!((*task).mm.pgd) }
}

unsafe fn brk_ptr(task: *mut TaskStruct) -> *mut u64 {
    // SAFETY: callers supply a live TaskStruct pointer.
    unsafe { core::ptr::addr_of_mut!((*task).mm.brk) }
}

unsafe fn kernel_page_ptr(task: *mut TaskStruct, index: usize) -> *mut u64 {
    // SAFETY: callers prove `index < MAX_PAGE_COUNT` and own this task's mm.
    unsafe {
        core::ptr::addr_of_mut!((*task).mm.kernel_pages)
            .cast::<u64>()
            .add(index)
    }
}

unsafe fn user_page_ptr(task: *mut TaskStruct, index: usize) -> *mut UserPage {
    // SAFETY: callers prove `index < MAX_PAGE_COUNT` and own this task's mm.
    unsafe {
        core::ptr::addr_of_mut!((*task).mm.user_pages)
            .cast::<UserPage>()
            .add(index)
    }
}

/// Number of populated kernel-page slots in this task.
///
/// # Safety
/// `task` points to a live `TaskStruct`; its mm is not concurrently mutated.
pub unsafe fn task_kp_count(task: *mut TaskStruct) -> i32 {
    let mut index = 0usize;
    while index < MAX_PAGE_COUNT {
        // SAFETY: `index` is in bounds and the caller owns the mm access.
        if unsafe { kernel_page_ptr(task, index).read() } == 0 {
            return index as i32;
        }
        index += 1;
    }
    MAX_PAGE_COUNT as i32
}

/// Number of populated user-page slots in this task.
///
/// # Safety
/// Same contract as [`task_kp_count`].
pub unsafe fn task_up_count(task: *mut TaskStruct) -> i32 {
    let mut index = 0usize;
    while index < MAX_PAGE_COUNT {
        // SAFETY: `index` is in bounds and the caller owns the mm access.
        if unsafe { user_page_ptr(task, index).read().pa } == 0 {
            return index as i32;
        }
        index += 1;
    }
    MAX_PAGE_COUNT as i32
}

/// Look up or allocate the next-level table for `uva`.
///
/// Returns its physical address and writes 1 to `new_table` only when this call
/// allocated the page. PA 0 is the OOM sentinel and never becomes a descriptor.
///
/// # Safety
/// `table` points to 512 writable entries in the owning task's table tree;
/// `new_table` is writable and the service callbacks obey [`Services`].
pub unsafe fn map_table(
    table: *mut u64,
    shift: u64,
    uva: u64,
    new_table: *mut i32,
    services: &Services,
) -> u64 {
    let shift = (shift & 63) as u32;
    let index = ((uva >> shift) & (ENTRIES_PER_TABLE - 1)) as usize;
    // SAFETY: the caller supplies a complete table and the masked index is <512.
    let slot = unsafe { table.add(index) };
    // SAFETY: this task exclusively owns mutation of the table slot.
    let entry = unsafe { slot.read() };
    if entry == 0 {
        // SAFETY: allocator exclusion is part of the caller's service contract.
        let next_level = unsafe { (services.get_free_page)() };
        if next_level == 0 {
            // SAFETY: the caller supplied a live scalar output.
            unsafe { new_table.write(0) };
            return 0;
        }
        // SAFETY: publish the zeroed table only after allocation succeeded.
        unsafe {
            new_table.write(1);
            slot.write(next_level | TD_USER_TABLE_FLAGS);
        }
        next_level
    } else {
        // SAFETY: the caller supplied a live scalar output.
        unsafe { new_table.write(0) };
        entry & PAGE_MASK
    }
}

/// Stamp one leaf PTE.
///
/// # Safety
/// `pte` points to a writable 512-entry table owned by this task.
pub unsafe fn map_table_entry(pte: *mut u64, uva: u64, phys_page: u64, flags: u64) {
    let index = ((uva >> PAGE_SHIFT) & (ENTRIES_PER_TABLE - 1)) as usize;
    // SAFETY: the masked index is in bounds and the task owns this leaf slot.
    unsafe { pte.add(index).write(phys_page | flags) };
}

unsafe fn rollback_map_tables(
    task: *mut TaskStruct,
    first_new: i32,
    pgd_was_fresh: bool,
    services: &Services,
) {
    // SAFETY: forwarded task ownership contract.
    let mut index = unsafe { task_kp_count(task) } - 1;
    while index >= first_new {
        // SAFETY: the loop spans only registered table pages owned by this call.
        let slot = unsafe { kernel_page_ptr(task, index as usize) };
        // SAFETY: the registered PA is relinquished before its slot is cleared.
        unsafe {
            (services.free_page)(slot.read());
            slot.write(0);
        }
        index -= 1;
    }
    if pgd_was_fresh {
        // SAFETY: only a PGD allocated by this call is reset here.
        unsafe { pgd_ptr(task).write(0) };
    }
}

/// Map `phys_page` at `uva`, allocating intermediate tables as needed.
///
/// Returns 0 on success and -1 on slot exhaustion or allocator OOM. Any
/// intermediate tables allocated by a failing call are rolled back.
///
/// # Safety
/// `task` is live and exclusively owns its mm mutations. `phys_page` is an
/// exclusive page which the caller retains until this function succeeds.
pub unsafe fn map_page(
    task: *mut TaskStruct,
    uva: u64,
    phys_page: u64,
    flags: u64,
    services: &Services,
) -> i32 {
    // SAFETY: the caller owns the task's mm.
    let first_new = unsafe { task_kp_count(task) };
    // SAFETY: same live task field.
    let pgd_was_fresh = unsafe { pgd_ptr(task).read() == 0 };

    if pgd_was_fresh {
        if first_new == MAX_PAGE_COUNT as i32 {
            return -1;
        }
        // SAFETY: allocator exclusion is part of the caller's contract.
        let new_pgd = unsafe { (services.get_free_page)() };
        if new_pgd == 0 {
            return -1;
        }
        // SAFETY: publish the fresh, zeroed PGD and register its ownership.
        unsafe {
            pgd_ptr(task).write(new_pgd);
            kernel_page_ptr(task, first_new as usize).write(new_pgd);
        }
    }

    // SAFETY: the PGD is nonzero after the branch above.
    let pgd = unsafe { pgd_ptr(task).read() };
    let mut new_table = 0i32;

    // SAFETY: every table PA came from the allocator and is high-half mapped.
    let pud = unsafe {
        map_table(
            pa_to_kva(pgd) as *mut u64,
            PGD_SHIFT as u64,
            uva,
            &mut new_table,
            services,
        )
    };
    if pud == 0 {
        // SAFETY: rolls back only pages registered by this invocation.
        unsafe { rollback_map_tables(task, first_new, pgd_was_fresh, services) };
        return -1;
    }
    if new_table != 0 {
        // SAFETY: task ownership is unchanged.
        let count = unsafe { task_kp_count(task) };
        if count == MAX_PAGE_COUNT as i32 {
            // SAFETY: preserve the source rollback order for this unregistered
            // table page, then release every table registered by this call.
            unsafe {
                (services.free_page)(pud);
                rollback_map_tables(task, first_new, pgd_was_fresh, services);
            }
            return -1;
        }
        // SAFETY: count identifies the first free bookkeeping slot.
        unsafe { kernel_page_ptr(task, count as usize).write(pud) };
    }

    // SAFETY: `pud` identifies a live, high-half-mapped table page.
    let pmd = unsafe {
        map_table(
            pa_to_kva(pud) as *mut u64,
            PUD_SHIFT as u64,
            uva,
            &mut new_table,
            services,
        )
    };
    if pmd == 0 {
        // SAFETY: rolls back only pages registered by this invocation.
        unsafe { rollback_map_tables(task, first_new, pgd_was_fresh, services) };
        return -1;
    }
    if new_table != 0 {
        // SAFETY: task ownership is unchanged.
        let count = unsafe { task_kp_count(task) };
        if count == MAX_PAGE_COUNT as i32 {
            // SAFETY: same source-compatible unregistered-table rollback.
            unsafe {
                (services.free_page)(pmd);
                rollback_map_tables(task, first_new, pgd_was_fresh, services);
            }
            return -1;
        }
        // SAFETY: count identifies the first free bookkeeping slot.
        unsafe { kernel_page_ptr(task, count as usize).write(pmd) };
    }

    // SAFETY: `pmd` identifies a live, high-half-mapped table page.
    let pte = unsafe {
        map_table(
            pa_to_kva(pmd) as *mut u64,
            PMD_SHIFT as u64,
            uva,
            &mut new_table,
            services,
        )
    };
    if pte == 0 {
        // SAFETY: rolls back only pages registered by this invocation.
        unsafe { rollback_map_tables(task, first_new, pgd_was_fresh, services) };
        return -1;
    }
    if new_table != 0 {
        // SAFETY: task ownership is unchanged.
        let count = unsafe { task_kp_count(task) };
        if count == MAX_PAGE_COUNT as i32 {
            // SAFETY: same source-compatible unregistered-table rollback.
            unsafe {
                (services.free_page)(pte);
                rollback_map_tables(task, first_new, pgd_was_fresh, services);
            }
            return -1;
        }
        // SAFETY: count identifies the first free bookkeeping slot.
        unsafe { kernel_page_ptr(task, count as usize).write(pte) };
    }

    // SAFETY: `pte` is the live leaf table for this UVA.
    unsafe { map_table_entry(pa_to_kva(pte) as *mut u64, uva, phys_page, flags) };

    // SAFETY: task ownership is unchanged.
    let count = unsafe { task_up_count(task) };
    if count == MAX_PAGE_COUNT as i32 {
        return -1;
    }
    // SAFETY: count identifies the first free user-page record.
    unsafe {
        user_page_ptr(task, count as usize).write(UserPage {
            pa: phys_page,
            uva,
            flags,
        })
    };
    0
}

/// Allocate and map a user page, returning its kernel alias or zero on failure.
///
/// # Safety
/// Same task/exclusion contract as [`map_page`].
pub unsafe fn allocate_user_page(
    task: *mut TaskStruct,
    uva: u64,
    flags: u64,
    services: &Services,
) -> u64 {
    // SAFETY: allocator exclusion is part of the caller's contract.
    let phys_page = unsafe { (services.get_free_page)() };
    if phys_page == 0 {
        return 0;
    }
    // SAFETY: the fresh page remains exclusively owned until map succeeds.
    if unsafe { map_page(task, uva, phys_page, flags, services) } < 0 {
        // SAFETY: the failed map did not transfer ownership of the leaf page.
        unsafe { (services.free_page)(phys_page) };
        return 0;
    }
    pa_to_kva(phys_page)
}

/// Clone `current`'s mapped user pages into the unpublished child `dst`.
///
/// # Safety
/// Both pointers are live distinct tasks. Current TTBR0 maps `current`'s UVAs;
/// `dst` is unpublished and exclusively owned by the caller.
pub unsafe fn copy_virt_memory(
    dst: *mut TaskStruct,
    current: *mut TaskStruct,
    services: &Services,
) -> i32 {
    let mut index = 0usize;
    while index < MAX_PAGE_COUNT {
        // SAFETY: index is in bounds; copy the record before any callback.
        let page = unsafe { user_page_ptr(current, index).read() };
        if page.pa != 0 {
            // SAFETY: destination is unpublished and exclusively owned.
            let kva = unsafe { allocate_user_page(dst, page.uva, page.flags, services) };
            if kva == 0 {
                return -1;
            }
            // SAFETY: `kva` is the fresh child page; current TTBR0 maps `page.uva`.
            unsafe {
                (services.copy_memory)(kva as *mut c_void, page.uva as *const c_void, PAGE_SIZE)
            };
        }
        index += 1;
    }
    // SAFETY: both fields are live; the child inherits the parent's break.
    unsafe { brk_ptr(dst).write(brk_ptr(current).read()) };
    0
}

unsafe fn lookup_pte_slot(task: *mut TaskStruct, uva: u64) -> *mut u64 {
    // SAFETY: task ownership is the caller's contract.
    let pgd = unsafe { pgd_ptr(task).read() };
    if pgd == 0 {
        return core::ptr::null_mut();
    }

    let pgd_table = pa_to_kva(pgd) as *mut u64;
    let pgd_index = ((uva >> PGD_SHIFT) & (ENTRIES_PER_TABLE - 1)) as usize;
    // SAFETY: masked index is in the live PGD.
    let pgd_entry = unsafe { pgd_table.add(pgd_index).read() };
    if pgd_entry == 0 {
        return core::ptr::null_mut();
    }

    let pud_table = pa_to_kva(pgd_entry & PAGE_MASK) as *mut u64;
    let pud_index = ((uva >> PUD_SHIFT) & (ENTRIES_PER_TABLE - 1)) as usize;
    // SAFETY: descriptor names a live next-level table.
    let pud_entry = unsafe { pud_table.add(pud_index).read() };
    if pud_entry == 0 {
        return core::ptr::null_mut();
    }

    let pmd_table = pa_to_kva(pud_entry & PAGE_MASK) as *mut u64;
    let pmd_index = ((uva >> PMD_SHIFT) & (ENTRIES_PER_TABLE - 1)) as usize;
    // SAFETY: descriptor names a live next-level table.
    let pmd_entry = unsafe { pmd_table.add(pmd_index).read() };
    if pmd_entry == 0 {
        return core::ptr::null_mut();
    }

    let pte_table = pa_to_kva(pmd_entry & PAGE_MASK) as *mut u64;
    let pte_index = ((uva >> PAGE_SHIFT) & (ENTRIES_PER_TABLE - 1)) as usize;
    // SAFETY: masked index is in the live leaf table.
    unsafe { pte_table.add(pte_index) }
}

/// Free every user page in `[start_uva, end_uva)` and clear its PTE/record.
///
/// The caller must flush this task's TLB before user execution resumes.
///
/// # Safety
/// `task` is live and exclusively owns its mm mutations.
pub unsafe fn unmap_user_range(
    task: *mut TaskStruct,
    start_uva: u64,
    end_uva: u64,
    services: &Services,
) {
    if start_uva >= end_uva {
        return;
    }
    let mut index = 0usize;
    while index < MAX_PAGE_COUNT {
        // SAFETY: index is in bounds; copy before callbacks.
        let page = unsafe { user_page_ptr(task, index).read() };
        if page.pa != 0 && page.uva >= start_uva && page.uva < end_uva {
            // SAFETY: task owns the page-table walk.
            let slot = unsafe { lookup_pte_slot(task, page.uva) };
            if !slot.is_null() {
                // SAFETY: slot is the owning task's leaf descriptor.
                unsafe { slot.write(0) };
            }
            // SAFETY: clear bookkeeping after relinquishing the mapped PA.
            unsafe {
                (services.free_page)(page.pa);
                user_page_ptr(task, index).write(UserPage::default());
            }
        }
        index += 1;
    }
}

unsafe fn output_fault(services: &Services, prefix: *const u8, value: u64) {
    // SAFETY: every prefix passed here is a static NUL-terminated C string and
    // the retained output path does not retain pointers or re-enter this mm.
    unsafe {
        (services.output)(MU, prefix);
        (services.output_u64)(MU, value);
        (services.output)(MU, c"\n".as_ptr().cast());
    }
}

unsafe fn oom_zombie(far: u64, services: &Services) -> i32 {
    // SAFETY: fixed output and non-returning production exit contract.
    unsafe {
        output_fault(services, c"[KERN] OOM at 0x".as_ptr().cast(), far);
        (services.exit_process)();
    }
    -1
}

/// Handle an EL0 data abort.
///
/// Translation faults in legal heap/stack regions demand-allocate. Fatal
/// permission, guard, text, and wild-UVA faults print and zombie the task.
///
/// # Safety
/// `current` is the live active task and the service callbacks obey their
/// synchronous contracts. Production `exit_process` does not return.
pub unsafe fn do_data_abort(
    current: *mut TaskStruct,
    far: u64,
    esr: u64,
    services: &Services,
) -> i32 {
    let dfsc = esr & 0x3F;
    if (0xC..=0xF).contains(&dfsc) {
        // SAFETY: fixed output and active-task exit contract.
        unsafe {
            output_fault(services, c"[KERN] perm fault at 0x".as_ptr().cast(), far);
            (services.exit_process)();
        }
        return -1;
    }
    if !(0x4..=0x7).contains(&dfsc) {
        return -1;
    }

    let fault_uva = far & PAGE_MASK;
    let rw_nx = user::TD_USER_PAGE_FLAGS_DEFAULT | user::TD_USER_XN;
    // SAFETY: `current` is the active live task.
    let current_brk = unsafe { brk_ptr(current).read() };

    if fault_uva >= user::HEAP_BASE && fault_uva < current_brk {
        // SAFETY: allocator exclusion is part of the entry-path contract.
        let page = unsafe { (services.get_free_page)() };
        if page == 0 {
            // SAFETY: hard-fault OOM must zombie the active task.
            return unsafe { oom_zombie(far, services) };
        }
        // SAFETY: the fresh page remains owned until mapping succeeds.
        if unsafe { map_page(current, fault_uva, page, rw_nx, services) } < 0 {
            // SAFETY: mapping failure leaves the leaf page with this caller.
            unsafe { (services.free_page)(page) };
            // SAFETY: hard-fault OOM must zombie the active task.
            return unsafe { oom_zombie(far, services) };
        }
        return 0;
    }

    if (user::STACK_LOW..user::STACK_TOP).contains(&fault_uva) {
        // SAFETY: allocator exclusion is part of the entry-path contract.
        let page = unsafe { (services.get_free_page)() };
        if page == 0 {
            // SAFETY: hard-fault OOM must zombie the active task.
            return unsafe { oom_zombie(far, services) };
        }
        // SAFETY: the fresh page remains owned until mapping succeeds.
        if unsafe { map_page(current, fault_uva, page, rw_nx, services) } < 0 {
            // SAFETY: mapping failure leaves the leaf page with this caller.
            unsafe { (services.free_page)(page) };
            // SAFETY: hard-fault OOM must zombie the active task.
            return unsafe { oom_zombie(far, services) };
        }
        return 0;
    }

    let prefix = if (user::STACK_GUARD_LOW..user::STACK_GUARD_HIGH).contains(&fault_uva) {
        c"[KERN] stack overflow at 0x".as_ptr().cast()
    } else if (user::TEXT_BASE..user::DATA_BASE).contains(&fault_uva) {
        c"[KERN] text fault at 0x".as_ptr().cast()
    } else {
        c"[KERN] invalid uva at 0x".as_ptr().cast()
    };
    // SAFETY: fixed output and active-task exit contract.
    unsafe {
        output_fault(services, prefix, far);
        (services.exit_process)();
    }
    -1
}

/// Handle any EL0 instruction abort by printing and zombifying the task.
///
/// # Safety
/// Same service/exit contract as [`do_data_abort`].
pub unsafe fn do_instruction_abort(far: u64, _esr: u64, services: &Services) -> i32 {
    // SAFETY: fixed output and active-task exit contract.
    unsafe {
        output_fault(services, c"[KERN] exec fault at 0x".as_ptr().cast(), far);
        (services.exit_process)();
    }
    -1
}

/// Catch any other EL0 synchronous exception, printing its EC and ELR.
///
/// # Safety
/// Same service/exit contract as [`do_data_abort`].
pub unsafe fn do_el0_sync_fault(esr: u64, elr: u64, services: &Services) -> i32 {
    let ec = (esr >> 26) & 0x3F;
    // SAFETY: every output pointer is a static NUL-terminated string.
    unsafe {
        (services.output)(MU, c"[KERN] el0 sync fault ec=0x".as_ptr().cast());
        (services.output_u64)(MU, ec);
        (services.output)(MU, c" at 0x".as_ptr().cast());
        (services.output_u64)(MU, elr);
        (services.output)(MU, c"\n".as_ptr().cast());
        (services.exit_process)();
    }
    -1
}

unsafe fn soft_demand_alloc(current: *mut TaskStruct, fault_uva: u64, services: &Services) -> i32 {
    let rw_nx = user::TD_USER_PAGE_FLAGS_DEFAULT | user::TD_USER_XN;
    // SAFETY: `current` is the active live task.
    let current_brk = unsafe { brk_ptr(current).read() };
    let legal = (user::HEAP_BASE..current_brk).contains(&fault_uva)
        || (user::STACK_LOW..user::STACK_TOP).contains(&fault_uva);
    if !legal {
        return -1;
    }

    // SAFETY: allocator exclusion is part of the caller's contract.
    let page = unsafe { (services.get_free_page)() };
    if page == 0 {
        return -1;
    }
    // SAFETY: the fresh page remains owned until mapping succeeds.
    if unsafe { map_page(current, fault_uva, page, rw_nx, services) } < 0 {
        // SAFETY: mapping failure leaves the leaf page with this caller.
        unsafe { (services.free_page)(page) };
        return -1;
    }
    0
}

/// Prefault every page in `[uva, uva + len)` for a soft copy-user operation.
///
/// Invalid/wrapping ranges and allocation failures return -1 without calling
/// `exit_process`.
///
/// # Safety
/// `current` is the live active task and its TTBR0 is installed when this
/// function returns to a copy operation.
pub unsafe fn check_and_prefault_user_range(
    current: *mut TaskStruct,
    uva: u64,
    len: u64,
    services: &Services,
) -> i32 {
    let Some(end_exclusive) = uva.checked_add(len) else {
        return -1;
    };
    if end_exclusive > user::STACK_TOP {
        return -1;
    }
    if len == 0 {
        return 0;
    }

    let mut page_uva = uva & PAGE_MASK;
    let end_page = (end_exclusive - 1) & PAGE_MASK;
    while page_uva <= end_page {
        let mut mapped = false;
        let mut index = 0usize;
        while index < MAX_PAGE_COUNT {
            // SAFETY: index is in bounds and the active task owns the mm.
            let page = unsafe { user_page_ptr(current, index).read() };
            if page.pa != 0 && page.uva == page_uva {
                mapped = true;
                break;
            }
            index += 1;
        }
        if !mapped {
            // SAFETY: forwarded active-task/service contract.
            if unsafe { soft_demand_alloc(current, page_uva, services) } < 0 {
                return -1;
            }
        }
        if page_uva == end_page {
            break;
        }
        page_uva += PAGE_SIZE;
    }
    0
}

/// Copy from current user VA into a kernel buffer.
///
/// # Safety
/// `kernel_buffer` is writable for `len`; `current` and the callbacks satisfy
/// [`check_and_prefault_user_range`]'s contract.
pub unsafe fn copy_from_user(
    current: *mut TaskStruct,
    kernel_buffer: *mut u8,
    uva: u64,
    len: u64,
    services: &Services,
) -> i32 {
    // SAFETY: forwarded active-task/service contract.
    if unsafe { check_and_prefault_user_range(current, uva, len, services) } < 0 {
        return -1;
    }
    // SAFETY: prefault proved the user range; caller supplied the kernel range.
    unsafe { (services.copy_memory)(kernel_buffer.cast(), uva as *const c_void, len) };
    0
}

/// Copy from a kernel buffer into current user VA.
///
/// # Safety
/// `kernel_buffer` is readable for `len`; otherwise the same contract as
/// [`copy_from_user`] applies.
pub unsafe fn copy_to_user(
    current: *mut TaskStruct,
    uva: u64,
    kernel_buffer: *const u8,
    len: u64,
    services: &Services,
) -> i32 {
    // SAFETY: forwarded active-task/service contract.
    if unsafe { check_and_prefault_user_range(current, uva, len, services) } < 0 {
        return -1;
    }
    // SAFETY: prefault proved the user range; caller supplied the kernel range.
    unsafe { (services.copy_memory)(uva as *mut c_void, kernel_buffer.cast(), len) };
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::{
        cell::UnsafeCell,
        sync::atomic::{AtomicBool, Ordering},
    };
    use std::sync::{Mutex, MutexGuard};

    const FAKE_MEMORY_SIZE: usize = 1024 * 1024;
    const FAKE_PAGE_COUNT: usize = FAKE_MEMORY_SIZE / PAGE_SIZE as usize;

    struct TestGlobal<T>(UnsafeCell<T>);

    // SAFETY: every test serializes access through TEST_LOCK.
    unsafe impl<T> Sync for TestGlobal<T> {}

    #[repr(align(4096))]
    struct AlignedMemory([u8; FAKE_MEMORY_SIZE]);

    static FAKE_MEMORY: TestGlobal<AlignedMemory> =
        TestGlobal(UnsafeCell::new(AlignedMemory([0; FAKE_MEMORY_SIZE])));
    static NEXT_FREE_PAGE: TestGlobal<usize> = TestGlobal(UnsafeCell::new(0));
    static EXIT_CALLED: AtomicBool = AtomicBool::new(false);
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    unsafe extern "C" fn fake_get_free_page() -> u64 {
        let next = NEXT_FREE_PAGE.0.get();
        // SAFETY: TEST_LOCK serializes this fake allocator.
        let offset = unsafe { next.read() };
        if offset + PAGE_SIZE as usize > FAKE_MEMORY_SIZE {
            return 0;
        }
        // SAFETY: the aligned object is static and the selected page is in bounds.
        let base = unsafe {
            core::ptr::addr_of_mut!((*FAKE_MEMORY.0.get()).0)
                .cast::<u8>()
                .add(offset)
        };
        assert_eq!(base as usize % PAGE_SIZE as usize, 0);
        // SAFETY: this page is the newly claimed fake allocation.
        unsafe {
            base.write_bytes(0, PAGE_SIZE as usize);
            next.write(offset + PAGE_SIZE as usize);
        }
        base as u64
    }

    unsafe extern "C" fn fake_free_page(_: u64) {}

    unsafe extern "C" fn fake_copy_memory(
        dst: *mut c_void,
        src: *const c_void,
        bytes: u64,
    ) -> *mut c_void {
        // SAFETY: callers supply disjoint readable/writable spans.
        unsafe {
            core::ptr::copy_nonoverlapping(src.cast::<u8>(), dst.cast::<u8>(), bytes as usize)
        };
        dst
    }

    unsafe extern "C" fn fake_output(_: i32, _: *const u8) {}
    unsafe extern "C" fn fake_output_u64(_: i32, _: u64) {}
    unsafe extern "C" fn fake_exit_process() {
        EXIT_CALLED.store(true, Ordering::SeqCst);
    }

    const SERVICES: Services = Services {
        get_free_page: fake_get_free_page,
        free_page: fake_free_page,
        copy_memory: fake_copy_memory,
        output: fake_output,
        output_u64: fake_output_u64,
        exit_process: fake_exit_process,
    };

    fn lock() -> MutexGuard<'static, ()> {
        TEST_LOCK
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    unsafe fn reset_fake_memory() {
        // SAFETY: TEST_LOCK serializes both globals.
        unsafe {
            NEXT_FREE_PAGE.0.get().write(0);
            core::ptr::addr_of_mut!((*FAKE_MEMORY.0.get()).0)
                .cast::<u8>()
                .write_bytes(0, FAKE_MEMORY_SIZE);
        }
        EXIT_CALLED.store(false, Ordering::SeqCst);
    }

    fn zero_task() -> TaskStruct {
        // SAFETY: every TaskStruct field accepts an all-zero representation.
        unsafe { core::mem::zeroed() }
    }

    #[test]
    fn task_counts_on_empty_task() {
        let _guard = lock();
        let mut task = zero_task();
        // SAFETY: the local task is exclusively owned.
        assert_eq!(unsafe { task_kp_count(&mut task) }, 0);
        // SAFETY: same local ownership.
        assert_eq!(unsafe { task_up_count(&mut task) }, 0);
    }

    #[test]
    fn map_page_allocates_tables() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        let mut task = zero_task();
        let uva = 0x1000;
        let pa = 0xDEAD_0000;
        let flags = 0x7;

        // SAFETY: local task and serialized fake services.
        assert_eq!(unsafe { map_page(&mut task, uva, pa, flags, &SERVICES) }, 0);
        assert_ne!(task.mm.pgd, 0);
        // SAFETY: local task is exclusively owned.
        assert_eq!(unsafe { task_kp_count(&mut task) }, 4);
        // SAFETY: local task is exclusively owned.
        assert_eq!(unsafe { task_up_count(&mut task) }, 1);
        assert_eq!(task.mm.user_pages[0].pa, pa);
        assert_eq!(task.mm.user_pages[0].uva, uva);
        assert_eq!(task.mm.user_pages[0].flags, flags);
    }

    #[test]
    fn lookup_pte_slot_finds_mapped_page() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        let mut task = zero_task();
        let uva = 0x2000;
        let pa = 0xBEEF_0000;
        // SAFETY: local task and serialized fake services.
        let _ = unsafe { map_page(&mut task, uva, pa, 0x7, &SERVICES) };

        // SAFETY: local task owns the table walk.
        let slot = unsafe { lookup_pte_slot(&mut task, uva) };
        assert!(!slot.is_null());
        // SAFETY: non-null slot belongs to the live leaf table.
        assert_eq!(unsafe { slot.read() }, pa | 0x7);

        // SAFETY: same local table ownership.
        let unmapped = unsafe { lookup_pte_slot(&mut task, 0x3000) };
        assert!(!unmapped.is_null());
        // SAFETY: non-null slot belongs to the live leaf table.
        assert_eq!(unsafe { unmapped.read() }, 0);

        // SAFETY: same local table ownership.
        assert!(unsafe { lookup_pte_slot(&mut task, 0x1_000_000_000) }.is_null());
    }

    #[test]
    fn unmap_user_range_clears_entries() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        let mut task = zero_task();
        // SAFETY: local task and serialized fake services.
        unsafe {
            let _ = map_page(&mut task, 0x1000, 0x10000, 0x7, &SERVICES);
            let _ = map_page(&mut task, 0x2000, 0x20000, 0x7, &SERVICES);
            let _ = map_page(&mut task, 0x3000, 0x30000, 0x7, &SERVICES);
            unmap_user_range(&mut task, 0x1500, 0x2500, &SERVICES);
        }

        assert_eq!(task.mm.user_pages[1].pa, 0);
        assert_ne!(task.mm.user_pages[0].pa, 0);
        assert_ne!(task.mm.user_pages[2].pa, 0);
        // SAFETY: local task owns the table walk.
        let slot = unsafe { lookup_pte_slot(&mut task, 0x2000) };
        assert!(!slot.is_null());
        // SAFETY: non-null slot belongs to the live leaf table.
        assert_eq!(unsafe { slot.read() }, 0);
    }

    #[test]
    fn data_abort_maps_heap() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        let mut task = zero_task();
        task.mm.brk = user::HEAP_BASE + 0x2000;
        let fault_uva = user::HEAP_BASE + 0x1000;
        let esr = 0x9200_0004;

        // SAFETY: local current task and serialized fake services.
        assert_eq!(
            unsafe { do_data_abort(&mut task, fault_uva, esr, &SERVICES) },
            0
        );
        // SAFETY: local task is exclusively owned.
        assert_eq!(unsafe { task_up_count(&mut task) }, 1);
        assert_eq!(task.mm.user_pages[0].uva, fault_uva);
    }

    #[test]
    fn prefault_user_range_maps_every_page() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        let mut task = zero_task();
        task.mm.brk = user::HEAP_BASE + 0x3000;

        // SAFETY: local current task and serialized fake services.
        assert_eq!(
            unsafe {
                check_and_prefault_user_range(&mut task, user::HEAP_BASE + 0x500, 0x2000, &SERVICES)
            },
            0
        );
        // SAFETY: local task is exclusively owned.
        assert_eq!(unsafe { task_up_count(&mut task) }, 3);
    }

    #[test]
    fn prefault_wild_uva_is_soft_failure() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        let mut task = zero_task();
        task.mm.brk = user::HEAP_BASE + 0x1000;

        // SAFETY: local current task and serialized fake services.
        assert_eq!(
            unsafe { check_and_prefault_user_range(&mut task, 0xDEAD_BEEF_000, 1, &SERVICES) },
            -1
        );
        assert!(!EXIT_CALLED.load(Ordering::SeqCst));
        // SAFETY: local task is exclusively owned.
        assert_eq!(unsafe { task_up_count(&mut task) }, 0);
    }

    #[test]
    fn map_page_rolls_back_tables_on_mid_walk_oom() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        for _ in 0..(FAKE_PAGE_COUNT - 1) {
            // SAFETY: serialized fake allocator.
            let _ = unsafe { fake_get_free_page() };
        }
        let mut task = zero_task();

        // SAFETY: local task and serialized fake services.
        assert_eq!(
            unsafe { map_page(&mut task, 0x1000, 0xDEAD_0000, 0x7, &SERVICES) },
            -1
        );
        // SAFETY: local task is exclusively owned.
        assert_eq!(unsafe { task_kp_count(&mut task) }, 0);
        assert_eq!(task.mm.pgd, 0);
        // SAFETY: local task is exclusively owned.
        assert_eq!(unsafe { task_up_count(&mut task) }, 0);
    }

    #[test]
    fn map_page_returns_failure_when_pgd_allocation_ooms() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        for _ in 0..FAKE_PAGE_COUNT {
            // SAFETY: serialized fake allocator.
            let _ = unsafe { fake_get_free_page() };
        }
        let mut task = zero_task();

        // SAFETY: local task and serialized fake services.
        assert_eq!(
            unsafe { map_page(&mut task, 0x1000, 0xDEAD_0000, 0x7, &SERVICES) },
            -1
        );
        assert_eq!(task.mm.pgd, 0);
        // SAFETY: local task is exclusively owned.
        assert_eq!(unsafe { task_kp_count(&mut task) }, 0);
    }

    #[test]
    fn allocate_user_page_returns_zero_on_oom() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        for _ in 0..FAKE_PAGE_COUNT {
            // SAFETY: serialized fake allocator.
            let _ = unsafe { fake_get_free_page() };
        }
        let mut task = zero_task();

        // SAFETY: local task and serialized fake services.
        assert_eq!(
            unsafe { allocate_user_page(&mut task, 0x1000, 0x7, &SERVICES) },
            0
        );
    }

    #[test]
    fn soft_demand_allocation_oom_does_not_exit() {
        let _guard = lock();
        // SAFETY: the test lock serializes the fake allocator.
        unsafe { reset_fake_memory() };
        let mut task = zero_task();
        task.mm.brk = user::HEAP_BASE + 0x2000;
        for _ in 0..FAKE_PAGE_COUNT {
            // SAFETY: serialized fake allocator.
            let _ = unsafe { fake_get_free_page() };
        }

        // SAFETY: local current task and serialized fake services.
        assert_eq!(
            unsafe {
                check_and_prefault_user_range(&mut task, user::HEAP_BASE + 0x500, 1, &SERVICES)
            },
            -1
        );
        assert!(!EXIT_CALLED.load(Ordering::SeqCst));
        // SAFETY: local task is exclusively owned.
        assert_eq!(unsafe { task_up_count(&mut task) }, 0);
    }
}
