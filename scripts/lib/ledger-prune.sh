#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# ledger-prune.sh — the one writer for the prune mode of the shrink-only
# ledgers. Sourced, not run. Contract: docs/wikis/maintainers/index.adoc,
# "Shrink-only ledgers: the prune mode".
#
# A checker decides which lines are stale, with the same code that decides it
# in check mode, and writes a PLAN. This file only applies the plan, and it
# refuses any plan that would do more than shrink the ledger:
#
#   * `delete` removes one line that is not a comment or a blank line;
#   * `lower` replaces a `key:N` line with `key:M`, same key, 0 < M < N.
#
# Nothing else is possible: no line is added, no count raised, no line moved,
# and every other byte of the file (comments, blanks, a missing final newline)
# is copied unchanged. A plan that breaks a rule writes nothing.
#
# Plan format, one change per line, TAB-separated:
#   <line number> <TAB> delete|lower <TAB> <new line, empty for delete> <TAB> <reason>
#   [<TAB> <shown as>]
# The optional last field is what the output prints in place of the line as it
# was: a JSON Lines ledger passes the row's id, because a whole row is long.
# It changes only the report, never what is written.
#
# Output, one line per change on stdout, then a summary:
#   prune: delete <ledger>:<line>: <line as it was> [<reason>]
#   prune: lower <ledger>:<line>: <line as it was> -> <new line> [<reason>]
#   prune: <ledger>: <d> line(s) deleted, <l> count(s) lowered

# ledger_prune_apply <ledger-file> <display-name> <plan-file>
# Returns 0 when applied, 2 when the plan breaks the invariant (nothing written).
ledger_prune_apply() {
  local ledger=$1 name=$2 plan=$3
  local -A act=() new=() why=() shown=()
  local n a l r s row line nl out k_old c_old k_new c_new deleted=0 lowered=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # Split by hand: `read` with IFS=TAB merges the empty third field of a
    # delete row into its neighbours, because TAB is IFS whitespace.
    n=${row%%$'\t'*}; row=${row#*$'\t'}
    a=${row%%$'\t'*}; row=${row#*$'\t'}
    l=${row%%$'\t'*}; row=${row#*$'\t'}
    r=${row%%$'\t'*}; s=""
    [ "$r" = "$row" ] || s=${row#*$'\t'}
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]] || { [ "$a" != delete ] && [ "$a" != lower ]; }; then
      echo "ledger-prune: bad plan row: $n $a" >&2; return 2
    fi
    if [ -n "${act[$n]:-}" ] && { [ "${act[$n]}" != "$a" ] || [ "${new[$n]}" != "$l" ]; }; then
      echo "ledger-prune: conflicting plan rows for line $n" >&2; return 2
    fi
    act[$n]=$a; new[$n]=$l; why[$n]=$r; shown[$n]=$s
  done < "$plan"

  out="$(mktemp)" || return 2
  local report=()
  n=0
  while :; do
    if IFS= read -r line; then nl=$'\n'
    elif [ -n "$line" ]; then nl=''
    else break
    fi
    n=$((n + 1))
    case "${act[$n]:-}" in
      '') printf '%s%s' "$line" "$nl" >> "$out" ;;
      delete)
        if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
          echo "ledger-prune: refusing to delete comment or blank line $n of $name" >&2
          rm -f "$out"; return 2
        fi
        report+=("prune: delete $name:$n: ${shown[$n]:-$line} [${why[$n]}]")
        deleted=$((deleted + 1)) ;;
      lower)
        if ! [[ "$line" =~ ^(.+):([1-9][0-9]*)$ ]]; then
          echo "ledger-prune: line $n of $name is not key:count; cannot lower it" >&2
          rm -f "$out"; return 2
        fi
        k_old=${BASH_REMATCH[1]}; c_old=${BASH_REMATCH[2]}
        if ! [[ "${new[$n]}" =~ ^(.+):([1-9][0-9]*)$ ]]; then
          echo "ledger-prune: replacement for line $n of $name is not key:count" >&2
          rm -f "$out"; return 2
        fi
        k_new=${BASH_REMATCH[1]}; c_new=${BASH_REMATCH[2]}
        if [ "$k_new" != "$k_old" ] || [ "$c_new" -ge "$c_old" ]; then
          echo "ledger-prune: line $n of $name may only be lowered: $line -> ${new[$n]}" >&2
          rm -f "$out"; return 2
        fi
        printf '%s%s' "${new[$n]}" "$nl" >> "$out"
        report+=("prune: lower $name:$n: ${shown[$n]:-$line} -> ${new[$n]} [${why[$n]}]")
        lowered=$((lowered + 1)) ;;
    esac
    unset 'act[$n]'
  done < "$ledger"

  if [ "${#act[@]}" -gt 0 ]; then
    echo "ledger-prune: plan names line(s) $name does not have: ${!act[*]}" >&2
    rm -f "$out"; return 2
  fi
  # cat, not mv: keep the ledger's inode, mode and ownership.
  cat "$out" > "$ledger"; rm -f "$out"
  [ "${#report[@]}" -gt 0 ] && printf '%s\n' "${report[@]}"
  echo "prune: $name: $deleted line(s) deleted, $lowered count(s) lowered"
  return 0
}
