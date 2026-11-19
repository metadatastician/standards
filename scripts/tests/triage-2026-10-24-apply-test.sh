#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# triage-2026-10-24-apply-test.sh — regression tests for
# scripts/triage-2026-10-24-apply.sh and the 2026-10-24 backlog classification.
#
# The script closes GitHub issues, so every test runs against a `gh` shim on
# PATH: nothing here touches the network, and a test failure cannot close an
# issue. What is asserted is exactly the contract the document claims:
#   * the CSV is complete (one row per open issue, unique, valid tiers);
#   * --report needs no network;
#   * dry-run writes nothing;
#   * --apply comments then closes every tier-C issue, and nothing else;
#   * an already-closed issue is skipped rather than re-commented.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUT="$SCRIPT_DIR/../triage-2026-10-24-apply.sh"
CSV="$ROOT/docs/triage/2026-10-24-issue-classification.csv"
DOC="$ROOT/docs/triage/2026-10-24-issue-classification.adoc"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

WORK_CLASSIFICATION="$(mktemp -d)"
trap 'rm -rf "$WORK_CLASSIFICATION"' EXIT

# 1. The subject exists and parses.
[ -f "$SUT" ] || fail "$SUT does not exist"
bash -n "$SUT" || fail "$SUT does not parse"
pass "script exists and parses"

# 2. The classification artifacts exist and agree with each other.
[ -f "$CSV" ] || fail "$CSV does not exist"
[ -f "$DOC" ] || fail "$DOC does not exist"

# Parsed with the same converter the SUT uses: a raw `grep ,` or `-F,` would
# be wrong on the rows whose quoted fields contain commas, and a validation
# that mis-parses its input certifies the wrong document.
TSV="$WORK_CLASSIFICATION/classification.tsv"
awk -f "$ROOT/scripts/lib/csv-to-tsv.awk" "$CSV" > "$TSV" \
  || fail "CSV does not parse with csv-to-tsv.awk"

rows="$(awk 'END { print NR - 1 }' "$TSV")"
[ "$rows" -gt 0 ] || fail "CSV has no rows"

# Column count is taken from the HEADER, not hardcoded: adding a column to the
# classification (the 2026-10-25 recheck note was the first) must not fail a
# validation whose only real invariant is "every row has the header's shape".
problems="$(awk -F'\t' '
  NR == 1 { want = NF; next }
  NF != want          { print "row " NR ": " NF " fields, header has " want }
  seen[$1]++          { print "row " NR ": duplicate issue number " $1 }
  $3 !~ /^[CQSEDRU]$/ { print "row " NR ": unknown tier code " $3 }
  $12 ~ /^[ \t]*$/    { print "row " NR ": no note" }
' "$TSV")"
[ -z "$problems" ] || fail "$problems"

for t in C Q S E D R U; do
  grep -q "== Tier $t " "$DOC" || fail "document has no Tier $t section"
done
grep -q "$rows" "$DOC" || fail "document does not state the total ($rows)"

tier_counts="$(awk -F'\t' 'NR > 1 { c[$3]++ } END {
  for (t in c) printf "%s=%d ", t, c[t] }' "$TSV" | sed 's/ *$//')"
pass "$rows classified issues ($tier_counts), unique numbers, every row annotated, every tier has a section"

# 3. --report must not need the network at all: run it with an empty PATH for gh.
REPORT_OUT="$(PATH="/usr/bin:/bin" bash "$SUT" --report)" || fail "--report failed without gh on PATH"
grep -q 'total' <<<"$REPORT_OUT" || fail "--report printed no total"
grep -qE 'C +close now' <<<"$REPORT_OUT" || fail "--report did not summarise tier C"
pass "--report works with no gh on PATH"

# 4. Everything below uses a shim gh.
WORK="$(mktemp -d)"
# Both directories: an EXIT trap replaces the previous one, so the shim's
# cleanup must also remove the classification workspace created above.
trap 'rm -rf "$WORK" "$WORK_CLASSIFICATION"' EXIT
CALLS="$WORK/calls.log"
: > "$CALLS"

cat > "$WORK/gh" <<'SHIM'
#!/usr/bin/env bash
# Records every invocation, then behaves just enough like gh for the SUT.
printf '%s\n' "$*" >> "$SHIM_CALLS"
case "${1:-} ${2:-}" in
  "issue view") printf '%s\n' "${SHIM_STATE:-OPEN}" ;;
  "issue comment") : ;;
  "issue close") : ;;
  *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$WORK/gh"

run_sut() { SHIM_CALLS="$CALLS" PATH="$WORK:$PATH" bash "$SUT" "$@"; }

C_TIER="$(awk -F'\t' 'NR > 1 && $3 == "C"' "$TSV" | wc -l | tr -d ' ')"
[ "$C_TIER" -gt 0 ] || fail "tier C is empty, nothing to apply"

# 4a. Dry-run: reads state, writes nothing.
run_sut > /dev/null || fail "dry-run failed"
grep -q 'issue view' "$CALLS" || fail "dry-run did not read issue state"
if grep -qE '^issue (close|comment)' "$CALLS"; then
  fail "dry-run issued a write ($(grep -cE '^issue (close|comment)' "$CALLS") writes)"
fi
pass "dry-run reads state and writes nothing"

# 4b. Apply: one comment and one close per tier-C issue, and nothing else.
: > "$CALLS"
run_sut --apply > /dev/null || fail "--apply failed"
closes="$(grep -cE '^issue close ' "$CALLS" || true)"
comments="$(grep -cE '^issue comment ' "$CALLS" || true)"
[ "$closes" = "$C_TIER" ] || fail "--apply closed $closes issues, expected $C_TIER"
[ "$comments" = "$C_TIER" ] || fail "--apply commented $comments times, expected $C_TIER"

# Every close names an issue number; every one of them is a tier-C number.
tier_c="$(awk -F'\t' 'NR > 1 && $3 == "C" { print $1 }' "$TSV" | sort -n)"
closed="$(awk '$1 == "issue" && $2 == "close"   { print $3 }' "$CALLS" | sort -n)"
commented="$(awk '$1 == "issue" && $2 == "comment" { print $3 }' "$CALLS" | sort -n)"

[ -n "$tier_c" ] || fail "tier C is empty in the CSV"
[ "$closed" = "$tier_c" ] \
  || fail "--apply closed a set that is not tier C"$'\n'"  tier C: $(printf '%s' "$tier_c" | tr '\n' ' ')"$'\n'"  closed: $(printf '%s' "$closed" | tr '\n' ' ')"
[ "$commented" = "$closed" ] || fail "a close was not preceded by a comment"
[ "$closed" = "$(printf '%s\n' "$closed" | sort -un)" ] \
  || fail "an issue was closed twice"

pass "--apply commented and closed exactly the $(printf '%s\n' "$closed" | wc -l | tr -d ' ') tier-C issues, nothing else"

# 4c. Idempotence: an already-closed issue is skipped, never re-commented.
: > "$CALLS"
SHIM_STATE=CLOSED run_sut --apply > /dev/null || fail "--apply failed when issues were already closed"
if grep -qE '^issue (close|comment)' "$CALLS"; then
  fail "already-closed issues were written to again"
fi
pass "already-closed issues are skipped"

printf '\nall triage-2026-10-24 assertions passed\n'
