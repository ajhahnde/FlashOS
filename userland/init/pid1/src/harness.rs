//! The in-kernel runtime test harness.
//!
//! Thirty scenarios that drive the kernel from EL0 and report `[TEST]` / `[PASS]` /
//! `[FAIL]` plus a closing `X/Y passed` tally. Each one validates against the
//! free-page count captured at PID 1 startup: a scenario that ends with the pool off
//! its baseline leaked a page, and that flips it to `[FAIL]` no matter what else it
//! proved. `scripts/run_qemu_test.sh` is the consumer -- it counts the scenarios, the
//! per-scenario free-page checkpoints, and the boot markers, so the lines below are a
//! contract, not diagnostics.
//!
//! Only PID 1 links this. It runs when the harness gate is on; a plain boot skips
//! straight to the login hand-off.

use crate::marks::*;
use crate::probe::*;
use flashsdk_abi::syscall::{Dirent, EACCES};
use flashsdk_rt::syscall as sys;

// ---- output -----------------------------------------------------------------

/// Every trace line the harness emits goes through the unified write path on fd 1,
/// so each one also exercises the syscall it is reporting through.
fn out(bytes: &[u8]) {
    let _ = sys::write(sys::STDOUT, bytes);
}

/// The verdict line: one write, one line, whichever way the scenario went.
fn verdict(ok: bool, pass: &[u8], fail: &[u8]) {
    out(if ok { pass } else { fail });
}

// ---- trace strings ----------------------------------------------------------

const FORK_ERR_MSG: &[u8] = b"fork error\n";
const NEWLINE: &[u8] = b"\n";
const CHILD_TAG: &[u8] = b"child";
const PARENT_TAG: &[u8] = b"parent";
const DONE_MSG: &[u8] = b"done\n";
const KILL_OK_MSG: &[u8] = b"kill ok\n";
const EXEC_ELF_OK_MSG: &[u8] = b"exec-elf ok\n";
const BRK_OK_MSG: &[u8] = b"brk ok\n";
const BRK_CHILD_OK_MSG: &[u8] = b"brk child ok\n";
const BRK_CHILD_BAD_MSG: &[u8] = b"brk child bad\n";
const PIPE_OK_MSG: &[u8] = b"pipe ok\n";
const PIPE_BAD_MSG: &[u8] = b"pipe bad\n";
const ECHO_OK_MSG: &[u8] = b"echo ok\n";
const ECHO_BAD_MSG: &[u8] = b"echo bad\n";
const FD_REDIRECT_OK_MSG: &[u8] = b"fd-redirect ok\n";
const FD_REDIRECT_BAD_MSG: &[u8] = b"fd-redirect bad\n";
const PASSED_SUFFIX: &[u8] = b" passed\n";

/// Sub-sector writeBack probe, reported under `[DBG]` so the oracle's
/// `[PASS]`/`[FAIL]`/checkpoint greps never see it and the tally cannot move.
const MAG_INBOOT_OK: &[u8] = b"[DBG] mag-inboot=01 (1-byte writeBack OK)\n";
const MAG_INBOOT_BAD: &[u8] = b"[DBG] mag-inboot=00 (1-byte writeBack REGRESSION)\n";
const CRUD_OK: &[u8] = b"[DBG] fs-crud OK (create/write/rename/unlink)\n";

// ---- parameters -------------------------------------------------------------

const NUM_ROUNDS: u32 = 3;
const NUM_CHILDREN: u32 = 5;
const CHILD_ITERS: u32 = 10;
const PAGE_SIZE_USER: u64 = 4096;

/// The canonical wild UVA: it sits in the 16 TiB heap-stack gap, outside every legal
/// region. Shared by wild-pointer (an EL0 store -- the data-abort hard path) and
/// efault-syscall (the same address handed to a syscall -- the soft path).
const WILD_UVA_CANONICAL: u64 = 0xDEAD_BEEF_000;

// ---- children ---------------------------------------------------------------

/// Burn `iters` iterations without the optimiser folding the loop away. The delay is
/// load-bearing: it is what lets a parent reach its blocking read before the child
/// runs, so the wait-queue path is the one under test rather than a lucky race.
fn spin(iters: u32) {
    let mut d = iters;
    while d > 0 {
        d = core::hint::black_box(d - 1);
    }
}

/// Print `str` `iters` times, then exit. Children only, hence the `!`.
fn child_loop(tag: &[u8], iters: u32) -> ! {
    let mut i = 0;
    while i < iters {
        out(tag);
        out(NEWLINE);
        spin(100_000);
        i += 1;
    }
    sys::exit(0)
}

/// Print forever. The kill scenario's child: it never reaches an exit of its own --
/// the parent's `kill` is what zombifies it.
fn child_loop_forever(tag: &[u8]) -> ! {
    loop {
        out(tag);
        out(NEWLINE);
        spin(100_000);
    }
}

/// Exec `path` with `argv` in the calling (forked) task, then exit. `exec_path`
/// returns only on failure -- a resolve, parse, or allocation error -- so the exit
/// below is that error path, not the success one.
fn exec_or_exit(path: &[u8], argv: &[*const u8]) -> ! {
    unsafe {
        sys::exec_path(path.as_ptr(), argv.as_ptr());
    }
    sys::exit(0)
}

// ---- scenarios --------------------------------------------------------------

fn run_fork_stress(baseline: u64) -> bool {
    out(&TEST_FORK_STRESS);
    let mut ok = true;

    let mut round = 0;
    while round < NUM_ROUNDS {
        let mut spawned = 0;
        while spawned < NUM_CHILDREN {
            let pid = sys::fork();
            if pid < 0 {
                out(FORK_ERR_MSG);
                ok = false;
                break;
            }
            if pid == 0 {
                child_loop(CHILD_TAG, CHILD_ITERS);
            }
            out(PARENT_TAG);
            out(NEWLINE);
            spawned += 1;
        }

        let mut reaped = 0;
        while reaped < NUM_CHILDREN {
            sys::wait();
            out(PARENT_TAG);
            out(NEWLINE);
            reaped += 1;
        }

        if sys::dump_free() != baseline {
            ok = false;
        }
        round += 1;
    }

    out(DONE_MSG);
    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_FORK_STRESS, &FAIL_FORK_STRESS);
    ok
}

/// Drive fork to the global task-slot cap and assert the failing fork degrades
/// cleanly: it returns -1 rather than crashing or leaving a half-built zombie, every
/// child reaps, and the pool returns to baseline. This is the userland-visible face
/// of the OOM soft-fail contract whose pieces are host-tested individually.
///
/// The parent accumulates children without reaping (running or zombie, both hold a
/// task slot) until fork fails. The real page pool is never exhausted -- the 64-slot
/// task cap is the deterministic limiter, so this behaves the same on both boards.
/// The guard bounds the loop: a regression that lets fork succeed past the cap fails
/// the scenario instead of hanging the harness.
const OOM_FORK_GUARD: u32 = 80;

fn run_oom_graceful(baseline: u64) -> bool {
    out(&TEST_OOM_GRACEFUL);
    let mut ok = true;

    let mut spawned = 0;
    let mut hit_cap = false;
    while spawned < OOM_FORK_GUARD {
        let pid = sys::fork();
        if pid < 0 {
            hit_cap = true;
            break;
        }
        if pid == 0 {
            sys::exit(0);
        }
        spawned += 1;
    }

    // A clean cap failure: fork worked at all, and the loop ended on the -1 slot-cap
    // return rather than on the runaway guard.
    if spawned == 0 {
        ok = false;
    }
    if !hit_cap {
        ok = false;
    }

    let mut reaped = 0;
    while reaped < spawned {
        sys::wait();
        reaped += 1;
    }

    // The checkpoint that matters: the cap-hit fork's abandoned child mm was released
    // and every reaped child returned its pages, so the pool is exactly where it
    // started.
    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_OOM_GRACEFUL, &FAIL_OOM_GRACEFUL);
    ok
}

