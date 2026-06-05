// BCM2711 EMMC2 SDHCI driver — PIO block I/O.
//
// MMIO at 0xFE340000 + LINEAR_MAP_BASE; reachable from EL1 via the
// TTBR1 device-typed mapping boot.S sets up for the GIC / UART / timer.
// Single-block read/write only; multi-block (CMD18 / CMD25) + DMA are
// future optimisations.
//
// Init sequence (matches the SD Physical Layer Simplified Spec):
//   1. Software reset (SRST_HC), internal clock @ ~400 kHz, bus power on
//   2. CMD0  — GO_IDLE_STATE
//   3. CMD8  — SEND_IF_COND, check pattern 0xAA (rejects pre-v2 cards)
//   4. ACMD41 loop — SD_SEND_OP_COND, HCS bit set, until card ready
//   5. CMD2  — ALL_SEND_CID
//   6. CMD3  — SEND_REL_ADDR, capture RCA
//   7. CMD9  — SEND_CSD, decode v2 capacity
//   8. CMD7  — SELECT_CARD (transfer state)
//   9. Switch DIV → ~25 MHz
//
// All waits are polled busy loops; IRQ-driven completion is a future
// perf pass. send_cmd / read_block / write_block return i32 with -1
// on any failure path; the caller (kernel.zig) logs `[Debug] EMMC2
// init FAILED` and continues — graceful degradation.
//
// STATUS — Pi-hardware EMMC2 VERIFIED on real microSD across the full
// stack. init() + write_block(LBA 2064) + read_block +
// byte-compare green against a 64 GB SDXC card formatted FAT32 (MBR,
// name "BOOT") booting FlashOS off EMMC2 with the Toshiba USB
// removed. `[PASS] fs-roundtrip` two-boot acceptance on the same
// card — write 1-byte ROUNDTR.MAG + 4-KiB ROUNDTR.DAT on boot 1,
// power-cycle, read back + verify on boot 2 (16/16 tally, 0 ERROR).
// SDHCI single-block PIO: poll BUFFER_*_RDY once per block, burst all
// 128 words through DATAPORT, then poll DATA_DONE once. The BCM2711
// Arasan controller fires BUFFER_*_RDY per block (not per word), so
// per-word polling drops bytes; the once-per-block pattern matches
// Linux sdhci.c and Circle. `log_io_fail` runs on every failure
// return — zero hot-path overhead and one log line per wedged op.

const std = @import("std");
const sdhci = @import("sdhci_cmd");
const block_dev = @import("block_dev");
const mailbox = @import("mailbox"); //      pure: clock-id constants
const mbox = @import("mailbox.zig"); //     board: VideoCore MMIO doorbell

// Per-step debug-print: needed to know which SDHCI init step fails on
// real hardware. main_output is the same UART sink kernel.zig uses;
// declaring it extern here keeps emmc2.zig out of the host-test
// build (the module is rpi4b-only, gated by board.zig).
extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
const MU: i32 = 0;

const LINEAR_MAP_BASE: u64 = 0xFFFF000000000000;
const DEVICE_BASE: u64 = 0xFE000000;
const EMMC2_BASE: u64 = DEVICE_BASE + 0x340000 + LINEAR_MAP_BASE;

// SDHCI register layout (BCM2711 ARM Peripherals §5, simplified to
// the registers the driver touches). Offsets match the SD spec 3.00
// Standard Host Controller register file.
const EmmcRegs = extern struct {
    arg2: u32, // 0x00
    blksizecnt: u32, // 0x04 — BLKSIZE (low 12) | BLKCNT (16..31)
    arg1: u32, // 0x08
    cmdtm: u32, // 0x0C — CMD + TRANSFER_MODE (sdhci_cmd encodes)
    resp0: u32, // 0x10
    resp1: u32, // 0x14
    resp2: u32, // 0x18
    resp3: u32, // 0x1C
    data: u32, // 0x20 — buffer port (PIO drain/fill)
    status: u32, // 0x24
    control0: u32, // 0x28
    control1: u32, // 0x2C
    interrupt: u32, // 0x30 — write-1-to-clear on real card
    irpt_mask: u32, // 0x34
    irpt_en: u32, // 0x38
    control2: u32, // 0x3C
};

