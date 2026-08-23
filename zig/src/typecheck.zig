// typecheck.zig — port of ../src/typecheck.c, VERBATIM in behavior.
// Bidirectional infer/check over Terms with a growable context stack (Ctx),
// resolve_type, and err_here varargs error formatting. Types are compared by
// alphaEq(norm(a), norm(b)); dependent Pi substitution for application.
//
// NOTE on error messages: every format string below is copied VERBATIM from
// typecheck.c (the 55 .expected.err fixtures grep -F exact substrings). Do NOT
// reword. Because err_here needs DYNAMIC (non-comptime-arg) formatting and
// ast.dhall_error_set only takes comptime formats, this module formats into the
// message buffer directly (see the U4 reviewer nit) — it does not route through
// dhall_error_set.
//
// The normalize error channel is a module-global with first-error-wins, exactly
// like the C original (infer_type reads normalize_get_error()).

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const normalize = @import("normalize.zig");

const alloc = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// context: growable stack of types, parallel names for diagnostics
// ---------------------------------------------------------------------------

const Ctx = struct {
    types: std.ArrayList(*dhall.Term),
    vals: std.ArrayList(?*dhall.Term),
    names: std.ArrayList(?[*:0]const u8),

    fn init() Ctx {
        return .{
            .types = std.ArrayList(*dhall.Term).initCapacity(alloc, 64) catch unreachable,
            .vals = std.ArrayList(?*dhall.Term).initCapacity(alloc, 64) catch unreachable,
            .names = std.ArrayList(?[*:0]const u8).initCapacity(alloc, 64) catch unreachable,
        };
    }
    fn deinit(self: *Ctx) void {
        self.types.deinit(alloc);
        self.vals.deinit(alloc);
        self.names.deinit(alloc);
    }
    fn push(self: *Ctx, ty: *dhall.Term, nm: ?[*:0]const u8, val: ?*dhall.Term) void {
        self.types.append(alloc, ty) catch unreachable;
        self.vals.append(alloc, val) catch unreachable;
        self.names.append(alloc, nm) catch unreachable;
    }
    fn pop(self: *Ctx) void {
        if (self.types.items.len > 0) {
            _ = self.types.pop();
            _ = self.vals.pop();
            _ = self.names.pop();
        }
    }
    fn lookup(self: *Ctx, idx: c_int) ?*dhall.Term {
        const n = self.types.items.len;
        if (idx < 0 or idx >= n) return null;
        const pos = n - 1 - @as(usize, @intCast(idx));
        if (pos >= n) return null;
        return ast.shift(idx + 1, 0, self.types.items[pos]);
    }
    fn name(self: *Ctx, idx: c_int) [*:0]const u8 {
        const n = self.names.items.len;
        if (idx < 0 or idx >= n) return "?";
        const pos = n - 1 - @as(usize, @intCast(idx));
        if (pos >= n) return "?";
        return self.names.items[pos] orelse "?";
    }
};

// ---- error formatting (mirrors err_here, typecheck.c:69-77) ----
// Pre-formats the dynamic message with std.fmt into the 512-byte buffer, then
// fills the DhallError fields. This is the U4-reviewer-sanctioned path: do NOT
// try to route varargs through ast.dhall_error_set (comptime-only).
fn err_here(e: *dhall.DhallError, st: dhall.ErrorStage, t: *dhall.Term, comptime fmt: []const u8, args: anytype) void {
    var m: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&m, fmt, args) catch unreachable;
    e.stage = st;
    e.span = t.loc;
    e.has_span = t.loc.line > 0;
    @memcpy(e.msg[0..s.len], s);
    e.msg[s.len] = 0;
}

/// C-style strcmp over label slices: -1 / 0 / +1 (mirrors typecheck.c strcmp).
fn cmp_labels(a: []const u8, b: []const u8) i8 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn is_sort(t: *dhall.Term) bool {
    return t.tag == .TmType or t.tag == .TmKind or t.tag == .TmSort;
}

// Is `t` (assumed normalized) usable in TYPE position — i.e. is it a sort
// (Type/Kind/Sort) or the empty record type `{}`?  `{=}` parses as an empty
// record LITERAL, whose inferred type is `{}` (TmRecordType, n==0); since the
// empty record value and type coincide (alpha_eq treats TmRecordType and
// TmRecordLit alike), `{=}` is a valid empty-record type marker in the schema
// DSL.  A non-empty record type is already accepted (inferring a TmRecordType
// yields Type, a sort); only the empty case needs this special case.
fn is_type_position(t: *dhall.Term) bool {
    if (is_sort(t)) return true;
    return t.tag == .TmRecordType and t.as.rec.n == 0;
}

