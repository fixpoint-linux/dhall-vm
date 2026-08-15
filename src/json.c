/* json.c — minimal JSON decoder (heap tree) + encoder (to a TmpBuf) for the
   LSP JSON-RPC 2.0 protocol. Handles the full JSON grammar we need (objects,
   arrays, strings with \\uXXXX escapes incl. surrogate pairs, numbers, true/
   false/null) and emits compact JSON (no insignificant whitespace), mirroring
   serialize.c's qstr escaping so output is byte-compatible with the rest of the
   codebase. Out-of-memory is fatal (exit 3), matching arena.c / tmpbuf_grow. */
#include "json.h"
#include <ctype.h>
#include <stdlib.h>

/* OOM is fatal, per the rest of the codebase (arena.c, tmpbuf_grow). */
static void *xmalloc(size_t n) {
    void *p = malloc(n);
    if (!p) { fputs("dhall-lsp: out of memory\n", stderr); exit(3); }
    return p;
}

static void *xrealloc(void *p, size_t n) {
    void *q = realloc(p, n);
    if (!q) { fputs("dhall-lsp: out of memory\n", stderr); exit(3); }
    return q;
}

typedef struct { const char *p; const char *end; } JP;

static Json *jparse_value(JP *jp);

static Json *jnew(JsonType t) {
    Json *v = xmalloc(sizeof *v);
    memset(v, 0, sizeof *v);
    v->type = t;
    return v;
}

static void jskip_ws(JP *jp) {
    while (jp->p < jp->end) {
        char c = *jp->p;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') jp->p++;
        else break;
    }
}

