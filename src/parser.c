/* parser.c — recursive-descent parser for the Dhall subset.
   Resolves names to de Bruijn indices at parse time. Records/union
   fields are sorted by label and made duplicate-free. Handles string
   interpolation via raw-char reading with recursive expression parsing.

   Precedence (loosest→tightest):
     ->  <  :  <  comparison(== != < <= > >=)  <  additive(+ - ++)
        <  multiplicative(*)  <  application
   Every constructed term's .loc is stamped (tloc) from the current token
   so type errors report file:line:col. Imports are inlined at parse time
   (no TmImport tag survives; the loader lives in Parser.loader). */
#include "dhall.h"
#include <ctype.h>

static Token peek(Parser *p) { return lexer_peek(&p->lx); }
static Token next(Parser *p) { return lexer_next(&p->lx); }
static bool at(Parser *p, TokType t) { return peek(p).type == t; }
static bool at_name(Parser *p, const char *s) {
    Token t = peek(p);
    return t.type == T_NAME && t.name && !strcmp(t.name, s);
}

static bool parser_err(Parser *p) { return p->err.stage != ERR_NONE || p->lx.err.stage != ERR_NONE; }

static SourceSpan no_span(void) { return SPAN_NONE; }

/* stamp a constructed term's source location */
static Term *tloc(Term *t, SourceSpan sp) {
    if (t) t->loc = sp;
    return t;
}

static void perr(Parser *p, SourceSpan sp, const char *fmt, ...) {
    if (parser_err(p)) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(p->err.msg, sizeof(p->err.msg), fmt, ap);
    va_end(ap);
    p->err.stage = ERR_PARSE;
    p->err.span = sp;
    p->err.has_span = sp.line > 0;
}

static bool expect(Parser *p, TokType t, const char *what) {
    Token tk = peek(p);
    if (tk.type == t) { next(p); return true; }
    if (tk.type == T_ERROR && p->lx.err.stage == ERR_LEX) {
        p->err = p->lx.err;
        return false;
    }
    perr(p, tk.span, "expected %s", what);
    return false;
}

/* ---------- name stack (de Bruijn resolution) ---------- */

static void push_name(Parser *p, const char *name) {
    if (p->nnames == p->namescap) {
        p->namescap = p->namescap ? p->namescap * 2 : 16;
        p->names = realloc((void *)p->names, p->namescap * sizeof(char *));
    }
    p->names[p->nnames++] = name;
}
static void pop_name(Parser *p) { if (p->nnames > 0) p->nnames--; }
static int lookup_name(Parser *p, const char *name) {
    for (int i = p->nnames - 1; i >= 0; i--)
        if (!strcmp(p->names[i], name))
            return (p->nnames - 1) - i;   /* de Bruijn index */
    return -1;
}

/* ---------- forward decls ---------- */

static Term *parse_term(Parser *p);
static Term *parse_term_impl(Parser *p);
static Term *parse_let(Parser *p);
static Term *parse_if(Parser *p);
static Term *parse_assert(Parser *p);
static Term *parse_arrow(Parser *p);
static Term *parse_annotation(Parser *p);
static Term *parse_comparison(Parser *p);
static Term *parse_additive(Parser *p);
static Term *parse_multiplicative(Parser *p);
static Term *parse_merge(Parser *p);
static Term *parse_application(Parser *p);
static Term *parse_field(Parser *p);
static Term *parse_atom(Parser *p);
static Term *parse_text(Parser *p);
static Term *parse_record(Parser *p);
static Term *parse_union(Parser *p);
static Term *parse_list(Parser *p);
static Term *parse_lambda(Parser *p);
static Term *parse_forall(Parser *p);

/* ---------- helpers ---------- */

static bool is_keyword(const char *s) { return builtin_is_keyword(s); }

static bool can_start_atom(Parser *p) {
    Token t = peek(p);
    switch (t.type) {
    case T_NAME: return t.name && !is_keyword(t.name);
    case T_NAT: case T_INT: case T_DBL: case T_STR_OPEN:
    case T_LPAREN: case T_LBRACE: case T_LANGLE: case T_LBRACKET:
    case T_LAMBDA: case T_IMPORT:
        return true;
    default: return false;
    }
}

