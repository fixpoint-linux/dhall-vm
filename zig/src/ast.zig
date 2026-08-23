// ast.zig — port of ../src/ast.c. PART 1 (U3): the full Term constructors and
// error helpers (ast.c:18-106). PART 2 (U4): capture-avoiding de Bruijn
// shift/subst, alpha-equivalence (alpha_eq), the normal-form pretty-printer
// (print_term) and shortest-round-trip double formatting (dbl_fmt) — a verbatim
// mirror of ast.c:125-549. Kept as a verbatim mirror of the corresponding ast.c
// code; do NOT "clean up" the semantics.
//
// NOTE: `arena.dhall_arena` is the single global arena (set per top-level eval),
// exactly like `extern Arena *dhall_arena` in dhall.h.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const bignum = @import("bignum.zig");

fn mk(tag: dhall.TermTag, loc: dhall.SourceSpan) *dhall.Term {
    const t: *dhall.Term = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.Term))));
    t.tag = tag;
    t.loc = loc;
    return t;
}

// ---------------- error helpers (ast.c:18-42) ----------------

pub fn dhall_error_clear(e: *dhall.DhallError) void {
    e.stage = .ERR_NONE;
    e.msg[0] = 0;
    e.span = dhall.SPAN_NONE;
    e.has_span = false;
}

pub fn dhall_error_exit(e: *dhall.DhallError) c_int {
    return switch (e.stage) {
        .ERR_TYPE => 1,
        .ERR_LEX, .ERR_PARSE => 2,
        else => 3,
    };
}

pub fn dhall_error_set(e: *dhall.DhallError, st: dhall.ErrorStage, sp: dhall.SourceSpan, comptime fmt: []const u8, args: anytype) void {
    var m: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&m, fmt, args) catch unreachable;
    @memcpy(e.msg[0..s.len], s);
    e.msg[s.len] = 0;
    e.stage = st;
    e.span = sp;
    e.has_span = sp.line > 0;
}

// ---------------- constructors (ast.c:46-106) ----------------
// Only the subset needed by builtins.c / lexer.c is ported here for U2.

pub fn tm_var(idx: c_int) *dhall.Term {
    const t = mk(.TmVar, dhall.SPAN_NONE);
    t.as.idx = idx;
    return t;
}

pub fn tm_const(c: dhall.Const) *dhall.Term {
    const t = mk(.TmConst, dhall.SPAN_NONE);
    t.as.c = c;
    return t;
}

pub fn tm_type() *dhall.Term {
    return mk(.TmType, dhall.SPAN_NONE);
}

pub fn tm_lam(d: ?*dhall.Term, b: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmLam, dhall.SPAN_NONE);
    t.as.lam = .{ .dom = d, .body = b };
    return t;
}

pub fn tm_pi(d: ?*dhall.Term, c: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmPi, dhall.SPAN_NONE);
    t.as.pi = .{ .dom = d, .cod = c };
    return t;
}

pub fn tm_app(f: ?*dhall.Term, x: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmApp, dhall.SPAN_NONE);
    t.as.app = .{ .fn_ = f, .arg = x };
    return t;
}

pub fn tm_builtin(n: []const u8) *dhall.Term {
    const t = mk(.TmBuiltin, dhall.SPAN_NONE);
    t.as.bname = arena.arena_strdup(arena.dhall_arena.?, n);
    return t;
}

pub fn tm_record_type(fs: ?[*]dhall.Field, n: c_int) *dhall.Term {
    const t = mk(.TmRecordType, dhall.SPAN_NONE);
    t.as.rec = .{ .fs = fs, .n = n };
    return t;
}

pub fn tm_record_lit(fs: ?[*]dhall.Field, n: c_int) *dhall.Term {
    const t = mk(.TmRecordLit, dhall.SPAN_NONE);
    t.as.rec = .{ .fs = fs, .n = n };
    return t;
}

pub fn tm_field(l: []const u8, r: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmField, dhall.SPAN_NONE);
    t.as.field = .{ .label = arena.arena_strdup(arena.dhall_arena.?, l), .rec = r };
    return t;
}

pub fn tm_union_type(fs: ?[*]dhall.Field, n: c_int) *dhall.Term {
    const t = mk(.TmUnionType, dhall.SPAN_NONE);
    t.as.uni = .{ .fs = fs, .n = n };
    return t;
}

pub fn tm_union_lit(fs: ?[*]dhall.Field, n: c_int) *dhall.Term {
    const t = mk(.TmUnionLit, dhall.SPAN_NONE);
    t.as.uni = .{ .fs = fs, .n = n };
    return t;
}

pub fn tm_merge(h: ?*dhall.Term, u: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmMerge, dhall.SPAN_NONE);
    t.as.merge = .{ .handlers = h, .u = u };
    return t;
}

pub fn tm_some(v: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmSome, dhall.SPAN_NONE);
    t.as.some = .{ .val = v };
    return t;
}

pub fn tm_none(ty: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmNone, dhall.SPAN_NONE);
    t.as.none = .{ .ty = ty };
    return t;
}

pub fn tm_op(op: dhall.OpKind, l: ?*dhall.Term, r: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmOp, dhall.SPAN_NONE);
    t.as.op = .{ .op = op, .lhs = l, .rhs = r };
    return t;
}

pub fn tm_assert(b: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmAssert, dhall.SPAN_NONE);
    t.as.assert_ = .{ .body = b };
    return t;
}

