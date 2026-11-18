#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-inline-python.sh — refuse Python embedded in non-Python files.
#
# Python is banned estate-wide, but every Python detector matches by file
# extension (`*.py`). A `python3 - <<'PY'` heredoc inside a workflow, a
# `python3 -c` one-liner in a justfile, or a `pip install` in a Containerfile
# is invisible to them. That gap is how a YAML parser written in Python got
# into the governance reusable after the ban. This gate closes it.
#
# Flagged, on non-comment lines of *.yml, *.yaml, *.sh, *.template,
# Justfile/justfile and Containerfile:
#   python[3] -c …   python[3] -m …   python[3] - (stdin)   python[3] <<…
#   <<'PY' / <<PY heredocs
#   python[3] <file>.py   pip[3] install
#
# Remaining debt is recorded in a SHRINK-ONLY ledger
# (.machine_readable/inline-python-allow.txt), one `path:count` per line.
# The gate fails when a path not in the ledger has a hit, when a count GROWS,
# and when an entry is STALE (its count dropped): a fix must shrink the ledger
# in the same change, so the ledger can never hide new debt behind old.
#
# Usage: check-inline-python.sh [--root DIR] [--ledger FILE] [--print | --prune]
#   --print  write the current `path:count` set to stdout and exit 0
#            (to regenerate the ledger after a fix).
#   --prune  delete each stale line and lower each count that is too high,
#            using the same comparison as the check, then exit 0. Nothing else
#            changes. With a new path, a grown count or a malformed entry the
#            ledger is left unchanged and the exit is 1. Contract:
#            docs/wikis/maintainers/index.adoc, "Shrink-only ledgers".
# Exit: 0 clean / matches ledger (or pruned clean), 1 violations, 2 usage error.
set -uo pipefail

ROOT=.
LEDGER=
PRINT=false
PRUNE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --ledger) LEDGER=${2:?--ledger needs a file}; shift 2 ;;
    --print) PRINT=true; shift ;;
    --prune) PRUNE=true; shift ;;
    *) echo "check-inline-python: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if $PRINT && $PRUNE; then echo "check-inline-python: --print and --prune exclude each other" >&2; exit 2; fi
[ -d "$ROOT" ] || { echo "check-inline-python: no such directory: $ROOT" >&2; exit 2; }
LEDGER=${LEDGER:-$ROOT/.machine_readable/inline-python-allow.txt}

# One ERE per form, alternated. Kept as data so the test suite can name it.
PATTERN='(^|[^[:alnum:]_.-])python3?[[:space:]]+(-[cm]([[:space:]]|$)|-([[:space:]]|$)|<<|[^[:space:]]+\.py([[:space:]]|$|[;&|)]))'
PATTERN+='|<<-?[[:space:]]*["'"'"']?PY["'"'"']?([[:space:]]|$)'
PATTERN+='|(^|[^[:alnum:]_.-])pip3?[[:space:]]+install([[:space:]]|$)'

# list_files — prints every in-scope file under $ROOT, relative to it, sorted.
# Tracked files only when $ROOT is a git work tree; otherwise a plain walk.
list_files() {
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" ls-files -z
  else
    (cd "$ROOT" && find . -type d -name .git -prune -o -type f -print0 | sed -z 's|^\./||')
  fi | while IFS= read -r -d '' f; do
    case "${f##*/}" in
      *.yml|*.yaml|*.sh|*.template|Justfile|justfile|Containerfile) printf '%s\n' "$f" ;;
    esac
  done | LC_ALL=C sort
}

# count_hits <file> — prints how many non-comment lines of <file> match PATTERN.
count_hits() {
  /usr/bin/grep -vE '^[[:space:]]*#' -- "$ROOT/$1" 2>/dev/null | /usr/bin/grep -cE -e "$PATTERN"
}

# show_hits <file> — prints each offending line as a GitHub ::error annotation.
show_hits() {
  /usr/bin/grep -nE -e "$PATTERN" -- "$ROOT/$1" | /usr/bin/grep -vE '^[0-9]+:[[:space:]]*#' |
    while IFS= read -r line; do
      echo "::error file=$1,line=${line%%:*}::inline Python: ${line#*:}"
    done
}

declare -A actual=() allowed=() lineof=()
while IFS= read -r f; do
  [ -f "$ROOT/$f" ] || continue
  n=$(count_hits "$f")
  [ "${n:-0}" -gt 0 ] && actual[$f]=$n
