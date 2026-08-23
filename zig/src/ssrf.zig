// ssrf.zig — port of ../src/ssrf.c + ../src/ssrf.h, verbatim in behavior.
//
// The classifier is folded VERBATIM from ref/ssrf_proto.c (VERIFIED: 36/36
// classification vectors). The mask tables below are the authoritative copy —
// do NOT hand-transcribe them elsewhere; the test vectors live in
// tests/ssrf_test.c and are mirrored as Zig unit tests at the bottom of this
// file.
//
// IPv4 blocked (host byte order after ntohl): 0.0.0.0/8, 10/8, 100.64/10
// (CGNAT), 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.0.2/24, 192.88.99/24,
// 192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24, 224/4 (multicast),
// 240/4 (reserved).  IPv6: ::/128, ::1/128, fe80::/10, fc00::/7 (ULA),
// ff00::/8 (multicast), 2001:db8::/32 (documentation), 2001::/32 (Teredo),
// 64:ff9b::/96 (NAT64), 2002::/16 (6to4), ::ffff:0:0/96 (IPv4-mapped — recurse
// into the embedded IPv4).  Unknown family fails closed.

const std = @import("std");

const c_alloc = std.heap.c_allocator;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn inet_pton(af: c_int, src: [*:0]const u8, dst: *anyopaque) c_int;

// ---- Url (mirror of ssrf.h typedef struct { ... } Url) ----
// Strings are NUL-terminated ([ :0 ]u8) so they can be passed directly to
// libc functions (getaddrinfo). Nullable so url_free() can safely skip any
// field that was never allocated.
pub const Url = struct {
    scheme: ?[:0]u8, // lowercase scheme, no ':' ; e.g. "http"
    host: ?[:0]u8, // host without surrounding [ ] brackets
    port: c_int, // numeric port, or 0 if absent
    path: ?[:0]u8, // path, always begins with '/', no ?query/#fragment

    pub fn free(u: *Url) void {
        if (u.scheme) |s| c_alloc.free(s);
        if (u.host) |s| c_alloc.free(s);
        if (u.path) |s| c_alloc.free(s);
        u.* = .{ .scheme = null, .host = null, .port = 0, .path = null };
    }
};

pub fn url_free(u: *Url) void {
    u.free();
}

// ---- DHALL_ALLOW_LOOPBACK test escape (TEST-ONLY, INSECURE) ----
// Default OFF. When set (to anything non-empty other than "0"), 127.0.0.0/8
// and ::1/128 are treated as public so the opt-in live test (tests/url.sh)
// can exercise the success fetch path against a localhost server. EVERYTHING
// else (private/link-local/reserved ranges) stays blocked. Do NOT set this in
// production. Read once and cached.
var allow_loopback_cached: c_int = -1;

fn allow_loopback() bool {
    if (allow_loopback_cached < 0) {
        const e = getenv("DHALL_ALLOW_LOOPBACK");
        allow_loopback_cached = if (e != null and e.?[0] != 0 and !std.mem.eql(u8, std.mem.span(e.?), "0")) 1 else 0;
    }
    return allow_loopback_cached == 1;
}

const INET: u16 = @intCast(std.posix.AF.INET);
const INET6: u16 = @intCast(std.posix.AF.INET6);

fn toHost(a: u32) u32 {
    // ntohl(sin_addr.s_addr) — network byte order -> host byte order.
    return std.mem.bigToNative(u32, a);
}

// is this address exactly loopback (127.0.0.0/8 or ::1)?
fn is_loopback(sa: *const std.c.sockaddr) bool {
    if (sa.family == INET) {
        const sa4 = @as(*const std.c.sockaddr.in, @ptrCast(@alignCast(sa)));
        const a = toHost(sa4.addr);
        return (a & 0xFF000000) == 0x7F000000; // 127/8
    }
    if (sa.family == INET6) {
        const sa6 = @as(*const std.c.sockaddr.in6, @ptrCast(@alignCast(sa)));
        const b = &sa6.addr;
        var i: usize = 0;
        while (i < 15) : (i += 1) if (b[i] != 0) return false;
        return b[15] == 0x01; // ::1
    }
    return false;
}

