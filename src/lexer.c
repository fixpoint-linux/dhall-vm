/* lexer.c — tokenizer for the Dhall subset. Produces tokens with source
   spans; skips whitespace and comments (-- line, {- -} nested block).
   Strings are not fully tokenized here — the parser drives raw-char
   reading (via lexer_read_char/lexer_peek_char) to handle ${} nesting.

   Operator disambiguation:
   - `+`/`-` are signed-literal prefixes only when NOT after a complete
     operand (tracked via the after_operand flag); otherwise they are the
     binary operators T_PLUS/T_MINUS.
   - `<` is union-open (T_LANGLE) iff followed by NAME (: or = not ==),
     else less-than (T_LT) — a bounded raw-char lookahead, restored after.
   - `>` is always T_RANGLE; the parser disambiguates greater-than vs
     union-closer positionally. */
#include "dhall.h"
#include <ctype.h>
#include <errno.h>

static int cur(Lexer *lx) { return lx->pos < lx->len ? (unsigned char)lx->src[lx->pos] : -1; }

void lexer_init(Lexer *lx, const char *src, const char *file) {
    lx->src = src;
    lx->len = strlen(src);
    lx->pos = 0;
    lx->line = 1;
    lx->col = 1;
    lx->file = file;
    lx->after_operand = false;
    lx->has_peek = false;
    dhall_error_clear(&lx->err);
}

SourceSpan lexer_here(Lexer *lx) { return (SourceSpan){ lx->file, lx->line, lx->col }; }

int lexer_read_char(Lexer *lx) {
    if (lx->pos >= lx->len) return -1;
    int c = (unsigned char)lx->src[lx->pos++];
    if (c == '\n') { lx->line++; lx->col = 1; }
    else lx->col++;
    return c;
}

int lexer_peek_char(Lexer *lx) { return cur(lx); }
bool lexer_eof(Lexer *lx) { return cur(lx) == -1; }

static void skip_ws_and_comments(Lexer *lx) {
    for (;;) {
        int c = cur(lx);
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') { lexer_read_char(lx); continue; }
        if (c == '-' && lx->pos + 1 < lx->len && lx->src[lx->pos + 1] == '-') {
            while (cur(lx) != -1 && cur(lx) != '\n') lexer_read_char(lx);
            continue;
        }
        if (c == '{' && lx->pos + 1 < lx->len && lx->src[lx->pos + 1] == '-') {
            lexer_read_char(lx); lexer_read_char(lx); /* consume {- */
            int depth = 1;
            while (depth > 0 && cur(lx) != -1) {
                if (cur(lx) == '{' && lx->pos + 1 < lx->len && lx->src[lx->pos + 1] == '-') { lexer_read_char(lx); lexer_read_char(lx); depth++; }
                else if (cur(lx) == '-' && lx->pos + 1 < lx->len && lx->src[lx->pos + 1] == '}') { lexer_read_char(lx); lexer_read_char(lx); depth--; }
                else lexer_read_char(lx);
            }
            continue;
        }
        break;
    }
}

static bool is_name_start(int c) { return c != -1 && (isalpha(c) || c == '_'); }
static bool is_name_char(int c) { return c != -1 && (isalnum(c) || c == '_' || c == '-' || c == '\'' || c == '/'); }

static bool is_digit(int c) { return c >= '0' && c <= '9'; }

/* is the current char a +/- that begins a signed literal? a sign starts a
   signed literal only when it is followed (possibly after whitespace) by a
   digit. Non-consuming: only inspects lx->src. */
static bool sign_starts_literal(Lexer *lx) {
    size_t p = lx->pos;
    if (p >= lx->len) return false;
    int s = (unsigned char)lx->src[p];
    if (s != '+' && s != '-') return false;
    p++;
    while (p < lx->len) {
        int w = (unsigned char)lx->src[p];
        if (w == ' ' || w == '\t' || w == '\r' || w == '\n') p++;
        else break;
    }
    return p < lx->len && is_digit((unsigned char)lx->src[p]);
}

