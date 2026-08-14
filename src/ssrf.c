/* ssrf.c — SSRF IP classifier + URL parser. See ssrf.h.

   The classifier is folded VERBATIM from ref/ssrf_proto.c (VERIFIED: 36/36
   classification vectors pass under gcc -std=c11 -Wall -Wextra AND
   cosmocc -std=c11 -O2 -Wall -Wextra). The mask tables below are the
   authoritative copy — do not hand-transcribe them elsewhere; the test
   vectors live in tests/ssrf_test.c.

   IPv4 blocked (host byte order after ntohl): 0.0.0.0/8, 10/8, 100.64/10
   (CGNAT), 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.0.2/24, 192.88.99/24,
   192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24, 224/4 (multicast),
   240/4 (reserved).  IPv6: ::/128, ::1/128, fe80::/10, fc00::/7 (ULA),
   ff00::/8 (multicast), 2001:db8::/32 (documentation), 2001::/32 (Teredo),
   64:ff9b::/96 (NAT64), 2002::/16 (6to4), ::ffff:0:0/96 (IPv4-mapped — recurse
   into the embedded IPv4).  Unknown family fails closed. */
#include "ssrf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>

/* ---- DHALL_ALLOW_LOOPBACK test escape (TEST-ONLY, INSECURE) ----
   Default OFF. When set (to anything non-empty other than "0"), 127.0.0.0/8
   and ::1/128 are treated as public so the opt-in live test (tests/url.sh)
   can exercise the success fetch path against a localhost server. EVERYTHING
   else (private/link-local/reserved ranges) stays blocked. Do NOT set this in
   production. Read once and cached. */
static bool allow_loopback(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("DHALL_ALLOW_LOOPBACK");
        cached = (e && e[0] != '\0' && strcmp(e, "0") != 0) ? 1 : 0;
    }
    return cached == 1;
}

/* is this address exactly loopback (127.0.0.0/8 or ::1)? */
static bool is_loopback(const struct sockaddr *sa) {
    if (sa->sa_family == AF_INET) {
        uint32_t a = ntohl(((const struct sockaddr_in *)sa)->sin_addr.s_addr);
        return (a & 0xFF000000u) == 0x7F000000u;   /* 127/8 */
    }
    if (sa->sa_family == AF_INET6) {
        const uint8_t *b = ((const struct sockaddr_in6 *)sa)->sin6_addr.s6_addr;
        int i;
        for (i = 0; i < 15; i++) if (b[i]) return false;
        return b[15] == 0x01;                        /* ::1 */
    }
    return false;
}

static bool ipv4_blocked(uint32_t a /* host byte order */) {
    if ((a & 0xFF000000u) == 0x00000000u) return true; /* 0.0.0.0/8 */
    if ((a & 0xFF000000u) == 0x0A000000u) return true; /* 10/8 */
    if ((a & 0xFFC00000u) == 0x64400000u) return true; /* 100.64/10 CGNAT */
    if ((a & 0xFF000000u) == 0x7F000000u) return true; /* 127/8 loopback */
    if ((a & 0xFFFF0000u) == 0xA9FE0000u) return true; /* 169.254/16 */
    if ((a & 0xFFF00000u) == 0xAC100000u) return true; /* 172.16/12 */
    if ((a & 0xFFFFFF00u) == 0xC0000000u) return true; /* 192.0.0/24 */
    if ((a & 0xFFFFFF00u) == 0xC0000200u) return true; /* 192.0.2/24 TEST */
    if ((a & 0xFFFFFF00u) == 0xC0586300u) return true; /* 192.88.99/24 */
    if ((a & 0xFFFF0000u) == 0xC0A80000u) return true; /* 192.168/16 */
    if ((a & 0xFFFE0000u) == 0xC6120000u) return true; /* 198.18/15 bench */
    if ((a & 0xFFFFFF00u) == 0xC6336400u) return true; /* 198.51.100/24 */
    if ((a & 0xFFFFFF00u) == 0xCB007100u) return true; /* 203.0.113/24 */
    if ((a & 0xF0000000u) == 0xE0000000u) return true; /* 224/4 mcast */
    if ((a & 0xF0000000u) == 0xF0000000u) return true; /* 240/4 reserved */
    return false;
}

static bool ipv4_bytes_blocked(const uint8_t b[4]) {
    uint32_t ip = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
                  ((uint32_t)b[2] << 8) | (uint32_t)b[3];
    return ipv4_blocked(ip);
}