fn run_kill(baseline: u64) -> bool {
    out(&TEST_KILL);
    let mut ok = true;

    let kill_pid = sys::fork();
    if kill_pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_KILL);
        return false;
    }
    if kill_pid == 0 {
        child_loop_forever(CHILD_TAG);
    }

    spin(500_000);
    sys::kill(kill_pid);
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    out(KILL_OK_MSG);
    verdict(ok, &PASS_KILL, &FAIL_KILL);
    ok
}

/// Fork a child that path-resolves and execs `/test/hello.elf`: the VFS resolve, the
/// ELF parse, the PT_LOAD walk, the stack page, and the entry dispatch all in one.
/// The kernel streams the image in from the initramfs itself, so the harness hands it
/// only a path and a minimal argv. Success means the child ran its own exit, the
/// parent reaped it, and the pool netted back to baseline -- exec teardown freed the
/// old pages and the reap swept the loader's.
fn run_exec_elf(baseline: u64) -> bool {
    out(&TEST_EXEC_ELF);
    let mut ok = true;

    let exec_pid = sys::fork();
    if exec_pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_EXEC_ELF);
        return false;
    }
    if exec_pid == 0 {
        let argv = [HELLO_ELF_PATH.as_ptr(), core::ptr::null()];
        exec_or_exit(HELLO_ELF_PATH, &argv);
    }
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    out(EXEC_ELF_OK_MSG);
    verdict(ok, &PASS_EXEC_ELF, &FAIL_EXEC_ELF);
    ok
}

/// The same path with a real argv vector: the kernel encodes the argument block onto
/// the new top stack page and the loader lands in the image with `x0 = argc`,
/// `x1 = argv`. `argv_echo` prints what it received, so the serial log carries the
/// proof; the pass criterion mirrors exec-elf's page balance.
fn run_execve(baseline: u64) -> bool {
    out(&TEST_EXECVE);
    let mut ok = true;

    let exec_pid = sys::fork();
    if exec_pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_EXECVE);
        return false;
    }
    if exec_pid == 0 {
        let argv = [
            b"argv_echo\0".as_ptr(),
            b"A\0".as_ptr(),
            b"B\0".as_ptr(),
            core::ptr::null(),
        ];
        exec_or_exit(ARGV_ECHO_PATH, &argv);
    }
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_EXECVE, &FAIL_EXECVE);
    ok
}

/// Heap demand-allocation and shrink-and-free. The child reads its initial break,
/// grows the heap, writes one byte per fresh page (each store faults and the handler
/// demand-allocates inside the legal heap range), reads the pattern back, then shrinks
/// the break again. The pass criterion is the usual page balance after the reap, which
/// proves the demand-allocated pages were tracked, the shrink unmapped them, and
/// whatever the shrink missed the reap swept. The `brk child ok` line is in-band
/// confirmation that the read-back matched -- informational, not the verdict.
const NUM_BRK_PAGES: u32 = 16;

// The child maps one inherited page plus NUM_BRK_PAGES heap pages. Past 30 the
// task's page list would silently truncate at its 32nd entry rather than fail.
const _: () = assert!(
    NUM_BRK_PAGES + 1 <= 31,
    "NUM_BRK_PAGES would overflow the task's user-page list -- raise MAX_PAGE_COUNT first"
);

fn run_brk(baseline: u64) -> bool {
    out(&TEST_BRK);
    let mut ok = true;

    let brk_pid = sys::fork();
    if brk_pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_BRK);
        return false;
    }
    if brk_pid == 0 {
        let initial = sys::brk(0);
        if initial < 0 {
            sys::exit(0);
        }
        let initial_u = initial as u64;

        let grown = sys::brk(initial_u + NUM_BRK_PAGES as u64 * PAGE_SIZE_USER);
        if grown < 0 {
            sys::exit(0);
        }

        // Touch every fresh page once. Each store traps with a level-3 translation
        // fault and the region-aware handler allocates inside [HEAP_BASE, brk).
        let mut page: u32 = 0;
        while page < NUM_BRK_PAGES {
            let p = (initial_u + page as u64 * PAGE_SIZE_USER) as *mut u8;
            unsafe { p.write_volatile((page as u8).wrapping_add(0x42)) };
            page += 1;
        }

        // Read back: proves each fault handed out a page that stayed mapped, rather
        // than a TLB alias of somebody else's physical page.
        let mut read_ok = true;
        page = 0;
        while page < NUM_BRK_PAGES {
            let p = (initial_u + page as u64 * PAGE_SIZE_USER) as *const u8;
            let expected = (page as u8).wrapping_add(0x42);
            if unsafe { p.read_volatile() } != expected {
                read_ok = false;
            }
            page += 1;
        }
        out(if read_ok {
            BRK_CHILD_OK_MSG
        } else {
            BRK_CHILD_BAD_MSG
        });

        // Shrink back to the original break. The reap would free the leftovers
        // anyway, so a failing shrink is not fatal here -- but exercising the unmap
        // path is the point.
        sys::brk(initial_u);
        sys::exit(0);
    }
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    out(BRK_OK_MSG);
    verdict(ok, &PASS_BRK, &FAIL_BRK);
    ok
}

/// Exec `/test/stackbomb.elf`, whose entry does nothing but recurse a kilobyte at a
/// time. After some 64 frames the child's stack pointer crosses into the guard page,
/// the kernel reports the overflow and zombifies the task, and the parent reaps it as
/// usual -- so the page balance is what this asserts. The child runs in the post-ELF
/// image, the only context where the high stack address is reachable.
fn run_stack_overflow(baseline: u64) -> bool {
    out(&TEST_STACK_OVERFLOW);
    let mut ok = true;

    let ovf_pid = sys::fork();
    if ovf_pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_STACK_OVERFLOW);
        return false;
    }
    if ovf_pid == 0 {
        let argv = [STACKBOMB_ELF_PATH.as_ptr(), core::ptr::null()];
        exec_or_exit(STACKBOMB_ELF_PATH, &argv);
    }
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_STACK_OVERFLOW, &FAIL_STACK_OVERFLOW);
    ok
}

/// Exec `/test/flibc_demo.elf` -- a payload that exercises the userspace library's
/// formatted output and bump allocator. The kernel-side assertions are the usual reap
/// and page balance; the payload's own `flibc hello 42` / `flibc malloc ok` lines are
/// the in-band proof that its printf and heap layers ran end to end.
fn run_flibc(baseline: u64) -> bool {
    out(&TEST_FLIBC);
    let mut ok = true;

    let flibc_pid = sys::fork();
    if flibc_pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_FLIBC);
        return false;
    }
    if flibc_pid == 0 {
        let argv = [FLIBC_DEMO_ELF_PATH.as_ptr(), core::ptr::null()];
        exec_or_exit(FLIBC_DEMO_ELF_PATH, &argv);
    }
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_FLIBC, &FAIL_FLIBC);
    ok
}

/// A child stores one byte at the wild UVA. The fault handler classifies it as a wild
/// pointer, reports it, and zombifies the task; the parent reaps, so the page balance
/// holds. No exec needed -- the classification keys off the region map, not the
/// loader's layout.
fn run_wild_pointer(baseline: u64) -> bool {
    out(&TEST_WILD_POINTER);
    let mut ok = true;

    let wp_pid = sys::fork();
    if wp_pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_WILD_POINTER);
        return false;
    }
    if wp_pid == 0 {
        let wild = WILD_UVA_CANONICAL as *mut u8;
        unsafe { wild.write_volatile(0x42) };
        // Only reached if the fault handler did not zombie the task. Exit cleanly so
        // the parent can still reap.
        sys::exit(0);
    }
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_WILD_POINTER, &FAIL_WILD_POINTER);
    ok
}

