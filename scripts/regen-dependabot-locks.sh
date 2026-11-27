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
# POST-PIN-BUMP HOOK (HOOK_PHASE=prepare|apply; owner-approved Option A)
# ---------------------------------------------------------------------
# A repository with scripts/post-pin-bump.sh is not given a bump PR by the main
# phase: bump_main DEFERS it (HOOK_DEFER_DIR). HOOK_PHASE=prepare runs the hook
# with no token, one container per deferral; HOOK_PHASE=apply takes the deferrals as
# the authority (one result each, identical row), treats the result as untrusted, re-derives the
# bump, and commits only the paths .github/post-pin-bump.paths allows. Every
# refusal is loud and fails the run. See 3-practice/ACTION-PINS-APPLIER.adoc.
#
# Usage: regen-dependabot-locks.sh [owner/repo]     (default: every repo the
#        installations can see).  DRY_RUN=1 regenerates but never commits.
# Env:   REGEN_TOKENS, DRY_RUN, REGEN_MAIN, BUMP_PINS, HOOK_DEFER_DIR, HOOK_RESULT_DIR, HOOK_IMAGE, HOOK_SANDBOX (none: tests only), DOCKER_BIN, IPTABLES_BIN/IP6TABLES_BIN (tests), GH_BIN (test stub), REGEN_TOOLS (dir
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
  # Who "we" are. An App installation token cannot call GET /user (403), so the
  # workflow passes the App slug as APPLIER_SLUG; a PAT falls back to /user.
  # Unknown means no reuse and no cleanup, never a guess.
  if [ -n "${APPLIER_SLUG:-}" ]; then
    actor="${APPLIER_SLUG}[bot]"
  else
    actor="$("$GH_BIN" api user --jq .login 2>/dev/null || true)"
  fi
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

# POST-PIN-BUMP HOOK (Option A, three phases; contract in
# 3-practice/ACTION-PINS-APPLIER.adoc). A repository may carry
# scripts/post-pin-bump.sh to regenerate files DERIVED from its pins (a
# lockfile, a generated table). Running repository code is never done where an
# App token exists, so a hook repo is split across three jobs:
#   apply         (token, no repo code)   bumps and relocks, then DEFERS the repo:
#                                         tree + meta go into $HOOK_DEFER_DIR.
#   hook-prepare  (NO token)              runs each hook in its own throwaway
#                                         container (hook_sandbox_run), with a
#                                         timeout, POST_PIN_BUMP=1 and no args, and
#                                         writes what it changed to $HOOK_RESULT_DIR.
#   hook-apply    (token, no repo code)   treats that result as UNTRUSTED: re-derives
#                                         the bump and the lock itself, reads the
#                                         allow-list from the DEFAULT branch, and
#                                         commits only allow-listed files, in the
#                                         same single commit, into the same PR.
HOOK_SCRIPT="scripts/post-pin-bump.sh"
HOOK_PATHS=".github/post-pin-bump.paths"
HOOK_TIMEOUT="${HOOK_TIMEOUT:-300}"
HOOK_MAX_FILES=200
HOOK_MAX_BYTES=1048576

# Hash of every file under .github/workflows and .github/actions in checkout $1:
# what the bump and the lock decided, so hook-apply can tell a stale hook result
# from a current one.
pin_hash() {
  (cd "$1" && { find .github/workflows .github/actions -type f -print0 2>/dev/null \
                  | LC_ALL=C sort -z | xargs -0 -r sha256sum; } | sha256sum | cut -d' ' -f1)
}