static bool ipv6_blocked(const uint8_t b[16]) {
    int i;
    /* First 10 bytes zero => the last 4 bytes embed an IPv4 address: BOTH the
       IPv4-mapped ::ffff:0:0/96 AND the deprecated IPv4-compatible ::/96
       recurse into it, so ::127.0.0.1 / ::10.0.0.1 / ::169.254.169.254
       cannot slip through. (0.0.0.0/8 blocks ::; 127/8 blocks ::1.) */
    bool first10zero = true;
    for (i = 0; i < 10; i++) if (b[i]) { first10zero = false; break; }
    if (first10zero && (b[10] | b[11]) == 0)          /* IPv4-compatible ::/96 */
        return ipv4_bytes_blocked(&b[12]);
    if (first10zero && b[10] == 0xFF && b[11] == 0xFF) /* IPv4-mapped ::ffff:0:0/96 */
        return ipv4_bytes_blocked(&b[12]);

    bool z = true; for (i = 0; i < 16; i++) if (b[i]) { z = false; break; }
    if (z) return true; /* ::/128 */

    bool lb = true; for (i = 0; i < 15; i++) if (b[i]) { lb = false; break; }
    if (lb && b[15] == 0x01) return true; /* ::1/128 */

    if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return true; /* fe80::/10 */
    if (b[0] == 0xFE && (b[1] & 0xC0) == 0xC0) return true; /* fec0::/10 site-local */
    if ((b[0] & 0xFE) == 0xFC) return true; /* fc00::/7 ULA */
    if (b[0] == 0xFF) return true; /* ff00::/8 mcast */
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8) return true; /* doc */
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00) return true; /* Teredo */
    if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B) return true; /* NAT64 */
    if (b[0] == 0x20 && b[1] == 0x02) return true; /* 6to4 */
    return false;
}

bool ssrf_addr_blocked(const struct sockaddr *sa) {
    if (!sa) return true;
    if (allow_loopback() && is_loopback(sa)) return false;
    if (sa->sa_family == AF_INET)
        return ipv4_blocked(ntohl(((const struct sockaddr_in *)sa)->sin_addr.s_addr));
    if (sa->sa_family == AF_INET6)
        return ipv6_blocked(((const struct sockaddr_in6 *)sa)->sin6_addr.s6_addr);
    return true; /* unknown family: fail closed */
}

/* ---- url_parse ---- */

static char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = malloc(n);
    if (r) memcpy(r, s, n);
    return r;
}

/* parse decimal port digits in [s, end); 1-65535 only. 0 on success. */
static int parse_port(const char *s, const char *end, int *port) {
    if (s >= end) return -1;                 /* empty port, e.g. "host:" */
    unsigned long v = 0;
    for (const char *q = s; q < end; q++) {
        if (*q < '0' || *q > '9') return -1;
        v = v * 10 + (unsigned long)(*q - '0');
        if (v > 65535) return -1;
    }
    if (v == 0) return -1;                   /* port 0 is invalid */
    *port = (int)v;
    return 0;
}

void url_free(Url *u) {
    if (!u) return;
    free(u->scheme);
    free(u->host);
    free(u->path);
    u->scheme = u->host = u->path = NULL;
    u->port = 0;
}

int url_parse(const char *spec, Url *out) {
    memset(out, 0, sizeof *out);
    if (!spec) return -1;

    const char *p = strstr(spec, "://");
    if (!p) return -1;
    size_t slen = (size_t)(p - spec);
    if (slen == 0) return -1;

    /* scheme (lowercased; schemes are case-insensitive) */
    out->scheme = malloc(slen + 1);
    if (!out->scheme) return -1;
    for (size_t i = 0; i < slen; i++)
        out->scheme[i] = (char)tolower((unsigned char)spec[i]);
    out->scheme[slen] = '\0';
    p += 3;

    /* authority = host[:port], up to the first '/', '?', '#' or end */
    const char *auth = p;
    const char *auth_end = auth;
    while (*auth_end && *auth_end != '/' && *auth_end != '?' && *auth_end != '#')
        auth_end++;

    const char *host_start = NULL, *host_end = NULL;
    int port = 0;
    if (auth < auth_end && *auth == '[') {
        /* bracketed IPv6: [::1]:port */
        const char *close = memchr(auth, ']', (size_t)(auth_end - auth));
        if (!close) goto fail;
        host_start = auth + 1;
        host_end = close;
        const char *after = close + 1;
        if (after < auth_end) {
            if (*after != ':') goto fail;
            if (parse_port(after + 1, auth_end, &port) != 0) goto fail;
        }
    } else {
        const char *colon = memchr(auth, ':', (size_t)(auth_end - auth));
        host_start = auth;
        host_end = colon ? colon : auth_end;
        if (colon && parse_port(colon + 1, auth_end, &port) != 0) goto fail;
    }

    size_t hlen = (size_t)(host_end - host_start);
    if (hlen == 0) goto fail;                /* empty host, e.g. http:///x */
    for (size_t i = 0; i < hlen; i++)        /* no ctl/space/DEL (CRLF injection) */
        if ((unsigned char)host_start[i] <= 0x20 || (unsigned char)host_start[i] == 0x7F)
            goto fail;
    out->host = malloc(hlen + 1);
    if (!out->host) goto fail;
    memcpy(out->host, host_start, hlen);
    out->host[hlen] = '\0';
    out->port = port;

    /* path: "/..." up to (not incl.) '?' or '#'; default "/" */
    if (*auth_end != '/') {
        out->path = xstrdup("/");
        if (!out->path) goto fail;
    } else {
        const char *pend = auth_end;
        while (*pend && *pend != '?' && *pend != '#') pend++;
        size_t plen = (size_t)(pend - auth_end);
        for (size_t i = 0; i < plen; i++)   /* no ctl/space/DEL (CRLF injection) */
            if ((unsigned char)auth_end[i] <= 0x20 || (unsigned char)auth_end[i] == 0x7F)
                goto fail;
        out->path = malloc(plen + 1);
        if (!out->path) goto fail;
        memcpy(out->path, auth_end, plen);
        out->path[plen] = '\0';
    }
    return 0;

fail:
    url_free(out);
    return -1;
}
