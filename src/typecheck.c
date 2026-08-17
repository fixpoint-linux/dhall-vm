/* typecheck.c — bidirectional infer/check over Terms.
   Adopts the verified de Bruijn infer/check from ref/proto.c VERBATIM
   and extends it for records, unions, merge, text interpolation,
   Integer/Double, Optional/Some, arithmetic operators, assert, and toMap.
   Types are compared by alphaEq(norm(a), norm(b)); dependent Pi
   substitution for application. */
#include "dhall.h"

/* ---- context: growable stack of types, parallel names for diagnostics ---- */

typedef struct {
    Term **types;
    Term **vals;
    const char **names;
    int n, cap;
} Ctx;

static void ctx_init(Ctx *g) {
    g->cap = 64;
    g->n = 0;
    g->types = malloc(g->cap * sizeof(Term *));
    g->vals = malloc(g->cap * sizeof(Term *));
    g->names = malloc(g->cap * sizeof(char *));
}
static void ctx_push(Ctx *g, Term *ty, const char *name, Term *val) {
    if (g->n == g->cap) {
        g->cap *= 2;
        g->types = realloc(g->types, g->cap * sizeof(Term *));
        g->vals = realloc(g->vals, g->cap * sizeof(Term *));
        g->names = realloc(g->names, g->cap * sizeof(char *));
    }
    g->types[g->n] = ty;
    g->vals[g->n] = val;
    g->names[g->n] = name;
    g->n++;
}
static void ctx_pop(Ctx *g) { if (g->n > 0) g->n--; }
static Term *ctx_lookup(Ctx *g, int idx) {
    int pos = g->n - 1 - idx;
    if (pos < 0 || pos >= g->n) return NULL;
    return shift(idx + 1, 0, g->types[pos]);
}
static const char *ctx_name(Ctx *g, int idx) {
    int pos = g->n - 1 - idx;
    if (pos < 0 || pos >= g->n) return "?";
    return g->names[pos] ? g->names[pos] : "?";
}

static Term *infer(Ctx *g, Term *t, DhallError *err);
static bool check(Ctx *g, Term *t, Term *ty, DhallError *err);
static Term *resolve_type(Ctx *g, Term *ty, int depth);

static bool is_sort(Term *t) {
    return t->tag == TmType || t->tag == TmKind || t->tag == TmSort;
}

/* Is `t` (assumed normalized) usable in TYPE position — i.e. is it a sort
 * (Type/Kind/Sort) or the empty record type `{}`?  `{=}` parses as an empty
 * record LITERAL, whose inferred type is `{}` (TmRecordType, n==0); since the
 * empty record value and type coincide (alpha_eq treats TmRecordType and
 * TmRecordLit alike), `{=}` is a valid empty-record type marker in the schema
 * DSL.  A non-empty record type is already accepted (inferring a TmRecordType
 * yields Type, a sort); only the empty case needs this special case. */
static bool is_type_position(Term *t) {
    if (is_sort(t)) return true;
    return t->tag == TmRecordType && t->as.rec.n == 0;
}

static void err_here(DhallError *e, ErrorStage st, Term *t, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(e->msg, sizeof(e->msg), fmt, ap);
    va_end(ap);
    e->stage = st;
    e->span = t ? t->loc : SPAN_NONE;
    e->has_span = t && t->loc.line > 0;
}

