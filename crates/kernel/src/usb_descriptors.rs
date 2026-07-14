//! Byte-exact USB CDC-ACM descriptors and SETUP-packet decoding.

pub const DESC_DEVICE: u8 = 1;
pub const DESC_CONFIG: u8 = 2;
pub const DESC_STRING: u8 = 3;
pub const DESC_INTERFACE: u8 = 4;
pub const DESC_ENDPOINT: u8 = 5;
pub const DESC_DEVICE_QUALIFIER: u8 = 6;
pub const DESC_OTHER_SPEED: u8 = 7;
pub const CS_INTERFACE: u8 = 0x24;

pub const REQ_GET_STATUS: u8 = 0x00;
pub const REQ_CLEAR_FEATURE: u8 = 0x01;
pub const REQ_SET_FEATURE: u8 = 0x03;
pub const REQ_SET_ADDRESS: u8 = 0x05;
pub const REQ_GET_DESCRIPTOR: u8 = 0x06;
pub const REQ_SET_DESCRIPTOR: u8 = 0x07;
pub const REQ_GET_CONFIGURATION: u8 = 0x08;
pub const REQ_SET_CONFIGURATION: u8 = 0x09;
pub const REQ_SET_LINE_CODING: u8 = 0x20;
pub const REQ_GET_LINE_CODING: u8 = 0x21;
pub const REQ_SET_CONTROL_LINE_STATE: u8 = 0x22;
pub const REQ_SEND_BREAK: u8 = 0x23;

pub const VID: u16 = 0x1209;
pub const PID: u16 = 0x0001;
pub const EP0_MPS: u16 = 64;
pub const LINE_CODING_DEFAULT: [u8; 7] = [0x00, 0xc2, 0x01, 0, 0, 0, 8];

pub static DEVICE_DESCRIPTOR: [u8; 18] = [
    0x12,
    DESC_DEVICE,
    0x00,
    0x02,
    0x02,
    0x00,
    0x00,
    0x40,
    0x09,
    0x12,
    0x01,
    0x00,
    0x00,
    0x01,
    0x01,
    0x02,
    0x03,
    0x01,
];

pub static CONFIG_DESCRIPTOR: [u8; 67] = [
    0x09,
    DESC_CONFIG,
    0x43,
    0x00,
    0x02,
    0x01,
    0x00,
    0x80,
    0x32,
    0x09,
    DESC_INTERFACE,
    0x00,
    0x00,
    0x01,
    0x02,
    0x02,
    0x01,
    0x00,
    0x05,
    CS_INTERFACE,
    0x00,
    0x10,
    0x01,
    0x05,
    CS_INTERFACE,
    0x01,
    0x00,
    0x01,
    0x04,
    CS_INTERFACE,
    0x02,
    0x02,
    0x05,
    CS_INTERFACE,
    0x06,
    0x00,
    0x01,
    0x07,
    DESC_ENDPOINT,
    0x81,
    0x03,
    0x10,
    0x00,
    0x10,
    0x09,
    DESC_INTERFACE,
    0x01,
    0x00,
    0x02,
    0x0a,
    0x00,
    0x00,
    0x00,
    0x07,
    DESC_ENDPOINT,
    0x02,
    0x02,
    0x40,
    0x00,
    0x00,
    0x07,
    DESC_ENDPOINT,
    0x82,
    0x02,
    0x40,
    0x00,
    0x00,
];

pub static STR_LANGID: [u8; 4] = [0x04, DESC_STRING, 0x09, 0x04];
pub static STR_MANUFACTURER: [u8; 16] = [
    16,
    DESC_STRING,
    b'F',
    0,
    b'l',
    0,
    b'a',
    0,
    b's',
    0,
    b'h',
    0,
    b'O',
    0,
    b'S',
    0,
];
pub static STR_PRODUCT: [u8; 30] = [
    30,
    DESC_STRING,
    b'F',
    0,
    b'l',
    0,
    b'a',
    0,
    b's',
    0,
    b'h',
    0,
    b'O',
    0,
    b'S',
    0,
    b' ',
    0,
    b'S',
    0,
    b'e',
    0,
    b'r',
    0,
    b'i',
    0,
    b'a',
    0,
    b'l',
    0,
];
pub static STR_SERIAL: [u8; 10] = [10, DESC_STRING, b'0', 0, b'0', 0, b'0', 0, b'1', 0];

