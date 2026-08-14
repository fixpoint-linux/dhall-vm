/* serialize.c — serializes a normal-form term to JSON, YAML, or TOML.
   Builds a small format-independent Value tree once via a single shared
   descent (term_to_value), then emits it with a format-specific writer.
   term_to_value errors (ERR_SERIALIZE stage) on functions/Pis/types/sorts
   and any non-value construct in normal form, and PROPAGATES nested errors
   so a non-value anywhere in the tree fails the whole serialization (rather
   than silently emitting malformed output). JSON emits NaN/Infinity as null
   (JSON has no representation); TOML requires a record at the top level and
   has no null; YAML uses block style (YAML 1.2 core schema). */
#include "dhall.h"
#include <math.h>
#include <ctype.h>

static const char *format_name(SerFormat fmt) {
    switch (fmt) {
    case FMT_JSON: return "JSON";
    case FMT_TOML: return "TOML";
    case FMT_YAML: return "YAML";
    }
    return "?";
}

/* ---------------- Value constructors ---------------- */

static Value *vnull(void) { Value *v = arena_alloc(dhall_arena, sizeof *v); v->kind = VK_NULL; return v; }
static Value *vnat(uint64_t n) { Value *v = arena_alloc(dhall_arena, sizeof *v); v->kind = VK_NAT; v->as.nat = n; return v; }
static Value *vint(int64_t n) { Value *v = arena_alloc(dhall_arena, sizeof *v); v->kind = VK_INT; v->as.i64 = n; return v; }
static Value *vdbl(double d) { Value *v = arena_alloc(dhall_arena, sizeof *v); v->kind = VK_DBL; v->as.dbl = d; return v; }
static Value *vbool(bool b) { Value *v = arena_alloc(dhall_arena, sizeof *v); v->kind = VK_BOOL; v->as.b = b; return v; }
static Value *vtext(const char *s) { Value *v = arena_alloc(dhall_arena, sizeof *v); v->kind = VK_TEXT; v->as.text = arena_strdup(dhall_arena, s); return v; }
static Value *varr(Value **items, int n) { Value *v = arena_alloc(dhall_arena, sizeof *v); v->kind = VK_ARRAY; v->as.arr.items = items; v->as.arr.n = n; return v; }
static Value *vtab(char **keys, Value **vals, int n) { Value *v = arena_alloc(dhall_arena, sizeof *v); v->kind = VK_TABLE; v->as.tab.keys = keys; v->as.tab.vals = vals; v->as.tab.n = n; return v; }

/* ---------------- shared descent: Term -> Value ---------------- */

static Value *term_to_value(Term *t, SerFormat fmt, DhallError *err) {
    switch (t->tag) {
    case TmConst:
        switch (t->as.c.kind) {
        case C_NAT: return vnat(t->as.c.nat);
        case C_INT: return vint(t->as.c.i64);
        case C_DBL: return vdbl(t->as.c.dbl);
        case C_BOOL: return vbool(t->as.c.b);
        }
        break; /* unreachable: all ConstKind values handled above */
    case TmText:
        if (!t->as.text || t->as.text->expr) {
            if (err) dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "text interpolation not normalized");
            return NULL;
        }
        return vtext(t->as.text->lit);
    case TmRecordLit: {
        int n = t->as.rec.n;
        char **keys = arena_alloc(dhall_arena, (size_t)(n ? n : 1) * sizeof(char *));
        Value **vals = arena_alloc(dhall_arena, (size_t)(n ? n : 1) * sizeof(Value *));
        for (int i = 0; i < n; i++) {
            Value *v = term_to_value(t->as.rec.fs[i].value, fmt, err);
            if (!v) return NULL;
            keys[i] = t->as.rec.fs[i].label;
            vals[i] = v;
        }
        return vtab(keys, vals, n);
    }
    case TmNil:
        return varr(NULL, 0);
    case TmCons: {
        int n = 0;
        for (Term *p = t; p->tag == TmCons; p = p->as.cons.tail) n++;
        Value **items = arena_alloc(dhall_arena, (size_t)(n ? n : 1) * sizeof(Value *));
        int i = 0;
        for (Term *p = t; p->tag == TmCons; p = p->as.cons.tail) {
            Value *v = term_to_value(p->as.cons.head, fmt, err);
            if (!v) return NULL;
            items[i++] = v;
        }
        return varr(items, n);
    }
    case TmUnionLit:
        /* union -> single-key table with the selected alternative */
        for (int i = 0; i < t->as.uni.n; i++) {
            if (t->as.uni.fs[i].value) {
                Value *v = term_to_value(t->as.uni.fs[i].value, fmt, err);
                if (!v) return NULL;
                char **keys = arena_alloc(dhall_arena, sizeof(char *));
                Value **vals = arena_alloc(dhall_arena, sizeof(Value *));
                keys[0] = t->as.uni.fs[i].label;
                vals[0] = v;
                return vtab(keys, vals, 1);
            }
        }
        return vtab(NULL, NULL, 0); /* unreachable in this subset */
    case TmSome:
        /* Dhall: Some x serializes as the inner value */
        return term_to_value(t->as.some.val, fmt, err);
    case TmNone:
        /* Dhall: None serializes as null */
        return vnull();
    case TmLam:
    case TmPi:
        if (err) dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "cannot serialize a function/Pi to %s", format_name(fmt));
        return NULL;
    case TmType: case TmKind: case TmSort:
        if (err) dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "cannot serialize a sort/type to %s", format_name(fmt));
        return NULL;
    case TmVar: case TmApp: case TmField: case TmMerge: case TmRecordType:
    case TmUnionType: case TmTextAppend: case TmLet: case TmIf: case TmAnn:
    case TmBuiltin: case TmOp: case TmAssert: case TmToMap:
        if (err) dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "cannot serialize a non-value to %s", format_name(fmt));
        return NULL;
    }
    if (err) dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "cannot serialize term to %s", format_name(fmt));
    return NULL;
}

