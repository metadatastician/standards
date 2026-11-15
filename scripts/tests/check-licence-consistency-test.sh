#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# check-licence-consistency-test.sh — fixture suite for the package.json
# manifest read in scripts/check-licence-consistency.sh.
#
# `tools/js-runtimes regen` writes package.json as one-line JCS
# (3-practice/LANGUAGE-POLICY.adoc §1.4). The checker read the licence with a
# line-based grep, which on a one-line file took everything after "license"
# as the value, so a consistent repository failed Governance with a
# "Licence-vs-manifest mismatch" (met in hyperpolymath/boj-server). The field
# is now read with a JSON parse (jq). These fixtures prove both shapes are
# read, that a real mismatch still fails, and that a missing jq is exit 2,
# never a pass.
#
# Run: bash scripts/tests/check-licence-consistency-test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/check-licence-consistency.sh"
command -v jq >/dev/null 2>&1 || { echo "check-licence-consistency-test: jq is not on PATH (cannot run, not a pass)" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# Outside any git repository, and not the carve-out list, so step (6) runs
# its ordinary branch over the fixture alone.
export GITHUB_REPOSITORY="example/licence-fixture"

pass=0; fail=0
fixture() { # fixture <package.json body>
  rm -rf "$WORK/r"; mkdir -p "$WORK/r"
  printf 'Mozilla Public License Version 2.0\n==================================\n' > "$WORK/r/LICENSE"
  printf '%s\n' "$1" > "$WORK/r/package.json"
}
expect() { # expect <wanted-exit> <label> [env PATH override]
  local want="$1" label="$2" got=0
  if [ -n "${3:-}" ]; then
    PATH="$3" bash "$CHECK" "$WORK/r" >"$WORK/out" 2>&1 || got=$?
  else
    bash "$CHECK" "$WORK/r" >"$WORK/out" 2>&1 || got=$?
  fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $label"
  else fail=$((fail+1)); echo "  FAIL  $label (wanted exit $want, got $got)"; sed 's/^/        /' "$WORK/out"; fi
}
names() { # names <fixed-string> <label>
  if grep -qF -- "$1" "$WORK/out"; then pass=$((pass+1)); echo "  ok    $2"
  else fail=$((fail+1)); echo "  FAIL  $2"; sed 's/^/        /' "$WORK/out"; fi
}
line() { # line <exact output line> <label>
  if grep -qxF -- "$1" "$WORK/out"; then pass=$((pass+1)); echo "  ok    $2"
  else fail=$((fail+1)); echo "  FAIL  $2"; sed 's/^/        /' "$WORK/out"; fi
}

echo "package.json licence field"
fixture '{
  "name": "fixture",
  "version": "0.0.0",
  "license": "MPL-2.0",
  "private": true
}'
expect 0 "pretty-printed package.json, licence matches"
line "[OK] Manifest licence (package.json): MPL-2.0" "and reads exactly MPL-2.0"

# What js-runtimes regen writes: keys sorted, one line, more keys after.
fixture '{"license":"MPL-2.0","name":"fixture","private":true,"scripts":{"test":"echo ok"},"version":"0.0.0"}'
expect 0 "one-line JCS package.json, licence matches"
line "[OK] Manifest licence (package.json): MPL-2.0" "and reads exactly MPL-2.0, not the rest of the line"

fixture '{"dependencies":{},"license":"MPL-2.0","name":"fixture"}'
expect 0 "one-line JCS with keys before the licence, licence matches"
line "[OK] Manifest licence (package.json): MPL-2.0" "and reads exactly MPL-2.0"

fixture '{"description":"says \"license\": MIT in prose","license":"MPL-2.0","name":"fixture"}'
expect 0 "a string that mentions \"license\" is not the field"
line "[OK] Manifest licence (package.json): MPL-2.0" "and the field is the one read"

fixture '{"license":{"type":"MPL-2.0","url":"https://www.mozilla.org/MPL/2.0/"},"name":"fixture"}'
expect 0 "legacy object form is read through its type"

echo "controls (the check can still fail)"
fixture '{"license":"MIT","name":"fixture","private":true,"version":"0.0.0"}'
expect 1 "one-line JCS package.json with a different licence fails"
names "Licence-vs-manifest mismatch: licence='MPL-2.0' manifest='MIT'" "and names both values"

fixture '{
  "license": "MIT",
  "name": "fixture"
}'
expect 1 "pretty-printed package.json with a different licence fails"

fixture '{"name":"fixture","private":true}'
expect 0 "no licence field is a warning, not a failure"
names "no licence field detected" "and says so"

fixture '{"name": "fixture", "license": "MPL-2.0",}'
expect 0 "a package.json that is not JSON is reported, not read as a licence"
names "not valid JSON" "and says so"

echo "cannot run"
# A PATH holding everything the checker uses except jq.
NOJQ="$WORK/nojq"; mkdir -p "$NOJQ"
for t in bash grep sed tr wc head ls sort git cat; do
  p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$NOJQ/$t"
done
fixture '{"license":"MPL-2.0","name":"fixture"}'
expect 2 "no jq on PATH is exit 2, not a pass" "$NOJQ"
names "cannot run, not a pass" "and says so"

echo
echo "check-licence-consistency-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
