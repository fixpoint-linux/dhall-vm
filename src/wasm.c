/* wasm.c — browser-callable entry point for the Dhall interpreter.
 *
 * Built to wasm via emscripten INSTEAD OF main.c (this file defines the
 * entry surface; main.c is not linked). Exports:
 *
 *   int         dhall_run(int mode, const char *src, int src_len)
 *   const char *dhall_out(void)
 *   int         dhall_out_len(void)
 *
 * mode: 0=typecheck 1=normalize 2=to-json 3=to-toml 4=to-yaml
 *
 * All output (the result, or an "Error: ..." message) is written to a
 * module-global growable buffer via open_memstream, so print_term() and the
 * serialize.c writers run UNCHANGED (they only ever use fputc/fputs/fprintf
 * on the FILE* they are handed). No fd_write/stdout is used at all, so the
 * browser needs no stdio shim.
 */
#include "dhall.h"
#include <emscripten.h>

static char  *g_out = NULL;
static size_t g_out_len = 0;

/* Format an error into g_out and return the process exit code. */
static int emit_error(DhallError *err, ImportLoader *loader) {
    free(g_out);
    g_out = NULL;
    g_out_len = 0;
    FILE *f = open_memstream(&g_out, &g_out_len);
    if (f) {
        fprintf(f, "Error: %s", err->msg);
        if (err->has_span) fprintf(f, " (at line %d, col %d)", err->span.line, err->span.col);
        fputc('\n', f);
        fclose(f);
    }
    import_loader_free(loader);
    return dhall_error_exit(err);
}

EMSCRIPTEN_KEEPALIVE
int dhall_run(int mode, const char *src, int src_len) {
    (void)src_len; /* src is NUL-terminated by the JS caller; length is informational */

    free(g_out);
    g_out = NULL;
    g_out_len = 0;

    if (!dhall_arena) dhall_arena = arena_new();
    arena_reset(dhall_arena);

    ImportLoader *loader = import_loader_new();
    import_loader_push_root(loader, NULL); /* no root file: relative imports fail (empty FS) */

    Parser p;
    memset(&p, 0, sizeof(p));
    p.loader = loader;
    DhallError err;
    dhall_error_clear(&err);

    Term *t = parse_source(&p, src, NULL, &err);
    if (!t) return emit_error(&err, loader);

    /* typecheck */
    if (mode == 0) {
        Term *ty = infer_type(&p, t, &err);
        if (!ty) return emit_error(&err, loader);
        normalize_clear_error();
        Term *nty = normalize(ty);
        if (normalize_has_error()) { err = *normalize_get_error(); return emit_error(&err, loader); }
        FILE *f = open_memstream(&g_out, &g_out_len);
        print_term(f, nty);
        fputc('\n', f);
        fclose(f);
        import_loader_free(loader);
        return 0;
    }

    normalize_clear_error();
    Term *nf = normalize(t);
    if (normalize_has_error()) { err = *normalize_get_error(); return emit_error(&err, loader); }

    if (mode == 1) { /* normalize */
        FILE *f = open_memstream(&g_out, &g_out_len);
        print_term(f, nf);
        fputc('\n', f);
        fclose(f);
    } else if (mode == 2 || mode == 3 || mode == 4) {
        SerFormat fmt = (mode == 2) ? FMT_JSON : (mode == 3) ? FMT_TOML : FMT_YAML;
        FILE *f = open_memstream(&g_out, &g_out_len);
        if (!term_serialize(f, nf, fmt, &err)) {
            fclose(f);
            free(g_out); g_out = NULL; g_out_len = 0;
            return emit_error(&err, loader);
        }
        if (mode == 2) fputc('\n', f); /* JSON: single line, no trailing newline from writer */
        fclose(f);
    } else {
        FILE *f = open_memstream(&g_out, &g_out_len);
        fprintf(f, "Error: unknown mode %d\n", mode);
        fclose(f);
        import_loader_free(loader);
        return 3;
    }

    import_loader_free(loader);
    return 0;
}

EMSCRIPTEN_KEEPALIVE
const char *dhall_out(void) { return g_out ? g_out : ""; }

EMSCRIPTEN_KEEPALIVE
int dhall_out_len(void) { return (int)g_out_len; }
