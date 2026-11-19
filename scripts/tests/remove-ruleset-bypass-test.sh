#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Offline tests for scripts/remove-ruleset-bypass.sh.
#
# This script edits branch protection for six rulesets at once, so the tests
# concentrate on the two ways that goes wrong: writing when it should have only
# reported, and writing a payload that changes something other than the bypass.
# A fake `gh` (via $GH) serves fixtures and records every PUT.
#
# Requires jq. No network.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../remove-ruleset-bypass.sh"
pass=0; fail=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# Fixtures: a bypassed ruleset, one with no bypass, and an inactive one.
mk() { # id name enforcement bypass
  jq -n --argjson id "$1" --arg n "$2" --arg e "$3" --argjson b "$4" '{
    id: $id, node_id: "RRS_x", name: $n, target: "branch", source_type: "Repository",
    source: "hyperpolymath/standards", enforcement: $e,
    created_at: "2026-10-06T14:41:36.643Z", current_user_can_bypass: "always",
    _links: {self: {href: "x"}, html: {href: "y"}},
    conditions: {ref_name: {exclude: [], include: ["~DEFAULT_BRANCH"]}},
    bypass_actors: (if $b == 1 then [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}] else [] end),
    rules: [{type: "required_status_checks", parameters: {
      strict_required_status_checks_policy: true, do_not_enforce_on_create: false,
      required_status_checks: [{context: "scan / gitleaks", integration_id: 15368}]}}]
  }'
}

mk 1 "Require-Linear-History" active 1 >"$work/rs1.json"
mk 2 "Lock-Floor" active 1 >"$work/rs2.json"
mk 3 "main gate" active 0 >"$work/rs3.json"
mk 4 "Dormant" evaluate 1 >"$work/rs4.json"

cat >"$work/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
method=GET; args=(); payload=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --input) payload="$2"; shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
path="${args[*]:-}"
if [ "$method" = PUT ]; then
  id="${path##*/}"
  cp "${payload:?}" "$PUT_DIR/$id.json"
  if [ "${REFUSE:-0}" = 1 ]; then
    echo '{"message":"Resource not accessible by integration","status":"403"}' >&2
    exit 1
  fi
  # Serve the written payload back on subsequent reads.
  jq "${MUTATION:-.}" "$PUT_DIR/$id.json" | jq '. + {id: 1, _links: {}}' >"$SERVE_DIR/$id.json"
  exit 0
fi
case "$path" in
  */rulesets) cat "$SERVE_DIR/list.json" ;;
  */rulesets/*)
    id="${path##*/}"
    echo "$id" >>"$SERVE_DIR/reads"
    if [ "${READ_FAIL:-}" = "$id" ]; then
      echo "fixture read failure" >&2; exit 1
    fi
    if [ -n "${BYPASS_SHAPE:-}" ] && [ ! -f "$PUT_DIR/$id.json" ]; then
      jq "$BYPASS_SHAPE" "$SRC_DIR/rs$id.json"; exit 0
    fi
    if [ "${VERIFY_FAIL:-0}" = 1 ] && [ -f "$PUT_DIR/$id.json" ]; then
      echo "curl: (52) Empty reply from server" >&2; exit 1     # GET after PUT
    fi
    if [ "${CORRUPT:-0}" = 1 ] && [ -f "$PUT_DIR/$id.json" ]; then
      echo '{"message":"Not Found"}'; exit 0                   # parses, wrong shape
    fi
    if [ -f "$SERVE_DIR/$id.json" ]; then cat "$SERVE_DIR/$id.json"; else cat "$SRC_DIR/rs$id.json"; fi ;;
  *) echo "unexpected: $path" >&2; exit 1 ;;
esac
SH
chmod +x "$work/gh"

setup() {
  rm -rf "$work/src" "$work/serve" "$work/put"
  mkdir -p "$work/src" "$work/serve" "$work/put"
  cp "$work"/rs*.json "$work/src/"
  cp "$work"/rs*.json "$work/serve/"
  jq -n '([range(1;5) | {id:.,target:"branch",source_type:"Repository"}] + [{id:5,target:"branch",source_type:"Organization"},{id:6,target:"tag",source_type:"Repository"}])' \
    >"$work/serve/list.json"
}

out=""; rc=0
run() {
  SRC_DIR="$work/src" SERVE_DIR="$work/serve" PUT_DIR="$work/put" \
    REFUSE="${REFUSE:-0}" VERIFY_FAIL="${VERIFY_FAIL:-0}" CORRUPT="${CORRUPT:-0}" \
    READ_FAIL="${READ_FAIL:-}" BYPASS_SHAPE="${BYPASS_SHAPE:-}" MUTATION="${MUTATION:-.}" \
    GH="$work/gh" REPO="example/repo" ONLY="${ONLY:-}" \
    bash "$script" "$@" >"$work/out" 2>&1
  rc=$?; out="$(cat "$work/out")"
}
check() { local l="$1" w="$2" g="$3"
  if [ "$g" = "$w" ]; then pass=$((pass+1)); echo "PASS $l"
  else fail=$((fail+1)); echo "FAIL $l — want $w got $g"; fi; }
check_says() { local l="$1" w="$2"
  if grep -qF "$w" <<<"$out"; then pass=$((pass+1)); echo "PASS $l"
  else fail=$((fail+1)); echo "FAIL $l — output lacks: $w"; printf '%s\n' "$out" | tail -4; fi; }

# 1. report-only: identifies the three bypasses, writes nothing
setup; run
check "report-only exits 0" 0 "$rc"
check_says "report-only counts them" "2 ruleset(s) would lose their bypass"
if [ -z "$(ls -A "$work/put")" ]; then pass=$((pass+1)); echo "PASS report-only wrote nothing"
else fail=$((fail+1)); echo "FAIL report-only wrote: $(ls "$work/put")"; fi