fn ipv4_blocked(a: u32) bool {
    // host byte order
    if ((a & 0xFF000000) == 0x00000000) return true; // 0.0.0.0/8
    if ((a & 0xFF000000) == 0x0A000000) return true; // 10/8
    if ((a & 0xFFC00000) == 0x64400000) return true; // 100.64/10 CGNAT
    if ((a & 0xFF000000) == 0x7F000000) return true; // 127/8 loopback
    if ((a & 0xFFFF0000) == 0xA9FE0000) return true; // 169.254/16
    if ((a & 0xFFF00000) == 0xAC100000) return true; // 172.16/12
    if ((a & 0xFFFFFF00) == 0xC0000000) return true; // 192.0.0/24
    if ((a & 0xFFFFFF00) == 0xC0000200) return true; // 192.0.2/24 TEST
    if ((a & 0xFFFFFF00) == 0xC0586300) return true; // 192.88.99/24
    if ((a & 0xFFFF0000) == 0xC0A80000) return true; // 192.168/16
    if ((a & 0xFFFE0000) == 0xC6120000) return true; // 198.18/15 bench
    if ((a & 0xFFFFFF00) == 0xC6336400) return true; // 198.51.100/24
    if ((a & 0xFFFFFF00) == 0xCB007100) return true; // 203.0.113/24
    if ((a & 0xF0000000) == 0xE0000000) return true; // 224/4 mcast
    if ((a & 0xF0000000) == 0xF0000000) return true; // 240/4 reserved
    return false;
}

fn ipv4_bytes_blocked(b: *const [4]u8) bool {
    const ip = (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | @as(u32, b[3]);
    return ipv4_blocked(ip);
}

fn ipv6_blocked(b: *const [16]u8) bool {
    // First 10 bytes zero => the last 4 bytes embed an IPv4 address: BOTH the
    // IPv4-mapped ::ffff:0:0/96 AND the deprecated IPv4-compatible ::/96
    // recurse into it, so ::127.0.0.1 / ::10.0.0.1 / ::169.254.169.254
    // cannot slip through.
    var first10zero = true;
    {
        var i: usize = 0;
        while (i < 10) : (i += 1) if (b[i] != 0) {
            first10zero = false;
            break;
        };
    }
    if (first10zero and (b[10] | b[11]) == 0) // IPv4-compatible ::/96
        return ipv4_bytes_blocked(b[12..16][0..4]);
    if (first10zero and b[10] == 0xFF and b[11] == 0xFF) // IPv4-mapped ::ffff:0:0/96
        return ipv4_bytes_blocked(b[12..16][0..4]);

    var z = true;
    {
        var i: usize = 0;
        while (i < 16) : (i += 1) if (b[i] != 0) {
            z = false;
            break;
        };
    }
    if (z) return true; // ::/128

    var lb = true;
    {
        var i: usize = 0;
        while (i < 15) : (i += 1) if (b[i] != 0) {
            lb = false;
            break;
        };
    }
    if (lb and b[15] == 0x01) return true; // ::1/128

    if (b[0] == 0xFE and (b[1] & 0xC0) == 0x80) return true; // fe80::/10
    if (b[0] == 0xFE and (b[1] & 0xC0) == 0xC0) return true; // fec0::/10 site-local
    if ((b[0] & 0xFE) == 0xFC) return true; // fc00::/7 ULA
    if (b[0] == 0xFF) return true; // ff00::/8 mcast
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0D and b[3] == 0xB8) return true; // doc
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x00 and b[3] == 0x00) return true; // Teredo
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xFF and b[3] == 0x9B) return true; // NAT64
    if (b[0] == 0x20 and b[1] == 0x02) return true; // 6to4
    return false;
}

