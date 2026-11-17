#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-marker-issue-refs.sh — a code marker must cite an issue.
#
# Owner decision 2026-11-17 (standards#955): a marker is a pointer to tracked
# work, never a second, untracked list of work. The gate refuses a bare marker
# and accepts only one that names an issue. The debt figure is then the set of
# OPEN issues the markers cite (see --online), and the Debtfile measure that
# counted files containing the word was retired. Spec: docs/DEBTFILE-SPEC.adoc,
# section "Every code marker cites an issue".
#
# WHAT A MARKER IS
#   The word TODO or FIXME (upper case, whole word; XXX and HACK are not
#   markers, as they were not counted by the retired measure) where it OPENS
#   the content of a comment: it follows a comment leader for the file's type
#   with only whitespace between, and is itself followed by "(", ":",
#   whitespace or the end of the line. Leaders by type:
#     "#"            shell, YAML, TOML, Nickel, Justfile, Containerfile, ...
#     "//", "/*"     Rust, C, JS, Zig, AffineScript, ... ; inside a /* */
#                    block, each line's content after an optional run of "*"
#     "--", "{-"     Haskell, Idris, Agda, Elm, Dhall, SQL; "/-" for Lean
#     "(*"           OCaml, Coq
#     ";"            Scheme, Lisp, deeds, ABNF, contractiles
#     "%"            TeX, Erlang, Logtalk, Mermaid
#     "<!--"         Markdown, HTML, XML, SVG
#     "//" at col 1  AsciiDoc, and every line inside a //// block
#   A line leader counts at the start of a line or after whitespace, so a
#   leader glued to code ("$#", "http://", "\n#") is not a leader. Only the
#   FIRST comment on a line is read: in "# see the old # note" the comment
#   content opens with "see", so a later "#" is text, not a new comment.
#   Not markers: a mention in running prose (Markdown and AsciiDoc text,
#   table cells, list items), a string, a file name, anything inside a
#   Markdown code fence or an AsciiDoc listing, literal or passthrough block,
#   and the body of a shell heredoc (shell, YAML, Justfile, Containerfile).
#
# THE ACCEPTED FORM
#   The marker word, then "(#123)" for an issue in this repository or
#   "(owner/repo#123)" for an issue elsewhere, then anything. Every other
#   marker is BARE and refused.
#
# LIMITS OF A LINE-BASED READING (each is pinned by the test suite)
#   * Strings are not parsed. A leader inside a string that is preceded by
#     whitespace (echo " # x") is read as a comment, and a string containing a
#     leader before the real comment hides that comment. The first fails
#     closed; the escape is the pragma below.
#   * Heredoc bodies are skipped from the line after "<<WORD" (or <<'WORD',
#     <<-WORD) to the line whose trimmed text is WORD; an unterminated heredoc
#     runs to the end of the file, as it does in bash.
#   * Block comments do not nest, and a second comment on the same line after
#     a block closes is not read. HTML comments and /* */ blocks spanning
#     lines are followed; Haskell {- -} and OCaml (* *) blocks are followed
#     the same way.
#   * A file type with no comment syntax known here (JSON, plain text, CSV,
#     an unknown extension) is not read; the summary line says how many such
#     files contain the word.
#   * Files are read as tracked by git (the working-tree copy, or the staged
#     copy with --cached). Outside a git work tree every file is walked.
#
# A GENUINE EXAMPLE (house pragma style, as for uuid/external in
# scripts/check-uuid-v8.sh): on the line, in any comment syntax,
#       hypatia: allow marker/example -- <reason>
#   or on the line before it
#       hypatia: allow-next-line marker/example -- <reason>
#   The reason is required. A pragma whose line carries no bare marker is
#   stale and fails. A pragma whose reason is the literal "<reason>" is a
#   documentation example and is ignored.
#
# GRANDFATHERED MARKERS
#   .machine_readable/marker-allow.txt is a SHRINK-ONLY ledger, one
#   `path:count` per file that had bare markers on 2026-11-17. The gate fails
#   on a file not listed that has any (new debt), on a file with more than its
#   count (grown), and on a stale line (fewer than its count, or none): the
#   same three-way discipline as scripts/check-inline-python.sh.
#
# EXCLUDED PATHS (one reason each)
#   *.ncl.in                         k9 templates; their marker fields are
#                                    fill-in placeholders by design
#   .machine_readable/Debtfile.a2ml  the debt register, which records this
#                                    debt in prose (the retired probe's rule)
#   docs/DEBTFILE-SPEC.adoc          the register's spec, likewise
#
# Usage: check-marker-issue-refs.sh [--root DIR] [--ledger FILE] [--cached]
#                                   [--print | --prune | --online [--repo O/R]]
#   (no mode)  check against the ledger
#   --print    write the current `path:count` set of bare markers and exit 0
#   --prune    delete stale ledger lines and lower counts that are too high,
#              in place; never adds a line or raises a count; a new or grown
#              offender still fails; idempotent
#   --online   read-only, needs gh: list every cited issue with its state and
#              fail if a marker cites an issue that is closed, does not exist,
#              or is a pull request. Does not check bare markers.
#   --repo     the owner/repo that "(#N)" means; default: the origin remote
#   --cached   read the staged copy of each file (for the pre-commit hook)
# Exit: 0 clean · 1 violations · 2 usage error, or (--online) an issue whose
#       state could not be read.
set -uo pipefail

