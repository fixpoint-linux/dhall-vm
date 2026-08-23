// lexer.zig — port of ../src/lexer.c, verbatim in behavior. Tokenizer for the
// Dhall subset. Produces tokens with source spans; skips whitespace and
// comments (-- line, {- -} nested block). Strings are not fully tokenized here
// — the parser drives raw-char reading (lexer_read_char/lexer_peek_char) to
// handle ${} nesting. See the C source header for the operator-disambiguation
// notes (signed-literal +/-, < union-open vs less-than, > always T_RANGLE).
//
// Extern-struct mirror of the C Lexer/Token/TokType (dhall.zig), same
// token-emission semantics, same span tracking. Uses libc strtod/strtoull so
// number parsing is byte-identical to the C engine (linked with -lc).

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const bignum = @import("bignum.zig");
const builtins = @import("builtins.zig");
const ast = @import("ast.zig");

extern fn strtod(nptr: [*:0]const u8, endptr: ?*[*c]u8) f64;
extern fn strtoull(nptr: [*:0]const u8, endptr: ?*[*c]u8, base: c_int) c_ulonglong;
extern fn __errno_location() *c_int;

// ERANGE errno value on Linux/glibc (used by strtoull overflow detection).
const ERANGE: c_int = 34;

// ---------------- char classes (C locale, matching lexer.c) ----------------

fn is_digit(c: c_int) bool {
    return c >= '0' and c <= '9';
}

fn isalpha(c: c_int) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn isalnum(c: c_int) bool {
    return isalpha(c) or is_digit(c);
}

fn isxdigit(c: c_int) bool {
    return is_digit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn tolower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ---------------- raw position helpers ----------------

fn cur(lx: *dhall.Lexer) c_int {
    if (lx.pos < lx.len) return @intCast(lx.src.?[lx.pos]);
    return -1;
}

pub fn lexer_init(lx: *dhall.Lexer, src: ?[*:0]const u8, file: ?[*:0]const u8) void {
    lx.src = src;
    lx.len = std.mem.len(src.?);
    lx.pos = 0;
    lx.line = 1;
    lx.col = 1;
    lx.file = file;
    lx.after_operand = false;
    lx.has_peek = false;
    ast.dhall_error_clear(&lx.err);
}

pub fn lexer_here(lx: *dhall.Lexer) dhall.SourceSpan {
    return .{ .file = lx.file, .line = lx.line, .col = lx.col };
}

pub fn lexer_read_char(lx: *dhall.Lexer) c_int {
    if (lx.pos >= lx.len) return -1;
    const c: c_int = @intCast(lx.src.?[lx.pos]);
    lx.pos += 1;
    if (c == '\n') {
        lx.line += 1;
        lx.col = 1;
    } else lx.col += 1;
    return c;
}

pub fn lexer_peek_char(lx: *dhall.Lexer) c_int {
    return cur(lx);
}

pub fn lexer_eof(lx: *dhall.Lexer) bool {
    return cur(lx) == -1;
}

fn skip_ws_and_comments(lx: *dhall.Lexer) void {
    while (true) {
        const c = cur(lx);
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            _ = lexer_read_char(lx);
            continue;
        }
        if (c == '-' and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == '-') {
            while (cur(lx) != -1 and cur(lx) != '\n') _ = lexer_read_char(lx);
            continue;
        }
        if (c == '{' and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == '-') {
            _ = lexer_read_char(lx);
            _ = lexer_read_char(lx); // consume {-
            var depth: c_int = 1;
            while (depth > 0 and cur(lx) != -1) {
                if (cur(lx) == '{' and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == '-') {
                    _ = lexer_read_char(lx);
                    _ = lexer_read_char(lx);
                    depth += 1;
                } else if (cur(lx) == '-' and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == '}') {
                    _ = lexer_read_char(lx);
                    _ = lexer_read_char(lx);
                    depth -= 1;
                } else _ = lexer_read_char(lx);
            }
            continue;
        }
        break;
    }
}

