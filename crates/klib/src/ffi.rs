//! The C-ABI seam between the remaining Flash kernel and the Rust modules.
//!
//! Every function here exists only because two languages currently share one
//! kernel image. Flash cannot see Rust slices, so each entry point takes an
//! explicit pointer/length pair, and each is re-wrapped on the Flash side into
//! the slice-shaped signature its callers already use. When a Flash caller ports,
//! its shim here goes with it; when the last one ports, this module is deleted.
//!
//! Rules for anything added here: `extern "C"`, `#[no_mangle]`, no panic may
//! cross the boundary, and no Rust type without a fixed representation.

use flashos_abi::syscall::{
    NR_SYSCALLS, SYS_AUTHENTICATE, SYS_BRK, SYS_CHDIR, SYS_CLOSE, SYS_CLOSE_CONSOLE,
    SYS_CONSOLE_INJECT, SYS_CPU_FREQ, SYS_CPU_TEMP, SYS_CREATE, SYS_DUMP_FREE, SYS_DUP2,
    SYS_EXECVE, SYS_EXIT, SYS_FORK, SYS_GETCWD, SYS_GETEGID, SYS_GETEUID, SYS_GETGID, SYS_GETUID,
    SYS_KILL, SYS_KLOG_READ, SYS_MEMTOTAL, SYS_MLOCK, SYS_MMAP, SYS_MSGGET, SYS_MUNLOCK,
    SYS_MUNMAP, SYS_OPEN_FILE, SYS_PASSWD, SYS_PIPE, SYS_READ, SYS_READDIR, SYS_REBOOT, SYS_RENAME,
    SYS_SBRK, SYS_SEEK, SYS_SEMGET, SYS_SETGID, SYS_SETUID, SYS_SET_CONSOLE_MODE, SYS_SHMGET,
    SYS_SOCKET, SYS_UNLINK, SYS_UPTIME, SYS_WAIT, SYS_WRITE,
};
use flashos_abi::task::KeRegs;
use flashos_kernel::{
    block_dev, console, execve, fat32_backend, fdtable, file, fork, generic_timer, hwrng,
    initramfs_backend, klog_ring, mailbox, mm_user, page_alloc, path, perm, pipe, sched, sdhci_cmd,
    sha256, shadow, sys, usb_descriptors, usb_tx_ring, utilc, vfs,
};

const NONE: usize = usize::MAX;

/// Resolve a USB descriptor. A null pointer means the endpoint should stall.
///
/// # Safety
/// `length` points to a writable `usize`.
#[no_mangle]
pub unsafe extern "C" fn fos_usb_get_descriptor(
    descriptor_type: u8,
    index: u8,
    length: *mut usize,
) -> *const u8 {
    match usb_descriptors::get_descriptor(descriptor_type, index) {
        Some(descriptor) => {
            unsafe { length.write(descriptor.len()) };
            descriptor.as_ptr()
        }
        None => {
            unsafe { length.write(0) };
            core::ptr::null()
        }
    }
}

/// Decode one eight-byte USB SETUP packet into the fixed output record.
///
/// # Safety
/// `raw` points to eight readable bytes and `output` to one writable, aligned
/// `Setup` record.
#[no_mangle]
pub unsafe extern "C" fn fos_usb_decode_setup(raw: *const u8, output: *mut usb_descriptors::Setup) {
    let mut bytes = [0; 8];
    unsafe { core::ptr::copy_nonoverlapping(raw, bytes.as_mut_ptr(), bytes.len()) };
    unsafe { output.write(usb_descriptors::decode_setup(bytes)) };
}

/// Enqueue one byte in the shared USB TX ring.
///
/// # Safety
/// `ring` points to the live, exclusively accessed 528-byte ring record.
#[no_mangle]
pub unsafe extern "C" fn fos_usb_tx_ring_push(ring: *mut usb_tx_ring::UsbTxRing, byte: u8) -> u8 {
    u8::from(unsafe { &mut *ring }.push(byte))
}

/// Copy queued bytes without consuming them.
///
/// # Safety
/// `ring` points to a live ring and `destination` to `destination_len`
/// writable bytes. The two regions do not overlap.
#[no_mangle]
pub unsafe extern "C" fn fos_usb_tx_ring_peek(
    ring: *const usb_tx_ring::UsbTxRing,
    destination: *mut u8,
    destination_len: usize,
) -> usize {
    let destination = unsafe { core::slice::from_raw_parts_mut(destination, destination_len) };
    unsafe { &*ring }.peek(destination)
}

/// Consume bytes already accepted by the hardware FIFO.
///
/// # Safety
/// `ring` satisfies [`fos_usb_tx_ring_push`]'s contract.
#[no_mangle]
pub unsafe extern "C" fn fos_usb_tx_ring_advance(ring: *mut usb_tx_ring::UsbTxRing, count: u64) {
    unsafe { &mut *ring }.advance(count);
}

/// Drop all queued bytes after reset or deconfiguration.
///
/// # Safety
/// `ring` satisfies [`fos_usb_tx_ring_push`]'s contract.
#[no_mangle]
pub unsafe extern "C" fn fos_usb_tx_ring_clear(ring: *mut usb_tx_ring::UsbTxRing) {
    unsafe { &mut *ring }.clear();
}

/// Offset-based representation of a parsed shadow entry. The slices all point
/// into the input line, so only their offsets and lengths cross the ABI.
#[derive(Clone, Copy)]
#[repr(C)]
pub struct FosShadowEntry {
    user_offset: usize,
    user_len: usize,
    iterations: u32,
    salt_offset: usize,
    salt_len: usize,
    hash_offset: usize,
    hash_len: usize,
}

unsafe extern "C" {
    fn memzero(start: u64, size: u64);
    fn get_sys_count() -> u64;
    fn get_sys_freq() -> u64;
    fn set_CNTP_CVAL(value: u64);
    fn setup_CNTP_CTL();
    static mut current: *mut mm_user::TaskStruct;
}

// ---- kernel console, byte movers, and the panic path ----
//
// The unmangled half of `flashos_kernel::utilc`. These names are what the
// remaining Flash modules, the retained assembly, and the compiler's own
// lowering of a struct copy all bind to, so they are spelled exactly as the
// kernel has always exported them.

/// Emit a NUL-terminated string on `interface`, teeing it into the kernel log.
///
/// # Safety
/// `string` is NUL-terminated and not retained past the call.
#[no_mangle]
pub unsafe extern "C" fn main_output(interface: i32, string: *const u8) {
    // SAFETY: forwarded NUL-termination contract.
    unsafe { utilc::main_output(interface, string) };
}

/// Emit one byte on `interface`.
///
/// # Safety
/// Called in kernel, syscall, or IRQ context.
#[no_mangle]
pub unsafe extern "C" fn main_output_char(interface: i32, byte: u8) {
    // SAFETY: the callee builds its own NUL-terminated pair.
    unsafe { utilc::main_output_char(interface, byte) };
}

/// Emit `value` as 16 hex chars on `interface`.
///
/// # Safety
/// Called in kernel, syscall, or IRQ context.
#[no_mangle]
pub unsafe extern "C" fn main_output_u64(interface: i32, value: u64) {
    // SAFETY: the callee owns its own render buffer.
    unsafe { utilc::main_output_u64(interface, value) };
}

/// Dump a task record's scheduler fields on `interface`.
///
/// # Safety
/// `task` points to a live `TaskStruct`.
#[no_mangle]
pub unsafe extern "C" fn main_output_process(interface: i32, task: *mut mm_user::TaskStruct) {
    // SAFETY: forwarded live-task contract.
    unsafe { utilc::main_output_process(interface, task) };
}

/// Read one byte from the console on `interface`.
///
/// # Safety
/// Called in kernel or syscall context.
#[no_mangle]
pub unsafe extern "C" fn main_recv(interface: i32) -> u8 {
    // SAFETY: the callee reads the driver's own MMIO.
    unsafe { utilc::main_recv(interface) }
}

