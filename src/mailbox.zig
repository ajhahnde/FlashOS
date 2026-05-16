// VideoCore mailbox — property-tag message construction + parsing.
//
// Three firmware services are needed to bring up EMMC2:
//   * "set power state" — defensively enable the SD-card VDD rail
//     (Circle's CardInit calls this before any controller reset on
//     Pi 4; the Pi 4 boot firmware leaves VDD on but matching Circle
//     rules out a half-powered state).
//   * "set GPIO state" — select the 3.3 V SD I/O rail via expander
//     line 4 (mailbox GPIO 132 / VDD_SD_IO_SEL: 0 = 3.3 V, 1 = 1.8 V).
//   * "get clock rate" — read the EMMC2 base clock the SDHCI divider
//     is derived from (the BCM2711 CAP register's base-clock field is
//     unreliable, so the firmware value is the only sound source).
// This module owns the message layout; the board side
// (src/board/<board>/mailbox.zig) owns the MMIO doorbell.
//
// Property message layout (all u32, little-endian):
//   [0] total buffer size in bytes
//   [1] request/response code (0 on request, 0x80000000 = OK)
//   [2] tag id
//   [3] tag value-buffer size in bytes
//   [4] tag request/response code
//   [5] value word 0
//   [6] value word 1
//   [7] end tag (0)

const std = @import("std");

// Property mailbox channel (ARM -> VC tag interface).
pub const CHANNEL_PROP: u32 = 8;

// Property tags.
pub const TAG_GET_CLOCK_RATE: u32 = 0x0003_0002;
pub const TAG_SET_GPIO_STATE: u32 = 0x0003_8041;
pub const TAG_SET_POWER_STATE: u32 = 0x0002_8001;

// VideoCore clock ids.
pub const CLOCK_ID_EMMC2: u32 = 12;

// VideoCore power-state device ids.
pub const DEVICE_ID_SD_CARD: u32 = 0;

// Power-state bits. Request: bit 0 = on/off, bit 1 = wait-until-stable.
// Response: bit 0 = current on/off, bit 1 = NO_DEVICE (firmware can't
// see this device).
pub const POWER_STATE_OFF: u32 = 0;
pub const POWER_STATE_ON: u32 = 1;
pub const POWER_STATE_WAIT: u32 = 2;
pub const POWER_STATE_NO_DEVICE: u32 = 2;

// Pi 4 firmware GPIO-expander lines (the RPi mailbox numbers the
// expander from 128). Per bcm2711-rpi-4-b.dts gpio-line-names: line 4
// "VDD_SD_IO_SEL" selects the SD I/O rail (1 = 1.8 V, 0 = 3.3 V).
pub const EXP_GPIO_BASE: u32 = 128;
pub const EXP_GPIO_SD_1V8: u32 = EXP_GPIO_BASE + 4;

// Request/response codes for word [1] and the per-tag code word.
const CODE_REQUEST: u32 = 0x0000_0000;
const CODE_RESPONSE_OK: u32 = 0x8000_0000;

// Every message this module builds is exactly 8 words. The caller
// places it in 16-byte-aligned memory the VideoCore can read (see
// the board side).
pub const Msg = [8]u32;

// Fill `buf` with a get-clock-rate request for `clock_id`.
pub fn buildGetClockRate(buf: *Msg, clock_id: u32) void {
    buf[0] = @intCast(buf.len * @sizeOf(u32)); // 32
    buf[1] = CODE_REQUEST;
    buf[2] = TAG_GET_CLOCK_RATE;
    buf[3] = 8; // value buffer: clock id + rate
    buf[4] = CODE_REQUEST;
    buf[5] = clock_id;
    buf[6] = 0;
    buf[7] = 0; // end tag
}

// Fill `buf` with a set-GPIO-state request.
pub fn buildSetGpioState(buf: *Msg, gpio: u32, state: u32) void {
    buf[0] = @intCast(buf.len * @sizeOf(u32)); // 32
    buf[1] = CODE_REQUEST;
    buf[2] = TAG_SET_GPIO_STATE;
    buf[3] = 8; // value buffer: gpio number + state
    buf[4] = CODE_REQUEST;
    buf[5] = gpio;
    buf[6] = state;
    buf[7] = 0; // end tag
}