pub fn tm_tomap(r: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmToMap, dhall.SPAN_NONE);
    t.as.tomap = .{ .rec = r };
    return t;
}

pub fn tm_combine(l: ?*dhall.Term, r: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmCombine, dhall.SPAN_NONE);
    t.as.combine = .{ .lhs = l, .rhs = r };
    return t;
}

pub fn tm_list_append(a: ?*dhall.Term, b: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmListAppend, dhall.SPAN_NONE);
    t.as.lappend = .{ .a = a, .b = b };
    return t;
}

pub fn tm_prefer(l: ?*dhall.Term, r: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmPrefer, dhall.SPAN_NONE);
    t.as.prefer = .{ .lhs = l, .rhs = r };
    return t;
}

pub fn tm_with(rec: ?*dhall.Term, path: ?[*]?[*:0]u8, npath: c_int, value: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmWith, dhall.SPAN_NONE);
    t.as.with_ = .{ .rec = rec, .path = path, .npath = npath, .value = value };
    return t;
}

pub fn field_new(label: []const u8, type_: ?*dhall.Term, value: ?*dhall.Term) *dhall.Field {
    const f: *dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.Field))));
    f.label = arena.arena_strdup(arena.dhall_arena.?, label);
    f.type = type_;
    f.value = value;
    return f;
}

pub fn text_parts_single(lit: []const u8) *dhall.Term {
    const pp: *dhall.TextPart = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.TextPart))));
    pp.lit = arena.arena_strdup(arena.dhall_arena.?, lit);
    pp.expr = null;
    pp.next = null;
    return tm_text(pp);
}

// ---------------- remaining constructors (ast.c:46-65) ----------------

pub fn tm_nat(n: u64) *dhall.Term {
    return tm_const(.{ .kind = .C_NAT, .nat = n, .i64 = 0, .dbl = 0, .b = false, .bnat = null, .big = null });
}

pub fn tm_int(n: i64) *dhall.Term {
    return tm_const(.{ .kind = .C_INT, .nat = 0, .i64 = n, .dbl = 0, .b = false, .bnat = null, .big = null });
}

pub fn tm_dbl(d: f64) *dhall.Term {
    return tm_const(.{ .kind = .C_DBL, .nat = 0, .i64 = 0, .dbl = d, .b = false, .bnat = null, .big = null });
}

pub fn tm_bool(b: bool) *dhall.Term {
    return tm_const(.{ .kind = .C_BOOL, .nat = 0, .i64 = 0, .dbl = 0, .b = b, .bnat = null, .big = null });
}

pub fn tm_text(parts: ?*dhall.TextPart) *dhall.Term {
    const t = mk(.TmText, dhall.SPAN_NONE);
    t.as.text = parts;
    return t;
}

pub fn tm_text_lit(s: []const u8) *dhall.Term {
    return text_parts_single(s);
}

pub fn tm_kind() *dhall.Term {
    return mk(.TmKind, dhall.SPAN_NONE);
}

pub fn tm_sort() *dhall.Term {
    return mk(.TmSort, dhall.SPAN_NONE);
}

pub fn tm_if(c: ?*dhall.Term, t2: ?*dhall.Term, e: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmIf, dhall.SPAN_NONE);
    t.as.if_ = .{ .c = c, .t = t2, .e = e };
    return t;
}

pub fn tm_let(an: ?*dhall.Term, v: ?*dhall.Term, b: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmLet, dhall.SPAN_NONE);
    t.as.let_ = .{ .ann = an, .val = v, .body = b };
    return t;
}

pub fn tm_ann(e: ?*dhall.Term, ty: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmAnn, dhall.SPAN_NONE);
    t.as.ann = .{ .e = e, .ty = ty };
    return t;
}

pub fn tm_nil() *dhall.Term {
    return mk(.TmNil, dhall.SPAN_NONE);
}

pub fn tm_cons(h: ?*dhall.Term, t2: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmCons, dhall.SPAN_NONE);
    t.as.cons = .{ .head = h, .tail = t2 };
    return t;
}

pub fn tm_append(a: ?*dhall.Term, b: ?*dhall.Term) *dhall.Term {
    const t = mk(.TmTextAppend, dhall.SPAN_NONE);
    t.as.append = .{ .a = a, .b = b };
    return t;
}

// ---------------------------------------------------------------------------
// shift — capture-avoiding de Bruijn shift (ast.c:125-177). Verbatim.
// CRITICAL off-by-one: under binders (TmLam/TmPi/TmLet body) the cutoff is
// cutoff+1 (ast.c:128-134); the TmWith path array is labels, NOT shifted
// (ast.c:171-172).
// ---------------------------------------------------------------------------

fn shift_text(d: c_int, cutoff: c_int, t: *dhall.Term) *dhall.Term {
    var head: ?*dhall.TextPart = null;
    var tail: ?*dhall.TextPart = null;
    var p = t.as.text;
    while (p) |pp| {
        const np: *dhall.TextPart = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.TextPart))));
        np.lit = pp.lit;
        np.expr = if (pp.expr) |e| shift(d, cutoff, e) else null;
        np.next = null;
        if (tail) |t2| t2.next = np else head = np;
        tail = np;
        p = pp.next;
    }
    const r = tm_text(head);
    r.loc = t.loc;
    return r;
}

