#!/bin/sh
# round-trip test for lambda normal forms.
# usage: tests/roundtrip.sh [dhall-binary]   (default: ./dhall.com.dbg)
#
# For each lambda term (fed via stdin):
#   nf1 = normalize(term)        must exit 0
#   nf2 = normalize(nf1)         must exit 0 (nf1 re-parses)
#   typecheck(nf1)               must exit 0 (nf1 is well-typed / re-parses)
#   assert nf1 == nf2            (idempotence)
set -u
BIN="${1:-./dhall.com.dbg}"
case "$BIN" in
    /*) : ;;
    *) BIN="$(pwd)/$BIN" ;;
esac
cd "$(dirname "$0")" || exit 1

OUT1=/tmp/dhall-roundtrip-1.txt
OUT2=/tmp/dhall-roundtrip-2.txt
ERR=/tmp/dhall-roundtrip-err.txt
pass=0
fail=0

check_one() {
    name="$1"
    term="$2"
    ok=1
    printf '%s\n' "$term" | "$BIN" normalize >"$OUT1" 2>"$ERR"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $name: normalize(term) failed (rc=$rc)"
        cat "$ERR"
        ok=0
    else
        # typecheck the normal form (must re-parse and be well-typed)
        printf '%s\n' "$(cat "$OUT1")" | "$BIN" typecheck >/dev/null 2>"$ERR"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: typecheck(nf) failed (rc=$rc)"
            cat "$ERR"
            ok=0
        fi
        # re-normalize the normal form (must re-parse)
        printf '%s\n' "$(cat "$OUT1")" | "$BIN" normalize >"$OUT2" 2>"$ERR"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: normalize(nf) failed (rc=$rc)"
            cat "$ERR"
            ok=0
        elif ! cmp -s "$OUT1" "$OUT2"; then
            echo "FAIL $name: normal form not idempotent"
            diff "$OUT1" "$OUT2"
            ok=0
        fi
    fi
    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1))
        echo "PASS $name"
    else
        fail=$((fail + 1))
    fi
}

check_one curried-id     '\(x : Natural) -> \(y : Natural) -> x'
check_one single-lambda  '\(x : Natural) -> x'
check_one higher-order   '\(f : Natural -> Natural) -> f'
check_one let-lambda     'let f = \(x : Natural) -> x in f'
check_one nested-3       '\(a : Natural) -> \(b : Natural) -> \(c : Natural) -> b'
check_one lambda-under-ann '\(x : Natural) -> \(y : Natural) -> y'
check_one stuck-interp       '\(x : Text) -> "${x}"'
check_one stuck-interp-mixed '\(x : Text) -> "a${x}b"'
check_one stuck-interp-multi '\(x : Text) -> \(y : Text) -> "a${x}b${y}c"'
check_one dbl-rt-lossy 'Double/show 0.123456789'
check_one dbl-rt-sum    '0.1 + 0.2'

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
