#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-pipe-grep-q.sh — no pipe into a quiet grep.
#
# THE DEFECT. Under `set -o pipefail`, `writer | grep -q PATTERN` is unsound.
# `grep -q` exits at its first match. If the writer is still writing (more than
# one write, or more than the 64 KiB pipe buffer) it is killed by SIGPIPE, the
# pipeline's status becomes 141, and a match reads as "no match". In a test
# that is an intermittent failure on a loaded machine. In a gate written
# `if writer | grep -q BAD; then fail`, it is a fail-open. The fix is to
# capture, then match, with no pipe:
#     out=$(writer); grep -q PATTERN <<<"$out"
#
# WHAT IT DETECTS. In every tracked file that is a shell source (*.sh, any
# file under .githooks/, any other file whose first line is a shell shebang)
# and in .github/workflows/*.yml and *.yaml (the text of `run:` blocks is
# scanned as plain lines; the YAML is not parsed), a pipe whose right-hand
# command is grep, egrep or fgrep with a quiet flag:
#   * -q alone, or inside a flag cluster (-qF, -Eq, -qxF, -iqE); a cluster is
#     read left to right and stops at a letter that takes an argument
#     (e f m A B C d D), so -eq is the pattern "q", not a quiet flag;
#   * --quiet and --silent;
#   * the quiet flag anywhere before a shell operator (| ; & ) >) or the
#     first "--", after the grep word, including after the pattern;
#   * `|&` as well as `|`; a `/path/to/grep`; a `command ` prefix; leading
#     NAME=value assignments; a leading `!`;
#   * the pipe on the previous line: `cmd |` then `grep -q ...` on the next
#     line, `cmd | \` then `grep -q ...`, and `cmd \` then `| grep -q ...`.
#     Blank lines and comment lines between the two are skipped, as bash does.
# Full-line comments (first non-blank character "#") are ignored.
#
# WHAT IT DOES NOT DETECT (each is a limit, not a promise):
#   * the command held in a variable or function (`$G -q`, `run_grep -q`);
#   * `xargs grep -q`, `git grep -q`, `rg -q`, `awk` or `sed -n` doing the
#     same job, `grep -c`, `grep -l`, `grep -m1` (not quiet flags, and the
#     SIGPIPE race needs -q, whose exit is at the first match);
#   * a pipe broken across `$(`...`)` or a line that does not end in the pipe,
#     for example `cmd | # note` (a trailing comment hides the pipe);
#   * the text of a heredoc body, a string or a message: they are scanned as
#     lines like any other, so a heredoc or an `echo "a | grep -q b"` that
#     spells the pattern is a false positive. Build such text from parts;
#   * quoted flags and patterns are replaced by a placeholder before the flags
#     are read, so a quote that spans lines is not followed;
#   * files that are not tracked (outside a git work tree every file is walked).
#
# THE LEDGER. .machine_readable/pipe-grep-q-allow.txt is a SHRINK-ONLY ledger,
# one `path:count` per file that has the pattern today. The gate fails on a
# file not listed that has any (new), on a file with more than its count
# (grown), and on a stale line (fewer than its count, or none): the same
# three-way discipline as scripts/check-inline-python.sh and
# scripts/check-marker-issue-refs.sh. --prune deletes stale lines and lowers
# counts that are too high, through scripts/lib/ledger-prune.sh; it never adds
# a line or raises a count. Contract: docs/wikis/maintainers/index.adoc,
# "Shrink-only ledgers".
#
# Usage: check-pipe-grep-q.sh [--root DIR] [--ledger FILE]
#                             [--print | --list | --prune]
#   (no mode)  check against the ledger
#   --print    write the current `path:count` set and exit 0
#   --list     write every finding as `path:line: text` and exit 0
#   --prune    delete stale ledger lines and lower counts that are too high,
#              in place; refuse (exit 1, ledger unchanged) on a new or grown
#              offender or a malformed ledger; idempotent
# Exit: 0 clean · 1 violations · 2 usage or setup error.
set -uo pipefail

ROOT=.
LEDGER=
MODE=check
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --ledger) LEDGER=${2:?--ledger needs a file}; shift 2 ;;
    --print) MODE=print; shift ;;
    --list) MODE=list; shift ;;
    --prune) MODE=prune; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-pipe-grep-q: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$ROOT" ] || { echo "check-pipe-grep-q: no such directory: $ROOT" >&2; exit 2; }
