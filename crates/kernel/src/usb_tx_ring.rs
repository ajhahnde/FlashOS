//! Bounded byte ring for the DWC2 CDC-ACM bulk-IN path.

#[derive(Clone)]
#[repr(C)]
pub struct ByteRing<const SIZE: usize> {
    pub bytes: [u8; SIZE],
    pub head: u64,
    pub tail: u64,
}

impl<const SIZE: usize> Default for ByteRing<SIZE> {
    fn default() -> Self {
        Self::new()
    }
}

impl<const SIZE: usize> ByteRing<SIZE> {
    pub const fn new() -> Self {
        Self {
            bytes: [0; SIZE],
            head: 0,
            tail: 0,
        }
    }
    pub const fn available(&self) -> u64 {
        self.head.wrapping_sub(self.tail)
    }
    pub const fn is_full(&self) -> bool {
        self.available() >= SIZE as u64
    }

    pub fn push(&mut self, byte: u8) -> bool {
        if self.is_full() {
            return false;
        }
        self.bytes[(self.head % SIZE as u64) as usize] = byte;
        self.head = self.head.wrapping_add(1);
        true
    }

    pub fn peek(&self, destination: &mut [u8]) -> usize {
        let count = core::cmp::min(self.available() as usize, destination.len());
        let mut index = 0;
        while index < count {
            destination[index] =
                self.bytes[(self.tail.wrapping_add(index as u64) % SIZE as u64) as usize];
            index += 1;
        }
        count
    }

    pub fn advance(&mut self, count: u64) {
        self.tail = self.tail.wrapping_add(count);
    }
    pub fn clear(&mut self) {
        self.head = 0;
        self.tail = 0;
    }
}

pub type UsbTxRing = ByteRing<512>;
const _: () =
    assert!(core::mem::size_of::<UsbTxRing>() == 528 && core::mem::align_of::<UsbTxRing>() == 8);

#[cfg(test)]
mod tests {
    use super::*;
    type Ring = ByteRing<8>;

    #[test]
    fn round_trip_preserves_order() {
        let mut ring = Ring::new();
        assert_eq!(ring.available(), 0);
        assert!(ring.push(0xaa));
        assert!(ring.push(0xbb));
        assert!(ring.push(0xcc));
        let mut output = [0; 8];
        assert_eq!(ring.peek(&mut output), 3);
        assert_eq!(&output[..3], &[0xaa, 0xbb, 0xcc]);
        assert_eq!(ring.available(), 3);
        ring.advance(3);
        assert_eq!(ring.available(), 0);
    }

    #[test]
    fn full_ring_rejects_without_overwrite() {
        let mut ring = Ring::new();
        for byte in 0..8 {
            assert!(ring.push(byte));
        }
        assert!(ring.is_full());
        assert!(!ring.push(0xff));
        assert_eq!(ring.available(), 8);
        let mut output = [0; 8];
        ring.peek(&mut output);
        assert_eq!(output, [0, 1, 2, 3, 4, 5, 6, 7]);
    }

    #[test]
    fn peek_clamps_to_destination_and_available() {
        let mut ring = Ring::new();
        ring.push(1);
        ring.push(2);
        let mut small = [0];
        assert_eq!(ring.peek(&mut small), 1);
        assert_eq!(small[0], 1);
        let mut large = [0; 8];
        assert_eq!(ring.peek(&mut large), 2);
    }

    #[test]
    fn ring_wraps_across_modulo_boundary() {
        let mut ring = Ring::new();
        for byte in 0..8 {
            ring.push(byte);
        }
        ring.advance(5);
        for byte in 100..105 {
            assert!(ring.push(byte));
        }
        assert_eq!(ring.available(), 8);
        let mut output = [0; 8];
        ring.peek(&mut output);
        assert_eq!(output, [5, 6, 7, 100, 101, 102, 103, 104]);
    }

    #[test]
    fn partial_advance_leaves_tail() {
        let mut ring = Ring::new();
        for byte in 0xd0..0xd6 {
            ring.push(byte);
        }
        let mut chunk = [0; 4];
        assert_eq!(ring.peek(&mut chunk), 4);
        ring.advance(4);
        let mut rest = [0; 8];
        assert_eq!(ring.peek(&mut rest), 2);
        assert_eq!(&rest[..2], &[0xd4, 0xd5]);
    }

    #[test]
    fn clear_drops_all_and_ring_is_reusable() {
        let mut ring = Ring::new();
        ring.push(1);
        ring.push(2);
        ring.advance(1);
        ring.clear();
        assert_eq!(ring.available(), 0);
        assert!(!ring.is_full());
        assert!(ring.push(9));
        assert_eq!(ring.available(), 1);
    }

    #[test]
    fn counters_preserve_order_across_u64_wrap() {
        let mut ring = Ring::new();
        ring.head = u64::MAX - 2;
        ring.tail = u64::MAX - 2;
        assert!(ring.push(0x11));
        assert!(ring.push(0x22));
        assert!(ring.push(0x33));
        assert_eq!(ring.available(), 3);
        let mut output = [0; 8];
        assert_eq!(ring.peek(&mut output), 3);
        assert_eq!((output[0], output[2]), (0x11, 0x33));
    }
}
