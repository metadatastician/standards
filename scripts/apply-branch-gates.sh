#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# apply-branch-gates.sh — fill the `required_status_checks` rule of a
# repository's active branch ruleset with contexts DERIVED from what its
# default-branch runs actually emitted.
#
# WHY THIS EXISTS
#   config/rulesets/README.adoc has said so outright since it was written:
#   "the propagation mechanism is still missing by design, and this note is the
#   reminder that a template fix without an applier is a half fix." Nothing in
#   this repository read config/rulesets/gates.json as DATA — every reference
#   was prose, or tests/test_governance_reusable_shape.sh asserting the file's
#   contents. gates.json specified a derivation that no code performed.
#   apply-tag-ruleset-canon.sh is the TAG applier; this is its branch sibling.
#
# CONTEXTS ARE DERIVED, NEVER TYPED
#   config/rulesets/gates.json: "Contexts are never typed by hand." A typed
#   context that nothing emits is a PHANTOM — it can never turn green, so it
#   blocks the branch forever. This script therefore reads the check names the
#   latest default-branch run of each gate workflow ACTUALLY produced:
#     GET /repos/{o}/{r}/actions/workflows/{file}/runs?branch=<default>&per_page=1
#     GET /repos/{o}/{r}/actions/runs/{id}/jobs
#   and uses the job `name` verbatim. For a reusable caller GitHub already
#   renders that as "<caller job id> / <reusable job name>".
#
# THE TWO REFUSALS THAT MATTER
#   if_no_run_yet            -> omit that file's contexts and REPORT it.
#                               Never write a context nothing has emitted.
#   if_zero_contexts_overall -> do NOT write the rule at all; report UNGATED.
#                               A required_status_checks rule with an empty list
#                               is a VACUOUS GATE: it reports "protected" while
#                               requiring nothing. That is worse than no rule,
#                               because it is indistinguishable from a real one
#                               in every summary view.
#
# EXACTNESS GUARD
#   A ruleset PUT REPLACES the whole object. This script therefore refuses to
#   write unless the planned body, normalised over the required_status_checks
#   rule alone, is byte-identical to the source. Anything else moved => refuse.
#   Without this, one jq slip silently strips required_signatures estate-wide.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   * It never CREATES a ruleset unless --create-gates is passed, and then only
#     from the committed canon body (--gates-only-file, guarded for shape).
#     Without the flag a repo with no repo-level branch ruleset is reported
#     NORULESET or ORG-INHERITED. Creating branch protection where none exists
#     is a policy act, not a gate-fill; owner decision O6 (standards#787 row
#     D17) IS that policy, so creating THAT ONE body implements a ruling.
#   * It never DELETES or rewrites another rule. Repos carrying the retired
#     types (update, required_deployments, code_quality, code_coverage) are
#     REPORTED, not repaired: the estate census was ruled report-only. Pass
#     --strip-retired to opt in, one repo at a time.
#   * It never emits a retired rule type itself. The exactness guard makes that
#     structurally impossible, not merely intended.
#   * Two active REPO-LEVEL branch rulesets are resolved BY SHAPE, and only by
#     shape: the gates ruleset is the one whose only rule is
#     required_status_checks. That pair is the EXPECTED O6 steady state, so a
#     flat refusal would make the applier unable to maintain the very shape the
#     ruling prescribes. If shape does not single one out => AMBIGUOUS, fail
#     closed. Rulesets are ADDITIVE (see apply-tag-ruleset-canon.sh): writing
#     one of a pair leaves the other enforcing, and the repo stays blocked by a
#     rule nothing announced. Guessing which to fill is how that happens
#     silently -- and NAME never discriminates, as the tag applier proved with
#     372 blocked repos and 26 healthy ones sharing one name.
#   * It never tries to write an ORG-INHERITED ruleset. repos/{r}/rulesets
#     RETURNS the org's rulesets alongside the repo's own, and one of them is
#     readable IN FULL at repos/{r}/rulesets/{id} -- so every read succeeds and
#     nothing warns you. The PUT to that same path 404s. That was measured 67
#     times, once for every metadatastician repo reached by the org-level
#     EstateBranching (18225024). The cure for an inherited ruleset is at
#     /orgs/{org}/rulesets/{id}, applied ONCE, not per repo -- so this script
#     reports ORG-INHERITED and stops rather than issuing 67 doomed writes.
#     The discriminator is .source_type, which the LIST endpoint does return
#     (verified against the live API: every entry carries it). An entry WITHOUT
#     it is reported UNKNOWN, never assumed repo-level: writability is exactly
#     what that field decides, and guessing it wrong is a silent 404.
#     ⚠ --create-gates does NOT change that: an org-inherited ruleset is still
#     never written. It creates a SECOND, repo-level checks-only ruleset beside
#     it, which is what O6 prescribes -- filling the inherited one would be a
#     fake gate regardless of writability, because bypass binds a RULESET.
#
# Inputs (environment):
#   GH_TOKEN       required for writes; needs administration:write on targets.
#   ESTATE_ORGS    optional, space-separated. Default "metadatastician".
#
# Flags:
#   --apply            perform writes. WITHOUT IT THIS SCRIPT ONLY REPORTS.
#   --repo OWNER/NAME  process exactly one repository (repeatable).
#   --limit N          process at most N repositories (pilot runs).
#   --gates-file F     default config/rulesets/gates.json
#   --strip-retired    also remove the 4 retired rule types. Off by default.
#   --require-green N  drop any derived context that is not green across the
#                      last N default-branch runs of its workflow, and REFUSE
#                      the repo outright if any of those runs cannot be read.
#                      Off (0) by
#                      default. Owner ruling on #956: "require the reliably-
#                      green set" -- a required context that is currently red
#                      blocks the branch the moment it is required, so gating
#                      on it converts a visible red into a merge deadlock.
#                      `skipped` and `neutral` COUNT AS GREEN: GitHub treats
#                      both as satisfying a required status check.
#   --skip-user        do not enumerate user/repos; use only ESTATE_ORGS.
#   --create-gates     when a repo has NO repo-level branch ruleset, CREATE the
#                      O6 checks-only one from --gates-only-file instead of
#                      reporting and stopping. Off by default: creating branch
#                      protection where none exists is a policy act. Owner
#                      decision O6 (standards#787 row D17) IS that policy and
#                      config/rulesets/gates-only.json is its committed body,
#                      so creating THAT ONE body implements a ruling rather
#                      than making one. The body is guarded for canon shape
#                      and this script fills its context list; it is never
#                      hand-written and never read from an arbitrary file.
#   --gates-only-file F  default config/rulesets/gates-only.json
#   --no-integration-bypass
#                      strip every Integration actor from the CREATED ruleset's
#                      bypass list, so the AI actors (claude, dependabot,
#                      github-actions, oikosbot) are genuinely bound by the
#                      gates from day one. Requires --create-gates: the update
#                      path may not touch bypass_actors at all (the exactness
#                      guard and the post-write DRIFT check both forbid it).
#                      ⚠ This DIVERGES from the committed canon body. It refuses
#                      to leave the bypass list empty -- a branch ruleset with
#                      zero bypass actors is the shape of the 2026-09-11 tag
#                      outage, and with require_code_owner_review upstream it
#                      would deadlock the repository outright.
#
# Output: TSV on stdout  repo <TAB> state <TAB> detail
#         per-class summary on stderr.
#
# Exit codes: 0 ok · 1 usage/refusal · 2 at least one repo FAILED
set -uo pipefail