LEDGER_REL=.machine_readable/pipe-grep-q-allow.txt
LEDGER=${LEDGER:-$ROOT/$LEDGER_REL}

IN_GIT=false
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && IN_GIT=true

# all_files — every file to consider, relative to $ROOT.
all_files() {
  if $IN_GIT; then
    git -C "$ROOT" -c core.quotePath=false ls-files
  else
    (cd "$ROOT" && find . -path ./.git -prune -o -type f -print) | sed 's|^\./||'
  fi
}

SHEBANG='^#!.*(^|[/ ])(ba|da|z|k)?sh([[:space:]]|$)'

# candidates — the shell sources among them: by name, by directory, by shebang.
candidates() {
  local f first
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -f "$ROOT/$f" ] || [ -L "$ROOT/$f" ]; then continue; fi
    case "$f" in
      *.sh|.githooks/*|.github/workflows/*.yml|.github/workflows/*.yaml) echo "$f"; continue ;;
    esac
    first=
    IFS= read -r first < "$ROOT/$f" 2>/dev/null || true
    [[ $first =~ $SHEBANG ]] && echo "$f"
  done < <(all_files) | LC_ALL=C sort
}

# scan <file>... — one record per finding: path TAB line TAB text. POSIX awk
# only (no interval expressions), so it runs under mawk.
scan() {
  awk '
    # quiet(r) — r is the text after the grep word; 1 if a quiet flag is in it.
    function quiet(r,   n, t, i, tok, j, c, skip) {
      gsub(/\047[^\047]*\047/, "Q", r)
      gsub(/"[^"]*"/, "Q", r)
      sub(/[|;&)>].*$/, "", r)
      n = split(r, t, /[[:space:]]+/)
      skip = 0
      for (i = 1; i <= n; i++) {
        tok = t[i]
        if (tok == "") continue
        if (skip) { skip = 0; continue }
        if (tok == "--") return 0
        if (tok == "--quiet" || tok == "--silent") return 1
        if (tok ~ /^--/) {
          if (tok ~ /^--(regexp|file|max-count|after-context|before-context|context|binary-files|devices|directories|exclude|include|label|color|colour)$/) skip = 1
          continue
        }
        if (tok ~ /^-[A-Za-z]+$/) {
          for (j = 2; j <= length(tok); j++) {
            c = substr(tok, j, 1)
            if (c == "q") return 1
            if (c ~ /[efmABCdD]/) { if (j == length(tok)) skip = 1; break }
          }
        }
      }
      return 0
    }
    BEGIN {
      G = "(![[:space:]]*)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(command[[:space:]]+)?(\\/[^[:space:]]*\\/)?(e|f)?grep([[:space:]]|$)"
      SAME = "(^|[^|&])\\|&?[[:space:]]*" G
      NEXT = "^[[:space:]]*" G
    }
    FNR == 1 { prevpipe = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*#/) next
      if (line ~ /^[[:space:]]*$/) next
      hit = 0
      s = line
      while (match(s, SAME)) {
        if (quiet(substr(s, RSTART + RLENGTH - 1))) hit = 1
        s = substr(s, RSTART + RLENGTH)
      }
      if (!hit && prevpipe && match(line, NEXT)) {
        if (quiet(substr(line, RSTART + RLENGTH - 1))) hit = 1
      }
      if (hit) printf "%s\t%d\t%s\n", FILENAME, FNR, line
      t = line
      sub(/[[:space:]]*\\$/, "", t)
      sub(/[[:space:]]+$/, "", t)
      prevpipe = (t ~ /(^|[^|&])\|$/ || t ~ /\|&$/)
    }' "$@"
}

FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(candidates)
RECORDS=$(mktemp) || exit 2
trap 'rm -f "$RECORDS"' EXIT
if [ "${#FILES[@]}" -gt 0 ]; then
  (cd "$ROOT" && scan "${FILES[@]}") > "$RECORDS"
fi

declare -A actual=() allowed=() lineof=()
while IFS=$'\t' read -r f ln text; do
  [ -n "$f" ] || continue
  actual[$f]=$(( ${actual[$f]:-0} + 1 ))
  : "$ln" "$text"
done < "$RECORDS"

if [ "$MODE" = print ]; then
  for f in "${!actual[@]}"; do printf '%s:%s\n' "$f" "${actual[$f]}"; done | LC_ALL=C sort
  exit 0
fi
if [ "$MODE" = list ]; then
  while IFS=$'\t' read -r f ln text; do printf '%s:%s: %s\n' "$f" "$ln" "$text"; done < "$RECORDS"
  exit 0
fi

# ---------------------------------------------------------------- ledger
LEDGER_SNAPSHOT=
[ -f "$LEDGER" ] && LEDGER_SNAPSHOT=$(cat -- "$LEDGER")
lineno=0
while IFS= read -r entry || [ -n "$entry" ]; do
  lineno=$((lineno + 1))
  case "$entry" in ''|'#'*) continue ;; esac
  if ! [[ "$entry" =~ ^([^[:space:]]+):([1-9][0-9]*)$ ]] || [ -n "${allowed[${BASH_REMATCH[1]}]:-}" ]; then
    echo "::error file=$LEDGER,line=$lineno::malformed or duplicate ledger entry (want one path:count per file): $entry"
    exit 1
  fi
  allowed[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}; lineof[${BASH_REMATCH[1]}]=$lineno
done <<<"$LEDGER_SNAPSHOT"

# verdicts — the one place staleness is decided; check and prune both read it.
#   NEW <path> <have>  GREW <path> <want> <have>
#   LOWER <path> <want> <have>  GONE <path> <want>
verdicts() {
  local f n want
  for f in "${!actual[@]}"; do
    n=${actual[$f]}; want=${allowed[$f]:-0}
    if [ "$want" -eq 0 ]; then echo "NEW $f $n"
    elif [ "$n" -gt "$want" ]; then echo "GREW $f $want $n"
    elif [ "$n" -lt "$want" ]; then echo "LOWER $f $want $n"
    fi
  done
  for f in "${!allowed[@]}"; do
    [ -z "${actual[$f]:-}" ] && echo "GONE $f ${allowed[$f]}"
  done
}
VERDICTS=$(verdicts | LC_ALL=C sort -k2)

show_lines() { # show_lines <path> — each finding as a GitHub ::error annotation
  while IFS=$'\t' read -r f ln text; do
    [ "$f" = "$1" ] || continue
    echo "::error file=$f,line=$ln::pipe into a quiet grep (capture, then match: out=\$(writer); grep -q PATTERN <<<\"\$out\"): $text"
  done < "$RECORDS"
}

fail=0
if [ "$MODE" = prune ]; then
  name=$LEDGER
  case "$LEDGER" in "$ROOT"/*) name=${LEDGER#"$ROOT"/} ;; esac
  hard=0
  plan=""
  while read -r v f a b; do
    case "$v" in
      NEW|GREW) hard=$((hard + 1)) ;;
      GONE)  plan+="${lineof[$f]}"$'\t'delete$'\t'$'\t'"stale ledger entry $f:$a — no pipe into a quiet grep left"$'\n' ;;
      LOWER) plan+="${lineof[$f]}"$'\t'lower$'\t'"$f:$b"$'\t'"stale ledger entry $f:$a — now $b"$'\n' ;;
    esac
  done <<<"$VERDICTS"
  if [ "$hard" -gt 0 ]; then
    echo "❌ pipe-grep-q: prune refused: $hard problem(s) that pruning may not hide; $name is unchanged."
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
while read -r v f a b; do
  case "$v" in
    NEW)   echo "❌ new pipe(s) into a quiet grep in $f ($a) — capture, then match"
           show_lines "$f"; fail=$((fail + 1)) ;;
    GREW)  echo "❌ pipes into a quiet grep GREW in $f: $b, ledger allows $a — the ledger is shrink-only"
           show_lines "$f"; fail=$((fail + 1)) ;;
    LOWER) echo "❌ stale ledger entry $f:$a — now $b; shrink the ledger to $f:$b in this change (or run --prune)"
           fail=$((fail + 1)) ;;
    GONE)  echo "❌ stale ledger entry $f:$a — no pipe into a quiet grep left; delete the line (or run --prune)"
           fail=$((fail + 1)) ;;
  esac
done <<<"$VERDICTS"

if [ "$fail" -gt 0 ]; then
  echo
  echo "❌ pipe-grep-q: $fail problem(s); $total ledgered pipe(s) into a quiet grep across ${#actual[@]} file(s)."
  exit 1
fi
echo "✅ pipe-grep-q: $total ledgered pipe(s) into a quiet grep across ${#actual[@]} file(s), none new, none grown, none stale."
