#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# apply-settings-canon.sh -- bring every repository the caller administers to
# the settings canon, config/settings/repo.json, in one run.
#
# WHAT IT APPLIES (every section of the canon, nothing else)
#   * the flat `repo` block: one PATCH /repos/{o}/{r} carrying only the keys
#     that differ (merge methods, delete_branch_on_merge, allow_auto_merge,
#     allow_update_branch, web_commit_signoff_required, squash commit format);
#   * `repo.security_and_analysis`, one key per PATCH, in canon order, so
#     secret_scanning lands before secret_scanning_push_protection
#     (docs/REPO-SETTINGS.adoc, "Ordering");
#   * `vulnerability_alerts`, then `automated_security_fixes` (the second
#     needs the first);
#   * `actions_workflow_permissions` (PUT .../actions/permissions/workflow);
#   * `actions_permissions`, handed to scripts/set-allowed-actions.sh, which
#     owns the ordering and rollback that keep an allow-list from ever being
#     left empty. The payload is the canon allow-list UNIONED with the
#     repository's live list: config/settings/actions-allowlist.json says
#     "never prune", so a repo-specific pattern is kept, never removed.
#   When the canon says allow_auto_merge=false, open PRs with auto-merge armed
#   are disarmed FIRST, before the setting is switched off. Whether switching
#   the setting off cancels requests already armed is not established, so
#   nothing is left to chance.
#
# WHAT IT DOES NOT TOUCH
#   * per_repo_deltas_allowed keys (description, topics, has_wiki, ...);
#   * rulesets and branch protection: they have their own canon and appliers
#     (config/rulesets/, apply-protection-floor.sh, apply-branch-gates.sh,
#     apply-tag-ruleset-canon.sh);
#   * actions_permissions.enabled: set-allowed-actions.sh keeps a repository's
#     Actions on/off state as it finds it, so a repo with Actions off is
#     reported as HOLD for a person to decide, not switched on.
#
# PRIVATE REPOSITORIES
#   secret_scanning and push protection are unavailable on private repositories
#   of a Free account. As the canon's repo_private_overrides says, they are
#   dropped there and reported as N/A, never as drift (REPO-SETTINGS.adoc).
#
# WHICH OWNERS, WHAT IT SKIPS (same rules as apply-branch-autodelete.sh)
#   Default owners: the logged-in account plus every organisation where the
#   caller is an ACTIVE ADMIN. `--owners a,b` names them instead; `--repo o/r`
#   (repeatable) runs on named repositories only. Forks, archived repositories
#   and the 007 repository under any owner are always skipped.
#
# HOW IT RUNS
#   Pass 1 reads every repository on its own (never from a list endpoint:
#   security_and_analysis is absent from lists) and prints one row per
#   difference. A listing or read that fails stops the run with exit 2 before
#   anything is written, so nothing unexamined is reported as compliant or
#   written on a guess. Comparisons are canon-subset-of-live, key by key, never
#   object equality: GitHub echoes back defaults it was never sent.
#   Pass 2 runs only with --apply. Every write is read back; "a 200 is not
#   proof". A rejected write or a failed read-back is reported as FAIL and the
#   run carries on with the next step and repository.
#
# CREDENTIAL
#   Your own `gh auth login`, with admin on the repositories. No CI credential
#   holds repository administration, and a fine-grained token limited to
#   selected repositories would make a partial walk look complete.
#
# USAGE
#   scripts/apply-settings-canon.sh                     # report only (default)
#   scripts/apply-settings-canon.sh --apply             # write, then read back
#   scripts/apply-settings-canon.sh --owners a,b [--apply]
#   scripts/apply-settings-canon.sh --repo owner/name [--repo ...] [--apply]
#
# OUTPUT  TSV rows: STATE <TAB> repo <TAB> key <TAB> expected <TAB> actual
#   DRIFT  differs from canon (will be written with --apply)
#   ARMED  open PR with auto-merge armed (will be disarmed)
#   N/A    not applicable (private repository, Free account)
#   HOLD   differs, but is left for a person (see WHAT IT DOES NOT TOUCH)
#   FIXED / FAIL / GOVERNED  results of --apply; GOVERNED means the Actions
#          policy is set at organisation or enterprise level and was not
#          escalated (set it there deliberately: scripts/set-allowed-actions.sh)
#
# EXIT  0 = report printed, or every write applied and read back;
#       1 = a write was rejected, did not read back, or is GOVERNED;
#       2 = usage, canon or `gh` error before any write.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CANON="${CANON:-$HERE/../config/settings/repo.json}"
ACTIONS_CANON="${ACTIONS_CANON:-$HERE/../config/settings/actions-allowlist.json}"
SET_ACTIONS="${SET_ACTIONS:-$HERE/set-allowed-actions.sh}"

