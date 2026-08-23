// parser.zig — port of ../src/parser.c, verbatim in behavior. Recursive-descent
// parser for the Dhall subset. Resolves names to de Bruijn indices at parse time.
// Records/union fields are sorted by label and made duplicate-free. Handles
// string interpolation via raw-char reading with recursive expression parsing.
// Imports are inlined at parse time (no TmImport tag survives); the loader lives
// in Parser.loader. Precedence and span-stamping (tloc) mirror parser.c exactly.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const lexer = @import("lexer.zig");
const builtins = @import("builtins.zig");
const ast = @import("ast.zig");
const import_mod = @import("import.zig");

const alloc = std.heap.c_allocator;

fn oom() noreturn {
    @panic("dhall: out of memory");
}

// ---------------- token helpers (parser.c:17-23) ----------------

fn peek(p: *dhall.Parser) dhall.Token {
    return lexer.lexer_peek(&p.lx);
}
fn next(p: *dhall.Parser) dhall.Token {
    return lexer.lexer_next(&p.lx);
}
fn at(p: *dhall.Parser, t: dhall.TokType) bool {
    return peek(p).type == t;
}
fn at_name(p: *dhall.Parser, s: []const u8) bool {
    const t = peek(p);
    if (t.type != .T_NAME) return false;
    const n = t.name orelse return false;
    return std.mem.eql(u8, std.mem.span(n), s);
}

fn parser_err(p: *dhall.Parser) bool {
    return p.err.stage != .ERR_NONE or p.lx.err.stage != .ERR_NONE;
}

fn no_span() dhall.SourceSpan {
    return dhall.SPAN_NONE;
}

// stamp a constructed term's source location (parser.c:30-33)
fn tloc(t: *dhall.Term, sp: dhall.SourceSpan) *dhall.Term {
    t.loc = sp;
    return t;
}

fn perr(p: *dhall.Parser, sp: dhall.SourceSpan, msg: []const u8) void {
    if (parser_err(p)) return;
    @memcpy(p.err.msg[0..msg.len], msg);
    p.err.msg[msg.len] = 0;
    p.err.stage = .ERR_PARSE;
    p.err.span = sp;
    p.err.has_span = sp.line > 0;
}

fn perrfmt(p: *dhall.Parser, sp: dhall.SourceSpan, comptime fmt: []const u8, args: anytype) void {
    if (parser_err(p)) return;
    var m: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&m, fmt, args) catch unreachable;
    perr(p, sp, s);
}

fn expect(p: *dhall.Parser, t: dhall.TokType, what: []const u8) bool {
    const tk = peek(p);
    if (tk.type == t) {
        _ = next(p);
        return true;
    }
    if (tk.type == .T_ERROR and p.lx.err.stage == .ERR_LEX) {
        p.err = p.lx.err;
        return false;
    }
    perrfmt(p, tk.span, "expected {s}", .{what});
    return false;
}

// ---------------- name stack (de Bruijn resolution) ----------------

fn push_name(p: *dhall.Parser, name: ?[*:0]const u8) void {
    if (p.nnames == p.namescap) {
        p.namescap = if (p.namescap != 0) p.namescap * 2 else 16;
        const newcap: usize = @intCast(p.namescap);
        if (p.names) |old| {
            const oldlen: usize = @intCast(newcap / 2);
            const newsl = alloc.realloc(old[0..oldlen], newcap) catch oom();
            p.names = newsl.ptr;
        } else {
            const newsl = alloc.alloc(?[*:0]const u8, newcap) catch oom();
            p.names = newsl.ptr;
        }
    }
    p.names.?[@intCast(p.nnames)] = name;
    p.nnames += 1;
}

fn pop_name(p: *dhall.Parser) void {
    if (p.nnames > 0) p.nnames -= 1;
}

fn lookup_name(p: *dhall.Parser, name: []const u8) c_int {
    var i: c_int = p.nnames - 1;
    while (i >= 0) : (i -= 1) {
        const nm = p.names.?[@intCast(i)] orelse continue;
        if (std.mem.eql(u8, std.mem.span(nm), name))
            return (p.nnames - 1) - i;
    }
    return -1;
}

// ---------------- helpers (parser.c:104-127) ----------------

fn is_keyword(s: []const u8) bool {
    return builtins.builtin_is_keyword(s);
}

fn can_start_atom(p: *dhall.Parser) bool {
    const t = peek(p);
    return switch (t.type) {
        .T_NAME => {
            const n = t.name orelse return false;
            return !is_keyword(std.mem.span(n));
        },
        .T_NAT, .T_INT, .T_DBL, .T_STR_OPEN, .T_STR_OPEN_MULTILINE,
        .T_LPAREN, .T_LBRACE, .T_LANGLE, .T_LBRACKET, .T_LAMBDA, .T_IMPORT => true,
        else => false,
    };
}

fn sort_fields(fs: []dhall.Field) void {
    var i: usize = 1;
    while (i < fs.len) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const la = std.mem.span(fs[j].label.?);
            const lb = std.mem.span(fs[j - 1].label.?);
            if (std.mem.lessThan(u8, la, lb)) {
                const tmp = fs[j];
                fs[j] = fs[j - 1];
                fs[j - 1] = tmp;
            } else break;
        }
    }
}

// ---------------- grammar ----------------

fn parse_term(p: *dhall.Parser) ?*dhall.Term {
    if (p.depth >= dhall.PARSE_MAX_DEPTH) {
        perrfmt(p, peek(p).span, "expression nesting too deep (max {d})", .{dhall.PARSE_MAX_DEPTH});
        return null;
    }
    p.depth += 1;
    const r = parse_term_impl(p);
    p.depth -= 1;
    return r;
}

