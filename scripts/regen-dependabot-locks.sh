#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# regen-dependabot-locks.sh — regenerate actions.lock on Dependabot PR branches.
#
# WHY THIS EXISTS
# ---------------
# Dependabot bumps the `uses:` refs in a workflow but never touches
# `.github/workflows/actions.lock`. The bump PR goes red on
# "Governance / Actions lockfile verify", is merged anyway (the check is not
# required), and main then drifts from its own lock — so every LATER pull
# request in that repository inherits a red it did not cause. Measured
# 2026-10-01 on sim-public-relations, cicd-squabbler, burble, stapeln and
# hypatia. This closes the loop at the source: the Dependabot PR is repaired
# before it can land.
#
# WHAT IT DOES, PER PULL REQUEST
# ------------------------------
# Selects open PRs authored by dependabot[bot], or opened by the standards pin
# applier (a bot author on its fixed branch; see select_prs), from a same-repo
# branch, that
# touch .github/workflows/, in a repository that already carries actions.lock.
# On a clone of the PR head it runs the estate lock repair order (see
# complete-job-refs.sh):
#   gh actions-lock → relock-sha-keys → complete-job-refs → close-lock → prune-stale
# then RESTORES every file except actions.lock, because `gh actions-lock`
# rewrite mode de-pins inline SHAs and can invent `uses: $/...` local refs.
# close-lock gets the lock as it stood before `gh actions-lock` (--prior). That
# lets a leaf whose tag has since moved keep its old `ref:` (close-lock.sh,
# MOVED TAGS).
# The result is committed only when:
#   * the ONLY changed path is .github/workflows/actions.lock,
#   * the lock names no `$/` ref and close-lock resolved every edge,
#   * update-actions-lock.sh --verify-local (the gate's own verifier) passes,
#     and so does check-lock-sync.sh, and
#   * check-lock-pin-contract.sh passes. --verify-local reports a leaf whose
#     `ref:` repeats its own SHA as the ADVISORY `sha-as-ref` and stays valid,
#     but the runner refuses that record ("invalid lockfile pin") in every
#     workflow that uses it. Without this check the bot could commit such a
#     record as a "repair" (hyperpolymath/laminar#99 carries five, written by
#     `gh actions-lock --no-narrow`).
# Anything else is reported and left for a human; nothing partial is written.
#
# The commit goes through GraphQL createCommitOnBranch with expectedHeadOid,
# authenticated as a GitHub App installation, so it is Verified (satisfies
# required_signatures) and refuses to land if Dependabot moved the branch
# meanwhile. A second run finds the lock current and does nothing.
#
# CREDENTIALS
# -----------
# One installation token per owner, passed as REGEN_TOKENS="owner=token ..."
# (the workflow mints them with actions/create-github-app-token). An empty set
# is reported as a warning and exits 0 — the job must not pretend it swept
# anything, and must not redden every schedule tick before the App exists.
#
# DEFAULT-BRANCH REPAIR (REGEN_MAIN=1)
# ------------------------------------
# Drift that already landed (a red lock check merged through automerge) is not
# on any open PR, so it is repaired separately: the default branch is cloned,
# regenerated with the same chain and the same refusals, and one lock-only PR
# is opened from $REPAIR_BRANCH. Nothing is pushed to the default branch. An
# existing $REPAIR_BRANCH is reused only when it is this script's own leftover
# (its head commit carries the repair headline) and no PR is open from it. An
# open repair PR is swept like a Dependabot PR. See repair_main.
#
# SINGLE-WRITER PIN BUMP (BUMP_PINS=1; owner ruling 2026-11-21)
# -------------------------------------------------------------
# Dependabot's github-actions ecosystem is off. bump_main clones the default
# branch, runs scripts/bump-action-pins.sh (third-party pins to the latest
# release; holds in config/settings/actions-bump-holds.txt), commits the bump
# LOCALLY, regenerates actions.lock on top of it with the same chain and
# refusals as above, and pushes the workflow edits and the lock in ONE commit
# (createCommitOnBranch) on $BUMP_PR_BRANCH, then opens one PR. The two files
# therefore cannot disagree. A repository with no lock gets the bump alone. It
# refuses any changed path outside .github/workflows and .github/actions. When
# the bump opened a PR, the lock-only repair is skipped for that repository. The
# App must hold Workflows: write for the push to be accepted.
#
# Usage: regen-dependabot-locks.sh [owner/repo]     (default: every repo the
#        installations can see).  DRY_RUN=1 regenerates but never commits.
# Env:   REGEN_TOKENS, DRY_RUN, REGEN_MAIN, BUMP_PINS, GH_BIN (test stub), REGEN_TOOLS (dir
#        holding the repair scripts; default: this script's directory).
set -uo pipefail

