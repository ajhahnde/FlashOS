// Kernel boot and main loop

const board = @import("board.zig");

const MU: i32 = 0;
const PL: i32 = 1;

const KTHREAD: u64 = 1;

// IRQ numbers
const VC_AUX_IRQ: u32 = 125;
const NS_PHYS_TIMER_IRQ: u32 = 30;

// UART / utils
extern fn mini_uart_init() void;
extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
extern fn main_output_char(interface: i32, ch: u8) void;
extern fn main_output_process(interface: i32, p: *anyopaque) void;
extern fn delay(ticks: u64) void;
extern fn get_el() u32;

// Generic timer
extern fn generic_timer_init() void;
extern fn get_sys_count() u64;

// IRQ
extern fn enable_interrupt_gic(intid: u32, core: u32) void;
extern fn irq_init_vectors() void;
extern fn irq_enable() void;

// Fork / sched
extern fn copy_process(clone_flags: u64, fn_ptr: u64, arg: u64) i32;
extern fn prepare_move_to_user(start_addr: u64, size: u64, fn_offset: u64) i32;
extern fn sched_init() void;
extern fn schedule() void;
extern var current: *anyopaque;

// Syscall table
extern fn sys_call_table_relocate() void;

// Trace
extern fn trace_init() void;
extern fn trace_output_kernel_pts(interface: i32) void;
extern fn pl011_uart_init() void;
extern fn ksyms_init() void;

// Page allocator
extern fn mem_map_init() void;
extern fn dump_free_count() u64;

// User space
extern fn user_process() void;
extern var user_start: u8;
extern var user_end: u8;

// Cross-core boot synchronization
export var state: u32 = 0;

/// Run by PID 1; returns to entry.S and does a kernel_exit 0.
export fn kernel_process() void {
    main_output(MU, "pid 1 started in EL");
    main_output_char(MU, @intCast(get_el() + '0'));
    main_output(MU, "\n");

    const user_start_addr: u64 = @intFromPtr(&user_start);
    const user_end_addr: u64 = @intFromPtr(&user_end);
    const user_size: u64 = user_end_addr - user_start_addr;

    const fn_offset: u64 = @intFromPtr(&user_process) - user_start_addr;
    const err = prepare_move_to_user(user_start_addr, user_size, fn_offset);
    if (err < 0) {
        main_output(MU, "Failed to move to user mode!\n");
    }
}

export fn kernel_main_impl(id: u64) void {
    // core 0 initializes mini-uart and handles uart interrupts
    if (id == 0) {
        // Page allocator bitmap zeroed first so anything later in bring-up
        // can hit get_free_page without a lazy-init branch.
        mem_map_init();

        // Mini-UART first so the [Debug] checkpoints land on the same cable
        // (pin 14/15) as the exception handler's "ERROR CAUGHT" output.
        mini_uart_init();
        main_output(MU, "[Debug] Mini-UART initialized\n");

        pl011_uart_init();
        main_output(MU, "[Debug] PL011 initialized\n");

        irq_init_vectors();
        main_output(MU, "[Debug] IRQ vectors loaded\n");

        // Board-specific GIC bring-up: GICv3 needs ICC_*_EL1 + per-core
        // redistributor wakeup. Pi's GICv2 inlines to nothing.
        board.irq.board_irq_init();

        enable_interrupt_gic(VC_AUX_IRQ, @intCast(id));
        main_output(MU, "[Debug] GIC enabled\n");

        ksyms_init();
        main_output(MU, "[Debug] ksyms done\n");

        sys_call_table_relocate();
        main_output(MU, "[Debug] Syscalls relocated\n");

        trace_init();
        main_output(MU, "[Debug] trace_init done\n");

        trace_output_kernel_pts(PL);
        main_output(MU, "[Debug] trace_output_kernel_pts done\n");

        // Boot-time free-page baseline. Logged before any task is created
        // so the user-space dumps later in the trace can be compared
        // against this absolute reference.
        _ = dump_free_count();

        state = 0;
        main_output(MU, "SUCCESS\n");
    }

    // single core for now
    while (id != 0) {}

    // startup message and EL
    main_output(MU, "Bare Metal... (core ");
    main_output_char(MU, @intCast(id + '0'));
    main_output(MU, ")\n");
    delay(30000);
    main_output(MU, "EL: ");
    main_output_char(MU, @intCast(get_el() + '0'));
    main_output(MU, "\n");
    // syscount
    const sys_count: u64 = get_sys_count();
    main_output_u64(MU, sys_count);
    main_output(MU, "\n");

    // generic timer and timer IRQ (vectors already loaded on core 0)
    generic_timer_init();
    enable_interrupt_gic(NS_PHYS_TIMER_IRQ, @intCast(id));
    irq_enable();

    // let the next core run
    state += 1;

    while (true) {
        if (id != 0 or state != 1) continue;
        sched_init();
        main_output_process(MU, current);
        // create pid 1, kernel threads don't need a user stack page
        const res = copy_process(KTHREAD, @intFromPtr(&kernel_process), 0);
        if (res <= 0) {
            main_output(MU, "fork error\n");
        }
        while (true) {
            main_output(MU, "init schedule..\n");
            schedule();
        }
    }
}
