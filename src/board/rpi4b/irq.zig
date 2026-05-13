// Interrupt handling — GIC (Generic Interrupt Controller) for Raspberry Pi 4

const LINEAR_MAP_BASE: u64 = 0xffff000000000000;
const GIC_BASE: u64 = 0xFF840000 + LINEAR_MAP_BASE;
const GICD_BASE: u64 = GIC_BASE + 0x1000;
const GICC_BASE: u64 = GIC_BASE + 0x2000;

const GICD_ISENABLER_BASE: u64 = GICD_BASE + 0x100;
const GICD_ITARGETSR_BASE: u64 = GICD_BASE + 0x800;
const GICC_IAR: u64 = GICC_BASE + 0x0C;
const GICC_EOIR: u64 = GICC_BASE + 0x10;

const DistributorEnableRegs = extern struct { bitmap: [32]u32 };
const DistributorTargetRegs = extern struct { set: [255]u32 };

fn enableRegs() *volatile DistributorEnableRegs {
    return @as(*volatile DistributorEnableRegs, @ptrFromInt(GICD_ISENABLER_BASE));
}
fn targetRegs() *volatile DistributorTargetRegs {
    return @as(*volatile DistributorTargetRegs, @ptrFromInt(GICD_ITARGETSR_BASE));
}
fn iarReg() *volatile u32 {
    return @as(*volatile u32, @ptrFromInt(GICC_IAR));
}
fn eoirReg() *volatile u32 {
    return @as(*volatile u32, @ptrFromInt(GICC_EOIR));
}

// IRQ numbers
const NS_PHYS_TIMER_IRQ: u32 = 30;
const VC_TIMER_IRQ_1: u32 = 97;
const VC_AUX_IRQ: u32 = 125;

const MU: i32 = 0;

extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
extern fn main_output_char(interface: i32, ch: u8) void;
extern fn main_output_process(interface: i32, p: *anyopaque) void;
extern fn mini_uart_recv() u8;
extern fn mini_uart_rx_pending() bool;
extern fn handle_sys_timer_1() void;
extern fn handle_generic_timer() void;
extern fn timer_tick() void;
extern fn get_core() u32;
extern var current: *anyopaque;

const console = @import("console");

const entry_error_messages = [_][*:0]const u8{
    "SYNC_INVALID_EL1t",
    "IRQ_INVALID_EL1t",
    "FIQ_INVALID_EL1t",
    "SERROR_INVALID_EL1t",
    "SYNC_INVALID_EL1h",
    "IRQ_INVALID_EL1h",
    "FIQ_INVALID_EL1h",
    "SERROR_INVALID_EL1h",
    "SYNC_INVALID_EL0_64",
    "IRQ_INVALID_EL0_64",
    "FIQ_INVALID_EL0_64",
    "SERROR_INVALID_EL0_64",
    "SYNC_INVALID_EL0_32",
    "IRQ_INVALID_EL0_32",
    "FIQ_INVALID_EL0_32",
    "SERROR_INVALID_EL0_32",
    "SYNC_ERROR",
    "SYSCALL_ERROR",
    "DATA_ABORT_ERROR",
};

export fn show_invalid_entry_message(typ: u32, esr: u64, address: u64) void {
    main_output(MU, "ERROR CAUGHT: ");
    main_output(MU, entry_error_messages[typ]);
    main_output(MU, ", ESR: ");
    main_output_u64(MU, esr);
    main_output(MU, ", Address: ");
    main_output_u64(MU, address);
    main_output(MU, "\n");
}

export fn enable_gic_distributor(intid: u32) void {
    const n: usize = @intCast(intid / 32);
    const shift: u5 = @intCast(intid % 32);
    enableRegs().bitmap[n] |= (@as(u32, 1) << shift);
}

export fn assign_interrupt_core(intid: u32, core: u32) void {
    const n: usize = @intCast(intid / 4);
    const byte_offset: u32 = intid % 4;
    const shift: u5 = @intCast(byte_offset * 8 + core);
    targetRegs().set[n] |= (@as(u32, 1) << shift);
}

export fn enable_interrupt_gic(intid: u32, core: u32) void {
    enable_gic_distributor(intid);
    assign_interrupt_core(intid, core);
}

export fn handle_irq() void {
    const iar: u32 = iarReg().*;
    // GICv2 GICC_IAR INTID is bits[9:0]; mask must be 0x3FF, not 0x2FF
    // (bit 8 was being silently cleared, masking any IRQ ID in 256..511).
    const intid: u32 = iar & 0x3FF;
    switch (intid) {
        VC_TIMER_IRQ_1 => {
            handle_sys_timer_1();
            eoirReg().* = iar;
        },
        VC_AUX_IRQ => {
            // Drain the entire RX FIFO in one IRQ slot. mini-UART FIFO
            // is 8 bytes on BCM2711; popping just one per IRQ would
            // lose bytes under sustained typing bursts since the level-
            // triggered AUX line refires only once per CPU-mask/unmask
            // round-trip. console_push ring-buffers + wakes the
            // sys_readConsole waiter.
            while (mini_uart_rx_pending()) {
                console.console_push(mini_uart_recv());
            }
            eoirReg().* = iar;
        },
        NS_PHYS_TIMER_IRQ => {
            handle_generic_timer();
            eoirReg().* = iar;
            if (get_core() == 0) {
                main_output(MU, "core ");
                main_output_char(MU, @intCast(get_core() + '0'));
                main_output(MU, ": generic timer interrupt\n");
                main_output_process(MU, current);
                timer_tick();
            }
        },
        else => main_output(MU, "unknown pending irq\n"),
    }
}

/// Pi's GICv2 needs no per-CPU init beyond what irq_init_vectors does;
/// kept as an empty inline so kernel.zig can call `board.irq.board_irq_init()`
/// uniformly across boards. Inlining ensures the rpi4b output stays
/// byte-identical (no `bl` is emitted).
pub inline fn board_irq_init() void {}
