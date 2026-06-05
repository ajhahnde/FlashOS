// BCM2711 DWC2 USB-OTG device (gadget) driver — CDC-ACM console.
//
// Brings the Synopsys DWC2 core up as a Full-Speed USB device and enumerates
// as a CDC-ACM serial function so macOS binds AppleUSBCDCACM and creates a
// /dev/tty.usbmodem node. Layered bottom-up: core bring-up (MMIO / reset /
// EP0 / the SET_ADDRESS quirk), the CDC descriptor set + class control
// requests (SET/GET_LINE_CODING, SET_CONTROL_LINE_STATE) on EP0, then the
// data path: on SET_CONFIGURATION it hardware-configures the
// CDC endpoints — EP1 IN (interrupt notify, activated but never queued), EP2
// OUT + EP2 IN (bulk) — and partitions a per-EP TX FIFO for each IN endpoint
// inside the core SPRAM. Bulk-OUT bytes drain from the shared RX FIFO straight
// into console.console_push (the same ring fsh reads). Bulk-IN rides a bounded
// preempt-guarded TX ring (cdc_tx → serviceTxRing); backpressure is a brief
// bounded spin then drop, so the kernel never blocks on a host that stopped
// reading. The console mux that routes fsh output through cdc_tx lives in
// sys.zig (console_tx).
//
// Design constraints:
//   * Full-Speed (DCFG.DevSpd = FS) — skips HS chirp + the qualifier descs.
//   * Polled — poll() reads GINTSTS from the PID-0 idle loop; no GIC/IRQ.
//   * Slave/PIO (GAHBCFG.DMAEn = 0) — CPU copies via the FIFO window.
//   * MMIO at 0xFE980000 is already device-mapped by boot.S, so this needs
//     no page allocator; all buffers are static (EP0 FS max packet = 64 B).
//   * Deferred connect — the gadget stays electrically detached until the
//     PID-0 idle loop services poll() at µs rate (sustained idle); see the
//     "Connection manager" section. Attaching any earlier guarantees a
//     failed enumeration (the boot harness starves the idle loop).
//
// QEMU `raspi4b` does NOT emulate the DWC2 *device* path, so this cannot be
// brought up in emulation. Two CI-safety invariants keep `zig build
// test-rpi4b` green there: (1) every wait loop is BOUNDED and usb_init
// fails soft with -1 (kernel logs + degrades, like emmc2.init()); (2)
// poll() is a single bounded pass and a no-op until `inited` is set. A dead
// MMIO read (GSNPSID == 0 / 0xFFFFFFFF) bails before any bring-up.
//
// The driver is debugged from the device-side trace UART — here the
// Mini-UART (TRACE = MU), the single adapter on the bench. macOS
// is near-silent on a failed enum, so every GINTSTS event + every SETUP is
// traced. Trace is event-gated (poll() prints only when a bit is actually
// handled) so an idle bus stays silent and the console remains readable.

const usb_desc = @import("usb_descriptors"); // pure: descriptors + SETUP decode
const usb_tx_ring = @import("usb_tx_ring"); //   pure: bulk-IN TX byte-ring (host-tested)
const mailbox = @import("mailbox"); //          pure: DEVICE_ID_USB_HCD, POWER_STATE_*
const mbox = @import("mailbox.zig"); //          board: VideoCore MMIO doorbell
const console = @import("console"); //           board-agnostic console RX ring

extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
// UP mutual exclusion for the TX ring. The ring has TWO producers (kernel
// main_output and the user sys_writeConsole path via console_tx) and one
// consumer (serviceTxRing, from the poll loop), so a plain lock-free SPSC ring
// is not enough — a producer preempted mid-enqueue would corrupt head.
// preempt_disable is the single-core lock (SMP → a real spinlock is future
// work, exactly as src/console.zig documents for the RX side).
extern fn preempt_disable() void;
extern fn preempt_enable() void;

// Trace sink. MU (interface 0) = Mini-UART, the existing bench adapter.
// Flip to 1 (PL011/UART4, GPIO8-9) if a second adapter is wired and you
// want USB trace off the console cable.
const TRACE: i32 = 0;

// Per-packet bulk trace (EP2 OUT byte counts, EP2 IN chunk sizes). Off by
// default so normal operation leaves the MU trace readable; flip on for HW
// bring-up to watch the data path move bytes.
const TRACE_BULK: bool = false;

// ---------------------------------------------------------------------------
// MMIO base + register access
// ---------------------------------------------------------------------------

const LINEAR_MAP_BASE: u64 = 0xFFFF000000000000;
const DWC2_BASE: u64 = 0xFE980000 + LINEAR_MAP_BASE;

