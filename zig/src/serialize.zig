// serialize.zig — serializes a normal-form term to JSON, YAML, or TOML.
// Verbatim port of ../src/serialize.c. Builds a small format-independent Value
// tree once via a single shared descent (term_to_value), then emits it with a
// format-specific writer. term_to_value errors (ERR_SERIALIZE stage) on
// functions/Pis/types/sorts and any non-value construct in normal form, and
// PROPAGATES nested errors so a non-value anywhere in the tree fails the whole
// serialization. JSON emits NaN/Infinity as null (JSON has no representation);
// TOML requires a record at the top level and has no null; YAML uses block
// style (YAML 1.2 core schema).
//
// All double formatting routes through ast.dbl_fmt (extern libc snprintf/
// strtod, U4) — NOT reimplemented here.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const ast = @import("ast.zig");
const bignum = @import("bignum.zig");

extern fn strtod(nptr: [*:0]const u8, endptr: ?*[*c]u8) f64;

fn format_name(fmt: dhall.SerFormat) []const u8 {
    return switch (fmt) {
        .FMT_JSON => "JSON",
        .FMT_TOML => "TOML",
        .FMT_YAML => "YAML",
    };
}

/// set an ERR_SERIALIZE error on *err if non-null (C's dhall_error_set(err,...)
/// is a no-op when err == NULL).
fn serr(err: ?*dhall.DhallError, comptime fmt: []const u8, args: anytype) void {
    if (err) |e| ast.dhall_error_set(e, dhall.ErrorStage.ERR_SERIALIZE, dhall.SPAN_NONE, fmt, args);
}

// ---------------- Value constructors ----------------

fn allocV() *dhall.Value {
    const p = arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.Value));
    return @ptrCast(@alignCast(p));
}

fn vnull() *dhall.Value {
    const v = allocV();
    v.kind = .VK_NULL;
    return v;
}
fn vnat(n: u64) *dhall.Value {
    const v = allocV();
    v.kind = .VK_NAT;
    v.as.nat = n;
    return v;
}
fn vnat_big(b: *dhall.BigNat) *dhall.Value {
    const v = allocV();
    v.kind = .VK_NAT;
    v.nat_big = true;
    v.as.bnat = b;
    return v;
}
fn vint(n: i64) *dhall.Value {
    const v = allocV();
    v.kind = .VK_INT;
    v.as.i64 = n;
    return v;
}
fn vint_big(b: *dhall.BigInt) *dhall.Value {
    const v = allocV();
    v.kind = .VK_INT;
    v.int_big = true;
    v.as.big = b;
    return v;
}
fn vdbl(d: f64) *dhall.Value {
    const v = allocV();
    v.kind = .VK_DBL;
    v.as.dbl = d;
    return v;
}
fn vbool(b: bool) *dhall.Value {
    const v = allocV();
    v.kind = .VK_BOOL;
    v.as.b = b;
    return v;
}
fn vtext(s: [*:0]const u8) *dhall.Value {
    const v = allocV();
    v.kind = .VK_TEXT;
    v.as.text = arena.arena_strdup(arena.dhall_arena.?, std.mem.span(s));
    return v;
}
fn varr(items: ?[*]?*dhall.Value, n: c_int) *dhall.Value {
    const v = allocV();
    v.kind = .VK_ARRAY;
    v.as.arr = .{ .items = items, .n = n };
    return v;
}
fn vtab(keys: ?[*]?[*:0]u8, vals: ?[*]?*dhall.Value, n: c_int) *dhall.Value {
    const v = allocV();
    v.kind = .VK_TABLE;
    v.as.tab = .{ .keys = keys, .vals = vals, .n = n };
    return v;
}

// ---------------- shared descent: Term -> Value ----------------

