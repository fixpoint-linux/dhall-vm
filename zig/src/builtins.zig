// builtins.zig — port of ../src/builtins.c, verbatim in behavior.
// Well-known builtins and their de Bruijn type schemas. The List builtin
// schemas are adopted VERBATIM from ref/proto.c; Optional/fold and Natural/fold
// from ref/vschema.c (see the C header comment). Every schema is a Term built
// with the ast constructors.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const ast = @import("ast.zig");

pub fn builtin_is_type_name(n: []const u8) bool {
    return std.mem.eql(u8, n, "Natural") or std.mem.eql(u8, n, "Integer") or
        std.mem.eql(u8, n, "Double") or std.mem.eql(u8, n, "Bool") or
        std.mem.eql(u8, n, "Text");
}

pub fn builtin_is_list(n: []const u8) bool {
    return std.mem.eql(u8, n, "List");
}

// reserved keywords handled specially by the parser (not plain builtins)
pub fn builtin_is_keyword(n: []const u8) bool {
    return std.mem.eql(u8, n, "let") or std.mem.eql(u8, n, "in") or
        std.mem.eql(u8, n, "if") or std.mem.eql(u8, n, "then") or
        std.mem.eql(u8, n, "else") or std.mem.eql(u8, n, "merge") or
        std.mem.eql(u8, n, "forall") or std.mem.eql(u8, n, "assert") or
        std.mem.eql(u8, n, "Some") or std.mem.eql(u8, n, "None") or
        std.mem.eql(u8, n, "toMap") or std.mem.eql(u8, n, "with");
}

// type constant terms
fn builtin_nat() *dhall.Term {
    return ast.tm_builtin("Natural");
}
fn builtin_int() *dhall.Term {
    return ast.tm_builtin("Integer");
}
fn builtin_dbl() *dhall.Term {
    return ast.tm_builtin("Double");
}
fn builtin_bool() *dhall.Term {
    return ast.tm_builtin("Bool");
}
fn builtin_text() *dhall.Term {
    return ast.tm_builtin("Text");
}
fn builtin_list() *dhall.Term {
    return ast.tm_builtin("List");
}

// ---- List builtin type schemas (verbatim from proto.c) ----

fn map_type() *dhall.Term {
    return ast.tm_pi(ast.tm_type(),
        ast.tm_pi(ast.tm_type(),
            ast.tm_pi(ast.tm_pi(ast.tm_var(1), ast.tm_var(1)),
                ast.tm_pi(ast.tm_app(builtin_list(), ast.tm_var(2)), ast.tm_app(builtin_list(), ast.tm_var(2))))));
}

fn filter_type() *dhall.Term {
    return ast.tm_pi(ast.tm_type(),
        ast.tm_pi(ast.tm_pi(ast.tm_var(0), builtin_bool()),
            ast.tm_pi(ast.tm_app(builtin_list(), ast.tm_var(1)), ast.tm_app(builtin_list(), ast.tm_var(2)))));
}

fn reverse_type() *dhall.Term {
    return ast.tm_pi(ast.tm_type(), ast.tm_pi(ast.tm_app(builtin_list(), ast.tm_var(0)), ast.tm_app(builtin_list(), ast.tm_var(1))));
}

fn fold_type() *dhall.Term {
    return ast.tm_pi(ast.tm_type(),
        ast.tm_pi(ast.tm_app(builtin_list(), ast.tm_var(0)),
            ast.tm_pi(ast.tm_type(),
                ast.tm_pi(ast.tm_pi(ast.tm_var(2), ast.tm_pi(ast.tm_var(1), ast.tm_var(2))),
                    ast.tm_pi(ast.tm_var(1), ast.tm_var(2))))));
}

// ---- Optional / Natural builtin schemas ----

fn opt() *dhall.Term {
    return ast.tm_builtin("Optional");
}
fn nat() *dhall.Term {
    return ast.tm_builtin("Natural");
}
fn app(f: ?*dhall.Term, x: ?*dhall.Term) *dhall.Term {
    return ast.tm_app(f, x);
}

// direct de Bruijn Optional/fold schema
fn direct_optional_fold() *dhall.Term {
    return ast.tm_pi(ast.tm_type(),
        ast.tm_pi(app(opt(), ast.tm_var(0)),
            ast.tm_pi(ast.tm_type(),
                ast.tm_pi(ast.tm_pi(ast.tm_var(2), ast.tm_var(1)),
                    ast.tm_pi(ast.tm_var(1), ast.tm_var(2))))));
}

// direct de Bruijn Natural/fold schema
fn direct_natural_fold() *dhall.Term {
    return ast.tm_pi(nat(),
        ast.tm_pi(ast.tm_type(),
            ast.tm_pi(ast.tm_pi(ast.tm_var(0), ast.tm_var(1)),
                ast.tm_pi(ast.tm_var(1), ast.tm_var(2)))));
}

