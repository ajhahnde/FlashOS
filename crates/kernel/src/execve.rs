//! Path-resolved ELF loading and argv staging.
//!
//! The VFS image is snapshotted into one static kernel buffer, argv is copied
//! and encoded before the current address space is torn down, and the process
//! loader consumes both buffers synchronously. FlashOS is
//! single-core; one function-wide preemption exclusion window serializes every
//! static from its first write through that final consume.

use crate::{
    file::File,
    path,
    perm::{self, Access},
    vfs,
};
use core::ptr::{addr_of, addr_of_mut};
use flashos_abi::{
    syscall::EACCES,
    task::{TaskStruct, UserPage, CWD_SIZE, MAX_PAGE_COUNT},
    user::STACK_TOP,
};

/// Largest executable image accepted by the path loader.
pub const MAX_EXEC_BYTES: usize = 0x1_0000;
/// Maximum number of argv strings represented by the encoder.
pub const MAX_ARGV: usize = 32;
/// Combined pointer/string byte budget in the eagerly mapped stack page.
pub const MAX_ARGV_BYTES: usize = 3072;

const PATH_BYTES: usize = 1024;
#[cfg(target_os = "none")]
const MU: i32 = 0;

/// Fixed-layout argv image passed synchronously to the process loader.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct ArgvBlock {
    pub sp: u64,
    pub argv_uva: u64,
    pub argc: u64,
    pub bytes_ptr: *mut u8,
    pub bytes_len: usize,
}

const _: () = {
    assert!(core::mem::size_of::<ArgvBlock>() == 40);
    assert!(core::mem::offset_of!(ArgvBlock, sp) == 0);
    assert!(core::mem::offset_of!(ArgvBlock, argv_uva) == 8);
    assert!(core::mem::offset_of!(ArgvBlock, argc) == 16);
    assert!(core::mem::offset_of!(ArgvBlock, bytes_ptr) == 24);
    assert!(core::mem::offset_of!(ArgvBlock, bytes_len) == 32);
};

#[derive(Clone, Copy)]
#[repr(C)]
struct ArgSpan {
    ptr: *const u8,
    len: usize,
}

const EMPTY_ARG: ArgSpan = ArgSpan {
    ptr: core::ptr::null(),
    len: 0,
};

static mut EXEC_BUF: [u8; MAX_EXEC_BYTES] = [0; MAX_EXEC_BYTES];
static mut ARG_STORAGE: [u8; MAX_ARGV_BYTES] = [0; MAX_ARGV_BYTES];
static mut EXEC_KPATH: [u8; PATH_BYTES] = [0; PATH_BYTES];
static mut EXEC_JOIN_BUF: [u8; CWD_SIZE] = [0; CWD_SIZE];
static mut EXEC_ARG_SPANS: [ArgSpan; MAX_ARGV] = [EMPTY_ARG; MAX_ARGV];
static mut ARGV_SCRATCH: [u8; MAX_ARGV_BYTES] = [0; MAX_ARGV_BYTES];

#[cfg(target_os = "none")]
mod seam {
    use super::TaskStruct;
    use crate::fork;
    use core::ptr::addr_of;

    unsafe extern "C" {
        static mut current: *mut TaskStruct;
        fn copy_from_user(kernel_buffer: *mut u8, uva: u64, len: u64) -> i32;
        fn preempt_disable();
        fn preempt_enable();
        fn free_page(page: u64);
        fn main_output(interface: i32, string: *const u8);
        fn exit_process();
    }

    #[inline]
    pub unsafe fn current_task() -> *mut TaskStruct {
        // SAFETY: the scheduler owns writes to the exported pointer.
        unsafe { addr_of!(current).read() }
    }

    #[inline]
    pub unsafe fn copy_user(destination: *mut u8, source_uva: u64, len: u64) -> i32 {
        // SAFETY: forwarded user-copy and destination-span contract.
        unsafe { copy_from_user(destination, source_uva, len) }
    }

    #[inline]
    pub unsafe fn disable_preemption() {
        // SAFETY: execve runs in the active task's syscall context.
        unsafe { preempt_disable() };
    }