# Derive the bump of repo $1 on its default branch, in the shell (no subshell, so
# the outputs survive): DB_BASE, DB_SHA, DB_WORK (a temp dir whose r/ is the
# bumped and relocked checkout), DB_ROWS and DB_N. Returns 0, or returns 1 with
# DB_OUT set to the "repo@branch<TAB>outcome" line and nothing left on disk.
# Refusals: any verdict regen_lock gives other than changed/current/no-lock, and
# any changed path outside .github/workflows or .github/actions. A repository
# with no lock gets the bump alone.
derive_bump() {
  local repo="$1" outcome p
  local -a paths=()
  DB_BASE=main; DB_SHA=; DB_WORK=; DB_ROWS=; DB_N=0; DB_OUT=
  _db_fail() { printf -v DB_OUT '%s@%s\t%s' "$repo" "$DB_BASE" "$1"; [ -z "$DB_WORK" ] || rm -rf "$DB_WORK"; DB_WORK=; return 1; }
  if ! DB_BASE="$("$GH_BIN" api "repos/$repo" --jq .default_branch)" || [ -z "$DB_BASE" ] \
     || ! DB_SHA="$("$GH_BIN" api "repos/$repo/commits/$DB_BASE" --jq .sha)"; then
    DB_BASE=main; _db_fail api-error; return 1
  fi
  DB_WORK="$(mktemp -d)"
  clone_branch "$DB_WORK/r" "$repo" "$DB_BASE" || { _db_fail clone-failed; return 1; }
  [ "$(git -C "$DB_WORK/r" rev-parse HEAD)" = "$DB_SHA" ] || { _db_fail moved; return 1; }
  DB_ROWS="$(bash "$REGEN_TOOLS/bump-action-pins.sh" "$DB_WORK/r" 2>/dev/null)" || { _db_fail bump-failed; return 1; }
  DB_N="$(printf '%s\n' "$DB_ROWS" | grep -c '	bumped$')"
  [ -n "$(git -C "$DB_WORK/r" status --porcelain)" ] || { _db_fail current; return 1; }
  if ! { git -C "$DB_WORK/r" add -A && git -C "$DB_WORK/r" -c user.name=pin-applier -c user.email=pin-applier@localhost \
           commit --quiet -m "bump"; }; then
    _db_fail bump-failed; return 1
  fi
  outcome="$(regen_lock "$DB_WORK/r")"
  case "$outcome" in
    changed|current|no-lock) ;;
    *) _db_fail "bump-$outcome"; return 1 ;;
  esac
  # Everything now differing from the default head, bump and lock together.
  # NUL-delimited into an array, so a path with a space stays one path and
  # nothing is glob-expanded.
  mapfile -d '' -t paths < <(git -C "$DB_WORK/r" diff --name-only -z "$DB_SHA")
  for p in "${paths[@]}"; do
    case "$p" in
      .github/workflows/*|.github/actions/*) ;;
      *) _db_fail bump-unexpected-path; return 1 ;;
    esac
  done
  return 0
}

# Bump third-party action pins on the default branch of repo $1 (open PRs: JSON
# array $2) and rewrite actions.lock in the SAME commit. This is the single
# writer: Dependabot's github-actions ecosystem is off, so nothing else moves
# a `uses:` SHA, and the lock is regenerated on top of the bump before anything
# is pushed (see derive_bump). A repository that carries scripts/post-pin-bump.sh
# is deferred to the hook phases instead of getting a PR here. Prints
# "repo@branch<TAB>outcome".
bump_main() {
  local repo="$1" prs="$2" outcome body p vis
  local -a paths=()
  if printf '%s' "$prs" | jq -e --arg b "$BUMP_PR_BRANCH" \
       'any(.[]; .head.ref == $b and .head.repo.full_name == .base.repo.full_name)' >/dev/null; then
    printf '%s@main\tbump-pr-open\n' "$repo"; return 0
  fi
  derive_bump "$repo" || { printf '%s\n' "$DB_OUT"; return 0; }
  if [ -f "$DB_WORK/r/$HOOK_SCRIPT" ]; then
    # A hook repo never gets a PR from this phase: its derived files must be
    # regenerated first. Without a deferral directory that cannot happen, so
    # say so rather than open a PR whose derived files are stale.
    # The deferral is the whole checkout in a workflow artifact of this PUBLIC
    # repository. Only a public repository may be deferred; a private or
    # internal one (or one whose visibility cannot be read) is refused by name.
    vis="$("$GH_BIN" api "repos/$repo" --jq .visibility 2>/dev/null)" || vis=unknown
    if [ "$vis" != public ]; then
      echo "::error::hook-refused-nonpublic: $repo is not public; its hook was NOT run and no PR was opened"
      printf '%s@%s\thook-refused-nonpublic: visibility is %s; its tree would be published in a public artifact\n' "$repo" "$DB_BASE" "${vis:-unknown}"
      rm -rf "$DB_WORK"; return 0
    fi
    if [ "${DRY_RUN:-0}" = 1 ]; then
      printf '%s@%s\twould-bump %s (hook: deferred)\n' "$repo" "$DB_BASE" "$DB_N"
    elif [ -z "${HOOK_DEFER_DIR:-}" ]; then
      printf '%s@%s\tbump-hook-not-deferred\n' "$repo" "$DB_BASE"
    elif defer_hook "$repo" "$DB_BASE" "$DB_SHA" "$DB_WORK/r"; then
      printf '%s@%s\thook-deferred\n' "$repo" "$DB_BASE"
    else
      printf '%s@%s\thook-defer-failed\n' "$repo" "$DB_BASE"
    fi
    rm -rf "$DB_WORK"; return 0
  fi
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '%s@%s\twould-bump %s\n' "$repo" "$DB_BASE" "$DB_N"; rm -rf "$DB_WORK"; return 0
  fi
  mapfile -d '' -t paths < <(git -C "$DB_WORK/r" diff --name-only -z "$DB_SHA")
  body="$(bump_body "$DB_ROWS")"
  outcome="$(open_branch_pr "$repo" "$DB_BASE" "$DB_SHA" "$DB_WORK/r" "$BUMP_PR_BRANCH" "$BUMP_PINS_HEADLINE" "$body" "${paths[@]}")"
  printf '%s@%s\t%s\n' "$repo" "$DB_BASE" "$outcome"
  rm -rf "$DB_WORK"
}

# The PR body for the bump rows $1 (TSV from bump-action-pins.sh).
bump_body() {
  printf '%s\n\n%s' "Third-party action pins moved to their latest release, and actions.lock rewritten in the same commit by the single-writer applier (scripts/bump-action-pins.sh and scripts/regen-dependabot-locks.sh, BUMP_PINS=1, in metadatastician/standards). Verified with update-actions-lock.sh --verify-local, check-lock-sync.sh and check-lock-pin-contract.sh where the repository has a lock." \
    "$(printf '%s\n' "$1" | awk -F'\t' '$5=="bumped"{printf "- %s: %s -> %s (%s)\n", $2, $3, $4, $1}' | head -n 40)"
}

# PHASE 1 (apply): leave repo $1's bumped, relocked checkout $4 (default branch
# $2 at $3) in $HOOK_DEFER_DIR for the hook phase: tree.tar without .git, and
# meta.tsv (repo, base, head sha, pin hash). No repository code runs here.
defer_hook() {
  local repo="$1" base="$2" sha="$3" dir="$4" d
  d="$(mktemp -d "$HOOK_DEFER_DIR/d.XXXXXX")" || return 1
  if tar -C "$dir" --exclude=./.git -cf "$d/tree.tar" . \
     && printf '%s\t%s\t%s\t%s\n' "$repo" "$base" "$sha" "$(pin_hash "$dir")" > "$d/meta.tsv"; then
    return 0
  fi
  rm -rf "$d"; return 1
}

# Run one repository's hook in its own throwaway container. The container sees
# ONLY the copy of that one tree ($1, mounted at /work): default outbound network only (no credential, runner token or
# runner file is in reach), no
# capabilities, no setuid escalation, an unprivileged uid, no runner state
# ($RUNNER_TEMP, _actions, other deferrals, the Actions runtime token). That is
# what keeps a hostile hook from touching another repository's result, from
# rewriting the runner's action code, and from reaching ACTIONS_RUNTIME_TOKEN
# (and so the shared cache). $2 names the deferral. Exit status is the hook's;
# 124/137 mean timed out. The image is $HOOK_IMAGE (built in the workflow from a
# digest-pinned base plus snapshot packages): bash, coreutils, jq, git, ca-certificates.
# HOOK_SANDBOX=none runs the hook on the host and exists ONLY for the offline
# tests: it is refused under GITHUB_ACTIONS.
hook_sandbox_run() {
  local tree="$1" name="$2" cname rc
  if [ "${HOOK_SANDBOX:-docker}" = none ]; then
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
      echo "hook-prepare: HOOK_SANDBOX=none is refused on a runner"; return 125
    fi
    ( cd "$tree" && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$tree/.." LANG=C.UTF-8 POST_PIN_BUMP=1 \
        timeout --kill-after=10 "$HOOK_TIMEOUT" bash "$HOOK_SCRIPT" </dev/null )
    return $?
  fi
  [ -n "${HOOK_IMAGE:-}" ] || { echo "hook-prepare: HOOK_IMAGE is not set"; return 125; }
  chmod -R a+rwX "$tree" 2>/dev/null
  cname="hook-${name//[^A-Za-z0-9_.-]/_}-$$"
  # The container's own scratch dir (its tmpfs), not a host path.
  # hypatia: allow content_patterns/hardcoded_tmp -- path inside the hook container, mounted as a private tmpfs
  local ctmp=/tmp
  # shellcheck disable=SC2016
  "${DOCKER_BIN:-docker}" run --rm --name "$cname" \
      --user 65534:65534 --cap-drop ALL \
      --security-opt no-new-privileges --pids-limit 512 --memory 2g \
      --read-only --tmpfs /tmp:rw,exec,size=512m \
      -v "$tree:/work:rw" -w /work \
      -e POST_PIN_BUMP=1 -e "HOME=$ctmp/home" -e "TMPDIR=$ctmp" -e LANG=C.UTF-8 \
      -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      "$HOOK_IMAGE" \
      sh -c 'umask 0; mkdir -p "$HOME"; exec timeout --kill-after=10 "$0" bash "$1"' "$HOOK_TIMEOUT" "$HOOK_SCRIPT" \
      </dev/null &
  local pid=$!
  # Outer guard: if the container ignores its own timeout, remove it.
  ( sleep $((HOOK_TIMEOUT + 30)); "${DOCKER_BIN:-docker}" rm -f "$cname" >/dev/null 2>&1 ) &
  local guard=$!
  wait "$pid"; rc=$?
  kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null
  return "$rc"
}

# git on a tree a hook has written: nothing from the runner's git config or the
# tree itself may steer it (no global or system config, no hooks, no lfs
# filters, no fsmonitor, no external attributes file).
hook_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git \
    -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.attributesFile=/dev/null \
    -c filter.lfs.process= -c filter.lfs.smudge= -c filter.lfs.clean= -c filter.lfs.required=false \
    "$@"
}

# The hook container has the default bridge and the internet (owner ruling,
# 2026-11-27), but not the host or the cloud's metadata service. Before any hook
# container runs, drop its subnet's traffic to link-local (169.254.0.0/16, and
# fe80::/10 when the bridge has IPv6) and to the bridge gateway, which is the
# host itself. DOCKER-USER is the FORWARD-path hook Docker leaves for operators:
# it stops link-local. Traffic to the gateway address is delivered to the host,
# so it never crosses FORWARD; that rule is also placed in INPUT, where it acts.
# Then a probe container checks the result: DNS must still resolve and the
# metadata address must not connect. Any rule that cannot be added, or a wrong
# probe, stops hook-prepare: the hook must not run without this.
hook_fw_add() {
  local -a c=()
  while [ "$1" != -- ]; do c+=("$1"); shift; done
  shift
  local chain="$1"; shift
  "${c[@]}" -C "$chain" "$@" >/dev/null 2>&1 && return 0
  "${c[@]}" -I "$chain" "$@"
}

hook_egress_guard() {
  local d="${DOCKER_BIN:-docker}" net sub gw v4=0 rc
  local -a ipt ip6t
  if [ -n "${IPTABLES_BIN:-}" ]; then ipt=("$IPTABLES_BIN"); else ipt=(sudo iptables); fi
  if [ -n "${IP6TABLES_BIN:-}" ]; then ip6t=("$IP6TABLES_BIN"); else ip6t=(sudo ip6tables); fi
  net="$("$d" network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}} {{.Gateway}}{{"\n"}}{{end}}' 2>&1)" \
    || { echo "hook-prepare: egress-guard: cannot read the docker bridge: $net"; return 1; }
  while read -r sub gw; do
    [ -n "$sub" ] || continue
    case "$sub" in *[!0-9a-fA-F:./]*|*/*/*|*/) echo "hook-prepare: egress-guard: odd bridge subnet '$sub'"; return 1 ;; esac
    case "$gw" in *[!0-9a-fA-F:.]*) echo "hook-prepare: egress-guard: odd bridge gateway '$gw'"; return 1 ;; esac
    if [ "${sub#*:}" != "$sub" ]; then
      hook_fw_add "${ip6t[@]}" -- DOCKER-USER -s "$sub" -d fe80::/10 -j DROP \
        || { echo "hook-prepare: egress-guard: cannot add the fe80::/10 rule"; return 1; }
      [ -z "$gw" ] || { hook_fw_add "${ip6t[@]}" -- DOCKER-USER -s "$sub" -d "$gw" -j DROP \
        && hook_fw_add "${ip6t[@]}" -- INPUT -s "$sub" -d "$gw" -j DROP; } \
        || { echo "hook-prepare: egress-guard: cannot add the IPv6 gateway rule"; return 1; }
    else
      [ -n "$gw" ] || { echo "hook-prepare: egress-guard: the bridge has no gateway"; return 1; }
      v4=1
      { hook_fw_add "${ipt[@]}" -- DOCKER-USER -s "$sub" -d 169.254.0.0/16 -j DROP \
        && hook_fw_add "${ipt[@]}" -- DOCKER-USER -s "$sub" -d "$gw" -j DROP \
        && hook_fw_add "${ipt[@]}" -- INPUT -s "$sub" -d "$gw" -j DROP; } \
        || { echo "hook-prepare: egress-guard: cannot add the IPv4 rules"; return 1; }
    fi
  done <<< "$net"
  [ "$v4" = 1 ] || { echo "hook-prepare: egress-guard: no IPv4 subnet on the docker bridge"; return 1; }
  [ -n "${HOOK_IMAGE:-}" ] || { echo "hook-prepare: HOOK_IMAGE is not set"; return 125; }
  # shellcheck disable=SC2016
  "$d" run --rm --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges \
      --read-only --pids-limit 64 --memory 256m "$HOOK_IMAGE" \
      bash -c 'getent hosts github.com >/dev/null || exit 10
               if timeout 5 bash -c ": </dev/tcp/169.254.169.254/80" 2>/dev/null; then exit 11; fi' </dev/null
  rc=$?
  case "$rc" in
    0) echo "hook-prepare: egress-guard: rules in place; DNS works, metadata is unreachable" ;;
    10) echo "hook-prepare: egress-guard: DNS broke after the rules (getent github.com failed)"; return 1 ;;
    11) echo "hook-prepare: egress-guard: 169.254.169.254:80 is still reachable"; return 1 ;;
    *) echo "hook-prepare: egress-guard: probe failed rc=$rc"; return 1 ;;
  esac
}

