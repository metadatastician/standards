#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

# Regression test for check-workflow-staleness.sh (recency-window model).
#
# Builds a hermetic fixture "standards" repo with a chain of commits at
# controlled ages, then points the gate at it via STALENESS_STANDARDS_DIR and
# checks that each pin classification (fresh / ahead / in-window-by-commits /
# in-window-by-days / out-of-window / forged) yields the expected exit code,
# alongside the structural rules (retired enforcer, SARIF code-scanning).

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/../check-workflow-staleness.sh"

# ── Build the fixture standards history ─────────────────────────────────────
FIX="$TEST_DIR/standards-fixture"
mkdir -p "$FIX"
git -C "$FIX" init -q
git -C "$FIX" config user.email "test@example.com"
git -C "$FIX" config user.name "Test"

commit_at() { # repo days_ago msg
  local repo="$1" days_ago="$2" msg="$3" ts
  ts=$(( $(date -u +%s) - days_ago * 86400 ))
  GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" \
    git -C "$repo" commit --allow-empty -q -m "$msg"
  git -C "$repo" rev-parse HEAD
}

C0=$(commit_at "$FIX" 400 "C0 ancient")
C1=$(commit_at "$FIX" 300 "C1")
# shellcheck disable=SC2034
C2=$(commit_at "$FIX" 20 "C2")
C3=$(commit_at "$FIX" 10 "C3")
C4=$(commit_at "$FIX" 2 "C4")
C5=$(commit_at "$FIX" 0 "C5 head")   # HEAD

FORGED="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

mk_repo() { mkdir -p "$1/.github/workflows"; }

# Write a consumer workflow that pins one standards reusable at $sha.
write_pin() { # file reusable sha
  cat > "$1" <<EOF
name: Consumer
on: push
jobs:
  job:
    uses: hyperpolymath/standards/.github/workflows/$2@$3
EOF
}

PASS=0
TOTAL=0

# run_case desc expected_exit repo [VAR=VAL ...]
run_case() {
  local desc="$1" expected="$2" repo="$3"; shift 3
  TOTAL=$((TOTAL + 1))
  set +e
  # Pin a non-canonical repository ID before "$@" (which may override it):
  # this suite itself runs in standards CI, whose inherited canonical ID
  # would otherwise make every consumer fixture self-identify as the canon.
  env GITHUB_REPOSITORY="hyperpolymath/test-repo" \
    GITHUB_REPOSITORY_ID=0 GITHUB_SERVER_URL=https://github.com \
    "$@" \
    STALENESS_STANDARDS_DIR="$FIX" \
    bash "$CHECK_SCRIPT" "$repo" >/dev/null 2>&1
  local rc=$?
  set -e
  if [ "$rc" -eq "$expected" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit $expected, got $rc)"
  fi
}

# run_case_out desc expected_exit expected_output_regex repo [VAR=VAL ...]
# As run_case, but also asserts the gate said the right thing — an exit code
# alone cannot tell "passed silently" from "passed with the advisory notice
# the propagation path depends on".
run_case_out() {
  local desc="$1" expected="$2" regex="$3" repo="$4"; shift 4
  TOTAL=$((TOTAL + 1))
  local out rc
  set +e
  out=$(env GITHUB_REPOSITORY="hyperpolymath/test-repo" \
    GITHUB_REPOSITORY_ID=0 GITHUB_SERVER_URL=https://github.com \
    "$@" \
    STALENESS_STANDARDS_DIR="$FIX" \
    bash "$CHECK_SCRIPT" "$repo" 2>&1)
  rc=$?
  set -e
  # A leading '!' inverts the match: assert the gate did NOT say this.
  local want=0
  case "$regex" in '!'*) want=1; regex="${regex#!}" ;; esac
  local got=0
  printf '%s' "$out" | grep -qE "$regex" || got=1
  if [ "$rc" -eq "$expected" ] && [ "$got" -eq "$want" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit $expected + /$regex/, got exit $rc)"
  fi
}

# ── 1. FRESH: pin == HEAD ───────────────────────────────────────────────────
R="$TEST_DIR/fresh"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C5"
run_case "fresh pin (== HEAD) passes" 0 "$R"

