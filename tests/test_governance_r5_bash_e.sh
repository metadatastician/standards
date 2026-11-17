#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# test_governance_r5_bash_e.sh — runs the R5 canonical-reference drift step of
# .github/workflows/governance-reusable.yml exactly as a runner does: the step's
# `run:` text, extracted with yq, under `bash -e` (a step with no `shell:` runs
# as `bash -e {0}` on ubuntu runners).
#
# Regression: under `-e`, `out=$(grep …)` on an include file with no match
# returned 1 and aborted the step before `rc=$?` — exit 1, no output, no
# annotation. echidna#410 went red on clean content. The planted-hit cases are
# the positive control: a real drift must still fail and name the line.
#
# Run: bash tests/test_governance_r5_bash_e.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/.github/workflows/governance-reusable.yml"
STEP='Canonical-reference drift (R5 generic)'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# Print the R5 step's run: text; fail the suite if the step cannot be found.
extract_step() {
  yq -r ".jobs.\"security-policy\".steps[] | select(.name == \"$STEP\") | .run" "$F"
}

# Build a fixture repo in $1 with one rule over the given include files.
# Remaining args are "path:content" pairs written into the fixture.
make_fixture() {
  local dir="$1"; shift
  mkdir -p "$dir/.github/canonical-references"
  cat > "$dir/.github/canonical-references/drift.yml" <<'RULE'
id: test-drift
description: planted drift marker
canonical_pointer: CANON.md
patterns:
  - "DRIFT_MARKER_[0-9]+"
scope:
  include: [a.md, b.md]
RULE
  local pair
  for pair in "$@"; do printf '%s\n' "${pair#*:}" > "$dir/${pair%%:*}"; done
}

# assert <label> <want-exit> <needle> <fixture-dir>: run the step under bash -e.
assert() {
  local label="$1" want="$2" needle="$3" dir="$4" out status
  out="$(cd "$dir" && bash -e "$WORK/r5.sh" 2>&1)"; status=$?
  if [ "$status" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $status; output: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  if ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL: $label — output lacks '$needle'; output: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

extract_step > "$WORK/r5.sh"
if [ ! -s "$WORK/r5.sh" ] || [ "$(head -c 4 "$WORK/r5.sh")" = "null" ]; then
  echo "FAIL: step '$STEP' not found in security-policy"; exit 1
fi

make_fixture "$WORK/clean" "a.md:nothing to see" "b.md:still nothing"
assert "no match in any include file passes" 0 "clean across 1 rule(s)" "$WORK/clean"

make_fixture "$WORK/hit" "a.md:nothing here" "b.md:see DRIFT_MARKER_42 here"
assert "hit after a no-match file still fails" 1 "::error file=b.md,line=1::[R5:test-drift]" "$WORK/hit"

make_fixture "$WORK/first" "a.md:DRIFT_MARKER_7 first" "b.md:nothing"
assert "hit in the first file fails" 1 "❌ [R5] 1 canonical-reference drift hit(s)" "$WORK/first"

mkdir -p "$WORK/optout"
assert "repo without the directory is skipped" 0 "skipped (repo has not opted in)" "$WORK/optout"

echo "R5 bash -e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