// Fill `buf` with a set-power-state request. The state word is the
// bitwise OR of `POWER_STATE_ON`/`OFF` with optionally `POWER_STATE_WAIT`
// to make the firmware block until the rail is stable.
pub fn buildSetPowerState(buf: *Msg, device_id: u32, state: u32) void {
    buf[0] = @intCast(buf.len * @sizeOf(u32)); // 32
    buf[1] = CODE_REQUEST;
    buf[2] = TAG_SET_POWER_STATE;
    buf[3] = 8; // value buffer: device id + state
    buf[4] = CODE_REQUEST;
    buf[5] = device_id;
    buf[6] = state;
    buf[7] = 0; // end tag
}

// Check the overall response code the VideoCore stamps into word [1].
pub fn checkResponse(buf: *const Msg) error{MailboxError}!void {
    if (buf[1] != CODE_RESPONSE_OK) return error.MailboxError;
}

// Parse a completed get-clock-rate response. Returns the rate in Hz.
// Fails if the VideoCore did not stamp the success code, echoed a
// different clock id than requested, or reported a zero rate.
pub fn parseClockRate(buf: *const Msg, clock_id: u32) error{MailboxError}!u32 {
    try checkResponse(buf);
    if (buf[5] != clock_id) return error.MailboxError;
    if (buf[6] == 0) return error.MailboxError;
    return buf[6];
}

// Parse a completed set-power-state response. Fails if the overall
// response code is not OK, the echoed device id differs, the firmware
// reports NO_DEVICE, or (when ON was requested) the rail did not come
// up.
pub fn parsePowerState(buf: *const Msg, device_id: u32, want_on: bool) error{MailboxError}!void {
    try checkResponse(buf);
    if (buf[5] != device_id) return error.MailboxError;
    if ((buf[6] & POWER_STATE_NO_DEVICE) != 0) return error.MailboxError;
    if (want_on and (buf[6] & POWER_STATE_ON) == 0) return error.MailboxError;
}

// Doorbell word: the property buffer's address with the low nibble
// replaced by the channel. The address must already be 16-byte
// aligned — the board side guarantees this with `align(16)`.
pub fn doorbell(buf_addr: u32, channel: u32) u32 {
    return (buf_addr & ~@as(u32, 0xF)) | (channel & 0xF);
}

// ---- Host tests ----

const testing = std.testing;

test "buildGetClockRate lays out an 8-word EMMC2 request" {
    var buf: Msg = undefined;
    buildGetClockRate(&buf, CLOCK_ID_EMMC2);
    try testing.expectEqual(@as(u32, 32), buf[0]);
    try testing.expectEqual(@as(u32, 0), buf[1]);
    try testing.expectEqual(TAG_GET_CLOCK_RATE, buf[2]);
    try testing.expectEqual(@as(u32, 8), buf[3]);
    try testing.expectEqual(@as(u32, 0), buf[4]);
    try testing.expectEqual(@as(u32, 12), buf[5]);
    try testing.expectEqual(@as(u32, 0), buf[6]);
    try testing.expectEqual(@as(u32, 0), buf[7]);
}

test "buildSetGpioState lays out an 8-word set-GPIO request" {
    var buf: Msg = undefined;
    buildSetGpioState(&buf, EXP_GPIO_SD_1V8, 0);
    try testing.expectEqual(@as(u32, 32), buf[0]);
    try testing.expectEqual(@as(u32, 0), buf[1]);
    try testing.expectEqual(TAG_SET_GPIO_STATE, buf[2]);
    try testing.expectEqual(@as(u32, 8), buf[3]);
    try testing.expectEqual(@as(u32, 0), buf[4]);
    try testing.expectEqual(@as(u32, 132), buf[5]);
    try testing.expectEqual(@as(u32, 0), buf[6]);
    try testing.expectEqual(@as(u32, 0), buf[7]);
}

test "checkResponse accepts the success code, rejects others" {
    var buf: Msg = undefined;
    buildSetGpioState(&buf, EXP_GPIO_SD_1V8, 0);
    try testing.expectError(error.MailboxError, checkResponse(&buf));
    buf[1] = 0x8000_0000;
    try checkResponse(&buf);
}

