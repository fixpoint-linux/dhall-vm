// lsp_json.zig — port of ../src/json.c + json.h for the LSP JSON-RPC 2.0
// protocol. Minimal JSON decoder (heap tree) + encoder (to a growable buffer).
// Handles the full JSON grammar (objects, arrays, strings with \uXXXX escapes
// incl. surrogate pairs, numbers, true/false/null) and emits compact JSON (no
// insignificant whitespace), mirroring json.c's escaping so output is
// byte-identical. Out-of-memory is fatal (exit 3), matching json.c / arena.c.
//
// The C LSP (src/lsp.c) was the only consumer of src/json.c, so this port uses
// native Zig representations (a tagged union + slices) rather than the C ABI
// mirror layout. The writer buffer is std.ArrayList(u8) instead of dhall.h's
// TmpBuf — callers own and deinit it.

const std = @import("std");

const alloc = std.heap.c_allocator;

extern fn snprintf(str: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;

fn oom() noreturn {
    std.debug.print("dhall-lsp: out of memory\n", .{});
    std.c.exit(3);
}

// ---------------------------------------------------------------------------
// Value tree
// ---------------------------------------------------------------------------
pub const Json = union(enum) {
    null_,
    bool_: bool,
    num: f64,
    str: [:0]u8, // NUL-terminated, heap-allocated (malloc'd, like json.c)
    arr: []?*Json,
    obj: Obj,

    pub const Obj = struct {
        keys: [][:0]u8,
        vals: []?*Json,
    };
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------
const JP = struct {
    s: []const u8,
    i: usize = 0,
};

fn is_digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn is_ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn jskip_ws(jp: *JP) void {
    while (jp.i < jp.s.len and is_ws(jp.s[jp.i])) jp.i += 1;
}

fn hexval(c: u8) ?u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn read_hex4(jp: *JP) ?u32 {
    if (jp.s.len - jp.i < 4) return null;
    var u: u32 = 0;
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        const h = hexval(jp.s[jp.i + k]) orelse return null;
        u = (u << 4) | h;
    }
    jp.i += 4;
    return u;
}

fn put_utf8(out: *std.ArrayList(u8), cp: u32) void {
    if (cp < 0x80) {
        out.append(alloc, @intCast(cp)) catch oom();
    } else if (cp < 0x800) {
        out.append(alloc, @intCast(0xC0 | (cp >> 6))) catch oom();
        out.append(alloc, @intCast(0x80 | (cp & 0x3F))) catch oom();
    } else if (cp < 0x10000) {
        out.append(alloc, @intCast(0xE0 | (cp >> 12))) catch oom();
        out.append(alloc, @intCast(0x80 | ((cp >> 6) & 0x3F))) catch oom();
        out.append(alloc, @intCast(0x80 | (cp & 0x3F))) catch oom();
    } else {
        out.append(alloc, @intCast(0xF0 | (cp >> 18))) catch oom();
        out.append(alloc, @intCast(0x80 | ((cp >> 12) & 0x3F))) catch oom();
        out.append(alloc, @intCast(0x80 | ((cp >> 6) & 0x3F))) catch oom();
        out.append(alloc, @intCast(0x80 | (cp & 0x3F))) catch oom();
    }
}

fn jparse_string(jp: *JP) ?[:0]u8 {
    if (jp.i >= jp.s.len or jp.s[jp.i] != '"') return null;
    jp.i += 1;
    var out = std.ArrayList(u8).initCapacity(alloc, (jp.s.len - jp.i) + 1) catch oom();
    while (jp.i < jp.s.len) {
        const c = jp.s[jp.i];
        if (c == '"') {
            jp.i += 1;
            out.append(alloc, 0) catch oom();
            const owned = out.toOwnedSlice(alloc) catch oom();
            return owned[0 .. owned.len - 1 :0];
        }
        if (c == '\\') {
            jp.i += 1;
            if (jp.i >= jp.s.len) break;
            const e = jp.s[jp.i];
            jp.i += 1;
            switch (e) {
                '"' => out.append(alloc, '"') catch oom(),
                '\\' => out.append(alloc, '\\') catch oom(),
                '/' => out.append(alloc, '/') catch oom(),
                'b' => out.append(alloc, 8) catch oom(),
                'f' => out.append(alloc, 12) catch oom(),
                'n' => out.append(alloc, '\n') catch oom(),
                'r' => out.append(alloc, '\r') catch oom(),
                't' => out.append(alloc, '\t') catch oom(),
                'u' => {
                    const hi = read_hex4(jp) orelse {
                        out.deinit(alloc);
                        return null;
                    };
                    var cp: u32 = hi;
                    if (hi >= 0xD800 and hi <= 0xDBFF) {
                        if (jp.s.len - jp.i < 2 or jp.s[jp.i] != '\\' or jp.s[jp.i + 1] != 'u') {
                            out.deinit(alloc);
                            return null;
                        }
                        jp.i += 2;
                        const lo = read_hex4(jp) orelse {
                            out.deinit(alloc);
                            return null;
                        };
                        if (lo < 0xDC00 or lo > 0xDFFF) {
                            out.deinit(alloc);
                            return null;
                        }
                        cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                    } else if (hi >= 0xDC00 and hi <= 0xDFFF) {
                        // lone low surrogate: not valid Unicode in isolation
                        out.deinit(alloc);
                        return null;
                    }
                    put_utf8(&out, cp);
                },
                else => {
                    out.deinit(alloc);
                    return null;
                },
            }
        } else if (c < 0x20) {
            out.deinit(alloc);
            return null;
        } else {
            out.append(alloc, c) catch oom();
            jp.i += 1;
        }
    }
    out.deinit(alloc);
    return null;
}

fn jparse_string_node(jp: *JP) ?*Json {
    const s = jparse_string(jp) orelse return null;
    const v = alloc.create(Json) catch oom();
    v.* = .{ .str = s };
    return v;
}

fn jparse_number(jp: *JP) ?*Json {
    const start = jp.i;
    if (jp.i < jp.s.len and jp.s[jp.i] == '-') jp.i += 1;
    // integer part: at least one digit; no leading zero unless it is just "0"
    if (jp.i >= jp.s.len or !is_digit(jp.s[jp.i])) return null;
    if (jp.s[jp.i] == '0') {
        jp.i += 1;
        if (jp.i < jp.s.len and is_digit(jp.s[jp.i])) return null; // "01"
    } else {
        while (jp.i < jp.s.len and is_digit(jp.s[jp.i])) jp.i += 1;
    }
    if (jp.i < jp.s.len and jp.s[jp.i] == '.') {
        jp.i += 1;
        if (jp.i >= jp.s.len or !is_digit(jp.s[jp.i])) return null; // "1."
        while (jp.i < jp.s.len and is_digit(jp.s[jp.i])) jp.i += 1;
    }
    if (jp.i < jp.s.len and (jp.s[jp.i] == 'e' or jp.s[jp.i] == 'E')) {
        jp.i += 1;
        if (jp.i < jp.s.len and (jp.s[jp.i] == '+' or jp.s[jp.i] == '-')) jp.i += 1;
        if (jp.i >= jp.s.len or !is_digit(jp.s[jp.i])) return null; // "1e"
        while (jp.i < jp.s.len and is_digit(jp.s[jp.i])) jp.i += 1;
    }
    const tok = jp.s[start..jp.i];
    const d = std.fmt.parseFloat(f64, tok) catch return null;
    const v = alloc.create(Json) catch oom();
    v.* = .{ .num = d };
    return v;
}

fn jparse_array(jp: *JP) ?*Json {
    jp.i += 1; // '['
    const v = alloc.create(Json) catch oom();
    var items = std.ArrayList(?*Json).initCapacity(alloc, 4) catch oom();
    jskip_ws(jp);
    if (jp.i < jp.s.len and jp.s[jp.i] == ']') {
        jp.i += 1;
        v.* = .{ .arr = items.toOwnedSlice(alloc) catch oom() };
        return v;
    }
    while (true) {
        jskip_ws(jp);
        const item = jparse_value(jp) orelse {
            for (items.items) |it| json_free(it);
            items.deinit(alloc);
            alloc.destroy(v);
            return null;
        };
        items.append(alloc, item) catch oom();
        jskip_ws(jp);
        if (jp.i < jp.s.len and jp.s[jp.i] == ',') {
            jp.i += 1;
            continue;
        }
        if (jp.i < jp.s.len and jp.s[jp.i] == ']') {
            jp.i += 1;
            break;
        }
        for (items.items) |it| json_free(it);
        items.deinit(alloc);
        alloc.destroy(v);
        return null;
    }
    v.* = .{ .arr = items.toOwnedSlice(alloc) catch oom() };
    return v;
}

fn jparse_object(jp: *JP) ?*Json {
    jp.i += 1; // '{'
    const v = alloc.create(Json) catch oom();
    var keys = std.ArrayList([:0]u8).initCapacity(alloc, 8) catch oom();
    var vals = std.ArrayList(?*Json).initCapacity(alloc, 8) catch oom();
    // Free everything accumulated so far (keys strings, vals trees, arrays,
    // the Json value) — mirrors json.c's `goto fail`.  On malformed input the
    // C oracle frees all n accumulated pairs, not just the current one.
    // NOTE: `v` is destroyed WITHOUT recursing into its (never-initialized on
    // the fail path) `as` union — json_free would switch on garbage.  The
    // accumulated keys/vals are freed explicitly above.
    const fail = struct {
        fn freeIt(a: std.mem.Allocator, kv: *Json, k: ?[:0]u8, ks: *std.ArrayList([:0]u8), vs: *std.ArrayList(?*Json)) void {
            if (k) |kk| a.free(kk);
            for (ks.items) |kk| a.free(kk);
            for (vs.items) |vv| json_free(vv);
            ks.deinit(a);
            vs.deinit(a);
            a.destroy(kv);
        }
    }.freeIt;
    jskip_ws(jp);
    if (jp.i < jp.s.len and jp.s[jp.i] == '}') {
        jp.i += 1;
        v.* = .{ .obj = .{
            .keys = keys.toOwnedSlice(alloc) catch oom(),
            .vals = vals.toOwnedSlice(alloc) catch oom(),
        } };
        return v;
    }
    while (true) {
        jskip_ws(jp);
        const k = jparse_string(jp) orelse {
            fail(alloc, v, null, &keys, &vals);
            return null;
        };
        jskip_ws(jp);
        if (jp.i >= jp.s.len or jp.s[jp.i] != ':') {
            fail(alloc, v, k, &keys, &vals);
            return null;
        }
        jp.i += 1;
        jskip_ws(jp);
        const val = jparse_value(jp) orelse {
            fail(alloc, v, k, &keys, &vals);
            return null;
        };
        keys.append(alloc, k) catch oom();
        vals.append(alloc, val) catch oom();
        jskip_ws(jp);
        if (jp.i < jp.s.len and jp.s[jp.i] == ',') {
            jp.i += 1;
            continue;
        }
        if (jp.i < jp.s.len and jp.s[jp.i] == '}') {
            jp.i += 1;
            break;
        }
        fail(alloc, v, null, &keys, &vals);
        return null;
    }
    v.* = .{ .obj = .{
        .keys = keys.toOwnedSlice(alloc) catch oom(),
        .vals = vals.toOwnedSlice(alloc) catch oom(),
    } };
    return v;
}

fn jparse_value(jp: *JP) ?*Json {
    jskip_ws(jp);
    if (jp.i >= jp.s.len) return null;
    const c = jp.s[jp.i];
    switch (c) {
        '{' => return jparse_object(jp),
        '[' => return jparse_array(jp),
        '"' => return jparse_string_node(jp),
        't' => if (jp.s.len - jp.i >= 4 and std.mem.eql(u8, jp.s[jp.i .. jp.i + 4], "true")) {
            jp.i += 4;
            const v = alloc.create(Json) catch oom();
            v.* = .{ .bool_ = true };
            return v;
        },
        'f' => if (jp.s.len - jp.i >= 5 and std.mem.eql(u8, jp.s[jp.i .. jp.i + 5], "false")) {
            jp.i += 5;
            const v = alloc.create(Json) catch oom();
            v.* = .{ .bool_ = false };
            return v;
        },
        'n' => if (jp.s.len - jp.i >= 4 and std.mem.eql(u8, jp.s[jp.i .. jp.i + 4], "null")) {
            jp.i += 4;
            const v = alloc.create(Json) catch oom();
            v.* = .null_;
            return v;
        },
        else => {},
    }
    if (c == '-' or is_digit(c)) return jparse_number(jp);
    return null;
}

pub fn json_parse(s: []const u8) ?*Json {
    var jp = JP{ .s = s };
    const v = jparse_value(&jp) orelse return null;
    jskip_ws(&jp);
    if (jp.i != jp.s.len) {
        json_free(v);
        return null;
    }
    return v;
}

pub fn json_free(v: ?*Json) void {
    const vv = v orelse return;
    switch (vv.*) {
        .str => |s| alloc.free(s),
        .arr => |items| {
            for (items) |it| json_free(it);
            alloc.free(items);
        },
        .obj => |o| {
            for (o.keys) |k| alloc.free(k);
            for (o.vals) |val| json_free(val);
            alloc.free(o.keys);
            alloc.free(o.vals);
        },
        else => {},
    }
    alloc.destroy(vv);
}

// ---------------------------------------------------------------------------
// Accessors (all NULL-safe)
// ---------------------------------------------------------------------------
pub fn json_obj_get(v: ?*Json, key: []const u8) ?*Json {
    const vv = v orelse return null;
    return switch (vv.*) {
        .obj => |o| blk: {
            for (o.keys, o.vals) |k, val| {
                if (std.mem.eql(u8, k, key)) break :blk val;
            }
            break :blk null;
        },
        else => null,
    };
}

pub fn json_str(v: ?*Json) ?[:0]const u8 {
    const vv = v orelse return null;
    return switch (vv.*) {
        .str => |s| s,
        else => null,
    };
}

pub fn json_num(v: ?*Json) f64 {
    const vv = v orelse return 0.0;
    return switch (vv.*) {
        .num => |d| d,
        else => 0.0,
    };
}

pub fn json_arr_get(v: ?*Json, i: usize) ?*Json {
    const vv = v orelse return null;
    return switch (vv.*) {
        .arr => |items| if (i < items.len) items[i] else null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Writer (appends to a std.ArrayList(u8))
// ---------------------------------------------------------------------------
pub fn write_raw(b: *std.ArrayList(u8), s: []const u8) void {
    b.appendSlice(alloc, s) catch oom();
}

pub fn write_string(b: *std.ArrayList(u8), s: []const u8) void {
    b.append(alloc, '"') catch oom();
    for (s) |ch| {
        switch (ch) {
            '"' => b.appendSlice(alloc, "\\\"") catch oom(),
            '\\' => b.appendSlice(alloc, "\\\\") catch oom(),
            8 => b.appendSlice(alloc, "\\b") catch oom(),
            12 => b.appendSlice(alloc, "\\f") catch oom(),
            '\n' => b.appendSlice(alloc, "\\n") catch oom(),
            '\r' => b.appendSlice(alloc, "\\r") catch oom(),
            '\t' => b.appendSlice(alloc, "\\t") catch oom(),
            else => {
                if (ch < 0x20) {
                    var esc: [8]u8 = undefined;
                    const n = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{ch}) catch unreachable;
                    b.appendSlice(alloc, n) catch oom();
                } else {
                    b.append(alloc, ch) catch oom();
                }
            },
        }
    }
    b.append(alloc, '"') catch oom();
}

pub fn write_key(b: *std.ArrayList(u8), k: []const u8) void {
    write_string(b, k);
    b.append(alloc, ':') catch oom();
}

pub fn write_int(b: *std.ArrayList(u8), v: i64) void {
    var buf: [32]u8 = undefined;
    const n = snprintf(&buf, buf.len, "%lld", @as(c_longlong, v));
    b.appendSlice(alloc, buf[0..@intCast(n)]) catch oom();
}

pub fn write_bool(b: *std.ArrayList(u8), v: bool) void {
    b.appendSlice(alloc, if (v) "true" else "false") catch oom();
}

pub fn write_null(b: *std.ArrayList(u8)) void {
    b.appendSlice(alloc, "null") catch oom();
}

fn num_is_integral(v: f64) bool {
    if (!std.math.isFinite(v)) return false;
    if (v < -9223372036854775808.0 or v >= 9223372036854775808.0) return false;
    return @trunc(v) == v;
}

pub fn emit(b: *std.ArrayList(u8), v: ?*Json) void {
    const vv = v orelse {
        write_null(b);
        return;
    };
    switch (vv.*) {
        .null_ => write_null(b),
        .bool_ => |x| write_bool(b, x),
        .num => |x| {
            if (num_is_integral(x)) {
                write_int(b, @intFromFloat(x));
            } else {
                var buf: [48]u8 = undefined;
                const n = snprintf(&buf, buf.len, "%.17g", x);
                b.appendSlice(alloc, buf[0..@intCast(n)]) catch oom();
            }
        },
        .str => |s| write_string(b, s),
        .arr => |items| {
            b.append(alloc, '[') catch oom();
            for (items, 0..) |it, i| {
                if (i != 0) b.append(alloc, ',') catch oom();
                emit(b, it);
            }
            b.append(alloc, ']') catch oom();
        },
        .obj => |o| {
            b.append(alloc, '{') catch oom();
            for (o.keys, o.vals, 0..) |k, val, i| {
                if (i != 0) b.append(alloc, ',') catch oom();
                write_key(b, k);
                emit(b, val);
            }
            b.append(alloc, '}') catch oom();
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn parse_and_emit(input: []const u8) ![]u8 {
    const root = json_parse(input) orelse return error.Malformed;
    defer json_free(root);
    var b = try std.ArrayList(u8).initCapacity(alloc, 64);
    defer b.deinit(alloc);
    emit(&b, root);
    return b.toOwnedSlice(alloc);
}

test "round-trip compact JSON" {
    const out = try parse_and_emit(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"a":[1,2,3],"b":true,"c":null}}
    );
    defer alloc.free(out);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"a":[1,2,3],"b":true,"c":null}}
    , out);
}

test "string escapes incl surrogate pair" {
    const out = try parse_and_emit(
        \\{"s":"a\"b\\c\n\t\u0041\ud834\udd1e"}
    );
    defer alloc.free(out);
    // \u0041 -> A ; \ud834\udd1e -> U+1D11E (UTF-8 F0 9D 84 9E)
    try testing.expectEqualStrings("{\"s\":\"a\\\"b\\\\c\\n\\tA\xF0\x9D\x84\x9E\"}", out);
}

test "malformed inputs rejected" {
    try testing.expect(json_parse("") == null);
    try testing.expect(json_parse("{") == null);
    try testing.expect(json_parse("[1,]") == null);
    try testing.expect(json_parse("01") == null);
    try testing.expect(json_parse("1.") == null);
    try testing.expect(json_parse("\"\\u12\"") == null); // truncated escape
    try testing.expect(json_parse("{\"a\":1,}") == null);
    try testing.expect(json_parse("tru") == null);
    try testing.expect(json_parse("{}x") == null); // trailing garbage
    try testing.expect(json_parse("  {\"k\":1.5e2}  ") != null);
}
