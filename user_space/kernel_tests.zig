// In-kernel runtime test harness.
//
// Formalises the fork-stress / kill / exec cycles into a
// `[TEST]/[PASS]/[FAIL]` suite with a final `X/Y passed\n` tally.
// Each scenario validates against the free-page baseline captured at
// PID 1 startup; any post-reap mismatch flips that scenario to [FAIL]
// and decrements the tally.
//
// Compiled into the same user_init.o object as user_space/init.zig
// (init.zig @imports this file). All decls land in .text.user /
// .rodata.user / .data.user via linksection — the linker script
// wraps those into the user_start / user_end blob the kernel copies
// at PID 1 setup.

// ---- Syscall ABI ----
//
// Numbers come from lib/syscall_defs.zig — same constants the kernel
// uses to populate sys_call_table in src/sys.zig, so a renumbering is a
// single-file edit.

const defs = @import("syscall_defs");

// Renamed from sys_write in v0.3.0 step 1.3 — slot 0 / SYS_WRITE
// constant stay stable (phase 8 decides whether the slot becomes the
// generic write(fd,buf,len)). The user-side rename is mechanical and
// matches the kernel-side handler name (src/sys.zig:sys_writeConsole).
pub fn sys_writeConsole(buf: [*:0]const u8) linksection(".text.user") void {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (defs.SYS_WRITE),
          [buf] "{x0}" (buf),
        : .{ .memory = true });
}

pub fn sys_openConsole(mode: i32) linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_OPEN_CONSOLE),
          [mode] "{x0}" (mode),
        : .{ .memory = true });
}

pub fn sys_readConsole(buf: [*]u8, len: u64) linksection(".text.user") i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_READ_CONSOLE),
          [buf] "{x0}" (buf),
          [len] "{x1}" (len),
        : .{ .memory = true });
}

// FIXME(phase 4/8): debug-only — see lib/syscall_defs.zig
// SYS_CONSOLE_INJECT note. Powers the QEMU-side deterministic
// console-echo scenario.
pub fn sys_console_inject(byte: u8) linksection(".text.user") void {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (defs.SYS_CONSOLE_INJECT),
          [b] "{x0}" (byte),
        : .{ .memory = true });
}

pub fn sys_fork() linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_FORK),
        : .{ .memory = true });
}

pub fn sys_exit() linksection(".text.user") noreturn {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (defs.SYS_EXIT),
        : .{ .memory = true });
    unreachable;
}

pub fn sys_wait() linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_WAIT),
        : .{ .memory = true });
}

// Returns the kernel's free-page count (and prints it to Mini-UART
// as the side effect that preserves the existing trace shape). The
// value powers the [PASS]/[FAIL] decision in each scenario.
pub fn sys_dump_free() linksection(".text.user") u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [nr] "{x8}" (defs.SYS_DUMP_FREE),
        : .{ .memory = true });
}

pub fn sys_kill(pid: i32) linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_KILL),
          [pid] "{x0}" (pid),
        : .{ .memory = true });
}

pub fn sys_exec(blob_addr: u64, blob_size: u64) linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_EXEC),
          [addr] "{x0}" (blob_addr),
          [size] "{x1}" (blob_size),
        : .{ .memory = true });
}

// brk(addr) — set heap break to `addr` (rounded up to page boundary).
// Returns the new break, or current if `addr == 0`. Negative return
// = error (out of bounds against [HEAP_BASE, STACK_TOP - budget)).
// i64 because the heap range covers UVAs that don't fit in i32.
pub fn sys_brk(addr: u64) linksection(".text.user") i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_BRK),
          [addr] "{x0}" (addr),
        : .{ .memory = true });
}

// sys_pipe returns both fds packed into one i64: low 32 bits = read fd,
// high 32 bits = write fd. Negative on failure. Compact ABI matches
// src/sys.zig:sys_pipe — single-register return keeps the wrapper
// trivial and avoids any copy_to_user dance.
pub fn sys_pipe() linksection(".text.user") i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_PIPE),
        : .{ .memory = true });
}

pub fn sys_pipe_read(fd: i32, buf: [*]u8, len: u64) linksection(".text.user") i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_PIPE_READ),
          [fd] "{x0}" (fd),
          [buf] "{x1}" (buf),
          [len] "{x2}" (len),
        : .{ .memory = true });
}

pub fn sys_pipe_write(fd: i32, buf: [*]const u8, len: u64) linksection(".text.user") i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_PIPE_WRITE),
          [fd] "{x0}" (fd),
          [buf] "{x1}" (buf),
          [len] "{x2}" (len),
        : .{ .memory = true });
}

pub fn sys_pipe_close(fd: i32) linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_PIPE_CLOSE),
          [fd] "{x0}" (fd),
        : .{ .memory = true });
}

// ---- Strings (.rodata.user — must be reachable from user-space) ----