inline fn regs() *volatile EmmcRegs {
    return @ptrFromInt(EMMC2_BASE);
}

// Off-struct register pointers — CAPABILITIES (0x40/0x44) and
// SLOTISR_VER (0xFC) are diagnostic-only, so keeping them out of the
// hot-path struct avoids forcing a 256-byte stride on every register
// access.
inline fn reg_at(comptime offset: u32) *volatile u32 {
    return @ptrFromInt(EMMC2_BASE + offset);
}

// STATUS register flags (offset 0x24).
const STATUS_CMD_INHIBIT: u32 = 1 << 0;
const STATUS_DAT_INHIBIT: u32 = 1 << 1;
const STATUS_SPACE_AVAIL: u32 = 1 << 10;
const STATUS_DATA_AVAIL: u32 = 1 << 11;

// INTERRUPT register flags (offset 0x30). Write-1-to-clear.
const INTERRUPT_CMD_DONE: u32 = 1 << 0;
const INTERRUPT_DATA_DONE: u32 = 1 << 1;
const INTERRUPT_WRITE_RDY: u32 = 1 << 4;
const INTERRUPT_READ_RDY: u32 = 1 << 5;
const INTERRUPT_ERR_MASK: u32 = 0x017F8000;

// CONTROL1 register flags (offset 0x2C).
const CTRL1_CLK_INTLEN: u32 = 1 << 0;
const CTRL1_CLK_STABLE: u32 = 1 << 1;
const CTRL1_CLK_EN: u32 = 1 << 2;
const CTRL1_SRST_HC: u32 = 1 << 24;
const CTRL1_SRST_CMD: u32 = 1 << 25;
const CTRL1_SRST_DAT: u32 = 1 << 26;
const CTRL1_SRST_ALL: u32 = CTRL1_SRST_HC | CTRL1_SRST_CMD | CTRL1_SRST_DAT;

// Polled-wait spin counts. Big enough to absorb sub-MHz SD cards on
// real hardware (~700 µs at 1.5 GHz) and trivial on QEMU. Don't lower
// to "tune for QEMU" — real cards are slower.
const SPIN_CMD: u32 = 1_000_000;
const SPIN_DATA: u32 = 1_000_000;

var rca: u32 = 0;
var capacity_blocks: u64 = 0;
var base_clock_hz: u32 = 0;

// Arasan SDHCI core inside the BCM2711 EMMC2 has a clock-domain-crossing
// bugette (Linux drivers/mmc/host/sdhci-iproc.c §"writel" + the bugette
// comment): successive register writes spaced closer than ~2 SD-card
// clock cycles can be silently dropped. At the ~390 kHz identification
// clock that is ~5 µs; back-to-back CPU writes at 1.5 GHz land
// nanoseconds apart, so ARG1 was being lost between BLKSIZECNT and
// CMDTM — every command with a non-zero argument (CMD8, ACMD41, CMD9,
// CMD17, …) fired with ARG=0 and timed out, while CMD0 looked fine
// because its argument is 0 either way. Linux mitigates by inserting a
// 4-SD-clock delay after every writel while host->clock ≤ 400 kHz; this
// driver does the same via `emmc_write`. The flag flips to `false` in
// init step 10 once the bus moves to ~25 MHz, after which the inter-write
// gap is no longer an issue.
var low_clock: bool = true;

// 4 SD-clock cycles at the ~390 kHz identification clock ≈ 10.3 µs,
// rounded up. Linux uses the same 4-clock delay in
// drivers/mmc/host/sdhci-iproc.c while host->clock ≤ 400 kHz.
const IDENT_CLOCK_DOMAIN_CROSSING_DELAY_US: u32 = 11;

inline fn emmc_write(reg: *volatile u32, val: u32) void {
    reg.* = val;
    if (low_clock) delay_us(IDENT_CLOCK_DOMAIN_CROSSING_DELAY_US);
}

