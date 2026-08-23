// bignum.zig — port of ../src/bignum.c, verbatim in behavior.
// Arbitrary-precision Natural (base-2^32 little-endian limbs) and signed
// Integer arithmetic. Dual representation: bnat/big pointers in a Const are
// NULL iff the value fits u64/i64. All results are arena-allocated BigNat/BigInt
// views (inputs read-only). Uses the arena as a std.mem.Allocator via the
// global `dhall_arena`.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");

extern fn strtod(nptr: [*:0]const u8, endptr: ?*[*c]u8) f64;

/// arena-allocated, zeroed limb array of n uint32 words.
fn limbs_alloc(n: c_int) [*]u32 {
    const count: usize = @intCast(if (n > 0) n else 1);
    return @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, count * 4)));
}

fn trim(a: *dhall.BigNat) void {
    while (a.nlimbs > 0 and a.limbs.?[@intCast(a.nlimbs - 1)] == 0) a.nlimbs -= 1;
}

/// uint64 -> limb view in caller-supplied scratch; returns limb count.
pub fn bignat_from_u64(n: u64, scratch: *[2]u32) c_int {
    scratch[0] = @truncate(n);
    if (n >= 0x100000000) {
        scratch[1] = @truncate(n >> 32);
        return 2;
    }
    return if (n != 0) 1 else 0;
}

/// BigNat -> uint64; *ok == false iff the value does not fit in 64 bits.
pub fn bignat_to_u64(a: *const dhall.BigNat, ok: *bool) u64 {
    if (a.nlimbs > 2) {
        ok.* = false;
        return 0;
    }
    var v: u64 = 0;
    if (a.nlimbs >= 1) v |= a.limbs.?[0];
    if (a.nlimbs >= 2) v |= @as(u64, a.limbs.?[1]) << 32;
    ok.* = true;
    return v;
}

/// decimal ASCII (no sign) -> BigNat, Horner mul-by-10+digit.
pub fn bignat_from_decimal(digits: []const u8) dhall.BigNat {
    const len = digits.len;
    const maxlimbs: c_int = @intCast(len / 9 + 3);
    const acc = limbs_alloc(maxlimbs);
    var n: c_int = 0;
    for (digits) |ch| {
        const d: u32 = @intCast(ch - '0');
        var carry: u64 = d;
        var j: c_int = 0;
        while (j < n) : (j += 1) {
            const t: u64 = @as(u64, acc[@intCast(j)]) *% 10 +% carry;
            acc[@intCast(j)] = @truncate(t);
            carry = t >> 32;
        }
        if (carry != 0) {
            acc[@intCast(n)] = @truncate(carry);
            n += 1;
        }
    }
    var r = dhall.BigNat{ .limbs = acc, .nlimbs = n };
    trim(&r);
    return r;
}

pub fn bignat_cmp(a: *const dhall.BigNat, b: *const dhall.BigNat) c_int {
    if (a.nlimbs != b.nlimbs) return if (a.nlimbs < b.nlimbs) -1 else 1;
    var i: c_int = a.nlimbs - 1;
    while (i >= 0) : (i -= 1) {
        if (a.limbs.?[@intCast(i)] != b.limbs.?[@intCast(i)])
            return if (a.limbs.?[@intCast(i)] < b.limbs.?[@intCast(i)]) -1 else 1;
    }
    return 0;
}

pub fn bignat_add(a: *const dhall.BigNat, b: *const dhall.BigNat) dhall.BigNat {
    const n: c_int = if (a.nlimbs > b.nlimbs) a.nlimbs else b.nlimbs;
    const out = limbs_alloc(n + 1);
    var carry: u64 = 0;
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const s: u64 = carry +%
            @as(u64, if (i < a.nlimbs) a.limbs.?[@intCast(i)] else 0) +%
            @as(u64, if (i < b.nlimbs) b.limbs.?[@intCast(i)] else 0);
        out[@intCast(i)] = @truncate(s);
        carry = s >> 32;
    }
    var m = n;
    if (carry != 0) {
        out[@intCast(m)] = @truncate(carry);
        m += 1;
    }
    var r = dhall.BigNat{ .limbs = out, .nlimbs = m };
    trim(&r);
    return r;
}

