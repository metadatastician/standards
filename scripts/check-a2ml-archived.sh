#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-a2ml-archived.sh — A2ML is retired (owner rulings D99, D269c, D312,
# D313); no A2ML file may appear outside the archive or the legacy ledger.
#
# Every tracked A2ML file (*.a2ml, *.a2ml.in, *.a2ml.template,
# *.a2ml.vN.template) must either sit under 9-archive/ or be named, by exact
# path, in .machine_readable/a2ml-legacy-allow.txt. The check runs both ways:
#
#   * a file in neither place FAILS: a new or moved A2ML file is drift;
#   * a ledger entry whose file is gone FAILS: the entry must leave in the
#     same commit that archives, translates or deletes its file, so the
#     ledger only shrinks (the exemption ratchet forbids it growing).
#
# Ledger entries are exact paths. A glob or a 9-archive/ path in the ledger
# is a defect: a pattern would absorb files added later, and an archived
# file needs no exemption.
#
# In a git work tree the set is the tracked files plus untracked files that
# are not ignored, so a contributor sees a new file before committing it.
# Outside git (fixtures) every file under ROOT is scanned.
#
# With --base REF the ledger is also compared with its copy at REF: an entry
# that REF did not list has JOINED the ledger and fails, whatever the line
# count. (Archiving one file while ledgering a new one keeps the count, so a
# count-only ratchet cannot see that swap.) A REF with no ledger yet is the
# bootstrap and passes.
#
# Usage: check-a2ml-archived.sh [--base REF] [ROOT]   (ROOT defaults to .)
# Exit:  0 clean · 1 violation · 2 setup error (no ledger, unreadable root,
#        unresolvable REF)

set -euo pipefail

BASE=""
if [ "${1:-}" = "--base" ]; then
  [ -n "${2:-}" ] || { echo "ERROR: --base needs a ref" >&2; exit 2; }
  BASE="$2"; shift 2
fi
ROOT="${1:-.}"
LEDGER_REL=".machine_readable/a2ml-legacy-allow.txt"
LEDGER="$ROOT/$LEDGER_REL"
A2ML_RE='\.a2ml(\.in|\.template|\.v[0-9]+\.template)?$'

[ -d "$ROOT" ] || { echo "ERROR: $ROOT is not a directory" >&2; exit 2; }
[ -f "$LEDGER" ] || { echo "ERROR: ledger $LEDGER_REL not found under $ROOT" >&2; exit 2; }

list_files() {
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # -z: without it git quotes unusual names (caf\303\251.a2ml in quotes),
    # and the closing quote would hide the extension from the match below.
    git -C "$ROOT" ls-files -z -co --exclude-standard
  else
    (cd "$ROOT" && find . -type f ! -path './.git/*' -printf '%P\0')
  fi
}

# ledger_entries: on stdin a ledger; prints "<line>\t<entry>" per entry,
# comments and blank lines dropped.
ledger_entries() {
  local raw entry n=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    n=$((n + 1))
    entry="${raw%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -n "$entry" ] && printf '%s\t%s\n' "$n" "$entry"
  done
  return 0
}

declare -A listed=()
fail=0
while IFS=$'\t' read -r lineno entry; do
  case "$entry" in
    *'*'*|*'?'*|*'['*)
      echo "::error file=$LEDGER_REL,line=$lineno::ledger entry '$entry' is a pattern; list exact paths only"
      fail=1; continue ;;
    9-archive/*)
      echo "::error file=$LEDGER_REL,line=$lineno::ledger entry '$entry' is under 9-archive/, which needs no exemption"
      fail=1; continue ;;
  esac
  if [ -n "${listed[$entry]:-}" ]; then
    echo "::error file=$LEDGER_REL,line=$lineno::ledger entry '$entry' is listed twice"
    fail=1; continue
  fi
  listed[$entry]="$lineno"
done < <(ledger_entries < "$LEDGER")

if [ -n "$BASE" ]; then
  git -C "$ROOT" rev-parse --verify -q "$BASE^{commit}" >/dev/null \
    || { echo "ERROR: --base $BASE does not resolve to a commit" >&2; exit 2; }
  if base_ledger="$(git -C "$ROOT" show "$BASE:$LEDGER_REL" 2>/dev/null)"; then
    declare -A was=()
    while IFS=$'\t' read -r _ entry; do was[$entry]=1; done < <(printf '%s\n' "$base_ledger" | ledger_entries)
    for entry in "${!listed[@]}"; do
      if [ -z "${was[$entry]:-}" ]; then
        echo "::error file=$LEDGER_REL,line=${listed[$entry]}::ledger entry '$entry' is not in the ledger at $BASE: nothing joins it (A2ML is retired)"
        fail=1
      fi
    done
  else
    echo "::notice::$LEDGER_REL is new since $BASE: bootstrap, no membership comparison"
  fi
fi

declare -A present=()
live=0
archived=0
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  # Skip only an entry deleted from the work tree. A dangling symlink fails
  # -e but is still a tracked A2ML path, so -L keeps it in the scan.
  [ -e "$ROOT/$f" ] || [ -L "$ROOT/$f" ] || continue
  case "$f" in
    9-archive/*) archived=$((archived + 1)); continue ;;
  esac
  present[$f]=1
  if [ -n "${listed[$f]:-}" ]; then
    live=$((live + 1))
  else
    echo "::error file=$f::A2ML file outside 9-archive/ and not in $LEDGER_REL. A2ML is retired: write a .deed or .k9.ncl instead, or archive it under 9-archive/a2ml/ at its original path"
    fail=1
  fi
done < <(list_files | grep -zE "$A2ML_RE" || true)

for entry in "${!listed[@]}"; do
  if [ -z "${present[$entry]:-}" ]; then
    echo "::error file=$LEDGER_REL,line=${listed[$entry]}::ledger entry '$entry' names no A2ML file; remove it (the ledger only shrinks)"
    fail=1
  fi
done

echo "a2ml archive gate: $live live (ledgered), $archived archived under 9-archive/"
if [ "$fail" -ne 0 ]; then
  echo "a2ml archive gate: FAIL"
  exit 1
fi
echo "a2ml archive gate: OK"