GH_BIN="${GH_BIN:-gh}"
REGEN_TOOLS="${REGEN_TOOLS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LOCK_PATH=.github/workflows/actions.lock

# Print one outcome token for the checkout in $1, leaving actions.lock modified
# only when the token is `changed`: no-lock | tool-failed | unresolvable |
# corrupt | dirty | unverified | current | changed.
#
# Repos with local composite actions (.github/actions/*) are regenerated like
# any other since standards#1122: complete-job-refs and prune-stale follow
# `uses: ./…` into the composites, and check-lock-sync.sh, run after
# --verify-local, fails a lock that is missing their refs. Before that, they
# were refused as `composite-unsupported`.
regen_lock() {
  local dir="$1" changed prior
  prior="$(mktemp)"
  (
    cd "$dir" || exit 1
    [ -f "$LOCK_PATH" ] || { echo no-lock; exit 0; }
    # Snapshot the lock before the tool rewrites it: close-lock may reuse a
    # record from it for a leaf whose tag moved (close-lock.sh, MOVED TAGS).
    cp "$LOCK_PATH" "$prior" || { echo tool-failed; exit 0; }
    # `gh actions-lock` exits non-zero whenever a workflow names a mutable
    # ref it will not auto-pin (e.g. hyperpolymath/cicd-suite/...@main, which
    # the template's dogfood-gate and main-estate-audit carry), even though it
    # has rewritten the lock for every other action. Measured 2026-10-05 on
    # proof-burrower#103: rc=1, lock rewritten, and the chain below plus
    # --verify-local then accepted it. So a non-zero exit is fatal only when
    # the tool left the lock untouched; otherwise the verifier stays the judge.
    local before
    before="$(git hash-object "$LOCK_PATH")"
    if ! "$GH_BIN" actions-lock >&2; then
      [ "$(git hash-object "$LOCK_PATH")" = "$before" ] && { echo tool-failed; exit 0; }
      echo "regen: gh actions-lock exited non-zero but rewrote the lock; continuing, --verify-local decides" >&2
    fi
    # Keep only the lock: undo every tool-authored workflow rewrite.
    git checkout --quiet -- . ":(exclude)$LOCK_PATH"
    git clean -fdq
    bash "$REGEN_TOOLS/relock-sha-keys.sh" >&2 || { echo tool-failed; exit 0; }
    bash "$REGEN_TOOLS/complete-job-refs.sh" >&2 || { echo tool-failed; exit 0; }
    GH_BIN="$GH_BIN" bash "$REGEN_TOOLS/close-lock.sh" --prior "$prior" >&2
    case $? in 0) ;; 3) echo unresolvable; exit 0 ;; *) echo tool-failed; exit 0 ;; esac
    bash "$REGEN_TOOLS/prune-stale.sh" >&2 || { echo tool-failed; exit 0; }
    if grep -Fq '$/' "$LOCK_PATH"; then echo corrupt; exit 0; fi
    changed="$(git status --porcelain --untracked-files=all)"
    if [ -n "$changed" ] && [ "$changed" != " M $LOCK_PATH" ]; then echo dirty; exit 0; fi
    if ! GH_BIN="$GH_BIN" bash "$REGEN_TOOLS/update-actions-lock.sh" --verify-local >&2; then
      echo unverified; exit 0
    fi
    # --verify-local cannot see refs used through local composite actions, or
    # job-level reusable-workflow refs; check-lock-sync.sh is the authority on
    # both, and it is the gate the PR will meet in CI.
    if ! bash "$REGEN_TOOLS/check-lock-sync.sh" >&2; then echo unverified; exit 0; fi
    # The representation contract is what the RUNNER enforces: a leaf whose
    # `ref:` is its own SHA passes both checks above and still kills every job
    # that uses it at `Set up job`. Exit 2 (not inspected) is refused too.
    if ! bash "$REGEN_TOOLS/check-lock-pin-contract.sh" "$LOCK_PATH" >&2; then
      echo unverified; exit 0
    fi
    if [ -z "$changed" ]; then echo current; else echo changed; fi
  )
  rm -f "$prior"
}

