#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-no-new-a2ml.sh — a change may not ADD an A2ML file.
#
# A2ML is retired (owner rulings D99, D269c, D312, D313). This gate judges a
# change, not a tree: it compares BASE with HEAD and fails on every A2ML path
# (*.a2ml, *.a2ml.in, *.a2ml.template, *.a2ml.vN.template) that the change
# adds. Files that already exist at BASE are never judged, so a repository
# with legacy A2ML adopts the gate with no baseline and no ledger.
#
# What counts as an addition (owner rulings of 2026-11-12, A7 Part 1a, and
# of 2026-11-14, "A2ML moves fail"): any A2ML file at a path where BASE had
# none, that is:
#   * a new A2ML path (git status A);
#   * a rename or move whose new path is A2ML, from any old path, an A2ML one
#     included (for example into 9-archive/): the file now stands at a new
#     path, and an A2ML file is to leave the tree, not move within it;
#   * a copy whose new path is A2ML.
# What does not: editing an existing A2ML file in place, or deleting one
# (deleting content is allowed). Rename detection is git's default (50%
# similarity), applied to the change as a whole: the gate compares two
# snapshots, so commit boundaries inside a PR do not count. A move that also
# rewrites most of the file is seen as a deletion plus an addition, and fails
# the same way.
#
# The change is measured from the merge base of BASE and HEAD, as a pull
# request diff is, so an A2ML file that the base branch deleted or moved after
# the PR branched is not mistaken for one the PR added.
#
# Usage: check-no-new-a2ml.sh BASE [HEAD] [ROOT]
#        HEAD defaults to HEAD, ROOT to the current directory.
# Exit:  0 nothing added · 1 an A2ML file added · 2 setup error

set -euo pipefail

BASE="${1:-}"
HEAD_REF="${2:-HEAD}"
ROOT="${3:-.}"
A2ML_RE='\.a2ml(\.in|\.template|\.v[0-9]+\.template)?$'

[ -n "$BASE" ] || { echo "usage: check-no-new-a2ml.sh BASE [HEAD] [ROOT]" >&2; exit 2; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "ERROR: $ROOT is not a git work tree" >&2; exit 2; }
for ref in "$BASE" "$HEAD_REF"; do
  git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || { echo "ERROR: cannot resolve $ref (fetch-depth too shallow?)" >&2; exit 2; }
done

# The fork point. BASE..HEAD alone would report as added every A2ML file the
# base deleted since the PR branched.
MERGE_BASE="$(git -C "$ROOT" merge-base "$BASE" "$HEAD_REF")" \
  || { echo "ERROR: no merge base between $BASE and $HEAD_REF (fetch-depth too shallow?)" >&2; exit 2; }

# Collect the diff first and check its status: read from a process
# substitution, a failing git diff would look like an empty, passing change.
DIFF_OUT="$(mktemp)"
trap 'rm -f "$DIFF_OUT"' EXIT
if ! git -C "$ROOT" diff --no-ext-diff --name-status -z -M -C --diff-filter=ACR \
     "$MERGE_BASE" "$HEAD_REF" > "$DIFF_OUT"; then
  echo "ERROR: git diff $MERGE_BASE $HEAD_REF failed; the change cannot be judged" >&2
  exit 2
fi

is_a2ml() { [[ "$1" =~ $A2ML_RE ]]; }

added=()
# -z: unusual names arrive unquoted, so the extension test sees the real name.
# Records are "STATUS\0PATH\0" or, for R and C, "STATUS\0OLD\0NEW\0".
while IFS= read -r -d '' status; do
  case "$status" in
    R*|C*)
      IFS= read -r -d '' old; IFS= read -r -d '' new
      # Owner ruling 2026-11-14: a move between two A2ML paths fails too.
      if is_a2ml "$new"; then
        added+=("$new"$'\t'"$status from $old")
      fi
      ;;
    A*)
      IFS= read -r -d '' path
      is_a2ml "$path" && added+=("$path"$'\t'"added")
      ;;
    *)
      IFS= read -r -d '' _path
      ;;
  esac
done < "$DIFF_OUT"

if [ "${#added[@]}" -eq 0 ]; then
  echo "no-new-a2ml: OK (no A2ML file added between merge base ${MERGE_BASE:0:12} and ${HEAD_REF})"
  exit 0
fi

for entry in "${added[@]}"; do
  path="${entry%%$'\t'*}"; how="${entry#*$'\t'}"
  echo "::error file=${path}::A2ML is retired: this change adds ${path} (${how}). Write the content as a clause of <repo>_chora.deed, a *.k9.ncl contract or coordination.k9 instead (standards .claude/CLAUDE.md, Machine-Readable Artefacts)."
done
echo "no-new-a2ml: FAIL — ${#added[@]} A2ML file(s) at a new path. Existing A2ML files may be edited down in place or deleted, never added, moved or copied."
exit 1
