// Process creation — fork() / move-to-user setup.
// Layouts (TaskStruct, KeRegs, ...) come from src/task_layout.zig.

const layout = @import("task_layout.zig");
const TaskStruct = layout.TaskStruct;
const CoreContext = layout.CoreContext;
const KeRegs = layout.KeRegs;
const TASK_RUNNING = layout.TASK_RUNNING;
const KTHREAD = layout.KTHREAD;
const MAX_PAGE_COUNT = layout.MAX_PAGE_COUNT;

const NR_TASKS: usize = 64;
const PAGE_SIZE: u64 = 1 << 12;
const THREAD_SIZE: u64 = PAGE_SIZE;
const USER_SP_INIT_POS: u64 = 2 * PAGE_SIZE;
const SPSR_EL1_MODE_EL0t: u64 = 0;
const MU: i32 = 0;

// Kernel-thread PCs must run via TTBR1 (high-mem linear map). Otherwise
// the moment a process does set_pgd() to a user pgd, TTBR0 stops mapping
// the kernel's low-VA copy and the next ret/blr to a kernel function
// faults. ORing instead of adding is idempotent if the address is
// already high.
const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

extern fn get_kernel_page() u64;
extern fn free_kernel_page(kp: u64) void;
extern fn allocate_user_page(task: *TaskStruct, uva: u64) u64;
extern fn copy_virt_memory(dst: *TaskStruct) i32;
extern fn memzero(start: u64, size: u64) void;
extern fn memcpy(dst: [*]u64, src: [*]const u64, bytes: u64) void;
extern fn copy_ke_regs(to: *KeRegs, from: *KeRegs) void;
extern fn set_pgd(pgd: u64) void;
extern fn preempt_disable() void;
extern fn preempt_enable() void;
extern fn ret_from_fork() void;
extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
extern fn main_output_char(interface: i32, ch: u8) void;

extern var current: *TaskStruct;
extern var task: [NR_TASKS]?*TaskStruct;
extern var nr_tasks: i32;
extern var next_pid: i32;

export fn task_ke_regs(tsk: *TaskStruct) *KeRegs {
    const p: u64 = @intFromPtr(tsk) + THREAD_SIZE - @sizeOf(KeRegs);
    return @ptrFromInt(p);
}

export fn copy_process(clone_flags: u64, fn_addr: u64, arg: u64) i32 {
    preempt_disable();

    const p: *TaskStruct = @ptrFromInt(get_kernel_page());

    const childregs = task_ke_regs(p);
    memzero(@intFromPtr(childregs), @sizeOf(KeRegs));
    memzero(@intFromPtr(&p.core_context), @sizeOf(CoreContext));

    if ((clone_flags & KTHREAD) != 0) {
        p.core_context.x19 = fn_addr | LINEAR_MAP_BASE;
        p.core_context.x20 = arg;
    } else {
        const cur_regs = task_ke_regs(current);
        // copy_ke_regs avoids gcc emitting a memcpy call
        copy_ke_regs(childregs, cur_regs);
        // child returns 0 from fork
        childregs.regs[0] = 0;
        if (copy_virt_memory(p) != 0) {
            free_kernel_page(@intFromPtr(p));
            return -1;
        }
    }

    p.flags = clone_flags;
    p.priority = current.priority;
    p.state = TASK_RUNNING;
    // Halved so a freshly forked child doesn't out-budget a parent that has
    // already burned ticks; gives the round-robin path a chance to interleave
    // parent/child during fork-stress instead of running parent in a tight
    // burst.
    p.counter = @divTrunc(p.priority, 2);
    p.preempt_count = 1;
    p.parent = current;

    p.core_context.lr = @intFromPtr(&ret_from_fork) | LINEAR_MAP_BASE;
    p.core_context.sp = @intFromPtr(childregs);

    // First-null-slot scan instead of monotonic nr_tasks bump so that slots
    // freed by do_wait get reused; otherwise long fork-stress runs hit
    // NR_TASKS=64 well before allocator pressure. nr_tasks is kept as a
    // high-water mark only.
    var slot: i32 = -1;
    var i: usize = 0;
    while (i < NR_TASKS) : (i += 1) {
        if (task[i] == null) {
            slot = @intCast(i);
            break;
        }
    }
    if (slot < 0) {
        free_kernel_page(@intFromPtr(p));
        preempt_enable();
        return -1;
    }
    // Pid is monotonic (next_pid++), independent of the reusable slot index.
    p.pid = next_pid;
    next_pid += 1;
    task[@intCast(slot)] = p;
    if (slot + 1 > nr_tasks) nr_tasks = slot + 1;

    main_output(MU, "created pid ");
    if (p.pid < 10) {
        main_output_char(MU, @intCast('0' + p.pid));
    } else {
        main_output_char(MU, @intCast('0' + @divTrunc(p.pid, 10)));
        main_output_char(MU, @intCast('0' + @mod(p.pid, 10)));
    }
    main_output(MU, " at ");
    main_output_u64(MU, @intFromPtr(p));
    main_output(MU, "\n");

    preempt_enable();
    return p.pid;
}

export fn prepare_move_to_user(start_addr: u64, size: u64, fn_addr: u64) i32 {
    const regs = task_ke_regs(current);
    memzero(@intFromPtr(regs), @sizeOf(KeRegs));
    regs.elr = fn_addr;
    regs.pstate = SPSR_EL1_MODE_EL0t;
    regs.sp = USER_SP_INIT_POS;

    const code_page = allocate_user_page(current, 0);
    if (code_page == 0) return -1;

    memcpy(@ptrFromInt(code_page), @ptrFromInt(start_addr), size);
    set_pgd(current.mm.pgd);
    return 0;
}