/// The instruction-side twin of wild-pointer: a child *jumps* to the same wild UVA.
/// The fetch raises an instruction abort where the store raised a data abort, and the
/// exception vector must route it to the abort handler rather than the invalid-entry
/// hang. Liveness is the real assertion -- had the routing regressed, the child would
/// spin the core, the parent would wait forever, and the boot would never reach the
/// shell.
fn run_exec_fault(baseline: u64) -> bool {
    out(&TEST_EXEC_FAULT);
    let mut ok = true;

    let ef_pid = sys::fork();
    if ef_pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_EXEC_FAULT);
        return false;
    }
    if ef_pid == 0 {
        let bad: extern "C" fn() =
            unsafe { core::mem::transmute(WILD_UVA_CANONICAL as usize as *const ()) };
        bad();
        sys::exit(0);
    }
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_EXEC_FAULT, &FAIL_EXEC_FAULT);
    ok
}

/// The third leg of the EL0 sync-dispatch trio: an undefined instruction raises an
/// exception class that is neither a syscall nor either abort, so the vector's
/// catch-all must handle it. Before that catch-all existed this spun the whole core,
/// which is why survival here is unambiguous proof it ran.
fn run_undef_instr(baseline: u64) -> bool {
    out(&TEST_UNDEF_INSTR);
    let mut ok = true;

    let ui_pid = sys::fork();
    if ui_pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_UNDEF_INSTR);
        return false;
    }
    if ui_pid == 0 {
        // A permanently-undefined A64 encoding, emitted as a raw word so it does not
        // depend on the assembler aliasing a mnemonic.
        unsafe { core::arch::asm!(".inst 0x00000000") };
        sys::exit(0);
    }
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_UNDEF_INSTR, &FAIL_UNDEF_INSTR);
    ok
}

/// Hand the wild UVA to a syscall instead of dereferencing it. The kernel's user-range
/// check must take the soft path -- return -1 to the caller -- and never the hard path
/// that kills the task. PID 1 itself is the probe: if the soft path regresses, the
/// harness dies mid-scenario and the boot never reaches the shell.
fn run_efault_syscall(baseline: u64) -> bool {
    out(&TEST_EFAULT_SYSCALL);
    let mut ok = true;

    let fd = unsafe { sys::open(WILD_UVA_CANONICAL as *const u8) };
    if fd != -1 {
        ok = false;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_EFAULT_SYSCALL, &FAIL_EFAULT_SYSCALL);
    ok
}

/// One child, one anonymous pipe, one deterministic payload. Covers pipe creation and
/// the fd-table install, fork's duplication of both ends, the child's close of the read
/// end, the write that wakes the blocked reader, the parent's drain, and the final
/// unref that frees the pipe page. The pattern is distinct enough that a truncation or
/// a reordering shows up in the byte compare rather than as a vague failure.
const PIPE_PAYLOAD_LEN: usize = 16;

fn run_pipe(baseline: u64) -> bool {
    out(&TEST_PIPE);
    let mut ok = true;

    let fds = sys::pipe();
    if fds < 0 {
        out(&FAIL_PIPE);
        return false;
    }
    let (rfd, wfd) = sys::pipe_ends(fds);

    let pid = sys::fork();
    if pid < 0 {
        sys::close(rfd);
        sys::close(wfd);
        out(FORK_ERR_MSG);
        out(&FAIL_PIPE);
        return false;
    }
    if pid == 0 {
        // Child writer: drop the read end, push the payload, drop the write end.
        sys::close(rfd);
        let mut buf = [0u8; PIPE_PAYLOAD_LEN];
        let mut oi = 0;
        while oi < PIPE_PAYLOAD_LEN {
            buf[oi] = 0xA0u8.wrapping_add(oi as u8);
            oi += 1;
        }
        if sys::write(wfd, &buf) != PIPE_PAYLOAD_LEN as i64 {
            out(&FAIL_PIPE_SHORT_WRITE);
        }
        sys::close(wfd);
        sys::exit(0);
    }

    // Parent reader: drop the write end first, so the child's EOF short-circuit stays
    // reachable if it ever short-writes.
    sys::close(wfd);

    // A pipe read returns whatever is buffered, so loop until the payload is whole or
    // the writer is gone. The child sends one burst; the loop keeps this robust to a
    // future change in short-read semantics.
    let mut inbuf = [0u8; PIPE_PAYLOAD_LEN];
    let mut got = 0usize;
    while got < PIPE_PAYLOAD_LEN {
        let n = sys::read(rfd, &mut inbuf[got..]);
        if n <= 0 {
            break;
        }
        got += n as usize;
    }
    if got != PIPE_PAYLOAD_LEN {
        ok = false;
    }

    let mut ci = 0;
    while ci < PIPE_PAYLOAD_LEN {
        if inbuf[ci] != 0xA0u8.wrapping_add(ci as u8) {
            ok = false;
        }
        ci += 1;
    }
    out(if ok { PIPE_OK_MSG } else { PIPE_BAD_MSG });

    sys::close(rfd);
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_PIPE, &FAIL_PIPE);
    ok
}

/// The console RX path end to end. A child injects bytes into the ring after a delay;
/// the parent is already blocked on an empty ring, so the wake fires on each push and
/// the parent loops because a console read short-returns. Both fds are the ones PID 1
/// was born with.
const ECHO_LEN: usize = 8;

fn run_console_echo(baseline: u64) -> bool {
    out(&TEST_CONSOLE_ECHO);
    let mut ok = true;

    let pid = sys::fork();
    if pid < 0 {
        out(&FAIL_CONSOLE_ECHO);
        return false;
    }
    if pid == 0 {
        // Delay so the parent reaches the read and hits the empty-ring branch first --
        // that branch is the wait-queue path under test. Single-core scheduling makes
        // this delay an upper bound on the parent entering the wait.
        spin(500_000);
        let mut i = 0;
        while i < ECHO_LEN {
            sys::console_inject(0xC0u8.wrapping_add(i as u8));
            i += 1;
        }
        sys::exit(0);
    }

    let mut inbuf = [0u8; ECHO_LEN];
    let mut got = 0usize;
    while got < ECHO_LEN {
        let n = sys::read(sys::STDIN, &mut inbuf[got..]);
        if n <= 0 {
            ok = false;
            break;
        }
        got += n as usize;
    }
    let mut i = 0;
    while i < ECHO_LEN {
        if inbuf[i] != 0xC0u8.wrapping_add(i as u8) {
            ok = false;
        }
        i += 1;
    }
    out(if ok { ECHO_OK_MSG } else { ECHO_BAD_MSG });
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_CONSOLE_ECHO, &FAIL_CONSOLE_ECHO);
    ok
}

/// The unified read/write/close/dup2 surface across a redirected stdio boundary, the
/// way a shell hands a child its pipeline. Both fds start as console slots and are
/// re-pointed at a pipe, which proves the tagged descriptor dispatch routes a dup2'd
/// fd to the pipe backend rather than the console.
///
/// The refcount choreography keeps the page balance neutral: the pipe installs two
/// refs, fork doubles them, each dup2 adds one, and the six closes drop them all. The
/// read loop terminates on the byte count rather than on EOF, so the result does not
/// depend on how the fork interleaves.
const FD_REDIRECT_PAYLOAD_LEN: usize = 16;

