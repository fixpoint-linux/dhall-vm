/* u3_parse_dump.c — U3 twin-driver (C side). Parses the file given on argv[1]
   with the real C parser (parser.c) and prints an S-expr of the raw Term tree,
   including de Bruijn indices and spans:
       (TAG line:col ...payload...)
   On parse error prints:
       ERROR <stage> <line>:<col> <msg>
   Byte-identical to the Zig twin driver (zig/src/parse_dump.zig); the U3 gate
   diffs the two streams across the corpus. Catches binder/name-resolution
   mistakes (de Bruijn indices) and span-stamping (tloc) before normalize exists.

   The driver passes loader == NULL so imports error out with "imports are not
   available" identically on both sides; import_resolve is stubbed (never called
   with loader == NULL). */
#include "dhall.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* stub import_resolve — never reached with loader == NULL */
Term *import_resolve(ImportLoader *l, const char *spec, const char *hash_hex,
                     Parser *p, DhallError *err) {
    (void)l; (void)spec; (void)hash_hex; (void)p;
    err->stage = ERR_IO;
    snprintf(err->msg, sizeof(err->msg), "imports unavailable");
    err->span = SPAN_NONE;
    err->has_span = false;
    return NULL;
}

static const char *tnames[31] = {
    "TmVar","TmConst","TmText","TmType","TmKind","TmSort","TmLam","TmPi",
    "TmApp","TmIf","TmLet","TmAnn","TmNil","TmCons","TmTextAppend","TmRecordType",
    "TmRecordLit","TmField","TmUnionType","TmUnionLit","TmMerge","TmBuiltin",
    "TmSome","TmNone","TmOp","TmAssert","TmToMap","TmCombine","TmWith",
    "TmListAppend","TmPrefer",
};
static const char *opnames[11] = {
    "OP_ADD","OP_SUB","OP_MUL","OP_LT","OP_LE","OP_GT","OP_GE","OP_EQ",
    "OP_NE","OP_AND","OP_OR",
};

static void dump_str(const char *s) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':  fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout);  break;
        case '\t': fputs("\\t", stdout);  break;
        case '\r': fputs("\\r", stdout);  break;
        default:
            if (*p < 0x20 || *p > 0x7e) printf("\\x%02x", *p);
            else putchar(*p);
            break;
        }
    }
    putchar('"');
}

static void dump_term(Term *t);

static void dump_const(Const c) {
    putchar(' ');
    switch (c.kind) {
    case C_NAT: {
        fputs("C_NAT ", stdout);
        uint32_t sc[2];
        BigNat B = const_bignat(c, sc);
        fputs(bignat_to_decimal(&B), stdout);
        break;
    }
    case C_INT: {
        fputs("C_INT ", stdout);
        uint32_t sc[2];
        BigInt B = const_bigint(c, sc);
        fputs(bigint_to_decimal(&B), stdout);
        break;
    }
    case C_DBL: {
        fputs("C_DBL ", stdout);
        uint64_t bits;
        memcpy(&bits, &c.dbl, 8);
        printf("%016llx", (unsigned long long)bits);
        break;
    }
    case C_BOOL:
        fputs("C_BOOL ", stdout);
        fputs(c.b ? "True" : "False", stdout);
        break;
    }
}

static void dump_fields(Field *fs, int n) {
    fputs(" (", stdout);
    for (int i = 0; i < n; i++) {
        printf("(F %s ", fs[i].label);
        if (fs[i].type) dump_term(fs[i].type); else putchar('0');
        putchar(' ');
        if (fs[i].value) dump_term(fs[i].value); else putchar('0');
        putchar(')');
    }
    putchar(')');
}