const FORK_ERR_MSG: [*:0]const u8 linksection(".rodata.user") = "fork error\n";
const NEWLINE: [*:0]const u8 linksection(".rodata.user") = "\n";
const CHILD_TAG: [*:0]const u8 linksection(".rodata.user") = "child";
const PARENT_TAG: [*:0]const u8 linksection(".rodata.user") = "parent";
const DONE_MSG: [*:0]const u8 linksection(".rodata.user") = "done\n";
const KILL_OK_MSG: [*:0]const u8 linksection(".rodata.user") = "kill ok\n";
const EXEC_OK_MSG: [*:0]const u8 linksection(".rodata.user") = "exec ok\n";
const EXEC_ELF_OK_MSG: [*:0]const u8 linksection(".rodata.user") = "exec-elf ok\n";
const BRK_OK_MSG: [*:0]const u8 linksection(".rodata.user") = "brk ok\n";
const BRK_CHILD_OK_MSG: [*:0]const u8 linksection(".rodata.user") = "brk child ok\n";
const BRK_CHILD_BAD_MSG: [*:0]const u8 linksection(".rodata.user") = "brk child bad\n";

const TEST_FORK_STRESS: [*:0]const u8 linksection(".rodata.user") = "[TEST] fork-stress\n";
const PASS_FORK_STRESS: [*:0]const u8 linksection(".rodata.user") = "[PASS] fork-stress\n";
const FAIL_FORK_STRESS: [*:0]const u8 linksection(".rodata.user") = "[FAIL] fork-stress\n";
const TEST_KILL: [*:0]const u8 linksection(".rodata.user") = "[TEST] kill\n";
const PASS_KILL: [*:0]const u8 linksection(".rodata.user") = "[PASS] kill\n";
const FAIL_KILL: [*:0]const u8 linksection(".rodata.user") = "[FAIL] kill\n";
const TEST_EXEC: [*:0]const u8 linksection(".rodata.user") = "[TEST] exec\n";
const PASS_EXEC: [*:0]const u8 linksection(".rodata.user") = "[PASS] exec\n";
const FAIL_EXEC: [*:0]const u8 linksection(".rodata.user") = "[FAIL] exec\n";
const TEST_EXEC_ELF: [*:0]const u8 linksection(".rodata.user") = "[TEST] exec-elf\n";
const PASS_EXEC_ELF: [*:0]const u8 linksection(".rodata.user") = "[PASS] exec-elf\n";
const FAIL_EXEC_ELF: [*:0]const u8 linksection(".rodata.user") = "[FAIL] exec-elf\n";
const TEST_BRK: [*:0]const u8 linksection(".rodata.user") = "[TEST] brk\n";
const PASS_BRK: [*:0]const u8 linksection(".rodata.user") = "[PASS] brk\n";
const FAIL_BRK: [*:0]const u8 linksection(".rodata.user") = "[FAIL] brk\n";
const TEST_STACK_OVERFLOW: [*:0]const u8 linksection(".rodata.user") = "[TEST] stack-overflow\n";
const PASS_STACK_OVERFLOW: [*:0]const u8 linksection(".rodata.user") = "[PASS] stack-overflow\n";
const FAIL_STACK_OVERFLOW: [*:0]const u8 linksection(".rodata.user") = "[FAIL] stack-overflow\n";
const TEST_WILD_POINTER: [*:0]const u8 linksection(".rodata.user") = "[TEST] wild-pointer\n";
const PASS_WILD_POINTER: [*:0]const u8 linksection(".rodata.user") = "[PASS] wild-pointer\n";
const FAIL_WILD_POINTER: [*:0]const u8 linksection(".rodata.user") = "[FAIL] wild-pointer\n";
const TEST_FLIBC: [*:0]const u8 linksection(".rodata.user") = "[TEST] flibc\n";
const PASS_FLIBC: [*:0]const u8 linksection(".rodata.user") = "[PASS] flibc\n";
const FAIL_FLIBC: [*:0]const u8 linksection(".rodata.user") = "[FAIL] flibc\n";
const TEST_TRACE: [*:0]const u8 linksection(".rodata.user") = "[TEST] trace\n";
const PASS_TRACE: [*:0]const u8 linksection(".rodata.user") = "[PASS] trace\n";
const FAIL_TRACE: [*:0]const u8 linksection(".rodata.user") = "[FAIL] trace\n";
const TEST_PIPE: [*:0]const u8 linksection(".rodata.user") = "[TEST] pipe\n";
const PASS_PIPE: [*:0]const u8 linksection(".rodata.user") = "[PASS] pipe\n";
const FAIL_PIPE: [*:0]const u8 linksection(".rodata.user") = "[FAIL] pipe\n";
const PIPE_OK_MSG: [*:0]const u8 linksection(".rodata.user") = "pipe ok\n";
const PIPE_BAD_MSG: [*:0]const u8 linksection(".rodata.user") = "pipe bad\n";
const TEST_CONSOLE_ECHO: [*:0]const u8 linksection(".rodata.user") = "[TEST] console-echo\n";
const PASS_CONSOLE_ECHO: [*:0]const u8 linksection(".rodata.user") = "[PASS] console-echo\n";
const FAIL_CONSOLE_ECHO: [*:0]const u8 linksection(".rodata.user") = "[FAIL] console-echo\n";
const ECHO_OK_MSG: [*:0]const u8 linksection(".rodata.user") = "echo ok\n";
const ECHO_BAD_MSG: [*:0]const u8 linksection(".rodata.user") = "echo bad\n";

