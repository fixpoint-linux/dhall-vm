/* json.c — serializes a normal-form term to JSON.
   Errors (with ERR_JSON stage) on functions/Pis/types/variables and any
   non-value construct in normal form. Handles NaN/Infinity (emitted as
   null, since JSON has no representation), escapes text, and emits
   record fields in sorted order. */
#include "dhall.h"
#include <math.h>

static void json_escape(FILE *out, const char *s) {
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

static void json_list(FILE *out, Term *t) {
    fputc('[', out);
    bool first = true;
    while (t->tag == TmCons) {
        if (!first) fputc(',', out);
        first = false;
        term_to_json(out, t->as.cons.head, NULL);
        t = t->as.cons.tail;
    }
    fputc(']', out);
}

bool term_to_json(FILE *out, Term *t, DhallError *err) {
    switch (t->tag) {
    case TmConst:
        switch (t->as.c.kind) {
        case C_NAT: fprintf(out, "%llu", (unsigned long long)t->as.c.nat); return true;
        case C_INT: fprintf(out, "%lld", (long long)t->as.c.i64); return true;
        case C_DBL:
            if (!isfinite(t->as.c.dbl)) { fputs("null", out); return true; }
            fprintf(out, "%g", t->as.c.dbl);
            return true;
        case C_BOOL: fputs(t->as.c.b ? "true" : "false", out); return true;
        }
        break;
    case TmText:
        if (!t->as.text || t->as.text->expr) {
            if (err) { err->stage = ERR_JSON; snprintf(err->msg, sizeof(err->msg), "text interpolation not normalized"); return false; }
            return false;
        }
        json_escape(out, t->as.text->lit);
        return true;
    case TmRecordLit:
        fputc('{', out);
        for (int i = 0; i < t->as.rec.n; i++) {
            if (i) fputc(',', out);
            json_escape(out, t->as.rec.fs[i].label);
            fputc(':', out);
            term_to_json(out, t->as.rec.fs[i].value, err);
        }
        fputc('}', out);
        return true;
    case TmNil: fputs("[]", out); return true;
    case TmCons: json_list(out, t); return true;
    case TmUnionLit:
        /* union → object with the selected alternative */
        for (int i = 0; i < t->as.uni.n; i++) {
            if (t->as.uni.fs[i].value) {
                fputc('{', out);
                json_escape(out, t->as.uni.fs[i].label);
                fputc(':', out);
                term_to_json(out, t->as.uni.fs[i].value, err);
                fputc('}', out);
                return true;
            }
        }
        fputs("{}", out);
        return true;
    case TmLam:
    case TmPi:
        if (err) { err->stage = ERR_JSON; snprintf(err->msg, sizeof(err->msg), "cannot serialize a function/Pi to JSON"); return false; }
        return false;
    case TmType: case TmKind: case TmSort:
        if (err) { err->stage = ERR_JSON; snprintf(err->msg, sizeof(err->msg), "cannot serialize a sort/type to JSON"); return false; }
        return false;
    case TmVar: case TmApp: case TmField: case TmMerge: case TmRecordType:
    case TmUnionType: case TmTextAppend: case TmLet: case TmIf: case TmAnn:
    case TmBuiltin:
        if (err) { err->stage = ERR_JSON; snprintf(err->msg, sizeof(err->msg), "cannot serialize a non-value to JSON"); return false; }
        return false;
    }
    if (err) { err->stage = ERR_JSON; snprintf(err->msg, sizeof(err->msg), "cannot serialize term to JSON"); return false; }
    return false;
}
