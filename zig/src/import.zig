// import.zig — port of ../src/import.c, verbatim in behavior.
//
// Scope: local file imports (./x, ../y, /abs), env:NAME (resolved to a Text
// literal via getenv), the always-absent `missing` import, http:// URL imports
// (SSRF-guarded fetch in http.zig), and a sha256:<hex> integrity check.
//
// DEVIATION from real Dhall: the sha256:<hex> hash is computed over the RAW
// SOURCE TEXT (file bytes / env-var value / URL response body), NOT the CBOR
// encoding of the beta-normal form. The hash is lowercase base16 hex (64
// chars), not base64. A hash mismatch is a HARD error (ERR_IO, not recoverable
// by `?`); an ABSENT import (`missing`, file-not-found, env-unset,
// URL-unreachable-or-blocked) is reported with stage ERR_MISSING, which the
// parser's `?` catches.
//
// Imports are inlined AT PARSE TIME: import_resolve() parses the referenced
// file with a FRESH name stack (imports are closed) into the SAME global arena.

const std = @import("std");
const dhall = @import("dhall.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const sha256 = @import("sha256.zig");
const http = @import("http.zig");

const c_alloc = std.heap.c_allocator;

const PATH_BUF = 4096;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

// The concrete loader behind the opaque dhall.ImportLoader. ArrayLists use
// c_allocator (malloc) mirroring the C calloc/realloc.
const Loader = struct {
    keys: std.ArrayList([:0]u8), // import chain: canonical keys (cycle detection)
    dirs: std.ArrayList([]u8), // dir stack (parallel to keys +1 root entry)
    ckeys: std.ArrayList([]u8), // cache: canonical key -> parsed term
    cterms: std.ArrayList(?*dhall.Term),
    depth: c_int, // import chain depth
};

fn oom() noreturn {
    @panic("dhall: out of memory");
}

fn toLoader(lp: ?*dhall.ImportLoader) *Loader {
    return @ptrCast(@alignCast(lp.?));
}

fn xstrdup(s: []const u8) [:0]u8 {
    return c_alloc.dupeZ(u8, s) catch oom();
}

// dirname: everything up to (not including) the last '/'; "." if none
fn path_dirname(path: []const u8) []u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        if (slash == 0) return c_alloc.dupe(u8, "/") catch oom();
        return c_alloc.dupe(u8, path[0..slash]) catch oom();
    }
    return c_alloc.dupe(u8, ".") catch oom();
}

// join base dir + spec (unless spec is absolute)
fn join_path(base: []const u8, spec: []const u8) [:0]u8 {
    if (spec.len > 0 and spec[0] == '/') return xstrdup(spec);
    const r = c_alloc.allocSentinel(u8, base.len + 1 + spec.len, 0) catch oom();
    @memcpy(r[0..base.len], base);
    r[base.len] = '/';
    @memcpy(r[base.len + 1 ..], spec);
    return r;
}

fn read_whole_file(path: []const u8) ?[:0]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);
    var buf = std.ArrayList(u8).initCapacity(c_alloc, 4096) catch return null;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch return null;
        if (n == 0) break;
        buf.appendSlice(c_alloc, chunk[0..n]) catch return null;
    }
    buf.append(c_alloc, 0) catch return null; // NUL-terminate
    const owned = buf.toOwnedSlice(c_alloc) catch return null;
    // owned has length content+1; the last byte is the NUL we appended.
    return owned[0 .. owned.len - 1 :0];
}

pub fn import_loader_new() ?*dhall.ImportLoader {
    const l = c_alloc.create(Loader) catch oom();
    l.* = .{
        .keys = std.ArrayList([:0]u8).empty,
        .dirs = std.ArrayList([]u8).empty,
        .ckeys = std.ArrayList([]u8).empty,
        .cterms = std.ArrayList(?*dhall.Term).empty,
        .depth = 0,
    };
    return @ptrCast(l);
}

