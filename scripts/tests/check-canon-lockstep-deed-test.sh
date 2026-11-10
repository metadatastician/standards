#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Gate A assertion 3 reads the spine deed's (canon …) clause
# (1-formats/deed/vocabulary/canon.adoc, rsr-template-repo#215), with the
# rsr-profile.a2ml [canon] block as a legacy fallback. Each case builds a fake
# spine and asserts the [3] section's verdict under --strict.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$REPO/scripts/check-canon-lockstep.sh"
FIXTURE="$REPO/1-formats/deed/tools/fixtures/valid/canon-clause_chora.deed"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

# The live pin, read from canon.lock with the script's own shape rules, so the
# test does not go stale on the next canon release.
LOCK="$REPO/canon.lock"
WANT_VER="$(awk '/^\[canon\]/{f=1;next} /^\[/{f=0} f && /^version[[:space:]]*=/{gsub(/.*=[[:space:]]*"|".*/,"");print;exit}' "$LOCK")"
WANT_CRIT="$(awk '/^[[:space:]]*criteria[[:space:]]*=/{f=1} f{print} f&&/}/{exit}' "$LOCK" | grep -oE '[0-9a-f]{64}' | head -1)"
WANT_GATES="$(awk '/^[[:space:]]*gates[[:space:]]*=/{f=1} f{print} f&&/}/{exit}' "$LOCK" | grep -oE '[0-9a-f]{64}' | head -1)"

# section3 <spine-dir>: run the gate and print only the [3] section.
section3() {
  bash "$CHECK" --canon "$REPO" --spine "$1" --base HEAD --strict 2>&1 \
    | awk '/^\[3\]/{f=1} /^\[4\]/{f=0} f'
}

# expect <name> <spine-dir> <PASS|FAIL> [needle]: assert the [3] verdict, and
# that needle (if given) appears in the section.
expect() {
  local out verdict
  out="$(section3 "$2")"
  if printf '%s' "$out" | grep -q 'FAIL'; then verdict=FAIL
  elif printf '%s' "$out" | grep -q 'PASS'; then verdict=PASS
  else verdict=NONE; fi
  if [ "$verdict" = "$3" ] && { [ -z "${4:-}" ] || printf '%s' "$out" | grep -qF -- "$4"; }; then
    PASSED=$((PASSED + 1)); echo "ok   $1"
  else
    FAILED=$((FAILED + 1)); echo "FAIL $1 (wanted $3${4:+ + '$4'}, got $verdict)"; printf '%s\n' "$out" | sed 's/^/     /'
  fi
}

# deed <dir> <version> <criteria> <gates>: write a spine deed with one clause.
deed() {
  mkdir -p "$1"
  cat > "$1/spine_chora.deed" <<DEED
;; SPDX-License-Identifier: MPL-2.0
; a (canon "decoy") in a comment must not be read
(repo-deed
  :schema-version "1.0.0"
  :canonical-name "spine"
  (canon
    :version "$2"
    :criteria-sha256 "$3"
    :gates-sha256 "$4"))
DEED
}

for v in WANT_VER WANT_CRIT WANT_GATES; do
  [ -n "${!v}" ] || { echo "FAIL could not read $v from canon.lock — the test's own reader is broken"; exit 1; }
done

deed "$WORK/match" "$WANT_VER" "$WANT_CRIT" "$WANT_GATES"
expect "deed matching canon.lock passes" "$WORK/match" PASS "reading spine_chora.deed"

# Two-phase lockstep: a spine that adopted this canon ahead of its release
# names the canon PR with :proposed-by. Gate A compares the pin alone, so the
# extra field neither breaks the read nor excuses a mismatch.
deed "$WORK/proposed" "$WANT_VER" "$WANT_CRIT" "$WANT_GATES"
sed -i 's|    :gates-sha256 "\([0-9a-f]*\)"))|    :gates-sha256 "\1"\n    :proposed-by "metadatastician/standards#1"))|' "$WORK/proposed/spine_chora.deed"
grep -q ':proposed-by' "$WORK/proposed/spine_chora.deed" || { echo "FAIL could not plant :proposed-by"; exit 1; }
expect "a pin adopted ahead of release (:proposed-by) passes when it matches" "$WORK/proposed" PASS "reading spine_chora.deed"
deed "$WORK/proposed-stale" "0.0.1" "$WANT_CRIT" "$WANT_GATES"
sed -i 's|    :gates-sha256 "\([0-9a-f]*\)"))|    :gates-sha256 "\1"\n    :proposed-by "metadatastician/standards#1"))|' "$WORK/proposed-stale/spine_chora.deed"
expect ":proposed-by does not excuse a mismatched pin" "$WORK/proposed-stale" FAIL "(version)"

deed "$WORK/bad-gates" "$WANT_VER" "$WANT_CRIT" "$(printf '%064d' 0)"
expect "wrong gates hash fails (criteria alone is not lockstep)" "$WORK/bad-gates" FAIL "(gates-sha256)"

