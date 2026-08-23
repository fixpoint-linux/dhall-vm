// normalize.zig — port of ../src/normalize.c, VERBATIM in behavior.
// Eager (call-by-value) strong normalization: beta, let, if, builtin delta
// rules (List/map|filter|reverse|fold, Optional/fold, Natural/fold capped at
// 2^20, Natural isZero/show/subtract/even/odd/toInteger, Integer
// toDouble/negate/show/clamp, Text/replace|show, Double/show, List
// length/head/last/indexed/build, Natural/build), record combine/prefer/with
// merges (sorted-field invariants), and norm_text PARTIAL-SPLICE semantics:
// stuck interpolations are PRESERVED, only closed Text splices, closed
// non-Text errors.
//
// CRITICAL: the normalize error channel is a MODULE-GLOBAL with first-error-wins
// (normalize.c:12-28), NOT an error union — call shapes and stuck-term
// semantics depend on it. Do NOT refactor. The arena global mirrors
// `extern Arena *dhall_arena` in dhall.h.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const ast = @import("ast.zig");
const bignum = @import("bignum.zig");

const MAX_NAT_FOLD: u64 = 1 << 20; // Natural/fold iteration cap (DoS guard)

// ---- overflow/error channel (normalize has no out-param) ----

var g_norm_err: dhall.DhallError = undefined;
var g_norm_err_set: bool = false;

pub fn normalize_clear_error() void {
    ast.dhall_error_clear(&g_norm_err);
    g_norm_err_set = false;
}

pub fn normalize_has_error() bool {
    return g_norm_err_set;
}

pub fn normalize_get_error() *dhall.DhallError {
    return &g_norm_err;
}

fn norm_set_error(sp: dhall.SourceSpan, msg: []const u8) void {
    if (g_norm_err_set) return; // first error wins
    g_norm_err.stage = .ERR_TYPE;
    g_norm_err.span = sp;
    g_norm_err.has_span = sp.line > 0;
    const n = @min(msg.len, g_norm_err.msg.len - 1);
    @memcpy(g_norm_err.msg[0..n], msg[0..n]);
    g_norm_err.msg[n] = 0;
    g_norm_err_set = true;
}

// ---- builtin application matching (verbatim from proto.c) ----

fn match_builtin(name: []const u8, n: usize, t: *dhall.Term, args: []*dhall.Term) bool {
    var cur = t;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (cur.tag != .TmApp) return false;
        args[i] = cur.as.app.arg.?;
        cur = cur.as.app.fn_.?;
    }
    return cur.tag == .TmBuiltin and std.mem.eql(u8, std.mem.span(cur.as.bname.?), name);
}

fn reverse_list(xs: *dhall.Term) *dhall.Term {
    var elems = std.ArrayList(*dhall.Term).initCapacity(std.heap.c_allocator, 16) catch unreachable;
    var cur = xs;
    while (cur.tag == .TmCons) {
        elems.append(std.heap.c_allocator, cur.as.cons.head.?) catch unreachable;
        cur = cur.as.cons.tail.?;
    }
    var out = ast.tm_nil();
    var i: usize = 0;
    while (i < elems.items.len) : (i += 1) {
        out = ast.tm_cons(elems.items[i], out);
    }
    elems.deinit(std.heap.c_allocator);
    return out;
}

// ---- text helpers ----

/// true if the text term has any interpolation parts
fn text_has_interp(t: *dhall.Term) bool {
    var p = t.as.text;
    while (p) |pp| {
        if (pp.expr != null) return true;
        p = pp.next;
    }
    return false;
}

/// true if the normalized value is a closed WHNF that is definitively NOT Text.
/// Used to reject non-Text interpolation in normalize/serializer modes (which have
/// no type information). Stuck/unknown-type terms (TmVar, TmApp, TmField, ...)
/// are PRESERVED (kept as interpolation parts) rather than spliced, matching
/// well-typed semantics where bound-Text interpolations may remain stuck.
fn is_closed_nontext_value(e: *dhall.Term) bool {
    return switch (e.tag) {
        .TmConst, .TmType, .TmKind, .TmSort, .TmNil, .TmCons, .TmRecordLit,
        .TmRecordType, .TmUnionLit, .TmUnionType, .TmBuiltin, .TmLam, .TmPi,
        .TmSome, .TmNone => true,
        else => false,
    };
}

/// normalize a text term by PARTIAL SPLICE: rebuild the TextPart list where
/// each interpolation part is spliced into the literal stream iff it
/// normalizes to a closed Text literal, errors iff it normalizes to a closed
/// non-Text value, and is otherwise PRESERVED as an (already-normalized)
/// expression part (stuck terms: TmVar, TmApp, ...). Adjacent literal chunks
/// are coalesced, so a fully-collapsed text becomes a single literal part.
fn norm_text(t: *dhall.Term) *dhall.Term {
    if (!text_has_interp(t)) return t;

    var lit: dhall.TmpBuf = undefined;
    arena.tmpbuf_init(&lit);
    var have_lit = false;
    var head: ?*dhall.TextPart = null;
    var tail: ?*dhall.TextPart = null;
    var any_expr = false;

    var p = t.as.text;
    while (p) |pp| {
        if (pp.lit) |l| {
            arena.tmpbuf_add(&lit, std.mem.span(l));
            have_lit = true;
        } else if (pp.expr) |ex| {
            const e = normalize(ex);
            if (e.tag == .TmText and e.as.text != null and e.as.text.?.expr == null and e.as.text.?.lit != null) {
                arena.tmpbuf_add(&lit, std.mem.span(e.as.text.?.lit.?)); // splice closed Text literal
                have_lit = true;
            } else if (is_closed_nontext_value(e)) {
                norm_set_error(ex.loc, "interpolation requires Text");
            } else {
                // preserve the stuck (already-normalized) interpolation expr
                if (have_lit) {
                    const np: *dhall.TextPart = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.TextPart))));
                    np.lit = arena.tmpbuf_arena(arena.dhall_arena.?, &lit);
                    np.expr = null;
                    np.next = null;
                    if (tail) |t2| t2.next = np else head = np;
                    tail = np;
                    have_lit = false;
                }
                const np: *dhall.TextPart = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.TextPart))));
                np.lit = null;
                np.expr = e;
                np.next = null;
                if (tail) |t2| t2.next = np else head = np;
                tail = np;
                any_expr = true;
            }
        }
        p = pp.next;
    }

    if (!any_expr)
        return ast.tm_text_lit(if (have_lit) std.mem.span(arena.tmpbuf_arena(arena.dhall_arena.?, &lit)) else "");

    if (have_lit) {
        const np: *dhall.TextPart = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.TextPart))));
        np.lit = arena.tmpbuf_arena(arena.dhall_arena.?, &lit);
        np.expr = null;
        np.next = null;
        if (tail) |t2| t2.next = np else head = np;
    }
    return ast.tm_text(head);
}

