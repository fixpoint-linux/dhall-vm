// ast_dump.zig — U4 twin-driver (Zig side). Byte-identical to u4_ast_dump.c.
// Parses the file given on argv[1] with zig/src/parser.zig, then runs the de
// Bruijn + printer pipeline:
//     === <path>
//     T <print_term(t)>
//     SHIFT <print_term(shift(1,0,t))>
//     SUB <print_term(subst(0, tm_var(7), shift(1,0,t)))>
//     AE <alpha_eq(t,t)> <alpha_eq(s,s)> <alpha_eq(t,sub)>
// On parse error prints:
//     === <path>
//     ERROR <stage> <line>:<col> <msg>
// Modes: <file>, SYNTHETIC (fixed alpha_eq cross-tag tests), DBL (adversarial
// doubles through dbl_fmt). The C-vs-Zig differential gate diffs these streams.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const bignum = @import("bignum.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

const alloc = std.heap.page_allocator;

const W = struct {
    fn out(s: []const u8) void {
        if (s.len == 0) return;
        _ = std.os.linux.write(1, s.ptr, s.len);
    }
};

fn mkBuf() *std.ArrayList(u8) {
    const b = alloc.create(std.ArrayList(u8)) catch unreachable;
    b.* = std.ArrayList(u8).initCapacity(alloc, 4096) catch unreachable;
    return b;
}

fn printLine(tag: []const u8, term: *dhall.Term) []u8 {
    const b = mkBuf();
    var out = ast.Out{ .b = b };
    out.str(tag);
    ast.print_term(out, term);
    b.append(alloc, '\n') catch unreachable;
    const items = b.items;
    alloc.destroy(b);
    return items;
}

fn printAeLine(tag: []const u8, v: usize) []u8 {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}{d}\n", .{ tag, v }) catch unreachable;
    return alloc.dupe(u8, s) catch unreachable;
}

fn run_pipeline(path: [*:0]const u8) usize {
    const fd = std.posix.openat(std.posix.AT.FDCWD, std.mem.span(path), .{ .ACCMODE = .RDONLY }, 0) catch {
        W.out(@ptrCast("=== "));
        W.out(std.mem.span(path));
        W.out(@ptrCast("ERROR open\n"));
        return 0;
    };
    var buf = std.ArrayList(u8).initCapacity(alloc, 4096) catch unreachable;
    defer buf.deinit(alloc);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch break;
        if (n == 0) break;
        buf.appendSlice(alloc, chunk[0..n]) catch break;
    }
    buf.append(alloc, 0) catch return 0;
    const srcz: [*:0]const u8 = @ptrCast(buf.items.ptr);

    arena.dhall_arena = arena.arena_new();
    var p: dhall.Parser = std.mem.zeroes(dhall.Parser);
    p.loader = null;
    var err: dhall.DhallError = undefined;
    ast.dhall_error_clear(&err);
    const t = parser.parse_source(&p, srcz, path, &err);
    if (t == null) {
        W.out(@ptrCast("=== "));
        W.out(std.mem.span(path));
        W.out(@ptrCast("\n"));
        var ebuf: [512]u8 = undefined;
        const es = std.fmt.bufPrint(&ebuf, "ERROR {d} {d}:{d} ", .{ @intFromEnum(err.stage), err.span.line, err.span.col }) catch unreachable;
        W.out(es);
        W.out(std.mem.sliceTo(&err.msg, 0));
        W.out(@ptrCast("\n"));
        return 0;
    }
    W.out(@ptrCast("=== "));
    W.out(std.mem.span(path));
    W.out(@ptrCast("\n"));
    const items1 = printLine("T ", t.?);
    W.out(items1);
    alloc.free(items1);
    const s = ast.shift(1, 0, t.?);
    const items2 = printLine("SHIFT ", s);
    W.out(items2);
    alloc.free(items2);
    const sub = ast.subst(0, ast.tm_var(7), s);
    const items3 = printLine("SUB ", sub);
    W.out(items3);
    alloc.free(items3);
    var aebuf: [64]u8 = undefined;
    const aes = std.fmt.bufPrint(&aebuf, "AE {d} {d} {d}\n", .{
        @intFromBool(ast.alpha_eq(t.?, t.?)),
        @intFromBool(ast.alpha_eq(s, s)),
        @intFromBool(ast.alpha_eq(t.?, sub)),
    }) catch unreachable;
    W.out(aes);
    return 0;
}

fn run_synthetic() usize {
    arena.dhall_arena = arena.arena_new();
    W.out(@ptrCast("=== SYNTHETIC\n"));
    const rl0 = ast.tm_record_lit(null, 0);
    const rt0 = ast.tm_record_type(null, 0);
    const ul0 = ast.tm_union_lit(null, 0);
    const ut0 = ast.tm_union_type(null, 0);
    const f1 = ast.field_new("a", null, ast.tm_nat(1));
    const f2 = ast.field_new("a", ast.tm_nat(1), null);
    const rl1 = ast.tm_record_lit(f1[0..1].ptr, 1);
    const rt1 = ast.tm_record_type(f2[0..1].ptr, 1);
    const uA = ast.field_new("a", null, ast.tm_nat(1));
    const uB = ast.field_new("a", ast.tm_nat(1), null);
    const ul1 = ast.tm_union_lit(uA[0..1].ptr, 1);
    const ut1 = ast.tm_union_type(uB[0..1].ptr, 1);
    const lam_a = ast.tm_lam(ast.tm_type(), ast.tm_var(0));
    const lam_b = ast.tm_lam(ast.tm_type(), ast.tm_var(1));
    const r = printAeLine("RLRT ", @intFromBool(ast.alpha_eq(rl0, rt0))); W.out(r); alloc.free(r);
    const r2 = printAeLine("RTRL ", @intFromBool(ast.alpha_eq(rt0, rl0))); W.out(r2); alloc.free(r2);
    const r3 = printAeLine("ULUT ", @intFromBool(ast.alpha_eq(ul0, ut0))); W.out(r3); alloc.free(r3);
    const r4 = printAeLine("UTUL ", @intFromBool(ast.alpha_eq(ut0, ul0))); W.out(r4); alloc.free(r4);
    const r5 = printAeLine("RL1RT1 ", @intFromBool(ast.alpha_eq(rl1, rt1))); W.out(r5); alloc.free(r5);
    const r6 = printAeLine("RL1RL1 ", @intFromBool(ast.alpha_eq(rl1, rl1))); W.out(r6); alloc.free(r6);
    const r7 = printAeLine("UL1UT1 ", @intFromBool(ast.alpha_eq(ul1, ut1))); W.out(r7); alloc.free(r7);
    const r8 = printAeLine("LAMAA ", @intFromBool(ast.alpha_eq(lam_a, lam_a))); W.out(r8); alloc.free(r8);
    const r9 = printAeLine("LAMAB ", @intFromBool(ast.alpha_eq(lam_a, lam_b))); W.out(r9); alloc.free(r9);
    return 0;
}

