// host_alloc: shared bump allocator for host tests.
//
// Consolidates the 1 MiB bump allocator used by src/pipe.zig,
// src/file.zig, src/vfs.zig, and src/initramfs.zig host tests.
// Linked as a separate object into each test target to satisfy
// `get_free_page` / `free_page` externs.
//
// State is isolated per test target (Zig creates one test binary
// per `addTest` call).

const PAGE_SIZE: usize = 4096;
var host_page_buf: [1 << 20]u8 align(PAGE_SIZE) = undefined;
var host_page_bump: usize = 0;

export fn get_free_page() u64 {
    if (host_page_bump + PAGE_SIZE > host_page_buf.len) return 0;
    const off = host_page_bump;
    host_page_bump += PAGE_SIZE;
    return @intFromPtr(&host_page_buf[off]);
}

export fn free_page(_: u64) void {}

pub fn reset_phys_mem() void {
    host_page_bump = 0;
}
