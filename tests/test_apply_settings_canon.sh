#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# test_apply_settings_canon.sh -- scripts/apply-settings-canon.sh must bring a
# repository to config/settings/repo.json and nothing else. Cases:
#
#   1. report only: drift is reported and NOTHING is written;
#   2. --apply: a drifted repo reads back as canon; an armed PR is disarmed
#      BEFORE the setting goes off; secret_scanning lands BEFORE push
#      protection; a repo-only Actions pattern is kept (never prune);
#   3. a private repo gets N/A for secret scanning and no secret-scanning write;
#   4. forks, archived repos and 007 are never read or written;
#   5. a rejected write and a write that does not read back are FAIL (exit 1),
#      and the run carries on with the next repository;
#   6. an org-governed Actions policy is GOVERNED, never escalated to the org;
#   7. a second --apply on a compliant repo writes nothing (idempotent);
#   8. a read that fails stops the run with exit 2 before any write, even when
#      an earlier repository in the same run has drift waiting to be written;
#   9. a successful write of `false` reads back as FIXED and the run exits 0
#      (jq's `//` treats false as absent, which once turned every such write
#      into a FAIL);
#  10. a repository with Actions switched off gets HOLD and no Actions write,
#      and stays off;
#  11. an armed pull request that cannot be disarmed blocks that repository's
#      allow_auto_merge switch, while its other settings still go through.
#
# No network: `gh` is a stateful stub on PATH. Each repository is one JSON
# file; writes change it, so read-backs see what was written. The fixtures are
# built FROM the live canon, so a canon edit cannot leave the test stale.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$here/scripts/apply-settings-canon.sh"
canon="$here/config/settings/repo.json"
allow="$here/config/settings/actions-allowlist.json"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

state="$tmp/state"; mkdir -p "$state" "$tmp/bin"
export STUB_STATE="$state" STUB_LOG="$tmp/gh.log"

# ── Fixtures, derived from the canon ─────────────────────────────────────
flat=$(jq -c '.repo | with_entries(select((.value|type) != "object"))' "$canon")
sa_on=$(jq -c '.repo.security_and_analysis' "$canon")
wf=$(jq -c '.actions_workflow_permissions | {default_workflow_permissions, can_approve_pull_request_reviews}' "$canon")
sel=$(jq -c '{github_owned_allowed, verified_allowed, patterns_allowed}' "$allow")
mk() { # mk owner/name jq-filter-applied-to-a-compliant-repo
  jq -n --argjson f "$flat" --argjson sa "$sa_on" --argjson wf "$wf" --argjson sel "$sel" --arg r "$1" '
    {live: ($f + {full_name: $r, private: false, fork: false, archived: false, security_and_analysis: $sa}),
     va: true, asf: true, wf: $wf,
     perms: {enabled: true, allowed_actions: "selected", sha_pinning_required: true},
     sel: $sel, prs: [], governed: false, reject_patch: false, ignore_patch: false,
     reject_disarm: false}' \
  | jq "$2" > "$state/${1/\//__}.json"
}
first_pattern=$(jq -r '.patterns_allowed[0]' "$allow")
mk me/drifty '.live.allow_auto_merge = (.live.allow_auto_merge | not)
  | .live.delete_branch_on_merge = false
  | .live.security_and_analysis.secret_scanning.status = "disabled"
  | .live.security_and_analysis.secret_scanning_push_protection.status = "disabled"
  | .va = false | .asf = false
  | .wf = {default_workflow_permissions: "write", can_approve_pull_request_reviews: true}
  | .sel.patterns_allowed = ((.sel.patterns_allowed[1:]) + ["local/only@*"])
  | .prs = [{number: 1, autoMergeRequest: {mergeMethod: "SQUASH"}}, {number: 2, autoMergeRequest: null}]'
mk me/clean '.'
mk me/priv '.live.private = true | .live.security_and_analysis = {dependabot_security_updates: {status: "enabled"}}
  | .live.allow_auto_merge = (.live.allow_auto_merge | not)'