RETIRED_TYPES='update required_deployments code_quality code_coverage'
ACTIONS_INTEGRATION_ID=15368

APPLY=0 LIMIT=0 STRIP_RETIRED=0 SKIP_USER=0 REQUIRE_GREEN=0
CREATE_GATES=0 NO_INTEGRATION_BYPASS=0
GATES_ONLY_FILE='config/rulesets/gates-only.json'
GATES_FILE='config/rulesets/gates.json'
REPOS_EXPLICIT=()

die() { printf '%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)         APPLY=1 ;;
    --repo)          shift; [ $# -gt 0 ] || die 'usage: --repo OWNER/NAME'; REPOS_EXPLICIT+=("$1") ;;
    --limit)         shift; [ $# -gt 0 ] || die 'usage: --limit N'; LIMIT="$1" ;;
    --gates-file)    shift; [ $# -gt 0 ] || die 'usage: --gates-file PATH'; GATES_FILE="$1" ;;
    --strip-retired) STRIP_RETIRED=1 ;;
    --require-green) shift; [ $# -gt 0 ] || die 'usage: --require-green N'; REQUIRE_GREEN="$1" ;;
    --skip-user)     SKIP_USER=1 ;;
    --create-gates)  CREATE_GATES=1 ;;
    --gates-only-file) shift; [ $# -gt 0 ] || die 'usage: --gates-only-file PATH'; GATES_ONLY_FILE="$1" ;;
    --no-integration-bypass) NO_INTEGRATION_BYPASS=1 ;;
    -h|--help)       sed -n '2,70p' "$0"; exit 0 ;;
    *)               die "unknown flag: $1" ;;
  esac
  shift
done

[ -r "$GATES_FILE" ] || die "gates file not readable: $GATES_FILE"
[ "$NO_INTEGRATION_BYPASS" = 1 ] && [ "$CREATE_GATES" = 0 ] \
  && die '--no-integration-bypass applies to the CREATED ruleset only; pass --create-gates (the update path may not alter bypass_actors)'
command -v gh >/dev/null || die 'gh is required'
command -v jq >/dev/null || die 'jq is required'
# Workflow triggers are read with a YAML parser; there is no line-matching
# fallback (a quoted `"paths":` key defeated the one that existed).
if ! { command -v yq >/dev/null && yq --version 2>/dev/null | grep -Eq 'github.com/mikefarah/yq/.*version v4\.'; }; then
  die 'mikefarah yq v4 is required to read workflow triggers (YAML-POLICY Y-1)'
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

jq -e . "$GATES_FILE" >/dev/null 2>&1 || die "gates file is not valid JSON: $GATES_FILE"

jq -r '.never_required_workflows[]?' "$GATES_FILE" | sort -u > "$WORK/never_wf"
jq -r '.never_required_contexts[]?'  "$GATES_FILE" | sort -u > "$WORK/never_ctx"

emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; printf '%s\n' "$2" >> "$WORK/states"; }

# --- normalise away ONLY the required_status_checks rule, so a diff of the
#     normalised forms proves nothing outside it moved.
# The required_status_checks rule is the INTENDED change, so it is removed from
# both sides before comparison -- including when it is being ADDED, where the
# two rule arrays legitimately differ in length. Everything else must match
# exactly. The rule's own contents are verified separately, after the write,
# by comparing the planned context set against what the API returns.
norm_rsc() {
  jq -S '.rules = ((.rules // []) | map(select(.type!="required_status_checks")))' "$1"
}