pub fn shift(d: c_int, cutoff: c_int, t: *dhall.Term) *dhall.Term {
    switch (t.tag) {
        .TmVar => return if (t.as.idx >= cutoff) tm_var(t.as.idx + d) else t,
        .TmLam => return tm_lam(shift(d, cutoff, t.as.lam.dom.?), shift(d, cutoff + 1, t.as.lam.body.?)),
        .TmPi => return tm_pi(shift(d, cutoff, t.as.pi.dom.?), shift(d, cutoff + 1, t.as.pi.cod.?)),
        .TmApp => return tm_app(shift(d, cutoff, t.as.app.fn_.?), shift(d, cutoff, t.as.app.arg.?)),
        .TmIf => return tm_if(shift(d, cutoff, t.as.if_.c.?), shift(d, cutoff, t.as.if_.t.?), shift(d, cutoff, t.as.if_.e.?)),
        .TmLet => return tm_let(if (t.as.let_.ann) |a| shift(d, cutoff, a) else null,
            shift(d, cutoff, t.as.let_.val.?),
            shift(d, cutoff + 1, t.as.let_.body.?)),
        .TmAnn => return tm_ann(shift(d, cutoff, t.as.ann.e.?), shift(d, cutoff, t.as.ann.ty.?)),
        .TmCons => return tm_cons(shift(d, cutoff, t.as.cons.head.?), shift(d, cutoff, t.as.cons.tail.?)),
        .TmTextAppend => return tm_append(shift(d, cutoff, t.as.append.a.?), shift(d, cutoff, t.as.append.b.?)),
        .TmText => return shift_text(d, cutoff, t),
        .TmRecordType, .TmRecordLit => {
            const n = t.as.rec.n;
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const src = &t.as.rec.fs.?[@intCast(i)];
                fs[@intCast(i)].label = src.label;
                fs[@intCast(i)].type = if (src.type) |ty| shift(d, cutoff, ty) else null;
                fs[@intCast(i)].value = if (src.value) |v| shift(d, cutoff, v) else null;
            }
            return if (t.tag == .TmRecordType) tm_record_type(fs, n) else tm_record_lit(fs, n);
        },
        .TmField => return tm_field(std.mem.span(t.as.field.label.?), shift(d, cutoff, t.as.field.rec.?)),
        .TmUnionType, .TmUnionLit => {
            const n = t.as.uni.n;
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const src = &t.as.uni.fs.?[@intCast(i)];
                fs[@intCast(i)].label = src.label;
                fs[@intCast(i)].type = if (src.type) |ty| shift(d, cutoff, ty) else null;
                fs[@intCast(i)].value = if (src.value) |v| shift(d, cutoff, v) else null;
            }
            return if (t.tag == .TmUnionType) tm_union_type(fs, n) else tm_union_lit(fs, n);
        },
        .TmMerge => return tm_merge(shift(d, cutoff, t.as.merge.handlers.?), shift(d, cutoff, t.as.merge.u.?)),
        .TmSome => return tm_some(shift(d, cutoff, t.as.some.val.?)),
        .TmNone => return tm_none(shift(d, cutoff, t.as.none.ty.?)),
        .TmOp => return tm_op(t.as.op.op, shift(d, cutoff, t.as.op.lhs.?), shift(d, cutoff, t.as.op.rhs.?)),
        .TmAssert => return tm_assert(shift(d, cutoff, t.as.assert_.body.?)),
        .TmToMap => return tm_tomap(shift(d, cutoff, t.as.tomap.rec.?)),
        .TmCombine => return tm_combine(shift(d, cutoff, t.as.combine.lhs.?), shift(d, cutoff, t.as.combine.rhs.?)),
        .TmListAppend => return tm_list_append(shift(d, cutoff, t.as.lappend.a.?), shift(d, cutoff, t.as.lappend.b.?)),
        .TmPrefer => return tm_prefer(shift(d, cutoff, t.as.prefer.lhs.?), shift(d, cutoff, t.as.prefer.rhs.?)),
        .TmWith => return tm_with(shift(d, cutoff, t.as.with_.rec.?), t.as.with_.path,
            t.as.with_.npath, shift(d, cutoff, t.as.with_.value.?)),
        .TmConst, .TmType, .TmKind, .TmSort,
        .TmNil, .TmBuiltin => return t,
    }
    return t;
}

// ---------------------------------------------------------------------------
// subst — capture-avoiding substitution (ast.c:196-248). Verbatim.
// CRITICAL: under binders (TmLam/TmPi/TmLet body) the index is j+1 AND the
// substitute is pre-shifted shift(1,0,s) (ast.c:199-205); the TmWith path array
// is labels, NOT substituted (ast.c:242-243).
// ---------------------------------------------------------------------------

fn subst_text(j: c_int, s: *dhall.Term, t: *dhall.Term) *dhall.Term {
    var head: ?*dhall.TextPart = null;
    var tail: ?*dhall.TextPart = null;
    var p = t.as.text;
    while (p) |pp| {
        const np: *dhall.TextPart = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.TextPart))));
        np.lit = pp.lit;
        np.expr = if (pp.expr) |e| subst(j, s, e) else null;
        np.next = null;
        if (tail) |t2| t2.next = np else head = np;
        tail = np;
        p = pp.next;
    }
    const r = tm_text(head);
    r.loc = t.loc;
    return r;
}

