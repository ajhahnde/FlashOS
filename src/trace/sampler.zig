// Statistical kernel profiler — the -Dtrace sampler (Path D).
//
// Reached from handle_irq on both boards, BEFORE timer_tick, with the
// saved exception frame the entry stub (arch/aarch64/entry.S) built at the kernel
// SP. We run in IRQ context: TTBR0 may still hold the interrupted user
// process's pgd, so we touch only globals reachable from there — `current`
// (exactly what timer_tick dereferences in the same context) and the
// symbol table via ksyms (which promotes its own low-VA literal to the
// linear-map alias). The current task's KeRegs lives on the kernel stack
// we are executing on, so the frame is always readable.
//
// The walk is allocation-free, lock-free and fault-free by construction:
// every step is bounded by the current task's kernel-stack page plus a
// monotonic frame-pointer guard, so a garbage FP terminates the walk
// rather than faulting. This is a *statistical* profiler — leaf frames and
// hand-written-asm frames that carry no standard AAPCS64 frame record are
// simply skipped. Compiled only under -Dtrace (see src/board/*/irq.flash).

const layout = @import("task_layout");
const KeRegs = layout.KeRegs;
const TaskStruct = layout.TaskStruct;
const ksyms = @import("ksyms");
const fp_walk = @import("fp_walk");

const PAGE_SIZE: u64 = 1 << 12;
// Boot console: Mini-UART on rpi4b, PL011 on virt. Both are visible under
// QEMU, so the trace shows on either board. (trace_output / interface 1 is
// the Pi-only UART4 and a stub on virt — deliberately not used here.)
const MU: i32 = 0;
const MAX_DEPTH: usize = 32;

extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
extern fn main_output_char(interface: i32, ch: u8) void;

// The same global timer_tick reads; reachable from IRQ context.
extern var current: ?*TaskStruct;

// Throttle: emit one backtrace every N ticks. The timer tick is ~1 Hz on
// real hardware (the only place it fires — QEMU never delivers the PPI), so
// N=1 is one sample per second over the UART: legible, not a flood. Raise to
// sub-sample a faster tick; N=0 disables emission entirely.
const THROTTLE_N: u64 = 1;
var tick: u64 = 0;

fn emit_frame(pc: u64) void {
    main_output(MU, "  ");
    main_output_u64(MU, pc);
    if (ksyms.ksym_nearest(pc)) |name| {
        main_output(MU, " ");
        main_output(MU, name);
    }
    main_output_char(MU, '\n');
}

pub fn trace_sample(frame: *KeRegs) void {
    tick +%= 1;
    if (THROTTLE_N == 0 or tick % THROTTLE_N != 0) return;

    main_output(MU, "[trace] tick=");
    main_output_u64(MU, tick);
    main_output_char(MU, '\n');

    // Leaf: the interrupted PC.
    emit_frame(frame.elr);

    // EL0t — the interrupt hit user code. The kernel frame chain only
    // begins below this exception, and the user stack is not ours to walk.
    if ((frame.pstate & 0xF) == 0) {
        main_output(MU, "  [user]\n");
        return;
    }

    // Bound the walk to the current task's kernel-stack page. kstack is the
    // page base when the task carries a dedicated kernel stack; older tasks
    // run on the stack that shares the TaskStruct page, so fall back to it.
    // The FP-chain decode itself lives in fp_walk.walkChain (host-tested);
    // here we just hand it a view of the page and emit the LRs it returns.
    // Note: under ReleaseSmall most kernel frames omit the x29 record, so
    // this is best-effort — it resolves whatever frames LLVM kept and the
    // guards turn a missing chain into an empty walk, never a fault. (Global
    // -fno-omit-frame-pointer would give full chains but crashes the boot;
    // see the build.zig -Dtrace note.)
    const cur = current orelse return;
    const base = if (cur.kstack != 0) cur.kstack else @intFromPtr(cur);
    const page: []const u8 = @as([*]const u8, @ptrFromInt(base))[0..PAGE_SIZE];
    var lrs: [MAX_DEPTH]u64 = undefined;
    const n = fp_walk.walkChain(page, base, frame.regs[29], &lrs);
    for (lrs[0..n]) |lr| emit_frame(lr);
}
