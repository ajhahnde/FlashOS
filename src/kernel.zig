// kernel: boot and main loop.

const board = @import("board.zig");
const initramfs = @import("initramfs");
const initramfs_backend = @import("initramfs_backend");
const fat32_backend = @import("fat32_backend");
const fdtable = @import("fdtable");
const task_layout = @import("task_layout");

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
extern fn main_output_process(interface: i32, p: *task_layout.TaskStruct) void;
extern fn delay(ticks: u64) void;
extern fn get_el() u32;

// Generic timer
extern fn generic_timer_init() void;
extern fn get_sys_count() u64;
extern fn hwrng_init() void;

// IRQ
extern fn enable_interrupt_gic(intid: u32, core: u32) void;
extern fn irq_init_vectors() void;
extern fn irq_enable() void;

// Fork / sched
extern fn copy_process(clone_flags: u64, fn_ptr: u64, arg: u64) i32;
extern fn prepare_move_to_user_elf(blob_addr_kva: u64, blob_size: u64) i32;
extern fn sched_init() void;
extern fn schedule() void;
extern var current: ?*task_layout.TaskStruct;

// Syscall table
extern fn sys_call_table_relocate() void;

// Trace
extern fn trace_init() void;
extern fn trace_output_kernel_pts(interface: i32) void;
extern fn pl011_uart_init() void;
extern fn ksyms_init() void;

// Page allocator
extern fn mem_map_init() void;
extern fn mem_map_reserve_below(end_pa: u64) void;
extern fn mem_map_reserve_above(start_pa: u64) void;

// PA marker emitted by both board linker scripts: the page just past the
// kernel image and its board-specific reserved regions (page tables on
// rpi4b; page tables + 64 MiB sdscratch on virt). Read at boot so the
// page allocator never returns a PA that overlaps the kernel image.
extern var _kernel_pa_end: u8;

const build_options = @import("build_options");
extern fn dump_free_count() u64;

// Cross-core boot synchronization
export var state: u32 = 0;

/// Run by PID 1; returns to entry.S and does a kernel_exit 0.
///
/// PID 1 is ELF-loaded: `/sbin/init` is the `pid1.elf`
/// artifact baked into the embedded initramfs. Its bytes (already
/// TTBR1-mapped, no allocation) go to `prepare_move_to_user_elf`,
/// the same loader the exec-elf / flibc test payloads use.
export fn kernel_process() void {
    main_output(MU, "pid 1 started in EL");
    main_output_char(MU, @intCast(get_el() + '0'));
    main_output(MU, "\n");

    const entry = (initramfs.locate("/sbin/init") catch null) orelse {
        main_output(MU, "PID 1: /sbin/init missing from initramfs\n");
        return;
    };

    // Pre-install stdio as console fds before handing control to EL0.
    // Console slots are refcount-exempt
    // shared singletons (ptr=null, kind=console) so the three installs
    // allocate no page and leave the free-page baseline untouched.
    // fork() inherits them via fdtable.dupAll; execve() preserves them.
    // User-space sees fd 0/1/2 already wired to the mini-UART.
    const cur: *task_layout.TaskStruct = current.?;
    _ = fdtable.install(cur, .console, null);
    _ = fdtable.install(cur, .console, null);
    _ = fdtable.install(cur, .console, null);

    const blob_kva: u64 = @intFromPtr(entry.data.ptr);
    const err = prepare_move_to_user_elf(blob_kva, entry.data.len);
    if (err < 0) {
        main_output(MU, "PID 1: ELF load failed\n");
    }
}

// Scratch LBA for the EL1 block-I/O smoke check. Retargeted from
// LBA 34_816 to LBA 2064: the single-partition
// format_sd.sh means the old 34_816 falls inside the FAT32 data
// region and would collide with user files once the disk fills in
// LBA 2064 sits in the FAT32 reserved-sector window
// (partition start LBA 2048 + 16 = 17th reserved sector, between the
// BPB at LBA 2048 and FAT1 around LBA 2080), which no FAT32 driver
// reads or writes. The 16-sector offset matches the BPB's
// `reserved_sec_cnt = 32` window minus the first BPB sector and the
// FSInfo at LBA 2049 — well clear of both. One-constant permanent fix.
const EMMC2_BLOCK_LBA: u32 = 2064;

// EL1-side block-I/O smoke check. Writes a deterministic pattern to
// EMMC2_BLOCK_LBA, reads it back through the same vtable, byte-
// compares. Emits `[PASS] emmc2-block` on match and `[FAIL]
// emmc2-block` (with a short reason tag) otherwise. Both buffers
// live on the kernel stack — no page allocation, no shift to the
// free-page baseline. scripts/run_qemu_test.sh greps for `[FAIL]
// emmc2-block` and fails the run if present; the EL0 16/16 tally is
// unaffected because this scenario runs before PID 1 is forked.
fn run_emmc2_smoke() void {
    var write_buf: [512]u8 = undefined;
    var read_buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 512) : (i += 1) write_buf[i] = @intCast((i + 0x42) & 0xFF);

    main_output(MU, "[TEST] emmc2-block\n");
    if (board.emmc2.write_block(EMMC2_BLOCK_LBA, &write_buf) != 0) {
        main_output(MU, "[FAIL] emmc2-block (write)\n");
        return;
    }
    if (board.emmc2.read_block(EMMC2_BLOCK_LBA, &read_buf) != 0) {
        main_output(MU, "[FAIL] emmc2-block (read)\n");
        return;
    }
    i = 0;
    while (i < 512) : (i += 1) {
        if (read_buf[i] != write_buf[i]) {
            main_output(MU, "[FAIL] emmc2-block (mismatch)\n");
            return;
        }
    }
    main_output(MU, "[PASS] emmc2-block\n");
}

