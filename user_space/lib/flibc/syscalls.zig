// Raw SVC wrappers for the FlashOS kernel ABI — the lowest layer of
// flibc. Each fn loads the syscall ID into x8 (per the EL0→EL1 contract
// established in src/entry.S:el0_svc), then `svc #0` to trap. Argument /
// return wiring follows AAPCS64: x0..x5 inputs, x0 return.
//
// Syscall IDs come from lib/syscall_defs.zig — the same constants the
// kernel-side dispatch table in src/sys.zig uses to populate
// sys_call_table. A renumbering there propagates here automatically.
//
// No `linksection` attributes: flibc consumers are ELF-loaded programs
// (sys_exec ELF path), not the in-blob user_init.o that PID 1 still
// uses. The kernel's loader places these wrappers wherever the ELF's
// PT_LOAD segments dictate, not in the .text.user blob region.

const defs = @import("syscall_defs");

/// sys_writeConsole(buf) — write a null-terminated string to MU.
/// The kernel's sys_writeConsole signature reads bytes until '\0', so the
/// caller must ensure null-termination. The flibc.io layer wraps this
/// with stack-buffered printf; direct callers must hand in a [*:0].
pub fn write(buf: [*:0]const u8) void {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (defs.SYS_WRITE),
          [buf] "{x0}" (buf),
        : .{ .memory = true });
}

pub fn fork() i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_FORK),
        : .{ .memory = true });
}

pub fn exit() noreturn {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (defs.SYS_EXIT),
        : .{ .memory = true });
    unreachable;
}

pub fn wait() i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_WAIT),
        : .{ .memory = true });
}

pub fn dump_free() u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [nr] "{x8}" (defs.SYS_DUMP_FREE),
        : .{ .memory = true });
}

pub fn exec(blob_addr: u64, blob_size: u64) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_EXEC),
          [addr] "{x0}" (blob_addr),
          [size] "{x1}" (blob_size),
        : .{ .memory = true });
}

pub fn kill(pid: i32) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_KILL),
          [pid] "{x0}" (pid),
        : .{ .memory = true });
}

/// brk(addr) — set the heap break to `addr` (rounded up to PAGE_SIZE by
/// the kernel). Returns the new break, or the current break if addr==0.
/// Negative on out-of-range (below HEAP_BASE, or above
/// STACK_TOP - STACK_BUDGET). i64 because the heap range covers UVAs
/// that don't fit in i32.
pub fn brk(addr: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_BRK),
          [addr] "{x0}" (addr),
        : .{ .memory = true });
}

/// sbrk(delta) — bump the break by `delta` bytes (kernel rounds the
/// resulting target up to PAGE_SIZE). Returns the *previous* break (the
/// start of the freshly-allocated region on grow) or -1 on
/// overflow / out-of-range. Negative `delta` shrinks; the kernel frees
/// released pages and flushes the TLB.
pub fn sbrk(delta: i64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_SBRK),
          [delta] "{x0}" (delta),
        : .{ .memory = true });
}