static void put_utf8(char *dst, unsigned cp, int *w) {
    if (cp < 0x80)          { dst[(*w)++] = (char)cp; }
    else if (cp < 0x800)    { dst[(*w)++] = (char)(0xC0 | (cp >> 6));
                              dst[(*w)++] = (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000)  { dst[(*w)++] = (char)(0xE0 | (cp >> 12));
                              dst[(*w)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                              dst[(*w)++] = (char)(0x80 | (cp & 0x3F)); }
    else                    { dst[(*w)++] = (char)(0xF0 | (cp >> 18));
                              dst[(*w)++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                              dst[(*w)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                              dst[(*w)++] = (char)(0x80 | (cp & 0x3F)); }
}

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int read_hex4(JP *jp) {
    if (jp->end - jp->p < 4) return -1;
    int u = 0;
    for (int i = 0; i < 4; i++) {
        int h = hexval((unsigned char)jp->p[i]);
        if (h < 0) return -1;
        u = (u << 4) | h;
    }
    jp->p += 4;
    return u;
}

static char *jparse_string(JP *jp) {
    if (jp->p >= jp->end || *jp->p != '"') return NULL;
    jp->p++;
    size_t cap = (size_t)(jp->end - jp->p) + 1;
    char *out = xmalloc(cap);
    int w = 0;
    while (jp->p < jp->end) {
        unsigned char c = (unsigned char)*jp->p;
        if (c == '"') { jp->p++; out[w] = '\0'; return out; }
        if (c == '\\') {
            jp->p++;
            if (jp->p >= jp->end) break;
            unsigned char e = (unsigned char)*jp->p++;
            switch (e) {
            case '"':  out[w++] = '"';  break;
            case '\\': out[w++] = '\\'; break;
            case '/':  out[w++] = '/';  break;
            case 'b':  out[w++] = '\b'; break;
            case 'f':  out[w++] = '\f'; break;
            case 'n':  out[w++] = '\n'; break;
            case 'r':  out[w++] = '\r'; break;
            case 't':  out[w++] = '\t'; break;
            case 'u': {
                int hi = read_hex4(jp);
                if (hi < 0) { free(out); return NULL; }
                unsigned cp = (unsigned)hi;
                if (hi >= 0xD800 && hi <= 0xDBFF) {
                    if (jp->end - jp->p < 2 || jp->p[0] != '\\' || jp->p[1] != 'u') { free(out); return NULL; }
                    jp->p += 2;
                    int lo = read_hex4(jp);
                    if (lo < 0xDC00 || lo > 0xDFFF) { free(out); return NULL; }
                    cp = 0x10000 + (((unsigned)hi - 0xD800) << 10) + ((unsigned)lo - 0xDC00);
                } else if (hi >= 0xDC00 && hi <= 0xDFFF) {
                    /* lone low surrogate: not valid Unicode in isolation */
                    free(out); return NULL;
                }
                put_utf8(out, cp, &w);
                break;
            }
            default: free(out); return NULL;
            }
        } else if (c < 0x20) {
            free(out); return NULL;
        } else {
            out[w++] = (char)c;
            jp->p++;
        }
    }
    free(out);
    return NULL;
}

static Json *jparse_string_node(JP *jp) {
    char *s = jparse_string(jp);
    if (!s) return NULL;
    Json *v = jnew(J_STR);
    v->as.str = s;
    return v;
}

static Json *jparse_number(JP *jp) {
    const char *start = jp->p;
    if (jp->p < jp->end && *jp->p == '-') jp->p++;
    /* integer part: at least one digit; no leading zero unless it is just "0" */
    if (jp->p >= jp->end || !isdigit((unsigned char)*jp->p)) return NULL;
    if (*jp->p == '0') {
        jp->p++;
        if (jp->p < jp->end && isdigit((unsigned char)*jp->p)) return NULL; /* "01" */
    } else {
        while (jp->p < jp->end && isdigit((unsigned char)*jp->p)) jp->p++;
    }
    if (jp->p < jp->end && *jp->p == '.') {
        jp->p++;
        if (jp->p >= jp->end || !isdigit((unsigned char)*jp->p)) return NULL; /* "1." */
        while (jp->p < jp->end && isdigit((unsigned char)*jp->p)) jp->p++;
    }
    if (jp->p < jp->end && (*jp->p == 'e' || *jp->p == 'E')) {
        jp->p++;
        if (jp->p < jp->end && (*jp->p == '+' || *jp->p == '-')) jp->p++;
        if (jp->p >= jp->end || !isdigit((unsigned char)*jp->p)) return NULL; /* "1e" */
        while (jp->p < jp->end && isdigit((unsigned char)*jp->p)) jp->p++;
    }
    char *endp = NULL;
    double d = strtod(start, &endp);
    if (endp != jp->p) return NULL;  /* strtod must consume exactly the token */
    Json *v = jnew(J_NUM);
    v->as.num = d;
    return v;
}

static Json *jparse_array(JP *jp) {
    jp->p++;
    Json *v = jnew(J_ARR);
    Json **items = NULL;
    int n = 0, cap = 0;
    jskip_ws(jp);
    if (jp->p < jp->end && *jp->p == ']') { jp->p++; return v; }
    for (;;) {
        jskip_ws(jp);
        Json *item = jparse_value(jp);
        if (!item) goto fail;
        if (n == cap) { cap = cap ? cap * 2 : 4; items = xrealloc(items, (size_t)cap * sizeof *items); }
        items[n++] = item;
        jskip_ws(jp);
        if (jp->p < jp->end && *jp->p == ',') { jp->p++; continue; }
        if (jp->p < jp->end && *jp->p == ']') { jp->p++; break; }
        goto fail;
    }
    v->as.arr.items = items;
    v->as.arr.n = n;
    return v;
fail:
    for (int i = 0; i < n; i++) json_free(items[i]);
    free(items);
    json_free(v);
    return NULL;
}

static Json *jparse_object(JP *jp) {
    jp->p++;
    Json *v = jnew(J_OBJ);
    char **keys = NULL;
    Json **vals = NULL;
    int n = 0, cap = 0;
    jskip_ws(jp);
    if (jp->p < jp->end && *jp->p == '}') { jp->p++; return v; }
    for (;;) {
        jskip_ws(jp);
        char *k = jparse_string(jp);
        if (!k) goto fail;
        jskip_ws(jp);
        if (jp->p >= jp->end || *jp->p != ':') { free(k); goto fail; }
        jp->p++;
        jskip_ws(jp);
        Json *val = jparse_value(jp);
        if (!val) { free(k); goto fail; }
        if (n == cap) {
            cap = cap ? cap * 2 : 8;
            keys = xrealloc(keys, (size_t)cap * sizeof *keys);
            vals = xrealloc(vals, (size_t)cap * sizeof *vals);
        }
        keys[n] = k;
        vals[n] = val;
        n++;
        jskip_ws(jp);
        if (jp->p < jp->end && *jp->p == ',') { jp->p++; continue; }
        if (jp->p < jp->end && *jp->p == '}') { jp->p++; break; }
        goto fail;
    }
    v->as.obj.keys = keys;
    v->as.obj.vals = vals;
    v->as.obj.n = n;
    return v;
fail:
    for (int i = 0; i < n; i++) { free(keys[i]); json_free(vals[i]); }
    free(keys);
    free(vals);
    json_free(v);
    return NULL;
}

static Json *jparse_value(JP *jp) {
    jskip_ws(jp);
    if (jp->p >= jp->end) return NULL;
    char c = *jp->p;
    if (c == '{') return jparse_object(jp);
    if (c == '[') return jparse_array(jp);
    if (c == '"') return jparse_string_node(jp);
    if (c == 't' && jp->end - jp->p >= 4 && !memcmp(jp->p, "true", 4)) { jp->p += 4; Json *v = jnew(J_BOOL); v->as.b = true; return v; }
    if (c == 'f' && jp->end - jp->p >= 5 && !memcmp(jp->p, "false", 5)) { jp->p += 5; Json *v = jnew(J_BOOL); v->as.b = false; return v; }
    if (c == 'n' && jp->end - jp->p >= 4 && !memcmp(jp->p, "null", 4)) { jp->p += 4; return jnew(J_NULL); }
    if (c == '-' || isdigit((unsigned char)c)) return jparse_number(jp);
    return NULL;
}

Json *json_parse(const char *s, size_t len) {
    JP jp = { s, s + len };
    Json *v = jparse_value(&jp);
    if (!v) return NULL;
    jskip_ws(&jp);
    if (jp.p != jp.end) { json_free(v); return NULL; }
    return v;
}

void json_free(Json *v) {
    if (!v) return;
    switch (v->type) {
    case J_STR: free(v->as.str); break;
    case J_ARR: for (int i = 0; i < v->as.arr.n; i++) json_free(v->as.arr.items[i]); free(v->as.arr.items); break;
    case J_OBJ: for (int i = 0; i < v->as.obj.n; i++) { free(v->as.obj.keys[i]); json_free(v->as.obj.vals[i]); } free(v->as.obj.keys); free(v->as.obj.vals); break;
    default: break;
    }
    free(v);
}

Json *json_obj_get(const Json *v, const char *key) {
    if (!v || v->type != J_OBJ) return NULL;
    for (int i = 0; i < v->as.obj.n; i++)
        if (!strcmp(v->as.obj.keys[i], key)) return v->as.obj.vals[i];
    return NULL;
}

const char *json_str(const Json *v) { return (v && v->type == J_STR) ? v->as.str : NULL; }
double      json_num(const Json *v) { return (v && v->type == J_NUM) ? v->as.num : 0.0; }
Json       *json_arr_get(const Json *v, int i) { return (v && v->type == J_ARR && i >= 0 && i < v->as.arr.n) ? v->as.arr.items[i] : NULL; }

void json_write_raw(TmpBuf *b, const char *s) { tmpbuf_add(b, s); }

void json_write_string(TmpBuf *b, const char *s) {
    tmpbuf_addc(b, '"');
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':  tmpbuf_add(b, "\\\""); break;
        case '\\': tmpbuf_add(b, "\\\\"); break;
        case '\b': tmpbuf_add(b, "\\b");  break;
        case '\f': tmpbuf_add(b, "\\f");  break;
        case '\n': tmpbuf_add(b, "\\n");  break;
        case '\r': tmpbuf_add(b, "\\r");  break;
        case '\t': tmpbuf_add(b, "\\t");  break;
        default:
            if (*p < 0x20) {
                char esc[8];
                snprintf(esc, sizeof esc, "\\u%04x", *p);
                tmpbuf_add(b, esc);
            } else {
                tmpbuf_addc(b, (char)*p);
            }
        }
    }
    tmpbuf_addc(b, '"');
}

void json_write_key(TmpBuf *b, const char *k) { json_write_string(b, k); tmpbuf_addc(b, ':'); }

void json_write_int(TmpBuf *b, long long v) {
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", v);
    tmpbuf_add(b, buf);
}

void json_write_bool(TmpBuf *b, bool v) { tmpbuf_add(b, v ? "true" : "false"); }
void json_write_null(TmpBuf *b) { tmpbuf_add(b, "null"); }

void json_emit(TmpBuf *b, const Json *v) {
    if (!v) { json_write_null(b); return; }
    switch (v->type) {
    case J_NULL: json_write_null(b); break;
    case J_BOOL: json_write_bool(b, v->as.b); break;
    case J_NUM:
        if (v->as.num == (double)(long long)v->as.num)
            json_write_int(b, (long long)v->as.num);
        else {
            char buf[48];
            snprintf(buf, sizeof buf, "%.17g", v->as.num);
            tmpbuf_add(b, buf);
        }
        break;
    case J_STR: json_write_string(b, v->as.str); break;
    case J_ARR:
        tmpbuf_addc(b, '[');
        for (int i = 0; i < v->as.arr.n; i++) { if (i) tmpbuf_addc(b, ','); json_emit(b, v->as.arr.items[i]); }
        tmpbuf_addc(b, ']');
        break;
    case J_OBJ:
        tmpbuf_addc(b, '{');
        for (int i = 0; i < v->as.obj.n; i++) { if (i) tmpbuf_addc(b, ','); json_write_key(b, v->as.obj.keys[i]); json_emit(b, v->as.obj.vals[i]); }
        tmpbuf_addc(b, '}');
        break;
    }
}