static int field_cmp(const void *a, const void *b) {
    const Field *fa = a, *fb = b;
    return strcmp(fa->label, fb->label);
}

static void sort_fields(Field *fs, int n) {
    qsort(fs, n, sizeof(Field), field_cmp);
}

/* ---------- grammar ---------- */

/* parse_term — recursion-depth-guarded entry point. Deeply nested input
   would otherwise exhaust the C stack (SIGSEGV); fail cleanly instead. */
static Term *parse_term(Parser *p) {
    if (p->depth >= PARSE_MAX_DEPTH) {
        perr(p, peek(p).span, "expression nesting too deep (max %d)", PARSE_MAX_DEPTH);
        return NULL;
    }
    p->depth++;
    Term *r = parse_term_impl(p);
    p->depth--;
    return r;
}

static Term *parse_term_impl(Parser *p) {
    if (at_name(p, "let")) return parse_let(p);
    if (at_name(p, "if")) return parse_if(p);
    if (at_name(p, "assert")) return parse_assert(p);
    if (at(p, T_LAMBDA)) return parse_lambda(p);
    if (at_name(p, "forall")) return parse_forall(p);
    return parse_arrow(p);
}

static Term *parse_let(Parser *p) {
    Token lt = next(p); /* let */
    Token nt = peek(p);
    if (nt.type != T_NAME || is_keyword(nt.name)) { perr(p, nt.span, "expected variable name after let"); return NULL; }
    next(p);
    Term *ann = NULL;
    if (at(p, T_COLON)) {
        next(p);
        ann = parse_arrow(p);
        if (!ann) return NULL;
    }
    if (!expect(p, T_EQUALS, "'=' in let binding")) return NULL;
    Term *val = parse_term(p);
    if (!val) return NULL;
    if (!at_name(p, "in")) { perr(p, peek(p).span, "expected 'in'"); return NULL; }
    next(p);
    push_name(p, nt.name);
    Term *body = parse_term(p);
    pop_name(p);
    if (!body) return NULL;
    return tloc(tm_let(ann, val, body), lt.span);
}

static Term *parse_if(Parser *p) {
    Token it = next(p); /* if */
    Term *c = parse_term(p);
    if (!c) return NULL;
    if (!at_name(p, "then")) { perr(p, peek(p).span, "expected 'then'"); return NULL; }
    next(p);
    Term *t = parse_term(p);
    if (!t) return NULL;
    if (!at_name(p, "else")) { perr(p, peek(p).span, "expected 'else'"); return NULL; }
    next(p);
    Term *e = parse_term(p);
    if (!e) return NULL;
    return tloc(tm_if(c, t, e), it.span);
}

static Term *parse_assert(Parser *p) {
    Token at_ = next(p); /* assert */
    if (!expect(p, T_COLON, "':' after assert")) return NULL;
    Term *body = parse_term(p);
    if (!body) return NULL;
    return tloc(tm_assert(body), at_.span);
}

static Term *parse_lambda(Parser *p) {
    Token lt = next(p); /* \ */
    if (!expect(p, T_LPAREN, "'(' in lambda")) return NULL;
    Token nt = peek(p);
    if (nt.type != T_NAME || is_keyword(nt.name)) { perr(p, nt.span, "expected parameter name in lambda"); return NULL; }
    next(p);
    if (!expect(p, T_COLON, "':' in lambda parameter type")) return NULL;
    Term *dom = parse_arrow(p);
    if (!dom) return NULL;
    if (!expect(p, T_RPAREN, "')' in lambda")) return NULL;
    if (!expect(p, T_ARROW, "'->' in lambda")) return NULL;
    push_name(p, nt.name);
    Term *body = parse_term(p);
    pop_name(p);
    if (!body) return NULL;
    return tloc(tm_lam(dom, body), lt.span);
}

static Term *parse_forall(Parser *p) {
    Token ft = next(p); /* forall */
    if (!expect(p, T_LPAREN, "'(' in forall")) return NULL;
    Token nt = peek(p);
    if (nt.type != T_NAME || is_keyword(nt.name)) { perr(p, nt.span, "expected binder name in forall"); return NULL; }
    next(p);
    if (!expect(p, T_COLON, "':' in forall binder type")) return NULL;
    Term *dom = parse_arrow(p);
    if (!dom) return NULL;
    if (!expect(p, T_RPAREN, "')' in forall")) return NULL;
    if (!expect(p, T_ARROW, "'->' in forall")) return NULL;
    push_name(p, nt.name);
    Term *cod = parse_term(p);
    pop_name(p);
    if (!cod) return NULL;
    return tloc(tm_pi(dom, cod), ft.span);
}