fn term_to_value(t: *dhall.Term, fmt: dhall.SerFormat, err: ?*dhall.DhallError) ?*dhall.Value {
    switch (t.tag) {
        .TmConst => return switch (t.as.c.kind) {
            .C_NAT => if (t.as.c.bnat) |b| vnat_big(b) else vnat(t.as.c.nat),
            .C_INT => if (t.as.c.big) |b| vint_big(b) else vint(t.as.c.i64),
            .C_DBL => vdbl(t.as.c.dbl),
            .C_BOOL => vbool(t.as.c.b),
        },
        .TmText => {
            if (t.as.text == null) {
                serr(err, "text interpolation not normalized", .{});
                return null;
            }
            var p = t.as.text.?;
            while (true) {
                if (p.expr != null) {
                    serr(err, "text interpolation not normalized", .{});
                    return null;
                }
                if (p.next == null) break;
                p = p.next.?;
            }
            return vtext(p.lit.?);
        },
        .TmRecordLit => {
            const n = t.as.rec.n;
            const keys: [*]?[*:0]u8 = @ptrCast(@alignCast(arena.arena_alloc(
                arena.dhall_arena.?,
                @sizeOf(?[*:0]u8) * @as(usize, @intCast(if (n > 0) n else 1)),
            )));
            const vals: [*]?*dhall.Value = @ptrCast(@alignCast(arena.arena_alloc(
                arena.dhall_arena.?,
                @sizeOf(?*dhall.Value) * @as(usize, @intCast(if (n > 0) n else 1)),
            )));
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const v = term_to_value(t.as.rec.fs.?[@intCast(i)].value.?, fmt, err) orelse return null;
                keys[@intCast(i)] = t.as.rec.fs.?[@intCast(i)].label;
                vals[@intCast(i)] = v;
            }
            return vtab(keys, vals, n);
        },
        .TmNil => return varr(null, 0),
        .TmCons => {
            var n: c_int = 0;
            var pc = t;
            while (pc.tag == .TmCons) : (pc = pc.as.cons.tail.?) n += 1;
            const items: [*]?*dhall.Value = @ptrCast(@alignCast(arena.arena_alloc(
                arena.dhall_arena.?,
                @sizeOf(?*dhall.Value) * @as(usize, @intCast(if (n > 0) n else 1)),
            )));
            var i: c_int = 0;
            var q = t;
            while (q.tag == .TmCons) : (q = q.as.cons.tail.?) {
                const v = term_to_value(q.as.cons.head.?, fmt, err) orelse return null;
                items[@intCast(i)] = v;
                i += 1;
            }
            return varr(items, n);
        },
        .TmUnionLit => {
            // union -> single-key table with the selected alternative
            const n = t.as.uni.n;
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                if (t.as.uni.fs.?[@intCast(i)].value) |fv| {
                    const v = term_to_value(fv, fmt, err) orelse return null;
                    const keys: [*]?[*:0]u8 = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(?[*:0]u8))));
                    const vals: [*]?*dhall.Value = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(?*dhall.Value))));
                    keys[0] = t.as.uni.fs.?[@intCast(i)].label;
                    vals[0] = v;
                    return vtab(keys, vals, 1);
                }
            }
            return vtab(null, null, 0); // unreachable in this subset
        },
        .TmSome => return term_to_value(t.as.some.val.?, fmt, err),
        .TmNone => return vnull(),
        .TmLam, .TmPi => {
            serr(err, "cannot serialize a function/Pi to {s}", .{format_name(fmt)});
            return null;
        },
        .TmType, .TmKind, .TmSort => {
            serr(err, "cannot serialize a sort/type to {s}", .{format_name(fmt)});
            return null;
        },
        .TmVar, .TmApp, .TmField, .TmMerge, .TmRecordType, .TmUnionType,
        .TmTextAppend, .TmLet, .TmIf, .TmAnn, .TmBuiltin, .TmOp, .TmAssert,
        .TmToMap, .TmCombine, .TmWith, .TmListAppend, .TmPrefer,
        => {
            serr(err, "cannot serialize a non-value to {s}", .{format_name(fmt)});
            return null;
        },
    }
}

