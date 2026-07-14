//! SDHCI command construction, CSD-v2 parsing, and clock-divider arithmetic.
//!
//! The rpi4b EMMC2 driver owns MMIO, command completion, and PIO transfers.
//! This module owns only the controller bit layouts and pure response parsing.

/// Hardware response shape encoded in CMD_RSPNS_TYPE.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum CmdResp {
    None,
    R1,
    R1b,
    R2,
    R3,
}

#[derive(Clone, Copy)]
#[repr(u8)]
pub enum CmdDir {
    Write = 0,
    Read = 1,
}

/// Encode the BCM2711 EMMC2 CMDTM register pair.
///
/// CMD_IXCHK_EN deliberately stays clear: BCM-family controllers can drop
/// responses when index checking is enabled instead of reporting an error.
pub const fn encode(idx: u8, resp: CmdResp, is_data: bool, dir: CmdDir) -> u32 {
    let response_type = match resp {
        CmdResp::None => 0,
        CmdResp::R2 => 1,
        CmdResp::R1 | CmdResp::R3 => 2,
        CmdResp::R1b => 3,
    };
    let mut value = response_type << 16;
    let crc_check = match resp {
        CmdResp::R1 | CmdResp::R1b | CmdResp::R2 => true,
        CmdResp::None | CmdResp::R3 => false,
    };
    if crc_check {
        value |= 1 << 19;
    }
    if is_data {
        value |= 1 << 21;
    }
    value |= (idx as u32) << 24;
    if is_data {
        value |= 1 << 1;
        value |= (dir as u32) << 4;
    }
    value
}

pub const CMD0_GO_IDLE: u32 = encode(0, CmdResp::None, false, CmdDir::Write);
pub const CMD2_ALL_SEND_CID: u32 = encode(2, CmdResp::R2, false, CmdDir::Write);
pub const CMD3_SEND_REL_ADDR: u32 = encode(3, CmdResp::R1, false, CmdDir::Write);
pub const CMD7_SELECT_CARD: u32 = encode(7, CmdResp::R1b, false, CmdDir::Write);
pub const CMD8_SEND_IF_COND: u32 = encode(8, CmdResp::R1, false, CmdDir::Write);
pub const CMD9_SEND_CSD: u32 = encode(9, CmdResp::R2, false, CmdDir::Write);
pub const CMD17_READ_SINGLE: u32 = encode(17, CmdResp::R1, true, CmdDir::Read);
pub const CMD24_WRITE_SINGLE: u32 = encode(24, CmdResp::R1, true, CmdDir::Write);
pub const CMD55_APP_CMD: u32 = encode(55, CmdResp::R1, false, CmdDir::Write);
pub const ACMD41_SD_SEND_OP_COND: u32 = encode(41, CmdResp::R3, false, CmdDir::Write);

/// VHS=1 (2.7-3.6 V supplied) plus check pattern 0xAA.
pub const CMD8_ARG_VHS_27_36_CHECK_AA: u32 = 0x0000_01aa;

/// HCS plus the 3.0-3.4 V OCR window; XPC and S18R stay clear.
pub const ACMD41_ARG_HCS_AND_VOLT: u32 = 0x40ff_8000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Csd {
    pub capacity_blocks: u64,
}

/// Parse an SDHC/SDXC CSD v2 response from BCM2711 RESP0..RESP3 words.
pub fn parse_csd_v2(response: [u32; 4]) -> Option<Csd> {
    let csd_structure = (response[3] >> 22) & 0x3;
    if csd_structure != 1 {
        return None;
    }
    let c_size_low = (response[1] >> 16) & 0x3f;
    let c_size_high = (response[2] & 0xffff) << 6;
    let c_size = c_size_low | c_size_high;
    Some(Csd {
        capacity_blocks: (u64::from(c_size) + 1) * 1024,
    })
}

/// Return the smallest power-of-two divisor that does not exceed the target
/// card clock, clamped to the largest power of two accepted by CONTROL1.
pub fn clock_divisor(base_hz: u32, target_hz: u32) -> u32 {
    if base_hz == 0 || target_hz == 0 {
        return 1;
    }
    let denominator = 2 * u64::from(target_hz);
    // Keep the source algorithm's exact arithmetic during the literal port.
    #[allow(clippy::manual_div_ceil)]
    let minimum = (u64::from(base_hz) + denominator - 1) / denominator;
    let mut divisor = 1;
    while u64::from(divisor) < minimum && divisor < 512 {
        divisor <<= 1;
    }
    divisor
}