const SLASH: [*:0]const u8 linksection(".rodata.user") = "/";
const PASSED_SUFFIX: [*:0]const u8 linksection(".rodata.user") = " passed\n";
const D0: [*:0]const u8 linksection(".rodata.user") = "0";
const D1: [*:0]const u8 linksection(".rodata.user") = "1";
const D2: [*:0]const u8 linksection(".rodata.user") = "2";
const D3: [*:0]const u8 linksection(".rodata.user") = "3";
const D4: [*:0]const u8 linksection(".rodata.user") = "4";
const D5: [*:0]const u8 linksection(".rodata.user") = "5";
const D6: [*:0]const u8 linksection(".rodata.user") = "6";
const D7: [*:0]const u8 linksection(".rodata.user") = "7";
const D8: [*:0]const u8 linksection(".rodata.user") = "8";
const D9: [*:0]const u8 linksection(".rodata.user") = "9";
const QMARK: [*:0]const u8 linksection(".rodata.user") = "?";

// ---- Test parameters ----

const NUM_ROUNDS: u32 = 3;
const NUM_CHILDREN: u32 = 5;
const CHILD_ITERS: u32 = 10;

// ---- Children ----

// Run `iters` print iterations and then sys_exit. Used by children only,
// so the call is noreturn. Parent's print bursts are inlined into the
// scenario bodies.
fn loop(str: [*:0]const u8, iters: u32) linksection(".text.user") noreturn {
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        sys_writeConsole(str);
        sys_writeConsole(NEWLINE);
        var d: u32 = 100_000;
        while (d > 0) : (d -= 1) {}
    }
    sys_exit();
}

// Loop forever printing `str`. Used by the sys_kill test child — it never
// reaches sys_exit; the parent's sys_kill is what flips it to TASK_ZOMBIE.
fn loop_forever(str: [*:0]const u8) linksection(".text.user") noreturn {
    while (true) {
        sys_writeConsole(str);
        sys_writeConsole(NEWLINE);
        var d: u32 = 100_000;
        while (d > 0) : (d -= 1) {}
    }
}

// ---- Exec-target blob ----
//
// Raw aarch64 instructions plus an inline string. On entry (post-exec)
// PC = uva 0, x0..x30 = 0, sp = USER_SP_INIT_POS. Sequence:
// sys_writeConsole(adr 1f) ; sys_exit. The label `1f` resolves PC-relative
// inside the blob, so the new code page (the only thing mapped at
// uva 0 after exec) is fully self-contained. `export` keeps the
// optimizer from tree-shaking it; the symbol itself is never called,
// only `adr`-referenced via exec_blob_start_addr below. The .balign 8
// markers enforce the 8-byte alignment sys_exec's kernel-side memcpy
// requires while user pages are mapped Device-typed.
export fn _exec_blob() linksection(".text.user.exec_blob") callconv(.naked) noreturn {
    asm volatile (
        \\.balign 8
        \\.globl _exec_blob_start
        \\_exec_blob_start:
        \\    mov x8, #0
        \\    adr x0, 1f
        \\    svc #0
        \\    mov x8, #2
        \\    svc #0
        \\1:
        \\    .ascii "exec'd\n"
        \\    .byte 0
        \\.balign 8
        \\.globl _exec_blob_end
        \\_exec_blob_end:
    );
}

// PC-relative resolution of the blob's runtime user-VA. `adr` produces
// a position-independent reference, which is the only kind that
// survives the user image being copied to UVA 0 at runtime.
fn exec_blob_start_addr() linksection(".text.user") u64 {
    return asm volatile (
        \\adr %[ret], _exec_blob_start
        : [ret] "=r" (-> u64),
    );
}

fn exec_blob_end_addr() linksection(".text.user") u64 {
    return asm volatile (
        \\adr %[ret], _exec_blob_end
        : [ret] "=r" (-> u64),
    );
}