fn run_fd_redirect(baseline: u64) -> bool {
    out(&TEST_FD_REDIRECT);
    let mut ok = true;

    let fds = sys::pipe();
    if fds < 0 {
        out(&FAIL_FD_REDIRECT);
        return false;
    }
    let (rfd, wfd) = sys::pipe_ends(fds);

    let pid = sys::fork();
    if pid < 0 {
        sys::close(rfd);
        sys::close(wfd);
        out(FORK_ERR_MSG);
        out(&FAIL_FD_REDIRECT);
        return false;
    }
    if pid == 0 {
        // Child writer: drop the read end, point stdout at the pipe, and push the
        // payload through the *unified* write -- fd 1 now carries a pipe tag, so the
        // dispatch must route to the pipe, not the console.
        sys::close(rfd);
        if sys::dup2(wfd, sys::STDOUT) != sys::STDOUT {
            out(FD_REDIRECT_BAD_MSG);
        }
        let mut buf = [0u8; FD_REDIRECT_PAYLOAD_LEN];
        let mut oi = 0;
        while oi < FD_REDIRECT_PAYLOAD_LEN {
            buf[oi] = 0xD0u8.wrapping_add(oi as u8);
            oi += 1;
        }
        if sys::write(sys::STDOUT, &buf) != FD_REDIRECT_PAYLOAD_LEN as i64 {
            out(&FAIL_FD_REDIRECT_SHORT_WRITE);
        }
        sys::close(sys::STDOUT);
        sys::close(wfd);
        sys::exit(0);
    }

    // Parent reader: drop the write end so the child's closes drive the pipe toward the
    // parent's sole reference, then point stdin at the read end.
    sys::close(wfd);
    if sys::dup2(rfd, sys::STDIN) != sys::STDIN {
        ok = false;
    }

    let mut inbuf = [0u8; FD_REDIRECT_PAYLOAD_LEN];
    let mut got = 0usize;
    while got < FD_REDIRECT_PAYLOAD_LEN {
        let n = sys::read(sys::STDIN, &mut inbuf[got..]);
        if n <= 0 {
            break;
        }
        got += n as usize;
    }
    if got != FD_REDIRECT_PAYLOAD_LEN {
        ok = false;
    }

    let mut ci = 0;
    while ci < FD_REDIRECT_PAYLOAD_LEN {
        if inbuf[ci] != 0xD0u8.wrapping_add(ci as u8) {
            ok = false;
        }
        ci += 1;
    }
    out(if ok {
        FD_REDIRECT_OK_MSG
    } else {
        FD_REDIRECT_BAD_MSG
    });

    // Restore PID 1's stdin. This scenario runs in PID 1 itself, not in a child, and
    // exec preserves the fd table -- so leaving fd 0 pointed at a dead pipe would hand
    // the interactive shell a stdin that reads EOF and quits after one prompt. fd 1 is
    // still the console here, and the console is refcount-exempt, so re-pointing fd 0
    // at it adds no pipe reference and the page balance is untouched.
    sys::close(sys::STDIN);
    sys::dup2(sys::STDOUT, sys::STDIN);
    sys::close(rfd);
    sys::wait();

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_FD_REDIRECT, &FAIL_FD_REDIRECT);
    ok
}

/// The read-only initramfs path end to end: open PID 1's own image, read four bytes,
/// assert the ELF magic, close. The file object the open allocated is freed by the
/// close, so the page count returns to baseline.
fn run_initramfs_open(baseline: u64) -> bool {
    out(&TEST_INITRAMFS_OPEN);
    let mut ok = true;

    let fd = unsafe { sys::open(INIT_PATH.as_ptr()) };
    if fd < 0 {
        ok = false;
    }

    let mut buf = [0u8; 4];
    if sys::read(fd, &mut buf) != 4 {
        ok = false;
    }
    if &buf != b"\x7fELF" {
        ok = false;
    }

    if sys::close(fd) != 0 {
        ok = false;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_INITRAMFS_OPEN, &FAIL_INITRAMFS_OPEN);
    ok
}

/// The VFS dispatch layer's legs. Positive: a path that resolves through the initramfs
/// backend. Negative-but-routed: a `/mnt/` path lands on the FAT32 backend, which
/// misses. Negative-not-routed: `/mnt` without the slash stays an initramfs path and
/// misses there. The harness cannot see which backend produced a given -1 -- the kernel
/// does not say -- so it asserts the contract (positives resolve, negatives do not),
/// and leaves per-backend coverage to the host tests.
fn run_vfs_dispatch(baseline: u64) -> bool {
    out(&TEST_VFS_DISPATCH);
    let mut ok = true;

    let fd = unsafe { sys::open(INIT_PATH.as_ptr()) };
    if fd < 0 {
        ok = false;
    }
    if sys::close(fd) != 0 {
        ok = false;
    }

    if unsafe { sys::open(MNT_MISSING_PATH.as_ptr()) } >= 0 {
        ok = false;
    }
    if unsafe { sys::open(MNT_BARE_PATH.as_ptr()) } >= 0 {
        ok = false;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_VFS_DISPATCH, &FAIL_VFS_DISPATCH);
    ok
}

/// Drive the patched scheduler trampolines through their canonical call chain: fork
/// enters the copy path, exit and wait route through the reap, and both legs cross the
/// scheduler via timer ticks and explicit yields. Four cycles is enough for each patched
/// entry to fire. Pass criterion is the usual page balance.
fn run_trace(baseline: u64) -> bool {
    out(&TEST_TRACE);
    let mut ok = true;

    let mut i = 0;
    while i < 4 {
        let pid = sys::fork();
        if pid < 0 {
            out(FORK_ERR_MSG);
            ok = false;
            break;
        }
        if pid == 0 {
            sys::exit(0);
        }
        sys::wait();
        i += 1;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_TRACE, &FAIL_TRACE);
    ok
}

// ---- the FAT32 legs ---------------------------------------------------------

const ROUNDTRIP_LEN: usize = 4096;

/// Create, write, read back, rename, and unlink a file inside one boot, leaving the
/// disk exactly as found -- so it is re-runnable and page-neutral. Reached only on a
/// mounted volume (the caller proved that by reading the magic byte), so it never runs
/// under QEMU. Folded into fs-roundtrip on purpose: no new `[TEST]` line, so the tally
/// cannot move.
fn run_crud_lifecycle() -> bool {
    // Clear anything a previously aborted run left behind.
    unsafe {
        sys::unlink(CRUD_PATH_A.as_ptr());
        sys::unlink(CRUD_PATH_B.as_ptr());
    }

    let fd_c = unsafe { sys::create(CRUD_PATH_A.as_ptr()) };
    if fd_c < 0 {
        return false;
    }
    let mut pat = [0u8; 16];
    let mut i = 0;
    while i < 16 {
        pat[i] = 0x5Au8.wrapping_add(i as u8);
        i += 1;
    }
    let w = sys::write(fd_c, &pat);
    let cc = sys::close(fd_c);
    if w != 16 || cc != 0 {
        unsafe { sys::unlink(CRUD_PATH_A.as_ptr()) };
        return false;
    }

    let fd_r = unsafe { sys::open(CRUD_PATH_A.as_ptr()) };
    if fd_r < 0 {
        unsafe { sys::unlink(CRUD_PATH_A.as_ptr()) };
        return false;
    }
    let mut got = [0u8; 16];
    let r = sys::read(fd_r, &mut got);
    sys::close(fd_r);
    if r != 16 {
        unsafe { sys::unlink(CRUD_PATH_A.as_ptr()) };
        return false;
    }
    i = 0;
    while i < 16 {
        if got[i] != 0x5Au8.wrapping_add(i as u8) {
            unsafe { sys::unlink(CRUD_PATH_A.as_ptr()) };
            return false;
        }
        i += 1;
    }

    // Rename: the old name must vanish and the new one must open.
    if unsafe { sys::rename(CRUD_PATH_A.as_ptr(), CRUD_PATH_B.as_ptr()) } != 0 {
        unsafe { sys::unlink(CRUD_PATH_A.as_ptr()) };
        return false;
    }
    if unsafe { sys::open(CRUD_PATH_A.as_ptr()) } >= 0 {
        unsafe { sys::unlink(CRUD_PATH_B.as_ptr()) };
        return false;
    }
    let fd_b = unsafe { sys::open(CRUD_PATH_B.as_ptr()) };
    if fd_b < 0 {
        return false;
    }
    sys::close(fd_b);

    // Unlink: it must be gone afterwards.
    if unsafe { sys::unlink(CRUD_PATH_B.as_ptr()) } != 0 {
        return false;
    }
    if unsafe { sys::open(CRUD_PATH_B.as_ptr()) } >= 0 {
        return false;
    }

    out(CRUD_OK);
    true
}