    #[inline]
    pub unsafe fn enable_preemption() {
        // SAFETY: matches a disable in the same syscall context.
        unsafe { preempt_enable() };
    }

    #[inline]
    pub unsafe fn release_page(page: u64) {
        // SAFETY: execve has removed every task-owned alias before reuse.
        unsafe { free_page(page) };
    }

    #[inline]
    pub unsafe fn load_image(blob: *mut u8, size: u64, argv: *const super::ArgvBlock) -> i32 {
        // SAFETY: both buffers remain live for the synchronous loader call and
        // execve owns current-mm replacement from this point onward.
        unsafe { fork::move_to_user_elf_argv(blob as u64, size, argv) }
    }

    #[inline]
    pub unsafe fn report_oom_and_exit() {
        // SAFETY: fixed NUL-terminated marker and active-task exit context.
        unsafe { main_output(super::MU, c"[KERN] OOM\n".as_ptr().cast()) };
        unsafe { exit_process() };
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    use super::TaskStruct;

    pub unsafe fn current_task() -> *mut TaskStruct {
        core::ptr::null_mut()
    }
    pub unsafe fn copy_user(_: *mut u8, _: u64, _: u64) -> i32 {
        -1
    }
    pub unsafe fn disable_preemption() {}
    pub unsafe fn enable_preemption() {}
    pub unsafe fn release_page(_: u64) {}
    pub unsafe fn load_image(_: *mut u8, _: u64, _: *const super::ArgvBlock) -> i32 {
        -1
    }
    pub unsafe fn report_oom_and_exit() {}
}

#[derive(Clone, Copy)]
struct ByteSpan {
    ptr: *mut u8,
    len: usize,
}

/// Encode argv pointers and strings flush against `top_stack_uva`.
///
/// # Safety
/// `args` points to `argc` readable spans, and every span describes readable
/// bytes for the duration of this synchronous call. The caller serializes the
/// module-level scratch buffer.
unsafe fn encode_argv_block(
    top_stack_uva: u64,
    argc: usize,
    args: *const ArgSpan,
) -> Option<ArgvBlock> {
    if argc > MAX_ARGV {
        return None;
    }

    let mut string_bytes = 0usize;
    let mut index = 0usize;
    while index < argc {
        // SAFETY: caller supplies `argc` readable spans.
        let arg = unsafe { args.add(index).read() };
        string_bytes = string_bytes.checked_add(arg.len)?.checked_add(1)?;
        if string_bytes > MAX_ARGV_BYTES {
            return None;
        }
        index += 1;
    }

    let pointer_bytes = argc.checked_mul(8)?;
    let core_bytes = pointer_bytes
        .checked_add(8)?
        .checked_add(string_bytes)?
        .checked_add(8)?;
    let total = core_bytes.checked_add(15)? & !15;
    if total > MAX_ARGV_BYTES {
        return None;
    }

    let base_uva = top_stack_uva.wrapping_sub(total as u64);
    let scratch = addr_of_mut!(ARGV_SCRATCH).cast::<u8>();
    // SAFETY: `total` is bounded by the scratch array length.
    unsafe { scratch.write_bytes(0, total) };

    let mut string_offset = pointer_bytes + 8;
    index = 0;
    while index < argc {
        // SAFETY: same `argc` span contract as above.
        let arg = unsafe { args.add(index).read() };
        let user_pointer = base_uva.wrapping_add(string_offset as u64).to_le();
        // SAFETY: the pointer slot is inside the bounded scratch image; use an
        // unaligned store because the byte array itself has alignment one.
        unsafe {
            scratch
                .add(index * 8)
                .cast::<u64>()
                .write_unaligned(user_pointer)
        };
        if arg.len != 0 {
            // SAFETY: source span is caller-provided and the checked total
            // proves the destination range fits in the scratch image.
            unsafe { core::ptr::copy_nonoverlapping(arg.ptr, scratch.add(string_offset), arg.len) };
        }
        // SAFETY: one NUL byte was included in `string_bytes` above.
        unsafe { scratch.add(string_offset + arg.len).write(0) };
        string_offset += arg.len + 1;
        index += 1;
    }

    Some(ArgvBlock {
        sp: base_uva,
        argv_uva: base_uva,
        argc: argc as u64,
        bytes_ptr: scratch,
        bytes_len: total,
    })
}

/// Preserve the historical `execve_impl(path_ptr, argv_ptr)` syscall seam.
///
/// # Safety
/// Both addresses are user virtual addresses in the active task. `argv_ptr`
/// may be zero; otherwise it names a NULL-terminated pointer vector.
pub unsafe fn execve_impl(path_ptr: u64, argv_ptr: u64) -> i32 {
    let current = unsafe { seam::current_task() };
    if current.is_null() {
        return -1;
    }

    // Function-wide serialization is the correctness contract for every
    // module static, including the gap between buffer fill and loader consume.
    unsafe { seam::disable_preemption() };
    let result = unsafe { execve_kernel(current, path_ptr, argv_ptr) };
    unsafe { seam::enable_preemption() };
    result
}

/// # Safety
/// `current` is the active live task and preemption remains disabled until this
/// function and the synchronous image-loader handoff return.
unsafe fn execve_kernel(current: *mut TaskStruct, path_ptr: u64, argv_ptr: u64) -> i32 {
    let kpath = addr_of_mut!(EXEC_KPATH).cast::<u8>();
    let mut path_len = 0usize;
    let mut terminated = false;
    while path_len < PATH_BYTES - 1 {
        let mut byte = 0u8;
        if unsafe { seam::copy_user(&raw mut byte, path_ptr + path_len as u64, 1) } < 0 {
            return -1;
        }
        // SAFETY: loop bound keeps the write inside EXEC_KPATH.
        unsafe { kpath.add(path_len).write(byte) };
        if byte == 0 {
            terminated = true;
            break;
        }
        path_len += 1;
    }
    if !terminated {
        return -1;
    }

    // SAFETY: the serialized static contains `path_len` initialized bytes.
    let raw_path = unsafe { core::slice::from_raw_parts(kpath, path_len) };
    let path = if raw_path.first() == Some(&b'/') {
        ByteSpan {
            ptr: kpath,
            len: path_len,
        }
    } else {
        // SAFETY: the function contract guarantees a live current task.
        let cwd = unsafe { addr_of!((*current).cwd).cast::<u8>() };
        let mut cwd_len = 0usize;
        while cwd_len < CWD_SIZE && unsafe { cwd.add(cwd_len).read() } != 0 {
            cwd_len += 1;
        }
        // SAFETY: current remains live and its fixed-size cwd is read-only for
        // this serialized call.
        let cwd = unsafe { core::slice::from_raw_parts(cwd, cwd_len) };
        let join = addr_of_mut!(EXEC_JOIN_BUF).cast::<u8>();
        // SAFETY: the function-wide exclusion window grants this call sole
        // access to the staging buffer.
        let join = unsafe { core::slice::from_raw_parts_mut(join, CWD_SIZE) };
        let Some(resolved) = path::join_resolve(cwd, raw_path, join) else {
            return -1;
        };
        ByteSpan {
            ptr: resolved.as_mut_ptr(),
            len: resolved.len(),
        }
    };

    let storage = addr_of_mut!(ARG_STORAGE).cast::<u8>();
    let spans = addr_of_mut!(EXEC_ARG_SPANS).cast::<ArgSpan>();
    let mut argc = 0usize;
    let mut storage_offset = 0usize;
    if argv_ptr != 0 {
        loop {
            // Preserve the reference order: the cap check happens before the
            // next pointer (including its terminating NULL) is copied.
            if argc >= MAX_ARGV {
                return -1;
            }
            let mut user_arg = 0u64;
            if unsafe {
                seam::copy_user(
                    (&raw mut user_arg).cast::<u8>(),
                    argv_ptr + (argc * 8) as u64,
                    8,
                )
            } < 0
            {
                return -1;
            }
            if user_arg == 0 {
                break;
            }

            let start = storage_offset;
            loop {
                let mut byte = 0u8;
                if unsafe {
                    seam::copy_user(&raw mut byte, user_arg + (storage_offset - start) as u64, 1)
                } < 0
                {
                    return -1;
                }
                if byte == 0 {
                    break;
                }
                if storage_offset >= MAX_ARGV_BYTES {
                    return -1;
                }
                // SAFETY: the explicit budget check bounds this write.
                unsafe { storage.add(storage_offset).write(byte) };
                storage_offset += 1;
            }
            // SAFETY: `argc < MAX_ARGV`; the span points into serialized
            // storage that remains live through the loader handoff.
            unsafe {
                spans.add(argc).write(ArgSpan {
                    ptr: storage.add(start),
                    len: storage_offset - start,
                })
            };
            argc += 1;
        }
    }

    let Some(argv_block) = (unsafe { encode_argv_block(STACK_TOP, argc, spans) }) else {
        return -1;
    };

    // SAFETY: ByteSpan points to one of the serialized module buffers.
    let path = unsafe { core::slice::from_raw_parts(path.ptr, path.len) };
    let mut open_result = vfs::OpenResult::default();
    unsafe { seam::disable_preemption() };
    let superblock = unsafe { vfs::open(path, &raw mut open_result) };
    unsafe { seam::enable_preemption() };
    if superblock.is_null() {
        return -1;
    }

    let euid = unsafe { addr_of!((*current).euid).read() };
    let egid = unsafe { addr_of!((*current).egid).read() };
    if !perm::check_access(
        open_result.mode,
        open_result.uid,
        open_result.gid,
        euid,
        egid,
        Access::Exec,
    ) {
        return -EACCES;
    }
    if open_result.size > MAX_EXEC_BYTES as u64 {
        return -1;
    }

    let mut file = File {
        private: open_result.private,
        size: open_result.size,
        ..File::default()
    };
    let image = addr_of_mut!(EXEC_BUF).cast::<u8>();
    let mut image_len = 0usize;
    unsafe { seam::disable_preemption() };
    while image_len < MAX_EXEC_BYTES {
        let take = (MAX_EXEC_BYTES - image_len) as u64;
        let read = unsafe { vfs::read(superblock, &raw mut file, image.add(image_len), take) };
        if read < 0 {
            unsafe { seam::enable_preemption() };
            return -1;
        }
        if read == 0 {
            break;
        }
        image_len += read as usize;
    }
    unsafe { seam::enable_preemption() };

    let is_elf = image_len >= 4
        && unsafe { image.read() } == 0x7f
        && unsafe { image.add(1).read() } == b'E'
        && unsafe { image.add(2).read() } == b'L'
        && unsafe { image.add(3).read() } == b'F';
    if !is_elf {
        return -1;
    }

    unsafe { seam::disable_preemption() };
    unsafe { vfs::close(superblock, &raw mut file) };
    unsafe { seam::enable_preemption() };

    // Point of no return. Preserve fds, cwd, and credentials; replace only mm.
    // SAFETY: current is live and execve exclusively owns its mm teardown.
    let user_pages = unsafe { addr_of_mut!((*current).mm.user_pages).cast::<UserPage>() };
    let mut index = 0usize;
    while index < MAX_PAGE_COUNT {
        // SAFETY: current exclusively owns every recorded mm page here.
        let page = unsafe { user_pages.add(index).read().pa };
        if page != 0 {
            unsafe { seam::release_page(page) };
        }
        unsafe { user_pages.add(index).write(UserPage::default()) };
        index += 1;
    }

    // SAFETY: same exclusive current-mm teardown contract as user_pages.
    let kernel_pages = unsafe { addr_of_mut!((*current).mm.kernel_pages).cast::<u64>() };
    index = 0;
    while index < MAX_PAGE_COUNT {
        let page = unsafe { kernel_pages.add(index).read() };
        if page != 0 {
            unsafe { seam::release_page(page) };
        }
        unsafe { kernel_pages.add(index).write(0) };
        index += 1;
    }
    unsafe { addr_of_mut!((*current).mm.pgd).write(0) };

    let result = unsafe { seam::load_image(image, image_len as u64, &raw const argv_block) };
    if result < 0 {
        unsafe { seam::report_oom_and_exit() };
    }

    // ret_from_syscall overwrites saved x0 after the loader returns; returning
    // argc preserves the AAPCS64 x0=argc entry contract for the new image.
    argc as i32
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    const TEST_TOP: u64 = 0x0000_0FFF_FFFF_F000;
    const TEST_PAGE: u64 = 1 << 12;
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> MutexGuard<'static, ()> {
        TEST_LOCK
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn encode(args: &[&[u8]]) -> Option<ArgvBlock> {
        let mut spans = [EMPTY_ARG; MAX_ARGV + 1];
        for (index, arg) in args.iter().enumerate() {
            spans[index] = ArgSpan {
                ptr: arg.as_ptr(),
                len: arg.len(),
            };
        }
        // SAFETY: local spans and borrowed bytes remain live for the call; each
        // test holds TEST_LOCK around the shared scratch buffer.
        unsafe { encode_argv_block(TEST_TOP, args.len(), spans.as_ptr()) }
    }

    fn argument(block: ArgvBlock, index: usize) -> &'static [u8] {
        // SAFETY: tests hold the scratch lock and inspect a block returned by
        // the encoder. Pointer values are little-endian UVA scalars.
        let pointer = unsafe {
            block
                .bytes_ptr
                .add(index * 8)
                .cast::<u64>()
                .read_unaligned()
        };
        let offset = u64::from_le(pointer).wrapping_sub(block.sp) as usize;
        let mut len = 0usize;
        while unsafe { block.bytes_ptr.add(offset + len).read() } != 0 {
            len += 1;
        }
        unsafe { core::slice::from_raw_parts(block.bytes_ptr.add(offset), len) }
    }

