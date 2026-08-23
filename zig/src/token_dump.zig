// token_dump.zig — U2 twin-driver (Zig side). Lexes the file given on argv[1]
// with zig/src/lexer.zig and prints one line per token:
//     <TOKTYPE> <line>:<col> <text>
// Byte-identical to the C twin driver (zig/u2_token_dump.c); the U2 gate diffs
// the two streams across the corpus.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const bignum = @import("bignum.zig");
const lexer = @import("lexer.zig");

const tnames = [_][]const u8{
    "T_EOF",       "T_NAT",       "T_INT",       "T_DBL",       "T_STR_OPEN",
    "T_STR_OPEN_MULTILINE", "T_NAME", "T_LAMBDA",  "T_ARROW",     "T_COLON",
    "T_EQUALS",    "T_COMMA",     "T_DOT",       "T_LPAREN",    "T_RPAREN",
    "T_LBRACE",    "T_RBRACE",    "T_LANGLE",    "T_RANGLE",    "T_LBRACKET",
    "T_RBRACKET",  "T_PLUSPLUS",  "T_PLUS",      "T_MINUS",     "T_STAR",
    "T_LT",        "T_LE",        "T_GT",        "T_GE",        "T_EQEQ",
    "T_NE",        "T_IMPORT",    "T_SHA256",    "T_QMARK",     "T_BAR",
    "T_MERGE",     "T_PREFER",    "T_AND",       "T_OR",        "T_HASH",
    "T_ERROR",
};

const W = struct {
    var written: usize = 0;
    fn out(s: []const u8) void {
        if (s.len == 0) return;
        const n = std.os.linux.write(1, s.ptr, s.len);
        written += n;
    }
};

fn appendInt(comptime T: type, v: T) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    W.out(s);
}

fn appendHex64(v: u64) void {
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>16}", .{v}) catch return;
    W.out(&buf);
}

pub fn main(init: std.process.Init) void {
    const alloc = std.heap.page_allocator;
    const argv = init.minimal.args.vector; // []const [*:0]const u8
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

    var lx: dhall.Lexer = undefined;
    lexer.lexer_init(&lx, srcz, path);

    while (true) {
        const t = lexer.lexer_next(&lx);
        W.out(tnames[@intFromEnum(t.type)]);
        W.out(" ");
        appendInt(u32, @intCast(t.span.line));
        W.out(":");
        appendInt(u32, @intCast(t.span.col));
        W.out(" ");
        switch (t.type) {
            .T_NAT => {
                var scratch: [2]u32 = undefined;
                const B = bignum.const_bignat(t.c, &scratch);
                W.out(std.mem.span(bignum.bignat_to_decimal(&B)));
            },
            .T_INT => {
                var scratch: [2]u32 = undefined;
                const B = bignum.const_bigint(t.c, &scratch);
                W.out(std.mem.span(bignum.bigint_to_decimal(&B)));
            },
            .T_DBL => {
                const bits: u64 = @bitCast(t.c.dbl);
                appendHex64(bits);
            },
            .T_NAME, .T_IMPORT, .T_SHA256 => {
                if (t.name) |n| W.out(std.mem.span(n)) else W.out("<none>");
            },
            .T_ERROR => {
                W.out(std.mem.sliceTo(&lx.err.msg, 0));
            },
            else => W.out("<none>"),
        }
        W.out("\n");
        if (t.type == .T_EOF) break;
    }
}
