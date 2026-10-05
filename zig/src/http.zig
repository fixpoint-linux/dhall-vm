// http.zig — port of ../src/http.c (native fetch + URL string helpers),
// verbatim in behavior.
//
// Security model (see README "Imports — URL imports"):
//   - http:// ONLY. https:// and any other scheme are rejected (no TLS).
//   - sha256 is REQUIRED for remote imports and checked by import.zig BEFORE
//     this code runs, so a URL reaching here always has an integrity hash.
//   - SSRF: resolve with getaddrinfo(AF_UNSPEC), reject the connection if ANY
//     resolved address is private/loopback/link-local/reserved (DNS-rebinding
//     defense); connect ONLY to a validated sockaddr, never the hostname string.
//   - Redirects 301/302/303/307/308 are followed up to a cap (5), re-validating
//     scheme + resolve + SSRF on every hop; redirect to non-http is a HARD error.
//   - Caps: 16 MiB body, 10 s per-poll timeout, 30 s overall monotonic deadline.
//   - No request body / cookies / credentials; only GET + Host header.
//
// Error model: an unreachable/blocked/timeout/4xx-5xx/redirect-cap-exceeded URL
// is ABSENT (recoverable by `?` => ERR_MISSING); a malformed response, an
// oversized body, or an unsupported redirect scheme is HARD (ERR_IO).

const std = @import("std");
const dhall = @import("dhall.zig");
const ast = @import("ast.zig");
const ssrf = @import("ssrf.zig");

const c_alloc = std.heap.c_allocator;

const HTTP_MAX_BODY: usize = 16 * 1024 * 1024; // 16 MiB body cap
const HTTP_MAX_HEADER: usize = 64 * 1024; // header allowance
const HTTP_MAX_RAW: usize = HTTP_MAX_BODY + HTTP_MAX_HEADER;
const HTTP_POLL_TIMEOUT_MS: c_int = 10000; // 10 s per poll
const HTTP_DEADLINE_MS: i64 = 30000; // 30 s overall
const HTTP_MAX_REDIRECTS: c_int = 5;
const HTTP_MAX_URL: usize = 4096; // sanity cap on URL length

pub const HTTP_OK: c_int = 0;
pub const HTTP_ABSENT: c_int = 1;
pub const HTTP_HARD: c_int = 2;

// ---- libc declarations (not exposed by std.c) ----
extern "c" fn socket(family: c_int, type_: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const std.c.sockaddr, len: c_uint) c_int;
extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn clock_gettime(clockid: c_int, tp: *Timespec) c_int;
extern "c" fn getsockopt(fd: c_int, level: c_int, optname: c_int, optval: *c_int, optlen: *c_uint) c_int;

const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;

const Timespec = extern struct { tv_sec: i64, tv_nsec: i64 };

const AF_UNSPEC: c_int = 0;
const SOCK_STREAM: c_int = 1;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x800;
const EINTR: c_int = 4;
const EAGAIN: c_int = 11;
const EWOULDBLOCK: c_int = 11;
const EINPROGRESS: c_int = 115;
const POLLIN: c_short = 1;
const POLLOUT: c_short = 4;
const POLLNVAL: c_short = 0x20;
const SOL_SOCKET: c_int = 1;
const SO_ERROR: c_int = 4;
const CLOCK_MONOTONIC: c_int = 1;

fn libc_errno() c_int {
    return std.posix.system._errno().*;
}

fn oom() noreturn {
    @panic("dhall: out of memory");
}

fn xstrdup(s: []const u8) [:0]u8 {
    return c_alloc.dupeZ(u8, s) catch oom();
}

// ---------- pure URL string helpers (used by import.zig too) ----------

// length of the "scheme://host" prefix (no trailing slash); 0 if malformed
fn url_authority_len(url: []const u8) usize {
    const p = std.mem.indexOf(u8, url, "://") orelse return 0;
    const slash = std.mem.indexOfScalarPos(u8, url, p + 3, '/');
    return if (slash) |s| s else url.len;
}

