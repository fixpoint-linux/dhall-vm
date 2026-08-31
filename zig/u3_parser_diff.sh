#!/usr/bin/env bash
# u3_parser_diff.sh — U3 parse-dump golden gate.
#
# Builds the Zig twin driver (a tiny main over zig/src/parser.zig) and for every
# fixture in the corpora asserts its parse-dump S-expression matches the recorded
# golden baseline in zig/golden/u3/:
#     (TAG line:col ...)   for a successful parse
#     ERROR <stage> <line>:<col> <msg>   on parse error
# The S-expr includes de Bruijn indices (binder/name-resolution) and spans
# (tloc stamping), so the gate catches name-resolution mistakes before the
# normalizer exists. The Zig port is the trusted implementation (byte-verified
# against the removed C oracle by the u3 differential before removal).
# RECORD_GOLDEN=1 regenerates the baselines; the corpora are fixed and the dump
# is deterministic, so the baselines are stable.
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
GOLDEN="$SCRIPT_DIR/golden/u3"
mkdir -p "$ZIGOUT" "$GOLDEN"

# ─── Zig cache dirs (sandbox) ───────────────────────────────────────────────
if [ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]; then export ZIG_GLOBAL_CACHE_DIR=/tmp/.zcache; fi
if [ -z "${ZIG_LOCAL_CACHE_DIR:-}" ];  then export ZIG_LOCAL_CACHE_DIR=/tmp/.zlcache;  fi
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

# ─── Build the Zig twin driver ──────────────────────────────────────────────
echo "building Zig twin driver..."
zig build-exe -O ReleaseSafe -lc \
    -femit-bin="$ZIGOUT/u3_z_dump" "$SCRIPT_DIR/src/parse_dump.zig"

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

PASS=0; FAIL=0

# check_one <relpath> — run the driver with cwd = repo root and the fixture's
# repo-relative path, then byte-compare stdout against zig/golden/u3/<relpath>.out
# (recording that golden first when RECORD_GOLDEN=1).
check_one() {
  local rel="$1"
  "$ZIGOUT/u3_z_dump" "$rel" > "$OUT"
  local golden="$GOLDEN/$rel.out"
  if [ "${RECORD_GOLDEN:-0}" = "1" ]; then
    mkdir -p "$(dirname "$golden")"
    cp "$OUT" "$golden"
    echo "recorded $rel"
    PASS=$((PASS + 1))
    return
  fi
  if cmp -s "$OUT" "$golden"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $rel"
    diff "$golden" "$OUT" | head -20 | sed 's/^/    /'
  fi
}

# Run every corpus with cwd = repo root and relative paths, so golden baselines
# are machine-independent (no absolute paths leak into the dump).
cd "$REPO_ROOT"

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
echo "=== U3 parse-dump: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -ne 0 ]; then
  echo "DIFF FAILURES PRESENT"
  exit 1
fi
echo "ALL PASS"
