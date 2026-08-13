# dhall-c

A subset interpreter for the Dhall configuration language, written in C.

## Build

```
make            # produces dhall.com (APE) + dhall.com.dbg (ELF)
make test       # runs the test suite
```

Requires `cosmocc` (Cosmopolitan toolchain).

## Usage

```
dhall typecheck [file|-]   # infer the type of an expression
dhall normalize [file|-]   # print the normal form
dhall to-json   [file|-]   # evaluate to JSON
```

Input is read from a file or stdin. Exit codes: `0` ok, `1` type error,
`2` parse/lex error, `3` internal/IO/JSON error.

## Known limitation: lambda normal forms do not round-trip

`normalize` prints de Bruijn-bound variables with synthetic names (`_0`, `_1`,
…). For example, `\\(x : Natural) -> \\(y : Natural) -> x` normalizes to
`\\(_ : Natural) -> \\(_ : Natural) -> _1`. The synthetic `_0`/`_1` names are
**not** legal Dhall identifiers, so re-parsing this output fails with an
"unbound variable" error.

This is a cosmetic limitation of the CLI output: the printed form is a faithful
normal form (correct, capture-avoiding, type-preserving), but it is intended for
human inspection rather than round-tripping. Fully-qualified names could be
restored by tracking the original binder names during normalization, but that is
deliberately out of scope for this subset interpreter.

## Recursion depth

The recursive-descent parser enforces a maximum nesting depth
(`PARSE_MAX_DEPTH`, 1000) and reports a parse error rather than overflowing the
C stack on deeply nested adversarial input.
