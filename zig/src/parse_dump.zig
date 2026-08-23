// parse_dump.zig — U3 twin-driver (Zig side). Parses the file given on argv[1]
// with zig/src/parser.zig and prints an S-expr of the raw Term tree, including
// de Bruijn indices and spans:
//     (TAG line:col ...payload...)
// On parse error prints:
//     ERROR <stage> <line>:<col> <msg>
// Byte-identical to the C twin driver (zig/u3_parse_dump.c); the U3 gate diffs
// the two streams across the corpus. Catches binder/name-resolution mistakes
// (de Bruijn indices) and span-stamping (tloc) before the normalizer exists.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const bignum = @import("bignum.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

const alloc = std.heap.page_allocator;

const tnames = [_][]const u8{
    "TmVar",       "TmConst",     "TmText",     "TmType",      "TmKind",
    "TmSort",      "TmLam",       "TmPi",       "TmApp",       "TmIf",
    "TmLet",       "TmAnn",       "TmNil",      "TmCons",      "TmTextAppend",
    "TmRecordType", "TmRecordLit", "TmField",   "TmUnionType", "TmUnionLit",
    "TmMerge",     "TmBuiltin",   "TmSome",     "TmNone",      "TmOp",
    "TmAssert",    "TmToMap",     "TmCombine",  "TmWith",      "TmListAppend",
    "TmPrefer",
};

const opnames = [_][]const u8{
    "OP_ADD", "OP_SUB", "OP_MUL", "OP_LT", "OP_LE", "OP_GT", "OP_GE", "OP_EQ",
    "OP_NE",  "OP_AND", "OP_OR",
};

const W = struct {
    var written: usize = 0;
    fn out(s: []const u8) void {
        if (s.len == 0) return;
        const n = std.os.linux.write(1, s.ptr, s.len);
        written += n;
    }
};

fn appendStr(b: *std.ArrayList(u8), s: []const u8) void {
    b.appendSlice(alloc, s) catch unreachable;
}
fn appendInt(b: *std.ArrayList(u8), v: anytype) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    appendStr(b, s);
}
fn appendHex64(b: *std.ArrayList(u8), v: u64) void {
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>16}", .{v}) catch unreachable;
    appendStr(b, &buf);
}

fn appendEsc(b: *std.ArrayList(u8), s: [*:0]const u8) void {
    appendStr(b, "\"");
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => appendStr(b, "\\\""),
            '\\' => appendStr(b, "\\\\"),
            '\n' => appendStr(b, "\\n"),
            '\t' => appendStr(b, "\\t"),
            '\r' => appendStr(b, "\\r"),
            else => {
                if (c < 0x20 or c > 0x7e) {
                    var h: [2]u8 = undefined;
                    _ = std.fmt.bufPrint(&h, "{x:0>2}", .{c}) catch unreachable;
                    appendStr(b, "\\x");
                    appendStr(b, &h);
                } else {
                    const one = [_]u8{c};
                    appendStr(b, &one);
                }
            },
        }
    }
    appendStr(b, "\"");
}

fn dump_const(b: *std.ArrayList(u8), c: dhall.Const) void {
    appendStr(b, " ");
    switch (c.kind) {
        .C_NAT => {
            appendStr(b, "C_NAT ");
            var sc: [2]u32 = undefined;
            const B = bignum.const_bignat(c, &sc);
            appendStr(b, std.mem.span(bignum.bignat_to_decimal(&B)));
        },
        .C_INT => {
            appendStr(b, "C_INT ");
            var sc: [2]u32 = undefined;
            const B = bignum.const_bigint(c, &sc);
            appendStr(b, std.mem.span(bignum.bigint_to_decimal(&B)));
        },
        .C_DBL => {
            appendStr(b, "C_DBL ");
            appendHex64(b, @bitCast(c.dbl));
        },
        .C_BOOL => {
            appendStr(b, "C_BOOL ");
            appendStr(b, if (c.b) "True" else "False");
        },
    }
}

fn dump_fields(b: *std.ArrayList(u8), fs: ?[*]dhall.Field, n: c_int) void {
    appendStr(b, " (");
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const f = fs.?[@intCast(i)];
        appendStr(b, "(F ");
        appendStr(b, std.mem.span(f.label.?));
        appendStr(b, " ");
        if (f.type) |ty| dump_term(b, ty) else appendStr(b, "0");
        appendStr(b, " ");
        if (f.value) |v| dump_term(b, v) else appendStr(b, "0");
        appendStr(b, ")");
    }
    appendStr(b, ")");
}