// fields must be sorted & unique by label; find index of label (binary)
fn field_find(fs: ?[*]dhall.Field, n: c_int, label: []const u8) c_int {
    var lo: c_int = 0;
    var hi: c_int = n - 1;
    while (lo <= hi) {
        const mid = @divTrunc(lo + hi, 2);
        const c = cmp_labels(std.mem.span(fs.?[@intCast(mid)].label.?), label);
        if (c == 0) return mid;
        if (c < 0) lo = mid + 1 else hi = mid - 1;
    }
    return -1;
}

fn fields_label_sets_equal(a: ?[*]dhall.Field, na: c_int, b: ?[*]dhall.Field, nb: c_int) bool {
    if (na != nb) return false;
    var i: c_int = 0;
    while (i < na) : (i += 1) {
        if (!std.mem.eql(u8, std.mem.span(a.?[@intCast(i)].label.?), std.mem.span(b.?[@intCast(i)].label.?))) return false;
    }
    return true;
}

fn is_list_type(t: *dhall.Term) bool {
    if (t.tag != .TmApp) return false;
    return t.as.app.fn_.?.tag == .TmBuiltin and std.mem.eql(u8, std.mem.span(t.as.app.fn_.?.as.bname.?), "List");
}

fn is_optional_type(t: *dhall.Term) bool {
    if (t.tag != .TmApp) return false;
    return t.as.app.fn_.?.tag == .TmBuiltin and std.mem.eql(u8, std.mem.span(t.as.app.fn_.?.as.bname.?), "Optional");
}

// scalar-kind classification for binary operators; SC_NONE if not scalar
const SC_NONE: c_int = -1;
const SC_NAT: c_int = 0;
const SC_INT: c_int = 1;
const SC_DBL: c_int = 2;
const SC_BOOL: c_int = 3;
const SC_TEXT: c_int = 4;

fn scalar_kind(ty: *dhall.Term) c_int {
    if (ty.tag == .TmBuiltin) {
        const b = std.mem.span(ty.as.bname.?);
        if (std.mem.eql(u8, b, "Natural")) return SC_NAT;
        if (std.mem.eql(u8, b, "Integer")) return SC_INT;
        if (std.mem.eql(u8, b, "Double")) return SC_DBL;
        if (std.mem.eql(u8, b, "Bool")) return SC_BOOL;
        if (std.mem.eql(u8, b, "Text")) return SC_TEXT;
    }
    return SC_NONE;
}

fn infer_binop(g: *Ctx, t: *dhall.Term, err: *dhall.DhallError) ?*dhall.Term {
    const lty = infer(g, t.as.op.lhs.?, err) orelse return null;
    const rty = infer(g, t.as.op.rhs.?, err) orelse return null;
    const nl = normalize.normalize(lty);
    const nr = normalize.normalize(rty);
    if (!ast.alpha_eq(nl, nr)) {
        err_here(err, .ERR_TYPE, t, "operands of different types", .{});
        return null;
    }
    const k = scalar_kind(nl);
    const op = t.as.op.op;
    if (op == .OP_AND or op == .OP_OR) {
        if (k != SC_BOOL) {
            err_here(err, .ERR_TYPE, t, "logical operator requires Bool operands", .{});
            return null;
        }
        return ast.tm_builtin("Bool");
    }
    if (op == .OP_ADD or op == .OP_SUB or op == .OP_MUL) {
        if (k != SC_NAT and k != SC_INT and k != SC_DBL) {
            err_here(err, .ERR_TYPE, t, "arithmetic operator requires Natural/Integer/Double operands", .{});
            return null;
        }
        return nl;
    }
    if (op == .OP_LT or op == .OP_LE or op == .OP_GT or op == .OP_GE) {
        if (k != SC_NAT and k != SC_INT and k != SC_DBL) {
            err_here(err, .ERR_TYPE, t, "comparison operator requires Natural/Integer/Double operands", .{});
            return null;
        }
        return ast.tm_builtin("Bool");
    }
    // OP_EQ / OP_NE
    if (k != SC_BOOL and k != SC_NAT and k != SC_INT and k != SC_DBL and k != SC_TEXT) {
        err_here(err, .ERR_TYPE, t, "equality operator does not support this type", .{});
        return null;
    }
    return ast.tm_builtin("Bool");
}

