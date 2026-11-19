#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Tests for scripts/dismiss-code-scanning-alerts.sh — the allowlist matcher
# that decides which code-scanning alerts may be dismissed.
#
# The point of these cases is the NEGATIVE direction. A matcher that dismisses
# too little is visible (the alerts stay open); one that dismisses too much
# hides a real finding behind a neighbour's rationale, and nothing in CI would
# ever say so. So every case here asserts an alert was NOT matched:
#
#   same rule id, different file      -> must not match
#   same rule id, same file, new line -> must not match
#   aggregate rule (no path) but the   -> must not match
#     entry names a real path
#   already dismissed / fixed         -> must not be re-dismissed
#
# Run: bash scripts/tests/dismiss-code-scanning-alerts-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/scripts/dismiss-code-scanning-alerts.sh"
FIXTURE="$HERE/fixtures/code-scanning-alerts.json"
ALLOWLIST="$ROOT/.github/code-scanning-dismissals.json"

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
# check NAME -- COMMAND [ARGS...]
# Runs COMMAND directly (never a string to re-parse); it passes when COMMAND exits 0.
check() {
  local name="$1"; shift
  [ "${1:-}" = "--" ] && shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
# jq_eq WANT JQ_ARGS...: the jq output equals WANT.
jq_eq() { local want="$1"; shift; [ "$(jq "$@")" = "$want" ]; }
# exit_is WANT COMMAND [ARGS...]: COMMAND, output discarded, exits WANT.
exit_is() { local want="$1"; shift; "$@" >/dev/null 2>&1; [ $? -eq "$want" ]; }

# Matches the script prints, as space-separated alert numbers.
# The fixture is stored as {"alerts": [...]} so each case can build a feed with
# jq; the script's contract is a bare array, so normalise here.
plan() {
  local feed
  feed="$(mktemp)"
  jq 'if type == "object" then .alerts else . end' "$1" > "$feed"
  ALERTS_JSON="$feed" bash "$SCRIPT" --repo test/repo 2>/dev/null \
    | sed -n 's/^  #\([0-9]\+\) .*/\1/p' | sort -n | tr '\n' ' '
  rm -f "$feed"
}

# Every path/line record must still point at a write-permission declaration
# in the workflow it claims to describe. A dismissal whose line has drifted
# is worse than an absent dismissal: it looks reasoned and specific while
# no longer matching the alert it was written for.
recorded_lines_grounded() {
  local path line text seen=0
  while IFS=$'\t' read -r path line; do
    seen=$((seen + 1))
    [ -f "$ROOT/$path" ] || {
      printf 'recorded workflow does not exist: %s\n' "$path" >&2
      return 1
    }
    text="$(sed -n "${line}p" "$ROOT/$path")"
    if grep -Eq '^[[:space:]]*#' <<<"$text"; then
      printf '%s:%s is a comment, not a permission: %s\n' "$path" "$line" "$text" >&2
      return 1
    fi
    grep -Eq '"?[A-Za-z-]+"?[[:space:]]*:[[:space:]]*"?write"?([[:space:],}]|$)' <<<"$text" || {
      printf '%s:%s is not a write permission: %s\n' "$path" "$line" "$text" >&2
      return 1
    }
  done < <(jq -r '.dismissals[] | select(.rule_id=="TokenPermissionsID") | [.path, .line] | @tsv' "$ALLOWLIST")
  [ "$seen" -gt 0 ]
}

echo "== allowlist is valid and every entry is specific =="
allowlist_parses() { jq -e . "$ALLOWLIST" >/dev/null; }
check "allowlist parses as JSON" -- allowlist_parses
check "no entry is path-less AND line-less without a rule that needs it" -- \
  jq_eq 1 '[.dismissals[] | select(.path==null and .line==null) | .rule_id] | length' "$ALLOWLIST"
check "the only path-less entry is the aggregate SASTID finding" -- \
  jq_eq SASTID -r '[.dismissals[] | select(.path==null and .line==null) | .rule_id] | join(",")' "$ALLOWLIST"
check "every TokenPermissionsID entry names both a path and a line" -- \
  jq_eq 0 '[.dismissals[] | select(.rule_id=="TokenPermissionsID") | select(.path==null or .line==null)] | length' "$ALLOWLIST"
check "every entry carries a reasoned comment" -- \
  jq_eq 0 '[.dismissals[] | select((.comment|length) < 40)] | length' "$ALLOWLIST"
check "every recorded TokenPermissionsID line is still a write permission" -- \
  recorded_lines_grounded

echo "== the real alert set matches exactly the eight token-permission + one SAST =="
M="$(plan "$FIXTURE")"
# plan_is WANT FEED: the matches plan() prints for FEED equal WANT.
plan_is() { [ "$(plan "$2")" = "$1" ]; }
check "matches 101 102 103 104 105 106 107 108 109 (got: $M)" -- \
  test "$M" = '101 102 103 104 105 106 107 108 109 '

echo "== negatives: a near-miss must never be dismissed =="
mk() { jq --argjson n "$1" --arg rule "$2" --arg path "$3" --argjson line "$4" \
        '.alerts = [{number: $n, state: "open", rule: {id: $rule},
                     most_recent_instance: {location: {path: $path, start_line: $line}}}]' \
        "$FIXTURE"; }