fn reg_at(off: u32) *volatile u32 {
    return @as(*volatile u32, @ptrFromInt(DWC2_BASE + off));
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

const GINTSTS_CURMOD: u32 = 1 << 0;
const GINTSTS_SOF: u32 = 1 << 3; // never unmask — floods the trace at 1 kHz
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
const DXEPTSIZ_PKTCNT_SHIFT: u5 = 19; // EP0 PktCnt is [20:19] (max 3 packets)
const EP0_MPS: u32 = 64; // Full-Speed EP0 max packet (bytes)

// HW-probe knob: if enumeration never reaches USBRST on hardware, flip this
// (and the paired DevSpd above) to try the dedicated FS serial PHY path.
const USE_FS_SERIAL_PHY: bool = false;

// Bounded-wait iteration caps. Each iteration is one MMIO read; 1M reads is
// trivial on real silicon and on QEMU (where the bit may never set, so the
// loop must terminate to keep the watchdog from hanging).
const SPIN: u32 = 1_000_000;

// ---------------------------------------------------------------------------
// Static state (no page allocator; FS EP0 max packet = 64 B)
// ---------------------------------------------------------------------------

var inited: bool = false;
var enumerated_flag: bool = false;
// Tracks the CDC DTR control line (SET_CONTROL_LINE_STATE wValue bit0). A host
// asserts DTR when it opens the tty (screen / piconnect attach); the 0→1 edge
// is our "operator just connected" signal, used to re-emit the login prompt
// (see dispatchSetup). Cleared on bus reset so a re-attach re-fires.
var dtr_asserted: bool = false;
var current_config: u8 = 0;
var setup_packet: [8]u8 align(4) = [_]u8{0} ** 8;

// CDC line coding (115200 8N1 default). GET_LINE_CODING returns it;
// SET_LINE_CODING captures the host's 7-byte OUT data stage into it. Cosmetic
// over USB but macOS round-trips it on port open.
var line_coding: [7]u8 = usb_desc.line_coding_default;
// A control-OUT write (SET_LINE_CODING) is mid-flight: its 7-byte data stage
// is arriving on EP0 OUT; the IN ZLP status is sent on the OUT XFRC.
var ep0_out_pending: bool = false;

const EnumState = enum { reset, default_state, addressed, configured };
var enum_state: EnumState = .reset;

// --- Bulk data path state ---
// Set on SET_CONFIGURATION(>=1) once EP1/EP2 are hardware-configured; cleared
// on USBRST / SET_CONFIGURATION(0). cdc_tx and the bulk-OUT route gate on it.
var data_configured: bool = false;
// An EP2 IN (bulk) transfer is in flight: EPENA is set and the host has not yet
// ACKed (DIEPINT2.XferCompl). serviceTxRing must not start a new transfer until
// this clears, or it would overwrite the in-flight FIFO contents.
var ep2_in_busy: bool = false;

// Bulk-IN TX ring. The bounded byte-ring arithmetic (monotone u64 head/tail,
// modulo indexing, overflow→false, peek-then-advance) lives in the pure
// usb_tx_ring module so it is host-unit-tested (same discipline as
// console.zig / pipe.zig). 512 B absorbs interactive bursts; sustained
// overflow past the bounded spin drops (policy: never block on the host).
// Each ring op below is bracketed in preempt_disable — the single-core lock
// between cdc_tx (producer) and serviceTxRing (consumer).
const TX_RING_SIZE: u64 = 512;
var tx_ring: usb_tx_ring.ByteRing(TX_RING_SIZE) = .{};

// Backpressure spin bound (per dropped byte). Sized to cover one bulk-IN packet
// draining at Full-Speed when the host IS reading; a host that stopped reading
// leaves EP2 NAKing so the spin expires and the byte drops — bounded, never a
// kernel stall.
const TX_SPIN: u32 = 2_000;

// ---------------------------------------------------------------------------
// Timing — accurate delay off the ARM generic-timer counter (self-contained;
// readable from reset, no kernel timer dependency, stays ~real-time on QEMU).
// ---------------------------------------------------------------------------

fn readCntfrq() u64 {
    return asm volatile ("mrs %[v], cntfrq_el0"
        : [v] "=r" (-> u64),
    );
}
fn readCntpct() u64 {
    return asm volatile ("mrs %[v], cntpct_el0"
        : [v] "=r" (-> u64),
    );
}
fn delay_us(us: u64) void {
    const freq = readCntfrq();
    if (freq == 0) return; // firmware left CNTFRQ unset — skip rather than spin
    const start = readCntpct();
    const ticks = (freq * us) / 1_000_000;
    while ((readCntpct() -% start) < ticks) {}
}

// ---------------------------------------------------------------------------
// Trace helpers (all to TRACE / Mini-UART; main_output_u64 prints 16 hex digits)
// ---------------------------------------------------------------------------

fn trace(s: [*:0]const u8) void {
    main_output(TRACE, s);
}
fn traceHex(s: [*:0]const u8, v: u64) void {
    main_output(TRACE, s);
    main_output_u64(TRACE, v);
    main_output(TRACE, "\n");
}

// ---------------------------------------------------------------------------
// Bounded MMIO waits
// ---------------------------------------------------------------------------

fn waitSet(off: u32, mask: u32) bool {
    var i: u32 = 0;
    while (i < SPIN) : (i += 1) {
        if ((reg_at(off).* & mask) != 0) return true;
    }
    return false;
}
fn waitClear(off: u32, mask: u32) bool {
    var i: u32 = 0;
    while (i < SPIN) : (i += 1) {
        if ((reg_at(off).* & mask) == 0) return true;
    }
    return false;
}

fn flushTxFifos() void {
    reg_at(GRSTCTL).* = GRSTCTL_TXFNUM_ALL | GRSTCTL_TXFFLSH;
    _ = waitClear(GRSTCTL, GRSTCTL_TXFFLSH);
}
fn flushRxFifo() void {
    reg_at(GRSTCTL).* = GRSTCTL_RXFFLSH;
    _ = waitClear(GRSTCTL, GRSTCTL_RXFFLSH);
}

// ---------------------------------------------------------------------------
// EP0 control plumbing
// ---------------------------------------------------------------------------

// Arm OUT-EP0 to receive the next SETUP (and the OUT ZLP status of an IN
// transfer). MANDATORY after every control transfer — forgetting it means
// the second SETUP (e.g. SET_ADDRESS after GET_DESCRIPTOR) never arrives.
fn armOutSetup() void {
    reg_at(DOEPTSIZ0).* = DOEPTSIZ0_SUPCNT_3 | DXEPTSIZ_PKTCNT_1 | (8 * 1);
    reg_at(DOEPCTL0).* = reg_at(DOEPCTL0).* | DXEPCTL_EPENA | DXEPCTL_CNAK;
}

// Send an EP0 IN transfer. The CDC config descriptor is 67 B > the 64-B FS
// EP0 max packet, so this packetizes: PktCnt = ceil(len / 64) (EP0 PktCnt is
// 2 bits → max 3 packets / 192 B; our largest transfer is the 67-B config).
// All bytes fit the 128-B EP0 TX FIFO at once, so slave-mode PIO pushes the
// whole transfer in one shot and the core splits it into max-packet chunks.
// len == 0 sends the status-stage ZLP. A short final packet (len not a
// multiple of 64 — true for every descriptor we serve) terminates the
// transfer, so no explicit ZLP is needed.
fn ep0SendData(data: []const u8) void {
    const len: u32 = @intCast(data.len);
    const pktcnt: u32 = if (len == 0) 1 else (len + EP0_MPS - 1) / EP0_MPS;
    reg_at(DIEPTSIZ0).* = (pktcnt << DXEPTSIZ_PKTCNT_SHIFT) | len; // PktCnt, XferSize=len
    reg_at(DIEPCTL0).* = reg_at(DIEPCTL0).* | DXEPCTL_EPENA | DXEPCTL_CNAK;
    const words = (len + 3) / 4;
    if (words == 0) return; // ZLP — EPENA alone sends the zero-length packet
    var space: u32 = 0;
    var i: u32 = 0;
    while (i < SPIN) : (i += 1) { // bounded wait for TX-FIFO space
        space = reg_at(DTXFSTS0).* & 0xFFFF;
        if (space >= words) break;
    }
    if (space < words) {
        trace("[usb] EP0 IN: TX-FIFO space timeout\n");
        return;
    }
    var w: u32 = 0;
    while (w < words) : (w += 1) {
        var word: u32 = 0;
        var b: u32 = 0;
        while (b < 4) : (b += 1) {
            const idx = w * 4 + b;
            if (idx < len) word |= @as(u32, data[idx]) << @as(u5, @intCast(b * 8));
        }
        reg_at(DFIFO0).* = word;
    }
}

fn stallEp0() void {
    reg_at(DIEPCTL0).* = reg_at(DIEPCTL0).* | DXEPCTL_STALL;
    reg_at(DOEPCTL0).* = reg_at(DOEPCTL0).* | DXEPCTL_STALL;
    armOutSetup();
}

// ---------------------------------------------------------------------------
// Bulk + notify endpoint plumbing
// ---------------------------------------------------------------------------

// Arm EP2 OUT to receive one bulk packet. PktCnt=1 / XferSize=MPS: the host's
// next bulk-OUT lands in the shared RX FIFO (drained by onRxFifoLevel), then
// DOEPINT2.XferCompl fires and onOutEpInt re-arms. One packet per arming keeps
// the slave-mode loop simple; a console's OUT rate is human typing.
fn armEp2Out() void {
    reg_at(DOEPTSIZ2).* = DXEPTSIZ_PKTCNT_1 | EP_BULK_MPS;
    reg_at(DOEPCTL2).* = reg_at(DOEPCTL2).* | DXEPCTL_EPENA | DXEPCTL_CNAK;
}

// Hardware-configure the CDC data + notify endpoints. Called on
// SET_CONFIGURATION(>=1); the TX FIFO partitions were laid down in usb_init.
//   * EP1 IN  — interrupt notify, MPS 16, TX FIFO #1. Activated for a
//     well-formed config but never queued (CDC SERIAL_STATE is optional), so
//     it simply NAKs the host's interrupt polls.
//   * EP2 IN  — bulk, MPS 64, TX FIFO #2. Driven by serviceTxRing.
//   * EP2 OUT — bulk, MPS 64. Armed here; bytes route to console_push.
// SetD0PID starts each toggle at DATA0; the core auto-toggles afterwards.
fn configureDataEndpoints() void {
    reg_at(DIEPCTL1).* = DXEPCTL_USBACTEP | DXEPCTL_EPTYPE_INTR |
        DXEPCTL_TXFNUM_1 | DXEPCTL_SETD0PID | EP_NOTIFY_MPS;
    reg_at(DIEPCTL2).* = DXEPCTL_USBACTEP | DXEPCTL_EPTYPE_BULK |
        DXEPCTL_TXFNUM_2 | DXEPCTL_SETD0PID | EP_BULK_MPS;
    reg_at(DOEPCTL2).* = DXEPCTL_USBACTEP | DXEPCTL_EPTYPE_BULK |
        DXEPCTL_SETD0PID | EP_BULK_MPS;
    // Aggregate EP2 OUT completion into GINTSTS.OEPINT. EP2 IN completion is
    // polled directly off DIEPINT2 in serviceTxRing (the per-EP status bit
    // latches independently of DAINTMSK), so it stays out of the mask.
    reg_at(DAINTMSK).* = reg_at(DAINTMSK).* | (1 << 18);
    ep2_in_busy = false;
    data_configured = true;
    armEp2Out();
    trace("[usb] data EPs configured (EP1 notify, EP2 bulk in/out)\n");
}

// SET_CONFIGURATION(0): tear the data path back down to the addressed state.
fn deconfigureDataEndpoints() void {
    data_configured = false;
    ep2_in_busy = false;
    reg_at(DAINTMSK).* = reg_at(DAINTMSK).* & ~@as(u32, 1 << 18);
    tx_ring.clear();
}

// ---------------------------------------------------------------------------
// SETUP decode + standard-request dispatch
// ---------------------------------------------------------------------------

fn dispatchSetup() void {
    const s = usb_desc.decodeSetup(&setup_packet);
    main_output(TRACE, "[usb] SETUP bmRT=");
    main_output_u64(TRACE, s.bmRequestType);
    main_output(TRACE, " bReq=");
    main_output_u64(TRACE, s.bRequest);
    main_output(TRACE, " wVal=");
    main_output_u64(TRACE, s.wValue);
    main_output(TRACE, " wLen=");
    main_output_u64(TRACE, s.wLength);
    main_output(TRACE, "\n");

    switch (s.bRequest) {
        usb_desc.REQ_GET_DESCRIPTOR => {
            if (usb_desc.getDescriptor(s.descType(), s.descIndex())) |d| {
                const n: u16 = @min(@as(u16, @intCast(d.len)), s.wLength);
                ep0SendData(d[0..n]);
            } else {
                trace("[usb] GET_DESCRIPTOR unknown -> STALL\n");
                stallEp0();
            }
        },
        usb_desc.REQ_SET_ADDRESS => {
            // DWC2 quirk: program DCFG.DevAddr NOW (after decode, before the
            // status-stage ZLP) — the core latches it at status completion.
            const addr = s.address();
            var dcfg = reg_at(DCFG).*;
            dcfg &= ~DCFG_DEVADDR_MASK;
            dcfg |= @as(u32, addr) << 4;
            reg_at(DCFG).* = dcfg;
            ep0SendData(&[_]u8{}); // ZLP status
            enum_state = .addressed;
            traceHex("[usb] SET_ADDRESS=", addr);
        },
        usb_desc.REQ_SET_CONFIGURATION => {
            current_config = @truncate(s.wValue);
            // Bring the bulk + notify endpoints up (or tear them down on
            // config 0) before acking, so the host can stream immediately.
            if (current_config >= 1) configureDataEndpoints() else deconfigureDataEndpoints();
            ep0SendData(&[_]u8{}); // ZLP status
            enum_state = .configured;
            enumerated_flag = (current_config >= 1);
            trace("[usb] SET_CONFIGURATION -> enumerated\n");
        },
        usb_desc.REQ_GET_CONFIGURATION => {
            ep0SendData(&[_]u8{current_config});
        },
        usb_desc.REQ_GET_STATUS => {
            ep0SendData(&[_]u8{ 0x00, 0x00 });
        },
        usb_desc.REQ_SET_FEATURE, usb_desc.REQ_CLEAR_FEATURE => {
            ep0SendData(&[_]u8{}); // ack, no-op
        },
        // --- CDC-ACM class requests (macOS sends these on tty open) ---
        usb_desc.REQ_GET_LINE_CODING => {
            ep0SendData(line_coding[0..]); // 7-byte line coding (control read)
        },
        usb_desc.REQ_SET_LINE_CODING => {
            // H2D with a 7-byte data stage. Defer the IN ZLP status to the OUT
            // XFRC (onOutEpInt); armOutSetup below receives the line coding.
            ep0_out_pending = true;
        },
        usb_desc.REQ_SET_CONTROL_LINE_STATE => {
            // wValue bit0 = DTR. The host raises it when a terminal opens the
            // tty. The boot's first `login:` prompt is emitted before any
            // terminal is attached, so it never reaches the operator; on the
            // DTR rising edge we push one newline into the console RX ring so
            // the waiting login (or a running shell) re-emits a fresh prompt —
            // the operator sees `login:` the instant they connect instead of
            // typing the username blind. Rising-edge only, so a host that
            // re-asserts DTR cannot spam prompts. console_push here is the same
            // RX-ring entry the bulk-OUT data path uses below, same context.
            const dtr = (s.wValue & 0x0001) != 0;
            if (dtr and !dtr_asserted) console.console_push('\n');
            dtr_asserted = dtr;
            ep0SendData(&[_]u8{}); // wLength=0 → ZLP status
        },
        usb_desc.REQ_SEND_BREAK => {
            ep0SendData(&[_]u8{}); // wLength=0 → ZLP status (break ignored)
        },
        else => {
            trace("[usb] unhandled bReq -> STALL\n");
            stallEp0();
        },
    }
    armOutSetup(); // ready for the OUT status / the data stage / the next SETUP
}

// ---------------------------------------------------------------------------
// GINTSTS event handlers
// ---------------------------------------------------------------------------

fn onUsbReset() void {
    reg_at(DCTL).* = reg_at(DCTL).* | DCTL_CGNPINNAK | DCTL_CGOUTNAK;
    flushTxFifos();
    flushRxFifo();
    var dcfg = reg_at(DCFG).*;
    dcfg &= ~DCFG_DEVADDR_MASK; // reset always returns to address 0
    reg_at(DCFG).* = dcfg;
    armOutSetup();
    enum_state = .reset;
    enumerated_flag = false;
    dtr_asserted = false; // re-attach after reset must re-fire the prompt nudge
    // A reset voids any in-flight bulk transfer and the host session;
    // drop the configured state + buffered TX so re-enumeration starts clean
    // (the TX FIFOs were just flushed above).
    data_configured = false;
    ep2_in_busy = false;
    tx_ring.clear();
    trace("[usb] USBRST: addr=0, EP0 re-armed\n");
}

fn onEnumDone() void {
    const spd = (reg_at(DSTS).* >> 1) & 0x3;
    // EP0 max packet = 64 (FS) → MPS[1:0] = 00 on both control EPs.
    reg_at(DIEPCTL0).* = reg_at(DIEPCTL0).* & ~DXEPCTL_MPS_MASK;
    reg_at(DOEPCTL0).* = reg_at(DOEPCTL0).* & ~DXEPCTL_MPS_MASK;
    enum_state = .default_state;
    traceHex("[usb] ENUMDONE speed=", spd);
}

// Save DAIF, then mask IRQs; the prior DAIF is handed back to irqRestore.
// Save/restore — NOT a blind irq_enable: onRxFifoLevel (below) runs from the
// idle-loop poll (IRQs on) AND the pre-enum timer-tick poll (IRQs already
// masked), so we must never unmask a mask the caller already held. "memory"
// clobber keeps the compiler from hoisting the ring RMW out of the region
// (the same full barrier a `bl irq_disable` call would have implied).
fn irqSave() u64 {
    const daif = asm volatile ("mrs %[v], daif"
        : [v] "=r" (-> u64),
    );
    asm volatile ("msr daifset, #2"
        :
        :
        : .{ .memory = true });
    return daif;
}
fn irqRestore(daif: u64) void {
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (daif),
        : .{ .memory = true });
}

