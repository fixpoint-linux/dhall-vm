/* arena.c — bump allocator for all AST nodes and strings.
   Memory is never freed individually; the whole arena is reset per
   top-level evaluation. 8-byte aligned. */
#include "dhall.h"

#define BLOCK_SIZE (64u * 1024u)

typedef struct ArenaBlock ArenaBlock;
struct ArenaBlock {
    ArenaBlock *next;
    size_t used, cap;
    char data[];            /* flexible array */
};

struct Arena {
    ArenaBlock *head;
};

static ArenaBlock *block_new(size_t cap) {
    ArenaBlock *b = malloc(sizeof(ArenaBlock) + cap);
    if (!b) { fputs("dhall: out of memory\n", stderr); exit(3); }
    b->next = NULL;
    b->used = 0;
    b->cap = cap;
    return b;
}

Arena *arena_new(void) {
    Arena *a = malloc(sizeof(Arena));
    if (!a) { fputs("dhall: out of memory\n", stderr); exit(3); }
    a->head = block_new(BLOCK_SIZE);
    return a;
}

void arena_reset(Arena *a) {
    ArenaBlock *b = a->head;
    while (b && b->next) {
        ArenaBlock *nx = b->next;
        free(b);
        b = nx;
    }
    if (!b) { a->head = block_new(BLOCK_SIZE); }
    else { b->used = 0; a->head = b; }
}

static void *arena_alloc_aligned(Arena *a, size_t n) {
    /* align to 8 bytes */
    n = (n + 7u) & ~(size_t)7u;
    ArenaBlock *b = a->head;
    if (b->used + n > b->cap) {
        size_t cap = BLOCK_SIZE;
        while (cap < n) cap *= 2;
        ArenaBlock *nb = block_new(cap);
        nb->next = a->head;
        a->head = nb;
        b = nb;
    }
    void *p = b->data + b->used;
    b->used += n;
    return p;
}

void *arena_alloc(Arena *a, size_t n) {
    if (n == 0) n = 1;
    void *p = arena_alloc_aligned(a, n);
    memset(p, 0, n);
    return p;
}

char *arena_strndup(Arena *a, const char *s, size_t n) {
    char *r = arena_alloc(a, n + 1);
    memcpy(r, s, n);
    r[n] = '\0';
    return r;
}

char *arena_strdup(Arena *a, const char *s) {
    return arena_strndup(a, s, strlen(s));
}

/* ------------------------------------------------------------------ */
/* TmpBuf                                                             */
/* ------------------------------------------------------------------ */

void tmpbuf_init(TmpBuf *b) { b->s = NULL; b->len = 0; b->cap = 0; }

static void tmpbuf_grow(TmpBuf *b, size_t need) {
    if (b->len + need + 1 <= b->cap) return;
    size_t cap = b->cap ? b->cap : 64;
    while (b->len + need + 1 > cap) cap *= 2;
    b->s = realloc(b->s, cap);
    if (!b->s) { fputs("dhall: out of memory\n", stderr); exit(3); }
    b->cap = cap;
}

void tmpbuf_add(TmpBuf *b, const char *s) {
    size_t n = strlen(s);
    tmpbuf_grow(b, n);
    memcpy(b->s + b->len, s, n);
    b->len += n;
    b->s[b->len] = '\0';
}

void tmpbuf_addc(TmpBuf *b, char c) {
    tmpbuf_grow(b, 1);
    b->s[b->len++] = c;
    b->s[b->len] = '\0';
}

char *tmpbuf_arena(Arena *a, TmpBuf *b) {
    char *r = arena_strdup(a, b->s ? b->s : "");
    free(b->s);
    b->s = NULL; b->len = 0; b->cap = 0;
    return r;
}
