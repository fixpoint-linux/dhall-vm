# dhall-c → Zig migration (zig/)

This directory holds the Zig port of the dhall-c interpreter CORE + CLI.
It mirrors the proven `carrasco-forcada-poc/zig/` migration pattern: Zig-native
modules under `zig/src/` + a differential harness (`zig/dhall_diff.sh`) + a final
C-ABI export layer, so consumers link the Zig core with zero source changes.

## Layout (planned, filled in by U1+)

- `src/`        — Zig modules, one per C file in `../src/` (dhall.zig, arena.zig,
                  bignum.zig, sha256.zig, lexer.zig, builtins.zig, parser.zig,
                  ast.zig, normalize.zig, typecheck.zig, serialize.zig,
                  import.zig, ssrf.zig, http.zig, main.zig, abi.zig).
- `dhall_diff.sh` — differential harness (U0, green on C-vs-C before any Zig).
- `zig-out/`    — Zig build artifacts (`zig build-exe` / `build-lib` output).
                  Git-ignored.

## Gate

`bash zig/dhall_diff.sh` must print `ALL PASS`. With both `C_DRIVER` and
`ZIG_DRIVER` set to the C oracle (`./dhall.com.dbg`) it is the C-vs-C sanity
gate that proves the harness itself before the Zig engine exists. From U1 onward
`ZIG_DRIVER` defaults to the built Zig binary (`zig-out/bin/dhall`) and the same
script becomes the byte-identical differential gate (stdout + exit code +
stderr across the 5 CLI modes: typecheck, normalize, to-json, to-toml, to-yaml).
