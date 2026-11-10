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
#   * the lock names no `$/` ref and close-lock resolved every edge, and
#   * update-actions-lock.sh --verify-local (the gate's own verifier) passes.
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
# Usage: regen-dependabot-locks.sh [owner/repo]     (default: every repo the
#        installations can see).  DRY_RUN=1 regenerates but never commits.
# Env:   REGEN_TOKENS, DRY_RUN, REGEN_MAIN, GH_BIN (test stub), REGEN_TOOLS (dir
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
    if [ -z "$changed" ]; then echo current; else echo changed; fi
  )
  rm -f "$prior"
}

# Commit messages: a Dependabot/applier PR repair, and a default-branch repair.
BUMP_HEADLINE="chore(deps): regenerate actions.lock for this bump"
BUMP_BODY="Dependabot updated workflow refs without the lockfile. Regenerated with the estate repair order (scripts/regen-dependabot-locks.sh in metadatastician/standards) and verified with update-actions-lock.sh --verify-local."
REPAIR_HEADLINE="fix(ci): regenerate the stale actions.lock"
REPAIR_BODY="The default branch's actions.lock no longer matches its workflows' uses: refs, so the lock gate is red and GitHub refuses to start the workflows whose refs drifted. Regenerated with the estate repair order (scripts/regen-dependabot-locks.sh in metadatastician/standards, REGEN_MAIN=1) and verified with update-actions-lock.sh --verify-local and check-lock-sync.sh. Only actions.lock changes."

# Commit the checkout's actions.lock onto branch $2 of repo $1, only if the
# branch head is still $3, with headline $5 and body $6 (default: the
# Dependabot-bump message). Prints the new commit oid.
commit_lock() {
  local repo="$1" branch="$2" expected="$3" dir="$4" payload
  local headline="${5:-$BUMP_HEADLINE}" body="${6:-$BUMP_BODY}"
  payload="$(jq -n \
    --arg repo "$repo" --arg branch "$branch" --arg oid "$expected" \
    --arg path "$LOCK_PATH" --arg contents "$(base64 -w0 < "$dir/$LOCK_PATH")" \
    --arg headline "$headline" --arg body "$body" \
    '{query: "mutation($in: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $in) { commit { oid } } }",
      variables: {in: {
        branch: {repositoryNameWithOwner: $repo, branchName: $branch},
        expectedHeadOid: $oid,
        message: {headline: $headline, body: $body},
        fileChanges: {additions: [{path: $path, contents: $contents}]}}}}')"
  printf '%s' "$payload" | "$GH_BIN" api graphql --input - --jq '.data.createCommitOnBranch.commit.oid'
}

# The branch scripts/apply-workflow-pins-remote.sh opens its PRs from.
APPLIER_BRANCH="${APPLIER_BRANCH:-chore/re-point-standards-workflow-pins}"
# The branch this script opens default-branch repair PRs from (REGEN_MAIN=1).
REPAIR_BRANCH="${REPAIR_BRANCH:-chore/regenerate-actions-lock}"

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
  jq -r --arg applier "$APPLIER_BRANCH" --arg repair "$REPAIR_BRANCH" '.[]
    | select(((.user.login == "dependabot[bot]")
              or ((.user.login | endswith("[bot]"))
                  and (.head.ref == $applier or .head.ref == $repair)))
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
    outcome=""
    if ! "$GH_BIN" api -X POST "repos/$repo/git/refs" \
         -f ref="refs/heads/$REPAIR_BRANCH" -f sha="$sha" --silent 2>/dev/null; then
      # The branch exists. Reuse it only if it is a leftover of ours.
      msg="$("$GH_BIN" api "repos/$repo/commits/$REPAIR_BRANCH" --jq .commit.message 2>/dev/null || true)"
      if [ "${msg%%$'\n'*}" = "$REPAIR_HEADLINE" ] \
         && "$GH_BIN" api -X PATCH "repos/$repo/git/refs/heads/$REPAIR_BRANCH" \
              -f sha="$sha" -F force=true --silent 2>/dev/null; then
        :
      else
        outcome="repair-branch-exists"
      fi
    fi
    if [ -z "$outcome" ]; then
      if oid="$(commit_lock "$repo" "$REPAIR_BRANCH" "$sha" "$work/r" "$REPAIR_HEADLINE" "$REPAIR_BODY")" \
         && printf '%s' "$oid" | grep -Eq '^[0-9a-f]{40}$'; then
        if pr="$("$GH_BIN" api -X POST "repos/$repo/pulls" -f title="$REPAIR_HEADLINE" \
                  -f head="$REPAIR_BRANCH" -f base="$base" -f body="$REPAIR_BODY" --jq .number)" \
           && [ -n "$pr" ]; then
          outcome="pr-opened #$pr ($oid)"
        else
          outcome="pr-refused ($oid)"
        fi
      else
        outcome="commit-refused"
      fi
    fi
  fi
  printf '%s@%s\t%s\n' "$repo" "$base" "$outcome"
  rm -rf "$work"
}

# Process every candidate PR of repo $1 with token $2; print one
# "repo#N<TAB>outcome" line per PR examined. With REGEN_MAIN=1, then repair
# the default branch's own lock (see repair_main).
process_repo() {
  local repo="$1" token="$2" num ref sha work outcome oid err files prs
  export GH_TOKEN="$token"
  # Only a 404 means "no lock here". A rate limit or 5xx must stay visible, or
  # the repository is silently counted as examined.
  if ! err="$("$GH_BIN" api "repos/$repo/contents/$LOCK_PATH" --silent 2>&1)"; then
    case "$err" in *"HTTP 404"*) return 0 ;; esac
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
  if [ "${REGEN_MAIN:-0}" = 1 ]; then
    repair_main "$repo" "$prs"
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
