/* normalize.c — eager (call-by-value) strong normalization.
   Adopts the verified de Bruijn normalizer from ref/proto.c VERBATIM
   (beta, let, if, builtin delta rules) and extends it for records,
   unions, merge, field access, text interpolation and text append. */
#include "dhall.h"

/* ---- builtin application matching (verbatim from proto.c) ---- */

static bool match_builtin(const char *name, int n, Term *t, Term **args) {
    Term *cur = t;
    for (int i = n - 1; i >= 0; i--) {
        if (cur->tag != TmApp) return false;
        args[i] = cur->as.app.arg;
        cur = cur->as.app.fn;
    }
    return cur->tag == TmBuiltin && strcmp(cur->as.bname, name) == 0;
}

static Term *reverse_list(Term *xs) {
    Term **elems = malloc(16 * sizeof(Term *));
    int n = 0, cap = 16;
    Term *cur = xs;
    while (cur->tag == TmCons) {
        if (n == cap) { cap *= 2; elems = realloc(elems, cap * sizeof(Term *)); }
        elems[n++] = cur->as.cons.head;
        cur = cur->as.cons.tail;
    }
    Term *out = tm_nil();
    for (int i = 0; i < n; i++) out = tm_cons(elems[i], out);
    free(elems);
    return out;
}

/* ---- text helpers ---- */

/* true if the text term has any interpolation parts */
static bool text_has_interp(Term *t) {
    for (TextPart *p = t->as.text; p; p = p->next)
        if (p->expr) return true;
    return false;
}

/* concatenate all parts into one arena string. interpolations must have
   normalized to plain text literals (guaranteed for well-typed input). */
static char *text_concat(Term *t) {
    TmpBuf b;
    tmpbuf_init(&b);
    for (TextPart *p = t->as.text; p; p = p->next) {
        if (p->lit) tmpbuf_add(&b, p->lit);
        else if (p->expr) {
            Term *e = normalize(p->expr);
            if (e->tag == TmText && e->as.text && !e->as.text->expr && e->as.text->lit)
                tmpbuf_add(&b, e->as.text->lit);
        }
    }
    return tmpbuf_arena(dhall_arena, &b);
}

/* normalize a text term: collapse interpolation into a single literal */
static Term *norm_text(Term *t) {
    if (!text_has_interp(t)) return t;
    return tm_text_lit(text_concat(t));
}

static Term *norm_field(Term *t) {
    Term *r = normalize(t->as.field.rec);
    if (r->tag == TmRecordLit) {
        for (int i = 0; i < r->as.rec.n; i++)
            if (!strcmp(r->as.rec.fs[i].label, t->as.field.label))
                return normalize(r->as.rec.fs[i].value);
        return t; /* unreachable for well-typed terms */
    }
    return tm_field(t->as.field.label, r);
}

static Term *norm_merge(Term *t) {
    Term *h = normalize(t->as.merge.handlers);
    Term *u = normalize(t->as.merge.u);
    if (u->tag == TmUnionLit) {
        /* find the selected alternative (the one carrying a value) */
        const char *sel = NULL; Term *v = NULL;
        for (int i = 0; i < u->as.uni.n; i++)
            if (u->as.uni.fs[i].value) { sel = u->as.uni.fs[i].label; v = u->as.uni.fs[i].value; break; }
        if (sel && h->tag == TmRecordLit) {
            for (int i = 0; i < h->as.rec.n; i++)
                if (!strcmp(h->as.rec.fs[i].label, sel))
                    return normalize(tm_app(h->as.rec.fs[i].value, v));
        }
    }
    return tm_merge(h, u); /* stuck */
}

