/* http.c — http:// URL import fetch (native) + URL string helpers.

   Security model (see README "Imports — URL imports"):
     - http:// ONLY. https:// and any other scheme are rejected (no TLS in this
       build — cosmocc ships no TLS and its static APE cannot link host libssl).
     - sha256 is REQUIRED for remote imports and checked by import.c BEFORE this
       code runs, so a URL reaching here always has an integrity hash.
     - SSRF: resolve with getaddrinfo(AF_UNSPEC), reject the connection if ANY
       resolved address is private/loopback/link-local/reserved (DNS-rebinding
       defense); connect ONLY to a validated sockaddr, never the hostname string.
     - Redirects 301/302/303/307/308 are followed up to a cap (5), re-validating
       scheme + resolve + SSRF on every hop; redirect to non-http is a HARD error.
     - Caps: 16 MiB body, 10 s per-poll timeout, 30 s overall monotonic deadline.
     - No request body / cookies / credentials; only GET + Host header.

   Error model: an unreachable/blocked/timeout/4xx-5xx/redirect-cap-exceeded URL
   is ABSENT (recoverable by `?` => ERR_MISSING); a malformed response, an
   oversized body, or an unsupported redirect scheme is HARD (ERR_IO).

   The pure string helpers url_dirname()/url_join() live here (NOT in ssrf.c)
   so import.c can resolve nested relative imports inside a URL document without
   pulling socket headers into the wasm build — this TU is compiled for wasm
   with the socket code #ifndef'd out (http_fetch returns HTTP_ABSENT there). */
#include "dhall.h"
#include "ssrf.h"

#include <stdlib.h>
#include <string.h>

#ifndef __EMSCRIPTEN__
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <strings.h>
#include <time.h>
#include <stdint.h>
#endif

/* HTTP_OK / HTTP_ABSENT / HTTP_HARD are declared in dhall.h. */

#define HTTP_MAX_BODY       (16u * 1024u * 1024u)  /* 16 MiB body cap */
#define HTTP_MAX_HEADER     (64u * 1024u)          /* header allowance */
#define HTTP_MAX_RAW        (HTTP_MAX_BODY + HTTP_MAX_HEADER)
#define HTTP_POLL_TIMEOUT_MS 10000                 /* 10 s per poll */
#define HTTP_DEADLINE_MS    30000                  /* 30 s overall */
#define HTTP_MAX_REDIRECTS  5
#define HTTP_MAX_URL        4096                   /* sanity cap on URL length */

/* ---------- pure URL string helpers (used by import.c too) ---------- */

static char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = malloc(n);
    if (r) memcpy(r, s, n);
    return r;
}

/* length of the "scheme://host" prefix (no trailing slash); 0 if malformed */
static size_t url_authority_len(const char *url) {
    const char *p = strstr(url, "://");
    if (!p) return 0;
    p += 3;
    const char *slash = strchr(p, '/');
    return slash ? (size_t)(slash - url) : strlen(url);
}

/* dirname of a URL: "http://h/a/b" -> "http://h/a/"; "http://h" -> "http://h/".
   Returns a malloc'd string (caller frees), or NULL on malformed/OOM. */
char *url_dirname(const char *url) {
    size_t alen = url_authority_len(url);
    if (!alen) return NULL;
    const char *slash = strrchr(url + alen, '/');
    if (!slash) {
        size_t n = strlen(url);
        char *r = malloc(n + 2);
        if (!r) return NULL;
        memcpy(r, url, n);
        r[n] = '/'; r[n + 1] = '\0';
        return r;
    }
    size_t n = (size_t)(slash - url) + 1;   /* include the trailing '/' */
    char *r = malloc(n + 1);
    if (!r) return NULL;
    memcpy(r, url, n);
    r[n] = '\0';
    return r;
}