/// saturating: a - b, clamped to 0.
pub fn bignat_sub(a: *const dhall.BigNat, b: *const dhall.BigNat) dhall.BigNat {
    if (bignat_cmp(a, b) < 0) return dhall.BigNat{ .limbs = null, .nlimbs = 0 };
    const n = a.nlimbs;
    const out = limbs_alloc(n);
    var borrow: u64 = 0;
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const d: u64 = @as(u64, a.limbs.?[@intCast(i)]) -%
            @as(u64, if (i < b.nlimbs) b.limbs.?[@intCast(i)] else 0) -% borrow;
        out[@intCast(i)] = @truncate(d);
        borrow = (d >> 63) & 1;
    }
    var r = dhall.BigNat{ .limbs = out, .nlimbs = n };
    trim(&r);
    return r;
}

pub fn bignat_mul(a: *const dhall.BigNat, b: *const dhall.BigNat) dhall.BigNat {
    if (a.nlimbs == 0 or b.nlimbs == 0) return dhall.BigNat{ .limbs = null, .nlimbs = 0 };
    const n: c_int = a.nlimbs + b.nlimbs;
    const out = limbs_alloc(n + 1); // +1 safety for carry ripple
    var i: c_int = 0;
    while (i < a.nlimbs) : (i += 1) {
        const ai: u64 = a.limbs.?[@intCast(i)];
        var carry: u64 = 0;
        var j: c_int = 0;
        while (j < b.nlimbs) : (j += 1) {
            const cur: u64 = @as(u64, out[@intCast(i + j)]) +% ai *% b.limbs.?[@intCast(j)] +% carry;
            out[@intCast(i + j)] = @truncate(cur);
            carry = cur >> 32;
        }
        var k: c_int = i + b.nlimbs;
        while (carry != 0) {
            const cur: u64 = @as(u64, out[@intCast(k)]) +% carry;
            out[@intCast(k)] = @truncate(cur);
            carry = cur >> 32;
            k += 1;
        }
    }
    var r = dhall.BigNat{ .limbs = out, .nlimbs = n };
    trim(&r);
    return r;
}

/// in-place short division by a uint32 divisor; returns remainder, shrinks *n.
fn divmod_u32(limbs: [*]u32, n: *c_int, d: u32) u32 {
    var rem: u64 = 0;
    var i: c_int = n.* - 1;
    while (i >= 0) : (i -= 1) {
        const cur: u64 = (rem << 32) | limbs[@intCast(i)];
        limbs[@intCast(i)] = @intCast(cur / d);
        rem = cur % d;
    }
    while (n.* > 0 and limbs[@intCast(n.* - 1)] == 0) n.* -= 1;
    return @truncate(rem);
}

/// BigNat -> decimal string (repeated divmod by 1e9).
pub fn bignat_to_decimal(a: *const dhall.BigNat) [*:0]u8 {
    if (a.nlimbs == 0) return arena.arena_strdup(arena.dhall_arena.?, "0");
    var n = a.nlimbs;
    const tmp = limbs_alloc(n);
    var i: c_int = 0;
    while (i < n) : (i += 1) tmp[@intCast(i)] = a.limbs.?[@intCast(i)];
    const digits = limbs_alloc(n * 2 + 2);
    var nd: c_int = 0;
    // do-while: n >= 1 here
    while (true) {
        digits[@intCast(nd)] = divmod_u32(tmp, &n, 1000000000);
        nd += 1;
        if (!(n > 0)) break;
    }
    var buf: dhall.TmpBuf = undefined;
    arena.tmpbuf_init(&buf);
    var chunk: [16]u8 = undefined;
    const first = std.fmt.bufPrint(&chunk, "{d}", .{digits[@intCast(nd - 1)]}) catch unreachable;
    arena.tmpbuf_add(&buf, first);
    var j: c_int = nd - 2;
    while (j >= 0) : (j -= 1) {
        const s = std.fmt.bufPrint(&chunk, "{d:0>9}", .{digits[@intCast(j)]}) catch unreachable;
        arena.tmpbuf_add(&buf, s);
    }
    return arena.tmpbuf_arena(arena.dhall_arena.?, &buf);
}