// ---- Hello-ELF bridge ----
//
// tools/hello_elf.S `.incbin`s `hello.elf` into kernel `.rodata` between
// `hello_elf_start` and `hello_elf_end`, both at TTBR1 high-mem. From
// EL0 those VAs are unreachable directly: an `adrp+add` against a
// 0xffff_… symbol would overflow the 4 GB range, and even a literal
// pool would be in kernel `.rodata` rather than in the user image.
//
// Solution: bake the kernel-VAs of the start AND end labels into u64
// slots that live INSIDE the user image (.text.user.elf_bridge —
// caught by linker.ld's .text.user wildcard). Each `.quad symbol`
// emits a single R_AARCH64_ABS64 relocation that the linker resolves
// at link time to the symbol's absolute VA. We deliberately do NOT
// write `.quad hello_elf_end - hello_elf_start` here: GAS rejects
// subtraction of two symbols whose definitions live in a different TU
// because no single ABS64 reloc can represent the difference. The
// size is instead computed at EL0 runtime as `hello_elf_kend -
// hello_elf_kva` from the two slots.
//
// At runtime the user image is relocated to UVA 0, so the *slot*
// address moves, but the slot's CONTENTS (the kernel-VAs) are
// unchanged. The user reads the slots via PC-relative `adrp+add+ldr`
// against the slot label — both PC and slot are in the same image, so
// that addressing mode is relocation-safe — and hands the resulting
// kernel-VA + size to sys_exec, which runs at EL1 and walks TTBR1
// happily.
//
// The naked fn is never called; declaring it as `noreturn` placates
// Zig and the inline asm body emits raw `.quad` directives whose
// labels become globals. Section is `.text.user.elf_bridge` (under
// `.text.user.*`, picked up by linker.ld's `*user_init*.o(.text .text.*)`).
export fn _hello_elf_bridge() linksection(".text.user.elf_bridge") callconv(.naked) noreturn {
    // Slots hold the *TTBR1 alias* of the kernel-rodata symbols, not
    // the bare link-time address. The kernel runs at low link-VAs but
    // executes through `0xffff_…` linear-map mappings; passing the bare
    // low VA through `sys_exec` lands the kernel's `memcpy` on a TTBR0
    // walk against the user pgd (which doesn't map kernel rodata) and
    // takes a translation fault. ORing LINEAR_MAP_BASE here produces a
    // single ABS64 relocation the linker resolves at build time.
    asm volatile (
        \\.balign 8
        \\.globl hello_elf_kva
        \\hello_elf_kva:
        \\    .quad hello_elf_start + 0xffff000000000000
        \\.globl hello_elf_kend
        \\hello_elf_kend:
        \\    .quad hello_elf_end + 0xffff000000000000
    );
}

// Slot readers — `extern const` references make the compiler emit a
// literal-pool `adrp+ldr` against the slot's link-time VA, which
// breaks once the user image is copied to UVA 0 (the adrp page is
// resolved against the link-time PC, not the runtime PC). Inline asm
// `adr` is PC-relative within ±1 MiB and survives the relocation —
// same pattern as `_exec_blob_start_addr` above. The follow-up `ldr`
// dereferences the slot to recover the kernel-VA the linker wrote.
fn hello_elf_kva_val() linksection(".text.user") u64 {
    return asm volatile (
        \\adr %[ret], hello_elf_kva
        \\ldr %[ret], [%[ret]]
        : [ret] "=r" (-> u64),
    );
}

fn hello_elf_kend_val() linksection(".text.user") u64 {
    return asm volatile (
        \\adr %[ret], hello_elf_kend
        \\ldr %[ret], [%[ret]]
        : [ret] "=r" (-> u64),
    );
}

// ---- Stackbomb-ELF bridge ----
//
// Same shape as the hello bridge above — the linker resolves the
// .quad directives to the kernel-VA of the rodata payload, the slot's
// CONTENTS survive the user image being copied to UVA 0, and EL0 reads
// the slot via PC-relative `adr+ldr` to recover the kernel-VA at
// runtime. See _hello_elf_bridge for the full reasoning.
export fn _stackbomb_elf_bridge() linksection(".text.user.elf_bridge") callconv(.naked) noreturn {
    asm volatile (
        \\.balign 8
        \\.globl stackbomb_elf_kva
        \\stackbomb_elf_kva:
        \\    .quad stackbomb_elf_start + 0xffff000000000000
        \\.globl stackbomb_elf_kend
        \\stackbomb_elf_kend:
        \\    .quad stackbomb_elf_end + 0xffff000000000000
    );
}

fn stackbomb_elf_kva_val() linksection(".text.user") u64 {
    return asm volatile (
        \\adr %[ret], stackbomb_elf_kva
        \\ldr %[ret], [%[ret]]
        : [ret] "=r" (-> u64),
    );
}

fn stackbomb_elf_kend_val() linksection(".text.user") u64 {
    return asm volatile (
        \\adr %[ret], stackbomb_elf_kend
        \\ldr %[ret], [%[ret]]
        : [ret] "=r" (-> u64),
    );
}

// ---- flibc_demo-ELF bridge ----
//
// Same shape as the hello / stackbomb bridges above — see
// _hello_elf_bridge for the full reasoning. The .quad slots resolve to
// the kernel-VAs of the .rodata payload at link time; EL0 reads them
// PC-relative so the slot-content survives the user image being copied
// to UVA 0 at PID 1 setup.
export fn _flibc_demo_elf_bridge() linksection(".text.user.elf_bridge") callconv(.naked) noreturn {
    asm volatile (
        \\.balign 8
        \\.globl flibc_demo_elf_kva
        \\flibc_demo_elf_kva:
        \\    .quad flibc_demo_elf_start + 0xffff000000000000
        \\.globl flibc_demo_elf_kend
        \\flibc_demo_elf_kend:
        \\    .quad flibc_demo_elf_end + 0xffff000000000000
    );
}

