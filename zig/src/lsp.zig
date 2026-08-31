// lsp.zig — port of ../src/lsp.c: the Language Server Protocol server for the
// Dhall subset interpreter (MVP). Speaks JSON-RPC 2.0 over stdio with
// Content-Length framing; a single synchronous loop. Reuses the ported
// interpreter core (parse_source / infer_type / normalize / print_term) for
// diagnostics + hover. Output is byte-identical to the C dhall-lsp.com.dbg.
//
// The C build had a wasm variant (LSP_NO_MAIN) driving lsp_handle() directly;
// that layering is not needed here — only the native binary is built, so the
// framing loop lives in main().

const std = @import("std");
const dhall = @import("dhall.zig");
const arena = @import("arena.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const normalize = @import("normalize.zig");
const typecheck = @import("typecheck.zig");
const import_mod = @import("import.zig");
const j = @import("lsp_json.zig");

const alloc = std.heap.c_allocator;

fn oom() noreturn {
    std.debug.print("dhall-lsp: out of memory\n", .{});
    std.c.exit(3);
}

// ---------------------------------------------------------------------------
// Output buffer (global, reset at the top of each message)
// ---------------------------------------------------------------------------
var g_out: std.ArrayList(u8) = undefined;

fn out_add(s: []const u8) void {
    g_out.appendSlice(alloc, s) catch oom();
}

fn write_frame(b: *std.ArrayList(u8)) void {
    var hdr: [64]u8 = undefined;
    const hn = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{b.items.len}) catch unreachable;
    out_add(hn);
    out_add(b.items);
}

// ---------------------------------------------------------------------------
// Document store (heap, persists across messages)
// ---------------------------------------------------------------------------
const Doc = struct { uri: [:0]u8, text: [:0]u8 };

var g_docs: std.ArrayList(Doc) = undefined;

fn dupz(s: []const u8) [:0]u8 {
    const r = alloc.alloc(u8, s.len + 1) catch oom();
    @memcpy(r[0..s.len], s);
    r[s.len] = 0;
    return r[0..s.len :0];
}

fn docs_get(uri: []const u8) ?[:0]const u8 {
    for (g_docs.items) |*d| {
        if (std.mem.eql(u8, d.uri, uri)) return d.text;
    }
    return null;
}

fn docs_set(uri: []const u8, text: []const u8) void {
    for (g_docs.items) |*d| {
        if (std.mem.eql(u8, d.uri, uri)) {
            alloc.free(d.text);
            d.text = dupz(text);
            return;
        }
    }
    g_docs.append(alloc, .{ .uri = dupz(uri), .text = dupz(text) }) catch oom();
}

fn docs_remove(uri: []const u8) void {
    for (g_docs.items, 0..) |*d, i| {
        if (std.mem.eql(u8, d.uri, uri)) {
            alloc.free(d.uri);
            alloc.free(d.text);
            _ = g_docs.swapRemove(i);
            return;
        }
    }
}

// file:///abs -> /abs (no percent-decoding); non-file/untitled -> NULL (CWD)
fn uri_to_path(uri: [:0]const u8) ?[*:0]const u8 {
    if (std.mem.startsWith(u8, uri, "file://")) return uri.ptr + 7;
    return null;
}

// print_term writes to a buffer; capture it as an arena-backed NUL-terminated
// string (arena_reset reclaims it at the next evaluate).
fn term_to_string(t: *dhall.Term) ?[:0]const u8 {
    const a = arena.dhall_arena.?.allocator();
    var list = std.ArrayList(u8).initCapacity(a, 256) catch return null;
    const out = ast.Out{ .b = &list };
    ast.print_term(out, t);
    list.append(a, 0) catch return null;
    return std.mem.sliceTo(list.items.ptr, 0);
}

// Evaluate the document: parse, infer, normalize the type. On success returns
// the normalized type's printed form (arena); on failure fills *diag.
fn evaluate(root_file: ?[*:0]const u8, file: [*:0]const u8, text: [*:0]const u8, diag: *dhall.DhallError) ?[:0]const u8 {
    arena.arena_reset(arena.dhall_arena.?);
    const loader = import_mod.import_loader_new();
    import_mod.import_loader_push_root(loader, root_file);
    var p: dhall.Parser = std.mem.zeroes(dhall.Parser);
    p.loader = loader;
    ast.dhall_error_clear(diag);

    const t = parser.parse_source(&p, text, file, diag);
    if (t == null) {
        import_mod.import_loader_free(loader);
        return null;
    }

    const ty = typecheck.infer_type(&p, t.?, diag);
    if (ty == null) {
        import_mod.import_loader_free(loader);
        return null;
    }

    normalize.normalize_clear_error();
    const nty = normalize.normalize(ty.?);
    if (normalize.normalize_has_error()) {
        diag.* = normalize.normalize_get_error().*;
        import_mod.import_loader_free(loader);
        return null;
    }

    const type_str = term_to_string(nty);
    import_mod.import_loader_free(loader);
    return type_str;
}