pub fn bignat_is_zero(a: *const dhall.BigNat) bool {
    return a.nlimbs == 0;
}

pub fn bignat_even(a: *const dhall.BigNat) bool {
    return a.nlimbs == 0 or (a.limbs.?[0] & 1) == 0;
}

/// small<->big seam: view any Const (C_NAT) as a BigNat, using caller scratch
/// for the small path (no allocation for values < 2^64).
pub fn const_bignat(c: dhall.Const, scratch: *[2]u32) dhall.BigNat {
    if (c.bnat) |p| return p.*;
    const n = bignat_from_u64(c.nat, scratch);
    return dhall.BigNat{ .limbs = scratch, .nlimbs = n };
}

/// BigNat -> Const: small values (<= 2 limbs) narrow back to .nat; larger
/// allocate a BigNat and set .bnat.  Round-trips const_bignat exactly.
pub fn bignat_to_const(b: dhall.BigNat) dhall.Const {
    if (b.nlimbs <= 2) {
        var v: u64 = 0;
        if (b.nlimbs >= 1) v |= b.limbs.?[0];
        if (b.nlimbs >= 2) v |= @as(u64, b.limbs.?[1]) << 32;
        return dhall.Const{ .kind = .C_NAT, .nat = v, .i64 = 0, .dbl = 0, .b = false, .bnat = null, .big = null };
    }
    const p: *dhall.BigNat = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.BigNat))));
    p.* = b;
    return dhall.Const{ .kind = .C_NAT, .nat = 0, .i64 = 0, .dbl = 0, .b = false, .bnat = p, .big = null };
}

// ---------------- arbitrary-precision signed Integer ----------------

/// build a signed value, normalizing -0 (mag.nlimbs==0 => neg=false).
fn bi_mk(neg: bool, mag: dhall.BigNat) dhall.BigInt {
    var neg2 = neg;
    if (mag.nlimbs == 0) neg2 = false;
    return dhall.BigInt{ .neg = neg2, .mag = mag };
}

/// small<->big seam for C_INT: view any Const as a signed BigInt, using caller
/// scratch for the small path.  The i64 magnitude is computed without
/// INT64_MIN negation UB.
pub fn const_bigint(c: dhall.Const, scratch: *[2]u32) dhall.BigInt {
    if (c.big) |p| return p.*;
    const v = c.i64;
    const mag: u64 = if (v >= 0)
        @intCast(v)
    else
        (@as(u64, @intCast(-(v + 1))) + 1);
    const n = bignat_from_u64(mag, scratch);
    return dhall.BigInt{ .neg = v < 0, .mag = .{ .limbs = scratch, .nlimbs = n } };
}

