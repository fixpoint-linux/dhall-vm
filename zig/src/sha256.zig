// sha256.zig — port of ../src/sha256.c, verbatim in behavior.
// Standard SHA-256 (FIPS 180-4) digest, lowercase-hex encoded into a
// NUL-terminated 65-byte buffer. All compression-function arithmetic wraps
// (u32 `+%`) to match C unsigned semantics in ReleaseSafe builds.

const std = @import("std");

const K = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

fn rotr(x: u32, comptime n: u32) u32 {
    return (x >> @as(u5, @intCast(n))) | (x << @as(u5, @intCast(32 - n)));
}

fn sha256_block(p: [*]const u8, h: *[8]u32) void {
    var w: [64]u32 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        w[i] = (@as(u32, p[i * 4]) << 24) |
            (@as(u32, p[i * 4 + 1]) << 16) |
            (@as(u32, p[i * 4 + 2]) << 8) |
            @as(u32, p[i * 4 + 3]);
    }
    while (i < 64) : (i += 1) {
        const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
    }
    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    var e = h[4];
    var f = h[5];
    var g = h[6];
    var hh = h[7];
    i = 0;
    while (i < 64) : (i += 1) {
        const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        const ch = (e & f) ^ ((~e) & g);
        const t1 = hh +% S1 +% ch +% K[i] +% w[i];
        const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const t2 = S0 +% maj;
        hh = g;
        g = f;
        f = e;
        e = d +% t1;
        d = c;
        c = b;
        b = a;
        a = t1 +% t2;
    }
    h[0] +%= a;
    h[1] +%= b;
    h[2] +%= c;
    h[3] +%= d;
    h[4] +%= e;
    h[5] +%= f;
    h[6] +%= g;
    h[7] +%= hh;
}

/// SHA-256 over `data`, lowercase-hex encoded into out[0..64], out[64] = NUL.
pub fn sha256_hex(data: []const u8, out: *[65]u8) void {
    const msg = data.ptr;
    var h = [8]u32{
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    var i: usize = 0;
    while (i + 64 <= data.len) : (i += 64) sha256_block(msg + i, &h);

    var last: [128]u8 = undefined;
    const rem0: usize = data.len - i;
    @memcpy(last[0..rem0], data[i..]);
    var rem: usize = rem0;
    last[rem] = 0x80;
    rem += 1;
    var total: usize = rem;
    if (total > 56) {
        while (total < 64) : (total += 1) last[total] = 0;
        sha256_block(&last, &h);
        total = 0;
    }
    while (total < 56) : (total += 1) last[total] = 0;
    const bits: u64 = @as(u64, data.len) *% 8;
    var j: usize = 0;
    while (j < 8) : (j += 1)
        last[56 + j] = @truncate(bits >> @as(u6, @intCast(56 - 8 * j)));
    sha256_block(&last, &h);

    const hexdig = "0123456789abcdef";
    j = 0;
    while (j < 8) : (j += 1) {
        out[j * 8 + 0] = hexdig[@intCast((h[j] >> 28) & 0xf)];
        out[j * 8 + 1] = hexdig[@intCast((h[j] >> 24) & 0xf)];
        out[j * 8 + 2] = hexdig[@intCast((h[j] >> 20) & 0xf)];
        out[j * 8 + 3] = hexdig[@intCast((h[j] >> 16) & 0xf)];
        out[j * 8 + 4] = hexdig[@intCast((h[j] >> 12) & 0xf)];
        out[j * 8 + 5] = hexdig[@intCast((h[j] >> 8) & 0xf)];
        out[j * 8 + 6] = hexdig[@intCast((h[j] >> 4) & 0xf)];
        out[j * 8 + 7] = hexdig[@intCast(h[j] & 0xf)];
    }
    out[64] = 0;
}

// ---------------------------------------------------------------------------
// Tests — NIST SHA-256 vectors
// ---------------------------------------------------------------------------
fn expectDigest(input: []const u8, expected: []const u8) !void {
    var out: [65]u8 = undefined;
    sha256_hex(input, &out);
    const got = std.mem.sliceTo(&out, 0);
    try std.testing.expectEqualStrings(expected, got);
}

test "sha256 empty string" {
    try expectDigest("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
}

test "sha256 'abc'" {
    try expectDigest("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

test "sha256 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'" {
    try expectDigest(
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    );
}

test "sha256 'The quick brown fox jumps over the lazy dog'" {
    try expectDigest("The quick brown fox jumps over the lazy dog", "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592");
}

test "sha256 one million 'a' (NIST 2-byte-length padding edge)" {
    var buf: [1000000]u8 = undefined;
    @memset(&buf, 'a');
    try expectDigest(&buf, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}