fn flibc_demo_elf_kva_val() linksection(".text.user") u64 {
    return asm volatile (
        \\adr %[ret], flibc_demo_elf_kva
        \\ldr %[ret], [%[ret]]
        : [ret] "=r" (-> u64),
    );
}

fn flibc_demo_elf_kend_val() linksection(".text.user") u64 {
    return asm volatile (
        \\adr %[ret], flibc_demo_elf_kend
        \\ldr %[ret], [%[ret]]
        : [ret] "=r" (-> u64),
    );
}

// ---- Scenarios ----

fn run_fork_stress(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_FORK_STRESS);
    var ok = true;

    var round: u32 = 0;
    while (round < NUM_ROUNDS) : (round += 1) {
        var spawned: u32 = 0;
        while (spawned < NUM_CHILDREN) : (spawned += 1) {
            const pid = sys_fork();
            if (pid < 0) {
                sys_writeConsole(FORK_ERR_MSG);
                ok = false;
                break;
            }
            if (pid == 0) {
                loop(CHILD_TAG, CHILD_ITERS);
            }
            sys_writeConsole(PARENT_TAG);
            sys_writeConsole(NEWLINE);
        }

        var reaped: u32 = 0;
        while (reaped < NUM_CHILDREN) : (reaped += 1) {
            _ = sys_wait();
            sys_writeConsole(PARENT_TAG);
            sys_writeConsole(NEWLINE);
        }

        if (sys_dump_free() != baseline) ok = false;
    }

    sys_writeConsole(DONE_MSG);
    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_FORK_STRESS else FAIL_FORK_STRESS);
    return ok;
}

fn run_kill(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_KILL);
    var ok = true;

    const kill_pid = sys_fork();
    if (kill_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_KILL);
        return false;
    }
    if (kill_pid == 0) {
        loop_forever(CHILD_TAG);
    }

    var d: u32 = 500_000;
    while (d > 0) : (d -= 1) {}
    _ = sys_kill(kill_pid);
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(KILL_OK_MSG);
    sys_writeConsole(if (ok) PASS_KILL else FAIL_KILL);
    return ok;
}

fn run_exec(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_EXEC);
    var ok = true;

    const exec_pid = sys_fork();
    if (exec_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_EXEC);
        return false;
    }
    if (exec_pid == 0) {
        const blob_addr = exec_blob_start_addr();
        const blob_size = exec_blob_end_addr() - blob_addr;
        _ = sys_exec(blob_addr, blob_size);
        // Only reachable on sys_exec failure.
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(EXEC_OK_MSG);
    sys_writeConsole(if (ok) PASS_EXEC else FAIL_EXEC);
    return ok;
}

// Forks a child that asks the kernel to load tools/hello.elf via the
// ELF path of sys_exec (parser + PT_LOAD walk + stack page + entry
// dispatch all live in src/fork.zig:prepare_move_to_user_elf). Success
// criterion mirrors run_exec: the child terminates cleanly (sys_exit
// from the ELF's own _start), the parent reaps it, and the free-page
// count returns to baseline — proving the loader's allocations were
// fully cleaned up by do_wait.
fn run_exec_elf(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_EXEC_ELF);
    var ok = true;

    const exec_pid = sys_fork();
    if (exec_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_EXEC_ELF);
        return false;
    }
    if (exec_pid == 0) {
        const kva = hello_elf_kva_val();
        const kend = hello_elf_kend_val();
        _ = sys_exec(kva, kend - kva);
        // Only reachable on sys_exec failure (parse error / alloc fail).
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(EXEC_ELF_OK_MSG);
    sys_writeConsole(if (ok) PASS_EXEC_ELF else FAIL_EXEC_ELF);
    return ok;
}

// Heap demand-allocation + shrink-and-free coverage. Forks a child that
// reads the initial break (HEAP_BASE, set by prepare_move_to_user when
// PID 1 was loaded — copy_virt_memory inherits it across fork), grows
// the heap by NUM_BRK_PAGES pages, walks the new range writing one
// byte per page (each touch fires do_data_abort which demand-allocates
// the heap page), reads the pattern back, then shrinks the break to
// the original. Success criterion mirrors the other reap-based tests:
// after the parent's wait the free-page count must equal the baseline,
// proving (a) demand-allocated heap pages were tracked in the child's
// user_pages, (b) the brk-shrink path freed them via unmap_user_range,
// and (c) what the shrink missed do_wait swept up. The "brk child ok"
// trace marker is the in-band confirmation that the read-back pattern
// matched — purely informational, the [PASS]/[FAIL] decision is
// baseline-only (mirrors run_exec / run_exec_elf).
const NUM_BRK_PAGES: u32 = 16;
const PAGE_SIZE_USER: u64 = 4096;