# Commit messages: a Dependabot/applier PR repair, and a default-branch repair.
BUMP_HEADLINE="chore(deps): regenerate actions.lock for this bump"
BUMP_BODY="Dependabot updated workflow refs without the lockfile. Regenerated with the estate repair order (scripts/regen-dependabot-locks.sh in metadatastician/standards) and verified with update-actions-lock.sh --verify-local."
REPAIR_HEADLINE="fix(ci): regenerate the stale actions.lock"
REPAIR_BODY="The default branch's actions.lock no longer matches its workflows' uses: refs, so the lock gate is red and GitHub refuses to start the workflows whose refs drifted. Regenerated with the estate repair order (scripts/regen-dependabot-locks.sh in metadatastician/standards, REGEN_MAIN=1) and verified with update-actions-lock.sh --verify-local and check-lock-sync.sh. Only actions.lock changes."

# Commit the files $7... (paths relative to checkout $4) onto branch $2 of repo
# $1, only if the branch head is still $3, with headline $5 and body $6, in ONE
# commit. Prints the new commit oid. The single-writer bump uses this to land
# workflow edits and actions.lock together, so the two can never disagree.
commit_files() {
  local repo="$1" branch="$2" expected="$3" dir="$4" headline="$5" body="$6" payload adds p
  shift 6
  adds="$(for p in "$@"; do
            jq -n --arg path "$p" --arg contents "$(base64 -w0 < "$dir/$p")" '{path: $path, contents: $contents}'
          done | jq -s .)"
  payload="$(jq -n \
    --arg repo "$repo" --arg branch "$branch" --arg oid "$expected" \
    --argjson adds "$adds" \
    --arg headline "$headline" --arg body "$body" \
    '{query: "mutation($in: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $in) { commit { oid } } }",
      variables: {in: {
        branch: {repositoryNameWithOwner: $repo, branchName: $branch},
        expectedHeadOid: $oid,
        message: {headline: $headline, body: $body},
        fileChanges: {additions: $adds}}}}')"
  printf '%s' "$payload" | "$GH_BIN" api graphql --input - --jq '.data.createCommitOnBranch.commit.oid'
}

# Commit the checkout's actions.lock onto branch $2 of repo $1, only if the
# branch head is still $3, with headline $5 and body $6 (default: the
# Dependabot-bump message). Prints the new commit oid.
commit_lock() {
  local repo="$1" branch="$2" expected="$3" dir="$4"
  commit_files "$repo" "$branch" "$expected" "$dir" "${5:-$BUMP_HEADLINE}" "${6:-$BUMP_BODY}" "$LOCK_PATH"
}

# The branch scripts/apply-workflow-pins-remote.sh opens its PRs from.
APPLIER_BRANCH="${APPLIER_BRANCH:-chore/re-point-standards-workflow-pins}"
# The branch this script opens default-branch repair PRs from (REGEN_MAIN=1).
REPAIR_BRANCH="${REPAIR_BRANCH:-chore/regenerate-actions-lock}"
# The branch the single-writer pin bump opens its PR from (BUMP_PINS=1); also set
# where bump_main is defined, so select_prs can match it.
BUMP_PR_BRANCH="${BUMP_PR_BRANCH:-chore/bump-action-pins}"

