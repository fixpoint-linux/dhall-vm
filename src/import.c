/* import.c — file/env import loader with cycle detection, a per-canonical-path
   term cache, and an import-chain depth guard.

   Scope: local file imports (./x, ../y, /abs), env:NAME (resolved to a Text
   literal via getenv), the always-absent `missing` import, and a sha256:<hex>
   integrity check. NO network/URL imports.

   DEVIATION from real Dhall: the sha256:<hex> hash is computed over the RAW
   SOURCE TEXT (file bytes / env-var value), NOT the CBOR encoding of the
   beta-normal form (this subset has no CBOR). The hash is lowercase base16
   hex (64 chars), not base64. A hash mismatch is a HARD error (ERR_IO, not
   recoverable by `?`); an ABSENT import (`missing`, file-not-found, env-unset)
   is reported with stage ERR_MISSING, which the parser's `?` catches.

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

Term *import_resolve(ImportLoader *l, const char *spec, const char *hash_hex,
                     Parser *p, DhallError *err) {
    dhall_error_clear(err);

    /* `missing` import: always absent (no cache lookup; any hash ignored). */
    if (strcmp(spec, "missing") == 0) {
        dhall_error_set(err, ERR_MISSING, SPAN_NONE, "missing import");
        return NULL;
    }

    /* env:NAME -> Text literal (value NOT parsed as Dhall source) */
    if (strncmp(spec, "env:", 4) == 0) {
        const char *name = spec + 4;
        const char *val = getenv(name);
        if (!val) {
            dhall_error_set(err, ERR_MISSING, SPAN_NONE, "environment variable '%s' not set", name);
            return NULL;
        }
        if (hash_hex) {
            char got[65];
            sha256_hex(val, strlen(val), got);
            if (strcmp(got, hash_hex) != 0) {
                dhall_error_set(err, ERR_IO, SPAN_NONE,
                                "sha256 mismatch for 'env:%s'", name);
                return NULL;
            }
        }
        return tm_text_lit(val);
    }

    /* file import: resolve against the current file's directory */
    const char *base = l->dn > 0 ? l->dirs[l->dn - 1] : ".";
    char *path = join_path(base, spec);
    if (!path) { dhall_error_set(err, ERR_IO, SPAN_NONE, "out of memory"); return NULL; }
    char canonical[PATH_BUF];
    if (!realpath(path, canonical)) {
        dhall_error_set(err, ERR_MISSING, SPAN_NONE, "cannot open file '%s'", spec);
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

    /* cache key = canonical path + optional hash, so a hashed import verifies
       on its own fresh read rather than being satisfied by an earlier un-hashed
       cache entry of the same file. */
    char *ckey = xstrdup(canonical);
    if (hash_hex) {
        size_t cl = strlen(ckey), hl = strlen(hash_hex);
        char *k = malloc(cl + 1 + hl + 1);
        if (k) { memcpy(k, ckey, cl); k[cl] = ' '; memcpy(k + cl + 1, hash_hex, hl + 1); free(ckey); ckey = k; }
    }

    /* cache hit */
    for (int i = 0; i < l->cn; i++)
        if (!strcmp(l->ckeys[i], ckey)) { free(ckey); return l->cterms[i]; }

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

    /* integrity check over the RAW SOURCE TEXT (deviation from real Dhall's
       CBOR-of-normal-form). Verified on the fresh-read path only — a cache hit
       above skips re-verification (documented simplification). */
    if (hash_hex) {
        char got[65];
        sha256_hex(src, strlen(src), got);
        if (strcmp(got, hash_hex) != 0) {
            dhall_error_set(err, ERR_IO, SPAN_NONE,
                            "sha256 mismatch for '%s': expected %s, got %s",
                            spec, hash_hex, got);
            free(src);
            return NULL;
        }
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
    l->ckeys[l->cn] = ckey;   /* ckey ownership moves into the cache */
    l->cterms[l->cn] = t;
    l->cn++;
    return t;
}