/// Render `value` as 16 hex chars into `buf`. No NUL.
///
/// # Safety
/// `buf` is writable for 16 bytes.
#[no_mangle]
pub unsafe extern "C" fn u64_to_char_array(value: u64, buf: *mut u8) {
    // SAFETY: forwarded 16-byte writable contract.
    unsafe { utilc::u64_to_char_array(value, buf) };
}

/// # Safety
/// `buf` is writable for one byte.
#[no_mangle]
pub unsafe extern "C" fn char_to_char_array(byte: u8, buf: *mut u8) {
    // SAFETY: forwarded one-byte writable contract.
    unsafe { utilc::char_to_char_array(byte, buf) };
}

/// Copy a saved register frame.
///
/// # Safety
/// Both pointers reference live, non-overlapping `KeRegs`.
#[no_mangle]
pub unsafe extern "C" fn copy_ke_regs(to: *mut KeRegs, from: *mut KeRegs) {
    // SAFETY: forwarded live-frame contract.
    unsafe { utilc::copy_ke_regs(to, from) };
}

/// Byte-wise compare without alignment requirements.
///
/// # Safety
/// Both pointers are readable for `n` bytes.
#[no_mangle]
pub unsafe extern "C" fn mem_eql_bytes(a: *const u8, b: *const u8, n: u64) -> bool {
    // SAFETY: forwarded readable-span contract.
    unsafe { utilc::mem_eql_bytes(a, b, n) }
}

/// Fill `n` bytes at `dst` with the low byte of `value`.
///
/// The kernel's own `memset`. This strong definition is what the linker binds,
/// in preference to the weak one `compiler_builtins` carries.
///
/// # Safety
/// `dst` is writable for `n` bytes.
#[no_mangle]
pub unsafe extern "C" fn memset(dst: *mut u8, value: i32, n: u64) -> *mut u8 {
    // SAFETY: forwarded writable-span contract.
    unsafe { utilc::memset(dst, value, n) }
}

/// Byte-granular memory copy, with an 8-byte fast path when both sides are
/// already 8-aligned.
///
/// The kernel's own `memcpy`, and the reason the image never grows a wide-load
/// copy: `SCTLR_EL1.A` is asserted, and callers hand this odd addresses.
///
/// # Safety
/// `destination` is writable and `source` readable for `bytes`; the regions do
/// not overlap.
#[no_mangle]
pub unsafe extern "C" fn memcpy(
    destination: *mut core::ffi::c_void,
    source: *const core::ffi::c_void,
    bytes: u64,
) -> *mut core::ffi::c_void {
    // SAFETY: forwarded non-overlapping span contract.
    unsafe { utilc::memcpy(destination.cast::<u8>(), source.cast::<u8>(), bytes) };
    destination
}

/// Print the message and halt. The kernel's terminal error path.
///
/// # Safety
/// `msg` is NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn panic(msg: *const u8) -> ! {
    // SAFETY: forwarded NUL-termination contract.
    unsafe { utilc::panic(msg) }
}

// ---- architectural timer and entropy fallback ----

fn architectural_count() -> u64 {
    // SAFETY: reading CNTPCT_EL0 is side-effect-free in the kernel's EL1 context.
    unsafe { get_sys_count() }
}

/// Arm the generic timer from the current architectural count.
///
/// # Safety
/// Called once during single-core bring-up before the timer IRQ is enabled.
#[no_mangle]
pub unsafe extern "C" fn generic_timer_init() {
    unsafe { setup_CNTP_CTL() };
    // SAFETY: bring-up exclusively initializes the timer deadline.
    let deadline = unsafe { generic_timer::initialize(architectural_count) };
    unsafe { set_CNTP_CVAL(deadline) };
}

/// Advance and re-arm the generic timer after one interrupt.
///
/// # Safety
/// Called only by the serialized timer IRQ on the active core.
#[no_mangle]
pub unsafe extern "C" fn handle_generic_timer() {
    // SAFETY: the IRQ path exclusively mutates the deadline.
    let deadline = unsafe { generic_timer::advance(architectural_count) };
    unsafe { set_CNTP_CVAL(deadline) };
}

/// Return whole seconds elapsed according to the architectural counter.
///
/// # Safety
/// Called from serialized kernel code while architectural counter access is
/// available at EL1.
#[no_mangle]
pub unsafe extern "C" fn uptime_seconds() -> u64 {
    let frequency = unsafe { get_sys_freq() };
    if frequency == 0 {
        return 0;
    }
    generic_timer::uptime_seconds(architectural_count(), frequency)
}

/// Seed and self-test the timer-backed entropy fallback.
///
/// # Safety
/// Called once during single-core bring-up before PID 1 starts.
#[no_mangle]
pub unsafe extern "C" fn hwrng_init() -> i32 {
    // SAFETY: bring-up exclusively initializes the mixer.
    unsafe { hwrng::initialize(architectural_count) }
}

// ---- scheduler state and task lifecycle ----
//
// The four globals remain defined by the transitional Zig adapter so surviving
// Flash/Zig direct loads stay PC-relative in the high-half kernel. Function
// bodies live in crates/kernel; these facades preserve the historical assembly
// and mixed-language symbol surface.

/// Increment the active task's preemption nesting count.
///
/// # Safety
/// Scheduler initialization has published a live current task.
#[no_mangle]
pub unsafe extern "C" fn preempt_disable() {
    unsafe { sched::preempt_disable() };
}

/// Decrement the active task's preemption nesting count.
///
/// # Safety
/// Matches a preceding `preempt_disable` for the active task.
#[no_mangle]
pub unsafe extern "C" fn preempt_enable() {
    unsafe { sched::preempt_enable() };
}

/// Body reached by the retained patchable `_schedule` trampoline.
///
/// # Safety
/// Called only after scheduler initialization.
#[no_mangle]
pub unsafe extern "C" fn _schedule_impl() {
    unsafe { sched::schedule_impl() };
}

/// Yield the active task.
///
/// # Safety
/// Called only after scheduler initialization.
#[no_mangle]
pub unsafe extern "C" fn schedule() {
    unsafe { sched::schedule() };
}

/// Switch to a live published task.
///
/// # Safety
/// `next` is live and scheduling is serialized.
#[no_mangle]
pub unsafe extern "C" fn switch_to(next: *mut sched::TaskStruct) {
    unsafe { sched::switch_to(next) };
}

/// Account a timer tick from the serialized IRQ path.
///
/// # Safety
/// Scheduler initialization has completed.
#[no_mangle]
pub unsafe extern "C" fn timer_tick() {
    unsafe { sched::timer_tick() };
}

/// Zombie the active task and yield.
///
/// # Safety
/// Called by the active task from kernel context.
#[no_mangle]
pub unsafe extern "C" fn exit_process() {
    unsafe { sched::exit_process() };
}

/// Release all user and page-table pages owned by a child task.
///
/// # Safety
/// `child` is unpublished or a zombie exclusively owned by its reaper.
#[no_mangle]
pub unsafe extern "C" fn release_user_mm(child: *mut sched::TaskStruct) {
    unsafe { sched::release_user_mm(child) };
}

/// Body reached by the retained patchable `do_wait` trampoline.
///
/// # Safety
/// Called by the active task from serialized syscall context.
#[no_mangle]
pub unsafe extern "C" fn do_wait_impl() -> i32 {
    unsafe { sched::do_wait_impl() }
}

/// Publish the boot task during single-core bring-up.
///
/// # Safety
/// Called once before task creation.
#[no_mangle]
pub unsafe extern "C" fn sched_init() {
    unsafe { sched::sched_init() };
}

/// Mark a target task zombie and wake an interruptible parent.
///
/// # Safety
/// `target` is live and the caller holds preemption exclusion.
#[no_mangle]
pub unsafe extern "C" fn fos_sched_zombify_and_wake_parent(target: *mut sched::TaskStruct) {
    unsafe { sched::zombify_and_wake_parent(target) };
}