static Term *parse_arrow(Parser *p) {
    Term *left = parse_annotation(p);
    if (!left) return NULL;
    if (at(p, T_ARROW)) {
        Token ar = next(p);
        push_name(p, "_");
        Term *right = parse_arrow(p);
        pop_name(p);
        if (!right) return NULL;
        return tloc(tm_pi(left, right), ar.span);
    }
    return left;
}

static Term *parse_annotation(Parser *p) {
    Term *e = parse_comparison(p);
    if (!e) return NULL;
    if (at(p, T_COLON)) {
        Token cn = next(p);
        Term *ty = parse_arrow(p);
        if (!ty) return NULL;
        return tloc(tm_ann(e, ty), cn.span);
    }
    return e;
}

static Term *parse_comparison(Parser *p) {
    if (p->union_depth > 0) return parse_additive(p); /* no comparison in union alts */
    Term *left = parse_additive(p);
    if (!left) return NULL;
    for (;;) {
        Token op_tk = peek(p);
        OpKind op;
        if (op_tk.type == T_EQEQ) op = OP_EQ;
        else if (op_tk.type == T_NE) op = OP_NE;
        else if (op_tk.type == T_LT) op = OP_LT;
        else if (op_tk.type == T_LE) op = OP_LE;
        else if (op_tk.type == T_RANGLE) op = OP_GT;
        else if (op_tk.type == T_GE) op = OP_GE;
        else break;
        next(p);
        Term *r = parse_additive(p);
        if (!r) return NULL;
        left = tloc(tm_op(op, left, r), op_tk.span);
    }
    return left;
}

static Term *parse_additive(Parser *p) {
    Term *left = parse_multiplicative(p);
    if (!left) return NULL;
    for (;;) {
        Token op_tk = peek(p);
        if (op_tk.type == T_PLUS) {
            next(p);
            Term *r = parse_multiplicative(p);
            if (!r) return NULL;
            left = tloc(tm_op(OP_ADD, left, r), op_tk.span);
        } else if (op_tk.type == T_MINUS) {
            next(p);
            Term *r = parse_multiplicative(p);
            if (!r) return NULL;
            left = tloc(tm_op(OP_SUB, left, r), op_tk.span);
        } else if (op_tk.type == T_PLUSPLUS) {
            next(p);
            Term *r = parse_multiplicative(p);
            if (!r) return NULL;
            left = tloc(tm_append(left, r), op_tk.span);
        } else break;
    }
    return left;
}

static Term *parse_multiplicative(Parser *p) {
    Term *left = parse_merge(p);
    if (!left) return NULL;
    while (at(p, T_STAR)) {
        Token op_tk = next(p);
        Term *r = parse_merge(p);
        if (!r) return NULL;
        left = tloc(tm_op(OP_MUL, left, r), op_tk.span);
    }
    return left;
}

static Term *parse_merge(Parser *p) {
    if (at_name(p, "merge")) {
        Token mt = next(p);
        Term *h = parse_field(p);
        if (!h) return NULL;
        Term *u = parse_field(p);
        if (!u) return NULL;
        return tloc(tm_merge(h, u), mt.span);
    }
    return parse_application(p);
}

static Term *parse_application(Parser *p) {
    Term *e = parse_field(p);
    if (!e) return NULL;
    while (can_start_atom(p)) {
        Term *arg = parse_field(p);
        if (!arg) return NULL;
        e = tloc(tm_app(e, arg), e->loc);
    }
    return e;
}

static Term *parse_field(Parser *p) {
    Term *e = parse_atom(p);
    if (!e) return NULL;
    while (at(p, T_DOT)) {
        Token dt = next(p);
        Token lt = peek(p);
        if (lt.type != T_NAME || is_keyword(lt.name)) { perr(p, lt.span, "expected label after '.'"); return NULL; }
        next(p);
        e = tloc(tm_field(lt.name, e), dt.span);
    }
    return e;
}

