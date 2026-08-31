// abi.zig — C-ABI export layer (U9): libdhall.so surface.
//
// Builds a gcc-linkable shared object that exports the exact `dhall.h` public
// surface dhake (and any other in-process consumer) links against, so the Zig
// engine can drop in as libdhall.so for dhake with ZERO consumer source changes.
// The consumer's own src/dhall.h stays the ABI source of truth; the Term/Field/
// TextPart/Parser/DhallError mirror types in dhall.zig are byte-identical
// extern layouts, so dhake's raw Term-tree walking (p->tag, p->as.cons.tail,
// rec->as.rec.fs[i].label/value, ...) works unchanged.
//
// Symbol set derived by grepping vendor/dhake/src/dhake.c for every dhall.h
// symbol it references (dafsa abi.zig did exactly this): the arena family
// (arena_new/reset/alloc/strdup/strndup + the `dhall_arena` global), the error
// helpers dhake uses (dhall_error_clear/exit), import_loader_new/push_root/free,
// parse_source, the normalize family (normalize + the normalize_clear_error/
// has_error/get_error channel), and sha256_hex (dhake's file-hash verification).
// dhake deliberately does NOT call infer_type/print_term/builtin_type_schema.
//
// The `dhall_arena` global is re-exported from arena.zig's `export var` — the
// C symbol and the core's internal global are the same storage.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena_mod = @import("arena.zig");
const ast_mod = @import("ast.zig");
const parser_mod = @import("parser.zig");
const normalize_mod = @import("normalize.zig");
const import_mod = @import("import.zig");
const sha256_mod = @import("sha256.zig");
const typecheck_mod = @import("typecheck.zig");

// ─── Arena ──────────────────────────────────────────────────────────────────
// The concrete Arena is opaque on the C side (forward-declared only), so these
// exports hand back / accept opaque pointers.

export fn arena_new() ?*arena_mod.Arena {
    const a = arena_mod.arena_new();
    // dhake links the core in-process and does `if (!dhall_arena)
    // dhall_arena = arena_new();`. Because Zig binds the core's internal
    // arena.dhall_arena to a LOCAL symbol (libdhall.so's own copy) rather than
    // through the interposable GLOBAL `dhall_arena`, dhake's COPY relocation on
    // the C global does NOT redirect the core's reads — the core's
    // `arena.dhall_arena` would stay NULL and every arena_alloc would panic.
    // Mirror the C flow explicitly: setting the internal global here guarantees
    // parse_source/normalize allocate into the arena dhake created.
    arena_mod.dhall_arena = a;
    return a;
}

export fn arena_reset(a: ?*arena_mod.Arena) void {
    const aa = a orelse return;
    arena_mod.arena_reset(aa);
}

export fn arena_alloc(a: ?*arena_mod.Arena, n: usize) ?*anyopaque {
    const aa = a orelse return null;
    return @ptrCast(arena_mod.arena_alloc(aa, n));
}

inline fn cstrSlice(s: [*c]const u8) ?[]const u8 {
    if (s == null) return null;
    const z: [*:0]const u8 = @ptrCast(s);
    return std.mem.span(z);
}

export fn arena_strdup(a: ?*arena_mod.Arena, s: [*c]const u8) ?[*:0]u8 {
    const aa = a orelse return null;
    const sl = cstrSlice(s) orelse return null;
    return arena_mod.arena_strdup(aa, sl);
}

export fn arena_strndup(a: ?*arena_mod.Arena, s: [*c]const u8, n: usize) ?[*:0]u8 {
    const aa = a orelse return null;
    if (s == null) return null;
    const p: [*]const u8 = @ptrCast(s);
    return arena_mod.arena_strndup(aa, p[0..n], n);
}

// ─── Error helpers ──────────────────────────────────────────────────────────

export fn dhall_error_clear(e: ?*dhall.DhallError) void {
    const ee = e orelse return;
    ast_mod.dhall_error_clear(ee);
}

export fn dhall_error_exit(e: ?*dhall.DhallError) c_int {
    const ee = e orelse return 3;
    return ast_mod.dhall_error_exit(ee);
}

// ─── Import loader ──────────────────────────────────────────────────────────

export fn import_loader_new() ?*dhall.ImportLoader {
    return import_mod.import_loader_new();
}

export fn import_loader_free(lp: ?*dhall.ImportLoader) void {
    import_mod.import_loader_free(lp);
}

export fn import_loader_push_root(lp: ?*dhall.ImportLoader, root_file: ?[*:0]const u8) void {
    import_mod.import_loader_push_root(lp, root_file);
}

// ─── Parse / normalize ──────────────────────────────────────────────────────

export fn parse_source(
    p: ?*dhall.Parser,
    src: ?[*:0]const u8,
    file: ?[*:0]const u8,
    err: ?*dhall.DhallError,
) ?*dhall.Term {
    const pp = p orelse return null;
    const ee = err orelse return null;
    return parser_mod.parse_source(pp, src, file, ee);
}

// infer_type (the typecheck gate in compendium/src/config.c, which visage's
// src/config.c mirrors): stock abi.zig originally omitted this because dhake
// does not call it, but in-process consumers that walk parse -> infer ->
// normalize do.  Exported here so libdhall.so carries the full eval pipeline.
export fn infer_type(
    p: ?*dhall.Parser,
    t: ?*dhall.Term,
    err: ?*dhall.DhallError,
) ?*dhall.Term {
    const pp = p orelse return null;
    const tt = t orelse return null;
    const ee = err orelse return null;
    return typecheck_mod.infer_type(pp, tt, ee);
}

export fn normalize(t: ?*dhall.Term) ?*dhall.Term {
    const tt = t orelse return null;
    return normalize_mod.normalize(tt);
}

export fn normalize_clear_error() void {
    normalize_mod.normalize_clear_error();
}

export fn normalize_has_error() bool {
    return normalize_mod.normalize_has_error();
}

export fn normalize_get_error() ?*dhall.DhallError {
    return normalize_mod.normalize_get_error();
}

// ─── sha256 (dhake file-hash verification) ─────────────────────────────────

export fn sha256_hex(data: [*c]const u8, len: usize, out: ?[*]u8) void {
    if (out == null) return;
    const s: []const u8 = if (data == null)
        &[_]u8{}
    else
        @as([*]const u8, @ptrCast(data))[0..len];
    const o: *[65]u8 = @ptrCast(@alignCast(out.?));
    sha256_mod.sha256_hex(s, o);
}

// ─── Force symbol emission (belt & braces with `export fn`) ─────────────────
// Also force the `dhall_arena` global symbol (it is an `export var` in arena.zig,
// but referencing it here guarantees the abi.zig compilation unit keeps it live).

comptime {
    _ = &arena_new;
    _ = &arena_reset;
    _ = &arena_alloc;
    _ = &arena_strdup;
    _ = &arena_strndup;
    _ = &dhall_error_clear;
    _ = &dhall_error_exit;
    _ = &import_loader_new;
    _ = &import_loader_free;
    _ = &import_loader_push_root;
    _ = &parse_source;
    _ = &infer_type;
    _ = &normalize;
    _ = &normalize_clear_error;
    _ = &normalize_has_error;
    _ = &normalize_get_error;
    _ = &sha256_hex;
    _ = &arena_mod.dhall_arena;
}
