#!/usr/bin/env bash
# u4_ast_diff.sh — U4 de Bruijn + printer twin-driver gate.
#
# Builds the C twin driver (a tiny main over src/parser.c + the C engine) and
# the Zig twin driver (over zig/src/parser.zig + zig/src/ast.zig), then for
# every fixture in the corpora runs both and asserts byte-identical pipeline
# output:
#     === <path>
#     T <print_term(t)>
#     SHIFT <print_term(shift(1,0,t))>
#     SUB <print_term(subst(0, tm_var(7), shift(1,0,t)))>
#     AE <alpha_eq(t,t)> <alpha_eq(s,s)> <alpha_eq(t,sub)>
# This surfaces de Bruijn off-by-ones in shift/subst and printer regressions
# (the de Bruijn machinery is the #1 correctness risk in the migration).
#
# Also runs two fixed-mode checks byte-identically on both sides:
#     SYNTHETIC  — cross-tag record/union alpha_eq (the LOAD-BEARING
#                  record-type<->record-literal / union-type<->union-literal
#                  coincidence) plus lambda alpha tests.
#     DBL        — adversarial doubles through dbl_fmt (1e300, 5e-324, 0.1,
#                  -0.0, DBL_MAX, DBL_MIN-subnormal, NAN, INF, -INF, ...).
#
# Corpora: tests/cases/*.dhall, tests/cases/imports/**/*.dhall, examples/*.dhall.
# (vendor/dhall-lang is not checked out in this tree; if present, covered too.)
#
# Gate: bash zig/u4_ast_diff.sh  →  ALL PASS
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIGOUT="$REPO_ROOT/zig-out"
mkdir -p "$ZIGOUT"

# ─── Zig cache dirs (sandbox) ───────────────────────────────────────────────
if [ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]; then export ZIG_GLOBAL_CACHE_DIR=/tmp/.zcache; fi
if [ -z "${ZIG_LOCAL_CACHE_DIR:-}" ];  then export ZIG_LOCAL_CACHE_DIR=/tmp/.zlcache;  fi
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

# ─── Build both twin drivers ────────────────────────────────────────────────
echo "building C twin driver..."
gcc -O2 -I "$REPO_ROOT/src" -o "$ZIGOUT/u4_c_dump" \
    "$REPO_ROOT/src/arena.c" "$REPO_ROOT/src/bignum.c" "$REPO_ROOT/src/ast.c" \
    "$REPO_ROOT/src/builtins.c" "$REPO_ROOT/src/lexer.c" "$REPO_ROOT/src/parser.c" \
    "$SCRIPT_DIR/u4_ast_dump.c" -lm
echo "building Zig twin driver..."
zig build-exe -O ReleaseSafe -lc \
    -femit-bin="$ZIGOUT/u4_z_dump" "$SCRIPT_DIR/src/ast_dump.zig"

C_OUT=$(mktemp); Z_OUT=$(mktemp)
trap 'rm -f "$C_OUT" "$Z_OUT"' EXIT

PASS=0; FAIL=0

diff_one() {
  local mode="$1"
  "$ZIGOUT/u4_c_dump" "$mode" > "$C_OUT"
  local crc=$?
  "$ZIGOUT/u4_z_dump" "$mode" > "$Z_OUT"
  local zrc=$?
  if [ "$crc" -ne "$zrc" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL(exit) $crc/$zrc: $mode"
    return
  fi
  if cmp -s "$C_OUT" "$Z_OUT"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $mode"
    diff "$C_OUT" "$Z_OUT" | head -40 | sed 's/^/    /'
  fi
}

# ─── fixed modes: synthetic alpha_eq + adversarial dbl_fmt + de Bruijn smoke ─
diff_one SYNTHETIC
diff_one DBL
diff_one DEBRUIJN

# ─── stdin-mode fixtures: tests/cases/*.dhall ───────────────────────────────
while IFS= read -r f; do diff_one "$f"; done < <(find "$REPO_ROOT/tests/cases" -maxdepth 1 -name '*.dhall' -print | sort)

# ─── file-mode fixtures: tests/cases/imports/**/*.dhall ─────────────────────
while IFS= read -r f; do diff_one "$f"; done < <(find "$REPO_ROOT/tests/cases/imports" -name '*.dhall' -print | sort)

# ─── file-mode fixtures: examples/*.dhall ───────────────────────────────────
while IFS= read -r f; do diff_one "$f"; done < <(find "$REPO_ROOT/examples" -maxdepth 1 -name '*.dhall' -print | sort)

# ─── dhall-lang corpus (if vendored) ────────────────────────────────────────
if [ -d "$REPO_ROOT/vendor/dhall-lang/tests" ]; then
  while IFS= read -r f; do diff_one "$f"; done < <(find "$REPO_ROOT/vendor/dhall-lang/tests" -name '*.dhall' -print | sort)
fi

echo
echo "=== U4 ast pipeline: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -ne 0 ]; then
  echo "DIFF FAILURES PRESENT"
  exit 1
fi
echo "ALL PASS"