fn parse_term_impl(p: *dhall.Parser) ?*dhall.Term {
    if (at_name(p, "let")) return parse_let(p);
    if (at_name(p, "if")) return parse_if(p);
    if (at_name(p, "assert")) return parse_assert(p);
    if (at(p, .T_LAMBDA)) return parse_lambda(p);
    if (at_name(p, "forall")) return parse_forall(p);
    return parse_arrow(p);
}

fn parse_let(p: *dhall.Parser) ?*dhall.Term {
    const lt = next(p); // let
    const nt = peek(p);
    const nm = nt.name orelse {
        perr(p, nt.span, "expected variable name after let");
        return null;
    };
    if (nt.type != .T_NAME or is_keyword(std.mem.span(nm))) {
        perr(p, nt.span, "expected variable name after let");
        return null;
    }
    _ = next(p);
    var ann: ?*dhall.Term = null;
    if (at(p, .T_COLON)) {
        _ = next(p);
        ann = parse_arrow(p) orelse return null;
    }
    if (!expect(p, .T_EQUALS, "'=' in let binding")) return null;
    const val = parse_term(p) orelse return null;
    if (!at_name(p, "in")) {
        if (!at_name(p, "let")) {
            perr(p, peek(p).span, "expected 'in' or another 'let' binding");
            return null;
        }
        push_name(p, nm);
        const body = parse_term(p);
        pop_name(p);
        if (body == null) return null;
        return tloc(ast.tm_let(ann, val, body), lt.span);
    }
    _ = next(p);
    push_name(p, nm);
    const body = parse_term(p);
    pop_name(p);
    if (body == null) return null;
    return tloc(ast.tm_let(ann, val, body), lt.span);
}

fn parse_if(p: *dhall.Parser) ?*dhall.Term {
    const it = next(p); // if
    const c = parse_term(p) orelse return null;
    if (!at_name(p, "then")) {
        perr(p, peek(p).span, "expected 'then'");
        return null;
    }
    _ = next(p);
    const t = parse_term(p) orelse return null;
    if (!at_name(p, "else")) {
        perr(p, peek(p).span, "expected 'else'");
        return null;
    }
    _ = next(p);
    const e = parse_term(p) orelse return null;
    return tloc(ast.tm_if(c, t, e), it.span);
}

fn parse_assert(p: *dhall.Parser) ?*dhall.Term {
    const at_ = next(p); // assert
    if (!expect(p, .T_COLON, "':' after assert")) return null;
    const body = parse_term(p) orelse return null;
    return tloc(ast.tm_assert(body), at_.span);
}

fn parse_lambda(p: *dhall.Parser) ?*dhall.Term {
    const lt = next(p); // \
    if (!expect(p, .T_LPAREN, "'(' in lambda")) return null;
    const nt = peek(p);
    const nm = nt.name orelse {
        perr(p, nt.span, "expected parameter name in lambda");
        return null;
    };
    if (nt.type != .T_NAME or is_keyword(std.mem.span(nm))) {
        perr(p, nt.span, "expected parameter name in lambda");
        return null;
    }
    _ = next(p);
    if (!expect(p, .T_COLON, "':' in lambda parameter type")) return null;
    const dom = parse_arrow(p) orelse return null;
    if (!expect(p, .T_RPAREN, "')' in lambda")) return null;
    if (!expect(p, .T_ARROW, "'->' in lambda")) return null;
    push_name(p, nm);
    const body = parse_term(p);
    pop_name(p);
    if (body == null) return null;
    return tloc(ast.tm_lam(dom, body), lt.span);
}

fn parse_forall(p: *dhall.Parser) ?*dhall.Term {
    const ft = next(p); // forall
    if (!expect(p, .T_LPAREN, "'(' in forall")) return null;
    const nt = peek(p);
    const nm = nt.name orelse {
        perr(p, nt.span, "expected binder name in forall");
        return null;
    };
    if (nt.type != .T_NAME or is_keyword(std.mem.span(nm))) {
        perr(p, nt.span, "expected binder name in forall");
        return null;
    }
    _ = next(p);
    if (!expect(p, .T_COLON, "':' in forall binder type")) return null;
    const dom = parse_arrow(p) orelse return null;
    if (!expect(p, .T_RPAREN, "')' in forall")) return null;
    if (!expect(p, .T_ARROW, "'->' in forall")) return null;
    push_name(p, nm);
    const cod = parse_term(p);
    pop_name(p);
    if (cod == null) return null;
    return tloc(ast.tm_pi(dom, cod), ft.span);
}

fn parse_arrow(p: *dhall.Parser) ?*dhall.Term {
    const left = parse_annotation(p) orelse return null;
    if (at(p, .T_ARROW)) {
        const ar = next(p);
        push_name(p, "_");
        const right = parse_arrow(p);
        pop_name(p);
        if (right == null) return null;
        return tloc(ast.tm_pi(left, right), ar.span);
    }
    return left;
}

fn parse_annotation(p: *dhall.Parser) ?*dhall.Term {
    const e = parse_with(p) orelse return null;
    if (at(p, .T_COLON)) {
        const cn = next(p);
        const ty = parse_arrow(p) orelse return null;
        return tloc(ast.tm_ann(e, ty), cn.span);
    }
    return e;
}

