// ls — directory-listing coreutil for /bin/ls. The
// first consumer of sys_readdir (slot 37). With no arguments it lists the
// current directory (passes "."; the syscall joins it against the task's
// cwd, exactly as open / chdir do); with arguments it lists each path in
// turn. Each entry's basename is written to fd 1, a trailing '/' appended
// for a directory (DT_DIR), then a newline. No flags (`-l` / `-a`), no
// recursion, no per-entry stat — those are fsh-v2 / later-phase scope.
//
// Stateless enumeration: the loop hands sys_readdir a fresh index each
// call until it returns -1 (end-of-directory / bad path). A missing or
// empty directory simply lists nothing — flibc has no stat to tell the
// two apart, and the minimal coreutil does not diagnose it.
//
// I/O is the unified write_fd (slot 33); the Dirent lives on the stack
// (rule 1, no heap). flibc_mem is imported for parity with echo / cat:
// the basename-length scan can lower to a libcall, and keeping the import
// uniform means a later tweak that introduces one cannot regress the link.

const flibc = @import("flibc");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

fn emit(s: []const u8) void {
    _ = flibc.sys.write_fd(1, s.ptr, s.len);
}

fn listDir(path: [*:0]const u8) void {
    var d: flibc.Dirent = .{};
    var i: u64 = 0;
    while (flibc.sys.readdir(path, i, &d) == 0) : (i += 1) {
        var n: usize = 0;
        while (n < d.name.len and d.name[n] != 0) : (n += 1) {}
        _ = flibc.sys.write_fd(1, &d.name, n);
        if (d.d_type == flibc.DT_DIR) emit("/");
        emit("\n");
    }
}

export fn main(argc: usize, argv: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    if (argc <= 1) {
        listDir(".");
    } else {
        var a: usize = 1;
        while (a < argc) : (a += 1) {
            const path = argv[a] orelse break;
            listDir(path);
        }
    }
    flibc.exit();
}
