//! Process cloning and move-to-user ELF setup.
//!
//! Fork builds an unpublished child under preemption exclusion, including its
//! dedicated kernel stack, user address space, file descriptors, cwd, and
//! credentials. The same module installs ELF images for boot and execve, then
//! switches TTBR0 only after every page is populated through its kernel alias.

use crate::{elf, execve::ArgvBlock, fdtable};
use core::ptr::{addr_of, addr_of_mut};
use flashos_abi::{
    task::{CoreContext, KTHREAD, TASK_RUNNING, THREAD_SIZE},
    user::{TD_USER_PAGE_FLAGS_DEFAULT, TD_USER_XN},
};
use flashsdk_abi::user::{HEAP_BASE, PAGE_SIZE, STACK_TOP};

pub use flashos_abi::task::{KeRegs, TaskStruct};

use crate::sched::NR_TASKS;

const SPSR_EL1_MODE_EL0T: u64 = 0;

#[cfg(target_os = "none")]
const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;
#[cfg(not(target_os = "none"))]
const LINEAR_MAP_BASE: u64 = 0;

#[cfg(target_os = "none")]
mod seam {
    use super::{TaskStruct, NR_TASKS};
    use core::ptr::{addr_of, addr_of_mut};

    unsafe extern "C" {
        static mut current: *mut TaskStruct;
        static mut task: [*mut TaskStruct; NR_TASKS];
        static mut nr_tasks: i32;
        static mut next_pid: i32;

        fn get_kernel_page() -> u64;
        fn free_kernel_page(page: u64);
        fn release_user_mm(task: *mut TaskStruct);
        fn allocate_user_page(task: *mut TaskStruct, uva: u64, flags: u64) -> u64;
        fn copy_virt_memory(task: *mut TaskStruct) -> i32;
        fn preempt_disable();
        fn preempt_enable();
        fn ret_from_fork();
        fn set_pgd(pgd: u64);
        #[cfg(feature = "verbose-fork")]
        fn main_output(interface: i32, string: *const u8);
        #[cfg(feature = "verbose-fork")]
        fn main_output_u64(interface: i32, value: u64);
        #[cfg(feature = "verbose-fork")]
        fn main_output_char(interface: i32, byte: u8);
    }

    #[inline]
    pub unsafe fn current_task() -> *mut TaskStruct {
        // SAFETY: scheduler writes are serialized and the caller holds the
        // process-model exclusion rule.
        unsafe { addr_of!(current).read() }
    }

    #[inline]
    pub unsafe fn task_at(index: usize) -> *mut TaskStruct {
        // SAFETY: caller proves the fixed table bound.
        unsafe { addr_of!(task).cast::<*mut TaskStruct>().add(index).read() }
    }

    #[inline]
    pub unsafe fn set_task_at(index: usize, value: *mut TaskStruct) {
        // SAFETY: caller proves the bound and holds preemption exclusion.
        unsafe {
            addr_of_mut!(task)
                .cast::<*mut TaskStruct>()
                .add(index)
                .write(value)
        };
    }

    #[inline]
    pub unsafe fn task_high_water() -> i32 {
        unsafe { addr_of!(nr_tasks).read() }
    }

    #[inline]
    pub unsafe fn set_task_high_water(value: i32) {
        unsafe { addr_of_mut!(nr_tasks).write(value) };
    }

    #[inline]
    pub unsafe fn take_pid() -> i32 {
        let pid = unsafe { addr_of!(next_pid).read() };
        unsafe { addr_of_mut!(next_pid).write(pid + 1) };
        pid
    }

    #[inline]
    pub unsafe fn allocate_task_page() -> u64 {
        unsafe { get_kernel_page() }
    }

    #[inline]
    pub unsafe fn free_task_page(page: u64) {
        unsafe { free_kernel_page(page) };
    }

    #[inline]
    pub unsafe fn release_mm(target: *mut TaskStruct) {
        unsafe { release_user_mm(target) };
    }

