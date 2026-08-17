/* ast.c — Term constructors, capture-avoiding de Bruijn shift/subst,
   alpha-equivalence, and a normal-form pretty-printer.
   Adopts the verified de Bruijn core from ref/proto.c. */
#include "dhall.h"
#include <math.h>

Arena *dhall_arena = NULL;

static Term *mk(TermTag tag, SourceSpan loc) {
    Term *t = arena_alloc(dhall_arena, sizeof(Term));
    t->tag = tag;
    t->loc = loc;
    return t;
}

/* ---------------- error helpers ---------------- */

void dhall_error_clear(DhallError *e) {
    e->stage = ERR_NONE;
    e->msg[0] = '\0';
    e->span = SPAN_NONE;
    e->has_span = false;
}

void dhall_error_set(DhallError *e, ErrorStage st, SourceSpan sp, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(e->msg, sizeof(e->msg), fmt, ap);
    va_end(ap);
    e->stage = st;
    e->span = sp;
    e->has_span = (sp.line > 0);
}

int dhall_error_exit(DhallError *e) {
    switch (e->stage) {
    case ERR_TYPE: return 1;
    case ERR_LEX:
    case ERR_PARSE: return 2;
    default: return 3;
    }
}

/* ---------------- constructors ---------------- */

Term *tm_var(int idx)            { Term *t = mk(TmVar, SPAN_NONE); t->as.idx = idx; return t; }
Term *tm_const(Const c)          { Term *t = mk(TmConst, SPAN_NONE); t->as.c = c; return t; }
Term *tm_nat(uint64_t n)         { Const c = { C_NAT, n, 0, 0, false, NULL, NULL }; return tm_const(c); }
Term *tm_int(int64_t n)          { Const c = { C_INT, 0, n, 0, false, NULL, NULL }; return tm_const(c); }
Term *tm_dbl(double d)           { Const c = { C_DBL, 0, 0, d, false, NULL, NULL }; return tm_const(c); }
Term *tm_bool(bool b)            { Const c = { C_BOOL, 0, 0, 0, b, NULL, NULL }; return tm_const(c); }
Term *tm_text(TextPart *parts)   { Term *t = mk(TmText, SPAN_NONE); t->as.text = parts; return t; }
Term *tm_text_lit(const char *s) { return text_parts_single(s); }
Term *tm_type(void)              { return mk(TmType, SPAN_NONE); }
Term *tm_kind(void)              { return mk(TmKind, SPAN_NONE); }
Term *tm_sort(void)              { return mk(TmSort, SPAN_NONE); }
Term *tm_lam(Term *d, Term *b)   { Term *t = mk(TmLam, SPAN_NONE); t->as.lam.dom = d; t->as.lam.body = b; return t; }
Term *tm_pi(Term *d, Term *c)    { Term *t = mk(TmPi, SPAN_NONE); t->as.pi.dom = d; t->as.pi.cod = c; return t; }
Term *tm_app(Term *f, Term *x)   { Term *t = mk(TmApp, SPAN_NONE); t->as.app.fn = f; t->as.app.arg = x; return t; }
Term *tm_if(Term *c, Term *t, Term *e) { Term *r = mk(TmIf, SPAN_NONE); r->as.if_.c = c; r->as.if_.t = t; r->as.if_.e = e; return r; }
Term *tm_let(Term *an, Term *v, Term *b) { Term *r = mk(TmLet, SPAN_NONE); r->as.let_.ann = an; r->as.let_.val = v; r->as.let_.body = b; return r; }
Term *tm_ann(Term *e, Term *ty)  { Term *r = mk(TmAnn, SPAN_NONE); r->as.ann.e = e; r->as.ann.ty = ty; return r; }
Term *tm_nil(void)               { return mk(TmNil, SPAN_NONE); }
Term *tm_cons(Term *h, Term *t)  { Term *r = mk(TmCons, SPAN_NONE); r->as.cons.head = h; r->as.cons.tail = t; return r; }
Term *tm_append(Term *a, Term *b){ Term *r = mk(TmTextAppend, SPAN_NONE); r->as.append.a = a; r->as.append.b = b; return r; }
Term *tm_builtin(const char *n)  { Term *t = mk(TmBuiltin, SPAN_NONE); t->as.bname = arena_strdup(dhall_arena, n); return t; }

