#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# retire-phantom-contexts.sh -- remove TYPED required-status-check contexts that
# nothing emits (phantoms) from repo-level branch rulesets.
#
# WHY THIS EXISTS
#   apply-branch-gates.sh: "A typed context that nothing emits is a PHANTOM --
#   it can never turn green, so it blocks the branch forever." That script never
#   writes one, but it also never REMOVES one it did not write. `CI/gate` was
#   typed by hand into live Branch-Floor rulesets (the canonical
#   config/rulesets/branch-floor.json is deletion + non_fast_forward only), and
#   nothing emits it: the interim publisher (proven-cicd-and-workflows#139)
#   was never merged and carries profiles for three repositories. Measured
#   2026-11-17: 368 of 443 open estate PRs sat at `pending` on it, and
#   hyperpolymath/valence-shell#229 had every one of its 18 check runs green.
#
#   Owner decision 2026-11-17: retire CI/gate rather than finish the publisher.
#   Repositories under the hyperpolymath USER account cannot use a merge queue
#   (GitHub offers it only to organisation-owned repositories), so the
#   replacement there is the real contexts plus auto-merge.
#
# WHAT IT DOES
#   For each repository, for each ACTIVE, REPO-LEVEL ruleset whose
#   required_status_checks rule lists a phantom context: remove exactly those
#   contexts. If the list becomes empty the rule is DROPPED, never left empty --
#   an empty required_status_checks list is a vacuous gate (apply-branch-gates.sh).
#
# WHAT IT DELIBERATELY DOES NOT DO
#   * It never writes without --apply. Report-only is the default.
#   * It never edits another rule, or another field. EXACTNESS GUARD: the planned
#     body, with required_status_checks rules removed from both sides, must be
#     byte-identical to the live body, and the remaining contexts must equal the
#     live contexts minus the phantoms. Anything else moved => REFUSED.
#     That includes the retired `code_coverage` rule, which is REPORTED as a
#     second blocker (`also:` column) but never stripped here.
#   * It never writes an ORG-INHERITED ruleset (PUT 404s; cure once at the org).
#   * It never edits a DISABLED ruleset. Disabled is a decision, not drift.
#   * It never writes over a change it has not seen: the ruleset is re-read immediately
#     before the PUT and the write is REFUSED if any writable field moved since the
#     planning read. (A window between that re-read and the PUT remains; the rulesets
#     API offers no conditional write.)
#   * It never writes without a verified backup: a backup that cannot be written, or
#     that differs from the live body, is a REFUSAL.
#   * It never runs on a partial estate: a failed or possibly truncated `--owner`
#     listing stops the run before any write.
#   * It never inspects only the first page of rulesets (`gh api --paginate`).
#   * It never writes a ruleset whose GET did not return `bypass_actors`: a PUT
#     replaces the whole object, so an unseen bypass list could be wiped.
#   * An absent `.source_type` is a REFUSAL, never a default to the writable arm.
#
# USAGE
#   scripts/retire-phantom-contexts.sh --repo OWNER/NAME [--repo ...]   # report
#   scripts/retire-phantom-contexts.sh --owner hyperpolymath            # report, every non-archived repo
#   scripts/retire-phantom-contexts.sh --repos FILE --apply             # write
#   Options:
#     --context NAME      phantom to retire (repeatable). Default: CI/gate
#     --backup-dir DIR    where --apply saves each live body before the PUT.
#                         Default: ./ruleset-backups
#
# STATES (TSV: repo <TAB> state <TAB> detail)
#   CLEAN              no active repo-level ruleset lists a phantom
#   WOULD-RETIRE       report mode; --apply would write this ruleset
#   RETIRED            written and verified by a second read
#   WROTE-UNVERIFIED   written, but the verifying read failed or still lists a phantom
#   ORG-INHERITED      a phantom lives in an org ruleset; fix it once at the org
#   DISABLED-SKIPPED   a disabled ruleset lists a phantom; left alone
#   REFUSED            guard tripped, absent source_type, or bypass_actors unreadable
#   UNKNOWN            a read failed; nothing recorded as clean
#
# EXIT  0 nothing failed (report rows are not failures)
#       3 at least one REFUSED, UNKNOWN or WROTE-UNVERIFIED row
#       2 usage error
set -uo pipefail

GH=${GH_BIN:-gh}
APPLY=0
BACKUP_DIR="./ruleset-backups"
declare -a REPOS=() CONTEXTS=()
OWNER=""

