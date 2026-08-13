/* builtins.c — well-known builtins and their de Bruijn type schemas.
   The List builtin schemas are adopted VERBATIM from ref/proto.c
   (map/filter/reverse/fold), which caught several off-by-one bugs.
   Optional/fold and Natural/fold are adopted VERBATIM from ref/vschema.c
   (direct de Bruijn derivations, verified to alpha-equal an independent
   named-binder derivation). */
#include "dhall.h"

bool builtin_is_type_name(const char *n) {
    return !strcmp(n, "Natural") || !strcmp(n, "Integer") ||
           !strcmp(n, "Double") || !strcmp(n, "Bool") ||
           !strcmp(n, "Text");
}

bool builtin_is_list(const char *n) {
    return !strcmp(n, "List");
}

/* reserved keywords handled specially by the parser (not plain builtins) */
bool builtin_is_keyword(const char *n) {
    return !strcmp(n, "let") || !strcmp(n, "in") || !strcmp(n, "if") ||
           !strcmp(n, "then") || !strcmp(n, "else") || !strcmp(n, "merge") ||
           !strcmp(n, "forall") || !strcmp(n, "assert") ||
           !strcmp(n, "Some") || !strcmp(n, "None") || !strcmp(n, "toMap");
}

/* type constant terms */
Term *builtin_nat(void) { return tm_builtin("Natural"); }
Term *builtin_int(void) { return tm_builtin("Integer"); }
Term *builtin_dbl(void) { return tm_builtin("Double"); }
Term *builtin_bool(void) { return tm_builtin("Bool"); }
Term *builtin_text(void) { return tm_builtin("Text"); }
Term *builtin_list(void) { return tm_builtin("List"); }

/* ---- List builtin type schemas (verbatim from proto.c) ---- */

static Term *map_type(void) {
    return tm_pi(tm_type(),
          tm_pi(tm_type(),
            tm_pi(tm_pi(tm_var(1), tm_var(1)),
              tm_pi(tm_app(builtin_list(), tm_var(2)), tm_app(builtin_list(), tm_var(2))))));
}
static Term *filter_type(void) {
    return tm_pi(tm_type(),
          tm_pi(tm_pi(tm_var(0), builtin_bool()),
            tm_pi(tm_app(builtin_list(), tm_var(1)), tm_app(builtin_list(), tm_var(2)))));
}
static Term *reverse_type(void) {
    return tm_pi(tm_type(), tm_pi(tm_app(builtin_list(), tm_var(0)), tm_app(builtin_list(), tm_var(1))));
}
static Term *fold_type(void) {
    return tm_pi(tm_type(),
          tm_pi(tm_app(builtin_list(), tm_var(0)),
            tm_pi(tm_type(),
              tm_pi(tm_pi(tm_var(2), tm_pi(tm_var(1), tm_var(2))),
                tm_pi(tm_var(1), tm_var(2))))));
}

/* ---- Optional / Natural builtin schemas ---- */

static Term *opt(void) { return tm_builtin("Optional"); }
static Term *nat(void) { return tm_builtin("Natural"); }
static Term *app(Term *f, Term *x) { return tm_app(f, x); }

/* VERIFIED (ref/vschema.c): direct de Bruijn Optional/fold schema.
   Optional/fold : forall T : Type -> Optional T ->
                   forall A : Type -> (T -> A) -> A -> A */
static Term *direct_optional_fold(void) {
    return tm_pi(tm_type(),
              tm_pi(app(opt(), tm_var(0)),
                tm_pi(tm_type(),
                  tm_pi(tm_pi(tm_var(2), tm_var(1)),
                    tm_pi(tm_var(1), tm_var(2))))));
}

/* VERIFIED (ref/vschema.c): direct de Bruijn Natural/fold schema.
   Natural/fold : Natural -> forall A : Type -> (A -> A) -> A -> A */
static Term *direct_natural_fold(void) {
    return tm_pi(nat(),
              tm_pi(tm_type(),
                tm_pi(tm_pi(tm_var(0), tm_var(1)),
                  tm_pi(tm_var(1), tm_var(2)))));
}

/* type schema for a builtin when used as a term; NULL if not a known builtin */
Term *builtin_type_schema(const char *n) {
    if (builtin_is_type_name(n)) return tm_type();
    if (builtin_is_list(n)) return tm_pi(tm_type(), tm_type());
    if (!strcmp(n, "List/map"))    return map_type();
    if (!strcmp(n, "List/filter")) return filter_type();
    if (!strcmp(n, "List/reverse"))return reverse_type();
    if (!strcmp(n, "List/fold"))   return fold_type();
    if (!strcmp(n, "Optional"))    return tm_pi(tm_type(), tm_type());
    if (!strcmp(n, "Optional/fold")) return direct_optional_fold();
    if (!strcmp(n, "Natural/fold"))  return direct_natural_fold();
    if (!strcmp(n, "Natural/isZero")) return tm_pi(nat(), tm_builtin("Bool"));
    if (!strcmp(n, "Natural/show"))   return tm_pi(nat(), tm_builtin("Text"));
    if (!strcmp(n, "Natural/subtract")) return tm_pi(nat(), tm_pi(nat(), nat()));
    return NULL;
}
