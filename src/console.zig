// Transitional adapter for the Rust-owned console RX ring.
//
// The board IRQ handlers and the unified read syscall reach the ring through
// this thin shim; the ring, wait queue, and blocking discipline live in
// crates/kernel/src/console.rs. Removed once the last Flash caller ports.

extern fn fos_console_push(byte: u8) void;
extern fn fos_console_read(buf: [*]u8, len: u64) i64;
extern fn fos_console_test_push(byte: u8) void;

pub fn console_push(byte: u8) void {
    fos_console_push(byte);
}

pub fn console_read(buf: [*]u8, len: u64) i64 {
    return fos_console_read(buf, len);
}

pub fn console_test_push(byte: u8) void {
    fos_console_test_push(byte);
}
