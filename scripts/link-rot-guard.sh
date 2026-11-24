#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# link-rot-guard.sh — internal-pointer integrity check for the canon and
# the spine (and any repo), with a shrink-only ledger of known breaks.
#
# Rationale: the estate has repeatedly shipped docs that point at paths a
# reorg moved (ADR-0003 and archetypes/README.adoc cite
# 9-archive/rhodium-standard-repositories/spec/SCAFFOLD-LIFECYCLE.adoc; the spec now
# lives at 0-canon/rsr/). The deed-pointer sweep (standards f5ba975) proved
# the pattern works when done by hand; this makes it a standing check.
#
# Checks real link syntax only (not code-quoted paths — too noisy):
#   1. AsciiDoc:  link:target[label]   and   image:target[alt]
#   2. Markdown:  [text](target)
# Relative targets only; http(s)/mailto/absolute/fragment-stripped. A target
# resolves when it exists beside the source file or under the root.
#
# ARCHIVE. The 9-archive/ district at the root is frozen history — the LAST
# COPY of dead upstream trees (standards-map note: "ARCHIVE, do not delete").
# Its internal links are historical and deliberately unmaintained; the guard
# polices live content. The exclusion is the path ROOT/9-archive, and does not
# depend on what the checkout directory is called (an earlier version keyed on
# the directory being named `standards`, so a clone or worktree under another
# name, and the pre-commit throwaway index, reported the whole archive).
# Pruning the district root rather than the tree inside it means anything else
# archived later is covered without another edit here.
#
# THE LEDGER. .machine_readable/link-rot-allow.txt is a SHRINK-ONLY ledger,
# one `path:count` per source file that has broken links today (the count is
# the number of broken links in it). With no ledger file the guard is strict,
# as it was before the ledger existed. The check fails on a file not listed
# that has any (new), on a file with more than its count (grown), and on a
# stale line (fewer than its count, or none): the same three-way discipline as
# scripts/check-pipe-grep-q.sh. --prune deletes stale lines and lowers counts
# that are too high, through scripts/lib/ledger-prune.sh; it never adds a line
# or raises a count. Contract: docs/wikis/maintainers/index.adoc,
# "Shrink-only ledgers".
#
# KNOWN LIMIT. The ledger holds a count per file, not the targets. Removing one
# ledgered break and adding a different one in the same file leaves the count
# unchanged and passes. The owner (2026-11-24) chose to burn the debt down
# rather than change the format: when the ledger reaches zero, the gate is
# strict and the limit goes with it.
#
# SYNTAX. A target resolves beside its source file only. Markdown titles are
# split off; AsciiDoc `image::` block macros are read; `{name}` is expanded from
# the same file's `:name: value` lines, and a reference left unresolved is
# skipped (it cannot be checked statically), not reported.
#
# BASE. A checker that reads only the final tree cannot see a change that adds a
# broken link and the ledger line that excuses it in the same commit. With
# --base REV the check also fails when a ledger line is new or higher than in
# the merge base of REV and HEAD (a ledger absent at the base is the initial
# snapshot and is accepted). Lines may only be removed or lowered. CI passes the
# pull-request base, as the A2ML gate does.
#
# Usage: link-rot-guard.sh [--root DIR] [--ledger FILE] [--base REV]
#                          [--print | --list | --prune] [ROOT]
#   (no mode)  check against the ledger (and against REV with --base)
#   --print    write the current `path:count` set and exit 0
#   --list     write every broken link as `BROKEN  path -> target` and exit 0
#   --prune    delete stale ledger lines and lower counts that are too high,
#              in place; refuse (exit 1, ledger unchanged) on a new or grown
#              offender or a malformed ledger; idempotent
#   ROOT       the same as --root (kept for `just link-rot-guard [ROOT]`)
# Exit: 0 clean · 1 violations · 2 usage or setup error.
set -uo pipefail

ROOT=.
LEDGER=
BASE=
MODE=check
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --ledger) LEDGER=${2:?--ledger needs a file}; shift 2 ;;
    --print) MODE=print; shift ;;
    --list) MODE=list; shift ;;
    --prune) MODE=prune; shift ;;
    --base) BASE=${2:?--base needs a revision}; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "link-rot-guard: unknown argument: $1" >&2; exit 2 ;;
    *) ROOT=$1; shift ;;
  esac
done
[ -d "$ROOT" ] || { echo "link-rot-guard: no such directory: $ROOT" >&2; exit 2; }
ROOT=$(cd "$ROOT" && pwd) || exit 2
LEDGER_REL=.machine_readable/link-rot-allow.txt
LEDGER=${LEDGER:-$ROOT/$LEDGER_REL}

RECORDS=$(mktemp) || exit 2
trap 'rm -f "$RECORDS"' EXIT