/* Resolve a (possibly relative) reference against a directory URL `base_dir`
   (which ends in '/'). Handles absolute URLs ("http://..." passthrough),
   absolute paths ("/x" -> scheme://host/x), and "./" "../" segments (strip ./,
   pop a segment for ../). Returns a malloc'd string, or NULL on OOM. */
char *url_join(const char *base_dir, const char *spec) {
    if (!base_dir || !spec) return NULL;
    if (strstr(spec, "://")) return xstrdup(spec);

    size_t alen = url_authority_len(base_dir);
    if (!alen) return xstrdup(spec);

    if (spec[0] == '/') {
        /* absolute path against the authority root */
        size_t sl = strlen(spec);
        char *r = malloc(alen + sl + 1);
        if (!r) return NULL;
        memcpy(r, base_dir, alen);
        memcpy(r + alen, spec, sl);
        r[alen + sl] = '\0';
        return r;
    }

    /* relative: start from base_dir (a directory ending in '/') and walk the
       spec's slash-separated segments, resolving "." and "..". */
    size_t cap = strlen(base_dir) + strlen(spec) + 2;
    char *out = malloc(cap);
    if (!out) return NULL;
    size_t n = strlen(base_dir);
    memcpy(out, base_dir, n);

    const char *s = spec;
    while (*s) {
        while (*s == '/') s++;
        if (!*s) break;
        const char *seg = s;
        while (*s && *s != '/') s++;
        size_t sl = (size_t)(s - seg);
        if (sl == 1 && seg[0] == '.') continue;
        if (sl == 2 && seg[0] == '.' && seg[1] == '.') {
            /* pop the last path segment (never below the authority root) */
            if (n > alen + 1) {
                size_t k = n - 1;              /* index of the trailing '/' */
                while (k > alen + 1 && out[k - 1] != '/') k--;
                n = k;                         /* keep the '/' at out[k-1] */
            }
            continue;
        }
        if (n + sl + 2 > cap) {
            cap = (n + sl + 2) * 2;
            char *nb = realloc(out, cap);
            if (!nb) { free(out); return NULL; }
            out = nb;
        }
        memcpy(out + n, seg, sl);
        n += sl;
        out[n++] = '/';
    }
    /* drop a trailing '/' if the result has a non-root path */
    if (n > alen + 1 && out[n - 1] == '/') n--;
    out[n] = '\0';
    return out;
}

#ifndef __EMSCRIPTEN__

/* ---------- native fetch helpers ---------- */

static int64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

typedef struct {
    int64_t deadline_ms;   /* absolute monotonic deadline in ms, or -1 = none */
    int redirects_left;
} FetchCtx;

/* find needle in haystack; NULL if not found */
static void *find_bytes(const void *hay, size_t hn, const void *ndl, size_t nn) {
    if (nn == 0) return (void *)hay;
    if (hn < nn) return NULL;
    const unsigned char *h = hay, *n = ndl;
    for (size_t i = 0; i + nn <= hn; i++)
        if (memcmp(h + i, n, nn) == 0) return (void *)(h + i);
    return NULL;
}

/* poll fd for `events`, honoring the per-op timeout and the overall deadline.
   Returns 0 when ready (the caller's next syscall reports the real outcome),
   -1 on timeout/error (sets *err to ERR_MISSING). */
static int wait_fd(FetchCtx *ctx, int fd, short events, DhallError *err, const char *url) {
    for (;;) {
        int64_t remain = HTTP_POLL_TIMEOUT_MS;
        if (ctx->deadline_ms >= 0) {
            int64_t now = now_ms();
            if (now < 0) { remain = HTTP_POLL_TIMEOUT_MS; }
            else if (now >= ctx->deadline_ms) {
                dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                                "missing import: timed out fetching '%s'", url);
                return -1;
            } else if (ctx->deadline_ms - now < remain) {
                remain = ctx->deadline_ms - now;
            }
        }
        struct pollfd pfd = { fd, events, 0 };
        int pr = poll(&pfd, 1, (int)remain);
        if (pr > 0) {
            if (pfd.revents & POLLNVAL) {
                dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                                "missing import: network error fetching '%s'", url);
                return -1;
            }
            return 0;  /* ready (possibly with an error the next syscall reveals) */
        }
        if (pr == 0) {
            dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                            "missing import: timed out fetching '%s'", url);
            return -1;
        }
        if (errno == EINTR) continue;
        dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                        "missing import: network error fetching '%s'", url);
        return -1;
    }
}