# ── 2. IN_WINDOW recent (default window) ────────────────────────────────────
R="$TEST_DIR/recent"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C4"
run_case "recent pin (2d, 1 behind) passes under default window" 0 "$R"

# ── 3. IN_WINDOW via the DAYS axis (commits axis disabled) ──────────────────
R="$TEST_DIR/days"; mk_repo "$R"
write_pin "$R/.github/workflows/hypatia.yml" "hypatia-scan-reusable.yml" "$C3"
run_case "10d/2-behind pin passes on days axis (window 1 commit / 14 days)" 0 "$R" \
  STALENESS_WINDOW_COMMITS=1 STALENESS_WINDOW_DAYS=14

# ── 4. IN_WINDOW via the COMMITS axis (days axis disabled) ──────────────────
R="$TEST_DIR/commits"; mk_repo "$R"
write_pin "$R/.github/workflows/scorecard.yml" "scorecard-reusable.yml" "$C1"
run_case "300d/4-behind pin passes on commits axis (window 5 commits / 1 day)" 0 "$R" \
  STALENESS_WINDOW_COMMITS=5 STALENESS_WINDOW_DAYS=1

# ── 5. OUT_OF_WINDOW: outside both axes -> ADVISORY, not a failure ──────────
# Contract change (2026-07-21): age alone no longer fails. Making it fail turned
# the gate into a clock that reddened the whole fleet ~14 days after every
# propagation (294 of 350 consumers, one pin, nothing wrong with any of them).
# The pin must still be *reported* so the propagation path has something to act
# on — hence the output assertion, not just the exit code.
R="$TEST_DIR/stale"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C0"
run_case_out "ancient pin (400d, 5 behind) passes with an advisory notice" 0 \
  '::notice.*outside the recency window' "$R" \
  STALENESS_WINDOW_COMMITS=2 STALENESS_WINDOW_DAYS=14

# ── 5b. KNOWN-BAD: pin predates a named defect fix -> hard fail at any age ───
# The deny-list is what the window was only ever proxying for. Strictly better
# in both directions: it catches this, and it does not punish 5 above.
R="$TEST_DIR/knownbad"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C1"
run_case_out "pin predating a known-bad fix fails regardless of window" 1 \
  'predates.*carries the' "$R" \
  STALENESS_WINDOW_COMMITS=9999 STALENESS_WINDOW_DAYS=9999 \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C3"

# ── 5c. KNOWN-BAD outranks freshness: an IN-WINDOW pin is still rejected ─────
R="$TEST_DIR/knownbad-fresh"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C4"
run_case "in-window pin carrying a known defect still fails" 1 "$R" \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C5"

# ── 5d. The fix commit itself is NOT denied (boundary is strict) ─────────────
R="$TEST_DIR/knownbad-boundary"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C3"
run_case "the fixing commit itself is not denied" 0 "$R" \
  STALENESS_WINDOW_COMMITS=9999 STALENESS_WINDOW_DAYS=9999 \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C3"

# ── 5e. The deny-list is scoped per reusable, not applied globally ───────────
R="$TEST_DIR/knownbad-scope"; mk_repo "$R"
write_pin "$R/.github/workflows/scorecard.yml" "scorecard-reusable.yml" "$C1"
run_case "a deny-list entry for another reusable does not fail this one" 0 "$R" \
  STALENESS_WINDOW_COMMITS=9999 STALENESS_WINDOW_DAYS=9999 \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C5"

# ── 6. UNKNOWN / forged SHA -> fail ─────────────────────────────────────────
R="$TEST_DIR/forged"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$FORGED"
run_case "forged pin (not a standards commit) fails" 1 "$R"

# ── 7. AHEAD: consumer pins a descendant of the gate's HEAD view -> pass ────
R="$TEST_DIR/ahead"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C5"
run_case "consumer ahead of gate HEAD passes" 0 "$R" STALENESS_EXPECTED_SHA="$C4"

# ── 8. Retired scorecard-enforcer.yml in a consumer -> fail ─────────────────
R="$TEST_DIR/enforcer"; mk_repo "$R"
touch "$R/.github/workflows/scorecard-enforcer.yml"
run_case "retired scorecard-enforcer.yml fails" 1 "$R"

