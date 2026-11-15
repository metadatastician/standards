#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-deed-lint-changed.sh — every .deed a change adds, edits, renames or
# copies must pass deed_lint (owner ruling 2026-11-14).
#
# A file named .deed is not a deed until the normative grammar accepts it:
# A2ML renamed to .deed still holds A2ML. This gate judges a change, not a
# tree: files the change does not touch are never judged, so a repository
# with failing deeds adopts it with no baseline. Deleting a deed passes.
# The change is measured from the merge base of BASE and HEAD, as a pull
# request diff is. Each path is linted at HEAD under its own name, because
# deed_lint dispatches on the file name. Negative test fixtures (under a
# fixtures/…/invalid/ path) are expected to fail and are not judged.
#
# Usage: check-deed-lint-changed.sh BASE HEAD ROOT DEED_LINT_JS
# Exit:  0 every touched deed passes · 1 one or more fail · 2 setup error

set -euo pipefail

BASE="${1:-}"; HEAD_REF="${2:-HEAD}"; ROOT="${3:-.}"; LINT="${4:-}"
[ -n "$BASE" ] && [ -n "$LINT" ] || { echo "usage: check-deed-lint-changed.sh BASE HEAD ROOT DEED_LINT_JS" >&2; exit 2; }
[ -f "$LINT" ] || { echo "ERROR: deed_lint not found at $LINT" >&2; exit 2; }
command -v bun >/dev/null || { echo "ERROR: bun is required to run deed_lint" >&2; exit 2; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "ERROR: $ROOT is not a git work tree" >&2; exit 2; }
for ref in "$BASE" "$HEAD_REF"; do
  git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || { echo "ERROR: cannot resolve $ref (fetch-depth too shallow?)" >&2; exit 2; }
done
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse "$HEAD_REF^{commit}")" ] \
  || { echo "ERROR: the work tree is not at $HEAD_REF; deeds are linted as checked out" >&2; exit 2; }
MERGE_BASE="$(git -C "$ROOT" merge-base "$BASE" "$HEAD_REF")" \
  || { echo "ERROR: no merge base between $BASE and $HEAD_REF" >&2; exit 2; }

DIFF_OUT="$(mktemp)"; trap 'rm -f "$DIFF_OUT"' EXIT
git -C "$ROOT" diff --no-ext-diff --name-status -z -M -C --diff-filter=ACMR \
  "$MERGE_BASE" "$HEAD_REF" > "$DIFF_OUT" \
  || { echo "ERROR: git diff failed; the change cannot be judged" >&2; exit 2; }


# Negative fixtures are meant to fail: any path that runs through a
# fixtures/ directory and then an invalid/ one (the deed_lint test layout).
is_negative_fixture() { [[ "/$1" =~ /fixtures/(.*/)?invalid/ ]]; }

touched=()
while IFS= read -r -d '' status; do
  case "$status" in
    R*|C*) IFS= read -r -d '' _old; IFS= read -r -d '' path ;;
    *)     IFS= read -r -d '' path ;;
  esac
  [[ "$path" == *.deed ]] && ! is_negative_fixture "$path" && touched+=("$path")
done < "$DIFF_OUT"

if [ "${#touched[@]}" -eq 0 ]; then
  echo "deed-lint-changed: OK (no .deed touched since merge base ${MERGE_BASE:0:12})"
  exit 0
fi

failed=0
for path in "${touched[@]}"; do
  if out="$(cd "$ROOT" && bun "$LINT" "$path" 2>&1)"; then
    echo "ok   $path"
  else
    failed=$((failed + 1))
    reason="$(printf '%s\n' "$out" | grep -m1 '^FAIL' | sed "s|^FAIL ${path}: ||")"
    echo "::error file=${path}::not a deed: ${reason:-deed_lint failed}. A .deed must pass standards 1-formats/deed/tools/deed_lint.js; legacy A2ML content is translated by kyX under a mapping spec, never renamed."
  fi
done
if [ "$failed" -gt 0 ]; then
  echo "deed-lint-changed: FAIL — ${failed} of ${#touched[@]} touched .deed file(s) fail deed_lint."
  exit 1
fi
echo "deed-lint-changed: OK (${#touched[@]} touched .deed file(s) pass deed_lint)"
