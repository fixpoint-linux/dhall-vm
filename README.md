# dhall-c

A subset interpreter for the Dhall configuration language, written in C.

## Build

The build is driven by **dhake**, a Make-like build tool whose buildfile
(`Dhakefile.dhall`) is written in Dhall. Run it from the project root:

```
dhake           # produces dhall.com (APE) + dhall.com.dbg (ELF)
dhake test      # runs the test suite (run.sh + roundtrip.sh + examples.sh + cli.sh)
dhake bench     # builds and runs the in-process benchmark (src/bench.c)
dhake --list    # list all targets
```

Requires `cosmocc` (Cosmopolitan toolchain) and the `dhake` binary on `$PATH`.

### Verified builds

Every compile target in `Dhakefile.dhall` pins two kinds of sha256 hashes (dhake's
verified-build feature, see `dhake --help` / README "Verified builds"):

- **`hash`** — the expected hash of the *output* binary. The cosmocc APE output is
  deterministic (same toolchain + sources + flags ⇒ identical bytes), so this pin is
  sound; dhake re-checks it on every build (including up-to-date runs), catching a
  tampered binary.
- **`depsHash`** — the expected hash of each *source* dependency, verified *before*
  building, catching a modified source.

If a pinned hash goes stale (you edit a source or bump the toolchain), the build
fails with the expected-vs-actual mismatch. Rebuild with `dhake --warn-hash-mismatch`
to print the actual hashes (in copy-pasteable `sha256:<hex>` form) and copy them into
`Dhakefile.dhall`.

## Usage

```
dhall typecheck [file|-]   # infer the type of an expression
dhall normalize [file|-]   # print the normal form
dhall to-json   [file|-]   # evaluate to JSON
dhall to-toml   [file|-]   # evaluate to TOML (top level must be a record)
dhall to-yaml   [file|-]   # evaluate to YAML (block style, 1.2 core schema)
dhall --help | -h          # print usage and exit 0
dhall --version | -V       # print the version and exit 0
```

Input is read from a file or stdin. Exit codes: `0` ok, `1` type error,
`2` parse/lex error, `3` internal/IO/serialize error. Type errors report
`Error: <msg> (at <file>:<line>:<col>)`.

### Examples

The `examples/` directory contains four self-contained (no relative-file
import) example configuration files, each with a header comment showing the
expected output. `dhake test` runs `tests/examples.sh`, which typechecks every
example and pins the serialized output against `examples/<name>.expected.*`
snapshots, so the docs can never drift from the implementation:

- `server.dhall` — a server config (nested record, Text union with a payload,
  `List Text`, scalars).
- `ci.dhall` — a CI pipeline config (`let`-bound shared step lists, a `merge`
  over a union, a list of records).
- `env-config.dhall` — `env:` imports; type-check only (the value of `$HOME`
  is host-specific, so no output snapshot).
- `types.dhall` — a tour of value types (record type annotation, `Some`/`None`
  optionals, arithmetic, comparisons, `merge`, `List/map`).

Run them directly, e.g.:

```
dhall typecheck examples/server.dhall
dhall to-json examples/server.dhall
```

### Benchmark

`dhake bench` builds and runs an in-process benchmark (`src/bench.c`) that
times the interpreter pipeline over a representative source string (~20-field
nested record, a 200-element list, a `let`/lambda, and a `merge`), printing a
table of `parse`, `parse+normalize`, `+infer_type`, and `+term_to_json`
phases with derived per-phase ns/op. It is a measurement tool, not a
correctness check, and is deliberately **not** part of `dhake all` or
`dhake test` (timing is nondeterministic). Note that `bench.c` links the
internal API and tracks `dhall.h`, so an API change may require a rebuild of
`dhake bench`.

### In-browser (WebAssembly) demo

The interpreter is also compiled to **WebAssembly** and shipped as a static
GitHub Pages site under `docs/` (the interpreter runs 100% client-side — your
code never leaves the browser). Build it with:

```
dhake wasm      # scripts/build-wasm.sh → docs/dhall.js + docs/dhall.wasm
node tests/wasm-smoke.js   # headless browser-API smoke test (run by `dhake wasm`)
node tests/wasm-fetch.js   # opt-in URL-import fetch test (needs a loopback socket)
```

