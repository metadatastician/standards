#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# validate-ledger-prune.sh — pre-commit: when the staged change makes a line of
# a shrink-only ledger stale, delete that line and stage the ledger, so the
# fix and its ledger line leave in the same commit (owner decision 2026-11-17,
# after a commit removed inline Python and left its ledger line behind).
#
# It owns no rules. Each ledger's own checker decides what is stale, with its
# --prune mode (contract: docs/wikis/maintainers/index.adoc, "Shrink-only
# ledgers"):
#   inline-python-allow.txt  scripts/check-inline-python.sh --prune
#   a2ml-legacy-allow.txt    scripts/check-a2ml-archived.sh --prune
#   k9-contract-debt.txt     .githooks/validate-k9.sh --prune (staged K9 files)
#   marker-allow.txt         scripts/check-marker-issue-refs.sh --prune
#   pipe-grep-q-allow.txt    scripts/check-pipe-grep-q.sh --prune
#   link-rot-allow.txt        scripts/link-rot-guard.sh --prune
#   departures.jsonl         scripts/departures.sh prune --ref <the index as a commit>
# lock-allow.txt, pipeline-allow.txt and required-contexts-allow.txt have no
# prune: what makes their lines stale lives on GitHub, not in the tree.
#
# What is judged is the INDEX, the content the commit will have: it is checked
# out into a throwaway repository (objects shared, nothing copied) and the
# checker runs there. The hook then refuses, naming the stale lines, instead of
# editing when the ledger has unstaged edits (they would be overwritten), and
# when the commit was made as `git commit <path>` (git commits a temporary
# index then, so a staged prune would land in the commit and not in yours).
#
# Departures are judged at a commit: the hook commits the throwaway index (its
# parent is HEAD, so ancestry checks see the real history) and runs prune at
# that commit. Every tree check is decided there. A `script` check is left
# UNEVALUATED, because the throwaway repository's HEAD is not that commit, so
# a row whose only failing evidence is a script is not pruned here; the
# shell-test suite and CI run `departures.sh check` on the real checkout.
#
# Fast no-op: nothing runs unless a staged path (added, changed, deleted) is
# named in a ledger, or the ledger itself is staged. A departures row with a
# `glob` (tree-grep-absent) can match a path it does not spell, so a departures
# ledger that holds one is judged on every commit with a staged path.
#
# Exit: 0 nothing to do or pruned and staged · 1 refused or a checker failed.
set -euo pipefail

REPO_ROOT="${INPUT_PATH:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGERS=(
  .machine_readable/inline-python-allow.txt
  .machine_readable/a2ml-legacy-allow.txt
  .machine_readable/k9-contract-debt.txt
  .machine_readable/marker-allow.txt
  .machine_readable/pipe-grep-q-allow.txt
  .machine_readable/link-rot-allow.txt
  .machine_readable/departures.jsonl
)

# Git commands for the throwaway repository must not see the variables git
# sets for this hook, or they would read and write the real index.
clean() { env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_PREFIX \
  -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git -c core.quotePath=false diff --cached --name-only --no-renames > "$WORK/staged"
[ -s "$WORK/staged" ] || exit 0

relevant=()
for ledger in "${LEDGERS[@]}"; do
  git cat-file -e ":$ledger" 2>/dev/null || continue
  text="$(git show ":$ledger")"
  if grep -qxF -- "$ledger" "$WORK/staged" \
     || grep -qF -f "$WORK/staged" <<< "$text" \
     || { [ "${ledger##*/}" = departures.jsonl ] && grep -qF '"glob":' <<< "$text"; }; then
    relevant+=("$ledger")
  fi
done
[ "${#relevant[@]}" -gt 0 ] || exit 0

# The index, materialised.
T="$WORK/index"
objects="$(cd "$(git rev-parse --git-path objects)" && pwd)"
clean git init -q "$T"
echo "$objects" > "$T/.git/objects/info/alternates"
git ls-files -s -z | (cd "$T" && clean git update-index -z --index-info)
clean git -C "$T" checkout-index -a -q

# index_commit: the materialised index as a commit of the throwaway repository,
# made once, with HEAD as its parent when there is one. Its HEAD is not moved.
index_commit() {
  if [ ! -s "$WORK/commit" ]; then
    local tree parent
    tree="$(clean git -C "$T" write-tree)"
    parent="$(git rev-parse -q --verify HEAD || true)"
    clean env GIT_AUTHOR_NAME=ledger-prune GIT_AUTHOR_EMAIL=ledger-prune@invalid \
      GIT_COMMITTER_NAME=ledger-prune GIT_COMMITTER_EMAIL=ledger-prune@invalid \
      git -C "$T" commit-tree --no-gpg-sign ${parent:+-p "$parent"} -m "staged index" "$tree" > "$WORK/commit"
  fi
  cat "$WORK/commit"
}

# `git commit <path>` hands the hook a temporary index; plain, -a and -i
# commits use <git-dir>/index or its .lock.
is_partial_commit() {
  [ -n "${GIT_INDEX_FILE:-}" ] || return 1
  local real; real="$(env -u GIT_INDEX_FILE git rev-parse --absolute-git-dir)/index"
  case "$(realpath -m "$GIT_INDEX_FILE")" in
    "$(realpath -m "$real")"|"$(realpath -m "$real.lock")") return 1 ;;
  esac
  return 0
}

