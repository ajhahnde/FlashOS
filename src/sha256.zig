// sha256: the kernel crypto unit — SHA-256, HMAC-SHA256, PBKDF2-HMAC-SHA256.
//
// Password-hashing primitives for FlashOS user authentication.
// The kernel hashes and salts credentials itself (the KDF lives in one
// audited place); userspace never needs these primitives, so this is an
// ordinary kernel module, not an ABI-shared one.
//
// Pure compute — no MMIO, no externs, no allocation, no std. Every working
// buffer is caller-stack or value-returned, so calling any function here
// can never perturb the free-page baseline the harness asserts. Host tests
// at the bottom gate the implementation against published vectors (NIST
// FIPS 180-2, RFC 4231, the standard PBKDF2-HMAC-SHA256 set): a wrong
// round constant or a flipped byte order is invisible at runtime — it
// would silently produce stable-but-wrong hashes, which is an
// authentication bypass or a permanently locked-out device. No consumer
// of these functions ships until the vector tests pass.
//
// Implementation notes, deliberate choices:
//
//  - The incremental hasher (init/update/final) is the core; the one-shot
//    helpers wrap it. Large inputs stream through a single 64-byte block
//    buffer — nothing here ever needs a message-sized buffer.
//  - Message words and the length field are assembled big-endian BY HAND
//    (shifts + @truncate). AArch64 is little-endian and std.mem is not
//    available freestanding; getting this wrong is the classic
//    silently-wrong-digest bug, which is exactly what the NIST vectors
//    catch.
//  - Block fills are explicit byte loops, never @memcpy of a runtime
//    length (project byte-loop discipline; see the FAT32 sub-sector write
//    rule in DOCUMENTATION.md).
//  - Addition is +% throughout the compression function: SHA-256 is
//    defined over mod-2^32 arithmetic.

// ---- SHA-256 core (FIPS 180-4) ----

pub const DIGEST_LENGTH: usize = 32;
pub const BLOCK_LENGTH: usize = 64;

// Initial hash state: the first 32 bits of the fractional parts of the
// square roots of the first 8 primes.
const H0 = [8]u32{
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
};

// Round constants: the first 32 bits of the fractional parts of the cube
// roots of the first 64 primes.
const K = [64]u32{
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
    0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
    0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
    0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
    0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
    0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
    0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
    0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
    0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
};

// Rotate-right for u32. n is comptime (all SHA-256 rotations are fixed),
// so both shift amounts are comptime-checked to fit the u5 shift type.
inline fn rotr(x: u32, comptime n: comptime_int) u32 {
    return (x >> n) | (x << (32 - n));
}

// One 64-byte block through the compression function, updating `state`.
fn compress(state: *[8]u32, block: *const [64]u8) void {
    // Message schedule. W[0..15] are the block words read big-endian;
    // W[16..63] extend them.
    var w: [64]u32 = undefined;
    var t: usize = 0;
    while (t < 16) : (t += 1) {
        w[t] = (@as(u32, block[t * 4]) << 24) |
            (@as(u32, block[t * 4 + 1]) << 16) |
            (@as(u32, block[t * 4 + 2]) << 8) |
            @as(u32, block[t * 4 + 3]);
    }
    while (t < 64) : (t += 1) {
        const s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
        const s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
        w[t] = w[t - 16] +% s0 +% w[t - 7] +% s1;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const sum1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        const ch = (e & f) ^ (~e & g);
        const temp1 = h +% sum1 +% ch +% K[i] +% w[i];
        const sum0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const temp2 = sum0 +% maj;
        h = g;
        g = f;
        f = e;
        e = d +% temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 +% temp2;
    }

    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
    state[4] +%= e;
    state[5] +%= f;
    state[6] +%= g;
    state[7] +%= h;
}

