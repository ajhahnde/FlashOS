// GICv3 + IRQ handling for QEMU's `-M virt`.
//
// ABI mirrors src/board/rpi4b/irq.zig:
//   * show_invalid_entry_message(typ, esr, address) — exception print
//   * enable_interrupt_gic(intid, core)             — distributor enable + route
//   * handle_irq()                                  — dispatcher
// Plus a Zig-side inline-able board_irq_init() that brings the CPU
// interface and the local redistributor up; kernel.zig calls it after
// irq_init_vectors. Pi's equivalent is an empty inline fn.
//
// MMIO map (per `qemu-system-aarch64 -M virt -d unimp`):
//   * Distributor (GICD)         @ 0x08000000
//   * Redistributor for core 0   @ 0x080A0000
// CPU interface uses ICC_*_EL1 system registers (per the GICv3 spec).
//
// Two interrupts are dispatched today: the ARM generic non-secure
// physical timer (PPI 14, INTID 30) and the PL011 console RX
// (SPI 1, INTID 33). PSCI-driven SMP and any further peripherals
// extend the switch in handle_irq.

const Dtb = @import("dtb.zig").Dtb;
const uart = @import("uart.zig");

const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

// All four hardware-locator constants below are mutable so
// board_irq_init can refresh them from the DTB the bootloader
// handed off (UEFI / QEMU `-kernel`). Fallbacks match QEMU virt's
// well-known layout so QEMU boots even when no DTB was passed.
var gicd_base_pa: u64 = 0x08000000;
var gicr_base_pa: u64 = 0x080A0000;
var ns_phys_timer_irq: u32 = 30; // ARM generic timer (PPI 14 → INTID 30)
var pl011_irq: u32 = 33; // PL011 console RX (SPI 1 → INTID 33)

inline fn gicdIsenabler(n: usize) *volatile u32 {
    return @ptrFromInt(gicd_base_pa + LINEAR_MAP_BASE + 0x100 + n * 4);
}

inline fn gicdIrouter(n: usize) *volatile u64 {
    return @ptrFromInt(gicd_base_pa + LINEAR_MAP_BASE + 0x6000 + n * 8);
}

inline fn gicrWaker() *volatile u32 {
    return @ptrFromInt(gicr_base_pa + LINEAR_MAP_BASE + 0x0014);
}

const GICR_WAKER_PROCESSOR_SLEEP: u32 = 1 << 1;
const GICR_WAKER_CHILDREN_ASLEEP: u32 = 1 << 2;

const MU: i32 = 0;

extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
extern fn main_output_char(interface: i32, ch: u8) void;
extern fn main_output_process(interface: i32, p: *anyopaque) void;
extern fn main_recv(interface: i32) u8;
extern fn handle_generic_timer() void;
extern fn timer_tick() void;
extern fn get_core() u32;
extern var current: *anyopaque;

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

/// CPU-side GICv3 bring-up for the calling core. Must run after
/// irq_init_vectors() and before any interrupt fires.
///   0. Pull GIC distributor / redistributor / timer-IRQ / PL011-IRQ
///      values from the DTB if the bootloader handed one off.
///   1. ICC_SRE_EL1 |= 1     — enable system-register CPU interface
///   2. ICC_PMR_EL1 = 0xff   — accept any priority
///   3. ICC_IGRPEN1_EL1 = 1  — enable Group-1 NS interrupts
///   4. Wake the local redistributor (GICR_WAKER): clear
///      ProcessorSleep, then poll until ChildrenAsleep clears.
pub fn board_irq_init() void {
    if (Dtb.fromHandoff()) |dtb| {
        if (dtb.findRegN("arm,gic-v3", 0)) |b| gicd_base_pa = b;
        if (dtb.findRegN("arm,gic-v3", 1)) |b| gicr_base_pa = b;
        if (dtb.findInterrupt("arm,armv8-timer")) |i| ns_phys_timer_irq = i;
    }
    pl011_irq = uart.pl011Irq();

    _ = asm volatile (
        \\mrs %[tmp], S3_0_C12_C12_5
        \\orr %[tmp], %[tmp], #1
        \\msr S3_0_C12_C12_5, %[tmp]
        \\isb
        : [tmp] "=&r" (-> u64),
    );

    asm volatile ("msr S3_0_C4_C6_0, %[v]"
        :
        : [v] "r" (@as(u64, 0xff)),
    );

    asm volatile (
        \\msr S3_0_C12_C12_7, %[v]
        \\isb
        :
        : [v] "r" (@as(u64, 1)),
    );

    const waker = gicrWaker();
    waker.* = waker.* & ~GICR_WAKER_PROCESSOR_SLEEP;
    while ((waker.* & GICR_WAKER_CHILDREN_ASLEEP) != 0) {}
}

/// Enable an interrupt at the GIC distributor and route SPIs
/// (intid >= 32) to core 0. PPIs (intid 16..31) are private to each
/// core's redistributor and don't need an IROUTER write.
export fn enable_interrupt_gic(intid: u32, core: u32) void {
    _ = core;

    const n: usize = @intCast(intid / 32);
    const shift: u5 = @intCast(intid % 32);
    gicdIsenabler(n).* = @as(u32, 1) << shift;

    if (intid >= 32) {
        const router_n: usize = @intCast(intid - 32);
        gicdIrouter(router_n).* = 0; // affinity = 0.0.0.0, IRM=0 (route to specific core)
    }
}

export fn handle_irq() void {
    var iar: u64 = undefined;
    asm volatile ("mrs %[iar], S3_0_C12_C12_0"
        : [iar] "=r" (iar),
    );
    const intid: u32 = @intCast(iar & 0xffffff); // bits[23:0]

    // ns_phys_timer_irq and pl011_irq are runtime values populated
    // from the DTB by board_irq_init, so dispatch via if/else
    // instead of a comptime-only `switch`.
    if (intid == ns_phys_timer_irq) {
        handle_generic_timer();
        asm volatile ("msr S3_0_C12_C12_1, %[iar]"
            :
            : [iar] "r" (iar),
        );
        if (get_core() == 0) {
            main_output(MU, "core ");
            main_output_char(MU, @intCast(get_core() + '0'));
            main_output(MU, ": generic timer interrupt\n");
            main_output_process(MU, current);
            timer_tick();
        }
    } else if (intid == pl011_irq) {
        main_output(MU, "PL011 Recv: ");
        main_output_char(MU, main_recv(MU));
        main_output(MU, "\n");
        asm volatile ("msr S3_0_C12_C12_1, %[iar]"
            :
            : [iar] "r" (iar),
        );
    } else {
        main_output(MU, "unknown pending irq\n");
    }
}
