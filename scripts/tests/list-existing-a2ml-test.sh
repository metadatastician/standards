#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# list-existing-a2ml-test.sh — scripts/list-existing-a2ml.sh lists every
# tracked A2ML path as a warning, gives an exact count, tags the A7 fallback
# paths it is told about, caps annotations, and never fails.
#
# Run: bash scripts/tests/list-existing-a2ml-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$SCRIPT_DIR/../list-existing-a2ml.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

assert() { # label want-status needle cmd...
  local label="$1" want="$2" needle="$3"; shift 3
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $status"; fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: $label — output lacked '$needle'"; echo "      $(printf '%s' "$out" | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}
refute() { # label needle cmd...
  local label="$1" needle="$2"; shift 2
  if "$@" 2>&1 | grep -qF -- "$needle"; then echo "FAIL: $label — output has '$needle'"; fail=$((fail + 1))
  else echo "PASS: $label"; pass=$((pass + 1)); fi
}

d="$WORK/r"; mkdir -p "$d/9-archive/x" "$d/sub"
git -C "$d" init -q
: > "$d/a.a2ml"; : > "$d/9-archive/x/b.a2ml"; : > "$d/sub/c.a2ml.template"; : > "$d/sub/d.a2ml.v2.template"
: > "$d/keep.txt"; : > "$d/notA2ML.a2mlx"; : > "$d/.a2ml-note"; : > "$d/untracked.a2ml.in"
git -C "$d" add a.a2ml 9-archive sub keep.txt notA2ML.a2mlx .a2ml-note
git -C "$d" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m base

assert "lists a tracked .a2ml as a warning" 0 "::warning file=a.a2ml::" bash "$LIST" "$d"
assert "lists .a2ml.template and .a2ml.vN.template" 0 "::warning file=sub/d.a2ml.v2.template::" bash "$LIST" "$d"
assert "exact count, archive count" 0 "4 tracked A2ML file(s) remain (1 under 9-archive/, 0 covered" bash "$LIST" "$d"
refute "ignores .a2mlx, .a2ml-note and untracked files" "notA2ML" bash "$LIST" "$d"
refute "an untracked A2ML file is not listed" "untracked.a2ml.in" bash "$LIST" "$d"
assert "a fallback path is tagged and counted, still listed" 0 "A7 fallback" env A2ML_FALLBACK_PATHS="a.a2ml" bash "$LIST" "$d"
assert "fallback count" 0 "1 covered by the A7 fallback" env A2ML_FALLBACK_PATHS="a.a2ml" bash "$LIST" "$d"
assert "annotations are capped, the count is not" 0 "4 tracked A2ML file(s)" env A2ML_MAX_ANNOTATIONS=1 bash "$LIST" "$d"
n=$(A2ML_MAX_ANNOTATIONS=1 bash "$LIST" "$d" | grep -c '^::warning file=')
[ "$n" = 1 ] && { echo "PASS: cap of 1 gives 1 file annotation"; pass=$((pass + 1)); } || { echo "FAIL: cap gave $n"; fail=$((fail + 1)); }
e="$WORK/e"; mkdir "$e"; git -C "$e" init -q
assert "a repository with no A2ML says so and exits 0" 0 "none" bash "$LIST" "$e"
assert "a non-git directory exits 2" 2 "not a git work tree" bash "$LIST" "$WORK"
git -C "$d" rm -q a.a2ml
assert "exit 0 whatever is found" 0 "::warning::existing-a2ml" bash "$LIST" "$d"

echo
echo "list-existing-a2ml-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