// dirname of a URL: "http://h/a/b" -> "http://h/a/"; "http://h" -> "http://h/".
pub fn url_dirname(url: []const u8) ?[:0]u8 {
    const alen = url_authority_len(url);
    if (alen == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, url[alen..], '/')) |off| {
        const slash = alen + off;
        const n = slash + 1; // include the trailing '/'
        const r = c_alloc.allocSentinel(u8, n, 0) catch oom();
        @memcpy(r[0..n], url[0..n]);
        return r;
    }
    const r = c_alloc.allocSentinel(u8, url.len + 1, 0) catch oom();
    @memcpy(r[0..url.len], url);
    r[url.len] = '/';
    return r;
}

// Resolve a (possibly relative) reference against a directory URL `base_dir`
// (which ends in '/'). Handles absolute URLs ("http://..." passthrough),
// absolute paths ("/x" -> scheme://host/x), and "./" "../" segments.
pub fn url_join(base_dir: []const u8, spec: []const u8) ?[:0]u8 {
    if (base_dir.len == 0 or spec.len == 0) return null;
    if (std.mem.indexOf(u8, spec, "://") != null) return xstrdup(spec);

    const alen = url_authority_len(base_dir);
    if (alen == 0) return xstrdup(spec);

    if (spec[0] == '/') {
        // absolute path against the authority root
        const r = c_alloc.allocSentinel(u8, alen + spec.len, 0) catch oom();
        @memcpy(r[0..alen], base_dir[0..alen]);
        @memcpy(r[alen..], spec);
        return r;
    }

    // relative: start from base_dir (a directory ending in '/') and walk the
    // spec's slash-separated segments, resolving "." and "..".
    var cap = base_dir.len + spec.len + 2;
    var out = c_alloc.alloc(u8, cap) catch oom();
    @memcpy(out[0..base_dir.len], base_dir);
    var n = base_dir.len;

    var s: usize = 0;
    while (s < spec.len) {
        while (s < spec.len and spec[s] == '/') s += 1;
        if (s >= spec.len) break;
        const seg_start = s;
        while (s < spec.len and spec[s] != '/') s += 1;
        const seg = spec[seg_start..s];
        if (seg.len == 1 and seg[0] == '.') continue;
        if (seg.len == 2 and seg[0] == '.' and seg[1] == '.') {
            // pop the last path segment (never below the authority root)
            if (n > alen + 1) {
                var k = n - 1; // index of the trailing '/'
                while (k > alen + 1 and out[k - 1] != '/') k -= 1;
                n = k; // keep the '/' at out[k-1]
            }
            continue;
        }
        if (n + seg.len + 2 > cap) {
            cap = (n + seg.len + 2) * 2;
            const nb = c_alloc.alloc(u8, cap) catch { c_alloc.free(out); return null; };
            @memcpy(nb[0..n], out[0..n]);
            c_alloc.free(out);
            out = nb;
        }
        @memcpy(out[n..][0..seg.len], seg);
        n += seg.len;
        out[n] = '/';
        n += 1;
    }
    // drop a trailing '/' if the result has a non-root path
    if (n > alen + 1 and out[n - 1] == '/') n -= 1;
    out[n] = 0;
    return out[0..n :0];
}

// ---------- native fetch helpers ----------

fn now_ms() i64 {
    var ts: Timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
    return @as(i64, ts.tv_sec) * 1000 + @as(i64, @divTrunc(ts.tv_nsec, 1000000));
}

const FetchCtx = struct {
    deadline_ms: i64, // absolute monotonic deadline in ms, or -1 = none
    redirects_left: c_int,
};

// find needle in haystack; null if not found
fn find_bytes(hay: []const u8, ndl: []const u8) ?usize {
    if (ndl.len == 0) return 0;
    if (hay.len < ndl.len) return null;
    return std.mem.indexOf(u8, hay, ndl);
}

