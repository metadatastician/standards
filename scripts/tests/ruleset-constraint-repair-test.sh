#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Check that plan-ruleset-constraint-repair.sh removes only the four retired
# constraints and, on explicit request, one confirmed-stale integration bypass.
set -euo pipefail

plan="$(cd "$(dirname "$0")/.." && pwd)/plan-ruleset-constraint-repair.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
same() { [ "$(jq -cS . <<<"$1")" = "$(jq -cS . <<<"$2")" ]; }

retained='[
  {"type":"required_signatures"},
  {"type":"pull_request","parameters":{"required_review_thread_resolution":true}},
  {"type":"required_status_checks","parameters":{"required_status_checks":[
    {"context":"scan / gitleaks","integration_id":15368}]}},
  {"type":"code_scanning","parameters":{"code_scanning_tools":["CodeQL"]}}
]'
retired='[{"type":"update"},{"type":"required_deployments"},{"type":"code_quality"},{"type":"code_coverage"}]'
jq -n --argjson r "$retained" --argjson x "$retired" '{
  id: 123, name: "Existing name", target: "branch", enforcement: "active",
  conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
  bypass_actors: [], rules: ($r + $x)
}' > "$tmp/fixture.json"
cp "$tmp/fixture.json" "$tmp/fixture.orig"

"$plan" "$tmp/fixture.json" > "$tmp/result.json"
same "$(jq .rules "$tmp/result.json")" "$retained" || fail 'Changed active protections'
same "$(jq .bypass_actors "$tmp/result.json")" '[]' || fail 'Changed bypass actors'
cmp -s "$tmp/fixture.json" "$tmp/fixture.orig" || fail 'Mutated input'
[ "$(jq '.rules | length' "$tmp/fixture.json")" = 8 ] || fail 'Mutated input'
jq -e 'has("id") | not' "$tmp/result.json" >/dev/null || fail 'Kept a read-only field'
"$plan" "$tmp/result.json" > "$tmp/again.json"
same "$(cat "$tmp/again.json")" "$(cat "$tmp/result.json")" || fail 'Not idempotent'

actors='[
  {"actor_type":"Integration","actor_id":288115,"bypass_mode":"always"},
  {"actor_type":"RepositoryRole","actor_id":288115,"bypass_mode":"pull_request"},
  {"actor_type":"Integration","actor_id":15368,"bypass_mode":"always"}
]'
jq --argjson a "$actors" '.bypass_actors = $a' "$tmp/fixture.json" > "$tmp/with-actors.json"
same "$("$plan" "$tmp/with-actors.json" | jq .bypass_actors)" "$actors" \
  || fail 'Changed actors without explicit selection'
same "$("$plan" "$tmp/with-actors.json" --remove-uninstalled-app 288115 | jq .bypass_actors)" \
  "$(jq '.[1:]' <<<"$actors")" || fail 'Removed an unrelated bypass'
for bad in 999 0 -288115 abc; do
  if "$plan" "$tmp/with-actors.json" --remove-uninstalled-app "$bad" >/dev/null 2>&1; then
    fail "Accepted an unknown app: $bad"
  fi
done
if "$plan" "$tmp/with-actors.json" --remove-uninstalled-app >/dev/null 2>&1; then
  fail 'Accepted a missing app id'
fi

for bad_target in '"tag"' null; do
  jq --argjson t "$bad_target" '.target = $t' "$tmp/fixture.json" > "$tmp/bad.json"
  if "$plan" "$tmp/bad.json" >/dev/null 2>&1; then fail 'Accepted unsupported scope'; fi
done
jq '.rules |= map(select(.type != "pull_request"))' "$tmp/fixture.json" > "$tmp/bad.json"
if "$plan" "$tmp/bad.json" >/dev/null 2>&1; then fail 'Accepted a ruleset without pull-request protection'; fi
jq '.rules += [{"type": 7}]' "$tmp/fixture.json" > "$tmp/bad.json"
if "$plan" "$tmp/bad.json" >/dev/null 2>&1; then fail 'Accepted malformed rule data'; fi
jq '.conditions.ref_name.exclude = ["refs/heads/x"]' "$tmp/fixture.json" > "$tmp/bad.json"
if "$plan" "$tmp/bad.json" >/dev/null 2>&1; then fail 'Accepted a ruleset with exclusions'; fi

echo 'PASS: only four retired constraints removed; CI, signatures, reviews, scans, scope, and bypass preserved'
