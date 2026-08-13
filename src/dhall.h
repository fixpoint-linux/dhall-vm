/* dhall.h — shared internal header for the Dhall subset interpreter.
   Single-TERM representation (everything is a term), de Bruijn indices,
   eager normalization, bidirectional typechecking. All AST nodes and
   strings are arena-allocated and never freed; the arena is reset per
   top-level evaluation. */
#ifndef DHALL_H
#define DHALL_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>

/* ------------------------------------------------------------------ */
/* Arena                                                              */
/* ------------------------------------------------------------------ */

typedef struct Arena Arena;

Arena *arena_new(void);
void arena_reset(Arena *a);
void *arena_alloc(Arena *a, size_t n);
char *arena_strdup(Arena *a, const char *s);
char *arena_strndup(Arena *a, const char *s, size_t n);

/* Growable char builder (malloc-backed scratch; not arena-resident). */
typedef struct { char *s; size_t len, cap; } TmpBuf;
void tmpbuf_init(TmpBuf *b);
void tmpbuf_add(TmpBuf *b, const char *s);
void tmpbuf_addc(TmpBuf *b, char c);
char *tmpbuf_arena(Arena *a, TmpBuf *b); /* copy into arena, frees scratch */

/* Global arena set by main() per top-level evaluation. */
extern Arena *dhall_arena;

/* ------------------------------------------------------------------ */
/* Source locations                                                    */
/* ------------------------------------------------------------------ */

typedef struct { int line, col; } SourceSpan;

#define SPAN_NONE ((SourceSpan){ 0, 0 })

/* ------------------------------------------------------------------ */
/* Term structure                                                      */
/* ------------------------------------------------------------------ */

typedef struct Term Term;
typedef struct Field Field;
typedef struct TextPart TextPart;

typedef enum {
    C_NAT, C_INT, C_DBL, C_BOOL
} ConstKind;

typedef struct {
    ConstKind kind;
    uint64_t nat;   /* C_NAT */
    int64_t i64;    /* C_INT */
    double dbl;     /* C_DBL */
    bool b;         /* C_BOOL */
} Const;

typedef enum {
    TmVar,          /* de Bruijn variable */
    TmConst,        /* Natural/Integer/Double/Bool literal */
    TmText,         /* Text literal with optional ${} interpolation */
    TmType, TmKind, TmSort,
    TmLam,          /* \x : T -> body */
    TmPi,           /* forall x : T -> U  (dependent) */
    TmApp,
    TmIf,
    TmLet,          /* let x [: T] = v in body */
    TmAnn,          /* e : T */
    TmNil, TmCons,  /* lists (cons/nil chains) */
    TmTextAppend,   /* t1 ++ t2 */
    TmRecordType,   /* { a : T, b : U } */
    TmRecordLit,    /* { a = v, b = w } */
    TmField,        /* r.a */
    TmUnionType,    /* < A : T | B : U > */
    TmUnionLit,     /* < A = v | B : U > */
    TmMerge,        /* merge handlers u */
    TmBuiltin       /* Natural/Bool/Text/List/List/map/... */
} TermTag;

struct TextPart {
    char *lit;              /* literal chunk (arena), NULL if starts with expr */
    Term *expr;             /* interpolation expr, NULL if this is a literal chunk */
    struct TextPart *next;
};

struct Field {
    char *label;            /* arena */
    Term *type;             /* record/union type field, or NULL */
    Term *value;            /* record literal value / union selected value, or NULL */
};

struct Term {
    TermTag tag;
    SourceSpan loc;
    union {
        int idx;                              /* TmVar */
        Const c;                              /* TmConst */
        TextPart *text;                       /* TmText */
        struct { Term *dom, *body; } lam;     /* TmLam */
        struct { Term *dom, *cod; } pi;       /* TmPi */
        struct { Term *fn, *arg; } app;       /* TmApp */
        struct { Term *c, *t, *e; } if_;      /* TmIf */
        struct { Term *ann, *val, *body; } let_; /* TmLet */
        struct { Term *e, *ty; } ann;         /* TmAnn */
        struct { Term *head, *tail; } cons;   /* TmCons */
        struct { Term *a, *b; } append;       /* TmTextAppend */
        struct { Field *fs; int n; } rec;     /* TmRecordType/TmRecordLit */
        struct { char *label; Term *rec; } field; /* TmField */
        struct { Field *fs; int n; } uni;     /* TmUnionType/TmUnionLit */
        struct { Term *handlers, *u; } merge; /* TmMerge */
        const char *bname;                    /* TmBuiltin */
    } as;
};

/* ------------------------------------------------------------------ */
/* Error reporting                                                     */
/* ------------------------------------------------------------------ */

typedef enum {
    ERR_NONE = 0, ERR_LEX, ERR_PARSE, ERR_TYPE, ERR_JSON, ERR_IO
} ErrorStage;

