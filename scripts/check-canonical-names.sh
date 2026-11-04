#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-canonical-names.sh — block REINTRODUCTION of deprecated names.
#
# 0-canon/CANONICAL-NAMES.adoc (owner mandate 2026-06-30) deprecates:
#   * 6a2                -> descriptiles
#   * agent_instructions -> bot_directives
# The bulk migration of existing occurrences is chartered separately; this guard
# stops NEW occurrences from landing in the meantime. It inspects only the
# ADDED lines of a diff (grandfathered existing text is untouched), so it can be
# wired into pre-commit and CI without tripping on the not-yet-migrated files.
#
# Usage: check-canonical-names.sh [base-ref]
#   base-ref default: origin/main (CI) then HEAD (pre-commit staged diff).
# Exit: 0 no new deprecated tokens · 1 a deprecated token was added · 2 usage

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit

BASE="${1:-}"
if [ -z "$BASE" ]; then
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then BASE="origin/main"; else BASE="HEAD"; fi
fi

# Deprecated token -> canonical replacement (for the error message).
declare -A REPL=( ["6a2"]="descriptiles" ["agent_instructions"]="bot_directives" )

# Files that legitimately NAME the deprecated tokens (the mandate itself, this
# guard, migration/charter docs, and frozen archives whose records cite the
# paths of their day). Excluded from the check. The scorecard archive is
# excluded record by record (ruling R5, #837): its README is still checked.
# 9-archive/ is excluded whole: it is frozen history indexed by
# 9-archive/MOVED.adoc, and a record archived there (the retired A2ML corpus
# lands under 9-archive/a2ml/ at its original path) must keep the names of
# its day. The anchored "9-archive/" prefix does not reach a sibling such as
# 9-archives/ or a nested .../9-archive/.
# The legacy A2ML ledger (.machine_readable/a2ml-legacy-allow.txt) names each
# live A2ML file by its real path, so it spells agent_instructions/ until those
# files are renamed or archived: a record of paths, not a new use.
is_excluded() {
  case "$1" in
    0-canon/CANONICAL-NAMES.adoc|scripts/check-canonical-names.sh|scripts/tests/*|\
    .machine_readable/a2ml-legacy-allow.txt|\
    *MIGRATION*|*migration*|*CHANGELOG*|\
    9-archive/*|\
    .machine_readable/archive/scorecards-v1/*.scorecard.a2ml) return 0 ;;
  esac
  return 1
}

# Added lines in the working diff vs BASE, per file.
added_diff() { git diff "$BASE" -- . 2>/dev/null; }

rc=0
current_file=""
while IFS= read -r line; do
  case "$line" in
    "+++ b/"*)
      current_file="${line#+++ b/}"
      if ! is_excluded "$current_file" &&
         [[ "/$current_file/" == */.machine_readable/6a2/* ]]; then
        echo "❌ $current_file: reintroduces deprecated '.machine_readable/6a2/' — use '.machine_readable/descriptiles/' (0-canon/CANONICAL-NAMES.adoc)"
        rc=1
      fi
      ;;
    "+"*)
      is_excluded "$current_file" && continue
      body="${line#+}"
      # Skip a line that is DESCRIBING the deprecation rather than using the old
      # name — it also mentions the canonical replacement or the mandate itself
      # (e.g. tooling comments, this guard's own wiring, docs about the rename).
      if printf '%s' "$body" | grep -Eqi 'deprecat|canonical|reintroduc|descriptiles|bot_directives'; then
        continue
      fi
      for tok in "${!REPL[@]}"; do
        # word-ish boundary so e.g. 'v6a2ml' style false hits are limited
        if printf '%s' "$body" | grep -Eq "(^|[^A-Za-z0-9])$tok([^A-Za-z0-9]|$)"; then
          echo "❌ $current_file: reintroduces deprecated '$tok' — use '${REPL[$tok]}' (0-canon/CANONICAL-NAMES.adoc)"
          echo "   + $body"
          rc=1
        fi
      done ;;
  esac
done < <(added_diff)

if [ "$rc" -eq 0 ]; then
  echo "✅ no deprecated names reintroduced (vs $BASE)"
fi
exit $rc
