/* bignum.c — arbitrary-precision Natural arithmetic (base-2^32 limbs).
   Adopts the verified limb algorithms from ref/bignum_harness.c VERBATIM
   (40+ oracle checks, ALL PASS), with malloc/calloc replaced by the
   arena (all results are arena-allocated BigNat views; inputs read-only).

   Representation: BigNat { uint32_t *limbs; int nlimbs; } little-endian,
   nlimbs == 0 means 0.  Values < 2^64 never allocate (the small path lives
   in Const.nat / tm_nat); only values >= 2^64 carry a BigNat*. */
#include "dhall.h"

/* arena-allocated, zeroed limb array of n uint32 words */
static uint32_t *limbs_alloc(int n) {
    return (uint32_t *)arena_alloc(dhall_arena, (size_t)(n > 0 ? n : 1) * 4);
}

static void trim(BigNat *a) {
    while (a->nlimbs > 0 && a->limbs[a->nlimbs - 1] == 0) a->nlimbs--;
}

/* uint64 -> limb view in caller-supplied scratch; returns limb count */
int bignat_from_u64(uint64_t n, uint32_t scratch[2]) {
    scratch[0] = (uint32_t)n;
    if (n >= 0x100000000ull) { scratch[1] = (uint32_t)(n >> 32); return 2; }
    return (n != 0) ? 1 : 0;
}

/* BigNat -> uint64; *ok == false iff the value does not fit in 64 bits.
   Boundary: 2^64-1 has 2 limbs (fits); 2^64 has 3 limbs (ok=false). */
uint64_t bignat_to_u64(const BigNat *a, bool *ok) {
    if (a->nlimbs > 2) { *ok = false; return 0; }
    uint64_t v = 0;
    if (a->nlimbs >= 1) v |= a->limbs[0];
    if (a->nlimbs >= 2) v |= (uint64_t)a->limbs[1] << 32;
    *ok = true;
    return v;
}

/* decimal ASCII (no sign, no leading junk) -> BigNat, Horner mul-by-10+digit */
BigNat bignat_from_decimal(const char *digits) {
    size_t len = strlen(digits);
    int maxlimbs = (int)(len / 9) + 3;
    uint32_t *acc = limbs_alloc(maxlimbs);
    int n = 0;
    for (size_t i = 0; i < len; i++) {
        uint32_t d = (uint32_t)(digits[i] - '0');
        uint64_t carry = d;
        for (int j = 0; j < n; j++) {
            uint64_t t = (uint64_t)acc[j] * 10 + carry;
            acc[j] = (uint32_t)t;
            carry = t >> 32;
        }
        if (carry) acc[n++] = (uint32_t)carry;
    }
    BigNat r = { acc, n };
    trim(&r);
    return r;
}

int bignat_cmp(const BigNat *a, const BigNat *b) {
    if (a->nlimbs != b->nlimbs) return a->nlimbs < b->nlimbs ? -1 : 1;
    for (int i = a->nlimbs - 1; i >= 0; i--)
        if (a->limbs[i] != b->limbs[i]) return a->limbs[i] < b->limbs[i] ? -1 : 1;
    return 0;
}

BigNat bignat_add(const BigNat *a, const BigNat *b) {
    int n = a->nlimbs > b->nlimbs ? a->nlimbs : b->nlimbs;
    uint32_t *out = limbs_alloc(n + 1);
    uint64_t carry = 0;
    for (int i = 0; i < n; i++) {
        uint64_t s = carry + (uint64_t)(i < a->nlimbs ? a->limbs[i] : 0)
                          + (uint64_t)(i < b->nlimbs ? b->limbs[i] : 0);
        out[i] = (uint32_t)s;
        carry = s >> 32;
    }
    int m = n;
    if (carry) out[m++] = (uint32_t)carry;
    BigNat r = { out, m };
    trim(&r);
    return r;
}

/* saturating: a - b, clamped to 0 */
BigNat bignat_sub(const BigNat *a, const BigNat *b) {
    if (bignat_cmp(a, b) < 0) return (BigNat){ NULL, 0 };
    int n = a->nlimbs;
    uint32_t *out = limbs_alloc(n);
    uint64_t borrow = 0;
    for (int i = 0; i < n; i++) {
        uint64_t d = (uint64_t)a->limbs[i] - (uint64_t)(i < b->nlimbs ? b->limbs[i] : 0) - borrow;
        out[i] = (uint32_t)d;
        borrow = (d >> 63) & 1;
    }
    BigNat r = { out, n };
    trim(&r);
    return r;
}

