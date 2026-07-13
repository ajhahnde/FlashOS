//! Clear + key/value line helpers.
//!
//! FlashOS is shell-first: the shell is the primary interface, and the few tools
//! that take over the whole screen -- the pager, the editor -- drive the alternate
//! screen through the flibc io seam. What stays here is the small,
//! non-full-screen line layer the one-shot status tools use: [`clear`] wipes the
//! screen, [`kv`] prints an aligned `key   value` metric row. Both are plain
//! ANSI/text over the serial console -- there is no framebuffer.

use crate::Sink;

/// Clear the screen and home the cursor without touching the buffer stack.
pub fn clear(sink: Sink) {
    sink(b"\x1b[H\x1b[2J");
}

/// Column the value starts at in a [`kv`] row. Eight fits `CPU`/`MEM`/`UP`/`USER`
/// with a margin; a longer key gets a single trailing space instead.
pub const KV_COL: usize = 8;

/// A `key      value` metric row + newline -- the renderer sysinfo and the status
/// tools use for each line. The key is padded to [`KV_COL`]; an over-long key
/// falls back to a single space so the value never collides.
pub fn kv(sink: Sink, key: &[u8], value: &[u8]) {
    sink(key);
    let pad = if key.len() < KV_COL {
        KV_COL - key.len()
    } else {
        1
    };
    repeat(sink, b" ", pad);
    sink(value);
    sink(b"\n");
}

/// Emit `s` `n` times.
fn repeat(sink: Sink, s: &[u8], n: usize) {
    for _ in 0..n {
        sink(s);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{cap_reset, cap_sink, captured};

    #[test]
    fn kv_pads_a_short_key_to_kv_col() {
        cap_reset();
        kv(cap_sink, b"CPU", b"1.50 GHz");
        assert_eq!(captured(), b"CPU     1.50 GHz\n".to_vec());
    }

    #[test]
    fn kv_falls_back_to_a_single_space_for_an_over_long_key() {
        cap_reset();
        kv(cap_sink, b"LONGKEYNAME", b"v");
        assert_eq!(captured(), b"LONGKEYNAME v\n".to_vec());
    }

    #[test]
    fn clear_emits_the_home_plus_erase_sequence() {
        cap_reset();
        clear(cap_sink);
        assert_eq!(captured(), b"\x1b[H\x1b[2J".to_vec());
    }
}