# strip_title <target> — a Markdown destination may carry a title:
# `target.md "A title"` or `<target.md> 'A title'`. Keep the destination only.
strip_title() {
  local t=$1
  case "$t" in
    '<'*'>'*) t=${t#<}; t=${t%%>*} ;;
    *) t=${t%%[[:space:]]*} ;;
  esac
  printf '%s' "$t"
}

# resolve_attrs <source> <target> — expand {name} from `:name: value` lines of
# the same source file. Prints the expanded target. Returns 1 when a reference
# stays unresolved (an attribute set elsewhere, by include or on the command
# line): such a target cannot be checked statically and is skipped, not
# reported as broken.
resolve_attrs() {
  local src=$1 t=$2 name val guard=0
  while [[ "$t" =~ \{([A-Za-z0-9_-]+)\} ]]; do
    name=${BASH_REMATCH[1]}
    val=$(sed -n -E "/^:${name}:[[:space:]]/{s/^:${name}:[[:space:]]+//;s/[[:space:]]+\$//;p;q;}" "$src")
    [ -n "$val" ] || return 1
    t=${t//\{$name\}/$val}
    guard=$((guard + 1)); [ "$guard" -lt 20 ] || return 1
  done
  case "$t" in *'{'*) return 1 ;; esac
  printf '%s' "$t"
}

# Every broken link, as `source TAB target`, source relative to ROOT. Runs from
# inside ROOT so each path is root-relative and the exclusion is a fixed path.
# A target resolves only beside its source file, as a renderer resolves it; a
# repo-root fallback would accept links that are broken where they are read.
scan() {
  local f dir target
  while IFS= read -r -d '' f; do
    f=${f#./}
    dir=$(dirname "$f")
    while IFS= read -r target; do
      target=$(strip_title "$target")
      target=$(resolve_attrs "$f" "$target") || continue
      target="${target%%#*}"
      target="${target%%\?*}"
      [ -z "$target" ] && continue
      case "$target" in
        http*|https*|mailto:*|/*) continue ;;
      esac
      if [ -e "$dir/$target" ]; then continue; fi
      printf '%s\t%s\n' "$f" "$target"
    done < <(
      case "$f" in
        *.adoc) grep -oE '(link|image)::?[^][]+\[' "$f" 2>/dev/null | sed -E 's/^(link|image)::?//; s/\[$//' ;;
        *.md)   grep -oE '\]\([^)]+\)' "$f" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^(http|mailto|#|/)' ;;
      esac
    )
  done < <(find . -path ./9-archive -prune -o -path '*/.git' -prune -o -type f \( -name '*.adoc' -o -name '*.md' \) -print0 | LC_ALL=C sort -z)
}
(cd "$ROOT" && scan) > "$RECORDS"

declare -A actual=() allowed=() lineof=()
while IFS=$'\t' read -r f target; do
  [ -n "$f" ] || continue
  actual[$f]=$(( ${actual[$f]:-0} + 1 ))
done < "$RECORDS"

if [ "$MODE" = print ]; then
  for f in "${!actual[@]}"; do printf '%s:%s\n' "$f" "${actual[$f]}"; done | LC_ALL=C sort
  exit 0
fi
if [ "$MODE" = list ]; then
  while IFS=$'\t' read -r f target; do echo "BROKEN  $f -> $target"; done < "$RECORDS"
  exit 0
fi

# ---------------------------------------------------------------- ledger
LEDGER_SNAPSHOT=
[ -f "$LEDGER" ] && LEDGER_SNAPSHOT=$(cat -- "$LEDGER")
lineno=0
while IFS= read -r entry || [ -n "$entry" ]; do
  lineno=$((lineno + 1))
  case "$entry" in ''|'#'*) continue ;; esac
  if ! [[ "$entry" =~ ^(.+):([1-9][0-9]*)$ ]] || [ -n "${allowed[${BASH_REMATCH[1]}]:-}" ]; then
    echo "::error file=$LEDGER,line=$lineno::malformed or duplicate ledger entry (want one path:count per file): $entry"
    exit 1
  fi
  allowed[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}; lineof[${BASH_REMATCH[1]}]=$lineno
done <<<"$LEDGER_SNAPSHOT"