Term *tm_record_type(Field *fs, int n) { Term *t = mk(TmRecordType, SPAN_NONE); t->as.rec.fs = fs; t->as.rec.n = n; return t; }
Term *tm_record_lit(Field *fs, int n)  { Term *t = mk(TmRecordLit, SPAN_NONE); t->as.rec.fs = fs; t->as.rec.n = n; return t; }
Term *tm_field(const char *l, Term *r) { Term *t = mk(TmField, SPAN_NONE); t->as.field.label = arena_strdup(dhall_arena, l); t->as.field.rec = r; return t; }
Term *tm_union_type(Field *fs, int n)  { Term *t = mk(TmUnionType, SPAN_NONE); t->as.uni.fs = fs; t->as.uni.n = n; return t; }
Term *tm_union_lit(Field *fs, int n)   { Term *t = mk(TmUnionLit, SPAN_NONE); t->as.uni.fs = fs; t->as.uni.n = n; return t; }
Term *tm_merge(Term *h, Term *u)       { Term *t = mk(TmMerge, SPAN_NONE); t->as.merge.handlers = h; t->as.merge.u = u; return t; }

Term *tm_some(Term *v)  { Term *t = mk(TmSome, SPAN_NONE); t->as.some.val = v; return t; }
Term *tm_none(Term *ty) { Term *t = mk(TmNone, SPAN_NONE); t->as.none.ty = ty; return t; }
Term *tm_op(OpKind op, Term *l, Term *r) { Term *t = mk(TmOp, SPAN_NONE); t->as.op.op = op; t->as.op.lhs = l; t->as.op.rhs = r; return t; }
Term *tm_assert(Term *b)  { Term *t = mk(TmAssert, SPAN_NONE); t->as.assert_.body = b; return t; }
Term *tm_tomap(Term *r)   { Term *t = mk(TmToMap, SPAN_NONE); t->as.tomap.rec = r; return t; }
Term *tm_combine(Term *l, Term *r) { Term *t = mk(TmCombine, SPAN_NONE); t->as.combine.lhs = l; t->as.combine.rhs = r; return t; }
Term *tm_list_append(Term *a, Term *b) { Term *t = mk(TmListAppend, SPAN_NONE); t->as.lappend.a = a; t->as.lappend.b = b; return t; }
Term *tm_prefer(Term *l, Term *r) { Term *t = mk(TmPrefer, SPAN_NONE); t->as.prefer.lhs = l; t->as.prefer.rhs = r; return t; }
Term *tm_with(Term *rec, char **path, int npath, Term *value) {
    Term *t = mk(TmWith, SPAN_NONE);
    t->as.with_.rec = rec;
    t->as.with_.path = path;
    t->as.with_.npath = npath;
    t->as.with_.value = value;
    return t;
}

Field *field_new(const char *label, Term *type, Term *value) {
    Field *f = arena_alloc(dhall_arena, sizeof(Field));
    f->label = arena_strdup(dhall_arena, label);
    f->type = type;
    f->value = value;
    return f;
}

Term *text_parts_single(const char *lit) {
    TextPart *p = arena_alloc(dhall_arena, sizeof(TextPart));
    p->lit = arena_strdup(dhall_arena, lit);
    p->expr = NULL;
    p->next = NULL;
    return tm_text(p);
}

/* ---------------- shift ---------------- */

static Term *shift_text(int d, int cutoff, Term *t) {
    TextPart *head = NULL, *tail = NULL;
    for (TextPart *p = t->as.text; p; p = p->next) {
        TextPart *np = arena_alloc(dhall_arena, sizeof(TextPart));
        np->lit = p->lit;
        np->expr = p->expr ? shift(d, cutoff, p->expr) : NULL;
        np->next = NULL;
        if (tail) tail->next = np; else head = np;
        tail = np;
    }
    Term *r = tm_text(head);
    r->loc = t->loc;
    return r;
}

