// Pipe-test-only stubs.
//
// pipe.zig calls `get_free_page` / `free_page` from the page allocator
// (src/page_alloc.zig). The page_alloc test target links the real
// allocator, so adding the same symbols to tests/host_stubs.zig would
// duplicate them at link time. This stub object is linked ONLY into
// the pipe test target — a bump allocator out of a static 1 MiB block
// is enough for the bookkeeping the pipe tests assert. `free_page` is
// a no-op; tests don't recycle pages.

var host_page_buf: [1 << 20]u8 align(4096) = undefined;
var host_page_bump: usize = 0;

export fn get_free_page() u64 {
    const PAGE: usize = 4096;
    if (host_page_bump + PAGE > host_page_buf.len) return 0;
    const off = host_page_bump;
    host_page_bump += PAGE;
    return @intFromPtr(&host_page_buf[off]);
}

export fn free_page(_: u64) void {}