fn run_brk(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_BRK);
    var ok = true;

    const brk_pid = sys_fork();
    if (brk_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_BRK);
        return false;
    }
    if (brk_pid == 0) {
        const initial = sys_brk(0);
        if (initial < 0) sys_exit();
        const initial_u: u64 = @bitCast(initial);

        const grown = sys_brk(initial_u + NUM_BRK_PAGES * PAGE_SIZE_USER);
        if (grown < 0) sys_exit();

        // Touch every fresh page once — each store traps to
        // do_data_abort with a level-3 translation fault and the
        // region-aware handler (Phase-2.6) demand-allocates inside
        // the legal heap range [HEAP_BASE, current.mm.brk).
        var page: u32 = 0;
        while (page < NUM_BRK_PAGES) : (page += 1) {
            const ptr: *volatile u8 = @ptrFromInt(initial_u + page * PAGE_SIZE_USER);
            ptr.* = @as(u8, @truncate(page)) +% 0x42;
        }

        // Read back to prove the demand-allocated pages persist (i.e.
        // each fault gave a fresh page that stayed mapped, not a TLB
        // alias of someone else's PA).
        var read_ok = true;
        page = 0;
        while (page < NUM_BRK_PAGES) : (page += 1) {
            const ptr: *volatile const u8 = @ptrFromInt(initial_u + page * PAGE_SIZE_USER);
            const expected: u8 = @as(u8, @truncate(page)) +% 0x42;
            if (ptr.* != expected) read_ok = false;
        }
        sys_writeConsole(if (read_ok) BRK_CHILD_OK_MSG else BRK_CHILD_BAD_MSG);

        // Shrink back to the original break — exercises
        // unmap_user_range so the per-process page balance returns to
        // zero before do_wait. Without this the test would still pass
        // (do_wait reaps the leftover heap pages), so we don't bail
        // even if the shrink itself reports failure.
        _ = sys_brk(initial_u);
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(BRK_OK_MSG);
    sys_writeConsole(if (ok) PASS_BRK else FAIL_BRK);
    return ok;
}

// Forks a child that sys_exec's tools/stackbomb.elf — a tiny
// freestanding aarch64 ET_EXEC whose _start does nothing but recurse,
// pushing 1 KiB per frame. After ~64 frames the child's SP crosses
// STACK_LOW and the next store enters the guard page; the kernel's
// do_data_abort detects the guard fault, prints `[KERN] stack overflow
// at 0x<hex>` to MU, and zombies the task via exit_process. The
// parent's sys_wait reaps as usual, so the per-process page balance
// returns to baseline — that's what this scenario asserts.
//
// The child runs in the post-ELF-load image (SP = STACK_TOP, eager
// top page mapped, layout from src/user_layout.zig), which is the
// only context where the high stack VA is reachable. Forking from
// PID 1's blob image is fine — copy_virt_memory carries over the
// (UVA-0) blob mapping, sys_exec then frees it and rebuilds the
// address space around the stackbomb ELF.
fn run_stack_overflow(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_STACK_OVERFLOW);
    var ok = true;

    const ovf_pid = sys_fork();
    if (ovf_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_STACK_OVERFLOW);
        return false;
    }
    if (ovf_pid == 0) {
        const kva = stackbomb_elf_kva_val();
        const kend = stackbomb_elf_kend_val();
        _ = sys_exec(kva, kend - kva);
        // Only reachable on sys_exec failure (parse error / alloc fail).
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_STACK_OVERFLOW else FAIL_STACK_OVERFLOW);
    return ok;
}

// Forks a child that sys_exec's tools/flibc_demo.elf — a flibc-driven
// payload that exercises printf (%d round-trip), malloc (bump-allocate
// 32 B + pattern verify), and exit. The harness validates kernel
// invariants the same way the existing exec/exec-elf scenarios do
// (parent reaps, free-page baseline holds), and additionally the
// in-band trace markers `flibc hello 42` / `flibc malloc ok` confirm
// flibc's printf and heap layers ran end-to-end. fork/wait/execve
// wrappers are present in flibc but not exercised here — they are
// thin sys_* passthroughs already covered by run_fork_stress and
// run_exec_elf via the kernel's syscall path.
fn run_flibc(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_FLIBC);
    var ok = true;

    const flibc_pid = sys_fork();
    if (flibc_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_FLIBC);
        return false;
    }
    if (flibc_pid == 0) {
        const kva = flibc_demo_elf_kva_val();
        const kend = flibc_demo_elf_kend_val();
        _ = sys_exec(kva, kend - kva);
        // Only reachable on sys_exec failure (parse error / alloc fail).
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_FLIBC else FAIL_FLIBC);
    return ok;
}