done < <(list_files)

if $PRINT; then
  for f in "${!actual[@]}"; do printf '%s:%s\n' "$f" "${actual[$f]}"; done | LC_ALL=C sort
  exit 0
fi

if [ -f "$LEDGER" ]; then
  lineno=0
  while IFS= read -r entry || [ -n "$entry" ]; do
    lineno=$((lineno + 1))
    case "$entry" in ''|'#'*) continue ;; esac
    if ! [[ "$entry" =~ ^([^[:space:]]+):([1-9][0-9]*)$ ]]; then
      echo "::error file=$LEDGER,line=$lineno::malformed ledger entry (want path:count): $entry"
      exit 1
    fi
    allowed[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    lineof[${BASH_REMATCH[1]}]+="${lineof[${BASH_REMATCH[1]}]:+ }$lineno"
  done < "$LEDGER"
fi

# stale <path> <delete|lower> <new-line> <message> — one stale finding. Check
# mode prints <message>; prune mode adds the change to the plan instead. The
# decision that it IS stale is made by the caller, in the loops below, and is
# the same in both modes.
PLAN=""
stale() {
  if $PRUNE; then
    PLAN+="${lineof[$1]}"$'\t'"$2"$'\t'"$3"$'\t'"${4#❌ }"$'\n'
  else
    echo "$4"
  fi
}

fail=0
hard=0
total=0
for f in "${!actual[@]}"; do
  n=${actual[$f]}; total=$((total + n))
  want=${allowed[$f]:-0}
  if [ "$want" -eq 0 ]; then
    echo "❌ new inline Python in $f ($n line(s)) — rewrite it in bash/yq/jq; Python is banned"
    show_hits "$f"; fail=$((fail + 1)); hard=$((hard + 1))
  elif [ "$n" -gt "$want" ]; then
    echo "❌ inline Python GREW in $f: $n line(s), ledger allows $want — the ledger is shrink-only"
    show_hits "$f"; fail=$((fail + 1)); hard=$((hard + 1))
  elif [ "$n" -lt "$want" ]; then
    stale "$f" lower "$f:$n" "❌ stale ledger entry $f:$want — now $n; shrink the ledger to $f:$n in this change"
    fail=$((fail + 1))
  fi
done
for f in "${!allowed[@]}"; do
  if [ -z "${actual[$f]:-}" ]; then
    stale "$f" delete "" "❌ stale ledger entry $f:${allowed[$f]} — no inline Python left; delete the line"
    fail=$((fail + 1))
  fi
done

if $PRUNE; then
  name=$LEDGER
  case "$LEDGER" in "$ROOT"/*) name=${LEDGER#"$ROOT"/} ;; esac
  if [ "$hard" -gt 0 ]; then
    echo "❌ inline-python: prune refused: $hard problem(s) that pruning may not hide; $name is unchanged."
    exit 1
  fi
  if [ -z "$PLAN" ]; then
    echo "prune: $name: nothing stale"
    echo "✅ inline-python: $total ledgered line(s) across ${#actual[@]} file(s), none new, none grown, none stale."
    exit 0
  fi
  # A stale path listed on two lines: the check reads only the last, so a
  # prune could not say which line to change. Leave that to a person.
  while IFS=$'\t' read -r lines _; do
    case "$lines" in *' '*)
      echo "❌ inline-python: prune refused: a stale path is listed on lines $lines of $name; fix it by hand."
      exit 1 ;;
    esac
  done <<< "$PLAN"
  # shellcheck source=SCRIPTDIR/lib/ledger-prune.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/ledger-prune.sh" || exit 2
  planfile=$(mktemp) || exit 2
  printf '%s' "$PLAN" > "$planfile"
  ledger_prune_apply "$LEDGER" "$name" "$planfile"; rc=$?
  rm -f "$planfile"
  [ "$rc" -eq 0 ] || exit 2
  echo "✅ inline-python: $total ledgered line(s) across ${#actual[@]} file(s), none new, none grown; stale lines pruned."
  exit 0
fi

if [ "$fail" -gt 0 ]; then
  echo
  echo "❌ inline-python: $fail problem(s); $total offending line(s) across ${#actual[@]} file(s)."
  exit 1
fi
echo "✅ inline-python: $total ledgered line(s) across ${#actual[@]} file(s), none new, none grown, none stale."