// RX FIFO non-empty: pop GRXSTSP ONCE and drain its data words. Every packet
// MUST be fully drained from DFIFO0 (even discarded ones) or the FIFO never
// empties and RXFLVL stays asserted forever. IRQs are masked across the whole
// drain (irqSave/irqRestore): the EP2 console_push below shares the console RX
// ring with the AUX mini-UART RX IRQ handler (board/rpi4b/irq.zig), so a nested
// console_push would race rx_head and drop/duplicate a byte. The window is one
// GRXSTSP packet — bounded and short.
fn onRxFifoLevel() void {
    const daif = irqSave();
    defer irqRestore(daif);
    const sts = reg_at(GRXSTSP).*;
    const epnum = sts & 0xF;
    const pktsts = (sts >> 17) & 0xF;
    const bcnt = (sts >> 4) & 0x7FF;
    const words = (bcnt + 3) / 4;
    switch (pktsts) {
        PKTSTS_SETUP_DATA => {
            var captured: u32 = 0;
            var i: u32 = 0;
            while (i < words) : (i += 1) {
                const word = reg_at(DFIFO0).*;
                var b: u32 = 0;
                while (b < 4) : (b += 1) {
                    if (captured < 8) {
                        setup_packet[captured] = @truncate(word >> @as(u5, @intCast(b * 8)));
                        captured += 1;
                    }
                }
            }
        },
        PKTSTS_OUT_DATA => {
            // Drain every word (or RXFLVL stays asserted). EP2 = CDC bulk OUT →
            // push each real byte into the console RX ring (the same ring fsh
            // reads). EP0 = a pending control-OUT write (SET_LINE_CODING) → keep
            // the first 7 bytes as the line coding.
            var captured: u32 = 0;
            var i: u32 = 0;
            while (i < words) : (i += 1) {
                const word = reg_at(DFIFO0).*;
                var b: u32 = 0;
                while (b < 4) : (b += 1) {
                    const byte: u8 = @truncate(word >> @as(u5, @intCast(b * 8)));
                    if (captured < bcnt) {
                        if (epnum == 2) {
                            console.console_push(byte);
                        } else if (ep0_out_pending and captured < line_coding.len) {
                            line_coding[captured] = byte;
                        }
                    }
                    captured += 1;
                }
            }
            if (TRACE_BULK and epnum == 2) traceHex("[usb] OUT2 bytes=", bcnt);
        },
        else => {}, // SETUP_COMP / OUT_COMP / GOUT_NAK carry no data words
    }
}

