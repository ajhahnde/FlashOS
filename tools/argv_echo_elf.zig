// Payload for [TEST] execve — proves the sys_execve path end to end:
// argv arrives on the freshly mapped user stack as x0 = argc, x1 = argv
// (AAPCS64), and the ELF is deliberately > 4 KiB so it can only load
// through sys_execve's PT_LOAD streaming. A single-page demo would also
// fit the legacy sys_exec snapshot cap and prove nothing about the cap
// being gone. The body walks argv[0..argc] and printf("%s\n", …) each,
// then exits.
//
// Entry: the flibc _start argc/argv shim (user_space/lib/flibc/start.zig),
// pulled into the compilation by the `comptime _ = @import("flibc_start")`
// below — addImport alone only makes a module available; Zig compiles it
// only when referenced, and the shim's `@export _start` must actually be
// emitted for ENTRY(_start) to resolve. The shim's `extern fn main` binds
// to the `export fn main` below; a plain `pub fn main` would not emit the
// C symbol the shim links against (link error: undefined symbol main).
//
// Build: aarch64-freestanding ET_EXEC via build.zig (pie=false, strip,
// ReleaseSmall, hello-style page caps), staged into the initramfs at
// /test/argv_echo.elf.

const flibc = @import("flibc");

comptime {
    _ = @import("flibc_start");
}

// .rodata padding that forces the linked ELF past one 4 KiB page so it
// can only travel sys_execve's streaming loader. The keep_pad() volatile
// asm below makes &PAD escape: a plain `_ = &PAD` is elided under
// ReleaseSmall (LLVM drops the dead address-of and GCs the unreferenced
// global, leaving a sub-page ELF). The volatile asm with PAD as an input
// operand and a memory clobber cannot be removed, so the section stays
// and --gc-sections keeps it — without polluting the argv output.
const PAD: [4096]u8 linksection(".rodata") = .{0xAB} ** 4096;

inline fn keep_pad() void {
    asm volatile (""
        :
        : [p] "r" (&PAD),
        : .{ .memory = true });
}

export fn main(argc: usize, argv: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    keep_pad();
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const s = argv[i] orelse break;
        flibc.printf("%s\n", .{s});
    }
    flibc.exit();
}