fn dump_term(b: *std.ArrayList(u8), t: *dhall.Term) void {
    appendStr(b, "(");
    appendStr(b, tnames[@intFromEnum(t.tag)]);
    appendStr(b, " ");
    appendInt(b, t.loc.line);
    appendStr(b, ":");
    appendInt(b, t.loc.col);
    switch (t.tag) {
        .TmVar => {
            appendStr(b, " ");
            appendInt(b, t.as.idx);
        },
        .TmConst => dump_const(b, t.as.c),
        .TmText => {
            var p = t.as.text;
            while (p) |pp| {
                appendStr(b, " ");
                if (pp.lit) |l| {
                    appendStr(b, "(lit ");
                    appendEsc(b, l);
                    appendStr(b, ")");
                } else if (pp.expr) |e| {
                    appendStr(b, "(expr ");
                    dump_term(b, e);
                    appendStr(b, ")");
                }
                p = pp.next;
            }
        },
        .TmType, .TmKind, .TmSort, .TmNil => {},
        .TmLam => {
            appendStr(b, " ");
            dump_term(b, t.as.lam.dom.?);
            appendStr(b, " ");
            dump_term(b, t.as.lam.body.?);
        },
        .TmPi => {
            appendStr(b, " ");
            dump_term(b, t.as.pi.dom.?);
            appendStr(b, " ");
            dump_term(b, t.as.pi.cod.?);
        },
        .TmApp => {
            appendStr(b, " ");
            dump_term(b, t.as.app.fn_.?);
            appendStr(b, " ");
            dump_term(b, t.as.app.arg.?);
        },
        .TmIf => {
            appendStr(b, " ");
            dump_term(b, t.as.if_.c.?);
            appendStr(b, " ");
            dump_term(b, t.as.if_.t.?);
            appendStr(b, " ");
            dump_term(b, t.as.if_.e.?);
        },
        .TmLet => {
            appendStr(b, " ");
            if (t.as.let_.ann) |a| dump_term(b, a) else appendStr(b, "0");
            appendStr(b, " ");
            dump_term(b, t.as.let_.val.?);
            appendStr(b, " ");
            dump_term(b, t.as.let_.body.?);
        },
        .TmAnn => {
            appendStr(b, " ");
            dump_term(b, t.as.ann.e.?);
            appendStr(b, " ");
            dump_term(b, t.as.ann.ty.?);
        },
        .TmCons => {
            appendStr(b, " ");
            dump_term(b, t.as.cons.head.?);
            appendStr(b, " ");
            dump_term(b, t.as.cons.tail.?);
        },
        .TmTextAppend => {
            appendStr(b, " ");
            dump_term(b, t.as.append.a.?);
            appendStr(b, " ");
            dump_term(b, t.as.append.b.?);
        },
        .TmRecordType, .TmRecordLit => dump_fields(b, t.as.rec.fs, t.as.rec.n),
        .TmField => {
            appendStr(b, " ");
            appendStr(b, std.mem.span(t.as.field.label.?));
            appendStr(b, " ");
            dump_term(b, t.as.field.rec.?);
        },
        .TmUnionType, .TmUnionLit => dump_fields(b, t.as.uni.fs, t.as.uni.n),
        .TmMerge => {
            appendStr(b, " ");
            dump_term(b, t.as.merge.handlers.?);
            appendStr(b, " ");
            dump_term(b, t.as.merge.u.?);
        },
        .TmBuiltin => {
            appendStr(b, " ");
            appendStr(b, std.mem.span(t.as.bname.?));
        },
        .TmSome => {
            appendStr(b, " ");
            dump_term(b, t.as.some.val.?);
        },
        .TmNone => {
            appendStr(b, " ");
            dump_term(b, t.as.none.ty.?);
        },
        .TmOp => {
            appendStr(b, " ");
            appendStr(b, opnames[@intFromEnum(t.as.op.op)]);
            appendStr(b, " ");
            dump_term(b, t.as.op.lhs.?);
            appendStr(b, " ");
            dump_term(b, t.as.op.rhs.?);
        },
        .TmAssert => {
            appendStr(b, " ");
            dump_term(b, t.as.assert_.body.?);
        },
        .TmToMap => {
            appendStr(b, " ");
            dump_term(b, t.as.tomap.rec.?);
        },
        .TmCombine => {
            appendStr(b, " ");
            dump_term(b, t.as.combine.lhs.?);
            appendStr(b, " ");
            dump_term(b, t.as.combine.rhs.?);
        },
        .TmWith => {
            appendStr(b, " ");
            dump_term(b, t.as.with_.rec.?);
            appendStr(b, " (");
            var i: c_int = 0;
            while (i < t.as.with_.npath) : (i += 1) {
                if (i > 0) appendStr(b, " ");
                appendStr(b, std.mem.span(t.as.with_.path.?[@intCast(i)].?));
            }
            appendStr(b, ")");
            appendStr(b, " ");
            dump_term(b, t.as.with_.value.?);
        },
        .TmListAppend => {
            appendStr(b, " ");
            dump_term(b, t.as.lappend.a.?);
            appendStr(b, " ");
            dump_term(b, t.as.lappend.b.?);
        },
        .TmPrefer => {
            appendStr(b, " ");
            dump_term(b, t.as.prefer.lhs.?);
            appendStr(b, " ");
            dump_term(b, t.as.prefer.rhs.?);
        },
    }
    appendStr(b, ")");
}

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    if (argv.len < 2) return;
    const path = argv[1];

    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        std.mem.span(path),
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch return;

    var buf = std.ArrayList(u8).initCapacity(alloc, 4096) catch return;
    defer buf.deinit(alloc);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch break;
        if (n == 0) break;
        buf.appendSlice(alloc, chunk[0..n]) catch break;
    }
    buf.append(alloc, 0) catch return;
    const srcz: [*:0]const u8 = @ptrCast(buf.items.ptr);

    const a = arena.arena_new();
    arena.dhall_arena = a;

    var p: dhall.Parser = std.mem.zeroes(dhall.Parser);
    p.loader = null;
    var err: dhall.DhallError = undefined;
    ast.dhall_error_clear(&err);
    const t = parser.parse_source(&p, srcz, path, &err);

    var ob = std.ArrayList(u8).initCapacity(alloc, 4096) catch return;
    defer ob.deinit(alloc);
    if (t) |tt| {
        dump_term(&ob, tt);
        ob.append(alloc, '\n') catch return;
    } else {
        ob.appendSlice(alloc, "ERROR ") catch return;
        appendInt(&ob, @intFromEnum(err.stage));
        ob.appendSlice(alloc, " ") catch return;
        appendInt(&ob, err.span.line);
        ob.appendSlice(alloc, ":") catch return;
        appendInt(&ob, err.span.col);
        ob.appendSlice(alloc, " ") catch return;
        ob.appendSlice(alloc, std.mem.sliceTo(&err.msg, 0)) catch return;
        ob.append(alloc, '\n') catch return;
    }
    W.out(ob.items);
}
