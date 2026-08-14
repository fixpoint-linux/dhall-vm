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

typedef struct { const char *file; int line, col; } SourceSpan;

#define SPAN_NONE ((SourceSpan){ NULL, 0, 0 })

/* ------------------------------------------------------------------ */
/* Term structure                                                      */
/* ------------------------------------------------------------------ */

typedef struct Term Term;
typedef struct Field Field;
typedef struct TextPart TextPart;
typedef struct Parser Parser;
typedef struct ImportLoader ImportLoader;

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

/* binary operator kinds (TmOp) */
typedef enum {
    OP_ADD, OP_SUB, OP_MUL,
    OP_LT, OP_LE, OP_GT, OP_GE, OP_EQ, OP_NE
} OpKind;

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
    TmBuiltin,      /* Natural/Bool/Text/List/List/map/... */
    TmSome,         /* Some x */
    TmNone,         /* None T */
    TmOp,           /* l + r, l == r, ... */
    TmAssert,       /* assert : body */
    TmToMap,        /* toMap r */
    TmCombine,      /* l /\ r  (recursive record merge) */
    TmWith          /* r with a.b = v  (record update) */
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
        struct { Term *val; } some;           /* TmSome */
        struct { Term *ty; } none;            /* TmNone */
        struct { OpKind op; Term *lhs, *rhs; } op; /* TmOp */
        struct { Term *body; } assert_;       /* TmAssert */
        struct { Term *rec; } tomap;          /* TmToMap */
        struct { Term *lhs, *rhs; } combine;  /* TmCombine */
        struct { Term *rec; char **path; int npath; Term *value; } with_; /* TmWith */
    } as;
};

/* ------------------------------------------------------------------ */
/* Error reporting                                                     */
/* ------------------------------------------------------------------ */