# --- is $1 listed in never_required_contexts, whole or after the first " / "?
is_never_ctx() {
  local c="$1" tail="${1#* / }"
  command grep -qxF -- "$c" "$WORK/never_ctx" && return 0
  [ "$tail" != "$c" ] && command grep -qxF -- "$tail" "$WORK/never_ctx" && return 0
  return 1
}

# Decide whether a workflow definition (YAML on stdin) triggers on
# `pull_request` or `pull_request_target` targeting the default branch ($1).
# Prevents deriving required_status_checks from push/schedule/dispatch-only
# workflows on $DEF that never fire on pull requests (standards#1040).
#
# The definition is read by mikefarah yq v4, a YAML parser, and never by
# matching key spellings on lines: a quoted key (`"paths": [...]`, or the flow
# form `pull_request: {"paths": [...]}`) is the same key as a bare one, and a
# line matcher that misses it derives a context that never reports. yq v4
# reads a bare `on` key as the string "on", not as the boolean true.
# `on` may be a string, a sequence or a mapping; all three are handled.
#
# Exit 0 = every PR to $DEF emits the workflow's contexts; 1 = no PR trigger
# for $DEF; 3 = a PR trigger for $DEF that carries `paths` or `paths-ignore`
# (standards#1065). A path-filtered workflow reports only on PRs touching
# those paths, so a context required from it waits forever on every other
# PR. 3 is a refusal to derive, reported in its own bucket, never a pass.
# 5 = the definition is not one parseable YAML mapping: a failed read, which
# the caller turns into a derivation failure, never into a verdict.
yaml_has_pr_trigger() {
  local def="$1" doc verdict
  doc=$(yq -o=json -I=0 '.' 2>/dev/null) || return 5
  verdict=$(printf '%s\n' "$doc" | jq -rs --arg def "$def" '
    def lst(x): if x == null then [] elif (x | type) == "array" then x else [x] end;
    def matches_def: tostring as $p | ($p == $def or $p == "*" or $p == "**");
    if length != 1 or (.[0] | type) != "object" then "unparseable"
    else
      .[0].on as $on
      | ( if   ($on | type) == "string" then {($on): null}
          elif ($on | type) == "array"  then ($on | map({(tostring): null}) | add // {})
          elif ($on | type) == "object" then $on
          else {} end ) as $events
      | [ $events | to_entries[]
          | select(.key == "pull_request" or .key == "pull_request_target")
          | (if (.value | type) == "object" then .value else {} end) as $c
          | select(($c | has("branches") | not) or any(lst($c.branches)[]; matches_def))
          | select(any(lst($c["branches-ignore"])[]; tostring == $def) | not)
          | {path_filtered: (($c | has("paths")) or ($c | has("paths-ignore")))} ] as $reach
      | if ($reach | length) == 0 then "no-pr-trigger"
        elif any($reach[]; .path_filtered) then "path-filtered"
        else "reachable" end
    end') || return 5
  case "$verdict" in
    reachable)     return 0 ;;
    no-pr-trigger) return 1 ;;
    path-filtered) return 3 ;;
    *)             return 5 ;;
  esac
}

# Read the workflow definition from the default branch and classify it.
# Exit codes as yaml_has_pr_trigger, plus 4 = the definition could not be read
# (API failure, or a body that is not inline base64 content). There is no
# fallback to run history: a past pull_request run shows the workflow CAN run
# on a PR, not that it runs on EVERY PR, because a paths filter lives only in
# the definition. An unread definition is a failed read, like any other here.
wf_triggers_on_pr() {
  local repo="$1" wfn="$2" def="$3" raw decoded
  raw=$(gh api "repos/$repo/contents/.github/workflows/$wfn" 2>/dev/null) || return 4
  printf '%s' "$raw" \
    | jq -e 'type == "object" and (.content | type) == "string" and .encoding == "base64"' >/dev/null 2>&1 \
    || return 4
  decoded=$(printf '%s' "$raw" | jq -r '.content' | tr -d '\n\r ' | base64 -d 2>/dev/null) || return 4
  printf '%s\n' "$decoded" | yaml_has_pr_trigger "$def"
}

# ---------------------------------------------------------------- repo list
if [ "${#REPOS_EXPLICIT[@]}" -gt 0 ]; then
  printf '%s\n' "${REPOS_EXPLICIT[@]}" > "$WORK/repos"
else
  : > "$WORK/repos"
  [ "$SKIP_USER" = 1 ] || gh repo list --limit 1000 --json nameWithOwner,isArchived \
      --jq '.[]|select(.isArchived|not)|.nameWithOwner' >> "$WORK/repos" 2>/dev/null
  printf '%s\n' ${ESTATE_ORGS:-metadatastician} | while IFS= read -r ORG; do
    [ -n "$ORG" ] || continue
    gh repo list "$ORG" --limit 1000 --json nameWithOwner,isArchived \
      --jq '.[]|select(.isArchived|not)|.nameWithOwner' >> "$WORK/repos" 2>/dev/null
  done
  sort -u "$WORK/repos" -o "$WORK/repos"
fi

