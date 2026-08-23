// arena.zig — port of ../src/arena.c, verbatim in behavior.
// Chunked bump allocator (memory never freed individually; whole arena reset
// per top-level evaluation; 8-byte aligned) + TmpBuf malloc-backed scratch.
// Also exposes the arena as a std.mem.Allocator.
//
// The concrete Arena/Block layout is internal (opaque in dhall.h), so it does
// not need to mirror C; only the BEHAVIOR is ported.

const std = @import("std");
const dhall = @import("dhall.zig");

const BLOCK_SIZE: usize = 64 * 1024;

/// Backing allocator for arena blocks / the Arena itself / TmpBuf scratch.
/// Uses libc malloc (matches the C original). Requires linking libc (-lc).
const backing = std.heap.c_allocator;

const Block = extern struct {
    next: ?*Block,
    used: usize,
    cap: usize,
};

pub const Arena = struct {
    head: ?*Block,

    /// Expose this arena as a std.mem.Allocator. free/resize/remap are no-ops
    /// (bump allocator; memory is only reclaimed by arena_reset).
    pub fn allocator(self: *Arena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &arena_vtable };
    }
};

// Global arena set by main() per top-level evaluation (mirrors `extern Arena
// *dhall_arena` in dhall.h). Implemented here because the concrete Arena lives
// here. `export var` so the C-ABI layer (abi.zig) re-exposes the symbol under
// the exact name dhake's `#include "dhall.h"` expects.
//
// NOTE (dual symbol): `pub export var` emits BOTH a LOCAL binding
// `arena.dhall_arena` AND a GLOBAL `dhall_arena` at the SAME BSS address
// (verified via readelf). All ~200+ internal core references address that one
// location; dhake's `R_X86_64_COPY` relocation on the GLOBAL also lands there.
// A consumer writing `dhall_arena = arena_new();` therefore sets exactly what
// the core reads — BUT only because abi.zig's exported `arena_new()` also does
// `arena_mod.dhall_arena = a` (the LOCAL binding). If the local/global ever
// diverge, arena_new's explicit write is what keeps the core in sync.
// (Arena is opaque on the C side, so exporting a `?*Arena` is a plain pointer.)
pub export var dhall_arena: ?*Arena = null;

fn block_data(b: *Block) [*]u8 {
    return @as([*]u8, @ptrCast(b)) + @sizeOf(Block);
}

fn oom() noreturn {
    std.debug.print("dhall: out of memory\n", .{});
    std.c.exit(3);
}

fn block_new(cap: usize) *Block {
    const total = @sizeOf(Block) + cap;
    const mem = backing.alignedAlloc(u8, std.mem.Alignment.of(Block), total) catch oom();
    const b: *Block = @ptrCast(mem.ptr);
    b.next = null;
    b.used = 0;
    b.cap = cap;
    return b;
}

fn block_free(b: *Block) void {
    const total = @sizeOf(Block) + b.cap;
    backing.free(@as([*]u8, @ptrCast(b))[0..total]);
}

pub fn arena_new() *Arena {
    const a = backing.create(Arena) catch oom();
    a.head = block_new(BLOCK_SIZE);
    return a;
}

pub fn arena_reset(a: *Arena) void {
    var b = a.head;
    while (b) |bb| {
        const nx = bb.next;
        if (nx != null) block_free(bb);
        b = nx;
    }
    if (b == null) {
        a.head = block_new(BLOCK_SIZE);
    } else {
        b.?.used = 0;
        a.head = b;
    }
}

fn arena_alloc_aligned(a: *Arena, n: usize) [*]u8 {
    // align to 8 bytes
    const an = (n +% 7) & ~@as(usize, 7);
    var b = a.head.?;
    if (b.used +% an > b.cap) {
        var cap: usize = BLOCK_SIZE;
        while (cap < an) cap *= 2;
        const nb = block_new(cap);
        nb.next = a.head;
        a.head = nb;
        b = nb;
    }
    const p = block_data(b) + b.used;
    b.used += an;
    return p;
}

pub fn arena_alloc(a: *Arena, n: usize) [*]u8 {
    var m = n;
    if (m == 0) m = 1;
    const p = arena_alloc_aligned(a, m);
    @memset(p[0..m], 0);
    return p;
}

pub fn arena_strndup(a: *Arena, s: []const u8, n: usize) [*:0]u8 {
    const r: [*]u8 = arena_alloc(a, n + 1);
    @memcpy(r[0..n], s[0..n]);
    r[n] = 0;
    return @ptrCast(r);
}

pub fn arena_strdup(a: *Arena, s: []const u8) [*:0]u8 {
    return arena_strndup(a, s, s.len);
}

