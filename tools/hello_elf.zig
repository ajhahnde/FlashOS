// Minimal AArch64 freestanding ELF for the [TEST] exec-elf scenario.
// Built as a separate executable in build.zig (pie=false, strip,
// ReleaseSmall) and embedded into the kernel image via .incbin in
// tools/hello_elf.S so the in-kernel test harness can hand its bytes to
// sys_exec without an initramfs (Phase 3) or filesystem (Phase 4).
//
// Body is pure inline asm with the syscall numbers from
// lib/syscall_defs.zig hard-coded (SYS_WRITE=0, SYS_EXIT=2). The
// payload string lives in the same .text section, reached PC-relative
// via `adr` so the loader is free to map this segment anywhere — the
// blob is fully position-independent at instruction granularity even
// though the ELF itself is ET_EXEC.

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\.balign 8
        \\    mov x8, #0
        \\    adr x0, 1f
        \\    svc #0
        \\    mov x8, #2
        \\    svc #0
        \\1:
        \\    .ascii "elf hello\n"
        \\    .byte 0
    );
}