/* shared double-quoted escaper (JSON basic string / TOML basic string / YAML dq) */
static void qstr(FILE *out, const char *s) {
    fputc('"', out);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"': fputs("\\\"", out); break;
        case '\\': fputs("\\\\", out); break;
        case '\b': fputs("\\b", out); break;
        case '\f': fputs("\\f", out); break;
        case '\n': fputs("\\n", out); break;
        case '\r': fputs("\\r", out); break;
        case '\t': fputs("\\t", out); break;
        default:
            if (*p < 0x20) fprintf(out, "\\u%04x", *p);
            else fputc(*p, out);
            break;
        }
    }
    fputc('"', out);
}

/* finite float with a forced '.', 'e', or 'E' so TOML/YAML read it as float */
static void dbl_marker(FILE *out, double d) {
    char buf[64]; snprintf(buf, sizeof buf, "%g", d);
    fputs(buf, out);
    if (!strpbrk(buf, ".eE")) fputs(".0", out);
}
static void dbl_json(FILE *out, double d) { if (!isfinite(d)) fputs("null", out); else { char b[64]; snprintf(b, sizeof b, "%g", d); fputs(b, out); } }
static void dbl_yaml(FILE *out, double d) { if (isnan(d)) fputs(".nan", out); else if (d == INFINITY) fputs(".inf", out); else if (d == -INFINITY) fputs("-.inf", out); else dbl_marker(out, d); }
static void dbl_toml(FILE *out, double d) { if (isnan(d)) fputs("nan", out); else if (d == INFINITY) fputs("inf", out); else if (d == -INFINITY) fputs("-inf", out); else dbl_marker(out, d); }

/* TOML key: bare iff [A-Za-z0-9_-]+ and not a reserved word, else basic-quoted */
static void toml_key(FILE *out, const char *k) {
    bool bare = *k != '\0';
    if (bare) for (const unsigned char *p = (const unsigned char *)k; *p; p++) if (!(isalnum(*p) || *p == '_' || *p == '-')) { bare = false; break; }
    if (bare && (!strcmp(k, "true") || !strcmp(k, "false") || !strcmp(k, "inf") || !strcmp(k, "nan"))) bare = false;
    if (bare) fputs(k, out); else qstr(out, k);
}