Term *normalize(Term *t) {
    switch (t->tag) {
    case TmVar: case TmConst: case TmType: case TmKind: case TmSort:
    case TmNil: case TmBuiltin:
        return t;
    case TmLam: return tm_lam(normalize(t->as.lam.dom), normalize(t->as.lam.body));
    case TmPi:  return tm_pi(normalize(t->as.pi.dom), normalize(t->as.pi.cod));
    case TmAnn: return normalize(t->as.ann.e);
    case TmLet: return normalize(subst(0, t->as.let_.val, t->as.let_.body));
    case TmCons: return tm_cons(normalize(t->as.cons.head), normalize(t->as.cons.tail));
    case TmText: return norm_text(t);
    case TmTextAppend: {
        Term *a = normalize(t->as.append.a);
        Term *b = normalize(t->as.append.b);
        if (a->tag == TmText && b->tag == TmText) {
            /* only safe when both are pure literals (no interpolation) */
            if (!text_has_interp(a) && !text_has_interp(b)) {
                TmpBuf buf; tmpbuf_init(&buf);
                tmpbuf_add(&buf, a->as.text->lit);
                tmpbuf_add(&buf, b->as.text->lit);
                return tm_text_lit(tmpbuf_arena(dhall_arena, &buf));
            }
        }
        return tm_append(a, b);
    }
    case TmIf: {
        Term *c = normalize(t->as.if_.c);
        if (c->tag == TmConst && c->as.c.kind == C_BOOL)
            return c->as.c.b ? normalize(t->as.if_.t) : normalize(t->as.if_.e);
        return tm_if(c, normalize(t->as.if_.t), normalize(t->as.if_.e));
    }
    case TmApp: {
        Term *args[6];
        if (match_builtin("List/map", 4, t, args)) {
            Term *xs = normalize(args[3]);
            if (xs->tag == TmNil) return tm_nil();
            if (xs->tag == TmCons) {
                Term *head = normalize(tm_app(args[2], xs->as.cons.head));
                Term *rest = normalize(tm_app(tm_app(tm_app(tm_app(tm_builtin("List/map"), args[0]), args[1]), args[2]), xs->as.cons.tail));
                return tm_cons(head, rest);
            }
        }
        if (match_builtin("List/filter", 3, t, args)) {
            Term *xs = normalize(args[2]);
            if (xs->tag == TmNil) return tm_nil();
            if (xs->tag == TmCons) {
                Term *pred = normalize(tm_app(args[1], xs->as.cons.head));
                Term *tail = normalize(tm_app(tm_app(tm_app(tm_builtin("List/filter"), args[0]), args[1]), xs->as.cons.tail));
                if (pred->tag == TmConst && pred->as.c.kind == C_BOOL)
                    return pred->as.c.b ? tm_cons(normalize(xs->as.cons.head), tail) : tail;
                return tm_cons(normalize(xs->as.cons.head), tail);
            }
        }
        if (match_builtin("List/reverse", 2, t, args)) {
            return reverse_list(normalize(args[1]));
        }
        if (match_builtin("List/fold", 5, t, args)) {
            Term *xs = normalize(args[1]);
            if (xs->tag == TmNil) return normalize(args[4]);
            if (xs->tag == TmCons) {
                Term *rest = normalize(tm_app(tm_app(tm_app(tm_app(tm_app(tm_builtin("List/fold"), args[0]), xs->as.cons.tail), args[2]), args[3]), args[4]));
                return normalize(tm_app(tm_app(args[3], xs->as.cons.head), rest));
            }
        }
        Term *f = normalize(t->as.app.fn);
        if (f->tag == TmLam) return normalize(subst(0, t->as.app.arg, f->as.lam.body));
        return tm_app(f, normalize(t->as.app.arg));
    }
    case TmRecordType: {
        Field *fs = arena_alloc(dhall_arena, t->as.rec.n * sizeof(Field));
        for (int i = 0; i < t->as.rec.n; i++) {
            fs[i].label = t->as.rec.fs[i].label;
            fs[i].type = t->as.rec.fs[i].type ? normalize(t->as.rec.fs[i].type) : NULL;
            fs[i].value = NULL;
        }
        return tm_record_type(fs, t->as.rec.n);
    }
    case TmRecordLit: {
        Field *fs = arena_alloc(dhall_arena, t->as.rec.n * sizeof(Field));
        for (int i = 0; i < t->as.rec.n; i++) {
            fs[i].label = t->as.rec.fs[i].label;
            fs[i].type = NULL;
            fs[i].value = normalize(t->as.rec.fs[i].value);
        }
        return tm_record_lit(fs, t->as.rec.n);
    }
    case TmField: return norm_field(t);
    case TmUnionType: {
        Field *fs = arena_alloc(dhall_arena, t->as.uni.n * sizeof(Field));
        for (int i = 0; i < t->as.uni.n; i++) {
            fs[i].label = t->as.uni.fs[i].label;
            fs[i].type = t->as.uni.fs[i].type ? normalize(t->as.uni.fs[i].type) : NULL;
            fs[i].value = NULL;
        }
        return tm_union_type(fs, t->as.uni.n);
    }
    case TmUnionLit: {
        Field *fs = arena_alloc(dhall_arena, t->as.uni.n * sizeof(Field));
        for (int i = 0; i < t->as.uni.n; i++) {
            fs[i].label = t->as.uni.fs[i].label;
            fs[i].type = t->as.uni.fs[i].type ? normalize(t->as.uni.fs[i].type) : NULL;
            fs[i].value = t->as.uni.fs[i].value ? normalize(t->as.uni.fs[i].value) : NULL;
        }
        return tm_union_lit(fs, t->as.uni.n);
    }
    case TmMerge: return norm_merge(t);
    }
    return t;
}