`dhake wasm` needs `emscripten clang lld llvm` (on Arch: `pacman -S emscripten
clang lld llvm`; see `scripts/build-wasm.sh` for the exact install/config
quirks). The built `docs/dhall.js` + `docs/dhall.wasm` are committed. A GitHub
Actions workflow (`.github/workflows/pages.yml`) deploys `docs/` to GitHub Pages
on every push to `master`; enable it once via Settings → Pages → Source →
**GitHub Actions** (no branch config or extra toolchain needed in CI). The site
(`docs/index.html`) typechecks, normalizes, and serializes (JSON/TOML/YAML)
Dhall expressions in a textarea, and loads the `examples/*.dhall` files.
`src/wasm.c` provides the browser-callable entry point and is deliberately kept
out of the native cosmocc build (`Dhakefile.dhall` `core`).

## Language Server

A Language Server Protocol (LSP) server (`dhall-lsp.com`) gives editors live
diagnostics and hover types. It speaks JSON-RPC 2.0 over stdio with
Content-Length framing, reusing the interpreter core (`parse_source` /
`infer_type` / `normalize`) for everything it reports.

```
dhake dhall-lsp.com        # produces dhall-lsp.com (APE) + dhall-lsp.com.dbg (ELF)
dhake test-lsp             # runs tests/lsp.sh (6 end-to-end checks)
```

Point your editor's LSP client at the `.dbg` binary (plain static ELF, no APE
loader needed) with the `dhall` filetype, e.g. for Neovim's `vim.lsp.start`:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "dhall",
  callback = function()
    vim.lsp.start({
      name = "dhall-lsp",
      cmd = { vim.fn.getcwd() .. "/dhall-lsp.com.dbg" },
    })
  end,
})
```

**Supported:** diagnostics-as-you-type (parse errors, type errors, and
normalize errors, with the span mapped to a 0-based LSP range) and hover (the
whole document's normalized type, rendered as Dhall).

**Limitations:** hover reports the whole-document type only (sub-expression
hover is not yet implemented); documents use full sync (`didOpen`/`didChange`
send the entire text); no completion yet; `file://` URIs are not
percent-decoded (paths with spaces are unsupported).

## Language features

The supported subset (single-term de Bruijn core, eager normalization,
bidirectional typechecking) includes:

- **Scalars** — `Natural`, `Integer`, `Double`, `Bool`, `Text` literals
  (with `${}` interpolation).
- **Binders** — `let`, lambdas (`\(x : T) -> body`), `forall`/Pi,
  annotations (`e : T`), `if/then/else`.