fn onOutEpInt() void {
    const doepint = reg_at(DOEPINT0).*;
    if ((doepint & DOEPINT_SETUP) != 0) {
        reg_at(DOEPINT0).* = DOEPINT_SETUP; // write-1-clear
        dispatchSetup(); // SETUP-complete is the decode trigger (setup_packet already captured)
    }
    if ((doepint & DXEPINT_XFERCOMPL) != 0) {
        reg_at(DOEPINT0).* = DXEPINT_XFERCOMPL;
        if (ep0_out_pending) {
            // SET_LINE_CODING data stage done → send the IN ZLP status that
            // finishes the control-OUT write.
            ep0_out_pending = false;
            ep0SendData(&[_]u8{});
            trace("[usb] SET_LINE_CODING\n");
        }
        armOutSetup(); // OUT status / data complete → re-arm for the next SETUP
    }

    // EP2 bulk OUT transfer complete (data already drained by onRxFifoLevel) →
    // re-arm for the next packet.
    if (data_configured) {
        const doepint2 = reg_at(DOEPINT2).*;
        if ((doepint2 & DXEPINT_XFERCOMPL) != 0) {
            reg_at(DOEPINT2).* = DXEPINT_XFERCOMPL;
            armEp2Out();
        }
    }
}

fn onInEpInt() void {
    const diepint = reg_at(DIEPINT0).*;
    if ((diepint & DXEPINT_XFERCOMPL) != 0) reg_at(DIEPINT0).* = DXEPINT_XFERCOMPL;
    if ((diepint & DIEPINT_TIMEOUT) != 0) reg_at(DIEPINT0).* = DIEPINT_TIMEOUT;
}