/// Replace the active task's user image through the path-resolved loader.
///
/// # Safety
/// `path_ptr` and nonzero `argv_ptr` are user virtual addresses owned by the
/// active task and follow the syscall's NUL-termination contracts.
#[no_mangle]
pub unsafe extern "C" fn execve_impl(path_ptr: u64, argv_ptr: u64) -> i32 {
    unsafe { execve::execve_impl(path_ptr, argv_ptr) }
}

/// Build and publish a kernel thread or user fork clone.
///
/// # Safety
/// Called from the retained process-creation assembly trampoline with a live
/// current task and serialized scheduler/allocator state.
#[no_mangle]
pub unsafe extern "C" fn copy_process_impl(clone_flags: u64, fn_addr: u64, arg: u64) -> i32 {
    unsafe { fork::copy_process_impl(clone_flags, fn_addr, arg) }
}

/// Resolve a task's exception frame at the top of its kernel-stack page.
///
/// # Safety
/// `task` points to a live task and any nonzero dedicated stack page is live.
#[no_mangle]
pub unsafe extern "C" fn task_ke_regs(task: *mut fork::TaskStruct) -> *mut fork::KeRegs {
    unsafe { fork::task_ke_regs(task) }
}

/// Install a boot ELF image without argv in the current task.
///
/// # Safety
/// The blob span is readable kernel memory and the caller owns current-mm
/// replacement.
#[no_mangle]
pub unsafe extern "C" fn prepare_move_to_user_elf(blob_addr_kva: u64, blob_size: u64) -> i32 {
    unsafe { fork::prepare_move_to_user_elf(blob_addr_kva, blob_size) }
}

const MM_USER_SERVICES: mm_user::Services = mm_user::Services {
    get_free_page,
    free_page,
    copy_memory: memcpy,
    output: main_output,
    output_u64: main_output_u64,
    exit_process,
};

/// Physical load address of the kernel, filled by `boot.S` before TTBR setup.
#[no_mangle]
pub static mut KERNEL_PA_BASE: u64 = 0;

/// # Safety
/// `task` points to a live task whose mm is not concurrently mutated.
#[no_mangle]
pub unsafe extern "C" fn task_kp_count(task: *mut mm_user::TaskStruct) -> i32 {
    unsafe { mm_user::task_kp_count(task) }
}

/// # Safety
/// Same contract as [`task_kp_count`].
#[no_mangle]
pub unsafe extern "C" fn task_up_count(task: *mut mm_user::TaskStruct) -> i32 {
    unsafe { mm_user::task_up_count(task) }
}

/// # Safety
/// `table` points to 512 live entries and `new_table` is writable.
#[no_mangle]
pub unsafe extern "C" fn map_table(
    table: *mut u64,
    shift: u64,
    uva: u64,
    new_table: *mut i32,
) -> u64 {
    unsafe { mm_user::map_table(table, shift, uva, new_table, &MM_USER_SERVICES) }
}

/// # Safety
/// `pte` points to a writable 512-entry table owned by the active task.
#[no_mangle]
pub unsafe extern "C" fn map_table_entry(pte: *mut u64, uva: u64, phys_page: u64, flags: u64) {
    unsafe { mm_user::map_table_entry(pte, uva, phys_page, flags) };
}

/// # Safety
/// `task` owns its mm and `phys_page` is exclusively owned by the caller until
/// the map succeeds.
#[no_mangle]
pub unsafe extern "C" fn map_page(
    task: *mut mm_user::TaskStruct,
    uva: u64,
    phys_page: u64,
    flags: u64,
) -> i32 {
    unsafe { mm_user::map_page(task, uva, phys_page, flags, &MM_USER_SERVICES) }
}

/// # Safety
/// `task` owns its mm and allocator access is serialized by kernel control flow.
#[no_mangle]
pub unsafe extern "C" fn allocate_user_page(
    task: *mut mm_user::TaskStruct,
    uva: u64,
    flags: u64,
) -> u64 {
    unsafe { mm_user::allocate_user_page(task, uva, flags, &MM_USER_SERVICES) }
}

/// # Safety
/// `dst` is an unpublished child and `current` remains the active parent.
#[no_mangle]
pub unsafe extern "C" fn copy_virt_memory(dst: *mut mm_user::TaskStruct) -> i32 {
    unsafe { mm_user::copy_virt_memory(dst, current, &MM_USER_SERVICES) }
}

/// # Safety
/// `task` owns its mm; the caller flushes its TLB before returning to EL0.
#[no_mangle]
pub unsafe extern "C" fn unmap_user_range(
    task: *mut mm_user::TaskStruct,
    start_uva: u64,
    end_uva: u64,
) {
    unsafe { mm_user::unmap_user_range(task, start_uva, end_uva, &MM_USER_SERVICES) };
}

/// Entry.S data-abort target. Fatal paths do not return in production.
///
/// # Safety
/// `current` must identify the active live task and exception entry must
/// serialize its mm and allocator access.
#[no_mangle]
pub unsafe extern "C" fn do_data_abort(far: u64, esr: u64) -> i32 {
    unsafe { mm_user::do_data_abort(current, far, esr, &MM_USER_SERVICES) }
}

/// Entry.S instruction-abort target. This does not return in production.
///
/// # Safety
/// Must be called only from the serialized EL0 exception path.
#[no_mangle]
pub unsafe extern "C" fn do_instruction_abort(far: u64, esr: u64) -> i32 {
    unsafe { mm_user::do_instruction_abort(far, esr, &MM_USER_SERVICES) }
}

/// Entry.S catch-all synchronous-fault target. This does not return in production.
///
/// # Safety
/// Must be called only from the serialized EL0 exception path.
#[no_mangle]
pub unsafe extern "C" fn do_el0_sync_fault(esr: u64, elr: u64) -> i32 {
    unsafe { mm_user::do_el0_sync_fault(esr, elr, &MM_USER_SERVICES) }
}

/// Soft-prefault a current-task user range without zombifying on failure.
///
/// # Safety
/// `current` must identify the active live task and the caller must serialize
/// its mm and allocator access.
#[no_mangle]
pub unsafe extern "C" fn check_and_prefault_user_range(uva: u64, len: u64) -> i32 {
    unsafe { mm_user::check_and_prefault_user_range(current, uva, len, &MM_USER_SERVICES) }
}

/// # Safety
/// `kernel_buffer` is writable for `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn copy_from_user(kernel_buffer: *mut u8, uva: u64, len: u64) -> i32 {
    unsafe { mm_user::copy_from_user(current, kernel_buffer, uva, len, &MM_USER_SERVICES) }
}

/// # Safety
/// `kernel_buffer` is readable for `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn copy_to_user(uva: u64, kernel_buffer: *mut u8, len: u64) -> i32 {
    unsafe { mm_user::copy_to_user(current, uva, kernel_buffer, len, &MM_USER_SERVICES) }
}

/// Reset the physical-page bitmap during single-core bring-up.
///
/// # Safety
/// Must run on core 0 before any allocator consumer becomes reachable.
#[no_mangle]
pub unsafe extern "C" fn mem_map_init() {
    // SAFETY: kernel bring-up calls this before any allocator consumer.
    unsafe { page_alloc::mem_map_init() };
}

/// Reserve allocator PAs occupied by the linked kernel image.
///
/// # Safety
/// Must follow bitmap initialization and precede runtime allocation.
#[no_mangle]
pub unsafe extern "C" fn mem_map_reserve_below(end_pa: u64) {
    // SAFETY: kernel bring-up calls this immediately after bitmap initialization.
    unsafe { page_alloc::mem_map_reserve_below(end_pa) };
}

/// Reserve allocator PAs outside the active board's RAM window.
///
/// # Safety
/// Must run during single-core bring-up before runtime allocation.
#[no_mangle]
pub unsafe extern "C" fn mem_map_reserve_above(start_pa: u64) {
    // SAFETY: kernel bring-up calls this before runtime allocation begins.
    unsafe { page_alloc::mem_map_reserve_above(start_pa) };
}

