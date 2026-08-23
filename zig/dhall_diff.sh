#!/usr/bin/env bash
# dhall_diff.sh — Differential harness for the dhall-c C→Zig migration (U6 gate).
#
# For each fixture:
#   - tests/cases/*.dhall             → stdin mode
#   - examples/*.dhall                 → file mode, cwd = repo root
# run BOTH $C_DRIVER and $ZIG_DRIVER in each mode with identical stdin/cwd/env
# (DHALL_TEST_ENV=hello-world) and assert byte-identical stdout, identical exit
# code, and identical stderr.
#
# U7 (serialize) scope: typecheck, normalize, and the 3 serializers
# (to-json/to-toml/to-yaml) over the no-import corpus (tests/cases/*.dhall +
# examples/*.dhall). The Zig binary does not resolve imports yet — ./ env:
# https:// sha256: as Text imports join at U8.  The imports corpus
# (tests/cases/imports/**) is therefore NOT run here.
#
# Gate: bash zig/dhall_diff.sh  →  ALL PASS
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Zig cache dirs (sandbox) ───────────────────────────────────────────────
if [ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]; then export ZIG_GLOBAL_CACHE_DIR=/tmp/.zcache; fi
if [ -z "${ZIG_LOCAL_CACHE_DIR:-}" ];  then export ZIG_LOCAL_CACHE_DIR=/tmp/.zlcache;  fi
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

# ─── Drivers (resolved to absolute paths so cwd resets never matter) ────────
# The C oracle is a Cosmopolitan APE binary; both drivers are invoked as
# ordinary subprocesses from inside a single bash process, so they always see a
# consistent cwd regardless of how the script itself is launched.
C_DRIVER="${C_DRIVER:-$REPO_ROOT/dhall.com.dbg}"
ZIG_DRIVER="${ZIG_DRIVER:-$REPO_ROOT/zig-out/bin/dhall}"

# Export DHALL_TEST_ENV for env: imports, identical for both drivers.
export DHALL_TEST_ENV=hello-world

# ─── Temp files / cleanup ───────────────────────────────────────────────────
C_OUT=$(mktemp);  Z_OUT=$(mktemp)
C_ERR=$(mktemp);  Z_ERR=$(mktemp)
C_RC=$(mktemp);   Z_RC=$(mktemp)
trap 'rm -f "$C_OUT" "$Z_OUT" "$C_ERR" "$Z_ERR" "$C_RC" "$Z_RC"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

# U7: typecheck + normalize + the 3 serializers (to-json/to-toml/to-yaml).
# Imports corpus still deferred to U8.
MODES="typecheck normalize to-json to-toml to-yaml"

# run_driver <driver> <mode> <stdin-file|-:> <file-arg> <workdir> <rcfile> <outfile> <errfile>
#   stdin-file  = "-" → read the expression from <file-arg> on stdin (stdin mode)
#               = any other path → feed that file as stdin (used by stdin mode)
#   file-arg    = argument passed to the driver after the mode.
#   workdir     = directory the driver runs in (cd inside a subshell).
run_driver() {
  local driver="$1" mode="$2" stdin_src="$3" filearg="$4" workdir="$5"
  local rcfile="$6" outfile="$7" errfile="$8"
  if [ "$stdin_src" = "-" ]; then
    ( cd "$workdir" && "$driver" "$mode" "$filearg" >"$outfile" 2>"$errfile" )
  else
    ( cd "$workdir" && "$driver" "$mode" < "$stdin_src" >"$outfile" 2>"$errfile" )
  fi
  echo "$?" >"$rcfile"
}

# compare <label> <mode>
compare() {
  local label="$1" mode="$2"
  local crc zrc
  crc=$(cat "$C_RC")
  zrc=$(cat "$Z_RC")
  if [ "$crc" = "$zrc" ] && cmp -s "$C_OUT" "$Z_OUT" && cmp -s "$C_ERR" "$Z_ERR"; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: [$label] mode=$mode"
    if [ "$crc" != "$zrc" ]; then echo "  exit code: C=$crc Z=$zrc"; fi
    if ! cmp -s "$C_OUT" "$Z_OUT"; then
      echo "  stdout differs:"
      diff "$C_OUT" "$Z_OUT" | sed 's/^/    /'
    fi
    if ! cmp -s "$C_ERR" "$Z_ERR"; then
      echo "  stderr differs:"
      diff "$C_ERR" "$Z_ERR" | sed 's/^/    /'
    fi
  fi
}

# diff_case <label> <mode> <stdin_src> <filearg> <workdir>
diff_case() {
  local label="$1" mode="$2" stdin_src="$3" filearg="$4" workdir="$5"
  run_driver "$C_DRIVER"  "$mode" "$stdin_src" "$filearg" "$workdir" "$C_RC" "$C_OUT" "$C_ERR"
  run_driver "$ZIG_DRIVER" "$mode" "$stdin_src" "$filearg" "$workdir" "$Z_RC" "$Z_OUT" "$Z_ERR"
  compare "$label" "$mode"
}

# diff_stdin <label> <dhall-file>  — stdin mode, cwd = repo root
diff_stdin() {
  local label="$1" f="$2" mode
  for mode in $MODES; do
    diff_case "$label" "$mode" "$f" "" "$REPO_ROOT"
  done
}

# diff_file <label> <dhall-file> <workdir> <filearg>
diff_file() {
  local label="$1" f="$2" workdir="$3" filearg="$4" mode
  for mode in $MODES; do
    diff_case "$label" "$mode" "-" "$filearg" "$workdir"
  done
}

# ─── stdin-mode fixtures: tests/cases/*.dhall ───────────────────────────────
# No ./ or env: imports in this directory (verified), so cwd = repo root is
# consistent for both drivers.  Each fixture is run once per mode on stdin.
for f in "$REPO_ROOT"/tests/cases/*.dhall; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  diff_stdin "cases/$name" "$f"
done

# ─── file-mode fixtures: tests/cases/imports/**/*.dhall ─────────────────────
# cwd = fixture's dir so relative imports resolve exactly as run.sh does.
while IFS= read -r f; do
  dir="$(dirname "$f")"
  name="$(basename "$f")"
  diff_file "imports/$name" "$f" "$dir" "$name"
done < <(find "$REPO_ROOT"/tests/cases/imports -name '*.dhall' -print | sort)

# ─── file-mode fixtures: examples/*.dhall ───────────────────────────────────
# cwd = repo root, arg = relative path (matches tests/examples.sh: "no relative
# ./ imports can break"; every example must behave identically on both drivers).
for f in "$REPO_ROOT"/examples/*.dhall; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  diff_file "examples/$name" "$f" "$REPO_ROOT" "examples/$name"
done

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "=== diff: $PASS_COUNT passed, $FAIL_COUNT failed ==="
if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "DIFF FAILURES PRESENT"
  exit 1
fi
echo "ALL PASS"