export fn kernel_main_impl(id: u64) void {
    // core 0 initializes mini-uart and handles uart interrupts
    if (id == 0) {
        // Page allocator bitmap zeroed first so anything later in bring-up
        // can hit get_free_page without a lazy-init branch.
        mem_map_init();
        // Reserve PAs occupied by the kernel image so get_free_page never
        // hands out a page that overlaps `.text` / `.data` / `.bss` /
        // page tables / sdscratch. On rpi4b the kernel sits below the
        // pool — reserve_below is a no-op. On virt the kernel is loaded
        // inside the pool window and the reservation is load-bearing.
        mem_map_reserve_below(@intFromPtr(&_kernel_pa_end));
        // Cap the pool at the actual RAM end on virt (QEMU `-m 1G` ⇒
        // RAM ends at 0x80000000, well below MALLOC_END's RPi-derived
        // 0xFC000000). Without this, an exhausting allocator path would
        // hand out PAs that map to nothing once the in-RAM half is full.
        if (build_options.board == .virt) {
            mem_map_reserve_above(0x80000000);
        }

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

        // USB-OTG gadget bring-up (DWC2). The device MMIO at 0xFE980000 is
        // already device-mapped by boot.S, so this needs no page allocator.
        // Fails soft on QEMU (no DWC2 device path) — bounded waits return
        // -1 and the polled console simply never enumerates. Serviced from
        // the PID-0 idle loop below.
        if (board.usb.usb_init() < 0) {
            main_output(MU, "[Debug] USB init FAILED (no controller?)\n");
        } else {
            main_output(MU, "[Debug] USB init OK\n");
        }

        ksyms_init();
        main_output(MU, "[Debug] ksyms done\n");

        sys_call_table_relocate();
        main_output(MU, "[Debug] Syscalls relocated\n");

        trace_init();
        main_output(MU, "[Debug] trace_init done\n");

        trace_output_kernel_pts(PL);
        main_output(MU, "[Debug] trace_output_kernel_pts done\n");

        // VFS root mount bring-up. initramfs_backend
        // only sets pointers — no get_free_page — so it slots in ahead
        // of the free-page baseline emit without shifting it. The FAT32
        // /mnt mount is wired later, after board.emmc2.init() has wired
        // block_dev.sd_dev (fat32_backend.init issues block reads).
        initramfs_backend.init();
        main_output(MU, "[Debug] VFS initramfs registered\n");

        // Block-device bring-up. On virt
        // the memory-backed fake never fails — graceful degradation
        // (log + continue) is still the contract for the rpi4b
        // driver, which can fail on missing SD card.
        // The smoke check below covers acceptance #2 + #7 in one
        // shot: it exercises the BlockDev vtable end-to-end and
        // proves init() wired `block_dev.sd_dev`.
        if (board.emmc2.init() < 0) {
            main_output(MU, "[Debug] EMMC2 init FAILED\n");
        } else {
            main_output(MU, "[Debug] EMMC2 init OK\n");
            run_emmc2_smoke();
            // FAT32 /mnt mount — needs block_dev.sd_dev, wired just
            // above by board.emmc2.init(). Fails soft: a blank/bad
            // disk leaves mount_table[1] null and /mnt/* resolves to
            // ENOENT.
            if (fat32_backend.init() < 0) {
                main_output(MU, "[Debug] VFS fat32 mount failed (slot null)\n");
            } else {
                main_output(MU, "[Debug] VFS fat32 mounted\n");
                // Permission overlay: init() parsed PERMS.TAB
                // into the backend's table. A mounted volume without a
                // parseable overlay is the loud anti-brick announcement:
                // /mnt runs on defaults (shadow floored 0600 root:root)
                // until the operator reseeds the overlay file.
                if (!fat32_backend.overlay_ok) {
                    main_output(MU, "[Debug] /mnt overlay missing or corrupt - defaults active, shadow floored\n");
                }
            }
        }

        // Entropy source bring-up. Seeds the fallback generator
        // from CNTPCT (readable from reset — independent of the
        // generic-timer IRQ setup below), self-tests, and announces the
        // active source. The announce line tees into the kernel log ring,
        // where [TEST] rng asserts it later. Allocates nothing.
        hwrng_init();

        // Boot-time free-page baseline. Logged before any task is created
        // so the user-space dumps later in the trace can be compared
        // against this absolute reference.
        _ = dump_free_count();

        state = 0;
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
        main_output_process(MU, current.?);
        // create pid 1, kernel threads don't need a user stack page
        const res = copy_process(KTHREAD, @intFromPtr(&kernel_process), 0);
        if (res <= 0) {
            main_output(MU, "fork error\n");
        }
        while (true) {
            // Idle-path UART RX poll (PID 0) — defensive backstop. The AUX
            // RX interrupt is the primary drain and reaches handle_irq on
            // real hardware; this only catches a byte left between IRQ
            // slots. No-op on virt.
            board.uart.poll_rx_into_console();
            board.usb.poll();
            schedule();
        }
    }
}
