#!/bin/sh
# example smoke tests for the Dhall subset interpreter.
# usage: tests/examples.sh [dhall-binary]   (default: ./dhall.com.dbg)
#
# For each examples/*.dhall (passed by path, cwd = repo root so no
# relative ./ imports can break; env: imports need no cwd):
#   - typecheck MUST exit 0 (every example must typecheck)
#   - normalize  MUST exit 0; if examples/<name>.expected.nf exists,
#     stdout must match it
#   - to-json / to-toml / to-yaml: if examples/<name>.expected.json/.toml/.yaml
#     exists, exit 0 AND stdout must match the snapshot; otherwise skipped.
set -u
BIN="${1:-./dhall.com.dbg}"
case "$BIN" in
    /*) : ;;
    *) BIN="$(pwd)/$BIN" ;;
esac
cd "$(dirname "$0")/.." || exit 1   # repo root

OUT=/tmp/dhall-examples-out.txt
ERR=/tmp/dhall-examples-err.txt
pass=0
fail=0

check_one() {
    f="$1"
    base="${f%.dhall}"
    name="$(basename "$base")"
    ok=1

    "$BIN" typecheck "$f" >"$OUT" 2>"$ERR"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $name: typecheck failed (rc=$rc)"
        cat "$ERR"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        "$BIN" normalize "$f" >"$OUT" 2>"$ERR"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: normalize failed (rc=$rc)"
            cat "$ERR"
            ok=0
        elif [ -f "$base.expected.nf" ] && ! cmp -s "$OUT" "$base.expected.nf"; then
            echo "FAIL $name: normalize output mismatch"
            diff "$base.expected.nf" "$OUT"
            ok=0
        fi
    fi

    if [ "$ok" -eq 1 ] && [ -f "$base.expected.json" ]; then
        "$BIN" to-json "$f" >"$OUT" 2>"$ERR"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: to-json failed (rc=$rc)"
            cat "$ERR"
            ok=0
        elif ! cmp -s "$OUT" "$base.expected.json"; then
            echo "FAIL $name: to-json output mismatch"
            diff "$base.expected.json" "$OUT"
            ok=0
        fi
    fi

    if [ "$ok" -eq 1 ] && [ -f "$base.expected.toml" ]; then
        "$BIN" to-toml "$f" >"$OUT" 2>"$ERR"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: to-toml failed (rc=$rc)"
            cat "$ERR"
            ok=0
        elif ! cmp -s "$OUT" "$base.expected.toml"; then
            echo "FAIL $name: to-toml output mismatch"
            diff "$base.expected.toml" "$OUT"
            ok=0
        fi
    fi

    if [ "$ok" -eq 1 ] && [ -f "$base.expected.yaml" ]; then
        "$BIN" to-yaml "$f" >"$OUT" 2>"$ERR"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: to-yaml failed (rc=$rc)"
            cat "$ERR"
            ok=0
        elif ! cmp -s "$OUT" "$base.expected.yaml"; then
            echo "FAIL $name: to-yaml output mismatch"
            diff "$base.expected.yaml" "$OUT"
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

for f in examples/*.dhall; do
    [ -e "$f" ] || continue
    check_one "$f"
done

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
