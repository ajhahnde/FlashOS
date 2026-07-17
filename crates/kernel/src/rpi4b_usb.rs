//! BCM2711 DWC2 USB-OTG device (gadget) driver — CDC-ACM console.
//!
//! Brings the Synopsys DWC2 core up as a Full-Speed USB device and enumerates
//! as a CDC-ACM serial function so macOS binds AppleUSBCDCACM and creates a
//! /dev/tty.usbmodem node. Layered bottom-up: core bring-up (MMIO / reset /
//! EP0 / the SET_ADDRESS quirk), the CDC descriptor set + class control
//! requests (SET/GET_LINE_CODING, SET_CONTROL_LINE_STATE) on EP0, then the
//! data path: on SET_CONFIGURATION it hardware-configures the CDC endpoints —
//! EP1 IN (interrupt notify, activated but never queued), EP2 OUT + EP2 IN
//! (bulk) — and partitions a per-EP TX FIFO for each IN endpoint inside the
//! core SPRAM. Bulk-OUT bytes drain from the shared RX FIFO straight into
//! `console::console_push` (the same ring fsh reads). Bulk-IN rides a bounded
//! preempt-guarded TX ring (`cdc_tx` → `service_tx_ring`); backpressure is a
//! brief bounded spin then drop, so the kernel never blocks on a host that
//! stopped reading. The console mux that routes fsh output through `cdc_tx`
//! lives in `sys` (`console_tx`).
//!
//! Design constraints:
//!   * Full-Speed (DCFG.DevSpd = FS) — skips HS chirp + the qualifier descs.
//!   * Polled — `poll` reads GINTSTS from the PID-0 idle loop; no GIC/IRQ.
//!   * Slave/PIO (GAHBCFG.DMAEn = 0) — CPU copies via the FIFO window.
//!   * MMIO at 0xFE980000 is already device-mapped by boot.S, so this needs
//!     no page allocator; all buffers are static (EP0 FS max packet = 64 B).
//!   * Deferred connect — the gadget stays electrically detached until the
//!     PID-0 idle loop services `poll` at µs rate (sustained idle); see the
//!     "Connection manager" section. Attaching any earlier guarantees a
//!     failed enumeration (the boot harness starves the idle loop).
//!
//! QEMU `raspi4b` does NOT emulate the DWC2 *device* path, so this cannot be
//! brought up in emulation. Two CI-safety invariants keep the rpi4b QEMU gate
//! green there: (1) every wait loop is BOUNDED and `init` fails soft with -1
//! (the kernel logs + degrades, like `rpi4b_emmc2::init`); (2) `poll` is a
//! single bounded pass and a no-op until `INITED` is set. A dead MMIO read
//! (GSNPSID == 0 / 0xFFFFFFFF) bails before any bring-up.
//!
//! The driver is debugged from the device-side trace UART — here the
//! Mini-UART (TRACE = MU), the single adapter on the bench. macOS is
//! near-silent on a failed enum, so every GINTSTS event + every SETUP is
//! traced. Trace is event-gated (`poll` prints only when a bit is actually
//! handled) so an idle bus stays silent and the console remains readable.

use crate::console;
use crate::mailbox;
use crate::rpi4b_mailbox as mbox;
use crate::usb_descriptors as usb_desc;
use crate::usb_tx_ring::UsbTxRing;
use crate::utilc;
use core::ptr::{addr_of_mut, read_volatile, write_volatile};

/// Trace sink. MU (interface 0) = Mini-UART, the existing bench adapter.
/// Flip to 1 (PL011/UART4, GPIO8-9) if a second adapter is wired and you
/// want USB trace off the console cable.
const TRACE: i32 = 0;
/// Gates the `[usb]` bring-up dump; flip to `true` to debug USB enumeration.
const TRACE_VERBOSE: bool = false;

/// Per-packet bulk trace (EP2 OUT byte counts, EP2 IN chunk sizes). Off by
/// default so normal operation leaves the MU trace readable; flip on for HW
/// bring-up to watch the data path move bytes.
const TRACE_BULK: bool = false;

// ---------------------------------------------------------------------------
// MMIO base + register access
// ---------------------------------------------------------------------------

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;
const DWC2_BASE: usize = 0xFE98_0000 + LINEAR_MAP_BASE;

#[inline]
fn reg_at(offset: u32) -> *mut u32 {
    (DWC2_BASE + offset as usize) as *mut u32
}

#[inline]
fn reg_read(offset: u32) -> u32 {
    // SAFETY: the DWC2 window is device-mapped by boot.S and every offset here
    // is a 4-byte-aligned register inside it.
    unsafe { read_volatile(reg_at(offset)) }
}

#[inline]
fn reg_write(offset: u32, value: u32) {
    // SAFETY: as `reg_read`; the core tolerates writes to every register the
    // driver touches in the states it touches them.
    unsafe { write_volatile(reg_at(offset), value) };
}

// Stock Synopsys DWC2 register offsets (same layout as TinyUSB `dwc2_regs.h`
// and Linux drivers/usb/dwc2/hw.h). Global core block @ 0x000, device block
// @ 0x800, per-EP IN @ 0x900, per-EP OUT @ 0xB00, FIFO windows @ 0x1000.
const GOTGCTL: u32 = 0x000;
const GAHBCFG: u32 = 0x008;
const GUSBCFG: u32 = 0x00C;
const GRSTCTL: u32 = 0x010;
const GINTSTS: u32 = 0x014;
const GINTMSK: u32 = 0x018;
const GRXSTSP: u32 = 0x020; // RX status read + POP (the SETUP/OUT decode)
const GRXFSIZ: u32 = 0x024;
const GNPTXFSIZ: u32 = 0x028; // == DIEPTXF0 in device mode (EP0 IN FIFO)
const GSNPSID: u32 = 0x040; // core ID — "OT2"/"OT3" signature for the dead-MMIO gate
const GHWCFG3: u32 = 0x04C; // [31:16] = total DFIFO SPRAM depth (words)
const DCFG: u32 = 0x800;
const DCTL: u32 = 0x804;
const DSTS: u32 = 0x808;
const DIEPMSK: u32 = 0x810;
const DOEPMSK: u32 = 0x814;
const DAINTMSK: u32 = 0x81C;
const DIEPCTL0: u32 = 0x900;
const DIEPINT0: u32 = 0x908;
const DIEPTSIZ0: u32 = 0x910;
const DTXFSTS0: u32 = 0x918; // EP0 IN TX-FIFO space available (words)
const DOEPCTL0: u32 = 0xB00;
const DOEPINT0: u32 = 0xB08;
const DOEPTSIZ0: u32 = 0xB10;
const DFIFO0: u32 = 0x1000; // EP0 / non-periodic FIFO push-pop window

// Per-EP IN/OUT register stride is 0x20. EP1 IN = notify, EP2 IN/OUT = bulk.
const DIEPCTL1: u32 = 0x920;
const DIEPCTL2: u32 = 0x940;
const DIEPINT2: u32 = 0x948;
const DIEPTSIZ2: u32 = 0x950;
const DTXFSTS2: u32 = 0x958; // EP2 IN TX-FIFO space available (words)
const DOEPCTL2: u32 = 0xB40;
const DOEPINT2: u32 = 0xB48;
const DOEPTSIZ2: u32 = 0xB50;
// Dedicated IN-EP TX-FIFO size/start registers (words): [31:16]=depth,
// [15:0]=start. DIEPTXF0 is GNPTXFSIZ (EP0 IN); DIEPTXFn @ 0x104 + (n-1)*4.
const DIEPTXF1: u32 = 0x104;
const DIEPTXF2: u32 = 0x108;
// Slave-mode FIFO access windows (0x1000 stride). OUT data is always read
// through window 0 (the shared RX FIFO); each IN endpoint is pushed through
// its own window: EP0 IN → 0x1000, EP2 IN → 0x3000.
const DFIFO2: u32 = 0x3000; // EP2 IN push window

