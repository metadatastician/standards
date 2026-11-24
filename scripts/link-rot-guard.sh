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
# SYNTAX. A target resolves beside its source file only. Read: AsciiDoc link:,
# image: and image:: (an image under the file's :imagesdir:), and Markdown
# [text](dest) with <angle> or balanced-parenthesis destinations and an optional
# title. Not read: comment lines, AsciiDoc listing/literal/comment blocks, and
# Markdown fenced blocks. `{name}` is expanded from the same file's
# `:name: value` lines; a reference left unresolved is skipped (it cannot be
# checked statically), not reported. An explicit URI scheme or an absolute path
# is external; a name that merely starts with "http" is a file.
#
# NOT READ (each is a limit, not a promise): Markdown reference-style links
# ([x]: dest), HTML href and src, AsciiDoc include:: and the <<xref>> shorthand,
# xref:id[] (local anchors), attributes defined in another file, and the
# AsciiDoc files with other extensions. A break of these kinds is
# not caught. xref:file.adoc[] and image macros are read.
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

# extract <file> — one link target per line. POSIX awk only (no interval
# expressions), so it runs under mawk.
#   AsciiDoc: link:T[ ... ], image:T[ ... ], the block form image::T[ ... ] and
#     xref:T[ ... ] when T names a file (T ends .adoc, .asciidoc or .md, with an
#     optional #anchor; xref:id[] is local and is not read). Skipped: comment
#     lines (//), inline passthroughs holding a macro (+x+, ++x++, pass:[x]),
#     and listing, literal and comment blocks (----, ...., ////),
#     which a renderer does not turn into links. An image target is read under
#     the :imagesdir: in effect. {name} is expanded from the attributes in
#     effect at that line (set by `:name: value`, removed by `:name!:` or
#     `:!name:`); a reference with no definition stays as {name} and is skipped
#     by the caller.
#   Markdown: [text](DEST) with DEST either <angle bracketed> or a bare run with
#     balanced parentheses ending at whitespace (a title may follow); a
#     backslash escapes the next character. Fenced code blocks (``` and ~~~)
#     and inline code spans are skipped.
extract() {
  case "$1" in
    *.adoc|*.asciidoc) awk '
      # One link target, after attributes and the image directory.
      function emit(m, kind,   n, nm) {
        for (n = 0; n < 20 && match(m, /\{[A-Za-z0-9_-]+\}/); n++) {
          nm = substr(m, RSTART + 1, RLENGTH - 2)
          if (!(nm in attr)) break
          m = substr(m, 1, RSTART - 1) attr[nm] substr(m, RSTART + RLENGTH)
        }
        if (kind == "xref" && m !~ /\.(adoc|asciidoc|md)([#?].*)?$/) return
        if (kind == "image" && ("imagesdir" in attr) && attr["imagesdir"] != "" && m !~ /^([A-Za-z][A-Za-z0-9+.-]*:|\/|\{)/) {
          m = attr["imagesdir"] "/" m
        }
        print m
      }
      # A delimited block ends only at the same delimiter, character and length.
      /^(\/\/\/\/+|----+|\.\.\.\.+)[[:space:]]*$/ {
        d = $0; sub(/[[:space:]]+$/, "", d)
        if (blk == "") blk = d; else if (d == blk) blk = ""
        next
      }
      blk != "" { next }
      /^\/\// { next }
      match($0, /^:!?[A-Za-z0-9_-]+!?:/) {
        tag = substr($0, 2, RLENGTH - 2); v = substr($0, RLENGTH + 1)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        if (tag ~ /^!/ || tag ~ /!$/) { sub(/^!/, "", tag); sub(/!$/, "", tag); delete attr[tag] }
        else attr[tag] = v
        next
      }
      {
        s = $0
        # A passthrough that wraps a whole macro shows it literally: +link:x[]+,
        # ++link:x[]++, pass:[link:x[]]. A passthrough inside a macro target
        # (link:pass:[a b.pdf][x]) is the target itself and is read here.
        gsub(/\+(link|image|xref):[^+]*\+/, "", s)
        gsub(/pass:[a-z,]*\[(link|image|xref):[^]]*\]/, "", s)
        while (match(s, /(link|image|xref)::?pass:[a-z,]*\[[^]]*\]/)) {
          m = substr(s, RSTART, RLENGTH)
          s = substr(s, 1, RSTART - 1) substr(s, RSTART + RLENGTH)
          kind = (m ~ /^image/) ? "image" : ((m ~ /^xref/) ? "xref" : "link")
          sub(/^(link|image|xref)::?pass:[a-z,]*\[/, "", m); sub(/\]$/, "", m)
          emit(m, kind)
        }
        while (match(s, /(link|image|xref)::?[^][]+\[/)) {
          m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          kind = (m ~ /^image/) ? "image" : ((m ~ /^xref/) ? "xref" : "link")
          sub(/^(link|image|xref)::?/, "", m); sub(/\[$/, "", m)
          emit(m, kind)
        }
      }' "$1" ;;
    *.md) awk '
      # A fence closes only on the same marker, at least as long as the opener,
      # with nothing after it (CommonMark): ```` holds ``` as content.
      match($0, /^[[:space:]]*(```+|~~~+)/) {
        run = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", run)
        rest = substr($0, RSTART + RLENGTH)
        if (!fence) { fence = 1; fc = substr(run, 1, 1); fl = length(run) }
        else if (substr(run, 1, 1) == fc && length(run) >= fl && rest ~ /^[[:space:]]*$/) fence = 0
        next
      }
      fence { next }
      {
        s = $0
        gsub(/``[^`]*``/, "", s); gsub(/`[^`]*`/, "", s)
        while ((i = index(s, "](")) > 0) {
          # A link needs an opening bracket before its "](".
          opener = (substr(s, 1, i - 1) ~ /\[/)
          s = substr(s, i + 2)
          if (!opener) continue
          if (substr(s, 1, 1) == "<") {
            j = index(s, ">"); if (j == 0) continue
            print substr(s, 2, j - 2); s = substr(s, j + 1)
          } else {
            depth = 0; out = ""
            for (k = 1; k <= length(s); k++) {
              c = substr(s, k, 1)
              if (c == "\\" && k < length(s)) { k++; out = out substr(s, k, 1); continue }
              if (c == "(") depth++
              else if (c == ")") { if (depth == 0) break; depth-- }
              else if (c ~ /[[:space:]]/) break
              out = out c
            }
            if (out != "") print out
            s = substr(s, k)
          }
        }
      }' "$1" ;;
  esac
}

# Every broken link, as `source TAB target`, source relative to ROOT. Runs from
# inside ROOT so each path is root-relative and the exclusion is a fixed path.
# A target resolves only beside its source file, as a renderer resolves it; a
# repo-root fallback would accept links that are broken where they are read.
#
# inside_root <dir> <target> — 0 when dir/target stays inside the root, judged
# on the text alone (".." never climbs above the root) and before the
# filesystem is asked anything. A link that leaves the repository is not a
# repository link, and probing a path outside the checkout would let document
# text test for files on the machine that runs the gate.
inside_root() {
  local -a parts=() out=()
  local part
  IFS=/ read -ra parts <<<"$1/$2"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) [ "${#out[@]}" -gt 0 ] || return 1; unset 'out[${#out[@]}-1]' ;;
      *) out+=("$part") ;;
    esac
  done
  return 0
}

# contained <dir> <target> — inside_root, and, when the tree holds a symlink,
# the canonical path as well: a symlinked directory that points out of the
# checkout must not let a link reach files beyond it. realpath -m answers the
# same whether or not the target exists, so it tests for nothing by itself.
contained() {
  inside_root "$1" "$2" || return 1
  [ "$HAS_LINKS" = 1 ] || return 0
  local p
  p=$(realpath -m -- "$1/$2") || return 1
  [[ "$p" == "$ROOT_REAL" || "$p" == "$ROOT_REAL"/* ]]
}

# scan <filelist> — a failure to list, read or extract is an error (return 2),
# not an empty result: an unread document must not look like a clean one.
scan() {
  local f dir target decoded links tmp
  ROOT_REAL=$(pwd -P) || return 2
  HAS_LINKS=0
  links=$(find . -path ./9-archive -prune -o -path '*/.git' -prune -o -type l -print -quit) || return 2
  [ -z "$links" ] || HAS_LINKS=1
  tmp=$(mktemp) || return 2
  while IFS= read -r -d '' f; do
    f=${f#./}
    dir=$(dirname "$f")
    extract "$f" > "$tmp" || { rm -f "$tmp"; return 2; }
    while IFS= read -r target; do
      # A reference the extractor could not expand is defined outside this file
      # (an include, the command line): it cannot be checked statically.
      case "$target" in *'{'*) continue ;; esac
      target="${target%%#*}"
      target="${target%%\?*}"
      [ -z "$target" ] && continue
      # An explicit URI scheme (https:, mailto:, irc:, ...) or an absolute path
      # is not a repository-relative link. A name that merely starts with
      # "http" (http-guide.md) is.
      if [[ "$target" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] || [[ "$target" == /* ]]; then continue; fi
      if contained "$dir" "$target"; then
        if [ -e "$dir/$target" ]; then continue; fi
        # A destination is a URL path: a%20b.md names the file "a b.md". The
        # literal name was tried first, so a file called 100%.md still resolves.
        if [[ "$target" =~ %[0-9A-Fa-f][0-9A-Fa-f] ]]; then
          decoded=$(printf '%b' "${target//%/\\x}")
          if contained "$dir" "$decoded" && [ -e "$dir/$decoded" ]; then continue; fi
        fi
      fi
      # Paths and targets come from contributor files and are printed into the
      # job log: a control character (a newline in a file name) could start a
      # line of its own and be read as a workflow command. Show it as "?".
      printf '%s\t%s\n' "${f//[[:cntrl:]]/?}" "${target//[[:cntrl:]]/?}"
    done < "$tmp"
  done < "$1"
  rm -f "$tmp"
}
FILES=$(mktemp) || exit 2
trap 'rm -f "$RECORDS" "$FILES"' EXIT
if ! (cd "$ROOT" && find . -path ./9-archive -prune -o -path '*/.git' -prune -o -type f \( -name '*.adoc' -o -name '*.asciidoc' -o -name '*.md' \) -print0 | LC_ALL=C sort -z) > "$FILES"; then
  echo "::error::link-rot: could not list the documents" >&2; exit 2
fi
if ! (cd "$ROOT" && scan "$FILES") > "$RECORDS"; then
  echo "::error::link-rot: a document could not be read or parsed; no verdict was drawn" >&2; exit 2
fi

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

# Data in a GitHub workflow command: % is written %25, and in a property
# (file=...) so are : and ,. Control characters were removed before this point.
gh_data() { local s=${1//%/%25}; s=${s//$'\r'/%0D}; s=${s//$'\n'/%0A}; printf '%s' "$s"; }
gh_prop() { local s; s=$(gh_data "$1"); s=${s//:/%3A}; s=${s//,/%2C}; printf '%s' "$s"; }

# ---------------------------------------------------------------- ledger
LEDGER_SNAPSHOT=
[ -f "$LEDGER" ] && LEDGER_SNAPSHOT=$(cat -- "$LEDGER")
lineno=0
while IFS= read -r entry || [ -n "$entry" ]; do
  lineno=$((lineno + 1))
  case "$entry" in ''|'#'*) continue ;; esac
  # A control character in a ledger line (a stray CR, say) is malformed, and
  # keeps every key that is printed later free of them.
  if [[ "$entry" == *[[:cntrl:]]* ]] \
     || ! [[ "$entry" =~ ^(.+):([1-9][0-9]{0,14})$ ]] || [ -n "${allowed[${BASH_REMATCH[1]}]:-}" ]; then
    printf '::error file=%s,line=%s::malformed or duplicate ledger entry (want one path:count per file): %s\n' \
      "$(gh_prop "$LEDGER")" "$lineno" "$(gh_data "${entry//[[:cntrl:]]/?}")"
    exit 1
  fi
  allowed[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}; lineof[${BASH_REMATCH[1]}]=$lineno
done <<<"$LEDGER_SNAPSHOT"

# --base: no ledger line may be new or higher than at the merge base.
basefail=0
if [ -n "$BASE" ] && [ "$MODE" = check ]; then
  # The ledger in use, as a path inside the repository, so the same file is
  # read at the base. A ledger outside it has no base to compare with.
  led_abs=$(realpath -m -- "$LEDGER"); root_abs=$(realpath -- "$ROOT")
  case "$led_abs" in
    "$root_abs"/*) rel=${led_abs#"$root_abs"/} ;;
    *) echo "::error::link-rot: --base needs a ledger inside the repository" >&2; exit 2 ;;
  esac
  mb=$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null) || mb=$BASE
  if ! git -C "$ROOT" rev-parse -q --verify "$mb^{commit}" >/dev/null 2>&1; then
    printf '::error::link-rot: cannot resolve base revision: %s\n' "$(gh_data "${BASE//[[:cntrl:]]/?}")"; exit 2
  fi
  if base_text=$(git -C "$ROOT" show "$mb:$rel" 2>/dev/null); then
    declare -A baseallowed=()
    while IFS= read -r e; do
      if [[ "$e" =~ ^(.+):([1-9][0-9]{0,14})$ ]]; then baseallowed[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}; fi
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
    printf '::error file=%s::broken internal link -> %s\n' "$(gh_prop "$f")" "$(gh_data "$target")"
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