Term *shift(int d, int cutoff, Term *t) {
    switch (t->tag) {
    case TmVar: return (t->as.idx >= cutoff) ? tm_var(t->as.idx + d) : t;
    case TmLam: return tm_lam(shift(d, cutoff, t->as.lam.dom), shift(d, cutoff + 1, t->as.lam.body));
    case TmPi:  return tm_pi(shift(d, cutoff, t->as.pi.dom), shift(d, cutoff + 1, t->as.pi.cod));
    case TmApp: return tm_app(shift(d, cutoff, t->as.app.fn), shift(d, cutoff, t->as.app.arg));
    case TmIf:  return tm_if(shift(d, cutoff, t->as.if_.c), shift(d, cutoff, t->as.if_.t), shift(d, cutoff, t->as.if_.e));
    case TmLet: return tm_let(t->as.let_.ann ? shift(d, cutoff, t->as.let_.ann) : NULL,
                              shift(d, cutoff, t->as.let_.val),
                              shift(d, cutoff + 1, t->as.let_.body));
    case TmAnn: return tm_ann(shift(d, cutoff, t->as.ann.e), shift(d, cutoff, t->as.ann.ty));
    case TmCons:return tm_cons(shift(d, cutoff, t->as.cons.head), shift(d, cutoff, t->as.cons.tail));
    case TmTextAppend: return tm_append(shift(d, cutoff, t->as.append.a), shift(d, cutoff, t->as.append.b));
    case TmText: return shift_text(d, cutoff, t);
    case TmRecordType:
    case TmRecordLit: {
        Field *fs = arena_alloc(dhall_arena, t->as.rec.n * sizeof(Field));
        for (int i = 0; i < t->as.rec.n; i++) {
            Field *src = &t->as.rec.fs[i];
            fs[i].label = src->label;
            fs[i].type = src->type ? shift(d, cutoff, src->type) : NULL;
            fs[i].value = src->value ? shift(d, cutoff, src->value) : NULL;
        }
        return (t->tag == TmRecordType) ? tm_record_type(fs, t->as.rec.n) : tm_record_lit(fs, t->as.rec.n);
    }
    case TmField: return tm_field(t->as.field.label, shift(d, cutoff, t->as.field.rec));
    case TmUnionType:
    case TmUnionLit: {
        Field *fs = arena_alloc(dhall_arena, t->as.uni.n * sizeof(Field));
        for (int i = 0; i < t->as.uni.n; i++) {
            Field *src = &t->as.uni.fs[i];
            fs[i].label = src->label;
            fs[i].type = src->type ? shift(d, cutoff, src->type) : NULL;
            fs[i].value = src->value ? shift(d, cutoff, src->value) : NULL;
        }
        return (t->tag == TmUnionType) ? tm_union_type(fs, t->as.uni.n) : tm_union_lit(fs, t->as.uni.n);
    }
    case TmMerge: return tm_merge(shift(d, cutoff, t->as.merge.handlers), shift(d, cutoff, t->as.merge.u));
    case TmSome: return tm_some(shift(d, cutoff, t->as.some.val));
    case TmNone: return tm_none(shift(d, cutoff, t->as.none.ty));
    case TmOp:   return tm_op(t->as.op.op, shift(d, cutoff, t->as.op.lhs), shift(d, cutoff, t->as.op.rhs));
    case TmAssert: return tm_assert(shift(d, cutoff, t->as.assert_.body));
    case TmToMap:  return tm_tomap(shift(d, cutoff, t->as.tomap.rec));
    case TmCombine: return tm_combine(shift(d, cutoff, t->as.combine.lhs), shift(d, cutoff, t->as.combine.rhs));
    case TmListAppend: return tm_list_append(shift(d, cutoff, t->as.lappend.a), shift(d, cutoff, t->as.lappend.b));
    case TmPrefer: return tm_prefer(shift(d, cutoff, t->as.prefer.lhs), shift(d, cutoff, t->as.prefer.rhs));
    case TmWith:    return tm_with(shift(d, cutoff, t->as.with_.rec), t->as.with_.path,
                                   t->as.with_.npath, shift(d, cutoff, t->as.with_.value));
    case TmConst: case TmType: case TmKind: case TmSort:
    case TmNil: case TmBuiltin: return t;
    }
    return t;
}