// ---------------- helpers ----------------

fn fmt_u64(out: ast.Out, n: u64) void {
    var b: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{d}", .{n}) catch unreachable;
    out.str(s);
}
fn fmt_i64(out: ast.Out, n: i64) void {
    var b: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{d}", .{n}) catch unreachable;
    out.str(s);
}

/// shared double-quoted escaper (JSON basic string / TOML basic string / YAML dq)
fn qstr(out: ast.Out, s: [*:0]const u8) void {
    out.chr('"');
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        switch (s[i]) {
            '"' => out.str("\\\""),
            '\\' => out.str("\\\\"),
            8 => out.str("\\b"),
            12 => out.str("\\f"),
            '\n' => out.str("\\n"),
            '\r' => out.str("\\r"),
            '\t' => out.str("\\t"),
            else => {
                if (s[i] < 0x20) {
                    var b: [8]u8 = undefined;
                    const hex = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{s[i]}) catch unreachable;
                    out.str(hex);
                } else {
                    out.chr(s[i]);
                }
            },
        }
    }
    out.chr('"');
}

fn dbl_json(out: ast.Out, d: f64) void {
    if (!std.math.isFinite(d)) {
        out.str("null");
    } else {
        var b: [64]u8 = undefined;
        ast.dbl_fmt(&b, 64, d);
        out.cstr(@ptrCast(&b));
    }
}
fn dbl_yaml(out: ast.Out, d: f64) void {
    if (std.math.isNan(d)) {
        out.str(".nan");
    } else if (d == std.math.inf(f64)) {
        out.str(".inf");
    } else if (d == -std.math.inf(f64)) {
        out.str("-.inf");
    } else {
        var b: [64]u8 = undefined;
        ast.dbl_fmt(&b, 64, d);
        out.cstr(@ptrCast(&b));
    }
}
fn dbl_toml(out: ast.Out, d: f64) void {
    if (std.math.isNan(d)) {
        out.str("nan");
    } else if (d == std.math.inf(f64)) {
        out.str("inf");
    } else if (d == -std.math.inf(f64)) {
        out.str("-inf");
    } else {
        var b: [64]u8 = undefined;
        ast.dbl_fmt(&b, 64, d);
        out.cstr(@ptrCast(&b));
    }
}

/// TOML key: bare iff [A-Za-z0-9_-]+ and not a reserved word, else basic-quoted
fn toml_key(out: ast.Out, k: [*:0]const u8) void {
    var bare = k[0] != 0;
    if (bare) {
        var i: usize = 0;
        while (k[i] != 0) : (i += 1) {
            const c = k[i];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) {
                bare = false;
                break;
            }
        }
    }
    if (bare) {
        const ks = std.mem.span(k);
        if (std.mem.eql(u8, ks, "true") or std.mem.eql(u8, ks, "false") or
            std.mem.eql(u8, ks, "inf") or std.mem.eql(u8, ks, "nan")) bare = false;
    }
    if (bare) out.cstr(k) else qstr(out, k);
}

/// Like toml_key but into a (quoted-or-bare) arena string, for table headers.
fn toml_key_str(k: [*:0]const u8) [*:0]u8 {
    var bare = k[0] != 0;
    if (bare) {
        var i: usize = 0;
        while (k[i] != 0) : (i += 1) {
            const c = k[i];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) {
                bare = false;
                break;
            }
        }
    }
    if (bare) {
        const ks = std.mem.span(k);
        if (std.mem.eql(u8, ks, "true") or std.mem.eql(u8, ks, "false") or
            std.mem.eql(u8, ks, "inf") or std.mem.eql(u8, ks, "nan")) bare = false;
    }
    if (bare) return arena.arena_strdup(arena.dhall_arena.?, std.mem.span(k));
    var b = std.ArrayList(u8).initCapacity(arena.dhall_arena.?.allocator(), 32) catch unreachable;
    const out = ast.Out{ .b = &b };
    qstr(out, k);
    b.append(arena.dhall_arena.?.allocator(), 0) catch unreachable;
    return @ptrCast(b.items.ptr);
}