ROOT=.
LEDGER=
MODE=check
CACHED=false
REPO=
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --ledger) LEDGER=${2:?--ledger needs a file}; shift 2 ;;
    --print) MODE=print; shift ;;
    --prune) MODE=prune; shift ;;
    --online) MODE=online; shift ;;
    --repo) REPO=${2:?--repo needs owner/repo}; shift 2 ;;
    --cached) CACHED=true; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-marker-issue-refs: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$ROOT" ] || { echo "check-marker-issue-refs: no such directory: $ROOT" >&2; exit 2; }
if $CACHED && [ "$MODE" = prune ]; then
  echo "check-marker-issue-refs: --prune edits the working-tree ledger; it does not combine with --cached" >&2
  exit 2
fi
LEDGER_REL=.machine_readable/marker-allow.txt
LEDGER=${LEDGER:-$ROOT/$LEDGER_REL}

IN_GIT=false
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && IN_GIT=true
if $CACHED && ! $IN_GIT; then
  echo "check-marker-issue-refs: --cached needs a git work tree" >&2; exit 2
fi

# candidates — every file that contains the word at all, relative to $ROOT,
# sorted, minus the excluded paths. Text files only (-I).
candidates() {
  if $IN_GIT; then
    local c=()
    $CACHED && c=(--cached)
    git -C "$ROOT" grep -I -l "${c[@]}" -E '(^|[^[:alnum:]_])(TODO|FIXME)([^[:alnum:]_]|$)' -- . \
      ':(exclude)*.ncl.in' ':(exclude).machine_readable/Debtfile.a2ml' \
      ':(exclude)docs/DEBTFILE-SPEC.adoc'
  else
    (cd "$ROOT" && grep -rIlE --exclude-dir=.git '(^|[^[:alnum:]_])(TODO|FIXME)([^[:alnum:]_]|$)' . |
      sed 's|^\./||' | grep -vE '\.ncl\.in$|^\.machine_readable/Debtfile\.a2ml$|^docs/DEBTFILE-SPEC\.adoc$')
  fi | LC_ALL=C sort
}

# read_file <rel> — the file's content: staged copy with --cached, else on disk.
read_file() {
  if $CACHED; then git -C "$ROOT" show ":$1" 2>/dev/null; else cat -- "$ROOT/$1"; fi
}