/* Like toml_key but into a (quoted-or-bare) arena string, for table headers. */
static char *toml_key_str(const char *k) {
    bool bare = *k != '\0';
    if (bare) for (const unsigned char *p = (const unsigned char *)k; *p; p++)
        if (!(isalnum(*p) || *p == '_' || *p == '-')) { bare = false; break; }
    if (bare && (!strcmp(k, "true") || !strcmp(k, "false") || !strcmp(k, "inf") || !strcmp(k, "nan"))) bare = false;
    if (bare) return arena_strdup(dhall_arena, k);
    size_t len = 2;
    for (const unsigned char *p = (const unsigned char *)k; *p; p++)
        len += (*p == '"' || *p == '\\' || *p == '\b' || *p == '\f' ||
                *p == '\n' || *p == '\r' || *p == '\t') ? 2 : (*p < 0x20 ? 6 : 1);
    char *out = arena_alloc(dhall_arena, len + 1);
    char *q = out;
    *q++ = '"';
    for (const unsigned char *p = (const unsigned char *)k; *p; p++) {
        switch (*p) {
        case '"':  *q++ = '\\'; *q++ = '"';  break;
        case '\\': *q++ = '\\'; *q++ = '\\'; break;
        case '\b': *q++ = '\\'; *q++ = 'b';  break;
        case '\f': *q++ = '\\'; *q++ = 'f';  break;
        case '\n': *q++ = '\\'; *q++ = 'n';  break;
        case '\r': *q++ = '\\'; *q++ = 'r';  break;
        case '\t': *q++ = '\\'; *q++ = 't';  break;
        default:
            if (*p < 0x20) q += sprintf(q, "\\u%04x", *p);
            else *q++ = *p;
            break;
        }
    }
    *q++ = '"';
    *q = '\0';
    return out;
}

/* ---------------- JSON emitter ---------------- */

static void json_value(FILE *out, const Value *v) {
    switch (v->kind) {
    case VK_NULL: fputs("null", out); break;
    case VK_NAT: fprintf(out, "%llu", (unsigned long long)v->as.nat); break;
    case VK_INT: fprintf(out, "%lld", (long long)v->as.i64); break;
    case VK_DBL: dbl_json(out, v->as.dbl); break;
    case VK_BOOL: fputs(v->as.b ? "true" : "false", out); break;
    case VK_TEXT: qstr(out, v->as.text); break;
    case VK_ARRAY:
        fputc('[', out);
        for (int i = 0; i < v->as.arr.n; i++) { if (i) fputc(',', out); json_value(out, v->as.arr.items[i]); }
        fputc(']', out);
        break;
    case VK_TABLE:
        fputc('{', out);
        for (int i = 0; i < v->as.tab.n; i++) { if (i) fputc(',', out); qstr(out, v->as.tab.keys[i]); fputc(':', out); json_value(out, v->as.tab.vals[i]); }
        fputc('}', out);
        break;
    }
}

static bool value_to_json(FILE *out, const Value *v, DhallError *err) {
    (void)err;
    json_value(out, v);
    return true;
}

/* ---------------- YAML emitter (block style, 2-space indent, 1.2 core) ---------------- */

static void yaml_ind(FILE *out, int n) { for (int i = 0; i < n; i++) fputc(' ', out); }

/* conservative: quote unless we can prove the string is a safe plain scalar */
static bool yaml_plain_ok(const char *s) {
    if (!s || !*s) return false;
    if (*s == ' ' || *s == '\t') return false;
    const char *lead = "-?:,[]{}#&*!|>'\"%@`";
    if (strchr(lead, *s)) return false;
    size_t n = strlen(s);
    if (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == ':') return false;
    if (strchr(s, '\n') || strchr(s, '\t')) return false;
    if (strstr(s, ": ") || strstr(s, " #")) return false;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) if (*p < 0x20) return false;
    static const char *res[] = { "null", "~", "true", "false", "True", "False", "TRUE", "FALSE", "Null", "NULL" };
    for (unsigned i = 0; i < sizeof res / sizeof *res; i++) if (!strcmp(s, res[i])) return false;
    char *end; (void)strtod(s, &end); if (end && *end == '\0' && end != s) return false;
    /* YAML 1.2 core-schema ints strtod does not recognize: 0o octal (and
       0x/0b hex/binary on libcs where strtod needs a 'p' exponent). */
    if (n >= 3 && s[0] == '0' && (s[1] == 'o' || s[1] == 'O' || s[1] == 'x' || s[1] == 'X' || s[1] == 'b' || s[1] == 'B'))
        return false;
    return true;
}

static void yaml_scalar(FILE *out, const Value *v) {
    switch (v->kind) {
    case VK_NULL: fputs("null", out); break;
    case VK_NAT: fprintf(out, "%llu", (unsigned long long)v->as.nat); break;
    case VK_INT: fprintf(out, "%lld", (long long)v->as.i64); break;
    case VK_DBL: dbl_yaml(out, v->as.dbl); break;
    case VK_BOOL: fputs(v->as.b ? "true" : "false", out); break;
    case VK_TEXT: if (yaml_plain_ok(v->as.text)) fputs(v->as.text, out); else qstr(out, v->as.text); break;
    default: break;
    }
}