typedef struct {
    ErrorStage stage;
    char msg[512];
    SourceSpan span;
    bool has_span;
} DhallError;

void dhall_error_clear(DhallError *e);
void dhall_error_set(DhallError *e, ErrorStage st, SourceSpan sp, const char *fmt, ...);
int dhall_error_exit(DhallError *e);

/* ------------------------------------------------------------------ */
/* ast.c                                                              */
/* ------------------------------------------------------------------ */

Term *tm_var(int idx);
Term *tm_const(Const c);
Term *tm_nat(uint64_t n);
Term *tm_int(int64_t n);
Term *tm_dbl(double d);
Term *tm_bool(bool b);
Term *tm_text(TextPart *parts);
Term *tm_text_lit(const char *s);
Term *tm_type(void);
Term *tm_kind(void);
Term *tm_sort(void);
Term *tm_lam(Term *dom, Term *body);
Term *tm_pi(Term *dom, Term *cod);
Term *tm_app(Term *fn, Term *arg);
Term *tm_if(Term *c, Term *t, Term *e);
Term *tm_let(Term *ann, Term *val, Term *body);
Term *tm_ann(Term *e, Term *ty);
Term *tm_nil(void);
Term *tm_cons(Term *head, Term *tail);
Term *tm_append(Term *a, Term *b);
Term *tm_record_type(Field *fs, int n);
Term *tm_record_lit(Field *fs, int n);
Term *tm_field(const char *label, Term *rec);
Term *tm_union_type(Field *fs, int n);
Term *tm_union_lit(Field *fs, int n);
Term *tm_merge(Term *handlers, Term *u);
Term *tm_builtin(const char *name);

Field *field_new(const char *label, Term *type, Term *value);
Term *text_parts_single(const char *lit);   /* text with one literal part */

Term *shift(int d, int cutoff, Term *t);
Term *subst(int j, Term *s, Term *t);
bool alpha_eq(Term *a, Term *b);

void print_term(FILE *out, Term *t);        /* pretty-print normal form */

/* builtins.c — well-known builtins and their type schemas */
bool builtin_is_type_name(const char *n);
bool builtin_is_list(const char *n);
Term *builtin_type_schema(const char *name);   /* de Bruijn type schema; NULL if unknown */

/* ------------------------------------------------------------------ */
/* lexer.c                                                             */
/* ------------------------------------------------------------------ */

typedef enum {
    T_EOF, T_NAT, T_INT, T_DBL, T_STR_OPEN, T_NAME,
    T_LAMBDA,   /* \ */
    T_ARROW,    /* -> */
    T_COLON, T_EQUALS, T_COMMA, T_DOT,
    T_LPAREN, T_RPAREN, T_LBRACE, T_RBRACE,
    T_LANGLE, T_RANGLE, T_LBRACKET, T_RBRACKET,
    T_PLUSPLUS, /* ++ */
    T_BAR,      /* | */
    T_ERROR
} TokType;

typedef struct {
    TokType type;
    SourceSpan span;
    Const c;
    char *name;         /* for T_NAME (arena) */
} Token;

typedef struct {
    const char *src;
    size_t len, pos;
    int line, col;
    Token peeked;
    bool has_peek;
    DhallError err;
} Lexer;

void lexer_init(Lexer *lx, const char *src);
Token lexer_peek(Lexer *lx);
Token lexer_next(Lexer *lx);
int lexer_read_char(Lexer *lx);      /* raw next char, updates line/col; -1 at EOF */
int lexer_peek_char(Lexer *lx);      /* raw next char without consuming */
SourceSpan lexer_here(Lexer *lx);    /* current position */
bool lexer_eof(Lexer *lx);           /* next char is EOF */

/* ------------------------------------------------------------------ */
/* parser.c                                                           */
/* ------------------------------------------------------------------ */

typedef struct {
    Lexer lx;
    /* de Bruijn name resolution stack */
    const char **names;
    int nnames, namescap;
    int depth;              /* current parser recursion depth (DoS guard) */
    DhallError err;
} Parser;

#define PARSE_MAX_DEPTH 1000   /* error (not crash) beyond this nesting depth */

Term *parse_source(Parser *p, const char *src, DhallError *err);

/* ------------------------------------------------------------------ */
/* normalize.c                                                        */
/* ------------------------------------------------------------------ */

Term *normalize(Term *t);

/* ------------------------------------------------------------------ */
/* typecheck.c                                                        */
/* ------------------------------------------------------------------ */

Term *infer_type(Parser *p, Term *t, DhallError *err);  /* returns type term or NULL */

/* ------------------------------------------------------------------ */
/* json.c                                                             */
/* ------------------------------------------------------------------ */

bool term_to_json(FILE *out, Term *t, DhallError *err); /* true on success */

#endif /* DHALL_H */