/* ---------------- subst ---------------- */

static Term *subst_text(int j, Term *s, Term *t) {
    TextPart *head = NULL, *tail = NULL;
    for (TextPart *p = t->as.text; p; p = p->next) {
        TextPart *np = arena_alloc(dhall_arena, sizeof(TextPart));
        np->lit = p->lit;
        np->expr = p->expr ? subst(j, s, p->expr) : NULL;
        np->next = NULL;
        if (tail) tail->next = np; else head = np;
        tail = np;
    }
    Term *r = tm_text(head);
    r->loc = t->loc;
    return r;
}

Term *subst(int j, Term *s, Term *t) {
    switch (t->tag) {
    case TmVar: return (t->as.idx == j) ? s : (t->as.idx > j) ? tm_var(t->as.idx - 1) : t;
    case TmLam: return tm_lam(subst(j, s, t->as.lam.dom), subst(j + 1, shift(1, 0, s), t->as.lam.body));
    case TmPi:  return tm_pi(subst(j, s, t->as.pi.dom), subst(j + 1, shift(1, 0, s), t->as.pi.cod));
    case TmApp: return tm_app(subst(j, s, t->as.app.fn), subst(j, s, t->as.app.arg));
    case TmIf:  return tm_if(subst(j, s, t->as.if_.c), subst(j, s, t->as.if_.t), subst(j, s, t->as.if_.e));
    case TmLet: return tm_let(t->as.let_.ann ? subst(j, s, t->as.let_.ann) : NULL,
                              subst(j, s, t->as.let_.val),
                              subst(j + 1, shift(1, 0, s), t->as.let_.body));
    case TmAnn: return tm_ann(subst(j, s, t->as.ann.e), subst(j, s, t->as.ann.ty));
    case TmCons:return tm_cons(subst(j, s, t->as.cons.head), subst(j, s, t->as.cons.tail));
    case TmTextAppend: return tm_append(subst(j, s, t->as.append.a), subst(j, s, t->as.append.b));
    case TmText: return subst_text(j, s, t);
    case TmRecordType:
    case TmRecordLit: {
        Field *fs = arena_alloc(dhall_arena, t->as.rec.n * sizeof(Field));
        for (int i = 0; i < t->as.rec.n; i++) {
            Field *src = &t->as.rec.fs[i];
            fs[i].label = src->label;
            fs[i].type = src->type ? subst(j, s, src->type) : NULL;
            fs[i].value = src->value ? subst(j, s, src->value) : NULL;
        }
        return (t->tag == TmRecordType) ? tm_record_type(fs, t->as.rec.n) : tm_record_lit(fs, t->as.rec.n);
    }
    case TmField: return tm_field(t->as.field.label, subst(j, s, t->as.field.rec));
    case TmUnionType:
    case TmUnionLit: {
        Field *fs = arena_alloc(dhall_arena, t->as.uni.n * sizeof(Field));
        for (int i = 0; i < t->as.uni.n; i++) {
            Field *src = &t->as.uni.fs[i];
            fs[i].label = src->label;
            fs[i].type = src->type ? subst(j, s, src->type) : NULL;
            fs[i].value = src->value ? subst(j, s, src->value) : NULL;
        }
        return (t->tag == TmUnionType) ? tm_union_type(fs, t->as.uni.n) : tm_union_lit(fs, t->as.uni.n);
    }
    case TmMerge: return tm_merge(subst(j, s, t->as.merge.handlers), subst(j, s, t->as.merge.u));
    case TmSome: return tm_some(subst(j, s, t->as.some.val));
    case TmNone: return tm_none(subst(j, s, t->as.none.ty));
    case TmOp:   return tm_op(t->as.op.op, subst(j, s, t->as.op.lhs), subst(j, s, t->as.op.rhs));
    case TmAssert: return tm_assert(subst(j, s, t->as.assert_.body));
    case TmToMap:  return tm_tomap(subst(j, s, t->as.tomap.rec));
    case TmCombine: return tm_combine(subst(j, s, t->as.combine.lhs), subst(j, s, t->as.combine.rhs));
    case TmListAppend: return tm_list_append(subst(j, s, t->as.lappend.a), subst(j, s, t->as.lappend.b));
    case TmPrefer: return tm_prefer(subst(j, s, t->as.prefer.lhs), subst(j, s, t->as.prefer.rhs));
    case TmWith:    return tm_with(subst(j, s, t->as.with_.rec), t->as.with_.path,
                                   t->as.with_.npath, subst(j, s, t->as.with_.value));
    case TmConst: case TmType: case TmKind: case TmSort:
    case TmNil: case TmBuiltin: return t;
    }
    return t;
}