/// FAT32 persistence across a power cycle. Two pre-seeded files carry the state: a
/// 4 KiB payload and a one-byte magic that selects the phase, so one binary serves both
/// boots. Magic 0 writes the pattern and arms the magic; magic 1 reads it back, compares,
/// and disarms. A board with no persistent card never mounts the volume, the first open
/// fails, and the scenario skip-passes so the tally still increments -- a genuinely broken
/// image lands there too, which is why the two-run acceptance and the hardware run are
/// what actually validate this path.
///
/// The free-page checkpoint fires exactly once per invocation in every branch, so the
/// per-scenario checkpoint count is identical on both boards.
fn run_fs_roundtrip(baseline: u64) -> bool {
    out(&TEST_FS_ROUNDTRIP);

    let mut payload = [0u8; ROUNDTRIP_LEN];

    // The magic byte decides the phase. A negative fd means the volume is not mounted,
    // which is a skip, not a failure.
    let fd_mag = unsafe { sys::open(ROUNDTRIP_MAG_PATH.as_ptr()) };
    if fd_mag < 0 {
        sys::dump_free(); // checkpoint-count parity with the real branches
        out(&PASS_SKIP);
        return true;
    }
    let mut magic = [0u8; 1];
    if sys::read(fd_mag, &mut magic) != 1 {
        sys::close(fd_mag);
        out(&FAIL_FS_ROUNDTRIP);
        return false;
    }
    if sys::close(fd_mag) != 0 {
        out(&FAIL_FS_ROUNDTRIP);
        return false;
    }

    // The CRUD leg, reachable only because the magic read just proved the volume is
    // mounted. It is self-cleaning, so the checkpoint below still lands on baseline.
    if !run_crud_lifecycle() {
        out(&FAIL_FS_ROUNDTRIP);
        return false;
    }

    match magic[0] {
        0 => {
            // First boot: write the payload, then arm the magic.
            let fd_w = unsafe { sys::open(ROUNDTRIP_DAT_PATH.as_ptr()) };
            if fd_w < 0 {
                out(&FAIL_FS_ROUNDTRIP);
                return false;
            }
            let mut i = 0;
            while i < ROUNDTRIP_LEN {
                payload[i] = pattern_byte(i);
                i += 1;
            }
            let w = sys::write(fd_w, &payload);
            let cw = sys::close(fd_w);
            if w != ROUNDTRIP_LEN as i64 || cw != 0 {
                out(&FAIL_FS_ROUNDTRIP);
                return false;
            }
            let fd_set = unsafe { sys::open(ROUNDTRIP_MAG_PATH.as_ptr()) };
            if fd_set < 0 {
                out(&FAIL_FS_ROUNDTRIP);
                return false;
            }
            let ws = sys::write(fd_set, &[1u8]);
            let cs = sys::close(fd_set);
            if ws != 1 || cs != 0 {
                out(&FAIL_FS_ROUNDTRIP);
                return false;
            }
            // Sub-sector writeBack probe: re-read the one-byte magic just written, in
            // the same boot. The explicit byte loop at the splice site would have to
            // break for this to fail. Open/read/close is page-neutral, as the verify
            // branch below demonstrates.
            let fd_chk = unsafe { sys::open(ROUNDTRIP_MAG_PATH.as_ptr()) };
            if fd_chk < 0 {
                out(&FAIL_FS_ROUNDTRIP);
                return false;
            }
            let mut chk = [0u8; 1];
            let rc = sys::read(fd_chk, &mut chk);
            let cchk = sys::close(fd_chk);
            if rc != 1 || cchk != 0 {
                out(&FAIL_FS_ROUNDTRIP);
                return false;
            }
            out(if chk[0] == 1 {
                MAG_INBOOT_OK
            } else {
                MAG_INBOOT_BAD
            });
            if chk[0] != 1 {
                return false;
            }
            if sys::dump_free() != baseline {
                out(&FAIL_FS_ROUNDTRIP);
                return false;
            }
            out(&PASS_WRITE);
            true
        }
        1 => {
            // Second boot: read the payload back, compare, disarm the magic.
            let fd_r = unsafe { sys::open(ROUNDTRIP_DAT_PATH.as_ptr()) };
            if fd_r < 0 {
                out(&FAIL_FS_ROUNDTRIP);
                return false;
            }
            let mut got = 0usize;
            let mut ok = true;
            while got < ROUNDTRIP_LEN {
                let n = sys::read(fd_r, &mut payload[got..]);
                if n <= 0 {
                    ok = false;
                    break;
                }
                got += n as usize;
            }
            if sys::close(fd_r) != 0 {
                ok = false;
            }
            if ok {
                // Compare against the formula, so no second 4 KiB buffer is needed.
                let mut i = 0;
                while i < ROUNDTRIP_LEN {
                    if payload[i] != pattern_byte(i) {
                        ok = false;
                        break;
                    }
                    i += 1;
                }
            }
            // Disarm regardless of the verdict: leaving the magic armed would jam every
            // future run on the verify branch.
            let fd_reset = unsafe { sys::open(ROUNDTRIP_MAG_PATH.as_ptr()) };
            if fd_reset >= 0 {
                sys::write(fd_reset, &[0u8]);
                sys::close(fd_reset);
            }
            if sys::dump_free() != baseline {
                ok = false;
            }
            verdict(ok, &PASS_VERIFY, &FAIL_FS_ROUNDTRIP);
            ok
        }
        _ => {
            sys::dump_free(); // checkpoint-count parity
            out(&FAIL_MAGIC);
            false
        }
    }
}

