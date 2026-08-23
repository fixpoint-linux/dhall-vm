/* u4_ast_dump.c — U4 twin-driver (C side). Parses the file given on argv[1]
   with the real C parser (parser.c), then runs the de Bruijn + printer pipeline
   and prints a byte-identical stream to the Zig twin (zig/src/ast_dump.zig):

       === <path>
       T <print_term(t)>
       SHIFT <print_term(shift(1,0,t))>
       SUB <print_term(subst(0, tm_var(7), shift(1,0,t)))>
       AE <alpha_eq(t,t)> <alpha_eq(s,s)> <alpha_eq(t,sub)>

   On parse error prints:
       === <path>
       ERROR <stage> <line>:<col> <msg>

   Modes:
       u4_ast_dump <file>       pipeline on a parsed file
       u4_ast_dump SYNTHETIC    fixed synthetic alpha_eq cross-tag tests
       u4_ast_dump DBL          adversarial doubles through dbl_fmt

   The C-vs-Zig differential gate diffs these streams across the corpora. */
#include "dhall.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

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

static int run_pipeline(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("=== %s\nERROR open\n", path); return 0; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *src = malloc((size_t)sz + 1);
    if (!src) { fclose(f); return 0; }
    fread(src, 1, (size_t)sz, f);
    src[sz] = '\0';
    fclose(f);

    dhall_arena = arena_new();
    Parser p;
    memset(&p, 0, sizeof(p));
    p.loader = NULL;
    DhallError err;
    dhall_error_clear(&err);
    Term *t = parse_source(&p, src, path, &err);
    if (!t) {
        printf("=== %s\nERROR %d %d:%d %s\n", path, (int)err.stage,
               err.span.line, err.span.col, err.msg);
        return 0;
    }
    printf("=== %s\n", path);
    printf("T "); print_term(stdout, t); printf("\n");
    Term *s = shift(1, 0, t);
    printf("SHIFT "); print_term(stdout, s); printf("\n");
    Term *sub = subst(0, tm_var(7), s);
    printf("SUB "); print_term(stdout, sub); printf("\n");
    printf("AE %d %d %d\n", (int)alpha_eq(t, t), (int)alpha_eq(s, s),
           (int)alpha_eq(t, sub));
    return 0;
}

static void print_ae(int v) { printf("%d", v); }

static int run_synthetic(void) {
    dhall_arena = arena_new();
    printf("=== SYNTHETIC\n");
    /* empty record literal {=} and empty record type {} coincide (cross-tag) */
    Term *rl0 = tm_record_lit(NULL, 0);
    Term *rt0 = tm_record_type(NULL, 0);
    /* empty union literal/type */
    Term *ul0 = tm_union_lit(NULL, 0);
    Term *ut0 = tm_union_type(NULL, 0);
    /* { a = 1 } literal vs { a : Natural } type (differ: populated slots) */
    Field *f1 = field_new("a", NULL, tm_nat(1));
    Field *f2 = field_new("a", tm_nat(1), NULL);
    Term *rl1 = tm_record_lit(f1, 1);
    Term *rt1 = tm_record_type(f2, 1);
    /* union lit < a = 1 > vs union type < a : Natural > */
    Field *u1 = field_new("a", NULL, tm_nat(1));
    Field *u2 = field_new("a", tm_nat(1), NULL);
    Term *ul1 = tm_union_lit(u1, 1);
    Term *ut1 = tm_union_type(u2, 1);
    /* lambda: same vs shifted body */
    Term *lam_a = tm_lam(tm_type(), tm_var(0));
    Term *lam_b = tm_lam(tm_type(), tm_var(1));
    printf("RLRT "); print_ae(alpha_eq(rl0, rt0)); printf("\n");
    printf("RTRL "); print_ae(alpha_eq(rt0, rl0)); printf("\n");
    printf("ULUT "); print_ae(alpha_eq(ul0, ut0)); printf("\n");
    printf("UTUL "); print_ae(alpha_eq(ut0, ul0)); printf("\n");
    printf("RL1RT1 "); print_ae(alpha_eq(rl1, rt1)); printf("\n");
    printf("RL1RL1 "); print_ae(alpha_eq(rl1, rl1)); printf("\n");
    printf("UL1UT1 "); print_ae(alpha_eq(ul1, ut1)); printf("\n");
    printf("LAMAA "); print_ae(alpha_eq(lam_a, lam_a)); printf("\n");
    printf("LAMAB "); print_ae(alpha_eq(lam_a, lam_b)); printf("\n");
    return 0;
}