static void yaml_key(FILE *out, const char *k) { if (yaml_plain_ok(k)) fputs(k, out); else qstr(out, k); }
static bool yaml_is_scalar(const Value *v) { return v->kind != VK_ARRAY && v->kind != VK_TABLE; }
static bool yaml_is_empty(const Value *v) { return (v->kind == VK_ARRAY && v->as.arr.n == 0) || (v->kind == VK_TABLE && v->as.tab.n == 0); }

static void yaml_emit(FILE *out, const Value *v, int ind);
static void yaml_emit_field(FILE *out, const char *key, const Value *val, int ind) {
    yaml_ind(out, ind); yaml_key(out, key); fputc(':', out);
    if (yaml_is_scalar(val)) { fputc(' ', out); yaml_scalar(out, val); fputc('\n', out); }
    else if (yaml_is_empty(val)) { fputc(' ', out); fputs(val->kind == VK_ARRAY ? "[]" : "{}", out); fputc('\n', out); }
    else { fputc('\n', out); yaml_emit(out, val, ind + 2); }
}
static void yaml_emit(FILE *out, const Value *v, int ind) {
    switch (v->kind) {
    case VK_ARRAY:
        if (v->as.arr.n == 0) { fputs("[]", out); break; }
        for (int i = 0; i < v->as.arr.n; i++) {
            const Value *it = v->as.arr.items[i];
            if (yaml_is_scalar(it)) { yaml_ind(out, ind); fputs("- ", out); yaml_scalar(out, it); fputc('\n', out); }
            else if (yaml_is_empty(it)) { yaml_ind(out, ind); fputs("- ", out); fputs(it->kind == VK_ARRAY ? "[]" : "{}", out); fputc('\n', out); }
            else if (it->kind == VK_TABLE) {
                yaml_ind(out, ind); fputs("- ", out);
                yaml_key(out, it->as.tab.keys[0]); fputc(':', out);
                const Value *fv = it->as.tab.vals[0];
                if (yaml_is_scalar(fv)) { fputc(' ', out); yaml_scalar(out, fv); fputc('\n', out); }
                else if (yaml_is_empty(fv)) { fputc(' ', out); fputs(fv->kind == VK_ARRAY ? "[]" : "{}", out); fputc('\n', out); }
                else { fputc('\n', out); yaml_emit(out, fv, ind + 4); }
                for (int j = 1; j < it->as.tab.n; j++) yaml_emit_field(out, it->as.tab.keys[j], it->as.tab.vals[j], ind + 2);
            } else { yaml_ind(out, ind); fputs("-\n", out); yaml_emit(out, it, ind + 2); }
        }
        break;
    case VK_TABLE:
        if (v->as.tab.n == 0) { fputs("{}", out); break; }
        for (int i = 0; i < v->as.tab.n; i++) yaml_emit_field(out, v->as.tab.keys[i], v->as.tab.vals[i], ind);
        break;
    default: yaml_scalar(out, v); break;
    }
}

static bool value_to_yaml(FILE *out, const Value *v, DhallError *err) {
    (void)err;
    if (v->kind == VK_ARRAY || v->kind == VK_TABLE) {
        yaml_emit(out, v, 0);
        /* non-empty arrays/tables already end with '\n'; empty ones and scalars do not */
        if ((v->kind == VK_ARRAY && v->as.arr.n == 0) || (v->kind == VK_TABLE && v->as.tab.n == 0))
            fputc('\n', out);
    } else {
        yaml_scalar(out, v);
        fputc('\n', out);
    }
    return true;
}

/* ---------------- TOML emitter ---------------- */