/// Allocate and zero one physical page, returning PA 0 on exhaustion.
///
/// # Safety
/// The caller must satisfy the kernel's single-core allocator exclusion.
#[no_mangle]
pub unsafe extern "C" fn get_free_page() -> u64 {
    // SAFETY: kernel callers serialize allocator access; assembly memzero accepts
    // the mapped exclusive page and does not retain it.
    unsafe { page_alloc::get_free_page(memzero) }
}

/// Return one physical page to the allocator.
///
/// # Safety
/// The caller relinquishes an allocator-owned PA and retains no live alias.
#[no_mangle]
pub unsafe extern "C" fn free_page(page: u64) {
    // SAFETY: the C ABI contract requires callers to relinquish the page here.
    unsafe { page_alloc::free_page(page) };
}

/// Allocate one page and return its high-half alias, or zero on exhaustion.
///
/// # Safety
/// The caller must satisfy the kernel's single-core allocator exclusion.
#[no_mangle]
pub unsafe extern "C" fn get_kernel_page() -> u64 {
    // SAFETY: same serialized allocation and memzero contract as get_free_page.
    unsafe { page_alloc::get_kernel_page(memzero) }
}

/// Return a high-half allocator page.
///
/// # Safety
/// The caller relinquishes a live allocator KVA and retains no live alias.
#[no_mangle]
pub unsafe extern "C" fn free_kernel_page(page: u64) {
    // SAFETY: the C ABI contract requires a live allocator KVA.
    unsafe { page_alloc::free_kernel_page(page) };
}

/// Print and return the current free-page count at a boot/test checkpoint.
///
/// # Safety
/// The caller must serialize the bitmap scan against allocator mutation.
#[no_mangle]
pub unsafe extern "C" fn dump_free_count() -> u64 {
    // SAFETY: checkpoint callers serialize the bitmap scan.
    let count = unsafe { page_alloc::free_count() };
    // SAFETY: fixed strings are NUL-terminated and the output functions do not
    // retain them or re-enter the allocator.
    unsafe {
        main_output(0, c"free_pages: ".as_ptr().cast());
        main_output_u64(0, count);
        main_output(0, c"\n".as_ptr().cast());
    }
    count
}

/// Return the post-reservation allocator pool size.
///
/// # Safety
/// Bring-up initialization and all reservations must already be complete.
#[no_mangle]
pub unsafe extern "C" fn mem_total_count() -> u64 {
    // SAFETY: runtime reads occur after boot reservations have completed.
    unsafe { page_alloc::mem_total_count() }
}

/// Allocate and zero one ABI-owned `File` record.
#[no_mangle]
pub extern "C" fn fos_file_alloc() -> *mut file::File {
    // SAFETY: the kernel's single-core allocator exclusion holds on this path.
    unsafe { file::alloc() }
}

/// Drop a file reference and free the page on the last one.
///
/// # Safety
/// `value` points to a live allocated `File` with at least one reference.
#[no_mangle]
pub unsafe extern "C" fn fos_file_unref(value: *mut file::File) {
    unsafe { file::unref(value) };
}

/// Add a file reference under the existing preemption exclusion.
///
/// # Safety
/// `value` points to a live allocated `File`.
#[no_mangle]
pub unsafe extern "C" fn fos_file_ref(value: *mut file::File) {
    unsafe { file::reference(value) };
}

/// Offset/length-only view of one parsed initramfs entry. No archive pointer is
/// embedded: the Flash root adapter derives the same high-half archive base and
/// reconstructs its borrowed slices from these integer spans.
#[repr(C)]
pub struct FosInitramfsEntry {
    name_offset: usize,
    name_len: usize,
    data_offset: usize,
    data_len: usize,
    mode: u32,
    uid: u32,
    gid: u32,
}

/// Locate one embedded CPIO entry: 1 = hit, 0 = miss, -1 = malformed archive.
///
/// # Safety
/// `path` is readable for `path_len`; `out` points to writable aligned storage.
#[no_mangle]
pub unsafe extern "C" fn fos_initramfs_locate(
    path: *const u8,
    path_len: usize,
    out: *mut FosInitramfsEntry,
) -> i32 {
    let path = unsafe { slice_from_raw(path, path_len) };
    let entry = match initramfs_backend::locate_production(path) {
        Ok(Some(entry)) => entry,
        Ok(None) => return 0,
        Err(_) => return -1,
    };
    let base = initramfs_backend::production_archive_base() as usize;
    unsafe {
        out.write(FosInitramfsEntry {
            name_offset: entry.name.as_ptr() as usize - base,
            name_len: entry.name.len(),
            data_offset: entry.data.as_ptr() as usize - base,
            data_len: entry.data.len(),
            mode: entry.mode,
            uid: entry.uid,
            gid: entry.gid,
        })
    };
    1
}

/// Wire the Rust-owned initramfs root backend during kernel bring-up.
#[no_mangle]
pub extern "C" fn fos_initramfs_backend_init() {
    // SAFETY: kernel.flash calls this exactly once during single-core bring-up.
    unsafe { initramfs_backend::init() };
}

/// # Safety
/// `ops` points to a live writable VFS vtable.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_relocate_ops(ops: *mut vfs::VfsOps) {
    unsafe { vfs::relocate_ops(ops) };
}

/// # Safety
/// `sb` lives for the kernel lifetime and registration occurs during bring-up.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_register_fat32(sb: *mut vfs::SuperBlock) {
    unsafe { vfs::register_fat32(sb) };
}

/// # Safety
/// Input/output pointers are valid for their declared spans.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_open(
    path: *const u8,
    path_len: usize,
    out: *mut vfs::OpenResult,
) -> *mut vfs::SuperBlock {
    let path = unsafe { slice_from_raw(path, path_len) };
    unsafe { vfs::open(path, out) }
}

/// # Safety
/// The superblock, file, and buffer satisfy the registered callback contract.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_read(
    sb: *mut vfs::SuperBlock,
    value: *mut file::File,
    buffer: *mut u8,
    len: u64,
) -> i64 {
    unsafe { vfs::read(sb, value, buffer, len) }
}

/// # Safety
/// `sb` and `value` are live registered records.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_seek(
    sb: *mut vfs::SuperBlock,
    value: *mut file::File,
    off: i64,
    whence: i32,
) -> i64 {
    unsafe { vfs::seek(sb, value, off, whence) }
}

/// # Safety
/// `sb` and `value` are live registered records.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_close(sb: *mut vfs::SuperBlock, value: *mut file::File) {
    unsafe { vfs::close(sb, value) };
}

/// # Safety
/// The superblock, file, and buffer satisfy the registered callback contract.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_write(
    sb: *mut vfs::SuperBlock,
    value: *mut file::File,
    buffer: *const u8,
    len: u64,
) -> i64 {
    unsafe { vfs::write(sb, value, buffer, len) }
}

/// # Safety
/// Input/output pointers are valid for their declared spans.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_readdir(
    path: *const u8,
    path_len: usize,
    index: u64,
    out: *mut vfs::Dirent,
) -> i32 {
    let path = unsafe { slice_from_raw(path, path_len) };
    unsafe { vfs::readdir(path, index, out) }
}

/// # Safety
/// Input/output pointers are valid for their declared spans.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_create(
    path: *const u8,
    path_len: usize,
    out: *mut vfs::OpenResult,
) -> *mut vfs::SuperBlock {
    let path = unsafe { slice_from_raw(path, path_len) };
    unsafe { vfs::create(path, out) }
}

/// # Safety
/// `path` is readable for `path_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_unlink(path: *const u8, path_len: usize) -> i32 {
    let path = unsafe { slice_from_raw(path, path_len) };
    unsafe { vfs::unlink(path) }
}

/// # Safety
/// Both input paths are readable for their declared lengths.
#[no_mangle]
pub unsafe extern "C" fn fos_vfs_rename(
    old: *const u8,
    old_len: usize,
    new: *const u8,
    new_len: usize,
) -> i32 {
    let old = unsafe { slice_from_raw(old, old_len) };
    let new = unsafe { slice_from_raw(new, new_len) };
    unsafe { vfs::rename(old, new) }
}