pub fn subst(j: c_int, s: *dhall.Term, t: *dhall.Term) *dhall.Term {
    switch (t.tag) {
        .TmVar => return if (t.as.idx == j) s else (if (t.as.idx > j) tm_var(t.as.idx - 1) else t),
        .TmLam => return tm_lam(subst(j, s, t.as.lam.dom.?), subst(j + 1, shift(1, 0, s), t.as.lam.body.?)),
        .TmPi => return tm_pi(subst(j, s, t.as.pi.dom.?), subst(j + 1, shift(1, 0, s), t.as.pi.cod.?)),
        .TmApp => return tm_app(subst(j, s, t.as.app.fn_.?), subst(j, s, t.as.app.arg.?)),
        .TmIf => return tm_if(subst(j, s, t.as.if_.c.?), subst(j, s, t.as.if_.t.?), subst(j, s, t.as.if_.e.?)),
        .TmLet => return tm_let(if (t.as.let_.ann) |a| subst(j, s, a) else null,
            subst(j, s, t.as.let_.val.?),
            subst(j + 1, shift(1, 0, s), t.as.let_.body.?)),
        .TmAnn => return tm_ann(subst(j, s, t.as.ann.e.?), subst(j, s, t.as.ann.ty.?)),
        .TmCons => return tm_cons(subst(j, s, t.as.cons.head.?), subst(j, s, t.as.cons.tail.?)),
        .TmTextAppend => return tm_append(subst(j, s, t.as.append.a.?), subst(j, s, t.as.append.b.?)),
        .TmText => return subst_text(j, s, t),
        .TmRecordType, .TmRecordLit => {
            const n = t.as.rec.n;
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const src = &t.as.rec.fs.?[@intCast(i)];
                fs[@intCast(i)].label = src.label;
                fs[@intCast(i)].type = if (src.type) |ty| subst(j, s, ty) else null;
                fs[@intCast(i)].value = if (src.value) |v| subst(j, s, v) else null;
            }
            return if (t.tag == .TmRecordType) tm_record_type(fs, n) else tm_record_lit(fs, n);
        },
        .TmField => return tm_field(std.mem.span(t.as.field.label.?), subst(j, s, t.as.field.rec.?)),
        .TmUnionType, .TmUnionLit => {
            const n = t.as.uni.n;
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const src = &t.as.uni.fs.?[@intCast(i)];
                fs[@intCast(i)].label = src.label;
                fs[@intCast(i)].type = if (src.type) |ty| subst(j, s, ty) else null;
                fs[@intCast(i)].value = if (src.value) |v| subst(j, s, v) else null;
            }
            return if (t.tag == .TmUnionType) tm_union_type(fs, n) else tm_union_lit(fs, n);
        },
        .TmMerge => return tm_merge(subst(j, s, t.as.merge.handlers.?), subst(j, s, t.as.merge.u.?)),
        .TmSome => return tm_some(subst(j, s, t.as.some.val.?)),
        .TmNone => return tm_none(subst(j, s, t.as.none.ty.?)),
        .TmOp => return tm_op(t.as.op.op, subst(j, s, t.as.op.lhs.?), subst(j, s, t.as.op.rhs.?)),
        .TmAssert => return tm_assert(subst(j, s, t.as.assert_.body.?)),
        .TmToMap => return tm_tomap(subst(j, s, t.as.tomap.rec.?)),
        .TmCombine => return tm_combine(subst(j, s, t.as.combine.lhs.?), subst(j, s, t.as.combine.rhs.?)),
        .TmListAppend => return tm_list_append(subst(j, s, t.as.lappend.a.?), subst(j, s, t.as.lappend.b.?)),
        .TmPrefer => return tm_prefer(subst(j, s, t.as.prefer.lhs.?), subst(j, s, t.as.prefer.rhs.?)),
        .TmWith => return tm_with(subst(j, s, t.as.with_.rec.?), t.as.with_.path,
            t.as.with_.npath, subst(j, s, t.as.with_.value.?)),
        .TmConst, .TmType, .TmKind, .TmSort,
        .TmNil, .TmBuiltin => return t,
    }
    return t;
}

// ---------------------------------------------------------------------------
// alpha_eq — alpha-equivalence (ast.c:277-360). Verbatim, including the
// LOAD-BEARING cross-tag comparison: record-type↔record-literal and
// union-type↔union-literal compare via fields_eq (ast.c:284-301) because the
// empty record value `{=}` and empty record type `{}` coincide. Never "clean up".
// ---------------------------------------------------------------------------

fn text_eq(a: ?*dhall.TextPart, b: ?*dhall.TextPart) bool {
    var pa = a;
    var pb = b;
    while (pa != null and pb != null) {
        const aa = pa.?;
        const bb = pb.?;
        if ((aa.lit != null) != (bb.lit != null)) return false;
        if (aa.lit) |la| {
            if (bb.lit == null or !std.mem.eql(u8, std.mem.span(la), std.mem.span(bb.lit.?))) return false;
        }
        if (aa.expr != null or bb.expr != null) {
            if (aa.expr == null or bb.expr == null) return false;
            if (!alpha_eq(aa.expr.?, bb.expr.?)) return false;
        }
        pa = aa.next;
        pb = bb.next;
    }
    return pa == pb;
}

fn fields_eq(a: ?[*]dhall.Field, na: c_int, b: ?[*]dhall.Field, nb: c_int) bool {
    if (na != nb) return false;
    var i: c_int = 0;
    while (i < na) : (i += 1) {
        const fa = &a.?[@intCast(i)];
        const fb = &b.?[@intCast(i)];
        if (!std.mem.eql(u8, std.mem.span(fa.label.?), std.mem.span(fb.label.?))) return false;
        if ((fa.type != null) != (fb.type != null)) return false;
        if (fa.type) |ta| {
            if (!alpha_eq(ta, fb.type.?)) return false;
        }
        if ((fa.value != null) != (fb.value != null)) return false;
        if (fa.value) |va| {
            if (!alpha_eq(va, fb.value.?)) return false;
        }
    }
    return true;
}

