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
`2` parse/lex error, `3` internal/IO/JSON error. Type errors report
`Error: <msg> (at <file>:<line>:<col>)`.

## Language features

The supported subset (single-term de Bruijn core, eager normalization,
bidirectional typechecking) includes:

- **Scalars** — `Natural`, `Integer`, `Double`, `Bool`, `Text` literals
  (with `${}` interpolation).
- **Binders** — `let`, lambdas (`\(x : T) -> body`), `forall`/Pi,
  annotations (`e : T`), `if/then/else`.
- **Records** — record types `{ a : T }`, record literals `{ a = v }`,
  field access, `toMap`.
- **Lists** — `[a, b, c]`, `List/map`, `List/filter`, `List/reverse`,
  `List/fold`.
- **Unions** — `< A : T | B : U >` and `< A = v | B : U >`, `merge`.
- **Optionals** — `Optional T`, `Some x`, `None T`, `Optional/fold`.
- **Arithmetic** — `+ - *` and comparisons `== != < <= > >=` over
  `Natural`/`Integer`/`Double` (equality also over `Bool`/`Text`), plus
  `Natural/isZero`, `Natural/show`, `Natural/subtract`, `Natural/fold`.
- **Assertions** — `assert : body` where `body : Bool` and normalizes to
  `True`. Note: the assertion is enforced during `typecheck`; the
  `normalize` and `to-json` modes do not typecheck first, so `assert : False`
  there evaluates to `true` without an error (always typecheck first to rely
  on the guarantee).
- **Imports** — local file imports and `env:` imports (see below).

### Arithmetic semantics

- `+ - *` require both operands to be the same scalar type
  (`Natural`/`Integer`/`Double`); `==`/`!=` also accept `Bool`/`Text`.
  Comparisons (`< <= > >=`) accept `Natural`/`Integer`/`Double`.
- `Natural` subtraction **saturates** at `0` (`2 - 7 == 0`).
- `Natural` `+`/`*` overflow is a runtime error (detected during
  normalization); `Integer` `+ - *` overflow via built-in checked
  arithmetic. `Double` is IEEE 754 (JSON maps non-finite to `null`).
- Division is intentionally **not** supported (no `/` operator).
- Operator precedence (loosest to tightest): `->`, `:`, comparisons,
  `+ - ++`, `*`, application.
- `Natural/subtract a b` is `max (b - a) 0` — the argument order is the
  opposite of the `-` operator.
- `Natural/fold` is capped at `2^20` iterations (DoS guard).

### Optionals

`Optional T` is the type constructor; `Some x` has type `Optional T` where
`x : T`; `None T` has type `Optional T`. `Optional/fold` eliminates a value:

```
Optional/fold T value A some none
```

where `some : T -> A` and `none : A`. In JSON, `Some x` serializes as `x`
and `None T` as `null`.

### toMap

`toMap r` where `r : { a : V, b : V, ... }` produces
`List { mapKey : Text, mapValue : V }`, one element per record field in
sorted label order. All field values must share a common type (a type
error otherwise), and the record must be non-empty (a deliberate deviation
from Dhall, which needs polymorphism this subset lacks).

## Imports

Local file imports and environment-variable imports are supported:

```
./dep.dhall        # relative to the importing file's directory
../x.dhall
/abs/path.dhall
env:HOME           # the value of $HOME as a Text literal
```

- Imports are resolved and inlined **at parse time**; the imported
  expression is closed (it cannot reference binders from the importing
  file).
- Relative paths resolve against the directory of the importing file (the
  CWD for stdin input).
- Import **cycles** are detected and reported (`import cycle`).
- A per-canonical-path cache gives correct diamond-import sharing.
- Import chain depth is capped (`MAX_IMPORT_DEPTH`, 64) — deeper chains
  error instead of overflowing the C stack.
- **No network imports** (no URL/http/missing/sha256) — the interpreter is
  self-contained and portable.

## Normal forms round-trip via de Bruijn references

`normalize` prints de Bruijn-bound variables with synthetic names (`_0`, `_1`,
…). For example, `\(x : Natural) -> \(y : Natural) -> x` normalizes to
`\(_ : Natural) -> \(_ : Natural) -> _1`. The parser accepts `_N` (an
underscore followed only by decimal digits) as a de Bruijn-index reference, so
printed normal forms **do round-trip**: they can be re-parsed, type-checked, and
re-normalized to themselves (idempotent).

**Documented deviation:** `_N` (underscore + all-digits, e.g. `_1`) is reserved
as a de Bruijn reference, not an ordinary identifier. `_` alone and
`_foo`/`_1a` remain ordinary identifiers. N maps directly to the de Bruijn index
and is bounds-checked; an out-of-range or overflowing `_N` is a parse error
(`invalid de Bruijn index`).

`forall` is accepted in type positions (lambda parameter types, let
annotations, record/union field types), so higher-order normal forms — e.g.
`\(_ : forall (_ : Natural) -> Natural) -> _0` — also round-trip.

## Known limitation: stuck text interpolation

`normalize` and `to-json` modes reject interpolation of a **closed non-Text**
value (e.g. `"${1+2}"` or `"${True}"`) with `interpolation requires Text`. However,
a **stuck** interpolation whose value is a bound variable of type Text (e.g.
`\(x : Text) -> "${x}"`) is still silently dropped, producing `\(_ : Text) -> ""`.
This is a known limitation (a faithful fix would require preserving interpolated
sub-terms through normalization and printing them back as `"${_0}"`), and is
deliberately out of scope for this subset interpreter.

## Recursion depth

The recursive-descent parser enforces a maximum nesting depth
(`PARSE_MAX_DEPTH`, 1000) and reports a parse error rather than overflowing the
C stack on deeply nested adversarial input. Import chains are additionally
guarded by `MAX_IMPORT_DEPTH` (see Imports).