/* ---------------- alphaEq ---------------- */

static bool text_eq(TextPart *a, TextPart *b) {
    while (a && b) {
        if ((a->lit ? true : false) != (b->lit ? true : false)) return false;
        if (a->lit && strcmp(a->lit, b->lit) != 0) return false;
        if (a->expr || b->expr) {
            if (!a->expr || !b->expr) return false;
            if (!alpha_eq(a->expr, b->expr)) return false;
        }
        a = a->next; b = b->next;
    }
    return a == b;
}

static bool fields_eq(Field *a, int na, Field *b, int nb) {
    if (na != nb) return false;
    for (int i = 0; i < na; i++) {
        if (strcmp(a[i].label, b[i].label) != 0) return false;
        if ((a[i].type ? true : false) != (b[i].type ? true : false)) return false;
        if (a[i].type && !alpha_eq(a[i].type, b[i].type)) return false;
        if ((a[i].value ? true : false) != (b[i].value ? true : false)) return false;
        if (a[i].value && !alpha_eq(a[i].value, b[i].value)) return false;
    }
    return true;
}

bool alpha_eq(Term *a, Term *b) {
    /* The empty record value `{=}` and empty record type `{}` coincide (they
     * are the same unit term — `{=}` : `{}`).  Treat record type/literal and
     * union type/literal as the same tag so a value and its declared type are
     * alpha-equal; `fields_eq` already compares only the populated slots, so a
     * record literal `{ a = 1 }` still differs from a record type `{ a : Nat }`. */
    int atag = a->tag, btag = b->tag;
    if (atag == TmRecordLit || atag == TmRecordType) {
        if (btag == TmRecordLit || btag == TmRecordType) {
            if (atag == btag) {
                /* same record tag: normal path below (fields_eq via the switch) */
            } else {
                return fields_eq(a->as.rec.fs, a->as.rec.n, b->as.rec.fs, b->as.rec.n);
            }
        }
    }
    if (atag == TmUnionLit || atag == TmUnionType) {
        if (btag == TmUnionLit || btag == TmUnionType) {
            if (atag == btag) {
                /* same union tag: normal path below */
            } else {
                return fields_eq(a->as.uni.fs, a->as.uni.n, b->as.uni.fs, b->as.uni.n);
            }
        }
    }
    if (a->tag != b->tag) return false;
    switch (a->tag) {
    case TmVar: return a->as.idx == b->as.idx;
    case TmConst: {
        Const *x = &a->as.c, *y = &b->as.c;
        if (x->kind != y->kind) return false;
        switch (x->kind) {
        case C_NAT: {
            uint32_t sa[2], sb[2];
            BigNat A = const_bignat(*x, sa);
            BigNat B = const_bignat(*y, sb);
            return bignat_cmp(&A, &B) == 0;
        }
        case C_INT: {
            uint32_t sa[2], sb[2];
            BigInt A = const_bigint(*x, sa);
            BigInt B = const_bigint(*y, sb);
            return bigint_cmp(&A, &B) == 0;
        }
        case C_DBL: return x->dbl == y->dbl;
        case C_BOOL: return x->b == y->b;
        }
        return false;
    }
    case TmText: return text_eq(a->as.text, b->as.text);
    case TmType: case TmKind: case TmSort: case TmNil: return true;
    case TmBuiltin: return strcmp(a->as.bname, b->as.bname) == 0;
    case TmLam: return alpha_eq(a->as.lam.dom, b->as.lam.dom) && alpha_eq(a->as.lam.body, b->as.lam.body);
    case TmPi:  return alpha_eq(a->as.pi.dom, b->as.pi.dom) && alpha_eq(a->as.pi.cod, b->as.pi.cod);
    case TmApp: return alpha_eq(a->as.app.fn, b->as.app.fn) && alpha_eq(a->as.app.arg, b->as.app.arg);
    case TmIf:  return alpha_eq(a->as.if_.c, b->as.if_.c) && alpha_eq(a->as.if_.t, b->as.if_.t) && alpha_eq(a->as.if_.e, b->as.if_.e);
    case TmLet: return ((a->as.let_.ann && b->as.let_.ann) ? alpha_eq(a->as.let_.ann, b->as.let_.ann) : (a->as.let_.ann == b->as.let_.ann))
                       && alpha_eq(a->as.let_.val, b->as.let_.val) && alpha_eq(a->as.let_.body, b->as.let_.body);
    case TmAnn: return alpha_eq(a->as.ann.e, b->as.ann.e) && alpha_eq(a->as.ann.ty, b->as.ann.ty);
    case TmCons:return alpha_eq(a->as.cons.head, b->as.cons.head) && alpha_eq(a->as.cons.tail, b->as.cons.tail);
    case TmTextAppend: return alpha_eq(a->as.append.a, b->as.append.a) && alpha_eq(a->as.append.b, b->as.append.b);
    case TmRecordType:
    case TmRecordLit: return fields_eq(a->as.rec.fs, a->as.rec.n, b->as.rec.fs, b->as.rec.n);
    case TmField: return strcmp(a->as.field.label, b->as.field.label) == 0 && alpha_eq(a->as.field.rec, b->as.field.rec);
    case TmUnionType:
    case TmUnionLit: return fields_eq(a->as.uni.fs, a->as.uni.n, b->as.uni.fs, b->as.uni.n);
    case TmMerge: return alpha_eq(a->as.merge.handlers, b->as.merge.handlers) && alpha_eq(a->as.merge.u, b->as.merge.u);
    case TmSome: return alpha_eq(a->as.some.val, b->as.some.val);
    case TmNone: return alpha_eq(a->as.none.ty, b->as.none.ty);
    case TmOp:   return a->as.op.op == b->as.op.op && alpha_eq(a->as.op.lhs, b->as.op.lhs) && alpha_eq(a->as.op.rhs, b->as.op.rhs);
    case TmAssert: return alpha_eq(a->as.assert_.body, b->as.assert_.body);
    case TmToMap:  return alpha_eq(a->as.tomap.rec, b->as.tomap.rec);
    case TmCombine: return alpha_eq(a->as.combine.lhs, b->as.combine.lhs) && alpha_eq(a->as.combine.rhs, b->as.combine.rhs);
    case TmListAppend: return alpha_eq(a->as.lappend.a, b->as.lappend.a) && alpha_eq(a->as.lappend.b, b->as.lappend.b);
    case TmPrefer: return alpha_eq(a->as.prefer.lhs, b->as.prefer.lhs) && alpha_eq(a->as.prefer.rhs, b->as.prefer.rhs);
    case TmWith: {
        if (a->as.with_.npath != b->as.with_.npath) return false;
        for (int i = 0; i < a->as.with_.npath; i++)
            if (strcmp(a->as.with_.path[i], b->as.with_.path[i]) != 0) return false;
        return alpha_eq(a->as.with_.rec, b->as.with_.rec) && alpha_eq(a->as.with_.value, b->as.with_.value);
    }
    }
    return false;
}

