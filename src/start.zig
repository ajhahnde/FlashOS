// start: kernel entry root for the Zig build.
//
// The entry point is `_start` in arch/aarch64/boot.S, which calls `kernel_main`
// (src/trace/patchable_trampolines.S) and lands in the Rust kernel root. Zig's
// executable target still needs a root module; this file is it. Every kernel
// module is Rust now, linked in from the crates/kernel staticlib, so there is
// nothing left to force-import here — this file is a bare root that the native
// build (cargo xtask) retires entirely.
