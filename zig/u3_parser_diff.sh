#!/usr/bin/env bash
# u3_parser_diff.sh — U3 parse-dump twin-driver gate.
#
# Builds the C twin driver (a tiny main over src/parser.c + the C engine) and
# the Zig twin driver (over zig/src/parser.zig), then for every fixture in the
# corpora runs both and asserts byte-identical parse-dump S-expressions:
#     (TAG line:col ...)   for a successful parse
#     ERROR <stage> <line>:<col> <msg>   on parse error
# The S-expr includes de Bruijn indices (binder/name-resolution) and spans
# (tloc stamping), so the gate catches name-resolution mistakes before the
# normalizer exists.
#
# Corpora: tests/cases/*.dhall, tests/cases/imports/**/*.dhall, examples/*.dhall.
# (vendor/dhall-lang is not checked out in this tree; if present, a loop below
# covers it.)
#
# Gate: bash zig/u3_parser_diff.sh  →  ALL PASS
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
gcc -O2 -I "$REPO_ROOT/src" -o "$ZIGOUT/u3_c_dump" \
    "$REPO_ROOT/src/arena.c" "$REPO_ROOT/src/bignum.c" "$REPO_ROOT/src/ast.c" \
    "$REPO_ROOT/src/builtins.c" "$REPO_ROOT/src/lexer.c" "$REPO_ROOT/src/parser.c" \
    "$SCRIPT_DIR/u3_parse_dump.c" -lm
echo "building Zig twin driver..."
zig build-exe -O ReleaseSafe -lc \
    -femit-bin="$ZIGOUT/u3_z_dump" "$SCRIPT_DIR/src/parse_dump.zig"

C_OUT=$(mktemp); Z_OUT=$(mktemp)
trap 'rm -f "$C_OUT" "$Z_OUT"' EXIT

PASS=0; FAIL=0

diff_dump() {
  local f="$1"
  "$ZIGOUT/u3_c_dump" "$f" > "$C_OUT"
  local crc=$?
  "$ZIGOUT/u3_z_dump" "$f" > "$Z_OUT"
  local zrc=$?
  if [ "$crc" -ne "$zrc" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL(exit) $crc/$zrc: $f"
    return
  fi
  if cmp -s "$C_OUT" "$Z_OUT"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $f"
    diff "$C_OUT" "$Z_OUT" | head -20 | sed 's/^/    /'
  fi
}

# ─── stdin-mode fixtures: tests/cases/*.dhall ───────────────────────────────
while IFS= read -r f; do diff_dump "$f"; done < <(find "$REPO_ROOT/tests/cases" -maxdepth 1 -name '*.dhall' -print | sort)

# ─── file-mode fixtures: tests/cases/imports/**/*.dhall ─────────────────────
while IFS= read -r f; do diff_dump "$f"; done < <(find "$REPO_ROOT/tests/cases/imports" -name '*.dhall' -print | sort)

# ─── file-mode fixtures: examples/*.dhall ───────────────────────────────────
while IFS= read -r f; do diff_dump "$f"; done < <(find "$REPO_ROOT/examples" -maxdepth 1 -name '*.dhall' -print | sort)

# ─── dhall-lang corpus (if vendored) ────────────────────────────────────────
if [ -d "$REPO_ROOT/vendor/dhall-lang/tests" ]; then
  while IFS= read -r f; do diff_dump "$f"; done < <(find "$REPO_ROOT/vendor/dhall-lang/tests" -name '*.dhall' -print | sort)
fi

echo
echo "=== U3 parse-dump: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -ne 0 ]; then
  echo "DIFF FAILURES PRESENT"
  exit 1
fi
echo "ALL PASS"