/* ---------------- pretty-printer (normal form) ---------------- */

static void print_text_escaped(FILE *out, const char *s) {
    for (const char *p = s; *p; p++) {
        switch (*p) {
        case '"': fputs("\\\"", out); break;
        case '\\': fputs("\\\\", out); break;
        case '$': fputs("\\$", out); break;
        case '\n': fputs("\\n", out); break;
        case '\t': fputs("\\t", out); break;
        case '\r': fputs("\\r", out); break;
        default: fputc(*p, out); break;
        }
    }
}

static const char *op_str(OpKind op) {
    switch (op) {
    case OP_ADD: return "+";
    case OP_SUB: return "-";
    case OP_MUL: return "*";
    case OP_LT: return "<";
    case OP_LE: return "<=";
    case OP_GT: return ">";
    case OP_GE: return ">=";
    case OP_EQ: return "==";
    case OP_NE: return "!=";
    case OP_AND: return "&&";
    case OP_OR: return "||";
    }
    return "?";
}

/* names for de Bruijn printing (lambda/pi) — synthetic */
static void print_rec_fields(FILE *out, Field *fs, int n, bool types) {
    fputc('{', out);
    for (int i = 0; i < n; i++) {
        if (i) fputc(',', out);
        fputs(fs[i].label, out);
        fputs(types ? ":" : "=", out);
        if (types) print_term(out, fs[i].type);
        else print_term(out, fs[i].value);
    }
    fputc('}', out);
}

