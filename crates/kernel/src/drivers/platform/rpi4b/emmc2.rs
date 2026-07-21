//! BCM2711 EMMC2 SDHCI driver — PIO block I/O.
//!
//! MMIO at 0xFE340000 + LINEAR_MAP_BASE; reachable from EL1 via the TTBR1
//! device-typed mapping boot.S sets up for the GIC / UART / timer. Single-block
//! read/write only; multi-block (CMD18 / CMD25) + DMA are future optimisations.
//!
//! Init sequence (matches the SD Physical Layer Simplified Spec):
//!   1. Software reset (SRST_HC), internal clock @ ~400 kHz, bus power on
//!   2. CMD0  — GO_IDLE_STATE
//!   3. CMD8  — SEND_IF_COND, check pattern 0xAA (rejects pre-v2 cards)
//!   4. ACMD41 loop — SD_SEND_OP_COND, HCS bit set, until card ready
//!   5. CMD2  — ALL_SEND_CID
//!   6. CMD3  — SEND_REL_ADDR, capture RCA
//!   7. CMD9  — SEND_CSD, decode v2 capacity
//!   8. CMD7  — SELECT_CARD (transfer state)
//!   9. Switch DIV → ~25 MHz
//!
//! All waits are polled busy loops; IRQ-driven completion is a future perf
//! pass. `init` / `send_cmd` / `read_block` / `write_block` return `i32` with -1
//! on any failure path; the caller logs `[Debug] EMMC2 init FAILED` and
//! continues — graceful degradation.
//!
//! SDHCI single-block PIO: poll BUFFER_*_RDY once per block, burst all 128
//! words through DATAPORT, then poll DATA_DONE once. The BCM2711 Arasan
//! controller fires BUFFER_*_RDY per block (not per word), so per-word polling
//! drops bytes; the once-per-block pattern matches Linux sdhci.c and Circle.
//! `log_io_fail` runs on every failure return — zero hot-path overhead and one
//! log line per wedged op.

use crate::block_dev;
use crate::mailbox;
use crate::rpi4b_mailbox as mbox;
use crate::sdhci_cmd as sdhci;
use crate::utilc;
use core::ptr::{addr_of_mut, read_volatile, write_volatile};
use flashos_console_ui::tags;

/// Per-step SDHCI init trace; flip to `true` to see which step fails on a bad
/// card.
const DIAG: bool = false;

/// The mini-UART sink kernel bring-up logs through.
const MU: i32 = 0;

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;
const DEVICE_BASE: usize = 0xFE00_0000;
const EMMC2_BASE: usize = DEVICE_BASE + 0x34_0000 + LINEAR_MAP_BASE;

/// SDHCI register layout (BCM2711 ARM Peripherals §5, simplified to the
/// registers the driver touches). Offsets match the SD spec 3.00 Standard Host
/// Controller register file.
#[repr(C)]
struct EmmcRegs {
    arg2: u32,       // 0x00
    blksizecnt: u32, // 0x04 — BLKSIZE (low 12) | BLKCNT (16..31)
    arg1: u32,       // 0x08
    cmdtm: u32,      // 0x0C — CMD + TRANSFER_MODE (sdhci_cmd encodes)
    resp0: u32,      // 0x10
    resp1: u32,      // 0x14
    resp2: u32,      // 0x18
    resp3: u32,      // 0x1C
    data: u32,       // 0x20 — buffer port (PIO drain/fill)
    status: u32,     // 0x24
    control0: u32,   // 0x28
    control1: u32,   // 0x2C
    interrupt: u32,  // 0x30 — write-1-to-clear on real card
    irpt_mask: u32,  // 0x34
    irpt_en: u32,    // 0x38
    control2: u32,   // 0x3C
}

#[inline]
fn regs() -> *mut EmmcRegs {
    EMMC2_BASE as *mut EmmcRegs
}

/// Off-struct register pointer. CAPABILITIES (0x40/0x44) and SLOTISR_VER (0xFC)
/// are diagnostic-only, so keeping them out of the hot-path struct avoids
/// forcing a 256-byte stride on every register access.
#[inline]
fn reg_at(offset: usize) -> *mut u32 {
    (EMMC2_BASE + offset) as *mut u32
}

// STATUS register flags (offset 0x24).
const STATUS_CMD_INHIBIT: u32 = 1 << 0;
const STATUS_DAT_INHIBIT: u32 = 1 << 1;

// INTERRUPT register flags (offset 0x30). Write-1-to-clear.
const INTERRUPT_CMD_DONE: u32 = 1 << 0;
const INTERRUPT_DATA_DONE: u32 = 1 << 1;
const INTERRUPT_WRITE_RDY: u32 = 1 << 4;
const INTERRUPT_READ_RDY: u32 = 1 << 5;
const INTERRUPT_ERR_MASK: u32 = 0x017F_8000;

// CONTROL1 register flags (offset 0x2C).
const CTRL1_CLK_INTLEN: u32 = 1 << 0;
const CTRL1_CLK_STABLE: u32 = 1 << 1;
const CTRL1_CLK_EN: u32 = 1 << 2;
const CTRL1_SRST_HC: u32 = 1 << 24;
const CTRL1_SRST_CMD: u32 = 1 << 25;
const CTRL1_SRST_DAT: u32 = 1 << 26;
const CTRL1_SRST_ALL: u32 = CTRL1_SRST_HC | CTRL1_SRST_CMD | CTRL1_SRST_DAT;