static void dump_term(Term *t) {
    printf("(%s %d:%d", tnames[(int)t->tag], t->loc.line, t->loc.col);
    switch (t->tag) {
    case TmVar: printf(" %d", t->as.idx); break;
    case TmConst: dump_const(t->as.c); break;
    case TmText:
        for (TextPart *p = t->as.text; p; p = p->next) {
            fputs(" ", stdout);
            if (p->lit) { fputs("(lit ", stdout); dump_str(p->lit); putchar(')'); }
            else if (p->expr) { fputs("(expr ", stdout); dump_term(p->expr); putchar(')'); }
        }
        break;
    case TmType: case TmKind: case TmSort: case TmNil: break;
    case TmLam: fputs(" ", stdout); dump_term(t->as.lam.dom); fputs(" ", stdout); dump_term(t->as.lam.body); break;
    case TmPi:  fputs(" ", stdout); dump_term(t->as.pi.dom);  fputs(" ", stdout); dump_term(t->as.pi.cod);  break;
    case TmApp: fputs(" ", stdout); dump_term(t->as.app.fn);  fputs(" ", stdout); dump_term(t->as.app.arg); break;
    case TmIf:  fputs(" ", stdout); dump_term(t->as.if_.c); fputs(" ", stdout); dump_term(t->as.if_.t); fputs(" ", stdout); dump_term(t->as.if_.e); break;
    case TmLet:
        fputs(" ", stdout);
        if (t->as.let_.ann) dump_term(t->as.let_.ann); else putchar('0');
        fputs(" ", stdout); dump_term(t->as.let_.val);
        fputs(" ", stdout); dump_term(t->as.let_.body);
        break;
    case TmAnn: fputs(" ", stdout); dump_term(t->as.ann.e); fputs(" ", stdout); dump_term(t->as.ann.ty); break;
    case TmCons: fputs(" ", stdout); dump_term(t->as.cons.head); fputs(" ", stdout); dump_term(t->as.cons.tail); break;
    case TmTextAppend: fputs(" ", stdout); dump_term(t->as.append.a); fputs(" ", stdout); dump_term(t->as.append.b); break;
    case TmRecordType: case TmRecordLit: dump_fields(t->as.rec.fs, t->as.rec.n); break;
    case TmField: fputs(" ", stdout); fputs(t->as.field.label, stdout); fputs(" ", stdout); dump_term(t->as.field.rec); break;
    case TmUnionType: case TmUnionLit: dump_fields(t->as.uni.fs, t->as.uni.n); break;
    case TmMerge: fputs(" ", stdout); dump_term(t->as.merge.handlers); fputs(" ", stdout); dump_term(t->as.merge.u); break;
    case TmBuiltin: fputs(" ", stdout); fputs(t->as.bname, stdout); break;
    case TmSome: fputs(" ", stdout); dump_term(t->as.some.val); break;
    case TmNone: fputs(" ", stdout); dump_term(t->as.none.ty); break;
    case TmOp:
        fputs(" ", stdout); fputs(opnames[(int)t->as.op.op], stdout);
        fputs(" ", stdout); dump_term(t->as.op.lhs);
        fputs(" ", stdout); dump_term(t->as.op.rhs);
        break;
    case TmAssert: fputs(" ", stdout); dump_term(t->as.assert_.body); break;
    case TmToMap:  fputs(" ", stdout); dump_term(t->as.tomap.rec); break;
    case TmCombine: fputs(" ", stdout); dump_term(t->as.combine.lhs); fputs(" ", stdout); dump_term(t->as.combine.rhs); break;
    case TmWith:
        fputs(" ", stdout); dump_term(t->as.with_.rec);
        fputs(" (", stdout);
        for (int i = 0; i < t->as.with_.npath; i++) {
            if (i) putchar(' ');
            fputs(t->as.with_.path[i], stdout);
        }
        putchar(')');
        fputs(" ", stdout); dump_term(t->as.with_.value);
        break;
    case TmListAppend: fputs(" ", stdout); dump_term(t->as.lappend.a); fputs(" ", stdout); dump_term(t->as.lappend.b); break;
    case TmPrefer: fputs(" ", stdout); dump_term(t->as.prefer.lhs); fputs(" ", stdout); dump_term(t->as.prefer.rhs); break;
    }
    putchar(')');
}

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
    Parser p;
    memset(&p, 0, sizeof(p));
    p.loader = NULL;
    DhallError err;
    dhall_error_clear(&err);
    Term *t = parse_source(&p, src, argv[1], &err);
    if (!t) {
        printf("ERROR %d %d:%d %s\n", (int)err.stage, err.span.line, err.span.col, err.msg);
        return 0;
    }
    dump_term(t);
    putchar('\n');
    return 0;
}