mk me/forked '.live.fork = true | .live.allow_auto_merge = (.live.allow_auto_merge | not)'
mk me/old '.live.archived = true | .live.allow_auto_merge = (.live.allow_auto_merge | not)'
mk org1/007 '.live.allow_auto_merge = (.live.allow_auto_merge | not)'
mk org1/gov '.perms.allowed_actions = "all" | .governed = true'
mk org1/broken '.live.delete_branch_on_merge = false | .reject_patch = true'
mk org1/sticky '.live.delete_branch_on_merge = false | .ignore_patch = true'
# Every drifted key here has a canon value of false or "read", so a wrong
# read-back of `false` cannot hide behind another repository's failure.
mk me/solo '.live.allow_auto_merge = true | .live.allow_merge_commit = true
  | .wf = {default_workflow_permissions: "write", can_approve_pull_request_reviews: true}
  | .prs = [{number: 7, autoMergeRequest: {mergeMethod: "SQUASH"}}]'
mk me/off '.perms.enabled = false | .perms.allowed_actions = "all"
  | .sel.patterns_allowed = ["local/only@*"]'
mk org1/stuck '.live.allow_auto_merge = true | .live.delete_branch_on_merge = false
  | .reject_disarm = true | .prs = [{number: 9, autoMergeRequest: {mergeMethod: "SQUASH"}}]'

cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stateful gh stub. Logs every call; reads and writes $STUB_STATE/<o>__<r>.json.
echo "$*" >> "$STUB_LOG"
f() { echo "$STUB_STATE/${1/\//__}.json"; }
upd() { local file; file=$(f "$1"); jq "$2" "$file" > "$file.t" && mv "$file.t" "$file"; }
out() { if [ -n "$jqx" ]; then jq -r "$jqx"; else cat; fi; }
jqx=""
if [ "$1" = pr ]; then
  sub=$2; shift 2; n=""; repo=""
  while [ $# -gt 0 ]; do case $1 in -R) repo=$2; shift 2 ;; --jq) jqx=$2; shift 2 ;;
    --json|--state|--limit) shift 2 ;; --disable-auto) shift ;; *) n=$1; shift ;; esac; done
  case $sub in
    list) jq -c '.prs' "$(f "$repo")" | out ;;
    merge)
      [ "$(jq -r .reject_disarm "$(f "$repo")")" = true ] && { echo "gh: disarm refused (HTTP 403)" >&2; exit 1; }
      upd "$repo" "(.prs[] | select(.number == $n) | .autoMergeRequest) = null" ;;
    view) jq -c ".prs[] | select(.number == $n) | {autoMergeRequest}" "$(f "$repo")" | out ;;
  esac
  exit 0
fi
[ "$1" = api ] || { echo "stub: unexpected $*" >&2; exit 99; }
shift; method=GET inc=0 path="" input="" fields=()
while [ $# -gt 0 ]; do case $1 in
  -X) method=$2; shift 2 ;; -i) inc=1; shift ;; --jq) jqx=$2; shift 2 ;; --paginate|--silent) shift ;;
  --input) input=$2; shift 2 ;; -f|-F) fields+=("$2"); shift 2 ;; *) path=$1; shift ;; esac; done
body='{}'
if [ -n "$input" ]; then if [ "$input" = - ]; then body=$(cat); else body=$(cat "$input"); fi; fi
for kv in "${fields[@]}"; do k=${kv%%=*} v=${kv#*=}
  case $v in true|false|[0-9]*) body=$(jq -c --arg k "$k" --argjson v "$v" '.[$k]=$v' <<<"$body") ;;
    *) body=$(jq -c --arg k "$k" --arg v "$v" '.[$k]=$v' <<<"$body") ;; esac; done