fn norm_field(t: *dhall.Term) *dhall.Term {
    const r = normalize(t.as.field.rec.?);
    if (r.tag == .TmRecordLit) {
        var i: c_int = 0;
        while (i < r.as.rec.n) : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(r.as.rec.fs.?[@intCast(i)].label.?), std.mem.span(t.as.field.label.?)))
                return normalize(r.as.rec.fs.?[@intCast(i)].value.?);
        }
        return t; // unreachable for well-typed terms
    }
    // Union constructor: `(U).l` where the projection's rec normalizes to a
    // union type reduces to the constructor:
    //   non-nullary l : T  =>  \(x : T) -> < ... | l = x@0 | ... >
    //     (selected alt carries var(0); other alts keep their types, shifted
    //      +1 under the new binder; the domain T stays outside, unshifted)
    //   nullary l (no type) =>  < ... | l = {=} | ... >  (the value itself)
    if (r.tag == .TmUnionType) {
        const n = r.as.uni.n;
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const af = r.as.uni.fs.?[@intCast(i)];
            if (!std.mem.eql(u8, std.mem.span(af.label.?), std.mem.span(t.as.field.label.?))) continue;
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(if (n > 0) n else 1)) * @sizeOf(dhall.Field))));
            var j: c_int = 0;
            while (j < n) : (j += 1) {
                const src = r.as.uni.fs.?[@intCast(j)];
                fs[@intCast(j)].label = src.label;
                if (j == i) {
                    fs[@intCast(j)].type = null;
                    fs[@intCast(j)].value = if (src.type != null) ast.tm_var(0) else ast.tm_record_lit(null, 0);
                } else {
                    fs[@intCast(j)].type = if (src.type) |ty| ast.shift(1, 0, ty) else null;
                    fs[@intCast(j)].value = null;
                }
            }
            if (af.type == null) return ast.tm_union_lit(fs, n); // nullary: the value, not a function
            return ast.tm_lam(af.type.?, ast.tm_union_lit(fs, n));
        }
        // unknown alternative label: keep stuck (the typechecker rejects it)
    }
    return ast.tm_field(std.mem.span(t.as.field.label.?), r);
}

fn norm_merge(t: *dhall.Term) *dhall.Term {
    const h = normalize(t.as.merge.handlers.?);
    const u = normalize(t.as.merge.u.?);
    if (u.tag == .TmUnionLit) {
        // find the selected alternative (the one carrying a value)
        var sel: ?[*:0]const u8 = null;
        var v: ?*dhall.Term = null;
        var i: c_int = 0;
        while (i < u.as.uni.n) : (i += 1) {
            if (u.as.uni.fs.?[@intCast(i)].value) |val| {
                sel = u.as.uni.fs.?[@intCast(i)].label;
                v = val;
                break;
            }
        }
        if (sel != null and h.tag == .TmRecordLit) {
            var j: c_int = 0;
            while (j < h.as.rec.n) : (j += 1) {
                if (std.mem.eql(u8, std.mem.span(h.as.rec.fs.?[@intCast(j)].label.?), std.mem.span(sel.?)))
                    return normalize(ast.tm_app(h.as.rec.fs.?[@intCast(j)].value, v));
            }
        }
    }
    return ast.tm_merge(h, u); // stuck
}

/// toMap normalization: build a cons-list of {mapKey,mapValue} records
/// in (already-sorted) label order.
fn norm_tomap(t: *dhall.Term) *dhall.Term {
    const r = normalize(t.as.tomap.rec.?);
    if (r.tag != .TmRecordLit) return ast.tm_tomap(r); // stuck
    var out = ast.tm_nil();
    // labels are sorted; build the list in reverse then reverse
    var i: c_int = 0;
    while (i < r.as.rec.n) : (i += 1) {
        const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, 2 * @sizeOf(dhall.Field))));
        fs[0].label = arena.arena_strdup(arena.dhall_arena.?, "mapKey");
        fs[0].type = null;
        fs[0].value = ast.tm_text_lit(std.mem.span(r.as.rec.fs.?[@intCast(i)].label.?));
        fs[1].label = arena.arena_strdup(arena.dhall_arena.?, "mapValue");
        fs[1].type = null;
        fs[1].value = normalize(r.as.rec.fs.?[@intCast(i)].value.?);
        const item = ast.tm_record_lit(fs, 2);
        out = ast.tm_cons(item, out);
    }
    return reverse_list(out);
}

// ---- arithmetic/comparison delta (constant operands) ----

