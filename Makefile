CC := cosmocc
CFLAGS := -std=c11 -O2 -g -Wall -Wextra
SRC := src/main.c src/arena.c src/lexer.c src/parser.c src/ast.c \
       src/normalize.c src/typecheck.c src/builtins.c src/serialize.c src/import.c \
       src/bignum.c src/sha256.c
# bench links every .c EXCEPT main.c (it has its own main).
BENCH_SRC := src/bench.c src/arena.c src/lexer.c src/parser.c src/ast.c \
             src/normalize.c src/typecheck.c src/builtins.c src/serialize.c src/import.c \
             src/bignum.c src/sha256.c
HDR := src/dhall.h

.PHONY: all test bench clean wasm

all: dhall.com

dhall.com: $(SRC) $(HDR)
	$(CC) $(CFLAGS) -o dhall.com $(SRC)

bench: bench.com
	./bench.com.dbg

bench.com: $(BENCH_SRC) $(HDR)
	$(CC) $(CFLAGS) -o bench.com $(BENCH_SRC)

# Build the interpreter to wasm (emscripten) for the GitHub Pages demo in docs/.
# Requires: pacman -S emscripten clang lld llvm  (see scripts/build-wasm.sh).
# docs/dhall.js + docs/dhall.wasm are committed site assets (Pages serves them
# with zero CI), so they are NOT removed by `make clean`.
wasm:
	./scripts/build-wasm.sh
	@node tests/wasm-smoke.js

test: all
	./tests/run.sh ./dhall.com.dbg && ./tests/roundtrip.sh ./dhall.com.dbg && ./tests/examples.sh ./dhall.com.dbg && ./tests/cli.sh ./dhall.com.dbg

clean:
	rm -f dhall.com dhall.com.dbg bench.com bench.com.dbg dhall.aarch64.elf bench.aarch64.elf