pub fn init() i32 {
    const r = regs();

    // Diagnostic dump before any controller poke. Proves the MMIO
    // address is right (SLOTISR_VER reads a sane vendor/version, not
    // 0xFFFFFFFF) and records the controller's pre-init state.
    main_output(MU, "[Debug] EMMC2 diag SLOTISR_VER=0x");
    main_output_u64(MU, reg_at(0xFC).*);
    main_output(MU, " CAPS_LO=0x");
    main_output_u64(MU, reg_at(0x40).*);
    main_output(MU, " CAPS_HI=0x");
    main_output_u64(MU, reg_at(0x44).*);
    main_output(MU, "\n");
    main_output(MU, "[Debug] EMMC2 diag entry ctrl0=0x");
    main_output_u64(MU, r.control0);
    main_output(MU, " ctrl1=0x");
    main_output_u64(MU, r.control1);
    main_output(MU, " ctrl2=0x");
    main_output_u64(MU, r.control2);
    main_output(MU, " status=0x");
    main_output_u64(MU, r.status);
    main_output(MU, " intr=0x");
    main_output_u64(MU, r.interrupt);
    main_output(MU, "\n");

    // 0. Ensure the SD-card power rail is on. Circle's CardInit calls
    //    PROPTAG_SET_POWER_STATE(SD_CARD, ON|WAIT) before any controller
    //    reset on Pi 4. The Pi 4 boot firmware loaded the kernel from
    //    this slot so VDD is normally already on, but matching Circle
    //    defensively rules out a half-powered state where commands
    //    transmit on the wire but the card can't answer.
    main_output(MU, "[Debug] EMMC2 step 0 sd_power_on\n");
    if (!mbox.setPowerState(mailbox.DEVICE_ID_SD_CARD, mailbox.POWER_STATE_ON | mailbox.POWER_STATE_WAIT)) {
        main_output(MU, "[Debug] EMMC2 sd_power_on FAILED\n");
        return -1;
    }
    delay_us(2_000);

    // 0a. Select the 3.3 V SD I/O rail (expander line 4 = 0; per
    //     bcm2711-rpi-4-b.dts VDD_SD_IO_SEL: 0 = 3.3 V, 1 = 1.8 V),
    //     matching the controller's 3.3 V drive — the conventional
    //     bring-up assumption. Pi-HW init has been verified end-to-end
    //     from this 3.3 V default; 1.8 V UHS-I
    //     switching stays a future perf concern.
    main_output(MU, "[Debug] EMMC2 step 0a sd_io_3v3\n");
    if (!mbox.setGpioState(mailbox.EXP_GPIO_SD_1V8, 0)) {
        main_output(MU, "[Debug] EMMC2 sd_io_3v3 FAILED\n");
        return -1;
    }
    delay_us(5_000);

    // 1. Software reset of the host controller. SRST_HC alone leaves
    //    the CMD/DAT sub-state machines in limbo — cmdtm writes have
    //    no effect on real hardware after SRST_HC alone. Triple-reset
    //    (SRST_HC | SRST_CMD | SRST_DAT) matches Linux's
    //    drivers/mmc/host/sdhci.c sdhci_reset(host, SDHCI_RESET_ALL).
    main_output(MU, "[Debug] EMMC2 step 1 SRST_ALL\n");
    emmc_write(&r.control1, r.control1 | CTRL1_SRST_ALL);
    if (!busy_wait_clear(&r.control1, CTRL1_SRST_ALL, 100_000)) return -1;

    // 1a. Bring the SD bus up before the clock. Circle's Pi 4 EMMC
    //     reset path powers VDD and clears CONTROL2 before configuring
    //     SDCLK; SRST_HC zeroes both. POWER_ON = bit 8, BUS_VOLTAGE =
    //     bits 11:9 (0b111 = 3.3 V). Let the rail settle before the
    //     clock is brought up.
    main_output(MU, "[Debug] EMMC2 step 1a bus_power\n");
    emmc_write(&r.control2, 0);
    emmc_write(&r.control0, (@as(u32, 1) << 8) | (@as(u32, 0b111) << 9));
    // SD spec PLSS §6.4.1: ≥1 ms after VDD reaches stable level before
    // first command. Pi 4 firmware can leave BUS_POWER cleared (entry
    // ctrl0=0x00800000 has bit 8 = 0), so this write may be the actual
    // VDD power-on edge for the card — be generous to cover both
    // power-cycle (cold rise) and pure-controller-toggle paths.
    delay_us(10_000);

    // 1b. Resolve the EMMC2 base clock from the VideoCore firmware.
    //     The SDHCI divider is derived from this; the CAP register's
    //     base-clock field is unreliable on the BCM2711, so the
    //     firmware value is the only sound source.
    main_output(MU, "[Debug] EMMC2 step 1b base_clock\n");
    base_clock_hz = mbox.getClockRate(mailbox.CLOCK_ID_EMMC2);
    if (base_clock_hz == 0) {
        main_output(MU, "[Debug] EMMC2 mailbox clock query FAILED\n");
        return -1;
    }
    main_output(MU, "[Debug] EMMC2 base clock=0x");
    main_output_u64(MU, base_clock_hz);
    main_output(MU, "\n");

    // 2. Internal clock + identification-mode divider (~400 kHz). The
    //    divisor is a power of two derived from the firmware base
    //    clock (the BCM2711 EMMC2 only accepts power-of-two dividers).
    //    The delays around CLK_EN mirror Circle's reset path — real
    //    hardware wants the internal clock to settle before the card
    //    clock is gated on, and again before the first command.
    //    TOUNIT = 0xC matches Circle's Pi 4 data-timeout choice.
    main_output(MU, "[Debug] EMMC2 step 2 CLK_STABLE\n");
    const id_div = sdhci.clockDivisor(base_clock_hz, 400_000);
    emmc_write(&r.control1, CTRL1_CLK_INTLEN | sdhci.control1ClockBits(id_div) | (@as(u32, 0xC) << 16));
    if (!busy_wait_set(&r.control1, CTRL1_CLK_STABLE, 100_000)) return -1;
    delay_us(2_000);
    emmc_write(&r.control1, r.control1 | CTRL1_CLK_EN);
    delay_us(2_000);

    // 2a. Enable interrupt-status latching. SRST zeroes IRPT_MASK
    //     (0x34, the SDHCI Normal+Error Interrupt Status Enable
    //     register); while it reads 0 the INTERRUPT register (0x30)
    //     never latches a single event, so the polled send_cmd loop
    //     spins out every command. IRPT_MASK gates 0x30 latching;
    //     IRPT_EN (0x38) is the physical-IRQ signal enable and stays
    //     clear — send_cmd is polled and no EMMC line is wired into
    //     the GIC. The explicit IRPT_EN=0 write matches Circle's
    //     CardReset (defensive against firmware that left it non-zero).
    emmc_write(&r.irpt_en, 0);
    emmc_write(&r.interrupt, 0xFFFF_FFFF);
    emmc_write(&r.irpt_mask, 0xFFFF_FFFF);
    delay_us(2_000);

    main_output(MU, "[Debug] EMMC2 pre-CMD0 status=0x");
    main_output_u64(MU, r.status);
    main_output(MU, " ctrl0=0x");
    main_output_u64(MU, r.control0);
    main_output(MU, " ctrl1=0x");
    main_output_u64(MU, r.control1);
    main_output(MU, " ctrl2=0x");
    main_output_u64(MU, r.control2);
    main_output(MU, " mask=0x");
    main_output_u64(MU, r.irpt_mask);
    main_output(MU, "\n");

    // 3. CMD0 — GO_IDLE_STATE. No response; the card transitions to idle.
    //    Triple-issue with 5 ms gaps. Pi 4 firmware can hand off with
    //    the card in Stand-by or Transfer state (RCA assigned, last
    //    block read complete) rather than the cold-POR Idle state every
    //    other bare-metal driver assumes. A single CMD0 with no inter-
    //    command settle is not guaranteed to traverse the state machine
    //    back to Idle when the card was warm-handed-off. Three sends
    //    with 5 ms gaps gives the card-side state machine time to
    //    transition, per SD PLSS §4.4 NCC + post-reset settle.
    main_output(MU, "[Debug] EMMC2 step 3 CMD0 (x3)\n");
    var cmd0_try: u32 = 0;
    while (cmd0_try < 3) : (cmd0_try += 1) {
        if (send_cmd(sdhci.CMD0_GO_IDLE, 0, BLKSIZECNT_NONE) < 0) return -1;
        delay_us(5_000);
    }

    main_output(MU, "[Debug] EMMC2 post-CMD0 status=0x");
    main_output_u64(MU, r.status);
    main_output(MU, " intr=0x");
    main_output_u64(MU, r.interrupt);
    main_output(MU, "\n");

    // Extra settle after CMD0 burst, before CMD8 — covers post-state-
    // transition NCC plus internal card-clock domain crossing.
    delay_us(5_000);

    // 4. CMD8 — SEND_IF_COND. Echo the 0xAA check pattern back in R7;
    //    mismatch means pre-v2.0 card or out-of-range voltage rail.
    main_output(MU, "[Debug] EMMC2 step 4 CMD8\n");
    if (send_cmd(sdhci.CMD8_SEND_IF_COND, sdhci.CMD8_ARG_VHS_27_36_CHECK_AA, BLKSIZECNT_NONE) < 0) {
        // CMD8 timeout = no card present or unreadable card. Fail
        // cleanly; kernel.zig logs `EMMC2 init FAILED` and degrades
        // to the initramfs path.
        return -1;
    }
    if ((r.resp0 & 0xFF) != 0xAA) {
        main_output(MU, "[Debug] EMMC2 step 4 CMD8 echo mismatch\n");
        return -1;
    }

    // 5. ACMD41 — SD_SEND_OP_COND with HCS. Repeated until bit 31 of
    //    OCR (resp0) is set, indicating card power-up complete. Each
    //    ACMD requires a preceding CMD55 (APP_CMD); failures inside
    //    the loop are tolerated because the next pass re-issues both.
    main_output(MU, "[Debug] EMMC2 step 5 ACMD41\n");
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        _ = send_cmd(sdhci.CMD55_APP_CMD, 0, BLKSIZECNT_NONE);
        _ = send_cmd(sdhci.ACMD41_SD_SEND_OP_COND, sdhci.ACMD41_ARG_HCS_AND_VOLT, BLKSIZECNT_NONE);
        if ((r.resp0 & (@as(u32, 1) << 31)) != 0) break;
        delay_us(10_000);
    }
    if (tries == 100) return -1;

    // 6. CMD2 — ALL_SEND_CID. R2 lands in resp0..resp3; the CID is
    //    not consumed past init, but the card must transition through
    //    this state to accept CMD3.
    main_output(MU, "[Debug] EMMC2 step 6 CMD2\n");
    if (send_cmd(sdhci.CMD2_ALL_SEND_CID, 0, BLKSIZECNT_NONE) < 0) return -1;

    // 7. CMD3 — SEND_REL_ADDR. R6: RCA in resp0[31:16]. Subsequent
    //    addressed commands (CMD7, CMD9) use this in arg[31:16].
    main_output(MU, "[Debug] EMMC2 step 7 CMD3\n");
    if (send_cmd(sdhci.CMD3_SEND_REL_ADDR, 0, BLKSIZECNT_NONE) < 0) return -1;
    rca = r.resp0 & 0xFFFF_0000;

    // 8. CMD9 — SEND_CSD. R2 again; parseCsdV2 rejects pre-SDHC v1.0
    //    cards (CSD_STRUCTURE = 0) which this driver does not
    //    support.
    main_output(MU, "[Debug] EMMC2 step 8 CMD9\n");
    if (send_cmd(sdhci.CMD9_SEND_CSD, rca, BLKSIZECNT_NONE) < 0) return -1;
    const csd = sdhci.parseCsdV2(.{ r.resp0, r.resp1, r.resp2, r.resp3 }) catch {
        main_output(MU, "[Debug] EMMC2 step 8 CSD parse failed (v1 card?)\n");
        return -1;
    };
    capacity_blocks = csd.capacity_blocks;

    // 9. CMD7 — SELECT_CARD. Moves the card into the transfer state so
    //    CMD17 / CMD24 are legal.
    main_output(MU, "[Debug] EMMC2 step 9 CMD7\n");
    if (send_cmd(sdhci.CMD7_SELECT_CARD, rca, BLKSIZECNT_NONE) < 0) return -1;

    // 10. Transfer-mode clock (~25 MHz). Divisor derived from the same
    //     firmware base clock as the identification divider. The PIO
    //     polled-wait loop dominates throughput, so default-speed SD
    //     (25 MHz) is fine; future perf can pick high-speed via CAP1.
    //     Once the clock crosses ~400 kHz the Arasan CDC bugette is no
    //     longer triggered (the 2-SD-clock window shrinks below CPU
    //     instruction-pair spacing only at the ID clock), so clear
    //     `low_clock` here and skip the per-write delay from now on.
    main_output(MU, "[Debug] EMMC2 step 10 switch_clk\n");
    const tx_div = sdhci.clockDivisor(base_clock_hz, 25_000_000);
    var c1 = r.control1;
    c1 &= ~CTRL1_CLK_EN;
    emmc_write(&r.control1, c1);
    c1 &= ~@as(u32, 0xFFC0); //                clear SDCLK freq select [15:6]
    c1 |= sdhci.control1ClockBits(tx_div);
    emmc_write(&r.control1, c1);
    if (!busy_wait_set(&r.control1, CTRL1_CLK_STABLE, 100_000)) return -1;
    emmc_write(&r.control1, r.control1 | CTRL1_CLK_EN);
    low_clock = false;

    // Wire the BlockDev vtable now the controller is in transfer state.
    // The FAT32 backend reads + writes through block_dev.sd_dev;
    // Acceptance #7 checks the slot is populated post-init.
    block_dev.sd_dev = .{ .read_fn = read_block, .write_fn = write_block };
    return 0;
}

