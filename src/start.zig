// start: kernel entry root for the Zig build.
//
// The entry point is `_start` in arch/aarch64/boot.S, which calls `kernel_main`
// (src/trace/patchable_trampolines.S) and lands in the Rust kernel root. Zig's
// executable target still needs a root module; this file is it: every remaining
// Zig/Flash kernel module is pulled in here via comptime @import so all
// `export fn` decls land in the final ELF.

comptime {
    _ = @import("sched");
    // The kernel log ring's storage. utilc used to pull this in; with utilc
    // Rust-owned, the only remaining reference is a C-ABI call, so the module
    // needs a force-import of its own to reach the linker.
    _ = @import("klog_ring");
}