static bool toml_value(FILE *out, const Value *v, DhallError *err) {
    switch (v->kind) {
    case VK_NAT:
        if (v->as.nat > (uint64_t)INT64_MAX) {
            if (err) dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "Natural exceeds TOML signed 64-bit range");
            return false;
        }
        fprintf(out, "%llu", (unsigned long long)v->as.nat);
        return true;
    case VK_INT: fprintf(out, "%lld", (long long)v->as.i64); return true;
    case VK_DBL: dbl_toml(out, v->as.dbl); return true;
    case VK_BOOL: fputs(v->as.b ? "true" : "false", out); return true;
    case VK_TEXT: qstr(out, v->as.text); return true;
    case VK_NULL:
        if (err) dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "cannot serialize null (None) to TOML");
        return false;
    case VK_ARRAY: {
        fputc('[', out);
        for (int i = 0; i < v->as.arr.n; i++) {
            if (i) fputs(", ", out);
            if (!toml_value(out, v->as.arr.items[i], err)) return false;
        }
        fputc(']', out);
        return true;
    }
    case VK_TABLE: {
        fputs("{ ", out);
        for (int i = 0; i < v->as.tab.n; i++) {
            if (i) fputs(", ", out);
            toml_key(out, v->as.tab.keys[i]);
            fputs(" = ", out);
            if (!toml_value(out, v->as.tab.vals[i], err)) return false;
        }
        fputs(" }", out);
        return true;
    }
    }
    return true;
}

/* two-pass: scalar/array fields first (key = value), then table fields as [a.b] headers */
static bool toml_table(FILE *out, const Value *v, const char *prefix, DhallError *err) {
    size_t plen = strlen(prefix);
    for (int i = 0; i < v->as.tab.n; i++)
        if (v->as.tab.vals[i]->kind != VK_TABLE) {
            toml_key(out, v->as.tab.keys[i]);
            fputs(" = ", out);
            if (!toml_value(out, v->as.tab.vals[i], err)) return false;
            fputc('\n', out);
        }
    for (int i = 0; i < v->as.tab.n; i++)
        if (v->as.tab.vals[i]->kind == VK_TABLE) {
            char *krend = toml_key_str(v->as.tab.keys[i]);
            size_t klen = strlen(krend);
            char *hdr = arena_alloc(dhall_arena, plen + klen + 1);
            memcpy(hdr, prefix, plen);
            memcpy(hdr + plen, krend, klen + 1);
            fprintf(out, "[%s]\n", hdr);
            char *np = arena_alloc(dhall_arena, plen + klen + 2);
            memcpy(np, hdr, plen + klen);
            np[plen + klen] = '.';
            np[plen + klen + 1] = '\0';
            if (!toml_table(out, v->as.tab.vals[i], np, err)) return false;
        }
    return true;
}

/* Pre-flight: find the first TOML-invalid value (null, or a Natural that
   exceeds TOML's signed 64-bit integer range) so we can fail cleanly before
   emitting any partial output. */
static const Value *toml_find_bad(const Value *v) {
    if (v->kind == VK_NULL) return v;
    if (v->kind == VK_NAT && v->as.nat > (uint64_t)INT64_MAX) return v;
    if (v->kind == VK_ARRAY) {
        for (int i = 0; i < v->as.arr.n; i++) { const Value *b = toml_find_bad(v->as.arr.items[i]); if (b) return b; }
    } else if (v->kind == VK_TABLE) {
        for (int i = 0; i < v->as.tab.n; i++) { const Value *b = toml_find_bad(v->as.tab.vals[i]); if (b) return b; }
    }
    return NULL;
}

static bool value_to_toml(FILE *out, const Value *v, DhallError *err) {
    if (v->kind != VK_TABLE) {
        if (err) dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "TOML requires the top-level value to be a record");
        return false;
    }
    const Value *bad = toml_find_bad(v);
    if (bad) {
        if (bad->kind == VK_NULL)
            dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "cannot serialize null (None) to TOML");
        else
            dhall_error_set(err, ERR_SERIALIZE, SPAN_NONE, "Natural exceeds TOML signed 64-bit range");
        return false;
    }
    return toml_table(out, v, "", err);
}

/* ---------------- public wrappers ---------------- */

bool term_serialize(FILE *out, Term *t, SerFormat fmt, DhallError *err) {
    Value *v = term_to_value(t, fmt, err);
    if (!v) return false;
    switch (fmt) {
    case FMT_JSON: return value_to_json(out, v, err);
    case FMT_YAML: return value_to_yaml(out, v, err);
    case FMT_TOML: return value_to_toml(out, v, err);
    }
    return false;
}

bool term_to_json(FILE *out, Term *t, DhallError *err) { return term_serialize(out, t, FMT_JSON, err); }
bool term_to_toml(FILE *out, Term *t, DhallError *err) { return term_serialize(out, t, FMT_TOML, err); }
bool term_to_yaml(FILE *out, Term *t, DhallError *err) { return term_serialize(out, t, FMT_YAML, err); }