/// BigInt -> Const: small magnitudes (|v| fits int64) narrow back to .i64;
/// larger allocate a BigInt and set .big (deep-copying the magnitude).
pub fn bigint_to_const(b: dhall.BigInt) dhall.Const {
    if (b.mag.nlimbs == 0)
        return dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = 0, .dbl = 0, .b = false, .bnat = null, .big = null };
    var ok: bool = false;
    const mag = bignat_to_u64(&b.mag, &ok);
    if (ok and !b.neg and mag <= std.math.maxInt(i64))
        return dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = @intCast(mag), .dbl = 0, .b = false, .bnat = null, .big = null };
    if (ok and b.neg and mag <= @as(u64, std.math.maxInt(i64)) + 1) {
        const v: i64 = if (mag == @as(u64, std.math.maxInt(i64)) + 1)
            std.math.minInt(i64)
        else
            -@as(i64, @intCast(mag));
        return dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = v, .dbl = 0, .b = false, .bnat = null, .big = null };
    }
    const p: *dhall.BigInt = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.BigInt))));
    p.neg = b.neg;
    p.mag.nlimbs = b.mag.nlimbs;
    p.mag.limbs = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(b.mag.nlimbs)) * 4)));
    @memcpy(p.mag.limbs.?[0..@as(usize, @intCast(b.mag.nlimbs))], b.mag.limbs.?[0..@as(usize, @intCast(b.mag.nlimbs))]);
    return dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = 0, .dbl = 0, .b = false, .bnat = null, .big = p };
}

pub fn bigint_add(a: *const dhall.BigInt, b: *const dhall.BigInt) dhall.BigInt {
    if (a.neg == b.neg) return bi_mk(a.neg, bignat_add(&a.mag, &b.mag));
    const c = bignat_cmp(&a.mag, &b.mag);
    if (c == 0) return bi_mk(false, dhall.BigNat{ .limbs = null, .nlimbs = 0 });
    if (c > 0) return bi_mk(a.neg, bignat_sub(&a.mag, &b.mag));
    return bi_mk(b.neg, bignat_sub(&b.mag, &a.mag));
}

pub fn bigint_sub(a: *const dhall.BigInt, b: *const dhall.BigInt) dhall.BigInt {
    const nb = bi_mk(!b.neg, b.mag);
    return bigint_add(a, &nb);
}

pub fn bigint_mul(a: *const dhall.BigInt, b: *const dhall.BigInt) dhall.BigInt {
    return bi_mk(a.neg != b.neg, bignat_mul(&a.mag, &b.mag));
}

pub fn bigint_neg(a: *const dhall.BigInt) dhall.BigInt {
    return bi_mk(!a.neg, a.mag);
}

pub fn bigint_cmp(a: *const dhall.BigInt, b: *const dhall.BigInt) c_int {
    if (a.neg != b.neg) return if (a.neg) -1 else 1;
    const c = bignat_cmp(&a.mag, &b.mag);
    return if (a.neg) -c else c;
}

/// signed decimal, arena-allocated; no leading '+' for non-negative values.
pub fn bigint_to_decimal(a: *const dhall.BigInt) [*:0]u8 {
    if (a.mag.nlimbs == 0) return arena.arena_strdup(arena.dhall_arena.?, "0");
    const d = bignat_to_decimal(&a.mag);
    if (!a.neg) return d;
    const len = std.mem.len(d);
    const s = arena.arena_alloc(arena.dhall_arena.?, len + 2);
    s[0] = '-';
    @memcpy(s[1 .. len + 1], d[0..len]);
    s[len + 1] = 0;
    return @ptrCast(s);
}

