CC := cosmocc
CFLAGS := -std=c11 -O2 -g -Wall -Wextra
SRC := src/main.c src/arena.c src/lexer.c src/parser.c src/ast.c \
       src/normalize.c src/typecheck.c src/builtins.c src/serialize.c src/import.c \
       src/bignum.c src/sha256.c src/ssrf.c src/http.c
# bench links every .c EXCEPT main.c (it has its own main).
BENCH_SRC := src/bench.c src/arena.c src/lexer.c src/parser.c src/ast.c \
             src/normalize.c src/typecheck.c src/builtins.c src/serialize.c src/import.c \
             src/bignum.c src/sha256.c src/ssrf.c src/http.c
# LSP server: links the interpreter core (no main.c, which has its own main)
# plus the JSON-RPC layer (json.c) and the LSP loop (lsp.c).
LSP_SRC := src/lsp.c src/json.c src/arena.c src/lexer.c src/parser.c src/ast.c \
           src/normalize.c src/typecheck.c src/builtins.c src/serialize.c src/import.c \
           src/bignum.c src/sha256.c src/ssrf.c src/http.c
HDR := src/dhall.h src/ssrf.h src/json.h

.PHONY: all test bench clean wasm test-ssrf lsp test-lsp

all: dhall.com

dhall.com: $(SRC) $(HDR)
	$(CC) $(CFLAGS) -o dhall.com $(SRC)

bench: bench.com
	./bench.com.dbg

bench.com: $(BENCH_SRC) $(HDR)
	$(CC) $(CFLAGS) -o bench.com $(BENCH_SRC)

lsp: dhall-lsp.com

dhall-lsp.com: $(LSP_SRC) $(HDR)
	$(CC) $(CFLAGS) -o dhall-lsp.com $(LSP_SRC)

test-lsp: dhall-lsp.com
	./tests/lsp.sh ./dhall-lsp.com.dbg

# Build the interpreter to wasm (emscripten) for the GitHub Pages demo in docs/.
# Requires: pacman -S emscripten clang lld llvm  (see scripts/build-wasm.sh).
# docs/dhall.js + docs/dhall.wasm are committed site assets (Pages serves them
# with zero CI), so they are NOT removed by `make clean`.
wasm:
	./scripts/build-wasm.sh
	@node tests/wasm-smoke.js
	@node tests/lsp-wasm-smoke.js

# Offline unit test for the SSRF classifier + url_parse (src/ssrf.c). This is
# the security crux: 36 classification vectors + url_parse vectors, deterministic
# and network-free. Compiled with cosmocc, run, assert exit 0.
test-ssrf: tests/ssrf_test.c src/ssrf.c src/ssrf.h
	$(CC) $(CFLAGS) -I src -o /tmp/ssrf_test tests/ssrf_test.c src/ssrf.c
	/tmp/ssrf_test

test: all test-ssrf test-lsp
	./tests/run.sh ./dhall.com.dbg && ./tests/roundtrip.sh ./dhall.com.dbg && ./tests/examples.sh ./dhall.com.dbg && ./tests/cli.sh ./dhall.com.dbg

clean:
	rm -f dhall.com dhall.com.dbg bench.com bench.com.dbg dhall.aarch64.elf bench.aarch64.elf dhall-lsp.com dhall-lsp.com.dbg dhall-lsp.aarch64.elf /tmp/ssrf_test /tmp/ssrf_test.dbg