pub fn import_loader_free(lp: ?*dhall.ImportLoader) void {
    const l = toLoader(lp);
    for (l.keys.items) |k| c_alloc.free(k);
    for (l.dirs.items) |d| c_alloc.free(d);
    for (l.ckeys.items) |k| c_alloc.free(k);
    l.keys.deinit(c_alloc);
    l.dirs.deinit(c_alloc);
    l.ckeys.deinit(c_alloc);
    l.cterms.deinit(c_alloc);
    c_alloc.destroy(l);
}

pub fn import_loader_push_root(lp: ?*dhall.ImportLoader, root_file: ?[*:0]const u8) void {
    const l = toLoader(lp);
    if (root_file) |rf| {
        var canonical_buf: [PATH_BUF:0]u8 = undefined;
        if (realpath(rf, &canonical_buf)) |canon| {
            // push root key so a self-import is detected as a cycle
            const cspan = std.mem.span(canon);
            l.keys.append(c_alloc, xstrdup(cspan)) catch oom();
            l.dirs.append(c_alloc, path_dirname(cspan)) catch oom();
            return;
        }
        // root file does not exist yet (e.g. an unsaved LSP buffer): still
        // resolve relative imports against the literal path's directory.
        l.dirs.append(c_alloc, path_dirname(std.mem.span(rf))) catch oom();
        return;
    }
    // stdin (no root file): relative imports resolve against CWD
    l.dirs.append(c_alloc, c_alloc.dupe(u8, ".") catch oom()) catch oom();
}

// http:// URL import: fetch (SSRF-guarded), sha256-verify, parse, cache.
fn import_resolve_url(lp: ?*dhall.ImportLoader, spec: [*:0]const u8, hash_hex: ?[*:0]const u8, p: *dhall.Parser, err: *dhall.DhallError) ?*dhall.Term {
    const l = toLoader(lp);
    const spec_span = std.mem.span(spec);
    // sha256 REQUIRED for remote, checked BEFORE any fetch (offline-deterministic,
    // fail-closed: an un-hashed URL import is a HARD error, not recoverable).
    const hh_span = if (hash_hex) |h| std.mem.span(h) else {
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "Import of remote URL requires a sha256: hash", .{});
        return null;
    };

    // cycle detection keyed on the URL spec
    for (l.keys.items) |k| {
        if (std.mem.eql(u8, k, spec_span)) {
            ast.dhall_error_set(err, .ERR_TYPE, dhall.SPAN_NONE, "import cycle", .{});
            return null;
        }
    }

    // cache key = spec + optional hash
    var ckey = xstrdup(spec_span);
    {
        const cl = ckey.len;
        const k = c_alloc.allocSentinel(u8, cl + 1 + hh_span.len, 0) catch oom();
        @memcpy(k[0..cl], ckey[0..cl]);
        k[cl] = ' ';
        @memcpy(k[cl + 1 ..], hh_span);
        c_alloc.free(ckey);
        ckey = k;
    }
    for (l.ckeys.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, ckey)) {
            c_alloc.free(ckey);
            return l.cterms.items[i];
        }
    }

    // depth guard
    if (l.depth >= dhall.MAX_IMPORT_DEPTH) {
        ast.dhall_error_set(err, .ERR_PARSE, dhall.SPAN_NONE, "import depth exceeded", .{});
        c_alloc.free(ckey);
        return null;
    }

    // fetch (SSRF-guarded; DNS/connect/timeout/blocked/4xx/5xx => ERR_MISSING)
    var body: ?[]u8 = null;
    var blen: usize = 0;
    const st = http.http_fetch(spec_span, &body, &blen, err);
    if (st != http.HTTP_OK) {
        c_alloc.free(ckey);
        if (body) |b| c_alloc.free(b);
        return null; // http_fetch already set *err (ERR_MISSING or ERR_IO)
    }

    // integrity check over the RAW BODY
    var got: [65]u8 = undefined;
    sha256.sha256_hex(body.?[0..blen], &got);
    const gspan = std.mem.sliceTo(&got, 0);
    if (!std.mem.eql(u8, gspan, hh_span)) {
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "sha256 mismatch for '{s}': expected {s}, got {s}", .{ spec_span, hh_span, gspan });
        c_alloc.free(body.?);
        c_alloc.free(ckey);
        return null;
    }

    // push chain key + URL dir (so nested relative imports resolve against it)
    l.keys.append(c_alloc, xstrdup(spec_span)) catch oom();
    const dir = http.url_dirname(spec_span) orelse xstrdup(spec_span); // OOM fallback: never push a NULL dir
    l.dirs.append(c_alloc, dir) catch oom();
    l.depth += 1;

    // parse with a FRESH name stack; inherit the global expression-nesting
    // depth so total recursion stays bounded across files.
    var sub: dhall.Parser = std.mem.zeroes(dhall.Parser);
    sub.loader = lp;
    sub.depth = p.depth;
    var sub_err: dhall.DhallError = undefined;
    ast.dhall_error_clear(&sub_err);
    const t = parser.parse_source(&sub, @ptrCast(body.?.ptr), spec, &sub_err);
    c_alloc.free(body.?);

    l.depth -= 1;
    c_alloc.free(l.keys.pop().?);
    c_alloc.free(l.dirs.pop().?);

    if (t == null) {
        c_alloc.free(ckey);
        err.* = sub_err;
        return null;
    }

    // cache the parsed term
    l.ckeys.append(c_alloc, ckey) catch oom();
    l.cterms.append(c_alloc, t) catch oom();
    return t;
}