/// The empty-file leg of the FAT32 write path: a file with no data cluster yet must be
/// given its first one before the write loop, or the sector arithmetic fails closed and
/// the write returns -1. Seeded as a zero-byte file on the card.
///
/// Not re-runnable in place: once the first write lands the file owns a cluster and is
/// no longer empty, and EL0 has no truncate to reset it -- so a populated re-run skips
/// honestly rather than reporting a pass it did not earn. Re-seed the card to re-arm it.
/// The checkpoint fires once per branch, as in fs-roundtrip.
fn run_fs_empty(baseline: u64) -> bool {
    out(&TEST_FS_EMPTY);

    // The probe classifies the file: no fd means the volume is unmounted, a zero-length
    // read means empty (the case under test), and anything else means a prior real run
    // already populated it.
    let fd_probe = unsafe { sys::open(EMPTY_PATH.as_ptr()) };
    if fd_probe < 0 {
        sys::dump_free(); // checkpoint-count parity
        out(&PASS_FS_EMPTY_SKIP);
        return true;
    }
    let mut probe = [0u8; 1];
    let pr = sys::read(fd_probe, &mut probe);
    if sys::close(fd_probe) != 0 {
        out(&FAIL_FS_EMPTY);
        return false;
    }
    if pr != 0 {
        sys::dump_free(); // checkpoint-count parity (populated re-run)
        out(&PASS_FS_EMPTY_SKIP);
        return true;
    }

    // The real phase: the write must traverse the first-cluster allocation for these
    // bytes to land at all.
    let fd_w = unsafe { sys::open(EMPTY_PATH.as_ptr()) };
    if fd_w < 0 {
        out(&FAIL_FS_EMPTY);
        return false;
    }
    let w = sys::write(fd_w, EMPTY_MARK);
    let cw = sys::close(fd_w);
    if w != EMPTY_MARK.len() as i64 || cw != 0 {
        out(&FAIL_FS_EMPTY);
        return false;
    }

    // Read it back: proves the cluster was allocated, recorded in the directory entry,
    // and that the data round-trips.
    let fd_r = unsafe { sys::open(EMPTY_PATH.as_ptr()) };
    if fd_r < 0 {
        out(&FAIL_FS_EMPTY);
        return false;
    }
    let mut got = [0u8; 8];
    let rn = sys::read(fd_r, &mut got);
    let cr = sys::close(fd_r);
    let mut ok = rn == EMPTY_MARK.len() as i64 && cr == 0;
    if ok {
        let mut i = 0;
        while i < EMPTY_MARK.len() {
            if got[i] != EMPTY_MARK[i] {
                ok = false;
            }
            i += 1;
        }
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_FS_EMPTY, &FAIL_FS_EMPTY);
    ok
}

/// Enumerate `/bin` through the stateless directory-index walk and assert that two
/// known tools are there (an exact count would break every time `/bin` grows), that the
/// end sentinel fires rather than the walk running away, and that the walk leaks nothing.
fn run_readdir(baseline: u64) -> bool {
    out(&TEST_READDIR);
    let mut ok = true;

    let mut found_fsh = false;
    let mut found_ls = false;
    let mut last: i32 = 0;
    let mut index: u64 = 0;
    // A bounded walk. The 64 is a runaway guard, not the sentinel -- the sentinel is the
    // -1 return asserted below.
    while index < 64 {
        let mut d = Dirent::default();
        last = unsafe { sys::readdir(BIN_DIR.as_ptr(), index, &mut d) };
        if last != 0 {
            break;
        }
        if name_eql(&d.name, b"fsh") {
            found_fsh = true;
        }
        if name_eql(&d.name, b"ls") {
            found_ls = true;
        }
        index += 1;
    }
    // The walk stopped on the end sentinel, not on the guard.
    if last >= 0 {
        ok = false;
    }
    if !found_fsh {
        ok = false;
    }
    if !found_ls {
        ok = false;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_READDIR, &FAIL_READDIR);
    ok
}

/// The kernel log ring end to end. The free-page call prints a line through the kernel's
/// own output path, which tees into the ring, so the snapshot taken right after must
/// contain it. Asserting the kernel-emitted marker rather than the harness's own header
/// keeps this robust to console state -- that line reaches the ring on every target. The
/// one free-page call doubles as this scenario's checkpoint.
const KLOG_SNAP_LEN: usize = 256;

fn run_klog(baseline: u64) -> bool {
    out(&TEST_KLOG);
    let mut ok = true;

    // Emits the marker into the ring AND is this scenario's checkpoint.
    if sys::dump_free() != baseline {
        ok = false;
    }

    let mut buf = [0u8; KLOG_SNAP_LEN];
    let n = sys::klog_read(&mut buf);
    if n <= 0 {
        ok = false;
    }
    if n > 0 && !find_sub(&buf[..n as usize], KLOG_MARKER) {
        ok = false;
    }

    verdict(ok, &PASS_KLOG, &FAIL_KLOG);
    ok
}

/// Assert the kernel's entropy source came up healthy. The generator is deliberately not
/// reachable from EL0 -- entropy stays kernel-internal, where the credential syscalls mint
/// their salts -- so this proves bring-up through the log ring, exactly as klog proves the
/// tee. The positive token matches any announce; the negative token is printed only by a
/// failed self-test and must be absent, so the two together assert that the announce ran
/// *and* that it was healthy.
///
/// This scenario MUST RUN FIRST. The announce is a boot-time line and the snapshot reads
/// only the most recent bytes of the ring; running late would push several kilobytes of
/// harness output between the announce and the snapshot, and the announce would fall out
/// of the window.
const RNG_SNAP_LEN: usize = 4096;

fn run_rng(baseline: u64) -> bool {
    out(&TEST_RNG);
    let mut ok = true;

    if sys::dump_free() != baseline {
        ok = false;
    }

    let mut buf = [0u8; RNG_SNAP_LEN];
    let n = sys::klog_read(&mut buf);
    if n <= 0 {
        ok = false;
    }
    if n > 0 {
        let snap = &buf[..n as usize];
        if !find_sub(snap, HWRNG_MARKER) {
            ok = false;
        }
        if find_sub(snap, HWRNG_FAIL_MARKER) {
            ok = false;
        }
    }

    verdict(ok, &PASS_RNG, &FAIL_RNG);
    ok
}

/// Hardware monitoring, the two metrics that need no firmware. The assertions tie the
/// syscalls to observable invariants rather than to "did not fault": the pool size is
/// frozen, so it can never be smaller than the live free count, and the pages held since
/// boot must stay a small fraction of it -- a garbage pool size blows straight past that
/// bound. Uptime is monotonic; two back-to-back reads land in the same second, so the
/// assertion here is non-decreasing, and the strictly-increasing check lives in the
/// hardware acceptance where the reads can be spaced.
fn run_hwmon_core(baseline: u64) -> bool {
    out(&TEST_HWMON_CORE);
    let mut ok = true;

    let total = sys::mem_total();
    if total == 0 {
        ok = false;
    }
    if total < baseline {
        ok = false;
    }
    if total - baseline > 1024 {
        ok = false;
    }

    let up1 = sys::uptime();
    let up2 = sys::uptime();
    if up2 < up1 {
        ok = false;
    }
    if up1 > 86_400 {
        ok = false;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_HWMON_CORE, &FAIL_HWMON_CORE);
    ok
}

/// Hardware monitoring, the two metrics that come from firmware. Board-uniform by design:
/// zero means unknown -- a board without the firmware channel reports it, and so does a
/// failed query -- and any other value must sit in a plausible silicon range. That keeps
/// the scenario green on real hardware and on the emulated board alike.
fn run_hwmon_mailbox(baseline: u64) -> bool {
    out(&TEST_HWMON_MAILBOX);
    let mut ok = true;

    // Milli-degrees Celsius; 20..120 C is the believable powered range.
    let temp = sys::cpu_temp();
    if temp != 0 && !(20_000..=120_000).contains(&temp) {
        ok = false;
    }

    // Hz; 100 MHz to 3 GHz spans idle-throttle to turbo with margin.
    let freq = sys::cpu_freq();
    if freq != 0 && !(100_000_000..=3_000_000_000).contains(&freq) {
        ok = false;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_HWMON_MAILBOX, &FAIL_HWMON_MAILBOX);
    ok
}

