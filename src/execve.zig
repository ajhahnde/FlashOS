// Transitional fixed-layout argv record consumed by fork.flash. The execve
// implementation and encoder are Rust-owned; this module disappears once the
// process loader is implemented in Rust.

pub const ArgvBlock = extern struct {
    sp: u64,
    argv_uva: u64,
    argc: u64,
    bytes_ptr: [*]u8,
    bytes_len: usize,
};

comptime {
    if (@offsetOf(ArgvBlock, "sp") != 0 or
        @offsetOf(ArgvBlock, "argv_uva") != 8 or
        @offsetOf(ArgvBlock, "argc") != 16 or
        @offsetOf(ArgvBlock, "bytes_ptr") != 24 or
        @offsetOf(ArgvBlock, "bytes_len") != 32 or
        @sizeOf(ArgvBlock) != 40)
    {
        @compileError("ArgvBlock layout drifted from Rust");
    }
}