case "$method $path" in
  "GET user") echo '{"login":"me"}' | out ;;
  "GET user/memberships/orgs")
    echo '[{"state":"active","role":"admin","organization":{"login":"org1"}},{"state":"active","role":"member","organization":{"login":"other"}}]' | out ;;
  "GET user/repos?"*|"GET orgs/"*"/repos?"*)
    o=me; case $path in orgs/*) o=${path#orgs/}; o=${o%%/*} ;; esac
    for s in "$STUB_STATE/${o}__"*.json; do jq -c '.live' "$s"; done | jq -s -c . | out ;;
  "GET orgs/"*|"PUT orgs/"*|*" enterprises/"*) echo "stub: escalation attempted: $method $path" >&2; exit 98 ;;
  *)
    rest=${path#repos/}; o=${rest%%/*}; rest=${rest#*/}; n=${rest%%/*}; sub=""
    [ "$rest" != "$n" ] && sub=${rest#*/}
    r="$o/$n"; file=$(f "$r")
    [ -f "$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    case "$method $sub" in
      "GET ") jq -c '.live' "$file" | out ;;
      "GET pulls?state=open&per_page=100")
        jq -c '[.prs[] | {number, auto_merge: .autoMergeRequest}]' "$file" | out ;;
      "PATCH ")
        [ "$(jq -r .reject_patch "$file")" = true ] && { echo "gh: Must have admin rights (HTTP 403)" >&2; exit 1; }
        [ "$(jq -r .ignore_patch "$file")" = true ] && { echo '{}'; exit 0; }
        upd "$r" ".live = (.live * $body)" ;;
      "GET vulnerability-alerts")
        if [ "$(jq -r .va "$file")" = true ]; then printf 'HTTP/2.0 204 No Content\n'
        else printf 'HTTP/2.0 404 Not Found\n'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
      "PUT vulnerability-alerts") upd "$r" '.va = true' ;;
      "GET automated-security-fixes")
        if [ "$(jq -r .va "$file")" != true ]; then printf 'HTTP/2.0 404 Not Found\n'; exit 1; fi
        printf 'HTTP/2.0 200 OK\nContent-Type: application/json\n\n'; jq -c '{enabled: .asf, paused: false}' "$file" ;;
      "PUT automated-security-fixes") upd "$r" '.asf = true' ;;
      "GET actions/permissions/workflow") jq -c '.wf' "$file" | out ;;
      "PUT actions/permissions/workflow") upd "$r" ".wf = (.wf * $body)" ;;
      "GET actions/permissions") jq -c '.perms' "$file" | out ;;
      "PUT actions/permissions")
        [ "$(jq -r .governed "$file")" = true ] && {
          echo "gh: Actions policy is set at the organization or enterprise level (HTTP 409)" >&2; exit 1; }
        upd "$r" ".perms = (.perms * $body)" ;;
      "GET actions/permissions/selected-actions") jq -c '.sel' "$file" | out ;;
      "PUT actions/permissions/selected-actions") upd "$r" ".sel = $body" ;;
      *) echo "stub: unhandled $method $path" >&2; exit 97 ;;
    esac ;;
esac
STUB
chmod +x "$tmp/bin/gh"
run() { set +e; out=$(PATH="$tmp/bin:$PATH" bash "$script" "$@" 2>"$tmp/err"); rc=$?; set -e; }
writes() { grep -cE '^api -X (PATCH|PUT)|^pr merge' "$STUB_LOG" || true; }
rows() { printf '%s\n' "$out" | awk -F'\t' -v s="$1" -v r="$2" '$1==s && $2==r'; }
live() { jq -r "$2" "$state/${1/\//__}.json"; }
canon_am=$(jq -r '.repo.allow_auto_merge | tostring' "$canon")

echo "1. report only"
: > "$STUB_LOG"; run
[ "$rc" -eq 0 ] && pass "exit 0" || bad "exit $rc ($(cat "$tmp/err"))"
[ "$(writes)" -eq 0 ] && pass "no write in report mode" || bad "report mode wrote: $(grep -E '^api -X|^pr merge' "$STUB_LOG")"
rows DRIFT me/drifty | grep -q $'\tallow_auto_merge\t'"$canon_am" && pass "allow_auto_merge drift reported" || bad "allow_auto_merge drift missing"
rows DRIFT me/drifty | grep -q 'actions.patterns_allowed' && pass "missing canon pattern reported" || bad "missing pattern not reported"
[ -z "$(rows DRIFT me/clean)$(rows ARMED me/clean)" ] && pass "compliant repo has no rows" || bad "clean repo reported: $(rows DRIFT me/clean)"