// Programmed into BLKSIZECNT for non-data commands. Circle writes
// BLKSIZECNT before *every* command (m_block_size | (m_blocks_to_transfer
// << 16); both fields are 0 outside a data transfer); this driver
// follows defensively — some BCM2711 EMMC2 firmware revisions
// reportedly hang CMD8 when stale BLKSIZECNT bits leak in from a
// prior data op.
const BLKSIZECNT_NONE: u32 = 0;
const BLKSIZECNT_512x1: u32 = (@as(u32, 1) << 16) | 512;

fn send_cmd(cmdtm: u32, arg: u32, blksizecnt: u32) i32 {
    const r = regs();
    if (!busy_wait_clear(&r.status, STATUS_CMD_INHIBIT, SPIN_CMD)) {
        main_output(MU, "[Debug] send_cmd CMD_INHIBIT stuck\n");
        return -1;
    }
    // Clear any stale CMD_DONE / error bits left from a previous command.
    // The Arasan clock-domain-crossing bug applies to *every* write at
    // ID-mode clock, including this one — without the inter-write gap
    // the BLKSIZECNT / ARG1 writes that follow can be silently dropped.
    emmc_write(&r.interrupt, INTERRUPT_CMD_DONE | INTERRUPT_ERR_MASK);
    emmc_write(&r.blksizecnt, blksizecnt);
    emmc_write(&r.arg1, arg);
    emmc_write(&r.cmdtm, cmdtm);

    var spin: u32 = 0;
    while (spin < SPIN_CMD) : (spin += 1) {
        const irpt = r.interrupt;
        if ((irpt & INTERRUPT_ERR_MASK) != 0) {
            main_output(MU, "[Debug] send_cmd ERR_MASK irpt=0x");
            main_output_u64(MU, irpt);
            main_output(MU, " status=0x");
            main_output_u64(MU, r.status);
            main_output(MU, " resp0=0x");
            main_output_u64(MU, r.resp0);
            main_output(MU, " resp1=0x");
            main_output_u64(MU, r.resp1);
            main_output(MU, "\n");
            emmc_write(&r.interrupt, INTERRUPT_ERR_MASK);
            main_output(MU, "[Debug] send_cmd post-clear intr=0x");
            main_output_u64(MU, r.interrupt);
            main_output(MU, "\n");
            return -1;
        }
        if ((irpt & INTERRUPT_CMD_DONE) != 0) {
            emmc_write(&r.interrupt, INTERRUPT_CMD_DONE);
            return 0;
        }
    }
    main_output(MU, "[Debug] send_cmd CMD_DONE timeout status=0x");
    main_output_u64(MU, r.status);
    main_output(MU, " irpt=0x");
    main_output_u64(MU, r.interrupt);
    main_output(MU, "\n");
    return -1;
}

