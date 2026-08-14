/* bench.c — a small in-process benchmark for the interpreter pipeline.
 *
 * Usage: make bench   (builds and runs ./bench.com.dbg)
 *
 * This is a MEASUREMENT TOOL, not a correctness check. It is NOT part of
 * `make test` or `make all`. It links against every .c EXCEPT main.c, so it
 * tracks dhall.h: if the internal API changes, `make bench` may need a touch.
 *
 * It embeds one representative source string (a ~20-field nested record, a
 * ~200-element list, a let/lambda, and a merge), then times four loops, each
 * with arena_reset() per iteration (exactly like main.c's per-eval reset):
 *   A  parse_source
 *   B  parse + normalize
 *   C  parse + normalize + infer_type
 *   D  parse + normalize + term_to_json (into a tmpfile, not /dev/null)
 * Per-phase ns/op is derived by subtraction. clock() timing with auto-scaled
 * N (loop runs >= ~100 ms for stable numbers).
 */
#include "dhall.h"
#include <time.h>

#define NSEC_PER_SEC 1000000000.0

/* ~20-field nested record + a 200-element list + let/lambda + merge. */
static const char SRC[] =
    "let scale = \\(x : Natural) -> x * 2\n"
    "in  let tag = merge { Even = \\(_ : Natural) -> \"even\", Odd = \\(_ : Natural) -> \"odd\" }\n"
    "                 (< Even = 2 | Odd : Natural >)\n"
    "in  { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9, j = 10,\n"
    "      k = \"text\", l = True, m = False, n = 3.5,\n"
    "      nested = { x = 1, y = { z = 2, w = { deep = 3 } } },\n"
    "      list = List/map Natural Natural scale [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,\n"
    "        11, 12, 13, 14, 15, 16, 17, 18, 19, 20,\n"
    "        21, 22, 23, 24, 25, 26, 27, 28, 29, 30,\n"
    "        31, 32, 33, 34, 35, 36, 37, 38, 39, 40,\n"
    "        41, 42, 43, 44, 45, 46, 47, 48, 49, 50,\n"
    "        51, 52, 53, 54, 55, 56, 57, 58, 59, 60,\n"
    "        61, 62, 63, 64, 65, 66, 67, 68, 69, 70,\n"
    "        71, 72, 73, 74, 75, 76, 77, 78, 79, 80,\n"
    "        81, 82, 83, 84, 85, 86, 87, 88, 89, 90,\n"
    "        91, 92, 93, 94, 95, 96, 97, 98, 99, 100,\n"
    "        101, 102, 103, 104, 105, 106, 107, 108, 109, 110,\n"
    "        111, 112, 113, 114, 115, 116, 117, 118, 119, 120,\n"
    "        121, 122, 123, 124, 125, 126, 127, 128, 129, 130,\n"
    "        131, 132, 133, 134, 135, 136, 137, 138, 139, 140,\n"
    "        141, 142, 143, 144, 145, 146, 147, 148, 149, 150,\n"
    "        151, 152, 153, 154, 155, 156, 157, 158, 159, 160,\n"
    "        161, 162, 163, 164, 165, 166, 167, 168, 169, 170,\n"
    "        171, 172, 173, 174, 175, 176, 177, 178, 179, 180,\n"
    "        181, 182, 183, 184, 185, 186, 187, 188, 189, 190,\n"
    "        191, 192, 193, 194, 195, 196, 197, 198, 199, 200 ],\n"
    "      tag = tag }\n";

static double now_sec(void) {
    return (double)clock() / (double)CLOCKS_PER_SEC;
}

/* Run one loop body `n` times, returning total seconds. `phase` picks the
   pipeline; `tmp` is a reusable tmpfile for phase D. */
static double run_loop(int n, int phase, FILE *tmp) {
    double t0 = now_sec();
    for (int i = 0; i < n; i++) {
        arena_reset(dhall_arena);
        ImportLoader *loader = import_loader_new();
        Parser p;
        memset(&p, 0, sizeof(p));
        p.loader = loader;
        DhallError err;
        dhall_error_clear(&err);
        Term *t = parse_source(&p, SRC, "<bench>", &err);
        if (!t) { fprintf(stderr, "bench: parse error: %s\n", err.msg); exit(2); }
        if (phase >= 1) {
            normalize_clear_error();
            Term *nf = normalize(t);
            if (normalize_has_error()) { fprintf(stderr, "bench: normalize error\n"); exit(2); }
            if (phase == 1) { import_loader_free(loader); continue; }
            if (phase == 2) {
                if (!infer_type(&p, t, &err)) { fprintf(stderr, "bench: type error: %s\n", err.msg); exit(2); }
            } else {
                fflush(tmp);
                if (!term_to_json(tmp, nf, &err)) { fprintf(stderr, "bench: serialize error: %s\n", err.msg); exit(2); }
            }
        }
        import_loader_free(loader);
    }
    return now_sec() - t0;
}

/* Determine n such that the loop runs at least ~100 ms (with a lower bound). */
static int autoscale(int phase, FILE *tmp) {
    int n = 1;
    double dt = 0;
    while (dt < 0.100 && n < 1000000) {
        n *= 2;
        dt = run_loop(n, phase, tmp);
    }
    return n;
}

int main(void) {
    dhall_arena = arena_new();
    FILE *tmp = tmpfile();
    if (!tmp) { fprintf(stderr, "bench: cannot create tmpfile\n"); return 3; }

    double phases[4];
    int n[4];
    const char *names[4] = {
        "parse            (A)",
        "parse+normalize  (B)",
        "+infer_type      (C)",
        "+term_to_json    (D)"
    };

    for (int ph = 0; ph < 4; ph++) {
        n[ph] = autoscale(ph, tmp);
        phases[ph] = run_loop(n[ph], ph, tmp);
    }

    printf("dhall-c bench (SRC = ~20-field nested record + 200-elem list + let/lambda + merge)\n");
    printf("%-22s %12s %14s\n", "phase", "ns/op", "ops/s");
    printf("%-22s %12s %14s\n", "------", "-----", "-----");
    for (int ph = 0; ph < 4; ph++) {
        double ns = (phases[ph] / (double)n[ph]) * NSEC_PER_SEC;
        double ops = (double)n[ph] / phases[ph];
        printf("%-22s %12.1f %14.0f\n", names[ph], ns, ops);
    }
    /* per-phase by subtraction (B-A = normalize, C-B = typecheck, D-B = serialize) */
    double nrm = ((phases[1] / n[1]) - (phases[0] / n[0])) * NSEC_PER_SEC;
    double tc  = ((phases[2] / n[2]) - (phases[1] / n[1])) * NSEC_PER_SEC;
    double ser = ((phases[3] / n[3]) - (phases[1] / n[1])) * NSEC_PER_SEC;
    printf("\nderived per-phase ns/op:\n");
    printf("  normalize  : %12.1f ns/op\n", nrm);
    printf("  typecheck  : %12.1f ns/op\n", tc);
    printf("  serialize  : %12.1f ns/op\n", ser);

    fclose(tmp);
    return 0;
}
