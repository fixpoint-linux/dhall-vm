#!/bin/sh
# test harness for the Dhall subset interpreter.
# usage: tests/run.sh [dhall-binary]   (default: ./dhall.com.dbg)
#
# For each tests/cases/*.dhall (stdin mode) and tests/cases/imports/*.dhall
# (file mode, so relative imports resolve against the fixture dir):
#   - typecheck is always run.
#       *.expected.err   -> must FAIL (exit != 0) and stderr must contain this text
#       (no *.expected.err) -> must SUCCEED (exit 0)
#   - *.expected.nf      -> normalize must succeed and stdout must match
#   - *.expected.nerr    -> normalize must FAIL and stderr must contain this text
#   - *.expected.json    -> to-json must succeed and stdout must match
#   - *.expected.jsonerr -> to-json must FAIL and stderr must contain this text
#   - *.expected.toml    -> to-toml must succeed and stdout must match
#   - *.expected.tomlerr -> to-toml must FAIL and stderr must contain this text
#   - *.expected.yaml    -> to-yaml must succeed and stdout must match
#   - *.expected.yamlerr -> to-yaml must FAIL and stderr must contain this text
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

# env value fixture for env: imports
export DHALL_TEST_ENV=hello-world

# check_one <file> <mode>   where mode = stdin | file
check_one() {
    f="$1"
    mode="$2"
    base="${f%.dhall}"
    name="$(basename "$base")"
    ok=1

    if [ "$mode" = file ]; then
        "$BIN" typecheck "$f" >"$OUT" 2>"$ERR"
    else
        "$BIN" typecheck < "$f" >"$OUT" 2>"$ERR"
    fi
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
        if [ "$mode" = file ]; then
            "$BIN" normalize "$f" >"$OUT" 2>"$ERR"
        else
            "$BIN" normalize < "$f" >"$OUT" 2>"$ERR"
        fi
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

    if [ -f "$base.expected.nerr" ]; then
        if [ "$mode" = file ]; then
            "$BIN" normalize "$f" >"$OUT" 2>"$ERR"
        else
            "$BIN" normalize < "$f" >"$OUT" 2>"$ERR"
        fi
        rc=$?
        want="$(cat "$base.expected.nerr")"
        if [ "$rc" -eq 0 ]; then
            echo "FAIL $name: normalize should have failed"
            ok=0
        elif ! grep -F -q "$want" "$ERR"; then
            echo "FAIL $name: normalize error mismatch (want: $want)"
            cat "$ERR"
            ok=0
        fi
    fi

    if [ -f "$base.expected.json" ]; then
        if [ "$mode" = file ]; then
            "$BIN" to-json "$f" >"$OUT" 2>"$ERR"
        else
            "$BIN" to-json < "$f" >"$OUT" 2>"$ERR"
        fi
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
        if [ "$mode" = file ]; then
            "$BIN" to-json "$f" >"$OUT" 2>"$ERR"
        else
            "$BIN" to-json < "$f" >"$OUT" 2>"$ERR"
        fi
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

    if [ -f "$base.expected.toml" ]; then
        if [ "$mode" = file ]; then
            "$BIN" to-toml "$f" >"$OUT" 2>"$ERR"
        else
            "$BIN" to-toml < "$f" >"$OUT" 2>"$ERR"
        fi
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: to-toml failed"
            cat "$ERR"
            ok=0
        elif ! cmp -s "$OUT" "$base.expected.toml"; then
            echo "FAIL $name: to-toml output mismatch"
            diff "$base.expected.toml" "$OUT"
            ok=0
        fi
    fi

    if [ -f "$base.expected.tomlerr" ]; then
        if [ "$mode" = file ]; then
            "$BIN" to-toml "$f" >"$OUT" 2>"$ERR"
        else
            "$BIN" to-toml < "$f" >"$OUT" 2>"$ERR"
        fi
        rc=$?
        want="$(cat "$base.expected.tomlerr")"
        if [ "$rc" -eq 0 ]; then
            echo "FAIL $name: to-toml should have failed"
            ok=0
        elif ! grep -F -q "$want" "$ERR"; then
            echo "FAIL $name: to-toml error mismatch (want: $want)"
            cat "$ERR"
            ok=0
        fi
    fi

    if [ -f "$base.expected.yaml" ]; then
        if [ "$mode" = file ]; then
            "$BIN" to-yaml "$f" >"$OUT" 2>"$ERR"
        else
            "$BIN" to-yaml < "$f" >"$OUT" 2>"$ERR"
        fi
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL $name: to-yaml failed"
            cat "$ERR"
            ok=0
        elif ! cmp -s "$OUT" "$base.expected.yaml"; then
            echo "FAIL $name: to-yaml output mismatch"
            diff "$base.expected.yaml" "$OUT"
            ok=0
        fi
    fi

    if [ -f "$base.expected.yamlerr" ]; then
        if [ "$mode" = file ]; then
            "$BIN" to-yaml "$f" >"$OUT" 2>"$ERR"
        else
            "$BIN" to-yaml < "$f" >"$OUT" 2>"$ERR"
        fi
        rc=$?
        want="$(cat "$base.expected.yamlerr")"
        if [ "$rc" -eq 0 ]; then
            echo "FAIL $name: to-yaml should have failed"
            ok=0
        elif ! grep -F -q "$want" "$ERR"; then
            echo "FAIL $name: to-yaml error mismatch (want: $want)"
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
}

for f in cases/*.dhall; do
    [ -e "$f" ] || continue
    check_one "$f" stdin
done

for f in cases/imports/*.dhall cases/imports/*/*.dhall; do
    [ -e "$f" ] || continue
    check_one "$f" file
done

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