# Read a pulls-list JSON array on stdin; print "number<TAB>head_ref<TAB>head_sha"
# for each open, non-draft PR from a same-repo branch that changes workflow refs
# without touching the lock: one authored by Dependabot, or one opened by the
# standards pin applier (scripts/apply-workflow-pins-remote.sh). The applier
# rewrites `uses:` pins only, so without this its PRs die at startup on an
# unclosed lock record. It is matched on a bot author AND its fixed branch name,
# so a human's branch of the same name is never rewritten. This script's own
# default-branch repair PRs are matched the same way, so a repair PR that
# drifts again before it merges is regenerated rather than left stale.
select_prs() {
  jq -r --arg applier "$APPLIER_BRANCH" --arg repair "$REPAIR_BRANCH" --arg bump "$BUMP_PR_BRANCH" '.[]
    | select(((.user.login == "dependabot[bot]")
              or ((.user.login | endswith("[bot]"))
                  and (.head.ref == $applier or .head.ref == $repair or .head.ref == $bump)))
             and (.draft | not)
             and .head.repo.full_name == .base.repo.full_name)
    | [.number, .head.ref, .head.sha] | @tsv'
}

# Shallow-clone branch $3 of repo $2 into $1 with the installation token in
# $GH_TOKEN. The token travels as a header from the environment: never in
# argv, and never persisted in the checkout's remote.origin.url (CWE-522).
clone_branch() {
  local dest="$1" repo="$2" ref="$3"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)" \
    git clone --quiet --depth 1 --branch "$ref" \
    "https://github.com/$repo.git" "$dest" 2>/dev/null
}

# Open ONE PR from branch $5 of repo $1 (default branch $2 at $3) carrying the
# files $8... of checkout $4, in one commit headed $6 with body $7. Prints the
# outcome. Never moves a branch it did not create: an existing branch is reused
# only when it carries nothing but the default head $3 (a stranded leftover of a
# commit that was refused: no commit on it, nothing to lose) or its head commit
# carries headline $6; and no PR is open from it (the callers check the latter).
# When the commit is refused (typically the App lacks Workflows: write) the
# branch this call created or reused is deleted again, but only while it still
# points at $3, so the next run can retry. Needs Pull requests: write, and
# Workflows: write when a path is under .github/workflows/.
open_branch_pr() {
  local repo="$1" base="$2" sha="$3" dir="$4" branch="$5" headline="$6" body="$7" msg oid pr head actor author_login
  shift 7
  actor="$("$GH_BIN" api user --jq .login 2>/dev/null || true)"
  if ! "$GH_BIN" api -X POST "repos/$repo/git/refs" \
       -f ref="refs/heads/$branch" -f sha="$sha" --silent 2>/dev/null; then
    # The branch exists. Reuse it only if it is a leftover of ours.
    head="$("$GH_BIN" api "repos/$repo/git/ref/heads/$branch" --jq .object.sha 2>/dev/null || true)"
    msg="$("$GH_BIN" api "repos/$repo/commits/$branch" --jq .commit.message 2>/dev/null || true)"
    author_login="$("$GH_BIN" api "repos/$repo/commits/$branch" --jq '.author.login // empty' 2>/dev/null || true)"
    if [ -n "$head" ] && [ "$head" = "$sha" ]; then
      :
    elif [ -n "$actor" ] && [ "$author_login" = "$actor" ] \
       && [ "${msg%%$'\n'*}" = "$headline" ] \
       && "$GH_BIN" api -X PATCH "repos/$repo/git/refs/heads/$branch" \
            -f sha="$sha" -F force=true --silent 2>/dev/null; then
      :
    else
      echo "repair-branch-exists"; return 0
    fi
  fi
  if oid="$(commit_files "$repo" "$branch" "$sha" "$dir" "$headline" "$body" "$@")" \
     && printf '%s' "$oid" | grep -Eq '^[0-9a-f]{40}$'; then
    if pr="$("$GH_BIN" api -X POST "repos/$repo/pulls" -f title="$headline" \
              -f head="$branch" -f base="$base" -f body="$body" --jq .number)" \
       && [ -n "$pr" ]; then
      echo "pr-opened #$pr ($oid)"
    else
      echo "pr-refused ($oid)"
    fi
  else
    # Do not strand the branch: remove it only while it is still the bare
    # default head this call put it on, never one that has since moved.
    head="$("$GH_BIN" api "repos/$repo/git/ref/heads/$branch" --jq .object.sha 2>/dev/null || true)"
    author_login="$("$GH_BIN" api "repos/$repo/commits/$branch" --jq '.author.login // empty' 2>/dev/null || true)"
    if [ -n "$head" ] && [ "$head" = "$sha" ] && [ -n "$actor" ] && [ "$author_login" = "$actor" ]; then
      "$GH_BIN" api -X DELETE "repos/$repo/git/refs/heads/$branch" --silent 2>/dev/null || true
    fi
    echo "commit-refused"
  fi
}

