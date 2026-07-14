//! Pure VideoCore property-mailbox message construction and parsing.

pub const CHANNEL_PROP: u32 = 8;
pub const TAG_GET_CLOCK_RATE: u32 = 0x0003_0002;
pub const TAG_SET_GPIO_STATE: u32 = 0x0003_8041;
pub const TAG_SET_POWER_STATE: u32 = 0x0002_8001;
pub const TAG_GET_TEMPERATURE: u32 = 0x0003_0006;
pub const CLOCK_ID_EMMC2: u32 = 12;
pub const CLOCK_ID_ARM: u32 = 3;
pub const DEVICE_ID_SD_CARD: u32 = 0;
pub const DEVICE_ID_USB_HCD: u32 = 3;
pub const POWER_STATE_OFF: u32 = 0;
pub const POWER_STATE_ON: u32 = 1;
pub const POWER_STATE_WAIT: u32 = 2;
pub const POWER_STATE_NO_DEVICE: u32 = 2;
pub const EXP_GPIO_BASE: u32 = 128;
pub const EXP_GPIO_SD_1V8: u32 = EXP_GPIO_BASE + 4;

const CODE_REQUEST: u32 = 0;
const CODE_RESPONSE_OK: u32 = 0x8000_0000;

pub type Msg = [u32; 8];

fn build(tag: u32, value0: u32, value1: u32) -> Msg {
    [
        core::mem::size_of::<Msg>() as u32,
        CODE_REQUEST,
        tag,
        8,
        CODE_REQUEST,
        value0,
        value1,
        0,
    ]
}

pub fn build_get_clock_rate(clock_id: u32) -> Msg {
    build(TAG_GET_CLOCK_RATE, clock_id, 0)
}

pub fn build_set_gpio_state(gpio: u32, state: u32) -> Msg {
    build(TAG_SET_GPIO_STATE, gpio, state)
}

pub fn build_set_power_state(device_id: u32, state: u32) -> Msg {
    build(TAG_SET_POWER_STATE, device_id, state)
}

pub fn build_get_temperature(temp_id: u32) -> Msg {
    build(TAG_GET_TEMPERATURE, temp_id, 0)
}

pub fn check_response(message: &Msg) -> bool {
    message[1] == CODE_RESPONSE_OK
}

pub fn parse_clock_rate(message: &Msg, clock_id: u32) -> Option<u32> {
    if !check_response(message) || message[5] != clock_id || message[6] == 0 {
        return None;
    }
    Some(message[6])
}

pub fn parse_temperature(message: &Msg, temp_id: u32) -> Option<u32> {
    if !check_response(message) || message[5] != temp_id || message[6] == 0 {
        return None;
    }
    Some(message[6])
}

pub fn parse_power_state(message: &Msg, device_id: u32, want_on: bool) -> bool {
    check_response(message)
        && message[5] == device_id
        && message[6] & POWER_STATE_NO_DEVICE == 0
        && (!want_on || message[6] & POWER_STATE_ON != 0)
}

