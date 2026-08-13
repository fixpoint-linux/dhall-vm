/* import.c — file/env import loader with cycle detection, a per-canonical-path
   term cache, and an import-chain depth guard.

   Scope: local file imports (./x, ../y, /abs) and env:NAME (resolved to a Text
   literal via getenv). NO network/URL/missing/sha256 imports.

   Imports are inlined AT PARSE TIME: import_resolve() parses the referenced
   file with a FRESH name stack (imports are closed — no outer-binder access)
   into the SAME global arena (imported terms must outlive the importing file's
   parse; the arena is only reset once per top-level evaluation in main.c). */
#include "dhall.h"

#define PATH_BUF 4096

struct ImportLoader {
    char **keys;      int n, cap;    /* import chain: canonical keys (cycle detection) */
    char **dirs;      int dn, dcap;  /* dir stack (parallel to keys +1 root entry) */
    char **ckeys;     int cn, ccap;  /* cache: canonical key -> parsed term */
    Term **cterms;
    int depth;                        /* import chain depth */
};

static char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = malloc(n);
    if (r) memcpy(r, s, n);
    return r;
}

/* dirname: everything up to (not including) the last '/'; "." if none */
static char *path_dirname(const char *path) {
    const char *slash = strrchr(path, '/');
    if (!slash) return xstrdup(".");
    if (slash == path) return xstrdup("/");
    size_t n = (size_t)(slash - path);
    char *r = malloc(n + 1);
    if (r) { memcpy(r, path, n); r[n] = '\0'; }
    return r;
}

/* join base dir + spec (unless spec is absolute) */
static char *join_path(const char *base, const char *spec) {
    if (spec[0] == '/') return xstrdup(spec);
    size_t bl = strlen(base), sl = strlen(spec);
    char *r = malloc(bl + sl + 2);
    if (!r) return NULL;
    memcpy(r, base, bl);
    r[bl] = '/';
    memcpy(r + bl + 1, spec, sl + 1);
    return r;
}

static char *read_whole_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (!buf) { fclose(f); return NULL; }
    for (;;) {
        if (len == cap) { cap *= 2; char *nb = realloc(buf, cap); if (!nb) { free(buf); fclose(f); return NULL; } buf = nb; }
        size_t n = fread(buf + len, 1, cap - len, f);
        len += n;
        if (n == 0) break;
    }
    buf[len] = '\0';
    fclose(f);
    return buf;
}

ImportLoader *import_loader_new(void) {
    return calloc(1, sizeof(ImportLoader));
}

void import_loader_free(ImportLoader *l) {
    if (!l) return;
    for (int i = 0; i < l->n; i++) free(l->keys[i]);
    free(l->keys);
    for (int i = 0; i < l->dn; i++) free(l->dirs[i]);
    free(l->dirs);
    for (int i = 0; i < l->cn; i++) free(l->ckeys[i]);
    free(l->ckeys);
    free(l->cterms);
    free(l);
}

void import_loader_push_root(ImportLoader *l, const char *root_file) {
    if (root_file) {
        char canonical[PATH_BUF];
        if (realpath(root_file, canonical)) {
            /* push root key so a self-import is detected as a cycle */
            if (l->n == l->cap) { l->cap = l->cap ? l->cap * 2 : 8; l->keys = realloc(l->keys, l->cap * sizeof(char *)); }
            l->keys[l->n++] = xstrdup(canonical);
            if (l->dn == l->dcap) { l->dcap = l->dcap ? l->dcap * 2 : 8; l->dirs = realloc(l->dirs, l->dcap * sizeof(char *)); }
            l->dirs[l->dn++] = path_dirname(canonical);
            return;
        }
    }
    /* stdin or unresolvable root: relative imports resolve against CWD */
    if (l->dn == l->dcap) { l->dcap = l->dcap ? l->dcap * 2 : 8; l->dirs = realloc(l->dirs, l->dcap * sizeof(char *)); }
    l->dirs[l->dn++] = xstrdup(".");
}

Term *import_resolve(ImportLoader *l, const char *spec, Parser *p, DhallError *err) {
    dhall_error_clear(err);

    /* env:NAME -> Text literal (value NOT parsed as Dhall source) */
    if (strncmp(spec, "env:", 4) == 0) {
        const char *name = spec + 4;
        const char *val = getenv(name);
        if (!val) {
            dhall_error_set(err, ERR_IO, SPAN_NONE, "environment variable '%s' not set", name);
            return NULL;
        }
        return tm_text_lit(val);
    }

    /* file import: resolve against the current file's directory */
    const char *base = l->dn > 0 ? l->dirs[l->dn - 1] : ".";
    char *path = join_path(base, spec);
    if (!path) { dhall_error_set(err, ERR_IO, SPAN_NONE, "out of memory"); return NULL; }
    char canonical[PATH_BUF];
    if (!realpath(path, canonical)) {
        dhall_error_set(err, ERR_IO, SPAN_NONE, "cannot open file '%s'", spec);
        free(path);
        return NULL;
    }
    free(path);

    /* cycle detection */
    for (int i = 0; i < l->n; i++)
        if (!strcmp(l->keys[i], canonical)) {
            dhall_error_set(err, ERR_TYPE, SPAN_NONE, "import cycle");
            return NULL;
        }

    /* cache hit */
    for (int i = 0; i < l->cn; i++)
        if (!strcmp(l->ckeys[i], canonical)) return l->cterms[i];

    /* depth guard */
    if (l->depth >= MAX_IMPORT_DEPTH) {
        dhall_error_set(err, ERR_PARSE, SPAN_NONE, "import depth exceeded");
        return NULL;
    }

    char *src = read_whole_file(canonical);
    if (!src) {
        dhall_error_set(err, ERR_IO, SPAN_NONE, "cannot open file '%s'", spec);
        return NULL;
    }

    /* push chain (key + dir) */
    if (l->n == l->cap) { l->cap = l->cap ? l->cap * 2 : 8; l->keys = realloc(l->keys, l->cap * sizeof(char *)); }
    l->keys[l->n++] = xstrdup(canonical);
    if (l->dn == l->dcap) { l->dcap = l->dcap ? l->dcap * 2 : 8; l->dirs = realloc(l->dirs, l->dcap * sizeof(char *)); }
    l->dirs[l->dn++] = path_dirname(canonical);
    l->depth++;

    /* parse with a FRESH name stack (imports are closed); inherit the global
       expression-nesting depth so total recursion stays bounded across files */
    Parser sub;
    memset(&sub, 0, sizeof(sub));
    sub.loader = l;
    sub.depth = p->depth;
    DhallError sub_err;
    dhall_error_clear(&sub_err);
    Term *t = parse_source(&sub, src, canonical, &sub_err);
    free(src);

    l->depth--;
    free(l->keys[--l->n]);
    free(l->dirs[--l->dn]);

    if (!t) { *err = sub_err; return NULL; }

    /* cache the parsed term */
    if (l->cn == l->ccap) {
        l->ccap = l->ccap ? l->ccap * 2 : 8;
        l->ckeys = realloc(l->ckeys, l->ccap * sizeof(char *));
        l->cterms = realloc(l->cterms, l->ccap * sizeof(Term *));
    }
    l->ckeys[l->cn] = xstrdup(canonical);
    l->cterms[l->cn] = t;
    l->cn++;
    return t;
}