fn parse_import_alt(p: *dhall.Parser) ?*dhall.Term {
    const outer_missing = p.import_missing;
    p.import_missing = false;
    var left = parse_or(p) orelse return null;
    var missing = p.import_missing;
    while (at(p, .T_QMARK)) {
        _ = next(p); // ?
        if (missing) {
            p.import_missing = false;
            left = parse_or(p) orelse return null;
            missing = p.import_missing;
        } else {
            const save = p.skip_imports;
            p.skip_imports = true;
            const fb = parse_or(p);
            p.skip_imports = save;
            if (fb == null) return null;
            p.import_missing = false;
        }
    }
    p.import_missing = outer_missing or missing;
    return left;
}

fn parse_or(p: *dhall.Parser) ?*dhall.Term {
    if (p.union_depth > 0) return parse_additive(p);
    var left = parse_and(p) orelse return null;
    while (at(p, .T_OR)) {
        const op_tk = next(p);
        const r = parse_and(p) orelse return null;
        left = tloc(ast.tm_op(.OP_OR, left, r), op_tk.span);
    }
    return left;
}

fn parse_and(p: *dhall.Parser) ?*dhall.Term {
    if (p.union_depth > 0) return parse_additive(p);
    var left = parse_comparison(p) orelse return null;
    while (at(p, .T_AND)) {
        const op_tk = next(p);
        const r = parse_comparison(p) orelse return null;
        left = tloc(ast.tm_op(.OP_AND, left, r), op_tk.span);
    }
    return left;
}

fn parse_comparison(p: *dhall.Parser) ?*dhall.Term {
    if (p.union_depth > 0) return parse_additive(p);
    var left = parse_additive(p) orelse return null;
    while (true) {
        const op_tk = peek(p);
        var op: dhall.OpKind = undefined;
        var found = true;
        if (op_tk.type == .T_EQEQ) op = .OP_EQ
        else if (op_tk.type == .T_NE) op = .OP_NE
        else if (op_tk.type == .T_LT) op = .OP_LT
        else if (op_tk.type == .T_LE) op = .OP_LE
        else if (op_tk.type == .T_RANGLE) op = .OP_GT
        else if (op_tk.type == .T_GE) op = .OP_GE
        else found = false;
        if (!found) break;
        _ = next(p);
        const r = parse_additive(p) orelse return null;
        left = tloc(ast.tm_op(op, left, r), op_tk.span);
    }
    return left;
}

fn parse_additive(p: *dhall.Parser) ?*dhall.Term {
    var left = parse_combine(p) orelse return null;
    while (true) {
        const op_tk = peek(p);
        if (op_tk.type == .T_PLUS) {
            _ = next(p);
            const r = parse_combine(p) orelse return null;
            left = tloc(ast.tm_op(.OP_ADD, left, r), op_tk.span);
        } else if (op_tk.type == .T_MINUS) {
            _ = next(p);
            const r = parse_combine(p) orelse return null;
            left = tloc(ast.tm_op(.OP_SUB, left, r), op_tk.span);
        } else if (op_tk.type == .T_PLUSPLUS) {
            _ = next(p);
            const r = parse_combine(p) orelse return null;
            left = tloc(ast.tm_append(left, r), op_tk.span);
        } else if (op_tk.type == .T_HASH) {
            _ = next(p);
            const r = parse_combine(p) orelse return null;
            left = tloc(ast.tm_list_append(left, r), op_tk.span);
        } else break;
    }
    return left;
}

fn parse_combine(p: *dhall.Parser) ?*dhall.Term {
    var left = parse_prefer(p) orelse return null;
    while (at(p, .T_MERGE)) {
        const op_tk = next(p);
        const r = parse_prefer(p) orelse return null;
        left = tloc(ast.tm_combine(left, r), op_tk.span);
    }
    return left;
}

fn parse_prefer(p: *dhall.Parser) ?*dhall.Term {
    var left = parse_multiplicative(p) orelse return null;
    while (at(p, .T_PREFER)) {
        const op_tk = next(p);
        const r = parse_multiplicative(p) orelse return null;
        left = tloc(ast.tm_prefer(left, r), op_tk.span);
    }
    return left;
}

fn parse_multiplicative(p: *dhall.Parser) ?*dhall.Term {
    var left = parse_merge(p) orelse return null;
    while (at(p, .T_STAR)) {
        const op_tk = next(p);
        const r = parse_merge(p) orelse return null;
        left = tloc(ast.tm_op(.OP_MUL, left, r), op_tk.span);
    }
    return left;
}

fn parse_merge(p: *dhall.Parser) ?*dhall.Term {
    if (at_name(p, "merge")) {
        const mt = next(p);
        const h = parse_field(p) orelse return null;
        const u = parse_field(p) orelse return null;
        return tloc(ast.tm_merge(h, u), mt.span);
    }
    return parse_application(p);
}