static bool is_import_path_char(int c) {
    if (c == -1) return false;
    if (isalnum(c)) return true;
    switch (c) { case '_': case '-': case '.': case '/': case '~': case '+': return true; }
    return false;
}

/* does a token type end a complete operand? (for +/- signed-vs-binary) */
static bool tok_ends_operand(TokType t, const char *name) {
    switch (t) {
    case T_NAT: case T_INT: case T_DBL:
    case T_RPAREN: case T_RBRACKET: case T_RBRACE: case T_RANGLE:
    case T_IMPORT: case T_STR_OPEN:
        return true;
    case T_NAME:
        /* A keyword never ends an operand, and a builtin (a function value)
           never does either — it is awaiting an application argument, so a
           following +/- is a signed literal (e.g. `Integer/toDouble +3`).
           Only a plain variable denotes a complete operand. */
        return !builtin_is_keyword(name) && builtin_type_schema(name) == NULL;
    default:
        return false;
    }
}

static Token emit(Lexer *lx, TokType t, SourceSpan sp, const char *name) {
    Token tok;
    tok.type = t;
    tok.span = sp;
    tok.name = (char *)name;
    tok.c = (Const){ C_NAT, 0, 0, 0, false };
    lx->after_operand = tok_ends_operand(t, name);
    return tok;
}

Token lexer_next(Lexer *lx);

