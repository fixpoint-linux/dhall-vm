CC := cosmocc
CFLAGS := -std=c11 -O2 -g -Wall -Wextra
SRC := src/main.c src/arena.c src/lexer.c src/parser.c src/ast.c \
       src/normalize.c src/typecheck.c src/builtins.c src/json.c src/import.c
HDR := src/dhall.h

.PHONY: all test clean

all: dhall.com

dhall.com: $(SRC) $(HDR)
	$(CC) $(CFLAGS) -o dhall.com $(SRC)

test: all
	./tests/run.sh ./dhall.com.dbg && ./tests/roundtrip.sh ./dhall.com.dbg

clean:
	rm -f dhall.com dhall.com.dbg