fn norm_op(t: *dhall.Term) *dhall.Term {
    const l = normalize(t.as.op.lhs.?);
    const r = normalize(t.as.op.rhs.?);
    const op = t.as.op.op;

    // boolean logic: eager AND/OR over Bool constants (no short-circuit)
    if (op == .OP_AND or op == .OP_OR) {
        if (l.tag == .TmConst and r.tag == .TmConst and
            l.as.c.kind == .C_BOOL and r.as.c.kind == .C_BOOL)
            return ast.tm_bool(if (op == .OP_AND) (l.as.c.b and r.as.c.b) else (l.as.c.b or r.as.c.b));
        return ast.tm_op(op, l, r); // stuck
    }

    if (l.tag == .TmConst and r.tag == .TmConst and l.as.c.kind == r.as.c.kind) {
        const k = l.as.c.kind;
        if (op == .OP_ADD or op == .OP_SUB or op == .OP_MUL) {
            switch (k) {
                .C_NAT => {
                    var sa: [2]u32 = undefined;
                    var sb: [2]u32 = undefined;
                    const A = bignum.const_bignat(l.as.c, &sa);
                    const B = bignum.const_bignat(r.as.c, &sb);
                    if (op == .OP_ADD) return ast.tm_const(bignum.bignat_to_const(bignum.bignat_add(&A, &B)));
                    if (op == .OP_SUB) return ast.tm_const(bignum.bignat_to_const(bignum.bignat_sub(&A, &B)));
                    return ast.tm_const(bignum.bignat_to_const(bignum.bignat_mul(&A, &B)));
                },
                .C_INT => {
                    var sa: [2]u32 = undefined;
                    var sb: [2]u32 = undefined;
                    const A = bignum.const_bigint(l.as.c, &sa);
                    const B = bignum.const_bigint(r.as.c, &sb);
                    if (op == .OP_ADD) return ast.tm_const(bignum.bigint_to_const(bignum.bigint_add(&A, &B)));
                    if (op == .OP_SUB) return ast.tm_const(bignum.bigint_to_const(bignum.bigint_sub(&A, &B)));
                    return ast.tm_const(bignum.bigint_to_const(bignum.bigint_mul(&A, &B)));
                },
                .C_DBL => {
                    const a = l.as.c.dbl;
                    const b = r.as.c.dbl;
                    if (op == .OP_ADD) return ast.tm_dbl(a + b);
                    if (op == .OP_SUB) return ast.tm_dbl(a - b);
                    return ast.tm_dbl(a * b);
                },
                else => {}, // Bool arithmetic is ill-typed
            }
        } else {
            // comparisons
            var lt = false;
            var le = false;
            var gt = false;
            var ge = false;
            var eq = false;
            switch (k) {
                .C_NAT => {
                    var sa: [2]u32 = undefined;
                    var sb: [2]u32 = undefined;
                    const A = bignum.const_bignat(l.as.c, &sa);
                    const B = bignum.const_bignat(r.as.c, &sb);
                    const c = bignum.bignat_cmp(&A, &B);
                    lt = c < 0;
                    le = c <= 0;
                    gt = c > 0;
                    ge = c >= 0;
                    eq = c == 0;
                },
                .C_INT => {
                    var sa: [2]u32 = undefined;
                    var sb: [2]u32 = undefined;
                    const A = bignum.const_bigint(l.as.c, &sa);
                    const B = bignum.const_bigint(r.as.c, &sb);
                    const c = bignum.bigint_cmp(&A, &B);
                    lt = c < 0;
                    le = c <= 0;
                    gt = c > 0;
                    ge = c >= 0;
                    eq = c == 0;
                },
                .C_DBL => {
                    lt = l.as.c.dbl < r.as.c.dbl;
                    le = l.as.c.dbl <= r.as.c.dbl;
                    gt = l.as.c.dbl > r.as.c.dbl;
                    ge = l.as.c.dbl >= r.as.c.dbl;
                    eq = l.as.c.dbl == r.as.c.dbl;
                },
                .C_BOOL => {
                    eq = l.as.c.b == r.as.c.b;
                },
            }
            switch (op) {
                .OP_LT => return ast.tm_bool(lt),
                .OP_LE => return ast.tm_bool(le),
                .OP_GT => return ast.tm_bool(gt),
                .OP_GE => return ast.tm_bool(ge),
                .OP_EQ => return ast.tm_bool(eq),
                .OP_NE => return ast.tm_bool(!eq),
                else => {},
            }
        }
    }
    // text equality
    if ((op == .OP_EQ or op == .OP_NE) and l.tag == .TmText and r.tag == .TmText
        and !text_has_interp(l) and !text_has_interp(r)) {
        const eq = std.mem.eql(u8, std.mem.span(l.as.text.?.lit.?), std.mem.span(r.as.text.?.lit.?));
        return ast.tm_bool(if (op == .OP_EQ) eq else !eq);
    }
    return ast.tm_op(op, l, r); // stuck
}