BigNat bignat_mul(const BigNat *a, const BigNat *b) {
    if (a->nlimbs == 0 || b->nlimbs == 0) return (BigNat){ NULL, 0 };
    int n = a->nlimbs + b->nlimbs;
    uint32_t *out = limbs_alloc(n + 1);   /* +1 safety for carry ripple */
    for (int i = 0; i < a->nlimbs; i++) {
        uint64_t ai = a->limbs[i];
        uint64_t carry = 0;
        for (int j = 0; j < b->nlimbs; j++) {
            uint64_t cur = (uint64_t)out[i + j] + ai * b->limbs[j] + carry;
            out[i + j] = (uint32_t)cur;
            carry = cur >> 32;
        }
        int k = i + b->nlimbs;
        while (carry) {
            uint64_t cur = (uint64_t)out[k] + carry;
            out[k] = (uint32_t)cur;
            carry = cur >> 32;
            k++;
        }
    }
    BigNat r = { out, n };
    trim(&r);
    return r;
}

/* in-place short division by a uint32 divisor; returns remainder, shrinks *n */
static uint32_t divmod_u32(uint32_t *limbs, int *n, uint32_t d) {
    uint64_t rem = 0;
    for (int i = *n - 1; i >= 0; i--) {
        uint64_t cur = (rem << 32) | limbs[i];
        limbs[i] = (uint32_t)(cur / d);
        rem = cur % d;
    }
    while (*n > 0 && limbs[*n - 1] == 0) (*n)--;
    return (uint32_t)rem;
}

/* BigNat -> decimal string (repeated divmod by 1e9) */
char *bignat_to_decimal(const BigNat *a) {
    if (a->nlimbs == 0) return arena_strdup(dhall_arena, "0");
    int n = a->nlimbs;
    uint32_t *tmp = limbs_alloc(n);
    for (int i = 0; i < n; i++) tmp[i] = a->limbs[i];
    uint32_t *digits = limbs_alloc(n * 2 + 2);
    int nd = 0;
    /* DO-WHILE (not while): n >= 1 here, and do-while keeps the compiler from
       emitting -Wmaybe-uninitialized on digits[nd-1] below. */
    do { digits[nd++] = divmod_u32(tmp, &n, 1000000000u); } while (n > 0);
    TmpBuf buf; tmpbuf_init(&buf);
    char chunk[16];
    snprintf(chunk, sizeof(chunk), "%u", digits[nd - 1]);
    tmpbuf_add(&buf, chunk);
    for (int i = nd - 2; i >= 0; i--) {
        snprintf(chunk, sizeof(chunk), "%09u", digits[i]);
        tmpbuf_add(&buf, chunk);
    }
    return tmpbuf_arena(dhall_arena, &buf);
}

bool bignat_is_zero(const BigNat *a) { return a->nlimbs == 0; }
bool bignat_even(const BigNat *a) { return a->nlimbs == 0 || (a->limbs[0] & 1) == 0; }

/* small<->big seam: view any Const (C_NAT) as a BigNat, using caller scratch
   for the small path (no allocation for values < 2^64). */
BigNat const_bignat(Const c, uint32_t scratch[2]) {
    if (c.bnat) return *c.bnat;
    int n = bignat_from_u64(c.nat, scratch);
    return (BigNat){ scratch, n };
}

/* BigNat -> Const: small values (<= 2 limbs) narrow back to .nat; larger
   allocate a BigNat and set .bnat.  Round-trips const_bignat exactly. */
Const bignat_to_const(BigNat b) {
    if (b.nlimbs <= 2) {
        uint64_t v = 0;
        if (b.nlimbs >= 1) v |= b.limbs[0];
        if (b.nlimbs >= 2) v |= (uint64_t)b.limbs[1] << 32;
        return (Const){ C_NAT, v, 0, 0, false, NULL, NULL };
    }
    BigNat *p = arena_alloc(dhall_arena, sizeof(BigNat));
    *p = b;
    return (Const){ C_NAT, 0, 0, 0, false, p, NULL };
}

/* ---------------- arbitrary-precision signed Integer ---------------- */