- **Records** — record types `{ a : T }`, record literals `{ a = v }`,
  field access, `toMap`, recursive record merge (`/\`), right-biased merge
  (`//`), and `with` record update.
- **Lists** — `[a, b, c]`, list append (`#`), `List/map`, `List/filter`,
  `List/reverse`, `List/fold`, `List/build`, `List/length`, `List/head`,
  `List/last`, `List/indexed`.
- **Unions** — `< A : T | B : U >` and `< A = v | B : U >`, `merge`.
- **Optionals** — `Optional T`, `Some x`, `None T`, `Optional/fold`.
- **Arithmetic** — `+ - *`, boolean logic (`&&`, `||`), and comparisons
  `== != < <= > >=` over `Natural`/`Integer`/`Double` (equality also over
  `Bool`/`Text`), plus `Natural/isZero`, `Natural/show`, `Natural/subtract`,
  `Natural/fold`, `Natural/build`, `Natural/even`, `Natural/odd`, `Natural/toInteger`,
  `Integer/toDouble`, `Integer/negate`, `Integer/show`, `Integer/clamp`,
  `Double/show`, `Text/show`, `Text/replace`.
- **Assertions** — `assert : body` where `body : Bool` normalizes to `True`.
  The assertion is **enforced in every mode**: `typecheck`, `normalize`, and the
  serializers (`to-json`/`to-toml`/`to-yaml`) all reject `assert : False`
  (or a stuck, non-`True` body) with `assertion did not hold`.
- **Serializers** — one evaluated value tree renders the same expression to
  **JSON**, **TOML** (top level must be a record), or **YAML** (block style, 1.2
  core schema), reusing a single shared value representation.
- **Imports** — local file imports, `env:` imports, and `http://` URL imports
  (see below).

### Multiline strings and Unicode operators

- **Multiline `Text`** literals use two single quotes (Dhall `'' ... ''` —
  *not* `"""` and *not* `'''`): an opening `''`, a mandatory newline, the
  content, and a closing `''`. They desugar to ordinary double-quoted `Text`
  at parse time, with standard-Dhall indentation stripping (longest common
  space/tab prefix over all non-blank lines plus the last line), `'''` →
  `''` and `''${` → `${` escaping, real `${}` interpolation, and `\r\n` →
  `\n`. `normalize` prints the desugared double-quoted form
  (e.g. `''` + newline + `  foo` + newline + `  ''` normalizes to `"foo\n"`),
  which re-parses and round-trips.
- **Unicode operators** `λ` (U+03BB), `→` (U+2192), `∀` (U+2200), `∧` (U+2227),
  `⫽` (U+2AFD) and `≡` (U+2261) are accepted as alternatives to `\`, `->`,
  `forall`, `/\`, `//` and `==` respectively (the ASCII forms still work).
  `⫽` — not `∨` — is the Unicode form of `//` (prefer), matching the Dhall
  standard (dhall.abnf); `∨` (U+2228) and `≢` (U+2262) are not Dhall operators
  and are rejected.

### Arithmetic semantics

- `+ - *` require both operands to be the same scalar type
  (`Natural`/`Integer`/`Double`); `==`/`!=` also accept `Bool`/`Text`.
  Comparisons (`< <= > >=`) accept `Natural`/`Integer`/`Double`.
- `Natural` and `Integer` are **unbounded** (arbitrary precision); `+` `-` `*`
  never overflow. `Natural` subtraction **saturates** at `0` (`2 - 7 == 0`).
  `Double` is IEEE 754 (JSON maps non-finite to `null`). Double literals are
  printed with the **shortest round-trip** representation (and non-finite maps
  to `null`/`.nan`/`.inf`/`-.inf`/`nan`/`inf` per format).
- Division is intentionally **not** supported (no `/` operator).
- Operator precedence (loosest to tightest): `->`, `:`, `with`, `||`, `&&`,
  comparisons, `+ - ++ #`, `/\`, `//`, `*`, application.
- `/\` is a **recursive** record merge: disjoint fields are kept, shared
  fields are recursively merged. A shared field that is not a record on both
  sides is a *type error* (faithful Dhall). `//` is the **right-biased**
  (non-recursive) merge/prefer: disjoint fields are kept and a shared field
  takes the right-hand value, with no recursion and no error on shared
  non-record fields.
- `with` both updates (a field's type may change) and inserts fields, and
  creates intermediate records for nested paths (`e with a.b = v`).
- `Natural/subtract a b` is `max (b - a) 0` — the argument order is the
  opposite of the `-` operator.
- `&&`/`||` require both operands to be `Bool`. `Integer/show` prints a
  leading `+` for non-negative values (`Integer/show +3` = `"+3"`), and
  `Text/show` renders a `Text` as a double-quoted Dhall literal with `$`
  escaped as `\u0024`. `Integer/clamp` maps a negative `Integer` to `0`.
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
error otherwise). `toMap` of the empty record literal (`{=}` or `{}`)
yields the empty list `[]`; because the element type `V` is unknowable
there, an annotation is required — `toMap {=} : List { mapKey : Text, mapValue : V }`.

## Imports

Local file imports, environment-variable imports, and `http://` URL imports are
supported:

```
./dep.dhall        # relative to the importing file's directory
../x.dhall
/abs/path.dhall
env:HOME           # the value of $HOME as a Text literal
http://host/x.dhall sha256:<64hex>
```

- Imports are resolved and inlined **at parse time**; the imported
  expression is closed (it cannot reference binders from the importing
  file).
- Relative paths resolve against the directory of the importing file (the
  CWD for stdin input). Relative imports **inside a URL document** resolve
  against that URL's directory (`./dep.dhall`, `../dep.dhall`), never against
  the local CWD.
- Import **cycles** are detected and reported (`import cycle`).
- A per-key cache gives correct diamond-import sharing.
- Import chain depth is capped (`MAX_IMPORT_DEPTH`, 64) — deeper chains
  error instead of overflowing the C stack.
- Local imports also support the always-absent `missing` import.
- `e0 ? e1` (import-fallback, tighter than `with`, looser than `||`) evaluates
  to `e1` when `e0` contains an absent import — a `missing` import, a file that
  does not exist, an unset `env:` variable, or a URL that is unreachable or
  blocked. A failed `sha256:` check, an import cycle, an unsupported URL
  scheme, or a parse error is **not** recoverable by `?`.

### URL imports (http)

`http://` URL imports are supported with a strong security posture:

- **`sha256:` is required** for every remote import (checked before any fetch);
  an un-hashed URL import is a hard error (`Import of remote URL requires a
  sha256: hash`). The fetched body is verified against the hash and a mismatch
  is a hard error.
- **http-only**: `https://` is recognized but rejected with a hard error
  (`not supported in this build (no TLS)`) — this build has no TLS. Any other
  scheme (`ftp://`, `file://`, …) is rejected with `unsupported URL scheme`.
- **SSRF protection**: the hostname is resolved and the connection is rejected
  if *any* resolved address is private / loopback / link-local / reserved /
  multicast (IPv4 and IPv6, including IPv4-mapped IPv6) — this defeats
  DNS-rebinding. The connection is made only to a validated address, never the
  hostname string. Unknown address families fail closed.
- **Redirects** (301/302/303/307/308) are followed up to a cap of 5, and every
  hop re-validates the scheme, re-resolves, and re-checks SSRF; a redirect to a
  non-http or blocked address is rejected.
- **Caps**: a 16 MiB body cap, a 10 s per-operation timeout, and a 30 s overall
  deadline. `Transfer-Encoding: chunked` is de-chunked (bounds-checked). No
  request body, cookies, or credentials are sent — only `GET` + a `Host` header.
- **Absent vs hard**: an unreachable / unresolvable / blocked / timeout /
  4xx/5xx / redirect-cap-exceeded URL is *absent* and recoverable by `?`.
  An unsupported scheme, `https://`, a missing or mismatched `sha256:`, or an
  oversized response is a *hard* error (not recoverable).
- Query strings and fragments are not supported in URL imports (the `?` and `#`
  are not part of the import; percent-encode them, or add a trailing path).

### URL imports in the browser

In the WebAssembly/browser build, `http://` imports are fetched with a
**synchronous XMLHttpRequest on the main thread**; this blocks the page for the
duration of the request (imports are inlined at parse time, so the interpreter
is already synchronous). It is deprecated but still supported in all major
browsers, and cannot be timed out. `emscripten_fetch()`'s synchronous mode is
**not** used here because Emscripten refuses it on the main browser thread
(returns NULL), so the build drives the XHR directly.

- **CORS**: a cross-origin `http` import only succeeds if the target sends CORS
  headers (`Access-Control-Allow-Origin`); otherwise it is reported **absent**
  and is recoverable by `?`. Same-origin fetches (files served alongside the
  page) work, provided the page itself is not a secure (`https://`) origin that
  blocks `http://` subresources as mixed content.
- **Security-model difference**: the native `getaddrinfo`/private-IP SSRF gate
  does **not** apply to the wasm path — the browser owns connectivity and
  enforces its own network policy (same-origin / CORS / mixed-content).
  Integrity therefore rests entirely on the mandatory `sha256:` hash, which is
  still required and verified on fetch.

### sha256: hash deviation

The `sha256:<64 hex>` check is a **documented deviation**: real Dhall hashes
the CBOR encoding of the beta-normal form, but dhall-c (which has no CBOR)
hashes the **raw source text** (file bytes / env-var value / URL response
body), and the digest is lowercase base16 hex rather than base64. This applies
to local, `env:`, and URL imports alike.

### Test-only escape

The `DHALL_ALLOW_LOOPBACK=1` environment variable is a **test-only, insecure**
escape that treats only `127.0.0.0/8` and `::1` as public, so the opt-in live
test (`tests/url.sh`) can exercise the success fetch path against a localhost
server. Every other private/link-local/reserved range stays blocked. Do not set
it in production.

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

## Stuck text interpolation (preserved, not dropped)

`normalize` and the serializer (`to-json`/`to-toml`/`to-yaml`) modes reject
interpolation of a **closed non-Text** value (e.g. `"${1+2}"` or `"${True}"`)
with `interpolation requires Text`. A **stuck** interpolation whose value is a
bound variable of type Text is now **preserved** rather than dropped: e.g.
`\(x : Text) -> "${x}"` normalizes to `\(_ : Text) -> "${_0}"` (which re-parses,
type-checks, and is idempotent). Well-typed closed interpolation still collapses
(`let x = "hi" in "say ${x}"` to `"say hi"`).

## Recursion depth

The recursive-descent parser enforces a maximum nesting depth
(`PARSE_MAX_DEPTH`, 1000) and reports a parse error rather than overflowing the
C stack on deeply nested adversarial input. Import chains are additionally
guarded by `MAX_IMPORT_DEPTH` (see Imports).