fn parse_with(p: *dhall.Parser) ?*dhall.Term {
    var e = parse_import_alt(p) orelse return null;
    while (at_name(p, "with")) {
        const wt = next(p); // with
        var cap: usize = 4;
        var n: usize = 0;
        var labels = alloc.alloc(?[*:0]const u8, cap) catch oom();
        const first = peek(p);
        const fnm = first.name orelse {
            perr(p, first.span, "expected field path after 'with'");
            alloc.free(labels);
            return null;
        };
        if (first.type != .T_NAME or is_keyword(std.mem.span(fnm))) {
            perr(p, first.span, "expected field path after 'with'");
            alloc.free(labels);
            return null;
        }
        _ = next(p);
        labels[n] = fnm;
        n += 1;
        while (at(p, .T_DOT)) {
            _ = next(p);
            const lt = peek(p);
            const ln = lt.name orelse {
                perr(p, lt.span, "expected label after '.' in with path");
                alloc.free(labels);
                return null;
            };
            if (lt.type != .T_NAME or is_keyword(std.mem.span(ln))) {
                perr(p, lt.span, "expected label after '.' in with path");
                alloc.free(labels);
                return null;
            }
            _ = next(p);
            if (n == cap) {
                cap *= 2;
                labels = alloc.realloc(labels[0..n], cap) catch oom();
            }
            labels[n] = ln;
            n += 1;
        }
        if (!expect(p, .T_EQUALS, "'=' in with expression")) {
            alloc.free(labels);
            return null;
        }
        const v = parse_import_alt(p) orelse {
            alloc.free(labels);
            return null;
        };
        const path: [*]?[*:0]u8 = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, n * @sizeOf(?[*:0]u8))));
        for (labels[0..n], 0..) |lb, i| path[i] = @ptrCast(@constCast(lb.?));
        alloc.free(labels);
        e = tloc(ast.tm_with(e, path, @intCast(n), v), wt.span);
    }
    return e;
}

fn parse_application(p: *dhall.Parser) ?*dhall.Term {
    var e = parse_field(p) orelse return null;
    while (can_start_atom(p)) {
        const arg = parse_field(p) orelse return null;
        e = tloc(ast.tm_app(e, arg), e.loc);
    }
    return e;
}

fn parse_field(p: *dhall.Parser) ?*dhall.Term {
    var e = parse_atom(p) orelse return null;
    while (at(p, .T_DOT)) {
        const dt = next(p);
        const lt = peek(p);
        const ln = lt.name orelse {
            perr(p, lt.span, "expected label after '.'");
            return null;
        };
        if (lt.type != .T_NAME or is_keyword(std.mem.span(ln))) {
            perr(p, lt.span, "expected label after '.'");
            return null;
        }
        _ = next(p);
        e = tloc(ast.tm_field(std.mem.span(ln), e), dt.span);
    }
    return e;
}

fn parse_atom(p: *dhall.Parser) ?*dhall.Term {
    const t = peek(p);
    switch (t.type) {
        .T_NAT => {
            _ = next(p);
            return tloc(ast.tm_const(t.c), t.span);
        },
        .T_INT => {
            _ = next(p);
            return tloc(ast.tm_const(t.c), t.span);
        },
        .T_DBL => {
            _ = next(p);
            return tloc(ast.tm_dbl(t.c.dbl), t.span);
        },
        .T_STR_OPEN => return parse_text(p),
        .T_STR_OPEN_MULTILINE => return parse_text_multiline(p),
        .T_LAMBDA => return parse_lambda(p),
        .T_IMPORT => {
            if (p.skip_imports) {
                _ = next(p);
                if (at(p, .T_SHA256)) _ = next(p);
                return tloc(ast.tm_var(0), t.span);
            }
            if (p.loader == null) {
                perr(p, t.span, "imports are not available");
                return null;
            }
            _ = next(p);
            var hex: ?[*:0]const u8 = null;
            if (at(p, .T_SHA256)) hex = next(p).name;
            var ie: dhall.DhallError = undefined;
            ast.dhall_error_clear(&ie);
            const r = import_mod.import_resolve(p.loader, t.name, hex, p, &ie);
            if (r == null) {
                if (ie.stage == .ERR_MISSING) {
                    p.import_missing = true;
                    if (p.missing_err.stage == .ERR_NONE) p.missing_err = ie;
                    return tloc(ast.tm_var(0), t.span);
                }
                if (!ie.has_span) {
                    ie.span = t.span;
                    ie.has_span = (t.span.line > 0);
                }
                p.err = ie;
                return null;
            }
            return r;
        },
        .T_LPAREN => {
            _ = next(p);
            const e = parse_term(p) orelse return null;
            if (!expect(p, .T_RPAREN, "')'")) return null;
            return e;
        },
        .T_LBRACE => return parse_record(p),
        .T_LANGLE => return parse_union(p),
        .T_LBRACKET => return parse_list(p),
        .T_NAME => {
            const nm = t.name orelse {
                perr(p, t.span, "unexpected token");
                return null;
            };
            const s = std.mem.span(nm);
            // '_N' (underscore followed only by digits) is a de Bruijn index
            if (s.len >= 2 and s[0] == '_') {
                var all_digits = true;
                var i: usize = 1;
                while (i < s.len) : (i += 1) {
                    if (s[i] < '0' or s[i] > '9') {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) {
                    var v: i64 = 0;
                    var ok = true;
                    i = 1;
                    while (i < s.len) : (i += 1) {
                        const d = s[i] - '0';
                        const lim = @divTrunc(std.math.maxInt(i64) - @as(i64, d), 10);
                        if (v > lim) {
                            ok = false;
                            break;
                        }
                        v = v * 10 + @as(i64, d);
                    }
                    if (!ok or v < 0 or v > std.math.maxInt(c_int)) {
                        perr(p, t.span, "invalid de Bruijn index");
                        return null;
                    }
                    _ = next(p);
                    return tloc(ast.tm_var(@intCast(v)), t.span);
                }
            }
            if (std.mem.eql(u8, s, "True")) {
                _ = next(p);
                return tloc(ast.tm_bool(true), t.span);
            }
            if (std.mem.eql(u8, s, "False")) {
                _ = next(p);
                return tloc(ast.tm_bool(false), t.span);
            }
            if (std.mem.eql(u8, s, "forall")) return parse_forall(p);
            if (std.mem.eql(u8, s, "Type")) {
                _ = next(p);
                return tloc(ast.tm_type(), t.span);
            }
            if (std.mem.eql(u8, s, "Kind")) {
                _ = next(p);
                return tloc(ast.tm_kind(), t.span);
            }
            if (std.mem.eql(u8, s, "Sort")) {
                _ = next(p);
                return tloc(ast.tm_sort(), t.span);
            }
            if (std.mem.eql(u8, s, "Some")) {
                _ = next(p);
                const v = parse_field(p) orelse return null;
                return tloc(ast.tm_some(v), t.span);
            }
            if (std.mem.eql(u8, s, "None")) {
                _ = next(p);
                const ty = parse_field(p) orelse return null;
                return tloc(ast.tm_none(ty), t.span);
            }
            if (std.mem.eql(u8, s, "toMap")) {
                _ = next(p);
                const r = parse_field(p) orelse return null;
                return tloc(ast.tm_tomap(r), t.span);
            }
            if (builtins.builtin_type_schema(s) != null) {
                _ = next(p);
                return tloc(ast.tm_builtin(s), t.span);
            }
            const idx = lookup_name(p, s);
            if (idx >= 0) {
                _ = next(p);
                return tloc(ast.tm_var(idx), t.span);
            }
            perrfmt(p, t.span, "unbound variable '{s}'", .{s});
            return null;
        },
        .T_ERROR => {
            if (p.lx.err.stage == .ERR_LEX) {
                p.err = p.lx.err;
                return null;
            }
        },
        else => {},
    }
    perr(p, t.span, "unexpected token");
    return null;
}

// ---------------- string literal with interpolation ----------------

fn text_add_part(buf: *dhall.TmpBuf, open: *bool, head: *?*dhall.TextPart, tail: *?*dhall.TextPart) void {
    if (open.*) {
        const np: *dhall.TextPart = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.TextPart))));
        np.lit = arena.tmpbuf_arena(arena.dhall_arena.?, buf);
        np.expr = null;
        np.next = null;
        if (tail.*) |tl| tl.next = np else head.* = np;
        tail.* = np;
        open.* = false;
    }
}

