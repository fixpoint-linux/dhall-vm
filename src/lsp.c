/* lsp.c — Language Server Protocol server for the Dhall subset interpreter
   (MVP). Speaks JSON-RPC 2.0 over stdio with Content-Length framing; a single
   synchronous loop. Reuses the interpreter core (parse_source / infer_type /
   normalize / print_term) for diagnostics + hover.

   Layering (shared by the native binary and the wasm build):
     - lsp_handle()      — process one incoming JSON-RPC message; append the
                           resulting response/notification frame(s) (still
                           Content-Length framed) to a module-global output
                           buffer (g_out).
     - lsp_out()/lsp_out_len() — expose that buffer (the wasm entry reads it;
                           the native main() flushes it to stdout).
     - main()            — stdio framing loop (read a frame -> lsp_handle ->
                           fwrite g_out -> repeat), compiled only for the native
                           target (the wasm build passes -DLSP_NO_MAIN and
                           drives lsp_handle directly, mirroring src/wasm.c). */
#include "dhall.h"
#include "json.h"

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define LSP_EXPORT EMSCRIPTEN_KEEPALIVE
#else
#define LSP_EXPORT
#endif

/* ------------------------------------------------------------------ */
/* Output buffer (module-global, reset at the top of each message)    */
/* ------------------------------------------------------------------ */

static char  *g_out = NULL;
static size_t g_out_len = 0;
static size_t g_out_cap = 0;

static void out_add(const char *s, size_t n) {
    if (g_out_len + n + 1 > g_out_cap) {
        size_t cap = g_out_cap ? g_out_cap : 256;
        while (g_out_len + n + 1 > cap) cap *= 2;
        g_out = realloc(g_out, cap);
        if (!g_out) { fputs("dhall-lsp: out of memory\n", stderr); exit(3); }
        g_out_cap = cap;
    }
    memcpy(g_out + g_out_len, s, n);
    g_out_len += n;
    g_out[g_out_len] = '\0';
}

/* Append one Content-Length-framed message (header + body) to g_out. */
static void write_frame(TmpBuf *b) {
    char hdr[64];
    int hn = snprintf(hdr, sizeof hdr, "Content-Length: %zu\r\n\r\n", b->len);
    out_add(hdr, (size_t)hn);
    out_add(b->s, b->len);
}

LSP_EXPORT const char *lsp_out(void) { return g_out ? g_out : ""; }

LSP_EXPORT int lsp_out_len(void) { return (int)g_out_len; }

/* ------------------------------------------------------------------ */
/* Document store (heap, persists across messages)                    */
/* ------------------------------------------------------------------ */

typedef struct { char *uri; char *text; } Doc;
static Doc *g_docs; static int g_ndocs, g_cap;

static const char *docs_get(const char *uri) {
    for (int i = 0; i < g_ndocs; i++)
        if (!strcmp(g_docs[i].uri, uri)) return g_docs[i].text;
    return NULL;
}

static void docs_set(const char *uri, const char *text) {
    for (int i = 0; i < g_ndocs; i++) {
        if (!strcmp(g_docs[i].uri, uri)) {
            free(g_docs[i].text);
            g_docs[i].text = text ? strdup(text) : NULL;
            return;
        }
    }
    if (g_ndocs == g_cap) {
        g_cap = g_cap ? g_cap * 2 : 8;
        g_docs = realloc(g_docs, (size_t)g_cap * sizeof *g_docs);
    }
    g_docs[g_ndocs].uri = strdup(uri);
    g_docs[g_ndocs].text = text ? strdup(text) : NULL;
    g_ndocs++;
}

static void docs_remove(const char *uri) {
    for (int i = 0; i < g_ndocs; i++) {
        if (!strcmp(g_docs[i].uri, uri)) {
            free(g_docs[i].uri);
            free(g_docs[i].text);
            g_docs[i] = g_docs[--g_ndocs];
            return;
        }
    }
}

/* file:///abs -> /abs (no percent-decoding); non-file/untitled -> NULL (CWD) */
static const char *uri_to_path(const char *uri) {
    if (uri && strncmp(uri, "file://", 7) == 0) return uri + 7;
    return NULL;
}

/* print_term writes to a FILE*; capture it as a heap string (caller frees).
   Native uses tmpfile(); wasm uses open_memstream (no MEMFS/tmpfile dependency,
   matching src/wasm.c). */