// Forks a child that writes one byte to 0xDEADBEEF000 — a UVA that
// falls in the 16 TiB heap-stack gap, outside every legal region
// (heap [HEAP_BASE, brk), stack [STACK_LOW, STACK_TOP), text
// [0, DATA_BASE)). Phase-2.6 do_data_abort classifies it as a wild
// pointer, prints `[KERN] invalid uva at 0x<hex>` to MU and zombies the
// task via exit_process; the parent's sys_wait reaps so the per-process
// page balance returns to baseline — that's what this scenario asserts.
//
// The child runs in the inherited blob image (no sys_exec needed) since
// the wild-pointer path doesn't depend on the loader's layout — only on
// do_data_abort's region classification, which keys off mm.brk + the
// static layout constants.
fn run_wild_pointer(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_WILD_POINTER);
    var ok = true;

    const wp_pid = sys_fork();
    if (wp_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_WILD_POINTER);
        return false;
    }
    if (wp_pid == 0) {
        const wild: *volatile u8 = @ptrFromInt(0xDEADBEEF000);
        wild.* = 0x42;
        // Only reached if do_data_abort failed to zombie the task —
        // shouldn't happen, but exit cleanly so the parent can wait.
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_WILD_POINTER else FAIL_WILD_POINTER);
    return ok;
}

// Forks one child, hands a deterministic 16-byte payload through an
// anonymous pipe (parent reads, child writes), reaps the child, and
// asserts the per-process free-page baseline holds. Coverage spans:
//   * sys_pipe → page allocation + fd-table install for both ends
//   * fork-dup of fd_table (parent and child see the same Pipe object)
//   * child sys_pipe_close on the read end → refcount 2 → 1
//   * sys_pipe_write of full payload → reader wake
//   * parent sys_pipe_read → drains pipe
//   * child sys_pipe_close on the write end + sys_exit → reap
//   * parent sys_pipe_close on the read end → unref → page freed
//
// The pattern is 0xA0..0xAF (16 bytes) — distinct enough that a
// truncation or out-of-order delivery shows up immediately in the
// byte compare. Free-page baseline is the [PASS] gate, matching
// every other reap-based scenario.
const PIPE_PAYLOAD_LEN: u64 = 16;

fn run_pipe(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_PIPE);
    var ok = true;

    const fds = sys_pipe();
    if (fds < 0) {
        sys_writeConsole(FAIL_PIPE);
        return false;
    }
    const rfd: i32 = @intCast(fds & 0xffff_ffff);
    const wfd: i32 = @intCast((fds >> 32) & 0xffff_ffff);

    const pid = sys_fork();
    if (pid < 0) {
        _ = sys_pipe_close(rfd);
        _ = sys_pipe_close(wfd);
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_PIPE);
        return false;
    }
    if (pid == 0) {
        // Child writer: close read end, push payload, close write end.
        _ = sys_pipe_close(rfd);
        var out: [16]u8 = undefined;
        var oi: u32 = 0;
        while (oi < PIPE_PAYLOAD_LEN) : (oi += 1) {
            out[oi] = 0xA0 +% @as(u8, @intCast(oi));
        }
        _ = sys_pipe_write(wfd, &out, PIPE_PAYLOAD_LEN);
        _ = sys_pipe_close(wfd);
        sys_exit();
    }

    // Parent reader: drop write end first so the EOF short-circuit
    // becomes reachable for the child if it ever short-writes.
    _ = sys_pipe_close(wfd);

    // pipe.read short-reads to whatever's currently buffered; loop
    // until we either collect the full payload or hit EOF (child
    // closed the write end). The child writes a single 16-byte burst,
    // but a future short-write semantics change shouldn't break the
    // test.
    var in: [16]u8 = undefined;
    var got: u64 = 0;
    while (got < PIPE_PAYLOAD_LEN) {
        const n = sys_pipe_read(rfd, @ptrCast(&in[got]), PIPE_PAYLOAD_LEN - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != PIPE_PAYLOAD_LEN) ok = false;

    var ci: u32 = 0;
    while (ci < PIPE_PAYLOAD_LEN) : (ci += 1) {
        const expected: u8 = 0xA0 +% @as(u8, @intCast(ci));
        if (in[ci] != expected) ok = false;
    }
    sys_writeConsole(if (ok) PIPE_OK_MSG else PIPE_BAD_MSG);

    _ = sys_pipe_close(rfd);
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_PIPE else FAIL_PIPE);
    return ok;
}

// Drives the console RX path end-to-end (v0.3.0 step 1.3). Forks one
// child that injects ECHO_LEN bytes via SYS_CONSOLE_INJECT after a
// short delay; the parent blocks in sys_readConsole on the empty
// ring, the WaitQueue wake fires on each push, and the parent loops
// because console_read short-returns. The injected pattern
// (0xC0..0xC7) is distinct enough that a truncation or out-of-order
// drain shows up immediately in the byte compare. sys_openConsole(0)
// / (1) are exercised to lock in the ABI even though the returned fd
// is purely synthetic until phase 4 unifies fd-tables.
//
// Test free-page baseline gate matches the other reap-based
// scenarios; the ring buffer lives in BSS, so the baseline must be
// fully restored after the child is reaped.
const ECHO_LEN: u64 = 8;

