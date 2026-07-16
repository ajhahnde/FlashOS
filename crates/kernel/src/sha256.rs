//! sha256: the kernel crypto unit — SHA-256, HMAC-SHA256, PBKDF2-HMAC-SHA256.
//!
//! Password-hashing primitives for FlashOS user authentication. The kernel
//! hashes and salts credentials itself (the KDF lives in one audited place);
//! userspace never needs these primitives, so this is an ordinary kernel
//! module, not an ABI-shared one.
//!
//! Pure compute — no MMIO, no externs, no allocation. Every working buffer is
//! caller-stack or value-returned, so calling any function here can never
//! perturb the free-page baseline the harness asserts. The tests at the bottom
//! gate the implementation against published vectors (NIST FIPS 180-2,
//! RFC 4231, the standard PBKDF2-HMAC-SHA256 set): a wrong round constant or a
//! flipped byte order is invisible at runtime — it would silently produce
//! stable-but-wrong hashes, which is an authentication bypass or a permanently
//! locked-out device. No consumer of these functions ships until the vector
//! tests pass.
//!
//! Implementation notes, deliberate choices:
//!
//!  - The incremental hasher (init/update/final) is the core; the one-shot
//!    helpers wrap it. Large inputs stream through a single 64-byte block
//!    buffer — nothing here ever needs a message-sized buffer.
//!  - Message words and the length field are assembled big-endian BY HAND
//!    (shifts + truncating casts). Getting this wrong is the classic
//!    silently-wrong-digest bug, which is exactly what the NIST vectors catch.
//!  - Block fills are explicit byte loops, never a bulk copy of a runtime
//!    length (project byte-loop discipline; see the FAT32 sub-sector write rule
//!    in DOCUMENTATION.md).
//!  - Addition is wrapping throughout the compression function: SHA-256 is
//!    defined over mod-2^32 arithmetic.

// ---- SHA-256 core (FIPS 180-4) ----

pub const DIGEST_LENGTH: usize = 32;
pub const BLOCK_LENGTH: usize = 64;

/// Initial hash state: the first 32 bits of the fractional parts of the square
/// roots of the first 8 primes.
const H0: [u32; 8] = [
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];

/// Round constants: the first 32 bits of the fractional parts of the cube roots
/// of the first 64 primes.
const K: [u32; 64] = [
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
];

/// One 64-byte block through the compression function, updating `state`.
fn compress(state: &mut [u32; 8], block: &[u8; 64]) {
    // Message schedule. w[0..16] are the block words read big-endian;
    // w[16..64] extend them.
    let mut w = [0u32; 64];
    let mut t = 0usize;
    while t < 16 {
        w[t] = ((block[t * 4] as u32) << 24)
            | ((block[t * 4 + 1] as u32) << 16)
            | ((block[t * 4 + 2] as u32) << 8)
            | (block[t * 4 + 3] as u32);
        t += 1;
    }
    while t < 64 {
        let s0 = w[t - 15].rotate_right(7) ^ w[t - 15].rotate_right(18) ^ (w[t - 15] >> 3);
        let s1 = w[t - 2].rotate_right(17) ^ w[t - 2].rotate_right(19) ^ (w[t - 2] >> 10);
        w[t] = w[t - 16]
            .wrapping_add(s0)
            .wrapping_add(w[t - 7])
            .wrapping_add(s1);
        t += 1;
    }

    let mut a = state[0];
    let mut b = state[1];
    let mut c = state[2];
    let mut d = state[3];
    let mut e = state[4];
    let mut f = state[5];
    let mut g = state[6];
    let mut h = state[7];

    let mut i = 0usize;
    while i < 64 {
        let sum1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let ch = (e & f) ^ (!e & g);
        let temp1 = h
            .wrapping_add(sum1)
            .wrapping_add(ch)
            .wrapping_add(K[i])
            .wrapping_add(w[i]);
        let sum0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
        let maj = (a & b) ^ (a & c) ^ (b & c);
        let temp2 = sum0.wrapping_add(maj);
        h = g;
        g = f;
        f = e;
        e = d.wrapping_add(temp1);
        d = c;
        c = b;
        b = a;
        a = temp1.wrapping_add(temp2);
        i += 1;
    }

    state[0] = state[0].wrapping_add(a);
    state[1] = state[1].wrapping_add(b);
    state[2] = state[2].wrapping_add(c);
    state[3] = state[3].wrapping_add(d);
    state[4] = state[4].wrapping_add(e);
    state[5] = state[5].wrapping_add(f);
    state[6] = state[6].wrapping_add(g);
    state[7] = state[7].wrapping_add(h);
}