/// Pack a 10-bit divisor into CONTROL1's split frequency-select field.
pub const fn control1_clock_bits(divisor: u32) -> u32 {
    let low = (divisor & 0xff) << 8;
    let high = ((divisor >> 8) & 0x3) << 6;
    low | high
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cmd0_go_idle_is_all_zero() {
        assert_eq!(CMD0_GO_IDLE, 0);
    }

    #[test]
    fn cmd17_encodes_read_single_block() {
        let value = CMD17_READ_SINGLE;
        assert_eq!((value >> 24) & 0x3f, 17);
        assert_eq!((value >> 16) & 0x3, 2);
        assert_ne!(value & (1 << 19), 0);
        assert_eq!(value & (1 << 20), 0);
        assert_ne!(value & (1 << 21), 0);
        assert_ne!(value & (1 << 1), 0);
        assert_eq!((value >> 4) & 1, 1);
    }

    #[test]
    fn cmd24_encodes_write_single_block() {
        let value = CMD24_WRITE_SINGLE;
        assert_eq!((value >> 24) & 0x3f, 24);
        assert_ne!(value & (1 << 19), 0);
        assert_eq!(value & (1 << 20), 0);
        assert_ne!(value & (1 << 21), 0);
        assert_eq!((value >> 4) & 1, 0);
    }

    #[test]
    fn cmd8_encodes_r7_shape_without_data() {
        let value = CMD8_SEND_IF_COND;
        assert_eq!((value >> 24) & 0x3f, 8);
        assert_eq!((value >> 16) & 0x3, 2);
        assert_ne!(value & (1 << 19), 0);
        assert_eq!(value & (1 << 20), 0);
        assert_eq!(value & (1 << 21), 0);
    }

    #[test]
    fn cmd7_encodes_busy_response() {
        let value = CMD7_SELECT_CARD;
        assert_eq!((value >> 24) & 0x3f, 7);
        assert_eq!((value >> 16) & 0x3, 3);
        assert_ne!(value & (1 << 19), 0);
        assert_eq!(value & (1 << 20), 0);
    }

    #[test]
    fn cmd55_encodes_app_command_index() {
        assert_eq!((CMD55_APP_CMD >> 24) & 0x3f, 55);
    }

    #[test]
    fn acmd41_encodes_r3_without_checks() {
        let value = ACMD41_SD_SEND_OP_COND;
        assert_eq!((value >> 24) & 0x3f, 41);
        assert_eq!((value >> 16) & 0x3, 2);
        assert_eq!(value & (1 << 19), 0);
        assert_eq!(value & (1 << 20), 0);
    }

    #[test]
    fn cmd2_encodes_r2_for_cid() {
        let value = CMD2_ALL_SEND_CID;
        assert_eq!((value >> 24) & 0x3f, 2);
        assert_eq!((value >> 16) & 0x3, 1);
        assert_ne!(value & (1 << 19), 0);
        assert_eq!(value & (1 << 20), 0);
        assert_eq!(value & (1 << 21), 0);
    }

    #[test]
    fn csd_v2_decodes_c_size_7647() {
        let mut response = [0; 4];
        response[3] = 1 << 22;
        response[1] = 0x1f << 16;
        response[2] = 0x77;
        assert_eq!(
            parse_csd_v2(response),
            Some(Csd {
                capacity_blocks: (7647 + 1) * 1024,
            })
        );
    }

    #[test]
    fn csd_v2_rejects_v1_structure() {
        assert_eq!(parse_csd_v2([0; 4]), None);
    }

    #[test]
    fn clock_divisor_rounds_up_to_power_of_two() {
        assert_eq!(clock_divisor(100_000_000, 400_000), 128);
        assert_eq!(clock_divisor(200_000_000, 400_000), 256);
        assert_eq!(clock_divisor(100_000_000, 25_000_000), 2);
    }

    #[test]
    fn clock_divisor_stays_inside_controller_range() {
        assert_eq!(clock_divisor(0, 400_000), 1);
        assert_eq!(clock_divisor(100_000_000, 400_000_000), 1);
        assert_eq!(clock_divisor(4_000_000_000, 1), 512);
    }

    #[test]
    fn control1_clock_bits_split_the_divisor() {
        assert_eq!(control1_clock_bits(250), 0xfa00);
        assert_eq!(control1_clock_bits(0x2a8), 0xa880);
    }
}
