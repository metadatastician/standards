#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -euo pipefail

# Unit test for scripts/lib/pin-ancestry.sh — the shared ancestry assertion
# (D5c). The compare API is served from file:// fixtures, so every verdict,
# including each refusal, is a planted positive control rather than an absence.

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/pin-ancestry.sh
. "$SCRIPT_DIR/../lib/pin-ancestry.sh"

export STANDARDS_REACHABILITY_API_BASE="file://$TEST_DIR"
export GITHUB_TOKEN=test-token
REPO=metadatastician/standards
mkdir -p "$TEST_DIR/repos/$REPO/compare"

pass=0 fail=0

# plant <sha> <body> — serve <body> as compare/<sha>...main.
plant() { printf '%s' "$2" > "$TEST_DIR/repos/$REPO/compare/$1...main"; }

# expect <rc> <label> <sha> — assert assert_pin_ancestry returns <rc>.
expect() {
  local want="$1" label="$2" sha="$3" got=0
  assert_pin_ancestry "$REPO" "$sha" main 2>/dev/null || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "PASS: $label (rc=$got)"; pass=$((pass + 1))
  else
    echo "FAIL: $label (want rc=$want, got rc=$got)"; fail=$((fail + 1))
  fi
}

# sha <n> — print <n> zero-padded to a 40-character fake commit SHA.
sha() { printf '%040d' "$1"; }

plant "$(sha 1)" '{"url":"x","status":"identical","ahead_by":0,"behind_by":0}'
plant "$(sha 2)" '{"url":"x","status":"ahead","ahead_by":3,"behind_by":0,"commits":[{"status":"diverged"}]}'
plant "$(sha 3)" '{"url":"x","status":"behind","ahead_by":0,"behind_by":2}'
plant "$(sha 4)" '{"url":"x","status":"diverged","ahead_by":4,"behind_by":1}'
plant "$(sha 5)" '{"message":"Not Found"}'

expect 0 "identical is an ancestor"                  "$(sha 1)"
expect 0 "ahead is an ancestor (first status wins)"  "$(sha 2)"
expect 1 "behind is NOT an ancestor (PR head)"       "$(sha 3)"
expect 1 "diverged is NOT an ancestor (orphan)"      "$(sha 4)"
expect 2 "body without status is indeterminate"      "$(sha 5)"
expect 2 "failed request is indeterminate"           "$(sha 6)"
expect 1 "abbreviated SHA is refused before probing" "5b1d0022"
expect 1 "non-hex SHA is refused"                    "$(sha 1 | tr 0 g)"

# The refusal must name the remedy, or the operator repins a PR head again.
msg=$(assert_pin_ancestry "$REPO" "$(sha 4)" main 2>&1 || true)
if grep -q 'never a PR head' <<<"$msg"; then
  echo "PASS: non-ancestor refusal names the remedy"; pass=$((pass + 1))
else
  echo "FAIL: non-ancestor refusal lacks the remedy: $msg"; fail=$((fail + 1))
fi

echo "----------------------------------------"
echo "$pass/$((pass + fail)) test cases passed."
[ "$fail" -eq 0 ]
