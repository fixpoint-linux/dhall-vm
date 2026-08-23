/* u2_token_dump.c — U2 twin-driver (C side). Lexes the file given on argv[1]
   with the real C lexer and prints one line per token:
       <TOKTYPE> <line>:<col> <text>
   where <text> is the token name/import-spec/hash, the decimal value for
   numbers, the raw double bits for T_DBL, the error message for T_ERROR, and
   "<none>" otherwise. Byte-identical to the Zig twin driver (zig/src/
   token_dump.zig); the U2 gate diffs the two streams across the corpus. */
#include "dhall.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static const char *tnames[41] = {
    "T_EOF","T_NAT","T_INT","T_DBL","T_STR_OPEN","T_STR_OPEN_MULTILINE","T_NAME","T_LAMBDA","T_ARROW",
    "T_COLON","T_EQUALS","T_COMMA","T_DOT","T_LPAREN","T_RPAREN","T_LBRACE","T_RBRACE","T_LANGLE","T_RANGLE",
    "T_LBRACKET","T_RBRACKET","T_PLUSPLUS","T_PLUS","T_MINUS","T_STAR","T_LT","T_LE","T_GT","T_GE","T_EQEQ",
    "T_NE","T_IMPORT","T_SHA256","T_QMARK","T_BAR","T_MERGE","T_PREFER","T_AND","T_OR","T_HASH","T_ERROR",
};

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 3;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *src = malloc((size_t)sz + 1);
    if (!src) return 4;
    fread(src, 1, (size_t)sz, f);
    src[sz] = '\0';
    fclose(f);

    dhall_arena = arena_new();
    Lexer lx;
    lexer_init(&lx, src, argv[1]);
    for (;;) {
        Token t = lexer_next(&lx);
        printf("%s %d:%d ", tnames[(int)t.type], t.span.line, t.span.col);
        switch (t.type) {
        case T_NAT: {
            uint32_t scratch[2];
            BigNat B = const_bignat(t.c, scratch);
            fputs(bignat_to_decimal(&B), stdout);
            break;
        }
        case T_INT: {
            uint32_t scratch[2];
            BigInt B = const_bigint(t.c, scratch);
            fputs(bigint_to_decimal(&B), stdout);
            break;
        }
        case T_DBL: {
            uint64_t bits;
            memcpy(&bits, &t.c.dbl, 8);
            printf("%016llx", (unsigned long long)bits);
            break;
        }
        case T_NAME: case T_IMPORT: case T_SHA256:
            fputs(t.name ? t.name : "<none>", stdout);
            break;
        case T_ERROR:
            fputs(lx.err.msg, stdout);
            break;
        default:
            fputs("<none>", stdout);
        }
        putchar('\n');
        if (t.type == T_EOF) break;
    }
    return 0;
}
