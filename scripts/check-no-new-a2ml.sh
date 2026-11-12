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
# What counts as an addition (owner ruling 2026-11-12, A7 Part 1a):
#   * a new A2ML path (git status A);
#   * a rename whose new path is A2ML and whose old path is not (git status R
#     from a non-A2ML file), because that creates an A2ML file;
#   * a copy whose new path is A2ML.
# What does not:
#   * a rename from one A2ML path to another (for example into 9-archive/):
#     a move adds no fact;
#   * editing or deleting an existing A2ML file (deleting content is allowed).
# Rename detection is git's default (50% similarity). A move that also
# rewrites most of the file is seen as a deletion plus an addition and fails;
# move first, edit in a second commit.
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

is_a2ml() { [[ "$1" =~ $A2ML_RE ]]; }

added=()
# -z: unusual names arrive unquoted, so the extension test sees the real name.
# Records are "STATUS\0PATH\0" or, for R and C, "STATUS\0OLD\0NEW\0".
while IFS= read -r -d '' status; do
  case "$status" in
    R*|C*)
      IFS= read -r -d '' old; IFS= read -r -d '' new
      if is_a2ml "$new"; then
        if [[ "$status" == C* ]] || ! is_a2ml "$old"; then
          added+=("$new"$'\t'"$status from $old")
        fi
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
done < <(git -C "$ROOT" diff --no-ext-diff --name-status -z -M -C --diff-filter=ACR "$BASE" "$HEAD_REF")

if [ "${#added[@]}" -eq 0 ]; then
  echo "no-new-a2ml: OK (no A2ML file added between ${BASE:0:12} and ${HEAD_REF})"
  exit 0
fi

for entry in "${added[@]}"; do
  path="${entry%%$'\t'*}"; how="${entry#*$'\t'}"
  echo "::error file=${path}::A2ML is retired: this change adds ${path} (${how}). Write the content as a clause of <repo>_chora.deed, a *.k9.ncl contract or coordination.k9 instead (standards .claude/CLAUDE.md, Machine-Readable Artefacts)."
done
echo "no-new-a2ml: FAIL — ${#added[@]} A2ML file(s) added. Existing A2ML files may be edited down or deleted, never added."
exit 1