static char *term_to_string(Term *t) {
#ifdef __EMSCRIPTEN__
    char *s = NULL;
    size_t n = 0;
    FILE *f = open_memstream(&s, &n);
    if (!f) return NULL;
    print_term(f, t);
    fclose(f);
    return s;
#else
    FILE *f = tmpfile();
    if (!f) return NULL;
    print_term(f, t);
    fflush(f);
    long n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    rewind(f);
    char *s = malloc((size_t)n + 1);
    if (!s) { fclose(f); return NULL; }
    size_t r = fread(s, 1, (size_t)n, f);
    s[r] = '\0';
    fclose(f);
    return s;
#endif
}

/* Evaluate the document: parse, infer, normalize the type. On success fills
   *type_str (heap) with the normalized type's printed form; else fills *diag. */
static bool evaluate(const char *root_file, const char *file, const char *text,
                     DhallError *diag, char **type_str) {
    if (type_str) *type_str = NULL;
    arena_reset(dhall_arena);
    ImportLoader *loader = import_loader_new();
    import_loader_push_root(loader, root_file);
    Parser p;
    memset(&p, 0, sizeof p);
    p.loader = loader;
    DhallError err;
    dhall_error_clear(&err);

    Term *t = parse_source(&p, text, file, &err);
    if (!t) { *diag = err; import_loader_free(loader); return false; }

    Term *ty = infer_type(&p, t, &err);
    if (!ty) { *diag = err; import_loader_free(loader); return false; }

    normalize_clear_error();
    Term *nty = normalize(ty);
    if (normalize_has_error()) { *diag = *normalize_get_error(); import_loader_free(loader); return false; }

    if (type_str) *type_str = term_to_string(nty);
    import_loader_free(loader);
    return true;
}

