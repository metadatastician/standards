#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# list-existing-a2ml.sh — report every A2ML file a repository still tracks.
#
# A2ML is entirely gone (owner rulings D99, D269c, D312, D313; .claude/CLAUDE.md
# "Identity, classification and the registry"): each tracked A2ML path is a
# departure. This lists them as one `::warning file=PATH::` annotation each,
# plus a count, and ALWAYS exits 0. It never fails a build and never edits a
# file; deletion and translation are separate, owner-reviewed work.
# check-no-new-a2ml.sh is the gate that fails a change adding one.
#
# A2ML paths are those check-no-new-a2ml.sh judges:
#   *.a2ml, *.a2ml.in, *.a2ml.template, *.a2ml.vN.template
#
# Archived copies under 9-archive/ are listed too (the owner ruled them
# departures; their removal is a dedicated PR). The exception the A7 migration
# plan (M5 to M7) allows, a new-input-first A2ML fallback in a shared reader,
# is NOT guessed at here: pass its paths in A2ML_FALLBACK_PATHS (newline- or
# space-separated) and they are tagged "(A7 fallback, kept until callers
# migrate)" and counted separately, but still listed.
#
# Usage: list-existing-a2ml.sh [ROOT]      (ROOT defaults to .)
# Exit:  always 0 (2 only when ROOT is not a git work tree)

set -euo pipefail

ROOT="${1:-.}"
A2ML_RE='\.a2ml(\.in|\.template|\.v[0-9]+\.template)?$'

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "ERROR: $ROOT is not a git work tree" >&2; exit 2; }

declare -A fallback=()
for p in ${A2ML_FALLBACK_PATHS:-}; do fallback["$p"]=1; done

# GitHub shows at most 50 annotations per job and truncates the rest, so only
# the first A2ML_MAX_ANNOTATIONS (default 40) become annotations; the full
# list goes to the step summary when one exists, and the count is always exact.
MAX="${A2ML_MAX_ANNOTATIONS:-40}"
total=0; kept=0; archived=0; shown=0
while IFS= read -r -d '' path; do
  [[ "$path" =~ $A2ML_RE ]] || continue
  total=$((total + 1))
  note="A2ML is retired; translate what a reader still needs into the chora deed, a K9 contract or coordination.k9, then delete this file (standards .claude/CLAUDE.md)."
  if [ -n "${fallback[$path]:-}" ]; then
    kept=$((kept + 1))
    note="A2ML is retired. (A7 fallback, kept until its callers migrate: standards A7 M5 to M7.)"
  elif [[ "$path" == 9-archive/* || "$path" == */9-archive/* ]]; then
    archived=$((archived + 1))
  fi
  # Workflow-command escaping for the property and data parts.
  esc() { local s="$1"; s="${s//'%'/%25}"; s="${s//$'\r'/%0D}"; s="${s//$'\n'/%0A}"; printf '%s' "$s"; }
  if [ "$shown" -lt "$MAX" ]; then
    shown=$((shown + 1))
    printf '::warning file=%s::%s\n' "$(esc "$path" | sed 's/:/%3A/g; s/,/%2C/g')" "$(esc "$note")"
  else
    echo "existing-a2ml: $path"
  fi
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf -- '- `%s`\n' "$path" >> "$GITHUB_STEP_SUMMARY"
done < <(git -C "$ROOT" ls-files -z)

if [ "$total" -eq 0 ]; then
  echo "existing-a2ml: none (no tracked A2ML file)"
else
  echo "::warning::existing-a2ml: $total tracked A2ML file(s) remain ($archived under 9-archive/, $kept covered by the A7 fallback exception). Advisory only: this check never fails."
fi
exit 0
