# Known bugs & limitations

This file tracks known bugs and behavioral limitations of the dhall-c
interpreter. They are documented here so they are not silently lost, and so a
future fix can be scoped precisely.

## 1. Stuck (bound-variable) text interpolation is silently dropped

**Status:** known / accepted (out of scope). Not fixed.

**Symptom:**
```
\(x : Text) -> "${x}"
```
normalizes to
```
\(_ : Text) -> ""
```
(exit 0) — the interpolated expression `x` is *silently dropped*, producing a
**wrong** normal form. This is distinct from the (fixed) closed non-Text case:
`"${1+2}"` now errors with `interpolation requires Text`, but a **stuck** (bound
Text) interpolation is still dropped to the empty string.

**Root cause:** in `src/normalize.c`, `text_concat()` concatenates interpolation
parts only when the normalized part is already a pure `Text` literal
(`TmText` with a literal, no `expr`). Any part that does not normalize to a
pure literal is skipped, so a bound `Text` variable (which normalizes to a
`TmVar`, not a literal) is dropped.

**Scope of a correct fix (deliberately NOT attempted):** proper *partial splice*
— rebuild the `TextPart` list keeping non-literal interpolation parts intact
instead of dropping them, and make `print_term` / `serialize.c` emit preserved
interpolation (e.g. `"${_0}"`). That bleeds into the `_N` round-trip machinery
and is a larger, riskier change.

**Why not error on all non-literal interpolations instead?** Because that would
wrongly reject the (valid, correct) `\(x : Text) -> "${x}"`. The distinction is:
`"${1+2}"` is ill-typed (non-Text value), while `"${x}"` with `x : Text` is
well-typed but "stuck" at normalize time (its value isn't known without
substitution — which here substitutes under a binder and stays symbolic).