// ---------------- JSON emitter ----------------

fn json_value(out: ast.Out, v: *const dhall.Value) void {
    switch (v.kind) {
        .VK_NULL => out.str("null"),
        .VK_NAT => {
            if (v.nat_big) out.cstr(bignum.bignat_to_decimal(v.as.bnat.?)) else fmt_u64(out, v.as.nat);
        },
        .VK_INT => {
            if (v.int_big) out.cstr(bignum.bigint_to_decimal(v.as.big.?)) else fmt_i64(out, v.as.i64);
        },
        .VK_DBL => dbl_json(out, v.as.dbl),
        .VK_BOOL => out.str(if (v.as.b) "true" else "false"),
        .VK_TEXT => qstr(out, v.as.text.?),
        .VK_ARRAY => {
            out.chr('[');
            var i: c_int = 0;
            while (i < v.as.arr.n) : (i += 1) {
                if (i != 0) out.chr(',');
                json_value(out, v.as.arr.items.?[@intCast(i)].?);
            }
            out.chr(']');
        },
        .VK_TABLE => {
            out.chr('{');
            var i: c_int = 0;
            while (i < v.as.tab.n) : (i += 1) {
                if (i != 0) out.chr(',');
                qstr(out, v.as.tab.keys.?[@intCast(i)].?);
                out.chr(':');
                json_value(out, v.as.tab.vals.?[@intCast(i)].?);
            }
            out.chr('}');
        },
    }
}

fn value_to_json(out: ast.Out, v: *const dhall.Value, err: ?*dhall.DhallError) bool {
    _ = err;
    json_value(out, v);
    return true;
}

// ---------------- YAML emitter (block style, 2-space indent, 1.2 core) ----------------

fn yaml_ind(out: ast.Out, n: c_int) void {
    var i: c_int = 0;
    while (i < n) : (i += 1) out.chr(' ');
}

/// conservative: quote unless we can prove the string is a safe plain scalar
fn yaml_plain_ok(s: [*:0]const u8) bool {
    const ss = std.mem.span(s);
    const slen = ss.len;
    if (slen == 0) return false;
    if (s[0] == ' ' or s[0] == '\t') return false;
    const lead = "-?:,[]{}#&*!|>'\"%@`";
    if (std.mem.indexOfScalar(u8, lead, s[0]) != null) return false;
    if (ss[slen - 1] == ' ' or ss[slen - 1] == '\t' or ss[slen - 1] == ':') return false;
    if (std.mem.indexOfScalar(u8, ss, '\n') != null) return false;
    if (std.mem.indexOfScalar(u8, ss, '\t') != null) return false;
    if (std.mem.indexOf(u8, ss, ": ") != null) return false;
    if (std.mem.indexOf(u8, ss, " #") != null) return false;
    var i: usize = 0;
    while (i < slen) : (i += 1) if (ss[i] < 0x20) return false;
    const res = [_][]const u8{ "null", "~", "true", "false", "True", "False", "TRUE", "FALSE", "Null", "NULL" };
    for (res) |r| if (std.mem.eql(u8, ss, r)) return false;
    var end: [*c]u8 = undefined;
    _ = strtod(s, &end);
    if (end != null) {
        if (end.* == 0 and @intFromPtr(end) != @intFromPtr(s)) return false;
    }
    // YAML 1.2 core-schema ints strtod does not recognize: 0o octal (and
    // 0x/0b hex/binary on libcs where strtod needs a 'p' exponent).
    if (slen >= 3 and s[0] == '0' and (s[1] == 'o' or s[1] == 'O' or s[1] == 'x' or s[1] == 'X' or s[1] == 'b' or s[1] == 'B'))
        return false;
    return true;
}