/// Return the number of bytes retained by a shared-layout kernel log ring.
///
/// # Safety
/// `ring` points to a live `KlogRing` with the fixed layout asserted by Rust
/// and declared as an `extern struct` by the Flash adapter.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_available(ring: *const klog_ring::KlogRing) -> u64 {
    unsafe { klog_ring::available(ring) }
}

/// Read one absolute monotone position from the shared kernel log ring.
///
/// # Safety
/// `ring` satisfies [`fos_klog_available`]'s contract.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_byte_at(ring: *const klog_ring::KlogRing, position: u64) -> u8 {
    unsafe { klog_ring::byte_at(ring, position) }
}

/// Append one byte to the shared kernel log ring.
///
/// # Safety
/// `ring` points to a live writable `KlogRing`.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_push(ring: *mut klog_ring::KlogRing, byte: u8) {
    unsafe { klog_ring::push(ring, byte) }
}

/// Append a NUL-terminated string to the shared kernel log ring.
///
/// # Safety
/// `ring` points to a live writable `KlogRing`; `string` points to a readable,
/// NUL-terminated byte sequence.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_push_str(ring: *mut klog_ring::KlogRing, string: *const u8) {
    unsafe { klog_ring::push_c_str(ring, string) }
}

/// Snapshot the newest retained bytes into caller-owned storage.
///
/// # Safety
/// `ring` points to a live `KlogRing`; `dst` points to `dst_len` writable
/// bytes and does not overlap the ring.
#[no_mangle]
pub unsafe extern "C" fn fos_klog_snapshot(
    ring: *const klog_ring::KlogRing,
    dst: *mut u8,
    dst_len: usize,
) -> usize {
    unsafe { klog_ring::snapshot(ring, dst, dst_len) }
}

/// Build a get-clock-rate property message.
///
/// # Safety
/// `message` points to eight writable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_build_get_clock_rate(message: *mut u32, clock_id: u32) {
    unsafe { store_mailbox_message(message, mailbox::build_get_clock_rate(clock_id)) }
}

/// Build a set-GPIO-state property message.
///
/// # Safety
/// `message` points to eight writable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_build_set_gpio_state(
    message: *mut u32,
    gpio: u32,
    state: u32,
) {
    unsafe { store_mailbox_message(message, mailbox::build_set_gpio_state(gpio, state)) }
}

/// Build a set-power-state property message.
///
/// # Safety
/// `message` points to eight writable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_build_set_power_state(
    message: *mut u32,
    device_id: u32,
    state: u32,
) {
    unsafe { store_mailbox_message(message, mailbox::build_set_power_state(device_id, state)) }
}

/// Build a get-temperature property message.
///
/// # Safety
/// `message` points to eight writable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_build_get_temperature(message: *mut u32, temp_id: u32) {
    unsafe { store_mailbox_message(message, mailbox::build_get_temperature(temp_id)) }
}

/// Check the overall property response code.
///
/// # Safety
/// `message` points to eight readable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_check_response(message: *const u32) -> u8 {
    let message = unsafe { load_mailbox_message(message) };
    u8::from(mailbox::check_response(&message))
}

/// Parse a clock-rate response, returning 0 on malformed input.
///
/// # Safety
/// `message` points to eight readable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_parse_clock_rate(message: *const u32, clock_id: u32) -> u32 {
    let message = unsafe { load_mailbox_message(message) };
    mailbox::parse_clock_rate(&message, clock_id).unwrap_or(0)
}

/// Parse a temperature response, returning 0 on malformed input.
///
/// # Safety
/// `message` points to eight readable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_parse_temperature(message: *const u32, temp_id: u32) -> u32 {
    let message = unsafe { load_mailbox_message(message) };
    mailbox::parse_temperature(&message, temp_id).unwrap_or(0)
}

/// Parse a power-state response. Plain integer booleans cross the ABI.
///
/// # Safety
/// `message` points to eight readable, suitably aligned `u32` words.
#[no_mangle]
pub unsafe extern "C" fn fos_mailbox_parse_power_state(
    message: *const u32,
    device_id: u32,
    want_on: u8,
) -> u8 {
    let message = unsafe { load_mailbox_message(message) };
    u8::from(mailbox::parse_power_state(
        &message,
        device_id,
        want_on != 0,
    ))
}

#[no_mangle]
pub extern "C" fn fos_mailbox_doorbell(buffer_address: u32, channel: u32) -> u32 {
    mailbox::doorbell(buffer_address, channel)
}

#[no_mangle]
pub extern "C" fn fos_sdhci_clock_divisor(base_hz: u32, target_hz: u32) -> u32 {
    sdhci_cmd::clock_divisor(base_hz, target_hz)
}

#[no_mangle]
pub extern "C" fn fos_sdhci_control1_clock_bits(divisor: u32) -> u32 {
    sdhci_cmd::control1_clock_bits(divisor)
}

/// Parse four controller response words, returning zero for an unsupported CSD.
#[no_mangle]
pub extern "C" fn fos_sdhci_parse_csd_v2(
    response0: u32,
    response1: u32,
    response2: u32,
    response3: u32,
) -> u64 {
    sdhci_cmd::parse_csd_v2([response0, response1, response2, response3])
        .map_or(0, |csd| csd.capacity_blocks)
}

/// Re-point a block device's callbacks to their high-half (TTBR1) aliases.
///
/// # Safety
/// `dev` points to a live, writable `BlockDev`.
#[no_mangle]
pub unsafe extern "C" fn fos_block_dev_relocate(dev: *mut block_dev::BlockDev) {
    unsafe { block_dev::relocate(dev) }
}

/// Mount the board-initialized SD device and register the FAT32 VFS backend.
///
/// # Safety
/// `dev` points to the kernel-lifetime board callback record, initialized
/// before this call and exclusively owned during bring-up.
#[no_mangle]
pub unsafe extern "C" fn fos_fat32_backend_init(dev: *mut block_dev::BlockDev) -> i32 {
    unsafe { fat32_backend::init(dev) }
}

/// Return one when the permission overlay was accepted at mount time.
#[no_mangle]
pub extern "C" fn fos_fat32_backend_overlay_ok() -> u8 {
    u8::from(fat32_backend::overlay_ok())
}

/// Copy a local message to firmware-visible storage with volatile word writes.
///
/// # Safety
/// `destination` points to eight writable, suitably aligned `u32` words.
unsafe fn store_mailbox_message(destination: *mut u32, message: mailbox::Msg) {
    let mut index = 0usize;
    while index < message.len() {
        unsafe { destination.add(index).write_volatile(message[index]) };
        index += 1;
    }
}

/// Snapshot firmware-visible storage with volatile word reads.
///
/// # Safety
/// `source` points to eight readable, suitably aligned `u32` words.
unsafe fn load_mailbox_message(source: *const u32) -> mailbox::Msg {
    let mut message = [0; 8];
    let mut index = 0usize;
    while index < message.len() {
        message[index] = unsafe { source.add(index).read_volatile() };
        index += 1;
    }
    message
}

/// PBKDF2-HMAC-SHA256 over caller-owned buffers.
///
/// SAFETY (caller's obligation, checked by the Flash wrapper's slice types):
/// `password`/`salt` point to `password_len`/`salt_len` readable bytes, and
/// `out` to `out_len` writable bytes; none of the three overlap.
///
/// # Safety
/// See above.
#[no_mangle]
pub unsafe extern "C" fn fos_pbkdf2_hmac_sha256(
    password: *const u8,
    password_len: usize,
    salt: *const u8,
    salt_len: usize,
    iterations: u32,
    out: *mut u8,
    out_len: usize,
) {
    // SAFETY: the caller guarantees each pointer/length pair describes a live,
    // non-overlapping region; a zero length yields an empty slice, for which the
    // pointer is never dereferenced (it must still be non-null and aligned, which
    // holds for every Flash slice, including empty ones taken from real arrays).
    let password = unsafe { slice_from_raw(password, password_len) };
    let salt = unsafe { slice_from_raw(salt, salt_len) };
    let out = unsafe { core::slice::from_raw_parts_mut(out, out_len) };
    sha256::pbkdf2_hmac_sha256(password, salt, iterations, out);
}

