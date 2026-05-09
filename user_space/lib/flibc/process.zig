// Process-glue layer of flibc — fork / wait / exit / execve as thin
// wrappers around the kernel ABI. fork / wait / exit are direct sys-*
// passthroughs; execve adds an ELF-magic guard so callers handed
// garbage (a non-ELF blob) get a synchronous error without paying for
// the kernel's snapshot allocation.
//
// All four wrappers run from EL0 in an ELF-loaded process — the only
// context flibc supports. PID 1 (still blob-loaded) cannot link against
// flibc until initramfs (Phase 3); for now PID 1 keeps using the
// `sys_*` wrappers in user_space/kernel_tests.zig.

const sys = @import("syscalls.zig");

/// fork() — clone the current process. Returns the child's pid in the
/// parent and 0 in the child. -1 on failure (NR_TASKS exhausted,
/// out-of-memory, etc.).
pub fn fork() i32 {
    return sys.fork();
}

/// wait() — block until any child terminates and reap it. Returns the
/// reaped child's pid, or -1 if the caller has no children.
pub fn wait() i32 {
    return sys.wait();
}

/// exit() — terminate the current process. Never returns. The kernel
/// flips the task to TASK_ZOMBIE; the parent's wait reaps it (frees
/// every user/kernel page tracked by `mm`).
pub fn exit() noreturn {
    sys.exit();
}

/// execve(blob_addr, blob_size) — replace the current address space
/// with the ELF at [blob_addr, blob_addr + blob_size). Validates ELF
/// magic up-front (sniffs `0x7f 'E' 'L' 'F'`) so a malformed blob is
/// rejected without the kernel paying the snapshot-page allocation;
/// passing the magic check forwards to sys_exec, which does the full
/// ehdr/phdr parse + region-aware mapping in
/// src/fork.zig:prepare_move_to_user_elf.
///
/// On success the syscall does not return — the kernel rewrites the
/// task's KeRegs frame and erets to the new entry point. On failure
/// (parse error, alloc failure, magic mismatch) returns -1 and the
/// caller's address space is untouched.
pub fn execve(blob_addr: u64, blob_size: u64) i32 {
    if (blob_size < 4) return -1;
    const bytes: [*]const u8 = @ptrFromInt(blob_addr);
    if (bytes[0] != 0x7f or bytes[1] != 'E' or bytes[2] != 'L' or bytes[3] != 'F') return -1;
    return sys.exec(blob_addr, blob_size);
}