pub fn alpha_eq(a: *dhall.Term, b: *dhall.Term) bool {
    const atag = a.tag;
    const btag = b.tag;
    if (atag == .TmRecordLit or atag == .TmRecordType) {
        if (btag == .TmRecordLit or btag == .TmRecordType) {
            if (atag != btag) {
                return fields_eq(a.as.rec.fs, a.as.rec.n, b.as.rec.fs, b.as.rec.n);
            }
        }
    }
    if (atag == .TmUnionLit or atag == .TmUnionType) {
        if (btag == .TmUnionLit or btag == .TmUnionType) {
            if (atag != btag) {
                return fields_eq(a.as.uni.fs, a.as.uni.n, b.as.uni.fs, b.as.uni.n);
            }
        }
    }
    if (a.tag != b.tag) return false;
    switch (a.tag) {
        .TmVar => return a.as.idx == b.as.idx,
        .TmConst => {
            const x = a.as.c;
            const y = b.as.c;
            if (x.kind != y.kind) return false;
            switch (x.kind) {
                .C_NAT => {
                    var sa: [2]u32 = undefined;
                    var sb: [2]u32 = undefined;
                    const A = bignum.const_bignat(x, &sa);
                    const B = bignum.const_bignat(y, &sb);
                    return bignum.bignat_cmp(&A, &B) == 0;
                },
                .C_INT => {
                    var sa: [2]u32 = undefined;
                    var sb: [2]u32 = undefined;
                    const A = bignum.const_bigint(x, &sa);
                    const B = bignum.const_bigint(y, &sb);
                    return bignum.bigint_cmp(&A, &B) == 0;
                },
                .C_DBL => return x.dbl == y.dbl,
                .C_BOOL => return x.b == y.b,
            }
            return false;
        },
        .TmText => return text_eq(a.as.text, b.as.text),
        .TmType, .TmKind, .TmSort, .TmNil => return true,
        .TmBuiltin => return std.mem.eql(u8, std.mem.span(a.as.bname.?), std.mem.span(b.as.bname.?)),
        .TmLam => return alpha_eq(a.as.lam.dom.?, b.as.lam.dom.?) and alpha_eq(a.as.lam.body.?, b.as.lam.body.?),
        .TmPi => return alpha_eq(a.as.pi.dom.?, b.as.pi.dom.?) and alpha_eq(a.as.pi.cod.?, b.as.pi.cod.?),
        .TmApp => return alpha_eq(a.as.app.fn_.?, b.as.app.fn_.?) and alpha_eq(a.as.app.arg.?, b.as.app.arg.?),
        .TmIf => return alpha_eq(a.as.if_.c.?, b.as.if_.c.?) and alpha_eq(a.as.if_.t.?, b.as.if_.t.?) and alpha_eq(a.as.if_.e.?, b.as.if_.e.?),
        .TmLet => {
            const ann_ok = (a.as.let_.ann != null) and (b.as.let_.ann != null);
            const ann_eq = if (ann_ok) alpha_eq(a.as.let_.ann.?, b.as.let_.ann.?) else (a.as.let_.ann == b.as.let_.ann);
            return ann_eq and
                alpha_eq(a.as.let_.val.?, b.as.let_.val.?) and alpha_eq(a.as.let_.body.?, b.as.let_.body.?);
        },
        .TmAnn => return alpha_eq(a.as.ann.e.?, b.as.ann.e.?) and alpha_eq(a.as.ann.ty.?, b.as.ann.ty.?),
        .TmCons => return alpha_eq(a.as.cons.head.?, b.as.cons.head.?) and alpha_eq(a.as.cons.tail.?, b.as.cons.tail.?),
        .TmTextAppend => return alpha_eq(a.as.append.a.?, b.as.append.a.?) and alpha_eq(a.as.append.b.?, b.as.append.b.?),
        .TmRecordType, .TmRecordLit => return fields_eq(a.as.rec.fs, a.as.rec.n, b.as.rec.fs, b.as.rec.n),
        .TmField => return std.mem.eql(u8, std.mem.span(a.as.field.label.?), std.mem.span(b.as.field.label.?)) and alpha_eq(a.as.field.rec.?, b.as.field.rec.?),
        .TmUnionType, .TmUnionLit => return fields_eq(a.as.uni.fs, a.as.uni.n, b.as.uni.fs, b.as.uni.n),
        .TmMerge => return alpha_eq(a.as.merge.handlers.?, b.as.merge.handlers.?) and alpha_eq(a.as.merge.u.?, b.as.merge.u.?),
        .TmSome => return alpha_eq(a.as.some.val.?, b.as.some.val.?),
        .TmNone => return alpha_eq(a.as.none.ty.?, b.as.none.ty.?),
        .TmOp => return a.as.op.op == b.as.op.op and alpha_eq(a.as.op.lhs.?, b.as.op.lhs.?) and alpha_eq(a.as.op.rhs.?, b.as.op.rhs.?),
        .TmAssert => return alpha_eq(a.as.assert_.body.?, b.as.assert_.body.?),
        .TmToMap => return alpha_eq(a.as.tomap.rec.?, b.as.tomap.rec.?),
        .TmCombine => return alpha_eq(a.as.combine.lhs.?, b.as.combine.lhs.?) and alpha_eq(a.as.combine.rhs.?, b.as.combine.rhs.?),
        .TmListAppend => return alpha_eq(a.as.lappend.a.?, b.as.lappend.a.?) and alpha_eq(a.as.lappend.b.?, b.as.lappend.b.?),
        .TmPrefer => return alpha_eq(a.as.prefer.lhs.?, b.as.prefer.lhs.?) and alpha_eq(a.as.prefer.rhs.?, b.as.prefer.rhs.?),
        .TmWith => {
            if (a.as.with_.npath != b.as.with_.npath) return false;
            var i: c_int = 0;
            while (i < a.as.with_.npath) : (i += 1) {
                if (!std.mem.eql(u8, std.mem.span(a.as.with_.path.?[@intCast(i)].?), std.mem.span(b.as.with_.path.?[@intCast(i)].?))) return false;
            }
            return alpha_eq(a.as.with_.rec.?, b.as.with_.rec.?) and alpha_eq(a.as.with_.value.?, b.as.with_.value.?);
        },
    }
    return false;
}