// ---------------------------------------------------------------------------
// Bulk-IN TX path (EP2)
// ---------------------------------------------------------------------------

// Push pending TX-ring bytes onto EP2 bulk IN, one max-packet (64 B) chunk per
// call. Self-contained: it retires a finished prior transfer by polling
// DIEPINT2.XferCompl directly (the per-EP status bit latches independent of
// DAINTMSK), so it makes progress whether driven from the poll loop (idle) or
// opportunistically from cdc_tx (a producer). preempt_disable makes the whole
// body the consumer critical section — mutually exclusive on this single core
// with cdc_tx's enqueue.
fn serviceTxRing() void {
    if (!data_configured) return;
    preempt_disable();
    // Retire a completed transfer so the next chunk can launch.
    if (ep2_in_busy and (reg_at(DIEPINT2).* & DXEPINT_XFERCOMPL) != 0) {
        reg_at(DIEPINT2).* = DXEPINT_XFERCOMPL;
        ep2_in_busy = false;
    }
    if (!ep2_in_busy) {
        // Peek one max-packet chunk WITHOUT consuming it — advance only once
        // the TX FIFO has actually taken the bytes (peek is read-only, so a
        // FIFO-full bail leaves the chunk queued for the next pass).
        var chunk_buf: [EP_BULK_MPS]u8 = undefined;
        const chunk: u32 = @intCast(tx_ring.peek(chunk_buf[0..]));
        if (chunk > 0) {
            const words: u32 = (chunk + 3) / 4;
            // Only launch if the EP2 TX FIFO can take the whole chunk now.
            if ((reg_at(DTXFSTS2).* & 0xFFFF) >= words) {
                reg_at(DIEPTSIZ2).* = DXEPTSIZ_PKTCNT_1 | chunk; // PktCnt=1, XferSize=chunk
                reg_at(DIEPCTL2).* = reg_at(DIEPCTL2).* | DXEPCTL_EPENA | DXEPCTL_CNAK;
                var w: u32 = 0;
                while (w < words) : (w += 1) {
                    var word: u32 = 0;
                    var b: u32 = 0;
                    while (b < 4) : (b += 1) {
                        const idx = w * 4 + b;
                        if (idx < chunk) word |= @as(u32, chunk_buf[idx]) << @as(u5, @intCast(b * 8));
                    }
                    reg_at(DFIFO2).* = word;
                }
                tx_ring.advance(chunk);
                ep2_in_busy = true;
                if (TRACE_BULK) traceHex("[usb] IN2 chunk=", chunk);
            }
        }
    }
    preempt_enable();
}

