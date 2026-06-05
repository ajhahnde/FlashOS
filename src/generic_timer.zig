// generic_timer: generic ARM timer driver.
//
// The tick deadline is maintained as an absolute CNTP_CVAL value and advanced
// by a fixed period each interrupt. Re-arming relative to the current counter
// (CNTP_TVAL) would rebase every deadline to handler-entry time, letting
// interrupt latency accumulate into the tick period and drift the cadence on
// real hardware.

const SYS_FREQ: u32 = 54_000_000;

extern fn setup_CNTP_CTL() void;
extern fn set_CNTP_CVAL(cval: u64) void;
extern fn get_sys_count() u64;

var next_deadline: u64 = 0;

export fn generic_timer_init() void {
    setup_CNTP_CTL();
    next_deadline = get_sys_count() +% SYS_FREQ;
    set_CNTP_CVAL(next_deadline);
}

export fn handle_generic_timer() void {
    next_deadline +%= SYS_FREQ;
    // If the new deadline already lies in the past (the handler ran very
    // late), rebase from the current counter so the timer does not refire
    // immediately for every missed period in a burst.
    const now = get_sys_count();
    if (@as(i64, @bitCast(next_deadline -% now)) <= 0) {
        next_deadline = now +% SYS_FREQ;
    }
    set_CNTP_CVAL(next_deadline);
}