fn run_dbl() usize {
    W.out(@ptrCast("=== DBL\n"));
    const dvals = [_]f64{
        1e300, 5e-324, 0.1, -0.0, 0.0, 1.0, -1.0, 3.141592653589793, 1e-7,
        1e21, 123456789.123, 2.5e-10, 100.0, 1e15, 1.7976931348623157e308,
        2.2250738585072014e-308, 6.0, -0.5, 1.2345678901234567, 9007199254740993.0,
    };
    for (dvals, 0..) |d, i| {
        var b: [64]u8 = undefined;
        ast.dbl_fmt(&b, b.len, d);
        var lbuf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&lbuf, "DBL{d} {s}\n", .{ i, std.mem.sliceTo(&b, 0) }) catch unreachable;
        W.out(s);
    }
    var b: [64]u8 = undefined;
    var lbuf: [128]u8 = undefined;
    ast.dbl_fmt(&b, b.len, std.math.nan(f64));
    const s1 = std.fmt.bufPrint(&lbuf, "NAN {s}\n", .{std.mem.sliceTo(&b, 0)}) catch unreachable;
    W.out(s1);
    ast.dbl_fmt(&b, b.len, std.math.inf(f64));
    const s2 = std.fmt.bufPrint(&lbuf, "INF {s}\n", .{std.mem.sliceTo(&b, 0)}) catch unreachable;
    W.out(s2);
    ast.dbl_fmt(&b, b.len, -std.math.inf(f64));
    const s3 = std.fmt.bufPrint(&lbuf, "NINF {s}\n", .{std.mem.sliceTo(&b, 0)}) catch unreachable;
    W.out(s3);
    return 0;
}

fn dbgLine(tag: []const u8, term: *dhall.Term) []u8 {
    return printLine(tag, term);
}

fn run_debruijn() usize {
    arena.dhall_arena = arena.arena_new();
    W.out(@ptrCast("=== DEBRUIJN\n"));
    const A = ast.tm_lam(ast.tm_type(), ast.tm_lam(ast.tm_type(), ast.tm_var(2)));
    const r1 = dbgLine("A ", A); W.out(r1); alloc.free(r1);
    const r2 = dbgLine("A1 ", ast.shift(1, 0, A)); W.out(r2); alloc.free(r2);
    const r3 = dbgLine("A2 ", ast.shift(2, 0, A)); W.out(r3); alloc.free(r3);
    const B = ast.tm_app(ast.tm_var(3), ast.tm_var(1));
    const r4 = dbgLine("B ", B); W.out(r4); alloc.free(r4);
    const r5 = dbgLine("BS ", ast.subst(1, ast.tm_var(9), B)); W.out(r5); alloc.free(r5);
    const C = ast.tm_lam(ast.tm_type(), ast.tm_var(0));
    const r6 = dbgLine("C ", C); W.out(r6); alloc.free(r6);
    const r7 = dbgLine("CS ", ast.subst(0, ast.tm_var(5), C)); W.out(r7); alloc.free(r7);
    const D = ast.tm_lam(ast.tm_type(), ast.tm_var(1));
    const r8 = dbgLine("D ", D); W.out(r8); alloc.free(r8);
    const r9 = dbgLine("DS ", ast.subst(0, ast.tm_var(5), D)); W.out(r9); alloc.free(r9);
    const E = ast.tm_lam(ast.tm_type(), ast.tm_lam(ast.tm_type(), ast.tm_var(1)));
    const r10 = dbgLine("E ", E); W.out(r10); alloc.free(r10);
    const r11 = dbgLine("E1 ", ast.shift(1, 0, E)); W.out(r11); alloc.free(r11);
    const r12 = printAeLine("EAE ", @intFromBool(ast.alpha_eq(E, ast.shift(1, 0, E)))); W.out(r12); alloc.free(r12);
    const r13 = printAeLine("EAE2 ", @intFromBool(ast.alpha_eq(ast.shift(1, 0, E), ast.shift(1, 0, E)))); W.out(r13); alloc.free(r13);
    return 0;
}

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    if (argv.len < 2) return;
    const mode = argv[1];
    if (std.mem.eql(u8, std.mem.span(mode), "SYNTHETIC")) {
        _ = run_synthetic();
        return;
    }
    if (std.mem.eql(u8, std.mem.span(mode), "DBL")) {
        _ = run_dbl();
        return;
    }
    if (std.mem.eql(u8, std.mem.span(mode), "DEBRUIJN")) {
        _ = run_debruijn();
        return;
    }
    _ = run_pipeline(mode);
}
