/* vschema.c — verification prototype for the NEW builtin de Bruijn type schemas.
   Links the REAL ast/arena/normalize/typecheck machinery by #including them.
   Checks: (a) hand-derived de Bruijn schema alpha-equals a named-binder-built version;
   (b) infer() type-checks the schema; (c) infer(schema) normalizes to Type;
   (d) partial application resolves the Optional T index.
   This is scratch proof, NOT the implementation.
   RESULT: ALL CHECKS PASSED. Copy direct_optional_fold()/direct_natural_fold() VERBATIM. */
#include "/workspace/src/dhall.h"

typedef struct { const char *names[32]; int n; } Scope;
static Term *V(Scope *s, const char *name) {
    for (int i = s->n - 1; i >= 0; i--)
        if (!strcmp(s->names[i], name)) return tm_var(s->n - 1 - i);
    fprintf(stderr, "NAMED SCOPE ERROR: unbound '%s'\n", name); exit(99);
}
static Scope push(Scope s, const char *name) { s.names[s.n++] = name; return s; }
static Term *O(void)  { return tm_builtin("Optional"); }
static Term *app(Term *f, Term *x) { return tm_app(f, x); }
static Term *NAT(void){ return tm_builtin("Natural"); }
static Term *BOOL(void){ return tm_builtin("Bool"); }
static Term *TEXT(void){ return tm_builtin("Text"); }

static Term *direct_optional_fold(void) {
    return tm_pi(tm_type(),
              tm_pi(app(O(), tm_var(0)),
                tm_pi(tm_type(),
                  tm_pi(tm_pi(tm_var(2), tm_var(1)),
                    tm_pi(tm_var(1), tm_var(2))))));
}
static Term *direct_natural_fold(void) {
    return tm_pi(NAT(),
              tm_pi(tm_type(),
                tm_pi(tm_pi(tm_var(0), tm_var(1)),
                  tm_pi(tm_var(1), tm_var(2)))));
}

static Term *named_optional_fold(void) {
    Scope s0 = {{0},0}; Scope sT = push(s0, "T");
    Term *optT = app(O(), V(&sT, "T"));
    Scope sV = push(sT, "_v"); Scope sA = push(sV, "A");
    Scope sA2 = push(sA, "_dummy"); Term *TtoA = tm_pi(V(&sA, "T"), V(&sA2, "A"));
    Scope sS = push(sA, "_some"); Scope sS2 = push(sS, "_dummy");
    Term *AtoA = tm_pi(V(&sS, "A"), V(&sS2, "A"));
    return tm_pi(tm_type(), tm_pi(optT, tm_pi(tm_type(), tm_pi(TtoA, AtoA))));
}
static Term *named_natural_fold(void) {
    Scope s0 = {{0},0}; Scope sN = push(s0, "n"); Scope sA = push(sN, "A");
    Scope sA2 = push(sA, "_dummy"); Term *AtoA1 = tm_pi(V(&sA, "A"), V(&sA2, "A"));
    Scope sS = push(sA, "_step"); Scope sS2 = push(sS, "_dummy");
    Term *AtoA2 = tm_pi(V(&sS, "A"), V(&sS2, "A"));
    return tm_pi(NAT(), tm_pi(tm_type(), tm_pi(AtoA1, AtoA2)));
}

Term *builtin_type_schema(const char *n) {
    if (!strcmp(n, "Natural") || !strcmp(n, "Integer") || !strcmp(n, "Double") ||
        !strcmp(n, "Bool") || !strcmp(n, "Text")) return tm_type();
    if (!strcmp(n, "List"))     return tm_pi(tm_type(), tm_type());
    if (!strcmp(n, "Optional")) return tm_pi(tm_type(), tm_type());
    if (!strcmp(n, "Optional/fold")) return direct_optional_fold();
    if (!strcmp(n, "Natural/fold"))  return direct_natural_fold();
    if (!strcmp(n, "Natural/isZero")) return tm_pi(NAT(), BOOL());
    if (!strcmp(n, "Natural/show"))   return tm_pi(NAT(), TEXT());
    if (!strcmp(n, "Natural/subtract")) return tm_pi(NAT(), tm_pi(NAT(), NAT()));
    return NULL;
}

static int failures = 0;
static void verify(bool cond, const char *what) { printf("%s %s\n", cond ? "PASS" : "FAIL", what); if (!cond) failures++; }

int main(void) {
    dhall_arena = arena_new(); DhallError err;
    Term *of_d = direct_optional_fold(); Term *of_n = named_optional_fold();
    verify(alpha_eq(of_d, of_n), "Optional/fold: direct == named");
    Term *nf_d = direct_natural_fold(); Term *nf_n = named_natural_fold();
    verify(alpha_eq(nf_d, nf_n), "Natural/fold: direct == named");
    Term *r;
    r = infer_type(NULL, of_d, &err); verify(r != NULL, "infer(Optional/fold) succeeds");
    verify(r && alpha_eq(normalize(r), tm_type()), "infer(Optional/fold) == Type");
    r = infer_type(NULL, nf_d, &err); verify(r != NULL, "infer(Natural/fold) succeeds");
    verify(r && alpha_eq(normalize(r), tm_type()), "infer(Natural/fold) == Type");
    Term *ofb = tm_builtin("Optional/fold");
    r = infer_type(NULL, ofb, &err); verify(r != NULL && r->tag == TmPi, "Optional/fold is Pi");
    r = infer_type(NULL, app(ofb, NAT()), &err);
    verify(r && r->tag == TmPi && alpha_eq(normalize(r->as.pi.dom), app(O(), NAT())),
          "Optional/fold Natural : Optional Natural -> ...");
    Term *nfb = tm_builtin("Natural/fold");
    r = infer_type(NULL, nfb, &err);
    verify(r && r->tag == TmPi && alpha_eq(normalize(r->as.pi.dom), NAT()), "Natural/fold : Natural -> ...");
    r = infer_type(NULL, app(nfb, tm_nat(0)), &err);
    verify(r && r->tag == TmPi && alpha_eq(normalize(r->as.pi.dom), tm_type()), "Natural/fold 0 : forall(A:Type) -> ...");
    printf("\n%s\n", failures ? "SOME CHECKS FAILED" : "ALL CHECKS PASSED");
    return failures ? 1 : 0;
}

#include "/workspace/src/arena.c"
#include "/workspace/src/ast.c"
#include "/workspace/src/normalize.c"
#include "/workspace/src/typecheck.c"