// Push one byte into the TX ring with the bounded spin-then-drop backpressure
// policy: when the ring is full, spin briefly draining the hardware to make
// room, then drop — the kernel must never block on a host that stopped
// reading.
fn txPushByte(byte: u8) void {
    var tries: u32 = 0;
    while (true) {
        preempt_disable();
        const ok = tx_ring.push(byte);
        preempt_enable();
        if (ok) return;
        serviceTxRing(); // ring full → drain a chunk to the FIFO, then retry
        tries += 1;
        if (tries >= TX_SPIN) return; // host not draining → drop this byte
    }
}

// Queue console bytes for the host over EP2 bulk IN. Called by the console mux
// (sys.zig console_tx). data_configured gates it (before enumeration the
// caller falls back to the UART).
pub fn cdc_tx(data: []const u8) void {
    if (!data_configured) return;
    for (data) |byte| {
        // Terminals need CRLF; the kernel writes LF-only. Mirror the
        // Mini-UART driver's newline translation (uart.zig does the same) so
        // both console transports render identically.
        if (byte == '\n') txPushByte('\r');
        txPushByte(byte);
    }
    serviceTxRing(); // kick: push what we just queued without waiting for idle
}

// ---------------------------------------------------------------------------
// Connection manager — when to be electrically visible
//
// A USB bus reset hardware-disarms EP0 OUT (DOEPTSIZ0.SUPCNT / DOEPCTL0.EPENA
// do not survive USBRST — Linux dwc2 and TinyUSB re-arm on every reset for
// exactly this reason). The host sends its first SETUP ~20 ms after the reset
// ends, so a SETUP is only ACKed if software re-arms EP0 inside that window.
// The PID-0 idle loop (µs-rate polls) can; the 1 Hz timer-tick backstop
// (board irq.zig) never can. During the boot harness the idle loop is starved,
// so every enumeration attempt the host makes in that window is doomed — and
// macOS permanently disables the port after ~4 failed attempts (~20 s),
// recoverable only by a fresh D+ attach event. Asserting the pull-up inside
// usb_init therefore guarantees a dead console (HW-diagnosed 2026-06-01:
// USBRST/ENUMDONE pairs processed, zero SETUPs ever seen).
//
// Policy: stay detached (DCTL.SftDiscon = 1) until poll() has been arriving
// at idle-loop rate for a sustained window — only then assert the pull-up.
// If the host then fails to enumerate (it gave up before we attached, or the
// system went busy mid-enumeration), pulse a detach long enough for the host
// to register it and re-attach: electrically identical to a physical replug,
// which clears macOS's port-disable state. All timing is wall-clock off
// CNTPCT (the same clock delay_us uses), never iteration counts.
// ---------------------------------------------------------------------------

const ConnState = enum { detached, attaching, attached, pulsing };
var conn_state: ConnState = .detached;
var last_poll_ts: u64 = 0; // CNTPCT at the previous poll() — the gap detector
var idle_streak_ts: u64 = 0; // CNTPCT when the current gap-free streak began
var conn_state_ts: u64 = 0; // CNTPCT when conn_state last changed

// A poll-to-poll gap above this means the idle loop does NOT own the CPU
// (boot harness / long user command): EP0 re-arm latency would exceed the
// host's SETUP window, so being attached is pointless.
const MAX_POLL_GAP_MS: u64 = 10;
// Gap-free polling for this long ⇒ sustained idle ⇒ safe to become visible.
const CONNECT_IDLE_MS: u64 = 2_000;
// Attached but not enumerated for this long ⇒ the host is not talking to us
// (it gave up before we attached, or went away) ⇒ force a fresh attach.
const ENUM_TIMEOUT_MS: u64 = 10_000;
// D+ released for this long during the re-attach pulse. Must clear the host's
// connect debounce (~100 ms, USB 2.0 §7.1.7.3) with a wide margin.
const DETACH_PULSE_MS: u64 = 1_000;

