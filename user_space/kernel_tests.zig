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

const SYS_WRITE_NUM: u64 = 0;
const SYS_FORK_NUM: u64 = 1;
const SYS_EXIT_NUM: u64 = 2;
const SYS_WAIT_NUM: u64 = 3;
const SYS_DUMP_FREE_NUM: u64 = 4;
const SYS_EXEC_NUM: u64 = 5;
const SYS_KILL_NUM: u64 = 6;

pub fn sys_write(buf: [*:0]const u8) linksection(".text.user") void {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (SYS_WRITE_NUM),
          [buf] "{x0}" (buf),
        : .{ .memory = true });
}

pub fn sys_fork() linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (SYS_FORK_NUM),
        : .{ .memory = true });
}

pub fn sys_exit() linksection(".text.user") noreturn {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (SYS_EXIT_NUM),
        : .{ .memory = true });
    unreachable;
}

pub fn sys_wait() linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (SYS_WAIT_NUM),
        : .{ .memory = true });
}

// Returns the kernel's free-page count (and prints it to Mini-UART
// as the side effect that preserves the existing trace shape). The
// value powers the [PASS]/[FAIL] decision in each scenario.
pub fn sys_dump_free() linksection(".text.user") u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [nr] "{x8}" (SYS_DUMP_FREE_NUM),
        : .{ .memory = true });
}

pub fn sys_kill(pid: i32) linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (SYS_KILL_NUM),
          [pid] "{x0}" (pid),
        : .{ .memory = true });
}

pub fn sys_exec(blob_addr: u64, blob_size: u64) linksection(".text.user") i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (SYS_EXEC_NUM),
          [addr] "{x0}" (blob_addr),
          [size] "{x1}" (blob_size),
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

const TEST_FORK_STRESS: [*:0]const u8 linksection(".rodata.user") = "[TEST] fork-stress\n";
const PASS_FORK_STRESS: [*:0]const u8 linksection(".rodata.user") = "[PASS] fork-stress\n";
const FAIL_FORK_STRESS: [*:0]const u8 linksection(".rodata.user") = "[FAIL] fork-stress\n";
const TEST_KILL: [*:0]const u8 linksection(".rodata.user") = "[TEST] kill\n";
const PASS_KILL: [*:0]const u8 linksection(".rodata.user") = "[PASS] kill\n";
const FAIL_KILL: [*:0]const u8 linksection(".rodata.user") = "[FAIL] kill\n";
const TEST_EXEC: [*:0]const u8 linksection(".rodata.user") = "[TEST] exec\n";
const PASS_EXEC: [*:0]const u8 linksection(".rodata.user") = "[PASS] exec\n";
const FAIL_EXEC: [*:0]const u8 linksection(".rodata.user") = "[FAIL] exec\n";

const SLASH: [*:0]const u8 linksection(".rodata.user") = "/";
const PASSED_SUFFIX: [*:0]const u8 linksection(".rodata.user") = " passed\n";
const D0: [*:0]const u8 linksection(".rodata.user") = "0";
const D1: [*:0]const u8 linksection(".rodata.user") = "1";
const D2: [*:0]const u8 linksection(".rodata.user") = "2";
const D3: [*:0]const u8 linksection(".rodata.user") = "3";
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
        sys_write(str);
        sys_write(NEWLINE);
        var d: u32 = 100_000;
        while (d > 0) : (d -= 1) {}
    }
    sys_exit();
}

// Loop forever printing `str`. Used by the sys_kill test child — it never
// reaches sys_exit; the parent's sys_kill is what flips it to TASK_ZOMBIE.
fn loop_forever(str: [*:0]const u8) linksection(".text.user") noreturn {
    while (true) {
        sys_write(str);
        sys_write(NEWLINE);
        var d: u32 = 100_000;
        while (d > 0) : (d -= 1) {}
    }
}

// ---- Exec-target blob ----
//
// Raw aarch64 instructions plus an inline string. On entry (post-exec)
// PC = uva 0, x0..x30 = 0, sp = USER_SP_INIT_POS. Sequence:
// sys_write(adr 1f) ; sys_exit. The label `1f` resolves PC-relative
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

// ---- Scenarios ----

fn run_fork_stress(baseline: u64) linksection(".text.user") bool {
    sys_write(TEST_FORK_STRESS);
    var ok = true;

    var round: u32 = 0;
    while (round < NUM_ROUNDS) : (round += 1) {
        var spawned: u32 = 0;
        while (spawned < NUM_CHILDREN) : (spawned += 1) {
            const pid = sys_fork();
            if (pid < 0) {
                sys_write(FORK_ERR_MSG);
                ok = false;
                break;
            }
            if (pid == 0) {
                loop(CHILD_TAG, CHILD_ITERS);
            }
            sys_write(PARENT_TAG);
            sys_write(NEWLINE);
        }

        var reaped: u32 = 0;
        while (reaped < NUM_CHILDREN) : (reaped += 1) {
            _ = sys_wait();
            sys_write(PARENT_TAG);
            sys_write(NEWLINE);
        }

        if (sys_dump_free() != baseline) ok = false;
    }

    sys_write(DONE_MSG);
    if (sys_dump_free() != baseline) ok = false;
    sys_write(if (ok) PASS_FORK_STRESS else FAIL_FORK_STRESS);
    return ok;
}

fn run_kill(baseline: u64) linksection(".text.user") bool {
    sys_write(TEST_KILL);
    var ok = true;

    const kill_pid = sys_fork();
    if (kill_pid < 0) {
        sys_write(FORK_ERR_MSG);
        sys_write(FAIL_KILL);
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
    sys_write(KILL_OK_MSG);
    sys_write(if (ok) PASS_KILL else FAIL_KILL);
    return ok;
}

fn run_exec(baseline: u64) linksection(".text.user") bool {
    sys_write(TEST_EXEC);
    var ok = true;

    const exec_pid = sys_fork();
    if (exec_pid < 0) {
        sys_write(FORK_ERR_MSG);
        sys_write(FAIL_EXEC);
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
    sys_write(EXEC_OK_MSG);
    sys_write(if (ok) PASS_EXEC else FAIL_EXEC);
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
    const total: u32 = 3;
    if (run_fork_stress(baseline)) passed += 1;
    if (run_kill(baseline)) passed += 1;
    if (run_exec(baseline)) passed += 1;
    return .{ .passed = passed, .total = total };
}

pub fn print_tally(passed: u32, total: u32) linksection(".text.user") void {
    write_digit(passed);
    sys_write(SLASH);
    write_digit(total);
    sys_write(PASSED_SUFFIX);
}

// 0..3 cover the current 3-scenario suite; '?' guards against drift
// if new tests are added without updating this chain.
//
// Written as an if/else chain — NOT a switch and NOT an array index —
// because the user image is copied to uva 0 at runtime; both a switch
// jump table and a const array of pointers would bake in absolute
// link-time addresses for D0..D3 and fault when dereferenced from
// uva 0. Only PC-relative `adr` references survive the relocation,
// which is what direct `sys_write(D_n)` produces.
fn write_digit(n: u32) linksection(".text.user") void {
    if (n == 0) sys_write(D0)
    else if (n == 1) sys_write(D1)
    else if (n == 2) sys_write(D2)
    else if (n == 3) sys_write(D3)
    else sys_write(QMARK);
}