// poll fd for `events`, honoring the per-op timeout and the overall deadline.
// Returns 0 when ready (the caller's next syscall reports the real outcome),
// -1 on timeout/error (sets *err to ERR_MISSING).
fn wait_fd(ctx: *FetchCtx, fd: c_int, events: c_short, err: *dhall.DhallError, url: []const u8) c_int {
    while (true) {
        var remain: c_int = HTTP_POLL_TIMEOUT_MS;
        if (ctx.deadline_ms >= 0) {
            const n = now_ms();
            if (n < 0) {
                remain = HTTP_POLL_TIMEOUT_MS;
            } else if (n >= ctx.deadline_ms) {
                ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: timed out fetching '{s}'", .{url});
                return -1;
            } else if (ctx.deadline_ms - n < remain) {
                remain = @intCast(ctx.deadline_ms - n);
            }
        }
        var pfd = [1]PollFd{.{ .fd = fd, .events = events, .revents = 0 }};
        const pr = poll(&pfd, 1, remain);
        if (pr > 0) {
            if ((pfd[0].revents & POLLNVAL) != 0) {
                ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: network error fetching '{s}'", .{url});
                return -1;
            }
            return 0;
        }
        if (pr == 0) {
            ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: timed out fetching '{s}'", .{url});
            return -1;
        }
        if (libc_errno() == EINTR) continue;
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: network error fetching '{s}'", .{url});
        return -1;
    }
}

// send the full buffer; false on failure (sets *err)
fn send_all(ctx: *FetchCtx, fd: c_int, buf: []const u8, err: *dhall.DhallError, url: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const w = send(fd, buf.ptr + off, buf.len - off, 0);
        if (w > 0) {
            off += @intCast(w);
            continue;
        }
        if (w < 0 and libc_errno() == EINTR) continue;
        if (w < 0 and (libc_errno() == EAGAIN or libc_errno() == EWOULDBLOCK)) {
            if (wait_fd(ctx, fd, POLLOUT, err, url) != 0) return false;
            continue;
        }
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: send failed fetching '{s}'", .{url});
        return false;
    }
    return true;
}

// read to EOF into a growable buffer capped at HTTP_MAX_RAW. Returns true on
// clean EOF, false on failure (sets *err: ERR_MISSING network, ERR_IO oversize).
fn recv_all(ctx: *FetchCtx, fd: c_int, raw: *std.ArrayList(u8), err: *dhall.DhallError, url: []const u8) bool {
    while (true) {
        const space = if (HTTP_MAX_RAW > raw.items.len) HTTP_MAX_RAW - raw.items.len else 0;
        if (space == 0) {
            ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "response from '{s}' exceeds 16 MiB", .{url});
            return false;
        }
        var chunk: [8192]u8 = undefined;
        const to_read: usize = @min(space, chunk.len);
        const r = recv(fd, &chunk, to_read, 0);
        if (r > 0) {
            raw.appendSlice(c_alloc, chunk[0..@intCast(r)]) catch oom();
            continue;
        }
        if (r == 0) return true; // EOF
        if (libc_errno() == EINTR) continue;
        if (libc_errno() == EAGAIN or libc_errno() == EWOULDBLOCK) {
            if (wait_fd(ctx, fd, POLLIN, err, url) != 0) return false;
            continue;
        }
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: recv failed fetching '{s}'", .{url});
        return false;
    }
}

fn hexval(c: u8) c_int {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return -1;
}

// de-chunk a Transfer-Encoding: chunked body (in[0..inlen)). Appends decoded
// body (<= HTTP_MAX_BODY) to `out`. false on malformed/oversized input.
fn de_chunk(in: []const u8, out: *std.ArrayList(u8)) bool {
    var p: usize = 0;
    const end = in.len;
    while (p < end) {
        const eol = find_bytes(in[p..], "\r\n") orelse return false;
        // parse hex chunk size, stopping at ';' (chunk extension)
        var q: usize = p;
        var sz: u64 = 0;
        var any = false;
        while (q < p + eol and in[q] != ';') {
            const d = hexval(in[q]);
            if (d < 0) return false;
            if (sz > (std.math.maxInt(u64) - @as(u64, @intCast(d))) / 16) return false;
            sz = sz * 16 + @as(u64, @intCast(d));
            any = true;
            q += 1;
        }
        if (!any) return false; // empty chunk size
        p = p + eol + 2; // past the size-line CRLF
        if (sz == 0) break; // last chunk
        // sz is u64 (a chunk size is up to 16 hex digits): compare in u64 so
        // the 32-bit targets cannot narrow it (usize is 32 bits on i386).
        if (sz > @as(u64, end - p)) return false;
        if (out.items.len + sz > HTTP_MAX_BODY) return false;
        out.appendSlice(c_alloc, in[p..][0..@intCast(sz)]) catch oom();
        p += @intCast(sz);
        if (end - p < 2 or in[p] != '\r' or in[p + 1] != '\n') return false;
        p += 2;
    }
    return true;
}