/// strtod over the decimal form; precision-loss, no error (matches Dhall).
pub fn bigint_to_double(a: *const dhall.BigInt) f64 {
    const d = bigint_to_decimal(a);
    return strtod(d, null);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
fn setArena() void {
    const a = arena.arena_new();
    arena.dhall_arena = a;
}

test "bignat decimal round-trip (incl. 2^64/2^128 boundaries)" {
    setArena();
    const cases = [_][]const u8{
        "0",
        "1",
        "9",
        "10",
        "99",
        "100",
        "999999999",
        "1000000000",
        "123456789",
        "18446744073709551615", // 2^64-1
        "18446744073709551616", // 2^64
        "9223372036854775808", // 2^63
        "340282366920938463463374607431768211455", // 2^128-1
        "340282366920938463463374607431768211456", // 2^128
        "10000000000000000000000000000000000000000000000000000",
    };
    for (cases) |s| {
        const b = bignat_from_decimal(s);
        const out = bignat_to_decimal(&b);
        try std.testing.expectEqualStrings(s, std.mem.span(out));
    }
}

test "bignat cmp at 2^64 boundary" {
    setArena();
    const a = bignat_from_decimal("18446744073709551615"); // 2^64-1
    const b = bignat_from_decimal("18446744073709551616"); // 2^64
    const zero = bignat_from_decimal("0");
    try std.testing.expect(bignat_cmp(&a, &b) < 0);
    try std.testing.expect(bignat_cmp(&b, &a) > 0);
    try std.testing.expect(bignat_cmp(&a, &a) == 0);
    try std.testing.expect(bignat_cmp(&zero, &a) < 0);
    try std.testing.expect(bignat_cmp(&a, &zero) > 0);
}

test "bignat add at 2^64 boundary" {
    setArena();
    const a = bignat_from_decimal("18446744073709551615"); // 2^64-1
    const one = bignat_from_decimal("1");
    const two = bignat_from_decimal("2");

    const sum = bignat_add(&a, &one);
    try std.testing.expectEqualStrings("18446744073709551616", std.mem.span(bignat_to_decimal(&sum)));

    // 2^64-1 + 2^64-1 = 2^65 - 2 = 36893488147419103230
    const s2 = bignat_add(&a, &a);
    try std.testing.expectEqualStrings("36893488147419103230", std.mem.span(bignat_to_decimal(&s2)));

    // 2^64 + 1 = 2^64+1
    const b = bignat_from_decimal("18446744073709551616"); // 2^64
    const s3 = bignat_add(&b, &one);
    try std.testing.expectEqualStrings("18446744073709551617", std.mem.span(bignat_to_decimal(&s3)));

    // 1 + 2 = 3
    const s4 = bignat_add(&one, &two);
    try std.testing.expectEqualStrings("3", std.mem.span(bignat_to_decimal(&s4)));
}

test "bignat sub at 2^64 boundary (saturating)" {
    setArena();
    const a = bignat_from_decimal("18446744073709551616"); // 2^64
    const b = bignat_from_decimal("18446744073709551615"); // 2^64-1
    const d = bignat_sub(&a, &b);
    try std.testing.expectEqualStrings("1", std.mem.span(bignat_to_decimal(&d)));

    // saturating: 5 - (2^64-1) = 0
    const five = bignat_from_decimal("5");
    const d2 = bignat_sub(&five, &b);
    try std.testing.expect(bignat_is_zero(&d2));
    try std.testing.expectEqualStrings("0", std.mem.span(bignat_to_decimal(&d2)));

    // 2^64 - 2^64 = 0
    const a2 = bignat_from_decimal("18446744073709551616");
    const d3 = bignat_sub(&a2, &a2);
    try std.testing.expect(bignat_is_zero(&d3));
}

test "bignat mul at 2^64 boundary" {
    setArena();
    const two_64 = bignat_from_decimal("18446744073709551616"); // 2^64
    const m = bignat_mul(&two_64, &two_64); // 2^128
    try std.testing.expectEqualStrings("340282366920938463463374607431768211456", std.mem.span(bignat_to_decimal(&m)));

    const a = bignat_from_decimal("18446744073709551615"); // 2^64-1
    const two = bignat_from_decimal("2");
    const m2 = bignat_mul(&a, &two); // 2^65 - 2
    try std.testing.expectEqualStrings("36893488147419103230", std.mem.span(bignat_to_decimal(&m2)));

    // 999999999 * 999999999 = 999999998000000001
    const x = bignat_from_decimal("999999999");
    const m3 = bignat_mul(&x, &x);
    try std.testing.expectEqualStrings("999999998000000001", std.mem.span(bignat_to_decimal(&m3)));
}

test "bigint signed round-trip + add/cmp at 2^63 boundary" {
    setArena();
    var s_min: [2]u32 = undefined;
    // INT64_MIN via const_bigint -> bigint_to_const round trip
    const cmin = dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = std.math.minInt(i64), .dbl = 0, .b = false, .bnat = null, .big = null };
    const bi_min = const_bigint(cmin, &s_min);
    try std.testing.expect(bi_min.neg);
    const c_back = bigint_to_const(bi_min);
    try std.testing.expectEqual(std.math.minInt(i64), c_back.i64);
    try std.testing.expectEqual(@as(?*dhall.BigInt, null), c_back.big);

    // INT64_MAX + 1 = 2^63 via bigint add (distinct scratch arrays so the two
    // BigInt operands do not alias each other's limb storage)
    var s_max: [2]u32 = undefined;
    const cmax = dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = std.math.maxInt(i64), .dbl = 0, .b = false, .bnat = null, .big = null };
    const bi_max = const_bigint(cmax, &s_max);
    var s_one: [2]u32 = undefined;
    const cone = dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = 1, .dbl = 0, .b = false, .bnat = null, .big = null };
    const bi_one = const_bigint(cone, &s_one);
    const bi_2_63 = bigint_add(&bi_max, &bi_one);
    try std.testing.expectEqualStrings("9223372036854775808", std.mem.span(bigint_to_decimal(&bi_2_63)));

    // 2^63 is big (doesn't fit i64), so bigint_to_const should allocate .big
    const c_2_63 = bigint_to_const(bi_2_63);
    try std.testing.expect(c_2_63.big != null);

    // bigint_to_decimal of the big 2^63 then round-trip back via const_bigint
    const decimal = bigint_to_decimal(&bi_2_63);
    try std.testing.expectEqualStrings("9223372036854775808", std.mem.span(decimal));

    // signed: -1 + 1 = 0 (neg-zero normalization)
    var s_neg1: [2]u32 = undefined;
    const cneg1 = dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = -1, .dbl = 0, .b = false, .bnat = null, .big = null };
    const bi_neg1 = const_bigint(cneg1, &s_neg1);
    const sum0 = bigint_add(&bi_neg1, &bi_one);
    try std.testing.expectEqualStrings("0", std.mem.span(bigint_to_decimal(&sum0)));
    try std.testing.expect(!sum0.neg); // -0 normalized to +0
}