fn is_name_start(c: c_int) bool {
    return c != -1 and (isalpha(c) or c == '_');
}

fn is_name_char(c: c_int) bool {
    return c != -1 and (isalnum(c) or c == '_' or c == '-' or c == '\'' or c == '/');
}

// is the current char a +/- that begins a signed literal? a sign starts a
// signed literal only when it is followed (possibly after whitespace) by a
// digit. Non-consuming: only inspects lx.src.
fn sign_starts_literal(lx: *dhall.Lexer) bool {
    var p = lx.pos;
    if (p >= lx.len) return false;
    const s: c_int = @intCast(lx.src.?[p]);
    if (s != '+' and s != '-') return false;
    p += 1;
    while (p < lx.len) {
        const w: c_int = @intCast(lx.src.?[p]);
        if (w == ' ' or w == '\t' or w == '\r' or w == '\n') p += 1 else break;
    }
    return p < lx.len and is_digit(@intCast(lx.src.?[p]));
}

fn is_import_path_char(c: c_int) bool {
    if (c == -1) return false;
    if (isalnum(c)) return true;
    return switch (c) {
        '_', '-', '.', '/', '~', '+' => true,
        else => false,
    };
}

// URL character set for a scheme:// import body (EXCLUDES '?' and '#', see C).
fn is_url_char(c: c_int) bool {
    if (c == -1) return false;
    if (isalnum(c)) return true;
    return switch (c) {
        '-', '.', '_', '~', ':', '/', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '%' => true,
        else => false,
    };
}

// does a token type end a complete operand? (for +/- signed-vs-binary)
fn tok_ends_operand(t: dhall.TokType, name: ?[*:0]u8) bool {
    return switch (t) {
        .T_NAT, .T_INT, .T_DBL, .T_RPAREN, .T_RBRACKET, .T_RBRACE, .T_RANGLE,
        .T_IMPORT, .T_SHA256, .T_STR_OPEN, .T_STR_OPEN_MULTILINE => true,
        .T_NAME => {
            // A keyword never ends an operand, and a builtin (a function value)
            // never does either — it is awaiting an application argument, so a
            // following +/- is a signed literal (e.g. `Integer/toDouble +3`).
            // Only a plain variable denotes a complete operand.
            const n = std.mem.span(name.?);
            return !builtins.builtin_is_keyword(n) and builtins.builtin_type_schema(n) == null;
        },
        else => false,
    };
}

fn emit(lx: *dhall.Lexer, t: dhall.TokType, sp: dhall.SourceSpan, name: ?[*:0]u8) dhall.Token {
    var tok: dhall.Token = undefined;
    tok.type = t;
    tok.span = sp;
    tok.name = name;
    tok.c = .{ .kind = .C_NAT, .nat = 0, .i64 = 0, .dbl = 0, .b = false, .bnat = null, .big = null };
    lx.after_operand = tok_ends_operand(t, name);
    return tok;
}

// set a fixed lex error message (mirrors snprintf of the literal format).
fn set_err(lx: *dhall.Lexer, sp: dhall.SourceSpan, msg: []const u8) void {
    lx.err.stage = .ERR_LEX;
    lx.err.span = sp;
    lx.err.has_span = true;
    @memcpy(lx.err.msg[0..msg.len], msg);
    lx.err.msg[msg.len] = 0;
}