pub fn import_resolve(lp: ?*dhall.ImportLoader, spec: ?[*:0]const u8, hash_hex: ?[*:0]const u8, p: *dhall.Parser, err: *dhall.DhallError) ?*dhall.Term {
    const l = toLoader(lp);
    ast.dhall_error_clear(err);
    const spec_c = spec orelse return null;
    const spec_span = std.mem.span(spec_c);

    // `missing` import: always absent (no cache lookup; any hash ignored).
    if (std.mem.eql(u8, spec_span, "missing")) {
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import", .{});
        return null;
    }

    // URL import (http://, https://, or any other scheme:// for a clear error)
    if (std.mem.indexOf(u8, spec_span, "://")) |s_idx| {
        const slen = s_idx;
        if (slen == 4 and std.mem.eql(u8, spec_span[0..4], "http"))
            return import_resolve_url(lp, spec_c, hash_hex, p, err);
        if (slen == 5 and std.mem.eql(u8, spec_span[0..5], "https")) {
            ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "https:// imports are not supported in this build (no TLS)", .{});
            return null;
        }
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "unsupported URL scheme '{s}'", .{spec_span[0..slen]});
        return null;
    }

    // env:NAME -> Text literal (value NOT parsed as Dhall source)
    if (std.mem.startsWith(u8, spec_span, "env:")) {
        // remote-origin guard: a document fetched from a URL must not read
        // local environment variables (real Dhall forbids remote -> local)
        if (l.dirs.items.len > 0 and std.mem.indexOf(u8, l.dirs.items[l.dirs.items.len - 1], "://") != null) {
            ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "environment imports are not allowed inside a remote (URL) import", .{});
            return null;
        }
        const name = spec_span[4..];
        // spec is NUL-terminated, so spec+4 is NUL-terminated for getenv
        const val = getenv(spec_c + 4);
        if (val == null) {
            ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "environment variable '{s}' not set", .{name});
            return null;
        }
        const vspan = std.mem.span(val.?);
        if (hash_hex) |hh| {
            const hh_span = std.mem.span(hh);
            var got: [65]u8 = undefined;
            sha256.sha256_hex(vspan, &got);
            if (!std.mem.eql(u8, std.mem.sliceTo(&got, 0), hh_span)) {
                ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "sha256 mismatch for 'env:{s}'", .{name});
                return null;
            }
        }
        return ast.tm_text_lit(vspan);
    }

    // file import: resolve against the current file's directory
    const base = if (l.dirs.items.len > 0) l.dirs.items[l.dirs.items.len - 1] else ".";
    // remote-origin guard: an ABSOLUTE local path inside a URL document must
    // not read the local filesystem.
    if (spec_span.len > 0 and spec_span[0] == '/' and std.mem.indexOf(u8, base, "://") != null) {
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "local file imports are not allowed inside a remote (URL) import", .{});
        return null;
    }
    // nested relative import inside a URL document: resolve against the URL
    // directory (never against the local CWD).
    if (std.mem.indexOf(u8, base, "://") != null and (spec_span.len == 0 or spec_span[0] != '/')) {
        const full = http.url_join(base, spec_span) orelse {
            ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "cannot resolve relative import '{s}' inside a URL import", .{spec_span});
            return null;
        };
        const t = import_resolve_url(lp, full.ptr, hash_hex, p, err);
        c_alloc.free(full);
        return t;
    }
    const path = join_path(base, spec_span);
    var canonical_buf: [PATH_BUF:0]u8 = undefined;
    if (realpath(path.ptr, &canonical_buf) == null) {
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "cannot open file '{s}'", .{spec_span});
        c_alloc.free(path);
        return null;
    }
    c_alloc.free(path);
    var clen: usize = 0;
    while (clen < PATH_BUF and canonical_buf[clen] != 0) clen += 1;
    const canonical = canonical_buf[0..clen];

    // cycle detection
    for (l.keys.items) |k| {
        if (std.mem.eql(u8, k, canonical)) {
            ast.dhall_error_set(err, .ERR_TYPE, dhall.SPAN_NONE, "import cycle", .{});
            return null;
        }
    }

    // cache key = canonical path + optional hash
    var ckey = xstrdup(canonical);
    if (hash_hex) |hh| {
        const hh_span = std.mem.span(hh);
        const cl = ckey.len;
        const k = c_alloc.allocSentinel(u8, cl + 1 + hh_span.len, 0) catch oom();
        @memcpy(k[0..cl], ckey[0..cl]);
        k[cl] = ' ';
        @memcpy(k[cl + 1 ..], hh_span);
        c_alloc.free(ckey);
        ckey = k;
    }

    // cache hit
    for (l.ckeys.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, ckey)) {
            c_alloc.free(ckey);
            return l.cterms.items[i];
        }
    }

    // depth guard
    if (l.depth >= dhall.MAX_IMPORT_DEPTH) {
        ast.dhall_error_set(err, .ERR_PARSE, dhall.SPAN_NONE, "import depth exceeded", .{});
        c_alloc.free(ckey);
        return null;
    }

    const src = read_whole_file(canonical) orelse {
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "cannot open file '{s}'", .{spec_span});
        c_alloc.free(ckey);
        return null;
    };

    // integrity check over the RAW SOURCE TEXT
    if (hash_hex) |hh| {
        const hh_span = std.mem.span(hh);
        var got: [65]u8 = undefined;
        sha256.sha256_hex(src[0..src.len], &got);
        const gspan = std.mem.sliceTo(&got, 0);
        if (!std.mem.eql(u8, gspan, hh_span)) {
            ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "sha256 mismatch for '{s}': expected {s}, got {s}", .{ spec_span, hh_span, gspan });
            c_alloc.free(src);
            c_alloc.free(ckey);
            return null;
        }
    }

    // push chain (key + dir)
    l.keys.append(c_alloc, xstrdup(canonical)) catch oom();
    l.dirs.append(c_alloc, path_dirname(canonical)) catch oom();
    l.depth += 1;

    // parse with a FRESH name stack (imports are closed); inherit the global
    // expression-nesting depth so total recursion stays bounded across files.
    var sub: dhall.Parser = std.mem.zeroes(dhall.Parser);
    sub.loader = lp;
    sub.depth = p.depth;
    var sub_err: dhall.DhallError = undefined;
    ast.dhall_error_clear(&sub_err);
    const t = parser.parse_source(&sub, src.ptr, &canonical_buf, &sub_err);
    c_alloc.free(src);

    l.depth -= 1;
    c_alloc.free(l.keys.pop().?);
    c_alloc.free(l.dirs.pop().?);

    if (t == null) {
        c_alloc.free(ckey);
        err.* = sub_err;
        return null;
    }

    // cache the parsed term
    l.ckeys.append(c_alloc, ckey) catch oom();
    l.cterms.append(c_alloc, t) catch oom();
    return t;
}