pub fn read_block(lba: u32, buf: *[512]u8) callconv(.c) i32 {
    const r = regs();
    if (!busy_wait_clear(&r.status, STATUS_CMD_INHIBIT | STATUS_DAT_INHIBIT, SPIN_DATA)) {
        log_io_fail("read pre-CMD17 inhibit-clear timeout", 0xFFFFFFFF);
        return -1;
    }
    // BLKSIZE = 512 (low 12 bits), BLKCNT = 1 (bits 16..31).
    if (send_cmd(sdhci.CMD17_READ_SINGLE, lba, BLKSIZECNT_512x1) < 0) return -1;

    // SDHCI single-block PIO: READ_RDY fires once when the block buffer
    // has the full 512 bytes ready; the host then drains it word-by-word
    // without re-polling. Per-word polling is wrong — the interrupt only
    // re-fires for the next block (this driver issues one).
    if (!busy_wait_set(&r.interrupt, INTERRUPT_READ_RDY | INTERRUPT_ERR_MASK, SPIN_DATA)) {
        log_io_fail("read READ_RDY timeout", 0xFFFFFFFF);
        return -1;
    }
    if ((r.interrupt & INTERRUPT_ERR_MASK) != 0) {
        log_io_fail("read ERR before READ_RDY", 0xFFFFFFFF);
        emmc_write(&r.interrupt, INTERRUPT_ERR_MASK);
        return -1;
    }
    emmc_write(&r.interrupt, INTERRUPT_READ_RDY);

    var i: u32 = 0;
    while (i < 128) : (i += 1) {
        const w = r.data;
        // SD bus is little-endian; the data port hands back the wire
        // order directly, so a verbatim byte copy preserves layout.
        const off = i * 4;
        const wbytes = std.mem.asBytes(&w);
        buf[off + 0] = wbytes[0];
        buf[off + 1] = wbytes[1];
        buf[off + 2] = wbytes[2];
        buf[off + 3] = wbytes[3];
    }

    if (!busy_wait_set(&r.interrupt, INTERRUPT_DATA_DONE | INTERRUPT_ERR_MASK, SPIN_DATA)) {
        log_io_fail("read DATA_DONE timeout", 0xFFFFFFFF);
        return -1;
    }
    if ((r.interrupt & INTERRUPT_ERR_MASK) != 0) {
        log_io_fail("read ERR before DATA_DONE", 0xFFFFFFFF);
        emmc_write(&r.interrupt, INTERRUPT_ERR_MASK);
        return -1;
    }
    emmc_write(&r.interrupt, INTERRUPT_DATA_DONE);
    return 0;
}