    #[test]
    fn encode_argv_block_lays_out_argc_three() {
        let _guard = lock();
        let block = encode(&[b"argv_echo", b"A", b"B"]).unwrap();
        assert_eq!(block.argc, 3);
        assert_eq!(block.sp, block.argv_uva);
        assert_eq!(block.sp % 16, 0);
        assert_eq!(block.sp + block.bytes_len as u64, TEST_TOP);
        assert!(block.sp >= TEST_TOP - TEST_PAGE);
        assert_eq!(argument(block, 0), b"argv_echo");
        assert_eq!(argument(block, 1), b"A");
        assert_eq!(argument(block, 2), b"B");
        let null = unsafe { block.bytes_ptr.add(3 * 8).cast::<u64>().read_unaligned() };
        assert_eq!(null, 0);
    }

    #[test]
    fn encode_argv_block_empty_argv_is_a_lone_null() {
        let _guard = lock();
        let block = encode(&[]).unwrap();
        assert_eq!(block.argc, 0);
        assert_eq!(block.sp, block.argv_uva);
        assert_eq!(block.sp % 16, 0);
        let null = unsafe { block.bytes_ptr.cast::<u64>().read_unaligned() };
        assert_eq!(null, 0);
    }

    #[test]
    fn encode_argv_block_rejects_more_than_maximum_strings() {
        let _guard = lock();
        let args = [b"x".as_slice(); MAX_ARGV + 1];
        assert!(encode(&args).is_none());
    }

    #[test]
    fn encode_argv_block_rejects_oversize_byte_budget() {
        let _guard = lock();
        let big = [0u8; MAX_ARGV_BYTES];
        assert!(encode(&[&big]).is_none());
    }

    #[test]
    fn encode_argv_block_keeps_sp_aligned_for_odd_lengths() {
        let _guard = lock();
        let block = encode(&[b"abc", b"de"]).unwrap();
        assert_eq!(block.sp % 16, 0);
        assert_eq!(block.sp + block.bytes_len as u64, TEST_TOP);
        assert_eq!(argument(block, 0), b"abc");
        assert_eq!(argument(block, 1), b"de");
    }

    #[test]
    fn encode_argv_block_pointers_stay_inside_the_stack_page() {
        let _guard = lock();
        let block = encode(&[b"one", b"two", b"three"]).unwrap();
        for index in 0..block.argc as usize {
            let pointer = unsafe {
                block
                    .bytes_ptr
                    .add(index * 8)
                    .cast::<u64>()
                    .read_unaligned()
            };
            let pointer = u64::from_le(pointer);
            assert!(pointer >= TEST_TOP - TEST_PAGE);
            assert!(pointer < TEST_TOP);
        }
    }
}
