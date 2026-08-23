/* shim for cosmopolitan <libc/calls/landlock.h> — redirect to linux/landlock.h
   and DECLARE the three landlock syscall wrappers (defined in shim.c; glibc
   does not provide them). Kept free of <sys/syscall.h> so the __NR_* macros it
   defines (e.g. __NR_socket) don't collide with dhake.c's `extern const int
   __NR_socket;`. */
#ifndef COSMO_CALLS_LANDLOCK_H
#define COSMO_CALLS_LANDLOCK_H

#include <linux/landlock.h>
#include <stddef.h>

int landlock_create_ruleset(const struct landlock_ruleset_attr *attr, size_t size, unsigned int flags);
int landlock_add_rule(int ruleset_fd, int rule_type, const void *rule_attr, unsigned int flags);
int landlock_restrict_self(int ruleset_fd, unsigned int flags);

#endif /* COSMO_CALLS_LANDLOCK_H */