/// Process credentials. PID 1's own getters report root; a forked child inherits root,
/// drops to an unprivileged identity, re-reads the getters, and is then barred from
/// climbing back. The child reports one verdict byte over a pipe so the result reaches
/// the scenario without PID 1 ever dropping its own root -- it must stay root to exec the
/// login supervisor next.
fn run_creds(baseline: u64) -> bool {
    out(&TEST_CREDS);
    let mut ok = true;

    // PID 1 is root: every getter reports zero.
    if sys::getuid() != 0 || sys::geteuid() != 0 {
        ok = false;
    }
    if sys::getgid() != 0 || sys::getegid() != 0 {
        ok = false;
    }

    let fds = sys::pipe();
    if fds < 0 {
        out(&FAIL_CREDS);
        return false;
    }
    let (rfd, wfd) = sys::pipe_ends(fds);

    let pid = sys::fork();
    if pid < 0 {
        sys::close(rfd);
        sys::close(wfd);
        out(FORK_ERR_MSG);
        out(&FAIL_CREDS);
        return false;
    }
    if pid == 0 {
        sys::close(rfd);
        let mut verdict_byte = b'Y';
        // The fork inherited root.
        if sys::getuid() != 0 || sys::getgid() != 0 {
            verdict_byte = b'N';
        }
        // Group first, while still root: after the uid drop the caller is no longer
        // privileged enough to change its group.
        if sys::setgid(1000) != 0 {
            verdict_byte = b'N';
        }
        if sys::setuid(1000) != 0 {
            verdict_byte = b'N';
        }
        // Real and effective both moved off root.
        if sys::getuid() != 1000 || sys::geteuid() != 1000 {
            verdict_byte = b'N';
        }
        if sys::getgid() != 1000 || sys::getegid() != 1000 {
            verdict_byte = b'N';
        }
        // And a dropped process must not be able to regain it.
        if sys::setuid(0) == 0 {
            verdict_byte = b'N';
        }
        sys::write(wfd, &[verdict_byte]);
        sys::close(wfd);
        sys::exit(0);
    }

    sys::close(wfd);
    let mut vbuf = [0u8; 1];
    let n = sys::read(rfd, &mut vbuf);
    if n != 1 || vbuf[0] != b'Y' {
        ok = false;
    }
    sys::close(rfd);
    sys::wait();

    // PID 1 itself never dropped root.
    if sys::getuid() != 0 || sys::geteuid() != 0 {
        ok = false;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_CREDS, &FAIL_CREDS);
    ok
}

fn do_auth(user: &[u8], pass: &[u8]) -> i64 {
    unsafe { sys::authenticate(user.as_ptr(), user.len(), pass.as_ptr(), pass.len()) }
}

fn do_passwd(user: &[u8], old: &[u8], new: &[u8]) -> i64 {
    unsafe {
        sys::passwd(
            user.as_ptr(),
            user.len(),
            old.as_ptr(),
            old.len(),
            new.as_ptr(),
            new.len(),
        )
    }
}

/// The kernel-side shadow verifier, driven directly: the seeded credentials must
/// authenticate, and a wrong password and an unknown user must both be refused.
fn run_authenticate(baseline: u64) -> bool {
    out(&TEST_AUTH);
    let mut ok = true;

    if do_auth(b"flash", b"flash") != 0 {
        ok = false;
    }
    if do_auth(b"flash", b"wrongpw") != -1 {
        ok = false;
    }
    if do_auth(b"nobody", b"flash") != -1 {
        ok = false;
    }

    // Kernel-stack canary. The crypto chain runs on the per-task kernel stack, directly
    // above the task struct -- and an overflow smashes that struct's tail, which is
    // exactly where the credentials live. PID 1 must still be root afterwards; garbage
    // here means the crypto frames outgrew the stack budget.
    if sys::getuid() != 0 || sys::geteuid() != 0 {
        ok = false;
    }
    if sys::getgid() != 0 || sys::getegid() != 0 {
        ok = false;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_AUTH, &FAIL_AUTH);
    ok
}

/// The permission layer on the open and exec paths. A dropped child must be refused the
/// 0600 shadow file with exactly the access error -- a bare -1 would mean "not found",
/// i.e. that the permission check never ran at all -- while the world-readable passwd file
/// stays open to it, and exec of that same no-x-bit file is refused with the same exact
/// code. PID 1, still root, bypasses every check and re-opens the shadow file.
fn run_perm(baseline: u64) -> bool {
    out(&TEST_PERM);
    let mut ok = true;

    let fds = sys::pipe();
    if fds < 0 {
        out(&FAIL_PERM);
        return false;
    }
    let (rfd, wfd) = sys::pipe_ends(fds);

    let pid = sys::fork();
    if pid < 0 {
        sys::close(rfd);
        sys::close(wfd);
        out(FORK_ERR_MSG);
        out(&FAIL_PERM);
        return false;
    }
    if pid == 0 {
        sys::close(rfd);
        let mut verdict_byte = b'Y';
        if sys::setgid(1000) != 0 {
            verdict_byte = b'N';
        }
        if sys::setuid(1000) != 0 {
            verdict_byte = b'N';
        }

        // 0600 root: the open must fail with exactly the access error. A success means
        // the password hashes leaked to a non-root reader.
        let shadow_fd = unsafe { sys::open(SHADOW_PATH.as_ptr()) };
        if shadow_fd != -EACCES {
            verdict_byte = b'N';
        }
        if shadow_fd >= 0 {
            sys::close(shadow_fd);
        }

        // 0644: world-readable, so the dropped child still opens it.
        let passwd_fd = unsafe { sys::open(ETC_PASSWD_PATH.as_ptr()) };
        if passwd_fd < 0 {
            verdict_byte = b'N';
        }
        if passwd_fd >= 0 {
            sys::close(passwd_fd);
        }

        // 0644 has no exec bit: exec must refuse it before parsing a single byte. A
        // non-ELF would otherwise fail with the generic -1, so the exact code is what
        // pins the permission check rather than the ELF magic gate.
        let exec_argv = [ETC_PASSWD_PATH.as_ptr(), core::ptr::null()];
        let rc = unsafe { sys::exec_path(ETC_PASSWD_PATH.as_ptr(), exec_argv.as_ptr()) };
        if rc != -EACCES {
            verdict_byte = b'N';
        }

        sys::write(wfd, &[verdict_byte]);
        sys::close(wfd);
        sys::exit(0);
    }

    sys::close(wfd);
    let mut vbuf = [0u8; 1];
    let n = sys::read(rfd, &mut vbuf);
    if n != 1 || vbuf[0] != b'Y' {
        ok = false;
    }
    sys::close(rfd);
    sys::wait();

    // The root bypass: PID 1 opens the same 0600 file.
    let root_fd = unsafe { sys::open(SHADOW_PATH.as_ptr()) };
    if root_fd < 0 {
        ok = false;
    }
    if root_fd >= 0 {
        sys::close(root_fd);
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_PERM, &FAIL_PERM);
    ok
}

/// The login lifecycle, driven through the real supervisor binary: authenticate, run the
/// shell, exit, re-prompt, authenticate as another user, exit. The script is injected
/// before the fork -- the closed-race pattern -- and the supervisor drains it as it reads.
/// This is the integration proof for fork-per-session, the privilege drop in the child, the
/// reap on logout, and the re-prompt loop.
///
/// Serial side effect worth knowing: each session emits the same authentication and shell
/// markers the real boot login does, so a full boot log carries three of each -- two from
/// here and one from the boot login. The oracle keys its guards on exactly those counts.
const LOGIN_CYCLE_SCRIPT: &[u8] = b"flash\nflash\nexit\nroot\nroot\nexit\n";

fn run_login(baseline: u64) -> bool {
    out(&TEST_LOGIN);
    let mut ok = true;

    for &b in LOGIN_CYCLE_SCRIPT {
        sys::console_inject(b);
    }

    let pid = sys::fork();
    if pid < 0 {
        out(FORK_ERR_MSG);
        out(&FAIL_LOGIN);
        return false;
    }
    if pid == 0 {
        // The child becomes the supervisor with a two-session limit. Each session forks,
        // drops privilege, and execs the shell, so the tree under this child is
        // pid1 -> login -> fsh.
        let argv = [LOGIN_BIN_PATH.as_ptr(), b"2\0".as_ptr(), core::ptr::null()];
        exec_or_exit(LOGIN_BIN_PATH, &argv);
    }
    sys::wait();

    // The whole tree -- the supervisor, both session shells, all their pages -- must be
    // reclaimed: the cycle is page-neutral, or the lifecycle leaks.
    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_LOGIN, &FAIL_LOGIN);
    ok
}