// tokenize one token starting at current raw position (skipping ws/comments)
fn tokenize(lx: *dhall.Lexer) dhall.Token {
    skip_ws_and_comments(lx);
    const sp = lexer_here(lx);
    const c = cur(lx);
    if (c == -1) return emit(lx, .T_EOF, sp, null);

    // string
    if (c == '"') {
        _ = lexer_read_char(lx);
        return emit(lx, .T_STR_OPEN, sp, null);
    }

    // multiline string opener ('' — two single quotes, not """ or ''')
    if (c == '\'' and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == '\'') {
        _ = lexer_read_char(lx);
        _ = lexer_read_char(lx);
        return emit(lx, .T_STR_OPEN_MULTILINE, sp, null);
    }

    // number: +n / -n / 0 -> Integer; digits -> Natural/Double.
    // A +/- is a signed-literal prefix only when NOT after an operand.
    if (is_digit(c) or ((c == '+' or c == '-') and !lx.after_operand and sign_starts_literal(lx))) {
        // signed literal
        if (c == '+' or c == '-') {
            _ = lexer_read_char(lx);
            // allow whitespace between the sign and the digits (`- 5`)
            while (cur(lx) == ' ' or cur(lx) == '\t' or cur(lx) == '\r' or cur(lx) == '\n')
                _ = lexer_read_char(lx);
            if (!is_digit(cur(lx))) {
                set_err(lx, sp, "expected digits after sign");
                return emit(lx, .T_ERROR, sp, null);
            }
            const t = tokenize(lx);
            if (t.type != .T_NAT and t.type != .T_DBL) {
                set_err(lx, sp, "expected number literal after sign");
                return emit(lx, .T_ERROR, sp, null);
            }
            if (t.type == .T_DBL) {
                var v = t.c.dbl;
                if (c == '-') v = -v;
                var r = emit(lx, .T_DBL, sp, null);
                r.c = .{ .kind = .C_DBL, .nat = 0, .i64 = 0, .dbl = v, .b = false, .bnat = null, .big = null };
                return r;
            }
            // Integer (arbitrary precision): build a signed BigInt directly.
            var mag_bn: dhall.BigNat = undefined;
            var scratch: [2]u32 = undefined;
            if (t.c.bnat) |p| {
                mag_bn = p.*;
            } else {
                const n = bignum.bignat_from_u64(t.c.nat, &scratch);
                mag_bn = .{ .limbs = &scratch, .nlimbs = n };
            }
            const bi = dhall.BigInt{ .neg = (c == '-'), .mag = mag_bn };
            var r = emit(lx, .T_INT, sp, null);
            r.c = bignum.bigint_to_const(bi);
            return r;
        }
        // unsigned literal
        const start = lx.pos;
        while (is_digit(cur(lx))) _ = lexer_read_char(lx);
        var is_double = (cur(lx) == '.' and lx.pos + 1 < lx.len and is_digit(@intCast(lx.src.?[lx.pos + 1])));
        if (!is_double and (cur(lx) == 'e' or cur(lx) == 'E')) is_double = true;
        if (is_double) {
            if (cur(lx) == '.') {
                _ = lexer_read_char(lx);
                while (is_digit(cur(lx))) _ = lexer_read_char(lx);
            }
            if (cur(lx) == 'e' or cur(lx) == 'E') {
                _ = lexer_read_char(lx);
                if (cur(lx) == '+' or cur(lx) == '-') _ = lexer_read_char(lx);
                if (!is_digit(cur(lx))) {
                    set_err(lx, sp, "malformed double literal");
                    return emit(lx, .T_ERROR, sp, null);
                }
                while (is_digit(cur(lx))) _ = lexer_read_char(lx);
            }
            const buf = arena.arena_strndup(arena.dhall_arena.?, lx.src.?[start..lx.pos], lx.pos - start);
            const d = strtod(buf, null);
            var t = emit(lx, .T_DBL, sp, null);
            t.c = .{ .kind = .C_DBL, .nat = 0, .i64 = 0, .dbl = d, .b = false, .bnat = null, .big = null };
            return t;
        }
        // Natural (arbitrary precision: ERANGE => parse the decimal as a BigNat)
        const buf = arena.arena_strndup(arena.dhall_arena.?, lx.src.?[start..lx.pos], lx.pos - start);
        __errno_location().* = 0;
        const v = strtoull(buf, null, 10);
        var t = emit(lx, .T_NAT, sp, null);
        if (__errno_location().* == ERANGE) {
            const bn = bignum.bignat_from_decimal(std.mem.span(buf));
            t.c = bignum.bignat_to_const(bn);
        } else {
            t.c = .{ .kind = .C_NAT, .nat = @intCast(v), .i64 = 0, .dbl = 0, .b = false, .bnat = null, .big = null };
        }
        return t;
    }

    // identifier / keyword (and env:NAME import)
    if (is_name_start(c)) {
        const start = lx.pos;
        _ = lexer_read_char(lx);
        while (is_name_char(cur(lx))) {
            // stop before a '/' that begins the /\\ merge operator, so `b/\\c`
            // lexes as `b` `\\/` `c` rather than identifier `b/` + lambda `\\c`.
            if (cur(lx) == '/' and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == '\\') break;
            _ = lexer_read_char(lx);
        }
        const name = arena.arena_strndup(arena.dhall_arena.?, lx.src.?[start..lx.pos], lx.pos - start);
        // env:NAME import: 'env' immediately followed by ':'
        if (std.mem.eql(u8, std.mem.span(name), "env") and cur(lx) == ':') {
            _ = lexer_read_char(lx); // ':'
            const s2 = lx.pos;
            if (cur(lx) != -1 and (isalpha(cur(lx)) or cur(lx) == '_')) {
                while (cur(lx) != -1 and (isalnum(cur(lx)) or cur(lx) == '_')) {
                    _ = lexer_read_char(lx);
                }
            }
            const nlen = lx.pos - s2;
            const spec = arena.arena_alloc(arena.dhall_arena.?, 4 + nlen + 1);
            @memcpy(spec[0..4], "env:");
            @memcpy(spec[4 .. 4 + nlen], lx.src.?[s2..lx.pos]);
            spec[4 + nlen] = 0;
            return emit(lx, .T_IMPORT, sp, @ptrCast(spec));
        }
        // `missing` import: always absent. Full-string match only.
        if (std.mem.eql(u8, std.mem.span(name), "missing"))
            return emit(lx, .T_IMPORT, sp, name);
        // sha256:<64 hexdigits> import hash. Bounded lookahead + rewind so
        // `sha256 : Text` / `sha256:Natural` still lex as T_NAME + T_COLON.
        if (std.mem.eql(u8, std.mem.span(name), "sha256") and cur(lx) == ':') {
            const save_pos = lx.pos;
            const save_line = lx.line;
            const save_col = lx.col;
            _ = lexer_read_char(lx); // ':'
            const hs = lx.pos;
            while (isxdigit(cur(lx))) _ = lexer_read_char(lx);
            const hlen = lx.pos - hs;
            if (hlen == 64 and !isxdigit(cur(lx))) {
                const hex = arena.arena_alloc(arena.dhall_arena.?, 65);
                var i: usize = 0;
                while (i < 64) : (i += 1)
                    hex[i] = tolower(lx.src.?[hs + i]);
                hex[64] = 0;
                return emit(lx, .T_SHA256, sp, @ptrCast(hex));
            }
            // rewind: not a hash (e.g. sha256:Natural, sha256 : Text)
            lx.pos = save_pos;
            lx.line = save_line;
            lx.col = save_col;
        }
        // scheme:// URL import. Only fires when immediately followed by "://".
        if (cur(lx) == ':' and lx.pos + 2 < lx.len and
            lx.src.?[lx.pos + 1] == '/' and lx.src.?[lx.pos + 2] == '/')
        {
            _ = lexer_read_char(lx); // ':'
            _ = lexer_read_char(lx); // '/'
            _ = lexer_read_char(lx); // '/'
            const us = lx.pos;
            while (is_url_char(cur(lx))) _ = lexer_read_char(lx);
            const ulen = lx.pos - us;
            const nlen = std.mem.len(name);
            const spec = arena.arena_alloc(arena.dhall_arena.?, nlen + 3 + ulen + 1);
            @memcpy(spec[0..nlen], name[0..nlen]);
            spec[nlen] = ':';
            spec[nlen + 1] = '/';
            spec[nlen + 2] = '/';
            @memcpy(spec[nlen + 3 .. nlen + 3 + ulen], lx.src.?[us..lx.pos]);
            spec[nlen + 3 + ulen] = 0;
            return emit(lx, .T_IMPORT, sp, @ptrCast(spec));
        }
        return emit(lx, .T_NAME, sp, name);
    }

    // record merge operator /\\ — BEFORE the import-path branch.
    if (c == '/' and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == '\\') {
        _ = lexer_read_char(lx);
        _ = lexer_read_char(lx);
        return emit(lx, .T_MERGE, sp, null);
    }

    // record prefer operator // — likewise BEFORE the import-path branch.
    if (c == '/' and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == '/') {
        _ = lexer_read_char(lx);
        _ = lexer_read_char(lx);
        return emit(lx, .T_PREFER, sp, null);
    }

    // import path: ./ ../ /abs
    if (c == '/' or
        (c == '.' and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == '/') or
        (c == '.' and lx.pos + 2 < lx.len and lx.src.?[lx.pos + 1] == '.' and lx.src.?[lx.pos + 2] == '/'))
    {
        const start = lx.pos;
        while (is_import_path_char(cur(lx))) _ = lexer_read_char(lx);
        const spec = arena.arena_strndup(arena.dhall_arena.?, lx.src.?[start..lx.pos], lx.pos - start);
        return emit(lx, .T_IMPORT, sp, spec);
    }

    // Unicode operator glyphs (UTF-8): λ U+03BB -> lambda, → U+2192 -> arrow.
    if (c == 0xCE and lx.pos + 1 < lx.len and lx.src.?[lx.pos + 1] == 0xBB) {
        _ = lexer_read_char(lx);
        _ = lexer_read_char(lx);
        return emit(lx, .T_LAMBDA, sp, null);
    }
    if (c == 0xE2 and lx.pos + 2 < lx.len and
        lx.src.?[lx.pos + 1] == 0x86 and lx.src.?[lx.pos + 2] == 0x92)
    {
        _ = lexer_read_char(lx);
        _ = lexer_read_char(lx);
        _ = lexer_read_char(lx);
        return emit(lx, .T_ARROW, sp, null);
    }
    // ∀ U+2200 -> forall; ∧ U+2227 -> T_MERGE; ≡ U+2261 -> T_EQEQ; ⫽ U+2AFD -> T_PREFER
    if (c == 0xE2 and lx.pos + 2 < lx.len) {
        const b1 = lx.src.?[lx.pos + 1];
        const b2 = lx.src.?[lx.pos + 2];
        if (b1 == 0x88 and b2 == 0x80) { // ∀ U+2200 forall
            _ = lexer_read_char(lx);
            _ = lexer_read_char(lx);
            _ = lexer_read_char(lx);
            return emit(lx, .T_NAME, sp, arena.arena_strdup(arena.dhall_arena.?, "forall"));
        }
        if (b1 == 0x88 and b2 == 0xA7) { // ∧ U+2227 combine
            _ = lexer_read_char(lx);
            _ = lexer_read_char(lx);
            _ = lexer_read_char(lx);
            return emit(lx, .T_MERGE, sp, null);
        }
        if (b1 == 0x89 and b2 == 0xA1) { // ≡ U+2261 equivalence
            _ = lexer_read_char(lx);
            _ = lexer_read_char(lx);
            _ = lexer_read_char(lx);
            return emit(lx, .T_EQEQ, sp, null);
        }
        if (b1 == 0xAB and b2 == 0xBD) { // ⫽ U+2AFD prefer
            _ = lexer_read_char(lx);
            _ = lexer_read_char(lx);
            _ = lexer_read_char(lx);
            return emit(lx, .T_PREFER, sp, null);
        }
    }

    // symbols
    _ = lexer_read_char(lx);
    switch (c) {
        '\\' => return emit(lx, .T_LAMBDA, sp, null),
        ':' => return emit(lx, .T_COLON, sp, null),
        '=' => {
            if (cur(lx) == '=') {
                _ = lexer_read_char(lx);
                return emit(lx, .T_EQEQ, sp, null);
            }
            return emit(lx, .T_EQUALS, sp, null);
        },
        ',' => return emit(lx, .T_COMMA, sp, null),
        '.' => return emit(lx, .T_DOT, sp, null),
        '(' => return emit(lx, .T_LPAREN, sp, null),
        ')' => return emit(lx, .T_RPAREN, sp, null),
        '{' => return emit(lx, .T_LBRACE, sp, null),
        '}' => return emit(lx, .T_RBRACE, sp, null),
        '<' => {
            if (cur(lx) == '=') {
                _ = lexer_read_char(lx);
                return emit(lx, .T_LE, sp, null);
            }
            // bounded lookahead: union-open iff < (ws) NAME (ws) (: or = not ==)
            const save_pos = lx.pos;
            const save_line = lx.line;
            const save_col = lx.col;
            while (cur(lx) == ' ' or cur(lx) == '\t' or cur(lx) == '\r' or cur(lx) == '\n')
                _ = lexer_read_char(lx);
            var is_union = false;
            if (is_name_start(cur(lx))) {
                while (is_name_char(cur(lx))) _ = lexer_read_char(lx);
                while (cur(lx) == ' ' or cur(lx) == '\t' or cur(lx) == '\r' or cur(lx) == '\n')
                    _ = lexer_read_char(lx);
                if (cur(lx) == ':' or
                    (cur(lx) == '=' and (lx.pos + 1 >= lx.len or lx.src.?[lx.pos + 1] != '=')))
                    is_union = true;
            }
            lx.pos = save_pos;
            lx.line = save_line;
            lx.col = save_col;
            return emit(lx, if (is_union) .T_LANGLE else .T_LT, sp, null);
        },
        '>' => {
            if (cur(lx) == '=') {
                _ = lexer_read_char(lx);
                return emit(lx, .T_GE, sp, null);
            }
            return emit(lx, .T_RANGLE, sp, null);
        },
        '[' => return emit(lx, .T_LBRACKET, sp, null),
        ']' => return emit(lx, .T_RBRACKET, sp, null),
        '|' => {
            if (cur(lx) == '|') {
                _ = lexer_read_char(lx);
                return emit(lx, .T_OR, sp, null);
            }
            return emit(lx, .T_BAR, sp, null);
        },
        '&' => {
            if (cur(lx) == '&') {
                _ = lexer_read_char(lx);
                return emit(lx, .T_AND, sp, null);
            }
            set_err(lx, sp, "unexpected '&'");
            return emit(lx, .T_ERROR, sp, null);
        },
        '#' => return emit(lx, .T_HASH, sp, null),
        '?' => return emit(lx, .T_QMARK, sp, null),
        '*' => return emit(lx, .T_STAR, sp, null),
        '+' => {
            if (cur(lx) == '+') {
                _ = lexer_read_char(lx);
                return emit(lx, .T_PLUSPLUS, sp, null);
            }
            return emit(lx, .T_PLUS, sp, null);
        },
        '-' => {
            if (cur(lx) == '>') {
                _ = lexer_read_char(lx);
                return emit(lx, .T_ARROW, sp, null);
            }
            return emit(lx, .T_MINUS, sp, null);
        },
        '!' => {
            if (cur(lx) == '=') {
                _ = lexer_read_char(lx);
                return emit(lx, .T_NE, sp, null);
            }
            set_err(lx, sp, "unexpected '!'");
            return emit(lx, .T_ERROR, sp, null);
        },
        else => {
            var m: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&m, "unexpected character '{c}'", .{@as(u8, @intCast(c))}) catch unreachable;
            set_err(lx, sp, s);
            return emit(lx, .T_ERROR, sp, null);
        },
    }
}

pub fn lexer_peek(lx: *dhall.Lexer) dhall.Token {
    if (!lx.has_peek) {
        lx.peeked = tokenize(lx);
        lx.has_peek = true;
    }
    return lx.peeked;
}

pub fn lexer_next(lx: *dhall.Lexer) dhall.Token {
    if (lx.has_peek) {
        lx.has_peek = false;
        return lx.peeked;
    }
    return tokenize(lx);
}