fn yaml_scalar(out: ast.Out, v: *const dhall.Value) void {
    switch (v.kind) {
        .VK_NULL => out.str("null"),
        .VK_NAT => {
            if (v.nat_big) out.cstr(bignum.bignat_to_decimal(v.as.bnat.?)) else fmt_u64(out, v.as.nat);
        },
        .VK_INT => {
            if (v.int_big) out.cstr(bignum.bigint_to_decimal(v.as.big.?)) else fmt_i64(out, v.as.i64);
        },
        .VK_DBL => dbl_yaml(out, v.as.dbl),
        .VK_BOOL => out.str(if (v.as.b) "true" else "false"),
        .VK_TEXT => {
            if (yaml_plain_ok(v.as.text.?)) out.cstr(v.as.text.?) else qstr(out, v.as.text.?);
        },
        else => {},
    }
}

fn yaml_key(out: ast.Out, k: [*:0]const u8) void {
    if (yaml_plain_ok(k)) out.cstr(k) else qstr(out, k);
}
fn yaml_is_scalar(v: *const dhall.Value) bool {
    return v.kind != .VK_ARRAY and v.kind != .VK_TABLE;
}
fn yaml_is_empty(v: *const dhall.Value) bool {
    return (v.kind == .VK_ARRAY and v.as.arr.n == 0) or (v.kind == .VK_TABLE and v.as.tab.n == 0);
}

fn yaml_emit_field(out: ast.Out, key: [*:0]const u8, val: *const dhall.Value, ind: c_int) void {
    yaml_ind(out, ind);
    yaml_key(out, key);
    out.chr(':');
    if (yaml_is_scalar(val)) {
        out.chr(' ');
        yaml_scalar(out, val);
        out.chr('\n');
    } else if (yaml_is_empty(val)) {
        out.chr(' ');
        out.str(if (val.kind == .VK_ARRAY) "[]" else "{}");
        out.chr('\n');
    } else {
        out.chr('\n');
        yaml_emit(out, val, ind + 2);
    }
}
fn yaml_emit(out: ast.Out, v: *const dhall.Value, ind: c_int) void {
    switch (v.kind) {
        .VK_ARRAY => {
            if (v.as.arr.n == 0) {
                out.str("[]");
            } else {
                var i: c_int = 0;
                while (i < v.as.arr.n) : (i += 1) {
                const it = v.as.arr.items.?[@intCast(i)].?;
                if (yaml_is_scalar(it)) {
                    yaml_ind(out, ind);
                    out.str("- ");
                    yaml_scalar(out, it);
                    out.chr('\n');
                } else if (yaml_is_empty(it)) {
                    yaml_ind(out, ind);
                    out.str("- ");
                    out.str(if (it.kind == .VK_ARRAY) "[]" else "{}");
                    out.chr('\n');
                } else if (it.kind == .VK_TABLE) {
                    yaml_ind(out, ind);
                    out.str("- ");
                    yaml_key(out, it.as.tab.keys.?[0].?);
                    out.chr(':');
                    const fv = it.as.tab.vals.?[0].?;
                    if (yaml_is_scalar(fv)) {
                        out.chr(' ');
                        yaml_scalar(out, fv);
                        out.chr('\n');
                    } else if (yaml_is_empty(fv)) {
                        out.chr(' ');
                        out.str(if (fv.kind == .VK_ARRAY) "[]" else "{}");
                        out.chr('\n');
                    } else {
                        out.chr('\n');
                        yaml_emit(out, fv, ind + 4);
                    }
                    var j: c_int = 1;
                    while (j < it.as.tab.n) : (j += 1)
                        yaml_emit_field(out, it.as.tab.keys.?[@intCast(j)].?, it.as.tab.vals.?[@intCast(j)].?, ind + 2);
                } else {
                    yaml_ind(out, ind);
                    out.str("-\n");
                    yaml_emit(out, it, ind + 2);
                }
            }
            }
        },
        .VK_TABLE => {
            if (v.as.tab.n == 0) {
                out.str("{}");
            } else {
                var i: c_int = 0;
                while (i < v.as.tab.n) : (i += 1)
                    yaml_emit_field(out, v.as.tab.keys.?[@intCast(i)].?, v.as.tab.vals.?[@intCast(i)].?, ind);
            }
        },
        else => yaml_scalar(out, v),
    }
}