deed "$WORK/old-ver" "0.0.1" "$WANT_CRIT" "$WANT_GATES"
expect "stale version fails (the #215 shape)" "$WORK/old-ver" FAIL "(version)"

deed "$WORK/short" "$WANT_VER" "${WANT_CRIT:0:12}" "$WANT_GATES"
expect "malformed hash fails on shape, not as a mismatch" "$WORK/short" FAIL "not well-formed"

deed "$WORK/dup" "$WANT_VER" "$WANT_CRIT" "$WANT_GATES"
sed -i 's/^    :gates-sha256 \(.*\)))$/    :gates-sha256 \1)\n  (canon :version "'"$WANT_VER"'" :criteria-sha256 "'"$WANT_CRIT"'" :gates-sha256 "'"$WANT_GATES"'"))/' "$WORK/dup/spine_chora.deed"
expect "two (canon …) clauses fail rather than pick one" "$WORK/dup" FAIL "not well-formed"

mkdir -p "$WORK/two-deeds"; deed "$WORK/two-deeds" "$WANT_VER" "$WANT_CRIT" "$WANT_GATES"
cp "$WORK/two-deeds/spine_chora.deed" "$WORK/two-deeds/other_chora.deed"
expect "two deeds fail" "$WORK/two-deeds" FAIL "one-deed-per-repo"

# An inline comment (deed.abnf: ";" to line-end, anywhere outside a string)
# is not part of the clause: a decoy :version there must never be read.
deed "$WORK/inline-stale" "0.0.1" "$WANT_CRIT" "$WANT_GATES"
sed -i 's/^  (canon$/  (canon ; :version "'"$WANT_VER"'"/' "$WORK/inline-stale/spine_chora.deed"
expect "inline-comment decoy cannot mask a stale version" "$WORK/inline-stale" FAIL "(version)"

deed "$WORK/inline-ok" "$WANT_VER" "$WANT_CRIT" "$WANT_GATES"
sed -i 's/^  (canon$/  (canon ; :version "0.0.1" -- a ";" here too/' "$WORK/inline-ok/spine_chora.deed"
expect "inline-comment decoy is ignored when the active pin matches" "$WORK/inline-ok" PASS

mkdir -p "$WORK/legacy/.machine_readable"
printf '[canon]\nversion = "0.0.1"\ncriteria_sha256 = "%s"\n' "$WANT_CRIT" > "$WORK/legacy/.machine_readable/rsr-profile.a2ml"
expect "legacy a2ml fallback still passes on criteria" "$WORK/legacy" PASS "LEGACY"

# A deed larger than the pipe buffer, with the clause near the top, must still
# be read. The comment-stripped text used to be piped into `grep -q`, which
# exits at the first match; under `set -o pipefail` the writer's SIGPIPE made
# the test false, and the 1114-line spine deed was reported as having no
# (canon …) clause in CI ('grep: write error: Broken pipe').
deed "$WORK/large" "$WANT_VER" "$WANT_CRIT" "$WANT_GATES"
awk -v n=4000 '/^    :gates-sha256/ { sub(/\)\)$/, ")"); print; for (i = 0; i < n; i++) printf "  (notes :line %d :text \"padding so the deed outgrows a 64 KiB pipe buffer\")\n", i; print ")"; next } { print }' "$WORK/large/spine_chora.deed" > "$WORK/large/x" && mv "$WORK/large/x" "$WORK/large/spine_chora.deed" || { echo "FAIL could not pad the large deed"; exit 1; }
expect "a deed larger than the pipe buffer is still read (no SIGPIPE false negative)" "$WORK/large" PASS "reading spine_chora.deed"

mkdir -p "$WORK/none"
expect "no deed clause and no profile fails" "$WORK/none" FAIL "no (canon …) deed clause"

# Both the shipped fixture and the example on the vocabulary page must stay
# on the live canon. Checking only the fixture cannot catch drift in the page.
mkdir -p "$WORK/fixture"; cp "$FIXTURE" "$WORK/fixture/"
expect "vocabulary fixture is on the live canon" "$WORK/fixture" PASS

mkdir -p "$WORK/example"
if awk '
  /^== Example$/ { section++; in_example=1; next }
  in_example && /^== / { in_example=0 }
  in_example && /^\[source,lisp\]$/ { source=1; next }
  source && /^----$/ { if (!block) { block=1; next } complete++; block=0; source=0; next }
  block { print }
  END { if (section != 1 || complete != 1 || block) exit 1 }
' "$REPO/1-formats/deed/vocabulary/canon.adoc" > "$WORK/example/example_chora.deed"; then
  expect "vocabulary page example is on the live canon" "$WORK/example" PASS "reading example_chora.deed"
else
  FAILED=$((FAILED + 1)); echo "FAIL could not extract exactly one complete vocabulary example"
fi

echo "passed $PASSED failed $FAILED"
[ "$FAILED" -eq 0 ]