fn text_add_expr(expr: *dhall.Term, head: *?*dhall.TextPart, tail: *?*dhall.TextPart) void {
    const np: *dhall.TextPart = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, @sizeOf(dhall.TextPart))));
    np.lit = null;
    np.expr = expr;
    np.next = null;
    if (tail.*) |tl| tl.next = np else head.* = np;
    tail.* = np;
}

fn parse_text(p: *dhall.Parser) ?*dhall.Term {
    const sp = peek(p).span;
    _ = next(p); // consume opening quote
    var buf: dhall.TmpBuf = undefined;
    arena.tmpbuf_init(&buf);
    var open = false;
    var head: ?*dhall.TextPart = null;
    var tail: ?*dhall.TextPart = null;
    while (true) {
        const c = lexer.lexer_peek_char(&p.lx);
        if (c == -1) {
            perr(p, sp, "unterminated string");
            return null;
        }
        if (c == '"') {
            _ = lexer.lexer_read_char(&p.lx);
            break;
        }
        if (c == '$' and p.lx.pos + 1 < p.lx.len and p.lx.src.?[p.lx.pos + 1] == '{') {
            _ = lexer.lexer_read_char(&p.lx); // $
            _ = lexer.lexer_read_char(&p.lx); // {
            text_add_part(&buf, &open, &head, &tail);
            p.lx.after_operand = false;
            const expr = parse_term(p) orelse return null;
            const cl = lexer.lexer_next(&p.lx);
            if (cl.type != .T_RBRACE) {
                perr(p, cl.span, "expected '}' to close interpolation");
                return null;
            }
            text_add_expr(expr, &head, &tail);
            continue;
        }
        if (c == '\\') {
            _ = lexer.lexer_read_char(&p.lx);
            const e = lexer.lexer_read_char(&p.lx);
            switch (e) {
                'n' => arena.tmpbuf_addc(&buf, '\n'),
                't' => arena.tmpbuf_addc(&buf, '\t'),
                'r' => arena.tmpbuf_addc(&buf, '\r'),
                'b' => arena.tmpbuf_addc(&buf, 0x08),
                'f' => arena.tmpbuf_addc(&buf, 0x0c),
                '"' => arena.tmpbuf_addc(&buf, '"'),
                '\\' => arena.tmpbuf_addc(&buf, '\\'),
                '$' => arena.tmpbuf_addc(&buf, '$'),
                else => if (e != -1) arena.tmpbuf_addc(&buf, @intCast(e)),
            }
            open = true;
            continue;
        }
        _ = lexer.lexer_read_char(&p.lx);
        arena.tmpbuf_addc(&buf, @intCast(c));
        open = true;
    }
    text_add_part(&buf, &open, &head, &tail);
    if (head == null) return tloc(ast.tm_text_lit(""), sp);
    return tloc(ast.tm_text(head), sp);
}

// ---------------- multiline string literal ('' ... '') ----------------

const MLine = struct {
    pfx: ?[*:0]const u8, // leading space/tab prefix (points into arena literals)
    plen: c_int, // length of that prefix
    blank: bool, // line has zero chars and no interpolation
};

