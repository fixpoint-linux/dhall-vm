#!/bin/sh
# CLI tests for the Dhall subset interpreter.
# usage: tests/cli.sh [dhall-binary]   (default: ./dhall.com.dbg)
#
# Asserts:
#   - --help and -h exit 0 and print a usage line containing 'Usage:' on stdout
#   - --version and -V exit 0 and print a line containing 'dhall-c' on stdout
#   - no arguments exits nonzero
#   - an unknown mode exits nonzero and prints 'unknown mode' on stderr
set -u
BIN="${1:-./dhall.com.dbg}"
case "$BIN" in
    /*) : ;;
    *) BIN="$(pwd)/$BIN" ;;
esac
cd "$(dirname "$0")" || exit 1

OUT=/tmp/dhall-cli-out.txt
ERR=/tmp/dhall-cli-err.txt
pass=0
fail=0

check() {
    name="$1"
    ok="$2"
    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1))
        echo "PASS $name"
    else
        fail=$((fail + 1))
        echo "FAIL $name"
    fi
}

# --help / -h : exit 0, stdout contains 'Usage:'
for flag in --help -h; do
    "$BIN" "$flag" >"$OUT" 2>"$ERR"
    rc=$?
    ok=1
    [ "$rc" -eq 0 ] || { echo "  $flag: expected exit 0, got $rc"; ok=0; }
    grep -q 'Usage:' "$OUT" || { echo "  $flag: stdout missing 'Usage:'"; ok=0; }
    check "help-$flag" "$ok"
done

# --version / -V : exit 0, stdout contains 'dhall-c'
for flag in --version -V; do
    "$BIN" "$flag" >"$OUT" 2>"$ERR"
    rc=$?
    ok=1
    [ "$rc" -eq 0 ] || { echo "  $flag: expected exit 0, got $rc"; ok=0; }
    grep -q 'dhall-c' "$OUT" || { echo "  $flag: stdout missing 'dhall-c'"; ok=0; }
    check "version-$flag" "$ok"
done

# no args : nonzero
"$BIN" >"$OUT" 2>"$ERR"
rc=$?
if [ "$rc" -eq 0 ]; then
    check "no-args-exits-nonzero" 0
else
    check "no-args-exits-nonzero" 1
fi

# unknown mode : nonzero + stderr contains 'unknown mode'
"$BIN" bogusmode >"$OUT" 2>"$ERR"
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  bogusmode: expected nonzero exit, got 0"; ok=0; }
grep -q 'unknown mode' "$ERR" || { echo "  bogusmode: stderr missing 'unknown mode'"; ok=0; }
check "bogusmode" "$ok"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
