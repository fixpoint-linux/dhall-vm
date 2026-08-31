# dhall-c Zig port (zig/)

This directory holds the Zig implementation of the dhall-c interpreter — the
**canonical** source. The original C oracle (`../src/*.c`) has been removed; the
Zig modules under `zig/src/` are the source of truth.

## Layout

- `src/`        — Zig modules (one per former C translation unit): `dhall.zig`,
                  `arena.zig`, `bignum.zig`, `sha256.zig`, `lexer.zig`,
                  `builtins.zig`, `parser.zig`, `ast.zig`, `normalize.zig`,
                  `typecheck.zig`, `serialize.zig`, `import.zig`, `ssrf.zig`,
                  `http.zig`, `main.zig` (CLI), `lsp.zig` + `lsp_json.zig`
                  (language server), `abi.zig` (C-ABI export layer → `libdhall.so`).
- `dhall_diff.sh` — interpreter CLI differential gate: byte-compares the Zig
                  binary (`zig-out/bin/dhall`) against the committed C oracle
                  (`../dhall.com.dbg`, kept as a prebuilt APE artifact) across the
                  typecheck/normalize/to-json/to-toml/to-yaml modes.
- `u2_lexer_diff.sh` / `u3_parser_diff.sh` / `u4_ast_diff.sh` — **golden/self**
                  gates: build only the Zig twin driver and byte-compare its
                  per-fixture output against a recorded baseline in `golden/`
                  (`RECORD_GOLDEN=1` regenerates). No C is compiled.
- `golden/`     — recorded golden baselines for the u2/u3/u4 harnesses (one
                  subdir each: `u2/`, `u3/`, `u4/`).
- `zig-out/`    — Zig build artifacts (`zig build-exe` / `build-lib` output).
                  Git-ignored.

## Gate

All green means the port is verified:

```
bash zig/dhall_diff.sh        # 1590/1590 interpreter differential (C APE oracle)
bash zig/u2_lexer_diff.sh     # ALL PASS golden token streams
bash zig/u3_parser_diff.sh    # ALL PASS golden parse dumps
bash zig/u4_ast_diff.sh       # ALL PASS golden de Bruijn + printer pipelines
bash tests/lsp.sh zig-out/bin/dhall-lsp   # 6/6 LSP
```