/* build a signed value, normalizing -0 (mag.nlimbs==0 => neg=false) */
static BigInt bi_mk(bool neg, BigNat mag) {
    if (mag.nlimbs == 0) neg = false;
    BigInt b = { neg, mag };
    return b;
}

/* small<->big seam for C_INT: view any Const as a signed BigInt, using caller
   scratch for the small path (no allocation for |value| < 2^63).  The i64
   magnitude is computed without INT64_MIN negation UB. */
BigInt const_bigint(Const c, uint32_t scratch[2]) {
    if (c.big) return *c.big;
    int64_t v = c.i64;
    uint64_t mag = (v >= 0) ? (uint64_t)v : (uint64_t)(-(v + 1)) + 1u;
    int n = bignat_from_u64(mag, scratch);
    BigInt b = { v < 0, { scratch, n } };
    return b;
}

/* BigInt -> Const: small magnitudes (|v| fits int64) narrow back to .i64;
   larger allocate a BigInt and set .big.  The big path DEEP-COPIES the
   magnitude because callers (lexer signed-literal, Natural/toInteger) feed
   stack-scratch limb arrays for the 2-limb 2^63..2^64-1 range. */
Const bigint_to_const(BigInt b) {
    if (b.mag.nlimbs == 0)
        return (Const){ C_INT, 0, 0, 0, false, NULL, NULL };
    bool ok;
    uint64_t mag = bignat_to_u64(&b.mag, &ok);
    if (ok && !b.neg && mag <= (uint64_t)INT64_MAX)
        return (Const){ C_INT, 0, (int64_t)mag, 0, false, NULL, NULL };
    if (ok && b.neg && mag <= (uint64_t)INT64_MAX + 1u) {
        int64_t v = (mag == (uint64_t)INT64_MAX + 1u) ? INT64_MIN : -(int64_t)mag;
        return (Const){ C_INT, 0, v, 0, false, NULL, NULL };
    }
    BigInt *p = arena_alloc(dhall_arena, sizeof(BigInt));
    p->neg = b.neg;
    p->mag.nlimbs = b.mag.nlimbs;
    p->mag.limbs = arena_alloc(dhall_arena, (size_t)b.mag.nlimbs * 4);
    memcpy(p->mag.limbs, b.mag.limbs, (size_t)b.mag.nlimbs * 4);
    return (Const){ C_INT, 0, 0, 0, false, NULL, p };
}

BigInt bigint_add(const BigInt *a, const BigInt *b) {
    if (a->neg == b->neg)
        return bi_mk(a->neg, bignat_add(&a->mag, &b->mag));
    int c = bignat_cmp(&a->mag, &b->mag);
    if (c == 0) return bi_mk(false, (BigNat){ NULL, 0 });
    if (c > 0) return bi_mk(a->neg, bignat_sub(&a->mag, &b->mag));
    return bi_mk(b->neg, bignat_sub(&b->mag, &a->mag));
}

BigInt bigint_sub(const BigInt *a, const BigInt *b) {
    BigInt nb = bi_mk(!b->neg, b->mag);
    return bigint_add(a, &nb);
}

BigInt bigint_mul(const BigInt *a, const BigInt *b) {
    return bi_mk(a->neg != b->neg, bignat_mul(&a->mag, &b->mag));
}

BigInt bigint_neg(const BigInt *a) {
    return bi_mk(!a->neg, a->mag);
}

int bigint_cmp(const BigInt *a, const BigInt *b) {
    if (a->neg != b->neg) return a->neg ? -1 : 1;
    int c = bignat_cmp(&a->mag, &b->mag);
    return a->neg ? -c : c;
}

/* signed decimal, arena-allocated; no leading '+' for non-negative values */
char *bigint_to_decimal(const BigInt *a) {
    if (a->mag.nlimbs == 0) return arena_strdup(dhall_arena, "0");
    char *d = bignat_to_decimal(&a->mag);
    if (!a->neg) return d;
    size_t len = strlen(d);
    char *s = arena_alloc(dhall_arena, len + 2);
    s[0] = '-';
    memcpy(s + 1, d, len + 1);
    return s;
}

/* strtod over the decimal form; precision-loss, no error (matches Dhall) */
double bigint_to_double(const BigInt *a) {
    return strtod(bigint_to_decimal(a), NULL);
}
