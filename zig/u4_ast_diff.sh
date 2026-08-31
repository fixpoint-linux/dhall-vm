#!/usr/bin/env bash
# u4_ast_diff.sh — U4 de Bruijn + printer golden gate.
#
# Builds the Zig twin driver (a tiny main over zig/src/parser.zig +
# zig/src/ast.zig) and for every fixture in the corpora asserts its pipeline
# output matches the recorded golden baseline in zig/golden/u4/:
#     === <path>
#     T <print_term(t)>
#     SHIFT <print_term(shift(1,0,t))>
#     SUB <print_term(subst(0, tm_var(7), shift(1,0,t)))>
#     AE <alpha_eq(t,t)> <alpha_eq(s,s)> <alpha_eq(t,sub)>
# On parse error prints:
#     === <path>
#     ERROR <stage> <line>:<col> <msg>
# This surfaces de Bruijn off-by-ones in shift/subst and printer regressions
# (the de Bruijn machinery is the #1 correctness risk in the migration). The Zig
# port is the trusted implementation (byte-verified against the removed C oracle
# by the u4 differential before removal).
#
# Also runs three fixed-mode checks recorded as goldens:
#     SYNTHETIC  — cross-tag record/union alpha_eq (the LOAD-BEARING
#                  record-type<->record-literal / union-type<->union-literal
#                  coincidence) plus lambda alpha tests.
#     DBL        — adversarial doubles through dbl_fmt (1e300, 5e-324, 0.1,
#                  -0.0, DBL_MAX, DBL_MIN-subnormal, NAN, INF, -INF, ...).
#     DEBRUIJN   — shift/subst/alpha_eq smoke over nested lambdas.
# RECORD_GOLDEN=1 regenerates the baselines; the corpora and fixed modes are
# deterministic, so the baselines are stable.
#
# Corpora: tests/cases/*.dhall, tests/cases/imports/**/*.dhall, examples/*.dhall.
# (vendor/dhall-lang is not checked out in this tree; if present, covered too.)
#
# Gate: bash zig/u4_ast_diff.sh  →  ALL PASS
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIGOUT="$REPO_ROOT/zig-out"
GOLDEN="$SCRIPT_DIR/golden/u4"
mkdir -p "$ZIGOUT" "$GOLDEN"

# ─── Zig cache dirs (sandbox) ───────────────────────────────────────────────
if [ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]; then export ZIG_GLOBAL_CACHE_DIR=/tmp/.zcache; fi
if [ -z "${ZIG_LOCAL_CACHE_DIR:-}" ];  then export ZIG_LOCAL_CACHE_DIR=/tmp/.zlcache;  fi
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

# ─── Build the Zig twin driver ──────────────────────────────────────────────
echo "building Zig twin driver..."
zig build-exe -O ReleaseSafe -lc \
    -femit-bin="$ZIGOUT/u4_z_dump" "$SCRIPT_DIR/src/ast_dump.zig"

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

PASS=0; FAIL=0

# check_one <mode-or-relpath> — run the driver with cwd = repo root (fixed mode
# strings pass through; file fixtures get their repo-relative path), then
# byte-compare stdout against zig/golden/u4/<mode-or-relpath>.out (recording that
# golden first when RECORD_GOLDEN=1). The `=== <path>` header uses the relative
# path, keeping baselines machine-independent.
check_one() {
  local arg="$1"
  "$ZIGOUT/u4_z_dump" "$arg" > "$OUT"
  local golden="$GOLDEN/$arg.out"
  if [ "${RECORD_GOLDEN:-0}" = "1" ]; then
    mkdir -p "$(dirname "$golden")"
    cp "$OUT" "$golden"
    echo "recorded $arg"
    PASS=$((PASS + 1))
    return
  fi
  if cmp -s "$OUT" "$golden"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $arg"
    diff "$golden" "$OUT" | head -40 | sed 's/^/    /'
  fi
}

# Run every corpus with cwd = repo root and relative paths, so golden baselines
# are machine-independent (no absolute paths leak into the `=== <path>` header).
cd "$REPO_ROOT"

# ─── fixed modes: synthetic alpha_eq + adversarial dbl_fmt + de Bruijn smoke ─
check_one SYNTHETIC
check_one DBL
check_one DEBRUIJN

# ─── tests/cases/*.dhall ────────────────────────────────────────────────────
while IFS= read -r f; do check_one "$f"; done < <(find tests/cases -maxdepth 1 -name '*.dhall' -print | sort)

# ─── tests/cases/imports/**/*.dhall ─────────────────────────────────────────
while IFS= read -r f; do check_one "$f"; done < <(find tests/cases/imports -name '*.dhall' -print | sort)

# ─── examples/*.dhall ───────────────────────────────────────────────────────
while IFS= read -r f; do check_one "$f"; done < <(find examples -maxdepth 1 -name '*.dhall' -print | sort)

# ─── dhall-lang corpus (if vendored) ────────────────────────────────────────
if [ -d vendor/dhall-lang/tests ]; then
  while IFS= read -r f; do check_one "$f"; done < <(find vendor/dhall-lang/tests -name '*.dhall' -print | sort)
fi

echo
echo "=== U4 ast pipeline: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -ne 0 ]; then
  echo "DIFF FAILURES PRESENT"
  exit 1
fi
echo "ALL PASS"