/// binary search in a sorted Field array (mirrors typecheck.c field_find)
fn nfield_find(fs: ?[*]dhall.Field, n: c_int, label: []const u8) c_int {
    var lo: c_int = 0;
    var hi: c_int = n - 1;
    while (lo <= hi) {
        const mid = @divTrunc(lo + hi, 2);
        const c = std.mem.order(u8, std.mem.span(fs.?[@intCast(mid)].label.?), label);
        if (c == .eq) return mid;
        if (c == .lt) {
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return -1;
}

/// C-style strcmp over label slices: -1 / 0 / +1 (mirrors normalize.c strcmp).
fn cmp_labels(a: []const u8, b: []const u8) i8 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

// ---- record merge /\\ ----

fn merge_record_lits_norm(l: *dhall.Term, r: *dhall.Term) *dhall.Term {
    const lfs = l.as.rec.fs.?;
    const ln = l.as.rec.n;
    const rfs = r.as.rec.fs.?;
    const rn = r.as.rec.n;
    const out: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(ln + rn)) * @sizeOf(dhall.Field))));
    var n: c_int = 0;
    var i: c_int = 0;
    var j: c_int = 0;
    while (i < ln or j < rn) {
        var cmp: i8 = undefined;
        if (i >= ln) {
            cmp = 1;
        } else if (j >= rn) {
            cmp = -1;
        } else {
            cmp = cmp_labels(std.mem.span(lfs[@intCast(i)].label.?), std.mem.span(rfs[@intCast(j)].label.?));
        }
        if (cmp < 0) {
            out[@intCast(n)] = lfs[@intCast(i)];
            n += 1;
            i += 1;
        } else if (cmp > 0) {
            out[@intCast(n)] = rfs[@intCast(j)];
            n += 1;
            j += 1;
        } else {
            out[@intCast(n)].label = lfs[@intCast(i)].label;
            out[@intCast(n)].type = null;
            out[@intCast(n)].value = norm_combine(lfs[@intCast(i)].value.?, rfs[@intCast(j)].value.?);
            n += 1;
            i += 1;
            j += 1;
        }
    }
    return ast.tm_record_lit(out, n);
}

fn merge_record_types_norm(l: *dhall.Term, r: *dhall.Term) *dhall.Term {
    const lfs = l.as.rec.fs.?;
    const ln = l.as.rec.n;
    const rfs = r.as.rec.fs.?;
    const rn = r.as.rec.n;
    const out: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(ln + rn)) * @sizeOf(dhall.Field))));
    var n: c_int = 0;
    var i: c_int = 0;
    var j: c_int = 0;
    while (i < ln or j < rn) {
        var cmp: i8 = undefined;
        if (i >= ln) {
            cmp = 1;
        } else if (j >= rn) {
            cmp = -1;
        } else {
            cmp = cmp_labels(std.mem.span(lfs[@intCast(i)].label.?), std.mem.span(rfs[@intCast(j)].label.?));
        }
        if (cmp < 0) {
            out[@intCast(n)] = lfs[@intCast(i)];
            n += 1;
            i += 1;
        } else if (cmp > 0) {
            out[@intCast(n)] = rfs[@intCast(j)];
            n += 1;
            j += 1;
        } else {
            out[@intCast(n)].label = lfs[@intCast(i)].label;
            out[@intCast(n)].type = norm_combine(lfs[@intCast(i)].type.?, rfs[@intCast(j)].type.?);
            out[@intCast(n)].value = null;
            n += 1;
            i += 1;
            j += 1;
        }
    }
    return ast.tm_record_type(out, n);
}

fn norm_combine(l: *dhall.Term, r: *dhall.Term) *dhall.Term {
    const l2 = normalize(l);
    const r2 = normalize(r);
    if (l2.tag == .TmRecordLit and r2.tag == .TmRecordLit)
        return merge_record_lits_norm(l2, r2);
    if (l2.tag == .TmRecordType and r2.tag == .TmRecordType)
        return merge_record_types_norm(l2, r2);
    return ast.tm_combine(l2, r2); // stuck
}

// ---- with record update ----

fn insert_field_lit(rec: *dhall.Term, k: []const u8, v: *dhall.Term) *dhall.Term {
    const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(rec.as.rec.n + 1)) * @sizeOf(dhall.Field))));
    var out: c_int = 0;
    var inserted = false;
    var j: c_int = 0;
    while (j < rec.as.rec.n) : (j += 1) {
        if (!inserted and cmp_labels(std.mem.span(rec.as.rec.fs.?[@intCast(j)].label.?), k) > 0) {
            fs[@intCast(out)].label = arena.arena_strdup(arena.dhall_arena.?, k);
            fs[@intCast(out)].type = null;
            fs[@intCast(out)].value = v;
            out += 1;
            inserted = true;
        }
        fs[@intCast(out)] = rec.as.rec.fs.?[@intCast(j)];
        out += 1;
    }
    if (!inserted) {
        fs[@intCast(out)].label = arena.arena_strdup(arena.dhall_arena.?, k);
        fs[@intCast(out)].type = null;
        fs[@intCast(out)].value = v;
        out += 1;
    }
    return ast.tm_record_lit(fs, out);
}

fn update_field_lit(rec: *dhall.Term, i: c_int, v: *dhall.Term) *dhall.Term {
    const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(rec.as.rec.n)) * @sizeOf(dhall.Field))));
    const n: usize = @intCast(rec.as.rec.n);
    @memcpy(fs[0..n], rec.as.rec.fs.?[0..n]);
    fs[@intCast(i)].value = v;
    return ast.tm_record_lit(fs, rec.as.rec.n);
}

fn with_update_lit(rec: *dhall.Term, path: ?[*]?[*:0]u8, n: c_int, v: *dhall.Term) *dhall.Term {
    const k = std.mem.span(path.?[0].?);
    const i = nfield_find(rec.as.rec.fs, rec.as.rec.n, k);
    if (i >= 0) {
        if (n == 1) return update_field_lit(rec, i, v);
        const sub = rec.as.rec.fs.?[@intCast(i)].value.?;
        const newsub = if (sub.tag == .TmRecordLit)
            with_update_lit(sub, path.? + 1, n - 1, v)
        else
            ast.tm_with(sub, path.? + 1, n - 1, v);
        return update_field_lit(rec, i, newsub);
    }
    if (n == 1) return insert_field_lit(rec, k, v);
    const sub = with_update_lit(ast.tm_record_lit(null, 0), path.? + 1, n - 1, v);
    return insert_field_lit(rec, k, sub);
}