// Incremental SHA-256. Usage: var h = Sha256.init(); h.update(...); ...;
// const digest = h.final(); — `final` consumes the state (padding is
// written into the block buffer); do not update() after final().
pub const Sha256 = struct {
    state: [8]u32,
    block: [64]u8,
    block_len: usize, // bytes pending in `block`, always < 64
    total_len: u64, // total message bytes absorbed (for the length field)

    pub fn init() Sha256 {
        return .{
            .state = H0,
            .block = [_]u8{0} ** 64,
            .block_len = 0,
            .total_len = 0,
        };
    }

    pub fn update(self: *Sha256, data: []const u8) void {
        // Byte loop into the block buffer; compress on every full block.
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            self.block[self.block_len] = data[i];
            self.block_len += 1;
            if (self.block_len == 64) {
                compress(&self.state, &self.block);
                self.block_len = 0;
            }
        }
        self.total_len +%= data.len;
    }

    pub fn final(self: *Sha256) [32]u8 {
        const bit_len: u64 = self.total_len *% 8;

        // Padding: a single 0x80 byte, zeros, then the 64-bit big-endian
        // bit length closing out a block.
        self.block[self.block_len] = 0x80;
        self.block_len += 1;
        if (self.block_len > 56) {
            // No room for the length field — pad this block out first.
            while (self.block_len < 64) : (self.block_len += 1) self.block[self.block_len] = 0;
            compress(&self.state, &self.block);
            self.block_len = 0;
        }
        while (self.block_len < 56) : (self.block_len += 1) self.block[self.block_len] = 0;
        self.block[56] = @truncate(bit_len >> 56);
        self.block[57] = @truncate(bit_len >> 48);
        self.block[58] = @truncate(bit_len >> 40);
        self.block[59] = @truncate(bit_len >> 32);
        self.block[60] = @truncate(bit_len >> 24);
        self.block[61] = @truncate(bit_len >> 16);
        self.block[62] = @truncate(bit_len >> 8);
        self.block[63] = @truncate(bit_len);
        compress(&self.state, &self.block);

        // Serialize the state big-endian into the digest.
        var out: [32]u8 = undefined;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            out[k * 4] = @truncate(self.state[k] >> 24);
            out[k * 4 + 1] = @truncate(self.state[k] >> 16);
            out[k * 4 + 2] = @truncate(self.state[k] >> 8);
            out[k * 4 + 3] = @truncate(self.state[k]);
        }
        return out;
    }
};

// One-shot SHA-256.
pub fn sha256(msg: []const u8) [32]u8 {
    var h = Sha256.init();
    h.update(msg);
    return h.final();
}

// ---- HMAC-SHA256 (RFC 2104) ----

// Keyed MAC with precomputed key pads: init() absorbs (key ^ ipad) and
// (key ^ opad) once, so every mac() afterwards costs two compressions.
// That is what makes PBKDF2's inner loop affordable — its iteration count
// times two compressions is the whole cost.
pub const HmacSha256 = struct {
    inner_init: Sha256, // state after absorbing (key ^ ipad)
    outer_init: Sha256, // state after absorbing (key ^ opad)

    pub fn init(key: []const u8) HmacSha256 {
        // Keys longer than the block are hashed first (RFC 2104); shorter
        // keys are zero-padded to the block length.
        var key_block = [_]u8{0} ** 64;
        if (key.len > 64) {
            const kh = sha256(key);
            var i: usize = 0;
            while (i < 32) : (i += 1) key_block[i] = kh[i];
        } else {
            var i: usize = 0;
            while (i < key.len) : (i += 1) key_block[i] = key[i];
        }

        var ipad: [64]u8 = undefined;
        var opad: [64]u8 = undefined;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            ipad[i] = key_block[i] ^ 0x36;
            opad[i] = key_block[i] ^ 0x5C;
        }

        var inner = Sha256.init();
        inner.update(ipad[0..]);
        var outer = Sha256.init();
        outer.update(opad[0..]);
        return .{ .inner_init = inner, .outer_init = outer };
    }

    // Close an inner hash that was seeded from inner_init and fed message
    // data: HMAC = H(opad || H(ipad || msg)).
    pub fn finish(self: *const HmacSha256, inner: *Sha256) [32]u8 {
        const inner_digest = inner.final();
        var outer = self.outer_init;
        outer.update(inner_digest[0..]);
        return outer.final();
    }

    // One-shot MAC over `msg` under this key.
    pub fn mac(self: *const HmacSha256, msg: []const u8) [32]u8 {
        var inner = self.inner_init;
        inner.update(msg);
        return self.finish(&inner);
    }
};

// One-shot HMAC-SHA256.
pub fn hmacSha256(key: []const u8, msg: []const u8) [32]u8 {
    const ctx = HmacSha256.init(key);
    return ctx.mac(msg);
}

// ---- PBKDF2-HMAC-SHA256 (RFC 2898 / RFC 8018) ----