test "bigint cmp and mul signed" {
    setArena();
    var s_n: [2]u32 = undefined;
    const cn = dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = -9223372036854775807, .dbl = 0, .b = false, .bnat = null, .big = null }; // -(2^63-1)
    const bi_n = const_bigint(cn, &s_n);
    var s_p: [2]u32 = undefined;
    const cp = dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = 9223372036854775807, .dbl = 0, .b = false, .bnat = null, .big = null }; // 2^63-1
    const bi_p = const_bigint(cp, &s_p);
    try std.testing.expect(bigint_cmp(&bi_n, &bi_p) < 0);
    try std.testing.expect(bigint_cmp(&bi_p, &bi_n) > 0);
    try std.testing.expect(bigint_cmp(&bi_p, &bi_p) == 0);

    // -(2^63-1) * -1 = 2^63-1
    var s_one_neg: [2]u32 = undefined;
    const cone = dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = -1, .dbl = 0, .b = false, .bnat = null, .big = null };
    const bi_one_neg = const_bigint(cone, &s_one_neg);
    const prod = bigint_mul(&bi_n, &bi_one_neg);
    try std.testing.expectEqualStrings("9223372036854775807", std.mem.span(bigint_to_decimal(&prod)));

    // 2^63-1 * 2 = 2^64-2 (big)
    var s_two: [2]u32 = undefined;
    const ctwo = dhall.Const{ .kind = .C_INT, .nat = 0, .i64 = 2, .dbl = 0, .b = false, .bnat = null, .big = null };
    const bi_two = const_bigint(ctwo, &s_two);
    const prod2 = bigint_mul(&bi_p, &bi_two);
    try std.testing.expectEqualStrings("18446744073709551614", std.mem.span(bigint_to_decimal(&prod2)));
}