static void print_uni_fields(FILE *out, Field *fs, int n) {
    fputc('<', out);
    for (int i = 0; i < n; i++) {
        if (i) fputc('|', out);
        fputs(fs[i].label, out);
        if (fs[i].value) { fputs(" = ", out); print_term(out, fs[i].value); }
        else { fputc(':', out); print_term(out, fs[i].type); }
    }
    fputc('>', out);
}

static void print_list(FILE *out, Term *t) {
    fputc('[', out);
    bool first = true;
    while (t->tag == TmCons) {
        if (!first) fputc(',', out);
        first = false;
        print_term(out, t->as.cons.head);
        t = t->as.cons.tail;
    }
    fputc(']', out);
}

/* shortest-round-trip Double literal: the fewest significant digits that
   strtod-parse back to the same double, always a valid Dhall Double literal
   (numeric-double-literal = 1*DIGIT ( '.' 1*DIGIT [exponent] / exponent ),
   exponent = "e" ["+"/"-"] 1*DIGIT). Non-finite keeps the legacy lowercase
   nan/inf/-inf (a documented deviation from NaN/Infinity/-Infinity). */
void dbl_fmt(char *buf, size_t cap, double d) {
    if (isnan(d))       { snprintf(buf, cap, "nan");  return; }
    if (d == INFINITY)  { snprintf(buf, cap, "inf");  return; }
    if (d == -INFINITY) { snprintf(buf, cap, "-inf"); return; }
    for (int p = 0; p <= 17; p++) {
        snprintf(buf, cap, "%.*g", p, d);
        if (strtod(buf, NULL) == d) break; /* first precision that round-trips */
    }
    if (!strchr(buf, '.') && !strchr(buf, 'e') && !strchr(buf, 'E')) {
        size_t n = strlen(buf);
        snprintf(buf + n, cap - n, ".0");  /* bare integer -> "N.0" */
    }
}

void print_term(FILE *out, Term *t);

static void print_lam_body(FILE *out, Term *dom, Term *body) {
    fputs("\\(_ : ", out);
    print_term(out, dom);
    fputs(") -> ", out);
    print_term(out, body);
}