// Derive out.len bytes of key material from a password and salt.
// iterations must be >= 1 (the caller picks the work factor; 0 would
// silently produce U_1-only material and is treated as 1).
pub fn pbkdf2HmacSha256(password: []const u8, salt: []const u8, iterations: u32, out: []u8) void {
    const prf = HmacSha256.init(password);
    const iters: u32 = if (iterations == 0) 1 else iterations;

    var block_index: u32 = 1; // T-block counter, 1-based per the RFC
    var out_pos: usize = 0;
    while (out_pos < out.len) : (block_index +%= 1) {
        // U_1 = PRF(P, S || INT_BE(block_index))
        var inner = prf.inner_init;
        inner.update(salt);
        const index_be = [4]u8{
            @truncate(block_index >> 24),
            @truncate(block_index >> 16),
            @truncate(block_index >> 8),
            @truncate(block_index),
        };
        inner.update(index_be[0..]);
        var u = prf.finish(&inner);

        // T_i = U_1 ^ U_2 ^ ... ^ U_c, with U_j = PRF(P, U_{j-1}).
        var t_block = u;
        var iter: u32 = 1;
        while (iter < iters) : (iter += 1) {
            u = prf.mac(u[0..]);
            var k: usize = 0;
            while (k < 32) : (k += 1) t_block[k] ^= u[k];
        }

        // Emit min(32, remaining) bytes of T_i.
        var n = out.len - out_pos;
        if (n > 32) n = 32;
        var j: usize = 0;
        while (j < n) : (j += 1) out[out_pos + j] = t_block[j];
        out_pos += n;
    }
}

// ---- Constant-time comparison ----

// Branch-free byte-slice equality for comparing secrets (a freshly derived
// PBKDF2 key against the stored verifier). Running time depends only on the
// slice length, not on the position of the first mismatch, so it leaks no
// information about a partially-correct guess. The length check
// short-circuits, but the compared lengths (fixed digest sizes) are public.
pub fn ctEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// ---- Host tests ----
//
// The vector tests below are the gate described in the header. Expected
// values are written as hex strings (decoded via std.fmt at test time) so
// they can be compared character-for-character against the published
// sources; the implementation itself never parses hex.

const std = @import("std");
const testing = std.testing;

test "ctEql: equal slices" {
    try testing.expect(ctEql("abc", "abc"));
    try testing.expect(ctEql("", ""));
    const k = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try testing.expect(ctEql(k[0..], k[0..]));
}

test "ctEql: one-bit difference" {
    try testing.expect(!ctEql("abc", "abd"));
    try testing.expect(!ctEql(&[_]u8{0x00}, &[_]u8{0x01}));
}

test "ctEql: length mismatch" {
    try testing.expect(!ctEql("abc", "ab"));
    try testing.expect(!ctEql("", "a"));
}

fn expectDigestHex(comptime hex: []const u8, digest: []const u8) !void {
    var expected: [64]u8 = undefined;
    const bytes = try std.fmt.hexToBytes(expected[0..hex.len / 2], hex);
    try testing.expectEqualSlices(u8, bytes, digest);
}

test "NIST FIPS 180-2: empty message" {
    const d = sha256("");
    try expectDigestHex(
        "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
        d[0..],
    );
}

test "NIST FIPS 180-2: 'abc'" {
    const d = sha256("abc");
    try expectDigestHex(
        "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD",
        d[0..],
    );
}

test "NIST FIPS 180-2: 448-bit two-block message" {
    const d = sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    try expectDigestHex(
        "248D6A61D20638B8E5C026930C3E6039A33CE45964FF2167F6ECEDD419DB06C1",
        d[0..],
    );
}

test "NIST FIPS 180-2: 896-bit message" {
    const d = sha256("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno" ++
        "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu");
    try expectDigestHex(
        "CF5B16A778AF8380036CE59E7B0492370B249B11E8F07A51AFAC45037AFEE9D1",
        d[0..],
    );
}

test "NIST FIPS 180-2: one million 'a' (streamed)" {
    // Streamed through update() in odd-sized chunks — there is no 1 MB
    // buffer anywhere, which is the point of the incremental hasher.
    var h = Sha256.init();
    const chunk = [_]u8{'a'} ** 1000;
    var fed: usize = 0;
    while (fed < 1_000_000) : (fed += chunk.len) {
        h.update(chunk[0..]);
    }
    const d = h.final();
    try expectDigestHex(
        "CDC76E5C9914FB9281A1C7E284D73E67F1809A48A497200E046D39CCC7112CD0",
        d[0..],
    );
}