// --- Bit fields (transcribed from stock DWC2; UPPERCASE hex per hygiene). ---
const GAHBCFG_GLBL_INTR_MSK: u32 = 1 << 0; // 0 = no IRQ to GIC (we poll)
const GAHBCFG_DMA_EN: u32 = 1 << 5; // 0 = slave/PIO (locked)
const GAHBCFG_TXF_EMP_LVL: u32 = 1 << 7;

const GUSBCFG_PHYSEL: u32 = 1 << 6; // 1 = dedicated FS serial PHY; 0 = USB2.0 (HS) PHY
const GUSBCFG_FORCE_HST: u32 = 1 << 29;
const GUSBCFG_FORCE_DEV: u32 = 1 << 30;

const GRSTCTL_CSFTRST: u32 = 1 << 0;
const GRSTCTL_RXFFLSH: u32 = 1 << 4;
const GRSTCTL_TXFFLSH: u32 = 1 << 5;
const GRSTCTL_TXFNUM_ALL: u32 = 0x10 << 6; // TxFNum = 0x10 → flush all TX FIFOs
const GRSTCTL_AHBIDLE: u32 = 1 << 31;

const GINTSTS_RXFLVL: u32 = 1 << 4;
const GINTSTS_USBSUSP: u32 = 1 << 11;
const GINTSTS_USBRST: u32 = 1 << 12;
const GINTSTS_ENUMDONE: u32 = 1 << 13;
const GINTSTS_IEPINT: u32 = 1 << 18;
const GINTSTS_OEPINT: u32 = 1 << 19;

// GRXSTSP PktSts field [20:17].
const PKTSTS_OUT_DATA: u32 = 2;
const PKTSTS_SETUP_DATA: u32 = 6;

// DCFG.DevSpd [1:0]. The wired-PHY choice is the biggest BCM2711 unknown:
// 0b01 = FS on the integrated USB-2.0 (HS) PHY (the expected BCM2711 path);
// 0b11 = FS on a dedicated FS serial transceiver. Paired with PHYSEL below.
const DCFG_DEVSPD_FS_HS_PHY: u32 = 0x1;
const DCFG_DEVSPD_FS_DEDICATED: u32 = 0x3;
const DCFG_DEVSPD_MASK: u32 = 0x3;
const DCFG_DEVADDR_MASK: u32 = 0x7F << 4; // DevAddr [10:4]

const DCTL_SFT_DISCON: u32 = 1 << 1; // 1 = D+ pull-up OFF; clear LAST
const DCTL_CGNPINNAK: u32 = 1 << 8;
const DCTL_CGOUTNAK: u32 = 1 << 10;

const GOTGCTL_BVALOEN: u32 = 1 << 6;
const GOTGCTL_BVALOVAL: u32 = 1 << 7;

const DXEPINT_XFERCOMPL: u32 = 1 << 0;
const DOEPINT_SETUP: u32 = 1 << 3;
const DIEPINT_TIMEOUT: u32 = 1 << 3;

const DXEPCTL_CNAK: u32 = 1 << 26;
const DXEPCTL_STALL: u32 = 1 << 21;
const DXEPCTL_EPENA: u32 = 1 << 31;
const DXEPCTL_MPS_MASK: u32 = 0x3; // EP0 MPS is an enum (00=64): NOT a byte count

// Non-control-EP control bits. Unlike EP0, MPS [10:0] is a literal byte count.
const DXEPCTL_USBACTEP: u32 = 1 << 15; // endpoint is active in the current config
const DXEPCTL_SETD0PID: u32 = 1 << 28; // force the data toggle to DATA0 (core then auto-toggles)
const DXEPCTL_EPTYPE_BULK: u32 = 2 << 18; // EPType [19:18]: 10 = bulk
const DXEPCTL_EPTYPE_INTR: u32 = 3 << 18; // EPType [19:18]: 11 = interrupt
const DXEPCTL_TXFNUM_1: u32 = 1 << 22; // TxFNum [25:22] → dedicated TX FIFO #1
const DXEPCTL_TXFNUM_2: u32 = 2 << 22; // TxFNum [25:22] → dedicated TX FIFO #2
const EP_BULK_MPS: u32 = 64; // FS bulk max packet (bytes)
const EP_NOTIFY_MPS: u32 = 16; // CDC interrupt notify max packet (bytes)

const DOEPTSIZ0_SUPCNT_3: u32 = 0x3 << 29; // accept up to 3 back-to-back SETUPs
const DXEPTSIZ_PKTCNT_1: u32 = 1 << 19;
const DXEPTSIZ_PKTCNT_SHIFT: u32 = 19; // EP0 PktCnt is [20:19] (max 3 packets)
const EP0_MPS: u32 = 64; // Full-Speed EP0 max packet (bytes)

/// HW-probe knob: if enumeration never reaches USBRST on hardware, flip this
/// (and the paired DevSpd above) to try the dedicated FS serial PHY path.
const USE_FS_SERIAL_PHY: bool = false;

/// Bounded-wait iteration cap. Each iteration is one MMIO read; 1M reads is
/// trivial on real silicon and on QEMU (where the bit may never set, so the
/// loop must terminate to keep the watchdog from hanging).
const SPIN: u32 = 1_000_000;

// ---------------------------------------------------------------------------
// Static state (no page allocator; FS EP0 max packet = 64 B)
// ---------------------------------------------------------------------------

static mut INITED: bool = false;
static mut ENUMERATED_FLAG: bool = false;
/// Tracks the CDC DTR control line (SET_CONTROL_LINE_STATE wValue bit0). A host
/// asserts DTR when it opens the tty (screen / piconnect attach); the 0→1 edge
/// is our "operator just connected" signal, used to re-emit the login prompt
/// (see `dispatch_setup`). Cleared on bus reset so a re-attach re-fires.
static mut DTR_ASSERTED: bool = false;
static mut CURRENT_CONFIG: u8 = 0;
static mut SETUP_PACKET: [u8; 8] = [0; 8];

/// Byte count of the CDC line-coding structure (USB CDC 1.1 §6.2.13).
const LINE_CODING_LEN: usize = 7;

/// CDC line coding (115200 8N1 default). GET_LINE_CODING returns it;
/// SET_LINE_CODING captures the host's 7-byte OUT data stage into it. Cosmetic
/// over USB but macOS round-trips it on port open.
static mut LINE_CODING: [u8; LINE_CODING_LEN] = usb_desc::LINE_CODING_DEFAULT;
/// A control-OUT write (SET_LINE_CODING) is mid-flight: its 7-byte data stage
/// is arriving on EP0 OUT; the IN ZLP status is sent on the OUT XFRC.
static mut EP0_OUT_PENDING: bool = false;

#[derive(Clone, Copy, PartialEq, Eq)]
enum EnumState {
    Reset,
    DefaultState,
    Addressed,
    Configured,
}
static mut ENUM_STATE: EnumState = EnumState::Reset;

