// union_test.zig — regression guard for nullary union support.
// Locks in the subtle lexer/parser behavior (`< File | Dir >` must lex as a
// union-open, not less-than) plus the eager nullary-constructor semantics:
//   (< File | Dir >).File  ⇥  < Dir | File = {} >   (a value of type U)
// Runs under fx-core's `zig build test` via the addTest(dhall_mod) step
// (dhall_mod.zig re-exports this file).
const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const normalize = @import("normalize.zig");

const alloc = std.heap.page_allocator;

fn run(comptime want_typecheck: bool, src: []const u8, out: *std.ArrayList(u8)) bool {
    // fresh arena per expression (mirrors main.zig)
    if (arena.dhall_arena == null) arena.dhall_arena = arena.arena_new();
    arena.arena_reset(arena.dhall_arena.?);

    // NUL-terminated buffer for the [*:0] source cast (mirrors main.zig's read loop)
    var zbuf = std.ArrayList(u8).initCapacity(alloc, src.len + 1) catch unreachable;
    defer zbuf.deinit(alloc);
    zbuf.appendSlice(alloc, src) catch unreachable;
    zbuf.append(alloc, 0) catch unreachable;
    const srcz: [*:0]const u8 = @ptrCast(zbuf.items.ptr);

    var p: dhall.Parser = std.mem.zeroes(dhall.Parser);
    p.loader = null; // import-free corpus
    var err: dhall.DhallError = undefined;
    ast.dhall_error_clear(&err);
    const t = parser.parse_source(&p, srcz, null, &err) orelse return false;

    if (want_typecheck) {
        const ty = typecheck.infer_type(&p, t, &err) orelse return false;
        normalize.normalize_clear_error();
        const nty = normalize.normalize(ty);
        if (normalize.normalize_has_error()) return false;
        const o = ast.Out{ .b = out };
        ast.print_term(o, nty);
        out.append(alloc, '\n') catch return false;
        return true;
    }

    normalize.normalize_clear_error();
    const nf = normalize.normalize(t);
    if (normalize.normalize_has_error()) return false;
    const o = ast.Out{ .b = out };
    ast.print_term(o, nf);
    out.append(alloc, '\n') catch return false;
    return true;
}

fn norm(src: []const u8) []const u8 {
    var out = std.ArrayList(u8).initCapacity(alloc, 128) catch unreachable;
    defer out.deinit(alloc);
    std.debug.assert(run(false, src, &out));
    return out.items;
}

fn tc(src: []const u8) []const u8 {
    var out = std.ArrayList(u8).initCapacity(alloc, 128) catch unreachable;
    defer out.deinit(alloc);
    std.debug.assert(run(true, src, &out));
    return out.items;
}

fn expectEq(comptime want_typecheck: bool, src: []const u8, want: []const u8) !void {
    var out = std.ArrayList(u8).initCapacity(alloc, 128) catch unreachable;
    defer out.deinit(alloc);
    if (!run(want_typecheck, src, &out)) return error.FailedToRun;
    if (!std.mem.eql(u8, out.items, want)) {
        std.debug.print("union_test: mismatch for '{s}':\n  got:  '{s}'\n  want: '{s}'\n", .{ src, out.items, want });
        return error.Mismatch;
    }
}

test "nullary union: lex as union-open, parse, typecheck, normalize" {
    try expectEq(true, "< File | Dir >", "Type\n");
    try expectEq(false, "< File | Dir >", "<Dir|File>\n");
    try expectEq(true, "< File >", "Type\n");
    try expectEq(false, "< File >", "<File>\n");
}

test "nullary union: constructor field access is a value (eager {})" {
    // (< File | Dir >).File : U  (the union type), normalizes to the value
    // carrying the empty record payload — dhall-c's eager-reduction model.
    try expectEq(true, "(< File | Dir >).File", "<Dir|File>\n");
    try expectEq(false, "(< File | Dir >).File", "<Dir|File = {}>\n");
    try expectEq(false, "(< File | Dir >).Dir", "<Dir = {}|File>\n");
    try expectEq(false, "< File >.File", "<File = {}>\n");
}

test "nullary union: let-bound union then field access" {
    try expectEq(false, "let T = < File | Dir > in T.File", "<Dir|File = {}>\n");
}

test "nullary union: merge with eager {} payload (handlers are functions)" {
    // In dhall-c's eager model the constructor value already carries the
    // empty-record payload, so the merge handler is applied to {} and must be
    // a function (consistent with typed-union handlers).
    try expectEq(false, "merge { File = \\(_ : {}) -> 1, Dir = 2 } (< File | Dir >).File", "1\n");
    try expectEq(false, "merge { File = 0, Dir = \\(_ : {}) -> 7 } (< File | Dir >).Dir", "7\n");
}

test "nullary union: unknown alternative rejected" {
    var out = std.ArrayList(u8).initCapacity(alloc, 64) catch unreachable;
    defer out.deinit(alloc);
    std.debug.assert(!run(true, "(< File | Dir >).Bogus", &out));
}

test "nullary union: bare label in a union literal types as {}" {
    try expectEq(true, "< File = {=} | Dir >", "<Dir:{}|File:{}>\n");
    try expectEq(false, "< File = {=} | Dir >", "<Dir|File = {}>\n");
}

// keep `norm`/`tc` referenced so unused-fn analysis is clean
comptime {
    _ = norm;
    _ = tc;
}