pub fn write_block(lba: u32, buf: *const [512]u8) callconv(.c) i32 {
    const r = regs();
    if (!busy_wait_clear(&r.status, STATUS_CMD_INHIBIT | STATUS_DAT_INHIBIT, SPIN_DATA)) {
        log_io_fail("write pre-CMD24 inhibit-clear timeout", 0xFFFFFFFF);
        return -1;
    }
    if (send_cmd(sdhci.CMD24_WRITE_SINGLE, lba, BLKSIZECNT_512x1) < 0) return -1;

    // SDHCI single-block PIO: WRITE_RDY fires once when the block buffer
    // is ready to accept 512 bytes; the host then pushes the full block
    // word-by-word without re-polling. Per-word polling is wrong — the
    // interrupt only re-fires for the next block (this driver issues one).
    if (!busy_wait_set(&r.interrupt, INTERRUPT_WRITE_RDY | INTERRUPT_ERR_MASK, SPIN_DATA)) {
        log_io_fail("write WRITE_RDY timeout", 0xFFFFFFFF);
        return -1;
    }
    if ((r.interrupt & INTERRUPT_ERR_MASK) != 0) {
        log_io_fail("write ERR before WRITE_RDY", 0xFFFFFFFF);
        emmc_write(&r.interrupt, INTERRUPT_ERR_MASK);
        return -1;
    }
    emmc_write(&r.interrupt, INTERRUPT_WRITE_RDY);

    var i: u32 = 0;
    while (i < 128) : (i += 1) {
        const off = i * 4;
        var w: u32 = undefined;
        const wbytes = std.mem.asBytes(&w);
        wbytes[0] = buf[off + 0];
        wbytes[1] = buf[off + 1];
        wbytes[2] = buf[off + 2];
        wbytes[3] = buf[off + 3];
        r.data = w;
    }

    if (!busy_wait_set(&r.interrupt, INTERRUPT_DATA_DONE | INTERRUPT_ERR_MASK, SPIN_DATA)) {
        log_io_fail("write DATA_DONE timeout", 0xFFFFFFFF);
        return -1;
    }
    if ((r.interrupt & INTERRUPT_ERR_MASK) != 0) {
        log_io_fail("write ERR before DATA_DONE", 0xFFFFFFFF);
        emmc_write(&r.interrupt, INTERRUPT_ERR_MASK);
        return -1;
    }
    emmc_write(&r.interrupt, INTERRUPT_DATA_DONE);
    return 0;
}

