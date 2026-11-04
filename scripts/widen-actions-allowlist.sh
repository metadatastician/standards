#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Widen an ALREADY-selected caller's Actions allow-list without pruning.
# Dry-run by default. Usage: widen-actions-allowlist.sh owner/repo [--apply] [canon.json]
# This does not change the Actions posture, enabled state, SHA-pin setting, or
# either broad publisher flag. Flag changes require a separate policy decision.
set -euo pipefail
repo=${1:?usage: widen-actions-allowlist.sh owner/repo [--apply] [canon.json]}
shift
apply=false
if [ "${1:-}" = --apply ]; then apply=true; shift; fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
canon=${1:-"$root/config/settings/actions-allowlist.json"}
[ $# -le 1 ] || { echo 'too many arguments' >&2; exit 2; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'invalid owner/repo' >&2; exit 2; }
gh_bin=${GH_BIN:-gh}
command -v "$gh_bin" >/dev/null && command -v jq >/dev/null || { echo 'gh and jq are required' >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
valid='type == "object" and (.github_owned_allowed | type == "boolean") and
  (.verified_allowed | type == "boolean") and (.patterns_allowed | type == "array") and
  all(.patterns_allowed[]; type == "string" and length > 0)'
jq -se "length == 1 and (.[0] | $valid)" "$canon" >/dev/null || { echo 'invalid canonical allow-list' >&2; exit 2; }
"$gh_bin" api "repos/$repo/actions/permissions" > "$tmp/permissions" || {
  echo "Cannot read Actions permissions for $repo; no changes made" >&2; exit 3;
}
posture=$(jq -ser 'if length == 1 and (.[0].allowed_actions | type) == "string" then .[0].allowed_actions else error("invalid permissions") end' "$tmp/permissions") || { echo 'invalid Actions permissions response' >&2; exit 3; }
case "$posture" in
  selected) ;;
  all|local_only) echo "SKIP: $repo uses $posture, not selected; no posture was changed"; exit 0 ;;
  *) echo "Unsupported Actions posture '$posture'; no changes made" >&2; exit 3 ;;
esac
"$gh_bin" api "repos/$repo/actions/permissions/selected-actions" > "$tmp/live" || {
  echo "Cannot read the live selected-actions list for $repo; no changes made" >&2; exit 3;
}
jq -se "length == 1 and (.[0] | $valid)" "$tmp/live" >/dev/null || { echo 'invalid live allow-list; no changes made' >&2; exit 3; }
# Union, never replace: an exact canon PUT may delete repo-specific actions.
# Preserve both broad publisher flags EXACTLY: enabling verified publishers
# permits far more than the narrow reusable pattern and needs its own review.
jq -n --slurpfile live "$tmp/live" --slurpfile canon "$canon" '
  {github_owned_allowed: $live[0].github_owned_allowed,
   verified_allowed: $live[0].verified_allowed,
   patterns_allowed: (($live[0].patterns_allowed + $canon[0].patterns_allowed) | unique)}
' > "$tmp/payload"
echo "${repo}: selected; live $(jq '.patterns_allowed | length' "$tmp/live") patterns -> union $(jq '.patterns_allowed | length' "$tmp/payload") patterns"
echo "github_owned_allowed: $(jq -r '.github_owned_allowed' "$tmp/live") -> $(jq -r '.github_owned_allowed' "$tmp/payload"); verified_allowed: $(jq -r '.verified_allowed' "$tmp/live") -> $(jq -r '.verified_allowed' "$tmp/payload")"
for flag in github_owned_allowed verified_allowed; do
  if [ "$(jq -r --arg f "$flag" '.[$f]' "$canon")" = true ] &&
     [ "$(jq -r --arg f "$flag" '.[$f]' "$tmp/live")" = false ]; then
    echo "NOTICE: $flag remains false; the live-policy checker will report the canonical flag difference. Review any change separately."
  fi
done
if [ "$apply" = false ]; then
  echo 'DRY RUN: no settings changed. Review additions:'
  jq -r --slurpfile old "$tmp/live" '.patterns_allowed - $old[0].patterns_allowed | .[]' "$tmp/payload"
  exit 0
fi
"$gh_bin" api -X PUT "repos/$repo/actions/permissions/selected-actions" --input "$tmp/payload" >/dev/null || {
  echo "Selected-actions PUT failed for $repo; stop rollout and inspect the live policy" >&2; exit 1;
}
"$gh_bin" api "repos/$repo/actions/permissions/selected-actions" > "$tmp/after" || {
  echo "PUT completed but read-back failed for $repo; stop rollout and inspect manually" >&2; exit 1;
}
# A count alone is insufficient: a missing canonical entry can be replaced by
# an unrelated extra. Verify every requested AND pre-existing pattern and flag.
if ! jq -se --slurpfile expected "$tmp/payload" "length == 1 and (.[0] | $valid and
    ((\$expected[0].patterns_allowed - .patterns_allowed) | length == 0) and
    (.github_owned_allowed == \$expected[0].github_owned_allowed) and
    (.verified_allowed == \$expected[0].verified_allowed))" "$tmp/after" >/dev/null; then
  echo "Read-back did not preserve the full union/flags for $repo; stop rollout" >&2; exit 1
fi
echo "OK: $repo selected-actions union verified; canary before caller propagation"
