/* builtins.c — well-known builtins and their de Bruijn type schemas.
   The List builtin schemas are adopted VERBATIM from ref/proto.c
   (map/filter/reverse/fold), which caught several off-by-one bugs. */
#include "dhall.h"

bool builtin_is_type_name(const char *n) {
    return !strcmp(n, "Natural") || !strcmp(n, "Integer") ||
           !strcmp(n, "Double") || !strcmp(n, "Bool") ||
           !strcmp(n, "Text");
}

bool builtin_is_list(const char *n) {
    return !strcmp(n, "List");
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

/* type schema for a builtin when used as a term; NULL if not a known builtin */
Term *builtin_type_schema(const char *n) {
    if (builtin_is_type_name(n)) return tm_type();
    if (builtin_is_list(n)) return tm_pi(tm_type(), tm_type());
    if (!strcmp(n, "List/map"))    return map_type();
    if (!strcmp(n, "List/filter")) return filter_type();
    if (!strcmp(n, "List/reverse"))return reverse_type();
    if (!strcmp(n, "List/fold"))   return fold_type();
    return NULL;
}