/* tokenize one token starting at current raw position (skipping ws/comments) */
static Token tokenize(Lexer *lx) {
    skip_ws_and_comments(lx);
    SourceSpan sp = lexer_here(lx);
    int c = cur(lx);
    if (c == -1) return emit(lx, T_EOF, sp, NULL);

    /* string */
    if (c == '"') { lexer_read_char(lx); return emit(lx, T_STR_OPEN, sp, NULL); }

    /* number: +n / -n / 0 -> Integer; digits -> Natural/Double.
       A +/- is a signed-literal prefix only when NOT after an operand. */
    if (is_digit(c) || ((c == '+' || c == '-') && !lx->after_operand &&
                        sign_starts_literal(lx))) {
        /* signed literal */
        if (c == '+' || c == '-') {
            lexer_read_char(lx);
            /* allow whitespace between the sign and the digits (`- 5`) */
            while (cur(lx) == ' ' || cur(lx) == '\t' || cur(lx) == '\r' || cur(lx) == '\n')
                lexer_read_char(lx);
            if (!is_digit(cur(lx))) {
                lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
                snprintf(lx->err.msg, sizeof(lx->err.msg), "expected digits after sign");
                return emit(lx, T_ERROR, sp, NULL);
            }
            Token t = tokenize(lx);
            if (t.type != T_NAT && t.type != T_DBL) {
                lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
                snprintf(lx->err.msg, sizeof(lx->err.msg), "expected number literal after sign");
                return emit(lx, T_ERROR, sp, NULL);
            }
            if (t.type == T_DBL) {
                double v = t.c.dbl;
                if (c == '-') v = -v;
                Token r = emit(lx, T_DBL, sp, NULL);
                r.c = (Const){ C_DBL, 0, 0, v, false };
                return r;
            }
            /* Integer: range-check the magnitude before signed conversion to
               avoid implementation-defined cast and signed-negation UB. */
            uint64_t mag = t.c.nat;
            if (c == '-') {
                if (mag > (uint64_t)INT64_MAX + 1u) {
                    lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
                    snprintf(lx->err.msg, sizeof(lx->err.msg), "Integer literal overflow");
                    return emit(lx, T_ERROR, sp, NULL);
                }
                int64_t v = (mag == (uint64_t)INT64_MAX + 1u) ? INT64_MIN : -(int64_t)mag;
                Token r = emit(lx, T_INT, sp, NULL);
                r.c = (Const){ C_INT, 0, v, 0, false };
                return r;
            } else {
                if (mag > (uint64_t)INT64_MAX) {
                    lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
                    snprintf(lx->err.msg, sizeof(lx->err.msg), "Integer literal overflow");
                    return emit(lx, T_ERROR, sp, NULL);
                }
                Token r = emit(lx, T_INT, sp, NULL);
                r.c = (Const){ C_INT, 0, (int64_t)mag, 0, false };
                return r;
            }
        }
        /* unsigned literal */
        size_t start = lx->pos;
        while (is_digit(cur(lx))) lexer_read_char(lx);
        bool is_double = (cur(lx) == '.' && lx->pos + 1 < lx->len && is_digit(lx->src[lx->pos + 1]));
        if (!is_double && (cur(lx) == 'e' || cur(lx) == 'E')) is_double = true;
        if (is_double) {
            if (cur(lx) == '.') {
                lexer_read_char(lx);
                while (is_digit(cur(lx))) lexer_read_char(lx);
            }
            if (cur(lx) == 'e' || cur(lx) == 'E') {
                lexer_read_char(lx);
                if (cur(lx) == '+' || cur(lx) == '-') lexer_read_char(lx);
                if (!is_digit(cur(lx))) {
                    lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
                    snprintf(lx->err.msg, sizeof(lx->err.msg), "malformed double literal");
                    return emit(lx, T_ERROR, sp, NULL);
                }
                while (is_digit(cur(lx))) lexer_read_char(lx);
            }
            char *buf = arena_strndup(dhall_arena, lx->src + start, lx->pos - start);
            char *end;
            errno = 0;
            double d = strtod(buf, &end);
            Token t = emit(lx, T_DBL, sp, NULL);
            t.c = (Const){ C_DBL, 0, 0, d, false };
            return t;
        }
        /* Natural */
        char *buf = arena_strndup(dhall_arena, lx->src + start, lx->pos - start);
        errno = 0;
        unsigned long long v = strtoull(buf, NULL, 10);
        if (errno == ERANGE) {
            lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
            snprintf(lx->err.msg, sizeof(lx->err.msg), "Natural literal overflow");
            return emit(lx, T_ERROR, sp, NULL);
        }
        Token t = emit(lx, T_NAT, sp, NULL);
        t.c = (Const){ C_NAT, (uint64_t)v, 0, 0, false };
        return t;
    }

    /* identifier / keyword (and env:NAME import) */
    if (is_name_start(c)) {
        size_t start = lx->pos;
        lexer_read_char(lx);
        while (is_name_char(cur(lx))) lexer_read_char(lx);
        char *name = arena_strndup(dhall_arena, lx->src + start, lx->pos - start);
        /* env:NAME import: 'env' immediately followed by ':' */
        if (!strcmp(name, "env") && cur(lx) == ':') {
            lexer_read_char(lx); /* ':' */
            size_t s2 = lx->pos;
            if (cur(lx) != -1 && (isalpha(cur(lx)) || cur(lx) == '_'))
                while (cur(lx) != -1 && (isalnum(cur(lx)) || cur(lx) == '_')) lexer_read_char(lx);
            size_t nlen = lx->pos - s2;
            char *spec = arena_alloc(dhall_arena, 4 + nlen + 1);
            memcpy(spec, "env:", 4);
            memcpy(spec + 4, lx->src + s2, nlen);
            spec[4 + nlen] = '\0';
            return emit(lx, T_IMPORT, sp, spec);
        }
        return emit(lx, T_NAME, sp, name);
    }

    /* record merge operator /\ — must be recognized BEFORE the import-path
       branch below, which would otherwise lex the bare '/' as an absolute
       import path. */
    if (c == '/' && lx->pos + 1 < lx->len && lx->src[lx->pos + 1] == '\\') {
        lexer_read_char(lx);
        lexer_read_char(lx);
        return emit(lx, T_MERGE, sp, NULL);
    }

    /* import path: ./ ../ /abs */
    if (c == '/' ||
        (c == '.' && lx->pos + 1 < lx->len && lx->src[lx->pos + 1] == '/') ||
        (c == '.' && lx->pos + 2 < lx->len && lx->src[lx->pos + 1] == '.' && lx->src[lx->pos + 2] == '/')) {
        size_t start = lx->pos;
        while (is_import_path_char(cur(lx))) lexer_read_char(lx);
        char *spec = arena_strndup(dhall_arena, lx->src + start, lx->pos - start);
        return emit(lx, T_IMPORT, sp, spec);
    }

    /* symbols */
    lexer_read_char(lx);
    switch (c) {
    case '\\': return emit(lx, T_LAMBDA, sp, NULL);
    case ':': return emit(lx, T_COLON, sp, NULL);
    case '=':
        if (cur(lx) == '=') { lexer_read_char(lx); return emit(lx, T_EQEQ, sp, NULL); }
        return emit(lx, T_EQUALS, sp, NULL);
    case ',': return emit(lx, T_COMMA, sp, NULL);
    case '.': return emit(lx, T_DOT, sp, NULL);
    case '(': return emit(lx, T_LPAREN, sp, NULL);
    case ')': return emit(lx, T_RPAREN, sp, NULL);
    case '{': return emit(lx, T_LBRACE, sp, NULL);
    case '}': return emit(lx, T_RBRACE, sp, NULL);
    case '<': {
        if (cur(lx) == '=') { lexer_read_char(lx); return emit(lx, T_LE, sp, NULL); }
        /* bounded lookahead: union-open iff < (ws) NAME (ws) (: or = not ==) */
        size_t save_pos = lx->pos;
        int save_line = lx->line, save_col = lx->col;
        while (cur(lx) == ' ' || cur(lx) == '\t' || cur(lx) == '\r' || cur(lx) == '\n')
            lexer_read_char(lx);
        bool is_union = false;
        if (is_name_start(cur(lx))) {
            while (is_name_char(cur(lx))) lexer_read_char(lx);
            while (cur(lx) == ' ' || cur(lx) == '\t' || cur(lx) == '\r' || cur(lx) == '\n')
                lexer_read_char(lx);
            if (cur(lx) == ':' ||
                (cur(lx) == '=' && (lx->pos + 1 >= lx->len || lx->src[lx->pos + 1] != '=')))
                is_union = true;
        }
        lx->pos = save_pos; lx->line = save_line; lx->col = save_col;
        return emit(lx, is_union ? T_LANGLE : T_LT, sp, NULL);
    }
    case '>':
        if (cur(lx) == '=') { lexer_read_char(lx); return emit(lx, T_GE, sp, NULL); }
        return emit(lx, T_RANGLE, sp, NULL);
    case '[': return emit(lx, T_LBRACKET, sp, NULL);
    case ']': return emit(lx, T_RBRACKET, sp, NULL);
    case '|': return emit(lx, T_BAR, sp, NULL);
    case '*': return emit(lx, T_STAR, sp, NULL);
    case '+':
        if (cur(lx) == '+') { lexer_read_char(lx); return emit(lx, T_PLUSPLUS, sp, NULL); }
        return emit(lx, T_PLUS, sp, NULL);
    case '-':
        if (cur(lx) == '>') { lexer_read_char(lx); return emit(lx, T_ARROW, sp, NULL); }
        return emit(lx, T_MINUS, sp, NULL);
    case '!':
        if (cur(lx) == '=') { lexer_read_char(lx); return emit(lx, T_NE, sp, NULL); }
        lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
        snprintf(lx->err.msg, sizeof(lx->err.msg), "unexpected '!'");
        return emit(lx, T_ERROR, sp, NULL);
    default:
        lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
        snprintf(lx->err.msg, sizeof(lx->err.msg), "unexpected character '%c'", c);
        return emit(lx, T_ERROR, sp, NULL);
    }
}

Token lexer_peek(Lexer *lx) {
    if (!lx->has_peek) {
        lx->peeked = tokenize(lx);
        lx->has_peek = true;
    }
    return lx->peeked;
}

Token lexer_next(Lexer *lx) {
    if (lx->has_peek) {
        lx->has_peek = false;
        return lx->peeked;
    }
    return tokenize(lx);
}