# PHASE 2 (hook-prepare): holds NO App token, and the job must not either. For
# each deferral in $HOOK_DEFER_DIR, run the repository's hook on a copy of its
# tree inside its own container (hook_sandbox_run; outbound network, one tree, no
# arguments; $HOOK_TIMEOUT seconds) and write to $HOOK_RESULT_DIR/<deferral>/,
# named after the deferral directory:
#   meta.tsv    the deferral's meta, copied
#   status      ok | no-hook | hook-failed rc=N | hook-timeout | hook-error
#   hook.log    the hook's output, truncated
#   changed.nul NUL-separated (mode, path) pairs for every added, modified or
#               deleted path; mode 000000 means deleted
#   files/      the new bytes of each added or modified regular file
# EVERYTHING written here is untrusted: the hook ran as this user and may have
# done anything to it. hook-apply re-checks all of it.
hook_prepare() {
  local in="${HOOK_DEFER_DIR:?HOOK_DEFER_DIR is not set}" out="${HOOK_RESULT_DIR:?HOOK_RESULT_DIR is not set}"
  local d n=0 o t rc mode path status
  mkdir -p "$out" || return 1
  # Before any hook container: block link-local and the host, then probe (see hook_egress_guard).
  if [ "${HOOK_SANDBOX:-docker}" != none ] && compgen -G "$in/*/" >/dev/null; then
    hook_egress_guard || return 1
  fi
  for d in "$in"/*/; do
    [ -d "$d" ] || continue
    n=$((n + 1)); o="$out/$(basename -- "${d%/}")"; mkdir -p "$o/files"
    if [ ! -f "$d/meta.tsv" ] || [ ! -f "$d/tree.tar" ]; then
      echo "hook-error" > "$o/status"; echo "hook-prepare: deferral $d is malformed"; continue
    fi
    cp "$d/meta.tsv" "$o/meta.tsv"
    t="$(mktemp -d)"; mkdir -p "$t/tree" "$t/home"
    if ! tar -C "$t/tree" -xf "$d/tree.tar" --no-same-owner 2>/dev/null \
       || [ ! -f "$t/tree/$HOOK_SCRIPT" ]; then
      echo "no-hook" > "$o/status"; rm -rf "$t"; continue
    fi
    # The baseline lives outside the tree, so the hook cannot rewrite what it is
    # compared against by editing the tree.
    export GIT_DIR="$t/git" GIT_WORK_TREE="$t/tree"
    if ! { hook_git init -q && hook_git add -A -f \
             && hook_git -c user.name=x -c user.email=x@localhost commit -q -m base; }; then
      unset GIT_DIR GIT_WORK_TREE; echo "hook-error" > "$o/status"; rm -rf "$t"; continue
    fi
    hook_sandbox_run "$t/tree" "$(basename -- "${d%/}")" > "$t/hook.log" 2>&1
    rc=$?
    head -c 20000 "$t/hook.log" > "$o/hook.log"
    case "$rc" in
      0) status=ok ;;
      124|137) status=hook-timeout ;;
      *) status="hook-failed rc=$rc" ;;
    esac
    echo "$status" > "$o/status"
    if [ "$status" = ok ]; then
      # Fail closed: a hook can leave files git cannot read (mode 000, owned by
      # another uid). A failed add or diff must not look like "no changes".
      if ! hook_git add -A -f >/dev/null 2>"$t/git.err" \
         || ! hook_git diff --cached --raw -z --no-renames HEAD > "$t/diff.raw" 2>>"$t/git.err"; then
        echo "hook-error" > "$o/status"; head -c 2000 "$t/git.err" >> "$o/hook.log"
        unset GIT_DIR GIT_WORK_TREE; rm -rf "$t"; continue
      fi
      : > "$o/changed.nul"
      while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        mode="${meta#:* }"; mode="${mode%% *}"
        printf '%s\0%s\0' "$mode" "$path" >> "$o/changed.nul"
        case "$mode" in 100644|100755)
          if [ -f "$t/tree/$path" ] && [ ! -L "$t/tree/$path" ]; then
            mkdir -p "$o/files/$(dirname -- "$path")" && cp -- "$t/tree/$path" "$o/files/$path"
          fi ;;
        esac
      done < "$t/diff.raw"
    fi
    unset GIT_DIR GIT_WORK_TREE
    rm -rf "$t"
  done
  echo "hook-prepare: $n deferral(s) processed"
}

# A path a hook may ever be allowed to write: relative, clean, no control
# characters, nothing inside .git.
hook_path_safe() {
  case "$1" in
    ''|/*|*//*|./*|../*|*/./*|*/../*|*/.|*/..|.|..|.git|.git/*|*/.git|*/.git/*) return 1 ;;
  esac
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}

# Reserved: the applier re-derives these itself, and a hook may not rewrite its
# own script or its own allow-list.
hook_path_reserved() {
  case "$1" in
    .github/workflows/*|.github/actions/*|"$HOOK_SCRIPT"|"$HOOK_PATHS") return 0 ;;
  esac
  return 1
}

# True when root $1 holds relative path $2 as a regular file reached through no
# symlink at any component.
plain_file() {
  local root="$1" rel="$2" cur="$1" part
  local -a parts
  IFS=/ read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    cur="$cur/$part"
    [ ! -L "$cur" ] || return 1
  done
  [ -f "$cur" ]
}

# True when no component of relative path $2 below root $1 is a symlink (the
# last one may be missing).
no_symlink_parents() {
  local cur="$1" part
  local -a parts
  IFS=/ read -r -a parts <<< "$2"
  for part in "${parts[@]}"; do
    cur="$cur/$part"
    [ ! -L "$cur" ] || return 1
  done
  return 0
}

# Read allow-list lines from stdin and print the valid ones; print nothing and
# return 1 on the first invalid line. A line is a file path, or a directory
# prefix ending in `/`. No globs. Blank lines and `#` comments are ignored. A
# pattern that could reach a reserved path is invalid.
hook_allowlist() {
  local line bare r
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    bare="${line%/}"
    hook_path_safe "$bare" || return 1
    case "$line" in
      */) for r in .github/workflows/x .github/actions/x "$HOOK_SCRIPT" "$HOOK_PATHS"; do
            case "$r" in "$line"*) return 1 ;; esac
          done ;;
      *) ! hook_path_reserved "$line" || return 1 ;;
    esac
    printf '%s\n' "$line"
  done
}