echo "4. skips"
if grep -qE 'repos/(me/forked|me/old|org1/007)' "$STUB_LOG"; then bad "a fork, archived repo or 007 was read"
else pass "fork, archived and 007 never read"; fi

echo "9. a write of false reads back as FIXED"
: > "$STUB_LOG"; run --apply --repo me/solo
[ "$rc" -eq 0 ] && pass "exit 0 on a clean single-repository apply" || bad "exit $rc, expected 0: $(rows FAIL me/solo | tr '\t' ' ')"
[ -z "$(rows FAIL me/solo)" ] && pass "no FAIL row" || bad "FAIL rows: $(rows FAIL me/solo | tr '\t' ' ')"
if [ "$canon_am" = false ]; then
  rows FIXED me/solo | grep -q $'\tallow_auto_merge=false' && pass "allow_auto_merge=false is FIXED" || bad "no FIXED row for allow_auto_merge=false"
  [ "$(live me/solo '.live.allow_auto_merge')" = false ] && pass "allow_auto_merge reads back false" || bad "allow_auto_merge not false"
fi
rows FIXED me/solo | grep -q $'\tallow_merge_commit=false' && pass "allow_merge_commit=false is FIXED" || bad "no FIXED row for allow_merge_commit=false"
rows FIXED me/solo | grep -q 'actions_workflow.can_approve_pull_request_reviews=false' && pass "workflow false value is FIXED" || bad "no FIXED row for can_approve_pull_request_reviews=false"

echo "2,3,5,6. --apply"
: > "$STUB_LOG"; run --apply
[ "$rc" -eq 1 ] && pass "exit 1 (rejected, unread-back and governed repos)" || bad "exit $rc, expected 1"
ok=1
for q in ".live.allow_auto_merge|tostring==\"$canon_am\"" '.live.delete_branch_on_merge' \
         '.live.security_and_analysis.secret_scanning.status=="enabled"' \
         '.live.security_and_analysis.secret_scanning_push_protection.status=="enabled"' \
         '.va' '.asf' '.wf.default_workflow_permissions=="read"' '.wf.can_approve_pull_request_reviews==false'; do
  [ "$(live me/drifty "$q")" = true ] || { ok=0; bad "me/drifty not canon after apply: $q"; }
done
[ "$ok" -eq 1 ] && pass "drifted repo reads back as canon"
if [ "$canon_am" = false ]; then
  [ "$(live me/drifty '.prs[0].autoMergeRequest')" = null ] && pass "armed PR disarmed" || bad "PR #1 still armed"
  d=$(grep -n '^pr merge 1 -R me/drifty' "$STUB_LOG" | cut -d: -f1); p=$(grep -n '^api -X PATCH repos/me/drifty' "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$d" ] && [ -n "$p" ] && [ "$d" -lt "$p" ] && pass "PR disarmed before the setting changed" || bad "disarm not before PATCH (d=$d p=$p)"
  grep -q '^pr merge 2 ' "$STUB_LOG" && bad "an unarmed PR was touched" || pass "unarmed PR left alone"