inline fn msToTicks(freq: u64, ms: u64) u64 {
    return (freq * ms) / 1000;
}

fn serviceConnection() void {
    const freq = readCntfrq();
    if (freq == 0) return; // no counter clock → stay detached (bring-up is dead anyway)
    const now = readCntpct();
    if ((now -% last_poll_ts) > msToTicks(freq, MAX_POLL_GAP_MS)) {
        idle_streak_ts = now; // gap → restart the sustained-idle streak
    }
    last_poll_ts = now;
    switch (conn_state) {
        .detached => {
            if ((now -% idle_streak_ts) > msToTicks(freq, CONNECT_IDLE_MS)) {
                reg_at(DCTL).* = reg_at(DCTL).* & ~DCTL_SFT_DISCON;
                conn_state = .attaching;
                conn_state_ts = now;
                // Connection-state traces kept for bring-up but commented out:
                // with no host attached, the attach/timeout/pulse cycle below
                // repeats forever and every transition would land on the fsh
                // console (same MU). Uncomment all three to debug enumeration.
                // trace("[usb] soft-connect (pull-up on)\n");
            }
        },
        .attaching => {
            if (enumerated_flag) {
                conn_state = .attached;
                conn_state_ts = now;
            } else if ((now -% conn_state_ts) > msToTicks(freq, ENUM_TIMEOUT_MS)) {
                reg_at(DCTL).* = reg_at(DCTL).* | DCTL_SFT_DISCON;
                conn_state = .pulsing;
                conn_state_ts = now;
                // trace("[usb] no enumeration -> detach pulse\n");
            }
        },
        .attached => {
            // onUsbReset cleared enumerated_flag → the host is re-enumerating
            // (host-side replug / port reset). Give it the standard window;
            // if it goes silent instead, .attaching times out into a pulse.
            if (!enumerated_flag) {
                conn_state = .attaching;
                conn_state_ts = now;
            }
        },
        .pulsing => {
            if ((now -% conn_state_ts) > msToTicks(freq, DETACH_PULSE_MS)) {
                reg_at(DCTL).* = reg_at(DCTL).* & ~DCTL_SFT_DISCON;
                conn_state = .attaching;
                conn_state_ts = now;
                // trace("[usb] re-attach (pull-up on)\n");
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

// Re-entrancy guard: poll() is reachable from BOTH the PID-0 idle loop
// (kernel.zig) and — until enumeration completes — the timer IRQ (board
// irq.zig, the 1 Hz service backstop). On a single core the IRQ can
// fire mid-poll; the guard turns the nested call into a no-op so the
// GRXSTSP/FIFO read sequences never interleave.
var in_poll: bool = false;

// One GINTSTS service pass; driven from the PID-0 idle loop (kernel.zig) and,
// until the gadget enumerates, from the timer tick (board irq.zig).
// No-op until a successful usb_init. Single bounded pass — no internal loop —
// so it can never hang the QEMU watchdog. Event-gated trace (idle = silent).
pub fn poll() void {
    if (!inited) return;
    if (in_poll) return;
    in_poll = true;
    defer in_poll = false;
    // Connection management first, INSIDE the in_poll guard: nested timer-IRQ
    // calls must neither pollute the idle-gap measurement nor race the state
    // machine.
    serviceConnection();
    const g = reg_at(GINTSTS).*;
    if ((g & GINTSTS_USBRST) != 0) {
        onUsbReset();
        reg_at(GINTSTS).* = GINTSTS_USBRST;
    }
    if ((g & GINTSTS_ENUMDONE) != 0) {
        onEnumDone();
        reg_at(GINTSTS).* = GINTSTS_ENUMDONE;
    }
    if ((g & GINTSTS_RXFLVL) != 0) onRxFifoLevel(); // self-clears via GRXSTSP
    if ((g & GINTSTS_OEPINT) != 0) onOutEpInt();
    if ((g & GINTSTS_IEPINT) != 0) onInEpInt();
    serviceTxRing(); // drain queued bulk-IN bytes (no-op until data_configured)
}

pub fn enumerated() bool {
    return enumerated_flag;
}

// Bring the OTG core up as a polled Full-Speed device. Returns 0 on success,
// -1 on any bounded-wait timeout / absent core (kernel logs + degrades).
pub fn usb_init() i32 {
    // 1. Power the USB HCD domain (defensive; firmware usually pre-powers).
    _ = mbox.setPowerState(mailbox.DEVICE_ID_USB_HCD, mailbox.POWER_STATE_ON | mailbox.POWER_STATE_WAIT);
    delay_us(2_000);

    // 0. Diagnostic dump + dead-MMIO gate. A live DWC2 core answers GSNPSID
    //    with an "OT" signature; QEMU (no device path) reads 0 / 0xFFFFFFFF.
    const snpsid = reg_at(GSNPSID).*;
    traceHex("[usb] GSNPSID=", snpsid);
    traceHex("[usb] GHWCFG3=", reg_at(GHWCFG3).*);
    if (snpsid == 0 or snpsid == 0xFFFFFFFF) {
        trace("[usb] no DWC2 core (dead MMIO) -> skip\n");
        return -1;
    }

    // 2. Wait for AHB idle, then 3. core soft-reset.
    if (!waitSet(GRSTCTL, GRSTCTL_AHBIDLE)) {
        trace("[usb] AHBIDLE timeout\n");
        return -1;
    }
    reg_at(GRSTCTL).* = reg_at(GRSTCTL).* | GRSTCTL_CSFTRST;
    if (!waitClear(GRSTCTL, GRSTCTL_CSFTRST) or !waitSet(GRSTCTL, GRSTCTL_AHBIDLE)) {
        trace("[usb] CSFTRST timeout\n");
        return -1;
    }
    trace("[usb] core soft-reset done\n");

    // 3a. Stay electrically detached (D+ released) through the rest of
    //     bring-up AND the rest of OS boot — the connection manager
    //     (serviceConnection) asserts the pull-up only once the idle loop
    //     demonstrably owns the CPU. Explicit write because the CSFTRST
    //     reset value of SftDiscon differs across core versions.
    reg_at(DCTL).* = reg_at(DCTL).* | DCTL_SFT_DISCON;

    // 4. PHY / mode select: force device mode, clear host mode, pick PHY.
    var gusbcfg = reg_at(GUSBCFG).*;
    gusbcfg &= ~GUSBCFG_FORCE_HST;
    gusbcfg |= GUSBCFG_FORCE_DEV;
    if (USE_FS_SERIAL_PHY) {
        gusbcfg |= GUSBCFG_PHYSEL;
    } else {
        gusbcfg &= ~GUSBCFG_PHYSEL;
    }
    reg_at(GUSBCFG).* = gusbcfg;
    traceHex("[usb] GUSBCFG=", gusbcfg);

    // 5. ~25 ms settle after ForceDevMode (DWC2 programming-guide requirement;
    //    skipping it silently wedges bring-up).
    delay_us(25_000);
    trace("[usb] post-forcedev settle\n");

    // 6. Slave/PIO + polled: DMAEn=0, GlblIntrMsk=0 (no IRQ to the GIC).
    reg_at(GAHBCFG).* = (reg_at(GAHBCFG).* & ~GAHBCFG_DMA_EN & ~GAHBCFG_GLBL_INTR_MSK) | GAHBCFG_TXF_EMP_LVL;

    // 7. Full-Speed.
    var dcfg = reg_at(DCFG).*;
    dcfg &= ~DCFG_DEVSPD_MASK;
    dcfg |= if (USE_FS_SERIAL_PHY) DCFG_DEVSPD_FS_DEDICATED else DCFG_DEVSPD_FS_HS_PHY;
    dcfg &= ~DCFG_DEVADDR_MASK;
    reg_at(DCFG).* = dcfg;
    traceHex("[usb] DCFG=", dcfg);

    // 8. FIFO partition (words), all inside the core SPRAM (GHWCFG3[31:16]):
    //      RX (shared OUT)      64 @ 0
    //      EP0 IN  (GNPTXFSIZ)  32 @ 64
    //      EP1 IN  (DIEPTXF1)   16 @ 96    (CDC notify)
    //      EP2 IN  (DIEPTXF2)   64 @ 112   (CDC bulk)
    //    Write GRXFSIZ before the TX partitions. BCM2711 SPRAM is 4080 words,
    //    so 176 words used leaves vast headroom. The EP1/EP2 partitions are
    //    laid down here (static) so configureDataEndpoints only flips DIEPCTL.
    const spram = reg_at(GHWCFG3).* >> 16;
    const rxfsiz: u32 = 64;
    const nptx_depth: u32 = 32;
    const ep1_start: u32 = rxfsiz + nptx_depth; // 96
    const ep1_depth: u32 = 16;
    const ep2_start: u32 = ep1_start + ep1_depth; // 112
    const ep2_depth: u32 = 64;
    if (spram != 0 and (ep2_start + ep2_depth) > spram) {
        trace("[usb] FIFO partition > SPRAM\n");
        return -1;
    }
    reg_at(GRXFSIZ).* = rxfsiz;
    reg_at(GNPTXFSIZ).* = (nptx_depth << 16) | rxfsiz;
    reg_at(DIEPTXF1).* = (ep1_depth << 16) | ep1_start;
    reg_at(DIEPTXF2).* = (ep2_depth << 16) | ep2_start;
    traceHex("[usb] GRXFSIZ=", reg_at(GRXFSIZ).*);
    traceHex("[usb] GNPTXFSIZ=", reg_at(GNPTXFSIZ).*);
    traceHex("[usb] DIEPTXF2=", reg_at(DIEPTXF2).*);

    // 9. Unmask the device interrupts we poll on (never SOF), clear stale.
    reg_at(GINTMSK).* = GINTSTS_USBRST | GINTSTS_ENUMDONE | GINTSTS_RXFLVL |
        GINTSTS_IEPINT | GINTSTS_OEPINT | GINTSTS_USBSUSP;
    reg_at(DOEPMSK).* = DXEPINT_XFERCOMPL | DOEPINT_SETUP;
    reg_at(DIEPMSK).* = DXEPINT_XFERCOMPL | DIEPINT_TIMEOUT;
    reg_at(DAINTMSK).* = (1 << 0) | (1 << 16); // IN-EP0 + OUT-EP0
    reg_at(GINTSTS).* = 0xFFFFFFFF; // write-1-clear all stale bits

    // 10. Force B-session valid (Mac sources VBUS; external power may leave
    //     session sense unreliable).
    reg_at(GOTGCTL).* = reg_at(GOTGCTL).* | GOTGCTL_BVALOEN | GOTGCTL_BVALOVAL;

    // Arm OUT-EP0 for the first SETUP before the host can enumerate.
    armOutSetup();

    // 11. Do NOT soft-connect here. Becoming host-visible before the kernel
    //     can answer SETUPs inside the host's timing guarantees a failed —
    //     and on macOS permanently abandoned — enumeration. The connection
    //     manager above asserts the pull-up once sustained idle is reached.
    conn_state = .detached;
    last_poll_ts = 0;
    idle_streak_ts = 0;
    conn_state_ts = 0;
    enum_state = .reset;
    enumerated_flag = false;
    inited = true;
    trace("[usb] init done (detached); connect deferred to idle\n");
    return 0;
}