// ---------------------------------------------------------------------------
// pretty-printer (normal form) — ast.c:362-549. Writes into a growable buffer.
// Synthetic '_' binder names, standard-format output. Verbatim.
// ---------------------------------------------------------------------------

extern fn snprintf(str: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;
extern fn strtod(nptr: [*:0]const u8, endptr: ?*[*c]u8) f64;

/// Output sink for print_term — a growable byte buffer (arena-backed).
pub const Out = struct {
    b: *std.ArrayList(u8),
    pub fn str(self: Out, s: []const u8) void {
        if (s.len == 0) return;
        self.b.appendSlice(arena.dhall_arena.?.allocator(), s) catch unreachable;
    }
    pub fn chr(self: Out, c: u8) void {
        self.b.append(arena.dhall_arena.?.allocator(), c) catch unreachable;
    }
    pub fn cstr(self: Out, s: [*:0]const u8) void {
        self.str(std.mem.span(s));
    }
};
fn print_text_escaped(out: Out, s: [*:0]const u8) void {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        switch (s[i]) {
            '"' => out.str("\\\""),
            '\\' => out.str("\\\\"),
            '$' => out.str("\\$"),
            '\n' => out.str("\\n"),
            '\t' => out.str("\\t"),
            '\r' => out.str("\\r"),
            else => out.chr(s[i]),
        }
    }
}

fn op_str(op: dhall.OpKind) []const u8 {
    return switch (op) {
        .OP_ADD => "+",
        .OP_SUB => "-",
        .OP_MUL => "*",
        .OP_LT => "<",
        .OP_LE => "<=",
        .OP_GT => ">",
        .OP_GE => ">=",
        .OP_EQ => "==",
        .OP_NE => "!=",
        .OP_AND => "&&",
        .OP_OR => "||",
    };
}

fn print_rec_fields(out: Out, fs: ?[*]dhall.Field, n: c_int, types: bool) void {
    out.chr('{');
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        if (i != 0) out.chr(',');
        out.cstr(fs.?[@intCast(i)].label.?);
        out.str(if (types) ":" else "=");
        if (types) {
            print_term(out, fs.?[@intCast(i)].type.?);
        } else {
            print_term(out, fs.?[@intCast(i)].value.?);
        }
    }
    out.chr('}');
}

fn print_uni_fields(out: Out, fs: ?[*]dhall.Field, n: c_int) void {
    out.chr('<');
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        if (i != 0) out.chr('|');
        out.cstr(fs.?[@intCast(i)].label.?);
        if (fs.?[@intCast(i)].value) |v| {
            out.str(" = ");
            print_term(out, v);
        } else {
            out.chr(':');
            print_term(out, fs.?[@intCast(i)].type.?);
        }
    }
    out.chr('>');
}

fn print_list(out: Out, t: *dhall.Term) void {
    out.chr('[');
    var first = true;
    var tt = t;
    while (tt.tag == .TmCons) {
        if (!first) out.chr(',');
        first = false;
        print_term(out, tt.as.cons.head.?);
        tt = tt.as.cons.tail.?;
    }
    out.chr(']');
}

/// shortest-round-trip Double literal (ast.c:431-448). Verbatim: C %.*g
/// p=0..17 first-round-trip search + '.0' suffix. MUST use extern libc
/// snprintf/strtod — Zig std.fmt does NOT reproduce C %g. Non-finite keeps the
/// legacy lowercase nan/inf/-inf.
pub fn dbl_fmt(buf: [*]u8, cap: usize, d: f64) void {
    if (std.math.isNan(d)) {
        _ = snprintf(buf, cap, "nan");
        return;
    }
    if (d == std.math.inf(f64)) {
        _ = snprintf(buf, cap, "inf");
        return;
    }
    if (d == -std.math.inf(f64)) {
        _ = snprintf(buf, cap, "-inf");
        return;
    }
    var p: c_int = 0;
    while (p <= 17) : (p += 1) {
        _ = snprintf(buf, cap, "%.*g", p, d);
        if (strtod(@ptrCast(buf), null) == d) break;
    }
    var has_dot_e = false;
    var i: usize = 0;
    while (buf[i] != 0) : (i += 1) {
        if (buf[i] == '.' or buf[i] == 'e' or buf[i] == 'E') {
            has_dot_e = true;
            break;
        }
    }
    if (!has_dot_e) {
        var n: usize = 0;
        while (buf[n] != 0) : (n += 1) {}
        _ = snprintf(buf + n, cap - n, ".0");
    }
}