fn norm_with(t: *dhall.Term) *dhall.Term {
    const r = normalize(t.as.with_.rec.?);
    const v = normalize(t.as.with_.value.?);
    if (r.tag != .TmRecordLit) return ast.tm_with(r, t.as.with_.path, t.as.with_.npath, v);
    return with_update_lit(r, t.as.with_.path, t.as.with_.npath, v);
}

// ---- list append # ----

fn norm_list_append(a: *dhall.Term, b: *dhall.Term) *dhall.Term {
    const a2 = normalize(a);
    const b2 = normalize(b);
    if (a2.tag == .TmNil) return b2;
    if (a2.tag == .TmCons) return ast.tm_cons(a2.as.cons.head, norm_list_append(a2.as.cons.tail.?, b2));
    return ast.tm_list_append(a2, b2); // stuck
}

// ---- record prefer // (right-biased, non-recursive) ----

fn prefer_merge_lits(l: *dhall.Term, r: *dhall.Term) *dhall.Term {
    const lfs = l.as.rec.fs.?;
    const ln = l.as.rec.n;
    const rfs = r.as.rec.fs.?;
    const rn = r.as.rec.n;
    const out: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(ln + rn)) * @sizeOf(dhall.Field))));
    var n: c_int = 0;
    var i: c_int = 0;
    var j: c_int = 0;
    while (i < ln or j < rn) {
        var cmp: i8 = undefined;
        if (i >= ln) {
            cmp = 1;
        } else if (j >= rn) {
            cmp = -1;
        } else {
            cmp = cmp_labels(std.mem.span(lfs[@intCast(i)].label.?), std.mem.span(rfs[@intCast(j)].label.?));
        }
        if (cmp < 0) {
            out[@intCast(n)] = lfs[@intCast(i)];
            n += 1;
            i += 1;
        } else if (cmp > 0) {
            out[@intCast(n)] = rfs[@intCast(j)];
            n += 1;
            j += 1;
        } else {
            out[@intCast(n)] = rfs[@intCast(j)]; // shared label: right wins
            n += 1;
            i += 1;
            j += 1;
        }
    }
    return ast.tm_record_lit(out, n);
}

fn prefer_merge_types(l: *dhall.Term, r: *dhall.Term) *dhall.Term {
    const lfs = l.as.rec.fs.?;
    const ln = l.as.rec.n;
    const rfs = r.as.rec.fs.?;
    const rn = r.as.rec.n;
    const out: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(ln + rn)) * @sizeOf(dhall.Field))));
    var n: c_int = 0;
    var i: c_int = 0;
    var j: c_int = 0;
    while (i < ln or j < rn) {
        var cmp: i8 = undefined;
        if (i >= ln) {
            cmp = 1;
        } else if (j >= rn) {
            cmp = -1;
        } else {
            cmp = cmp_labels(std.mem.span(lfs[@intCast(i)].label.?), std.mem.span(rfs[@intCast(j)].label.?));
        }
        if (cmp < 0) {
            out[@intCast(n)] = lfs[@intCast(i)];
            n += 1;
            i += 1;
        } else if (cmp > 0) {
            out[@intCast(n)] = rfs[@intCast(j)];
            n += 1;
            j += 1;
        } else {
            out[@intCast(n)] = rfs[@intCast(j)]; // shared label: right wins
            n += 1;
            i += 1;
            j += 1;
        }
    }
    return ast.tm_record_type(out, n);
}

fn norm_prefer(l: *dhall.Term, r: *dhall.Term) *dhall.Term {
    const l2 = normalize(l);
    const r2 = normalize(r);
    if (l2.tag == .TmRecordLit and r2.tag == .TmRecordLit) return prefer_merge_lits(l2, r2);
    if (l2.tag == .TmRecordType and r2.tag == .TmRecordType) return prefer_merge_types(l2, r2);
    return ast.tm_prefer(l2, r2); // stuck
}

// ---- Double/show / Text/show renderers ----

fn dbl_show(d: f64) *dhall.Term {
    var dbuf: [64]u8 = undefined;
    ast.dbl_fmt(&dbuf, dbuf.len, d);
    return ast.tm_text_lit(std.mem.sliceTo(&dbuf, 0));
}

fn text_show(t: *dhall.Term) *dhall.Term {
    const s = t.as.text.?.lit.?;
    var b: dhall.TmpBuf = undefined;
    arena.tmpbuf_init(&b);
    arena.tmpbuf_addc(&b, '"');
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        switch (s[i]) {
            '"' => arena.tmpbuf_add(&b, "\\\""),
            '\\' => arena.tmpbuf_add(&b, "\\\\"),
            '$' => arena.tmpbuf_add(&b, "\\u0024"),
            '\x08' => arena.tmpbuf_add(&b, "\\b"),
            '\x0c' => arena.tmpbuf_add(&b, "\\f"),
            '\n' => arena.tmpbuf_add(&b, "\\n"),
            '\r' => arena.tmpbuf_add(&b, "\\r"),
            '\t' => arena.tmpbuf_add(&b, "\\t"),
            else => {
                if (s[i] < 0x20) {
                    var esc: [8]u8 = undefined;
                    const es = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{s[i]}) catch unreachable;
                    arena.tmpbuf_add(&b, es);
                } else {
                    arena.tmpbuf_addc(&b, s[i]);
                }
            },
        }
    }
    arena.tmpbuf_addc(&b, '"');
    return ast.tm_text_lit(std.mem.span(arena.tmpbuf_arena(arena.dhall_arena.?, &b)));
}

