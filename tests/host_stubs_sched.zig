// Sched-test-only stubs.
//
// sched.zig itself exports `current`, `preempt_disable`, `preempt_enable`,
// and `schedule` — so wait_queue.zig / pipe.zig externs that are pulled in
// transitively (sched.zig @imports pipe) resolve through sched.zig's own
// strong symbols. tests/host_stubs.zig defines the same names; linking
// both would double-define. This file fills only the HW-side gap: the
// assembly trampolines (`_schedule`, `core_switch_to`, set_pgd, irq_*),
// the kernel-page free hooks (`free_page`, `free_kernel_page`), and the
// page allocator entry point pipe.zig still needs (`get_free_page`).
//
// All stubs are inert — the sched tests exercise the pure helpers
// (pick_next_running / refill_counters / zombify_and_wake_parent) against
// local TaskStruct fixtures and never reach the scheduling tail.

export fn core_switch_to(_: *anyopaque, _: *anyopaque) void {}
export fn set_pgd(_: u64) void {}
export fn irq_enable() void {}
export fn irq_disable() void {}

// free_page is counted so the release_user_mm host test can assert the
// mm sweep frees exactly the populated slots. Inert otherwise — no sched
// test reaches a real free path besides that one.
var freed_pages: u64 = 0;
export fn free_page(_: u64) void {
    freed_pages += 1;
}
export fn sched_free_count() u64 {
    return freed_pages;
}
export fn sched_reset_free_count() void {
    freed_pages = 0;
}

export fn free_kernel_page(_: u64) void {}
export fn _schedule() void {}

// pipe.zig consumes get_free_page; sched.zig imports pipe but no sched
// test exercises a pipe path, so a stub returning 0 is enough — the
// symbol exists for link-time resolution only.
export fn get_free_page() u64 {
    return 0;
}
