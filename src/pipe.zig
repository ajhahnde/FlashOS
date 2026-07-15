// Transitional adapter for the Rust-owned anonymous pipe.
//
// The pipe page layout, ref-counted lifetime, and blocking read/write live in
// crates/kernel/src/pipe.rs. This shim mirrors only the header fields a Flash
// caller still touches directly (`refs`); the wait-queue heads are opaque
// Rust-owned words. Removed once the last Flash caller ports.

pub const Pipe = extern struct {
    refs: u32,
    _pad: u32,
    head: u64,
    tail: u64,
    // WaitQueue heads, owned and mutated only by the Rust side.
    readers_wq: u64,
    writers_wq: u64,
};

extern fn fos_pipe_alloc() ?*Pipe;
extern fn fos_pipe_ref(p: *Pipe) void;
extern fn fos_pipe_unref(p: *Pipe) void;
extern fn fos_pipe_read(p: *Pipe, buf: [*]u8, len: u64) i64;
extern fn fos_pipe_write(p: *Pipe, buf: [*]const u8, len: u64) i64;

pub fn alloc() ?*Pipe {
    return fos_pipe_alloc();
}

pub fn ref(p: *Pipe) void {
    fos_pipe_ref(p);
}

pub fn unref(p: *Pipe) void {
    fos_pipe_unref(p);
}

pub fn read(p: *Pipe, buf: [*]u8, len: u64) i64 {
    return fos_pipe_read(p, buf, len);
}

pub fn write(p: *Pipe, buf: [*]const u8, len: u64) i64 {
    return fos_pipe_write(p, buf, len);
}