// recursive merge of two record TYPES. A shared field must recursively be a
// record type, else this is a type error (the faithful Dhall rule — the
// right-biased OVERRIDE is the separate // operator, out of scope).
fn merge_record_types(l: *dhall.Term, r: *dhall.Term, loc: *dhall.Term, err: *dhall.DhallError) ?*dhall.Term {
    const lfs = l.as.rec.fs;
    const ln = l.as.rec.n;
    const rfs = r.as.rec.fs;
    const rn = r.as.rec.n;
    const out: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(ln + rn)) * @sizeOf(dhall.Field))));
    var n: c_int = 0;
    var i: c_int = 0;
    var j: c_int = 0;
    while (i < ln or j < rn) {
        var cmp: c_int = 0;
        if (i >= ln) {
            cmp = 1;
        } else if (j >= rn) {
            cmp = -1;
        } else {
            cmp = cmp_labels(std.mem.span(lfs.?[@intCast(i)].label.?), std.mem.span(rfs.?[@intCast(j)].label.?));
        }
        if (cmp < 0) {
            out[@intCast(n)] = lfs.?[@intCast(i)];
            n += 1;
            i += 1;
        } else if (cmp > 0) {
            out[@intCast(n)] = rfs.?[@intCast(j)];
            n += 1;
            j += 1;
        } else {
            const lt = normalize.normalize(lfs.?[@intCast(i)].type.?);
            const rt = normalize.normalize(rfs.?[@intCast(j)].type.?);
            if (lt.tag == .TmRecordType and rt.tag == .TmRecordType) {
                out[@intCast(n)].label = lfs.?[@intCast(i)].label;
                out[@intCast(n)].type = merge_record_types(lt, rt, loc, err) orelse return null;
                out[@intCast(n)].value = null;
            } else {
                err_here(err, .ERR_TYPE, loc, "shared field '{s}' is not a record type", .{std.mem.span(lfs.?[@intCast(i)].label.?)});
                return null;
            }
            n += 1;
            i += 1;
            j += 1;
        }
    }
    return ast.tm_record_type(out, n);
}

// right-biased (non-recursive) merge of two record TYPES for the // operator:
// a shared label takes the right-hand type, with no recursion and no error.
fn prefer_record_types(l: *dhall.Term, r: *dhall.Term) *dhall.Term {
    const lfs = l.as.rec.fs;
    const ln = l.as.rec.n;
    const rfs = r.as.rec.fs;
    const rn = r.as.rec.n;
    const out: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(ln + rn)) * @sizeOf(dhall.Field))));
    var n: c_int = 0;
    var i: c_int = 0;
    var j: c_int = 0;
    while (i < ln or j < rn) {
        var cmp: c_int = 0;
        if (i >= ln) {
            cmp = 1;
        } else if (j >= rn) {
            cmp = -1;
        } else {
            cmp = cmp_labels(std.mem.span(lfs.?[@intCast(i)].label.?), std.mem.span(rfs.?[@intCast(j)].label.?));
        }
        if (cmp < 0) {
            out[@intCast(n)] = lfs.?[@intCast(i)];
            n += 1;
            i += 1;
        } else if (cmp > 0) {
            out[@intCast(n)] = rfs.?[@intCast(j)];
            n += 1;
            j += 1;
        } else {
            out[@intCast(n)] = rfs.?[@intCast(j)];
            n += 1;
            j += 1;
            i += 1;
        }
    }
    return ast.tm_record_type(out, n);
}

// insert field k : vty into a record TYPE, keeping labels sorted
fn insert_field_type(rty: *dhall.Term, k: []const u8, vty: *dhall.Term) *dhall.Term {
    const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(rty.as.rec.n + 1)) * @sizeOf(dhall.Field))));
    var out: c_int = 0;
    var inserted = false;
    var j: c_int = 0;
    while (j < rty.as.rec.n) : (j += 1) {
        if (!inserted and cmp_labels(std.mem.span(rty.as.rec.fs.?[@intCast(j)].label.?), k) > 0) {
            fs[@intCast(out)].label = arena.arena_strdup(arena.dhall_arena.?, k);
            fs[@intCast(out)].type = vty;
            fs[@intCast(out)].value = null;
            out += 1;
            inserted = true;
        }
        fs[@intCast(out)] = rty.as.rec.fs.?[@intCast(j)];
        out += 1;
    }
    if (!inserted) {
        fs[@intCast(out)].label = arena.arena_strdup(arena.dhall_arena.?, k);
        fs[@intCast(out)].type = vty;
        fs[@intCast(out)].value = null;
        out += 1;
    }
    return ast.tm_record_type(fs, out);
}

// mirror of normalize's with_update_lit, but over record TYPES: compute the
// type of `rec with path = v` given rec's type rty and v's type vty.
fn with_type_at(rty: *dhall.Term, path: []?[*:0]u8, vty: *dhall.Term, loc: *dhall.Term, err: *dhall.DhallError) ?*dhall.Term {
    if (path.len == 0) return vty;
    const k = std.mem.span(path[0].?);
    const i = field_find(rty.as.rec.fs, rty.as.rec.n, k);
    if (i >= 0) {
        if (path.len == 1) {
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(rty.as.rec.n)) * @sizeOf(dhall.Field))));
            const src = rty.as.rec.fs.?;
            @memcpy(fs[0..@intCast(rty.as.rec.n)], src[0..@intCast(rty.as.rec.n)]);
            fs[@intCast(i)].type = vty;
            return ast.tm_record_type(fs, rty.as.rec.n);
        }
        const ft = normalize.normalize(rty.as.rec.fs.?[@intCast(i)].type.?);
        if (ft.tag != .TmRecordType) {
            err_here(err, .ERR_TYPE, loc, "cannot descend into non-record field '{s}'", .{k});
            return null;
        }
        const sub = with_type_at(ft, path[1..], vty, loc, err) orelse return null;
        const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(rty.as.rec.n)) * @sizeOf(dhall.Field))));
        const src = rty.as.rec.fs.?;
        @memcpy(fs[0..@intCast(rty.as.rec.n)], src[0..@intCast(rty.as.rec.n)]);
        fs[@intCast(i)].type = sub;
        return ast.tm_record_type(fs, rty.as.rec.n);
    }
    if (path.len == 1) return insert_field_type(rty, k, vty);
    const sub = with_type_at(ast.tm_record_type(null, 0), path[1..], vty, loc, err) orelse return null;
    return insert_field_type(rty, k, sub);
}