/// Incremental SHA-256. Usage: `let mut h = Sha256::init(); h.update(..); ..;
/// let digest = h.final_digest();` — `final_digest` consumes the state (padding
/// is written into the block buffer); do not `update` after it.
#[derive(Clone, Copy)]
pub struct Sha256 {
    state: [u32; 8],
    block: [u8; 64],
    /// bytes pending in `block`, always < 64
    block_len: usize,
    /// total message bytes absorbed (for the length field)
    total_len: u64,
}

impl Sha256 {
    pub fn init() -> Sha256 {
        Sha256 {
            state: H0,
            block: [0u8; 64],
            block_len: 0,
            total_len: 0,
        }
    }

    pub fn update(&mut self, data: &[u8]) {
        // Byte loop into the block buffer; compress on every full block.
        let mut i = 0usize;
        while i < data.len() {
            self.block[self.block_len] = data[i];
            self.block_len += 1;
            if self.block_len == 64 {
                let mut state = self.state;
                compress(&mut state, &self.block);
                self.state = state;
                self.block_len = 0;
            }
            i += 1;
        }
        self.total_len = self.total_len.wrapping_add(data.len() as u64);
    }

    pub fn final_digest(&mut self) -> [u8; 32] {
        let bit_len: u64 = self.total_len.wrapping_mul(8);

        // Padding: a single 0x80 byte, zeros, then the 64-bit big-endian bit
        // length closing out a block.
        self.block[self.block_len] = 0x80;
        self.block_len += 1;
        if self.block_len > 56 {
            // No room for the length field — pad this block out first.
            while self.block_len < 64 {
                self.block[self.block_len] = 0;
                self.block_len += 1;
            }
            let mut state = self.state;
            compress(&mut state, &self.block);
            self.state = state;
            self.block_len = 0;
        }
        while self.block_len < 56 {
            self.block[self.block_len] = 0;
            self.block_len += 1;
        }
        self.block[56] = (bit_len >> 56) as u8;
        self.block[57] = (bit_len >> 48) as u8;
        self.block[58] = (bit_len >> 40) as u8;
        self.block[59] = (bit_len >> 32) as u8;
        self.block[60] = (bit_len >> 24) as u8;
        self.block[61] = (bit_len >> 16) as u8;
        self.block[62] = (bit_len >> 8) as u8;
        self.block[63] = bit_len as u8;
        let mut state = self.state;
        compress(&mut state, &self.block);
        self.state = state;

        // Serialize the state big-endian into the digest.
        let mut out = [0u8; 32];
        let mut k = 0usize;
        while k < 8 {
            out[k * 4] = (self.state[k] >> 24) as u8;
            out[k * 4 + 1] = (self.state[k] >> 16) as u8;
            out[k * 4 + 2] = (self.state[k] >> 8) as u8;
            out[k * 4 + 3] = self.state[k] as u8;
            k += 1;
        }
        out
    }
}

/// One-shot SHA-256.
pub fn sha256(msg: &[u8]) -> [u8; 32] {
    let mut h = Sha256::init();
    h.update(msg);
    h.final_digest()
}

// ---- HMAC-SHA256 (RFC 2104) ----

/// Keyed MAC with precomputed key pads: `init` absorbs (key ^ ipad) and
/// (key ^ opad) once, so every `mac` afterwards costs two compressions. That is
/// what makes PBKDF2's inner loop affordable — its iteration count times two
/// compressions is the whole cost.
#[derive(Clone, Copy)]
pub struct HmacSha256 {
    /// state after absorbing (key ^ ipad)
    inner_init: Sha256,
    /// state after absorbing (key ^ opad)
    outer_init: Sha256,
}

