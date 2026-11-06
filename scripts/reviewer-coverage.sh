#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Read-only metadata snapshot. No review request, approval or merge is issued.
set -euo pipefail
unknown() {
  printf 'reviewer-coverage: %s\n' "${1:-evidence could not be validated}" >&2
  printf '%s\n' '**External reviewer coverage (advisory snapshot)**' '' \
    'INDETERMINATE — evidence unavailable or head changed; no review or approval inferred.'
  exit 1
}
[ "$#" -eq 4 ] || unknown 'expected head, reviews, comments and checked head'
head="$1"
[[ "$head" =~ ^[a-f0-9]{40}$ ]] || unknown 'invalid head identifier'
[ "$head" = "$4" ] || unknown 'PR head changed during collection'
for file in "$2" "$3"; do
  jq -e 'type == "array" and all(.[]; type == "array")' "$file" >/dev/null 2>&1 || unknown 'invalid paginated evidence'
done

report=$(jq -nr --arg head "$head" --slurpfile reviews "$2" --slurpfile comments "$3" '
  # A substantive review can discuss rate limits. Only the known failure
  # notice shape in a COMMENTED review is an unavailable-review notice.
  def rabbit_notice: ((.user.login == "coderabbitai") or (.user.login == "coderabbitai[bot]")) and
    ((.state // "COMMENTED") == "COMMENTED") and
    ((.body // "") | test("^(<!-- coderabbit-ai-generated:v1 -->\\s*)?(#{1,6}\\s*)?(Review limit reached|Rate limit exceeded)[.!]?(\\r?\\n|$)"; "i"));
  def absent: rabbit_notice or (((.state // "COMMENTED") == "COMMENTED") and
    ((.body // "") | test("^\\s*((Copilot|Codex|CodeRabbit) (was )?(unable to|could not) review this pull request\\b|Copilot has reached (their|its|your) quota limit([.!]|$))"; "i")));
  def quota: rabbit_notice or (absent and ((.body // "" | split("\n")[0]) |
    test("insufficient remaining quota|quota.{0,40}(exhausted|exceeded)|quota limit|rate limit exceeded|review limit reached"; "i")));
  ($reviews[0] | flatten(1)) as $reviews |
  ($comments[0] | flatten(1)) as $comments |
  [
    {name:"Copilot", accounts:["copilot-pull-request-reviewer", "copilot-pull-request-reviewer[bot]"]},
    {name:"Codex", accounts:["chatgpt-codex-connector[bot]"]},
    {name:"CodeRabbit", accounts:["coderabbitai", "coderabbitai[bot]"]}
  ] | map(
    . as $reviewer |
    [$reviews[] | select(.user.login as $login | $reviewer.accounts | index($login))] as $own |
    [$own[] | select(.commit_id == $head and .state != "PENDING" and .state != "DISMISSED")] as $current |
    [$current[] | select((.state as $state | ["APPROVED","CHANGES_REQUESTED","COMMENTED"] | index($state)) and (absent | not))] as $completed |
    (if ($completed | length) > 0 then "review observed on this head (not an approval inference)"
     elif any($current[]; quota) then "NO REVIEW — quota exhausted on this head"
     elif any($current[]; absent) then "NO REVIEW — reviewer reported unavailable on this head"
     elif any($comments[]; (.user.login as $login | $reviewer.accounts | index($login)) and absent)
       then "NO REVIEW on this head — unavailable/quota notice observed; comment head unknown"
     elif ($own | length) > 0 then "NO REVIEW on this head — only stale, pending or dismissed evidence"
     else "NO REVIEW observed on this head" end) as $state |
    "| \($reviewer.name) | \($state) |"
  ) as $rows |
  (["**External reviewer coverage (advisory snapshot)**", "",
    "Head: `\($head)`. This is coverage, not a fourth lane or a merge verdict.",
    "Later reviews require a fresh summary run. Silence and quota failures never mean approval.", "",
    "| Reviewer | Evidence |", "|---|---|"] + $rows + [""]) | join("\n")
') || unknown 'evidence classification failed'
printf '%s\n' "$report"