die() { echo "apply-settings-canon: $*" >&2; exit 2; }

APPLY=0
OWNERS=""
REPOS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --owners)
      case "${2:-}" in ''|-*) die "--owners needs a comma-separated list" ;; esac
      OWNERS="$2"; shift 2 ;;
    --repo)
      case "${2:-}" in */*) REPOS+=("$2") ;; *) die "--repo needs owner/name" ;; esac
      shift 2 ;;
    -h|--help) sed -n '3,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"
[ -f "$CANON" ] || die "canon not found: $CANON"
[ -f "$ACTIONS_CANON" ] || die "actions canon not found: $ACTIONS_CANON"
[ -x "$SET_ACTIONS" ] || [ -f "$SET_ACTIONS" ] || die "not found: $SET_ACTIONS"
jq -e . "$CANON" >/dev/null 2>&1 || die "canon is not valid JSON: $CANON"
jq -e .patterns_allowed "$ACTIONS_CANON" >/dev/null 2>&1 || die "actions canon has no patterns_allowed"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Canon, read once ──────────────────────────────────────────────────────
DELTAS="$(jq -c '.per_repo_deltas_allowed // []' "$CANON")"
REPO_FLAT="$(jq -c --argjson d "$DELTAS" \
  '.repo | with_entries(select((.value|type) != "object" and ((.key) as $k | $d | index($k) | not)))' "$CANON")"
SA_PUBLIC="$(jq -c '[.repo.security_and_analysis // {} | to_entries[] | {k: .key, v: .value.status}]' "$CANON")"
SA_PRIVATE="$(jq -c '[.repo_private_overrides.security_and_analysis // {} | to_entries[] | {k: .key, v: .value.status}]' "$CANON")"
WF_CANON="$(jq -c '.actions_workflow_permissions | {default_workflow_permissions, can_approve_pull_request_reviews}' "$CANON")"
AP_ALLOWED="$(jq -r '.actions_permissions.allowed_actions' "$CANON")"
AP_SHA="$(jq -r '.actions_permissions.sha_pinning_required | tostring' "$CANON")"
AP_ENABLED="$(jq -r '.actions_permissions.enabled | tostring' "$CANON")"
VA_CANON="$(jq -r '.vulnerability_alerts.enabled | tostring' "$CANON")"
ASF_CANON="$(jq -r '.automated_security_fixes.enabled | tostring' "$CANON")"
AUTO_MERGE_OFF="$(jq -r '.repo.allow_auto_merge == false' "$CANON")"
ALLOW_FIELDS="$(jq -c '{github_owned_allowed, verified_allowed, patterns_allowed}' "$ACTIONS_CANON")"

row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}"; }

PLAN="$WORK/plan.tsv"     # repo <TAB> step <TAB> argument, in apply order
: > "$PLAN"
plan() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PLAN"; }

# HTTP status of a GET that answers with a status code rather than a body.
http_status() {
  local out code
  out="$(gh api -i "$1" 2>&1)"
  code="$(grep -oE '^HTTP/[0-9.]+ [0-9]{3}' <<<"$out" | head -1 | grep -oE '[0-9]{3}$')"
  [ -n "$code" ] || code="$(grep -oE '\(HTTP [0-9]{3}\)' <<<"$out" | head -1 | grep -oE '[0-9]{3}')"
  printf '%s\n' "${code:-000}"
  sed '1,/^\r*$/d' <<<"$out" > "$WORK/body"
}

# vulnerability-alerts: 204 = enabled, 404 = disabled.
va_state() {
  case "$(http_status "repos/$1/vulnerability-alerts")" in
    204) echo true ;; 404) echo false ;; *) return 1 ;;
  esac
}
# automated-security-fixes: 200 + {"enabled":...}; 404 when alerts are off.
asf_state() {
  case "$(http_status "repos/$1/automated-security-fixes")" in
    200) jq -r '.enabled | tostring' "$WORK/body" ;; 404) echo false ;; *) return 1 ;;
  esac
}

# ── Which repositories ────────────────────────────────────────────────────
if [ "${#REPOS[@]}" -eq 0 ]; then
  me="$(gh api user --jq .login)" || die "gh is not logged in"
  if [ -z "$OWNERS" ]; then
    orgs="$(gh api --paginate user/memberships/orgs \
      --jq '.[] | select(.state == "active" and .role == "admin") | .organization.login')" \
      || die "could not list organisation memberships"
    OWNERS="$me${orgs:+,$(paste -sd, - <<<"$orgs")}"
  fi
  walked=0
  IFS=',' read -r -a owner_list <<<"$OWNERS"
  for o in "${owner_list[@]}"; do
    [ -n "$o" ] || continue
    walked=$((walked + 1))
    if [ "$o" = "$me" ]; then ep="user/repos?affiliation=owner&per_page=100"
    else ep="orgs/$o/repos?type=all&per_page=100"; fi
    listing="$(gh api --paginate "$ep" --jq '.[] | select((.fork or .archived) | not) | .full_name')" \
      || die "could not list repositories for $o"
    while read -r r; do [ -n "$r" ] && REPOS+=("$r"); done <<<"$listing"
  done
  [ "$walked" -gt 0 ] || die "--owners names no owner"
  echo "Owners: $OWNERS" >&2
fi

# ── Pass 1: read and compare ──────────────────────────────────────────────
printf 'state\trepo\tkey\texpected\tactual\n'
n_repos=0 n_rows=0 n_hold=0
for r in "${REPOS[@]}"; do
  [ "${r#*/}" = "007" ] && continue
  live="$(gh api "repos/$r")" || die "could not read $r"
  if [ "$(jq -r '(.fork or .archived)' <<<"$live")" = true ]; then continue; fi
  n_repos=$((n_repos + 1))
  private="$(jq -r '.private' <<<"$live")"

  # Auto-merge requests already armed: disarmed before the setting goes off.
  if [ "$AUTO_MERGE_OFF" = true ]; then
    prs="$(gh pr list -R "$r" --state open --limit 1000 --json number,autoMergeRequest)" \
      || die "could not list pull requests for $r"
    for n in $(jq -r '.[] | select(.autoMergeRequest != null) | .number' <<<"$prs"); do
      row ARMED "$r" "pr#$n" "auto-merge off" "armed"; n_rows=$((n_rows + 1))
      plan "$r" DISARM "$n"
    done
  fi

  # Flat repo block: only the keys that differ go in the PATCH body.
  diff="$(jq -c --argjson c "$REPO_FLAT" '. as $l | $c
           | with_entries(select(($l[.key] | tostring) != (.value | tostring)))' <<<"$live")"
  while IFS=$'\t' read -r k exp act; do
    [ -n "$k" ] || continue
    row DRIFT "$r" "$k" "$exp" "$act"; n_rows=$((n_rows + 1))
  done < <(jq -r --argjson l "$live" 'to_entries[]
             | [.key, (.value|tostring), ($l[.key] // "ABSENT" | tostring)] | @tsv' <<<"$diff")
  [ "$diff" = "{}" ] || plan "$r" PATCH "$diff"

  # security_and_analysis, in canon order; private repos get the override.
  if [ "$private" = true ]; then
    sa="$SA_PRIVATE"
    while read -r k; do
      [ -n "$k" ] || continue
      row "N/A" "$r" "security_and_analysis.$k" "enabled" "unavailable on a private repository (Free account)"
    done < <(jq -r --argjson p "$SA_PRIVATE" '.[] | select(.k as $k | $p | map(.k) | index($k) | not) | .k' <<<"$SA_PUBLIC")
  else
    sa="$SA_PUBLIC"
  fi
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    act="$(jq -r --arg k "$k" '.security_and_analysis[$k].status // "ABSENT"' <<<"$live")"
    if [ "$act" != "$v" ]; then
      row DRIFT "$r" "security_and_analysis.$k" "$v" "$act"; n_rows=$((n_rows + 1))
      plan "$r" SA "$k=$v"
    fi
  done < <(jq -r '.[] | [.k, .v] | @tsv' <<<"$sa")

  # Vulnerability alerts, then automated security fixes (which need them).
  va="$(va_state "$r")" || die "could not read vulnerability-alerts for $r"
  if [ "$VA_CANON" = true ] && [ "$va" != true ]; then
    row DRIFT "$r" vulnerability_alerts true "$va"; n_rows=$((n_rows + 1)); plan "$r" VA true
  fi
  asf="$(asf_state "$r")" || die "could not read automated-security-fixes for $r"
  if [ "$ASF_CANON" = true ] && [ "$asf" != true ]; then
    row DRIFT "$r" automated_security_fixes true "$asf"; n_rows=$((n_rows + 1)); plan "$r" ASF true
  fi

  # Workflow token permissions.
  wf="$(gh api "repos/$r/actions/permissions/workflow")" || die "could not read workflow permissions for $r"
  wfdiff="$(jq -c --argjson c "$WF_CANON" '. as $l | $c
             | with_entries(select(($l[.key] | tostring) != (.value | tostring)))' <<<"$wf")"
  while IFS=$'\t' read -r k exp act; do
    [ -n "$k" ] || continue
    row DRIFT "$r" "actions_workflow.$k" "$exp" "$act"; n_rows=$((n_rows + 1))
  done < <(jq -r --argjson l "$wf" 'to_entries[]
             | [.key, (.value|tostring), ($l[.key] // "ABSENT" | tostring)] | @tsv' <<<"$wfdiff")
  [ "$wfdiff" = "{}" ] || plan "$r" WF "$WF_CANON"

  # Actions policy. Union payload: canon patterns plus every live pattern.
  perms="$(gh api "repos/$r/actions/permissions")" || die "could not read Actions permissions for $r"
  allowed="$(jq -r '.allowed_actions // "ABSENT"' <<<"$perms")"
  sha="$(jq -r '.sha_pinning_required // false | tostring' <<<"$perms")"
  enabled="$(jq -r '.enabled // true | tostring' <<<"$perms")"
  need=0
  if [ "$enabled" != "$AP_ENABLED" ]; then
    row HOLD "$r" actions.enabled "$AP_ENABLED" "$enabled (left for a person: switching Actions on is a decision)"
    n_rows=$((n_rows + 1)); n_hold=$((n_hold + 1))
  fi
  [ "$allowed" = "$AP_ALLOWED" ] || { row DRIFT "$r" actions.allowed_actions "$AP_ALLOWED" "$allowed"; need=1; }
  [ "$sha" = "$AP_SHA" ] || { row DRIFT "$r" actions.sha_pinning_required "$AP_SHA" "$sha"; need=1; }
  live_sel='{}'
  if [ "$allowed" = selected ]; then
    live_sel="$(gh api "repos/$r/actions/permissions/selected-actions")" \
      || die "could not read selected actions for $r"
    missing="$(jq -c --argjson c "$ALLOW_FIELDS" \
      '[$c.patterns_allowed[] as $p | select(((.patterns_allowed // []) | index($p)) == null) | $p]' <<<"$live_sel")"
    if [ "$missing" != "[]" ]; then
      row DRIFT "$r" actions.patterns_allowed "includes canon" "missing $(jq 'length' <<<"$missing"): $(jq -r '.[:5] | join(", ")' <<<"$missing")"
      need=1
    fi
    for k in github_owned_allowed verified_allowed; do
      exp="$(jq -r --arg k "$k" '.[$k] | tostring' <<<"$ALLOW_FIELDS")"
      act="$(jq -r --arg k "$k" '.[$k] // "ABSENT" | tostring' <<<"$live_sel")"
      [ "$act" = "$exp" ] || { row DRIFT "$r" "actions.$k" "$exp" "$act"; need=1; }
    done
  fi
  if [ "$need" -eq 1 ]; then
    n_rows=$((n_rows + 1))
    payload="$WORK/actions-$n_repos.json"
    jq -n --argjson c "$ALLOW_FIELDS" --argjson l "$live_sel" '
      {github_owned_allowed: $c.github_owned_allowed,
       verified_allowed: $c.verified_allowed,
       patterns_allowed: (reduce (($c.patterns_allowed // []) + ($l.patterns_allowed // []))[] as $p
                            ([]; if index($p) then . else . + [$p] end))}' > "$payload"
    plan "$r" ACTIONS "$payload"
  fi
done

steps="$(wc -l < "$PLAN" | tr -d ' ')"
echo "Repositories examined: $n_repos; rows: $n_rows; writes planned: $steps; held for a person: $n_hold" >&2
if [ "$APPLY" -eq 0 ]; then
  [ "$steps" -eq 0 ] || echo "Report only. Re-run with --apply to write, then read back." >&2
  exit 0
fi

# ── Pass 2: write, then read back ─────────────────────────────────────────
failed=0
ok()   { row FIXED "$1" "$2"; }
fail() { row FAIL "$1" "$2" "" "$3"; failed=1; }

apply_step() {
  local r="$1" step="$2" arg="$3" k v got live rc
  case "$step" in
    DISARM)
      gh pr merge "$arg" -R "$r" --disable-auto >/dev/null 2>"$WORK/err" \
        || { fail "$r" "pr#$arg" "disarm rejected: $(tr '\n' ' ' < "$WORK/err")"; return; }
      got="$(gh pr view "$arg" -R "$r" --json autoMergeRequest --jq '.autoMergeRequest == null')" \
        || { fail "$r" "pr#$arg" "could not read back"; return; }
      [ "$got" = true ] && ok "$r" "pr#$arg auto-merge disarmed" || fail "$r" "pr#$arg" "still armed after disarm"
      ;;
    PATCH)
      gh api -X PATCH "repos/$r" --input - <<<"$arg" >/dev/null 2>"$WORK/err" \
        || { fail "$r" "repo settings" "PATCH rejected: $(tr '\n' ' ' < "$WORK/err")"; return; }
      live="$(gh api "repos/$r")" || { fail "$r" "repo settings" "could not read back"; return; }
      while IFS=$'\t' read -r k v got; do
        [ -n "$k" ] || continue
        [ "$v" = "$got" ] && ok "$r" "$k=$v" || fail "$r" "$k" "read back $got, not $v"
      done < <(jq -r --argjson l "$live" 'to_entries[]
                 | [.key, (.value|tostring), ($l[.key] // "ABSENT" | tostring)] | @tsv' <<<"$arg")
      ;;
    SA)
      k="${arg%%=*}"; v="${arg#*=}"
      jq -n --arg k "$k" --arg v "$v" '{security_and_analysis: {($k): {status: $v}}}' \
        | gh api -X PATCH "repos/$r" --input - >/dev/null 2>"$WORK/err" \
        || { fail "$r" "security_and_analysis.$k" "PATCH rejected: $(tr '\n' ' ' < "$WORK/err")"; return; }
      got="$(gh api "repos/$r" --jq ".security_and_analysis.$k.status // \"ABSENT\"")" \
        || { fail "$r" "security_and_analysis.$k" "could not read back"; return; }
      [ "$got" = "$v" ] && ok "$r" "security_and_analysis.$k=$v" \
        || fail "$r" "security_and_analysis.$k" "read back $got, not $v"
      ;;
    VA)
      gh api -X PUT "repos/$r/vulnerability-alerts" >/dev/null 2>"$WORK/err" \
        || { fail "$r" vulnerability_alerts "PUT rejected: $(tr '\n' ' ' < "$WORK/err")"; return; }
      got="$(va_state "$r")" || { fail "$r" vulnerability_alerts "could not read back"; return; }
      [ "$got" = true ] && ok "$r" "vulnerability_alerts=true" || fail "$r" vulnerability_alerts "read back $got"
      ;;
    ASF)
      gh api -X PUT "repos/$r/automated-security-fixes" >/dev/null 2>"$WORK/err" \
        || { fail "$r" automated_security_fixes "PUT rejected: $(tr '\n' ' ' < "$WORK/err")"; return; }
      got="$(asf_state "$r")" || { fail "$r" automated_security_fixes "could not read back"; return; }
      [ "$got" = true ] && ok "$r" "automated_security_fixes=true" || fail "$r" automated_security_fixes "read back $got"
      ;;
    WF)
      gh api -X PUT "repos/$r/actions/permissions/workflow" --input - <<<"$arg" >/dev/null 2>"$WORK/err" \
        || { fail "$r" actions_workflow "PUT rejected: $(tr '\n' ' ' < "$WORK/err")"; return; }
      live="$(gh api "repos/$r/actions/permissions/workflow")" \
        || { fail "$r" actions_workflow "could not read back"; return; }
      while IFS=$'\t' read -r k v got; do
        [ -n "$k" ] || continue
        [ "$v" = "$got" ] && ok "$r" "actions_workflow.$k=$v" || fail "$r" "actions_workflow.$k" "read back $got, not $v"
      done < <(jq -r --argjson l "$live" 'to_entries[]
                 | [.key, (.value|tostring), ($l[.key] // "ABSENT" | tostring)] | @tsv' <<<"$arg")
      ;;
    ACTIONS)
      # set-allowed-actions.sh reads back itself and refuses success on an
      # empty or short allow-list. ACTIONS_NO_ESCALATE keeps a per-repository
      # payload from being written to a whole organisation.
      ACTIONS_NO_ESCALATE=1 bash "$SET_ACTIONS" "$r" "$arg" >"$WORK/act" 2>&1
      rc=$?
      case "$rc" in
        0) ok "$r" "actions policy (canon allow-list unioned with live)" ;;
        3) row GOVERNED "$r" actions "" "policy set at organisation or enterprise level; not escalated"; failed=1 ;;
        *) fail "$r" actions "set-allowed-actions.sh exit $rc: $(tail -3 "$WORK/act" | tr '\n' ' ')" ;;
      esac
      ;;
  esac
}

while IFS=$'\t' read -r r step arg; do
  apply_step "$r" "$step" "$arg"
done < "$PLAN"
exit "$failed"
