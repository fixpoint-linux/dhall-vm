/* main.c — CLI entry point.
     dhall typecheck [file|-]
     dhall normalize [file|-]
     dhall to-json   [file|-]
   Reads source from stdin or a file. Prints the inferred type (typecheck),
   the normal form (normalize), or JSON (to-json). Exit codes: 0 ok,
   1 type error, 2 parse/lex error, 3 internal/IO/JSON. */
#include "dhall.h"

static char *read_all(FILE *f, size_t *len_out) {
    size_t cap = 65536, len = 0;
    char *buf = malloc(cap);
    if (!buf) return NULL;
    for (;;) {
        if (len == cap) { cap *= 2; buf = realloc(buf, cap); if (!buf) return NULL; }
        size_t n = fread(buf + len, 1, cap - len, f);
        len += n;
        if (n == 0) break;
    }
    buf[len] = '\0';
    if (len_out) *len_out = len;
    return buf;
}

static void print_error(const DhallError *e) {
    fprintf(stderr, "Error: %s", e->msg);
    if (e->has_span)
        fprintf(stderr, " (at line %d, col %d)", e->span.line, e->span.col);
    fputc('\n', stderr);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s typecheck|normalize|to-json [file|-]\n", argv[0]);
        return 3;
    }
    const char *mode = argv[1];
    bool want_typecheck = !strcmp(mode, "typecheck");
    bool want_normalize = !strcmp(mode, "normalize");
    bool want_json = !strcmp(mode, "to-json");
    if (!want_typecheck && !want_normalize && !want_json) {
        fprintf(stderr, "Error: unknown mode '%s' (expected typecheck|normalize|to-json)\n", mode);
        return 3;
    }

    /* read input */
    FILE *in = stdin;
    bool close_in = false;
    if (argc >= 3 && strcmp(argv[2], "-") != 0) {
        in = fopen(argv[2], "rb");
        if (!in) {
            fprintf(stderr, "Error: cannot open file '%s'\n", argv[2]);
            return 3;
        }
        close_in = true;
    }
    size_t src_len = 0;
    char *src = read_all(in, &src_len);
    if (close_in) fclose(in);
    if (!src) { fprintf(stderr, "Error: out of memory\n"); return 3; }

    /* per-evaluation arena */
    if (!dhall_arena) dhall_arena = arena_new();
    arena_reset(dhall_arena);

    Parser p;
    memset(&p, 0, sizeof(p));
    DhallError err;
    dhall_error_clear(&err);

    Term *t = parse_source(&p, src, &err);
    free(src);
    if (!t) { print_error(&err); return dhall_error_exit(&err); }

    if (want_typecheck) {
        Term *ty = infer_type(&p, t, &err);
        if (!ty) { print_error(&err); return dhall_error_exit(&err); }
        Term *nty = normalize(ty);
        print_term(stdout, nty);
        fputc('\n', stdout);
        return 0;
    }

    Term *nf = normalize(t);

    if (want_normalize) {
        print_term(stdout, nf);
        fputc('\n', stdout);
        return 0;
    }

    /* to-json */
    if (!term_to_json(stdout, nf, &err)) { print_error(&err); return dhall_error_exit(&err); }
    fputc('\n', stdout);
    return 0;
}
