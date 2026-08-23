/* shim for cosmopolitan <libc/calls/struct/seccomp.internal.h> — redirect to
   linux/seccomp.h (struct seccomp_data, SECCOMP_RET_*, SECCOMP_MODE_FILTER). */
#ifndef COSMO_CALLS_STRUCT_SECCOMP_INTERNAL_H
#define COSMO_CALLS_STRUCT_SECCOMP_INTERNAL_H

#include <linux/seccomp.h>

#endif