impl HmacSha256 {
    pub fn init(key: &[u8]) -> HmacSha256 {
        // Keys longer than the block are hashed first (RFC 2104); shorter keys
        // are zero-padded to the block length.
        let mut key_block = [0u8; 64];
        if key.len() > 64 {
            let kh = sha256(key);
            let mut i = 0usize;
            while i < 32 {
                key_block[i] = kh[i];
                i += 1;
            }
        } else {
            let mut i = 0usize;
            while i < key.len() {
                key_block[i] = key[i];
                i += 1;
            }
        }

        let mut ipad = [0u8; 64];
        let mut opad = [0u8; 64];
        let mut i = 0usize;
        while i < 64 {
            ipad[i] = key_block[i] ^ 0x36;
            opad[i] = key_block[i] ^ 0x5C;
            i += 1;
        }

        let mut inner = Sha256::init();
        inner.update(&ipad);
        let mut outer = Sha256::init();
        outer.update(&opad);
        HmacSha256 {
            inner_init: inner,
            outer_init: outer,
        }
    }

    /// Close an inner hash that was seeded from `inner_init` and fed message
    /// data: HMAC = H(opad || H(ipad || msg)).
    pub fn finish(&self, inner: &mut Sha256) -> [u8; 32] {
        let inner_digest = inner.final_digest();
        let mut outer = self.outer_init;
        outer.update(&inner_digest);
        outer.final_digest()
    }

    /// One-shot MAC over `msg` under this key.
    pub fn mac(&self, msg: &[u8]) -> [u8; 32] {
        let mut inner = self.inner_init;
        inner.update(msg);
        self.finish(&mut inner)
    }
}

/// One-shot HMAC-SHA256.
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let ctx = HmacSha256::init(key);
    ctx.mac(msg)
}

// ---- PBKDF2-HMAC-SHA256 (RFC 2898 / RFC 8018) ----

/// Derive `out.len()` bytes of key material from a password and salt.
/// `iterations` must be >= 1 (the caller picks the work factor; 0 would silently
/// produce U_1-only material and is treated as 1).
pub fn pbkdf2_hmac_sha256(password: &[u8], salt: &[u8], iterations: u32, out: &mut [u8]) {
    let prf = HmacSha256::init(password);
    let iters: u32 = if iterations == 0 { 1 } else { iterations };

    let mut block_index: u32 = 1; // T-block counter, 1-based per the RFC
    let mut out_pos = 0usize;
    while out_pos < out.len() {
        // U_1 = PRF(P, S || INT_BE(block_index))
        let mut inner = prf.inner_init;
        inner.update(salt);
        let index_be = [
            (block_index >> 24) as u8,
            (block_index >> 16) as u8,
            (block_index >> 8) as u8,
            block_index as u8,
        ];
        inner.update(&index_be);
        let mut u = prf.finish(&mut inner);

        // T_i = U_1 ^ U_2 ^ ... ^ U_c, with U_j = PRF(P, U_{j-1}).
        let mut t_block = u;
        let mut iter: u32 = 1;
        while iter < iters {
            u = prf.mac(&u);
            let mut k = 0usize;
            while k < 32 {
                t_block[k] ^= u[k];
                k += 1;
            }
            iter += 1;
        }

        // Emit min(32, remaining) bytes of T_i.
        let mut n = out.len() - out_pos;
        if n > 32 {
            n = 32;
        }
        let mut j = 0usize;
        while j < n {
            out[out_pos + j] = t_block[j];
            j += 1;
        }
        out_pos += n;
        block_index = block_index.wrapping_add(1);
    }
}

// ---- Constant-time comparison ----

/// Branch-free byte-slice equality for comparing secrets (a freshly derived
/// PBKDF2 key against the stored verifier). Running time depends only on the
/// slice length, not on the position of the first mismatch, so it leaks no
/// information about a partially-correct guess. The length check short-circuits,
/// but the compared lengths (fixed digest sizes) are public.
pub fn ct_eql(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    let mut i = 0usize;
    while i < a.len() {
        diff |= a[i] ^ b[i];
        i += 1;
    }
    diff == 0
}

