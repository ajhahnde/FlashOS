// cat — minimal coreutil for /bin/cat. With no
// arguments it copies fd 0 to fd 1 until EOF (the `echo hi | cat`
// acceptance case: cat's fd 0 is the pipe read end). With arguments it
// opens each path via flibc.open and copies its bytes to fd 1; an
// unopenable path prints a diagnostic to fd 2 and the next path is
// tried. No flags, no `-` stdin sentinel (fsh-v2 scope).
//
// All I/O is the unified fd ABI (read slot 32 / write_fd slot 33 / open
// slot 7 / close slot 34). The copy buffer is a single stack array —
// rule 1, no heap. flibc_mem is imported for parity with echo / fsh: the
// read→write copy needs no memcpy, but keeping the import uniform means
// a later tweak that introduces one cannot regress the link.

const flibc = @import("flibc");
const defs = @import("syscall_defs");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

const BUF_LEN: usize = 512;

fn drain(fd: i32) void {
    var buf: [BUF_LEN]u8 = undefined;
    while (true) {
        const n = flibc.sys.read(fd, &buf, buf.len);
        if (n <= 0) break;
        _ = flibc.sys.write_fd(1, &buf, @intCast(n));
    }
}

export fn main(argc: usize, argv: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    if (argc <= 1) {
        drain(0);
    } else {
        var i: usize = 1;
        while (i < argc) : (i += 1) {
            const path = argv[i] orelse break;
            const fd = flibc.sys.open(path);
            if (fd < 0) {
                // -EACCES is the permission-layer denial — say so;
                // anything else keeps the historical generic miss.
                const msg: []const u8 = if (fd == -defs.EACCES)
                    "cat: Permission denied\n"
                else
                    "cat: cannot open\n";
                _ = flibc.sys.write_fd(2, msg.ptr, msg.len);
                continue;
            }
            drain(fd);
            _ = flibc.sys.close(fd);
        }
    }
    flibc.exit();
}
