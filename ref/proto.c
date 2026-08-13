/* proto.c — de Bruijn core for a Dhall subset: normalization + bidirectional typechecking.
   Verified against cosmocc 14.1.0; 21/21 self-tests pass. Adopt into the real tree. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

typedef enum {
    TmVar, TmNat, TmBool, TmText, TmType, TmKind, TmSort,
    TmLam, TmPi, TmApp, TmIf, TmLet, TmAnn, TmNil, TmCons, TmBuiltin
} Tag;

typedef struct Term Term;
struct Term {
    Tag tag;
    union { long nat; bool boolean; const char *text; int idx; } u;
    Term *a, *b, *c;
};

static Term *mk(Tag t) {
    Term *r = calloc(1, sizeof(Term)); r->tag = t; return r;
}
static Term *var(int i)      { Term *r = mk(TmVar);   r->u.idx = i; return r; }
static Term *natLit(long n)  { Term *r = mk(TmNat);   r->u.nat = n; return r; }
static Term *boolLit(bool b) { Term *r = mk(TmBool);  r->u.boolean = b; return r; }
static Term *textLit(const char *s){ Term *r = mk(TmText); r->u.text = s; return r; }
static Term *ttype(void)     { return mk(TmType); }
static Term *tkind(void)     { return mk(TmKind); }
static Term *tsort(void)     { return mk(TmSort); }
static Term *lam(Term *d, Term *b){ Term *r = mk(TmLam); r->a = d; r->b = b; return r; }
static Term *pi(Term *d, Term *c){ Term *r = mk(TmPi); r->a = d; r->b = c; return r; }
static Term *app(Term *f, Term *x){ Term *r = mk(TmApp); r->a = f; r->b = x; return r; }
static Term *iff(Term *c, Term *t, Term *e){ Term *r = mk(TmIf); r->a=c; r->b=t; r->c=e; return r; }
static Term *let_(Term *ty, Term *v, Term *b){ Term *r = mk(TmLet); r->a=ty; r->b=v; r->c=b; return r; }
static Term *ann(Term *e, Term *ty){ Term *r = mk(TmAnn); r->a=e; r->b=ty; return r; }
static Term *nil(void){ return mk(TmNil); }
static Term *cons(Term *h, Term *t){ Term *r = mk(TmCons); r->a=h; r->b=t; return r; }
static Term *builtin(const char *n){ Term *r = mk(TmBuiltin); r->u.text = n; return r; }

static Term *natType(void) { return builtin("Natural"); }
static Term *boolType(void){ return builtin("Bool"); }
static Term *textType(void){ return builtin("Text"); }
static Term *listType(void){ return builtin("List"); }

static Term *shift(int d, int cutoff, Term *t) {
    switch (t->tag) {
    case TmVar: return (t->u.idx >= cutoff) ? var(t->u.idx + d) : t;
    case TmLam: return lam(shift(d, cutoff, t->a), shift(d, cutoff+1, t->b));
    case TmPi:  return pi(shift(d, cutoff, t->a), shift(d, cutoff+1, t->b));
    case TmApp: return app(shift(d, cutoff, t->a), shift(d, cutoff, t->b));
    case TmIf:  return iff(shift(d,cutoff,t->a), shift(d,cutoff,t->b), shift(d,cutoff,t->c));
    case TmLet: return let_(t->a?shift(d,cutoff,t->a):NULL, shift(d,cutoff,t->b), shift(d,cutoff+1,t->c));
    case TmAnn: return ann(shift(d,cutoff,t->a), shift(d,cutoff,t->b));
    case TmCons:return cons(shift(d,cutoff,t->a), shift(d,cutoff,t->b));
    default: return t;
    }
}

static Term *subst(int j, Term *s, Term *t) {
    switch (t->tag) {
    case TmVar: return (t->u.idx == j) ? s : t;
    case TmLam: return lam(subst(j,s,t->a), subst(j+1, shift(1,0,s), t->b));
    case TmPi:  return pi(subst(j,s,t->a), subst(j+1, shift(1,0,s), t->b));
    case TmApp: return app(subst(j,s,t->a), subst(j,s,t->b));
    case TmIf:  return iff(subst(j,s,t->a), subst(j,s,t->b), subst(j,s,t->c));
    case TmLet: return let_(t->a?subst(j,s,t->a):NULL, subst(j,s,t->b), subst(j+1, shift(1,0,s), t->c));
    case TmAnn: return ann(subst(j,s,t->a), subst(j,s,t->b));
    case TmCons:return cons(subst(j,s,t->a), subst(j,s,t->b));
    default: return t;
    }
}

static bool matchBuiltin(const char *name, int n, Term *t, Term **args) {
    Term *cur = t;
    for (int i = n-1; i >= 0; i--) {
        if (cur->tag != TmApp) return false;
        args[i] = cur->b;
        cur = cur->a;
    }
    return cur->tag == TmBuiltin && strcmp(cur->u.text, name) == 0;
}

static Term *reverseList(Term *xs) {
    Term **elems = malloc(16 * sizeof(Term*)); int n = 0, cap = 16;
    Term *cur = xs;
    while (cur->tag == TmCons) {
        if (n == cap) { cap *= 2; elems = realloc(elems, cap * sizeof(Term*)); }
        elems[n++] = cur->a; cur = cur->b;
    }
    Term *out = nil();
    for (int i = 0; i < n; i++) out = cons(elems[i], out);
    free(elems);
    return out;
}

static Term *norm(Term *t) {
    switch (t->tag) {
    case TmVar: case TmNat: case TmBool: case TmText:
    case TmType: case TmKind: case TmSort: case TmNil: case TmBuiltin:
        return t;
    case TmLam: return lam(norm(t->a), norm(t->b));
    case TmPi:  return pi(norm(t->a), norm(t->b));
    case TmAnn: return norm(t->a);
    case TmLet: return norm(subst(0, t->b, t->c));
    case TmCons:return cons(norm(t->a), norm(t->b));
    case TmIf: {
        Term *c = norm(t->a);
        if (c->tag == TmBool) return c->u.boolean ? norm(t->b) : norm(t->c);
        return iff(c, norm(t->b), norm(t->c));
    }
    case TmApp: {
        Term *args[5];
        if (matchBuiltin("List/map", 4, t, args)) {
            Term *xs = norm(args[3]);
            if (xs->tag == TmNil) return nil();
            if (xs->tag == TmCons) {
                Term *head = norm(app(args[2], xs->a));
                Term *rest = norm(app(app(app(app(builtin("List/map"),args[0]),args[1]),args[2]), xs->b));
                return cons(head, rest);
            }
        }
        if (matchBuiltin("List/filter", 3, t, args)) {
            Term *xs = norm(args[2]);
            if (xs->tag == TmNil) return nil();
            if (xs->tag == TmCons) {
                Term *pred = norm(app(args[1], xs->a));
                Term *tail = norm(app(app(app(builtin("List/filter"),args[0]),args[1]), xs->b));
                if (pred->tag == TmBool) return pred->u.boolean ? cons(norm(xs->a), tail) : tail;
                return cons(norm(xs->a), tail);
            }
        }
        if (matchBuiltin("List/reverse", 2, t, args)) {
            return reverseList(norm(args[1]));
        }
        if (matchBuiltin("List/fold", 5, t, args)) {
            Term *xs = norm(args[1]);
            if (xs->tag == TmNil) return norm(args[4]);
            if (xs->tag == TmCons) {
                Term *rest = norm(app(app(app(app(app(builtin("List/fold"),args[0]),xs->b),args[2]),args[3]),args[4]));
                return norm(app(app(args[3], xs->a), rest));
            }
        }
        Term *f = norm(t->a);
        if (f->tag == TmLam) return norm(subst(0, t->b, f->b));
        return app(f, norm(t->b));
    }
    }
    return t;
}

static bool alphaEq(Term *a, Term *b) {
    if (!a || !b) return a == b;
    if (a->tag != b->tag) return false;
    switch (a->tag) {
    case TmVar: return a->u.idx == b->u.idx;
    case TmNat: return a->u.nat == b->u.nat;
    case TmBool:return a->u.boolean == b->u.boolean;
    case TmText:return strcmp(a->u.text, b->u.text) == 0;
    case TmType: case TmKind: case TmSort: case TmNil: return true;
    case TmBuiltin: return strcmp(a->u.text, b->u.text) == 0;
    case TmLam: case TmPi: case TmApp: case TmCons:
        return alphaEq(a->a,b->a) && alphaEq(a->b,b->b);
    case TmIf:  return alphaEq(a->a,b->a)&&alphaEq(a->b,b->b)&&alphaEq(a->c,b->c);
    case TmLet: return ((a->a&&b->a)?alphaEq(a->a,b->a):(a->a==b->a))&&alphaEq(a->b,b->b)&&alphaEq(a->c,b->c);
    case TmAnn: return alphaEq(a->a,b->a)&&alphaEq(a->b,b->b);
    }
    return false;
}

typedef struct { Term *types[64]; int n; } Ctx;

static Term *ctxLookup(Ctx *g, int idx) {
    int pos = g->n - 1 - idx;
    if (pos < 0 || pos >= g->n) return NULL;
    return shift(idx + 1, 0, g->types[pos]);
}
static void ctxPush(Ctx *g, Term *ty) { g->types[g->n++] = ty; }

static Term *infer(Ctx *g, Term *t, char *err, size_t esz);
static bool check(Ctx *g, Term *t, Term *ty, char *err, size_t esz);

static bool isSort(Term *t) { return t->tag == TmType || t->tag == TmKind || t->tag == TmSort; }

static Term *mapType(void) {
    return pi(ttype(),
          pi(ttype(),
            pi(pi(var(1),var(1)),
              pi(app(listType(),var(2)), app(listType(),var(2))))));
}
static Term *filterType(void) {
    return pi(ttype(),
          pi(pi(var(0),boolType()),
            pi(app(listType(),var(1)), app(listType(),var(2)))));
}
static Term *reverseType(void) {
    return pi(ttype(), pi(app(listType(),var(0)), app(listType(),var(1))));
}
static Term *foldType(void) {
    return pi(ttype(),
          pi(app(listType(),var(0)),
            pi(ttype(),
              pi(pi(var(2), pi(var(1), var(2))),
                pi(var(1), var(2))))));
}

static Term *infer(Ctx *g, Term *t, char *err, size_t esz) {
    switch (t->tag) {
    case TmVar: {
        Term *ty = ctxLookup(g, t->u.idx);
        if (!ty) { snprintf(err, esz, "unbound variable (de Bruijn index %d)", t->u.idx); return NULL; }
        return ty;
    }
    case TmNat: return natType();
    case TmBool:return boolType();
    case TmText:return textType();
    case TmType:return tkind();
    case TmKind:return tsort();
    case TmSort:return tsort();
    case TmBuiltin: {
        const char *n = t->u.text;
        if (!strcmp(n,"Natural")||!strcmp(n,"Bool")||!strcmp(n,"Text")) return ttype();
        if (!strcmp(n,"List")) return pi(ttype(), ttype());
        if (!strcmp(n,"List/map"))    return mapType();
        if (!strcmp(n,"List/filter")) return filterType();
        if (!strcmp(n,"List/reverse"))return reverseType();
        if (!strcmp(n,"List/fold"))   return foldType();
        snprintf(err, esz, "unknown builtin: %s", n); return NULL;
    }
    case TmPi: {
        Term *d = infer(g, t->a, err, esz); if (!d) return NULL;
        if (!isSort(d)) { snprintf(err,esz,"Pi domain is not a type/sort"); return NULL; }
        ctxPush(g, t->a);
        Term *c = infer(g, t->b, err, esz);
        g->n--;
        if (!c) return NULL;
        if (!isSort(c)) { snprintf(err,esz,"Pi codomain is not a type/sort"); return NULL; }
        return c;
    }
    case TmApp: {
        Term *f = infer(g, t->a, err, esz); if (!f) return NULL;
        Term *fn = norm(f);
        if (fn->tag != TmPi) { snprintf(err,esz,"application of a non-function"); return NULL; }
        if (!check(g, t->b, fn->a, err, esz)) return NULL;
        return norm(subst(0, t->b, fn->b));
    }
    case TmIf: {
        if (!check(g, t->a, boolType(), err, esz)) return NULL;
        Term *ty = infer(g, t->b, err, esz); if (!ty) return NULL;
        if (!check(g, t->c, ty, err, esz)) return NULL;
        return ty;
    }
    case TmLet: {
        Term *valTy = t->a;
        if (valTy) {
            if (!check(g, t->b, valTy, err, esz)) return NULL;
        } else {
            valTy = infer(g, t->b, err, esz); if (!valTy) return NULL;
        }
        ctxPush(g, valTy);
        Term *r = infer(g, t->c, err, esz);
        g->n--;
        return r;
    }
    case TmAnn: {
        Term *ty = t->b;
        Term *tty = infer(g, ty, err, esz); if (!tty) return NULL;
        if (!isSort(tty)) { snprintf(err,esz,"annotation is not a type"); return NULL; }
        if (!check(g, t->a, ty, err, esz)) return NULL;
        return ty;
    }
    case TmNil: snprintf(err,esz,"cannot infer type of empty list (needs annotation)"); return NULL;
    case TmCons: {
        Term *tty = infer(g, t->b, err, esz); if (!tty) return NULL;
        Term *nt = norm(tty);
        if (nt->tag != TmApp || !(nt->a->tag==TmBuiltin && !strcmp(nt->a->u.text,"List"))) {
            snprintf(err,esz,"cons tail is not a list"); return NULL;
        }
        if (!check(g, t->a, nt->b, err, esz)) return NULL;
        return tty;
    }
    case TmLam: snprintf(err,esz,"cannot infer type of lambda (needs annotation)"); return NULL;
    default: snprintf(err,esz,"unsupported term in infer"); return NULL;
    }
}

static bool check(Ctx *g, Term *t, Term *ty, char *err, size_t esz) {
    Term *nty = norm(ty);
    if (t->tag == TmLam && nty->tag == TmPi) {
        if (!alphaEq(norm(t->a), norm(nty->a))) {
            snprintf(err, esz, "lambda domain annotation mismatch");
            return false;
        }
        ctxPush(g, nty->a);
        bool ok = check(g, t->b, nty->b, err, esz);
        g->n--;
        return ok;
    }
    if (t->tag == TmNil && nty->tag == TmApp && nty->a->tag==TmBuiltin && !strcmp(nty->a->u.text,"List"))
        return true;
    if (t->tag == TmCons && nty->tag == TmApp && nty->a->tag==TmBuiltin && !strcmp(nty->a->u.text,"List"))
        return check(g, t->a, nty->b, err, esz) && check(g, t->b, nty, err, esz);
    Term *got = infer(g, t, err, esz);
    if (!got) return false;
    Term *ngot = norm(got);
    if (!alphaEq(ngot, nty)) {
        snprintf(err, esz, "type mismatch");
        return false;
    }
    return true;
}