fn mline_push(lines: *?[*]MLine, n: *c_int, cap: *c_int, pfx: ?[*:0]const u8, plen: c_int, blank: bool) void {
    if (n.* == cap.*) {
        cap.* = if (cap.* != 0) cap.* * 2 else 16;
        if (lines.*) |old| {
            const oldlen: usize = @intCast(n.*);
            const newsl = alloc.realloc(old[0..oldlen], @intCast(cap.*)) catch oom();
            lines.* = newsl.ptr;
        } else {
            const newsl = alloc.alloc(MLine, @intCast(cap.*)) catch oom();
            lines.* = newsl.ptr;
        }
    }
    lines.*.?[@intCast(n.*)] = .{ .pfx = pfx, .plen = plen, .blank = blank };
    n.* += 1;
}

fn multiline_indent_len(head: ?*dhall.TextPart) c_int {
    var lines: ?[*]MLine = null;
    var n: c_int = 0;
    var cap: c_int = 0;
    var line_blank = true;
    var indent_done = false;
    var line_pfx: ?[*:0]const u8 = null;
    var line_plen: c_int = 0;
    var p = head;
    while (p) |pp| {
        if (pp.expr != null) {
            if (!indent_done) indent_done = true;
            line_blank = false;
        } else {
            const s = pp.lit.?;
            var i: usize = 0;
            while (s[i] != 0) : (i += 1) {
                const c = s[i];
                if (c == '\n') {
                    mline_push(&lines, &n, &cap, line_pfx, line_plen, line_blank);
                    line_blank = true;
                    indent_done = false;
                    line_pfx = null;
                    line_plen = 0;
                } else {
                    line_blank = false;
                    if (!indent_done) {
                        if (c == ' ' or c == '\t') {
                            if (line_pfx == null) line_pfx = @ptrCast(s + i);
                            line_plen += 1;
                        } else {
                            indent_done = true;
                        }
                    }
                }
            }
        }
        p = pp.next;
    }
    mline_push(&lines, &n, &cap, line_pfx, line_plen, line_blank);
    var common: ?[*:0]const u8 = null;
    var common_len: c_int = 0;
    var have = false;
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const li = lines.?[@intCast(i)];
        if (li.blank and i != n - 1) continue;
        if (!have) {
            common = li.pfx;
            common_len = li.plen;
            have = true;
        } else {
            const m = if (common_len < li.plen) common_len else li.plen;
            var j: c_int = 0;
            while (j < m and common.?[@intCast(j)] == li.pfx.?[@intCast(j)]) j += 1;
            common_len = j;
        }
    }
    const k = if (have) common_len else 0;
    if (lines) |old| alloc.free(old[0..@intCast(n)]);
    return k;
}

fn multiline_strip(head: ?*dhall.TextPart, k: c_int) ?*dhall.TextPart {
    var buf: dhall.TmpBuf = undefined;
    arena.tmpbuf_init(&buf);
    var open = false;
    var out: ?*dhall.TextPart = null;
    var otail: ?*dhall.TextPart = null;
    var remaining = k;
    var p = head;
    while (p) |pp| {
        if (pp.expr != null) {
            text_add_part(&buf, &open, &out, &otail);
            text_add_expr(pp.expr.?, &out, &otail);
        } else {
            const s = pp.lit.?;
            var i: usize = 0;
            while (s[i] != 0) : (i += 1) {
                const c = s[i];
                if (c == '\n') {
                    arena.tmpbuf_addc(&buf, '\n');
                    open = true;
                    remaining = k;
                } else if (remaining > 0) {
                    remaining -= 1;
                } else {
                    arena.tmpbuf_addc(&buf, c);
                    open = true;
                }
            }
        }
        p = pp.next;
    }
    text_add_part(&buf, &open, &out, &otail);
    return out;
}