/* send the full buffer; false on failure (sets *err) */
static bool send_all(FetchCtx *ctx, int fd, const char *buf, size_t n,
                     DhallError *err, const char *url) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = send(fd, buf + off, n - off, 0);
        if (w > 0) { off += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wait_fd(ctx, fd, POLLOUT, err, url) != 0) return false;
            continue;
        }
        dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                        "missing import: send failed fetching '%s'", url);
        return false;
    }
    return true;
}

/* read to EOF into a growable buffer capped at HTTP_MAX_RAW. Returns true on
   clean EOF, false on failure (sets *err: ERR_MISSING network, ERR_IO oversize). */
static bool recv_all(FetchCtx *ctx, int fd, char **buf, size_t *len, size_t *cap,
                     DhallError *err, const char *url) {
    for (;;) {
        if (*len == *cap) {
            size_t ncap = *cap ? *cap * 2 : 8192;
            if (ncap > HTTP_MAX_RAW) {
                dhall_error_set(err, ERR_IO, SPAN_NONE,
                                "response from '%s' exceeds 16 MiB", url);
                return false;
            }
            char *nb = realloc(*buf, ncap);
            if (!nb) { dhall_error_set(err, ERR_IO, SPAN_NONE, "out of memory"); return false; }
            *buf = nb;
            *cap = ncap;
        }
        ssize_t r = recv(fd, *buf + *len, *cap - *len, 0);
        if (r > 0) { *len += (size_t)r; continue; }
        if (r == 0) return true;   /* EOF */
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (wait_fd(ctx, fd, POLLIN, err, url) != 0) return false;
            continue;
        }
        dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                        "missing import: recv failed fetching '%s'", url);
        return false;
    }
}

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* de-chunk a Transfer-Encoding: chunked body (in[0..inlen)). Produces a
   NUL-terminated malloc'd buffer of the decoded body (<= HTTP_MAX_BODY) with
   *outlen = decoded length. false on malformed/oversized input. */
static bool de_chunk(const char *in, size_t inlen, char **out, size_t *outlen) {
    char *buf = malloc(inlen + 1);
    if (!buf) return false;
    size_t o = 0;
    const char *p = in, *end = in + inlen;
    while (p < end) {
        const char *eol = find_bytes(p, (size_t)(end - p), "\r\n", 2);
        if (!eol) { free(buf); return false; }
        /* parse hex chunk size, stopping at ';' (chunk extension) */
        const char *q = p;
        unsigned long long sz = 0;
        bool any = false;
        while (q < eol && *q != ';') {
            int d = hexval((unsigned char)*q);
            if (d < 0) { free(buf); return false; }
            if (sz > ((unsigned long long)((size_t)-1) - (unsigned long long)d) / 16ull) {
                free(buf); return false;   /* size overflow */
            }
            sz = sz * 16 + (unsigned long long)d;
            any = true;
            q++;
        }
        if (!any) { free(buf); return false; }   /* empty chunk size */
        p = eol + 2;                              /* past the size-line CRLF */
        if (sz == 0) break;                       /* last chunk */
        if ((size_t)sz > (size_t)(end - p)) { free(buf); return false; }
        if (o + (size_t)sz > HTTP_MAX_BODY) { free(buf); return false; }
        memcpy(buf + o, p, (size_t)sz);
        o += (size_t)sz;
        p += (size_t)sz;
        if (end - p < 2 || p[0] != '\r' || p[1] != '\n') { free(buf); return false; }
        p += 2;
    }
    buf[o] = '\0';
    *out = buf;
    *outlen = o;
    return true;
}