# --base: no ledger line may be new or higher than at the merge base.
basefail=0
if [ -n "$BASE" ] && [ "$MODE" = check ]; then
  rel=$LEDGER_REL
  case "$LEDGER" in "$ROOT"/*) rel=${LEDGER#"$ROOT"/} ;; esac
  mb=$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null) || mb=$BASE
  if ! git -C "$ROOT" rev-parse -q --verify "$mb^{commit}" >/dev/null 2>&1; then
    echo "::error::link-rot: cannot resolve base revision: $BASE"; exit 2
  fi
  if base_text=$(git -C "$ROOT" show "$mb:$rel" 2>/dev/null); then
    declare -A baseallowed=()
    while IFS= read -r e; do
      if [[ "$e" =~ ^(.+):([1-9][0-9]*)$ ]]; then baseallowed[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}; fi
    done <<<"$base_text"
    for f in "${!allowed[@]}"; do
      b=${baseallowed[$f]:-0}
      if [ "${allowed[$f]}" -gt "$b" ]; then
        echo "❌ ledger grew against base: $f: $b -> ${allowed[$f]} — the ledger is shrink-only"
        basefail=$((basefail + 1))
      fi
    done
  else
    echo "link-rot: no ledger at base ${BASE} — initial snapshot accepted"
  fi
fi

# verdicts — the one place staleness is decided; check and prune both read it.
# One record per line, TAB-separated so a path may hold a space:
#   NEW path have · GREW path want have · LOWER path want have · GONE path want
verdicts() {
  local f n want
  for f in "${!actual[@]}"; do
    n=${actual[$f]}; want=${allowed[$f]:-0}
    if [ "$want" -eq 0 ]; then printf 'NEW\t%s\t%s\n' "$f" "$n"
    elif [ "$n" -gt "$want" ]; then printf 'GREW\t%s\t%s\t%s\n' "$f" "$want" "$n"
    elif [ "$n" -lt "$want" ]; then printf 'LOWER\t%s\t%s\t%s\n' "$f" "$want" "$n"
    fi
  done
  for f in "${!allowed[@]}"; do
    [ -z "${actual[$f]:-}" ] && printf 'GONE\t%s\t%s\n' "$f" "${allowed[$f]}"
  done
}
VERDICTS=$(verdicts | LC_ALL=C sort -t$'\t' -k2,2)

show_links() { # show_links <path> — each broken link as a GitHub ::error annotation
  while IFS=$'\t' read -r f target; do
    [ "$f" = "$1" ] || continue
    echo "::error file=$f::broken internal link -> $target"
  done < "$RECORDS"
}

fail=$basefail
if [ "$MODE" = prune ]; then
  name=$LEDGER
  case "$LEDGER" in "$ROOT"/*) name=${LEDGER#"$ROOT"/} ;; esac
  hard=0
  plan=""
  while IFS=$'\t' read -r v f a b; do
    case "$v" in
      NEW|GREW) hard=$((hard + 1)) ;;
      GONE)  plan+="${lineof[$f]}"$'\t'delete$'\t'$'\t'"stale ledger entry $f:$a — no broken link left"$'\n' ;;
      LOWER) plan+="${lineof[$f]}"$'\t'lower$'\t'"$f:$b"$'\t'"stale ledger entry $f:$a — now $b"$'\n' ;;
    esac
  done <<<"$VERDICTS"
  if [ "$hard" -gt 0 ]; then
    echo "❌ link-rot: prune refused: $hard problem(s) that pruning may not hide; $name is unchanged."
  elif [ -z "$plan" ]; then
    echo "prune: $name: nothing stale"
  else
    # shellcheck source=SCRIPTDIR/lib/ledger-prune.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lib/ledger-prune.sh" || exit 2
    planfile=$(mktemp) || exit 2
    printf '%s' "$plan" > "$planfile"
    ledger_prune_apply "$LEDGER" "$name" "$planfile"; rc=$?
    rm -f "$planfile"
    [ "$rc" -eq 0 ] || exit 2
    VERDICTS=""
  fi
fi

total=0
for f in "${!actual[@]}"; do total=$((total + actual[$f])); done
while IFS=$'\t' read -r v f a b; do
  case "$v" in
    NEW)   echo "❌ new broken link(s) in $f ($a) — fix the link"
           show_links "$f"; fail=$((fail + 1)) ;;
    GREW)  echo "❌ broken links GREW in $f: $b, ledger allows $a — the ledger is shrink-only"
           show_links "$f"; fail=$((fail + 1)) ;;
    LOWER) echo "❌ stale ledger entry $f:$a — now $b; shrink the ledger to $f:$b in this change (or run --prune)"
           fail=$((fail + 1)) ;;
    GONE)  echo "❌ stale ledger entry $f:$a — no broken link left; delete the line (or run --prune)"
           fail=$((fail + 1)) ;;
  esac
done <<<"$VERDICTS"

if [ "$fail" -gt 0 ]; then
  echo
  echo "❌ link-rot: $fail problem(s); $total ledgered broken link(s) across ${#actual[@]} file(s)."
  exit 1
fi
echo "✅ link-rot: $total ledgered broken link(s) across ${#actual[@]} file(s), none new, none grown, none stale."