pub fn ssrf_addr_blocked(sa: ?*const std.c.sockaddr) bool {
    const s = sa orelse return true;
    if (allow_loopback() and is_loopback(s)) return false;
    if (s.family == INET)
        return ipv4_blocked(toHost(@as(*const std.c.sockaddr.in, @ptrCast(@alignCast(s))).addr));
    if (s.family == INET6)
        return ipv6_blocked(&@as(*const std.c.sockaddr.in6, @ptrCast(@alignCast(s))).addr);
    return true; // unknown family: fail closed
}

// ---- url_parse ----

fn xstrdup(s: []const u8) [:0]u8 {
    return c_alloc.dupeZ(u8, s) catch oom();
}

fn oom() noreturn {
    @panic("dhall: out of memory");
}

// parse decimal port digits in [s, end); 1-65535 only. 0 on success.
fn parse_port(s: []const u8, port: *c_int) c_int {
    if (s.len == 0) return -1; // empty port, e.g. "host:"
    var v: u64 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return -1;
        v = v * 10 + (ch - '0');
        if (v > 65535) return -1;
    }
    if (v == 0) return -1; // port 0 is invalid
    port.* = @intCast(v);
    return 0;
}

pub fn url_parse(spec: ?[]const u8, out: *Url) c_int {
    out.* = .{ .scheme = null, .host = null, .port = 0, .path = null };
    const s = spec orelse return -1;

    const p = std.mem.indexOf(u8, s, "://") orelse return -1;
    const slen = p;
    if (slen == 0) return -1;

    // scheme (lowercased; schemes are case-insensitive)
    const scheme_buf = c_alloc.allocSentinel(u8, slen, 0) catch oom();
    for (scheme_buf, 0..) |*c, i| c.* = std.ascii.toLower(s[i]);
    out.scheme = scheme_buf;
    const auth = s[slen + 3 ..]; // p += 3

    // authority = host[:port], up to the first '/', '?', '#' or end
    var auth_end: usize = 0;
    while (auth_end < auth.len) {
        const c = auth[auth_end];
        if (c == '/' or c == '?' or c == '#') break;
        auth_end += 1;
    }
    const a = auth[0..auth_end];

    var host_start: usize = 0;
    var host_end: usize = 0;
    var port: c_int = 0;
    if (a.len > 0 and a[0] == '[') {
        // bracketed IPv6: [::1]:port
        const close_opt = std.mem.indexOfScalar(u8, a, ']');
        if (close_opt == null) { url_free(out); return -1; }
        const close = close_opt.?;
        host_start = 1;
        host_end = close;
        const after = close + 1;
        if (after < a.len) {
            if (a[after] != ':') { url_free(out); return -1; }
            if (parse_port(a[after + 1 ..], &port) != 0) { url_free(out); return -1; }
        }
    } else {
        const colon = std.mem.indexOfScalar(u8, a, ':');
        host_start = 0;
        host_end = if (colon) |c| c else a.len;
        if (colon) |c| {
            if (parse_port(a[c + 1 ..], &port) != 0) { url_free(out); return -1; }
        }
    }

    const hlen = host_end - host_start;
    if (hlen == 0) { url_free(out); return -1; } // empty host, e.g. http:///x
    // no ctl/space/DEL (CRLF injection)
    for (a[host_start..host_end]) |ch| {
        if (ch <= 0x20 or ch == 0x7F) { url_free(out); return -1; }
    }
    out.host = c_alloc.dupeZ(u8, a[host_start..host_end]) catch oom();
    out.port = port;

    // path: "/..." up to (not incl.) '?' or '#'; default "/"
    if (auth_end >= auth.len or auth[auth_end] != '/') {
        out.path = xstrdup("/");
    } else {
        var pend = auth_end;
        while (pend < auth.len) {
            const c = auth[pend];
            if (c == '?' or c == '#') break;
            pend += 1;
        }
        // no ctl/space/DEL (CRLF injection)
        for (auth[auth_end..pend]) |ch| {
            if (ch <= 0x20 or ch == 0x7F) { url_free(out); return -1; }
        }
        out.path = c_alloc.dupeZ(u8, auth[auth_end..pend]) catch oom();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Tests — the 36 classification vectors + url_parse vectors from
// tests/ssrf_test.c, mirrored as Zig unit tests.
// ---------------------------------------------------------------------------

fn chk_v4(label: []const u8, ip: []const u8, want: bool) !void {
    var s = std.mem.zeroes(std.c.sockaddr.in);
    s.family = @intCast(INET);
    if (inet_pton(2, @ptrCast(ip), @ptrCast(&s.addr)) != 1) {
        std.debug.print("FAIL {s} bad IPv4 literal {s}\n", .{ label, ip });
        return error.BadLiteral;
    }
    const got = ssrf_addr_blocked(@ptrCast(&s));
    if (got != want) {
        std.debug.print("FAIL {s} got={s} want={s}\n", .{ label, if (got) "blocked" else "public", if (want) "blocked" else "public" });
        return error.Mismatch;
    }
}

fn chk_v6(label: []const u8, ip: []const u8, want: bool) !void {
    var s = std.mem.zeroes(std.c.sockaddr.in6);
    s.family = @intCast(INET6);
    var bytes: [16]u8 = undefined;
    const nb = inet_pton(10, @ptrCast(ip), @ptrCast(&bytes));
    if (nb != 1) {
        std.debug.print("FAIL {s} bad IPv6 literal {s}\n", .{ label, ip });
        return error.BadLiteral;
    }
    @memcpy(&s.addr, &bytes);
    const got = ssrf_addr_blocked(@ptrCast(&s));
    if (got != want) {
        std.debug.print("FAIL {s} got={s} want={s}\n", .{ label, if (got) "blocked" else "public", if (want) "blocked" else "public" });
        return error.Mismatch;
    }
}

fn chk_url(label: []const u8, spec: []const u8, ok: bool, scheme: []const u8, host: []const u8, port: c_int, path: []const u8) !void {
    var u: Url = undefined;
    const rc = url_parse(spec, &u);
    if (!ok) {
        if (rc == 0) {
            std.debug.print("FAIL {s} parsed but should have failed\n", .{label});
            url_free(&u);
            return error.Parsed;
        }
        return;
    }
    if (rc != 0) {
        std.debug.print("FAIL {s} url_parse returned -1\n", .{label});
        return error.ParseFailed;
    }
    const got_scheme = u.scheme orelse return error.Missing;
    const got_host = u.host orelse return error.Missing;
    const got_path = u.path orelse return error.Missing;
    if (!std.mem.eql(u8, got_scheme, scheme) or !std.mem.eql(u8, got_host, host) or u.port != port or !std.mem.eql(u8, got_path, path)) {
        std.debug.print("FAIL {s} got scheme={s} host={s} port={d} path={s}\n", .{ label, got_scheme, got_host, u.port, got_path });
        url_free(&u);
        return error.Mismatch;
    }
    url_free(&u);
}

test "36 classification vectors" {
    // IPv4
    try chk_v4("0.0.0.0", "0.0.0.0", true);
    try chk_v4("10.0.0.1", "10.0.0.1", true);
    try chk_v4("100.64.0.1 CGNAT", "100.64.0.1", true);
    try chk_v4("127.0.0.1", "127.0.0.1", true);
    try chk_v4("127.255.255.255", "127.255.255.255", true);
    try chk_v4("169.254.169.254", "169.254.169.254", true);
    try chk_v4("172.16.0.1", "172.16.0.1", true);
    try chk_v4("172.31.255.255", "172.31.255.255", true);
    try chk_v4("192.0.0.1", "192.0.0.1", true);
    try chk_v4("192.0.2.1 TEST", "192.0.2.1", true);
    try chk_v4("192.88.99.1", "192.88.99.1", true);
    try chk_v4("192.168.0.1", "192.168.0.1", true);
    try chk_v4("198.18.0.1 bench", "198.18.0.1", true);
    try chk_v4("198.51.100.1", "198.51.100.1", true);
    try chk_v4("203.0.113.1", "203.0.113.1", true);
    try chk_v4("224.0.0.1 mcast", "224.0.0.1", true);
    try chk_v4("255.255.255.255", "255.255.255.255", true);
    try chk_v4("1.1.1.1", "1.1.1.1", false);
    try chk_v4("8.8.8.8", "8.8.8.8", false);
    try chk_v4("93.184.216.34", "93.184.216.34", false);
    try chk_v4("172.32.0.1 public", "172.32.0.1", false);
    try chk_v4("192.169.0.1 public", "192.169.0.1", false);
    // IPv6
    try chk_v6("::", "::", true);
    try chk_v6("::1", "::1", true);
    try chk_v6("::ffff:127.0.0.1", "::ffff:127.0.0.1", true);
    try chk_v6("::ffff:10.0.0.1", "::ffff:10.0.0.1", true);
    try chk_v6("fe80::1", "fe80::1", true);
    try chk_v6("fc00::1 ULA", "fc00::1", true);
    try chk_v6("fd12::1 ULA", "fd12::1", true);
    try chk_v6("ff02::1 mcast", "ff02::1", true);
    try chk_v6("2001:db8::1", "2001:db8::1", true);
    try chk_v6("64:ff9b::808:808", "64:ff9b::808:808", true);
    try chk_v6("2002::1 6to4", "2002::1", true);
    try chk_v6("2606:4700:4700::1111", "2606:4700:4700::1111", false);
    try chk_v6("2001:4860:4860::8888", "2001:4860:4860::8888", false);
    try chk_v6("::ffff:1.1.1.1", "::ffff:1.1.1.1", false);
    // IPv4-compatible ::/96 must recurse into the embedded IPv4 too
    try chk_v6("::127.0.0.1 compatible", "::127.0.0.1", true);
    try chk_v6("::10.0.0.1 compatible", "::10.0.0.1", true);
    try chk_v6("::169.254.169.254 compatible", "::169.254.169.254", true);
    try chk_v6("::8.8.8.8 public", "::8.8.8.8", false);
    try chk_v6("fec0::1 site-local", "fec0::1", true);
}

test "url_parse vectors" {
    try chk_url("http basic", "http://example.com", true, "http", "example.com", 0, "/");
    try chk_url("http port", "http://example.com:8080/x", true, "http", "example.com", 8080, "/x");
    try chk_url("http path", "http://example.com/a/b/c", true, "http", "example.com", 0, "/a/b/c");
    try chk_url("http empty path", "http://example.com/", true, "http", "example.com", 0, "/");
    try chk_url("https default", "https://example.com", true, "https", "example.com", 0, "/");
    try chk_url("ipv6 bracketed", "http://[::1]:8080/x", true, "http", "::1", 8080, "/x");
    try chk_url("ipv6 no port", "http://[::1]/x", true, "http", "::1", 0, "/x");
    try chk_url("uppercase scheme", "HTTP://Example.COM/p", true, "http", "Example.COM", 0, "/p");
    try chk_url("query stripped", "http://example.com/x?q=1", true, "http", "example.com", 0, "/x");
    try chk_url("fragment stripped", "http://example.com/x#frag", true, "http", "example.com", 0, "/x");
    try chk_url("no scheme", "example.com", false, "", "", 0, "");
    try chk_url("empty host", "http:///x", false, "", "", 0, "");
    try chk_url("bad port", "http://example.com:abc/x", false, "", "", 0, "");
    try chk_url("port zero", "http://example.com:0/x", false, "", "", 0, "");
    try chk_url("unterminated brkt", "http://[::1/x", false, "", "", 0, "");
    try chk_url("userinfo rejected", "http://user:pass@h/x", false, "", "", 0, "");
    try chk_url("unbracketed v6", "http://::1/x", false, "", "", 0, "");
    // CRLF / ctl / space injection into host or path (redirect Location)
    try chk_url("crlf in path", "http://h/ok\nHost: evil", false, "", "", 0, "");
    try chk_url("ctl in host", "http://h\x01ost/x", false, "", "", 0, "");
    try chk_url("space in path", "http://h/a b", false, "", "", 0, "");
    try chk_url("no injection ok", "http://h/a%20b", true, "http", "h", 0, "/a%20b");
}