[ -s "$WORK/repos" ] || die 'refusing to report a clean sweep over nothing: target list is empty'
[ "$LIMIT" -gt 0 ] 2>/dev/null && head -n "$LIMIT" "$WORK/repos" > "$WORK/r2" && mv "$WORK/r2" "$WORK/repos"

printf '# mode=%s repos=%d gates=%s\n' \
  "$( [ "$APPLY" = 1 ] && echo APPLY || echo REPORT-ONLY )" "$(wc -l < "$WORK/repos")" "$GATES_FILE" >&2
printf 'repo\tstate\tdetail\n'
: > "$WORK/states"

# ---------------------------------------------------------------- main loop
while IFS= read -r R; do
  [ -n "$R" ] || continue

  gh api "repos/$R" > "$WORK/repo.json" 2>"$WORK/e" \
    || { emit "$R" "UNKNOWN" "repo GET failed: $(head -c 100 "$WORK/e" | tr -d '\n')"; continue; }
  DEF=$(jq -r '.default_branch // empty' "$WORK/repo.json")
  [ -n "$DEF" ] || { emit "$R" "UNKNOWN" 'no default branch (empty repo?)'; continue; }

  # ---- 1. which gate workflow FILES apply (profiles) --------------------
  gh api "repos/$R/contents/.github/workflows" --jq '.[]?|.name' 2>/dev/null | sort -u > "$WORK/wf" || : > "$WORK/wf"
  gh api "repos/$R/contents" --jq '.[]?|.name' 2>/dev/null | sort -u > "$WORK/root" || : > "$WORK/root"

  : > "$WORK/gatewf"
  jq -r '.profiles | to_entries[] | @base64' "$GATES_FILE" > "$WORK/profiles"
  while IFS= read -r P64; do
    P=$(printf '%s' "$P64" | base64 -d)
    KEY=$(printf '%s' "$P" | jq -r '.key')
    ACTIVE=0
    if [ "$KEY" = base ]; then
      ACTIVE=1
    else
      # detect: root-level files/globs
      while IFS= read -r PAT; do
        [ -n "$PAT" ] || continue
        while IFS= read -r F; do
          case "$F" in $PAT) ACTIVE=1 ;; esac
        done < "$WORK/root"
      done < <(printf '%s' "$P" | jq -r '.value.detect[]?')
      # detect_workflows: presence of a workflow file
      while IFS= read -r WFN; do
        [ -n "$WFN" ] || continue
        command grep -qxF -- "$WFN" "$WORK/wf" && ACTIVE=1
      done < <(printf '%s' "$P" | jq -r '.value.detect_workflows[]?')
    fi
    [ "$ACTIVE" = 1 ] || continue
    printf '%s' "$P" | jq -r '.value.gate_workflows[]?' >> "$WORK/gatewf"
  done < "$WORK/profiles"

  sort -u "$WORK/gatewf" -o "$WORK/gatewf"
  # a gate workflow must exist in the repo AND not be never-required
  : > "$WORK/gatewf2"
  while IFS= read -r WFN; do
    [ -n "$WFN" ] || continue
    command grep -qxF -- "$WFN" "$WORK/never_wf" && continue
    command grep -qxF -- "$WFN" "$WORK/wf" || continue
    printf '%s\n' "$WFN" >> "$WORK/gatewf2"
  done < "$WORK/gatewf"

  # ---- 2. DERIVE contexts from real runs --------------------------------
  # FAIL CLOSED.  A swallowed API error here raises nothing -- it silently
  # SHORTENS the list, and the gate is written weaker than intended while
  # every other line of output still reports success.  (Measured 2026-09-22:
  # this dropped 2 of 18 required contexts on standards/main.)  So capture
  # the exit status of every fetch and refuse to write if any one failed.
  : > "$WORK/ctx"; : > "$WORK/gatewf3"; NORUN=''; NOPR=''; PATHF=''; DERIVEFAIL=''
  while IFS= read -r WFN; do
    [ -n "$WFN" ] || continue
    if ! RID=$(gh api "repos/$R/actions/workflows/$WFN/runs?branch=$DEF&per_page=1" \
                 --jq '.workflow_runs[0] | select(. != null) | "\(.id // "")"'); then
      DERIVEFAIL="${DERIVEFAIL:+$DERIVEFAIL,}$WFN(runs-query-failed)"; continue
    fi
    if [ -z "$RID" ]; then NORUN="${NORUN:+$NORUN,}$WFN"; continue; fi
    PRRC=0; wf_triggers_on_pr "$R" "$WFN" "$DEF" || PRRC=$?
    if [ "$PRRC" -eq 4 ]; then
      DERIVEFAIL="${DERIVEFAIL:+$DERIVEFAIL,}$WFN(workflow-definition-unreadable)"; continue
    elif [ "$PRRC" -eq 5 ]; then
      DERIVEFAIL="${DERIVEFAIL:+$DERIVEFAIL,}$WFN(workflow-definition-unparseable)"; continue
    elif [ "$PRRC" -eq 3 ]; then
      # Reachable only from PRs touching its paths (standards#1065): exclude,
      # never silently require.
      PATHF="${PATHF:+$PATHF,}$WFN"; continue
    elif [ "$PRRC" -ne 0 ]; then
      NOPR="${NOPR:+$NOPR,}$WFN"; continue
    fi
    if ! gh api "repos/$R/actions/runs/$RID/jobs?per_page=100" --paginate \
           --jq '.jobs[]?|.name' > "$WORK/jobs1"; then
      DERIVEFAIL="${DERIVEFAIL:+$DERIVEFAIL,}$WFN(jobs-query-failed)"; continue
    fi
    # a run that EXISTS but reports zero jobs is a failed read, not an empty gate
    if [ ! -s "$WORK/jobs1" ]; then
      DERIVEFAIL="${DERIVEFAIL:+$DERIVEFAIL,}$WFN(run $RID returned zero jobs)"; continue
    fi
    cat "$WORK/jobs1" >> "$WORK/ctx"
    # Record the workflows that actually CONTRIBUTED contexts.  The greenness
    # probe below must iterate these, not gatewf2: gatewf2 still holds every
    # NORUN workflow, for which an empty runs query is the LEGITIMATE state.
    printf '%s\n' "$WFN" >> "$WORK/gatewf3"
  done < "$WORK/gatewf2"

  sort -u "$WORK/ctx" -o "$WORK/ctx"
  : > "$WORK/ctx2"; EXCLUDED=''
  while IFS= read -r C; do
    [ -n "$C" ] || continue
    if is_never_ctx "$C"; then EXCLUDED="${EXCLUDED:+$EXCLUDED,}$C"; continue; fi
    printf '%s\n' "$C" >> "$WORK/ctx2"
  done < "$WORK/ctx"

  # ---- optional: keep only contexts that are RELIABLY green ------------
  # The same rule in the other direction: an UNREAD run cannot prove a
  # context green, so a failed fetch here must refuse, never silently admit.
  NOTGREEN=''
  if [ "$REQUIRE_GREEN" -gt 0 ] 2>/dev/null; then
    : > "$WORK/bad"
    while IFS= read -r WFN; do
      [ -n "$WFN" ] || continue
      if ! gh api "repos/$R/actions/workflows/$WFN/runs?branch=$DEF&per_page=$REQUIRE_GREEN" \
             --jq '.workflow_runs[]?.id' > "$WORK/rids"; then
        DERIVEFAIL="${DERIVEFAIL:+$DERIVEFAIL,}$WFN(green-runs-query-failed)"; continue
      fi
      # Third instance of the same class.  A runs query that SUCCEEDS with an
      # empty list leaves rids empty, the loop below never runs, nothing lands
      # in "bad", and every context this workflow contributed is admitted as
      # green.  We are iterating gatewf3 -- workflows that DID contribute
      # contexts, hence had a run -- so zero runs here is a failed read.
      if [ ! -s "$WORK/rids" ]; then
        DERIVEFAIL="${DERIVEFAIL:+$DERIVEFAIL,}$WFN(green-runs-query-returned-none)"; continue
      fi
      while IFS= read -r RID2; do
        [ -n "$RID2" ] || continue
        # Ask for NAME + CONCLUSION of every job and classify locally.
        # Asking the API only for the NON-green jobs cannot tell "this run is
        # all green" apart from "this run was not read": both return ZERO
        # lines, and zero lines is read as greenness. That is the same
        # fail-open as the derivation loop above, pointing the other way --
        # there it SHORTENS the gate, here it ADMITS a context that was never
        # shown to be green. An unread run proves nothing in either direction.
        if ! gh api "repos/$R/actions/runs/$RID2/jobs?per_page=100" --paginate \
               --jq '.jobs[]? | [.name, (.conclusion // "pending")] | @tsv' \
               > "$WORK/jobs2"; then
          DERIVEFAIL="${DERIVEFAIL:+$DERIVEFAIL,}$WFN(run $RID2 green-check-failed)"; continue
        fi
        # a run that EXISTS but reports zero jobs is a failed read, not a green run
        if [ ! -s "$WORK/jobs2" ]; then
          DERIVEFAIL="${DERIVEFAIL:+$DERIVEFAIL,}$WFN(run $RID2 returned zero jobs)"; continue
        fi
        # a job is acceptable when success/skipped/neutral, or still running
        while IFS=$'\t' read -r JN JC; do
          [ -n "$JN" ] || continue
          case "$JC" in
            success|skipped|neutral|pending) ;;
            *) printf '%s\n' "$JN" >> "$WORK/bad" ;;
          esac
        done < "$WORK/jobs2"
      done < "$WORK/rids"
    done < "$WORK/gatewf3"
    sort -u "$WORK/bad" -o "$WORK/bad"
    : > "$WORK/ctx3"
    while IFS= read -r C; do
      [ -n "$C" ] || continue
      if command grep -qxF -- "$C" "$WORK/bad"; then NOTGREEN="${NOTGREEN:+$NOTGREEN,}$C"; continue; fi
      printf '%s\n' "$C" >> "$WORK/ctx3"
    done < "$WORK/ctx2"
    mv "$WORK/ctx3" "$WORK/ctx2"
  fi

  NCTX=$(wc -l < "$WORK/ctx2")
  DETAIL="branch=$DEF gate_files=$(wc -l < "$WORK/gatewf2") contexts=$NCTX"
  [ -n "$NOTGREEN" ] && DETAIL="$DETAIL not_green=[$NOTGREEN]"
  [ -n "$NORUN" ]    && DETAIL="$DETAIL no_run=[$NORUN]"
  [ -n "$NOPR" ]     && DETAIL="$DETAIL no_pr_trigger=[$NOPR]"
  [ -n "$PATHF" ]    && DETAIL="$DETAIL path_filtered=[$PATHF]"
  [ -n "$EXCLUDED" ] && DETAIL="$DETAIL excluded=[$EXCLUDED]"

  # ---- THE OTHER REFUSAL: a gate derived from an incomplete read --------
  # An unread run is not an absent context.  Writing here would produce a
  # real, plausible, permanent ruleset that is simply WEAKER than intended,
  # reported as success, with nothing anywhere to say so.
  if [ -n "$DERIVEFAIL" ]; then
    emit "$R" "REFUSED" "$DETAIL derive_failed=[$DERIVEFAIL] — refusing to write a gate derived from an incomplete read"
    continue
  fi

  # ---- THE REFUSAL: a rule with an empty list is a vacuous gate ---------
  if [ "$NCTX" -eq 0 ]; then
    emit "$R" "UNGATED" "$DETAIL — refusing to write an empty required_status_checks rule"
    continue
  fi

  # ---- build the checks payload ONCE, before the ruleset is located ------
  # Both downstream paths need it: the PUT body filled into an existing rule,
  # and the POST body created from the canon checks-only file.
  jq -R -s --argjson iid "$ACTIONS_INTEGRATION_ID" \
    'split("\n")|map(select(length>0))|map({context:., integration_id:$iid})' "$WORK/ctx2" > "$WORK/checks.json"

  # ---- 3. locate the one active REPO-LEVEL branch ruleset ----------------
  # This listing includes the ORG's rulesets as well as the repo's own, and an
  # inherited one reads back in full at repos/{r}/rulesets/{id} while the PUT
  # to that same path 404s. Fetch the population and classify LOCALLY -- a
  # server-side select whose empty result is also its success result cannot
  # fail closed.
  gh api "repos/$R/rulesets" > "$WORK/rs.json" 2>"$WORK/e" \
    || { emit "$R" "UNKNOWN" "rulesets GET failed"; continue; }
  jq -r '.[]|select(.target=="branch" and .enforcement=="active")
         |[(.source_type // "MISSING"), (.id|tostring)]|@tsv' "$WORK/rs.json" > "$WORK/active"
  # awk, not grep -P: -P is a GNU extension and this script must not depend on
  # which grep the runner ships.
  awk -F'\t' '$1=="Repository"{print $2}'                "$WORK/active" > "$WORK/ids"
  awk -F'\t' '$1!="Repository" && $1!="MISSING"{print $2}' "$WORK/active" > "$WORK/inherited"
  NMISS=$(awk -F'\t' '$1=="MISSING"{c++} END{print c+0}'  "$WORK/active")
  NIDS=$(wc -l < "$WORK/ids")
  NINH=$(wc -l < "$WORK/inherited")

  # An absent discriminator REFUSES; it never defaults to the writable arm.
  [ "${NMISS:-0}" -gt 0 ] && { emit "$R" "UNKNOWN" "$DETAIL — $NMISS active branch ruleset(s) carry no .source_type; cannot tell repo-level from org-inherited, refusing to guess"; continue; }
  if [ "$NIDS" -eq 0 ]; then
    # ---- 3a. nothing repo-level to fill: REPORT, or CREATE under the flag --
    # Creating branch protection where none exists is a policy act, which is
    # why this script refused to do it at all. Owner decision O6 (#787 D17) IS
    # that policy and config/rulesets/gates-only.json is its committed body, so
    # creating THAT ONE body implements a ruling rather than making one. It
    # stays behind an explicit flag and is never the default.
    #
    # An org-inherited ruleset does NOT satisfy O6 and must not be filled in
    # its place: bypass binds a RULESET, never a rule, so required_status_checks
    # added to EstateBranching (whose bypass list is long and deliberate) would
    # be a fake gate -- indistinguishable from a real one in every summary view.
    # O6's whole content is that the checks live in their own object with their
    # own short bypass list. So the cure here is a SECOND, repo-level ruleset
    # alongside the inherited one, not a write to the inherited one.
    if [ "$CREATE_GATES" = 0 ]; then
      if [ "$NINH" -gt 0 ]; then
        emit "$R" "ORG-INHERITED" "$DETAIL — the only active branch ruleset(s) here are org-level ($(paste -sd, "$WORK/inherited")); writable ONLY at /orgs/{org}/rulesets/{id} with an admin:org credential (a repo token reads it and cannot write it), cured once at the org, never per repo — and filling one would be a fake gate anyway, since bypass binds a ruleset; pass --create-gates to add the O6 repo-level checks-only ruleset from $GATES_ONLY_FILE"
      else
        emit "$R" "NORULESET" "$DETAIL — no active branch ruleset; pass --create-gates to create the O6 checks-only ruleset from $GATES_ONLY_FILE"
      fi
      continue
    fi
    [ -r "$GATES_ONLY_FILE" ] \
      || { emit "$R" "REFUSED" "$DETAIL — --create-gates needs a readable $GATES_ONLY_FILE"; continue; }
    # CANON-SHAPE GUARD. Never hand-write a ruleset body, and never create one
    # from a file that is not the canon body: it must target branches, be
    # active, carry required_status_checks as its ONLY rule, and arrive with an
    # EMPTY context list -- this script is what fills it. A committed non-empty
    # list would be a TYPED context, which is the one thing gates.json forbids.
    if [ "$(jq -cS '[.rules[]?.type]|unique' "$GATES_ONLY_FILE")" != '["required_status_checks"]' ] \
       || [ "$(jq -r '.target // ""' "$GATES_ONLY_FILE")" != 'branch' ] \
       || [ "$(jq -r '.enforcement // ""' "$GATES_ONLY_FILE")" != 'active' ] \
       || [ "$(jq -r '[.rules[]?|select(.type=="required_status_checks")|.parameters.required_status_checks[]?]|length' "$GATES_ONLY_FILE")" != '0' ]; then
      emit "$R" "REFUSED" "$DETAIL — $GATES_ONLY_FILE is not the canon checks-only body (target/enforcement/sole-rule/empty-contexts)"
      continue
    fi
    jq --slurpfile ck "$WORK/checks.json" '
        .rules = [{ type:"required_status_checks",
                    parameters:{ strict_required_status_checks_policy:false,
                                 do_not_enforce_on_create:false,
                                 required_status_checks:$ck[0] } }]
      ' "$GATES_ONLY_FILE" > "$WORK/create.json"

    if [ "$NO_INTEGRATION_BYPASS" = 1 ]; then
      jq '.bypass_actors = [(.bypass_actors // [])[] | select(.actor_type != "Integration")]' \
        "$WORK/create.json" > "$WORK/c2" && mv "$WORK/c2" "$WORK/create.json"
      # A branch ruleset with ZERO bypass actors is the shape of the 2026-09-11
      # tag outage, and where an org ruleset upstream sets
      # require_code_owner_review with a CODEOWNERS the sole contributor cannot
      # self-approve, it deadlocks the repository outright. Refuse, never warn.
      [ "$(jq '[.bypass_actors[]?]|length' "$WORK/create.json")" -gt 0 ] \
        || { emit "$R" "REFUSED" "$DETAIL — --no-integration-bypass would leave $GATES_ONLY_FILE with an EMPTY bypass list; a zero-bypass ruleset is an outage, not a strict gate"; continue; }
      DETAIL="$DETAIL bypass=no_integrations"
    fi

    if [ "$APPLY" = 0 ]; then
      emit "$R" "WOULD-CREATE" "$DETAIL ruleset=<new from $GATES_ONLY_FILE> :: $(tr '\n' '|' < "$WORK/ctx2")"
      continue
    fi
    if ! gh api -X POST "repos/$R/rulesets" --input "$WORK/create.json" > "$WORK/created.json" 2>"$WORK/e"; then
      emit "$R" "FAILED" "$DETAIL — POST: $(head -c 160 "$WORK/e" | tr -d '\n')"; continue
    fi
    NEWID=$(jq -r '.id // empty' "$WORK/created.json")
    [ -n "$NEWID" ] || { emit "$R" "WROTE-UNVERIFIED" "$DETAIL — POST returned no id"; continue; }
    gh api "repos/$R/rulesets/$NEWID" > "$WORK/after.json" 2>/dev/null \
      || { emit "$R" "WROTE-UNVERIFIED" "$DETAIL — re-GET of new ruleset $NEWID failed"; continue; }
    WANT=$(jq -cS '[.rules[]?|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|sort' "$WORK/create.json")
    GOT=$(jq  -cS '[.rules[]?|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|sort' "$WORK/after.json")
    [ "$WANT" = "$GOT" ] \
      || { emit "$R" "DRIFT" "$DETAIL — contexts after create != planned (ruleset $NEWID)"; continue; }
    # The bypass list is the whole point of a checks-only ruleset, so verify it
    # landed as sent -- a server-side default here would silently restore the
    # actors --no-integration-bypass exists to remove.
    WANT_BY=$(jq -cS '[.bypass_actors[]?|{actor_id,actor_type,bypass_mode}]|sort' "$WORK/create.json")
    GOT_BY=$(jq  -cS '[.bypass_actors[]?|{actor_id,actor_type,bypass_mode}]|sort' "$WORK/after.json")
    [ "$WANT_BY" = "$GOT_BY" ] \
      || { emit "$R" "DRIFT" "$DETAIL — bypass_actors after create != planned (ruleset $NEWID)"; continue; }
    emit "$R" "CREATED" "$DETAIL ruleset=$NEWID :: $(tr '\n' '|' < "$WORK/ctx2")"
    continue
  fi

  # TWO repo-level branch rulesets is the EXPECTED steady state after owner
  # decision O6 (#787 row D17): a baseline ruleset carrying the review and
  # signature rules, plus a second checks-only ruleset whose short bypass list
  # is the entire point -- bypass binds a RULESET, never a rule, so status
  # checks must live in their own object to have any teeth. Returning
  # AMBIGUOUS there makes the applier permanently unable to maintain the very
  # shape O6 prescribes.
  # SHAPE is the discriminator: the gates ruleset is the one whose ONLY rule is
  # required_status_checks. Name classifies nothing -- the tag applier proved
  # that estate-wide, where 372 blocked repos and 26 healthy ones shared a name.
  # NOTE: the LIST endpoint omits .rules, so this needs a by-id GET. That same
  # omission is what turned every PUT into a POST in the 2026-09-11 outage.
  if [ "$NIDS" -gt 1 ]; then
    : > "$WORK/shaped"
    while IFS= read -r CAND; do
      [ -n "$CAND" ] || continue
      gh api "repos/$R/rulesets/$CAND" > "$WORK/cand.json" 2>/dev/null || continue
      if [ "$(jq -cS '[.rules[]?.type]|unique' "$WORK/cand.json")" = '["required_status_checks"]' ]; then
        printf '%s\n' "$CAND" >> "$WORK/shaped"
      fi
    done < "$WORK/ids"
    if [ "$(wc -l < "$WORK/shaped")" -eq 1 ]; then
      cp "$WORK/shaped" "$WORK/ids"; NIDS=1
      DETAIL="$DETAIL picked_by=shape"
    fi
  fi
  [ "$NIDS" -gt 1 ] && { emit "$R" "AMBIGUOUS" "$DETAIL — $NIDS active repo-level branch rulesets ($(paste -sd, "$WORK/ids")) and none is uniquely checks-only; rulesets are additive, refusing to guess"; continue; }
  ID=$(cat "$WORK/ids")
  # Additive: an inherited ruleset still enforces alongside the one being filled.
  [ "$NINH" -gt 0 ] && DETAIL="$DETAIL org_inherited=[$(paste -sd, "$WORK/inherited")]"

  gh api "repos/$R/rulesets/$ID" > "$WORK/live.json" 2>/dev/null \
    || { emit "$R" "UNKNOWN" "ruleset $ID GET failed"; continue; }

  FOUND_RETIRED=$(jq -r --arg rt "$RETIRED_TYPES" \
      '[.rules[]?.type] as $t | ($rt|split(" ")) - (($rt|split(" ")) - $t) | join(",")' "$WORK/live.json")
  [ -n "$FOUND_RETIRED" ] && DETAIL="$DETAIL retired_present=[$FOUND_RETIRED]"

  # ---- 4. build the PUT body -------------------------------------------

  jq --slurpfile ck "$WORK/checks.json" '
      {name,target,enforcement,conditions,bypass_actors,rules}
      | .rules = ((.rules // []) | map(select(.type!="required_status_checks")))
      | .rules += [{ type:"required_status_checks",
                     parameters:{ strict_required_status_checks_policy:false,
                                  do_not_enforce_on_create:false,
                                  required_status_checks:$ck[0] } }]
    ' "$WORK/live.json" > "$WORK/put.json"

  if [ "$STRIP_RETIRED" = 1 ]; then
    jq --arg rt "$RETIRED_TYPES" '($rt|split(" ")) as $r | .rules |= map(select(.type as $t | ($r|index($t))|not))' \
      "$WORK/put.json" > "$WORK/p2" && mv "$WORK/p2" "$WORK/put.json"
  fi

  # structural assertion: we never emit a retired type that was not already there
  EMITTED_RETIRED=$(jq -r --arg rt "$RETIRED_TYPES" \
      '[.rules[]?.type] as $t | ($rt|split(" ")) - (($rt|split(" ")) - $t) | join(",")' "$WORK/put.json")
  if [ "$STRIP_RETIRED" = 1 ] && [ -n "$EMITTED_RETIRED" ]; then
    emit "$R" "REFUSED" "$DETAIL — --strip-retired left [$EMITTED_RETIRED] in the body"; continue
  fi

  # ---- EXACTNESS GUARD (skipped when --strip-retired deliberately differs)
  if [ "$STRIP_RETIRED" = 0 ]; then
    jq '{name,target,enforcement,conditions,bypass_actors,rules}' "$WORK/live.json" > "$WORK/src.json"
    if ! diff -q <(norm_rsc "$WORK/src.json") <(norm_rsc "$WORK/put.json") >/dev/null; then
      emit "$R" "REFUSED" "$DETAIL — exactness guard: change outside the required_status_checks rule"
      continue
    fi
  fi

  if [ "$APPLY" = 0 ]; then
    emit "$R" "WOULD-GATE" "$DETAIL ruleset=$ID :: $(tr '\n' '|' < "$WORK/ctx2")"
    continue
  fi

  if ! gh api -X PUT "repos/$R/rulesets/$ID" --input "$WORK/put.json" >/dev/null 2>"$WORK/e"; then
    emit "$R" "FAILED" "$DETAIL — PUT: $(head -c 160 "$WORK/e" | tr -d '\n')"; continue
  fi

  # ---- 5. post-write verification --------------------------------------
  gh api "repos/$R/rulesets/$ID" > "$WORK/after.json" 2>/dev/null \
    || { emit "$R" "WROTE-UNVERIFIED" "$DETAIL — re-GET failed"; continue; }
  PRE_BY=$(jq -cS '.bypass_actors//[]' "$WORK/live.json");  POST_BY=$(jq -cS '.bypass_actors//[]' "$WORK/after.json")
  WANT=$(jq -cS '[.rules[]?|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|sort' "$WORK/put.json")
  GOT=$(jq  -cS '[.rules[]?|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|sort' "$WORK/after.json")
  if [ "$PRE_BY" != "$POST_BY" ]; then emit "$R" "DRIFT" "$DETAIL — bypass_actors changed across the write"; continue; fi
  if [ "$WANT" != "$GOT" ];       then emit "$R" "DRIFT" "$DETAIL — contexts after write != planned"; continue; fi
  emit "$R" "GATED" "$DETAIL ruleset=$ID :: $(tr '\n' '|' < "$WORK/ctx2")"
done < "$WORK/repos"

echo '# summary' >&2
sort "$WORK/states" | uniq -c | sort -rn >&2
command grep -qx 'FAILED' "$WORK/states" && exit 2
exit 0
