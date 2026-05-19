// page_alloc: physical page allocator for kernel memory.
// Isolated from scheduler state — no dependency on task_struct.

// Constants
pub const PAGE_SIZE: u64 = 1 << 12;
pub const MALLOC_START: u64 = 0x40000000;
pub const MALLOC_END: u64 = 0xFC000000;
pub const MALLOC_SIZE: u64 = MALLOC_END - MALLOC_START;
pub const MALLOC_PAGES: u64 = MALLOC_SIZE / PAGE_SIZE;

const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

fn pa_to_kva(pa: u64) u64 {
    return pa + LINEAR_MAP_BASE;
}

fn kva_to_pa(kva: u64) u64 {
    return kva - LINEAR_MAP_BASE;
}

// Memory map: tracks which physical pages are allocated (1 = allocated, 0 = free)
// Stored in kernel BSS section. Must be initialized once via mem_map_init
// from the boot path before any get_free_page / free_page / dump_free_count
// call. The init is idempotent (re-zeroes the bitmap), so callers in test
// code can reset state by calling it again.
var mem_map: [MALLOC_PAGES]u8 = undefined;

/// Zero the memory bitmap. Called eagerly from kernel_main on core 0
/// before any allocator user runs.
export fn mem_map_init() void {
    for (0..MALLOC_PAGES) |i| {
        mem_map[i] = 0;
    }
}

/// Allocate a physical page; returns its physical address.
/// Panics if out of memory (no in-kernel error handling).
export fn get_free_page() u64 {
    for (0..MALLOC_PAGES) |i| {
        if (mem_map[i] == 0) {
            mem_map[i] = 1; // Mark as allocated

            const ret: u64 = MALLOC_START + @as(u64, @intCast(i)) * PAGE_SIZE;

            // Zero the page before handing it out.
            memzero(pa_to_kva(ret), PAGE_SIZE);

            return ret;
        }
    }

    // Out of physical memory
    panic("Out of physical memory!");
    return 0;
}

/// Free a physical page. Argument must be a PA from get_free_page.
export fn free_page(p: u64) void {
    const index: usize = @intCast((p - MALLOC_START) / PAGE_SIZE);
    if (index < MALLOC_PAGES) {
        mem_map[index] = 0;
    }
}

/// Allocate a page and return its kernel virtual address.
export fn get_kernel_page() u64 {
    const phys_page = get_free_page();
    return pa_to_kva(phys_page);
}

/// Free a kernel page. Argument must be a KVA from get_kernel_page.
export fn free_kernel_page(kp: u64) void {
    const pa = kva_to_pa(kp);
    free_page(pa);
}

/// Print the count of currently-free physical pages over Mini-UART and
/// return it. Format: `free_pages: <16-hex>\n`. Cheap (linear scan of
/// mem_map) but only invoked at sync points by the leak-test path — a
/// kernel boot baseline in kernel_main and again from user space via
/// sys_dump_free before/after each scenario. The returned value powers
/// the in-kernel test harness's [PASS]/[FAIL] decision; void callers
/// (kernel_main) ignore it.
export fn dump_free_count() u64 {
    var free_count: u64 = 0;
    for (0..MALLOC_PAGES) |i| {
        if (mem_map[i] == 0) free_count += 1;
    }
    main_output(MU, "free_pages: ");
    main_output_u64(MU, free_count);
    main_output(MU, "\n");
    return free_count;
}

// External C function declarations
extern fn memzero(start: u64, size: u64) void;
extern fn panic(msg: [*:0]const u8) noreturn;
extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;

const MU: i32 = 0;

// ---------------------------------------------------------------------------
// Host-only unit tests. Compiled out of the kernel binary; `zig build test`
// links each per-module test target against `tests/host_stubs.zig`, which
// stubs the assembly-only externs (`memzero`, `panic`, `main_output*`)
// the kernel modules normally depend on.
// ---------------------------------------------------------------------------

const std = @import("std");

fn reset_for_test() void {
    mem_map_init();
}

test "pa_to_kva / kva_to_pa round-trip" {
    const pa: u64 = MALLOC_START + 7 * PAGE_SIZE;
    try std.testing.expectEqual(pa, kva_to_pa(pa_to_kva(pa)));
}

test "mem_map_init zeroes the bitmap" {
    for (0..MALLOC_PAGES) |i| mem_map[i] = 0xff;
    mem_map_init();
    for (0..MALLOC_PAGES) |i| {
        try std.testing.expectEqual(@as(u8, 0), mem_map[i]);
    }
}

test "get_free_page returns sequential pages from MALLOC_START" {
    reset_for_test();
    const a = get_free_page();
    const b = get_free_page();
    const c = get_free_page();
    try std.testing.expectEqual(@as(u64, MALLOC_START), a);
    try std.testing.expectEqual(@as(u64, MALLOC_START + PAGE_SIZE), b);
    try std.testing.expectEqual(@as(u64, MALLOC_START + 2 * PAGE_SIZE), c);
}

test "free_page reuses the slot on next allocation" {
    reset_for_test();
    const a = get_free_page();
    _ = get_free_page();
    free_page(a);
    const reused = get_free_page();
    try std.testing.expectEqual(a, reused);
}

test "dump_free_count tracks allocations" {
    reset_for_test();
    try std.testing.expectEqual(MALLOC_PAGES, dump_free_count());
    _ = get_free_page();
    _ = get_free_page();
    _ = get_free_page();
    try std.testing.expectEqual(MALLOC_PAGES - 3, dump_free_count());
}

test "free_page silently ignores above-range PA" {
    reset_for_test();
    const before = dump_free_count();
    free_page(MALLOC_END + PAGE_SIZE);
    free_page(MALLOC_END + 1024 * PAGE_SIZE);
    const after = dump_free_count();
    try std.testing.expectEqual(before, after);
}

test "get_kernel_page returns KVA of a free physical page" {
    reset_for_test();
    const kva = get_kernel_page();
    try std.testing.expect(kva >= LINEAR_MAP_BASE + MALLOC_START);
    free_kernel_page(kva);
    try std.testing.expectEqual(MALLOC_PAGES, dump_free_count());
}