fn parse_text_multiline(p: *dhall.Parser) ?*dhall.Term {
    const sp = peek(p).span;
    _ = next(p); // consume T_STR_OPEN_MULTILINE
    // Mandatory newline after the opening ''
    {
        const c = lexer.lexer_peek_char(&p.lx);
        if (c == '\n') {
            _ = lexer.lexer_read_char(&p.lx);
        } else if (c == '\r') {
            _ = lexer.lexer_read_char(&p.lx);
            if (lexer.lexer_peek_char(&p.lx) != '\n') {
                perr(p, sp, "multiline string must begin with a newline after ''");
                return null;
            }
            _ = lexer.lexer_read_char(&p.lx);
        } else {
            perr(p, sp, "multiline string must begin with a newline after ''");
            return null;
        }
    }
    var buf: dhall.TmpBuf = undefined;
    arena.tmpbuf_init(&buf);
    var open = false;
    var head: ?*dhall.TextPart = null;
    var tail: ?*dhall.TextPart = null;
    while (true) {
        const c = lexer.lexer_peek_char(&p.lx);
        if (c == -1) {
            perr(p, sp, "unterminated multiline string");
            return null;
        }
        if (c == '\'') {
            const s = p.lx.src.?;
            const pos = p.lx.pos;
            const len = p.lx.len;
            const c1: c_int = if (pos + 1 < len) @intCast(s[pos + 1]) else -1;
            const c2: c_int = if (pos + 2 < len) @intCast(s[pos + 2]) else -1;
            const c3: c_int = if (pos + 3 < len) @intCast(s[pos + 3]) else -1;
            if (c1 == '\'' and c2 == '\'') { // ''' -> literal ''
                _ = lexer.lexer_read_char(&p.lx);
                _ = lexer.lexer_read_char(&p.lx);
                _ = lexer.lexer_read_char(&p.lx);
                arena.tmpbuf_addc(&buf, '\'');
                arena.tmpbuf_addc(&buf, '\'');
                open = true;
                continue;
            }
            if (c1 == '\'' and c2 == '$' and c3 == '{') { // ''${ -> literal ${
                _ = lexer.lexer_read_char(&p.lx);
                _ = lexer.lexer_read_char(&p.lx);
                _ = lexer.lexer_read_char(&p.lx);
                _ = lexer.lexer_read_char(&p.lx);
                arena.tmpbuf_addc(&buf, '$');
                arena.tmpbuf_addc(&buf, '{');
                open = true;
                continue;
            }
            if (c1 == '\'') { // '' -> end of literal
                _ = lexer.lexer_read_char(&p.lx);
                _ = lexer.lexer_read_char(&p.lx);
                break;
            }
            _ = lexer.lexer_read_char(&p.lx); // lone ' is literal
            arena.tmpbuf_addc(&buf, '\'');
            open = true;
            continue;
        }
        if (c == '$' and p.lx.pos + 1 < p.lx.len and p.lx.src.?[p.lx.pos + 1] == '{') {
            _ = lexer.lexer_read_char(&p.lx); // $
            _ = lexer.lexer_read_char(&p.lx); // {
            text_add_part(&buf, &open, &head, &tail);
            p.lx.after_operand = false;
            const expr = parse_term(p) orelse return null;
            const cl = lexer.lexer_next(&p.lx);
            if (cl.type != .T_RBRACE) {
                perr(p, cl.span, "expected '}' to close interpolation");
                return null;
            }
            text_add_expr(expr, &head, &tail);
            continue;
        }
        if (c == '\r') {
            if (p.lx.pos + 1 < p.lx.len and p.lx.src.?[p.lx.pos + 1] == '\n') {
                _ = lexer.lexer_read_char(&p.lx);
                _ = lexer.lexer_read_char(&p.lx);
                arena.tmpbuf_addc(&buf, '\n');
            } else {
                _ = lexer.lexer_read_char(&p.lx);
                arena.tmpbuf_addc(&buf, '\r');
            }
            open = true;
            continue;
        }
        _ = lexer.lexer_read_char(&p.lx);
        arena.tmpbuf_addc(&buf, @intCast(c));
        open = true;
    }
    text_add_part(&buf, &open, &head, &tail);
    if (head == null) return tloc(ast.tm_text_lit(""), sp);
    const k = multiline_indent_len(head);
    head = multiline_strip(head, k);
    if (head == null) return tloc(ast.tm_text_lit(""), sp);
    return tloc(ast.tm_text(head), sp);
}

// ---------------- records ----------------

fn parse_record(p: *dhall.Parser) ?*dhall.Term {
    const sp = peek(p).span;
    _ = next(p); // {
    if (at(p, .T_RBRACE)) {
        _ = next(p);
        return tloc(ast.tm_record_lit(null, 0), sp);
    }
    if (at(p, .T_EQUALS)) { // {=} empty record literal
        _ = next(p);
        if (!expect(p, .T_RBRACE, "'}' to close empty record literal")) return null;
        return tloc(ast.tm_record_lit(null, 0), sp);
    }
    var cap: usize = 4;
    var n: usize = 0;
    var fs = alloc.alloc(dhall.Field, cap) catch oom();
    var first_sep: c_int = 0;
    while (true) {
        const nt = peek(p);
        const nm = nt.name orelse {
            perr(p, nt.span, "expected record field label");
            alloc.free(fs);
            return null;
        };
        if (nt.type != .T_NAME or is_keyword(std.mem.span(nm))) {
            perr(p, nt.span, "expected record field label");
            alloc.free(fs);
            return null;
        }
        _ = next(p);
        const sep = peek(p);
        var this_sep: c_int = 0;
        var ty: ?*dhall.Term = null;
        var val: ?*dhall.Term = null;
        if (sep.type == .T_COLON) {
            this_sep = 1;
            _ = next(p);
            ty = parse_arrow(p) orelse {
                alloc.free(fs);
                return null;
            };
        } else if (sep.type == .T_EQUALS) {
            this_sep = 2;
            _ = next(p);
            val = parse_term(p) orelse {
                alloc.free(fs);
                return null;
            };
        } else {
            perr(p, sep.span, "expected ':' or '=' in record field");
            alloc.free(fs);
            return null;
        }
        if (first_sep == 0) {
            first_sep = this_sep;
        } else if (first_sep != this_sep) {
            perr(p, sep.span, "cannot mix record type and literal fields");
            alloc.free(fs);
            return null;
        }
        if (n == cap) {
            cap *= 2;
            fs = alloc.realloc(fs[0..n], cap) catch oom();
        }
        fs[n] = .{ .label = nm, .type = ty, .value = val };
        n += 1;
        if (at(p, .T_COMMA)) {
            _ = next(p);
            continue;
        }
        break;
    }
    if (!expect(p, .T_RBRACE, "'}' to close record")) {
        alloc.free(fs);
        return null;
    }
    sort_fields(fs[0..n]);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(fs[i].label.?), std.mem.span(fs[i - 1].label.?))) {
            perrfmt(p, no_span(), "duplicate record field '{s}'", .{std.mem.span(fs[i].label.?)});
            alloc.free(fs);
            return null;
        }
    }
    const af: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, n * @sizeOf(dhall.Field))));
    @memcpy(af[0..n], fs[0..n]);
    alloc.free(fs);
    return tloc(if (first_sep == 1) ast.tm_record_type(af, @intCast(n)) else ast.tm_record_lit(af, @intCast(n)), sp);
}

// ---------------- unions ----------------

