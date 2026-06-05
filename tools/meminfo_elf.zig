// meminfo — free-page reporter for /bin/meminfo. The
// standalone /bin form of fsh's `free` built-in: one line carrying the
// kernel's current free-page count via sys_dump_free (slot 30). Output
// goes through flibc.printf (the legacy slot-0 console write), so meminfo
// is a Pi-interactive / serial-log tool. It is deliberately kept out of
// the CI FSH_SCRIPT: the live free-page value is non-deterministic and
// would break the baseline sys_dump_free checkpoint count.
//
// flibc_mem is imported for parity with the other coreutils — printf's
// integer formatting needs no memcpy, but a uniform import set keeps a
// later tweak from regressing the link.

const flibc = @import("flibc");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

export fn main(_: usize, _: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    flibc.printf("free pages: %u\n", .{flibc.sys.dump_free()});
    flibc.exit();
}