# Repair a stale actions.lock on the default branch of repo $1, whose open PRs
# are the JSON array $2. Regenerates it with the same chain as a Dependabot
# PR and opens ONE lock-only PR from $REPAIR_BRANCH; prints
# "repo@branch<TAB>outcome". Dependabot repairs fix new drift; this fixes drift
# that already landed (a red lock check merged through automerge), which
# otherwise reddens every later PR and stops GitHub starting the drifted
# workflows. Never moves a branch it did not create: an existing
# $REPAIR_BRANCH is reused only when its head commit carries this script's
# repair headline and no PR is open from it. Needs Pull requests: write.
repair_main() {
  local repo="$1" prs="$2" base sha work outcome oid pr msg
  if printf '%s' "$prs" | jq -e --arg b "$REPAIR_BRANCH" \
       'any(.[]; .head.ref == $b and .head.repo.full_name == .base.repo.full_name)' >/dev/null; then
    printf '%s@main\trepair-pr-open\n' "$repo"; return 0
  fi
  if ! base="$("$GH_BIN" api "repos/$repo" --jq .default_branch)" || [ -z "$base" ] \
     || ! sha="$("$GH_BIN" api "repos/$repo/commits/$base" --jq .sha)"; then
    printf '%s@main\tapi-error\n' "$repo"; return 0
  fi
  work="$(mktemp -d)"
  if ! clone_branch "$work/r" "$repo" "$base"; then
    printf '%s@%s\tclone-failed\n' "$repo" "$base"; rm -rf "$work"; return 0
  fi
  if [ "$(git -C "$work/r" rev-parse HEAD)" != "$sha" ]; then
    printf '%s@%s\tmoved\n' "$repo" "$base"; rm -rf "$work"; return 0
  fi
  outcome="$(regen_lock "$work/r")"
  if [ "$outcome" = changed ] && [ "${DRY_RUN:-0}" != 1 ]; then
    outcome="$(open_branch_pr "$repo" "$base" "$sha" "$work/r" "$REPAIR_BRANCH" "$REPAIR_HEADLINE" "$REPAIR_BODY" "$LOCK_PATH")"
  fi
  printf '%s@%s\t%s\n' "$repo" "$base" "$outcome"
  rm -rf "$work"
}

# The branch and messages for the single-writer pin bump (BUMP_PINS=1).
BUMP_PR_BRANCH="${BUMP_PR_BRANCH:-chore/bump-action-pins}"
BUMP_PINS_HEADLINE="chore(deps): bump third-party action pins and actions.lock together"

