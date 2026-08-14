/* tests/ssrf_test.c — standalone unit test for src/ssrf.c (SSRF classifier +
   url_parse). Compiled by the Makefile `test-ssrf` target with cosmocc and run
   as part of `make test`. Asserts the 36 classification vectors (VERIFIED in
   ref/ssrf_proto.c) plus url_parse vectors. Exits nonzero on any failure. */
#include "ssrf.h"

#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>

static int fails, checks;

static void chk(const char *label, bool got, bool want) {
    checks++;
    if (got != want) {
        fails++;
        printf("FAIL %-28s got=%s want=%s\n", label,
               got ? "blocked" : "public", want ? "blocked" : "public");
    } else {
        printf("ok   %-28s %s\n", label, got ? "blocked" : "public");
    }
}

static void chk_v4(const char *label, const char *ip, bool want) {
    struct sockaddr_in s; memset(&s, 0, sizeof s); s.sin_family = AF_INET;
    if (inet_pton(AF_INET, ip, &s.sin_addr) != 1) {
        checks++; fails++;
        printf("FAIL %-28s bad IPv4 literal %s\n", label, ip);
        return;
    }
    chk(label, ssrf_addr_blocked((struct sockaddr *)&s), want);
}

static void chk_v6(const char *label, const char *ip, bool want) {
    struct sockaddr_in6 s; memset(&s, 0, sizeof s); s.sin6_family = AF_INET6;
    if (inet_pton(AF_INET6, ip, &s.sin6_addr) != 1) {
        checks++; fails++;
        printf("FAIL %-28s bad IPv6 literal %s\n", label, ip);
        return;
    }
    chk(label, ssrf_addr_blocked((struct sockaddr *)&s), want);
}

/* url_parse helper: parse and assert each field, then free. */
static void chk_url(const char *label, const char *spec, bool ok,
                    const char *scheme, const char *host, int port, const char *path) {
    Url u;
    checks++;
    int rc = url_parse(spec, &u);
    if (!ok) {
        if (rc == 0) {
            fails++;
            printf("FAIL %-28s parsed but should have failed\n", label);
            url_free(&u);
        } else {
            printf("ok   %-28s rejected\n", label);
        }
        return;
    }
    if (rc != 0) {
        fails++;
        printf("FAIL %-28s url_parse returned -1\n", label);
        return;
    }
    bool good = !strcmp(u.scheme, scheme) && !strcmp(u.host, host) &&
                u.port == port && !strcmp(u.path, path);
    if (!good) {
        fails++;
        printf("FAIL %-28s got scheme=%s host=%s port=%d path=%s\n",
               label, u.scheme, u.host, u.port, u.path);
    } else {
        printf("ok   %-28s %s://%s%s\n", label, u.scheme, u.host, u.path);
    }
    url_free(&u);
}