fi
ss=$(awk '/^api -X PATCH repos\/me\/drifty/{n++} END{print n+0}' "$STUB_LOG")
[ "$ss" -ge 3 ] && pass "repo block and each security key patched separately ($ss PATCHes)" || bad "expected >=3 PATCHes on me/drifty, got $ss"
printf '%s\n' "$out" | awk -F'\t' '$1=="FIXED" && $2=="me/drifty"{print $3}' > "$tmp/fixed"
a=$(grep -n '^security_and_analysis.secret_scanning=' "$tmp/fixed" | cut -d: -f1); b=$(grep -n '^security_and_analysis.secret_scanning_push_protection=' "$tmp/fixed" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && pass "secret_scanning before push protection" || bad "security order wrong (a=$a b=$b)"
pats=$(live me/drifty '.sel.patterns_allowed')
jq -e 'index("local/only@*")' <<<"$pats" >/dev/null && pass "repo-only Actions pattern kept (never prune)" || bad "local pattern pruned"
jq -e --arg p "$first_pattern" 'index($p)' <<<"$pats" >/dev/null && pass "missing canon pattern added" || bad "canon pattern not added"
grep -qE '^api -X PATCH repos/me/priv --input' "$STUB_LOG" && pass "private repo flat block patched" || bad "private repo not patched"
[ "$(live me/priv '.live.security_and_analysis | has("secret_scanning")')" = false ] && pass "no secret-scanning write on the private repo" || bad "secret scanning written on private repo"
rows N/A me/priv | grep -q 'secret_scanning' && pass "private repo reports N/A" || bad "no N/A row for private repo"
rows FAIL org1/broken | grep -q 'rejected' && pass "rejected write is FAIL" || bad "rejected write not FAIL"
rows FAIL org1/sticky | grep -q 'read back' && pass "write that does not read back is FAIL" || bad "sticky not FAIL"
rows GOVERNED org1/gov | grep -q . && pass "org-governed Actions policy is GOVERNED" || bad "no GOVERNED row"
grep -q 'escalation attempted' "$tmp/err" && bad "escalated to the organisation" || pass "never escalated to the organisation"
grep -qE '^api -X (PATCH|PUT) repos/me/clean' "$STUB_LOG" && bad "compliant repo was written" || pass "compliant repo not written"

echo "10. Actions switched off"
rows HOLD me/off | grep -q 'actions.enabled' && pass "disabled Actions reported as HOLD" || bad "no HOLD row for me/off"
grep -qE '^api -X PUT repos/me/off/actions' "$STUB_LOG" && bad "Actions policy written on a repo with Actions off" || pass "no Actions write on a repo with Actions off"
[ "$(live me/off '.perms.enabled')" = false ] && pass "Actions stay off" || bad "Actions were switched on"
# The helper on its own must not switch Actions on either: it once read a live
# `enabled: false` as true and sent enabled=true with the policy.
mk me/off2 '.perms.enabled = false | .perms.allowed_actions = "all"'
set +e
PATH="$tmp/bin:$PATH" ACTIONS_NO_ESCALATE=1 bash "$here/scripts/set-allowed-actions.sh" me/off2 "$allow" >/dev/null 2>&1
set -e
[ "$(live me/off2 '.perms.enabled')" = false ] && pass "set-allowed-actions.sh keeps Actions off" || bad "set-allowed-actions.sh switched Actions on"

echo "11. a failed disarm blocks the auto-merge switch"
if [ "$canon_am" = false ]; then
  rows FAIL org1/stuck | grep -q 'pr#9' && pass "failed disarm is FAIL" || bad "no FAIL row for the disarm"
  rows FAIL org1/stuck | grep -q $'\tallow_auto_merge\t' && pass "allow_auto_merge reported as not written" || bad "no FAIL row for allow_auto_merge"
  [ "$(live org1/stuck '.live.allow_auto_merge')" = true ] && pass "setting left on while a PR is still armed" || bad "setting switched off with a PR still armed"
  [ "$(live org1/stuck '.live.delete_branch_on_merge')" = true ] && pass "the repository's other settings still applied" || bad "other settings were not applied"
fi

echo "7. idempotent"
: > "$STUB_LOG"; run --apply --repo me/drifty --repo me/clean
[ "$rc" -eq 0 ] && [ "$(writes)" -eq 0 ] && pass "second apply writes nothing" || bad "second apply rc=$rc writes=$(writes)"

echo "8. fail closed"
mk me/late '.live.delete_branch_on_merge = false'
: > "$STUB_LOG"; run --apply --repo me/late --repo me/missing
[ "$rc" -eq 2 ] && [ "$(writes)" -eq 0 ] && pass "unreadable repo stops the run before any write" || bad "rc=$rc writes=$(writes)"
[ "$(live me/late '.live.delete_branch_on_merge')" = false ] && pass "the drifted repo read first was not written" || bad "me/late was written before all reads finished"

exit "$fail"
