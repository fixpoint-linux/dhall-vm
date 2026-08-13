/* lexer.c — tokenizer for the Dhall subset. Produces tokens with source
   spans; skips whitespace and comments (-- line, {- -} nested block).
   Strings are not fully tokenized here — the parser drives raw-char
   reading (via lexer_read_char/lexer_peek_char) to handle ${} nesting. */
#include "dhall.h"
#include <ctype.h>
#include <errno.h>

static int cur(Lexer *lx) { return lx->pos < lx->len ? (unsigned char)lx->src[lx->pos] : -1; }

void lexer_init(Lexer *lx, const char *src) {
    lx->src = src;
    lx->len = strlen(src);
    lx->pos = 0;
    lx->line = 1;
    lx->col = 1;
    lx->has_peek = false;
    dhall_error_clear(&lx->err);
}

SourceSpan lexer_here(Lexer *lx) { return (SourceSpan){ lx->line, lx->col }; }

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

static bool is_name_start(int c) { return isalpha(c) || c == '_'; }
static bool is_name_char(int c) { return isalnum(c) || c == '_' || c == '-' || c == '\'' || c == '/'; }

static bool is_digit(int c) { return c >= '0' && c <= '9'; }

static Token mk_tok(TokType t, SourceSpan sp) {
    Token tok; tok.type = t; tok.span = sp; tok.name = NULL;
    tok.c = (Const){ C_NAT, 0, 0, 0, false };
    return tok;
}

Token lexer_next(Lexer *lx);

/* tokenize one token starting at current raw position (skipping ws/comments) */
static Token tokenize(Lexer *lx) {
    skip_ws_and_comments(lx);
    SourceSpan sp = lexer_here(lx);
    int c = cur(lx);
    if (c == -1) return mk_tok(T_EOF, sp);

    /* string */
    if (c == '"') { lexer_read_char(lx); return mk_tok(T_STR_OPEN, sp); }

    /* number: +n / -n / 0 -> Integer; digits -> Natural/Double */
    if (is_digit(c) || ((c == '+' || c == '-') &&
                        lx->pos + 1 < lx->len && is_digit((unsigned char)lx->src[lx->pos + 1]))) {
        /* signed literal */
        if (c == '+' || c == '-') {
            lexer_read_char(lx);
            if (!is_digit(cur(lx))) {
                lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
                snprintf(lx->err.msg, sizeof(lx->err.msg), "expected digits after sign");
                return mk_tok(T_ERROR, sp);
            }
            Token t = tokenize(lx);
            if (t.type != T_NAT && t.type != T_DBL) {
                lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
                snprintf(lx->err.msg, sizeof(lx->err.msg), "expected number literal after sign");
                return mk_tok(T_ERROR, sp);
            }
            if (t.type == T_DBL) {
                Token r = mk_tok(T_DBL, sp);
                double v = t.c.dbl;
                if (c == '-') v = -v;
                r.c = (Const){ C_DBL, 0, 0, v, false };
                return r;
            }
            int64_t v = (int64_t)t.c.nat;
            if (c == '-') v = -v;
            Token r = mk_tok(T_INT, sp);
            r.c = (Const){ C_INT, 0, v, 0, false };
            return r;
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
                    return mk_tok(T_ERROR, sp);
                }
                while (is_digit(cur(lx))) lexer_read_char(lx);
            }
            char *buf = arena_strndup(dhall_arena, lx->src + start, lx->pos - start);
            char *end;
            errno = 0;
            double d = strtod(buf, &end);
            Token t = mk_tok(T_DBL, sp);
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
            return mk_tok(T_ERROR, sp);
        }
        Token t = mk_tok(T_NAT, sp);
        t.c = (Const){ C_NAT, (uint64_t)v, 0, 0, false };
        return t;
    }

    /* identifier / keyword */
    if (is_name_start(c)) {
        size_t start = lx->pos;
        lexer_read_char(lx);
        while (is_name_char(cur(lx))) lexer_read_char(lx);
        Token t = mk_tok(T_NAME, sp);
        t.name = arena_strndup(dhall_arena, lx->src + start, lx->pos - start);
        return t;
    }

    /* symbols */
    lexer_read_char(lx);
    switch (c) {
    case '\\': return mk_tok(T_LAMBDA, sp);
    case ':': return mk_tok(T_COLON, sp);
    case '=': return mk_tok(T_EQUALS, sp);
    case ',': return mk_tok(T_COMMA, sp);
    case '.': return mk_tok(T_DOT, sp);
    case '(': return mk_tok(T_LPAREN, sp);
    case ')': return mk_tok(T_RPAREN, sp);
    case '{': return mk_tok(T_LBRACE, sp);
    case '}': return mk_tok(T_RBRACE, sp);
    case '<': return mk_tok(T_LANGLE, sp);
    case '>': return mk_tok(T_RANGLE, sp);
    case '[': return mk_tok(T_LBRACKET, sp);
    case ']': return mk_tok(T_RBRACKET, sp);
    case '|': return mk_tok(T_BAR, sp);
    case '+':
        if (cur(lx) == '+') { lexer_read_char(lx); return mk_tok(T_PLUSPLUS, sp); }
        lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
        snprintf(lx->err.msg, sizeof(lx->err.msg), "unexpected '+'");
        return mk_tok(T_ERROR, sp);
    case '-':
        if (cur(lx) == '>') { lexer_read_char(lx); return mk_tok(T_ARROW, sp); }
        lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
        snprintf(lx->err.msg, sizeof(lx->err.msg), "unexpected '-'");
        return mk_tok(T_ERROR, sp);
    default:
        lx->err.stage = ERR_LEX; lx->err.span = sp; lx->err.has_span = true;
        snprintf(lx->err.msg, sizeof(lx->err.msg), "unexpected character '%c'", c);
        return mk_tok(T_ERROR, sp);
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