/* parse the 3-digit status code from the status line; -1 if malformed */
static int parse_status(const char *raw, size_t hdrlen) {
    /* "HTTP/1.1 200 OK\r\n" — find the first space, then 3 digits */
    const char *line_end = find_bytes(raw, hdrlen, "\r\n", 2);
    if (!line_end) line_end = raw + hdrlen;
    const char *sp = find_bytes(raw, (size_t)(line_end - raw), " ", 1);
    if (!sp) return -1;
    const char *d = sp + 1;
    if (d + 3 > line_end) return -1;
    if (d[0] < '0' || d[0] > '9' || d[1] < '0' || d[1] > '9' || d[2] < '0' || d[2] > '9')
        return -1;
    return (d[0] - '0') * 100 + (d[1] - '0') * 10 + (d[2] - '0');
}

/* extract Location and whether Transfer-Encoding contains "chunked" from the
   header block raw[0..hdrlen). Location is a slice (not NUL-terminated). */
static void parse_headers(const char *raw, size_t hdrlen,
                          const char **location, size_t *loc_len, bool *chunked) {
    *location = NULL; *loc_len = 0; *chunked = false;
    /* skip the status line */
    const char *p = find_bytes(raw, hdrlen, "\r\n", 2);
    if (!p) return;
    p += 2;
    const char *end = raw + hdrlen;
    while (p < end) {
        const char *eol = find_bytes(p, (size_t)(end - p), "\r\n", 2);
        if (!eol) eol = end;
        const char *colon = find_bytes(p, (size_t)(eol - p), ":", 1);
        if (colon) {
            size_t nlen = (size_t)(colon - p);
            const char *v = colon + 1;
            while (v < eol && (*v == ' ' || *v == '\t')) v++;
            size_t vlen = (size_t)(eol - v);
            if (nlen == 8 && strncasecmp(p, "Location", 8) == 0) {
                *location = v; *loc_len = vlen;
            } else if (nlen == 17 && strncasecmp(p, "Transfer-Encoding", 17) == 0) {
                for (size_t i = 0; i + 7 <= vlen; i++) {
                    if (strncasecmp(v + i, "chunked", 7) == 0 &&
                        (i == 0 || v[i-1] == ',' || v[i-1] == ' ' || v[i-1] == '\t') &&
                        (i + 7 == vlen || v[i+7] == ',' || v[i+7] == ' ' || v[i+7] == '\t')) {
                        *chunked = true;
                        break;
                    }
                }
            }
        }
        p = eol;
        while (p < end && (*p == '\r' || *p == '\n')) p++;
    }
}

/* resolve a redirect Location (absolute or relative) against the current URL */
static char *resolve_location(const char *url, const char *loc, size_t loc_len) {
    char *l = malloc(loc_len + 1);
    if (!l) return NULL;
    memcpy(l, loc, loc_len);
    l[loc_len] = '\0';
    if (strstr(l, "://")) return l;      /* absolute URL */
    char *base = url_dirname(url);
    if (!base) { free(l); return NULL; }
    char *joined = url_join(base, l);
    free(base);
    free(l);
    return joined;
}

static int http_fetch_impl(FetchCtx *ctx, const char *url, char **body, size_t *len,
                           DhallError *err);

/* non-blocking connect with timeout; 0 ok, -1 fail (sets *err) */
static int connect_timeout(FetchCtx *ctx, int fd, const struct sockaddr *addr,
                           socklen_t alen, DhallError *err, const char *url) {
    if (connect(fd, addr, alen) == 0) return 0;
    if (errno != EINPROGRESS) {
        dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                        "missing import: cannot connect to '%s'", url);
        return -1;
    }
    if (wait_fd(ctx, fd, POLLOUT, err, url) != 0) return -1;
    int soerr = 0;
    socklen_t sl = sizeof soerr;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) != 0 || soerr != 0) {
        dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                        "missing import: cannot connect to '%s'", url);
        return -1;
    }
    return 0;
}