// --- Bulk data path state ---
/// Set on SET_CONFIGURATION(>=1) once EP1/EP2 are hardware-configured; cleared
/// on USBRST / SET_CONFIGURATION(0). `cdc_tx` and the bulk-OUT route gate on it.
static mut DATA_CONFIGURED: bool = false;
/// An EP2 IN (bulk) transfer is in flight: EPENA is set and the host has not yet
/// ACKed (DIEPINT2.XferCompl). `service_tx_ring` must not start a new transfer
/// until this clears, or it would overwrite the in-flight FIFO contents.
static mut EP2_IN_BUSY: bool = false;

/// Bulk-IN TX ring. The bounded byte-ring arithmetic (monotone u64 head/tail,
/// modulo indexing, overflow→false, peek-then-advance) lives in the pure
/// `usb_tx_ring` module so it is host-unit-tested (same discipline as
/// `console` / `pipe`). 512 B absorbs interactive bursts; sustained overflow
/// past the bounded spin drops (policy: never block on the host). Each ring op
/// below is bracketed in `preempt_disable` — the single-core lock between
/// `cdc_tx` (producer) and `service_tx_ring` (consumer).
static mut TX_RING: UsbTxRing = UsbTxRing::new();

/// Raw handle to the TX ring. The ring is a `static mut` with several
/// serialized users, so every access goes through a raw pointer rather than a
/// long-lived reference.
#[inline]
fn tx_ring() -> *mut UsbTxRing {
    addr_of_mut!(TX_RING)
}

/// Backpressure spin bound (per dropped byte). Sized to cover one bulk-IN packet
/// draining at Full-Speed when the host IS reading; a host that stopped reading
/// leaves EP2 NAKing so the spin expires and the byte drops — bounded, never a
/// kernel stall.
const TX_SPIN: u32 = 2_000;

#[cfg(target_os = "none")]
mod seam {
    unsafe extern "C" {
        pub fn preempt_disable();
        pub fn preempt_enable();
    }

    /// Read CNTFRQ_EL0 — the generic-timer frequency the firmware programmed.
    #[inline]
    pub fn read_cntfrq() -> u64 {
        let value: u64;
        // SAFETY: a read-only system-register move with no memory effect.
        unsafe {
            core::arch::asm!("mrs {v}, cntfrq_el0", v = out(reg) value,
                options(nomem, nostack, preserves_flags));
        }
        value
    }

    /// Read CNTPCT_EL0 — the free-running physical counter.
    #[inline]
    pub fn read_cntpct() -> u64 {
        let value: u64;
        // SAFETY: a read-only system-register move with no memory effect.
        unsafe {
            core::arch::asm!("mrs {v}, cntpct_el0", v = out(reg) value,
                options(nomem, nostack, preserves_flags));
        }
        value
    }

    /// Save DAIF, then mask IRQs; the prior DAIF is handed back to
    /// [`irq_restore`]. Save/restore — NOT a blind `irq_enable`:
    /// `on_rx_fifo_level` runs from the idle-loop poll (IRQs on) AND the
    /// pre-enum timer-tick poll (IRQs already masked), so we must never unmask
    /// a mask the caller already held. The `memory` clobber keeps the compiler
    /// from hoisting the ring RMW out of the region (the same full barrier a
    /// `bl irq_disable` call would have implied).
    #[inline]
    pub fn irq_save() -> u64 {
        let daif: u64;
        // SAFETY: reading DAIF and masking IRQs at EL1 is always architecturally
        // legal; the memory clobber pins the critical section.
        unsafe {
            core::arch::asm!("mrs {v}, daif", v = out(reg) daif,
                options(nomem, nostack, preserves_flags));
            core::arch::asm!("msr daifset, #2", options(nostack, preserves_flags));
        }
        daif
    }