fn value_to_yaml(out: ast.Out, v: *const dhall.Value, err: ?*dhall.DhallError) bool {
    _ = err;
    if (v.kind == .VK_ARRAY or v.kind == .VK_TABLE) {
        yaml_emit(out, v, 0);
        // non-empty arrays/tables already end with '\n'; empty ones and scalars do not
        if ((v.kind == .VK_ARRAY and v.as.arr.n == 0) or (v.kind == .VK_TABLE and v.as.tab.n == 0))
            out.chr('\n');
    } else {
        yaml_scalar(out, v);
        out.chr('\n');
    }
    return true;
}

// ---------------- TOML emitter ----------------

fn toml_value(out: ast.Out, v: *const dhall.Value, err: ?*dhall.DhallError) bool {
    switch (v.kind) {
        .VK_NAT => {
            if (v.nat_big) {
                serr(err, "Natural exceeds TOML signed 64-bit range", .{});
                return false;
            }
            if (v.as.nat > @as(u64, @intCast(std.math.maxInt(i64)))) {
                serr(err, "Natural exceeds TOML signed 64-bit range", .{});
                return false;
            }
            fmt_u64(out, v.as.nat);
            return true;
        },
        .VK_INT => {
            if (v.int_big) {
                serr(err, "Integer exceeds TOML signed 64-bit range", .{});
                return false;
            }
            fmt_i64(out, v.as.i64);
            return true;
        },
        .VK_DBL => {
            dbl_toml(out, v.as.dbl);
            return true;
        },
        .VK_BOOL => {
            out.str(if (v.as.b) "true" else "false");
            return true;
        },
        .VK_TEXT => {
            qstr(out, v.as.text.?);
            return true;
        },
        .VK_NULL => {
            serr(err, "cannot serialize null (None) to TOML", .{});
            return false;
        },
        .VK_ARRAY => {
            out.chr('[');
            var i: c_int = 0;
            while (i < v.as.arr.n) : (i += 1) {
                if (i != 0) out.str(", ");
                if (!toml_value(out, v.as.arr.items.?[@intCast(i)].?, err)) return false;
            }
            out.chr(']');
            return true;
        },
        .VK_TABLE => {
            out.str("{ ");
            var i: c_int = 0;
            while (i < v.as.tab.n) : (i += 1) {
                if (i != 0) out.str(", ");
                toml_key(out, v.as.tab.keys.?[@intCast(i)].?);
                out.str(" = ");
                if (!toml_value(out, v.as.tab.vals.?[@intCast(i)].?, err)) return false;
            }
            out.str(" }");
            return true;
        },
    }
    return true;
}

