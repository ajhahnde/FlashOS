// Generic ARM timer driver

const SYS_FREQ: u32 = 54_000_000;

extern fn setup_CNTP_CTL() void;
extern fn set_CNTP_TVAL(tval: u32) void;

export fn generic_timer_init() void {
    setup_CNTP_CTL();
    set_CNTP_TVAL(SYS_FREQ);
}

export fn handle_generic_timer() void {
    set_CNTP_TVAL(SYS_FREQ);
}