// ---------------------------------------------------------------------------
// TmpBuf (malloc-backed growable char builder; struct declared in dhall.zig)
// ---------------------------------------------------------------------------
pub fn tmpbuf_init(b: *dhall.TmpBuf) void {
    b.s = null;
    b.len = 0;
    b.cap = 0;
}

fn tmpbuf_grow(b: *dhall.TmpBuf, need: usize) void {
    if (b.len + need + 1 <= b.cap) return;
    var cap: usize = if (b.cap != 0) b.cap else 64;
    while (b.len + need + 1 > cap) cap *= 2;
    const old: []u8 = if (b.s) |p| p[0..b.cap] else &.{};
    const ns = backing.realloc(old, cap) catch oom();
    b.s = ns.ptr;
    b.cap = cap;
}

pub fn tmpbuf_add(b: *dhall.TmpBuf, s: []const u8) void {
    tmpbuf_grow(b, s.len);
    const base = b.s.?;
    @memcpy(base[b.len..][0..s.len], s);
    b.len += s.len;
    base[b.len] = 0;
}

pub fn tmpbuf_addc(b: *dhall.TmpBuf, c: u8) void {
    tmpbuf_grow(b, 1);
    const base = b.s.?;
    base[b.len] = c;
    b.len += 1;
    base[b.len] = 0;
}

/// Copy current contents into the arena, free the malloc scratch, reset. The
/// returned string is arena-resident and NUL-terminated.
pub fn tmpbuf_arena(a: *Arena, b: *dhall.TmpBuf) [*:0]u8 {
    const s: []const u8 = if (b.s) |p| p[0..b.len] else "";
    const r = arena_strdup(a, s);
    if (b.s) |p| backing.free(p[0..b.cap]);
    b.s = null;
    b.len = 0;
    b.cap = 0;
    return r;
}

// ---------------------------------------------------------------------------
// std.mem.Allocator exposure
// ---------------------------------------------------------------------------
const arena_vtable = std.mem.Allocator.VTable{
    .alloc = arenaAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
};

fn arenaAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = alignment;
    _ = ret_addr;
    const a: *Arena = @ptrCast(@alignCast(ctx));
    return arena_alloc_aligned(a, len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "arena alloc + zeroing + reset" {
    const a = arena_new();
    defer backing.destroy(a);

    const p1 = arena_alloc(a, 16);
    @memset(p1[0..16], 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), p1[0]);

    // fresh alloc is zeroed
    const p2 = arena_alloc(a, 8);
    for (p2[0..8]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    // a large allocation that exceeds a block gets its own doubled block
    const big = arena_alloc(a, BLOCK_SIZE + 100);
    for (big[0..(BLOCK_SIZE + 100)]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    arena_reset(a);
    // after reset allocations still work and are zeroed
    const p3 = arena_alloc(a, 32);
    for (p3[0..32]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "arena_strdup / strndup are NUL-terminated" {
    const a = arena_new();
    defer backing.destroy(a);

    const s1 = arena_strdup(a, "hello");
    const span1 = std.mem.span(s1);
    try std.testing.expectEqualStrings("hello", span1);

    const s2 = arena_strndup(a, "abcdef", 3);
    const span2 = std.mem.span(s2);
    try std.testing.expectEqualStrings("abc", span2);
}

test "tmpbuf add / addc / arena round-trip" {
    const a = arena_new();
    defer backing.destroy(a);

    var buf: dhall.TmpBuf = undefined;
    tmpbuf_init(&buf);
    tmpbuf_add(&buf, "abc");
    tmpbuf_addc(&buf, 'd');
    tmpbuf_add(&buf, "efg");
    try std.testing.expectEqual(@as(usize, 7), buf.len);

    const r = tmpbuf_arena(a, &buf);
    try std.testing.expectEqualStrings("abcdefg", std.mem.span(r));
    // scratch was freed and reset
    try std.testing.expectEqual(@as(?[*]u8, null), buf.s);
    try std.testing.expectEqual(@as(usize, 0), buf.len);
    try std.testing.expectEqual(@as(usize, 0), buf.cap);
}

test "arena as std.mem.Allocator" {
    const a = arena_new();
    defer backing.destroy(a);
    const alloc = a.allocator();

    const bytes = alloc.alloc(u8, 100) catch @panic("oom");
    bytes[0] = 42;
    bytes[99] = 7;
    try std.testing.expectEqual(@as(u8, 42), bytes[0]);
    try std.testing.expectEqual(@as(u8, 7), bytes[99]);
    alloc.free(bytes); // no-op, must not crash

    // create/destroy a typed value through the arena allocator
    const p = alloc.create(u64) catch @panic("oom");
    p.* = 123456789;
    try std.testing.expectEqual(@as(u64, 123456789), p.*);
    alloc.destroy(p);
}