# family_of <rel> — prints "LT|BO|BC|MODE|HD" for the file's comment syntax,
# or nothing when the type has none known here. LT is a space-separated list
# of line leaders; BO/BC open and close a block comment; MODE is generic, md
# or adoc; HD is 1 where shell heredocs occur.
family_of() {
  local base=${1##*/} ext first
  # A template keeps the syntax of what it renders: x.rs.liquid reads as x.rs.
  case "$base" in
    *.liquid|*.tmpl|*.template|*.in|*.example|*.j2) base=${base%.*} ;;
  esac
  case "$base" in
    Justfile|justfile|Containerfile|Dockerfile|Mustfile|Dustfile) echo '#||||1'; return ;;
    Makefile|CODEOWNERS|Gemfile|Rakefile|Brewfile|Procfile|Intentfile|Trustfile|Bustfile) echo '#||||0'; return ;;
    .gitignore|.gitattributes|.gitmodules|.dockerignore|.editorconfig|.env) echo '#||||0'; return ;;
  esac
  ext=
  case "$base" in *.*) ext=${base##*.} ;; esac
  case "$ext" in
    sh|bash|zsh|ksh|yml|yaml|kyaml|just) echo '#||||1' ;;
    toml|ncl|nix|py|pyi|rb|rake|gemspec|pl|pm|r|R|jl|ex|exs|cr|nim|tcl|ps1|awk|jq|conf|cfg|properties|cmake|k9|a2ml|mk|ttl|sparql|cff|coffee|fish) echo '#||||0' ;;
    rs|c|h|cc|cpp|cxx|hpp|hh|js|mjs|cjs|jsx|ts|tsx|go|java|kt|kts|swift|zig|affine|res|resi|scala|cs|fs|dart|gleam|proto|groovy|sol|scss|less|me|jsonc|json5) echo '//|/*|*/|generic|0' ;;
    css) echo '|/*|*/|generic|0' ;;
    php|hcl|tf) echo '# //|/*|*/|generic|0' ;;
    hs|lhs|idr|lidr|agda|elm|purs|dhall|cabal) echo '--|{-|-}|generic|0' ;;
    lean) echo '--|/-|-/|generic|0' ;;
    sql) echo '--|/*|*/|generic|0' ;;
    lua|ada|adb|ads|vhd|vhdl) echo '--||||0' ;;
    ml|mli|v|sml|thy) echo '|(*|*)|generic|0' ;;
    scm|ss|sld|rkt|el|lisp|cl|clj|cljs|cljc|edn|deed|abnf|contractile|asm|s|fnl|dune) echo ';||||0' ;;
    ini) echo '; #||||0' ;;
    tex|sty|cls|erl|hrl|mermaid|mmd) echo '%||||0' ;;
    lgt) echo '%|/*|*/|generic|0' ;;
    md|markdown) echo '|<!--|-->|md|0' ;;
    html|htm|xml|svg|xsl|xslt|xhtml|vue|plist|rss) echo '|<!--|-->|generic|0' ;;
    adoc|asciidoc|asc) echo '|||adoc|0' ;;
    '')
      # No extension: a shell script by its shebang (hooks, tools).
      first=$(read_file "$1" | head -n 1)
      if [[ $first =~ ^#!.*sh ]]; then echo '#||||1'; fi ;;
  esac
}

# scan <rel> <family> — prints one record per finding on stdout:
#   B <line> <text>   bare marker            C <line> <ref>   cited marker
#   X <line>          bare marker excused     E <line> <msg>   pragma defect
# POSIX awk only (no interval expressions), so it runs under mawk.
scan() {
  local lt bo bc mode hd rest
  IFS='|' read -r lt bo bc mode hd rest <<<"$2"
  : "$rest"
  read_file "$1" | awk -v LT="$lt" -v BO="$bo" -v BC="$bc" -v MODE="${mode:-generic}" -v HDOK="${hd:-0}" '
    function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
    function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
    function striprun(s, c) { while (c != "" && substr(s, 1, 1) == c) s = substr(s, 2); return s }
    # First position of tok in s at the start of s or after a blank; 0 if none.
    function leaderpos(s, tok,   off, p, q) {
      if (tok == "") return 0
      off = 0
      while ((p = index(substr(s, off + 1), tok)) > 0) {
        q = off + p
        if (q == 1 || substr(s, q - 1, 1) ~ /[ \t]/) return q
        off = q
      }
      return 0
    }
    # Judge the content of the first comment on this line.
    function judge(content,   c, r) {
      if (judged) return
      judged = 1
      c = ltrim(content)
      if (!(c ~ /^(TODO|FIXME)$/ || c ~ /^(TODO|FIXME)[(: \t]/)) return
      if (c ~ /^(TODO|FIXME)\((#[1-9][0-9]*|[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]*)\)/) {
        r = c; sub(/^(TODO|FIXME)\(/, "", r); sub(/\).*$/, "", r); cref = r
      } else bare = 1
    }
    # Content after a leader token: drop a run of its last character, and a "!".
    function after(s, tok) {
      s = striprun(s, substr(tok, length(tok), 1))
      return striprun(s, "!")
    }
    function generic(s,   n, i, toks, best, btok, p, code, w, content, q) {
      if (inblock != "") {
        p = index(s, inblock)
        content = p ? substr(s, 1, p - 1) : s
        judge(striprun(ltrim(content), "*"))
        if (!p) return
        s = substr(s, p + length(inblock)); inblock = ""
      }
      n = split(LT, toks, " ")
      best = 0; btok = ""
      for (i = 1; i <= n; i++) {
        p = leaderpos(s, toks[i])
        if (p && (!best || p < best)) { best = p; btok = toks[i] }
      }
      p = leaderpos(s, BO)
      if (p && (!best || p < best)) { best = p; btok = BO }
      if (HDOK == 1 && hd == "") {
        code = best ? substr(s, 1, best - 1) : s
        if (match(code, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
          q = RSTART
          if (!(q > 1 && substr(code, q - 1, 1) == "<") && substr(code, q + 2, 1) != "<" && index(substr(code, 1, q - 1), "((") == 0) {
            w = substr(code, RSTART, RLENGTH); sub(/^<<-?[ \t]*["\047]?/, "", w); pendhd = w
          }
        }
      }
      if (!best) return
      content = substr(s, best + length(btok))
      if (btok == BO) {
        content = after(content, BO)
        p = index(content, BC)
        if (p) content = substr(content, 1, p - 1); else inblock = BC
      } else content = after(content, btok)
      judge(content)
    }
    function md(s,   t) {
      if (fence != "") { if (substr(ltrim(s), 1, 3) == fence) fence = ""; return }
      if (inblock == "" && s ~ /^ ? ? ?(```|~~~)/) { fence = substr(ltrim(s), 1, 3); return }
      generic(s)
    }
    function adoc(s,   t) {
      t = rtrim(s)
      if (adelim != "") {
        if (t == adelim) { adelim = ""; acomment = 0; return }
        if (acomment) judge(s)
        return
      }
      if (t ~ /^\/\/\/\/+$/) { adelim = t; acomment = 1; return }
      if (t ~ /^----+$/ || t ~ /^\.\.\.\.+$/ || t ~ /^\+\+\+\++$/) { adelim = t; return }
      if (t ~ /^```/) { adelim = "```"; return }
      if (s ~ /^\/\//) judge(striprun(substr(s, 3), "/"))
    }
    # Pragma on line s: "" none, "doc", "bad", "same", "next".
    function pkind(s,   k, rest) {
      if (index(s, "marker/example") == 0) return ""
      if (s ~ /hypatia:[ \t]*allow-next-line[ \t]+marker\/example/) k = "next"
      else if (s ~ /hypatia:[ \t]*allow[ \t]+marker\/example/) k = "same"
      else return ""
      rest = s; sub(/.*marker\/example/, "", rest)
      if (rest ~ /^[ \t]*--[ \t]*<reason>/) return "doc"
      if (rest !~ /^[ \t]*--[ \t]*[^ \t]/) return "bad"
      return k
    }
    BEGIN { inblock = ""; hd = ""; pendhd = ""; fence = ""; adelim = ""; acomment = 0; pend = 0 }
    {
      sub(/\r$/, "")
      judged = 0; bare = 0; cref = ""
      if (hd != "") {
        if (ltrim(rtrim($0)) == hd) hd = ""
      } else if (MODE == "adoc") adoc($0)
      else if (MODE == "md") md($0)
      else generic($0)
      if (pendhd != "") { hd = pendhd; pendhd = "" }

      k = pkind($0)
      covered = 0
      if (pend) {
        covered = 1
        if (!bare) print "E " pend " stale marker/example pragma (the next line has no bare marker)"
        pend = 0
      }
      if (k == "bad") print "E " NR " malformed marker/example pragma; write \"hypatia: allow marker/example -- <reason>\" with a reason"
      else if (k == "same") {
        covered = 1
        if (!bare) print "E " NR " stale marker/example pragma (this line has no bare marker)"
      } else if (k == "next") pend = NR
      if (bare) { if (covered) print "X " NR; else print "B " NR " " $0 }
      if (cref != "") print "C " NR " " cref
    }
    END { if (pend) print "E " pend " stale marker/example pragma (no line follows it)" }'
}

# ---------------------------------------------------------------- measure
declare -A actual=() allowed=()
RECORDS=$(mktemp)
trap 'rm -f "$RECORDS"' EXIT
skipped=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  fam=$(family_of "$f")
  if [ -z "$fam" ]; then skipped=$((skipped + 1)); continue; fi
  scan "$f" "$fam" | while IFS= read -r rec; do printf '%s\t%s\n' "$f" "$rec"; done >> "$RECORDS"
done < <(candidates)

while IFS=$'\t' read -r f rec; do
  case "$rec" in B\ *) actual[$f]=$(( ${actual[$f]:-0} + 1 )) ;; esac
done < "$RECORDS"

if [ "$MODE" = print ]; then
  for f in "${!actual[@]}"; do printf '%s:%s\n' "$f" "${actual[$f]}"; done | LC_ALL=C sort
  exit 0
fi

# ---------------------------------------------------------------- online
if [ "$MODE" = online ]; then
  command -v gh >/dev/null 2>&1 || { echo "check-marker-issue-refs: --online needs gh on PATH" >&2; exit 2; }
  if [ -z "$REPO" ]; then
    url=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
    REPO=$(printf '%s' "$url" | sed -nE 's#^(https://|git@|ssh://git@)github\.com[:/]([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')
  fi
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "check-marker-issue-refs: cannot tell which repository (#N) means; pass --repo owner/repo" >&2; exit 2; }
  declare -A where=()
  while IFS=$'\t' read -r f rec; do
    case "$rec" in
      C\ *) rest=${rec#C }; line=${rest%% *}; ref=${rest#* }
            [ "${ref#\#}" != "$ref" ] && ref="$REPO$ref"
            where[$ref]="${where[$ref]:+${where[$ref]} }$f:$line" ;;
    esac
  done < "$RECORDS"
  fail=0 unknown=0 open=0
  for ref in $(printf '%s\n' "${!where[@]}" | LC_ALL=C sort); do
    r=${ref%#*} n=${ref##*#}
    if out=$(gh api "repos/$r/issues/$n" --jq '.state + " " + (if .pull_request then "pull-request" else "issue" end)' 2>&1); then
      state=${out%% *} kind=${out##* }
      if [ "$kind" != issue ]; then
        echo "❌ $ref is a pull request, not an issue — cited at ${where[$ref]}"; fail=$((fail + 1))
      elif [ "$state" = open ]; then
        echo "open    $ref  ${where[$ref]}"; open=$((open + 1))
      else
        echo "❌ $ref is $state: the work is recorded as finished but the marker is still here — ${where[$ref]}"
        fail=$((fail + 1))
      fi
    elif grep -qE 'Not Found|HTTP 404|HTTP 410' <<<"$out"; then
      echo "❌ $ref does not exist — cited at ${where[$ref]}"; fail=$((fail + 1))
    else
      echo "⚠ $ref could not be read: $out"; unknown=$((unknown + 1))
    fi
  done
  echo
  if [ "$fail" -gt 0 ]; then
    echo "❌ marker-issue-refs --online: $fail cited reference(s) are not open issues; $open open, $unknown unreadable."
    exit 1
  fi
  if [ "$unknown" -gt 0 ]; then
    echo "⚠ marker-issue-refs --online: $unknown cited issue(s) could not be read; $open open. Not a pass."
    exit 2
  fi
  echo "✅ marker-issue-refs --online: $open cited issue(s), all open. This set is the marker debt."
  exit 0
fi

# ---------------------------------------------------------------- ledger
ledger_text() {
  if $CACHED && [ "$LEDGER" = "$ROOT/$LEDGER_REL" ]; then
    git -C "$ROOT" show ":$LEDGER_REL" 2>/dev/null || true
  elif [ -f "$LEDGER" ]; then
    cat -- "$LEDGER"
  fi
}
LEDGER_SNAPSHOT=$(ledger_text)
lineno=0
while IFS= read -r entry || [ -n "$entry" ]; do
  lineno=$((lineno + 1))
  case "$entry" in ''|'#'*) continue ;; esac
  if ! [[ "$entry" =~ ^([^[:space:]]+):([1-9][0-9]*)$ ]] || [ -n "${allowed[${BASH_REMATCH[1]}]:-}" ]; then
    echo "::error file=$LEDGER,line=$lineno::malformed or duplicate ledger entry (want one path:count per file): $entry"
    exit 1
  fi
  allowed[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
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

show_bare() { # show_bare <path> — each bare marker as a GitHub ::error annotation
  while IFS=$'\t' read -r f rec; do
    [ "$f" = "$1" ] || continue
    case "$rec" in B\ *) rest=${rec#B }
      echo "::error file=$f,line=${rest%% *}::bare marker (cite an issue: TODO(#N) or TODO(owner/repo#N)): ${rest#* }" ;;
    esac
  done < "$RECORDS"
}

fail=0
while IFS=$'\t' read -r f rec; do
  case "$rec" in E\ *) rest=${rec#E }
    echo "::error file=$f,line=${rest%% *}::${rest#* }"; fail=$((fail + 1)) ;;
  esac
done < "$RECORDS"

if [ "$MODE" = prune ]; then
  pruned=0
  if [ -f "$LEDGER" ]; then
    tmp=$(mktemp)
    declare -A drop=() lower=()
    while read -r v f a b; do
      case "$v" in GONE) drop[$f]=1 ;; LOWER) lower[$f]=$b ;; esac
      : "$a"
    done <<<"$VERDICTS"
    while IFS= read -r entry || [ -n "$entry" ]; do
      p=${entry%:*}
      case "$entry" in ''|'#'*) printf '%s\n' "$entry" ;;
        *) if [ -n "${drop[$p]:-}" ]; then pruned=$((pruned + 1)); echo "pruned: deleted $entry (no bare marker left)" >&3
           elif [ -n "${lower[$p]:-}" ]; then pruned=$((pruned + 1)); echo "pruned: $entry -> $p:${lower[$p]}" >&3; printf '%s:%s\n' "$p" "${lower[$p]}"
           else printf '%s\n' "$entry"; fi ;;
      esac
    done < "$LEDGER" 3>&1 > "$tmp"
    if [ "$pruned" -gt 0 ]; then cat "$tmp" > "$LEDGER"; fi
    rm -f "$tmp"
  fi
  echo "marker-issue-refs --prune: $pruned ledger line(s) changed."
  VERDICTS=$(printf '%s\n' "$VERDICTS" | grep -E '^(NEW|GREW) ' || true)
fi

total=0
for f in "${!actual[@]}"; do total=$((total + actual[$f])); done
while read -r v f a b; do
  case "$v" in
    NEW)   echo "❌ new bare marker(s) in $f ($a) — cite an issue: TODO(#N) or TODO(owner/repo#N)"
           show_bare "$f"; fail=$((fail + 1)) ;;
    GREW)  echo "❌ bare markers GREW in $f: $b, ledger allows $a — the ledger is shrink-only"
           show_bare "$f"; fail=$((fail + 1)) ;;
    LOWER) echo "❌ stale ledger entry $f:$a — now $b; shrink the ledger to $f:$b in this change (or run --prune)"
           fail=$((fail + 1)) ;;
    GONE)  echo "❌ stale ledger entry $f:$a — no bare marker left; delete the line (or run --prune)"
           fail=$((fail + 1)) ;;
  esac
done <<<"$VERDICTS"

note=""
[ "$skipped" -gt 0 ] && note=" ($skipped file(s) with the word in a type with no known comment syntax were not read)"
if [ "$fail" -gt 0 ]; then
  echo
  echo "❌ marker-issue-refs: $fail problem(s); $total bare marker(s) across ${#actual[@]} file(s)$note."
  exit 1
fi
echo "✅ marker-issue-refs: $total ledgered bare marker(s) across ${#actual[@]} file(s), none new, none grown, none stale$note."
