#!/bin/sh
# Build the Dhall interpreter to wasm (emscripten), output to docs/.
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
EM_CONFIG="$EMCONF" "$EMCC" -O2 \
  -I src \
  -s MODULARIZE=1 \
  -s EXPORT_NAME=createDhall \
  -s EXPORTED_FUNCTIONS=_dhall_run,_dhall_out,_dhall_out_len,_malloc,_free \
  -s EXPORTED_RUNTIME_METHODS=ccall,cwrap,stringToUTF8,UTF8ToString,lengthBytesUTF8,HEAPU8 \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s TOTAL_STACK=5242880 \
  -o "$OUT/dhall.js" \
  src/wasm.c src/arena.c src/lexer.c src/parser.c src/ast.c \
  src/normalize.c src/typecheck.c src/builtins.c src/serialize.c \
  src/import.c src/bignum.c

mkdir -p docs
cp "$OUT/dhall.js" "$OUT/dhall.wasm" docs/ 2>/dev/null || cp "$OUT"/dhall.js "$OUT"/dhall.wasm docs/
rm -rf "$OUT" "$EMCONF"
ls -la docs/dhall.js docs/dhall.wasm
echo "built docs/dhall.js + docs/dhall.wasm"