static Term *parse_atom(Parser *p) {
    Token t = peek(p);
    switch (t.type) {
    case T_NAT: next(p); return tloc(tm_nat(t.c.nat), t.span);
    case T_INT: next(p); return tloc(tm_int(t.c.i64), t.span);
    case T_DBL: next(p); return tloc(tm_dbl(t.c.dbl), t.span);
    case T_STR_OPEN: return parse_text(p);
    case T_LAMBDA: return parse_lambda(p);
    case T_IMPORT: {
        if (!p->loader) { perr(p, t.span, "imports are not available"); return NULL; }
        next(p);
        DhallError ie;
        dhall_error_clear(&ie);
        Term *r = import_resolve(p->loader, t.name, p, &ie);
        if (!r) {
            /* Only attach the import site when the inner error carried no
               location of its own (env/missing/cycle/depth).  Preserve the
               imported file's file:line:col for parse/lex errors. */
            if (!ie.has_span) { ie.span = t.span; ie.has_span = (t.span.line > 0); }
            p->err = ie;
            return NULL;
        }
        return r;
    }
    case T_LPAREN: {
        next(p);
        Term *e = parse_term(p);
        if (!e) return NULL;
        if (!expect(p, T_RPAREN, "')'")) return NULL;
        return e;
    }
    case T_LBRACE: return parse_record(p);
    case T_LANGLE: return parse_union(p);
    case T_LBRACKET: return parse_list(p);
    case T_NAME: {
        const char *s = t.name;
        if (!strcmp(s, "True")) { next(p); return tloc(tm_bool(true), t.span); }
        if (!strcmp(s, "False")) { next(p); return tloc(tm_bool(false), t.span); }
        if (!strcmp(s, "Type")) { next(p); return tloc(tm_type(), t.span); }
        if (!strcmp(s, "Kind")) { next(p); return tloc(tm_kind(), t.span); }
        if (!strcmp(s, "Sort")) { next(p); return tloc(tm_sort(), t.span); }
        if (!strcmp(s, "Some")) { next(p); Term *v = parse_field(p); if (!v) return NULL; return tloc(tm_some(v), t.span); }
        if (!strcmp(s, "None")) { next(p); Term *ty = parse_field(p); if (!ty) return NULL; return tloc(tm_none(ty), t.span); }
        if (!strcmp(s, "toMap")) { next(p); Term *r = parse_field(p); if (!r) return NULL; return tloc(tm_tomap(r), t.span); }
        if (builtin_type_schema(s) != NULL) { next(p); return tloc(tm_builtin(s), t.span); }
        int idx = lookup_name(p, s);
        if (idx >= 0) { next(p); return tloc(tm_var(idx), t.span); }
        perr(p, t.span, "unbound variable '%s'", s);
        return NULL;
    }
    case T_ERROR:
        if (p->lx.err.stage == ERR_LEX) { p->err = p->lx.err; return NULL; }
        break;
    default:
        break;
    }
    perr(p, t.span, "unexpected token");
    return NULL;
}

/* ---------- string literal with interpolation ---------- */

static void text_add_part(Parser *p, TmpBuf *buf, bool *open, TextPart **head, TextPart **tail) {
    (void)p;
    if (*open) {
        TextPart *np = arena_alloc(dhall_arena, sizeof(TextPart));
        np->lit = tmpbuf_arena(dhall_arena, buf);
        np->expr = NULL;
        np->next = NULL;
        if (*tail) (*tail)->next = np; else *head = np;
        *tail = np;
        *open = false;
    }
}

static void text_add_expr(Parser *p, Term *expr, TextPart **head, TextPart **tail) {
    (void)p;
    TextPart *np = arena_alloc(dhall_arena, sizeof(TextPart));
    np->lit = NULL;
    np->expr = expr;
    np->next = NULL;
    if (*tail) (*tail)->next = np; else *head = np;
    *tail = np;
}