fn log_io_fail(tag: [*:0]const u8, word_idx: u32) void {
    const r = regs();
    main_output(MU, "[Debug] EMMC2 ");
    main_output(MU, tag);
    if (word_idx != 0xFFFFFFFF) {
        main_output(MU, " word=0x");
        main_output_u64(MU, word_idx);
    }
    main_output(MU, " status=0x");
    main_output_u64(MU, r.status);
    main_output(MU, " intr=0x");
    main_output_u64(MU, r.interrupt);
    main_output(MU, " resp0=0x");
    main_output_u64(MU, r.resp0);
    main_output(MU, "\n");
}

// Polled-bit helpers. Returns true on the bit reaching the target
// state inside `max_spin` iterations, false on timeout. Callers
// translate timeout to a -1 return (send_cmd / read_block / write_block).
fn busy_wait_set(reg: *volatile u32, mask: u32, max_spin: u32) bool {
    var i: u32 = 0;
    while (i < max_spin) : (i += 1) {
        if ((reg.* & mask) != 0) return true;
    }
    return false;
}

fn busy_wait_clear(reg: *volatile u32, mask: u32, max_spin: u32) bool {
    var i: u32 = 0;
    while (i < max_spin) : (i += 1) {
        if ((reg.* & mask) == 0) return true;
    }
    return false;
}

// Coarse delay used during ACMD41 polling. Real driver uses the
// generic timer's udelay; dragging that in at this layer would force
// a new named-module dependency for a microsecond pause that is only
// hit during init. A future perf pass can swap. The 100×us multiplier
// is a back-of-envelope match for a 1.5 GHz core with the spin body
// being a single `nop`; QEMU executes faster but the only effect is
// quicker init, which is fine.
fn delay_us(us: u32) void {
    var i: u64 = @as(u64, us) * 100;
    while (i > 0) : (i -= 1) {
        asm volatile ("nop");
    }
}
