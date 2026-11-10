#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# propagate-workflow-pins.sh — Deliberate, audit-first propagation of the
#   standards reusable-workflow SHA pins to consumer repos.
#
# This is the *deliberate-bump* half of the workflow-staleness story. The gate
# (scripts/check-workflow-staleness.sh) no longer forces a consumer to HEAD on
# every standards commit — it tolerates pins within a recency window (see
# docs/decisions/ADR-003-workflow-pin-staleness-window.adoc). This script is
# how a bump actually lands when one is *wanted* (e.g. to pick up a fix early,
# or on a scheduled cadence): it rewrites a consumer's standards reusable pins
# to a target SHA so a human / gitbot-fleet can open a bump PR.
#
# It is the concrete standards-side action referenced by the Hypatia
# `sha_bump_propagation` rule (hyperpolymath/hypatia): that rule surfaces a
# `:review` finding "consumer pin is behind standards HEAD"; the routed fix is
# to run this script (--fix) in the consumer checkout and open a draft PR. The
# rule decides *whether* to bump; this script performs the edit.
#
# Mode: READ-ONLY (audit) by default.
#   Pass --fix to stage the rewrite on a branch in each affected repo.
#   The script NEVER commits or pushes — that is the human's / bot's job
#   (estate guardrail: no unattended mutations; mirrors
#   scripts/propagate-gitignore-67-68.sh).
#
# Principles (do not violate):
#   * Non-destructive: only rewrites the SHA after a standards reusable `@`,
#     and moves a pin still under the former owner to the current one.
#   * Idempotent: pins already at the target are left untouched.
#   * No auto-commit / auto-push.
#   * Shell-only: no Python, no Ruby.
#
# Usage:
#   bash scripts/propagate-workflow-pins.sh [--fix] [--to <sha>] [PATH]
#
#   PATH may be a single consumer repo (has .github/workflows) or a parent
#   directory of many repos. Defaults to the current directory.
#   --to <sha>  target standards SHA to pin to. If omitted, resolved from
#               (in order) $STANDARDS_TARGET_SHA, the main ref of a local
#               standards checkout ($STANDARDS_DIR or ~/standards), then the
#               remote main ref. A feature-worktree HEAD is never selected.
#
# Output: tab-separated audit lines suitable for review.

set -euo pipefail

# The shared ancestry assertion (D5c): every pin bumper calls the same one.
# shellcheck source-path=SCRIPTDIR source=lib/pin-ancestry.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/pin-ancestry.sh"

# ---------------------------------------------------------------------------
# Configuration / argument parsing
# ---------------------------------------------------------------------------

FIX_MODE=false
LOCK_REFUSED=0
TARGET_SHA="${STANDARDS_TARGET_SHA:-}"
BRANCH="chore/bump-standards-pins"
TARGET_PATH="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix) FIX_MODE=true; shift ;;
    --to) TARGET_SHA="$2"; shift 2 ;;
    --to=*) TARGET_SHA="${1#*=}"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) TARGET_PATH="$1"; shift ;;
  esac
done

# The canonical owner since the transfer (standards#1390). Actions does not
# redirect a job-level `uses:` across a transfer ("workflow was not found"), so
# a pin under the former owner is stale even at the target SHA: it is matched,
# counted as behind and rewritten to the canonical owner.
STANDARDS_REPO="metadatastician/standards"

# Matches `<owner>/standards/.github/workflows/<name>.yml@<sha>`, for the
# canonical and the former owner, on any active line. We rewrite the owner and
# the SHA only; everything else on the line is kept.
PIN_RE='(hyperpolymath|metadatastician)/standards/\.github/workflows/[A-Za-z0-9._-]+\.yml@[0-9a-fA-F]{7,40}'

log() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Resolve the target SHA
# ---------------------------------------------------------------------------

resolve_target() {
  if [ -n "$TARGET_SHA" ]; then printf '%s' "$TARGET_SHA"; return 0; fi

  local sd="${STANDARDS_DIR:-$HOME/standards}"
  # The old implementation used HEAD. When invoked from a standards feature
  # worktree, that propagated a PR-intermediate commit before it had landed on
  # main. GitHub's contents API could read that commit, but cross-repository
  # reusable workflows rejected it as `workflow was not found` (251 active
  # workflow files / 70 repos in the 2026-09-04 incident).
  local ref
  for ref in refs/remotes/origin/main refs/heads/main; do
    if git -C "$sd" rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1; then
      git -C "$sd" rev-parse "${ref}^{commit}"
      return 0
    fi
  done

  # Network fallback — the live standards HEAD.
  local remote
  remote=$(git ls-remote "https://github.com/${STANDARDS_REPO}.git" refs/heads/main 2>/dev/null | awk '{print $1}')
  if [ -n "$remote" ]; then printf '%s' "$remote"; return 0; fi

  return 1
}

