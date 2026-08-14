/* bignum_harness.c — standalone verification of the base-2^32 limb BigNat
 * arithmetic that dhall-c will adopt for arbitrary-precision Natural.
 *
 * This mirrors the EXACT algorithms the implementer will drop into dhall.h /
 * a new bignum.c (limbs are malloc'd here instead of arena_alloc'd; the
 * arithmetic is identical).  Oracle values are hardcoded (computed with
 * Python's arbitrary-precision ints).  Build:
 *     gcc -std=c11 -O2 -Wall -Wextra -o bignum_harness bignum_harness.c
 * Run: ./bignum_harness   (exits 0 iff all checks pass)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct { uint32_t *limbs; int nlimbs; } BigNat;

static uint32_t *alloc_limbs(int n) { return (uint32_t *)calloc((size_t)(n > 0 ? n : 1), 4); }

static void trim(BigNat *a) { while (a->nlimbs > 0 && a->limbs[a->nlimbs - 1] == 0) a->nlimbs--; }

static int from_u64(uint64_t n, uint32_t out[2]) {
    int m = 0;
    out[0] = (uint32_t)n;
    if (n >= 0x100000000ull) { out[1] = (uint32_t)(n >> 32); m = 2; }
    else if (n != 0) m = 1;
    return m;
}

static uint64_t to_u64(const BigNat *a, bool *ok) {
    if (a->nlimbs > 2) { *ok = false; return 0; }
    uint64_t v = 0;
    if (a->nlimbs >= 1) v |= a->limbs[0];
    if (a->nlimbs >= 2) v |= (uint64_t)a->limbs[1] << 32;
    *ok = true;
    return v;
}

/* decimal ASCII (no sign, no leading junk) -> BigNat, Horner mul-by-10+digit */
static BigNat from_decimal(const char *s) {
    size_t len = strlen(s);
    int maxlimbs = (int)(len / 9) + 3;
    uint32_t *acc = alloc_limbs(maxlimbs);
    int n = 0;
    for (size_t i = 0; i < len; i++) {
        uint32_t d = (uint32_t)(s[i] - '0');
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

static int cmp(const BigNat *a, const BigNat *b) {
    if (a->nlimbs != b->nlimbs) return a->nlimbs < b->nlimbs ? -1 : 1;
    for (int i = a->nlimbs - 1; i >= 0; i--)
        if (a->limbs[i] != b->limbs[i]) return a->limbs[i] < b->limbs[i] ? -1 : 1;
    return 0;
}

static BigNat add(const BigNat *a, const BigNat *b) {
    int n = a->nlimbs > b->nlimbs ? a->nlimbs : b->nlimbs;
    uint32_t *out = alloc_limbs(n + 1);
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

static BigNat sub(const BigNat *a, const BigNat *b) {
    if (cmp(a, b) < 0) return (BigNat){ NULL, 0 };  /* saturate at 0 */
    int n = a->nlimbs;
    uint32_t *out = alloc_limbs(n);
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

static BigNat mul(const BigNat *a, const BigNat *b) {
    if (a->nlimbs == 0 || b->nlimbs == 0) return (BigNat){ NULL, 0 };
    int n = a->nlimbs + b->nlimbs;
    uint32_t *out = alloc_limbs(n + 1);   /* +1 safety for carry ripple */
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
static char *to_decimal(const BigNat *a) {
    if (a->nlimbs == 0) { char *s = malloc(2); strcpy(s, "0"); return s; }
    int n = a->nlimbs;
    uint32_t *tmp = malloc((size_t)n * 4);
    memcpy(tmp, a->limbs, (size_t)n * 4);
    uint32_t *digits = malloc((size_t)(n * 2 + 2) * 4);
    int nd = 0;
    do { digits[nd++] = divmod_u32(tmp, &n, 1000000000u); } while (n > 0);
    char *out = malloc((size_t)nd * 9 + 16);
    char *q = out;
    q += sprintf(q, "%u", digits[nd - 1]);
    for (int i = nd - 2; i >= 0; i--) q += sprintf(q, "%09u", digits[i]);
    *q = '\0';
    free(tmp); free(digits);
    return out;
}

static bool bignat_is_zero(const BigNat *a) { return a->nlimbs == 0; }
static bool bignat_even(const BigNat *a) { return a->nlimbs == 0 || (a->limbs[0] & 1) == 0; }

/* ------------ test plumbing ------------ */

static int failures = 0;

static void check_dec(const char *label, const char *got, const char *want) {
    if (strcmp(got, want) != 0) {
        printf("FAIL %s: got %s want %s\n", label, got, want);
        failures++;
    }
}

static void check_bool(const char *label, bool got, bool want) {
    if (got != want) { printf("FAIL %s: got %d want %d\n", label, got, want); failures++; }
}

static void check_u64(const char *label, uint64_t got, uint64_t want) {
    if (got != want) { printf("FAIL %s: got %llu want %llu\n", label,
        (unsigned long long)got, (unsigned long long)want); failures++; }
}

/* parse -> decimal round trip */
static void rt(const char *dec) {
    BigNat a = from_decimal(dec);
    char *s = to_decimal(&a);
    check_dec("roundtrip", s, dec);
    free(s); free(a.limbs);
}

/* binary op on decimal strings, compare to oracle */
static void op(const char *label, const char *xs, const char *ys, char opc, const char *want) {
    BigNat a = from_decimal(xs), b = from_decimal(ys), r;
    if (opc == '+') r = add(&a, &b);
    else if (opc == '-') r = sub(&a, &b);
    else r = mul(&a, &b);
    char *s = to_decimal(&r);
    check_dec(label, s, want);
    free(s); free(r.limbs); free(a.limbs); free(b.limbs);
}

static void cmp_check(const char *xs, const char *ys, int want) {
    BigNat a = from_decimal(xs), b = from_decimal(ys);
    int c = cmp(&a, &b);
    int got = c < 0 ? -1 : c > 0 ? 1 : 0;
    if (got != want) { printf("FAIL cmp(%s,%s): got %d want %d\n", xs, ys, got, want); failures++; }
    free(a.limbs); free(b.limbs);
}

int main(void) {
    /* round-trips (canonical, no leading zeros) */
    rt("0");
    rt("1");
    rt("9");
    rt("4294967295");                 /* 2^32-1 */
    rt("4294967296");                 /* 2^32 */
    rt("18446744073709551615");       /* 2^64-1 */
    rt("18446744073709551616");       /* 2^64 */
    rt("18446744073709551617");       /* 2^64+1 */
    rt("340282366920938463463374607431768211456");   /* 2^128 */
    rt("340282366920938463463374607431768211455");   /* 2^128-1 */
    rt("1000000000000000000000000000000");           /* 10^30 */
    rt("170141183460469231731687303715884105728");   /* 2^127 */

    /* add */
    op("add-64-1+1", "18446744073709551615", "1", '+', "18446744073709551616");
    op("add-2x64-1", "18446744073709551615", "18446744073709551615", '+', "36893488147419103230");
    op("add-2x64", "18446744073709551616", "18446744073709551616", '+', "36893488147419103232");
    op("add-2x128", "340282366920938463463374607431768211456",
        "340282366920938463463374607431768211456", '+', "680564733841876926926749214863536422912");
    op("add-1e30", "1000000000000000000000000000000",
        "1000000000000000000000000000000", '+', "2000000000000000000000000000000");
    op("add-64+127", "18446744073709551616",
        "170141183460469231731687303715884105728", '+', "170141183460469231750134047789593657344");

    /* sub (saturating) */
    op("sub-sat", "2", "7", '-', "0");
    op("sub-2x64-1", "18446744073709551615", "1", '-', "18446744073709551614");
    op("sub-1e30-1", "1000000000000000000000000000000", "1", '-', "999999999999999999999999999999");
    op("sub-64p1-1", "18446744073709551617", "1", '-', "18446744073709551616");
    op("sub-128-64", "340282366920938463463374607431768211456",
        "18446744073709551616", '-', "340282366920938463444927863358058659840");

    /* mul */
    op("mul-32-32", "4294967296", "4294967296", '*', "18446744073709551616");
    op("mul-64sq", "18446744073709551615", "18446744073709551615", '*',
        "340282366920938463426481119284349108225");
    op("mul-64-64", "18446744073709551616", "18446744073709551616", '*',
        "340282366920938463463374607431768211456");
    op("mul-1e15", "1000000000000000", "1000000000000000", '*', "1000000000000000000000000000000");
    op("mul-by-0", "340282366920938463463374607431768211456", "0", '*', "0");

    /* comparisons */
    cmp_check("18446744073709551615", "18446744073709551616", -1);
    cmp_check("18446744073709551616", "18446744073709551616", 0);
    cmp_check("18446744073709551617", "18446744073709551616", 1);
    cmp_check("340282366920938463463374607431768211456", "18446744073709551616", 1);
    cmp_check("0", "1", -1);

    /* to_u64 / is_zero / even */
    {
        BigNat z = from_decimal("0");
        BigNat max64 = from_decimal("18446744073709551615");  /* 2^64-1: 2 limbs, fits */
        BigNat e = from_decimal("18446744073709551616");      /* 2^64: 3 limbs, even */
        BigNat o = from_decimal("18446744073709551617");      /* 2^64+1: 3 limbs, odd */
        BigNat big = from_decimal("340282366920938463463374607431768211456"); /* 2^128 */
        bool ok = false;
        check_bool("iszero", bignat_is_zero(&z), true);
        check_bool("even-64", bignat_even(&e), true);
        check_bool("odd-64p1", bignat_even(&o), false);
        check_u64("tou64-max", to_u64(&max64, &ok), 0xFFFFFFFFFFFFFFFFull); /* ok true (nlimbs==2) */
        check_bool("tou64-max-ok", ok, true);
        (void)to_u64(&e, &ok);      /* 2^64 -> nlimbs==3 -> does NOT fit */
        check_bool("tou64-2^64-fails", ok, false);
        (void)to_u64(&big, &ok);
        check_bool("tou64-big-fails", ok, false);
        free(z.limbs); free(max64.limbs); free(e.limbs); free(o.limbs); free(big.limbs);
    }

    /* from_u64 view (small path) */
    {
        uint32_t scratch[2];
        int n = from_u64(0xFFFFFFFFFFFFFFFFull, scratch);
        check_bool("fromu64-max-n", n == 2, true);
        check_u64("fromu64-max-lo", scratch[0], 0xFFFFFFFFu);
        check_u64("fromu64-max-hi", scratch[1], 0xFFFFFFFFu);
    }

    if (failures == 0) { printf("ALL PASS\n"); return 0; }
    printf("%d failure(s)\n", failures);
    return 1;
}
