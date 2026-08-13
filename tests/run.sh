#!/bin/sh
# test harness for the Dhall subset interpreter.
# usage: tests/run.sh [dhall-binary]   (default: ./dhall.com.dbg)
#
# For each tests/cases/*.dhall:
#   - typecheck is always run.
#       *.expected.err   -> must FAIL (exit != 0) and stderr must contain this text
#       (no *.expected.err) -> must SUCCEED (exit 0)
#   - *.expected.nf      -> normalize must succeed and stdout must match
#   - *.expected.json    -> to-json must succeed and stdout must match
#   - *.expected.jsonerr -> to-json must FAIL and stderr must contain this text
set -u
BIN="${1:-./dhall.com.dbg}"
case "$BIN" in
    /*) : ;;
    *) BIN="$(pwd)/$BIN" ;;
esac
cd "$(dirname "$0")" || exit 1

OUT=/tmp/dhall-test-out.txt
ERR=/tmp/dhall-test-err.txt
pass=0
fail=0

for f in cases/*.dhall; do
    [ -e "$f" ] || continue
    base="${f%.dhall}"
    name="$(basename "$base")"
    ok=1

    "$BIN" typecheck < "$f" >"$OUT" 2>"$ERR"
    rc=$?
    if [ -f "$base.expected.err" ]; then
        want="$(cat "$base.expected.err")"
        if [ "$rc" -eq 0 ]; then
            echo "FAIL $name: typecheck should have failed"
            ok=0
        elif ! grep -F -q "$want" "$ERR"; then
            echo "FAIL $name: typecheck error message mismatch (want: $want)"
            cat "$ERR"
            ok=0
        fi
    else
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: typecheck failed (rc=$rc)"
            cat "$ERR"
            ok=0
        fi
    fi

    if [ -f "$base.expected.nf" ]; then
        "$BIN" normalize < "$f" >"$OUT" 2>"$ERR"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: normalize failed"
            cat "$ERR"
            ok=0
        elif ! cmp -s "$OUT" "$base.expected.nf"; then
            echo "FAIL $name: normalize output mismatch"
            diff "$base.expected.nf" "$OUT"
            ok=0
        fi
    fi

    if [ -f "$base.expected.json" ]; then
        "$BIN" to-json < "$f" >"$OUT" 2>"$ERR"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: to-json failed"
            cat "$ERR"
            ok=0
        elif ! cmp -s "$OUT" "$base.expected.json"; then
            echo "FAIL $name: to-json output mismatch"
            diff "$base.expected.json" "$OUT"
            ok=0
        fi
    fi

    if [ -f "$base.expected.jsonerr" ]; then
        "$BIN" to-json < "$f" >"$OUT" 2>"$ERR"
        rc=$?
        want="$(cat "$base.expected.jsonerr")"
        if [ "$rc" -eq 0 ]; then
            echo "FAIL $name: to-json should have failed"
            ok=0
        elif ! grep -F -q "$want" "$ERR"; then
            echo "FAIL $name: to-json error mismatch (want: $want)"
            cat "$ERR"
            ok=0
        fi
    fi

    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1))
        echo "PASS $name"
    else
        fail=$((fail + 1))
    fi
done

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