    #[inline]
    pub unsafe fn clone_mm(target: *mut TaskStruct) -> i32 {
        unsafe { copy_virt_memory(target) }
    }

    #[inline]
    pub unsafe fn allocate_page(target: *mut TaskStruct, uva: u64, flags: u64) -> u64 {
        unsafe { allocate_user_page(target, uva, flags) }
    }

    #[inline]
    pub unsafe fn disable_preemption() {
        unsafe { preempt_disable() };
    }

    #[inline]
    pub unsafe fn enable_preemption() {
        unsafe { preempt_enable() };
    }

    #[inline]
    pub fn fork_return_pc() -> u64 {
        ret_from_fork as *const () as usize as u64
    }

    #[inline]
    pub unsafe fn switch_pgd(pgd: u64) {
        unsafe { set_pgd(pgd) };
    }

    #[cfg(feature = "verbose-fork")]
    pub unsafe fn report_child(pid: i32, child: *mut TaskStruct) {
        unsafe { main_output(0, c"created pid ".as_ptr().cast()) };
        if pid < 10 {
            unsafe { main_output_char(0, (b'0' as i32 + pid) as u8) };
        } else {
            unsafe { main_output_char(0, (b'0' as i32 + pid / 10) as u8) };
            unsafe { main_output_char(0, (b'0' as i32 + pid % 10) as u8) };
        }
        unsafe { main_output(0, c" at ".as_ptr().cast()) };
        unsafe { main_output_u64(0, child as u64) };
        unsafe { main_output(0, c"\n".as_ptr().cast()) };
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    use super::{TaskStruct, NR_TASKS};
    use core::ptr::{addr_of, addr_of_mut, null_mut};

    #[repr(C, align(4096))]
    struct Page([u8; 4096]);

    static mut CURRENT: *mut TaskStruct = null_mut();
    static mut TASKS: [*mut TaskStruct; NR_TASKS] = [null_mut(); NR_TASKS];
    static mut NR_TASKS_HIGH: i32 = 0;
    static mut NEXT_PID: i32 = 1;
    static mut PAGES: [Page; 256] = [const { Page([0; 4096]) }; 256];
    static mut PAGE_INDEX: usize = 0;
    static mut FAIL_CLONE_MM: bool = false;

    pub unsafe fn current_task() -> *mut TaskStruct {
        unsafe { addr_of!(CURRENT).read() }
    }

    pub unsafe fn task_at(index: usize) -> *mut TaskStruct {
        unsafe { addr_of!(TASKS).cast::<*mut TaskStruct>().add(index).read() }
    }

    pub unsafe fn set_task_at(index: usize, value: *mut TaskStruct) {
        unsafe {
            addr_of_mut!(TASKS)
                .cast::<*mut TaskStruct>()
                .add(index)
                .write(value)
        };
    }

    pub unsafe fn task_high_water() -> i32 {
        unsafe { addr_of!(NR_TASKS_HIGH).read() }
    }

    pub unsafe fn set_task_high_water(value: i32) {
        unsafe { addr_of_mut!(NR_TASKS_HIGH).write(value) };
    }

    pub unsafe fn take_pid() -> i32 {
        let pid = unsafe { addr_of!(NEXT_PID).read() };
        unsafe { addr_of_mut!(NEXT_PID).write(pid + 1) };
        pid
    }

    pub unsafe fn allocate_task_page() -> u64 {
        let index = unsafe { addr_of!(PAGE_INDEX).read() };
        if index == 256 {
            return 0;
        }
        unsafe { addr_of_mut!(PAGE_INDEX).write(index + 1) };
        let page = unsafe { addr_of_mut!(PAGES).cast::<Page>().add(index) };
        unsafe { page.cast::<u8>().write_bytes(0, 4096) };
        page as u64
    }

    pub unsafe fn free_task_page(_: u64) {}
    pub unsafe fn release_mm(_: *mut TaskStruct) {}

    pub unsafe fn clone_mm(_: *mut TaskStruct) -> i32 {
        -i32::from(unsafe { addr_of!(FAIL_CLONE_MM).read() })
    }

    pub unsafe fn allocate_page(_: *mut TaskStruct, _: u64, _: u64) -> u64 {
        unsafe { allocate_task_page() }
    }

    pub unsafe fn disable_preemption() {}
    pub unsafe fn enable_preemption() {}
    pub fn fork_return_pc() -> u64 {
        0
    }
    pub unsafe fn switch_pgd(_: u64) {}

    #[cfg(feature = "verbose-fork")]
    pub unsafe fn report_child(_: i32, _: *mut TaskStruct) {}

    #[cfg(test)]
    pub unsafe fn reset() {
        unsafe {
            addr_of_mut!(CURRENT).write(null_mut());
            addr_of_mut!(TASKS)
                .cast::<u8>()
                .write_bytes(0, core::mem::size_of_val(&*addr_of!(TASKS)));
            addr_of_mut!(NR_TASKS_HIGH).write(0);
            addr_of_mut!(NEXT_PID).write(1);
            addr_of_mut!(PAGE_INDEX).write(0);
            addr_of_mut!(FAIL_CLONE_MM).write(false);
        }
    }

    #[cfg(test)]
    pub unsafe fn set_current(task: *mut TaskStruct) {
        unsafe { addr_of_mut!(CURRENT).write(task) };
    }

    #[cfg(test)]
    pub unsafe fn fail_clone_mm(value: bool) {
        unsafe { addr_of_mut!(FAIL_CLONE_MM).write(value) };
    }
}

/// Resolve the exception frame at the top of a task's kernel-stack page.
///
/// # Safety
/// `task` points to a live task page; a nonzero `kstack` names a live dedicated
/// stack page.
pub unsafe fn task_ke_regs(task: *mut TaskStruct) -> *mut KeRegs {
    let kstack = unsafe { addr_of!((*task).kstack).read() };
    let base = if kstack == 0 { task as u64 } else { kstack };
    (base + THREAD_SIZE - core::mem::size_of::<KeRegs>() as u64) as *mut KeRegs
}

unsafe fn copy_ke_regs(destination: *mut KeRegs, source: *const KeRegs) {
    let mut index = 0usize;
    while index < 31 {
        let value = unsafe { addr_of!((*source).regs).cast::<u64>().add(index).read() };
        unsafe {
            addr_of_mut!((*destination).regs)
                .cast::<u64>()
                .add(index)
                .write(value)
        };
        index += 1;
    }
    unsafe {
        addr_of_mut!((*destination).sp).write(addr_of!((*source).sp).read());
        addr_of_mut!((*destination).elr).write(addr_of!((*source).elr).read());
        addr_of_mut!((*destination).pstate).write(addr_of!((*source).pstate).read());
    }
}

unsafe fn release_child(child: *mut TaskStruct) {
    unsafe { seam::release_mm(child) };
    let kstack = unsafe { addr_of!((*child).kstack).read() };
    if kstack != 0 {
        unsafe { seam::free_task_page(kstack) };
    }
    unsafe { seam::free_task_page(child as u64) };
}

/// Build and publish a kernel thread or a fork clone.
///
/// # Safety
/// Scheduler initialization has published a live current task. Allocator,
/// scheduler-global, and parent-task access obey the single-core exclusion
/// contract.
pub unsafe fn copy_process_impl(clone_flags: u64, fn_addr: u64, arg: u64) -> i32 {
    unsafe { seam::disable_preemption() };

    let task_page = unsafe { seam::allocate_task_page() };
    if task_page == 0 {
        unsafe { seam::enable_preemption() };
        return -1;
    }
    let child = task_page as *mut TaskStruct;

    let stack_page = unsafe { seam::allocate_task_page() };
    if stack_page == 0 {
        unsafe { seam::free_task_page(task_page) };
        unsafe { seam::enable_preemption() };
        return -1;
    }
    unsafe { addr_of_mut!((*child).kstack).write(stack_page) };

    let child_regs = unsafe { task_ke_regs(child) };
    unsafe {
        child_regs
            .cast::<u8>()
            .write_bytes(0, core::mem::size_of::<KeRegs>())
    };
    unsafe {
        addr_of_mut!((*child).core_context)
            .cast::<u8>()
            .write_bytes(0, core::mem::size_of::<CoreContext>())
    };

    let parent = unsafe { seam::current_task() };
    if clone_flags & KTHREAD != 0 {
        unsafe { addr_of_mut!((*child).core_context.x19).write(fn_addr | LINEAR_MAP_BASE) };
        unsafe { addr_of_mut!((*child).core_context.x20).write(arg) };
    } else {
        let parent_regs = unsafe { task_ke_regs(parent) };
        unsafe { copy_ke_regs(child_regs, parent_regs) };
        unsafe { addr_of_mut!((*child_regs).regs).cast::<u64>().write(0) };

        if unsafe { seam::clone_mm(child) } != 0 {
            unsafe { release_child(child) };
            unsafe { seam::enable_preemption() };
            return -1;
        }

        unsafe { fdtable::dup_all(parent, child) };
        unsafe {
            core::ptr::copy_nonoverlapping(
                addr_of!((*parent).cwd).cast::<u8>(),
                addr_of_mut!((*child).cwd).cast::<u8>(),
                core::mem::size_of_val(&(*parent).cwd),
            )
        };
        unsafe {
            addr_of_mut!((*child).uid).write(addr_of!((*parent).uid).read());
            addr_of_mut!((*child).gid).write(addr_of!((*parent).gid).read());
            addr_of_mut!((*child).euid).write(addr_of!((*parent).euid).read());
            addr_of_mut!((*child).egid).write(addr_of!((*parent).egid).read());
        }
    }

    let priority = unsafe { addr_of!((*parent).priority).read() };
    unsafe {
        addr_of_mut!((*child).flags).write(clone_flags);
        addr_of_mut!((*child).priority).write(priority);
        addr_of_mut!((*child).state).write(TASK_RUNNING);
        addr_of_mut!((*child).counter).write(priority / 2);
        addr_of_mut!((*child).preempt_count).write(1);
        addr_of_mut!((*child).parent).write(parent);
        addr_of_mut!((*child).core_context.lr).write(seam::fork_return_pc() | LINEAR_MAP_BASE);
        addr_of_mut!((*child).core_context.sp).write(child_regs as u64);
    }

    let mut slot = None;
    let mut index = 0usize;
    while index < NR_TASKS {
        if unsafe { seam::task_at(index) }.is_null() {
            slot = Some(index);
            break;
        }
        index += 1;
    }
    let Some(slot) = slot else {
        unsafe { release_child(child) };
        unsafe { seam::enable_preemption() };
        return -1;
    };

    let pid = unsafe { seam::take_pid() };
    unsafe { addr_of_mut!((*child).pid).write(pid) };
    unsafe { seam::set_task_at(slot, child) };
    if slot as i32 + 1 > unsafe { seam::task_high_water() } {
        unsafe { seam::set_task_high_water(slot as i32 + 1) };
    }

    #[cfg(feature = "verbose-fork")]
    unsafe {
        seam::report_child(pid, child)
    };

    unsafe { seam::enable_preemption() };
    pid
}

/// Load an ELF image into the current task without argv.
///
/// # Safety
/// `blob_addr_kva` names `blob_size` readable kernel bytes and the caller owns
/// replacement of the active task's address space.
pub unsafe fn prepare_move_to_user_elf(blob_addr_kva: u64, blob_size: u64) -> i32 {
    unsafe { prepare_move_to_user_elf_argv(blob_addr_kva, blob_size, None) }
}

unsafe fn prepare_move_to_user_elf_argv(
    blob_addr_kva: u64,
    blob_size: u64,
    argv_block: Option<ArgvBlock>,
) -> i32 {
    let Ok(blob_len) = usize::try_from(blob_size) else {
        return -1;
    };
    let blob = unsafe { core::slice::from_raw_parts(blob_addr_kva as *const u8, blob_len) };
    let Ok(header) = elf::parse_ehdr(blob) else {
        return -1;
    };

    let current = unsafe { seam::current_task() };
    let mut entry_mapped = false;
    let mut headers = elf::iterate_phdrs(blob, header);
    loop {
        let program = match headers.next_header() {
            Ok(Some(program)) => program,
            Ok(None) => break,
            Err(_) => return -1,
        };
        if program.p_type != elf::PT_LOAD {
            continue;
        }

        if header.e_entry >= program.p_vaddr
            && header.e_entry < program.p_vaddr + program.p_memsz
            && program.p_flags & elf::PF_X != 0
        {
            entry_mapped = true;
        }

        if program.p_vaddr & (PAGE_SIZE - 1) != 0 || program.p_memsz < program.p_filesz {
            return -1;
        }
        if program.p_memsz == 0 {
            continue;
        }

        let flags = if program.p_flags & elf::PF_X != 0 {
            TD_USER_PAGE_FLAGS_DEFAULT
        } else {
            TD_USER_PAGE_FLAGS_DEFAULT | TD_USER_XN
        };
        let pages = program.p_memsz.div_ceil(PAGE_SIZE);
        let mut index = 0u64;
        while index < pages {
            let user_address = program.p_vaddr + index * PAGE_SIZE;
            let kernel_address = unsafe { seam::allocate_page(current, user_address, flags) };
            if kernel_address == 0 {
                return -1;
            }

            let segment_offset = index * PAGE_SIZE;
            if segment_offset < program.p_filesz {
                let remaining = program.p_filesz - segment_offset;
                let bytes = remaining.min(PAGE_SIZE) as usize;
                let source = blob_addr_kva + program.p_offset + segment_offset;
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        source as *const u8,
                        kernel_address as *mut u8,
                        bytes,
                    )
                };
            }
            index += 1;
        }
    }

    if !entry_mapped {
        return -1;
    }

    let stack_user_address = STACK_TOP - PAGE_SIZE;
    let stack_kernel_address = unsafe {
        seam::allocate_page(
            current,
            stack_user_address,
            TD_USER_PAGE_FLAGS_DEFAULT | TD_USER_XN,
        )
    };
    if stack_kernel_address == 0 {
        return -1;
    }

    let registers = unsafe { task_ke_regs(current) };
    unsafe {
        registers
            .cast::<u8>()
            .write_bytes(0, core::mem::size_of::<KeRegs>())
    };
    unsafe {
        addr_of_mut!((*registers).elr).write(header.e_entry);
        addr_of_mut!((*registers).pstate).write(SPSR_EL1_MODE_EL0T);
    }

    if let Some(arguments) = argv_block {
        let destination = stack_kernel_address + (PAGE_SIZE - arguments.bytes_len as u64);
        unsafe {
            core::ptr::copy_nonoverlapping(
                arguments.bytes_ptr,
                destination as *mut u8,
                arguments.bytes_len,
            )
        };
        unsafe {
            addr_of_mut!((*registers).regs)
                .cast::<u64>()
                .write(arguments.argc);
            addr_of_mut!((*registers).regs)
                .cast::<u64>()
                .add(1)
                .write(arguments.argv_uva);
            addr_of_mut!((*registers).sp).write(arguments.sp);
        }
    } else {
        unsafe { addr_of_mut!((*registers).sp).write(STACK_TOP) };
    }

    unsafe { addr_of_mut!((*current).mm.brk).write(HEAP_BASE) };
    let pgd = unsafe { addr_of!((*current).mm.pgd).read() };
    unsafe { seam::switch_pgd(pgd) };
    0
}