# 2. --apply writes each, and only bypass_actors changes
setup; run --apply
check "apply exits 0" 0 "$rc"
# rs1 and rs2 are active WITH a bypass; rs3 has none; rs4 is inactive and must
# be skipped. Two is the correct number, not four.
check "apply wrote the 2 active bypassed rulesets" 2 "$(ls "$work/put" | wc -l | tr -d ' ')"
check "all payloads have zero bypass" "0 0" "$(for f in "$work/put"/*.json; do jq -r '.bypass_actors|length' "$f"; done | tr '\n' ' ' | sed 's/ $//')"
check "rules preserved in every payload" "1 1" "$(for f in "$work/put"/*.json; do jq -r '.rules|length' "$f"; done | tr '\n' ' ' | sed 's/ $//')"
check "conditions preserved" "1 1" "$(for f in "$work/put"/*.json; do jq -r 'if .conditions.ref_name.include==["~DEFAULT_BRANCH"] then 1 else 0 end' "$f"; done | tr '\n' ' ' | sed 's/ $//')"
check "read-only fields not sent" "0 0" "$(for f in "$work/put"/*.json; do jq -r 'if has("id") or has("_links") or has("created_at") then 1 else 0 end' "$f"; done | tr '\n' ' ' | sed 's/ $//')"

# 3. an inactive ruleset is skipped, not written
setup; ONLY=4 run --apply
check "inactive skipped, exit 0" 0 "$rc"
check_says "inactive reported as skipped" "enforcement=evaluate"
check "inactive not written" 0 "$(ls "$work/put" | wc -l | tr -d ' ')"

# 4. a ruleset with no bypass is left alone
setup; ONLY=3 run --apply
check "no-bypass exits 0" 0 "$rc"
check "no-bypass not written" 0 "$(ls "$work/put" | wc -l | tr -d ' ')"

# 5. targeted rewrite only touches the named ruleset
setup; ONLY=2 run --apply
check "targeted wrote exactly 1" 1 "$(ls "$work/put" | wc -l | tr -d ' ')"
check "targeted wrote the right one" "2.json" "$(ls "$work/put")"

# 6. the API refuses (installation token): explain the trap, exit 1
setup; REFUSE=1; run --apply
check "403 exits 1" 1 "$rc"
check_says "403 explains the installation-token trap" "installation"
REFUSE=0

# 7. the read-back GET fails after a successful PUT. Reported by Codex on #1338
#    and a genuine bug in the first version: an empty verify.json made
#    `[ "" -ne 0 ]` a syntax error, which evaluated false, skipped the mismatch
#    branch, and printed "verified" after verifying nothing.
setup; VERIFY_FAIL=1; run --apply
check "read-back failure exits 1" 1 "$rc"
check_says "read-back failure says UNVERIFIED" "UNVERIFIED"
if grep -q "verified: 0 bypass" <<<"$out"; then
  fail=$((fail+1)); echo "FAIL read-back failure still claimed verification"
else pass=$((pass+1)); echo "PASS read-back failure did not claim verification"; fi
VERIFY_FAIL=0

# 8. the read-back returns valid JSON but not a ruleset (no bypass_actors array)
setup; CORRUPT=1; run --apply
check "corrupt read-back exits 1" 1 "$rc"
check_says "corrupt read-back says UNVERIFIED" "UNVERIFIED"
CORRUPT=0

# Inherited and non-branch rulesets must never reach the repository endpoint.
setup; run --apply
check "inherited and tag rulesets not read" 0 "$(grep -Ec '^(5|6)$' "$work/serve/reads")"
setup; ONLY=5 run --apply
check "explicit inherited target refused" 1 "$rc"
check "explicit inherited target not written" 0 "$(ls "$work/put" | wc -l | tr -d ' ')"

# A failed explicit target is a failure; broad scans retain their skip policy.
setup; ONLY='1 2' READ_FAIL=2 run --apply
check "unreadable explicit target fails" 1 "$rc"
check_says "unreadable explicit target named" "cannot read targeted ruleset 2"
setup; READ_FAIL=2 run --apply
check "unreadable non-targeted ruleset skipped" 0 "$rc"
check_says "unreadable non-targeted ruleset named" "SKIP 2"

for shape in 'del(.bypass_actors)' '.bypass_actors=null' '.bypass_actors={}' '.bypass_actors=""'; do
  setup; ONLY=1 BYPASS_SHAPE="$shape" run --apply
  check "unknown bypass shape $shape fails" 1 "$rc"
  check_says "unknown bypass shape $shape reported" "expected an array"
  check "unknown bypass shape $shape not written" 0 "$(ls "$work/put" | wc -l | tr -d ' ')"
done

# Equal rule counts cannot hide changed rules or other writable fields.
for mutation in \
  '.rules[0].parameters.required_status_checks[0].context="different check"' \
  '.conditions.ref_name.include=["~ALL"]' \
  '.enforcement="disabled"' \
  '.name="different name"' \
  '.target="tag"' \
  '.bypass_actors=[{actor_type:"RepositoryRole",actor_id:5,bypass_mode:"always"}]'; do
  setup; ONLY=1 MUTATION="$mutation" run --apply
  check "read-back mutation $mutation fails" 1 "$rc"
  check_says "read-back mutation $mutation diagnosed" "read-back mismatch"
done

# 9. unknown argument is not silently ignored
run --force
check "unknown arg exits 2" 2 "$rc"

echo
echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