    /// Restore a DAIF saved by [`irq_save`].
    #[inline]
    pub fn irq_restore(daif: u64) {
        // SAFETY: the value came from this core's DAIF one critical section ago.
        unsafe {
            core::arch::asm!("msr daif, {v}", v = in(reg) daif,
                options(nostack, preserves_flags));
        }
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    pub unsafe fn preempt_disable() {}
    pub unsafe fn preempt_enable() {}
    pub fn read_cntfrq() -> u64 {
        0
    }
    pub fn read_cntpct() -> u64 {
        0
    }
    pub fn irq_save() -> u64 {
        0
    }
    pub fn irq_restore(_daif: u64) {}
}

// ---------------------------------------------------------------------------
// Timing — accurate delay off the ARM generic-timer counter (self-contained;
// readable from reset, no kernel timer dependency, stays ~real-time on QEMU).
// ---------------------------------------------------------------------------

fn delay_us(us: u64) {
    let freq = seam::read_cntfrq();
    if freq == 0 {
        return; // firmware left CNTFRQ unset — skip rather than spin
    }
    let start = seam::read_cntpct();
    let ticks = (freq * us) / 1_000_000;
    while seam::read_cntpct().wrapping_sub(start) < ticks {}
}

// ---------------------------------------------------------------------------
// Trace helpers (all to TRACE / Mini-UART; main_output_u64 prints 16 hex digits)
// ---------------------------------------------------------------------------

fn trace(text: &'static [u8]) {
    if !TRACE_VERBOSE {
        return;
    }
    // SAFETY: the caller's byte string is a NUL-terminated static.
    unsafe { utilc::main_output(TRACE, text.as_ptr()) };
}

fn trace_hex(text: &'static [u8], value: u64) {
    if !TRACE_VERBOSE {
        return;
    }
    // SAFETY: as `trace`; the sink is the serialized bring-up log.
    unsafe {
        utilc::main_output(TRACE, text.as_ptr());
        utilc::main_output_u64(TRACE, value);
        utilc::main_output(TRACE, b"\n\0".as_ptr());
    }
}

// ---------------------------------------------------------------------------
// Bounded MMIO waits
// ---------------------------------------------------------------------------

fn wait_set(offset: u32, mask: u32) -> bool {
    let mut i: u32 = 0;
    while i < SPIN {
        if reg_read(offset) & mask != 0 {
            return true;
        }
        i += 1;
    }
    false
}

fn wait_clear(offset: u32, mask: u32) -> bool {
    let mut i: u32 = 0;
    while i < SPIN {
        if reg_read(offset) & mask == 0 {
            return true;
        }
        i += 1;
    }
    false
}

fn flush_tx_fifos() {
    reg_write(GRSTCTL, GRSTCTL_TXFNUM_ALL | GRSTCTL_TXFFLSH);
    let _ = wait_clear(GRSTCTL, GRSTCTL_TXFFLSH);
}

fn flush_rx_fifo() {
    reg_write(GRSTCTL, GRSTCTL_RXFFLSH);
    let _ = wait_clear(GRSTCTL, GRSTCTL_RXFFLSH);
}

// ---------------------------------------------------------------------------
// EP0 control plumbing
// ---------------------------------------------------------------------------

/// Arm OUT-EP0 to receive the next SETUP (and the OUT ZLP status of an IN
/// transfer). MANDATORY after every control transfer — forgetting it means
/// the second SETUP (e.g. SET_ADDRESS after GET_DESCRIPTOR) never arrives.
fn arm_out_setup() {
    reg_write(DOEPTSIZ0, DOEPTSIZ0_SUPCNT_3 | DXEPTSIZ_PKTCNT_1 | 8);
    reg_write(DOEPCTL0, reg_read(DOEPCTL0) | DXEPCTL_EPENA | DXEPCTL_CNAK);
}

/// Send an EP0 IN transfer. The CDC config descriptor is 67 B > the 64-B FS
/// EP0 max packet, so this packetizes: PktCnt = ceil(len / 64) (EP0 PktCnt is
/// 2 bits → max 3 packets / 192 B; our largest transfer is the 67-B config).
/// All bytes fit the 128-B EP0 TX FIFO at once, so slave-mode PIO pushes the
/// whole transfer in one shot and the core splits it into max-packet chunks.
/// `len == 0` sends the status-stage ZLP. A short final packet (len not a
/// multiple of 64 — true for every descriptor we serve) terminates the
/// transfer, so no explicit ZLP is needed.
fn ep0_send_data(data: &[u8]) {
    let len = data.len() as u32;
    let pktcnt = if len == 0 { 1 } else { len.div_ceil(EP0_MPS) };
    reg_write(DIEPTSIZ0, (pktcnt << DXEPTSIZ_PKTCNT_SHIFT) | len); // PktCnt, XferSize=len
    reg_write(DIEPCTL0, reg_read(DIEPCTL0) | DXEPCTL_EPENA | DXEPCTL_CNAK);
    let words = len.div_ceil(4);
    if words == 0 {
        return; // ZLP — EPENA alone sends the zero-length packet
    }
    let mut space: u32 = 0;
    let mut i: u32 = 0;
    while i < SPIN {
        // bounded wait for TX-FIFO space
        space = reg_read(DTXFSTS0) & 0xFFFF;
        if space >= words {
            break;
        }
        i += 1;
    }
    if space < words {
        trace(b"[usb] EP0 IN: TX-FIFO space timeout\n\0");
        return;
    }
    push_words(DFIFO0, data, words);
}

/// Pack `data` little-endian into `words` 32-bit pushes through a FIFO window.
/// Bytes past the end of `data` pad with zero — the core only clocks out
/// XferSize bytes.
fn push_words(window: u32, data: &[u8], words: u32) {
    let mut w: u32 = 0;
    while w < words {
        let mut word: u32 = 0;
        let mut b: u32 = 0;
        while b < 4 {
            let index = (w * 4 + b) as usize;
            if index < data.len() {
                word |= u32::from(data[index]) << (b * 8);
            }
            b += 1;
        }
        reg_write(window, word);
        w += 1;
    }
}

fn stall_ep0() {
    reg_write(DIEPCTL0, reg_read(DIEPCTL0) | DXEPCTL_STALL);
    reg_write(DOEPCTL0, reg_read(DOEPCTL0) | DXEPCTL_STALL);
    arm_out_setup();
}

// ---------------------------------------------------------------------------
// Bulk + notify endpoint plumbing
// ---------------------------------------------------------------------------

/// Arm EP2 OUT to receive one bulk packet. PktCnt=1 / XferSize=MPS: the host's
/// next bulk-OUT lands in the shared RX FIFO (drained by `on_rx_fifo_level`),
/// then DOEPINT2.XferCompl fires and `on_out_ep_int` re-arms. One packet per
/// arming keeps the slave-mode loop simple; a console's OUT rate is human
/// typing.
fn arm_ep2_out() {
    reg_write(DOEPTSIZ2, DXEPTSIZ_PKTCNT_1 | EP_BULK_MPS);
    reg_write(DOEPCTL2, reg_read(DOEPCTL2) | DXEPCTL_EPENA | DXEPCTL_CNAK);
}

/// Hardware-configure the CDC data + notify endpoints. Called on
/// SET_CONFIGURATION(>=1); the TX FIFO partitions were laid down in `init`.
///   * EP1 IN  — interrupt notify, MPS 16, TX FIFO #1. Activated for a
///     well-formed config but never queued (CDC SERIAL_STATE is optional), so
///     it simply NAKs the host's interrupt polls.
///   * EP2 IN  — bulk, MPS 64, TX FIFO #2. Driven by `service_tx_ring`.
///   * EP2 OUT — bulk, MPS 64. Armed here; bytes route to `console_push`.
/// SetD0PID starts each toggle at DATA0; the core auto-toggles afterwards.
fn configure_data_endpoints() {
    reg_write(
        DIEPCTL1,
        DXEPCTL_USBACTEP
            | DXEPCTL_EPTYPE_INTR
            | DXEPCTL_TXFNUM_1
            | DXEPCTL_SETD0PID
            | EP_NOTIFY_MPS,
    );
    reg_write(
        DIEPCTL2,
        DXEPCTL_USBACTEP | DXEPCTL_EPTYPE_BULK | DXEPCTL_TXFNUM_2 | DXEPCTL_SETD0PID | EP_BULK_MPS,
    );
    reg_write(
        DOEPCTL2,
        DXEPCTL_USBACTEP | DXEPCTL_EPTYPE_BULK | DXEPCTL_SETD0PID | EP_BULK_MPS,
    );
    // Aggregate EP2 OUT completion into GINTSTS.OEPINT. EP2 IN completion is
    // polled directly off DIEPINT2 in `service_tx_ring` (the per-EP status bit
    // latches independently of DAINTMSK), so it stays out of the mask.
    reg_write(DAINTMSK, reg_read(DAINTMSK) | (1 << 18));
    // SAFETY: single-core driver state, mutated only from the serialized poll /
    // control paths.
    unsafe {
        EP2_IN_BUSY = false;
        DATA_CONFIGURED = true;
    }
    arm_ep2_out();
    trace(b"[usb] data EPs configured (EP1 notify, EP2 bulk in/out)\n\0");
}

/// SET_CONFIGURATION(0): tear the data path back down to the addressed state.
fn deconfigure_data_endpoints() {
    reg_write(DAINTMSK, reg_read(DAINTMSK) & !(1u32 << 18));
    // SAFETY: as `configure_data_endpoints`; the ring has no other live borrow.
    unsafe {
        DATA_CONFIGURED = false;
        EP2_IN_BUSY = false;
        (*tx_ring()).clear();
    }
}

// ---------------------------------------------------------------------------
// SETUP decode + standard-request dispatch
// ---------------------------------------------------------------------------

fn dispatch_setup() {
    // SAFETY: `SETUP_PACKET` was filled by the serialized RX-FIFO drain; the
    // trace sink is the serialized bring-up log.
    let setup = usb_desc::decode_setup(unsafe { SETUP_PACKET });
    unsafe {
        utilc::main_output(TRACE, b"[usb] SETUP bmRT=\0".as_ptr());
        utilc::main_output_u64(TRACE, u64::from(setup.bm_request_type));
        utilc::main_output(TRACE, b" bReq=\0".as_ptr());
        utilc::main_output_u64(TRACE, u64::from(setup.request));
        utilc::main_output(TRACE, b" wVal=\0".as_ptr());
        utilc::main_output_u64(TRACE, u64::from(setup.value));
        utilc::main_output(TRACE, b" wLen=\0".as_ptr());
        utilc::main_output_u64(TRACE, u64::from(setup.length));
        utilc::main_output(TRACE, b"\n\0".as_ptr());
    }

    match setup.request {
        usb_desc::REQ_GET_DESCRIPTOR => {
            if let Some(descriptor) =
                usb_desc::get_descriptor(setup.descriptor_type(), setup.descriptor_index())
            {
                let n = core::cmp::min(descriptor.len(), setup.length as usize);
                ep0_send_data(&descriptor[..n]);
            } else {
                trace(b"[usb] GET_DESCRIPTOR unknown -> STALL\n\0");
                stall_ep0();
            }
        }
        usb_desc::REQ_SET_ADDRESS => {
            // DWC2 quirk: program DCFG.DevAddr NOW (after decode, before the
            // status-stage ZLP) — the core latches it at status completion.
            let address = setup.address();
            let mut dcfg = reg_read(DCFG);
            dcfg &= !DCFG_DEVADDR_MASK;
            dcfg |= u32::from(address) << 4;
            reg_write(DCFG, dcfg);
            ep0_send_data(&[]); // ZLP status
                                // SAFETY: serialized control path.
            unsafe { ENUM_STATE = EnumState::Addressed };
            trace_hex(b"[usb] SET_ADDRESS=\0", u64::from(address));
        }
        usb_desc::REQ_SET_CONFIGURATION => {
            let config = setup.value as u8;
            // SAFETY: serialized control path.
            unsafe { CURRENT_CONFIG = config };
            // Bring the bulk + notify endpoints up (or tear them down on
            // config 0) before acking, so the host can stream immediately.
            if config >= 1 {
                configure_data_endpoints();
            } else {
                deconfigure_data_endpoints();
            }
            ep0_send_data(&[]); // ZLP status
                                // SAFETY: serialized control path.
            unsafe {
                ENUM_STATE = EnumState::Configured;
                ENUMERATED_FLAG = config >= 1;
            }
            trace(b"[usb] SET_CONFIGURATION -> enumerated\n\0");
        }
        usb_desc::REQ_GET_CONFIGURATION => {
            // SAFETY: serialized control path.
            ep0_send_data(&[unsafe { CURRENT_CONFIG }]);
        }
        usb_desc::REQ_GET_STATUS => {
            ep0_send_data(&[0x00, 0x00]);
        }
        usb_desc::REQ_SET_FEATURE | usb_desc::REQ_CLEAR_FEATURE => {
            ep0_send_data(&[]); // ack, no-op
        }
        // --- CDC-ACM class requests (macOS sends these on tty open) ---
        usb_desc::REQ_GET_LINE_CODING => {
            // SAFETY: serialized control path; the copy is read-only.
            let line_coding = unsafe { LINE_CODING };
            ep0_send_data(&line_coding); // 7-byte line coding (control read)
        }
        usb_desc::REQ_SET_LINE_CODING => {
            // H2D with a 7-byte data stage. Defer the IN ZLP status to the OUT
            // XFRC (`on_out_ep_int`); `arm_out_setup` below receives the line
            // coding.
            // SAFETY: serialized control path.
            unsafe { EP0_OUT_PENDING = true };
        }
        usb_desc::REQ_SET_CONTROL_LINE_STATE => {
            // wValue bit0 = DTR. The host raises it when a terminal opens the
            // tty. The boot's first `login:` prompt is emitted before any
            // terminal is attached, so it never reaches the operator; on the
            // DTR rising edge we push one newline into the console RX ring so
            // the waiting login (or a running shell) re-emits a fresh prompt —
            // the operator sees `login:` the instant they connect instead of
            // typing the username blind. Rising-edge only, so a host that
            // re-asserts DTR cannot spam prompts. `console_push` here is the
            // same RX-ring entry the bulk-OUT data path uses below, same
            // context.
            let dtr = setup.value & 0x0001 != 0;
            // SAFETY: serialized control path; `console_push` is the ring's
            // producer entry and runs on this single core.
            unsafe {
                if dtr && !DTR_ASSERTED {
                    console::console_push(b'\n');
                }
                DTR_ASSERTED = dtr;
            }
            ep0_send_data(&[]); // wLength=0 → ZLP status
        }
        usb_desc::REQ_SEND_BREAK => {
            ep0_send_data(&[]); // wLength=0 → ZLP status (break ignored)
        }
        _ => {
            trace(b"[usb] unhandled bReq -> STALL\n\0");
            stall_ep0();
        }
    }
    arm_out_setup(); // ready for the OUT status / the data stage / the next SETUP
}

// ---------------------------------------------------------------------------
// GINTSTS event handlers
// ---------------------------------------------------------------------------

fn on_usb_reset() {
    reg_write(DCTL, reg_read(DCTL) | DCTL_CGNPINNAK | DCTL_CGOUTNAK);
    flush_tx_fifos();
    flush_rx_fifo();
    let mut dcfg = reg_read(DCFG);
    dcfg &= !DCFG_DEVADDR_MASK; // reset always returns to address 0
    reg_write(DCFG, dcfg);
    arm_out_setup();
    // SAFETY: single-core driver state, serialized with the poll path.
    unsafe {
        ENUM_STATE = EnumState::Reset;
        ENUMERATED_FLAG = false;
        DTR_ASSERTED = false; // re-attach after reset must re-fire the prompt nudge
                              // A reset voids any in-flight bulk transfer and the host session;
                              // drop the configured state + buffered TX so re-enumeration starts clean
                              // (the TX FIFOs were just flushed above).
        DATA_CONFIGURED = false;
        EP2_IN_BUSY = false;
        (*tx_ring()).clear();
    }
    trace(b"[usb] USBRST: addr=0, EP0 re-armed\n\0");
}

fn on_enum_done() {
    let speed = (reg_read(DSTS) >> 1) & 0x3;
    // EP0 max packet = 64 (FS) → MPS[1:0] = 00 on both control EPs.
    reg_write(DIEPCTL0, reg_read(DIEPCTL0) & !DXEPCTL_MPS_MASK);
    reg_write(DOEPCTL0, reg_read(DOEPCTL0) & !DXEPCTL_MPS_MASK);
    // SAFETY: serialized poll path.
    unsafe { ENUM_STATE = EnumState::DefaultState };
    trace_hex(b"[usb] ENUMDONE speed=\0", u64::from(speed));
}

/// RX FIFO non-empty: pop GRXSTSP ONCE and drain its data words. Every packet
/// MUST be fully drained from DFIFO0 (even discarded ones) or the FIFO never
/// empties and RXFLVL stays asserted forever. IRQs are masked across the whole
/// drain (`irq_save`/`irq_restore`): the EP2 `console_push` below shares the
/// console RX ring with the AUX mini-UART RX IRQ handler (`rpi4b_irq`), so a
/// nested `console_push` would race rx_head and drop/duplicate a byte. The
/// window is one GRXSTSP packet — bounded and short.
fn on_rx_fifo_level() {
    let daif = seam::irq_save();
    let status = reg_read(GRXSTSP);
    let epnum = status & 0xF;
    let pktsts = (status >> 17) & 0xF;
    let bcnt = (status >> 4) & 0x7FF;
    let words = bcnt.div_ceil(4);
    match pktsts {
        PKTSTS_SETUP_DATA => {
            let mut captured: u32 = 0;
            let mut i: u32 = 0;
            while i < words {
                let word = reg_read(DFIFO0);
                let mut b: u32 = 0;
                while b < 4 {
                    if captured < 8 {
                        // SAFETY: serialized drain; `captured` is bounds-checked.
                        unsafe {
                            addr_of_mut!(SETUP_PACKET)
                                .cast::<u8>()
                                .add(captured as usize)
                                .write((word >> (b * 8)) as u8);
                        }
                        captured += 1;
                    }
                    b += 1;
                }
                i += 1;
            }
        }
        PKTSTS_OUT_DATA => {
            // Drain every word (or RXFLVL stays asserted). EP2 = CDC bulk OUT →
            // push each real byte into the console RX ring (the same ring fsh
            // reads). EP0 = a pending control-OUT write (SET_LINE_CODING) → keep
            // the first 7 bytes as the line coding.
            let mut captured: u32 = 0;
            let mut i: u32 = 0;
            while i < words {
                let word = reg_read(DFIFO0);
                let mut b: u32 = 0;
                while b < 4 {
                    let byte = (word >> (b * 8)) as u8;
                    if captured < bcnt {
                        // SAFETY: serialized drain with IRQs masked, so the
                        // console ring has no competing producer.
                        unsafe {
                            if epnum == 2 {
                                console::console_push(byte);
                            } else if EP0_OUT_PENDING && (captured as usize) < LINE_CODING_LEN {
                                addr_of_mut!(LINE_CODING)
                                    .cast::<u8>()
                                    .add(captured as usize)
                                    .write(byte);
                            }
                        }
                    }
                    captured += 1;
                    b += 1;
                }
                i += 1;
            }
            if TRACE_BULK && epnum == 2 {
                trace_hex(b"[usb] OUT2 bytes=\0", u64::from(bcnt));
            }
        }
        // SETUP_COMP / OUT_COMP / GOUT_NAK carry no data words
        _ => {}
    }
    seam::irq_restore(daif);
}

fn on_out_ep_int() {
    let doepint = reg_read(DOEPINT0);
    if doepint & DOEPINT_SETUP != 0 {
        reg_write(DOEPINT0, DOEPINT_SETUP); // write-1-clear
        dispatch_setup(); // SETUP-complete is the decode trigger (SETUP_PACKET already captured)
    }
    if doepint & DXEPINT_XFERCOMPL != 0 {
        reg_write(DOEPINT0, DXEPINT_XFERCOMPL);
        // SAFETY: serialized poll path.
        if unsafe { EP0_OUT_PENDING } {
            // SET_LINE_CODING data stage done → send the IN ZLP status that
            // finishes the control-OUT write.
            // SAFETY: as above.
            unsafe { EP0_OUT_PENDING = false };
            ep0_send_data(&[]);
            trace(b"[usb] SET_LINE_CODING\n\0");
        }
        arm_out_setup(); // OUT status / data complete → re-arm for the next SETUP
    }

    // EP2 bulk OUT transfer complete (data already drained by `on_rx_fifo_level`)
    // → re-arm for the next packet.
    // SAFETY: serialized poll path.
    if unsafe { DATA_CONFIGURED } {
        let doepint2 = reg_read(DOEPINT2);
        if doepint2 & DXEPINT_XFERCOMPL != 0 {
            reg_write(DOEPINT2, DXEPINT_XFERCOMPL);
            arm_ep2_out();
        }
    }
}

fn on_in_ep_int() {
    let diepint = reg_read(DIEPINT0);
    if diepint & DXEPINT_XFERCOMPL != 0 {
        reg_write(DIEPINT0, DXEPINT_XFERCOMPL);
    }
    if diepint & DIEPINT_TIMEOUT != 0 {
        reg_write(DIEPINT0, DIEPINT_TIMEOUT);
    }
}

// ---------------------------------------------------------------------------
// Bulk-IN TX path (EP2)
// ---------------------------------------------------------------------------

/// Push pending TX-ring bytes onto EP2 bulk IN, one max-packet (64 B) chunk per
/// call. Self-contained: it retires a finished prior transfer by polling
/// DIEPINT2.XferCompl directly (the per-EP status bit latches independent of
/// DAINTMSK), so it makes progress whether driven from the poll loop (idle) or
/// opportunistically from `cdc_tx` (a producer). `preempt_disable` makes the
/// whole body the consumer critical section — mutually exclusive on this single
/// core with `cdc_tx`'s enqueue.
fn service_tx_ring() {
    // SAFETY: single-core driver state; the whole body below is the serialized
    // consumer critical section.
    unsafe {
        if !DATA_CONFIGURED {
            return;
        }
        seam::preempt_disable();
        // Retire a completed transfer so the next chunk can launch.
        if EP2_IN_BUSY && reg_read(DIEPINT2) & DXEPINT_XFERCOMPL != 0 {
            reg_write(DIEPINT2, DXEPINT_XFERCOMPL);
            EP2_IN_BUSY = false;
        }
        if !EP2_IN_BUSY {
            // Peek one max-packet chunk WITHOUT consuming it — advance only once
            // the TX FIFO has actually taken the bytes (peek is read-only, so a
            // FIFO-full bail leaves the chunk queued for the next pass).
            let mut chunk_buf = [0u8; EP_BULK_MPS as usize];
            let chunk = (*tx_ring()).peek(&mut chunk_buf) as u32;
            if chunk > 0 {
                let words = chunk.div_ceil(4);
                // Only launch if the EP2 TX FIFO can take the whole chunk now.
                if reg_read(DTXFSTS2) & 0xFFFF >= words {
                    reg_write(DIEPTSIZ2, DXEPTSIZ_PKTCNT_1 | chunk); // PktCnt=1, XferSize=chunk
                    reg_write(DIEPCTL2, reg_read(DIEPCTL2) | DXEPCTL_EPENA | DXEPCTL_CNAK);
                    push_words(DFIFO2, &chunk_buf[..chunk as usize], words);
                    (*tx_ring()).advance(u64::from(chunk));
                    EP2_IN_BUSY = true;
                    if TRACE_BULK {
                        trace_hex(b"[usb] IN2 chunk=\0", u64::from(chunk));
                    }
                }
            }
        }
        seam::preempt_enable();
    }
}

/// Push one byte into the TX ring with the bounded spin-then-drop backpressure
/// policy: when the ring is full, spin briefly draining the hardware to make
/// room, then drop — the kernel must never block on a host that stopped
/// reading.
fn tx_push_byte(byte: u8) {
    let mut tries: u32 = 0;
    loop {
        // SAFETY: the ring op is bracketed by the single-core preempt lock.
        let ok = unsafe {
            seam::preempt_disable();
            let ok = (*tx_ring()).push(byte);
            seam::preempt_enable();
            ok
        };
        if ok {
            return;
        }
        service_tx_ring(); // ring full → drain a chunk to the FIFO, then retry
        tries += 1;
        if tries >= TX_SPIN {
            return; // host not draining → drop this byte
        }
    }
}

/// Queue console bytes for the host over EP2 bulk IN. Called by the console mux
/// (`sys::console_tx`). `DATA_CONFIGURED` gates it (before enumeration the
/// caller falls back to the UART).
///
/// # Safety
/// `data` is a live, readable byte slice; the driver's single-core serialization
/// rules apply.
pub unsafe fn cdc_tx(data: &[u8]) {
    // SAFETY: serialized producer state.
    if !unsafe { DATA_CONFIGURED } {
        return;
    }
    for &byte in data {
        // Terminals need CRLF; the kernel writes LF-only. Mirror the
        // Mini-UART driver's newline translation (`rpi4b_uart` does the same) so
        // both console transports render identically.
        if byte == b'\n' {
            tx_push_byte(b'\r');
        }
        tx_push_byte(byte);
    }
    service_tx_ring(); // kick: push what we just queued without waiting for idle
}

// ---------------------------------------------------------------------------
// Connection manager — when to be electrically visible
//
// A USB bus reset hardware-disarms EP0 OUT (DOEPTSIZ0.SUPCNT / DOEPCTL0.EPENA
// do not survive USBRST — Linux dwc2 and TinyUSB re-arm on every reset for
// exactly this reason). The host sends its first SETUP ~20 ms after the reset
// ends, so a SETUP is only ACKed if software re-arms EP0 inside that window.
// The PID-0 idle loop (µs-rate polls) can; the 1 Hz timer-tick backstop
// (rpi4b_irq) never can. During the boot harness the idle loop is starved,
// so every enumeration attempt the host makes in that window is doomed — and
// macOS permanently disables the port after ~4 failed attempts (~20 s),
// recoverable only by a fresh D+ attach event. Asserting the pull-up inside
// `init` therefore guarantees a dead console (HW-diagnosed 2026-06-01:
// USBRST/ENUMDONE pairs processed, zero SETUPs ever seen).
//
// Policy: stay detached (DCTL.SftDiscon = 1) until `poll` has been arriving
// at idle-loop rate for a sustained window — only then assert the pull-up.
// If the host then fails to enumerate (it gave up before we attached, or the
// system went busy mid-enumeration), pulse a detach long enough for the host
// to register it and re-attach: electrically identical to a physical replug,
// which clears macOS's port-disable state. All timing is wall-clock off
// CNTPCT (the same clock `delay_us` uses), never iteration counts.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum ConnState {
    Detached,
    Attaching,
    Attached,
    Pulsing,
}
static mut CONN_STATE: ConnState = ConnState::Detached;
static mut LAST_POLL_TS: u64 = 0; // CNTPCT at the previous poll — the gap detector
static mut IDLE_STREAK_TS: u64 = 0; // CNTPCT when the current gap-free streak began
static mut CONN_STATE_TS: u64 = 0; // CNTPCT when CONN_STATE last changed

