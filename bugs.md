# Known bugs & limitations

This file tracks known bugs and behavioral limitations of the dhall-c
interpreter. They are documented here so they are not silently lost, and so a
future fix can be scoped precisely.

## 1. Stuck (bound-variable) text interpolation is silently dropped

**Status:** FIXED.

**Symptom (before the fix):** `\(x : Text) -> "${x}"` normalized to
`\(_ : Text) -> ""` (exit 0) - the interpolated expression `x` was silently
dropped, producing a **wrong** normal form. (This was distinct from the closed
non-Text case `"${1+2}"`, which has always errored with
`interpolation requires Text`.)

**What changed:** `src/normalize.c` now does a *partial splice* in `norm_text()`:
it rebuilds the TextPart list, splicing an interpolation part into the literal
stream only when it normalizes to a closed `Text` literal, erroring (as before)
when it normalizes to a closed non-`Text` value (`interpolation requires Text`),
and otherwise preserving the (already-normalized) stuck expression as an `expr`
part. `src/ast.c` `print_term`'s `TmText` case now emits those preserved parts
back as `${...}` (e.g. `"${_0}"`), which re-parse via the existing `_N` de Bruijn
machinery. So `\(x : Text) -> "${x}"` now normalizes to `\(_ : Text) -> "${_0}"`
(idempotent, round-trips). Closed non-Text interpolation (`"${1+2}"`) still
errors, and well-typed closed interpolation (`let x = "hi" in "say ${x}"`) still
collapses to `"say hi"`.

## 2. Double/show (and the serializers) print with `%g`, not shortest-round-trip

**Status:** OPEN (accepted deviation).

`Double/show` (`src/normalize.c` `dbl_show`) formats a `Double` literal with
`%g`, which yields only 6 significant digits. For common inputs this is **lossy**
or malformed:
- `Double/show 0.123456789` → `"0.123457"` (should round-trip to
  `"0.123456789"`).
- `Double/show 1e10` → `"1e+10"` (not a valid Dhall Double literal; the `.0` /
  scientific marker is wrong).

This is consistent with the pre-existing value serializers (`serialize.c` also
uses `%g`), so it is a codebase-wide Double-literal-formatting limitation, not a
regression from the `Double/show` builtin. Real Dhall requires the **shortest
round-trip** literal (Grisu/Ryu). Fixing it properly means a shortest-round-trip
formatter shared by `print_term`, `Double/show`, and the JSON/TOML/YAML
serializers.
