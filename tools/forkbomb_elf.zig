// forkbomb — capped fork/reap loop for /bin/forkbomb.
// A leak detector, NOT a stress test: it forks a fixed N=16 times, each
// child exits immediately, and the parent reaps each child right after
// forking it — so at most one child is ever live and the run never
// approaches exhaustion. forkbomb is never driven to fork() == -1: the
// kernel's OOM path is graceful (get_free_page returns a 0 sentinel and
// every allocation site fails cleanly — see DOCUMENTATION §3), and the
// in-kernel [TEST] oom-graceful scenario is what drives fork to the
// task-slot cap and asserts the clean -1 + reap + restored baseline.
//
// Output is a single summary line via flibc.printf (legacy slot-0 console
// write); kept out of the CI FSH_SCRIPT for the same reason as meminfo
// (Pi-interactive demo). flibc_mem imported for coreutil parity.

const flibc = @import("flibc");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

const FORKS: u32 = 16;

export fn main(_: usize, _: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    var reaped: u32 = 0;
    var i: u32 = 0;
    while (i < FORKS) : (i += 1) {
        const pid = flibc.fork();
        if (pid == 0) {
            // Child: exit at once — keeps at most one child live.
            flibc.exit();
        }
        if (pid < 0) break; // fork failed (must not happen while capped)
        _ = flibc.wait(); // parent reaps immediately
        reaped += 1;
    }
    flibc.printf("forkbomb: spawned and reaped %u children\n", .{reaped});
    flibc.exit();
}