/// A poll-to-poll gap above this means the idle loop does NOT own the CPU
/// (boot harness / long user command): EP0 re-arm latency would exceed the
/// host's SETUP window, so being attached is pointless.
const MAX_POLL_GAP_MS: u64 = 10;
/// Gap-free polling for this long ⇒ sustained idle ⇒ safe to become visible.
const CONNECT_IDLE_MS: u64 = 2_000;
/// Attached but not enumerated for this long ⇒ the host is not talking to us
/// (it gave up before we attached, or went away) ⇒ force a fresh attach.
const ENUM_TIMEOUT_MS: u64 = 10_000;
/// D+ released for this long during the re-attach pulse. Must clear the host's
/// connect debounce (~100 ms, USB 2.0 §7.1.7.3) with a wide margin.
const DETACH_PULSE_MS: u64 = 1_000;

#[inline]
fn ms_to_ticks(freq: u64, ms: u64) -> u64 {
    (freq * ms) / 1000
}

fn service_connection() {
    let freq = seam::read_cntfrq();
    if freq == 0 {
        return; // no counter clock → stay detached (bring-up is dead anyway)
    }
    let now = seam::read_cntpct();
    // SAFETY: single-core state, mutated only from inside the `IN_POLL` guard.
    unsafe {
        if now.wrapping_sub(LAST_POLL_TS) > ms_to_ticks(freq, MAX_POLL_GAP_MS) {
            IDLE_STREAK_TS = now; // gap → restart the sustained-idle streak
        }
        LAST_POLL_TS = now;
        match CONN_STATE {
            ConnState::Detached => {
                if now.wrapping_sub(IDLE_STREAK_TS) > ms_to_ticks(freq, CONNECT_IDLE_MS) {
                    reg_write(DCTL, reg_read(DCTL) & !DCTL_SFT_DISCON);
                    CONN_STATE = ConnState::Attaching;
                    CONN_STATE_TS = now;
                    // Connection-state traces kept for bring-up but commented out:
                    // with no host attached, the attach/timeout/pulse cycle below
                    // repeats forever and every transition would land on the fsh
                    // console (same MU). Uncomment all three to debug enumeration.
                    // trace(b"[usb] soft-connect (pull-up on)\n\0");
                }
            }
            ConnState::Attaching => {
                if ENUMERATED_FLAG {
                    CONN_STATE = ConnState::Attached;
                    CONN_STATE_TS = now;
                } else if now.wrapping_sub(CONN_STATE_TS) > ms_to_ticks(freq, ENUM_TIMEOUT_MS) {
                    reg_write(DCTL, reg_read(DCTL) | DCTL_SFT_DISCON);
                    CONN_STATE = ConnState::Pulsing;
                    CONN_STATE_TS = now;
                    // trace(b"[usb] no enumeration -> detach pulse\n\0");
                }
            }
            ConnState::Attached => {
                // `on_usb_reset` cleared ENUMERATED_FLAG → the host is
                // re-enumerating (host-side replug / port reset). Give it the
                // standard window; if it goes silent instead, Attaching times
                // out into a pulse.
                if !ENUMERATED_FLAG {
                    CONN_STATE = ConnState::Attaching;
                    CONN_STATE_TS = now;
                }
            }
            ConnState::Pulsing => {
                if now.wrapping_sub(CONN_STATE_TS) > ms_to_ticks(freq, DETACH_PULSE_MS) {
                    reg_write(DCTL, reg_read(DCTL) & !DCTL_SFT_DISCON);
                    CONN_STATE = ConnState::Attaching;
                    CONN_STATE_TS = now;
                    // trace(b"[usb] re-attach (pull-up on)\n\0");
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

/// Re-entrancy guard: `poll` is reachable from BOTH the PID-0 idle loop
/// (kernel bring-up root) and — until enumeration completes — the timer IRQ
/// (`rpi4b_irq`, the 1 Hz service backstop). On a single core the IRQ can fire
/// mid-poll; the guard turns the nested call into a no-op so the GRXSTSP/FIFO
/// read sequences never interleave.
static mut IN_POLL: bool = false;

/// One GINTSTS service pass; driven from the PID-0 idle loop and, until the
/// gadget enumerates, from the timer tick (`rpi4b_irq`). No-op until a
/// successful `init`. Single bounded pass — no internal loop — so it can never
/// hang the QEMU watchdog. Event-gated trace (idle = silent).
///
/// # Safety
/// The BCM2711 device mapping is installed; runs on the single kernel core.
pub unsafe fn poll() {
    // SAFETY: single-core driver state; the guard below serializes the nested
    // timer-IRQ entry against the idle-loop caller.
    unsafe {
        if !INITED {
            return;
        }
        if IN_POLL {
            return;
        }
        IN_POLL = true;
    }
    // Connection management first, INSIDE the IN_POLL guard: nested timer-IRQ
    // calls must neither pollute the idle-gap measurement nor race the state
    // machine.
    service_connection();
    let pending = reg_read(GINTSTS);
    if pending & GINTSTS_USBRST != 0 {
        on_usb_reset();
        reg_write(GINTSTS, GINTSTS_USBRST);
    }
    if pending & GINTSTS_ENUMDONE != 0 {
        on_enum_done();
        reg_write(GINTSTS, GINTSTS_ENUMDONE);
    }
    if pending & GINTSTS_RXFLVL != 0 {
        on_rx_fifo_level(); // self-clears via GRXSTSP
    }
    if pending & GINTSTS_OEPINT != 0 {
        on_out_ep_int();
    }
    if pending & GINTSTS_IEPINT != 0 {
        on_in_ep_int();
    }
    service_tx_ring(); // drain queued bulk-IN bytes (no-op until DATA_CONFIGURED)
                       // SAFETY: as above; the guard is released on the single exit path.
    unsafe { IN_POLL = false };
}

/// Whether the gadget is enumerated and the CDC data path is live.
///
/// # Safety
/// Runs on the single kernel core.
pub unsafe fn enumerated() -> bool {
    // SAFETY: single-core driver state.
    unsafe { ENUMERATED_FLAG }
}

/// Bring the OTG core up as a polled Full-Speed device. Returns 0 on success,
/// -1 on any bounded-wait timeout / absent core (the kernel logs + degrades).
///
/// # Safety
/// The BCM2711 device mapping is installed and bring-up calls this once.
pub unsafe fn init() -> i32 {
    // 1. Power the USB HCD domain (defensive; firmware usually pre-powers).
    // SAFETY: the serialized bring-up path owns the mailbox transaction.
    let _ = unsafe {
        mbox::set_power_state(
            mailbox::DEVICE_ID_USB_HCD,
            mailbox::POWER_STATE_ON | mailbox::POWER_STATE_WAIT,
        )
    };
    delay_us(2_000);

    // 0. Diagnostic dump + dead-MMIO gate. A live DWC2 core answers GSNPSID
    //    with an "OT" signature; QEMU (no device path) reads 0 / 0xFFFFFFFF.
    let snpsid = reg_read(GSNPSID);
    trace_hex(b"[usb] GSNPSID=\0", u64::from(snpsid));
    trace_hex(b"[usb] GHWCFG3=\0", u64::from(reg_read(GHWCFG3)));
    if snpsid == 0 || snpsid == 0xFFFF_FFFF {
        trace(b"[usb] no DWC2 core (dead MMIO) -> skip\n\0");
        return -1;
    }

    // 2. Wait for AHB idle, then 3. core soft-reset.
    if !wait_set(GRSTCTL, GRSTCTL_AHBIDLE) {
        trace(b"[usb] AHBIDLE timeout\n\0");
        return -1;
    }
    reg_write(GRSTCTL, reg_read(GRSTCTL) | GRSTCTL_CSFTRST);
    if !wait_clear(GRSTCTL, GRSTCTL_CSFTRST) || !wait_set(GRSTCTL, GRSTCTL_AHBIDLE) {
        trace(b"[usb] CSFTRST timeout\n\0");
        return -1;
    }
    trace(b"[usb] core soft-reset done\n\0");

    // 3a. Stay electrically detached (D+ released) through the rest of
    //     bring-up AND the rest of OS boot — the connection manager
    //     (`service_connection`) asserts the pull-up only once the idle loop
    //     demonstrably owns the CPU. Explicit write because the CSFTRST
    //     reset value of SftDiscon differs across core versions.
    reg_write(DCTL, reg_read(DCTL) | DCTL_SFT_DISCON);

    // 4. PHY / mode select: force device mode, clear host mode, pick PHY.
    let mut gusbcfg = reg_read(GUSBCFG);
    gusbcfg &= !GUSBCFG_FORCE_HST;
    gusbcfg |= GUSBCFG_FORCE_DEV;
    if USE_FS_SERIAL_PHY {
        gusbcfg |= GUSBCFG_PHYSEL;
    } else {
        gusbcfg &= !GUSBCFG_PHYSEL;
    }
    reg_write(GUSBCFG, gusbcfg);
    trace_hex(b"[usb] GUSBCFG=\0", u64::from(gusbcfg));

    // 5. ~25 ms settle after ForceDevMode (DWC2 programming-guide requirement;
    //    skipping it silently wedges bring-up).
    delay_us(25_000);
    trace(b"[usb] post-forcedev settle\n\0");

    // 6. Slave/PIO + polled: DMAEn=0, GlblIntrMsk=0 (no IRQ to the GIC).
    reg_write(
        GAHBCFG,
        (reg_read(GAHBCFG) & !GAHBCFG_DMA_EN & !GAHBCFG_GLBL_INTR_MSK) | GAHBCFG_TXF_EMP_LVL,
    );

    // 7. Full-Speed.
    let mut dcfg = reg_read(DCFG);
    dcfg &= !DCFG_DEVSPD_MASK;
    dcfg |= if USE_FS_SERIAL_PHY {
        DCFG_DEVSPD_FS_DEDICATED
    } else {
        DCFG_DEVSPD_FS_HS_PHY
    };
    dcfg &= !DCFG_DEVADDR_MASK;
    reg_write(DCFG, dcfg);
    trace_hex(b"[usb] DCFG=\0", u64::from(dcfg));

    // 8. FIFO partition (words), all inside the core SPRAM (GHWCFG3[31:16]):
    //      RX (shared OUT)      64 @ 0
    //      EP0 IN  (GNPTXFSIZ)  32 @ 64
    //      EP1 IN  (DIEPTXF1)   16 @ 96    (CDC notify)
    //      EP2 IN  (DIEPTXF2)   64 @ 112   (CDC bulk)
    //    Write GRXFSIZ before the TX partitions. BCM2711 SPRAM is 4080 words,
    //    so 176 words used leaves vast headroom. The EP1/EP2 partitions are
    //    laid down here (static) so `configure_data_endpoints` only flips
    //    DIEPCTL.
    let spram = reg_read(GHWCFG3) >> 16;
    let rxfsiz: u32 = 64;
    let nptx_depth: u32 = 32;
    let ep1_start: u32 = rxfsiz + nptx_depth; // 96
    let ep1_depth: u32 = 16;
    let ep2_start: u32 = ep1_start + ep1_depth; // 112
    let ep2_depth: u32 = 64;
    if spram != 0 && (ep2_start + ep2_depth) > spram {
        trace(b"[usb] FIFO partition > SPRAM\n\0");
        return -1;
    }
    reg_write(GRXFSIZ, rxfsiz);
    reg_write(GNPTXFSIZ, (nptx_depth << 16) | rxfsiz);
    reg_write(DIEPTXF1, (ep1_depth << 16) | ep1_start);
    reg_write(DIEPTXF2, (ep2_depth << 16) | ep2_start);
    trace_hex(b"[usb] GRXFSIZ=\0", u64::from(reg_read(GRXFSIZ)));
    trace_hex(b"[usb] GNPTXFSIZ=\0", u64::from(reg_read(GNPTXFSIZ)));
    trace_hex(b"[usb] DIEPTXF2=\0", u64::from(reg_read(DIEPTXF2)));

    // 9. Unmask the device interrupts we poll on (never SOF), clear stale.
    reg_write(
        GINTMSK,
        GINTSTS_USBRST
            | GINTSTS_ENUMDONE
            | GINTSTS_RXFLVL
            | GINTSTS_IEPINT
            | GINTSTS_OEPINT
            | GINTSTS_USBSUSP,
    );
    reg_write(DOEPMSK, DXEPINT_XFERCOMPL | DOEPINT_SETUP);
    reg_write(DIEPMSK, DXEPINT_XFERCOMPL | DIEPINT_TIMEOUT);
    reg_write(DAINTMSK, (1 << 0) | (1 << 16)); // IN-EP0 + OUT-EP0
    reg_write(GINTSTS, 0xFFFF_FFFF); // write-1-clear all stale bits

    // 10. Force B-session valid (Mac sources VBUS; external power may leave
    //     session sense unreliable).
    reg_write(
        GOTGCTL,
        reg_read(GOTGCTL) | GOTGCTL_BVALOEN | GOTGCTL_BVALOVAL,
    );

    // Arm OUT-EP0 for the first SETUP before the host can enumerate.
    arm_out_setup();

    // 11. Do NOT soft-connect here. Becoming host-visible before the kernel
    //     can answer SETUPs inside the host's timing guarantees a failed —
    //     and on macOS permanently abandoned — enumeration. The connection
    //     manager above asserts the pull-up once sustained idle is reached.
    // SAFETY: serialized bring-up owns every driver static here.
    unsafe {
        CONN_STATE = ConnState::Detached;
        LAST_POLL_TS = 0;
        IDLE_STREAK_TS = 0;
        CONN_STATE_TS = 0;
        ENUM_STATE = EnumState::Reset;
        ENUMERATED_FLAG = false;
        INITED = true;
    }
    trace(b"[usb] init done (detached); connect deferred to idle\n\0");
    0
}