/// Constant-time byte-slice equality. Returns 1 on equal, 0 otherwise — a plain
/// byte, not a Rust `bool`, so the value crossing the boundary is one both
/// languages agree on.
///
/// # Safety
/// `a`/`b` point to `a_len`/`b_len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn fos_ct_eql(a: *const u8, a_len: usize, b: *const u8, b_len: usize) -> u8 {
    // SAFETY: as documented above; both regions are read-only and may overlap.
    let a = unsafe { slice_from_raw(a, a_len) };
    let b = unsafe { slice_from_raw(b, b_len) };
    u8::from(sha256::ct_eql(a, b))
}

/// Normalize a path into `out`, returning its length or `usize::MAX` on error.
///
/// # Safety
/// Each pointer describes a live region of the accompanying length. `out`
/// must be writable and must not overlap either input.
#[no_mangle]
pub unsafe extern "C" fn fos_path_join_resolve(
    cwd: *const u8,
    cwd_len: usize,
    rel: *const u8,
    rel_len: usize,
    out: *mut u8,
    out_len: usize,
) -> usize {
    let cwd = unsafe { slice_from_raw(cwd, cwd_len) };
    let rel = unsafe { slice_from_raw(rel, rel_len) };
    let out = unsafe { mut_slice_from_raw(out, out_len) };
    path::join_resolve(cwd, rel, out).map_or(NONE, |resolved| resolved.len())
}

/// Check one Unix permission intent. Invalid intent tags fail closed.
#[no_mangle]
pub extern "C" fn fos_perm_check_access(
    mode: u32,
    file_uid: u32,
    file_gid: u32,
    euid: u32,
    egid: u32,
    want: u8,
) -> u8 {
    let want = match want {
        0 => perm::Access::Read,
        1 => perm::Access::Write,
        2 => perm::Access::Exec,
        _ => return 0,
    };
    u8::from(perm::check_access(
        mode, file_uid, file_gid, euid, egid, want,
    ))
}

/// Parse one shadow line into offsets relative to that line.
///
/// # Safety
/// `line` is readable for `line_len` bytes and `out` points to writable,
/// properly aligned storage for one `FosShadowEntry`.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_parse_line(
    line: *const u8,
    line_len: usize,
    out: *mut FosShadowEntry,
) -> u8 {
    let line = unsafe { slice_from_raw(line, line_len) };
    let Some(entry) = shadow::parse_line(line) else {
        return 0;
    };
    let base = line.as_ptr() as usize;
    let result = FosShadowEntry {
        user_offset: entry.user.as_ptr() as usize - base,
        user_len: entry.user.len(),
        iterations: entry.iterations,
        salt_offset: entry.salt_hex.as_ptr() as usize - base,
        salt_len: entry.salt_hex.len(),
        hash_offset: entry.hash_hex.as_ptr() as usize - base,
        hash_len: entry.hash_hex.len(),
    };
    unsafe { out.write(result) };
    1
}

/// Decode hex, returning the byte count or `usize::MAX` on error.
///
/// # Safety
/// The input is readable and the output writable for their stated lengths;
/// the regions do not overlap.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_hex_decode(
    input: *const u8,
    input_len: usize,
    out: *mut u8,
    out_len: usize,
) -> usize {
    let input = unsafe { slice_from_raw(input, input_len) };
    let out = unsafe { mut_slice_from_raw(out, out_len) };
    shadow::hex_decode(input, out).unwrap_or(NONE)
}

/// Encode lowercase hex, returning the character count or `usize::MAX`.
///
/// # Safety
/// The input is readable and the output writable for their stated lengths;
/// the regions do not overlap.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_hex_encode(
    input: *const u8,
    input_len: usize,
    out: *mut u8,
    out_len: usize,
) -> usize {
    let input = unsafe { slice_from_raw(input, input_len) };
    let out = unsafe { mut_slice_from_raw(out, out_len) };
    shadow::hex_encode(input, out).unwrap_or(NONE)
}

/// Find a user's line, writing its byte span and returning 1 on success.
///
/// # Safety
/// Both input regions are readable for their stated lengths; `start` and
/// `end` point to writable, aligned `usize` values.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_find_user_line(
    content: *const u8,
    content_len: usize,
    user: *const u8,
    user_len: usize,
    start: *mut usize,
    end: *mut usize,
) -> u8 {
    let content = unsafe { slice_from_raw(content, content_len) };
    let user = unsafe { slice_from_raw(user, user_len) };
    let Some(span) = shadow::find_user_line(content, user) else {
        return 0;
    };
    unsafe {
        start.write(span.start);
        end.write(span.end);
    }
    1
}

/// Rewrite a shadow line in place, returning 1 on success.
///
/// # Safety
/// `content` is writable for its stated length; the other regions are
/// readable and do not overlap `content` or each other.
#[no_mangle]
pub unsafe extern "C" fn fos_shadow_rewrite_line_in_place(
    content: *mut u8,
    content_len: usize,
    user: *const u8,
    user_len: usize,
    salt: *const u8,
    salt_len: usize,
    hash: *const u8,
    hash_len: usize,
) -> u8 {
    let content = unsafe { mut_slice_from_raw(content, content_len) };
    let user = unsafe { slice_from_raw(user, user_len) };
    let salt = unsafe { slice_from_raw(salt, salt_len) };
    let hash = unsafe { slice_from_raw(hash, hash_len) };
    u8::from(shadow::rewrite_line_in_place(content, user, salt, hash))
}

// ---- syscall handlers, the fixed dispatch table, and its relocation ----
//
// `entry.S` reaches the table with `adr x27, sys_call_table` and bounds the
// dispatch with the NR_SYSCALLS literal in asm_defs_common.inc, so the symbol
// name, the slot map, and the table's 56 entries are all frozen ABI. The
// handlers below are the C-ABI face of `flashos_kernel::sys`; unlike the rest of
// this module they are not transitional — when the last Flash caller goes, these
// stay as the assembly's entry points.

