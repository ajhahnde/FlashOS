// GPIO driver for Raspberry Pi 4

const LINEAR_MAP_BASE: u64 = 0xffff000000000000;
const DEVICE_BASE: u64 = 0xFE000000;
const GPIO_BASE: u64 = DEVICE_BASE + 0x00200000 + LINEAR_MAP_BASE;

const GpioPinData = extern struct {
    reserved: u32,
    data: [2]u32,
};

const GpioRegs = extern struct {
    func_select: [6]u32,
    output_set: GpioPinData,
    output_clear: GpioPinData,
    level: GpioPinData,
    ev_detect_status: GpioPinData,
    re_detect_enable: GpioPinData,
    fe_detect_enable: GpioPinData,
    hi_detect_enable: GpioPinData,
    lo_detect_enable: GpioPinData,
    async_re_detect: GpioPinData,
    async_fe_detect: GpioPinData,
    reserved: u32,
    pupd_enable: u32,
    pupd_enable_clocks: [2]u32,
    reserved2: [18]u32,
    pullup_pulldown: [4]u32,
};

fn getGpioRegs() *volatile GpioRegs {
    return @as(*volatile GpioRegs, @ptrFromInt(GPIO_BASE));
}

/// Set the alternate function for a GPIO pin
export fn gpio_pin_set_func(pin_number: u8, func: u8) void {
    const regs = getGpioRegs();
    const bit_start: u5 = @intCast((pin_number % 10) * 3);
    const reg: usize = pin_number / 10;

    var selector = regs.func_select[reg];
    selector &= ~(@as(u32, 7) << bit_start);
    selector |= (@as(u32, func) << bit_start);
    regs.func_select[reg] = selector;
}

/// Disable pull-up/pull-down for a GPIO pin
export fn gpio_pin_enable(pin_number: u8) void {
    const regs = getGpioRegs();
    const idx: usize = pin_number / 16;
    const bit_start: u5 = @intCast((pin_number % 16) * 2);

    var reg = regs.pullup_pulldown[idx];
    reg &= ~(@as(u32, 3) << bit_start);
    regs.pullup_pulldown[idx] = reg;
}