pub fn normalize(t: *dhall.Term) *dhall.Term {
    switch (t.tag) {
        .TmVar, .TmConst, .TmType, .TmKind, .TmSort,
        .TmNil, .TmBuiltin => return t,
        .TmLam => return ast.tm_lam(normalize(t.as.lam.dom.?), normalize(t.as.lam.body.?)),
        .TmPi => return ast.tm_pi(normalize(t.as.pi.dom.?), normalize(t.as.pi.cod.?)),
        .TmAnn => return normalize(t.as.ann.e.?),
        .TmLet => return normalize(ast.subst(0, t.as.let_.val.?, t.as.let_.body.?)),
        .TmCons => return ast.tm_cons(normalize(t.as.cons.head.?), normalize(t.as.cons.tail.?)),
        .TmText => return norm_text(t),
        .TmTextAppend => {
            const a = normalize(t.as.append.a.?);
            const b = normalize(t.as.append.b.?);
            if (a.tag == .TmText and b.tag == .TmText) {
                // only safe when both are pure literals (no interpolation)
                if (!text_has_interp(a) and !text_has_interp(b)) {
                    var buf: dhall.TmpBuf = undefined;
                    arena.tmpbuf_init(&buf);
                    arena.tmpbuf_add(&buf, std.mem.span(a.as.text.?.lit.?));
                    arena.tmpbuf_add(&buf, std.mem.span(b.as.text.?.lit.?));
                    return ast.tm_text_lit(std.mem.span(arena.tmpbuf_arena(arena.dhall_arena.?, &buf)));
                }
            }
            return ast.tm_append(a, b);
        },
        .TmIf => {
            const c = normalize(t.as.if_.c.?);
            if (c.tag == .TmConst and c.as.c.kind == .C_BOOL)
                return if (c.as.c.b) normalize(t.as.if_.t.?) else normalize(t.as.if_.e.?);
            return ast.tm_if(c, normalize(t.as.if_.t.?), normalize(t.as.if_.e.?));
        },
        .TmApp => {
            var args: [6]*dhall.Term = undefined;
            if (match_builtin("List/map", 4, t, args[0..4])) {
                const xs = normalize(args[3]);
                if (xs.tag == .TmNil) return ast.tm_nil();
                if (xs.tag == .TmCons) {
                    const head = normalize(ast.tm_app(args[2], xs.as.cons.head));
                    const rest = normalize(ast.tm_app(ast.tm_app(ast.tm_app(ast.tm_app(ast.tm_builtin("List/map"), args[0]), args[1]), args[2]), xs.as.cons.tail));
                    return ast.tm_cons(head, rest);
                }
            }
            if (match_builtin("List/filter", 3, t, args[0..3])) {
                const xs = normalize(args[2]);
                if (xs.tag == .TmNil) return ast.tm_nil();
                if (xs.tag == .TmCons) {
                    const pred = normalize(ast.tm_app(args[1], xs.as.cons.head));
                    const tail = normalize(ast.tm_app(ast.tm_app(ast.tm_app(ast.tm_builtin("List/filter"), args[0]), args[1]), xs.as.cons.tail));
                    if (pred.tag == .TmConst and pred.as.c.kind == .C_BOOL)
                        return if (pred.as.c.b) ast.tm_cons(normalize(xs.as.cons.head.?), tail) else tail;
                    return ast.tm_cons(normalize(xs.as.cons.head.?), tail);
                }
            }
            if (match_builtin("List/reverse", 2, t, args[0..2])) {
                return reverse_list(normalize(args[1]));
            }
            if (match_builtin("List/fold", 5, t, args[0..5])) {
                const xs = normalize(args[1]);
                if (xs.tag == .TmNil) return normalize(args[4]);
                if (xs.tag == .TmCons) {
                    const rest = normalize(ast.tm_app(ast.tm_app(ast.tm_app(ast.tm_app(ast.tm_app(ast.tm_builtin("List/fold"), args[0]), xs.as.cons.tail), args[2]), args[3]), args[4]));
                    return normalize(ast.tm_app(ast.tm_app(args[3], xs.as.cons.head), rest));
                }
            }
            if (match_builtin("Optional/fold", 5, t, args[0..5])) {
                // args: [0]=T, [1]=value, [2]=A, [3]=some (T->A), [4]=none (A)
                const v = normalize(args[1]);
                if (v.tag == .TmSome) return normalize(ast.tm_app(args[3], v.as.some.val));
                if (v.tag == .TmNone) return normalize(args[4]);
            }
            if (match_builtin("Natural/fold", 4, t, args[0..4])) {
                // args: [0]=n, [1]=A, [2]=step (A->A), [3]=base (A)
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_NAT) {
                    var scratch: [2]u32 = undefined;
                    var ok: bool = undefined;
                    const B = bignum.const_bignat(n.as.c, &scratch);
                    const count = bignum.bignat_to_u64(&B, &ok);
                    if (!ok or count > MAX_NAT_FOLD) {
                        norm_set_error(t.loc, "Natural/fold limit exceeded");
                        return t; // stuck
                    }
                    var acc = normalize(args[3]);
                    var i: u64 = 0;
                    while (i < count) : (i += 1)
                        acc = normalize(ast.tm_app(args[2], acc));
                    return acc;
                }
            }
            if (match_builtin("Natural/isZero", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_NAT) {
                    var scratch: [2]u32 = undefined;
                    const B = bignum.const_bignat(n.as.c, &scratch);
                    return ast.tm_bool(bignum.bignat_is_zero(&B));
                }
            }
            if (match_builtin("Natural/show", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_NAT) {
                    var scratch: [2]u32 = undefined;
                    const B = bignum.const_bignat(n.as.c, &scratch);
                    return ast.tm_text_lit(std.mem.span(bignum.bignat_to_decimal(&B)));
                }
            }
            if (match_builtin("Natural/subtract", 2, t, args[0..2])) {
                // Natural/subtract : Natural -> Natural -> Natural = max(b - a, 0)
                // (arg order opposite the `-` operator)
                const a = normalize(args[0]);
                const b = normalize(args[1]);
                if (a.tag == .TmConst and a.as.c.kind == .C_NAT and
                    b.tag == .TmConst and b.as.c.kind == .C_NAT)
                {
                    var sa: [2]u32 = undefined;
                    var sb: [2]u32 = undefined;
                    const A = bignum.const_bignat(a.as.c, &sa);
                    const B = bignum.const_bignat(b.as.c, &sb);
                    return ast.tm_const(bignum.bignat_to_const(bignum.bignat_sub(&B, &A)));
                }
            }
            if (match_builtin("Natural/even", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_NAT) {
                    var scratch: [2]u32 = undefined;
                    const B = bignum.const_bignat(n.as.c, &scratch);
                    return ast.tm_bool(bignum.bignat_even(&B));
                }
            }
            if (match_builtin("Natural/odd", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_NAT) {
                    var scratch: [2]u32 = undefined;
                    const B = bignum.const_bignat(n.as.c, &scratch);
                    return ast.tm_bool(!bignum.bignat_even(&B));
                }
            }
            if (match_builtin("Natural/toInteger", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_NAT) {
                    var scratch: [2]u32 = undefined;
                    const B = bignum.const_bignat(n.as.c, &scratch);
                    const bi = dhall.BigInt{ .neg = false, .mag = B };
                    return ast.tm_const(bignum.bigint_to_const(bi));
                }
            }
            if (match_builtin("Integer/toDouble", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_INT) {
                    var scratch: [2]u32 = undefined;
                    const B = bignum.const_bigint(n.as.c, &scratch);
                    return ast.tm_dbl(bignum.bigint_to_double(&B));
                }
            }
            if (match_builtin("Text/replace", 3, t, args[0..3])) {
                const needle = normalize(args[0]);
                const repl = normalize(args[1]);
                const hay = normalize(args[2]);
                if (needle.tag == .TmText and !text_has_interp(needle) and
                    repl.tag == .TmText and !text_has_interp(repl) and
                    hay.tag == .TmText and !text_has_interp(hay))
                {
                    const nd = std.mem.span(needle.as.text.?.lit.?);
                    const rp = std.mem.span(repl.as.text.?.lit.?);
                    var hs = std.mem.span(hay.as.text.?.lit.?);
                    const ndlen = nd.len;
                    if (ndlen == 0) return ast.tm_text_lit(hs); // guard: no infinite loop
                    var buf: dhall.TmpBuf = undefined;
                    arena.tmpbuf_init(&buf);
                    while (true) {
                        if (std.mem.indexOf(u8, hs, nd)) |found_pos| {
                            arena.tmpbuf_add(&buf, hs[0..found_pos]);
                            arena.tmpbuf_add(&buf, rp);
                            hs = hs[found_pos + ndlen ..];
                        } else {
                            arena.tmpbuf_add(&buf, hs);
                            break;
                        }
                    }
                    return ast.tm_text_lit(std.mem.span(arena.tmpbuf_arena(arena.dhall_arena.?, &buf)));
                }
            }
            if (match_builtin("List/length", 2, t, args[0..2])) {
                const xs = normalize(args[1]);
                var cur = xs;
                var count: u64 = 0;
                while (cur.tag == .TmCons) {
                    count += 1;
                    cur = cur.as.cons.tail.?;
                }
                if (cur.tag == .TmNil) return ast.tm_nat(count);
                // stuck list (bound var / stuck tail): fall through and leave
                // the application stuck, mirroring List/map/List/reverse
            }
            if (match_builtin("Integer/negate", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_INT) {
                    var scratch: [2]u32 = undefined;
                    const B = bignum.const_bigint(n.as.c, &scratch);
                    return ast.tm_const(bignum.bigint_to_const(bignum.bigint_neg(&B)));
                }
            }
            if (match_builtin("Integer/show", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_INT) {
                    var scratch: [2]u32 = undefined;
                    const B = bignum.const_bigint(n.as.c, &scratch);
                    const dec = bignum.bigint_to_decimal(&B);
                    if (B.neg) return ast.tm_text_lit(std.mem.span(dec));
                    const dlen = std.mem.len(dec);
                    const s = arena.arena_alloc(arena.dhall_arena.?, dlen + 2);
                    s[0] = '+';
                    @memcpy(s[1 .. dlen + 1], dec[0..dlen]);
                    s[dlen + 1] = 0;
                    const sz: [*:0]u8 = @ptrCast(s);
                    return ast.tm_text_lit(std.mem.span(sz));
                }
            }
            if (match_builtin("Integer/clamp", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_INT) {
                    var scratch: [2]u32 = undefined;
                    const B = bignum.const_bigint(n.as.c, &scratch);
                    if (B.neg) return ast.tm_nat(0);
                    return ast.tm_const(bignum.bignat_to_const(B.mag));
                }
            }
            if (match_builtin("Double/show", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmConst and n.as.c.kind == .C_DBL)
                    return dbl_show(n.as.c.dbl);
            }
            if (match_builtin("Text/show", 1, t, args[0..1])) {
                const n = normalize(args[0]);
                if (n.tag == .TmText and !text_has_interp(n))
                    return text_show(n);
            }
            if (match_builtin("List/head", 2, t, args[0..2])) {
                const xs = normalize(args[1]);
                if (xs.tag == .TmCons) return ast.tm_some(xs.as.cons.head);
                if (xs.tag == .TmNil) return ast.tm_none(normalize(args[0]));
            }
            if (match_builtin("List/last", 2, t, args[0..2])) {
                const xs = normalize(args[1]);
                if (xs.tag == .TmNil) return ast.tm_none(normalize(args[0]));
                if (xs.tag == .TmCons) {
                    var cur = xs;
                    while (cur.as.cons.tail.?.tag == .TmCons) cur = cur.as.cons.tail.?;
                    if (cur.as.cons.tail.?.tag != .TmNil) return t; // stuck tail
                    return ast.tm_some(cur.as.cons.head);
                }
            }
            if (match_builtin("List/indexed", 2, t, args[0..2])) {
                const xs = normalize(args[1]);
                if (xs.tag == .TmNil) return ast.tm_nil();
                if (xs.tag == .TmCons) {
                    var rev = ast.tm_nil();
                    var i: u64 = 0;
                    var cur = xs;
                    while (cur.tag == .TmCons) {
                        const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, 2 * @sizeOf(dhall.Field))));
                        fs[0].label = arena.arena_strdup(arena.dhall_arena.?, "index");
                        fs[0].type = null;
                        fs[0].value = ast.tm_nat(i);
                        fs[1].label = arena.arena_strdup(arena.dhall_arena.?, "value");
                        fs[1].type = null;
                        fs[1].value = cur.as.cons.head;
                        rev = ast.tm_cons(ast.tm_record_lit(fs, 2), rev);
                        i += 1;
                        cur = cur.as.cons.tail.?;
                    }
                    if (cur.tag != .TmNil) return t; // stuck tail
                    return reverse_list(rev);
                }
            }
            if (match_builtin("List/build", 2, t, args[0..2])) {
                const A = normalize(args[0]);
                const g = normalize(args[1]);
                const listA = ast.tm_app(ast.tm_builtin("List"), A);
                const cons = ast.tm_lam(A, ast.tm_lam(listA, ast.tm_cons(ast.tm_var(1), ast.tm_var(0))));
                return normalize(ast.tm_app(ast.tm_app(ast.tm_app(g, listA), cons), ast.tm_nil()));
            }
            if (match_builtin("Natural/build", 1, t, args[0..1])) {
                const g = normalize(args[0]);
                const succ = ast.tm_lam(ast.tm_builtin("Natural"), ast.tm_op(.OP_ADD, ast.tm_var(0), ast.tm_nat(1)));
                return normalize(ast.tm_app(ast.tm_app(ast.tm_app(g, ast.tm_builtin("Natural")), succ), ast.tm_nat(0)));
            }
            const f = normalize(t.as.app.fn_.?);
            if (f.tag == .TmLam) return normalize(ast.subst(0, t.as.app.arg.?, f.as.lam.body.?));
            return ast.tm_app(f, normalize(t.as.app.arg.?));
        },
        .TmRecordType => {
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(t.as.rec.n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < t.as.rec.n) : (i += 1) {
                fs[@intCast(i)].label = t.as.rec.fs.?[@intCast(i)].label;
                fs[@intCast(i)].type = if (t.as.rec.fs.?[@intCast(i)].type) |ty| normalize(ty) else null;
                fs[@intCast(i)].value = null;
            }
            return ast.tm_record_type(fs, t.as.rec.n);
        },
        .TmRecordLit => {
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(t.as.rec.n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < t.as.rec.n) : (i += 1) {
                fs[@intCast(i)].label = t.as.rec.fs.?[@intCast(i)].label;
                fs[@intCast(i)].type = null;
                fs[@intCast(i)].value = normalize(t.as.rec.fs.?[@intCast(i)].value.?);
            }
            return ast.tm_record_lit(fs, t.as.rec.n);
        },
        .TmField => return norm_field(t),
        .TmUnionType => {
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(t.as.uni.n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < t.as.uni.n) : (i += 1) {
                fs[@intCast(i)].label = t.as.uni.fs.?[@intCast(i)].label;
                fs[@intCast(i)].type = if (t.as.uni.fs.?[@intCast(i)].type) |ty| normalize(ty) else null;
                fs[@intCast(i)].value = null;
            }
            return ast.tm_union_type(fs, t.as.uni.n);
        },
        .TmUnionLit => {
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(t.as.uni.n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < t.as.uni.n) : (i += 1) {
                fs[@intCast(i)].label = t.as.uni.fs.?[@intCast(i)].label;
                fs[@intCast(i)].type = if (t.as.uni.fs.?[@intCast(i)].type) |ty| normalize(ty) else null;
                fs[@intCast(i)].value = if (t.as.uni.fs.?[@intCast(i)].value) |v| normalize(v) else null;
            }
            return ast.tm_union_lit(fs, t.as.uni.n);
        },
        .TmMerge => return norm_merge(t),
        .TmSome => return ast.tm_some(normalize(t.as.some.val.?)),
        .TmNone => return ast.tm_none(normalize(t.as.none.ty.?)),
        .TmOp => return norm_op(t),
        .TmAssert => {
            const b = normalize(t.as.assert_.body.?);
            // only a literal True assertion holds; never claim true blindly
            if (b.tag == .TmConst and b.as.c.kind == .C_BOOL and b.as.c.b)
                return ast.tm_bool(true);
            if (b.tag == .TmConst and b.as.c.kind == .C_BOOL and !b.as.c.b)
                norm_set_error(t.loc, "assertion did not hold");
            return ast.tm_assert(b); // stuck / non-Bool body: keep the assert
        },
        .TmToMap => return norm_tomap(t),
        .TmCombine => return norm_combine(t.as.combine.lhs.?, t.as.combine.rhs.?),
        .TmWith => return norm_with(t),
        .TmListAppend => return norm_list_append(t.as.lappend.a.?, t.as.lappend.b.?),
        .TmPrefer => return norm_prefer(t.as.prefer.lhs.?, t.as.prefer.rhs.?),
    }
    return t;
}