void print_term(FILE *out, Term *t) {
    switch (t->tag) {
    case TmVar: { fprintf(out, "_%d", t->as.idx); break; }
    case TmConst:
        switch (t->as.c.kind) {
        case C_NAT: {
            uint32_t scratch[2];
            BigNat B = const_bignat(t->as.c, scratch);
            fputs(bignat_to_decimal(&B), out);
            break;
        }
        case C_INT: {
            uint32_t scratch[2];
            BigInt B = const_bigint(t->as.c, scratch);
            fputs(bigint_to_decimal(&B), out);
            break;
        }
        case C_DBL: {
            char dbuf[64];
            dbl_fmt(dbuf, sizeof(dbuf), t->as.c.dbl);
            fputs(dbuf, out);
            break;
        }
        case C_BOOL: fputs(t->as.c.b ? "True" : "False", out); break;
        }
        break;
    case TmText: {
        fputc('"', out);
        for (TextPart *p = t->as.text; p; p = p->next) {
            if (p->lit) print_text_escaped(out, p->lit);
            else if (p->expr) {
                fputs("${", out);
                print_term(out, p->expr);
                fputc('}', out);
            }
        }
        fputc('"', out);
        break;
    }
    case TmType: fputs("Type", out); break;
    case TmKind: fputs("Kind", out); break;
    case TmSort: fputs("Sort", out); break;
    case TmLam: print_lam_body(out, t->as.lam.dom, t->as.lam.body); break;
    case TmPi: {
        fputs("forall (_ : ", out);
        print_term(out, t->as.pi.dom);
        fputs(") -> ", out);
        print_term(out, t->as.pi.cod);
        break;
    }
    case TmApp:
        fputc('(', out); print_term(out, t->as.app.fn); fputc(' ', out);
        print_term(out, t->as.app.arg); fputc(')', out);
        break;
    case TmIf: { fputs("(if ", out); print_term(out, t->as.if_.c); fputs(" then ", out);
                 print_term(out, t->as.if_.t); fputs(" else ", out); print_term(out, t->as.if_.e); fputc(')', out); break; }
    case TmLet: { fputs("(let = ", out); print_term(out, t->as.let_.val); fputs(" in ", out);
                  print_term(out, t->as.let_.body); fputc(')', out); break; }
    case TmAnn: { fputc('(', out); print_term(out, t->as.ann.e); fputs(" : ", out);
                  print_term(out, t->as.ann.ty); fputc(')', out); break; }
    case TmNil: fputs("[]", out); break;
    case TmCons: print_list(out, t); break;
    case TmTextAppend: { fputc('(', out); print_term(out, t->as.append.a); fputs(" ++ ", out);
                         print_term(out, t->as.append.b); fputc(')', out); break; }
    case TmRecordType: print_rec_fields(out, t->as.rec.fs, t->as.rec.n, true); break;
    case TmRecordLit: print_rec_fields(out, t->as.rec.fs, t->as.rec.n, false); break;
    case TmField: { print_term(out, t->as.field.rec); fputc('.', out); fputs(t->as.field.label, out); break; }
    case TmUnionType: print_uni_fields(out, t->as.uni.fs, t->as.uni.n); break;
    case TmUnionLit: print_uni_fields(out, t->as.uni.fs, t->as.uni.n); break;
    case TmMerge: { fputs("(merge ", out); print_term(out, t->as.merge.handlers); fputc(' ', out);
                    print_term(out, t->as.merge.u); fputc(')', out); break; }
    case TmBuiltin: fputs(t->as.bname, out); break;
    case TmSome: { fputs("Some ", out); print_term(out, t->as.some.val); break; }
    case TmNone: { fputs("None ", out); print_term(out, t->as.none.ty); break; }
    case TmOp: { fputc('(', out); print_term(out, t->as.op.lhs); fprintf(out, " %s ", op_str(t->as.op.op));
                 print_term(out, t->as.op.rhs); fputc(')', out); break; }
    case TmAssert: { fputs("(assert : ", out); print_term(out, t->as.assert_.body); fputc(')', out); break; }
    case TmToMap:  { fputs("(toMap ", out); print_term(out, t->as.tomap.rec); fputc(')', out); break; }
    case TmCombine: { fputc('(', out); print_term(out, t->as.combine.lhs); fputs(" /\\ ", out);
                      print_term(out, t->as.combine.rhs); fputc(')', out); break; }
    case TmListAppend: { fputc('(', out); print_term(out, t->as.lappend.a); fputs(" # ", out);
                         print_term(out, t->as.lappend.b); fputc(')', out); break; }
    case TmPrefer: { fputc('(', out); print_term(out, t->as.prefer.lhs); fputs(" // ", out);
                     print_term(out, t->as.prefer.rhs); fputc(')', out); break; }
    case TmWith: { fputc('(', out); print_term(out, t->as.with_.rec); fputs(" with ", out);
                   for (int i = 0; i < t->as.with_.npath; i++) {
                       if (i) fputc('.', out);
                       fputs(t->as.with_.path[i], out);
                   }
                   fputs(" = ", out); print_term(out, t->as.with_.value); fputc(')', out); break; }
    }
}