die() { printf 'FATAL: %s\n' "$*" >&2; exit 2; }
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}"; [ -n "${STATES:-}" ] && printf '%s\n' "$2" >> "$STATES"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)      APPLY=1 ;;
    --repo)       REPOS+=("${2:?--repo needs OWNER/NAME}"); shift ;;
    --repos)      [ -r "${2:-}" ] || die "--repos: cannot read '${2:-}'"
                  # `|| [ -n "$l" ]` keeps a final line that has no trailing newline.
                  while IFS= read -r l || [ -n "$l" ]; do l=${l%%#*}; l=${l//[[:space:]]/}; [ -n "$l" ] && REPOS+=("$l"); done < "$2"; shift ;;
    --owner)      OWNER="${2:?--owner needs a login}"; shift ;;
    --context)    CONTEXTS+=("${2:?--context needs a name}"); shift ;;
    --backup-dir) BACKUP_DIR="${2:?}"; shift ;;
    -h|--help)    sed -n '2,62p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
  shift
done

command -v jq >/dev/null || die "jq is required"
command -v "$GH" >/dev/null || die "gh is required"
[ ${#CONTEXTS[@]} -gt 0 ] || CONTEXTS=("CI/gate")

WORK=$(mktemp -d -t phantomctx.XXXXXX); trap 'rm -rf "$WORK"' EXIT
STATES="$WORK/states"; : > "$STATES"

if [ -n "$OWNER" ]; then
  # Capture the listing and check its status BEFORE using any of it: a listing that
  # fails part-way must stop the run, not --apply over a partial estate.
  LIMIT=2000
  "$GH" repo list "$OWNER" --no-archived --limit "$LIMIT" --json nameWithOwner --jq '.[].nameWithOwner' \
    > "$WORK/owner-repos" 2>"$WORK/owner-err" \
    || die "cannot list repositories of $OWNER: $(head -c 200 "$WORK/owner-err")"
  n=$(grep -c . "$WORK/owner-repos" || true)
  [ "$n" -gt 0 ] || die "listing of $OWNER returned no repositories"
  [ "$n" -lt "$LIMIT" ] || die "listing of $OWNER hit --limit $LIMIT and may be truncated"
  while IFS= read -r r || [ -n "$r" ]; do [ -n "$r" ] && REPOS+=("$r"); done < "$WORK/owner-repos"
fi
[ ${#REPOS[@]} -gt 0 ] || die "no repositories: give --repo, --repos or --owner"
for r in "${REPOS[@]}"; do [[ "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository '$r'"; done
PHANTOMS=$(printf '%s\n' "${CONTEXTS[@]}" | jq -R . | jq -sc .)
[ "$APPLY" = 1 ] && { mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"; }

# The phantom contexts a ruleset body lists, as a JSON array.
phantoms_in() {
  jq -c --argjson p "$PHANTOMS" '
    [.rules[]? | select(.type == "required_status_checks")
     | .parameters.required_status_checks[]?.context | select(. as $c | $p | index($c))] | unique' "$1"
}

# Plan: drop phantom contexts; drop the rule if nothing is left.
plan_body() {
  jq --argjson p "$PHANTOMS" '
    {name, target, enforcement, conditions, bypass_actors,
     rules: [ .rules[]
       | if .type == "required_status_checks" then
           .parameters.required_status_checks |= map(select(.context as $c | ($p | index($c)) | not))
         else . end
       | select(.type != "required_status_checks" or (.parameters.required_status_checks | length) > 0) ]}' "$1"
}

# Exactness guard. 0 = only phantom contexts (and an emptied rule) differ.
guard() {
  local live=$1 plan=$2
  local a b
  a=$(jq -S '{name,target,enforcement,conditions,bypass_actors,rules:[.rules[]|select(.type!="required_status_checks")]}' "$live")
  b=$(jq -S '{name,target,enforcement,conditions,bypass_actors,rules:[.rules[]|select(.type!="required_status_checks")]}' "$plan")
  [ "$a" = "$b" ] || return 1
  a=$(jq -cS --argjson p "$PHANTOMS" '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[]|select(.context as $c|($p|index($c))|not)]|sort' "$live")
  b=$(jq -cS '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[]]|sort' "$plan")
  [ "$a" = "$b" ]
}

# The fields a PUT writes; used to detect a change between the planning read and the write.
writable() { jq -S '{name,target,enforcement,conditions,bypass_actors,rules}' "$1"; }

for repo in "${REPOS[@]}"; do
  # --paginate: a repository can carry up to 75 repo + 75 org rulesets, more than one page.
  # gh prints one JSON array per page; -s 'add' merges them into a single array.
  if ! "$GH" api "repos/$repo/rulesets?includes_parents=true&per_page=100" --paginate > "$WORK/pages" 2>/dev/null \
     || ! jq -s 'add // []' "$WORK/pages" > "$WORK/list" 2>/dev/null \
     || ! jq -e 'type == "array"' "$WORK/list" >/dev/null 2>&1; then
    emit "$repo" UNKNOWN "rulesets list unreadable"; continue
  fi
  if jq -e 'any(.[]; has("source_type") | not)' "$WORK/list" >/dev/null; then
    emit "$repo" REFUSED "a ruleset carries no source_type"; continue
  fi
  # Read every ruleset first, so retired rule types are reported across ALL active
  # rulesets of the repository, not only the one that lists the phantom.
  rm -f "$WORK"/rs.*; unreadable=0
  while IFS=$'\t' read -r id _; do
    if ! "$GH" api "repos/$repo/rulesets/$id" > "$WORK/rs.$id" 2>/dev/null || ! jq -e '.rules' "$WORK/rs.$id" >/dev/null 2>&1; then
      emit "$repo" UNKNOWN "ruleset $id unreadable"; unreadable=1; rm -f "$WORK/rs.$id"
    fi
  done < <(jq -r '.[] | [.id, .source_type] | @tsv' "$WORK/list")
  also=""
  if compgen -G "$WORK/rs.*" >/dev/null; then
    also=$(jq -rs '[.[]|select(.enforcement=="active")|.rules[].type
             |select(.=="code_coverage" or .=="code_quality" or .=="required_deployments")]|unique|join(",")' "$WORK"/rs.*)
  fi
  found=$unreadable
  while IFS=$'\t' read -r id stype; do
    [ -f "$WORK/rs.$id" ] || continue
    cp "$WORK/rs.$id" "$WORK/live"
    hit=$(phantoms_in "$WORK/live")
    [ "$hit" = "[]" ] && continue
    found=1
    name=$(jq -r .name "$WORK/live")
    detail="ruleset $id '$name' lists $hit${also:+; also in this repo: $also (retired, not touched)}"
    if [ "$stype" != "Repository" ]; then emit "$repo" ORG-INHERITED "$detail; source_type=$stype"; continue; fi
    if [ "$(jq -r .enforcement "$WORK/live")" != "active" ]; then emit "$repo" DISABLED-SKIPPED "$detail"; continue; fi
    if ! jq -e 'has("bypass_actors")' "$WORK/live" >/dev/null; then emit "$repo" REFUSED "$detail; bypass_actors not returned"; continue; fi
    plan_body "$WORK/live" > "$WORK/plan"
    if ! guard "$WORK/live" "$WORK/plan"; then emit "$repo" REFUSED "$detail; exactness guard"; continue; fi
    kept=$(jq '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[]]|length' "$WORK/plan")
    shape=$([ "$kept" = 0 ] && echo "rule dropped" || echo "rule kept, $kept context(s) remain")
    if [ "$APPLY" = 0 ]; then emit "$repo" WOULD-RETIRE "$detail -> $shape"; continue; fi
    backup="$BACKUP_DIR/${repo//\//__}.$id.json"
    if ! cp "$WORK/live" "$backup" 2>/dev/null || ! cmp -s "$WORK/live" "$backup"; then
      emit "$repo" REFUSED "$detail; backup to $backup failed, nothing written"; continue
    fi
    # Re-read immediately before the write: a PUT replaces the whole object, so a change
    # made since the planning read (an owner edit, another applier) would be lost.
    if ! "$GH" api "repos/$repo/rulesets/$id" > "$WORK/fresh" 2>/dev/null \
       || [ "$(writable "$WORK/fresh")" != "$(writable "$WORK/live")" ]; then
      emit "$repo" REFUSED "$detail; ruleset changed or unreadable since it was read, nothing written; rerun"; continue
    fi
    if ! "$GH" api -X PUT "repos/$repo/rulesets/$id" --input "$WORK/plan" > /dev/null 2>"$WORK/err"; then
      emit "$repo" REFUSED "$detail; PUT failed: $(head -c 200 "$WORK/err" | tr '\n\t' '  ')"; continue
    fi
    if "$GH" api "repos/$repo/rulesets/$id" > "$WORK/after" 2>/dev/null && [ "$(phantoms_in "$WORK/after")" = "[]" ]; then
      emit "$repo" RETIRED "$detail -> $shape; backup $backup"
    else
      emit "$repo" WROTE-UNVERIFIED "$detail; verifying read failed or still lists a phantom"
    fi
  done < <(jq -r '.[] | [.id, .source_type] | @tsv' "$WORK/list")
  [ "$found" = 0 ] && emit "$repo" CLEAN ""
done

{ printf '# summary:'; sort "$STATES" | uniq -c | awk '{printf " %s=%s", $2, $1}'; echo; } >&2
grep -qE '^(REFUSED|UNKNOWN|WROTE-UNVERIFIED)$' "$STATES" && exit 3
exit 0