test "parseClockRate returns the rate on a well-formed response" {
    var buf: Msg = undefined;
    buildGetClockRate(&buf, CLOCK_ID_EMMC2);
    buf[1] = 0x8000_0000; // VC: overall OK
    buf[4] = 0x8000_0008; // VC: tag OK + 8 bytes returned
    buf[6] = 100_000_000; // 100 MHz
    try testing.expectEqual(@as(u32, 100_000_000), try parseClockRate(&buf, CLOCK_ID_EMMC2));
}

test "parseClockRate rejects a missing success code" {
    var buf: Msg = undefined;
    buildGetClockRate(&buf, CLOCK_ID_EMMC2);
    buf[6] = 100_000_000;
    try testing.expectError(error.MailboxError, parseClockRate(&buf, CLOCK_ID_EMMC2));
}

test "parseClockRate rejects a clock-id mismatch" {
    var buf: Msg = undefined;
    buildGetClockRate(&buf, CLOCK_ID_EMMC2);
    buf[1] = 0x8000_0000;
    buf[5] = 1; // VC echoed a different clock
    buf[6] = 100_000_000;
    try testing.expectError(error.MailboxError, parseClockRate(&buf, CLOCK_ID_EMMC2));
}

test "parseClockRate rejects a zero rate" {
    var buf: Msg = undefined;
    buildGetClockRate(&buf, CLOCK_ID_EMMC2);
    buf[1] = 0x8000_0000;
    try testing.expectError(error.MailboxError, parseClockRate(&buf, CLOCK_ID_EMMC2));
}

test "doorbell merges the channel into the low nibble" {
    try testing.expectEqual(@as(u32, 0x0008_1218), doorbell(0x0008_1210, CHANNEL_PROP));
    try testing.expectEqual(@as(u32, 0x0010_0008), doorbell(0x0010_000F, CHANNEL_PROP));
}

test "buildSetPowerState lays out an 8-word SD_CARD power-on request" {
    var buf: Msg = undefined;
    buildSetPowerState(&buf, DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT);
    try testing.expectEqual(@as(u32, 32), buf[0]);
    try testing.expectEqual(@as(u32, 0), buf[1]);
    try testing.expectEqual(TAG_SET_POWER_STATE, buf[2]);
    try testing.expectEqual(@as(u32, 8), buf[3]);
    try testing.expectEqual(@as(u32, 0), buf[4]);
    try testing.expectEqual(@as(u32, 0), buf[5]);
    try testing.expectEqual(@as(u32, 3), buf[6]);
    try testing.expectEqual(@as(u32, 0), buf[7]);
}

test "parsePowerState accepts a well-formed ON response" {
    var buf: Msg = undefined;
    buildSetPowerState(&buf, DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT);
    buf[1] = 0x8000_0000;
    buf[6] = POWER_STATE_ON;
    try parsePowerState(&buf, DEVICE_ID_SD_CARD, true);
}

test "parsePowerState rejects NO_DEVICE" {
    var buf: Msg = undefined;
    buildSetPowerState(&buf, DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT);
    buf[1] = 0x8000_0000;
    buf[6] = POWER_STATE_NO_DEVICE; // bit 1 in response = device missing
    try testing.expectError(error.MailboxError, parsePowerState(&buf, DEVICE_ID_SD_CARD, true));
}

test "parsePowerState rejects rail-not-on when ON was requested" {
    var buf: Msg = undefined;
    buildSetPowerState(&buf, DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT);
    buf[1] = 0x8000_0000;
    buf[6] = POWER_STATE_OFF;
    try testing.expectError(error.MailboxError, parsePowerState(&buf, DEVICE_ID_SD_CARD, true));
}

test "parsePowerState rejects device-id mismatch" {
    var buf: Msg = undefined;
    buildSetPowerState(&buf, DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT);
    buf[1] = 0x8000_0000;
    buf[5] = 7; // VC echoed a different device
    buf[6] = POWER_STATE_ON;
    try testing.expectError(error.MailboxError, parsePowerState(&buf, DEVICE_ID_SD_CARD, true));
}