fn infer(g: *Ctx, t: *dhall.Term, err: *dhall.DhallError) ?*dhall.Term {
    switch (t.tag) {
        .TmVar => {
            const ty = g.lookup(t.as.idx) orelse {
                err_here(err, .ERR_TYPE, t, "unbound variable '{s}'", .{std.mem.span(g.name(t.as.idx))});
                return null;
            };
            return resolve_type(g, ty, 0);
        },
        .TmConst => switch (t.as.c.kind) {
            .C_NAT => return ast.tm_builtin("Natural"),
            .C_INT => return ast.tm_builtin("Integer"),
            .C_DBL => return ast.tm_builtin("Double"),
            .C_BOOL => return ast.tm_builtin("Bool"),
        },
        .TmText => {
            // check interpolation subterms are Text
            var p = t.as.text;
            while (p) |pp| {
                if (pp.expr) |e| {
                    if (!check(g, e, ast.tm_builtin("Text"), err)) {
                        err_here(err, .ERR_TYPE, e, "interpolation requires Text", .{});
                        return null;
                    }
                }
                p = pp.next;
            }
            return ast.tm_builtin("Text");
        },
        .TmType => return ast.tm_kind(),
        .TmKind => return ast.tm_sort(),
        .TmSort => return ast.tm_sort(),
        .TmBuiltin => {
            const n = std.mem.span(t.as.bname.?);
            const schema = builtins.builtin_type_schema(n);
            if (schema == null) {
                err_here(err, .ERR_TYPE, t, "unknown builtin: {s}", .{n});
                return null;
            }
            return schema;
        },
        .TmPi => {
            const d = infer(g, t.as.pi.dom.?, err) orelse return null;
            if (!is_type_position(normalize.normalize(d))) {
                err_here(err, .ERR_TYPE, t, "Pi domain is not a type/sort", .{});
                return null;
            }
            g.push(t.as.pi.dom.?, "_", null);
            const c = infer(g, t.as.pi.cod.?, err);
            g.pop();
            if (c == null) return null;
            if (!is_type_position(normalize.normalize(c.?))) {
                err_here(err, .ERR_TYPE, t, "Pi codomain is not a type/sort", .{});
                return null;
            }
            return c;
        },
        .TmApp => {
            const f = infer(g, t.as.app.fn_.?, err) orelse return null;
            const fn_t = normalize.normalize(f);
            if (fn_t.tag != .TmPi) {
                err_here(err, .ERR_TYPE, t, "application of a non-function", .{});
                return null;
            }
            if (!check(g, t.as.app.arg.?, fn_t.as.pi.dom.?, err)) return null;
            return normalize.normalize(ast.subst(0, t.as.app.arg.?, fn_t.as.pi.cod.?));
        },
        .TmIf => {
            if (!check(g, t.as.if_.c.?, ast.tm_builtin("Bool"), err)) return null;
            const ty = infer(g, t.as.if_.t.?, err) orelse return null;
            if (!check(g, t.as.if_.e.?, ty, err)) return null;
            return ty;
        },
        .TmLet => {
            var valTy = t.as.let_.ann;
            if (valTy) |vt| {
                if (!check(g, t.as.let_.val.?, vt, err)) return null;
            } else {
                const vt = infer(g, t.as.let_.val.?, err) orelse return null;
                valTy = vt;
            }
            g.push(valTy.?, "x", t.as.let_.val);
            const r = infer(g, t.as.let_.body.?, err);
            g.pop();
            return r;
        },
        .TmAnn => {
            const tty = infer(g, t.as.ann.ty.?, err) orelse return null;
            if (!is_type_position(normalize.normalize(tty))) {
                err_here(err, .ERR_TYPE, t, "annotation is not a type", .{});
                return null;
            }
            if (!check(g, t.as.ann.e.?, t.as.ann.ty.?, err)) return null;
            return resolve_type(g, t.as.ann.ty.?, 0);
        },
        .TmLam => {
            // only inferable when a domain annotation is present
            if (t.as.lam.dom == null) {
                err_here(err, .ERR_TYPE, t, "cannot infer type of lambda (needs annotation)", .{});
                return null;
            }
            g.push(t.as.lam.dom.?, "_", null);
            const cod = infer(g, t.as.lam.body.?, err);
            g.pop();
            if (cod == null) return null;
            return ast.tm_pi(t.as.lam.dom.?, cod);
        },
        .TmNil => {
            err_here(err, .ERR_TYPE, t, "cannot infer type of empty list (needs annotation)", .{});
            return null;
        },
        .TmCons => {
            // infer the element type from the head, then propagate List headTy
            // down the tail (bidirectional list typing; [] cannot infer on its own)
            const hty = infer(g, t.as.cons.head.?, err) orelse return null;
            const listTy = ast.tm_app(ast.tm_builtin("List"), hty);
            if (!check(g, t.as.cons.tail.?, listTy, err)) return null;
            return listTy;
        },
        .TmTextAppend => {
            if (!check(g, t.as.append.a.?, ast.tm_builtin("Text"), err)) return null;
            if (!check(g, t.as.append.b.?, ast.tm_builtin("Text"), err)) return null;
            return ast.tm_builtin("Text");
        },
        .TmRecordType => {
            var i: c_int = 0;
            while (i < t.as.rec.n) : (i += 1) {
                const fi = &t.as.rec.fs.?[@intCast(i)];
                if (fi.type == null) continue;
                const ty = infer(g, fi.type.?, err) orelse return null;
                if (!is_type_position(normalize.normalize(ty))) {
                    err_here(err, .ERR_TYPE, t, "record field type is not a type", .{});
                    return null;
                }
            }
            return ast.tm_type();
        },
        .TmRecordLit => {
            const n = t.as.rec.n;
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const src = &t.as.rec.fs.?[@intCast(i)];
                const vty = infer(g, src.value.?, err) orelse return null;
                fs[@intCast(i)].label = src.label;
                fs[@intCast(i)].type = vty;
                fs[@intCast(i)].value = null;
            }
            return ast.tm_record_type(fs, n);
        },
        .TmField => {
            const rty = infer(g, t.as.field.rec.?, err) orelse return null;
            const nt = normalize.normalize(rty);
            if (nt.tag != .TmRecordType) {
                err_here(err, .ERR_TYPE, t, "field access on a non-record", .{});
                return null;
            }
            const i = field_find(nt.as.rec.fs, nt.as.rec.n, std.mem.span(t.as.field.label.?));
            if (i < 0 or nt.as.rec.fs.?[@intCast(i)].type == null) {
                err_here(err, .ERR_TYPE, t, "no such field: {s}", .{std.mem.span(t.as.field.label.?)});
                return null;
            }
            return nt.as.rec.fs.?[@intCast(i)].type;
        },
        .TmUnionType => {
            var i: c_int = 0;
            while (i < t.as.uni.n) : (i += 1) {
                const fi = &t.as.uni.fs.?[@intCast(i)];
                if (fi.type == null) continue;
                const ty = infer(g, fi.type.?, err) orelse return null;
                if (!is_type_position(normalize.normalize(ty))) {
                    err_here(err, .ERR_TYPE, t, "union alternative type is not a type", .{});
                    return null;
                }
            }
            return ast.tm_type();
        },
        .TmUnionLit => {
            const n = t.as.uni.n;
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const src = &t.as.uni.fs.?[@intCast(i)];
                fs[@intCast(i)].label = src.label;
                fs[@intCast(i)].type = null;
                fs[@intCast(i)].value = null;
                if (src.value) |v| {
                    const vty = infer(g, v, err) orelse return null;
                    fs[@intCast(i)].type = vty;
                } else if (src.type) |st| {
                    fs[@intCast(i)].type = st;
                } else {
                    err_here(err, .ERR_TYPE, t, "union literal alternative has no type", .{});
                    return null;
                }
            }
            return ast.tm_union_type(fs, n);
        },
        .TmMerge => {
            const uty = infer(g, t.as.merge.u.?, err) orelse return null;
            const nut = normalize.normalize(uty);
            if (nut.tag != .TmUnionType) {
                err_here(err, .ERR_TYPE, t, "merge second argument is not a union", .{});
                return null;
            }

            const hty = infer(g, t.as.merge.handlers.?, err) orelse return null;
            const nht = normalize.normalize(hty);
            if (nht.tag != .TmRecordType) {
                err_here(err, .ERR_TYPE, t, "merge handlers are not a record", .{});
                return null;
            }

            if (!fields_label_sets_equal(nut.as.uni.fs, nut.as.uni.n, nht.as.rec.fs, nht.as.rec.n)) {
                err_here(err, .ERR_TYPE, t, "merge handler and union labels do not match", .{});
                return null;
            }

            var result: ?*dhall.Term = null;
            var i: c_int = 0;
            while (i < nut.as.uni.n) : (i += 1) {
                const label = std.mem.span(nut.as.uni.fs.?[@intCast(i)].label.?);
                const altTy = nut.as.uni.fs.?[@intCast(i)].type;
                const hTy = normalize.normalize(nht.as.rec.fs.?[@intCast(i)].type.?);
                if (hTy.tag != .TmPi) {
                    err_here(err, .ERR_TYPE, t, "merge handler '{s}' is not a function", .{label});
                    return null;
                }
                if (!ast.alpha_eq(normalize.normalize(hTy.as.pi.dom.?), normalize.normalize(altTy.?))) {
                    err_here(err, .ERR_TYPE, t, "merge handler '{s}' domain does not match alternative type", .{label});
                    return null;
                }
                const cod = normalize.normalize(hTy.as.pi.cod.?);
                if (result == null) {
                    result = cod;
                } else if (!ast.alpha_eq(result.?, cod)) {
                    err_here(err, .ERR_TYPE, t, "merge handlers do not have a common result type (handler '{s}')", .{label});
                    return null;
                }
            }
            if (result == null) {
                err_here(err, .ERR_TYPE, t, "merge of an empty union", .{});
                return null;
            }
            return result;
        },
        .TmSome => {
            const vty = infer(g, t.as.some.val.?, err) orelse return null;
            return ast.tm_app(ast.tm_builtin("Optional"), vty);
        },
        .TmNone => {
            const tty = infer(g, t.as.none.ty.?, err) orelse return null;
            if (!is_type_position(normalize.normalize(tty))) {
                err_here(err, .ERR_TYPE, t, "None type argument is not a Type", .{});
                return null;
            }
            return ast.tm_app(ast.tm_builtin("Optional"), t.as.none.ty.?);
        },
        .TmOp => return infer_binop(g, t, err),
        .TmAssert => {
            const bty = infer(g, t.as.assert_.body.?, err) orelse return null;
            if (!ast.alpha_eq(normalize.normalize(bty), normalize.normalize(ast.tm_builtin("Bool")))) {
                err_here(err, .ERR_TYPE, t, "assert is not a Bool", .{});
                return null;
            }
            const b = normalize.normalize(t.as.assert_.body.?);
            if (!(b.tag == .TmConst and b.as.c.kind == .C_BOOL and b.as.c.b)) {
                err_here(err, .ERR_TYPE, t, "assertion did not hold", .{});
                return null;
            }
            return ast.tm_builtin("Bool");
        },
        .TmToMap => {
            const rty = infer(g, t.as.tomap.rec.?, err) orelse return null;
            const nrt = normalize.normalize(rty);
            if (nrt.tag != .TmRecordType) {
                err_here(err, .ERR_TYPE, t, "toMap argument is not a record", .{});
                return null;
            }
            const n = nrt.as.rec.n;
            if (n == 0) {
                err_here(err, .ERR_TYPE, t, "toMap of an empty record", .{});
                return null;
            }
            const T0 = normalize.normalize(nrt.as.rec.fs.?[0].type.?);
            var i: c_int = 1;
            while (i < n) : (i += 1) {
                if (!ast.alpha_eq(T0, normalize.normalize(nrt.as.rec.fs.?[@intCast(i)].type.?))) {
                    err_here(err, .ERR_TYPE, t, "toMap requires all record fields to have the same type", .{});
                    return null;
                }
            }
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, 2 * @sizeOf(dhall.Field))));
            fs[0].label = arena.arena_strdup(arena.dhall_arena.?, "mapKey");
            fs[0].type = ast.tm_builtin("Text");
            fs[0].value = null;
            fs[1].label = arena.arena_strdup(arena.dhall_arena.?, "mapValue");
            fs[1].type = T0;
            fs[1].value = null;
            const recTy = ast.tm_record_type(fs, 2);
            return ast.tm_app(ast.tm_builtin("List"), recTy);
        },
        .TmCombine => {
            const nl = normalize.normalize(t.as.combine.lhs.?);
            const nr = normalize.normalize(t.as.combine.rhs.?);
            if (nl.tag == .TmRecordType and nr.tag == .TmRecordType) {
                // type-level merge: both operands are record types
                if (merge_record_types(nl, nr, t, err) == null) return null;
                return ast.tm_type();
            }
            const lty = infer(g, t.as.combine.lhs.?, err) orelse return null;
            const rty = infer(g, t.as.combine.rhs.?, err) orelse return null;
            const nlt = normalize.normalize(lty);
            const nrt = normalize.normalize(rty);
            if (nlt.tag != .TmRecordType or nrt.tag != .TmRecordType) {
                err_here(err, .ERR_TYPE, t, "record merge operand is not a record", .{});
                return null;
            }
            return merge_record_types(nlt, nrt, t, err);
        },
        .TmListAppend => {
            const aty = infer(g, t.as.lappend.a.?, err) orelse return null;
            const bty = infer(g, t.as.lappend.b.?, err) orelse return null;
            const nat = normalize.normalize(aty);
            const nbt = normalize.normalize(bty);
            if (!is_list_type(nat) or !is_list_type(nbt)) {
                err_here(err, .ERR_TYPE, t, "list append operand is not a List", .{});
                return null;
            }
            if (!ast.alpha_eq(normalize.normalize(nat.as.app.arg.?), normalize.normalize(nbt.as.app.arg.?))) {
                err_here(err, .ERR_TYPE, t, "list append operands have different element types", .{});
                return null;
            }
            return nat;
        },
        .TmPrefer => {
            const nl = normalize.normalize(t.as.prefer.lhs.?);
            const nr = normalize.normalize(t.as.prefer.rhs.?);
            if (nl.tag == .TmRecordType and nr.tag == .TmRecordType) {
                // type-level prefer: both operands are record types
                _ = prefer_record_types(nl, nr); // never errors; result discarded
                return ast.tm_type();
            }
            const lty = infer(g, t.as.prefer.lhs.?, err) orelse return null;
            const rty = infer(g, t.as.prefer.rhs.?, err) orelse return null;
            const nlt = normalize.normalize(lty);
            const nrt = normalize.normalize(rty);
            if (nlt.tag != .TmRecordType or nrt.tag != .TmRecordType) {
                err_here(err, .ERR_TYPE, t, "record prefer operand is not a record", .{});
                return null;
            }
            return prefer_record_types(nlt, nrt);
        },
        .TmWith => {
            const rty = infer(g, t.as.with_.rec.?, err) orelse return null;
            const nr = normalize.normalize(rty);
            if (nr.tag != .TmRecordType) {
                err_here(err, .ERR_TYPE, t, "with target is not a record", .{});
                return null;
            }
            const vty = infer(g, t.as.with_.value.?, err) orelse return null;
            const path = t.as.with_.path.?[0..@intCast(t.as.with_.npath)];
            return with_type_at(nr, path, vty, t, err);
        },
    }
}