fn run_console_echo(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_CONSOLE_ECHO);
    var ok = true;

    if (sys_openConsole(0) != 0) ok = false;
    if (sys_openConsole(1) != 1) ok = false;

    const pid = sys_fork();
    if (pid < 0) {
        sys_writeConsole(FAIL_CONSOLE_ECHO);
        return false;
    }
    if (pid == 0) {
        // Delay so the parent reaches sys_readConsole and hits the
        // empty-ring branch first — that's the WaitQueue path we
        // want to cover. The same loop length is used by run_kill;
        // single-core scheduling makes that an upper bound for the
        // parent to enter wait state.
        var d: u32 = 500_000;
        while (d > 0) : (d -= 1) {}
        var i: u32 = 0;
        while (i < ECHO_LEN) : (i += 1) {
            sys_console_inject(0xC0 +% @as(u8, @intCast(i)));
        }
        sys_exit();
    }

    var in: [8]u8 = undefined;
    var got: u64 = 0;
    while (got < ECHO_LEN) {
        const n = sys_readConsole(@ptrCast(&in[got]), ECHO_LEN - got);
        if (n <= 0) {
            ok = false;
            break;
        }
        got += @intCast(n);
    }
    var i: u32 = 0;
    while (i < ECHO_LEN) : (i += 1) {
        const expected: u8 = 0xC0 +% @as(u8, @intCast(i));
        if (in[i] != expected) ok = false;
    }
    sys_writeConsole(if (ok) ECHO_OK_MSG else ECHO_BAD_MSG);
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_CONSOLE_ECHO else FAIL_CONSOLE_ECHO);
    return ok;
}

// Drives the patched trampolines (kernel_main/_schedule/do_wait/copy_process)
// through their canonical user-visible call chain: fork enters copy_process,
// exit/wait routes through do_wait, both legs cross _schedule via timer
// ticks + explicit yields. Four sequential cycles is enough for each
// patched entry to fire; the in-band trace markers land on PL011 (UART4
// on Pi, no-op on virt where pl011_uart_send_string is comptime-stubbed).
// Pass criterion mirrors the other reap-based scenarios: free-page count
// after the loop equals the suite baseline.
fn run_trace(baseline: u64) linksection(".text.user") bool {
    sys_writeConsole(TEST_TRACE);
    var ok = true;

    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const pid = sys_fork();
        if (pid < 0) {
            sys_writeConsole(FORK_ERR_MSG);
            ok = false;
            break;
        }
        if (pid == 0) sys_exit();
        _ = sys_wait();
    }

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_TRACE else FAIL_TRACE);
    return ok;
}

// ---- Runner ----

pub const TestResult = struct {
    passed: u32,
    total: u32,
};

pub fn run_all() linksection(".text.user") TestResult {
    const baseline = sys_dump_free();
    var passed: u32 = 0;
    const total: u32 = 11;
    if (run_fork_stress(baseline)) passed += 1;
    if (run_kill(baseline)) passed += 1;
    if (run_exec(baseline)) passed += 1;
    if (run_exec_elf(baseline)) passed += 1;
    if (run_brk(baseline)) passed += 1;
    if (run_stack_overflow(baseline)) passed += 1;
    if (run_wild_pointer(baseline)) passed += 1;
    if (run_flibc(baseline)) passed += 1;
    if (run_pipe(baseline)) passed += 1;
    if (run_console_echo(baseline)) passed += 1;
    if (run_trace(baseline)) passed += 1;
    return .{ .passed = passed, .total = total };
}

// Tens-digit unrolling: write_digit only covers 0..9 directly. The
// suite now reports 10/10, so decompose two-digit values into
// `(n / 10)` then `(n % 10)`. Single-digit values stay unchanged.
// Up to 99/99 — phase 5 can revisit if the suite ever overflows.
pub fn print_tally(passed: u32, total: u32) linksection(".text.user") void {
    if (passed >= 10) {
        write_digit(passed / 10);
        write_digit(passed % 10);
    } else write_digit(passed);
    sys_writeConsole(SLASH);
    if (total >= 10) {
        write_digit(total / 10);
        write_digit(total % 10);
    } else write_digit(total);
    sys_writeConsole(PASSED_SUFFIX);
}

// 0..9 cover the current 9-scenario suite; '?' guards against drift
// if new tests are added without updating this chain.
//
// Written as an if/else chain — NOT a switch and NOT an array index —
// because the user image is copied to uva 0 at runtime; both a switch
// jump table and a const array of pointers would bake in absolute
// link-time addresses for D0..D9 and fault when dereferenced from
// uva 0. Only PC-relative `adr` references survive the relocation,
// which is what direct `sys_writeConsole(D_n)` produces.
fn write_digit(n: u32) linksection(".text.user") void {
    if (n == 0) sys_writeConsole(D0)
    else if (n == 1) sys_writeConsole(D1)
    else if (n == 2) sys_writeConsole(D2)
    else if (n == 3) sys_writeConsole(D3)
    else if (n == 4) sys_writeConsole(D4)
    else if (n == 5) sys_writeConsole(D5)
    else if (n == 6) sys_writeConsole(D6)
    else if (n == 7) sys_writeConsole(D7)
    else if (n == 8) sys_writeConsole(D8)
    else if (n == 9) sys_writeConsole(D9)
    else sys_writeConsole(QMARK);
}