check "same rule+line, different file: no match" -- \
  plan_is '' <(mk 201 TokenPermissionsID .github/workflows/branch-protection.yml 193)
check "same rule+file, new line: no match" -- \
  plan_is '' <(mk 202 TokenPermissionsID .github/workflows/debt-measure.yml 52)
check "the old deep-recon line does not match the corrected dismissal" -- \
  plan_is '' <(mk 206 TokenPermissionsID .github/workflows/deep-recon-reusable.yml 70)
check "the old Hypatia reusable line is no longer dismissed" -- \
  plan_is '' <(mk 207 TokenPermissionsID .github/workflows/hypatia-scan-reusable.yml 62)
check "the comment line above the Hypatia caller permission is not the dismissal" -- \
  plan_is '' <(mk 210 TokenPermissionsID .github/workflows/hypatia-scan.yml 25)
check "the comment line above the reusable-workflow permission is not the dismissal" -- \
  plan_is '' <(mk 211 TokenPermissionsID .github/workflows/hypatia-scan-reusable.yml 107)
check "the reusable's line before block-on-critical is no longer dismissed" -- \
  plan_is '' <(mk 213 TokenPermissionsID .github/workflows/hypatia-scan-reusable.yml 98)
check "the comment line above the fork-governance permission is not the dismissal" -- \
  plan_is '' <(mk 212 TokenPermissionsID .github/workflows/fork-governance.yml 288)
check "the old fork-governance line is no longer dismissed" -- \
  plan_is '' <(mk 208 TokenPermissionsID .github/workflows/fork-governance.yml 81)
check "the current fork-governance permission line is matched" -- \
  plan_is '209 ' <(mk 209 TokenPermissionsID .github/workflows/fork-governance.yml 289)
check "aggregate rule with a real path does not inherit the SASTID entry" -- \
  plan_is '' <(mk 204 SASTID .github/workflows/ci.yml 12)
check "unlisted rule id: no match" -- \
  plan_is '' <(mk 203 PinnedDependenciesID 9-archive/x/setup.sh.template 144)
check "a new binary-artifact alert is not auto-dismissed" -- \
  plan_is '' <(mk 205 BinaryArtifactsID 2-protocols/axel/casket-ssg 1)

echo "== only OPEN alerts are considered =="
check "dismissed and fixed alerts are not re-dismissed" -- \
  plan_is '' <(jq '{alerts: [ .alerts[] | select(.number==301 or .number==302) ]}' "$FIXTURE")

echo "== fail-closed behaviour =="
# json_body N: a temp file holding just the N-alert array under test
FEED_TMP="$(mktemp)"; jq '.alerts' "$FIXTURE" > "$FEED_TMP"
trap 'rm -f "$FEED_TMP"' EXIT

check "missing allowlist exits 2" -- \
  exit_is 2 env ALERTS_JSON="$FEED_TMP" bash "$SCRIPT" --allowlist /nonexistent --repo t/r

tmp_bad="$(mktemp)"
jq '.dismissals += [{rule_id:"TokenPermissionsID", reason:"because", comment:"short", path:"p", line:1}]' \
  "$ALLOWLIST" > "$tmp_bad"
check "an entry with a bad reason exits 2" -- \
  exit_is 2 env ALERTS_JSON="$FEED_TMP" bash "$SCRIPT" --allowlist "$tmp_bad" --repo t/r

jq '.dismissals += [{rule_id:"TokenPermissionsID", reason:"won'"'"'t fix", comment:"a comment long enough to pass the length check", path:"p", line:1}]' \
  "$ALLOWLIST" > "$tmp_bad"
check "a valid extra entry exits 0 (control for the case above)" -- \
  exit_is 0 env ALERTS_JSON="$FEED_TMP" bash "$SCRIPT" --allowlist "$tmp_bad" --repo t/r
rm -f "$tmp_bad"

echo "== dry run by default =="
plan_only_shown() { grep -q 'Plan only' <<<"$(ALERTS_JSON="$FEED_TMP" bash "$SCRIPT" --repo test/repo 2>&1)"; }
check "without --apply the script never calls the API" -- plan_only_shown

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
