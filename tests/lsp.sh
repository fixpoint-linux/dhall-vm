#!/bin/sh
# LSP end-to-end test for the Dhall subset interpreter's language server.
# usage: tests/lsp.sh [dhall-lsp-binary]   (default: ./dhall-lsp.com.dbg)
set -u
BIN="${1:-./dhall-lsp.com.dbg}"
case "$BIN" in
    /*) : ;;
    *) BIN="$(pwd)/$BIN" ;;
esac
cd "$(dirname "$0")" || exit 1

OUT=/tmp/dhall-lsp-out.txt
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

# send <json>  — emit one Content-Length-framed message (ASCII JSON, no newline)
send() {
    msg="$1"
    n=${#msg}
    printf 'Content-Length: %d\r\n\r\n%s' "$n" "$msg"
}

{
    send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    send '{"jsonrpc":"2.0","method":"initialized","params":{}}'
    # a.dhall: Natural + Text type error at line 1 col 3 -> 0-based line 0 char 2
    send '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/a.dhall","languageId":"dhall","version":1,"text":"1 + \"x\""}}}'
    send '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/a.dhall"},"position":{"line":0,"character":0}}}'
    # b.dhall: valid; hover should return Natural
    send '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/b.dhall","languageId":"dhall","version":1,"text":"1 + 2"}}}'
    send '{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/b.dhall"},"position":{"line":0,"character":0}}}'
    send '{"jsonrpc":"2.0","id":4,"method":"shutdown"}'
    send '{"jsonrpc":"2.0","method":"exit"}'
} | "$BIN" > "$OUT"
rc=$?

ok=1
grep -q '"hoverProvider":true' "$OUT"     || { echo "  missing hoverProvider"; ok=0; }
grep -q '"textDocumentSync":1' "$OUT"     || { echo "  missing textDocumentSync"; ok=0; }
check "initialize-capabilities" "$ok"

ok=1
grep -q '"character":2}' "$OUT"                       || { echo "  missing 0-based range"; ok=0; }
grep -q '"message":"operands of different types"' "$OUT" || { echo "  missing type-error message"; ok=0; }
check "diagnostic-range-and-message" "$ok"

ok=1
grep -q '"uri":"file:///tmp/b.dhall","diagnostics":\[\]' "$OUT" || { echo "  missing empty diagnostics"; ok=0; }
check "valid-doc-empty-diagnostics" "$ok"

ok=1
grep -q '"value":"Natural"' "$OUT" || { echo "  missing hover type"; ok=0; }
check "hover-type" "$ok"

ok=1
grep -q '"id":2,"result":null' "$OUT" || { echo "  missing null hover result"; ok=0; }
check "hover-null-on-error" "$ok"

if [ "$rc" -eq 0 ]; then
    check "shutdown-exit-code-0" 1
else
    echo "  exit code was $rc"
    check "shutdown-exit-code-0" 0
fi

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