/// Every handler the table binds. Each is the unmangled symbol the reference
/// exported, with the same signature and the same error sentinels.
macro_rules! syscall_handlers {
    ($($(#[$meta:meta])* fn $name:ident($($arg:ident: $ty:ty),*) $(-> $ret:ty)?;)*) => {
        $(
            $(#[$meta])*
            /// # Safety
            /// Reached only through the dispatch table from `el0_svc`, which
            /// supplies the serialized EL1 syscall context — a live current
            /// task, single-core exclusion, and user addresses owned by that
            /// task — that the `flashos_kernel::sys` body documents.
            #[no_mangle]
            pub unsafe extern "C" fn $name($($arg: $ty),*) $(-> $ret)? {
                // SAFETY: reached only through the dispatch table from `el0_svc`,
                // which supplies the serialized syscall context every handler
                // documents.
                unsafe { sys::$name($($arg),*) }
            }
        )*
    };
}

syscall_handlers! {
    fn sys_fork() -> i32;
    fn sys_execve(path_ptr: u64, argv_ptr: u64) -> i32;
    fn sys_wait() -> i32;
    fn sys_exit();
    fn sys_kill(pid: i32) -> i32;
    fn sys_dump_free() -> u64;
    fn sys_mem_total() -> u64;
    fn sys_uptime() -> u64;
    fn sys_cpu_temp() -> u64;
    fn sys_cpu_freq() -> u64;
    fn sys_open_file(path_ptr: u64) -> i32;
    fn sys_create(path_ptr: u64) -> i32;
    fn sys_unlink(path_ptr: u64) -> i32;
    fn sys_rename(old_ptr: u64, new_ptr: u64) -> i32;
    fn sys_seek(fd: i32, off: i64, whence: i32) -> i64;
    fn sys_brk(addr: u64) -> i64;
    fn sys_sbrk(delta: i64) -> i64;
    fn sys_pipe() -> i64;
    fn sys_set_console_mode(mode: u64) -> i64;
    fn sys_console_inject(byte: u64);
    fn sys_read(fd: i32, buf_uva: u64, len: u64) -> i64;
    fn sys_write(fd: i32, buf_uva: u64, len: u64) -> i64;
    fn sys_close(fd: i32) -> i32;
    fn sys_dup2(oldfd: i32, newfd: i32) -> i32;
    fn sys_chdir(path_ptr: u64) -> i32;
    fn sys_getcwd(buf_uva: u64, len: u64) -> i64;
    fn sys_readdir(path_ptr: u64, index: u64, dirent_uva: u64) -> i32;
    fn sys_klog_read(buf_uva: u64, len: u64) -> i64;
    fn sys_getuid() -> i64;
    fn sys_geteuid() -> i64;
    fn sys_getgid() -> i64;
    fn sys_getegid() -> i64;
    fn sys_setuid(uid: u32) -> i64;
    fn sys_setgid(gid: u32) -> i64;
    fn sys_authenticate(user_uva: u64, user_len: u64, pass_uva: u64, pass_len: u64) -> i64;
    fn sys_passwd(
        user_uva: u64,
        user_len: u64,
        old_uva: u64,
        old_len: u64,
        new_uva: u64,
        new_len: u64
    ) -> i64;
}

/// SYS_REBOOT — resets the board and never returns, so `el0_svc` never reaches
/// the eret back to the caller.
///
/// # Safety
/// Reached only through the dispatch table.
#[no_mangle]
pub unsafe extern "C" fn sys_reboot() -> ! {
    // SAFETY: forwarded syscall context.
    unsafe { sys::sys_reboot() }
}

/// Reserved slots that were never implemented, plus the inert console close.
/// They occupy their table entries so the numbers stay claimed.
#[no_mangle]
pub extern "C" fn sys_mmap() {
    sys::sys_mmap();
}
/// See [`sys_mmap`].
#[no_mangle]
pub extern "C" fn sys_munmap() {
    sys::sys_munmap();
}
/// See [`sys_mmap`].
#[no_mangle]
pub extern "C" fn sys_mlock() {
    sys::sys_mlock();
}
/// See [`sys_mmap`].
#[no_mangle]
pub extern "C" fn sys_munlock() {
    sys::sys_munlock();
}
/// See [`sys_mmap`].
#[no_mangle]
pub extern "C" fn sys_socket() {
    sys::sys_socket();
}
/// See [`sys_mmap`].
#[no_mangle]
pub extern "C" fn sys_msgget() {
    sys::sys_msgget();
}
/// See [`sys_mmap`].
#[no_mangle]
pub extern "C" fn sys_semget() {
    sys::sys_semget();
}
/// See [`sys_mmap`].
#[no_mangle]
pub extern "C" fn sys_shmget() {
    sys::sys_shmget();
}
/// See [`sys_mmap`].
#[no_mangle]
pub extern "C" fn sys_close_console() {
    sys::sys_close_console();
}

/// Retired ABI slots. The numbers stay reserved forever — a stale binary
/// invoking one gets a clean -1, never a silently different syscall.
#[no_mangle]
pub extern "C" fn sys_retired() -> i64 {
    sys::sys_retired()
}

/// Syscalls run at EL1h with TTBR0 holding the *user* pgd, so each entry is
/// OR-ed with the linear-map base and the `blr` in `el0_svc` lands in the
/// kernel's high-mem mapping.
const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;

/// Syscall dispatch table — referenced from `entry.S` (`adr x27, sys_call_table`).
///
/// The slot-to-constant binding is compiler-enforced by the indexed writes
/// below: a renumbering in the ABI crate propagates here automatically, a
/// duplicate id would overwrite, and a gap leaves a null that still traps
/// cleanly. The upper dispatch bound is the NR_SYSCALLS literal in
/// `arch/aarch64/asm_defs_common.inc`; keep it in lockstep with the highest
/// user-facing id + 1.
///
/// The unified ABI (slots 32..35) carries all console / pipe / file I/O. The
/// legacy per-kind shims at slots 0 / 5 / 8 / 9 / 11 / 23 / 24 / 27..29 were
/// retired: those slots route to `sys_retired` (a clean -1) and their numbers
/// are never reused.
#[no_mangle]
#[allow(non_upper_case_globals)]
pub static mut sys_call_table: [*const (); NR_SYSCALLS] = {
    let mut t: [*const (); NR_SYSCALLS] = [core::ptr::null(); NR_SYSCALLS];

    t[SYS_FORK as usize] = sys_fork as *const ();
    t[SYS_EXIT as usize] = sys_exit as *const ();
    t[SYS_WAIT as usize] = sys_wait as *const ();
    t[SYS_DUMP_FREE as usize] = sys_dump_free as *const ();
    t[SYS_KILL as usize] = sys_kill as *const ();
    t[SYS_EXECVE as usize] = sys_execve as *const ();

    t[SYS_OPEN_FILE as usize] = sys_open_file as *const ();
    t[SYS_SEEK as usize] = sys_seek as *const ();

    t[SYS_BRK as usize] = sys_brk as *const ();
    t[SYS_SBRK as usize] = sys_sbrk as *const ();
    t[SYS_MMAP as usize] = sys_mmap as *const ();
    t[SYS_MUNMAP as usize] = sys_munmap as *const ();
    t[SYS_MLOCK as usize] = sys_mlock as *const ();
    t[SYS_MUNLOCK as usize] = sys_munlock as *const ();

    t[SYS_PIPE as usize] = sys_pipe as *const ();
    t[SYS_SOCKET as usize] = sys_socket as *const ();
    t[SYS_MSGGET as usize] = sys_msgget as *const ();
    t[SYS_SEMGET as usize] = sys_semget as *const ();
    t[SYS_SHMGET as usize] = sys_shmget as *const ();

    t[SYS_SET_CONSOLE_MODE as usize] = sys_set_console_mode as *const ();
    t[SYS_CLOSE_CONSOLE as usize] = sys_close_console as *const ();

    t[SYS_CONSOLE_INJECT as usize] = sys_console_inject as *const ();

    t[SYS_READ as usize] = sys_read as *const ();
    t[SYS_WRITE as usize] = sys_write as *const ();
    t[SYS_CLOSE as usize] = sys_close as *const ();
    t[SYS_DUP2 as usize] = sys_dup2 as *const ();

    t[SYS_CHDIR as usize] = sys_chdir as *const ();
    t[SYS_GETCWD as usize] = sys_getcwd as *const ();
    t[SYS_READDIR as usize] = sys_readdir as *const ();

    t[SYS_KLOG_READ as usize] = sys_klog_read as *const ();

    t[SYS_GETUID as usize] = sys_getuid as *const ();
    t[SYS_GETEUID as usize] = sys_geteuid as *const ();
    t[SYS_GETGID as usize] = sys_getgid as *const ();
    t[SYS_GETEGID as usize] = sys_getegid as *const ();
    t[SYS_SETUID as usize] = sys_setuid as *const ();
    t[SYS_SETGID as usize] = sys_setgid as *const ();

    t[SYS_AUTHENTICATE as usize] = sys_authenticate as *const ();
    t[SYS_PASSWD as usize] = sys_passwd as *const ();
    t[SYS_REBOOT as usize] = sys_reboot as *const ();

    t[SYS_MEMTOTAL as usize] = sys_mem_total as *const ();
    t[SYS_UPTIME as usize] = sys_uptime as *const ();
    t[SYS_CPU_TEMP as usize] = sys_cpu_temp as *const ();
    t[SYS_CPU_FREQ as usize] = sys_cpu_freq as *const ();

    t[SYS_CREATE as usize] = sys_create as *const ();
    t[SYS_UNLINK as usize] = sys_unlink as *const ();
    t[SYS_RENAME as usize] = sys_rename as *const ();

    // Retired: legacy per-kind console / file / pipe / exec shims (write_str,
    // exec, readFile, writeFile, closeFile, openConsole, readConsole,
    // pipe_read, pipe_write, pipe_close). Slot numbers are never reused; any
    // caller gets -1.
    let retired = [0usize, 5, 8, 9, 11, 23, 24, 27, 28, 29];
    let mut i = 0;
    while i < retired.len() {
        t[retired[i]] = sys_retired as *const ();
        i += 1;
    }

    t
};

// Build-time guard: `arch/aarch64/asm_defs_common.inc` must declare
// `#define NR_SYSCALLS 56` to match. If the highest SYS_* constant moves, bump
// the asm-side literal too, then update this check.
const _: () = assert!(NR_SYSCALLS == 56);

/// Map each syscall function pointer to its high-mem (TTBR1) alias so `el0_svc`
/// can `blr` through the table after the user pgd has been installed in TTBR0.
///
/// # Safety
/// Called exactly once during bring-up, before any user pgd replaces the
/// identity map.
#[no_mangle]
pub unsafe extern "C" fn sys_call_table_relocate() {
    let mut i = 0;
    while i < NR_SYSCALLS {
        // SAFETY: bring-up owns the table exclusively; each slot is either null
        // or a live kernel function whose low-half address gains its high-half
        // alias exactly once.
        unsafe {
            let slot = (&raw mut sys_call_table).cast::<*const ()>().add(i);
            let low_half = slot.read() as u64;
            slot.write((low_half | LINEAR_MAP_BASE) as *const ());
        }
        i += 1;
    }
}

/// `core::slice::from_raw_parts`, with the empty case made explicit rather than
/// trusting a possibly-dangling pointer that is never read.
///
/// # Safety
/// `ptr` points to `len` readable bytes, or `len` is 0.
unsafe fn slice_from_raw<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        return &[];
    }
    // SAFETY: the caller guarantees `len` readable bytes at `ptr`.
    unsafe { core::slice::from_raw_parts(ptr, len) }
}

/// Mutable counterpart of `slice_from_raw`.
///
/// # Safety
/// `ptr` points to `len` writable bytes, or `len` is 0.
unsafe fn mut_slice_from_raw<'a>(ptr: *mut u8, len: usize) -> &'a mut [u8] {
    if len == 0 {
        return &mut [];
    }
    // SAFETY: the caller guarantees `len` writable bytes at `ptr`.
    unsafe { core::slice::from_raw_parts_mut(ptr, len) }
}

// ---- console RX ring, anonymous pipe, fd table ----
//
// Each group below is the C-ABI seam for one Rust module whose Flash callers
// (sys, fork, sched, kernel, board IRQ/UART) have not yet ported. When they do,
// these go with them.

/// Enqueue one console byte from a board IRQ handler.
///
/// # Safety
/// Called from the exception entry path on the single kernel core.
#[no_mangle]
pub unsafe extern "C" fn fos_console_push(byte: u8) {
    // SAFETY: forwarded IRQ-context contract.
    unsafe { console::console_push(byte) }
}

/// Drain up to `len` console bytes into `buf`, blocking for the first.
///
/// # Safety
/// `buf` points to `len` writable bytes; EL1 syscall context.
#[no_mangle]
pub unsafe extern "C" fn fos_console_read(buf: *mut u8, len: u64) -> i64 {
    // SAFETY: forwarded buffer contract.
    unsafe { console::console_read(buf, len) }
}

/// Inject one console byte from EL1 (deterministic QEMU echo coverage).
///
/// # Safety
/// EL1 syscall context on the single kernel core.
#[no_mangle]
pub unsafe extern "C" fn fos_console_test_push(byte: u8) {
    // SAFETY: forwarded EL1-context contract.
    unsafe { console::console_test_push(byte) }
}

/// Allocate a zeroed pipe page. Null on allocator failure.
///
/// # Safety
/// Single kernel core.
#[no_mangle]
pub unsafe extern "C" fn fos_pipe_alloc() -> *mut pipe::Pipe {
    // SAFETY: the allocator seam yields a fresh page or null.
    unsafe { pipe::alloc() }
}

/// Take one pipe reference.
///
/// # Safety
/// `p` points to a live pipe.
#[no_mangle]
pub unsafe extern "C" fn fos_pipe_ref(p: *mut pipe::Pipe) {
    // SAFETY: forwarded pipe contract.
    unsafe { pipe::pipe_ref(p) }
}

/// Drop one pipe reference, freeing the page on the last.
///
/// # Safety
/// `p` points to a live pipe with at least one reference.
#[no_mangle]
pub unsafe extern "C" fn fos_pipe_unref(p: *mut pipe::Pipe) {
    // SAFETY: forwarded pipe contract.
    unsafe { pipe::unref(p) }
}

/// Blocking pipe read of up to `len` bytes.
///
/// # Safety
/// `p` is live and `buf` points to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fos_pipe_read(p: *mut pipe::Pipe, buf: *mut u8, len: u64) -> i64 {
    // SAFETY: forwarded pipe/buffer contract.
    unsafe { pipe::read(p, buf, len) }
}