/// two-pass: scalar/array fields first (key = value), then table fields as [a.b] headers
fn toml_table(out: ast.Out, v: *const dhall.Value, prefix: [*:0]const u8, err: ?*dhall.DhallError) bool {
    const plen = std.mem.len(prefix);
    var i: c_int = 0;
    while (i < v.as.tab.n) : (i += 1) {
        if (v.as.tab.vals.?[@intCast(i)].?.kind != .VK_TABLE) {
            toml_key(out, v.as.tab.keys.?[@intCast(i)].?);
            out.str(" = ");
            if (!toml_value(out, v.as.tab.vals.?[@intCast(i)].?, err)) return false;
            out.chr('\n');
        }
    }
    i = 0;
    while (i < v.as.tab.n) : (i += 1) {
        if (v.as.tab.vals.?[@intCast(i)].?.kind == .VK_TABLE) {
            const krend = toml_key_str(v.as.tab.keys.?[@intCast(i)].?);
            const klen = std.mem.len(krend);
            const hdr: [*:0]u8 = @ptrCast(arena.arena_alloc(arena.dhall_arena.?, plen + klen + 1));
            @memcpy(hdr[0..plen], prefix[0..plen]);
            @memcpy(hdr[plen .. plen + klen], krend[0..klen]);
            hdr[plen + klen] = 0;
            out.str("[");
            out.cstr(hdr);
            out.str("]\n");
            const np: [*:0]u8 = @ptrCast(arena.arena_alloc(arena.dhall_arena.?, plen + klen + 2));
            @memcpy(np[0 .. plen + klen], hdr[0 .. plen + klen]);
            np[plen + klen] = '.';
            np[plen + klen + 1] = 0;
            if (!toml_table(out, v.as.tab.vals.?[@intCast(i)].?, np, err)) return false;
        }
    }
    return true;
}

/// Pre-flight: find the first TOML-invalid value (null, or a Natural that
/// exceeds TOML's signed 64-bit integer range) so we can fail cleanly before
/// emitting any partial output.
fn toml_find_bad(v: *const dhall.Value) ?*const dhall.Value {
    if (v.kind == .VK_NULL) return v;
    if (v.kind == .VK_NAT and (v.nat_big or v.as.nat > @as(u64, @intCast(std.math.maxInt(i64))))) return v;
    if (v.kind == .VK_INT and v.int_big) return v;
    if (v.kind == .VK_ARRAY) {
        var i: c_int = 0;
        while (i < v.as.arr.n) : (i += 1) {
            const b = toml_find_bad(v.as.arr.items.?[@intCast(i)].?);
            if (b) |bb| return bb;
        }
    } else if (v.kind == .VK_TABLE) {
        var i: c_int = 0;
        while (i < v.as.tab.n) : (i += 1) {
            const b = toml_find_bad(v.as.tab.vals.?[@intCast(i)].?);
            if (b) |bb| return bb;
        }
    }
    return null;
}

fn value_to_toml(out: ast.Out, v: *const dhall.Value, err: ?*dhall.DhallError) bool {
    if (v.kind != .VK_TABLE) {
        serr(err, "TOML requires the top-level value to be a record", .{});
        return false;
    }
    const bad = toml_find_bad(v);
    if (bad) |badv| {
        if (badv.kind == .VK_NULL)
            serr(err, "cannot serialize null (None) to TOML", .{})
        else if (badv.kind == .VK_INT)
            serr(err, "Integer exceeds TOML signed 64-bit range", .{})
        else
            serr(err, "Natural exceeds TOML signed 64-bit range", .{});
        return false;
    }
    return toml_table(out, v, "", err);
}

// ---------------- public wrappers ----------------

pub fn term_serialize(out: ast.Out, t: *dhall.Term, fmt: dhall.SerFormat, err: ?*dhall.DhallError) bool {
    const v = term_to_value(t, fmt, err) orelse return false;
    return switch (fmt) {
        .FMT_JSON => value_to_json(out, v, err),
        .FMT_YAML => value_to_yaml(out, v, err),
        .FMT_TOML => value_to_toml(out, v, err),
    };
}

pub fn term_to_json(out: ast.Out, t: *dhall.Term, err: ?*dhall.DhallError) bool {
    return term_serialize(out, t, .FMT_JSON, err);
}
pub fn term_to_toml(out: ast.Out, t: *dhall.Term, err: ?*dhall.DhallError) bool {
    return term_serialize(out, t, .FMT_TOML, err);
}
pub fn term_to_yaml(out: ast.Out, t: *dhall.Term, err: ?*dhall.DhallError) bool {
    return term_serialize(out, t, .FMT_YAML, err);
}