/* fields must be sorted & unique by label; find index of label (binary) */
static int field_find(Field *fs, int n, const char *label) {
    int lo = 0, hi = n - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        int c = strcmp(fs[mid].label, label);
        if (c == 0) return mid;
        else if (c < 0) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

static bool fields_label_sets_equal(Field *a, int na, Field *b, int nb) {
    if (na != nb) return false;
    for (int i = 0; i < na; i++)
        if (strcmp(a[i].label, b[i].label) != 0) return false;
    return true;
}

static bool is_list_type(Term *t) {
    if (t->tag != TmApp) return false;
    return t->as.app.fn->tag == TmBuiltin && strcmp(t->as.app.fn->as.bname, "List") == 0;
}

static bool is_optional_type(Term *t) {
    if (t->tag != TmApp) return false;
    return t->as.app.fn->tag == TmBuiltin && strcmp(t->as.app.fn->as.bname, "Optional") == 0;
}

/* scalar-kind classification for binary operators; SC_NONE if not scalar */
enum { SC_NONE = -1, SC_NAT, SC_INT, SC_DBL, SC_BOOL, SC_TEXT };
static int scalar_kind(Term *ty) {
    if (ty->tag == TmBuiltin) {
        if (!strcmp(ty->as.bname, "Natural")) return SC_NAT;
        if (!strcmp(ty->as.bname, "Integer")) return SC_INT;
        if (!strcmp(ty->as.bname, "Double"))  return SC_DBL;
        if (!strcmp(ty->as.bname, "Bool"))    return SC_BOOL;
        if (!strcmp(ty->as.bname, "Text"))    return SC_TEXT;
    }
    return SC_NONE;
}

static Term *infer_binop(Ctx *g, Term *t, DhallError *err) {
    Term *lty = infer(g, t->as.op.lhs, err);
    if (!lty) return NULL;
    Term *rty = infer(g, t->as.op.rhs, err);
    if (!rty) return NULL;
    Term *nl = normalize(lty);
    Term *nr = normalize(rty);
    if (!alpha_eq(nl, nr)) {
        err_here(err, ERR_TYPE, t, "operands of different types");
        return NULL;
    }
    int k = scalar_kind(nl);
    OpKind op = t->as.op.op;
    if (op == OP_AND || op == OP_OR) {
        if (k != SC_BOOL) {
            err_here(err, ERR_TYPE, t, "logical operator requires Bool operands");
            return NULL;
        }
        return tm_builtin("Bool");
    }
    if (op == OP_ADD || op == OP_SUB || op == OP_MUL) {
        if (k != SC_NAT && k != SC_INT && k != SC_DBL) {
            err_here(err, ERR_TYPE, t, "arithmetic operator requires Natural/Integer/Double operands");
            return NULL;
        }
        return nl;
    }
    if (op == OP_LT || op == OP_LE || op == OP_GT || op == OP_GE) {
        if (k != SC_NAT && k != SC_INT && k != SC_DBL) {
            err_here(err, ERR_TYPE, t, "comparison operator requires Natural/Integer/Double operands");
            return NULL;
        }
        return tm_builtin("Bool");
    }
    /* OP_EQ / OP_NE */
    if (k != SC_BOOL && k != SC_NAT && k != SC_INT && k != SC_DBL && k != SC_TEXT) {
        err_here(err, ERR_TYPE, t, "equality operator does not support this type");
        return NULL;
    }
    return tm_builtin("Bool");
}

/* recursive merge of two record TYPES. A shared field must recursively be a
   record type, else this is a type error (the faithful Dhall rule — the
   right-biased OVERRIDE is the separate // operator, out of scope). */
static Term *merge_record_types(Term *l, Term *r, Term *loc, DhallError *err) {
    Field *lfs = l->as.rec.fs; int ln = l->as.rec.n;
    Field *rfs = r->as.rec.fs; int rn = r->as.rec.n;
    Field *out = arena_alloc(dhall_arena, (size_t)(ln + rn) * sizeof(Field));
    int n = 0, i = 0, j = 0;
    while (i < ln || j < rn) {
        int cmp;
        if (i >= ln) cmp = 1;
        else if (j >= rn) cmp = -1;
        else cmp = strcmp(lfs[i].label, rfs[j].label);
        if (cmp < 0) { out[n++] = lfs[i++]; }
        else if (cmp > 0) { out[n++] = rfs[j++]; }
        else {
            Term *lt = normalize(lfs[i].type);
            Term *rt = normalize(rfs[j].type);
            if (lt->tag == TmRecordType && rt->tag == TmRecordType) {
                out[n].label = lfs[i].label;
                out[n].type = merge_record_types(lt, rt, loc, err);
                out[n].value = NULL;
                if (!out[n].type) return NULL;
            } else {
                err_here(err, ERR_TYPE, loc, "shared field '%s' is not a record type", lfs[i].label);
                return NULL;
            }
            n++; i++; j++;
        }
    }
    return tm_record_type(out, n);
}

/* right-biased (non-recursive) merge of two record TYPES for the // operator:
   a shared label takes the right-hand type, with no recursion and no error. */
static Term *prefer_record_types(Term *l, Term *r) {
    Field *lfs = l->as.rec.fs; int ln = l->as.rec.n;
    Field *rfs = r->as.rec.fs; int rn = r->as.rec.n;
    Field *out = arena_alloc(dhall_arena, (size_t)(ln + rn) * sizeof(Field));
    int n = 0, i = 0, j = 0;
    while (i < ln || j < rn) {
        int cmp;
        if (i >= ln) cmp = 1;
        else if (j >= rn) cmp = -1;
        else cmp = strcmp(lfs[i].label, rfs[j].label);
        if (cmp < 0) { out[n++] = lfs[i++]; }
        else if (cmp > 0) { out[n++] = rfs[j++]; }
        else { out[n++] = rfs[j++]; i++; }
    }
    return tm_record_type(out, n);
}

/* insert field k : vty into a record TYPE, keeping labels sorted */
static Term *insert_field_type(Term *rty, const char *k, Term *vty) {
    Field *fs = arena_alloc(dhall_arena, (size_t)(rty->as.rec.n + 1) * sizeof(Field));
    int out = 0;
    bool inserted = false;
    for (int j = 0; j < rty->as.rec.n; j++) {
        if (!inserted && strcmp(rty->as.rec.fs[j].label, k) > 0) {
            fs[out].label = arena_strdup(dhall_arena, k);
            fs[out].type = vty;
            fs[out].value = NULL;
            out++;
            inserted = true;
        }
        fs[out++] = rty->as.rec.fs[j];
    }
    if (!inserted) {
        fs[out].label = arena_strdup(dhall_arena, k);
        fs[out].type = vty;
        fs[out].value = NULL;
        out++;
    }
    return tm_record_type(fs, out);
}

/* mirror of normalize's with_update_lit, but over record TYPES: compute the
   type of `rec with path = v` given rec's type rty and v's type vty. */
static Term *with_type_at(Term *rty, char **path, int n, Term *vty, Term *loc, DhallError *err) {
    if (n == 0) return vty;
    const char *k = path[0];
    int i = field_find(rty->as.rec.fs, rty->as.rec.n, k);
    if (i >= 0) {
        if (n == 1) {
            Field *fs = arena_alloc(dhall_arena, (size_t)rty->as.rec.n * sizeof(Field));
            memcpy(fs, rty->as.rec.fs, (size_t)rty->as.rec.n * sizeof(Field));
            fs[i].type = vty;
            return tm_record_type(fs, rty->as.rec.n);
        }
        Term *ft = normalize(rty->as.rec.fs[i].type);
        if (ft->tag != TmRecordType) {
            err_here(err, ERR_TYPE, loc, "cannot descend into non-record field '%s'", k);
            return NULL;
        }
        Term *sub = with_type_at(ft, path + 1, n - 1, vty, loc, err);
        if (!sub) return NULL;
        Field *fs = arena_alloc(dhall_arena, (size_t)rty->as.rec.n * sizeof(Field));
        memcpy(fs, rty->as.rec.fs, (size_t)rty->as.rec.n * sizeof(Field));
        fs[i].type = sub;
        return tm_record_type(fs, rty->as.rec.n);
    }
    if (n == 1) return insert_field_type(rty, k, vty);
    Term *sub = with_type_at(tm_record_type(NULL, 0), path + 1, n - 1, vty, loc, err);
    if (!sub) return NULL;
    return insert_field_type(rty, k, sub);
}

static Term *infer(Ctx *g, Term *t, DhallError *err) {
    switch (t->tag) {
    case TmVar: {
        Term *ty = ctx_lookup(g, t->as.idx);
        if (!ty) {
            err_here(err, ERR_TYPE, t, "unbound variable '%s'", ctx_name(g, t->as.idx));
            return NULL;
        }
        return resolve_type(g, ty, 0);
    }
    case TmConst:
        switch (t->as.c.kind) {
        case C_NAT: return tm_builtin("Natural");
        case C_INT: return tm_builtin("Integer");
        case C_DBL: return tm_builtin("Double");
        case C_BOOL: return tm_builtin("Bool");
        }
        return NULL;
    case TmText: {
        /* check interpolation subterms are Text */
        for (TextPart *p = t->as.text; p; p = p->next)
            if (p->expr && !check(g, p->expr, tm_builtin("Text"), err)) {
                err_here(err, ERR_TYPE, p->expr, "interpolation requires Text");
                return NULL;
            }
        return tm_builtin("Text");
    }
    case TmType: return tm_kind();
    case TmKind: return tm_sort();
    case TmSort: return tm_sort();
    case TmBuiltin: {
        const char *n = t->as.bname;
        Term *schema = builtin_type_schema(n);
        if (!schema) {
            err_here(err, ERR_TYPE, t, "unknown builtin: %s", n);
            return NULL;
        }
        return schema;
    }
    case TmPi: {
        Term *d = infer(g, t->as.pi.dom, err);
        if (!d) return NULL;
        if (!is_type_position(normalize(d))) { err_here(err, ERR_TYPE, t, "Pi domain is not a type/sort"); return NULL; }
        ctx_push(g, t->as.pi.dom, "_", NULL);
        Term *c = infer(g, t->as.pi.cod, err);
        ctx_pop(g);
        if (!c) return NULL;
        if (!is_type_position(normalize(c))) { err_here(err, ERR_TYPE, t, "Pi codomain is not a type/sort"); return NULL; }
        return c;
    }
    case TmApp: {
        Term *f = infer(g, t->as.app.fn, err);
        if (!f) return NULL;
        Term *fn = normalize(f);
        if (fn->tag != TmPi) { err_here(err, ERR_TYPE, t, "application of a non-function"); return NULL; }
        if (!check(g, t->as.app.arg, fn->as.pi.dom, err)) return NULL;
        return normalize(subst(0, t->as.app.arg, fn->as.pi.cod));
    }
    case TmIf: {
        if (!check(g, t->as.if_.c, tm_builtin("Bool"), err)) return NULL;
        Term *ty = infer(g, t->as.if_.t, err);
        if (!ty) return NULL;
        if (!check(g, t->as.if_.e, ty, err)) return NULL;
        return ty;
    }
    case TmLet: {
        Term *valTy = t->as.let_.ann;
        if (valTy) {
            if (!check(g, t->as.let_.val, valTy, err)) return NULL;
        } else {
            valTy = infer(g, t->as.let_.val, err);
            if (!valTy) return NULL;
        }
        ctx_push(g, valTy, "x", t->as.let_.val);
        Term *r = infer(g, t->as.let_.body, err);
        ctx_pop(g);
        return r;
    }
    case TmAnn: {
        Term *tty = infer(g, t->as.ann.ty, err);
        if (!tty) return NULL;
        if (!is_type_position(normalize(tty))) { err_here(err, ERR_TYPE, t, "annotation is not a type"); return NULL; }
        if (!check(g, t->as.ann.e, t->as.ann.ty, err)) return NULL;
        return resolve_type(g, t->as.ann.ty, 0);
    }
    case TmLam: {
        /* only inferable when a domain annotation is present */
        if (!t->as.lam.dom) { err_here(err, ERR_TYPE, t, "cannot infer type of lambda (needs annotation)"); return NULL; }
        ctx_push(g, t->as.lam.dom, "_", NULL);
        Term *cod = infer(g, t->as.lam.body, err);
        ctx_pop(g);
        if (!cod) return NULL;
        return tm_pi(t->as.lam.dom, cod);
    }
    case TmNil:
        err_here(err, ERR_TYPE, t, "cannot infer type of empty list (needs annotation)");
        return NULL;
    case TmCons: {
        /* infer the element type from the head, then propagate List headTy
           down the tail (bidirectional list typing; [] cannot infer on its own) */
        Term *hty = infer(g, t->as.cons.head, err);
        if (!hty) return NULL;
        Term *listTy = tm_app(tm_builtin("List"), hty);
        if (!check(g, t->as.cons.tail, listTy, err)) return NULL;
        return listTy;
    }
    case TmTextAppend: {
        if (!check(g, t->as.append.a, tm_builtin("Text"), err)) return NULL;
        if (!check(g, t->as.append.b, tm_builtin("Text"), err)) return NULL;
        return tm_builtin("Text");
    }
    case TmRecordType: {
        for (int i = 0; i < t->as.rec.n; i++) {
            if (!t->as.rec.fs[i].type) continue;
            Term *ty = infer(g, t->as.rec.fs[i].type, err);
            if (!ty) return NULL;
            if (!is_type_position(normalize(ty))) { err_here(err, ERR_TYPE, t, "record field type is not a type"); return NULL; }
        }
        return tm_type();
    }
    case TmRecordLit: {
        Field *fs = arena_alloc(dhall_arena, t->as.rec.n * sizeof(Field));
        for (int i = 0; i < t->as.rec.n; i++) {
            Term *vty = infer(g, t->as.rec.fs[i].value, err);
            if (!vty) return NULL;
            fs[i].label = t->as.rec.fs[i].label;
            fs[i].type = vty;
            fs[i].value = NULL;
        }
        return tm_record_type(fs, t->as.rec.n);
    }
    case TmField: {
        Term *rty = infer(g, t->as.field.rec, err);
        if (!rty) return NULL;
        Term *nt = normalize(rty);
        if (nt->tag != TmRecordType) { err_here(err, ERR_TYPE, t, "field access on a non-record"); return NULL; }
        int i = field_find(nt->as.rec.fs, nt->as.rec.n, t->as.field.label);
        if (i < 0 || !nt->as.rec.fs[i].type) { err_here(err, ERR_TYPE, t, "no such field: %s", t->as.field.label); return NULL; }
        return nt->as.rec.fs[i].type;
    }
    case TmUnionType: {
        for (int i = 0; i < t->as.uni.n; i++) {
            if (!t->as.uni.fs[i].type) continue;
            Term *ty = infer(g, t->as.uni.fs[i].type, err);
            if (!ty) return NULL;
            if (!is_type_position(normalize(ty))) { err_here(err, ERR_TYPE, t, "union alternative type is not a type"); return NULL; }
        }
        return tm_type();
    }
    case TmUnionLit: {
        Field *fs = arena_alloc(dhall_arena, t->as.uni.n * sizeof(Field));
        for (int i = 0; i < t->as.uni.n; i++) {
            fs[i].label = t->as.uni.fs[i].label;
            fs[i].type = NULL;
            fs[i].value = NULL;
            if (t->as.uni.fs[i].value) {
                Term *vty = infer(g, t->as.uni.fs[i].value, err);
                if (!vty) return NULL;
                fs[i].type = vty;
            } else if (t->as.uni.fs[i].type) {
                fs[i].type = t->as.uni.fs[i].type;
            } else {
                err_here(err, ERR_TYPE, t, "union literal alternative has no type"); return NULL;
            }
        }
        return tm_union_type(fs, t->as.uni.n);
    }
    case TmMerge: {
        Term *uty = infer(g, t->as.merge.u, err);
        if (!uty) return NULL;
        Term *nut = normalize(uty);
        if (nut->tag != TmUnionType) { err_here(err, ERR_TYPE, t, "merge second argument is not a union"); return NULL; }

        Term *hty = infer(g, t->as.merge.handlers, err);
        if (!hty) return NULL;
        Term *nht = normalize(hty);
        if (nht->tag != TmRecordType) { err_here(err, ERR_TYPE, t, "merge handlers are not a record"); return NULL; }

        if (!fields_label_sets_equal(nut->as.uni.fs, nut->as.uni.n, nht->as.rec.fs, nht->as.rec.n)) {
            err_here(err, ERR_TYPE, t, "merge handler and union labels do not match");
            return NULL;
        }

        Term *result = NULL;
        for (int i = 0; i < nut->as.uni.n; i++) {
            const char *label = nut->as.uni.fs[i].label;
            Term *altTy = nut->as.uni.fs[i].type;
            Term *hTy = normalize(nht->as.rec.fs[i].type);
            if (hTy->tag != TmPi) { err_here(err, ERR_TYPE, t, "merge handler '%s' is not a function", label); return NULL; }
            if (!alpha_eq(normalize(hTy->as.pi.dom), normalize(altTy))) {
                err_here(err, ERR_TYPE, t, "merge handler '%s' domain does not match alternative type", label);
                return NULL;
            }
            Term *cod = normalize(hTy->as.pi.cod);
            if (!result) {
                result = cod;
            } else if (!alpha_eq(result, cod)) {
                err_here(err, ERR_TYPE, t, "merge handlers do not have a common result type (handler '%s')", label);
                return NULL;
            }
        }
        if (!result) { err_here(err, ERR_TYPE, t, "merge of an empty union"); return NULL; }
        return result;
    }
    case TmSome: {
        Term *vty = infer(g, t->as.some.val, err);
        if (!vty) return NULL;
        return tm_app(tm_builtin("Optional"), vty);
    }
    case TmNone: {
        Term *tty = infer(g, t->as.none.ty, err);
        if (!tty) return NULL;
        if (!is_type_position(normalize(tty))) { err_here(err, ERR_TYPE, t, "None type argument is not a Type"); return NULL; }
        return tm_app(tm_builtin("Optional"), t->as.none.ty);
    }
    case TmOp:
        return infer_binop(g, t, err);
    case TmAssert: {
        Term *bty = infer(g, t->as.assert_.body, err);
        if (!bty) return NULL;
        if (!alpha_eq(normalize(bty), normalize(tm_builtin("Bool")))) {
            err_here(err, ERR_TYPE, t, "assert is not a Bool");
            return NULL;
        }
        Term *b = normalize(t->as.assert_.body);
        if (!(b->tag == TmConst && b->as.c.kind == C_BOOL && b->as.c.b)) {
            err_here(err, ERR_TYPE, t, "assertion did not hold");
            return NULL;
        }
        return tm_builtin("Bool");
    }
    case TmToMap: {
        Term *rty = infer(g, t->as.tomap.rec, err);
        if (!rty) return NULL;
        Term *nrt = normalize(rty);
        if (nrt->tag != TmRecordType) { err_here(err, ERR_TYPE, t, "toMap argument is not a record"); return NULL; }
        int n = nrt->as.rec.n;
        if (n == 0) { err_here(err, ERR_TYPE, t, "toMap of an empty record"); return NULL; }
        Term *T0 = normalize(nrt->as.rec.fs[0].type);
        for (int i = 1; i < n; i++) {
            if (!alpha_eq(T0, normalize(nrt->as.rec.fs[i].type))) {
                err_here(err, ERR_TYPE, t, "toMap requires all record fields to have the same type");
                return NULL;
            }
        }
        Field *fs = arena_alloc(dhall_arena, 2 * sizeof(Field));
        fs[0].label = arena_strdup(dhall_arena, "mapKey");
        fs[0].type = tm_builtin("Text");
        fs[0].value = NULL;
        fs[1].label = arena_strdup(dhall_arena, "mapValue");
        fs[1].type = T0;
        fs[1].value = NULL;
        Term *recTy = tm_record_type(fs, 2);
        return tm_app(tm_builtin("List"), recTy);
    }
    case TmCombine: {
        Term *nl = normalize(t->as.combine.lhs);
        Term *nr = normalize(t->as.combine.rhs);
        if (nl->tag == TmRecordType && nr->tag == TmRecordType) {
            /* type-level merge: both operands are record types */
            if (!merge_record_types(nl, nr, t, err)) return NULL;
            return tm_type();
        }
        Term *lty = infer(g, t->as.combine.lhs, err);
        if (!lty) return NULL;
        Term *rty = infer(g, t->as.combine.rhs, err);
        if (!rty) return NULL;
        Term *nlt = normalize(lty);
        Term *nrt = normalize(rty);
        if (nlt->tag != TmRecordType || nrt->tag != TmRecordType) {
            err_here(err, ERR_TYPE, t, "record merge operand is not a record");
            return NULL;
        }
        return merge_record_types(nlt, nrt, t, err);
    }
    case TmListAppend: {
        Term *aty = infer(g, t->as.lappend.a, err);
        if (!aty) return NULL;
        Term *bty = infer(g, t->as.lappend.b, err);
        if (!bty) return NULL;
        Term *nat = normalize(aty);
        Term *nbt = normalize(bty);
        if (!is_list_type(nat) || !is_list_type(nbt)) {
            err_here(err, ERR_TYPE, t, "list append operand is not a List");
            return NULL;
        }
        if (!alpha_eq(normalize(nat->as.app.arg), normalize(nbt->as.app.arg))) {
            err_here(err, ERR_TYPE, t, "list append operands have different element types");
            return NULL;
        }
        return nat;
    }
    case TmPrefer: {
        Term *nl = normalize(t->as.prefer.lhs);
        Term *nr = normalize(t->as.prefer.rhs);
        if (nl->tag == TmRecordType && nr->tag == TmRecordType) {
            /* type-level prefer: both operands are record types */
            prefer_record_types(nl, nr); /* never errors; result discarded */
            return tm_type();
        }
        Term *lty = infer(g, t->as.prefer.lhs, err);
        if (!lty) return NULL;
        Term *rty = infer(g, t->as.prefer.rhs, err);
        if (!rty) return NULL;
        Term *nlt = normalize(lty);
        Term *nrt = normalize(rty);
        if (nlt->tag != TmRecordType || nrt->tag != TmRecordType) {
            err_here(err, ERR_TYPE, t, "record prefer operand is not a record");
            return NULL;
        }
        return prefer_record_types(nlt, nrt);
    }
    case TmWith: {
        Term *rty = infer(g, t->as.with_.rec, err);
        if (!rty) return NULL;
        Term *nr = normalize(rty);
        if (nr->tag != TmRecordType) {
            err_here(err, ERR_TYPE, t, "with target is not a record");
            return NULL;
        }
        Term *vty = infer(g, t->as.with_.value, err);
        if (!vty) return NULL;
        return with_type_at(nr, t->as.with_.path, t->as.with_.npath, vty, t, err);
    }
    default:
        err_here(err, ERR_TYPE, t, "unsupported term in infer");
        return NULL;
    }
}

static Term *resolve_type(Ctx *g, Term *ty, int depth) {
    switch (ty->tag) {
    case TmVar: {
        int idx = ty->as.idx;
        if (idx >= depth) {
            int pos = g->n - 1 - (idx - depth);
            if (pos >= 0 && pos < g->n && g->vals[pos])
                return resolve_type(g, shift(idx - depth + 1, 0, g->vals[pos]), 0);
        }
        return ty;
    }
    case TmLam:
        return tm_lam(resolve_type(g, ty->as.lam.dom, depth), resolve_type(g, ty->as.lam.body, depth + 1));
    case TmPi:
        return tm_pi(resolve_type(g, ty->as.pi.dom, depth), resolve_type(g, ty->as.pi.cod, depth + 1));
    case TmApp:
        return tm_app(resolve_type(g, ty->as.app.fn, depth), resolve_type(g, ty->as.app.arg, depth));
    case TmRecordType: {
        Field *fs = arena_alloc(dhall_arena, ty->as.rec.n * sizeof(Field));
        for (int i = 0; i < ty->as.rec.n; i++) {
            fs[i].label = ty->as.rec.fs[i].label;
            fs[i].type = ty->as.rec.fs[i].type ? resolve_type(g, ty->as.rec.fs[i].type, depth) : NULL;
            fs[i].value = NULL;
        }
        return tm_record_type(fs, ty->as.rec.n);
    }
    case TmUnionType: {
        Field *fs = arena_alloc(dhall_arena, ty->as.uni.n * sizeof(Field));
        for (int i = 0; i < ty->as.uni.n; i++) {
            fs[i].label = ty->as.uni.fs[i].label;
            fs[i].type = ty->as.uni.fs[i].type ? resolve_type(g, ty->as.uni.fs[i].type, depth) : NULL;
            fs[i].value = NULL;
        }
        return tm_union_type(fs, ty->as.uni.n);
    }
    default:
        return ty;
    }
}

static bool check(Ctx *g, Term *t, Term *ty, DhallError *err) {
    Term *nty = normalize(resolve_type(g, ty, 0));
    if (t->tag == TmLam && nty->tag == TmPi) {
        if (!alpha_eq(normalize(resolve_type(g, t->as.lam.dom, 0)), normalize(nty->as.pi.dom))) {
            err_here(err, ERR_TYPE, t, "lambda domain annotation mismatch");
            return false;
        }
        ctx_push(g, nty->as.pi.dom, "_", NULL);
        bool ok = check(g, t->as.lam.body, nty->as.pi.cod, err);
        ctx_pop(g);
        return ok;
    }
    if (t->tag == TmNil && nty->tag == TmApp && is_list_type(nty))
        return true;
    if (t->tag == TmCons && is_list_type(nty))
        return check(g, t->as.cons.head, nty->as.app.arg, err) && check(g, t->as.cons.tail, nty, err);
    if (t->tag == TmSome && is_optional_type(nty))
        return check(g, t->as.some.val, nty->as.app.arg, err);
    if (t->tag == TmNone && is_optional_type(nty)) {
        if (!alpha_eq(normalize(resolve_type(g, t->as.none.ty, 0)), normalize(nty->as.app.arg))) {
            err_here(err, ERR_TYPE, t, "None type argument mismatch");
            return false;
        }
        Term *tty = infer(g, t->as.none.ty, err);
        if (!tty) return false;
        if (!is_type_position(normalize(tty))) { err_here(err, ERR_TYPE, t, "None type argument is not a Type"); return false; }
        return true;
    }
    if (t->tag == TmRecordLit && nty->tag == TmRecordType) {
        if (!fields_label_sets_equal(t->as.rec.fs, t->as.rec.n, nty->as.rec.fs, nty->as.rec.n)) {
            err_here(err, ERR_TYPE, t, "record literal labels do not match record type");
            return false;
        }
        for (int i = 0; i < t->as.rec.n; i++)
            if (!check(g, t->as.rec.fs[i].value, nty->as.rec.fs[i].type, err))
                return false;
        return true;
    }
    if (t->tag == TmUnionLit && nty->tag == TmUnionType) {
        for (int i = 0; i < t->as.uni.n; i++) {
            const char *label = t->as.uni.fs[i].label;
            int j = -1;
            for (int k = 0; k < nty->as.uni.n; k++)
                if (!strcmp(nty->as.uni.fs[k].label, label)) { j = k; break; }
            if (j < 0) {
                err_here(err, ERR_TYPE, t, "union literal alternative '%s' is not in the union type", label);
                return false;
            }
            Term *declTy = nty->as.uni.fs[j].type;
            Term *val = t->as.uni.fs[i].value;
            if (val) {
                if (!declTy) {
                    err_here(err, ERR_TYPE, t, "union alternative '%s' carries no value (no declared type)", label);
                    return false;
                }
                if (!check(g, val, declTy, err)) return false;
            }
        }
        return true;
    }
    if (t->tag == TmText && nty->tag == TmBuiltin && !strcmp(nty->as.bname, "Text")) {
        for (TextPart *p = t->as.text; p; p = p->next)
            if (p->expr && !check(g, p->expr, tm_builtin("Text"), err)) {
                err_here(err, ERR_TYPE, p->expr, "interpolation requires Text");
                return false;
            }
        return true;
    }
    if (t->tag == TmToMap) {
        /* toMap of an EMPTY record: the element type V is unknowable under
           infer (no fields to read it from), so take V from the annotation.
           Succeeds iff the record normalizes to an empty record literal AND
           the target is List { mapKey : Text, mapValue : V } for some V.
           Any other case falls through to infer (non-empty records, or a
           mismatched/malformed target). */
        Term *nr = normalize(t->as.tomap.rec);
        if (nr->tag == TmRecordLit && nr->as.rec.n == 0 && is_list_type(nty)) {
            Term *elem = normalize(nty->as.app.arg);
            if (elem->tag == TmRecordType && elem->as.rec.n == 2 &&
                elem->as.rec.fs[0].type && elem->as.rec.fs[1].type &&
                !strcmp(elem->as.rec.fs[0].label, "mapKey") &&
                !strcmp(elem->as.rec.fs[1].label, "mapValue") &&
                alpha_eq(normalize(elem->as.rec.fs[0].type), normalize(tm_builtin("Text"))))
                return true;
        }
    }
    Term *got = infer(g, t, err);
    if (!got) return false;
    Term *ngot = normalize(got);
    if (!alpha_eq(ngot, nty)) {
        err_here(err, ERR_TYPE, t, "type mismatch");
        return false;
    }
    return true;
}

Term *infer_type(Parser *p, Term *t, DhallError *err) {
    (void)p;
    normalize_clear_error();
    Ctx g;
    ctx_init(&g);
    Term *r = infer(&g, t, err);
    free(g.types);
    free(g.vals);
    free(g.names);
    if (normalize_has_error()) {
        *err = *normalize_get_error();
        return NULL;
    }
    return r;
}