test "streaming equivalence: byte-by-byte == chunked == one-shot" {
    // Exercises every block-boundary path in update(): a message long
    // enough to span multiple blocks, fed three different ways.
    var msg: [257]u8 = undefined;
    for (&msg, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    const oneshot = sha256(msg[0..]);

    var by_byte = Sha256.init();
    for (msg) |b| by_byte.update(&[_]u8{b});
    const d_byte = by_byte.final();

    var chunked = Sha256.init();
    chunked.update(msg[0..63]);
    chunked.update(msg[63..64]); // exactly closes block 1
    chunked.update(msg[64..130]); // spans a boundary
    chunked.update(msg[130..130]); // empty update
    chunked.update(msg[130..]);
    const d_chunk = chunked.final();

    try testing.expectEqualSlices(u8, oneshot[0..], d_byte[0..]);
    try testing.expectEqualSlices(u8, oneshot[0..], d_chunk[0..]);
}

test "RFC 4231: HMAC-SHA256 test cases 1-4" {
    // Case 1: 20-byte 0x0B key.
    {
        const key = [_]u8{0x0B} ** 20;
        const d = hmacSha256(key[0..], "Hi There");
        try expectDigestHex(
            "B0344C61D8DB38535CA8AFCEAF0BF12B881DC200C9833DA726E9376C2E32CFF7",
            d[0..],
        );
    }
    // Case 2: short ASCII key.
    {
        const d = hmacSha256("Jefe", "what do ya want for nothing?");
        try expectDigestHex(
            "5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843",
            d[0..],
        );
    }
    // Case 3: 20-byte 0xAA key, 50-byte 0xDD message.
    {
        const key = [_]u8{0xAA} ** 20;
        const msg = [_]u8{0xDD} ** 50;
        const d = hmacSha256(key[0..], msg[0..]);
        try expectDigestHex(
            "773EA91E36800E46854DB8EBD09181A72959098B3EF8C122D9635514CED565FE",
            d[0..],
        );
    }
    // Case 4: 25-byte counting key, 50-byte 0xCD message.
    {
        const key = [_]u8{
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
            0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
            0x15, 0x16, 0x17, 0x18, 0x19,
        };
        const msg = [_]u8{0xCD} ** 50;
        const d = hmacSha256(key[0..], msg[0..]);
        try expectDigestHex(
            "82558A389A443C0EA4CC819899F2083A85F0FAA3E578F8077A2E3FF46729665B",
            d[0..],
        );
    }
}

test "RFC 4231: HMAC-SHA256 oversize-key cases 6-7" {
    // 131-byte key — longer than the 64-byte block, so init() must hash
    // it first. Both remaining RFC cases use it.
    const key = [_]u8{0xAA} ** 131;
    {
        const d = hmacSha256(key[0..], "Test Using Larger Than Block-Size Key - Hash Key First");
        try expectDigestHex(
            "60E431591EE0B67F0D8A26AACBF5B77F8E0BC6213728C5140546040F0EE37F54",
            d[0..],
        );
    }
    {
        const d = hmacSha256(key[0..], "This is a test using a larger than block-size key and a " ++
            "larger than block-size data. The key needs to be hashed " ++
            "before being used by the HMAC algorithm.");
        try expectDigestHex(
            "9B09FFA71B942FCB27635FBCD5B0E944BFDC63644F0713938A7F51535C3A35E2",
            d[0..],
        );
    }
}

test "PBKDF2-HMAC-SHA256: published vectors (c=1, c=2, c=4096)" {
    // The standard PBKDF2-HMAC-SHA256 vector set (the RFC 6070 cases
    // re-keyed to SHA-256; cross-published in multiple library test
    // suites). The differential test below independently checks the
    // implementation against std.crypto, so a transcription error here
    // and an implementation error cannot mask each other.
    var dk: [32]u8 = undefined;

    pbkdf2HmacSha256("password", "salt", 1, dk[0..]);
    try expectDigestHex(
        "120FB6CFFCF8B32C43E7225256C4F837A86548C92CCC35480805987CB70BE17B",
        dk[0..],
    );

    pbkdf2HmacSha256("password", "salt", 2, dk[0..]);
    try expectDigestHex(
        "AE4D0C95AF6B46D32D0ADFF928F06DD02A303F8EF3C251DFD6E2D85A95474C43",
        dk[0..],
    );

    pbkdf2HmacSha256("password", "salt", 4096, dk[0..]);
    try expectDigestHex(
        "C5E478D59288C841AA530DB6845C4C8D962893A001CE4E11A4963873AA98134A",
        dk[0..],
    );
}

test "PBKDF2-HMAC-SHA256: multi-block and truncated outputs" {
    // dkLen=40 forces a second T-block (T_1 full + 8 bytes of T_2).
    {
        var dk: [40]u8 = undefined;
        pbkdf2HmacSha256(
            "passwordPASSWORDpassword",
            "saltSALTsaltSALTsaltSALTsaltSALTsalt",
            4096,
            dk[0..],
        );
        try expectDigestHex(
            "348C89DBCBD32B2F32D814B8116E84CF2B17347EBC1800181C4E2A1FB8DD53E1C635518C7DAC47E9",
            dk[0..],
        );
    }
    // dkLen=16 truncates T_1; password and salt carry embedded NULs.
    {
        var dk: [16]u8 = undefined;
        pbkdf2HmacSha256("pass\x00word", "sa\x00lt", 4096, dk[0..]);
        try expectDigestHex(
            "89B69D0516F829893C696226650A8687",
            dk[0..],
        );
    }
}

test "PBKDF2-HMAC-SHA256: RFC 7914 reference vector (dkLen=64)" {
    var dk: [64]u8 = undefined;
    pbkdf2HmacSha256("passwd", "salt", 1, dk[0..]);
    try expectDigestHex(
        "55AC046E56E3089FEC1691C22544B605F94185216DDE0465E68B9D57C20DACBC" ++
            "49CA9CCCF179B645991664B39D77EF317C71B845B1E30BD509112041D3A19783",
        dk[0..],
    );
}

test "differential: sha256 matches std.crypto for lengths 0..257" {
    // Patterned (deterministic) messages of every length crossing the
    // one-block and two-block boundaries. Catches any divergence the
    // fixed vectors might miss, with std.crypto as the reference.
    var msg: [257]u8 = undefined;
    for (&msg, 0..) |*b, i| b.* = @truncate(i *% 131 +% 89);

    var len: usize = 0;
    while (len <= msg.len) : (len += 1) {
        const ours = sha256(msg[0..len]);
        var theirs: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(msg[0..len], &theirs, .{});
        try testing.expectEqualSlices(u8, theirs[0..], ours[0..]);
    }
}

test "differential: HMAC matches std.crypto across key/msg sizes" {
    // Key lengths sweep across the block boundary (incl. 0, 64, 65);
    // message lengths sweep across block boundaries.
    var buf: [192]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);

    const key_lens = [_]usize{ 0, 1, 31, 32, 63, 64, 65, 128, 192 };
    const msg_lens = [_]usize{ 0, 1, 55, 56, 63, 64, 65, 127, 128, 192 };
    for (key_lens) |kl| {
        for (msg_lens) |ml| {
            const ours = hmacSha256(buf[0..kl], buf[0..ml]);
            var theirs: [32]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha256.create(&theirs, buf[0..ml], buf[0..kl]);
            try testing.expectEqualSlices(u8, theirs[0..], ours[0..]);
        }
    }
}

test "differential: PBKDF2 matches std.crypto" {
    // Odd dkLen (not a digest multiple), several iteration counts.
    const cases = [_]struct { pw: []const u8, salt: []const u8, c: u32, len: usize }{
        .{ .pw = "password", .salt = "salt", .c = 1, .len = 20 },
        .{ .pw = "password", .salt = "salt", .c = 100, .len = 33 },
        .{ .pw = "", .salt = "salt", .c = 7, .len = 32 },
        .{ .pw = "password", .salt = "", .c = 7, .len = 32 },
        .{ .pw = "a-fairly-long-password-beyond-one-sha-block-aaaaaaaaaaaaaaaaaaaaaaaaaa", .salt = "pepper", .c = 13, .len = 48 },
    };
    for (cases) |case| {
        var ours: [64]u8 = undefined;
        var theirs: [64]u8 = undefined;
        pbkdf2HmacSha256(case.pw, case.salt, case.c, ours[0..case.len]);
        try std.crypto.pwhash.pbkdf2(theirs[0..case.len], case.pw, case.salt, case.c, std.crypto.auth.hmac.sha2.HmacSha256);
        try testing.expectEqualSlices(u8, theirs[0..case.len], ours[0..case.len]);
    }
}