static int http_fetch_impl(FetchCtx *ctx, const char *url, char **body, size_t *len,
                           DhallError *err) {
    Url u;
    if (url_parse(url, &u) != 0) {
        dhall_error_set(err, ERR_IO, SPAN_NONE, "malformed URL '%s'", url);
        return HTTP_HARD;
    }
    if (strcmp(u.scheme, "http") != 0) {
        dhall_error_set(err, ERR_IO, SPAN_NONE,
                        "%s:// imports are not supported in this build (no TLS)", u.scheme);
        url_free(&u);
        return HTTP_HARD;
    }
    if (strlen(url) > HTTP_MAX_URL) {
        dhall_error_set(err, ERR_IO, SPAN_NONE, "URL too long");
        url_free(&u);
        return HTTP_HARD;
    }

    /* resolve + SSRF (DNS-rebinding defense: reject if ANY addr is blocked) */
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portbuf[8];
    snprintf(portbuf, sizeof portbuf, "%d", u.port ? u.port : 80);
    int gai = getaddrinfo(u.host, portbuf, &hints, &res);
    if (gai != 0 || !res) {
        dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                        "missing import: cannot resolve host '%s'", u.host);
        url_free(&u);
        return HTTP_ABSENT;
    }
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        if (ssrf_addr_blocked(ai->ai_addr)) {
            freeaddrinfo(res);
            dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                            "missing import: URL blocked (non-public address)");
            url_free(&u);
            return HTTP_ABSENT;
        }
    }

    /* connect ONLY to a validated sockaddr (never the hostname string) */
    int fd = socket(res->ai_family, SOCK_STREAM, 0);
    if (fd < 0) {
        freeaddrinfo(res);
        dhall_error_set(err, ERR_MISSING, SPAN_NONE, "missing import: socket failed");
        url_free(&u);
        return HTTP_ABSENT;
    }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int cr = connect_timeout(ctx, fd, res->ai_addr, res->ai_addrlen, err, url);
    freeaddrinfo(res);
    if (cr != 0) { close(fd); url_free(&u); return HTTP_ABSENT; }

    /* send GET request */
    char req[HTTP_MAX_URL + 256];
    int rlen = snprintf(req, sizeof req,
                        "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n",
                        u.path, u.host);
    if (rlen < 0 || (size_t)rlen >= sizeof req) {
        close(fd);
        dhall_error_set(err, ERR_IO, SPAN_NONE, "URL too long");
        url_free(&u);
        return HTTP_HARD;
    }
    if (!send_all(ctx, fd, req, (size_t)rlen, err, url)) {
        close(fd); url_free(&u);
        return (err->stage == ERR_MISSING) ? HTTP_ABSENT : HTTP_HARD;
    }

    /* read the whole response (headers + body), capped */
    char *raw = NULL;
    size_t rawlen = 0, rawcap = 0;
    if (!recv_all(ctx, fd, &raw, &rawlen, &rawcap, err, url)) {
        free(raw); close(fd); url_free(&u);
        return (err->stage == ERR_MISSING) ? HTTP_ABSENT : HTTP_HARD;
    }
    close(fd);

    /* split headers / body */
    char *hend = find_bytes(raw, rawlen, "\r\n\r\n", 4);
    if (!hend) {
        free(raw);
        dhall_error_set(err, ERR_IO, SPAN_NONE, "malformed HTTP response from '%s'", url);
        url_free(&u);
        return HTTP_HARD;
    }
    size_t hdrlen = (size_t)(hend - raw) + 4;
    int code = parse_status(raw, hdrlen);
    if (code <= 0) {
        free(raw);
        dhall_error_set(err, ERR_IO, SPAN_NONE, "malformed HTTP response from '%s'", url);
        url_free(&u);
        return HTTP_HARD;
    }
    const char *location = NULL; size_t loc_len = 0;
    bool chunked = false;
    parse_headers(raw, hdrlen, &location, &loc_len, &chunked);
    const char *body_start = raw + hdrlen;
    size_t body_raw_len = rawlen - hdrlen;

    /* redirects */
    if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
        if (!location) {
            free(raw);
            dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                            "missing import: HTTP %d from '%s' (no Location)", code, url);
            url_free(&u);
            return HTTP_ABSENT;
        }
        if (ctx->redirects_left <= 0) {
            free(raw);
            dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                            "missing import: too many redirects fetching '%s'", url);
            url_free(&u);
            return HTTP_ABSENT;
        }
        char *next = resolve_location(url, location, loc_len);
        url_free(&u);
        if (!next) {
            free(raw);
            dhall_error_set(err, ERR_IO, SPAN_NONE, "malformed redirect Location from '%s'", url);
            return HTTP_HARD;
        }
        /* re-validate scheme + resolve + SSRF on the next hop (recursion) */
        Url nu;
        if (url_parse(next, &nu) != 0) {
            free(raw); free(next);
            dhall_error_set(err, ERR_IO, SPAN_NONE, "malformed redirect URL from '%s'", url);
            return HTTP_HARD;
        }
        if (strcmp(nu.scheme, "http") != 0) {
            free(raw); free(next);
            dhall_error_set(err, ERR_IO, SPAN_NONE,
                            "%s:// redirects are not supported (no TLS)", nu.scheme);
            url_free(&nu);
            return HTTP_HARD;
        }
        url_free(&nu);
        free(raw);
        ctx->redirects_left--;
        int r = http_fetch_impl(ctx, next, body, len, err);
        free(next);
        return r;
    }

    /* non-2xx is absent */
    if (code < 200 || code >= 300) {
        free(raw);
        dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                        "missing import: HTTP %d from '%s'", code, url);
        url_free(&u);
        return HTTP_ABSENT;
    }

    /* final body: de-chunk or raw */
    char *out = NULL;
    size_t outlen = 0;
    if (chunked) {
        if (!de_chunk(body_start, body_raw_len, &out, &outlen)) {
            free(raw);
            dhall_error_set(err, ERR_IO, SPAN_NONE, "malformed chunked response from '%s'", url);
            url_free(&u);
            return HTTP_HARD;
        }
    } else {
        out = malloc(body_raw_len + 1);
        if (!out) {
            free(raw);
            dhall_error_set(err, ERR_IO, SPAN_NONE, "out of memory");
            url_free(&u);
            return HTTP_HARD;
        }
        memcpy(out, body_start, body_raw_len);
        out[body_raw_len] = '\0';
        outlen = body_raw_len;
    }
    free(raw);
    url_free(&u);

    if (outlen > HTTP_MAX_BODY) {
        free(out);
        dhall_error_set(err, ERR_IO, SPAN_NONE, "response from '%s' exceeds 16 MiB", url);
        return HTTP_HARD;
    }
    *body = out;
    *len = outlen;
    return HTTP_OK;
}

#endif /* __EMSCRIPTEN__ */

int http_fetch(const char *url, char **body, size_t *len, DhallError *err) {
#ifdef __EMSCRIPTEN__
    (void)url; (void)body; (void)len;
    dhall_error_set(err, ERR_MISSING, SPAN_NONE,
                    "missing import: network unavailable (URL imports are not supported in wasm)");
    return HTTP_ABSENT;
#else
    if (body) *body = NULL;
    if (len) *len = 0;
    FetchCtx ctx;
    ctx.redirects_left = HTTP_MAX_REDIRECTS;
    ctx.deadline_ms = now_ms();
    if (ctx.deadline_ms >= 0) ctx.deadline_ms += HTTP_DEADLINE_MS;
    return http_fetch_impl(&ctx, url, body, len, err);
#endif
}