static void publish_diagnostics(const char *uri, const DhallError *diag) {
    TmpBuf b; tmpbuf_init(&b);
    json_write_raw(&b, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
    json_write_string(&b, uri);
    json_write_raw(&b, ",\"diagnostics\":[");
    if (diag) {
        int line = diag->has_span && diag->span.line > 0 ? diag->span.line - 1 : 0;
        int col  = diag->has_span && diag->span.col  > 0 ? diag->span.col  - 1 : 0;
        json_write_raw(&b, "{\"range\":{\"start\":{\"line\":");
        json_write_int(&b, line);
        json_write_raw(&b, ",\"character\":");
        json_write_int(&b, col);
        json_write_raw(&b, "},\"end\":{\"line\":");
        json_write_int(&b, line);
        json_write_raw(&b, ",\"character\":");
        json_write_int(&b, col);
        json_write_raw(&b, "}},\"severity\":1,\"source\":\"dhall-lsp\",\"message\":");
        json_write_string(&b, diag->msg);
        json_write_raw(&b, "}");
    }
    json_write_raw(&b, "]}}");
    write_frame(&b);
    free(b.s);
}

static void handle_doc_change(const char *uri, const char *text) {
    docs_set(uri, text);
    DhallError diag;
    dhall_error_clear(&diag);
    char *type_str = NULL;
    bool ok = evaluate(uri_to_path(uri), uri, text, &diag, &type_str);
    free(type_str);
    publish_diagnostics(uri, ok ? NULL : &diag);
}

static void respond_result(const Json *id, const char *result_frag) {
    TmpBuf b; tmpbuf_init(&b);
    json_write_raw(&b, "{\"jsonrpc\":\"2.0\",\"id\":");
    json_emit(&b, id);
    json_write_raw(&b, ",\"result\":");
    json_write_raw(&b, result_frag);
    json_write_raw(&b, "}");
    write_frame(&b);
    free(b.s);
}

static void respond_error(const Json *id, int code, const char *msg) {
    TmpBuf b; tmpbuf_init(&b);
    json_write_raw(&b, "{\"jsonrpc\":\"2.0\",\"id\":");
    json_emit(&b, id);
    json_write_raw(&b, ",\"error\":{\"code\":");
    json_write_int(&b, code);
    json_write_raw(&b, ",\"message\":");
    json_write_string(&b, msg);
    json_write_raw(&b, "}}");
    write_frame(&b);
    free(b.s);
}

static void handle_initialize(const Json *id) {
    respond_result(id, "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true}}");
}

static void handle_hover(const Json *id, const Json *params) {
    const Json *td = json_obj_get(params, "textDocument");
    const char *uri = td ? json_str(json_obj_get(td, "uri")) : NULL;
    const char *text = uri ? docs_get(uri) : NULL;
    if (!text) { respond_result(id, "null"); return; }
    DhallError diag;
    dhall_error_clear(&diag);
    char *type_str = NULL;
    bool ok = evaluate(uri_to_path(uri), uri, text, &diag, &type_str);
    if (!ok || !type_str) { free(type_str); respond_result(id, "null"); return; }
    TmpBuf b; tmpbuf_init(&b);
    json_write_raw(&b, "{\"contents\":{\"language\":\"dhall\",\"value\":");
    json_write_string(&b, type_str);
    json_write_raw(&b, "}}");
    respond_result(id, b.s);
    free(b.s);
    free(type_str);
}

/* ------------------------------------------------------------------ */
/* Message core                                                       */
/* ------------------------------------------------------------------ */

static bool g_shut_down = false;

/* Process one incoming JSON-RPC message. Appends any resulting frame(s) to the
   output buffer (exposed via lsp_out/lsp_out_len). Returns true when the server
   should exit (an "exit" notification was received). */
LSP_EXPORT bool lsp_handle(const char *json, int len) {
    g_out_len = 0;                      /* reset output for this message */
    if (g_out) g_out[0] = '\0';

    if (!dhall_arena) dhall_arena = arena_new();

    Json *root = json_parse(json, (size_t)len);
    if (!root) return false;

    const char *method = json_str(json_obj_get(root, "method"));
    Json *id = json_obj_get(root, "id");
    bool is_request = id && id->type != J_NULL;
    Json *params = json_obj_get(root, "params");

    bool done = false;
    if (method && !strcmp(method, "initialize")) {
        handle_initialize(id);
    } else if (method && !strcmp(method, "initialized")) {
        /* no reply */
    } else if (method && !strcmp(method, "shutdown")) {
        g_shut_down = true;
        respond_result(id, "null");
    } else if (method && !strcmp(method, "exit")) {
        done = true;
    } else if (method && !strcmp(method, "textDocument/didOpen")) {
        const Json *td = json_obj_get(params, "textDocument");
        const char *uri = td ? json_str(json_obj_get(td, "uri")) : NULL;
        const char *text = td ? json_str(json_obj_get(td, "text")) : NULL;
        if (uri && text) handle_doc_change(uri, text);
    } else if (method && !strcmp(method, "textDocument/didChange")) {
        const Json *td = json_obj_get(params, "textDocument");
        const char *uri = td ? json_str(json_obj_get(td, "uri")) : NULL;
        const Json *cc = json_obj_get(params, "contentChanges");
        const Json *last = (cc && cc->type == J_ARR && cc->as.arr.n > 0)
                           ? json_arr_get(cc, cc->as.arr.n - 1) : NULL;
        const char *text = last ? json_str(json_obj_get(last, "text")) : NULL;
        if (uri && text) handle_doc_change(uri, text);
    } else if (method && !strcmp(method, "textDocument/didClose")) {
        const Json *td = json_obj_get(params, "textDocument");
        const char *uri = td ? json_str(json_obj_get(td, "uri")) : NULL;
        if (uri) { docs_remove(uri); publish_diagnostics(uri, NULL); }
    } else if (method && !strcmp(method, "textDocument/hover")) {
        handle_hover(id, params);
    } else if (is_request) {
        respond_error(id, -32601, "method not found");
    }

    json_free(root);
    return done;
}

/* ------------------------------------------------------------------ */
/* Native stdio framing (excluded from the wasm build)               */
/* ------------------------------------------------------------------ */

#ifndef LSP_NO_MAIN

/* Read one frame: header lines until a blank line, then Content-Length bytes. */
static char *read_frame(void) {
    long content_length = -1;
    char line[256];
    for (;;) {
        size_t i = 0;
        int c;
        while (i + 1 < sizeof line && (c = fgetc(stdin)) != EOF && c != '\n')
            line[i++] = (char)c;
        if (c == EOF && i == 0) return NULL;
        line[i] = '\0';
        if (i > 0 && line[i - 1] == '\r') line[--i] = '\0';
        if (i == 0) break;
        if (strncmp(line, "Content-Length:", 15) == 0)
            content_length = strtol(line + 15, NULL, 10);
    }
    if (content_length < 0 || content_length > (1 << 24)) return NULL;
    char *buf = malloc((size_t)content_length + 1);
    if (!buf) return NULL;
    size_t got = 0;
    while (got < (size_t)content_length) {
        size_t n = fread(buf + got, 1, (size_t)content_length - got, stdin);
        if (n == 0) { free(buf); return NULL; }
        got += n;
    }
    buf[content_length] = '\0';
    return buf;
}

int main(void) {
    dhall_arena = arena_new();

    for (;;) {
        char *raw = read_frame();
        if (!raw) break;
        bool done = lsp_handle(raw, (int)strlen(raw));
        if (g_out_len > 0) fwrite(g_out, 1, g_out_len, stdout);
        fflush(stdout);
        free(raw);
        if (done) return g_shut_down ? 0 : 1;
    }
    return 0;
}

#endif /* !LSP_NO_MAIN */
