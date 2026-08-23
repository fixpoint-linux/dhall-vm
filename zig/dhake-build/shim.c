/* shim.c — glibc-side definitions for dhake.c's cosmopolitan-only externals:
   the three landlock syscall wrappers and the `extern const int __NR_socket`
   global dhake.c references in its seccomp BPF filter. */
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/landlock.h>
#include <stddef.h>

int landlock_create_ruleset(const struct landlock_ruleset_attr *attr, size_t size, unsigned int flags) {
    return (int)syscall(__NR_landlock_create_ruleset, attr, size, flags);
}
int landlock_add_rule(int ruleset_fd, int rule_type, const void *rule_attr, unsigned int flags) {
    return (int)syscall(__NR_landlock_add_rule, ruleset_fd, rule_type, rule_attr, flags);
}
int landlock_restrict_self(int ruleset_fd, unsigned int flags) {
    return (int)syscall(__NR_landlock_restrict_self, ruleset_fd, flags);
}

/* sys/syscall.h defines __NR_socket (and SYS_socket) as macros; dhake.c
   declares the same name as an extern global. Capture the numeric value while
   the macro is live, then undef and provide the real variable. */
static const long dhall_shim_socket_nr = (long)SYS_socket; /* = __NR_socket (41 on x86_64) */
#undef __NR_socket
const int __NR_socket = (int)dhall_shim_socket_nr;
