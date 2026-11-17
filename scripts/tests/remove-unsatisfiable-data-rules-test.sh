#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Offline tests for scripts/remove-unsatisfiable-data-rules.sh.
#
# The script edits branch protection, so the tests concentrate on the ways
# that goes wrong: writing when it should only report, removing a rule type
# nobody named, and changing anything besides the named rules. A fake `gh`
# (via $GH) serves fixtures and records every PUT. No network. Requires jq.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../remove-unsatisfiable-data-rules.sh"
pass=0; fail=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

mk() { # id name enforcement rules-json
  jq -n --argjson id "$1" --arg n "$2" --arg e "$3" --argjson rules "$4" '{
    id: $id, node_id: "RRS_x", name: $n, target: "branch", source_type: "Repository",
    source: "example/repo", enforcement: $e,
    created_at: "2026-10-06T14:41:36.643Z", current_user_can_bypass: "never",
    _links: {self: {href: "x"}, html: {href: "y"}},
    conditions: {ref_name: {exclude: [], include: ["~DEFAULT_BRANCH"]}},
    bypass_actors: [],
    rules: $rules
  }'
}

BASE='{"type":"deletion"}'
Q='{"type":"code_quality","parameters":{"severity":"all"}}'
C='{"type":"code_coverage","parameters":{"minimum_coverage":61,"max_coverage_drop":5}}'

mk 1 "main gate" active "[$BASE,$Q,$C]" >"$work/rs1.json"
mk 2 "quality only" active "[$BASE,$Q]" >"$work/rs2.json"
mk 3 "plain" active "[$BASE]" >"$work/rs3.json"
mk 4 "dormant" evaluate "[$BASE,$Q]" >"$work/rs4.json"

cat >"$work/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
method=GET; args=(); payload=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --input) payload="$2"; shift 2 ;;
    repo) echo "example/repo"; exit 0 ;;
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
  jq '. + {id: 1, _links: {}}' "$PUT_DIR/$id.json" >"$SERVE_DIR/$id.json"
  exit 0
fi
case "$path" in
  */rulesets) cat "$SERVE_DIR/list.json" ;;
  */rulesets/*)
    id="${path##*/}"
    if [ "${VERIFY_FAIL:-0}" = 1 ] && [ -f "$PUT_DIR/$id.json" ]; then
      echo "curl: (52) Empty reply from server" >&2; exit 1
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
  rm -f "$work/serve/list.json"
  jq -n '([range(1;5) | {id:.,target:"branch",source_type:"Repository"}] + [{id:5,target:"branch",source_type:"Organization"}])' \
    >"$work/serve/list.json"
}

out=""; rc=0
run() {
  SRC_DIR="$work/src" SERVE_DIR="$work/serve" PUT_DIR="$work/put" \
    REFUSE="${REFUSE:-0}" VERIFY_FAIL="${VERIFY_FAIL:-0}" \
    GH="$work/gh" REPO="example/repo" ONLY="${ONLY:-}" \
    bash "$script" "$@" >"$work/out" 2>&1
  rc=$?; out="$(cat "$work/out")"
}
check() { local l="$1" w="$2" g="$3"
  if [ "$g" = "$w" ]; then pass=$((pass+1)); echo "PASS $l"
  else fail=$((fail+1)); echo "FAIL $l — want $w got $g"; printf '%s\n' "$out" | tail -4; fi; }
check_says() { local l="$1" w="$2"
  if grep -qF "$w" <<<"$out"; then pass=$((pass+1)); echo "PASS $l"
  else fail=$((fail+1)); echo "FAIL $l — output lacks: $w"; printf '%s\n' "$out" | tail -4; fi; }

# 1. report-only: names the data rules, writes nothing
setup; run
check "report-only exits 0" 0 "$rc"
check_says "report-only names code_quality" "code_quality(severity=all)"
check_says "report-only names code_coverage" "code_coverage"
check_says "dormant ruleset is skipped, not counted as feedable" "SKIP"
if [ -z "$(ls -A "$work/put")" ]; then pass=$((pass+1)); echo "PASS report-only wrote nothing"
else fail=$((fail+1)); echo "FAIL report-only wrote: $(ls "$work/put")"; fi

# 2. --apply with no --rule refuses before any write
setup; run --apply
check "apply without --rule exits 2" 2 "$rc"
if [ -z "$(ls -A "$work/put")" ]; then pass=$((pass+1)); echo "PASS refusals write nothing"
else fail=$((fail+1)); echo "FAIL refusal wrote: $(ls "$work/put")"; fi

# 3. removing code_quality keeps code_coverage and every other field
setup; run --apply --rule code_quality
check "apply exits 0" 0 "$rc"
check "main gate keeps deletion+coverage" 'deletion,code_coverage' \
  "$(jq -r '[.rules[].type] | join(",")' "$work/put/1.json")"
check "quality-only keeps deletion" 'deletion' \
  "$(jq -r '[.rules[].type] | join(",")' "$work/put/2.json")"
if [ -f "$work/put/3.json" ]; then fail=$((fail+1)); echo "FAIL plain ruleset was rewritten"
else pass=$((pass+1)); echo "PASS plain ruleset untouched"; fi
if [ -f "$work/put/4.json" ]; then fail=$((fail+1)); echo "FAIL dormant ruleset was rewritten"
else pass=$((pass+1)); echo "PASS dormant ruleset untouched"; fi
check "surviving coverage rule is byte-identical" "$(jq -c '.rules[] | select(.type=="code_coverage")' "$work/src/rs1.json")" \
  "$(jq -c '.rules[] | select(.type=="code_coverage")' "$work/put/1.json")"
check "conditions are unchanged" "$(jq -c .conditions "$work/src/rs1.json")" \
  "$(jq -c .conditions "$work/put/1.json")"

# 4. removing both types needs both named
setup; run --apply --rule code_quality --rule code_coverage
check "both types removed when both named" 'deletion' \
  "$(jq -r '[.rules[].type] | join(",")' "$work/put/1.json")"

# 5. unknown rule type is a usage error, before any API write
setup; run --apply --rule deletion
check "unnamed rule type exits 2" 2 "$rc"
if [ -z "$(ls -A "$work/put")" ]; then pass=$((pass+1)); echo "PASS usage error wrote nothing"
else fail=$((fail+1)); echo "FAIL usage error wrote: $(ls "$work/put")"; fi

# 6. ONLY scopes the write to one ruleset
setup; ONLY=2 run --apply --rule code_quality
check "ONLY=2 exits 0" 0 "$rc"
if [ -f "$work/put/1.json" ]; then fail=$((fail+1)); echo "FAIL ONLY=2 also wrote ruleset 1"
else pass=$((pass+1)); echo "PASS ONLY=2 wrote only ruleset 2"; fi

# 7. a refused write is fatal; an unreadable read-back is UNVERIFIED, never ok
setup; REFUSE=1 run --apply --rule code_quality
check "refused write exits 1" 1 "$rc"
setup; VERIFY_FAIL=1 run --apply --rule code_quality
check "failed read-back exits 1" 1 "$rc"
check_says "failed read-back says UNVERIFIED" "UNVERIFIED"

printf '\nremove-unsatisfiable-data-rules tests: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