/// Load an ELF image with the argv block produced by execve.
///
/// # Safety
/// A non-null `argv_block` points to one live `ArgvBlock`; its byte span and
/// the ELF blob remain readable for this synchronous call.
pub unsafe fn move_to_user_elf_argv(
    blob_addr_kva: u64,
    blob_size: u64,
    argv_block: *const ArgvBlock,
) -> i32 {
    let arguments = if argv_block.is_null() {
        None
    } else {
        Some(unsafe { argv_block.read() })
    };
    unsafe { prepare_move_to_user_elf_argv(blob_addr_kva, blob_size, arguments) }
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

    unsafe fn reset_with_parent(priority: i64) -> TaskStruct {
        unsafe { seam::reset() };
        let mut parent = TaskStruct {
            priority,
            ..TaskStruct::default()
        };
        unsafe { seam::set_current(&raw mut parent) };
        parent
    }

    #[test]
    fn copy_process_impl_creates_a_child() {
        let _guard = lock();
        let mut parent = unsafe { reset_with_parent(10) };
        unsafe { seam::set_current(&raw mut parent) };

        let child_pid = unsafe { copy_process_impl(0, 0, 0) };
        assert!(child_pid > 0);
        assert_eq!(unsafe { seam::task_high_water() }, 1);
        let child = unsafe { seam::task_at(0) };
        assert!(!child.is_null());
        assert_eq!(unsafe { addr_of!((*child).pid).read() }, child_pid);
        assert_eq!(unsafe { addr_of!((*child).priority).read() }, 10);
        assert_eq!(unsafe { addr_of!((*child).counter).read() }, 5);
    }

    #[test]
    fn task_ke_regs_uses_the_task_or_dedicated_stack_page() {
        let _guard = lock();
        let mut task = TaskStruct::default();

        let registers = unsafe { task_ke_regs(&raw mut task) };
        assert_eq!(
            registers as usize - (&raw const task) as usize,
            THREAD_SIZE as usize - core::mem::size_of::<KeRegs>()
        );

        #[repr(C, align(16))]
        struct Stack([u8; THREAD_SIZE as usize]);
        let mut stack = Stack([0; THREAD_SIZE as usize]);
        task.kstack = (&raw mut stack) as u64;
        let registers = unsafe { task_ke_regs(&raw mut task) };
        assert_eq!(
            registers as u64,
            (&raw mut stack) as u64 + THREAD_SIZE - core::mem::size_of::<KeRegs>() as u64
        );
    }

    #[test]
    fn copy_process_impl_returns_minus_one_when_the_task_page_ooms() {
        let _guard = lock();
        let mut parent = unsafe { reset_with_parent(10) };
        unsafe { seam::set_current(&raw mut parent) };
        for _ in 0..256 {
            assert_ne!(unsafe { seam::allocate_task_page() }, 0);
        }
        assert_eq!(unsafe { copy_process_impl(0, 0, 0) }, -1);
    }

    #[test]
    fn copy_process_impl_returns_minus_one_when_mm_clone_fails() {
        let _guard = lock();
        let mut parent = unsafe { reset_with_parent(10) };
        unsafe { seam::set_current(&raw mut parent) };
        unsafe { seam::fail_clone_mm(true) };
        assert_eq!(unsafe { copy_process_impl(0, 0, 0) }, -1);
        assert!(unsafe { seam::task_at(0) }.is_null());
    }

    #[test]
    fn copy_process_impl_returns_minus_one_when_all_slots_are_full() {
        let _guard = lock();
        let mut parent = unsafe { reset_with_parent(10) };
        unsafe { seam::set_current(&raw mut parent) };
        let mut dummy = TaskStruct::default();
        for index in 0..NR_TASKS {
            unsafe { seam::set_task_at(index, &raw mut dummy) };
        }
        assert_eq!(unsafe { copy_process_impl(0, 0, 0) }, -1);
    }
}
