/* normalize.c — eager (call-by-value) strong normalization.
   Adopts the verified de Bruijn normalizer from ref/proto.c VERBATIM
   (beta, let, if, builtin delta rules) and extends it for records,
   unions, merge, field access, text interpolation, text append, and
   Optional/Some, arithmetic operators, assert, and toMap. */
#include "dhall.h"

#define MAX_NAT_FOLD (1u << 20)   /* Natural/fold iteration cap (DoS guard) */

/* ---- overflow/error channel (normalize has no out-param) ---- */

static DhallError g_norm_err;
static bool g_norm_err_set = false;

void normalize_clear_error(void) {
    dhall_error_clear(&g_norm_err);
    g_norm_err_set = false;
}
bool normalize_has_error(void) { return g_norm_err_set; }
DhallError *normalize_get_error(void) { return &g_norm_err; }
static void norm_set_error(SourceSpan sp, const char *msg) {
    if (g_norm_err_set) return;   /* first error wins */
    g_norm_err.stage = ERR_TYPE;
    g_norm_err.span = sp;
    g_norm_err.has_span = (sp.line > 0);
    snprintf(g_norm_err.msg, sizeof(g_norm_err.msg), "%s", msg);
    g_norm_err_set = true;
}

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

/* true if the normalized value is a closed WHNF that is definitively NOT Text.
   Used to reject non-Text interpolation in normalize/serializer modes (which have
   no type information). Stuck/unknown-type terms (TmVar, TmApp, TmField, ...)
   are left to the existing behavior (silently dropped), matching well-typed
   semantics where bound-Text interpolations may remain stuck. */
