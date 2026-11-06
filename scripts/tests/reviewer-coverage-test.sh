#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
helper="$root/scripts/reviewer-coverage.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
reviews="$tmp/reviews.json"
comments="$tmp/comments.json"
printf '[[]]\n' > "$comments"
printf '[[]]\n' > "$reviews"
pass=0; fail=0
check() {
  if grep -Fq -- "$3" <<< "$2"; then printf 'PASS: %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); fi
}
snapshot() { bash "$helper" "$head" "$reviews" "$comments" "$head"; }
review() {
  jq -n --arg head "$head" --arg state "$1" --arg body "$2" \
    '[[{user:{login:"copilot-pull-request-reviewer[bot]"},commit_id:$head,state:$state,body:$body}]]' > "$reviews"
}
check 'silence is no review' "$(snapshot)" '| Copilot | NO REVIEW observed on this head |'
review COMMENTED 'Copilot was unable to review this pull request because the user who requested the review has insufficient remaining quota.'
report=$(snapshot)
check 'quota COMMENTED is no review' "$report" '| Copilot | NO REVIEW — quota exhausted on this head |'
printf '%s\n' "$report" > "$tmp/coverage.md"
review COMMENTED 'Copilot has reached their quota limit.'
check 'alternate known quota notice is no review' "$(snapshot)" 'NO REVIEW — quota exhausted on this head'
review COMMENTED 'Copilot was unable to review this pull request due to a service error.'
check 'other unavailable reviews are no review' "$(snapshot)" 'reviewer reported unavailable on this head'
for state in PENDING DISMISSED; do
  review "$state" 'Reviewed'
  check "$state is not current coverage" "$(snapshot)" 'only stale, pending or dismissed evidence'
done
for account in copilot-pull-request-reviewer 'copilot-pull-request-reviewer[bot]' 'chatgpt-codex-connector[bot]' coderabbitai 'coderabbitai[bot]'; do
  case "$account" in copilot*) name=Copilot ;; chatgpt*) name=Codex ;; *) name=CodeRabbit ;; esac
  jq -n --arg head "$head" --arg account "$account" \
    '[[{user:{login:$account},commit_id:$head,state:"COMMENTED",body:"Reviewed"}]]' > "$reviews"
  check "reviewer alias $account" "$(snapshot)" "| $name | review observed on this head"
done
review COMMENTED Reviewed
jq '.[0][0].commit_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$reviews" > "$tmp/stale.json"
mv "$tmp/stale.json" "$reviews"
check 'stale head is no review' "$(snapshot)" 'only stale, pending or dismissed evidence'
review CHANGES_REQUESTED Reviewed
check 'actual review is coverage, not approval' "$(snapshot)" 'review observed on this head (not an approval inference)'
for state in COMMENTED APPROVED CHANGES_REQUESTED; do
  review "$state" 'The retry path mishandles rate limit exceeded and review limit reached errors.'
  check "substantive $state discussing quotas remains coverage" "$(snapshot)" 'review observed on this head (not an approval inference)'
done
printf '[[]]\n' > "$reviews"
jq -n '[[{user:{login:"someone"},body:"Copilot was unable to review this pull request because of insufficient remaining quota."}]]' > "$comments"
check 'human text cannot impersonate bot' "$(snapshot)" '| Copilot | NO REVIEW observed on this head |'
jq -n '[[{user:{login:"copilot-pull-request-reviewer[bot]"},body:"Copilot was unable to review this pull request because of insufficient remaining quota."}]]' > "$comments"
check 'issue comment head remains unknown' "$(snapshot)" 'comment head unknown'
jq -n '[[{user:{login:"coderabbitai[bot]"},body:"## Rate limit exceeded\nPlease wait before retrying."}]]' > "$comments"
check 'standalone CodeRabbit quota notice is retained' "$(snapshot)" '| CodeRabbit | NO REVIEW on this head — unavailable/quota notice observed; comment head unknown |'
jq -n '[[{user:{login:"someone"},body:"## Rate limit exceeded\nPlease wait before retrying."}]]' > "$comments"
check 'standalone notice is scoped to CodeRabbit identity' "$(snapshot)" '| CodeRabbit | NO REVIEW observed on this head |'
printf '{}\n' > "$reviews"
if report=$(snapshot); then fail=$((fail+1)); else check 'bad response is indeterminate' "$report" 'INDETERMINATE'; fi
printf '[[]]\n' > "$reviews"
if report=$(bash "$helper" "$head" "$reviews" "$comments" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb); then fail=$((fail+1))
else check 'head race is indeterminate' "$report" 'INDETERMINATE'; fi
bash "$root/scripts/fork-governance-render.sh" --out "$tmp/render" \
  --deed-result success --k9-result success --k9-verdict green \
  --hypatia-result success --hypatia-verdict green --reviewer-coverage "$tmp/coverage.md" >/dev/null
check 'coverage is embedded in summary' "$(cat "$tmp/render/body.md")" 'NO REVIEW — quota exhausted on this head'
check 'coverage does not change badge' "$(cat "$tmp/render/badge.json")" 'brightgreen'
# Fill the body near its budget after reserving the publisher's footer.
# A nonempty grid replaces the missing-grid placeholder; calibrate its exact
# overhead first so the boundary assertion is independent of header prose.
printf x > "$tmp/large-grid.md"
bash "$root/scripts/fork-governance-render.sh" --out "$tmp/base" --k9-report "$tmp/large-grid.md" >/dev/null
overhead=$(( $(wc -c < "$tmp/base/body.md") - 1 ))
head -c "$((62940-overhead))" /dev/zero | tr '\0' x > "$tmp/large-grid.md"
bash "$root/scripts/fork-governance-render.sh" --out "$tmp/large" --k9-report "$tmp/large-grid.md" \
  --reviewer-coverage "$tmp/coverage.md" >/dev/null 2>&1
if [ "$(( $(wc -c < "$tmp/large/body.md") + 2048 ))" -le 65000 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
printf 'reviewer-coverage: passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
