#!/bin/sh
# Opt-in LIVE test for http:// URL imports (tests/url.sh).
#   usage: tests/url.sh [dhall-binary]
#
# NOT part of `dhake test` (the offline suite): it needs a real loopback socket
# and the DHALL_ALLOW_LOOPBACK=1 TEST-ONLY escape, which bypasses ONLY
# 127.0.0.0/8 and ::1 (every other private/link-local/reserved range stays
# blocked) — see src/ssrf.c. Serves a fixed body "42\n" over HTTP and verifies
# the interpreter fetches it, sha256-verifies it, and normalizes it, plus two
# negatives (hash mismatch, redirect-to-blocked). Gracefully SKIPs (exit 0) if
# it cannot bind a loopback port or no python3 is available.
set -u

BIN="${1:-./dhall.com.dbg}"
case "$BIN" in
    /*) : ;;
    *) BIN="$(cd "$(dirname "$0")/.." && pwd)/$BIN" ;;
esac

# fixed body (3 bytes) and its sha256 (same content as tests/cases/imports/hash-foo.dhall)
SHA=084c799cd551dd1d8d5c5f9a5d593b2e931f5e36122ee5c793c1d08a19839cc0

PORT=18999
PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
if [ -z "$PY" ]; then
    echo "SKIP url: no python3 (needed for the test HTTP server)"
    exit 0
fi

SRV=$(mktemp)
cat > "$SRV" <<'PYEOF'
import http.server, sys
BODY = b"42\n"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redir":
            self.send_response(302)
            self.send_header("Location", "http://169.254.169.254/x")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

"$PY" "$SRV" "$PORT" 2>/dev/null &
SRV_PID=$!
cleanup() { kill "$SRV_PID" 2>/dev/null; rm -f "$SRV" "$TMP"; }
TMP=$(mktemp)
trap cleanup EXIT INT TERM

# wait for the server (or detect bind failure)
ready=0
i=0
while [ "$i" -lt 25 ]; do
    if "$PY" -c "import socket,sys; s=socket.create_connection(('127.0.0.1',$PORT),0.2); s.close()" 2>/dev/null; then
        ready=1
        break
    fi
    if ! kill -0 "$SRV_PID" 2>/dev/null; then
        break
    fi
    i=$((i + 1))
    sleep 0.2
done
if [ "$ready" -ne 1 ]; then
    echo "SKIP url: cannot bind loopback port (no loopback network available)"
    exit 0
fi

fail=0

# 1) success: fetch + sha256-verify + normalize
out=$(printf 'http://127.0.0.1:%s/x.dhall sha256:%s\n' "$PORT" "$SHA" \
      | DHALL_ALLOW_LOOPBACK=1 "$BIN" normalize 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "42" ]; then
    echo "PASS url: fetch+sha256+normalize"
else
    echo "FAIL url: fetch+sha256+normalize (rc=$rc)"
    echo "$out"
    fail=1
fi

# 2) sha256 mismatch is a HARD error (not recoverable)
out=$(printf 'http://127.0.0.1:%s/x.dhall sha256:0000000000000000000000000000000000000000000000000000000000000000 ? 99\n' "$PORT" \
      | DHALL_ALLOW_LOOPBACK=1 "$BIN" normalize 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -F -q 'sha256 mismatch'; then
    echo "PASS url: sha256-mismatch hard error"
else
    echo "FAIL url: sha256-mismatch should be a hard error (rc=$rc)"
    echo "$out"
    fail=1
fi

# 3) redirect to a blocked (link-local) address is blocked, even with the escape
out=$(printf 'http://127.0.0.1:%s/redir sha256:%s\n' "$PORT" "$SHA" \
      | DHALL_ALLOW_LOOPBACK=1 "$BIN" normalize 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -F -q 'missing import'; then
    echo "PASS url: redirect-to-blocked rejected"
else
    echo "FAIL url: redirect-to-blocked should error (rc=$rc)"
    echo "$out"
    fail=1
fi

exit "$fail"