fn resolve_type(g: *Ctx, ty: *dhall.Term, depth: c_int) *dhall.Term {
    switch (ty.tag) {
        .TmVar => {
            const idx = ty.as.idx;
            if (idx >= depth) {
                const pos = @as(c_int, @intCast(g.vals.items.len)) - 1 - (idx - depth);
                if (pos >= 0 and pos < g.vals.items.len) {
                    if (g.vals.items[@intCast(pos)]) |v| {
                        return resolve_type(g, ast.shift(idx - depth + 1, 0, v), 0);
                    }
                }
            }
            return ty;
        },
        .TmLam => return ast.tm_lam(resolve_type(g, ty.as.lam.dom.?, depth), resolve_type(g, ty.as.lam.body.?, depth + 1)),
        .TmPi => return ast.tm_pi(resolve_type(g, ty.as.pi.dom.?, depth), resolve_type(g, ty.as.pi.cod.?, depth + 1)),
        .TmApp => return ast.tm_app(resolve_type(g, ty.as.app.fn_.?, depth), resolve_type(g, ty.as.app.arg.?, depth)),
        .TmRecordType => {
            const n = ty.as.rec.n;
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const src = &ty.as.rec.fs.?[@intCast(i)];
                fs[@intCast(i)].label = src.label;
                fs[@intCast(i)].type = if (src.type) |st| resolve_type(g, st, depth) else null;
                fs[@intCast(i)].value = null;
            }
            return ast.tm_record_type(fs, n);
        },
        .TmUnionType => {
            const n = ty.as.uni.n;
            const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @as(usize, @intCast(n)) * @sizeOf(dhall.Field))));
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const src = &ty.as.uni.fs.?[@intCast(i)];
                fs[@intCast(i)].label = src.label;
                fs[@intCast(i)].type = if (src.type) |st| resolve_type(g, st, depth) else null;
                fs[@intCast(i)].value = null;
            }
            return ast.tm_union_type(fs, n);
        },
        else => return ty,
    }
}

