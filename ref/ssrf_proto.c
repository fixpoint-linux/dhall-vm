/* ref/ssrf_proto.c — VERIFIED SSRF IP-classification logic + self-test harness.
 *
 * This is prototype/verification code produced during planning of the
 * dhall-c URL/http import feature (unit 2). It is NOT part of the final
 * change; the implementer should fold `ssrf_addr_blocked` (and the mask
 * tables) into a new src/ssrf.c, and the test vectors into tests/ssrf_test.c.
 *
 * VERIFIED: 36/36 classification vectors pass under BOTH
 *   gcc -std=c11 -Wall -Wextra   and   cosmocc -std=c11 -O2 -Wall -Wextra.
 * The only compiler warning was an unused `len` param (dropped in the
 * export below).
 *
 * The classifier answers: is this resolved socket address private / loopback /
 * link-local / reserved / multicast / unspecified?  The real feature resolves
 * a hostname with getaddrinfo(AF_UNSPEC) and rejects the connection if ANY
 * resolved address is blocked — the DNS-rebinding defense.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>

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
    /* ::ffff:0:0/96 IPv4-mapped: recurse into the embedded IPv4 */
    bool is_mapped = true;
    for (i = 0; i < 10; i++) if (b[i]) { is_mapped = false; break; }
    if (is_mapped && b[10] == 0xFF && b[11] == 0xFF)
        return ipv4_bytes_blocked(&b[12]);

    bool z = true; for (i = 0; i < 16; i++) if (b[i]) { z = false; break; }
    if (z) return true; /* ::/128 */

    bool lb = true; for (i = 0; i < 15; i++) if (b[i]) { lb = false; break; }
    if (lb && b[15] == 0x01) return true; /* ::1/128 */

    if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return true; /* fe80::/10 */
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
    if (sa->sa_family == AF_INET)
        return ipv4_blocked(ntohl(((struct sockaddr_in *)sa)->sin_addr.s_addr));
    if (sa->sa_family == AF_INET6)
        return ipv6_blocked(((struct sockaddr_in6 *)sa)->sin6_addr.s6_addr);
    return true; /* unknown family: fail closed */
}

/* ---- self-test ---- */
static int fails, checks;
static void chk(const char *label, bool got, bool want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %-28s got=%s want=%s\n", label,
        got ? "blocked" : "public", want ? "blocked" : "public"); }
    else printf("ok   %-28s %s\n", label, got ? "blocked" : "public");
}
static void chk_v4(const char *label, const char *ip, bool want) {
    struct sockaddr_in s; memset(&s, 0, sizeof s); s.sin_family = AF_INET;
    inet_pton(AF_INET, ip, &s.sin_addr);
    chk(label, ssrf_addr_blocked((struct sockaddr *)&s), want);
}
static void chk_v6(const char *label, const char *ip, bool want) {
    struct sockaddr_in6 s; memset(&s, 0, sizeof s); s.sin6_family = AF_INET6;
    inet_pton(AF_INET6, ip, &s.sin6_addr);
    chk(label, ssrf_addr_blocked((struct sockaddr *)&s), want);
}
int main(void) {
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
    printf("\n%d checks, %d failures\n", checks, fails);
    return fails == 0 ? 0 : 1;
}