int main(void) {
    /* ---- 36 classification vectors (verbatim from ref/ssrf_proto.c) ---- */
    chk_v4("0.0.0.0", "0.0.0.0", true);
    chk_v4("10.0.0.1", "10.0.0.1", true);
    chk_v4("100.64.0.1 CGNAT", "100.64.0.1", true);
    chk_v4("127.0.0.1", "127.0.0.1", true);
    chk_v4("127.255.255.255", "127.255.255.255", true);
    chk_v4("169.254.169.254", "169.254.169.254", true);
    chk_v4("172.16.0.1", "172.16.0.1", true);
    chk_v4("172.31.255.255", "172.31.255.255", true);
    chk_v4("192.0.0.1", "192.0.0.1", true);
    chk_v4("192.0.2.1 TEST", "192.0.2.1", true);
    chk_v4("192.88.99.1", "192.88.99.1", true);
    chk_v4("192.168.0.1", "192.168.0.1", true);
    chk_v4("198.18.0.1 bench", "198.18.0.1", true);
    chk_v4("198.51.100.1", "198.51.100.1", true);
    chk_v4("203.0.113.1", "203.0.113.1", true);
    chk_v4("224.0.0.1 mcast", "224.0.0.1", true);
    chk_v4("255.255.255.255", "255.255.255.255", true);
    chk_v4("1.1.1.1", "1.1.1.1", false);
    chk_v4("8.8.8.8", "8.8.8.8", false);
    chk_v4("93.184.216.34", "93.184.216.34", false);
    chk_v4("172.32.0.1 public", "172.32.0.1", false);
    chk_v4("192.169.0.1 public", "192.169.0.1", false);
    chk_v6("::", "::", true);
    chk_v6("::1", "::1", true);
    chk_v6("::ffff:127.0.0.1", "::ffff:127.0.0.1", true);
    chk_v6("::ffff:10.0.0.1", "::ffff:10.0.0.1", true);
    chk_v6("fe80::1", "fe80::1", true);
    chk_v6("fc00::1 ULA", "fc00::1", true);
    chk_v6("fd12::1 ULA", "fd12::1", true);
    chk_v6("ff02::1 mcast", "ff02::1", true);
    chk_v6("2001:db8::1", "2001:db8::1", true);
    chk_v6("64:ff9b::808:808", "64:ff9b::808:808", true);
    chk_v6("2002::1 6to4", "2002::1", true);
    chk_v6("2606:4700:4700::1111", "2606:4700:4700::1111", false);
    chk_v6("2001:4860:4860::8888", "2001:4860:4860::8888", false);
    chk_v6("::ffff:1.1.1.1", "::ffff:1.1.1.1", false);
    /* IPv4-compatible ::/96 must recurse into the embedded IPv4 too */
    chk_v6("::127.0.0.1 compatible", "::127.0.0.1", true);
    chk_v6("::10.0.0.1 compatible", "::10.0.0.1", true);
    chk_v6("::169.254.169.254 compatible", "::169.254.169.254", true);
    chk_v6("::8.8.8.8 public", "::8.8.8.8", false);
    chk_v6("fec0::1 site-local", "fec0::1", true);

    /* ---- url_parse vectors ---- */
    chk_url("http basic",       "http://example.com",        true, "http", "example.com", 0,    "/");
    chk_url("http port",        "http://example.com:8080/x", true, "http", "example.com", 8080, "/x");
    chk_url("http path",        "http://example.com/a/b/c",  true, "http", "example.com", 0,    "/a/b/c");
    chk_url("http empty path",  "http://example.com/",       true, "http", "example.com", 0,    "/");
    chk_url("https default",    "https://example.com",       true, "https", "example.com", 0,   "/");
    chk_url("ipv6 bracketed",   "http://[::1]:8080/x",       true, "http", "::1",        8080, "/x");
    chk_url("ipv6 no port",     "http://[::1]/x",            true, "http", "::1",        0,    "/x");
    chk_url("uppercase scheme", "HTTP://Example.COM/p",      true, "http", "Example.COM", 0,   "/p");
    chk_url("query stripped",   "http://example.com/x?q=1",  true, "http", "example.com", 0,    "/x");
    chk_url("fragment stripped","http://example.com/x#frag", true, "http", "example.com", 0,    "/x");
    chk_url("no scheme",        "example.com",               false, "", "", 0, "");
    chk_url("empty host",       "http:///x",                 false, "", "", 0, "");
    chk_url("bad port",         "http://example.com:abc/x",  false, "", "", 0, "");
    chk_url("port zero",        "http://example.com:0/x",    false, "", "", 0, "");
    chk_url("unterminated brkt","http://[::1/x",             false, "", "", 0, "");
    chk_url("userinfo rejected","http://user:pass@h/x",      false, "", "", 0, "");
    chk_url("unbracketed v6",   "http://::1/x",              false, "", "", 0, "");
    /* CRLF / ctl / space injection into host or path (redirect Location) */
    chk_url("crlf in path",      "http://h/ok\nHost: evil",  false, "", "", 0, "");
    chk_url("ctl in host",       "http://h\x01ost/x",        false, "", "", 0, "");
    chk_url("space in path",     "http://h/a b",             false, "", "", 0, "");
    chk_url("no injection ok",   "http://h/a%20b",           true,  "http", "h", 0, "/a%20b");

    printf("\n%d checks, %d failures\n", checks, fails);
    return fails == 0 ? 0 : 1;
}