# Bump third-party action pins on the default branch of repo $1 (open PRs: JSON
# array $2) and rewrite actions.lock in the SAME commit. This is the single
# writer: Dependabot's github-actions ecosystem is off, so nothing else moves
# a `uses:` SHA, and the lock is regenerated on top of the bump before anything
# is pushed. The bump is committed locally first so regen_lock's "restore every
# file except the lock" step keeps the bumped workflows. Refusals: any verdict
# regen_lock gives other than changed/current/no-lock, and any changed path
# outside .github/workflows or .github/actions. A repository with no lock gets
# the bump alone. Prints "repo@branch<TAB>outcome".
bump_main() {
  local repo="$1" prs="$2" base sha work outcome rows n p body
  local -a paths=()
  if printf '%s' "$prs" | jq -e --arg b "$BUMP_PR_BRANCH" \
       'any(.[]; .head.ref == $b and .head.repo.full_name == .base.repo.full_name)' >/dev/null; then
    printf '%s@main\tbump-pr-open\n' "$repo"; return 0
  fi
  if ! base="$("$GH_BIN" api "repos/$repo" --jq .default_branch)" || [ -z "$base" ] \
     || ! sha="$("$GH_BIN" api "repos/$repo/commits/$base" --jq .sha)"; then
    printf '%s@main\tapi-error\n' "$repo"; return 0
  fi
  work="$(mktemp -d)"
  if ! clone_branch "$work/r" "$repo" "$base"; then
    printf '%s@%s\tclone-failed\n' "$repo" "$base"; rm -rf "$work"; return 0
  fi
  if [ "$(git -C "$work/r" rev-parse HEAD)" != "$sha" ]; then
    printf '%s@%s\tmoved\n' "$repo" "$base"; rm -rf "$work"; return 0
  fi
  rows="$(bash "$REGEN_TOOLS/bump-action-pins.sh" "$work/r" 2>/dev/null)" || {
    printf '%s@%s\tbump-failed\n' "$repo" "$base"; rm -rf "$work"; return 0; }
  n="$(printf '%s\n' "$rows" | grep -c '	bumped$')"
  if [ -z "$(git -C "$work/r" status --porcelain)" ]; then
    printf '%s@%s\tcurrent\n' "$repo" "$base"; rm -rf "$work"; return 0
  fi
  git -C "$work/r" add -A && git -C "$work/r" -c user.name=pin-applier -c user.email=pin-applier@localhost \
    commit --quiet -m "bump" || { printf '%s@%s\tbump-failed\n' "$repo" "$base"; rm -rf "$work"; return 0; }
  outcome="$(regen_lock "$work/r")"
  case "$outcome" in
    changed|current|no-lock) ;;
    *) printf '%s@%s\tbump-%s\n' "$repo" "$base" "$outcome"; rm -rf "$work"; return 0 ;;
  esac
  # Everything now differing from the default head, bump and lock together.
  # NUL-delimited into an array, so a path with a space stays one path and
  # nothing is glob-expanded.
  mapfile -d '' -t paths < <(git -C "$work/r" diff --name-only -z "$sha")
  for p in "${paths[@]}"; do
    case "$p" in
      .github/workflows/*|.github/actions/*) ;;
      *) printf '%s@%s\tbump-unexpected-path\n' "$repo" "$base"; rm -rf "$work"; return 0 ;;
    esac
  done
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '%s@%s\twould-bump %s\n' "$repo" "$base" "$n"; rm -rf "$work"; return 0
  fi
  body="Third-party action pins moved to their latest release, and actions.lock rewritten in the same commit by the single-writer applier (scripts/bump-action-pins.sh and scripts/regen-dependabot-locks.sh, BUMP_PINS=1, in metadatastician/standards). Verified with update-actions-lock.sh --verify-local, check-lock-sync.sh and check-lock-pin-contract.sh where the repository has a lock.

$(printf '%s\n' "$rows" | awk -F'\t' '$5=="bumped"{printf "- %s: %s -> %s (%s)\n", $2, $3, $4, $1}' | head -n 40)"
  outcome="$(open_branch_pr "$repo" "$base" "$sha" "$work/r" "$BUMP_PR_BRANCH" "$BUMP_PINS_HEADLINE" "$body" "${paths[@]}")"
  printf '%s@%s\t%s\n' "$repo" "$base" "$outcome"
  rm -rf "$work"
}

# Process every candidate PR of repo $1 with token $2; print one
# "repo#N<TAB>outcome" line per PR examined. With REGEN_MAIN=1, then repair
# the default branch's own lock (see repair_main).
process_repo() {
  local repo="$1" token="$2" num ref sha work outcome oid err files prs bumped
  export GH_TOKEN="$token"
  # Only a 404 means "no lock here". A rate limit or 5xx must stay visible, or
  # the repository is silently counted as examined.
  if ! err="$("$GH_BIN" api "repos/$repo/contents/$LOCK_PATH" --silent 2>&1)"; then
    case "$err" in
      *"HTTP 404"*)
        # No lock here. With BUMP_PINS=1 the repository still gets its
        # third-party pins bumped (the bump alone; there is no lock to write).
        if [ "${BUMP_PINS:-0}" = 1 ]; then
          if ! prs="$("$GH_BIN" api --paginate "repos/$repo/pulls?state=open&per_page=100")"; then
            printf '%s\tapi-error\n' "$repo"; return 0
          fi
          bump_main "$repo" "$(printf '%s' "$prs" | jq -s 'add // []')"
        fi
        return 0 ;;
    esac
    printf '%s\tapi-error\n' "$repo"; return 0
  fi
  if ! prs="$("$GH_BIN" api --paginate "repos/$repo/pulls?state=open&per_page=100")"; then
    printf '%s\tapi-error\n' "$repo"; return 0
  fi
  prs="$(printf '%s' "$prs" | jq -s 'add // []')"
  while IFS=$'\t' read -r num ref sha; do
    [ -n "$num" ] || continue
    if ! files="$("$GH_BIN" api --paginate "repos/$repo/pulls/$num/files?per_page=100" --jq '.[].filename')"; then
      printf '%s#%s\tapi-error\n' "$repo" "$num"; continue
    fi
    printf '%s\n' "$files" | grep -q '^\.github/workflows/' || continue
    work="$(mktemp -d)"
    if ! clone_branch "$work/r" "$repo" "$ref"; then
      printf '%s#%s\tclone-failed\n' "$repo" "$num"; rm -rf "$work"; continue
    fi
    if [ "$(git -C "$work/r" rev-parse HEAD)" != "$sha" ]; then
      printf '%s#%s\tmoved\n' "$repo" "$num"; rm -rf "$work"; continue
    fi
    outcome="$(regen_lock "$work/r")"
    if [ "$outcome" = changed ] && [ "${DRY_RUN:-0}" != 1 ]; then
      if oid="$(commit_lock "$repo" "$ref" "$sha" "$work/r")" && printf '%s' "$oid" | grep -Eq '^[0-9a-f]{40}$'; then
        outcome="committed $oid"
      else
        outcome="commit-refused"
      fi
    fi
    printf '%s#%s\t%s\n' "$repo" "$num" "$outcome"
    rm -rf "$work"
  done < <(printf '%s' "$prs" | select_prs)
  # The bump regenerates the lock itself, so when it opened a PR the lock-only
  # repair is skipped: two PRs rewriting the same lock would conflict.
  bumped=""
  if [ "${BUMP_PINS:-0}" = 1 ]; then
    bumped="$(bump_main "$repo" "$prs")"
    printf '%s\n' "$bumped"
  fi
  if [ "${REGEN_MAIN:-0}" = 1 ]; then
    case "$bumped" in
      *"pr-opened"*) ;;
      *) repair_main "$repo" "$prs" ;;
    esac
  fi
}

# Enumerate every repository visible to each owner's installation token (or
# only $1), process them, and print the denominator alongside the outcomes.
# An owner whose enumeration fails is named and skipped, so the other owner is
# still swept; the run then exits non-zero.
main() {
  local only="${1:-}" pair owner token repos total=0 seen failed=0 tokens="${REGEN_TOKENS:-}"
  if [ -z "${tokens// /}" ]; then
    echo "::warning::regen-dependabot-locks: no App installation token (vars.APP_ID / secrets.APP_PRIVATE_KEY unset or the App is not installed). Nothing was examined."
    return 0
  fi
  for pair in $tokens; do
    owner="${pair%%=*}"; token="${pair#*=}"
    [ -n "$token" ] || { echo "::warning::no installation token for $owner — its repositories were NOT examined"; continue; }
    if [ -n "$only" ]; then
      [ "${only%%/*}" = "$owner" ] || continue
      repos="$only"
    else
      repos="$(GH_TOKEN="$token" "$GH_BIN" api --paginate 'installation/repositories?per_page=100' \
               --jq '.repositories[] | select(.archived | not) | .full_name')" || {
        echo "::error::could not enumerate $owner's installation repositories — NOT examined"
        failed=1; continue; }
    fi
    seen=$(printf '%s\n' "$repos" | grep -c .)
    total=$((total + seen))
    echo "$owner: $seen repositories in scope"
    while IFS= read -r r; do
      [ -n "$r" ] && process_repo "$r" "$token"
    done <<< "$repos"
  done
  echo "examined $total repositories"
  return "$failed"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
