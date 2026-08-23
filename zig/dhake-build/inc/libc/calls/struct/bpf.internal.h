/* shim for cosmopolitan <libc/calls/struct/bpf.internal.h> — linux/filter.h
   provides struct sock_filter/sock_fprog and the BPF_STMT/BPF_JUMP construction
   macros but NOT the classic opcode constants; define those here. */
#ifndef COSMO_CALLS_STRUCT_BPF_INTERNAL_H
#define COSMO_CALLS_STRUCT_BPF_INTERNAL_H

#include <linux/filter.h>

/* classic socket-filter opcodes / modes (Linux stable ABI) */
#define BPF_LD   0x00
#define BPF_W    0x00
#define BPF_ABS  0x20
#define BPF_JMP  0x05
#define BPF_JEQ  0x10
#define BPF_K    0x00
#define BPF_RET  0x06

#endif