# ── 9. Consumer-owned direct Scorecard SARIF upload -> fail ────────────────
R="$TEST_DIR/sarif"; mk_repo "$R"
cat > "$R/.github/workflows/scorecard.yml" <<'EOF'
name: Scorecard
on: push
jobs:
  scorecard:
    steps:
      - uses: ossf/scorecard-action@abc
      - uses: github/codeql-action/upload-sarif@xyz
EOF
run_case "consumer direct Scorecard SARIF upload fails" 1 "$R"

# The standards repository contains the canonical reusable that consumers call.
# Its uploader is the controlled source, not a forbidden ad hoc consumer copy.
run_case "canonical standards Scorecard SARIF uploader passes" 0 "$R" \
  GITHUB_REPOSITORY=hyperpolymath/standards

# The repository was transferred to metadatastician/standards; self-recognition
# tied to the old slug made the canon fail its own consumer rules (2026-10-25).
run_case "transferred slug metadatastician/standards is still the canon" 0 "$R" \
  GITHUB_REPOSITORY=metadatastician/standards

# Candidate-controlled files are NOT identity evidence, even when the deed
# recites the canon's repository UUID: a consumer can copy all three files to
# exempt itself from the consumer-only SARIF/retired-enforcer rules.
cat > "$R/standards_chora.deed" <<'EOF'
(repo-deed
  :canonical-name "standards"
  :repo-uuid #u8"gv-clade-index:github.com/hyperpolymath/standards")
EOF
mkdir -p "$R/scripts"
touch "$R/scripts/check-workflow-staleness.sh" "$R/.github/workflows/scorecard-reusable.yml"
run_case "copied canon files cannot self-grant standards identity" 1 "$R" \
  GITHUB_REPOSITORY=example/renamed-again
rm -f "$R/standards_chora.deed" "$R/scripts/check-workflow-staleness.sh" \
      "$R/.github/workflows/scorecard-reusable.yml"

# A future rename changes the slug but not GitHub's immutable repository ID,
# so that platform-supplied signal still recognises the canon.
run_case "immutable repository ID recognises the canon under a future slug" 0 "$R" \
  GITHUB_REPOSITORY=example/renamed-again GITHUB_REPOSITORY_ID=1116521501

# The origin fallback requires a real owner boundary: an owner that merely
# ends in a known slug (evil-hyperpolymath) is not the canon.
git -C "$R" init -q
git -C "$R" remote add origin https://github.com/evil-hyperpolymath/standards
run_case "lookalike owner suffix in origin is not standards" 1 "$R" \
  GITHUB_REPOSITORY=example/renamed-again
git -C "$R" remote set-url origin git@github.com:metadatastician/standards.git
run_case "checkout origin identifies the canon when the slug signal is stale" 0 "$R" \
  GITHUB_REPOSITORY=example/renamed-again

# ── 10. No workflows dir -> pass ────────────────────────────────────────────
R="$TEST_DIR/empty"; mkdir -p "$R"
run_case "no .github/workflows passes" 0 "$R"

# ── 11. Commented-out pin is ignored (ancient SHA, but in a comment) ────────
R="$TEST_DIR/commented"; mk_repo "$R"
cat > "$R/.github/workflows/governance.yml" <<EOF
name: Consumer
on: push
jobs:
  job:
    # example: uses: hyperpolymath/standards/.github/workflows/governance-reusable.yml@$C0
    uses: hyperpolymath/standards/.github/workflows/governance-reusable.yml@$C5
EOF
run_case "commented-out ancient pin is ignored; active fresh pin passes" 0 "$R"

# ── 12. Clean multi-reusable repo (all three at a recent SHA) -> pass ───────
R="$TEST_DIR/multi"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C4"
write_pin "$R/.github/workflows/hypatia.yml" "hypatia-scan-reusable.yml" "$C4"
write_pin "$R/.github/workflows/scorecard.yml" "scorecard-reusable.yml" "$C4"
run_case "clean multi-reusable repo passes" 0 "$R"

# ── 13. THE PRODUCTION PATH: partial clone, where a local negative is not
#       trustworthy ──────────────────────────────────────────────────────────
# In CI the governance reusable clones standards with `--filter=tree:0`, so the
# checkout is ALWAYS partial — and `merge-base --is-ancestor` is measured
# unreliable there (awesome-haskell, four consecutive runs). Cases 1-12 all run
# against a complete `git init` fixture, so none of them exercise the code that
# actually protects production. Mark the fixture partial to reach it.
#
# The API is pointed at a closed port so these stay hermetic and fast: the
# question is what the gate does when it can neither trust the clone nor reach
# the server.
UNREACHABLE="http://127.0.0.1:1"
git -C "$FIX" config remote.origin.promisor true

# 13a. A local POSITIVE is still trusted — a deny must not need the network.
R="$TEST_DIR/partial-deny"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C1"
run_case_out "partial clone: local positive still denies without the network" 1 \
  'predates' "$R" \
  STALENESS_WINDOW_COMMITS=9999 STALENESS_WINDOW_DAYS=9999 \
  STALENESS_API_BASE="$UNREACHABLE" \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C3"

# 13b. A local NEGATIVE must NOT be silently accepted. Unverifiable is reported
#      as SKIPPED — "could not check" must never read as "passed".
R="$TEST_DIR/partial-unchecked"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C4"
run_case_out "partial clone: unverifiable deny-list check is reported SKIPPED, not passed" 0 \
  'SKIPPED, not passed' "$R" \
  STALENESS_WINDOW_COMMITS=9999 STALENESS_WINDOW_DAYS=9999 \
  STALENESS_API_BASE="$UNREACHABLE" \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C3"

# 13b-redirect. The standards transfer must not turn the degraded-history
# fallback into a skipped known-bad check. The fake API redirects the old
# repository name but answers the canonical name; no real network is used.
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/curl" <<'CURL'
#!/usr/bin/env bash
url="${!#}"
printf '%s\n' "$url" >> "$STALENESS_TEST_API_LOG"
case "$url" in
  */repos/metadatastician/standards/compare/*|*/repos/example/fork/compare/*)
    printf '{"status":"ahead","ahead_by":1,"behind_by":0}\n200' ;;
  */repos/hyperpolymath/standards/compare/*)
    printf '{"message":"Moved Permanently"}\n301' ;;
  *) printf '{"message":"Not Found"}\n404' ;;
esac
CURL
chmod +x "$MOCK_BIN/curl"
API_LOG="$TEST_DIR/api-requests"
: > "$API_LOG"
# C4 is locally after C3, so the partial clone's negative answer must take
# the server fallback. The mock's positive answer must still reject the pin.
run_case_out "partial clone: canonical default API retains known-bad rejection" 1 \
  'predates.*carries the' "$R" \
  PATH="$MOCK_BIN:$PATH" STALENESS_TEST_API_LOG="$API_LOG" \
  STALENESS_STANDARDS_NWO="" \
  STALENESS_API_BASE="https://api.example.invalid" \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C3"
run_case_out "partial clone: explicit old-owner redirect remains visibly unchecked" 0 \
  'SKIPPED, not passed' "$R" \
  PATH="$MOCK_BIN:$PATH" STALENESS_TEST_API_LOG="$API_LOG" \
  STALENESS_STANDARDS_NWO="hyperpolymath/standards" \
  STALENESS_API_BASE="https://api.example.invalid" \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C3"
run_case_out "partial clone: explicit repository override retains known-bad rejection" 1 \
  'predates.*carries the' "$R" \
  PATH="$MOCK_BIN:$PATH" STALENESS_TEST_API_LOG="$API_LOG" \
  STALENESS_STANDARDS_NWO="example/fork" \
  STALENESS_API_BASE="https://api.example.invalid" \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C3"

# 13c. A complete clone's negative IS trusted — no warning, no network.
git -C "$FIX" config --unset remote.origin.promisor
R="$TEST_DIR/complete-quiet"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C4"
run_case_out "complete clone: local negative is trusted silently (no SKIPPED warning)" 0 \
  '!SKIPPED' "$R" \
  STALENESS_WINDOW_COMMITS=9999 STALENESS_WINDOW_DAYS=9999 \
  STALENESS_API_BASE="$UNREACHABLE" \
  STALENESS_KNOWN_BAD_BEFORE="governance-reusable.yml:$C3"

# ── 14. THE REPOSITORY'S OWN NAME, AFTER THE ORG RENAME ─────────────────────
# The canon's self-scan is only skipped when the gate recognises the repo it is
# running in. `hyperpolymath/standards` -> `metadatastician/standards` made that
# recognition FALSE, so the canon ran the consumer-only structural rules against
# its own reusable workflows and failed on the file that publishes Scorecard
# SARIF FOR the estate. These three cases pin both spellings, and pin that a
# consumer is still treated as a consumer.
#
# The fixture repo root has no .git, so the remote fallback cannot rescue a miss:
# only the GITHUB_REPOSITORY comparison can make these pass.
R="$TEST_DIR/canon-new-owner"; mk_repo "$R"
cp "$FIX"/.github/workflows/*.yml "$R/.github/workflows/" 2>/dev/null || true
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C5"
# These direct invocations need the same identity isolation as run_case:
# the host CI repository ID must not override the fixture's slug.
TOTAL=$((TOTAL + 1))
set +e
env GITHUB_REPOSITORY_ID=0 GITHUB_SERVER_URL=https://github.com \
  GITHUB_REPOSITORY="metadatastician/standards" \
  STALENESS_STANDARDS_DIR="$FIX" \
  bash "$CHECK_SCRIPT" "$R" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "PASS: canon under the NEW owner name is recognised as standards (rename regression)"
  PASS=$((PASS + 1))
else
  echo "FAIL: canon under the new owner name ran consumer rules (exit $rc)"
fi

R="$TEST_DIR/canon-old-owner"; mk_repo "$R"
write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C5"
TOTAL=$((TOTAL + 1))
set +e
env GITHUB_REPOSITORY_ID=0 GITHUB_SERVER_URL=https://github.com \
  GITHUB_REPOSITORY="hyperpolymath/standards" \
  STALENESS_STANDARDS_DIR="$FIX" \
  bash "$CHECK_SCRIPT" "$R" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "PASS: canon under the LEGACY owner name is still recognised as standards"
  PASS=$((PASS + 1))
else
  echo "FAIL: canon under the legacy owner name ran consumer rules (exit $rc)"
fi

# Both directions of the same switch, asserted behaviourally rather than by
# reading the script: the retired-enforcer rule applies to a CONSUMER and is
# waived for the CANON. A lookalike owner (someone/standards) must stay a
# consumer — nothing may be promoted to canon by its name looking similar.
for owner in "someone/standards" "metadatastician/standards"; do
  R="$TEST_DIR/enforcer-${owner%%/*}"; mk_repo "$R"
  write_pin "$R/.github/workflows/governance.yml" "governance-reusable.yml" "$C5"
  : > "$R/.github/workflows/scorecard-enforcer.yml"
  TOTAL=$((TOTAL + 1))
  set +e
  out=$(env GITHUB_REPOSITORY_ID=0 GITHUB_SERVER_URL=https://github.com \
    GITHUB_REPOSITORY="$owner" \
    STALENESS_STANDARDS_DIR="$FIX" \
    bash "$CHECK_SCRIPT" "$R" 2>&1)
  rc=$?
  set -e
  if [ "$owner" = "someone/standards" ]; then
    # Consumer: the retired enforcer is a hard error.
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'scorecard-enforcer.yml is retired'; then
      echo "PASS: a lookalike owner is still a consumer (retired enforcer is a hard error)"
      PASS=$((PASS + 1))
    else
      echo "FAIL: lookalike owner was waived as canon (exit $rc)"
    fi
  else
    # Canon: the same file is the canonical history, not a consumer mistake.
    if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'scorecard-enforcer.yml is retired'; then
      echo "PASS: the canon itself is exempt from the consumer-only retired-enforcer rule"
      PASS=$((PASS + 1))
    else
      echo "FAIL: canon ran consumer rules on its own workflows (exit $rc)"
    fi
  fi
done

echo "----------------------------------------"
echo "$PASS/$TOTAL test cases passed."
[ "$PASS" -eq "$TOTAL" ] || { echo "Some regression tests FAILED."; exit 1; }
echo "All regression tests passed!"
exit 0