// parse the 3-digit status code from the status line; -1 if malformed
fn parse_status(raw: []const u8, hdrlen: usize) c_int {
    // "HTTP/1.1 200 OK\r\n" — find the first space, then 3 digits
    var line_end = find_bytes(raw[0..hdrlen], "\r\n") orelse hdrlen;
    if (line_end > hdrlen) line_end = hdrlen;
    const sp = find_bytes(raw[0..line_end], " ") orelse return -1;
    const d = sp + 1;
    if (d + 3 > line_end) return -1;
    if (raw[d] < '0' or raw[d] > '9' or raw[d + 1] < '0' or raw[d + 1] > '9' or raw[d + 2] < '0' or raw[d + 2] > '9') return -1;
    return @as(c_int, raw[d] - '0') * 100 + @as(c_int, raw[d + 1] - '0') * 10 + @as(c_int, raw[d + 2] - '0');
}

fn strncasecmp(a: []const u8, b: []const u8) bool {
    if (a.len < b.len) return false;
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
    }
    return true;
}

// extract Location and whether Transfer-Encoding contains "chunked" from the
// header block raw[0..hdrlen). Location is a slice.
fn parse_headers(raw: []const u8, hdrlen: usize, location: *?[]const u8, chunked: *bool) void {
    location.* = null;
    chunked.* = false;
    // skip the status line
    var p = find_bytes(raw[0..hdrlen], "\r\n") orelse return;
    p += 2;
    const end = hdrlen;
    while (p < end) {
        const eol = find_bytes(raw[p..end], "\r\n") orelse end - p;
        const colon = find_bytes(raw[p..][0..eol], ":");
        if (colon) |c| {
            const nlen = c;
            var v = p + c + 1;
            while (v < p + eol and (raw[v] == ' ' or raw[v] == '\t')) v += 1;
            const vlen = p + eol - v;
            if (nlen == 8 and strncasecmp(raw[p..p + nlen], "Location")) {
                location.* = raw[v..][0..vlen];
            } else if (nlen == 17 and strncasecmp(raw[p..p + nlen], "Transfer-Encoding")) {
                var i: usize = 0;
                while (i + 7 <= vlen) : (i += 1) {
                    if (strncasecmp(raw[v + i .. v + i + 7], "chunked") and
                        (i == 0 or raw[v + i - 1] == ',' or raw[v + i - 1] == ' ' or raw[v + i - 1] == '\t') and
                        (i + 7 == vlen or raw[v + i + 7] == ',' or raw[v + i + 7] == ' ' or raw[v + i + 7] == '\t'))
                    {
                        chunked.* = true;
                        break;
                    }
                }
            }
        }
        p = p + eol;
        while (p < end and (raw[p] == '\r' or raw[p] == '\n')) p += 1;
    }
}

// resolve a redirect Location (absolute or relative) against the current URL
fn resolve_location(url: []const u8, loc: []const u8) ?[]u8 {
    if (std.mem.indexOf(u8, loc, "://") != null) return xstrdup(loc); // absolute URL
    const base = url_dirname(url) orelse return null;
    const joined = url_join(base, loc);
    c_alloc.free(base);
    return joined;
}