fn parse_union(p: *dhall.Parser) ?*dhall.Term {
    const sp = peek(p).span;
    _ = next(p); // <
    if (at(p, .T_RANGLE)) {
        _ = next(p);
        return tloc(ast.tm_union_type(null, 0), sp);
    }
    p.union_depth += 1;
    var cap: usize = 4;
    var n: usize = 0;
    var fs = alloc.alloc(dhall.Field, cap) catch oom();
    var is_lit = false;
    blk: {
        while (true) {
            const nt = peek(p);
            const nm = nt.name orelse {
                perr(p, nt.span, "expected union alternative label");
                break :blk;
            };
            if (nt.type != .T_NAME or is_keyword(std.mem.span(nm))) {
                perr(p, nt.span, "expected union alternative label");
                break :blk;
            }
            _ = next(p);
            const sep = peek(p);
            var ty: ?*dhall.Term = null;
            var val: ?*dhall.Term = null;
            if (sep.type == .T_COLON) {
                _ = next(p);
                ty = parse_arrow(p) orelse break :blk;
            } else if (sep.type == .T_EQUALS) {
                is_lit = true;
                _ = next(p);
                val = parse_term(p) orelse break :blk;
            } else {
                perr(p, sep.span, "expected ':' or '=' in union alternative");
                break :blk;
            }
            if (n == cap) {
                cap *= 2;
                fs = alloc.realloc(fs[0..n], cap) catch oom();
            }
            fs[n] = .{ .label = nm, .type = ty, .value = val };
            n += 1;
            if (at(p, .T_BAR)) {
                _ = next(p);
                continue;
            }
            break;
        }
        if (!expect(p, .T_RANGLE, "'>' to close union")) break :blk;
        if (is_lit) {
            var val_count: c_int = 0;
            for (fs[0..n]) |f| {
                if (f.value != null) val_count += 1;
            }
            if (val_count != 1) {
                perr(p, no_span(), "union literal must have exactly one alternative with a value");
                break :blk;
            }
        }
        sort_fields(fs[0..n]);
        var i: usize = 1;
        while (i < n) : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(fs[i].label.?), std.mem.span(fs[i - 1].label.?))) {
                perrfmt(p, no_span(), "duplicate union alternative '{s}'", .{std.mem.span(fs[i].label.?)});
                break :blk;
            }
        }
        const af: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, n * @sizeOf(dhall.Field))));
        @memcpy(af[0..n], fs[0..n]);
        alloc.free(fs);
        p.union_depth -= 1;
        return tloc(if (is_lit) ast.tm_union_lit(af, @intCast(n)) else ast.tm_union_type(af, @intCast(n)), sp);
    }
    alloc.free(fs);
    p.union_depth -= 1;
    return null;
}

// ---------------- lists ----------------

fn parse_list(p: *dhall.Parser) ?*dhall.Term {
    const sp = peek(p).span;
    _ = next(p); // [
    if (at(p, .T_RBRACKET)) {
        _ = next(p);
        return tloc(ast.tm_nil(), sp);
    }
    var cap: usize = 4;
    var n: usize = 0;
    var elems = alloc.alloc(*dhall.Term, cap) catch oom();
    while (true) {
        const e = parse_field(p) orelse {
            alloc.free(elems);
            return null;
        };
        if (n == cap) {
            cap *= 2;
            elems = alloc.realloc(elems[0..n], cap) catch oom();
        }
        elems[n] = e;
        n += 1;
        if (at(p, .T_COMMA)) {
            _ = next(p);
            continue;
        }
        break;
    }
    if (!expect(p, .T_RBRACKET, "']' to close list")) {
        alloc.free(elems);
        return null;
    }
    var out: *dhall.Term = ast.tm_nil();
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        out = tloc(ast.tm_cons(elems[i], out), elems[i].loc);
    }
    alloc.free(elems);
    return tloc(out, sp);
}

// ---------------- entry ----------------

pub fn parse_source(p: *dhall.Parser, src: ?[*:0]const u8, file: ?[*:0]const u8, err: *dhall.DhallError) ?*dhall.Term {
    lexer.lexer_init(&p.lx, src, file);
    p.nnames = 0;
    p.import_missing = false;
    p.skip_imports = false;
    p.missing_err = .{ .stage = .ERR_NONE, .msg = [_]u8{0} ** 512, .span = dhall.SPAN_NONE, .has_span = false };
    ast.dhall_error_clear(&p.err);
    var t = parse_term(p);
    if (t == null and p.err.stage == .ERR_NONE and p.lx.err.stage == .ERR_NONE) {
        perr(p, lexer.lexer_here(&p.lx), "empty input");
    }
    if (t != null and !at(p, .T_EOF)) {
        perr(p, peek(p).span, "unexpected trailing input");
        t = null;
    }
    if (parser_err(p)) {
        err.* = if (p.err.stage != .ERR_NONE) p.err else p.lx.err;
        return null;
    }
    if (p.import_missing and t != null) {
        err.* = if (p.missing_err.stage != .ERR_NONE)
            p.missing_err
        else
            .{ .stage = .ERR_MISSING, .msg = blk: {
                var m = [_]u8{0} ** 512;
                @memcpy(m[0.."missing import".len], "missing import");
                break :blk m;
            }, .span = dhall.SPAN_NONE, .has_span = false };
        return null;
    }
    if (t == null) {
        perr(p, lexer.lexer_here(&p.lx), "parse error");
        err.* = p.err;
        return null;
    }
    err.* = .{ .stage = .ERR_NONE, .msg = [_]u8{0} ** 512, .span = dhall.SPAN_NONE, .has_span = false };
    return t;
}
