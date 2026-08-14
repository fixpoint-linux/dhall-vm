/* ssrf.h — SSRF address classifier + URL parsing (security-critical).
   Kept dependency-free (no dhall.h) so it can be unit-tested standalone.

   The classifier answers: is this RESOLVED socket address private / loopback /
   link-local / reserved / multicast / unspecified?  http.c resolves a hostname
   with getaddrinfo(AF_UNSPEC) and rejects the connection if ANY resolved
   address is blocked — the DNS-rebinding defense.  Unknown address families
   fail closed (blocked). */
#ifndef SSRF_H
#define SSRF_H

#include <stdbool.h>

struct sockaddr;

/* Parsed URL. Caller must url_free() it. */
typedef struct {
    char *scheme;   /* lowercase scheme, no ':'; e.g. "http" */
    char *host;     /* host without surrounding [ ] brackets */
    int   port;     /* numeric port, or 0 if absent (scheme default applies) */
    char *path;     /* path, always begins with '/', no ?query/#fragment */
} Url;

/* true => this resolved address must NOT be contacted (fail-closed). */
bool ssrf_addr_blocked(const struct sockaddr *sa);

/* Parse a URL like "http://host[:port][/path]" or "http://[::1]:8080/path".
   Returns 0 on success (out fully populated), -1 on malformed input.
   Userinfo (user:pass@host) is NOT supported and is rejected as malformed. */
int url_parse(const char *spec, Url *out);

void url_free(Url *u);

#endif /* SSRF_H */