fn print_lam_body(out: Out, dom: *dhall.Term, body: *dhall.Term) void {
    out.str("\\(_ : ");
    print_term(out, dom);
    out.str(") -> ");
    print_term(out, body);
}

pub fn print_term(out: Out, t: *dhall.Term) void {
    switch (t.tag) {
        .TmVar => {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "_{d}", .{t.as.idx}) catch unreachable;
            out.str(s);
        },
        .TmConst => switch (t.as.c.kind) {
            .C_NAT => {
                var scratch: [2]u32 = undefined;
                const B = bignum.const_bignat(t.as.c, &scratch);
                out.cstr(bignum.bignat_to_decimal(&B));
            },
            .C_INT => {
                var scratch: [2]u32 = undefined;
                const B = bignum.const_bigint(t.as.c, &scratch);
                out.cstr(bignum.bigint_to_decimal(&B));
            },
            .C_DBL => {
                var dbuf: [64]u8 = undefined;
                dbl_fmt(&dbuf, dbuf.len, t.as.c.dbl);
                out.str(std.mem.sliceTo(&dbuf, 0));
            },
            .C_BOOL => out.str(if (t.as.c.b) "True" else "False"),
        },
        .TmText => {
            out.chr('"');
            var p = t.as.text;
            while (p) |pp| {
                if (pp.lit) |l| {
                    print_text_escaped(out, l);
                } else if (pp.expr) |e| {
                    out.str("${");
                    print_term(out, e);
                    out.chr('}');
                }
                p = pp.next;
            }
            out.chr('"');
        },
        .TmType => out.str("Type"),
        .TmKind => out.str("Kind"),
        .TmSort => out.str("Sort"),
        .TmLam => print_lam_body(out, t.as.lam.dom.?, t.as.lam.body.?),
        .TmPi => {
            out.str("forall (_ : ");
            print_term(out, t.as.pi.dom.?);
            out.str(") -> ");
            print_term(out, t.as.pi.cod.?);
        },
        .TmApp => {
            out.chr('(');
            print_term(out, t.as.app.fn_.?);
            out.chr(' ');
            print_term(out, t.as.app.arg.?);
            out.chr(')');
        },
        .TmIf => {
            out.str("(if ");
            print_term(out, t.as.if_.c.?);
            out.str(" then ");
            print_term(out, t.as.if_.t.?);
            out.str(" else ");
            print_term(out, t.as.if_.e.?);
            out.chr(')');
        },
        .TmLet => {
            out.str("(let = ");
            print_term(out, t.as.let_.val.?);
            out.str(" in ");
            print_term(out, t.as.let_.body.?);
            out.chr(')');
        },
        .TmAnn => {
            out.chr('(');
            print_term(out, t.as.ann.e.?);
            out.str(" : ");
            print_term(out, t.as.ann.ty.?);
            out.chr(')');
        },
        .TmNil => out.str("[]"),
        .TmCons => print_list(out, t),
        .TmTextAppend => {
            out.chr('(');
            print_term(out, t.as.append.a.?);
            out.str(" ++ ");
            print_term(out, t.as.append.b.?);
            out.chr(')');
        },
        .TmRecordType => print_rec_fields(out, t.as.rec.fs, t.as.rec.n, true),
        .TmRecordLit => print_rec_fields(out, t.as.rec.fs, t.as.rec.n, false),
        .TmField => {
            print_term(out, t.as.field.rec.?);
            out.chr('.');
            out.cstr(t.as.field.label.?);
        },
        .TmUnionType, .TmUnionLit => print_uni_fields(out, t.as.uni.fs, t.as.uni.n),
        .TmMerge => {
            out.str("(merge ");
            print_term(out, t.as.merge.handlers.?);
            out.chr(' ');
            print_term(out, t.as.merge.u.?);
            out.chr(')');
        },
        .TmBuiltin => out.cstr(t.as.bname.?),
        .TmSome => {
            out.str("Some ");
            print_term(out, t.as.some.val.?);
        },
        .TmNone => {
            out.str("None ");
            print_term(out, t.as.none.ty.?);
        },
        .TmOp => {
            out.chr('(');
            print_term(out, t.as.op.lhs.?);
            out.str(" ");
            out.str(op_str(t.as.op.op));
            out.str(" ");
            print_term(out, t.as.op.rhs.?);
            out.chr(')');
        },
        .TmAssert => {
            out.str("(assert : ");
            print_term(out, t.as.assert_.body.?);
            out.chr(')');
        },
        .TmToMap => {
            out.str("(toMap ");
            print_term(out, t.as.tomap.rec.?);
            out.chr(')');
        },
        .TmCombine => {
            out.chr('(');
            print_term(out, t.as.combine.lhs.?);
            out.str(" /\\ ");
            print_term(out, t.as.combine.rhs.?);
            out.chr(')');
        },
        .TmListAppend => {
            out.chr('(');
            print_term(out, t.as.lappend.a.?);
            out.str(" # ");
            print_term(out, t.as.lappend.b.?);
            out.chr(')');
        },
        .TmPrefer => {
            out.chr('(');
            print_term(out, t.as.prefer.lhs.?);
            out.str(" // ");
            print_term(out, t.as.prefer.rhs.?);
            out.chr(')');
        },
        .TmWith => {
            out.chr('(');
            print_term(out, t.as.with_.rec.?);
            out.str(" with ");
            var i: c_int = 0;
            while (i < t.as.with_.npath) : (i += 1) {
                if (i != 0) out.chr('.');
                out.cstr(t.as.with_.path.?[@intCast(i)].?);
            }
            out.str(" = ");
            print_term(out, t.as.with_.value.?);
            out.chr(')');
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
fn setArena() void {
    arena.dhall_arena = arena.arena_new();
}

fn dump(term: *dhall.Term) []u8 {
    var b = std.ArrayList(u8).initCapacity(std.heap.page_allocator, 64) catch unreachable;
    const out = Out{ .b = &b };
    print_term(out, term);
    return b.toOwnedSlice(std.heap.page_allocator) catch unreachable;
}

test "shift: cutoff+1 under binders; free var shifted, bound untouched" {
    setArena();
    // \x. \y. _2  (free var 2 under two binders)
    const t = tm_lam(tm_type(), tm_lam(tm_type(), tm_var(2)));
    try std.testing.expectEqualStrings("\\(_ : Type) -> \\(_ : Type) -> _2", dump(t));
    try std.testing.expectEqualStrings("\\(_ : Type) -> \\(_ : Type) -> _3", dump(shift(1, 0, t)));
    try std.testing.expectEqualStrings("\\(_ : Type) -> \\(_ : Type) -> _4", dump(shift(2, 0, t)));
}

test "shift: bound var 0 not shifted under its binder" {
    setArena();
    const t = tm_lam(tm_type(), tm_var(0)); // \x. x
    try std.testing.expectEqualStrings("\\(_ : Type) -> _0", dump(t));
    try std.testing.expectEqualStrings("\\(_ : Type) -> _0", dump(shift(1, 0, t)));
}

test "subst: decrement free vars above j, replace j, leave below" {
    setArena();
    const t = tm_app(tm_var(3), tm_var(1)); // (_3 _1)
    const r = subst(1, tm_var(9), t);
    try std.testing.expectEqualStrings("(_2 _9)", dump(r)); // 3->2, 1->9
}

test "subst: under binder, substitute is shifted +1" {
    setArena();
    const t = tm_lam(tm_type(), tm_var(1)); // \x. _1 (free var 1)
    const r = subst(0, tm_var(5), t);
    try std.testing.expectEqualStrings("\\(_ : Type) -> _6", dump(r)); // 5->6 under binder
}

test "subst: bound var 0 left alone" {
    setArena();
    const t = tm_lam(tm_type(), tm_var(0)); // \x. x
    const r = subst(0, tm_var(5), t);
    try std.testing.expectEqualStrings("\\(_ : Type) -> _0", dump(r));
}

test "alpha_eq: record-type<->record-literal and union-type<->union-literal" {
    setArena();
    // empty record literal {=} and empty record type {} coincide (LOAD-BEARING)
    const rl0 = tm_record_lit(null, 0);
    const rt0 = tm_record_type(null, 0);
    try std.testing.expect(alpha_eq(rl0, rt0));
    try std.testing.expect(alpha_eq(rt0, rl0));
    // empty union literal/type coincide
    const ul0 = tm_union_lit(null, 0);
    const ut0 = tm_union_type(null, 0);
    try std.testing.expect(alpha_eq(ul0, ut0));
    // { a = 1 } literal differs from { a : Natural } type (populated slots)
    const f1 = field_new("a", null, tm_nat(1));
    const f2 = field_new("a", tm_nat(1), null);
    const rl1 = tm_record_lit(f1[0..1].ptr, 1);
    const rt1 = tm_record_type(f2[0..1].ptr, 1);
    try std.testing.expect(!alpha_eq(rl1, rt1));
    try std.testing.expect(alpha_eq(rl1, rl1));
    // lambda alpha: same index equal, different index not
    const lam_a = tm_lam(tm_type(), tm_var(0));
    const lam_b = tm_lam(tm_type(), tm_var(1));
    try std.testing.expect(alpha_eq(lam_a, lam_a));
    try std.testing.expect(!alpha_eq(lam_a, lam_b));
}

test "dbl_fmt: shortest-round-trip + .0 suffix + legacy non-finite" {
    setArena();
    var b: [64]u8 = undefined;
    dbl_fmt(&b, b.len, 0.1);
    try std.testing.expectEqualStrings("0.1", std.mem.sliceTo(&b, 0));
    dbl_fmt(&b, b.len, 1.0);
    try std.testing.expectEqualStrings("1.0", std.mem.sliceTo(&b, 0));
    dbl_fmt(&b, b.len, -0.0);
    try std.testing.expectEqualStrings("-0.0", std.mem.sliceTo(&b, 0));
    dbl_fmt(&b, b.len, 1e300);
    try std.testing.expectEqualStrings("1e+300", std.mem.sliceTo(&b, 0));
    dbl_fmt(&b, b.len, 5e-324);
    try std.testing.expectEqualStrings("5e-324", std.mem.sliceTo(&b, 0));
    dbl_fmt(&b, b.len, std.math.nan(f64));
    try std.testing.expectEqualStrings("nan", std.mem.sliceTo(&b, 0));
    dbl_fmt(&b, b.len, std.math.inf(f64));
    try std.testing.expectEqualStrings("inf", std.mem.sliceTo(&b, 0));
    dbl_fmt(&b, b.len, -std.math.inf(f64));
    try std.testing.expectEqualStrings("-inf", std.mem.sliceTo(&b, 0));
}