/// Polled-wait spin counts. Big enough to absorb sub-MHz SD cards on real
/// hardware (~700 µs at 1.5 GHz) and trivial on QEMU. Don't lower to "tune for
/// QEMU" — real cards are slower.
const SPIN_CMD: u32 = 1_000_000;
const SPIN_DATA: u32 = 1_000_000;

static mut RCA: u32 = 0;
static mut CAPACITY_BLOCKS: u64 = 0;
static mut BASE_CLOCK_HZ: u32 = 0;

/// Arasan SDHCI core inside the BCM2711 EMMC2 has a clock-domain-crossing
/// bugette (Linux drivers/mmc/host/sdhci-iproc.c §"writel" + the bugette
/// comment): successive register writes spaced closer than ~2 SD-card clock
/// cycles can be silently dropped. At the ~390 kHz identification clock that is
/// ~5 µs; back-to-back CPU writes at 1.5 GHz land nanoseconds apart, so ARG1 was
/// being lost between BLKSIZECNT and CMDTM — every command with a non-zero
/// argument (CMD8, ACMD41, CMD9, CMD17, …) fired with ARG=0 and timed out, while
/// CMD0 looked fine because its argument is 0 either way. Linux mitigates by
/// inserting a 4-SD-clock delay after every writel while host->clock ≤ 400 kHz;
/// this driver does the same via `emmc_write`. The flag flips to `false` in init
/// step 10 once the bus moves to ~25 MHz, after which the inter-write gap is no
/// longer an issue.
static mut LOW_CLOCK: bool = true;

/// 4 SD-clock cycles at the ~390 kHz identification clock ≈ 10.3 µs, rounded up.
/// Linux uses the same 4-clock delay in drivers/mmc/host/sdhci-iproc.c while
/// host->clock ≤ 400 kHz.
const IDENT_CLOCK_DOMAIN_CROSSING_DELAY_US: u32 = 11;

/// Write one controller register, honouring the Arasan clock-domain-crossing
/// delay while the bus is still at the identification clock.
///
/// # Safety
/// `reg` must address a live EMMC2 register in the device mapping.
#[inline]
unsafe fn emmc_write(reg: *mut u32, value: u32) {
    // SAFETY: the caller guarantees a live device-mapped register.
    unsafe { write_volatile(reg, value) };
    // SAFETY: `LOW_CLOCK` is only touched by this serialized bring-up path.
    if unsafe { LOW_CLOCK } {
        delay_us(IDENT_CLOCK_DOMAIN_CROSSING_DELAY_US);
    }
}

/// Read one controller register.
///
/// # Safety
/// `reg` must address a live EMMC2 register in the device mapping.
#[inline]
unsafe fn emmc_read(reg: *mut u32) -> u32 {
    // SAFETY: the caller guarantees a live device-mapped register.
    unsafe { read_volatile(reg) }
}

/// NUL-terminated form of the frozen `[Debug] ` marker. The assertion below is
/// the single-source guard: if the marker ever changes, this fails to compile
/// rather than silently drifting from the boot-log contract.
const DEBUG_MARK_C: &[u8] = b"[Debug] \0";
const _: () = assert!(
    matches!(DEBUG_MARK_C.split_last(), Some((0, rest)) if rest.len() == tags::DEBUG_MARK.len())
);

/// Open a diagnostic line with the `[Debug] ` marker. Compiled out entirely
/// while `DIAG` is false.
///
/// # Safety
/// `text` must be NUL-terminated and static.
unsafe fn diag_line(text: &'static [u8]) {
    if DIAG {
        // SAFETY: both strings are NUL-terminated statics and the klog sink is
        // allocation-free.
        unsafe {
            utilc::main_output(MU, DEBUG_MARK_C.as_ptr());
            utilc::main_output(MU, text.as_ptr());
        }
    }
}

/// Continue a diagnostic line without re-emitting the marker. Compiled out
/// entirely while `DIAG` is false.
///
/// # Safety
/// `text` must be NUL-terminated and static.
unsafe fn diag(text: &'static [u8]) {
    if DIAG {
        // SAFETY: the caller guarantees a NUL-terminated static byte string.
        unsafe { utilc::main_output(MU, text.as_ptr()) };
    }
}

/// Print one diagnostic hex value. Compiled out entirely while `DIAG` is false.
unsafe fn diag_u64(value: u64) {
    if DIAG {
        // SAFETY: the klog sink is allocation-free and re-entrancy-safe.
        unsafe { utilc::main_output_u64(MU, value) };
    }
}

