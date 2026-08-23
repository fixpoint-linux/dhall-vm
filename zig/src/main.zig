// main.zig — CLI entry point (U5: `normalize` mode; the first Zig CLI binary).
// Mirrors ../src/main.c VERBATIM in behavior for the `normalize` mode:
//     dhall normalize [file|-]
// Reads source from stdin or a file. Prints the normal form (print_term + '\n').
// Exit codes: 0 ok, 1 type/normalize error, 2 parse/lex error, 3 internal/IO.
//
// Imports are NOT wired yet (they land in import.zig, U8); the parser runs with
// loader == null so any import errors out ("imports are not available"), exactly
// as the U3/U4 twin drivers do. The U5 differential therefore covers the
// no-import corpora (tests/cases/*.dhall, import-free examples); the
// tests/cases/imports/** corpus joins when imports land at U8.

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const normalize = @import("normalize.zig");
const typecheck = @import("typecheck.zig");
const serialize = @import("serialize.zig");
const import_mod = @import("import.zig");

const alloc = std.heap.page_allocator;

fn writeAll(fd: i32, s: []const u8) void {
    if (s.len == 0) return;
    _ = std.os.linux.write(fd, s.ptr, s.len);
}

fn print_error(e: *const dhall.DhallError) void {
    var line = std.ArrayList(u8).initCapacity(alloc, 128) catch unreachable;
    defer line.deinit(alloc);
    line.appendSlice(alloc, "Error: ") catch unreachable;
    line.appendSlice(alloc, std.mem.sliceTo(&e.msg, 0)) catch unreachable;
    if (e.has_span) {
        if (e.span.file) |f| {
            line.appendSlice(alloc, " (at ") catch unreachable;
            line.appendSlice(alloc, std.mem.span(f)) catch unreachable;
            var nbuf: [24]u8 = undefined;
            const l = std.fmt.bufPrint(&nbuf, ":{d}:{d}", .{ e.span.line, e.span.col }) catch unreachable;
            line.appendSlice(alloc, l) catch unreachable;
            line.appendSlice(alloc, ")") catch unreachable;
        } else {
            var nbuf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&nbuf, " (at line {d}, col {d})", .{ e.span.line, e.span.col }) catch unreachable;
            line.appendSlice(alloc, s) catch unreachable;
        }
    }
    line.append(alloc, '\n') catch unreachable;
    writeAll(2, line.items);
}

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;

    if (argv.len >= 2 and (std.mem.eql(u8, std.mem.span(argv[1]), "--help") or std.mem.eql(u8, std.mem.span(argv[1]), "-h"))) {
        usage();
        return;
    }
    if (argv.len >= 2 and (std.mem.eql(u8, std.mem.span(argv[1]), "--version") or std.mem.eql(u8, std.mem.span(argv[1]), "-V"))) {
        var b: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "dhall-c {s}\n", .{dhall.DHALL_VERSION}) catch unreachable;
        writeAll(1, s);
        return;
    }
    if (argv.len < 2) {
        var b: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "usage: {s} <mode> [file]  (run '{s} --help' for details)\n", .{ std.mem.span(argv[0]), std.mem.span(argv[0]) }) catch unreachable;
        writeAll(2, s);
        std.c.exit(3);
    }
    const mode = argv[1];
    const want_normalize = std.mem.eql(u8, std.mem.span(mode), "normalize");
    const want_typecheck = std.mem.eql(u8, std.mem.span(mode), "typecheck");
    const want_json = std.mem.eql(u8, std.mem.span(mode), "to-json");
    const want_toml = std.mem.eql(u8, std.mem.span(mode), "to-toml");
    const want_yaml = std.mem.eql(u8, std.mem.span(mode), "to-yaml");
    if (!want_normalize and !want_typecheck and !want_json and !want_toml and !want_yaml) {
        var b: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "Error: unknown mode '{s}' (expected typecheck|normalize|to-json|to-toml|to-yaml)\n", .{std.mem.span(mode)}) catch unreachable;
        writeAll(2, s);
        std.c.exit(3);
    }

    // read input (stdin or file)
    var fd: i32 = 0;
    var close_fd = false;
    var src_file: ?[*:0]const u8 = null;
    if (argv.len >= 3 and !std.mem.eql(u8, std.mem.span(argv[2]), "-")) {
        const path = std.mem.span(argv[2]);
        fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch {
            var b: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "Error: cannot open file '{s}'\n", .{path}) catch unreachable;
            writeAll(2, s);
            std.c.exit(3);
        };
        close_fd = true;
        src_file = argv[2];
    }

    var buf = std.ArrayList(u8).initCapacity(alloc, 65536) catch unreachable;
    defer buf.deinit(alloc);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch break;
        if (n == 0) break;
        buf.appendSlice(alloc, chunk[0..n]) catch break;
    }
    if (close_fd) _ = std.os.linux.close(fd);
    buf.append(alloc, 0) catch return;
    const srcz: [*:0]const u8 = @ptrCast(buf.items.ptr);

    // per-evaluation arena
    if (arena.dhall_arena == null) arena.dhall_arena = arena.arena_new();
    arena.arena_reset(arena.dhall_arena.?);

    // import loader (mirrors main.c:109-110)
    const loader = import_mod.import_loader_new();
    import_mod.import_loader_push_root(loader, src_file);

    var p: dhall.Parser = std.mem.zeroes(dhall.Parser);
    p.loader = loader;
    var err: dhall.DhallError = undefined;
    ast.dhall_error_clear(&err);
    const t = parser.parse_source(&p, srcz, src_file, &err);
    if (t == null) {
        import_mod.import_loader_free(loader);
        print_error(&err);
        std.c.exit(ast.dhall_error_exit(&err));
    }

    if (want_typecheck) {
        const ty = typecheck.infer_type(&p, t.?, &err);
        if (ty == null) {
            import_mod.import_loader_free(loader);
            print_error(&err);
            std.c.exit(ast.dhall_error_exit(&err));
        }
        normalize.normalize_clear_error();
        const nty = normalize.normalize(ty.?);
        if (normalize.normalize_has_error()) {
            err = normalize.normalize_get_error().*;
            import_mod.import_loader_free(loader);
            print_error(&err);
            std.c.exit(ast.dhall_error_exit(&err));
        }
        // print inferred type to stdout
        var tob = std.ArrayList(u8).initCapacity(alloc, 4096) catch unreachable;
        defer tob.deinit(alloc);
        const tout = ast.Out{ .b = &tob };
        ast.print_term(tout, nty);
        tob.append(alloc, '\n') catch return;
        import_mod.import_loader_free(loader);
        writeAll(1, tob.items);
        return;
    }

    normalize.normalize_clear_error();
    const nf = normalize.normalize(t.?);
    if (normalize.normalize_has_error()) {
        err = normalize.normalize_get_error().*;
        import_mod.import_loader_free(loader);
        print_error(&err);
        std.c.exit(ast.dhall_error_exit(&err));
    }

    var ob = std.ArrayList(u8).initCapacity(alloc, 4096) catch unreachable;
    defer ob.deinit(alloc);
    const out = ast.Out{ .b = &ob };

    if (want_normalize) {
        // print normal form to stdout
        ast.print_term(out, nf);
        ob.append(alloc, '\n') catch return;
        import_mod.import_loader_free(loader);
        writeAll(1, ob.items);
        return;
    }

    // serializers: to-json / to-toml / to-yaml
    const ok = if (want_json)
        serialize.term_to_json(out, nf, &err)
    else if (want_toml)
        serialize.term_to_toml(out, nf, &err)
    else
        serialize.term_to_yaml(out, nf, &err);
    if (!ok) {
        import_mod.import_loader_free(loader);
        print_error(&err);
        std.c.exit(ast.dhall_error_exit(&err));
    }
    import_mod.import_loader_free(loader);
    if (want_json) ob.append(alloc, '\n') catch return; // JSON is single-line; serializer adds no trailing newline
    writeAll(1, ob.items);
}

fn usage() void {
    const text =
        \\dhall-c — a Dhall configuration-language subset interpreter
        \\
        \\Usage:
        \\  dhall <mode> [file]
        \\  dhall --help | -h
        \\  dhall --version | -V
        \\
        \\Modes:
        \\  typecheck   infer and print the type of the expression
        \\  normalize   print the normal form
        \\  to-json     evaluate to JSON
        \\  to-toml     evaluate to TOML (top level must be a record)
        \\  to-yaml     evaluate to YAML
        \\
        \\file is a path, or "-" (default) to read from stdin.
        \\
        \\Exit codes: 0 ok, 1 type error, 2 parse/lex error, 3 internal/IO/serialize error.
        \\
        \\Examples:
        \\  dhall typecheck config.dhall
        \\  dhall to-json config.dhall
        \\  echo "{ a = 1, b = True }" | dhall to-yaml
        \\
    ;
    writeAll(1, text);
}
