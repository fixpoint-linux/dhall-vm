/* main.c — CLI entry point.
     dhall typecheck [file|-]
     dhall normalize [file|-]
     dhall to-json   [file|-]
     dhall to-toml   [file|-]
     dhall to-yaml   [file|-]
   Reads source from stdin or a file. Prints the inferred type (typecheck),
   the normal form (normalize), or a serialized form (to-json/to-toml/to-yaml).
   Exit codes: 0 ok, 1 type error, 2 parse/lex error, 3 internal/IO/serialize. */
#include "dhall.h"

static char *read_all(FILE *f, size_t *len_out) {
    size_t cap = 65536, len = 0;
    char *buf = malloc(cap);
    if (!buf) return NULL;
    for (;;) {
        if (len == cap) { cap *= 2; char *nb = realloc(buf, cap); if (!nb) { free(buf); return NULL; } buf = nb; }
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
    if (e->has_span) {
        if (e->span.file)
            fprintf(stderr, " (at %s:%d:%d)", e->span.file, e->span.line, e->span.col);
        else
            fprintf(stderr, " (at line %d, col %d)", e->span.line, e->span.col);
    }
    fputc('\n', stderr);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s typecheck|normalize|to-json|to-toml|to-yaml [file|-]\n", argv[0]);
        return 3;
    }
    const char *mode = argv[1];
    bool want_typecheck = !strcmp(mode, "typecheck");
    bool want_normalize = !strcmp(mode, "normalize");
    bool want_json = !strcmp(mode, "to-json");
    bool want_toml = !strcmp(mode, "to-toml");
    bool want_yaml = !strcmp(mode, "to-yaml");
    if (!want_typecheck && !want_normalize && !want_json && !want_toml && !want_yaml) {
        fprintf(stderr, "Error: unknown mode '%s' (expected typecheck|normalize|to-json|to-toml|to-yaml)\n", mode);
        return 3;
    }

    /* read input */
    FILE *in = stdin;
    bool close_in = false;
    const char *src_file = NULL;
    if (argc >= 3 && strcmp(argv[2], "-") != 0) {
        in = fopen(argv[2], "rb");
        if (!in) {
            fprintf(stderr, "Error: cannot open file '%s'\n", argv[2]);
            return 3;
        }
        close_in = true;
        src_file = argv[2];
    }
    size_t src_len = 0;
    char *src = read_all(in, &src_len);
    if (close_in) fclose(in);
    if (!src) { fprintf(stderr, "Error: out of memory\n"); return 3; }

    /* per-evaluation arena (reset ONCE; imported files allocate into it) */
    if (!dhall_arena) dhall_arena = arena_new();
    arena_reset(dhall_arena);

    ImportLoader *loader = import_loader_new();
    import_loader_push_root(loader, src_file);

    Parser p;
    memset(&p, 0, sizeof(p));
    p.loader = loader;
    DhallError err;
    dhall_error_clear(&err);

    Term *t = parse_source(&p, src, src_file, &err);
    free(src);
    if (!t) { print_error(&err); import_loader_free(loader); return dhall_error_exit(&err); }

    if (want_typecheck) {
        Term *ty = infer_type(&p, t, &err);
        if (!ty) { print_error(&err); import_loader_free(loader); return dhall_error_exit(&err); }
        normalize_clear_error();
        Term *nty = normalize(ty);
        if (normalize_has_error()) {
            err = *normalize_get_error();
            print_error(&err);
            import_loader_free(loader);
            return dhall_error_exit(&err);
        }
        print_term(stdout, nty);
        fputc('\n', stdout);
        import_loader_free(loader);
        return 0;
    }

    normalize_clear_error();
    Term *nf = normalize(t);
    if (normalize_has_error()) {
        err = *normalize_get_error();
        print_error(&err);
        import_loader_free(loader);
        return dhall_error_exit(&err);
    }

    if (want_normalize) {
        print_term(stdout, nf);
        fputc('\n', stdout);
        import_loader_free(loader);
        return 0;
    }

    /* serializers: to-json / to-toml / to-yaml */
    if (want_json) {
        if (!term_to_json(stdout, nf, &err)) { print_error(&err); import_loader_free(loader); return dhall_error_exit(&err); }
        fputc('\n', stdout); /* JSON is single-line; the serializer adds no trailing newline */
    } else if (want_toml) {
        if (!term_to_toml(stdout, nf, &err)) { print_error(&err); import_loader_free(loader); return dhall_error_exit(&err); }
        /* TOML output carries its own trailing newline */
    } else if (want_yaml) {
        if (!term_to_yaml(stdout, nf, &err)) { print_error(&err); import_loader_free(loader); return dhall_error_exit(&err); }
        /* YAML output carries its own trailing newline */
    }
    import_loader_free(loader);
    return 0;
}
