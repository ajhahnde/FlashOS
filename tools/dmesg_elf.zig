// dmesg — kernel-log dumper for /bin/dmesg. Reads the kernel
// byte-ring (src/klog_ring.zig) through sys_klog_read (slot 38) and writes
// the retained boot log to fd 1. The whole point: read the boot log over
// the USB-C console without the Mini-UART / FTDI adapter.
//
// One snapshot, one write. sys_klog_read copies the most-recent
// min(len, retained) bytes oldest-first, so a single buffer of KLOG_SIZE
// captures the entire retained log in one coherent call — no offset
// cursor, no loop, no tearing from concurrent kernel logging. The buffer
// is a stack array (rule 1, no heap); the kernel's copy_to_user
// demand-faults its pages, so the KLOG_SIZE frame stays well inside the
// 64 KiB user stack budget. flibc_mem is imported for parity with the
// other coreutils — a later tweak that lowers a copy to a libcall cannot
// then regress the link.
//
// No flags (`-c` clear, `-n` level, `-w` follow are later scope); any
// argument is ignored. Pi-interactive surface — like meminfo / forkbomb it
// is built into the initramfs but not driven by the CI harness, which
// asserts the ring + syscall directly via [TEST] klog.

const flibc = @import("flibc");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

export fn main(argc: usize, argv: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    _ = argc;
    _ = argv;

    // KLOG_SIZE-wide so the whole retained ring fits in one snapshot. The
    // kernel returns min(buf.len, retained) bytes; sizing the buffer to the
    // ring guarantees the complete log rather than just the most recent
    // tail.
    var buf: [flibc.KLOG_SIZE]u8 = undefined;
    const n = flibc.sys.klog_read(&buf, buf.len);
    if (n > 0) _ = flibc.sys.write_fd(1, &buf, @intCast(n));

    flibc.exit();
}