pub const fn doorbell(buffer_address: u32, channel: u32) -> u32 {
    (buffer_address & !0xf) | (channel & 0xf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_clock_rate_request_is_exact() {
        assert_eq!(
            build_get_clock_rate(CLOCK_ID_EMMC2),
            [32, 0, TAG_GET_CLOCK_RATE, 8, 0, 12, 0, 0]
        );
    }

    #[test]
    fn set_gpio_state_request_is_exact() {
        assert_eq!(
            build_set_gpio_state(EXP_GPIO_SD_1V8, 0),
            [32, 0, TAG_SET_GPIO_STATE, 8, 0, 132, 0, 0]
        );
    }

    #[test]
    fn response_check_accepts_only_the_success_code() {
        let mut message = build_set_gpio_state(EXP_GPIO_SD_1V8, 0);
        assert!(!check_response(&message));
        message[1] = CODE_RESPONSE_OK;
        assert!(check_response(&message));
    }

    #[test]
    fn clock_rate_parses_a_well_formed_response() {
        let mut message = build_get_clock_rate(CLOCK_ID_EMMC2);
        message[1] = CODE_RESPONSE_OK;
        message[4] = 0x8000_0008;
        message[6] = 100_000_000;
        assert_eq!(
            parse_clock_rate(&message, CLOCK_ID_EMMC2),
            Some(100_000_000)
        );
    }

    #[test]
    fn clock_rate_rejects_a_missing_success_code() {
        let mut message = build_get_clock_rate(CLOCK_ID_EMMC2);
        message[6] = 100_000_000;
        assert_eq!(parse_clock_rate(&message, CLOCK_ID_EMMC2), None);
    }

    #[test]
    fn clock_rate_rejects_an_id_mismatch() {
        let mut message = build_get_clock_rate(CLOCK_ID_EMMC2);
        message[1] = CODE_RESPONSE_OK;
        message[5] = 1;
        message[6] = 100_000_000;
        assert_eq!(parse_clock_rate(&message, CLOCK_ID_EMMC2), None);
    }

    #[test]
    fn clock_rate_rejects_zero() {
        let mut message = build_get_clock_rate(CLOCK_ID_EMMC2);
        message[1] = CODE_RESPONSE_OK;
        assert_eq!(parse_clock_rate(&message, CLOCK_ID_EMMC2), None);
    }

    #[test]
    fn doorbell_replaces_the_low_nibble_with_the_channel() {
        assert_eq!(doorbell(0x0008_1210, CHANNEL_PROP), 0x0008_1218);
        assert_eq!(doorbell(0x0010_000f, CHANNEL_PROP), 0x0010_0008);
    }

    #[test]
    fn sd_card_power_on_request_is_exact() {
        assert_eq!(
            build_set_power_state(DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT),
            [32, 0, TAG_SET_POWER_STATE, 8, 0, 0, 3, 0]
        );
    }

    #[test]
    fn usb_hcd_power_on_request_carries_the_device_and_state() {
        let message = build_set_power_state(DEVICE_ID_USB_HCD, POWER_STATE_ON | POWER_STATE_WAIT);
        assert_eq!(message[5], 3);
        assert_eq!(message[6], 3);
    }

    #[test]
    fn power_state_accepts_a_well_formed_on_response() {
        let mut message =
            build_set_power_state(DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT);
        message[1] = CODE_RESPONSE_OK;
        message[6] = POWER_STATE_ON;
        assert!(parse_power_state(&message, DEVICE_ID_SD_CARD, true));
    }

    #[test]
    fn power_state_rejects_no_device() {
        let mut message =
            build_set_power_state(DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT);
        message[1] = CODE_RESPONSE_OK;
        message[6] = POWER_STATE_NO_DEVICE;
        assert!(!parse_power_state(&message, DEVICE_ID_SD_CARD, true));
    }

    #[test]
    fn power_state_rejects_a_rail_that_did_not_turn_on() {
        let mut message =
            build_set_power_state(DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT);
        message[1] = CODE_RESPONSE_OK;
        message[6] = POWER_STATE_OFF;
        assert!(!parse_power_state(&message, DEVICE_ID_SD_CARD, true));
    }

    #[test]
    fn power_state_rejects_an_id_mismatch() {
        let mut message =
            build_set_power_state(DEVICE_ID_SD_CARD, POWER_STATE_ON | POWER_STATE_WAIT);
        message[1] = CODE_RESPONSE_OK;
        message[5] = 7;
        message[6] = POWER_STATE_ON;
        assert!(!parse_power_state(&message, DEVICE_ID_SD_CARD, true));
    }

    #[test]
    fn get_temperature_request_is_exact() {
        assert_eq!(
            build_get_temperature(0),
            [32, 0, TAG_GET_TEMPERATURE, 8, 0, 0, 0, 0]
        );
    }

    #[test]
    fn temperature_parses_a_well_formed_response() {
        let mut message = build_get_temperature(0);
        message[1] = CODE_RESPONSE_OK;
        message[4] = 0x8000_0008;
        message[6] = 47_233;
        assert_eq!(parse_temperature(&message, 0), Some(47_233));
    }

    #[test]
    fn temperature_rejects_a_missing_success_code() {
        let mut message = build_get_temperature(0);
        message[6] = 47_233;
        assert_eq!(parse_temperature(&message, 0), None);
    }

    #[test]
    fn temperature_rejects_an_id_mismatch() {
        let mut message = build_get_temperature(0);
        message[1] = CODE_RESPONSE_OK;
        message[5] = 1;
        message[6] = 47_233;
        assert_eq!(parse_temperature(&message, 0), None);
    }

    #[test]
    fn temperature_rejects_zero() {
        let mut message = build_get_temperature(0);
        message[1] = CODE_RESPONSE_OK;
        assert_eq!(parse_temperature(&message, 0), None);
    }
}