pub fn get_descriptor(descriptor_type: u8, index: u8) -> Option<&'static [u8]> {
    match descriptor_type {
        DESC_DEVICE => Some(&DEVICE_DESCRIPTOR),
        DESC_CONFIG => Some(&CONFIG_DESCRIPTOR),
        DESC_STRING => match index {
            0 => Some(&STR_LANGID),
            1 => Some(&STR_MANUFACTURER),
            2 => Some(&STR_PRODUCT),
            3 => Some(&STR_SERIAL),
            _ => None,
        },
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Setup {
    pub bm_request_type: u8,
    pub request: u8,
    pub value: u16,
    pub index: u16,
    pub length: u16,
}

impl Setup {
    pub const fn descriptor_type(self) -> u8 {
        (self.value >> 8) as u8
    }
    pub const fn descriptor_index(self) -> u8 {
        self.value as u8
    }
    pub const fn address(self) -> u8 {
        (self.value & 0x7f) as u8
    }
}

pub const fn decode_setup(raw: [u8; 8]) -> Setup {
    Setup {
        bm_request_type: raw[0],
        request: raw[1],
        value: u16::from_le_bytes([raw[2], raw[3]]),
        index: u16::from_le_bytes([raw[4], raw[5]]),
        length: u16::from_le_bytes([raw[6], raw[7]]),
    }
}

const _: () = assert!(core::mem::size_of::<Setup>() == 8 && core::mem::align_of::<Setup>() == 2);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_descriptor_is_byte_exact() {
        assert_eq!(DEVICE_DESCRIPTOR.len(), 18);
        assert_eq!(
            &DEVICE_DESCRIPTOR[..8],
            &[18, DESC_DEVICE, 0, 2, 2, 0, 0, 64]
        );
        assert_eq!(&DEVICE_DESCRIPTOR[8..12], &[0x09, 0x12, 1, 0]);
        assert_eq!(DEVICE_DESCRIPTOR[17], 1);
    }

    #[test]
    fn config_descriptor_is_byte_exact() {
        assert_eq!(CONFIG_DESCRIPTOR.len(), 67);
        assert_eq!(&CONFIG_DESCRIPTOR[..6], &[9, DESC_CONFIG, 0x43, 0, 2, 1]);
        assert_eq!(&CONFIG_DESCRIPTOR[10..16], &[DESC_INTERFACE, 0, 0, 1, 2, 2]);
        assert_eq!(&CONFIG_DESCRIPTOR[38..41], &[DESC_ENDPOINT, 0x81, 3]);
        assert_eq!(CONFIG_DESCRIPTOR[49], 0x0a);
        assert_eq!(&CONFIG_DESCRIPTOR[55..58], &[2, 2, 0x40]);
        assert_eq!(&CONFIG_DESCRIPTOR[62..65], &[0x82, 2, 0x40]);
    }

    #[test]
    fn union_descriptor_links_communications_to_data() {
        assert_eq!(&CONFIG_DESCRIPTOR[32..37], &[5, CS_INTERFACE, 6, 0, 1]);
        assert_eq!(CONFIG_DESCRIPTOR[25], 1);
        assert_eq!(CONFIG_DESCRIPTOR[27], 1);
    }

    #[test]
    fn langid_descriptor_is_exact() {
        assert_eq!(STR_LANGID, [4, 3, 9, 4]);
    }

    #[test]
    fn resolver_serves_known_descriptors_and_stalls_unknown() {
        assert!(get_descriptor(DESC_DEVICE, 0).is_some());
        assert_eq!(get_descriptor(DESC_CONFIG, 0).unwrap().len(), 67);
        assert_eq!(get_descriptor(DESC_STRING, 0).unwrap().len(), 4);
        assert!(get_descriptor(DESC_STRING, 1).is_some());
        assert!(get_descriptor(DESC_STRING, 9).is_none());
        assert!(get_descriptor(DESC_DEVICE_QUALIFIER, 0).is_none());
        assert!(get_descriptor(DESC_OTHER_SPEED, 0).is_none());
    }

    #[test]
    fn string_descriptors_are_utf16le_with_correct_lengths() {
        assert_eq!(&STR_MANUFACTURER[..5], &[16, DESC_STRING, b'F', 0, b'l']);
        assert_eq!(STR_SERIAL[0], 10);
    }

    #[test]
    fn line_coding_is_115200_8n1() {
        assert_eq!(LINE_CODING_DEFAULT, [0, 0xc2, 1, 0, 0, 0, 8]);
    }

    #[test]
    fn decode_get_descriptor_device() {
        let setup = decode_setup([0x80, 6, 0, 1, 0, 0, 64, 0]);
        assert_eq!(
            (setup.bm_request_type, setup.request, setup.value),
            (0x80, REQ_GET_DESCRIPTOR, 0x100)
        );
        assert_eq!(
            (
                setup.descriptor_type(),
                setup.descriptor_index(),
                setup.length
            ),
            (DESC_DEVICE, 0, 64)
        );
    }

    #[test]
    fn decode_set_address_masks_to_seven_bits() {
        let setup = decode_setup([0, 5, 0xeb, 0, 0, 0, 0, 0]);
        assert_eq!(setup.request, REQ_SET_ADDRESS);
        assert_eq!(setup.address(), 0x6b);
    }

    #[test]
    fn decode_set_configuration() {
        let setup = decode_setup([0, 9, 1, 0, 0, 0, 0, 0]);
        assert_eq!((setup.request, setup.value), (REQ_SET_CONFIGURATION, 1));
    }

    #[test]
    fn decode_set_line_coding() {
        let setup = decode_setup([0x21, 0x20, 0, 0, 0, 0, 7, 0]);
        assert_eq!(
            (setup.bm_request_type, setup.request, setup.length),
            (0x21, REQ_SET_LINE_CODING, 7)
        );
    }

    #[test]
    fn descriptor_length_chain_matches_total_length() {
        let mut cursor = 0;
        while cursor < CONFIG_DESCRIPTOR.len() {
            assert_ne!(CONFIG_DESCRIPTOR[cursor], 0);
            cursor += usize::from(CONFIG_DESCRIPTOR[cursor]);
        }
        assert_eq!(cursor, 67);
        assert_eq!(
            u16::from_le_bytes([CONFIG_DESCRIPTOR[2], CONFIG_DESCRIPTOR[3]]),
            67
        );
    }

    #[test]
    fn served_config_length_matches_total_length() {
        let descriptor = get_descriptor(DESC_CONFIG, 0).unwrap();
        assert_eq!(descriptor.len(), 67);
        assert_eq!(
            u16::from_le_bytes([descriptor[2], descriptor[3]]) as usize,
            descriptor.len()
        );
    }

    #[test]
    fn descriptor_type_and_index_split_value() {
        let config = decode_setup([0x80, 6, 0, 2, 0, 0, 0xff, 0]);
        assert_eq!(
            (config.descriptor_type(), config.descriptor_index()),
            (DESC_CONFIG, 0)
        );
        let string = decode_setup([0x80, 6, 3, 3, 9, 4, 0xff, 0]);
        assert_eq!(
            (string.descriptor_type(), string.descriptor_index()),
            (DESC_STRING, 3)
        );
    }

    #[test]
    fn decode_set_control_line_state() {
        let setup = decode_setup([0x21, 0x22, 3, 0, 0, 0, 0, 0]);
        assert_eq!(
            (
                setup.bm_request_type,
                setup.request,
                setup.value,
                setup.length
            ),
            (0x21, REQ_SET_CONTROL_LINE_STATE, 3, 0)
        );
    }

    #[test]
    fn decode_remaining_standard_requests() {
        assert_eq!(
            decode_setup([0x80, 8, 0, 0, 0, 0, 1, 0]).request,
            REQ_GET_CONFIGURATION
        );
        assert_eq!(
            decode_setup([0x80, 0, 0, 0, 0, 0, 2, 0]).request,
            REQ_GET_STATUS
        );
        let clear = decode_setup([2, 1, 0, 0, 0x82, 0, 0, 0]);
        assert_eq!((clear.request, clear.index), (REQ_CLEAR_FEATURE, 0x82));
    }
}