static bool is_closed_nontext_value(Term *e) {
    switch (e->tag) {
    case TmConst:
    case TmType:
    case TmKind:
    case TmSort:
    case TmNil:
    case TmCons:
    case TmRecordLit:
    case TmRecordType:
    case TmUnionLit:
    case TmUnionType:
    case TmBuiltin:
    case TmLam:
    case TmPi:
    case TmSome:
    case TmNone:
        return true;
    default:
        return false;
    }
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
            else if (is_closed_nontext_value(e))
                norm_set_error(p->expr->loc, "interpolation requires Text");
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

/* ---- toMap normalization: build a cons-list of {mapKey,mapValue} records
   in (already-sorted) label order ---- */
static Term *norm_tomap(Term *t) {
    Term *r = normalize(t->as.tomap.rec);
    if (r->tag != TmRecordLit) return tm_tomap(r); /* stuck */
    Term *out = tm_nil();
    /* labels are sorted; build the list in reverse then reverse */
    for (int i = 0; i < r->as.rec.n; i++) {
        Field *fs = arena_alloc(dhall_arena, 2 * sizeof(Field));
        fs[0].label = arena_strdup(dhall_arena, "mapKey");
        fs[0].type = NULL;
        fs[0].value = tm_text_lit(r->as.rec.fs[i].label);
        fs[1].label = arena_strdup(dhall_arena, "mapValue");
        fs[1].type = NULL;
        fs[1].value = normalize(r->as.rec.fs[i].value);
        Term *item = tm_record_lit(fs, 2);
        out = tm_cons(item, out);
    }
    return reverse_list(out);
}

/* ---- arithmetic/comparison delta (constant operands) ---- */

static Term *norm_op(Term *t) {
    Term *l = normalize(t->as.op.lhs);
    Term *r = normalize(t->as.op.rhs);
    OpKind op = t->as.op.op;
    SourceSpan loc = t->loc;

    if (l->tag == TmConst && r->tag == TmConst && l->as.c.kind == r->as.c.kind) {
        ConstKind k = l->as.c.kind;
        if (op == OP_ADD || op == OP_SUB || op == OP_MUL) {
            switch (k) {
            case C_NAT: {
                uint64_t a = l->as.c.nat, b = r->as.c.nat;
                if (op == OP_ADD) {
                    if (a > UINT64_MAX - b) { norm_set_error(loc, "arithmetic overflow"); return tm_op(op, l, r); }
                    return tm_nat(a + b);
                }
                if (op == OP_SUB) return tm_nat(a < b ? 0 : a - b);
                if (b != 0 && a > UINT64_MAX / b) { norm_set_error(loc, "arithmetic overflow"); return tm_op(op, l, r); }
                return tm_nat(a * b);
            }
            case C_INT: {
                int64_t a = l->as.c.i64, b = r->as.c.i64, res;
                bool ov = false;
                if (op == OP_ADD) ov = __builtin_add_overflow(a, b, &res);
                else if (op == OP_SUB) ov = __builtin_sub_overflow(a, b, &res);
                else ov = __builtin_mul_overflow(a, b, &res);
                if (ov) { norm_set_error(loc, "arithmetic overflow"); return tm_op(op, l, r); }
                return tm_int(res);
            }
            case C_DBL: {
                double a = l->as.c.dbl, b = r->as.c.dbl;
                if (op == OP_ADD) return tm_dbl(a + b);
                if (op == OP_SUB) return tm_dbl(a - b);
                return tm_dbl(a * b);
            }
            default: break; /* Bool arithmetic is ill-typed */
            }
        } else {
            /* comparisons */
            bool lt = false, le = false, gt = false, ge = false, eq = false;
            switch (k) {
            case C_NAT:
                lt = l->as.c.nat < r->as.c.nat; le = l->as.c.nat <= r->as.c.nat;
                gt = l->as.c.nat > r->as.c.nat; ge = l->as.c.nat >= r->as.c.nat;
                eq = l->as.c.nat == r->as.c.nat; break;
            case C_INT:
                lt = l->as.c.i64 < r->as.c.i64; le = l->as.c.i64 <= r->as.c.i64;
                gt = l->as.c.i64 > r->as.c.i64; ge = l->as.c.i64 >= r->as.c.i64;
                eq = l->as.c.i64 == r->as.c.i64; break;
            case C_DBL:
                lt = l->as.c.dbl < r->as.c.dbl; le = l->as.c.dbl <= r->as.c.dbl;
                gt = l->as.c.dbl > r->as.c.dbl; ge = l->as.c.dbl >= r->as.c.dbl;
                eq = l->as.c.dbl == r->as.c.dbl; break;
            case C_BOOL:
                eq = l->as.c.b == r->as.c.b; break;
            }
            switch (op) {
            case OP_LT: return tm_bool(lt);
            case OP_LE: return tm_bool(le);
            case OP_GT: return tm_bool(gt);
            case OP_GE: return tm_bool(ge);
            case OP_EQ: return tm_bool(eq);
            case OP_NE: return tm_bool(!eq);
            default: break;
            }
        }
    }
    /* text equality */
    if ((op == OP_EQ || op == OP_NE) && l->tag == TmText && r->tag == TmText
        && !text_has_interp(l) && !text_has_interp(r)) {
        bool eq = strcmp(l->as.text->lit, r->as.text->lit) == 0;
        return tm_bool(op == OP_EQ ? eq : !eq);
    }
    return tm_op(op, l, r); /* stuck */
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
        if (match_builtin("Optional/fold", 5, t, args)) {
            /* args: [0]=T, [1]=value, [2]=A, [3]=some (T->A), [4]=none (A) */
            Term *v = normalize(args[1]);
            if (v->tag == TmSome) return normalize(tm_app(args[3], v->as.some.val));
            if (v->tag == TmNone) return normalize(args[4]);
        }
        if (match_builtin("Natural/fold", 4, t, args)) {
            /* args: [0]=n, [1]=A, [2]=step (A->A), [3]=base (A) */
            Term *n = normalize(args[0]);
            if (n->tag == TmConst && n->as.c.kind == C_NAT) {
                uint64_t count = n->as.c.nat;
                if (count > MAX_NAT_FOLD) {
                    norm_set_error(t->loc, "Natural/fold limit exceeded");
                    return t; /* stuck */
                }
                Term *acc = normalize(args[3]);
                for (uint64_t i = 0; i < count; i++)
                    acc = normalize(tm_app(args[2], acc));
                return acc;
            }
        }
        if (match_builtin("Natural/isZero", 1, t, args)) {
            Term *n = normalize(args[0]);
            if (n->tag == TmConst && n->as.c.kind == C_NAT)
                return tm_bool(n->as.c.nat == 0);
        }
        if (match_builtin("Natural/show", 1, t, args)) {
            Term *n = normalize(args[0]);
            if (n->tag == TmConst && n->as.c.kind == C_NAT) {
                char buf[32];
                snprintf(buf, sizeof(buf), "%llu", (unsigned long long)n->as.c.nat);
                return tm_text_lit(buf);
            }
        }
        if (match_builtin("Natural/subtract", 2, t, args)) {
            /* Natural/subtract : Natural -> Natural -> Natural = max(b - a, 0)
               (arg order opposite the `-` operator) */
            Term *a = normalize(args[0]);
            Term *b = normalize(args[1]);
            if (a->tag == TmConst && a->as.c.kind == C_NAT &&
                b->tag == TmConst && b->as.c.kind == C_NAT)
                return tm_nat(b->as.c.nat < a->as.c.nat ? 0 : b->as.c.nat - a->as.c.nat);
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
    case TmSome: return tm_some(normalize(t->as.some.val));
    case TmNone: return tm_none(normalize(t->as.none.ty));
    case TmOp:   return norm_op(t);
    case TmAssert: {
        Term *b = normalize(t->as.assert_.body);
        /* only a literal True assertion holds; never claim true blindly */
        if (b->tag == TmConst && b->as.c.kind == C_BOOL && b->as.c.b)
            return tm_bool(true);
        if (b->tag == TmConst && b->as.c.kind == C_BOOL && !b->as.c.b)
            norm_set_error(t->loc, "assertion did not hold");
        return tm_assert(b); /* stuck / non-Bool body: keep the assert */
    }
    case TmToMap: return norm_tomap(t);
    }
    return t;
}
