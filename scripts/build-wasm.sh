#!/bin/sh
# Build the Dhall interpreter AND the LSP server to wasm (emscripten), output to docs/.
# Requires: pacman -S emscripten clang lld llvm
#   (emscripten BUNDLES binaryen; do NOT also `pacman -S binaryen` — they conflict.)
set -euo pipefail
cd "$(dirname "$0")/.."

# emscripten's stock config points LLVM_ROOT=/opt/emscripten-llvm/bin, which no
# repo package provides; repoint at the system clang/lld/llvm (22.1.x).
EMCONF="$(mktemp)"
cat > "$EMCONF" <<'EOF'
import os
NODE_JS = '/usr/bin/node'
LLVM_ROOT = '/usr/bin'
BINARYEN_ROOT = '/usr'
EMSCRIPTEN_ROOT = '/usr/lib/emscripten'
CACHE = os.path.expanduser('~/.cache/emscripten')
EOF

EMCC=/usr/lib/emscripten/emcc
# Build to a temp dir, then copy into docs/. This matters on bind-mounted or
# root-owned checkouts where emscripten's shutil.move/copystat (preserving the
# temp file's owner/timestamps) hits EPERM; a plain `cp` only writes new files.
OUT="$(mktemp -d)"

# Flags shared by both modules + the interpreter core (no main.c / wasm.c / lsp.c).
COMMON="-O2 -I src -s MODULARIZE=1 -s ALLOW_MEMORY_GROWTH=1 -s TOTAL_STACK=5242880"
RUNTIME="-s EXPORTED_RUNTIME_METHODS=ccall,cwrap,stringToUTF8,UTF8ToString,lengthBytesUTF8,HEAPU8"
CORE="src/arena.c src/lexer.c src/parser.c src/ast.c src/normalize.c src/typecheck.c src/builtins.c src/serialize.c src/import.c src/bignum.c src/sha256.c src/http.c"

# (1) interpreter: src/wasm.c entry (dhall_run / dhall_out / dhall_out_len).
EM_CONFIG="$EMCONF" "$EMCC" $COMMON \
  -s EXPORT_NAME=createDhall \
  -s EXPORTED_FUNCTIONS=_dhall_run,_dhall_out,_dhall_out_len,_malloc,_free \
  $RUNTIME \
  -o "$OUT/dhall.js" \
  src/wasm.c $CORE

# (2) LSP server: src/lsp.c + src/json.c. -DLSP_NO_MAIN drops the stdio main();
# lsp_handle / lsp_out / lsp_out_len are the wasm entry surface.
EM_CONFIG="$EMCONF" "$EMCC" $COMMON -DLSP_NO_MAIN \
  -s EXPORT_NAME=createDhallLsp \
  -s EXPORTED_FUNCTIONS=_lsp_handle,_lsp_out,_lsp_out_len,_malloc,_free \
  $RUNTIME \
  -o "$OUT/dhall-lsp.js" \
  src/lsp.c src/json.c $CORE

mkdir -p docs
cp "$OUT/dhall.js" "$OUT/dhall.wasm" "$OUT/dhall-lsp.js" "$OUT/dhall-lsp.wasm" docs/ 2>/dev/null \
  || cp "$OUT"/dhall.js "$OUT"/dhall.wasm "$OUT"/dhall-lsp.js "$OUT"/dhall-lsp.wasm docs/
rm -rf "$OUT" "$EMCONF"
ls -la docs/dhall.js docs/dhall.wasm docs/dhall-lsp.js docs/dhall-lsp.wasm
echo "built docs/dhall.js + docs/dhall.wasm + docs/dhall-lsp.js + docs/dhall-lsp.wasm"