/// Password change against the writable shadow on the card.
///
/// Where a card is mounted, the full roundtrip: root resets the account to its seed
/// password without needing the old one (self-healing, so an interrupted previous run
/// cannot jam this), root rotates it to a temporary value and authentication proves both
/// that the change took and that the old password stopped working, a dropped child is
/// refused a foreign record and its own record with a wrong old password (both with
/// exactly the access error) and then restores the seed through the legitimate path, and
/// the parent confirms the restore so the boot login and the next run still authenticate.
///
/// Where no card is mounted, the syscall must answer a clean -1 -- not an access error,
/// and certainly not a success -- and the scenario skip-passes.
fn run_passwd(baseline: u64) -> bool {
    out(&TEST_PASSWD);
    let mut ok = true;

    let user: &[u8] = b"flash";
    let seed_pw: &[u8] = b"flash";
    let temp_pw: &[u8] = b"changed1";
    let none: &[u8] = b"";

    // Probe for a writable shadow. PID 1 is root, so this is about existence, not
    // permission.
    let probe_fd = unsafe { sys::open(MNT_SHADOW_PATH.as_ptr()) };
    if probe_fd < 0 {
        if do_passwd(user, seed_pw, temp_pw) != -1 {
            ok = false;
        }
        if sys::dump_free() != baseline {
            ok = false;
        }
        verdict(ok, &PASS_PASSWD_SKIP, &FAIL_PASSWD);
        return ok;
    }
    sys::close(probe_fd);

    // (1) Self-heal: root resets the account to the seed password. An interrupted run may
    // have left the temporary password active; this line makes the scenario re-entrant.
    if do_passwd(user, none, seed_pw) != 0 {
        ok = false;
    }
    if do_auth(user, seed_pw) != 0 {
        ok = false;
    }

    // (2) Root rotates to the temporary password: the change is live and persisted, and
    // the old password stops working.
    if do_passwd(user, none, temp_pw) != 0 {
        ok = false;
    }
    if do_auth(user, temp_pw) != 0 {
        ok = false;
    }
    if do_auth(user, seed_pw) != -1 {
        ok = false;
    }

    // (3) The non-root rules, probed by a dropped child reporting over a pipe.
    let fds = sys::pipe();
    if fds < 0 {
        out(&FAIL_PASSWD);
        return false;
    }
    let (rfd, wfd) = sys::pipe_ends(fds);

    let pid = sys::fork();
    if pid < 0 {
        sys::close(rfd);
        sys::close(wfd);
        out(FORK_ERR_MSG);
        out(&FAIL_PASSWD);
        return false;
    }
    if pid == 0 {
        sys::close(rfd);
        let mut verdict_byte = b'Y';
        if sys::setgid(1000) != 0 {
            verdict_byte = b'N';
        }
        if sys::setuid(1000) != 0 {
            verdict_byte = b'N';
        }

        // A foreign record is off limits, whatever password is offered.
        if do_passwd(b"root", b"root", b"hijacked") != -(EACCES as i64) {
            verdict_byte = b'N';
        }
        // The caller's own record still needs the correct old password.
        if do_passwd(user, b"wrongold", seed_pw) != -(EACCES as i64) {
            verdict_byte = b'N';
        }
        // The legitimate path, which also restores the seed password for the boot login
        // and for the next run.
        if do_passwd(user, temp_pw, seed_pw) != 0 {
            verdict_byte = b'N';
        }

        sys::write(wfd, &[verdict_byte]);
        sys::close(wfd);
        sys::exit(0);
    }

    sys::close(wfd);
    let mut vbuf = [0u8; 1];
    let n = sys::read(rfd, &mut vbuf);
    if n != 1 || vbuf[0] != b'Y' {
        ok = false;
    }
    sys::close(rfd);
    sys::wait();

    // (4) The child's restore is visible here: the seed password authenticates again, and
    // the shadow is back in its boot state.
    if do_auth(user, seed_pw) != 0 {
        ok = false;
    }

    // The same kernel-stack canary as authenticate: the key-derivation chain runs directly
    // above the task struct, and smashed credentials would show up right here.
    if sys::getuid() != 0 || sys::geteuid() != 0 {
        ok = false;
    }

    if sys::dump_free() != baseline {
        ok = false;
    }
    verdict(ok, &PASS_PASSWD, &FAIL_PASSWD);
    ok
}

// ---- the runner -------------------------------------------------------------

pub struct TestResult {
    pub passed: u32,
    pub total: u32,
}

/// The scenarios, in contract order, called straight-line rather than through a table of
/// function pointers: a pointer table is data, and data holding code addresses is exactly
/// what this image cannot carry -- only PC-relative references survive the way the loader
/// places it. The order is not cosmetic either. `rng` must run first (its ring snapshot
/// has to still contain the boot-time announce), and `login` and `passwd` run last: the
/// first scripts the console and must not interleave with the I/O scenarios, and the
/// second is the most environment-dependent one, so a failure there can never cascade into
/// the login test before it.
macro_rules! run_scenarios {
    ($baseline:expr, $passed:ident, $($scenario:path),+ $(,)?) => {
        $(
            if $scenario($baseline) {
                $passed += 1;
            }
        )+
    };
}

/// How many scenarios the runner drives. The oracle counts the `[PASS]`/`[FAIL]` lines and
/// this must equal them; it is spelled here rather than derived so that dropping a call
/// from the list below fails the tally instead of silently shrinking the suite.
const SCENARIO_COUNT: u32 = 30;

pub fn run_all() -> TestResult {
    // Warm the deepest stack page the scenarios will have the kernel write into (a read
    // syscall's destination buffer lives here).
    //
    // This is no longer a crash workaround -- the copy-to-user path faults EL0 pages in
    // correctly now -- but it is still required for baseline stability: without it, the
    // first scenario to take a syscall read would demand-allocate this page and its free
    // count, and every later one, would sit a page below the baseline captured just after.
    let mut warmup = core::mem::MaybeUninit::<[u8; 4096]>::uninit();
    let base = warmup.as_mut_ptr() as *mut u8;
    let mut wi = 0usize;
    while wi < 4096 {
        unsafe { base.add(wi).write_volatile(0) };
        wi += PAGE_SIZE_USER as usize;
    }
    unsafe { base.add(4095).write_volatile(0) };

    let baseline = sys::dump_free();
    let mut passed: u32 = 0;
    run_scenarios!(
        baseline,
        passed,
        run_rng,
        run_fork_stress,
        run_oom_graceful,
        run_kill,
        run_exec_elf,
        run_execve,
        run_brk,
        run_stack_overflow,
        run_wild_pointer,
        run_exec_fault,
        run_undef_instr,
        run_efault_syscall,
        run_flibc,
        run_pipe,
        run_console_echo,
        run_fd_redirect,
        run_initramfs_open,
        run_vfs_dispatch,
        run_trace,
        run_fs_roundtrip,
        run_fs_empty,
        run_readdir,
        run_klog,
        run_hwmon_core,
        run_hwmon_mailbox,
        run_creds,
        run_authenticate,
        run_perm,
        run_login,
        run_passwd,
    );
    TestResult {
        passed,
        total: SCENARIO_COUNT,
    }
}

/// The closing `X/Y passed` line.
pub fn print_tally(passed: u32, total: u32) {
    write_number(passed);
    out(b"/");
    write_number(total);
    out(PASSED_SUFFIX);
}

fn write_number(n: u32) {
    let (rendered, len) = digits(n);
    out(&rendered[..len]);
}