fn publish_diagnostics(uri: []const u8, diag: ?*const dhall.DhallError) void {
    var b = std.ArrayList(u8).initCapacity(alloc, 128) catch oom();
    defer b.deinit(alloc);
    j.write_raw(&b, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
    j.write_string(&b, uri);
    j.write_raw(&b, ",\"diagnostics\":[");
    if (diag) |d| {
        const line: i64 = if (d.has_span and d.span.line > 0) @as(i64, d.span.line) - 1 else 0;
        const col: i64 = if (d.has_span and d.span.col > 0) @as(i64, d.span.col) - 1 else 0;
        j.write_raw(&b, "{\"range\":{\"start\":{\"line\":");
        j.write_int(&b, line);
        j.write_raw(&b, ",\"character\":");
        j.write_int(&b, col);
        j.write_raw(&b, "},\"end\":{\"line\":");
        j.write_int(&b, line);
        j.write_raw(&b, ",\"character\":");
        j.write_int(&b, col);
        j.write_raw(&b, "}},\"severity\":1,\"source\":\"dhall-lsp\",\"message\":");
        j.write_string(&b, std.mem.sliceTo(&d.msg, 0));
        j.write_raw(&b, "}");
    }
    j.write_raw(&b, "]}}");
    write_frame(&b);
}

fn handle_doc_change(uri: [:0]const u8, text: [:0]const u8) void {
    docs_set(uri, text);
    var diag: dhall.DhallError = undefined;
    ast.dhall_error_clear(&diag);
    const type_str = evaluate(uri_to_path(uri), uri.ptr, text.ptr, &diag);
    publish_diagnostics(uri, if (type_str == null) &diag else null);
}

fn respond_result(id: ?*j.Json, result_frag: []const u8) void {
    var b = std.ArrayList(u8).initCapacity(alloc, 128) catch oom();
    defer b.deinit(alloc);
    j.write_raw(&b, "{\"jsonrpc\":\"2.0\",\"id\":");
    j.emit(&b, id);
    j.write_raw(&b, ",\"result\":");
    j.write_raw(&b, result_frag);
    j.write_raw(&b, "}");
    write_frame(&b);
}

fn respond_error(id: ?*j.Json, code: i64, msg: []const u8) void {
    var b = std.ArrayList(u8).initCapacity(alloc, 128) catch oom();
    defer b.deinit(alloc);
    j.write_raw(&b, "{\"jsonrpc\":\"2.0\",\"id\":");
    j.emit(&b, id);
    j.write_raw(&b, ",\"error\":{\"code\":");
    j.write_int(&b, code);
    j.write_raw(&b, ",\"message\":");
    j.write_string(&b, msg);
    j.write_raw(&b, "}}");
    write_frame(&b);
}

fn handle_initialize(id: ?*j.Json) void {
    respond_result(id, "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true}}");
}

fn handle_hover(id: ?*j.Json, params: ?*j.Json) void {
    const td = j.json_obj_get(params, "textDocument");
    const uri = if (td) |t| j.json_str(j.json_obj_get(t, "uri")) else null;
    const text = if (uri) |u| docs_get(u) else null;
    if (text == null) {
        respond_result(id, "null");
        return;
    }
    var diag: dhall.DhallError = undefined;
    ast.dhall_error_clear(&diag);
    const type_str = evaluate(uri_to_path(uri.?), uri.?.ptr, text.?.ptr, &diag);
    if (type_str == null) {
        respond_result(id, "null");
        return;
    }
    var b = std.ArrayList(u8).initCapacity(alloc, 128) catch oom();
    defer b.deinit(alloc);
    j.write_raw(&b, "{\"contents\":{\"language\":\"dhall\",\"value\":");
    j.write_string(&b, type_str.?);
    j.write_raw(&b, "}}");
    respond_result(id, b.items);
}

var g_shutdown: bool = false;

// Process one incoming JSON-RPC message. Appends any resulting frame(s) to the
// global output buffer. Returns true when the server should exit (an "exit"
// notification was received).
fn lsp_handle(json: []const u8) bool {
    g_out.clearRetainingCapacity();

    if (arena.dhall_arena == null) arena.dhall_arena = arena.arena_new();

    const root = j.json_parse(json) orelse return false;
    defer j.json_free(root);

    const method = j.json_str(j.json_obj_get(root, "method"));
    const id = j.json_obj_get(root, "id");
    const is_request = id != null and id.?.* != .null_;
    const params = j.json_obj_get(root, "params");

    var done = false;
    if (method != null and std.mem.eql(u8, method.?, "initialize")) {
        handle_initialize(id);
    } else if (method != null and std.mem.eql(u8, method.?, "initialized")) {
        // no reply
    } else if (method != null and std.mem.eql(u8, method.?, "shutdown")) {
        g_shutdown = true;
        respond_result(id, "null");
    } else if (method != null and std.mem.eql(u8, method.?, "exit")) {
        done = true;
    } else if (method != null and std.mem.eql(u8, method.?, "textDocument/didOpen")) {
        const td = j.json_obj_get(params, "textDocument");
        const uri = if (td) |t| j.json_str(j.json_obj_get(t, "uri")) else null;
        const text = if (td) |t| j.json_str(j.json_obj_get(t, "text")) else null;
        if (uri != null and text != null) handle_doc_change(uri.?, text.?);
    } else if (method != null and std.mem.eql(u8, method.?, "textDocument/didChange")) {
        const td = j.json_obj_get(params, "textDocument");
        const uri = if (td) |t| j.json_str(j.json_obj_get(t, "uri")) else null;
        const cc = j.json_obj_get(params, "contentChanges");
        const last = if (cc != null and cc.?.* == .arr and cc.?.arr.len > 0)
            j.json_arr_get(cc, cc.?.arr.len - 1)
        else
            null;
        const text = if (last) |l| j.json_str(j.json_obj_get(l, "text")) else null;
        if (uri != null and text != null) handle_doc_change(uri.?, text.?);
    } else if (method != null and std.mem.eql(u8, method.?, "textDocument/didClose")) {
        const td = j.json_obj_get(params, "textDocument");
        const uri = if (td) |t| j.json_str(j.json_obj_get(t, "uri")) else null;
        if (uri != null) {
            docs_remove(uri.?);
            publish_diagnostics(uri.?, null);
        }
    } else if (method != null and std.mem.eql(u8, method.?, "textDocument/hover")) {
        handle_hover(id, params);
    } else if (is_request) {
        respond_error(id, -32601, "method not found");
    }

    return done;
}

// ---------------------------------------------------------------------------
// Native stdio framing
// ---------------------------------------------------------------------------
var stdin_buf: [8192]u8 = undefined;
var stdin_pos: usize = 0;
var stdin_end: usize = 0;

fn getc() i32 {
    if (stdin_pos >= stdin_end) {
        const n = std.posix.read(0, &stdin_buf) catch return -1;
        if (n == 0) return -1;
        stdin_pos = 0;
        stdin_end = n;
    }
    const c = stdin_buf[stdin_pos];
    stdin_pos += 1;
    return c;
}

// Read one frame: header lines until a blank line, then Content-Length bytes.
fn read_frame() ?[]u8 {
    var content_length: i64 = -1;
    var line: [256]u8 = undefined;
    while (true) {
        var i: usize = 0;
        var c: i32 = undefined;
        while (i + 1 < line.len) {
            c = getc();
            if (c == -1) break;
            if (c == '\n') break;
            line[i] = @intCast(c);
            i += 1;
        }
        if (c == -1 and i == 0) return null;
        line[i] = 0;
        if (i > 0 and line[i - 1] == '\r') {
            i -= 1;
            line[i] = 0;
        }
        if (i == 0) break;
        if (std.mem.startsWith(u8, line[0..i], "Content-Length:")) {
            content_length = std.fmt.parseInt(i64, std.mem.trimStart(u8, line[15..i], " \t"), 10) catch -1;
        }
    }
    if (content_length < 0 or content_length > (1 << 24)) return null;
    const buf = alloc.alloc(u8, @intCast(content_length + 1)) catch return null;
    var got: usize = 0;
    while (got < @as(usize, @intCast(content_length))) {
        const c = getc();
        if (c == -1) {
            alloc.free(buf);
            return null;
        }
        buf[got] = @intCast(c);
        got += 1;
    }
    buf[@intCast(content_length)] = 0;
    return buf[0..@intCast(content_length)];
}

fn write_stdout(s: []const u8) void {
    if (s.len == 0) return;
    var off: usize = 0;
    while (off < s.len) {
        const n = std.os.linux.write(1, s[off..].ptr, s.len - off);
        if (n == 0 or n > s.len - off) break; // 0 / errno-as-usize => stop
        off += n;
    }
}

pub fn main() void {
    arena.dhall_arena = arena.arena_new();
    g_out = std.ArrayList(u8).initCapacity(alloc, 256) catch oom();
    g_docs = std.ArrayList(Doc).initCapacity(alloc, 8) catch oom();

    while (true) {
        const raw = read_frame() orelse break;
        const done = lsp_handle(raw);
        if (g_out.items.len > 0) write_stdout(g_out.items);
        alloc.free(raw);
        if (done) std.c.exit(if (g_shutdown) 0 else 1);
    }
}