static Term *parse_text(Parser *p) {
    SourceSpan sp = peek(p).span;
    next(p); /* consume opening quote (T_STR_OPEN) */
    TmpBuf buf; tmpbuf_init(&buf);
    bool open = false;
    TextPart *head = NULL, *tail = NULL;

    for (;;) {
        int c = lexer_peek_char(&p->lx);
        if (c == -1) { perr(p, sp, "unterminated string"); return NULL; }
        if (c == '"') {
            lexer_read_char(&p->lx);
            break;
        }
        if (c == '$' && p->lx.pos + 1 < p->lx.len && p->lx.src[p->lx.pos + 1] == '{') {
            lexer_read_char(&p->lx); /* $ */
            lexer_read_char(&p->lx); /* { */
            text_add_part(p, &buf, &open, &head, &tail);
            Term *expr = parse_term(p);
            if (!expr) return NULL;
            Token cl = lexer_next(&p->lx);
            if (cl.type != T_RBRACE) { perr(p, cl.span, "expected '}' to close interpolation"); return NULL; }
            text_add_expr(p, expr, &head, &tail);
            continue;
        }
        if (c == '\\') {
            lexer_read_char(&p->lx);
            int e = lexer_read_char(&p->lx);
            switch (e) {
            case 'n': tmpbuf_addc(&buf, '\n'); break;
            case 't': tmpbuf_addc(&buf, '\t'); break;
            case 'r': tmpbuf_addc(&buf, '\r'); break;
            case 'b': tmpbuf_addc(&buf, '\b'); break;
            case 'f': tmpbuf_addc(&buf, '\f'); break;
            case '"': tmpbuf_addc(&buf, '"'); break;
            case '\\': tmpbuf_addc(&buf, '\\'); break;
            case '$': tmpbuf_addc(&buf, '$'); break;
            default: if (e != -1) tmpbuf_addc(&buf, (char)e); break;
            }
            open = true;
            continue;
        }
        lexer_read_char(&p->lx);
        tmpbuf_addc(&buf, (char)c);
        open = true;
    }
    text_add_part(p, &buf, &open, &head, &tail);
    if (!head) return tloc(tm_text_lit(""), sp);
    return tloc(tm_text(head), sp);
}

/* ---------- records ---------- */

static Term *parse_record(Parser *p) {
    SourceSpan sp = peek(p).span;
    next(p); /* { */
    if (at(p, T_RBRACE)) { next(p); return tloc(tm_record_lit(NULL, 0), sp); }
    if (at(p, T_EQUALS)) { /* {=} empty record literal */
        next(p);
        if (!expect(p, T_RBRACE, "'}' to close empty record literal")) return NULL;
        return tloc(tm_record_lit(NULL, 0), sp);
    }

    int cap = 4, n = 0;
    Field *fs = malloc(cap * sizeof(Field));
    int first_sep = 0; /* 0=unknown, 1=':', 2='=' */

    for (;;) {
        Token nt = peek(p);
        if (nt.type != T_NAME || is_keyword(nt.name)) { perr(p, nt.span, "expected record field label"); free(fs); return NULL; }
        next(p);
        Token sep = peek(p);
        int this_sep = 0;
        Term *ty = NULL, *val = NULL;
        if (sep.type == T_COLON) { this_sep = 1; next(p); ty = parse_arrow(p); if (!ty) { free(fs); return NULL; } }
        else if (sep.type == T_EQUALS) { this_sep = 2; next(p); val = parse_term(p); if (!val) { free(fs); return NULL; } }
        else { perr(p, sep.span, "expected ':' or '=' in record field"); free(fs); return NULL; }

        if (first_sep == 0) first_sep = this_sep;
        else if (first_sep != this_sep) { perr(p, sep.span, "cannot mix record type and literal fields"); free(fs); return NULL; }

        if (n == cap) { cap *= 2; fs = realloc(fs, cap * sizeof(Field)); }
        fs[n].label = nt.name;
        fs[n].type = ty;
        fs[n].value = val;
        n++;

        if (at(p, T_COMMA)) { next(p); continue; }
        break;
    }
    if (!expect(p, T_RBRACE, "'}' to close record")) { free(fs); return NULL; }

    sort_fields(fs, n);
    /* duplicate check */
    for (int i = 1; i < n; i++)
        if (!strcmp(fs[i].label, fs[i - 1].label)) {
            perr(p, no_span(), "duplicate record field '%s'", fs[i].label);
            free(fs); return NULL;
        }

    /* copy into arena so the term outlives the temp array */
    Field *af = arena_alloc(dhall_arena, n * sizeof(Field));
    memcpy(af, fs, n * sizeof(Field));
    free(fs);
    return tloc((first_sep == 1) ? tm_record_type(af, n) : tm_record_lit(af, n), sp);
}