/// Blocking pipe write of up to `len` bytes.
///
/// # Safety
/// `p` is live and `buf` points to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn fos_pipe_write(p: *mut pipe::Pipe, buf: *const u8, len: u64) -> i64 {
    // SAFETY: forwarded pipe/buffer contract.
    unsafe { pipe::write(p, buf, len) }
}

/// Install `ptr` under `kind` in the task's first free fd slot; -1 if full.
///
/// # Safety
/// `task` points to a live task owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn fos_fdtable_install(
    task: *mut fdtable::TaskStruct,
    kind: u8,
    ptr: *mut core::ffi::c_void,
) -> i32 {
    // SAFETY: forwarded task contract; the tag byte is validated by `from_u8`.
    unsafe { fdtable::install(task, fdtable::Kind::from_u8(kind), ptr) }
}

/// Write the occupied slot for `fd` into `out`; returns 1 if found, 0 otherwise.
///
/// # Safety
/// `task` is live and `out` points to a writable `FdSlot`.
#[no_mangle]
pub unsafe extern "C" fn fos_fdtable_get(
    task: *mut fdtable::TaskStruct,
    fd: i32,
    out: *mut fdtable::FdSlot,
) -> i32 {
    // SAFETY: forwarded task/out contract.
    unsafe {
        match fdtable::get(task, fd) {
            Some(slot) => {
                out.write(slot);
                1
            }
            None => 0,
        }
    }
}

/// Resolve `fd` to an open file, or null.
///
/// # Safety
/// `task` points to a live task owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn fos_fdtable_get_file(
    task: *mut fdtable::TaskStruct,
    fd: i32,
) -> *mut file::File {
    // SAFETY: forwarded task contract.
    unsafe { fdtable::get_file(task, fd) }
}

/// Duplicate `oldfd` onto `newfd`; returns `newfd` or -1.
///
/// # Safety
/// `task` points to a live task owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn fos_fdtable_dup2(
    task: *mut fdtable::TaskStruct,
    oldfd: i32,
    newfd: i32,
) -> i32 {
    // SAFETY: forwarded task contract.
    unsafe { fdtable::dup2(task, oldfd, newfd) }
}

/// Close `fd`, dropping its backend reference; -1 for an already-free fd.
///
/// # Safety
/// `task` points to a live task owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn fos_fdtable_close(task: *mut fdtable::TaskStruct, fd: i32) -> i32 {
    // SAFETY: forwarded task contract.
    unsafe { fdtable::close(task, fd) }
}

/// Close every occupied slot in `task`.
///
/// # Safety
/// `task` points to a live task owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn fos_fdtable_close_all(task: *mut fdtable::TaskStruct) {
    // SAFETY: forwarded task contract.
    unsafe { fdtable::close_all(task) }
}

/// Copy every occupied slot from `src` into the unpublished child `dst`.
///
/// # Safety
/// Both pointers are live, distinct tasks owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn fos_fdtable_dup_all(
    src: *mut fdtable::TaskStruct,
    dst: *mut fdtable::TaskStruct,
) {
    // SAFETY: forwarded task contract.
    unsafe { fdtable::dup_all(src, dst) }
}