# Whether path $1 is covered by the allow-list lines in $2.
hook_allowed() {
  local path="$1" pat
  while IFS= read -r pat; do
    case "$pat" in
      */) case "$path" in "$pat"*) return 0 ;; esac ;;
      *)  [ "$path" = "$pat" ] && return 0 ;;
    esac
  done <<< "$2"
  return 1
}

# PHASE 3, one repository: result directory $1 (untrusted), token already in
# GH_TOKEN. Prints "repo@branch<TAB>outcome" and returns 1 when the outcome is a
# refusal that must fail the run.
hook_apply_repo() {
  local def="$1" res="$2" repo base sha pins status prs allow n=0 mode path root size tmode want outcome body
  local -a paths=() hookpaths=()
  # The deferral row is authoritative; the result row must be byte-identical.
  IFS=$'\t' read -r repo base sha pins < "$def/meta.tsv" || { printf 'unknown\thook-bad-meta\n'; return 1; }
  if ! { [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] \
         && [[ "$pins" =~ ^[0-9a-f]{64}$ ]]; }; then
    printf 'unknown\thook-bad-meta\n'; return 1
  fi
  if ! cmp -s "$def/meta.tsv" "$res/meta.tsv"; then
    printf '%s\thook-result-mismatch: the result row differs from the deferral\n' "$repo"; return 1
  fi
  status="$(head -c 100 "$res/status" 2>/dev/null)"
  if [ "$status" != ok ]; then printf '%s\thook-refused: %s\n' "$repo" "${status:-no status}"; return 1; fi
  if ! prs="$("$GH_BIN" api --paginate "repos/$repo/pulls?state=open&per_page=100")"; then
    printf '%s\tapi-error\n' "$repo"; return 1
  fi
  prs="$(printf '%s' "$prs" | jq -s 'add // []')"
  if printf '%s' "$prs" | jq -e --arg b "$BUMP_PR_BRANCH" \
       'any(.[]; .head.ref == $b and .head.repo.full_name == .base.repo.full_name)' >/dev/null; then
    printf '%s@%s\tbump-pr-open: a bump PR is already open, so the hook result was NOT applied\n' "$repo" "$base"; return 1
  fi
  # Re-derive. Nothing of the hook phase's tree is used: only its result files.
  derive_bump "$repo" || { printf '%s\n' "$DB_OUT"; return 1; }
  root="$DB_WORK/r"
  if [ "$DB_SHA" != "$sha" ]; then
    printf '%s@%s\thook-stale-head\n' "$repo" "$DB_BASE"; rm -rf "$DB_WORK"; return 1
  fi
  if [ "$(pin_hash "$root")" != "$pins" ]; then
    printf '%s@%s\thook-stale-pins\n' "$repo" "$DB_BASE"; rm -rf "$DB_WORK"; return 1
  fi
  if ! git -C "$root" cat-file -e "$sha:$HOOK_SCRIPT" 2>/dev/null; then
    printf '%s@%s\thook-refused: the default branch has no %s\n' "$repo" "$DB_BASE" "$HOOK_SCRIPT"; rm -rf "$DB_WORK"; return 1
  fi
  # Read the allow-list from the default-branch commit, never from the tree the
  # hook ran in.
  allow="$(git -C "$root" show "$sha:$HOOK_PATHS" 2>/dev/null)" || allow=""
  if ! allow="$(printf '%s\n' "$allow" | hook_allowlist)"; then
    printf '%s@%s\thook-refused: invalid %s\n' "$repo" "$DB_BASE" "$HOOK_PATHS"; rm -rf "$DB_WORK"; return 1
  fi
  [ -f "$res/changed.nul" ] || : > "$res/changed.nul"
  while IFS= read -r -d '' mode && IFS= read -r -d '' path; do
    n=$((n + 1))
    if [ "$n" -gt "$HOOK_MAX_FILES" ]; then
      printf '%s@%s\thook-refused: more than %s changed paths\n' "$repo" "$DB_BASE" "$HOOK_MAX_FILES"; rm -rf "$DB_WORK"; return 1
    fi
    if ! hook_path_safe "$path" || hook_path_reserved "$path"; then
      printf '%s@%s\thook-refused: path not allowed: %s\n' "$repo" "$DB_BASE" "${path//[[:cntrl:]]/?}"; rm -rf "$DB_WORK"; return 1
    fi
    if [ -z "$allow" ] || ! hook_allowed "$path" "$allow"; then
      printf '%s@%s\thook-refused: not in %s: %s\n' "$repo" "$DB_BASE" "$HOOK_PATHS" "$path"; rm -rf "$DB_WORK"; return 1
    fi
    case "$mode" in
      100644|100755) ;;
      000000) printf '%s@%s\thook-refused: deletion: %s\n' "$repo" "$DB_BASE" "$path"; rm -rf "$DB_WORK"; return 1 ;;
      *) printf '%s@%s\thook-refused: not a regular file (mode %s): %s\n' "$repo" "$DB_BASE" "$mode" "$path"; rm -rf "$DB_WORK"; return 1 ;;
    esac
    # The mode cannot be set through createCommitOnBranch: an existing file
    # keeps its own, and a new file is 100644.
    tmode="$(git -C "$root" ls-tree "$sha" -- "$path" | awk '{print $1}')"
    if [ -n "$tmode" ]; then want="$tmode"; else want=100644; fi
    if [ "$mode" != "$want" ]; then
      printf '%s@%s\thook-refused: file mode change: %s\n' "$repo" "$DB_BASE" "$path"; rm -rf "$DB_WORK"; return 1
    fi
    if [ -L "$res/files" ] || ! plain_file "$res/files" "$path" || ! no_symlink_parents "$root" "$path"; then
      printf '%s@%s\thook-refused: unreadable or symlinked: %s\n' "$repo" "$DB_BASE" "$path"; rm -rf "$DB_WORK"; return 1
    fi
    size="$(stat -c %s "$res/files/$path")"
    if [ "$size" -gt "$HOOK_MAX_BYTES" ]; then
      printf '%s@%s\thook-refused: over %s bytes: %s\n' "$repo" "$DB_BASE" "$HOOK_MAX_BYTES" "$path"; rm -rf "$DB_WORK"; return 1
    fi
    hookpaths+=("$path")
  done < "$res/changed.nul"
  for path in "${hookpaths[@]}"; do
    if ! { mkdir -p "$root/$(dirname -- "$path")" && cp -- "$res/files/$path" "$root/$path"; }; then
      printf '%s@%s\thook-refused: cannot place: %s\n' "$repo" "$DB_BASE" "$path"; rm -rf "$DB_WORK"; return 1
    fi
  done
  mapfile -d '' -t paths < <(git -C "$root" diff --name-only -z "$sha"; git -C "$root" ls-files -z --others --exclude-standard)
  for path in "${paths[@]}"; do
    case "$path" in
      .github/workflows/*|.github/actions/*) ;;
      *) if hook_path_reserved "$path" || ! hook_allowed "$path" "$allow"; then
           printf '%s@%s\thook-refused: unexpected path: %s\n' "$repo" "$DB_BASE" "$path"; rm -rf "$DB_WORK"; return 1
         fi ;;
    esac
  done
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '%s@%s\twould-bump %s (+%s hook file(s))\n' "$repo" "$DB_BASE" "$DB_N" "${#hookpaths[@]}"; rm -rf "$DB_WORK"; return 0
  fi
  body="$(bump_body "$DB_ROWS")"
  if [ "${#hookpaths[@]}" -gt 0 ]; then
    body="$body

Regenerated by the repository's own scripts/post-pin-bump.sh in a token-less job, and accepted only because $HOOK_PATHS on the default branch allows them:
$(printf -- '- %s\n' "${hookpaths[@]}")"
  fi
  outcome="$(open_branch_pr "$repo" "$DB_BASE" "$DB_SHA" "$root" "$BUMP_PR_BRANCH" "$BUMP_PINS_HEADLINE" "$body" "${paths[@]}")"
  printf '%s@%s\t%s\n' "$repo" "$DB_BASE" "$outcome"
  rm -rf "$DB_WORK"
  case "$outcome" in pr-opened*) return 0 ;; *) return 1 ;; esac
}

# PHASE 3 driver. The deferral directories in $HOOK_DEFER_DIR (downloaded from
# the token job's own artifact) are the authority: repo, owner and token come
# from them, never from a result. Each deferral needs exactly one result
# directory of the same name whose meta.tsv is byte-identical; a missing,
# duplicate (a result name that is not a deferral, or a second result for one)
# or extra result is a loud failure. Any refusal is printed as an ::error:: and
# makes the run fail; nothing partial is ever pushed.
hook_apply_main() {
  local def res name tokens="${REGEN_TOKENS:-}" pair repo owner token failed=0 n=0 line r
  local -A tok=() want=()
  local in="${HOOK_DEFER_DIR:?HOOK_DEFER_DIR is not set}" out="${HOOK_RESULT_DIR:?HOOK_RESULT_DIR is not set}"
  for pair in $tokens; do [ -n "${pair#*=}" ] && tok["${pair%%=*}"]="${pair#*=}"; done
  for def in "$in"/*/; do
    [ -d "$def" ] || continue
    want["$(basename -- "${def%/}")"]=1
  done
  # Anything in the result that no deferral asked for.
  for r in "$out"/* "$out"/.[!.]*; do
    [ -e "$r" ] || [ -L "$r" ] || continue
    name="$(basename -- "$r")"
    if [ -z "${want[$name]:-}" ]; then
      echo "::error::hook-apply: hook-result-extra: result '${name//[^A-Za-z0-9_.-]/?}' matches no deferral"
      failed=1
    fi
  done
  for def in "$in"/*/; do
    [ -d "$def" ] || continue
    n=$((n + 1)); name="$(basename -- "${def%/}")"; res="$out/$name"
    repo="$(cut -f1 "$def/meta.tsv" 2>/dev/null | head -c 200)"
    owner="${repo%%/*}"; token="${tok[$owner]:-}"
    if [ -L "$res" ] || [ ! -d "$res" ]; then
      echo "::error::hook-apply: hook-result-missing: no result for deferral '$name' (${repo//[[:cntrl:]]/?})"
      failed=1; continue
    fi
    if [ -z "$token" ]; then
      echo "::error::hook-apply: no installation token for '${owner//[[:cntrl:]]/?}'; ${repo//[[:cntrl:]]/?} NOT processed"
      failed=1; continue
    fi
    export GH_TOKEN="$token"
    line="$(hook_apply_repo "${def%/}" "$res")" || { failed=1; echo "::error::hook-apply: $line"; continue; }
    printf '%s\n' "$line"
  done
  echo "hook-apply: $n deferral(s) examined"
  return "$failed"
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
  case "${HOOK_PHASE:-}" in
    '')      main "$@" ;;
    prepare) hook_prepare ;;
    apply)   hook_apply_main ;;
    *)       echo "::error::unknown HOOK_PHASE '${HOOK_PHASE}' (want prepare or apply)"; exit 2 ;;
  esac
fi