typedef enum {
    ERR_NONE = 0, ERR_LEX, ERR_PARSE, ERR_TYPE, ERR_SERIALIZE, ERR_IO
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
Term *tm_some(Term *val);
Term *tm_none(Term *ty);
Term *tm_op(OpKind op, Term *lhs, Term *rhs);
Term *tm_assert(Term *body);
Term *tm_tomap(Term *rec);
Term *tm_combine(Term *lhs, Term *rhs);
Term *tm_with(Term *rec, char **path, int npath, Term *value);

Field *field_new(const char *label, Term *type, Term *value);
Term *text_parts_single(const char *lit);   /* text with one literal part */

Term *shift(int d, int cutoff, Term *t);
Term *subst(int j, Term *s, Term *t);
bool alpha_eq(Term *a, Term *b);

void print_term(FILE *out, Term *t);        /* pretty-print normal form */

/* builtins.c — well-known builtins and their type schemas */
bool builtin_is_type_name(const char *n);
bool builtin_is_list(const char *n);
bool builtin_is_keyword(const char *n);
Term *builtin_type_schema(const char *name);   /* de Bruijn type schema; NULL if unknown */

/* ------------------------------------------------------------------ */
/* lexer.c                                                             */
/* ------------------------------------------------------------------ */

typedef enum {
    T_EOF, T_NAT, T_INT, T_DBL, T_STR_OPEN, T_STR_OPEN_MULTILINE, T_NAME,
    T_LAMBDA,   /* \ */
    T_ARROW,    /* -> */
    T_COLON, T_EQUALS, T_COMMA, T_DOT,
    T_LPAREN, T_RPAREN, T_LBRACE, T_RBRACE,
    T_LANGLE, T_RANGLE, T_LBRACKET, T_RBRACKET,
    T_PLUSPLUS, /* ++ */
    T_PLUS, T_MINUS, T_STAR,
    T_LT, T_LE, T_GT, T_GE, T_EQEQ, T_NE,
    T_IMPORT,   /* ./path, ../path, /path, env:NAME */
    T_BAR,      /* | */
    T_MERGE,    /* /\ */
    T_ERROR
} TokType;

typedef struct {
    TokType type;
    SourceSpan span;
    Const c;
    char *name;         /* for T_NAME and T_IMPORT spec (arena) */
} Token;

typedef struct {
    const char *src;
    size_t len, pos;
    int line, col;
    const char *file;       /* source filename (NULL = unknown) */
    bool after_operand;     /* did the last emitted token end a complete operand? */
    Token peeked;
    bool has_peek;
    DhallError err;
} Lexer;

void lexer_init(Lexer *lx, const char *src, const char *file);
Token lexer_peek(Lexer *lx);
Token lexer_next(Lexer *lx);
int lexer_read_char(Lexer *lx);      /* raw next char, updates line/col; -1 at EOF */
int lexer_peek_char(Lexer *lx);      /* raw next char without consuming */
SourceSpan lexer_here(Lexer *lx);    /* current position */
bool lexer_eof(Lexer *lx);           /* next char is EOF */

/* ------------------------------------------------------------------ */
/* import.c — file/env import loader                                  */
/* ------------------------------------------------------------------ */

#define MAX_IMPORT_DEPTH 64   /* error (not crash) beyond this import-chain depth */

ImportLoader *import_loader_new(void);
void import_loader_free(ImportLoader *l);
/* register the root file (or NULL for stdin) so relative imports resolve
   against its directory and self-import is detected */
void import_loader_push_root(ImportLoader *l, const char *root_file);
/* resolve an import spec (./x, ../y, /abs, env:NAME) to a term.
   On error sets *err and returns NULL. */
Term *import_resolve(ImportLoader *l, const char *spec, Parser *p, DhallError *err);

/* ------------------------------------------------------------------ */
/* parser.c                                                           */
/* ------------------------------------------------------------------ */

struct Parser {
    Lexer lx;
    /* de Bruijn name resolution stack */
    const char **names;
    int nnames, namescap;
    int depth;              /* current parser recursion depth (DoS guard) */
    int union_depth;        /* >0 while parsing a union alternative (no comparison) */
    ImportLoader *loader;   /* import chain/cache/dir (NULL = no imports) */
    DhallError err;
};

#define PARSE_MAX_DEPTH 1000   /* error (not crash) beyond this nesting depth */

Term *parse_source(Parser *p, const char *src, const char *file, DhallError *err);

/* ------------------------------------------------------------------ */
/* normalize.c                                                        */
/* ------------------------------------------------------------------ */

Term *normalize(Term *t);

/* overflow/error channel: normalize() has no out-param, so errors detected
   during normalization (arithmetic overflow, Natural/fold limit) are recorded
   in a module-global that callers clear before and check after. */
void normalize_clear_error(void);
bool normalize_has_error(void);
DhallError *normalize_get_error(void);

/* ------------------------------------------------------------------ */
/* typecheck.c                                                        */
/* ------------------------------------------------------------------ */

Term *infer_type(Parser *p, Term *t, DhallError *err);  /* returns type term or NULL */

/* ------------------------------------------------------------------ */
/* serialize.c                                                        */
/* ------------------------------------------------------------------ */

typedef enum { FMT_JSON, FMT_TOML, FMT_YAML } SerFormat;

/* Format-independent value tree built by term_to_value() from the
   normal form; the JSON/YAML/TOML emitters share it. */
typedef enum {
    VK_NULL, VK_NAT, VK_INT, VK_DBL, VK_BOOL, VK_TEXT, VK_ARRAY, VK_TABLE
} ValueKind;
typedef struct Value Value;
struct Value {
    ValueKind kind;
    union {
        uint64_t nat;   /* VK_NAT */
        int64_t i64;    /* VK_INT */
        double dbl;     /* VK_DBL */
        bool b;         /* VK_BOOL */
        char *text;     /* VK_TEXT */
        struct { Value **items; int n; } arr;  /* VK_ARRAY */
        struct { char **keys; Value **vals; int n; } tab; /* VK_TABLE */
    } as;
};

bool term_to_json(FILE *out, Term *t, DhallError *err); /* true on success */
bool term_to_toml(FILE *out, Term *t, DhallError *err); /* true on success */
bool term_to_yaml(FILE *out, Term *t, DhallError *err); /* true on success */
bool term_serialize(FILE *out, Term *t, SerFormat fmt, DhallError *err);

#endif /* DHALL_H */
