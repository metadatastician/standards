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
reject() {
  local reason="$1" status=0
  shift
  "$plan" "$@" > "$tmp/refused.json" 2>/dev/null || status=$?
  [ "$status" -eq 1 ] || fail "$reason: expected exit 1, got $status"
  [ ! -s "$tmp/refused.json" ] || fail "$reason: emitted plan output"
}

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
same "$("$plan" "$tmp/with-actors.json" --remove-uninstalled-app +000288115 | jq .bypass_actors)" \
  "$(jq '.[1:]' <<<"$actors")" || fail 'Did not normalize the decimal app ID'
# The oversized value is 2^64 + 288115 and used to wrap to the existing ID.
for bad in 999 0 -288115 abc 18446744073709839731; do
  reject "Invalid app ID: $bad" "$tmp/with-actors.json" --remove-uninstalled-app "$bad"
done
reject 'Missing app ID' "$tmp/with-actors.json" --remove-uninstalled-app

: > "$tmp/bad.json"
reject 'Empty input' "$tmp/bad.json"
cat "$tmp/fixture.json" "$tmp/fixture.json" > "$tmp/bad.json"
reject 'Multiple JSON documents' "$tmp/bad.json"
{ cat "$tmp/fixture.json"; printf '{\n'; } > "$tmp/bad.json"
reject 'Malformed trailing JSON' "$tmp/bad.json"

for bad_target in '"tag"' null; do
  jq --argjson t "$bad_target" '.target = $t' "$tmp/fixture.json" > "$tmp/bad.json"
  reject 'Unsupported scope' "$tmp/bad.json"
done
jq '.rules |= map(select(.type != "pull_request"))' "$tmp/fixture.json" > "$tmp/bad.json"
reject 'Missing pull-request protection' "$tmp/bad.json"
jq '.rules += [{"type": 7}]' "$tmp/fixture.json" > "$tmp/bad.json"
reject 'Malformed rule data' "$tmp/bad.json"
jq '.conditions.ref_name.exclude = ["refs/heads/x"]' "$tmp/fixture.json" > "$tmp/bad.json"
reject 'Ruleset with exclusions' "$tmp/bad.json"

echo 'PASS: only four retired constraints removed; CI, signatures, reviews, scans, scope, and bypass preserved'
