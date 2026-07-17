//! Pure AAPCS64 frame-pointer chain walker — the decode math behind the trace
//! sampler, factored out with no kernel dependencies so it can be host-tested
//! deterministically (the live timer sampler only fires on real hardware, where
//! async ticks interrupt the kernel).
//!
//! On AArch64 a standard frame record is two words at the frame pointer:
//!
//! ```text
//!   [fp + 0] = caller's frame pointer (the next link in the chain)
//!   [fp + 8] = the return address (saved LR) into the caller
//! ```
//!
//! `walk_chain` follows that chain, collecting the saved LRs, bounded by the
//! stack page and a set of guards that make a garbage pointer terminate the walk
//! instead of running off into unmapped memory:
//!
//! * fp must stay inside `[base, base + page)` with room for both words,
//! * fp must be 16-byte aligned (AAPCS64 requires it),
//! * the chain must climb monotonically (next > fp) — a stale or self-
//!   referential record stops the walk rather than looping forever,
//! * the caller-supplied `out` slice caps the depth.
//!
//! `mem` is a flat view of the stack page whose first byte is virtual address
//! `base`; reads go through the slice (not raw pointers) so the same code runs
//! unchanged on the host under test.

/// Read a little-endian `u64` from the front of `bytes`, or `None` if short.
///
/// The guards in `walk_chain` already prove both reads are in range; going
/// through `get` anyway keeps the walker free of a panic branch, which would
/// otherwise drag the formatting machinery into the kernel image.
fn read_u64(bytes: &[u8]) -> Option<u64> {
    let word: [u8; 8] = bytes.get(..8)?.try_into().ok()?;
    Some(u64::from_le_bytes(word))
}

/// Follow the frame-pointer chain starting at `start_fp`, writing each frame's
/// saved LR into `out`. Returns the number of LRs written.
pub fn walk_chain(mem: &[u8], base: u64, start_fp: u64, out: &mut [u64]) -> usize {
    let top = base.wrapping_add(mem.len() as u64);
    let mut fp = start_fp;
    let mut n = 0;

    while n < out.len()
        && fp >= base
        // Room for both words, computed wrap-safe: a near-u64-max fp must not
        // slip through by `fp + 16` wrapping past `top` (which would make
        // fp - base a giant offset and fault on the read). `fp <= top` first
        // keeps `top - fp` from underflowing.
        && fp <= top
        && top - fp >= 16
        && (fp & 0xF) == 0
    {
        let off = (fp - base) as usize;
        let Some(record) = mem.get(off..off + 16) else {
            break;
        };
        let (Some(lr), Some(next)) = (read_u64(&record[8..]), read_u64(record)) else {
            break;
        };
        out[n] = lr;
        n += 1; // count the frame we just decoded before any early-out
        if next <= fp {
            break; // monotonic guard: chain must climb the stack
        }
        fp = next; // a next that leaves the page ends the walk via the loop cond
    }
    n
}

#[cfg(test)]
mod tests {
    use super::walk_chain;

    /// Lay a frame record (caller-fp, saved-lr) into `mem` at virtual address
    /// `fp_va`, given the page base.
    fn put_frame(mem: &mut [u8], base: u64, fp_va: u64, next_fp: u64, lr: u64) {
        let off = (fp_va - base) as usize;
        mem[off..off + 8].copy_from_slice(&next_fp.to_le_bytes());
        mem[off + 8..off + 16].copy_from_slice(&lr.to_le_bytes());
    }

    #[test]
    fn walks_a_well_formed_three_deep_chain() {
        let base: u64 = 0x4000;
        let mut page = [0u8; 0x200];
        // Three frames climbing the stack: 0x4040 -> 0x4080 -> 0x40C0.
        put_frame(&mut page, base, 0x4040, 0x4080, 0xAAAA);
        put_frame(&mut page, base, 0x4080, 0x40C0, 0xBBBB);
        put_frame(&mut page, base, 0x40C0, base + 0x200, 0xCCCC); // next == top: walk ends
        let mut out = [0u64; 8];
        let n = walk_chain(&page, base, 0x4040, &mut out);
        assert_eq!(n, 3);
        assert_eq!(out[0], 0xAAAA);
        assert_eq!(out[1], 0xBBBB);
        assert_eq!(out[2], 0xCCCC);
    }

    #[test]
    fn stops_on_a_non_monotonic_link() {
        let base: u64 = 0x4000;
        let mut page = [0u8; 0x200];
        put_frame(&mut page, base, 0x4040, 0x4080, 0x1111);
        put_frame(&mut page, base, 0x4080, 0x4080, 0x2222); // points to itself -> stop
        let mut out = [0u64; 8];
        let n = walk_chain(&page, base, 0x4040, &mut out);
        assert_eq!(n, 2);
        assert_eq!(out[0], 0x1111);
        assert_eq!(out[1], 0x2222);
    }

    #[test]
    fn rejects_a_misaligned_start_fp_without_reading() {
        let base: u64 = 0x4000;
        let page = [0u8; 0x200];
        let mut out = [0u64; 8];
        assert_eq!(walk_chain(&page, base, 0x4044, &mut out), 0);
    }

    #[test]
    fn rejects_an_out_of_page_start_fp() {
        let base: u64 = 0x4000;
        let page = [0u8; 0x200];
        let mut out = [0u64; 8];
        // Below the page and flush against the top (no room for two words).
        assert_eq!(walk_chain(&page, base, 0x3000, &mut out), 0);
        assert_eq!(walk_chain(&page, base, base + 0x200 - 8, &mut out), 0);
    }

    #[test]
    fn rejects_a_wrapping_near_u64_max_start_fp_without_faulting() {
        let base: u64 = 0x4000;
        let page = [0u8; 0x200];
        let mut out = [0u64; 8];
        // fp is 16-aligned and within 16 of u64::MAX, so a naive `fp + 16 <= top`
        // guard wraps to ~0 and accepts it, then fp - base is a giant offset that
        // faults on the read. The wrap-safe bound must reject it outright.
        assert_eq!(walk_chain(&page, base, 0xFFFF_FFFF_FFFF_FFF0, &mut out), 0);
    }

    #[test]
    fn depth_is_capped_by_the_out_slice() {
        let base: u64 = 0x4000;
        let mut page = [0u8; 0x400];
        // A long climbing chain; only the first two should be captured.
        let mut fp: u64 = 0x4040;
        while fp + 0x40 < base + 0x400 {
            put_frame(&mut page, base, fp, fp + 0x40, fp); // lr = fp for easy checking
            fp += 0x40;
        }
        let mut out = [0u64; 2];
        let n = walk_chain(&page, base, 0x4040, &mut out);
        assert_eq!(n, 2);
        assert_eq!(out[0], 0x4040);
        assert_eq!(out[1], 0x4080);
    }
}