// ---- Host tests ----
//
// The vector tests below are the gate described in the header. Expected values
// are written as hex strings (decoded at test time) so they can be compared
// character-for-character against the published sources; the implementation
// itself never parses hex.
//
// The three `differential:` tests check every digest against the RustCrypto
// reference implementations, which are dev-dependencies: host-test-only, never
// linked into the kernel staticlib. They replace the std.crypto differentials
// the Flash module carried, one for one.

#[cfg(test)]
mod tests {
    use super::*;

    /// Decode a hex string into bytes and compare it against `digest`.
    fn expect_digest_hex(hex: &str, digest: &[u8]) {
        let mut expected = [0u8; 64];
        let n = hex.len() / 2;
        for i in 0..n {
            let byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).expect("bad hex");
            expected[i] = byte;
        }
        assert_eq!(&expected[..n], digest);
    }

    #[test]
    fn ct_eql_equal_slices() {
        assert!(ct_eql(b"abc", b"abc"));
        assert!(ct_eql(b"", b""));
        let k = [0xDEu8, 0xAD, 0xBE, 0xEF];
        assert!(ct_eql(&k, &k));
    }

    #[test]
    fn ct_eql_one_bit_difference() {
        assert!(!ct_eql(b"abc", b"abd"));
        assert!(!ct_eql(&[0x00], &[0x01]));
    }

    #[test]
    fn ct_eql_length_mismatch() {
        assert!(!ct_eql(b"abc", b"ab"));
        assert!(!ct_eql(b"", b"a"));
    }

    #[test]
    fn nist_fips_180_2_empty_message() {
        let d = sha256(b"");
        expect_digest_hex(
            "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
            &d,
        );
    }

    #[test]
    fn nist_fips_180_2_abc() {
        let d = sha256(b"abc");
        expect_digest_hex(
            "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD",
            &d,
        );
    }

    #[test]
    fn nist_fips_180_2_448_bit_two_block_message() {
        let d = sha256(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
        expect_digest_hex(
            "248D6A61D20638B8E5C026930C3E6039A33CE45964FF2167F6ECEDD419DB06C1",
            &d,
        );
    }

    #[test]
    fn nist_fips_180_2_896_bit_message() {
        let d = sha256(
            b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno\
              ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
        );
        expect_digest_hex(
            "CF5B16A778AF8380036CE59E7B0492370B249B11E8F07A51AFAC45037AFEE9D1",
            &d,
        );
    }

    #[test]
    fn nist_fips_180_2_one_million_a_streamed() {
        // Streamed through update() in odd-sized chunks — there is no 1 MB
        // buffer anywhere, which is the point of the incremental hasher.
        let mut h = Sha256::init();
        let chunk = [b'a'; 1000];
        let mut fed = 0usize;
        while fed < 1_000_000 {
            h.update(&chunk);
            fed += chunk.len();
        }
        let d = h.final_digest();
        expect_digest_hex(
            "CDC76E5C9914FB9281A1C7E284D73E67F1809A48A497200E046D39CCC7112CD0",
            &d,
        );
    }

    #[test]
    fn streaming_equivalence_byte_chunked_oneshot() {
        // Exercises every block-boundary path in update(): a message long
        // enough to span multiple blocks, fed three different ways.
        let mut msg = [0u8; 257];
        for (i, b) in msg.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(31).wrapping_add(7);
        }

        let oneshot = sha256(&msg);

        let mut by_byte = Sha256::init();
        for b in msg.iter() {
            by_byte.update(&[*b]);
        }
        let d_byte = by_byte.final_digest();

        let mut chunked = Sha256::init();
        chunked.update(&msg[0..63]);
        chunked.update(&msg[63..64]); // exactly closes block 1
        chunked.update(&msg[64..130]); // spans a boundary
        chunked.update(&msg[130..130]); // empty update
        chunked.update(&msg[130..]);
        let d_chunk = chunked.final_digest();

        assert_eq!(oneshot, d_byte);
        assert_eq!(oneshot, d_chunk);
    }

    #[test]
    fn rfc_4231_case_1_20_byte_0x0b_key() {
        let key = [0x0Bu8; 20];
        let d = hmac_sha256(&key, b"Hi There");
        expect_digest_hex(
            "B0344C61D8DB38535CA8AFCEAF0BF12B881DC200C9833DA726E9376C2E32CFF7",
            &d,
        );
    }

    #[test]
    fn rfc_4231_case_2_short_ascii_key() {
        let d = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        expect_digest_hex(
            "5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843",
            &d,
        );
    }

    #[test]
    fn rfc_4231_case_3_20_byte_0xaa_key_50_byte_0xdd_message() {
        let key = [0xAAu8; 20];
        let msg = [0xDDu8; 50];
        let d = hmac_sha256(&key, &msg);
        expect_digest_hex(
            "773EA91E36800E46854DB8EBD09181A72959098B3EF8C122D9635514CED565FE",
            &d,
        );
    }

    #[test]
    fn rfc_4231_case_4_25_byte_counting_key_50_byte_0xcd_message() {
        let key = [
            0x01u8, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
            0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19,
        ];
        let msg = [0xCDu8; 50];
        let d = hmac_sha256(&key, &msg);
        expect_digest_hex(
            "82558A389A443C0EA4CC819899F2083A85F0FAA3E578F8077A2E3FF46729665B",
            &d,
        );
    }

    // Cases 6-7 share a 131-byte key — longer than the 64-byte block, so init()
    // must hash it first.

    #[test]
    fn rfc_4231_case_6_131_byte_oversize_key_short_message() {
        let key = [0xAAu8; 131];
        let d = hmac_sha256(
            &key,
            b"Test Using Larger Than Block-Size Key - Hash Key First",
        );
        expect_digest_hex(
            "60E431591EE0B67F0D8A26AACBF5B77F8E0BC6213728C5140546040F0EE37F54",
            &d,
        );
    }

    #[test]
    fn rfc_4231_case_7_131_byte_oversize_key_oversize_message() {
        let key = [0xAAu8; 131];
        let d = hmac_sha256(
            &key,
            b"This is a test using a larger than block-size key and a \
              larger than block-size data. The key needs to be hashed \
              before being used by the HMAC algorithm.",
        );
        expect_digest_hex(
            "9B09FFA71B942FCB27635FBCD5B0E944BFDC63644F0713938A7F51535C3A35E2",
            &d,
        );
    }

    #[test]
    fn pbkdf2_published_vectors_c1_c2_c4096() {
        // The standard PBKDF2-HMAC-SHA256 vector set (the RFC 6070 cases
        // re-keyed to SHA-256; cross-published in multiple library test
        // suites). The differential tests below independently check the
        // implementation against RustCrypto, so a transcription error here and
        // an implementation error cannot mask each other.
        let mut dk = [0u8; 32];

        pbkdf2_hmac_sha256(b"password", b"salt", 1, &mut dk);
        expect_digest_hex(
            "120FB6CFFCF8B32C43E7225256C4F837A86548C92CCC35480805987CB70BE17B",
            &dk,
        );

        pbkdf2_hmac_sha256(b"password", b"salt", 2, &mut dk);
        expect_digest_hex(
            "AE4D0C95AF6B46D32D0ADFF928F06DD02A303F8EF3C251DFD6E2D85A95474C43",
            &dk,
        );

        pbkdf2_hmac_sha256(b"password", b"salt", 4096, &mut dk);
        expect_digest_hex(
            "C5E478D59288C841AA530DB6845C4C8D962893A001CE4E11A4963873AA98134A",
            &dk,
        );
    }

    #[test]
    fn pbkdf2_multi_block_output_dklen_40() {
        // dkLen=40 forces a second T-block (T_1 full + 8 bytes of T_2).
        let mut dk = [0u8; 40];
        pbkdf2_hmac_sha256(
            b"passwordPASSWORDpassword",
            b"saltSALTsaltSALTsaltSALTsaltSALTsalt",
            4096,
            &mut dk,
        );
        expect_digest_hex(
            "348C89DBCBD32B2F32D814B8116E84CF2B17347EBC1800181C4E2A1FB8DD53E1C635518C7DAC47E9",
            &dk,
        );
    }

    #[test]
    fn pbkdf2_truncated_output_with_embedded_nuls_dklen_16() {
        // dkLen=16 truncates T_1; password and salt carry embedded NULs.
        let mut dk = [0u8; 16];
        pbkdf2_hmac_sha256(b"pass\x00word", b"sa\x00lt", 4096, &mut dk);
        expect_digest_hex("89B69D0516F829893C696226650A8687", &dk);
    }

    #[test]
    fn pbkdf2_rfc_7914_reference_vector_dklen_64() {
        let mut dk = [0u8; 64];
        pbkdf2_hmac_sha256(b"passwd", b"salt", 1, &mut dk);
        expect_digest_hex(
            "55AC046E56E3089FEC1691C22544B605F94185216DDE0465E68B9D57C20DACBC\
             49CA9CCCF179B645991664B39D77EF317C71B845B1E30BD509112041D3A19783",
            &dk,
        );
    }

    #[test]
    fn differential_sha256_matches_reference_for_lengths_0_to_257() {
        // Patterned (deterministic) messages of every length crossing the
        // one-block and two-block boundaries. Catches any divergence the fixed
        // vectors might miss, with RustCrypto as the reference.
        use sha2::{Digest, Sha256 as RefSha256};

        let mut msg = [0u8; 257];
        for (i, b) in msg.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(131).wrapping_add(89);
        }

        for len in 0..=msg.len() {
            let ours = sha256(&msg[0..len]);
            let theirs = RefSha256::digest(&msg[0..len]);
            assert_eq!(&ours[..], &theirs[..], "length {len}");
        }
    }

    #[test]
    fn differential_hmac_matches_reference_across_key_and_msg_sizes() {
        // Key lengths sweep across the block boundary (incl. 0, 64, 65);
        // message lengths sweep across block boundaries.
        use hmac::{Mac, SimpleHmac};
        use sha2::Sha256 as RefSha256;

        let mut buf = [0u8; 192];
        for (i, b) in buf.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(37).wrapping_add(11);
        }

        let key_lens = [0usize, 1, 31, 32, 63, 64, 65, 128, 192];
        let msg_lens = [0usize, 1, 55, 56, 63, 64, 65, 127, 128, 192];
        for kl in key_lens {
            for ml in msg_lens {
                let ours = hmac_sha256(&buf[0..kl], &buf[0..ml]);
                let mut mac = SimpleHmac::<RefSha256>::new_from_slice(&buf[0..kl])
                    .expect("SimpleHmac takes any key length");
                mac.update(&buf[0..ml]);
                let theirs = mac.finalize().into_bytes();
                assert_eq!(&ours[..], &theirs[..], "key {kl} msg {ml}");
            }
        }
    }

    #[test]
    fn differential_pbkdf2_matches_reference() {
        // Odd dkLen (not a digest multiple), several iteration counts.
        use hmac::SimpleHmac;
        use sha2::Sha256 as RefSha256;

        struct Case {
            pw: &'static [u8],
            salt: &'static [u8],
            c: u32,
            len: usize,
        }

        let cases = [
            Case {
                pw: b"password",
                salt: b"salt",
                c: 1,
                len: 20,
            },
            Case {
                pw: b"password",
                salt: b"salt",
                c: 100,
                len: 33,
            },
            Case {
                pw: b"",
                salt: b"salt",
                c: 7,
                len: 32,
            },
            Case {
                pw: b"password",
                salt: b"",
                c: 7,
                len: 32,
            },
            Case {
                pw: b"a-fairly-long-password-beyond-one-sha-block-aaaaaaaaaaaaaaaaaaaaaaaaaa",
                salt: b"pepper",
                c: 13,
                len: 48,
            },
        ];

        for case in cases {
            let mut ours = [0u8; 64];
            let mut theirs = [0u8; 64];
            pbkdf2_hmac_sha256(case.pw, case.salt, case.c, &mut ours[0..case.len]);
            pbkdf2::pbkdf2::<SimpleHmac<RefSha256>>(
                case.pw,
                case.salt,
                case.c,
                &mut theirs[0..case.len],
            )
            .expect("SimpleHmac takes any key length");
            assert_eq!(&ours[0..case.len], &theirs[0..case.len]);
        }
    }
}