status=0
for ledger in "${relevant[@]}"; do
  case "$ledger" in
    *inline-python-allow.txt)
      [ -f scripts/check-inline-python.sh ] || { echo "[ledger-prune] $ledger: no checker here, skipped"; continue; }
      cmd=(bash "$REPO_ROOT/scripts/check-inline-python.sh" --root "$T" --prune) ;;
    *a2ml-legacy-allow.txt)
      [ -f scripts/check-a2ml-archived.sh ] || { echo "[ledger-prune] $ledger: no checker here, skipped"; continue; }
      cmd=(bash "$REPO_ROOT/scripts/check-a2ml-archived.sh" --prune "$T") ;;
    *k9-contract-debt.txt)
      k9v="${K9_VALIDATOR:-$REPO_ROOT/1-formats/k9/tools/k9-validate.sh}"
      [ -f "$k9v" ] || { echo "[ledger-prune] $ledger: no K9 validator here, skipped"; continue; }
      cmd=(env INPUT_PATH="$T" K9_VALIDATOR="$k9v" K9_CHANGED_FILES=
           INPUT_STAGED_FILES="$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACM)"
           bash "$HOOK_DIR/validate-k9.sh" --prune) ;;
    *marker-allow.txt)
      [ -f scripts/check-marker-issue-refs.sh ] || { echo "[ledger-prune] $ledger: no checker here, skipped"; continue; }
      cmd=(bash "$REPO_ROOT/scripts/check-marker-issue-refs.sh" --root "$T" --prune) ;;
    *pipe-grep-q-allow.txt)
      [ -f scripts/check-pipe-grep-q.sh ] || { echo "[ledger-prune] $ledger: no checker here, skipped"; continue; }
      cmd=(bash "$REPO_ROOT/scripts/check-pipe-grep-q.sh" --root "$T" --prune) ;;
    *link-rot-allow.txt)
      [ -f scripts/link-rot-guard.sh ] || { echo "[ledger-prune] $ledger: no checker here, skipped"; continue; }
      cmd=(bash "$REPO_ROOT/scripts/link-rot-guard.sh" --root "$T" --prune) ;;
    *departures.jsonl)
      [ -f scripts/departures.sh ] || { echo "[ledger-prune] $ledger: no checker here, skipped"; continue; }
      cmd=(bash "$REPO_ROOT/scripts/departures.sh" prune --ref "$(index_commit)" "$ledger") ;;
  esac
  rc=0; out="$(cd "$T" && clean "${cmd[@]}" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    echo "[ledger-prune] $ledger: the checker refused to prune (exit $rc); nothing was changed"
    status=1; continue
  fi
  git show ":$ledger" > "$WORK/before"
  cmp -s "$WORK/before" "$T/$ledger" && continue   # nothing stale
  removed="$(printf '%s\n' "$out" | grep '^prune: ' || true)"
  if is_partial_commit; then
    printf '%s\n' "$removed"
    echo "[ledger-prune] $ledger has stale lines (above), and this commit was made as 'git commit <path>'."
    echo "  Run the prune, stage $ledger, and commit without paths (or name $ledger too)."
    status=1; continue
  fi
  if ! git diff --quiet -- "$ledger"; then
    printf '%s\n' "$removed"
    echo "[ledger-prune] $ledger has stale lines (above) and unstaged edits; not editing it."
    echo "  Stage or discard your edits to $ledger, then commit again."
    status=1; continue
  fi
  cat "$T/$ledger" > "$ledger"
  git add -- "$ledger"
  printf '%s\n' "$removed"
  echo "[ledger-prune] $ledger: stale lines removed (above) and the ledger staged into this commit"
done
exit "$status"