/* ---------- unions ---------- */

static Term *parse_union(Parser *p) {
    SourceSpan sp = peek(p).span;
    next(p); /* < */
    if (at(p, T_RANGLE)) { next(p); return tloc(tm_union_type(NULL, 0), sp); }

    p->union_depth++;
    int cap = 4, n = 0;
    Field *fs = malloc(cap * sizeof(Field));
    bool is_lit = false;

    for (;;) {
        Token nt = peek(p);
        if (nt.type != T_NAME || is_keyword(nt.name)) { perr(p, nt.span, "expected union alternative label"); goto fail; }
        next(p);
        Token sep = peek(p);
        Term *ty = NULL, *val = NULL;
        if (sep.type == T_COLON) { next(p); ty = parse_arrow(p); if (!ty) goto fail; }
        else if (sep.type == T_EQUALS) { is_lit = true; next(p); val = parse_term(p); if (!val) goto fail; }
        else { perr(p, sep.span, "expected ':' or '=' in union alternative"); goto fail; }

        if (n == cap) { cap *= 2; fs = realloc(fs, cap * sizeof(Field)); }
        fs[n].label = nt.name;
        fs[n].type = ty;
        fs[n].value = val;
        n++;

        if (at(p, T_BAR)) { next(p); continue; }
        break;
    }
    if (!expect(p, T_RANGLE, "'>' to close union")) goto fail;

    if (is_lit) {
        int val_count = 0;
        for (int i = 0; i < n; i++) if (fs[i].value) val_count++;
        if (val_count != 1) { perr(p, no_span(), "union literal must have exactly one alternative with a value"); goto fail; }
    }

    sort_fields(fs, n);
    for (int i = 1; i < n; i++)
        if (!strcmp(fs[i].label, fs[i - 1].label)) {
            perr(p, no_span(), "duplicate union alternative '%s'", fs[i].label);
            goto fail;
        }

    Field *af = arena_alloc(dhall_arena, n * sizeof(Field));
    memcpy(af, fs, n * sizeof(Field));
    free(fs);
    p->union_depth--;
    return tloc(is_lit ? tm_union_lit(af, n) : tm_union_type(af, n), sp);

fail:
    free(fs);
    p->union_depth--;
    return NULL;
}

/* ---------- lists ---------- */

static Term *parse_list(Parser *p) {
    SourceSpan sp = peek(p).span;
    next(p); /* [ */
    if (at(p, T_RBRACKET)) { next(p); return tloc(tm_nil(), sp); }
    int cap = 4, n = 0;
    Term **elems = malloc(cap * sizeof(Term *));
    for (;;) {
        Term *e = parse_field(p);
        if (!e) { free(elems); return NULL; }
        if (n == cap) { cap *= 2; elems = realloc(elems, cap * sizeof(Term *)); }
        elems[n++] = e;
        if (at(p, T_COMMA)) { next(p); continue; }
        break;
    }
    if (!expect(p, T_RBRACKET, "']' to close list")) { free(elems); return NULL; }
    Term *out = tm_nil();
    for (int i = n - 1; i >= 0; i--) out = tloc(tm_cons(elems[i], out), elems[i]->loc);
    free(elems);
    return tloc(out, sp);
}

/* ---------- entry ---------- */

Term *parse_source(Parser *p, const char *src, const char *file, DhallError *err) {
    lexer_init(&p->lx, src, file);
    p->nnames = 0;
    dhall_error_clear(&p->err);
    Term *t = parse_term(p);
    if (!t && p->err.stage == ERR_NONE && p->lx.err.stage == ERR_NONE) {
        /* empty or immediate parse error with NULL without setting err */
        perr(p, lexer_here(&p->lx), "empty input");
    }
    if (t && !at(p, T_EOF)) {
        perr(p, peek(p).span, "unexpected trailing input");
        t = NULL;
    }
    if (parser_err(p)) {
        *err = p->err.stage != ERR_NONE ? p->err : p->lx.err;
        return NULL;
    }
    if (!t) { perr(p, lexer_here(&p->lx), "parse error"); *err = p->err; return NULL; }
    *err = (DhallError){ ERR_NONE, {0}, SPAN_NONE, false };
    return t;
}