// non-blocking connect with timeout; 0 ok, -1 fail (sets *err)
fn connect_timeout(ctx: *FetchCtx, fd: c_int, addr: *const std.c.sockaddr, alen: c_uint, err: *dhall.DhallError, url: []const u8) c_int {
    if (connect(fd, addr, alen) == 0) return 0;
    if (libc_errno() != EINPROGRESS) {
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: cannot connect to '{s}'", .{url});
        return -1;
    }
    if (wait_fd(ctx, fd, POLLOUT, err, url) != 0) return -1;
    var soerr: c_int = 0;
    var sl: c_uint = @sizeOf(c_int);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) != 0 or soerr != 0) {
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: cannot connect to '{s}'", .{url});
        return -1;
    }
    return 0;
}

fn http_fetch_impl(ctx: *FetchCtx, url: []const u8, body: *?[]u8, len: *usize, err: *dhall.DhallError) c_int {
    var u: ssrf.Url = undefined;
    if (ssrf.url_parse(url, &u) != 0) {
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "malformed URL '{s}'", .{url});
        return HTTP_HARD;
    }
    if (!std.mem.eql(u8, u.scheme.?, "http")) {
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "{s}:// imports are not supported in this build (no TLS)", .{u.scheme.?});
        u.free();
        return HTTP_HARD;
    }
    if (url.len > HTTP_MAX_URL) {
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "URL too long", .{});
        u.free();
        return HTTP_HARD;
    }

    // resolve + SSRF (DNS-rebinding defense: reject if ANY addr is blocked)
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = AF_UNSPEC;
    hints.socktype = SOCK_STREAM;
    var portbuf: [16]u8 = undefined;
    const ps = std.fmt.bufPrint(&portbuf, "{d}", .{if (u.port != 0) u.port else 80}) catch unreachable;
    portbuf[ps.len] = 0;
    const pz: [:0]const u8 = portbuf[0..ps.len :0];
    var res: ?*std.c.addrinfo = null;
    const gai = std.c.getaddrinfo(u.host.?.ptr, pz.ptr, &hints, &res);
    if (@intFromEnum(gai) != 0 or res == null) {
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: cannot resolve host '{s}'", .{u.host.?});
        u.free();
        return HTTP_ABSENT;
    }
    {
        var ai: ?*std.c.addrinfo = res;
        while (ai) |a| : (ai = a.next) {
            if (ssrf.ssrf_addr_blocked(a.addr)) {
                std.c.freeaddrinfo(res.?);
                ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: URL blocked (non-public address)", .{});
                u.free();
                return HTTP_ABSENT;
            }
        }
    }

    // connect ONLY to a validated sockaddr (never the hostname string)
    const fd = socket(res.?.family, SOCK_STREAM, 0);
    if (fd < 0) {
        std.c.freeaddrinfo(res.?);
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: socket failed", .{});
        u.free();
        return HTTP_ABSENT;
    }
    const flags = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (flags >= 0) _ = fcntl(fd, F_SETFL, @as(c_int, flags | O_NONBLOCK));
    const cr = connect_timeout(ctx, fd, res.?.addr.?, res.?.addrlen, err, url);
    std.c.freeaddrinfo(res.?);
    if (cr != 0) {
        _ = close(fd);
        u.free();
        return HTTP_ABSENT;
    }

    // send GET request
    var req: [HTTP_MAX_URL + 256]u8 = undefined;
    const rlen = std.fmt.bufPrint(&req, "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ u.path.?, u.host.? }) catch {
        _ = close(fd);
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "URL too long", .{});
        u.free();
        return HTTP_HARD;
    };
    if (!send_all(ctx, fd, rlen, err, url)) {
        _ = close(fd);
        u.free();
        return if (err.stage == .ERR_MISSING) HTTP_ABSENT else HTTP_HARD;
    }

    // read the whole response (headers + body), capped
    var raw = std.ArrayList(u8).initCapacity(c_alloc, 8192) catch oom();
    if (!recv_all(ctx, fd, &raw, err, url)) {
        raw.deinit(c_alloc);
        _ = close(fd);
        u.free();
        return if (err.stage == .ERR_MISSING) HTTP_ABSENT else HTTP_HARD;
    }
    _ = close(fd);

    // split headers / body
    const hend = find_bytes(raw.items, "\r\n\r\n") orelse {
        raw.deinit(c_alloc);
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "malformed HTTP response from '{s}'", .{url});
        u.free();
        return HTTP_HARD;
    };
    const hdrlen = hend + 4;
    const code = parse_status(raw.items, hdrlen);
    if (code <= 0) {
        raw.deinit(c_alloc);
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "malformed HTTP response from '{s}'", .{url});
        u.free();
        return HTTP_HARD;
    }
    var location: ?[]const u8 = null;
    var chunked = false;
    parse_headers(raw.items, hdrlen, &location, &chunked);
    const body_start = hdrlen;

    // redirects
    if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) {
        if (location == null) {
            raw.deinit(c_alloc);
            ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: HTTP {d} from '{s}' (no Location)", .{ code, url });
            u.free();
            return HTTP_ABSENT;
        }
        if (ctx.redirects_left <= 0) {
            raw.deinit(c_alloc);
            ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: too many redirects fetching '{s}'", .{url});
            u.free();
            return HTTP_ABSENT;
        }
        const next = resolve_location(url, location.?) orelse {
            raw.deinit(c_alloc);
            ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "malformed redirect Location from '{s}'", .{url});
            u.free();
            return HTTP_HARD;
        };
        // re-validate scheme + resolve + SSRF on the next hop (recursion)
        var nu: ssrf.Url = undefined;
        if (ssrf.url_parse(next, &nu) != 0) {
            raw.deinit(c_alloc);
            c_alloc.free(next);
            ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "malformed redirect URL from '{s}'", .{url});
            u.free();
            return HTTP_HARD;
        }
        if (!std.mem.eql(u8, nu.scheme.?, "http")) {
            raw.deinit(c_alloc);
            c_alloc.free(next);
            ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "{s}:// redirects are not supported (no TLS)", .{nu.scheme.?});
            nu.free();
            u.free();
            return HTTP_HARD;
        }
        nu.free();
        raw.deinit(c_alloc);
        ctx.redirects_left -= 1;
        const r = http_fetch_impl(ctx, next, body, len, err);
        c_alloc.free(next);
        return r;
    }

    // non-2xx is absent
    if (code < 200 or code >= 300) {
        raw.deinit(c_alloc);
        ast.dhall_error_set(err, .ERR_MISSING, dhall.SPAN_NONE, "missing import: HTTP {d} from '{s}'", .{ code, url });
        u.free();
        return HTTP_ABSENT;
    }

    // final body: de-chunk or raw
    var out = std.ArrayList(u8).initCapacity(c_alloc, 4096) catch oom();
    if (chunked) {
        if (!de_chunk(raw.items[body_start..], &out)) {
            raw.deinit(c_alloc);
            out.deinit(c_alloc);
            ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "malformed chunked response from '{s}'", .{url});
            u.free();
            return HTTP_HARD;
        }
    } else {
        out.appendSlice(c_alloc, raw.items[body_start..]) catch oom();
    }
    raw.deinit(c_alloc);
    u.free();

    if (out.items.len > HTTP_MAX_BODY) {
        out.deinit(c_alloc);
        ast.dhall_error_set(err, .ERR_IO, dhall.SPAN_NONE, "response from '{s}' exceeds 16 MiB", .{url});
        return HTTP_HARD;
    }

    // NUL-terminated body buffer: [0..outlen] plus a trailing NUL at [outlen].
    const owned = out.toOwnedSlice(c_alloc) catch oom();
    const buf = c_alloc.alloc(u8, owned.len + 1) catch oom();
    @memcpy(buf[0..owned.len], owned);
    buf[owned.len] = 0;
    c_alloc.free(owned);
    body.* = buf;
    len.* = buf.len - 1;
    return HTTP_OK;
}

pub fn http_fetch(url: []const u8, body: *?[]u8, len: *usize, err: *dhall.DhallError) c_int {
    body.* = null;
    len.* = 0;
    var ctx = FetchCtx{
        .redirects_left = HTTP_MAX_REDIRECTS,
        .deadline_ms = now_ms(),
    };
    if (ctx.deadline_ms >= 0) ctx.deadline_ms += HTTP_DEADLINE_MS;
    return http_fetch_impl(&ctx, url, body, len, err);
}
