// Bump allocator over the kernel's brk/sbrk syscalls — the heap layer
// of flibc. State-free by design: every malloc(n) is a thin
// sys_sbrk(+aligned_n) wrapper that returns the previous break as the
// pointer to the freshly-allocated region. No internal bookkeeping
// means flibc itself emits no `.bss` / `.data`, which keeps consuming
// ELF demos at one PT_LOAD (and inside sys_exec's PAGE_SIZE blob cap).
//
// The kernel's sys_brk rounds every break to PAGE_SIZE, so this
// allocator wastes (PAGE_SIZE - aligned_n) bytes per call when the
// caller asks for less than a page. That's intentional for the demo-
// scale userland flibc targets today; a proper free-list / per-page
// sub-allocator is Phase-4 work once `fsh` and the demo programs need
// many small allocations.

const sys = @import("syscalls.zig");

const ALIGN: u64 = 8;

/// malloc(n) — return a pointer to a freshly-allocated region of at
/// least `n` bytes (rounded up to 8). Returns null on failure
/// (kernel rejects out-of-bounds break, propagated as a negative sbrk
/// return). The memory is zeroed by the kernel's get_free_page on first
/// touch via the do_data_abort demand-alloc path.
pub fn malloc(n: u64) ?[*]u8 {
    if (n == 0) return null;
    const aligned: u64 = (n + ALIGN - 1) & ~(ALIGN - 1);
    const prev = sys.sbrk(@intCast(aligned));
    if (prev < 0) return null;
    return @ptrFromInt(@as(u64, @bitCast(prev)));
}

/// free — no-op. The bump allocator never reclaims individual
/// allocations; the kernel reaps the entire heap on process exit
/// (do_wait clears every page in `mm.user_pages`). Provided so consumers
/// can keep the alloc/free pairing readable even though the call is
/// inert.
pub fn free(_: ?[*]u8) void {}