if ! TARGET_SHA="$(resolve_target)"; then
  log "ERROR: could not resolve a target standards SHA. Pass --to <sha> or set STANDARDS_TARGET_SHA."
  exit 2
fi

# Prove that the proposed pin is a full commit SHA reachable from standards'
# default branch. Merely proving that `/commits/<sha>` exists is insufficient:
# a squash-merged PR leaves its intermediate commits addressable through the
# API but unusable as cross-repository reusable-workflow refs.
validate_target() {
  [[ "$TARGET_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || {
    log "ERROR: target must be a full 40-character hexadecimal commit SHA: $TARGET_SHA"
    return 1
  }

  local sd="${STANDARDS_DIR:-$HOME/standards}" ref head shallow
  local local_main_seen=false
  if git -C "$sd" cat-file -e "${TARGET_SHA}^{commit}" >/dev/null 2>&1; then
    for ref in refs/remotes/origin/main refs/heads/main; do
      if head=$(git -C "$sd" rev-parse --verify "${ref}^{commit}" 2>/dev/null); then
        local_main_seen=true
        if git -C "$sd" merge-base --is-ancestor "$TARGET_SHA" "$head"; then
          return 0
        fi
      fi
    done

    # Only reject after every usable local main ref has been checked. A
    # shallow or partial graph is not conclusive, so defer that case to the
    # authoritative server comparison below.
    shallow=$(git -C "$sd" rev-parse --is-shallow-repository 2>/dev/null || printf 'true')
    if [[ "$local_main_seen" == true && "$shallow" != true ]] &&
       [[ "$(git -C "$sd" config --get remote.origin.promisor 2>/dev/null || true)" != true ]] &&
       [[ -z "$(git -C "$sd" config --get remote.origin.partialclonefilter 2>/dev/null || true)" ]]; then
      log "ERROR: target ${TARGET_SHA} exists but is not reachable from any available local standards main ref."
      return 1
    fi
  fi

  # Neither usable local main ref proved reachability. Local refs can be stale,
  # so only the authoritative server comparison may return a negative result.
  assert_pin_ancestry "$STANDARDS_REPO" "$TARGET_SHA" main || {
    log "ERROR: refusing propagation of ${TARGET_SHA}."
    return 1
  }
}

validate_target || exit 2

# ---------------------------------------------------------------------------
# Per-file rewrite (the unit-testable core)
# ---------------------------------------------------------------------------

# Echoes the count of pins in $1 that are NOT already the canonical owner at
# $TARGET_SHA. A former-owner pin at the target still counts: it never resolves.
count_behind() {
  local f="$1"
  grep -hoE "$PIN_RE" "$f" 2>/dev/null \
    | grep -vcE "^${STANDARDS_REPO}/.*@${TARGET_SHA}\$" || true
}

# Rewrite every standards reusable pin in $1 to the canonical owner at
# $TARGET_SHA, in place.
rewrite_file() {
  local f="$1"
  sed -E -i "s#(hyperpolymath|metadatastician)/standards/(\\.github/workflows/[A-Za-z0-9._-]+\\.yml@)[0-9a-fA-F]{7,40}#${STANDARDS_REPO}/\\2${TARGET_SHA}#g" "$f"
}

# ---------------------------------------------------------------------------
# Per-repo processing
# ---------------------------------------------------------------------------

# process_repo REPO — print an audit of matching standards SHA pins in the
# local checkout's workflows; do nothing if its workflows directory is absent.
# Under --fix, rewrite pins to TARGET_SHA and relock an existing actions.lock
# when workflows change. A relock failure increments LOCK_REFUSED for the
# script's final exit status, restores each rewritten workflow to its content
# before this run (uncommitted edits included), and skips branch selection and
# staging. Otherwise, selects BRANCH and stages the entire workflows directory
# when pins change in a Git checkout; branch/staging failures are ignored.
# Returns 0 after processing without committing or pushing. Temporary directory
# creation, workflow backup, rewrite or restoration errors terminate the script.
process_repo() {
  local repo="$1" name
  name="$(basename "$repo")"
  local wfdir="$repo/.github/workflows"
  [ -d "$wfdir" ] || return 0

  local total_behind=0 files_touched=0
  local f base behind orig=""
  # The originals of the files rewritten below, restored if the lock refuses.
  if $FIX_MODE; then orig="$(mktemp -d)"; fi
  for f in "$wfdir"/*.yml "$wfdir"/*.yaml; do
    [ -f "$f" ] || continue
    grep -qE "$PIN_RE" "$f" || continue
    base="$(basename "$f")"
    behind="$(count_behind "$f")"
    if [ "$behind" -gt 0 ]; then
      printf '%-30s\t%-28s\tBEHIND(%s)\t-> %s\n' "$name" "$base" "$behind" "${TARGET_SHA:0:12}"
      total_behind=$((total_behind + behind))
      files_touched=$((files_touched + 1))
      if $FIX_MODE; then
        cp -p "$f" "$orig/$base"
        rewrite_file "$f"
      fi
    else
      printf '%-30s\t%-28s\tFRESH\t-> %s\n' "$name" "$base" "${TARGET_SHA:0:12}"
    fi
  done

  # The lock must follow the pins. Rewriting `uses:` alone leaves actions.lock
  # keyed to the old standards commit, which check-lock-sync.sh rejects and
  # GitHub refuses at startup (jobs=0). relock-standards-pin.sh is fail-closed:
  # it leaves the lock untouched and exits 1 when it cannot relock correctly.
  if $FIX_MODE && [ "$files_touched" -gt 0 ] && [ -f "$wfdir/actions.lock" ]; then
    if bash "$(dirname "${BASH_SOURCE[0]}")/relock-standards-pin.sh" --to "$TARGET_SHA" "$wfdir" >&2; then
      printf '%-30s\t%-28s\t%s\t-> %s\n' "$name" "actions.lock" "RELOCKED" "${TARGET_SHA:0:12}"
    else
      printf '%-30s\t%-28s\t%s\t-> %s\n' "$name" "actions.lock" "LOCK-REFUSED" "${TARGET_SHA:0:12}"
      LOCK_REFUSED=$((LOCK_REFUSED + 1))
      # New pins over the old lock is the state the relock exists to prevent:
      # put this repo's workflows back as they were, and leave its index and
      # branch untouched.
      cp -p "$orig"/* "$wfdir"/
      rm -rf "$orig"
      log "  [not staged] $name — lock refused; workflows restored"
      return 0
    fi
  fi
  [ -z "$orig" ] || rm -rf "$orig"

  if $FIX_MODE && [ "$files_touched" -gt 0 ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    local current_branch
    current_branch=$(git -C "$repo" branch --show-current 2>/dev/null || echo "")
    if [ "$current_branch" != "$BRANCH" ]; then
      if git -C "$repo" rev-parse --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
        git -C "$repo" checkout -q "$BRANCH" 2>/dev/null || true
      else
        git -C "$repo" checkout -q -b "$BRANCH" 2>/dev/null || true
      fi
    fi
    git -C "$repo" add "$wfdir" 2>/dev/null || true
    log "  [staged] $name — $files_touched file(s) on branch '$BRANCH' (commit/push left to human/gitbot-fleet)"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "# propagate-workflow-pins.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# mode:   $([ "$FIX_MODE" = true ] && echo FIX || echo AUDIT)"
echo "# target: $TARGET_SHA"
echo "# path:   $TARGET_PATH"
echo "#"
printf '%-30s\t%-28s\t%s\t%s\n' "REPO" "WORKFLOW" "STATUS" "TARGET"

if [ -d "$TARGET_PATH/.github/workflows" ]; then
  process_repo "$TARGET_PATH"
else
  for repo in "$TARGET_PATH"/*/; do
    [ -d "${repo}.github/workflows" ] || continue
    process_repo "${repo%/}"
  done
fi

echo "#"
echo "# Audit complete."
if $FIX_MODE; then
  echo "# --fix: review staged branches ('$BRANCH') and open DRAFT PRs."
else
  echo "# Re-run with --fix to stage the bump on a branch (no commit/push)."
fi
if [ "$LOCK_REFUSED" -gt 0 ]; then
  echo "# LOCK-REFUSED in $LOCK_REFUSED repo(s): actions.lock could not follow the pins; workflows restored, staging skipped."
  echo "# See relock-standards-pin.sh's message above."
  exit 1
fi