/// Bring the controller and card up to transfer state and wire the block-device
/// vtable. Returns 0 on success, -1 on any failure — the caller degrades to the
/// initramfs path.
///
/// # Safety
/// The BCM2711 device mapping is installed and kernel bring-up calls this once,
/// before any block I/O.
pub unsafe fn init() -> i32 {
    let r = regs();

    // Diagnostic dump before any controller poke. Proves the MMIO address is
    // right (SLOTISR_VER reads a sane vendor/version, not 0xFFFFFFFF) and
    // records the controller's pre-init state.
    if DIAG {
        // SAFETY: diagnostic reads of live device-mapped registers.
        unsafe {
            diag_line(b"EMMC2 diag SLOTISR_VER=0x\0");
            diag_u64(u64::from(emmc_read(reg_at(0xFC))));
            diag(b" CAPS_LO=0x\0");
            diag_u64(u64::from(emmc_read(reg_at(0x40))));
            diag(b" CAPS_HI=0x\0");
            diag_u64(u64::from(emmc_read(reg_at(0x44))));
            diag(b"\n\0");
            diag_line(b"EMMC2 diag entry ctrl0=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).control0))));
            diag(b" ctrl1=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).control1))));
            diag(b" ctrl2=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).control2))));
            diag(b" status=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).status))));
            diag(b" intr=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).interrupt))));
            diag(b"\n\0");
        }
    }

    // 0. Ensure the SD-card power rail is on. Circle's CardInit calls
    //    PROPTAG_SET_POWER_STATE(SD_CARD, ON|WAIT) before any controller reset
    //    on Pi 4. The Pi 4 boot firmware loaded the kernel from this slot so VDD
    //    is normally already on, but matching Circle defensively rules out a
    //    half-powered state where commands transmit on the wire but the card
    //    can't answer.
    // SAFETY: mailbox calls are serialized by the single-core kernel.
    unsafe { diag_line(b"EMMC2 step 0 sd_power_on\n\0") };
    // SAFETY: as above.
    if !unsafe {
        mbox::set_power_state(
            mailbox::DEVICE_ID_SD_CARD,
            mailbox::POWER_STATE_ON | mailbox::POWER_STATE_WAIT,
        )
    } {
        // SAFETY: diagnostic sink only.
        unsafe { diag_line(b"EMMC2 sd_power_on FAILED\n\0") };
        return -1;
    }
    delay_us(2_000);

    // 0a. Select the 3.3 V SD I/O rail (expander line 4 = 0; per
    //     bcm2711-rpi-4-b.dts VDD_SD_IO_SEL: 0 = 3.3 V, 1 = 1.8 V), matching the
    //     controller's 3.3 V drive — the conventional bring-up assumption. Pi-HW
    //     init has been verified end-to-end from this 3.3 V default; 1.8 V UHS-I
    //     switching stays a future perf concern.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 0a sd_io_3v3\n\0") };
    // SAFETY: mailbox calls are serialized by the single-core kernel.
    if !unsafe { mbox::set_gpio_state(mailbox::EXP_GPIO_SD_1V8, 0) } {
        // SAFETY: diagnostic sink only.
        unsafe { diag_line(b"EMMC2 sd_io_3v3 FAILED\n\0") };
        return -1;
    }
    delay_us(5_000);

    // 1. Software reset of the host controller. SRST_HC alone leaves the CMD/DAT
    //    sub-state machines in limbo — cmdtm writes have no effect on real
    //    hardware after SRST_HC alone. Triple-reset (SRST_HC | SRST_CMD |
    //    SRST_DAT) matches Linux's drivers/mmc/host/sdhci.c
    //    sdhci_reset(host, SDHCI_RESET_ALL).
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 1 SRST_ALL\n\0") };
    // SAFETY: live device-mapped registers throughout the reset sequence.
    unsafe {
        let control1 = addr_of_mut!((*r).control1);
        emmc_write(control1, emmc_read(control1) | CTRL1_SRST_ALL);
        if !busy_wait_clear(control1, CTRL1_SRST_ALL, 100_000) {
            return -1;
        }
    }

    // 1a. Bring the SD bus up before the clock. Circle's Pi 4 EMMC reset path
    //     powers VDD and clears CONTROL2 before configuring SDCLK; SRST_HC zeroes
    //     both. POWER_ON = bit 8, BUS_VOLTAGE = bits 11:9 (0b111 = 3.3 V). Let the
    //     rail settle before the clock is brought up.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 1a bus_power\n\0") };
    // SAFETY: live device-mapped registers.
    unsafe {
        emmc_write(addr_of_mut!((*r).control2), 0);
        emmc_write(addr_of_mut!((*r).control0), (1u32 << 8) | (0b111u32 << 9));
    }
    // SD spec PLSS §6.4.1: ≥1 ms after VDD reaches stable level before first
    // command. Pi 4 firmware can leave BUS_POWER cleared (entry ctrl0=0x00800000
    // has bit 8 = 0), so this write may be the actual VDD power-on edge for the
    // card — be generous to cover both power-cycle (cold rise) and
    // pure-controller-toggle paths.
    delay_us(10_000);

    // 1b. Resolve the EMMC2 base clock from the VideoCore firmware. The SDHCI
    //     divider is derived from this; the CAP register's base-clock field is
    //     unreliable on the BCM2711, so the firmware value is the only sound
    //     source.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 1b base_clock\n\0") };
    // SAFETY: mailbox calls are serialized by the single-core kernel; the
    // statics belong to this serialized bring-up path.
    let base_clock_hz = unsafe { mbox::get_clock_rate(mailbox::CLOCK_ID_EMMC2) };
    // SAFETY: as above.
    unsafe { BASE_CLOCK_HZ = base_clock_hz };
    if base_clock_hz == 0 {
        // SAFETY: diagnostic sink only.
        unsafe { diag_line(b"EMMC2 mailbox clock query FAILED\n\0") };
        return -1;
    }
    if DIAG {
        // SAFETY: diagnostic sink only.
        unsafe {
            diag_line(b"EMMC2 base clock=0x\0");
            diag_u64(u64::from(base_clock_hz));
            diag(b"\n\0");
        }
    }

    // 2. Internal clock + identification-mode divider (~400 kHz). The divisor is
    //    a power of two derived from the firmware base clock (the BCM2711 EMMC2
    //    only accepts power-of-two dividers). The delays around CLK_EN mirror
    //    Circle's reset path — real hardware wants the internal clock to settle
    //    before the card clock is gated on, and again before the first command.
    //    TOUNIT = 0xC matches Circle's Pi 4 data-timeout choice.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 2 CLK_STABLE\n\0") };
    let id_div = sdhci::clock_divisor(base_clock_hz, 400_000);
    // SAFETY: live device-mapped registers.
    unsafe {
        let control1 = addr_of_mut!((*r).control1);
        emmc_write(
            control1,
            CTRL1_CLK_INTLEN | sdhci::control1_clock_bits(id_div) | (0xCu32 << 16),
        );
        if !busy_wait_set(control1, CTRL1_CLK_STABLE, 100_000) {
            return -1;
        }
        delay_us(2_000);
        emmc_write(control1, emmc_read(control1) | CTRL1_CLK_EN);
        delay_us(2_000);
    }

    // 2a. Enable interrupt-status latching. SRST zeroes IRPT_MASK (0x34, the
    //     SDHCI Normal+Error Interrupt Status Enable register); while it reads 0
    //     the INTERRUPT register (0x30) never latches a single event, so the
    //     polled send_cmd loop spins out every command. IRPT_MASK gates 0x30
    //     latching; IRPT_EN (0x38) is the physical-IRQ signal enable and stays
    //     clear — send_cmd is polled and no EMMC line is wired into the GIC. The
    //     explicit IRPT_EN=0 write matches Circle's CardReset (defensive against
    //     firmware that left it non-zero).
    // SAFETY: live device-mapped registers.
    unsafe {
        emmc_write(addr_of_mut!((*r).irpt_en), 0);
        emmc_write(addr_of_mut!((*r).interrupt), 0xFFFF_FFFF);
        emmc_write(addr_of_mut!((*r).irpt_mask), 0xFFFF_FFFF);
    }
    delay_us(2_000);

    if DIAG {
        // SAFETY: diagnostic reads of live device-mapped registers.
        unsafe {
            diag_line(b"EMMC2 pre-CMD0 status=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).status))));
            diag(b" ctrl0=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).control0))));
            diag(b" ctrl1=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).control1))));
            diag(b" ctrl2=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).control2))));
            diag(b" mask=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).irpt_mask))));
            diag(b"\n\0");
        }
    }

    // 3. CMD0 — GO_IDLE_STATE. No response; the card transitions to idle.
    //    Triple-issue with 5 ms gaps. Pi 4 firmware can hand off with the card in
    //    Stand-by or Transfer state (RCA assigned, last block read complete)
    //    rather than the cold-POR Idle state every other bare-metal driver
    //    assumes. A single CMD0 with no inter-command settle is not guaranteed to
    //    traverse the state machine back to Idle when the card was warm-handed-off.
    //    Three sends with 5 ms gaps gives the card-side state machine time to
    //    transition, per SD PLSS §4.4 NCC + post-reset settle.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 3 CMD0 (x3)\n\0") };
    let mut cmd0_try = 0u32;
    while cmd0_try < 3 {
        // SAFETY: the controller is reset and clocked; command issue is serialized.
        if unsafe { send_cmd(sdhci::CMD0_GO_IDLE, 0, BLKSIZECNT_NONE) } < 0 {
            return -1;
        }
        delay_us(5_000);
        cmd0_try += 1;
    }

    if DIAG {
        // SAFETY: diagnostic reads of live device-mapped registers.
        unsafe {
            diag_line(b"EMMC2 post-CMD0 status=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).status))));
            diag(b" intr=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).interrupt))));
            diag(b"\n\0");
        }
    }

    // Extra settle after CMD0 burst, before CMD8 — covers post-state-transition
    // NCC plus internal card-clock domain crossing.
    delay_us(5_000);

    // 4. CMD8 — SEND_IF_COND. Echo the 0xAA check pattern back in R7; mismatch
    //    means pre-v2.0 card or out-of-range voltage rail.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 4 CMD8\n\0") };
    // SAFETY: command issue is serialized on the clocked controller.
    if unsafe {
        send_cmd(
            sdhci::CMD8_SEND_IF_COND,
            sdhci::CMD8_ARG_VHS_27_36_CHECK_AA,
            BLKSIZECNT_NONE,
        )
    } < 0
    {
        // CMD8 timeout = no card present or unreadable card. Fail cleanly; the
        // caller logs `EMMC2 init FAILED` and degrades to the initramfs path.
        return -1;
    }
    // SAFETY: response register of the just-completed command.
    if unsafe { emmc_read(addr_of_mut!((*r).resp0)) } & 0xFF != 0xAA {
        // SAFETY: diagnostic sink only.
        unsafe { diag_line(b"EMMC2 step 4 CMD8 echo mismatch\n\0") };
        return -1;
    }

    // 5. ACMD41 — SD_SEND_OP_COND with HCS. Repeated until bit 31 of OCR (resp0)
    //    is set, indicating card power-up complete. Each ACMD requires a preceding
    //    CMD55 (APP_CMD); failures inside the loop are tolerated because the next
    //    pass re-issues both.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 5 ACMD41\n\0") };
    let mut tries = 0u32;
    while tries < 100 {
        // SAFETY: command issue is serialized on the clocked controller.
        unsafe {
            let _ = send_cmd(sdhci::CMD55_APP_CMD, 0, BLKSIZECNT_NONE);
            let _ = send_cmd(
                sdhci::ACMD41_SD_SEND_OP_COND,
                sdhci::ACMD41_ARG_HCS_AND_VOLT,
                BLKSIZECNT_NONE,
            );
        }
        // SAFETY: response register of the just-completed command.
        if unsafe { emmc_read(addr_of_mut!((*r).resp0)) } & (1u32 << 31) != 0 {
            break;
        }
        delay_us(10_000);
        tries += 1;
    }
    if tries == 100 {
        return -1;
    }

    // 6. CMD2 — ALL_SEND_CID. R2 lands in resp0..resp3; the CID is not consumed
    //    past init, but the card must transition through this state to accept
    //    CMD3.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 6 CMD2\n\0") };
    // SAFETY: command issue is serialized on the clocked controller.
    if unsafe { send_cmd(sdhci::CMD2_ALL_SEND_CID, 0, BLKSIZECNT_NONE) } < 0 {
        return -1;
    }

    // 7. CMD3 — SEND_REL_ADDR. R6: RCA in resp0[31:16]. Subsequent addressed
    //    commands (CMD7, CMD9) use this in arg[31:16].
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 7 CMD3\n\0") };
    // SAFETY: command issue is serialized on the clocked controller.
    if unsafe { send_cmd(sdhci::CMD3_SEND_REL_ADDR, 0, BLKSIZECNT_NONE) } < 0 {
        return -1;
    }
    // SAFETY: response register of the just-completed command; `RCA` belongs to
    // this serialized bring-up path.
    let rca = unsafe { emmc_read(addr_of_mut!((*r).resp0)) } & 0xFFFF_0000;
    // SAFETY: as above.
    unsafe { RCA = rca };

    // 8. CMD9 — SEND_CSD. R2 again; parse_csd_v2 rejects pre-SDHC v1.0 cards
    //    (CSD_STRUCTURE = 0) which this driver does not support.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 8 CMD9\n\0") };
    // SAFETY: command issue is serialized on the clocked controller.
    if unsafe { send_cmd(sdhci::CMD9_SEND_CSD, rca, BLKSIZECNT_NONE) } < 0 {
        return -1;
    }
    // SAFETY: response registers of the just-completed command.
    let response = unsafe {
        [
            emmc_read(addr_of_mut!((*r).resp0)),
            emmc_read(addr_of_mut!((*r).resp1)),
            emmc_read(addr_of_mut!((*r).resp2)),
            emmc_read(addr_of_mut!((*r).resp3)),
        ]
    };
    let Some(csd) = sdhci::parse_csd_v2(response) else {
        // SAFETY: diagnostic sink only.
        unsafe { diag_line(b"EMMC2 step 8 CSD parse failed (v1 card?)\n\0") };
        return -1;
    };
    // SAFETY: `CAPACITY_BLOCKS` belongs to this serialized bring-up path.
    unsafe { CAPACITY_BLOCKS = csd.capacity_blocks };

    // 9. CMD7 — SELECT_CARD. Moves the card into the transfer state so CMD17 /
    //    CMD24 are legal.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 9 CMD7\n\0") };
    // SAFETY: command issue is serialized on the clocked controller.
    if unsafe { send_cmd(sdhci::CMD7_SELECT_CARD, rca, BLKSIZECNT_NONE) } < 0 {
        return -1;
    }

    // 10. Transfer-mode clock (~25 MHz). Divisor derived from the same firmware
    //     base clock as the identification divider. The PIO polled-wait loop
    //     dominates throughput, so default-speed SD (25 MHz) is fine; future perf
    //     can pick high-speed via CAP1. Once the clock crosses ~400 kHz the Arasan
    //     CDC bugette is no longer triggered (the 2-SD-clock window shrinks below
    //     CPU instruction-pair spacing only at the ID clock), so clear `LOW_CLOCK`
    //     here and skip the per-write delay from now on.
    // SAFETY: diagnostic sink only.
    unsafe { diag_line(b"EMMC2 step 10 switch_clk\n\0") };
    let tx_div = sdhci::clock_divisor(base_clock_hz, 25_000_000);
    // SAFETY: live device-mapped registers.
    unsafe {
        let control1 = addr_of_mut!((*r).control1);
        let mut c1 = emmc_read(control1);
        c1 &= !CTRL1_CLK_EN;
        emmc_write(control1, c1);
        c1 &= !0xFFC0u32; // clear SDCLK freq select [15:6]
        c1 |= sdhci::control1_clock_bits(tx_div);
        emmc_write(control1, c1);
        if !busy_wait_set(control1, CTRL1_CLK_STABLE, 100_000) {
            return -1;
        }
        emmc_write(control1, emmc_read(control1) | CTRL1_CLK_EN);
        LOW_CLOCK = false;
    }

    // Wire the BlockDev vtable now the controller is in transfer state. The FAT32
    // backend reads + writes through the shared record; acceptance #7 checks the
    // slot is populated post-init.
    // SAFETY: the vtable is BSS-resident and only written here, before any
    // reader exists.
    unsafe {
        block_dev::set_sd_dev(block_dev::BlockDev {
            read_fn: Some(read_block),
            write_fn: Some(write_block),
        });
    }
    0
}

/// Programmed into BLKSIZECNT for non-data commands. Circle writes BLKSIZECNT
/// before *every* command (m_block_size | (m_blocks_to_transfer << 16); both
/// fields are 0 outside a data transfer); this driver follows defensively — some
/// BCM2711 EMMC2 firmware revisions reportedly hang CMD8 when stale BLKSIZECNT
/// bits leak in from a prior data op.
const BLKSIZECNT_NONE: u32 = 0;
const BLKSIZECNT_512X1: u32 = (1u32 << 16) | 512;

/// Issue one command and poll it to completion. Returns 0 on CMD_DONE, -1 on any
/// error bit or timeout.
///
/// # Safety
/// The controller is reset and clocked; command issue is serialized by the
/// single-core kernel.
unsafe fn send_cmd(cmdtm: u32, arg: u32, blksizecnt: u32) -> i32 {
    let r = regs();
    // SAFETY: live device-mapped registers throughout.
    unsafe {
        if !busy_wait_clear(addr_of_mut!((*r).status), STATUS_CMD_INHIBIT, SPIN_CMD) {
            diag_line(b"send_cmd CMD_INHIBIT stuck\n\0");
            return -1;
        }
        // Clear any stale CMD_DONE / error bits left from a previous command. The
        // Arasan clock-domain-crossing bug applies to *every* write at ID-mode
        // clock, including this one — without the inter-write gap the BLKSIZECNT /
        // ARG1 writes that follow can be silently dropped.
        emmc_write(
            addr_of_mut!((*r).interrupt),
            INTERRUPT_CMD_DONE | INTERRUPT_ERR_MASK,
        );
        emmc_write(addr_of_mut!((*r).blksizecnt), blksizecnt);
        emmc_write(addr_of_mut!((*r).arg1), arg);
        emmc_write(addr_of_mut!((*r).cmdtm), cmdtm);

        let mut spin = 0u32;
        while spin < SPIN_CMD {
            let irpt = emmc_read(addr_of_mut!((*r).interrupt));
            if irpt & INTERRUPT_ERR_MASK != 0 {
                if DIAG {
                    diag_line(b"send_cmd ERR_MASK irpt=0x\0");
                    diag_u64(u64::from(irpt));
                    diag(b" status=0x\0");
                    diag_u64(u64::from(emmc_read(addr_of_mut!((*r).status))));
                    diag(b" resp0=0x\0");
                    diag_u64(u64::from(emmc_read(addr_of_mut!((*r).resp0))));
                    diag(b" resp1=0x\0");
                    diag_u64(u64::from(emmc_read(addr_of_mut!((*r).resp1))));
                    diag(b"\n\0");
                }
                emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_ERR_MASK);
                if DIAG {
                    diag_line(b"send_cmd post-clear intr=0x\0");
                    diag_u64(u64::from(emmc_read(addr_of_mut!((*r).interrupt))));
                    diag(b"\n\0");
                }
                return -1;
            }
            if irpt & INTERRUPT_CMD_DONE != 0 {
                emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_CMD_DONE);
                return 0;
            }
            spin += 1;
        }
        if DIAG {
            diag_line(b"send_cmd CMD_DONE timeout status=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).status))));
            diag(b" irpt=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).interrupt))));
            diag(b"\n\0");
        }
        -1
    }
}

/// Read one 512-byte sector into `buf`. Returns 0 on success, -1 otherwise.
///
/// # Safety
/// `buf` must point to a live, writable 512-byte buffer, and the controller must
/// have completed `init`.
pub extern "C" fn read_block(lba: u32, buf: *mut [u8; 512]) -> i32 {
    let r = regs();
    // SAFETY: live device-mapped registers; `buf` is guaranteed by the caller.
    unsafe {
        if !busy_wait_clear(
            addr_of_mut!((*r).status),
            STATUS_CMD_INHIBIT | STATUS_DAT_INHIBIT,
            SPIN_DATA,
        ) {
            log_io_fail(b"read pre-CMD17 inhibit-clear timeout\0", 0xFFFF_FFFF);
            return -1;
        }
        // BLKSIZE = 512 (low 12 bits), BLKCNT = 1 (bits 16..31).
        if send_cmd(sdhci::CMD17_READ_SINGLE, lba, BLKSIZECNT_512X1) < 0 {
            return -1;
        }

        // SDHCI single-block PIO: READ_RDY fires once when the block buffer has
        // the full 512 bytes ready; the host then drains it word-by-word without
        // re-polling. Per-word polling is wrong — the interrupt only re-fires for
        // the next block (this driver issues one).
        if !busy_wait_set(
            addr_of_mut!((*r).interrupt),
            INTERRUPT_READ_RDY | INTERRUPT_ERR_MASK,
            SPIN_DATA,
        ) {
            log_io_fail(b"read READ_RDY timeout\0", 0xFFFF_FFFF);
            return -1;
        }
        if emmc_read(addr_of_mut!((*r).interrupt)) & INTERRUPT_ERR_MASK != 0 {
            log_io_fail(b"read ERR before READ_RDY\0", 0xFFFF_FFFF);
            emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_ERR_MASK);
            return -1;
        }
        emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_READ_RDY);

        let bytes = buf.cast::<u8>();
        let mut i = 0usize;
        while i < 128 {
            let word = emmc_read(addr_of_mut!((*r).data));
            // SD bus is little-endian; the data port hands back the wire order
            // directly, so a verbatim byte copy preserves layout. The buffer is
            // byte-aligned by type, and the target carries `+strict-align`, so
            // these stores cannot be widened into an unaligned word store.
            let word_bytes = word.to_le_bytes();
            let off = i * 4;
            bytes.add(off).write(word_bytes[0]);
            bytes.add(off + 1).write(word_bytes[1]);
            bytes.add(off + 2).write(word_bytes[2]);
            bytes.add(off + 3).write(word_bytes[3]);
            i += 1;
        }

        if !busy_wait_set(
            addr_of_mut!((*r).interrupt),
            INTERRUPT_DATA_DONE | INTERRUPT_ERR_MASK,
            SPIN_DATA,
        ) {
            log_io_fail(b"read DATA_DONE timeout\0", 0xFFFF_FFFF);
            return -1;
        }
        if emmc_read(addr_of_mut!((*r).interrupt)) & INTERRUPT_ERR_MASK != 0 {
            log_io_fail(b"read ERR before DATA_DONE\0", 0xFFFF_FFFF);
            emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_ERR_MASK);
            return -1;
        }
        emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_DATA_DONE);
    }
    0
}

/// Write one 512-byte sector from `buf`. Returns 0 on success, -1 otherwise.
///
/// # Safety
/// `buf` must point to a live, readable 512-byte buffer, and the controller must
/// have completed `init`.
pub extern "C" fn write_block(lba: u32, buf: *const [u8; 512]) -> i32 {
    let r = regs();
    // SAFETY: live device-mapped registers; `buf` is guaranteed by the caller.
    unsafe {
        if !busy_wait_clear(
            addr_of_mut!((*r).status),
            STATUS_CMD_INHIBIT | STATUS_DAT_INHIBIT,
            SPIN_DATA,
        ) {
            log_io_fail(b"write pre-CMD24 inhibit-clear timeout\0", 0xFFFF_FFFF);
            return -1;
        }
        if send_cmd(sdhci::CMD24_WRITE_SINGLE, lba, BLKSIZECNT_512X1) < 0 {
            return -1;
        }

        // SDHCI single-block PIO: WRITE_RDY fires once when the block buffer is
        // ready to accept 512 bytes; the host then pushes the full block
        // word-by-word without re-polling. Per-word polling is wrong — the
        // interrupt only re-fires for the next block (this driver issues one).
        if !busy_wait_set(
            addr_of_mut!((*r).interrupt),
            INTERRUPT_WRITE_RDY | INTERRUPT_ERR_MASK,
            SPIN_DATA,
        ) {
            log_io_fail(b"write WRITE_RDY timeout\0", 0xFFFF_FFFF);
            return -1;
        }
        if emmc_read(addr_of_mut!((*r).interrupt)) & INTERRUPT_ERR_MASK != 0 {
            log_io_fail(b"write ERR before WRITE_RDY\0", 0xFFFF_FFFF);
            emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_ERR_MASK);
            return -1;
        }
        emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_WRITE_RDY);

        let bytes = buf.cast::<u8>();
        let mut i = 0usize;
        while i < 128 {
            // The buffer is byte-aligned by type and the target carries
            // `+strict-align`, so this gather cannot be widened into an unaligned
            // word load from a caller buffer sitting at an odd address.
            let off = i * 4;
            let word = u32::from_le_bytes([
                bytes.add(off).read(),
                bytes.add(off + 1).read(),
                bytes.add(off + 2).read(),
                bytes.add(off + 3).read(),
            ]);
            write_volatile(addr_of_mut!((*r).data), word);
            i += 1;
        }

        if !busy_wait_set(
            addr_of_mut!((*r).interrupt),
            INTERRUPT_DATA_DONE | INTERRUPT_ERR_MASK,
            SPIN_DATA,
        ) {
            log_io_fail(b"write DATA_DONE timeout\0", 0xFFFF_FFFF);
            return -1;
        }
        if emmc_read(addr_of_mut!((*r).interrupt)) & INTERRUPT_ERR_MASK != 0 {
            log_io_fail(b"write ERR before DATA_DONE\0", 0xFFFF_FFFF);
            emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_ERR_MASK);
            return -1;
        }
        emmc_write(addr_of_mut!((*r).interrupt), INTERRUPT_DATA_DONE);
    }
    0
}

/// Log one wedged block op with the controller state that explains it.
///
/// # Safety
/// `tag` must be NUL-terminated and static; the device mapping must be live.
unsafe fn log_io_fail(tag: &'static [u8], word_idx: u32) {
    if DIAG {
        let r = regs();
        // SAFETY: diagnostic reads of live device-mapped registers; the caller
        // guarantees the terminator.
        unsafe {
            diag_line(b"EMMC2 \0");
            diag(tag);
            if word_idx != 0xFFFF_FFFF {
                diag(b" word=0x\0");
                diag_u64(u64::from(word_idx));
            }
            diag(b" status=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).status))));
            diag(b" intr=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).interrupt))));
            diag(b" resp0=0x\0");
            diag_u64(u64::from(emmc_read(addr_of_mut!((*r).resp0))));
            diag(b"\n\0");
        }
    }
}

/// Spin until every bit in `mask` reads set. Returns false on timeout; callers
/// translate that to a -1 return.
///
/// # Safety
/// `reg` must address a live EMMC2 register in the device mapping.
unsafe fn busy_wait_set(reg: *mut u32, mask: u32, max_spin: u32) -> bool {
    let mut i = 0u32;
    while i < max_spin {
        // SAFETY: the caller guarantees a live device-mapped register.
        if unsafe { read_volatile(reg) } & mask != 0 {
            return true;
        }
        i += 1;
    }
    false
}

/// Spin until every bit in `mask` reads clear. Returns false on timeout; callers
/// translate that to a -1 return.
///
/// # Safety
/// `reg` must address a live EMMC2 register in the device mapping.
unsafe fn busy_wait_clear(reg: *mut u32, mask: u32, max_spin: u32) -> bool {
    let mut i = 0u32;
    while i < max_spin {
        // SAFETY: the caller guarantees a live device-mapped register.
        if unsafe { read_volatile(reg) } & mask == 0 {
            return true;
        }
        i += 1;
    }
    false
}

/// Coarse delay used during ACMD41 polling. The real driver uses the generic
/// timer's udelay; dragging that in at this layer would force a new module
/// dependency for a microsecond pause that is only hit during init. A future
/// perf pass can swap. The 100×us multiplier is a back-of-envelope match for a
/// 1.5 GHz core with the spin body being a single `nop`; QEMU executes faster
/// but the only effect is quicker init, which is fine.
fn delay_us(us: u32) {
    let mut i = u64::from(us) * 100;
    while i > 0 {
        #[cfg(target_arch = "aarch64")]
        // SAFETY: `nop` has no operands, no memory effect, and no flag effect.
        unsafe {
            core::arch::asm!("nop", options(nomem, nostack, preserves_flags));
        }
        #[cfg(not(target_arch = "aarch64"))]
        core::hint::spin_loop();
        i -= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_layout_matches_the_sdhci_register_file() {
        assert_eq!(core::mem::offset_of!(EmmcRegs, arg2), 0x00);
        assert_eq!(core::mem::offset_of!(EmmcRegs, blksizecnt), 0x04);
        assert_eq!(core::mem::offset_of!(EmmcRegs, arg1), 0x08);
        assert_eq!(core::mem::offset_of!(EmmcRegs, cmdtm), 0x0C);
        assert_eq!(core::mem::offset_of!(EmmcRegs, resp0), 0x10);
        assert_eq!(core::mem::offset_of!(EmmcRegs, data), 0x20);
        assert_eq!(core::mem::offset_of!(EmmcRegs, status), 0x24);
        assert_eq!(core::mem::offset_of!(EmmcRegs, control0), 0x28);
        assert_eq!(core::mem::offset_of!(EmmcRegs, control1), 0x2C);
        assert_eq!(core::mem::offset_of!(EmmcRegs, interrupt), 0x30);
        assert_eq!(core::mem::offset_of!(EmmcRegs, irpt_mask), 0x34);
        assert_eq!(core::mem::offset_of!(EmmcRegs, irpt_en), 0x38);
        assert_eq!(core::mem::offset_of!(EmmcRegs, control2), 0x3C);
        assert_eq!(core::mem::size_of::<EmmcRegs>(), 0x40);
    }

    #[test]
    fn emmc2_base_addresses_the_bcm2711_sdhci_slot() {
        assert_eq!(EMMC2_BASE, 0xFFFF_0000_FE34_0000);
        assert_eq!(reg_at(0xFC) as usize, 0xFFFF_0000_FE34_00FC);
    }

    #[test]
    fn non_data_commands_clear_blksizecnt_and_data_commands_ask_for_one_block() {
        assert_eq!(BLKSIZECNT_NONE, 0);
        assert_eq!(BLKSIZECNT_512X1 & 0xFFF, 512);
        assert_eq!(BLKSIZECNT_512X1 >> 16, 1);
    }

    #[test]
    fn reset_mask_covers_all_three_sub_state_machines() {
        assert_eq!(CTRL1_SRST_ALL, (1 << 24) | (1 << 25) | (1 << 26));
    }

    #[test]
    fn error_mask_matches_the_sdhci_error_interrupt_window() {
        // Bits 15..24 — the SDHCI Error Interrupt Status half of register 0x30.
        assert_eq!(INTERRUPT_ERR_MASK, 0x017F_8000);
        assert_eq!(INTERRUPT_ERR_MASK & INTERRUPT_CMD_DONE, 0);
        assert_eq!(INTERRUPT_ERR_MASK & INTERRUPT_DATA_DONE, 0);
        assert_eq!(INTERRUPT_ERR_MASK & INTERRUPT_READ_RDY, 0);
        assert_eq!(INTERRUPT_ERR_MASK & INTERRUPT_WRITE_RDY, 0);
    }

    // Asserts on a compile-time constant on purpose; kept a runnable test for
    // the failure message.
    #[allow(clippy::assertions_on_constants)]
    #[test]
    fn identification_delay_covers_four_sd_clocks_at_the_id_clock() {
        // 4 cycles at ~390 kHz is ~10.3 µs; the constant rounds up.
        assert!(IDENT_CLOCK_DOMAIN_CROSSING_DELAY_US >= 11);
    }
}
