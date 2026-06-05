// echo — minimal coreutil for /bin/echo. Writes its
// arguments to fd 1, space-separated, followed by a newline. No flags
// (`-n` / `-e` are fsh-v2 scope); argv[0] (the program name) is skipped.
//
// Output goes through the unified write_fd(1, …) (slot 33), NOT the
// legacy slot-0 console write: when fsh runs `echo hi | cat`, echo's
// fd 1 has been dup2'd onto the pipe write end, so it must route through
// the fd table to land in the pipe rather than straight on the console.
//
// Entry is the flibc _start argc/argv shim. flibc_mem is imported
// because computing each argument's length is a bare `while (s[n] != 0)`
// scan that LLVM lowers to a `strlen` libcall (bundle_compiler_rt=false
// would otherwise leave it undefined at link).

const flibc = @import("flibc");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

fn emit(s: []const u8) void {
    _ = flibc.sys.write_fd(1, s.ptr, s.len);
}

fn emitz(s: [*:0]const u8) void {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    _ = flibc.sys.write_fd(1, s, n);
}

export fn main(argc: usize, argv: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    var i: usize = 1;
    while (i < argc) : (i += 1) {
        const s = argv[i] orelse break;
        emitz(s);
        if (i + 1 < argc) emit(" ");
    }
    emit("\n");
    flibc.exit();
}
