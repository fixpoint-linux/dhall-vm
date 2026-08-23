#!/usr/bin/env bash
# u2_lexer_diff.sh — U2 token-dump twin-driver gate.
#
# Builds the C twin driver (a tiny main over src/lexer.c + the C engine) and
# the Zig twin driver (over zig/src/lexer.zig), then for every fixture in the
# corpora runs both and asserts byte-identical token streams:
#     <TOKTYPE> <line>:<col> <text>
# Corpora: tests/cases/*.dhall, tests/cases/imports/**/*.dhall, examples/*.dhall.
# (vendor/dhall-lang is not checked out in this tree; if it is present later,
# add a loop below.)
#
# Gate: bash zig/u2_lexer_diff.sh  →  ALL PASS
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
gcc -O2 -I "$REPO_ROOT/src" -o "$ZIGOUT/u2_c_tok" \
    "$REPO_ROOT/src/arena.c" "$REPO_ROOT/src/bignum.c" "$REPO_ROOT/src/ast.c" \
    "$REPO_ROOT/src/builtins.c" "$REPO_ROOT/src/lexer.c" \
    "$SCRIPT_DIR/u2_token_dump.c" -lm
echo "building Zig twin driver..."
zig build-exe -O ReleaseSafe -lc \
    -femit-bin="$ZIGOUT/u2_z_tok" "$SCRIPT_DIR/src/token_dump.zig"

C_OUT=$(mktemp); Z_OUT=$(mktemp)
trap 'rm -f "$C_OUT" "$Z_OUT"' EXIT

PASS=0; FAIL=0

diff_tokens() {
  local f="$1"
  "$ZIGOUT/u2_c_tok" "$f" > "$C_OUT"
  "$ZIGOUT/u2_z_tok" "$f" > "$Z_OUT"
  if cmp -s "$C_OUT" "$Z_OUT"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $f"
    diff "$C_OUT" "$Z_OUT" | head -20 | sed 's/^/    /'
  fi
}

# ─── stdin-mode fixtures: tests/cases/*.dhall ───────────────────────────────
while IFS= read -r f; do diff_tokens "$f"; done < <(find "$REPO_ROOT/tests/cases" -maxdepth 1 -name '*.dhall' -print | sort)

# ─── file-mode fixtures: tests/cases/imports/**/*.dhall ─────────────────────
while IFS= read -r f; do diff_tokens "$f"; done < <(find "$REPO_ROOT/tests/cases/imports" -name '*.dhall' -print | sort)

# ─── file-mode fixtures: examples/*.dhall ───────────────────────────────────
while IFS= read -r f; do diff_tokens "$f"; done < <(find "$REPO_ROOT/examples" -maxdepth 1 -name '*.dhall' -print | sort)

# ─── dhall-lang corpus (if vendored) ────────────────────────────────────────
if [ -d "$REPO_ROOT/vendor/dhall-lang/tests" ]; then
  while IFS= read -r f; do diff_tokens "$f"; done < <(find "$REPO_ROOT/vendor/dhall-lang/tests" -name '*.dhall' -print | sort)
fi

echo
echo "=== U2 lexer token-dump: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -ne 0 ]; then
  echo "DIFF FAILURES PRESENT"
  exit 1
fi
echo "ALL PASS"