fn check(g: *Ctx, t: *dhall.Term, ty: *dhall.Term, err: *dhall.DhallError) bool {
    const nty = normalize.normalize(resolve_type(g, ty, 0));
    if (t.tag == .TmLam and nty.tag == .TmPi) {
        if (!ast.alpha_eq(normalize.normalize(resolve_type(g, t.as.lam.dom.?, 0)), normalize.normalize(nty.as.pi.dom.?))) {
            err_here(err, .ERR_TYPE, t, "lambda domain annotation mismatch", .{});
            return false;
        }
        g.push(nty.as.pi.dom.?, "_", null);
        const ok = check(g, t.as.lam.body.?, nty.as.pi.cod.?, err);
        g.pop();
        return ok;
    }
    if (t.tag == .TmNil and nty.tag == .TmApp and is_list_type(nty))
        return true;
    if (t.tag == .TmCons and is_list_type(nty))
        return check(g, t.as.cons.head.?, nty.as.app.arg.?, err) and check(g, t.as.cons.tail.?, nty, err);
    if (t.tag == .TmSome and is_optional_type(nty))
        return check(g, t.as.some.val.?, nty.as.app.arg.?, err);
    if (t.tag == .TmNone and is_optional_type(nty)) {
        if (!ast.alpha_eq(normalize.normalize(resolve_type(g, t.as.none.ty.?, 0)), normalize.normalize(nty.as.app.arg.?))) {
            err_here(err, .ERR_TYPE, t, "None type argument mismatch", .{});
            return false;
        }
        const tty = infer(g, t.as.none.ty.?, err) orelse return false;
        if (!is_type_position(normalize.normalize(tty))) {
            err_here(err, .ERR_TYPE, t, "None type argument is not a Type", .{});
            return false;
        }
        return true;
    }
    if (t.tag == .TmRecordLit and nty.tag == .TmRecordType) {
        if (!fields_label_sets_equal(t.as.rec.fs, t.as.rec.n, nty.as.rec.fs, nty.as.rec.n)) {
            err_here(err, .ERR_TYPE, t, "record literal labels do not match record type", .{});
            return false;
        }
        var i: c_int = 0;
        while (i < t.as.rec.n) : (i += 1) {
            if (!check(g, t.as.rec.fs.?[@intCast(i)].value.?, nty.as.rec.fs.?[@intCast(i)].type.?, err))
                return false;
        }
        return true;
    }
    if (t.tag == .TmUnionLit and nty.tag == .TmUnionType) {
        var i: c_int = 0;
        while (i < t.as.uni.n) : (i += 1) {
            const label = std.mem.span(t.as.uni.fs.?[@intCast(i)].label.?);
            var j: c_int = -1;
            var k: c_int = 0;
            while (k < nty.as.uni.n) : (k += 1) {
                if (std.mem.eql(u8, std.mem.span(nty.as.uni.fs.?[@intCast(k)].label.?), label)) {
                    j = k;
                    break;
                }
            }
            if (j < 0) {
                err_here(err, .ERR_TYPE, t, "union literal alternative '{s}' is not in the union type", .{label});
                return false;
            }
            const declTy = nty.as.uni.fs.?[@intCast(j)].type;
            const val = t.as.uni.fs.?[@intCast(i)].value;
            if (val) |v| {
                if (declTy == null) {
                    err_here(err, .ERR_TYPE, t, "union alternative '{s}' carries no value (no declared type)", .{label});
                    return false;
                }
                if (!check(g, v, declTy.?, err)) return false;
            }
        }
        return true;
    }
    if (t.tag == .TmText and nty.tag == .TmBuiltin and std.mem.eql(u8, std.mem.span(nty.as.bname.?), "Text")) {
        var p = t.as.text;
        while (p) |pp| {
            if (pp.expr) |e| {
                if (!check(g, e, ast.tm_builtin("Text"), err)) {
                    err_here(err, .ERR_TYPE, e, "interpolation requires Text", .{});
                    return false;
                }
            }
            p = pp.next;
        }
        return true;
    }
    if (t.tag == .TmToMap) {
        // toMap of an EMPTY record: the element type V is unknowable under
        // infer (no fields to read it from), so take V from the annotation.
        // Succeeds iff the record normalizes to an empty record literal AND
        // the target is List { mapKey : Text, mapValue : V } for some V.
        // Any other case falls through to infer (non-empty records, or a
        // mismatched/malformed target).
        const nr = normalize.normalize(t.as.tomap.rec.?);
        if (nr.tag == .TmRecordLit and nr.as.rec.n == 0 and is_list_type(nty)) {
            const elem = normalize.normalize(nty.as.app.arg.?);
            if (elem.tag == .TmRecordType and elem.as.rec.n == 2 and
                elem.as.rec.fs.?[0].type != null and elem.as.rec.fs.?[1].type != null and
                std.mem.eql(u8, std.mem.span(elem.as.rec.fs.?[0].label.?), "mapKey") and
                std.mem.eql(u8, std.mem.span(elem.as.rec.fs.?[1].label.?), "mapValue") and
                ast.alpha_eq(normalize.normalize(elem.as.rec.fs.?[0].type.?), normalize.normalize(ast.tm_builtin("Text"))))
                return true;
        }
    }
    const got = infer(g, t, err) orelse return false;
    const ngot = normalize.normalize(got);
    if (!ast.alpha_eq(ngot, nty)) {
        err_here(err, .ERR_TYPE, t, "type mismatch", .{});
        return false;
    }
    return true;
}

pub fn infer_type(p: *dhall.Parser, t: *dhall.Term, err: *dhall.DhallError) ?*dhall.Term {
    _ = p;
    normalize.normalize_clear_error();
    var g = Ctx.init();
    defer g.deinit();
    const r = infer(&g, t, err);
    if (normalize.normalize_has_error()) {
        err.* = normalize.normalize_get_error().*;
        return null;
    }
    return r;
}