// Natural/build
fn direct_natural_build() *dhall.Term {
    return ast.tm_pi(ast.tm_pi(ast.tm_type(), ast.tm_pi(ast.tm_pi(ast.tm_var(0), ast.tm_var(1)), ast.tm_pi(ast.tm_var(1), ast.tm_var(2)))), nat());
}

// List/build
fn list_build_type() *dhall.Term {
    return ast.tm_pi(ast.tm_type(),
        ast.tm_pi(ast.tm_pi(ast.tm_type(),
                ast.tm_pi(ast.tm_pi(ast.tm_var(1), ast.tm_pi(ast.tm_var(1), ast.tm_var(2))),
                    ast.tm_pi(ast.tm_var(1), ast.tm_var(2)))),
            ast.tm_app(builtin_list(), ast.tm_var(1))));
}

// List/head, List/last
fn list_head_type() *dhall.Term {
    return ast.tm_pi(ast.tm_type(),
        ast.tm_pi(ast.tm_app(builtin_list(), ast.tm_var(0)),
            ast.tm_app(opt(), ast.tm_var(1))));
}

// List/indexed
fn list_indexed_type() *dhall.Term {
    const fs: [*]dhall.Field = @ptrCast(@alignCast(arena.arena_alloc(arena.dhall_arena.?, 2 * @sizeOf(dhall.Field))));
    fs[0] = .{ .label = arena.arena_strdup(arena.dhall_arena.?, "index"), .type = builtin_nat(), .value = null };
    fs[1] = .{ .label = arena.arena_strdup(arena.dhall_arena.?, "value"), .type = ast.tm_var(1), .value = null };
    const rec = ast.tm_record_type(fs, 2);
    return ast.tm_pi(ast.tm_type(),
        ast.tm_pi(ast.tm_app(builtin_list(), ast.tm_var(0)),
            ast.tm_app(builtin_list(), rec)));
}

// type schema for a builtin when used as a term; NULL if not a known builtin
pub fn builtin_type_schema(n: []const u8) ?*dhall.Term {
    if (builtin_is_type_name(n)) return ast.tm_type();
    if (builtin_is_list(n)) return ast.tm_pi(ast.tm_type(), ast.tm_type());
    if (std.mem.eql(u8, n, "List/map")) return map_type();
    if (std.mem.eql(u8, n, "List/filter")) return filter_type();
    if (std.mem.eql(u8, n, "List/reverse")) return reverse_type();
    if (std.mem.eql(u8, n, "List/fold")) return fold_type();
    if (std.mem.eql(u8, n, "Optional")) return ast.tm_pi(ast.tm_type(), ast.tm_type());
    if (std.mem.eql(u8, n, "Optional/fold")) return direct_optional_fold();
    if (std.mem.eql(u8, n, "Natural/fold")) return direct_natural_fold();
    if (std.mem.eql(u8, n, "Natural/isZero")) return ast.tm_pi(nat(), ast.tm_builtin("Bool"));
    if (std.mem.eql(u8, n, "Natural/show")) return ast.tm_pi(nat(), ast.tm_builtin("Text"));
    if (std.mem.eql(u8, n, "Natural/subtract")) return ast.tm_pi(nat(), ast.tm_pi(nat(), nat()));
    if (std.mem.eql(u8, n, "Natural/even")) return ast.tm_pi(nat(), builtin_bool());
    if (std.mem.eql(u8, n, "Natural/odd")) return ast.tm_pi(nat(), builtin_bool());
    if (std.mem.eql(u8, n, "Natural/toInteger")) return ast.tm_pi(nat(), builtin_int());
    if (std.mem.eql(u8, n, "Integer/toDouble")) return ast.tm_pi(builtin_int(), builtin_dbl());
    if (std.mem.eql(u8, n, "Text/replace")) return ast.tm_pi(builtin_text(), ast.tm_pi(builtin_text(), ast.tm_pi(builtin_text(), builtin_text())));
    if (std.mem.eql(u8, n, "List/length")) return ast.tm_pi(ast.tm_type(), ast.tm_pi(ast.tm_app(builtin_list(), ast.tm_var(0)), nat()));
    if (std.mem.eql(u8, n, "Integer/negate")) return ast.tm_pi(builtin_int(), builtin_int());
    if (std.mem.eql(u8, n, "Integer/show")) return ast.tm_pi(builtin_int(), builtin_text());
    if (std.mem.eql(u8, n, "Integer/clamp")) return ast.tm_pi(builtin_int(), nat());
    if (std.mem.eql(u8, n, "Double/show")) return ast.tm_pi(builtin_dbl(), builtin_text());
    if (std.mem.eql(u8, n, "Text/show")) return ast.tm_pi(builtin_text(), builtin_text());
    if (std.mem.eql(u8, n, "List/head")) return list_head_type();
    if (std.mem.eql(u8, n, "List/last")) return list_head_type();
    if (std.mem.eql(u8, n, "List/indexed")) return list_indexed_type();
    if (std.mem.eql(u8, n, "List/build")) return list_build_type();
    if (std.mem.eql(u8, n, "Natural/build")) return direct_natural_build();
    return null;
}