static int run_dbl(void) {
    printf("=== DBL\n");
    double dvals[] = {
        1e300, 5e-324, 0.1, -0.0, 0.0, 1.0, -1.0, 3.141592653589793, 1e-7,
        1e21, 123456789.123, 2.5e-10, 100.0, 1e15, 1.7976931348623157e308,
        2.2250738585072014e-308, 6.0, -0.5, 1.2345678901234567, 9007199254740993.0,
    };
    for (unsigned i = 0; i < sizeof(dvals) / sizeof(dvals[0]); i++) {
        char b[64];
        dbl_fmt(b, sizeof(b), dvals[i]);
        printf("DBL%u %s\n", i, b);
    }
    char b[64];
    dbl_fmt(b, sizeof(b), NAN);    printf("NAN %s\n", b);
    dbl_fmt(b, sizeof(b), INFINITY); printf("INF %s\n", b);
    dbl_fmt(b, sizeof(b), -INFINITY); printf("NINF %s\n", b);
    return 0;
}

/* Fixed de Bruijn smoke tests — free-variable terms so shift/subst actually
   fire (corpus files are closed terms where these are near-identity). */
static int run_debruijn(void) {
    dhall_arena = arena_new();
    printf("=== DEBRUIJN\n");
    /* A: nested lam, free var 2 in innermost body: \x. \y. _2
       shift(1,0): free var 2 -> 3; bound vars unchanged.
       shift(2,0): free var 2 -> 4. */
    Term *A = tm_lam(tm_type(), tm_lam(tm_type(), tm_var(2)));
    printf("A "); print_term(stdout, A); printf("\n");
    printf("A1 "); print_term(stdout, shift(1, 0, A)); printf("\n");
    printf("A2 "); print_term(stdout, shift(2, 0, A)); printf("\n");
    /* B: free vars 3 and 1 in an app; subst(1, _9) -> _3->_2 (dec), _1->_9 */
    Term *B = tm_app(tm_var(3), tm_var(1));
    printf("B "); print_term(stdout, B); printf("\n");
    printf("BS "); print_term(stdout, subst(1, tm_var(9), B)); printf("\n");
    /* C: lambda whose body is the bound var 0; subst(0,_5) leaves it alone */
    Term *C = tm_lam(tm_type(), tm_var(0));
    printf("C "); print_term(stdout, C); printf("\n");
    printf("CS "); print_term(stdout, subst(0, tm_var(5), C)); printf("\n");
    /* D: lambda body is free var 1; subst(0,_5) must shift substitute +1 */
    Term *D = tm_lam(tm_type(), tm_var(1));
    printf("D "); print_term(stdout, D); printf("\n");
    printf("DS "); print_term(stdout, subst(0, tm_var(5), D)); printf("\n");
    /* E: shift the substituted result back down (round-trip sanity) */
    Term *E = tm_lam(tm_type(), tm_lam(tm_type(), tm_var(1))); /* free var 1 under 2 binders */
    printf("E "); print_term(stdout, E); printf("\n");
    printf("E1 "); print_term(stdout, shift(1, 0, E)); printf("\n");
    printf("EAE "); print_ae(alpha_eq(E, shift(1, 0, E))); printf("\n");
    printf("EAE2 "); print_ae(alpha_eq(shift(1, 0, E), shift(1, 0, E))); printf("\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (strcmp(argv[1], "SYNTHETIC") == 0) return run_synthetic();
    if (strcmp(argv[1], "DBL") == 0) return run_dbl();
    if (strcmp(argv[1], "DEBRUIJN") == 0) return run_debruijn();
    return run_pipeline(argv[1]);
}
