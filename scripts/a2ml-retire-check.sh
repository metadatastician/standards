#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# a2ml-retire-check.sh — the live retire-check for A2ML (owner decision,
# 2026-11-17: "a live retire-check first"). For every tracked A2ML file
# (*.a2ml, *.a2ml.in, *.a2ml.template, *.a2ml.vN.template) it recomputes the
# three deletion conditions of .claude/CLAUDE.md ("Machine-Readable
# Artefacts") and prints what blocks each file, from a closed vocabulary:
#
#   1. every fact is in a target deed, or the mapping spec drops it;
#   2. every target deed passes 1-formats/deed/tools/deed_lint.js;
#   3. no workflow, script, template or tool reads, writes or generates it.
#
# It reads; it never deletes or edits an A2ML file or a ledger. Deletion stays
# a separate, per-file, owner-visible commit. Documentation, the blocker
# vocabulary and the rulings file: docs/wikis/maintainers/index.adoc,
# section "A2ML retirement: the retire-check" ([[a2ml-retire-check]]).
#
# WHAT IS MECHANICAL AND WHAT IS NOT
#   * Family and governing mapping spec: from the path (and, for
#     0-AI-MANIFEST.a2ml, the [ai-allocation] content shape the spec names).
#   * Facts: compared field by field only where the comparison is scripted
#     here: CLADE (clade-to-repo-deed.adoc §3), and STATE and SCORECARD when
#     the rulings file carries their decision row. Any other family whose
#     target deeds exist is reported `facts-unchecked:<family>`, and such a
#     file is never classed deletable.
#   * Readers: a tracked file that is not prose (.adoc .md .txt .html), not
#     data (.jsonl .csv .tsv .svg), not A2ML, not under 9-archive/,
#     docs/archive/ or .machine_readable/archive/, and that names the file's
#     exact path (`reader:`) or only its basename as a word (`name-reader:`).
#     A writer or generator names the file too, so it is reported as a reader;
#     the tool does not tell readers and writers apart. Files under
#     scripts/tests/ count for an exact path only. Readers outside the tree
#     come from the rulings file (`external-reader:`).
#   * Rulings that the tree cannot show (owner decisions, known spec gaps,
#     open questions, readers in other repositories, which families kyX
#     translates) come from rulings files: each --rulings FILE adds its rows,
#     and with none given, ROOT's .machine_readable/a2ml-retire-rulings.jsonl
#     is read if it exists. Rows never override one another: every row that
#     matches a path applies, and an id given twice is an error. Change a row
#     and the classes move; nothing about a ruling is written in this script.
#     A dropped or decision row may name a `record` file of the tree that must
#     name the path exactly before the file can go (`record-missing:<file>`).
#
# Usage: a2ml-retire-check.sh [--root DIR] [--repo NAME] [--rulings FILE]...
#                             [--counts FILE] [--base REV]
#                             [--json | --summary | --write-counts | --check]
#   (default)   a table: class, path, blockers
#   --json      one JCS object per line (sorted keys), ordered by path
#   --summary   counts per class and per blocker, each "n of N"
#   --write-counts  write the live counts (JCS) to --counts FILE, by default
#               ROOT/.machine_readable/a2ml-retire-counts.json
#   --check     the gate: exit 1 when a file is deletable-now (prints the
#               `git rm` and the ledger line to delete), when a file is
#               unclassified, when the counts file is missing or stale, and,
#               with --base REV, when an A2ML path joined since REV (only an
#               unchanged rename, git R100, may keep its place)
#   --repo      the repository name rulings rows are scoped by (default: the
#               stem of the single <name>_chora.deed at ROOT, else ROOT's name)
# Exit: 0 done (--check: no finding) · 1 --check found a deletable or unclassified
#       file, stale counts or a joined path · 2 setup error (missing tool,
#       malformed rulings, bad root or --base).
# Needs bash 4, git, jq, awk, grep; bun as soon as one target deed exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEED_LINT="${DEED_LINT:-$SCRIPT_DIR/../1-formats/deed/tools/deed_lint.js}"
MAPPINGS="${MAPPINGS:-$SCRIPT_DIR/../1-formats/deed/mappings}"
BUN="${BUN:-bun}"
SELF_TOOL="scripts/a2ml-retire-check.sh"
SELF_TEST="scripts/tests/a2ml-retire-check-test.sh"
A2ML_RE='\.a2ml(\.in|\.template|\.v[0-9]+\.template)?$'
LEDGER_REL=".machine_readable/a2ml-legacy-allow.txt"
COUNTS_REL=".machine_readable/a2ml-retire-counts.json"

ROOT=.; REPO=""; RULINGS=(); MODE=table; BASE_REV=""; COUNTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a name}"; shift 2 ;;
    --rulings) RULINGS+=("${2:?--rulings needs a file}"); shift 2 ;;
    --base) BASE_REV="${2:?--base needs a revision}"; shift 2 ;;
    --write-counts) MODE=write-counts; shift ;;
    --counts) COUNTS="${2:?--counts needs a file}"; shift 2 ;;
    --json) MODE=json; shift ;;
    --summary) MODE=summary; shift ;;
    --check) MODE=check; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 2; }
for t in git jq awk grep; do command -v "$t" >/dev/null 2>&1 || die "$t is required"; done
[ -d "$ROOT" ] || die "$ROOT is not a directory"
ROOT="$(cd "$ROOT" && pwd)"
REPO_ARG=$REPO; RULINGS_ARG=("${RULINGS[@]}"); COUNTS_ARG=$COUNTS
[ -n "$COUNTS" ] || COUNTS="$ROOT/$COUNTS_REL"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ── the file set ──────────────────────────────────────────────────────────
if top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" && [ "$top" = "$ROOT" ]; then
  git -C "$ROOT" ls-files -z > "$T/all"
else
  (cd "$ROOT" && find . -type f ! -path './.git/*' -printf '%P\0') > "$T/all"
fi
tr '\0' '\n' < "$T/all" | grep -E "$A2ML_RE" | LC_ALL=C sort > "$T/a2ml" || true
if grep -q $'\t' "$T/a2ml"; then die "an A2ML path contains a tab; this tool cannot report it"; fi
N=$(grep -c . "$T/a2ml" || true)

if [ -z "$REPO" ]; then
  shopt -s nullglob; choras=("$ROOT"/*_chora.deed); shopt -u nullglob
  if [ "${#choras[@]}" -eq 1 ]; then REPO="$(basename "${choras[0]}" _chora.deed)"; else REPO="$(basename "$ROOT")"; fi
fi

# ── the rulings files ─────────────────────────────────────────────────────
# Each --rulings FILE adds its rows; with none, ROOT's own file is read if it
# exists. Rows never override one another: every row that matches a path
# applies, and the same id in two rows (one file or two) is an error.
KINDS='["dropped","decision","spec-gap","ruling-needed","pending","external-reader","kyx-family"]'
FIELDS='["date","family","id","key","kind","match","record","recorded","repo","requires","summary"]'
if [ "${#RULINGS[@]}" -eq 0 ] && [ -f "$ROOT/.machine_readable/a2ml-retire-rulings.jsonl" ]; then
  RULINGS=("$ROOT/.machine_readable/a2ml-retire-rulings.jsonl")
fi
: > "$T/rulings.all"
bad=""
for rf in "${RULINGS[@]}"; do
  [ -f "$rf" ] || die "rulings file $rf not found"
  jq -c . "$rf" > "$T/rulings.one" 2>/dev/null || die "rulings file $rf is not JSON Lines"
  one=$(jq -r --argjson kinds "$KINDS" --argjson fields "$FIELDS" --arg f "$rf" '
    def ok_key: (type == "string") and test("^[a-z0-9][a-z0-9-]*$");
    (if type != "object" then "not an object"
     elif (keys - $fields) != [] then "unknown field(s) \(keys - $fields)"
     elif (.id | ok_key | not) then "id must be lower-case words joined by -"
     elif (. as $row | $kinds | index($row.kind)) == null then "kind \(.kind | tojson) is not one of \($kinds | join(", "))"
     elif ((.date // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not) then "date must be YYYY-MM-DD"
     elif ((.recorded // "") | length) == 0 then "recorded (where the ruling is written) is required"
     elif ((.summary // "") | type) != "string" or ((.summary // "") | length) == 0 then "summary is required"
     elif (.match == null and .family == null) then "match or family is required"
     elif ((.kind == "decision" or .kind == "kyx-family") and .family == null) then "\(.kind) needs family"
     elif ((.kind | IN("spec-gap","ruling-needed","pending","external-reader")) and (.key | ok_key | not)) then "\(.kind) needs a key"
     elif (.requires != null and (.kind != "dropped" or (.requires | ok_key | not))) then "requires is a key, on a dropped row only"
     elif (.record != null and ((.kind | IN("dropped","decision") | not) or (.record | type) != "string" or (.record | test("^/|(^|/)\\.\\.(/|$)")))) then "record is a repository-relative file, on a dropped or decision row only"
     else empty end) as $e | "\($f) line \(input_line_number): \($e)"' "$T/rulings.one") || die "rulings file $rf could not be checked"
  bad="${bad}${one:+${bad:+$'\n'}$one}"
  cat "$T/rulings.one" >> "$T/rulings.all"
done
# each match pattern must compile
while IFS= read -r m; do
  [ -z "$m" ] && continue
  jq -n --arg m "$m" '"" | test($m)' >/dev/null 2>&1 || bad="${bad}${bad:+$'\n'}match '$m' is not a regular expression"
done < <(jq -r '.match // empty' "$T/rulings.all")
dups=$(jq -r '.id' "$T/rulings.all" | sort | uniq -d)
[ -z "$dups" ] || bad="${bad}${bad:+$'\n'}id(s) given twice: $dups"
[ -z "$bad" ] || die "rulings: $bad"
jq -c --arg repo "$REPO" 'select(.repo == null or .repo == $repo)' "$T/rulings.all" > "$T/rulings"
if [ "${#RULINGS[@]}" -gt 0 ]; then
  RULINGS_NOTE="$(grep -c . "$T/rulings" || true) of $(grep -c . "$T/rulings.all" || true) rulings rows apply to '$REPO'"
else
  RULINGS_NOTE="no rulings file: no owner rulings applied"
fi

# ── pass 1: family, governing spec, base directory ────────────────────────
# family_of PATH -> sets FAM SPEC BASE UNCL (BASE: the directory that holds
# the record's .machine_readable/, or the record's own directory).
family_of() {
  local p=$1 bn=${1##*/} dir
  FAM=none; SPEC=""; BASE=""; UNCL=""
  dir=${p%/*}; [ "$dir" = "$p" ] && dir=""
  if [[ $p =~ ^(.*/)?\.machine_readable/(descriptiles/)?(CLADE|META|ECOSYSTEM|AGENTIC|NEUROSYM|PLAYBOOK|STATE)\.a2ml$ ]]; then
    FAM=${BASH_REMATCH[3]}; BASE=${BASH_REMATCH[1]%/}
  elif [[ $p =~ ^(.*/)?\.machine_readable/bot_directives/[^/]+\.a2ml$ ]]; then
    FAM=BOT-DIRECTIVES; BASE=${BASH_REMATCH[1]%/}
  elif [[ $p =~ ^(.*/)?\.machine_readable/.*\.scorecard\.a2ml$ ]]; then
    FAM=SCORECARD; BASE=${BASH_REMATCH[1]%/}
  elif [ "$p" = "0-canon/rsr/rsr-criteria-v2.a2ml" ]; then
    FAM=RSR-CRITERIA
  elif [ "$bn" = "0-AI-MANIFEST.a2ml" ] && grep -q '^\[ai-allocation\]' "$ROOT/$p" 2>/dev/null; then
    FAM=AI-MANIFEST; BASE=$dir
  fi
  case $FAM in
    CLADE) SPEC=clade-to-repo-deed.adoc ;;
    META|ECOSYSTEM) SPEC=meta-ecosystem-to-repo-deed.adoc ;;
    AGENTIC|NEUROSYM|PLAYBOOK|BOT-DIRECTIVES) SPEC=agentic-neurosym-playbook-to-repo-deed.adoc ;;
    STATE) SPEC=state-v1-decision.adoc ;;
    SCORECARD) SPEC=scorecard-corpus-decision.adoc ;;
    AI-MANIFEST) SPEC=ai-manifest-decision.adoc ;;
    RSR-CRITERIA) SPEC=rsr-criteria-to-praxis-deed.adoc ;;
  esac
  if [ -n "$SPEC" ] && [ ! -f "$MAPPINGS/$SPEC" ]; then UNCL="its mapping spec $SPEC is missing from $MAPPINGS"; fi
  return 0
}
: > "$T/fam.tsv"
while IFS= read -r p; do
  family_of "$p"
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$p" "$FAM" "$SPEC" "$BASE" "$UNCL" >> "$T/fam.tsv"
done < "$T/a2ml"

# Rulings rows that apply to each file: path \t id \t kind \t key \t requires
jq -R -r --slurpfile R "$T/rulings" '
  split("\u001f") as [$p, $f] | $R[] | . as $row
  | select(($row.match == null or ($p | test($row.match))) and ($row.family == null or $row.family == $f))
  | [$p, .id, .kind, (.key // ""), (.requires // ""), (.record // "")] | join("\u001f")' < <(cut -d $'\x1f' -f1,2 "$T/fam.tsv") > "$T/rul.tsv"
declare -A KYX=()
while IFS= read -r f; do KYX[$f]=1; done < <(jq -r 'select(.kind == "kyx-family") | .family' "$T/rulings")

# ── readers: two grep passes over the candidate files ─────────────────────
tr '\0' '\n' < "$T/all" | grep -vE "$A2ML_RE" \
  | grep -vE '\.(adoc|md|txt|html|jsonl|csv|tsv|svg)$|^9-archive/|^docs/archive/|^\.machine_readable/archive/' \
  | grep -vxF -e "$SELF_TOOL" -e "$SELF_TEST" -e "$COUNTS_REL" > "$T/cands" || true
cut -d $'\x1f' -f1 "$T/fam.tsv" > "$T/pat.path"
awk -F/ '{print $NF}' "$T/pat.path" | LC_ALL=C sort -u > "$T/pat.name"
: > "$T/exact.tsv"; : > "$T/name.tsv"
if [ -s "$T/cands" ] && [ -s "$T/pat.path" ]; then
  (cd "$ROOT" || exit 0; tr '\n' '\0' < "$T/cands" | xargs -0 -r grep -I -o -H -Z -F -f "$T/pat.path" -- 2>/dev/null || true) \
    | while IFS= read -r -d '' f && IFS= read -r m; do printf '%s\t%s\n' "$m" "$f"; done | LC_ALL=C sort -u > "$T/exact.tsv"
  (cd "$ROOT" || exit 0; grep -v '^scripts/tests/' "$T/cands" | tr '\n' '\0' | xargs -0 -r grep -I -o -w -H -Z -F -f "$T/pat.name" -- 2>/dev/null || true) \
    | while IFS= read -r -d '' f && IFS= read -r m; do printf '%s\t%s\n' "$m" "$f"; done | LC_ALL=C sort -u > "$T/name.tsv"
fi
declare -A RX=() RN=()
while IFS=$'\t' read -r m f; do RX[$m]+="$f"$'\n'; done < "$T/exact.tsv"
while IFS=$'\t' read -r m f; do RN[$m]+="$f"$'\n'; done < "$T/name.tsv"

# ── deeds: lint and AST, cached; bun only when a deed exists ──────────────
need_bun() {
  command -v "$BUN" >/dev/null 2>&1 \
    || die "bun is required to read and lint the target deeds (deed_lint.js); install bun or set BUN"
  [ -f "$DEED_LINT" ] || die "deed_lint.js not found at $DEED_LINT"
}
key_of() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
# lint_deed REL BASE -> sets LINT=ok|fail (profile for descriptiles, --root BASE when it holds a chora)
lint_deed() {
  local rel=$1 base=$2 k prof="" args=()
  k="lint-$(key_of "$rel")"
  if [ ! -f "$T/$k" ]; then
    need_bun
    case "${rel##*/}" in
      META.deed) prof=--meta ;; AGENTIC.deed) prof=--agentic ;; NEUROSYM.deed) prof=--neurosym ;;
      STATE.deed) prof=--state ;; ECOSYSTEM.deed) prof=--ecosystem ;;
    esac
    if [ -n "$prof" ]; then
      args=("$prof" "$ROOT/$rel")
      [ -n "$(base_chora "$base")" ] && args+=(--root "$ROOT${base:+/$base}")
    else
      args=("$ROOT/$rel")
    fi
    if "$BUN" "$DEED_LINT" "${args[@]}" >/dev/null 2>&1; then echo ok > "$T/$k"; else echo fail > "$T/$k"; fi
  fi
  LINT=$(cat "$T/$k")
}
# ast_file REL -> path of the cached AST JSON ("" when the deed does not parse)
ast_file() {
  local rel=$1 k; k="ast-$(key_of "$rel")"
  if [ ! -f "$T/$k" ] && [ ! -f "$T/$k.none" ]; then
    need_bun
    "$BUN" "$DEED_LINT" --ast-json "$ROOT/$rel" > "$T/$k" 2>/dev/null || { rm -f "$T/$k"; : > "$T/$k.none"; }
  fi
  if [ -f "$T/$k" ]; then AST="$T/$k"; else AST=""; fi
}
has_clause() { jq -e --arg c "$2" 'any(.items[]; .[0] == "clause" and .[1] == $c)' "$1" >/dev/null; }
# base_chora BASE -> the one <name>_chora.deed in BASE ("" none, "MULTI" several)
base_chora() {
  local d="$ROOT${1:+/$1}" c; shopt -s nullglob; c=("$d"/*_chora.deed); shopt -u nullglob
  if [ "${#c[@]}" -eq 0 ]; then echo ""; elif [ "${#c[@]}" -gt 1 ]; then echo MULTI; else echo "${1:+$1/}${c[0]##*/}"; fi
}

# ── the A2ML record reader (TOML-shaped records only) ─────────────────────
# Prints "path<TAB>json-value" per fact, or "!unsupported<TAB>line N" for a
# line it cannot read (inline table, multi-line string, non-TOML text).
read_record() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function strip(s,   i, c, q, out) {
      q = ""; out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { out = out c; if (c == "\\" && q == "\"") { i++; out = out substr(s, i, 1); continue } if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047") { q = c; out = out c; continue }
        if (c == "#") break
        out = out c
      }
      return out
    }
    function depth(s,   i, c, q, d) {
      q = ""; d = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == "\\" && q == "\"") { i++; continue } if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047") { q = c; continue }
        if (c == "[" || c == "{") d++
        if (c == "]" || c == "}") d--
      }
      return d
    }
    function emit(key, v,   inner) {
      v = trim(v)
      if (v ~ /^"""/ || v ~ /^\047\047\047/ || v ~ /^\{/ || v ~ /\{/) { print "!unsupported\tline " NR; return }
      if (v ~ /^\047/) { inner = substr(v, 2, length(v) - 2); gsub(/\\/, "\\\\", inner); gsub(/"/, "\\\"", inner); v = "\"" inner "\"" }
      else if (v ~ /^\[/) { if (v ~ /\047/) { print "!unsupported\tline " NR; return } gsub(/,[ \t]*\]$/, "]", v) }
      print (section == "" ? "" : section ".") key "\t" v
    }
    BEGIN { section = ""; buf = ""; key = "" }
    {
      line = trim(strip($0))
      if (buf != "") { buf = buf " " line; if (depth(buf) <= 0) { emit(key, buf); buf = "" } ; next }
      if (line == "") next
      if (line ~ /^@profile\(id=[^)]*\)$/) { v = line; sub(/^@profile\(id=/, "", v); sub(/\)$/, "", v); print "@profile.id\t\"" v "\""; next }
      if (line ~ /^\[\[[^]]+\]\]$/) { n = substr(line, 3, length(line) - 4); n = trim(n); if (!(n in idx)) idx[n] = -1; idx[n]++; section = n "[" idx[n] "]"; next }
      if (line ~ /^\[[^]]+\]$/) { section = trim(substr(line, 2, length(line) - 2)); next }
      if (match(line, /^[A-Za-z0-9_.-]+[ \t]*=/)) {
        key = trim(substr(line, 1, RLENGTH - 1)); v = trim(substr(line, RLENGTH + 1))
        if (depth(v) > 0) { buf = v; next }
        emit(key, v); next
      }
      print "!unsupported\tline " NR
    }
    END { if (buf != "") print "!unsupported\tunterminated value" }' "$1"
}
# facts_json FILE -> JSON array of {path, value}, or "" when the record is unreadable
facts_json() {
  local out
  out=$(read_record "$1" | jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t") | {path: .[0], raw: .[1]})
    | if any(.path == "!unsupported") then null
      else map({path, value: (.raw | try fromjson catch {"__bad__": true})})
      | if any(.value | type == "object" and has("__bad__")) then null else . end end') || out=null
  [ "$out" = null ] && out=""
  printf '%s' "$out"
}

# The field tables, as jq: CLADE (clade-to-repo-deed.adoc §3) and the two
# STATE extracts (state-v1-decision.adoc option B, §3; maturity per
# vocabulary/maturity.adoc). "chora" and "state" name the target deeds.
# shellcheck disable=SC2016  # jq programs: the $ names are jq variables
JQ_COMMON='
  def norm: if .[0] == "list" then (.[1] | map(norm)) elif .[0] == "boolean" then (.[1] == "#t")
            elif .[0] == "integer" then (.[1] | tonumber) else .[1] end;
  def clauses($items; $n): [$items[] | select(.[0] == "clause" and .[1] == $n) | .[2]];
  def field($items; $n): first($items[] | select(.[0] == "field" and .[1] == $n) | {v: (.[2] | norm)}) // null;
  def lookup($items; $path):
    if ($path | length) == 1 then field($items; $path[0])
    else ($path[0]) as $h
      | (if ($h | type) == "object" then clauses($items; $h.c)[$h.i] else clauses($items; $h)[0] end) as $sub
      | if $sub == null then null else lookup($sub; $path[1:]) end end;
  def items($ast): if $ast == null then null else $ast.items end;
  # CHORA-SPEC 11.2 (CA1): (clade (placement :scheme :category :primary #t | :rank n) …).
  # A chora still in the withdrawn flat form (read with a warning for one
  # release) is looked up by path, as before.
  def placed($its; $r):
    (clauses($its; "clade")[0]) as $cl
    | if $cl == null then null
      else [clauses($cl; "placement")[] | select(field(.; "scheme").v == "clade-12")
            | {c: field(.; "category").v, p: ((field(.; "primary") // {v: false}).v),
               r: ((field(.; "rank") // {v: null}).v)}] as $ps
      | if ($ps | length) == 0 then lookup($its; $r.p)
        elif $r.placement == "primary" then ($ps | map(select(.p)) | if length == 1 then {v: .[0].c} else null end)
        else {v: ($ps | map(select(.p | not)) | sort_by(.r) | map(.c))} end end;
  def compare($facts; $chora; $state):
    [ $facts[] | . as $f | ($f.path | route) as $r
      | if $r.skip then empty
        elif $r.drop then {s: "dropped"}
        elif $r.unlisted then {s: "unlisted"}
        else (if $r.deed == "chora" then items($chora) else items($state) end) as $its
          | (if $its == null then null elif $r.placement then placed($its; $r) else lookup($its; $r.p) end) as $got
          | {s: (if $got != null and $got.v == $f.value then "present" else "missing" end),
             legacy: ($r.deed == "state" and ($chora != null) and ((lookup($chora.items; $r.p) // {v: null}).v == $f.value))}
        end ]
    | {checked: length, present: map(select(.s == "present")) | length,
       dropped: map(select(.s == "dropped")) | length,
       unlisted: map(select(.s == "unlisted")) | length,
       missing: map(select(.s == "missing" or .s == "unlisted")) | length,
       legacy_chora: map(select(.s == "missing" and .legacy)) | length};'
JQ_CLADE='
  def route:
    if . == "identity.uuid" then {drop: true}
    elif . == "identity.canonical-name" then {deed: "chora", p: ["canonical-name"]}
    elif . == "identity.primary-forge" then {deed: "chora", p: ["identity", "primary-forge"]}
    elif . == "identity.primary-owner" then {deed: "chora", p: ["identity", "owner"]}
    elif . == "identity.prefixed-name" then {deed: "chora", p: ["identity", "prefixed-name"]}
    elif . == "clade.primary" then {deed: "chora", placement: "primary", p: split(".")}
    elif . == "clade.secondary" then {deed: "chora", placement: "ranked", p: split(".")}
    elif test("^clade\\.(primary-name|assigned|rationale)$") then {drop: true}
    elif test("^forges\\.(github|gitlab|bitbucket)$")
      or test("^lineage\\.(type|parent|born|previous-names|instantiated-from)$") then {deed: "chora", p: split(".")}
    elif test("^status\\.history\\[[0-9]+\\]\\.(phase|since|note)$") then
      (capture("^status\\.history\\[(?<i>[0-9]+)\\]\\.(?<f>.*)$")
       | {deed: "state", p: ["status", {c: "history", i: 0}, {c: "entry", i: (.i | tonumber)}, .f]})
    elif test("^status\\.(phase|since|present|aliases|merged-into|superseded-by|successors|ended)$") then {deed: "state", p: split(".")}
    else {unlisted: true} end;'
JQ_STATE='
  def route:
    if . == "position.phase" then {deed: "state", p: ["status", "phase"]}
    elif . == "position.maturity" then {deed: "state", p: ["maturity", "level"]}
    else {skip: true} end;'

# ── pass 2: targets, conditions, blockers, class ──────────────────────────
S=$'\x1f'
declare -A RULIDS=() DROPPED=() DECIDED=() REQS=() RECS=() RBLOCK=()
while IFS=$'\x1f' read -r p id kind key req rec; do
  RULIDS[$p]+="$id$S"
  case $kind in
    dropped) DROPPED[$p]=1; [ -n "$req" ] && REQS[$p]+="ruling-condition:$req$S"
             [ -n "$rec" ] && RECS[$p]+="$rec$S" ;;
    decision) DECIDED[$p]=1; [ -n "$rec" ] && RECS[$p]+="$rec$S" ;;
    spec-gap) RBLOCK[$p]+="gap:spec-gap:$key$S" ;;
    ruling-needed) RBLOCK[$p]+="ruling-needed:$key$S" ;;
    pending) RBLOCK[$p]+="pending:$key$S" ;;
    external-reader) RBLOCK[$p]+="external-reader:$key$S" ;;
  esac
done < "$T/rul.tsv"

# named_in PATH FILE: FILE names PATH exactly (not as part of a longer path)
named_in() {
  local re
  [ -f "$2" ] || return 1
  re=$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g')
  grep -qE "(^|[^A-Za-z0-9_./-])$re([^A-Za-z0-9_./-]|$)" "$2"
}
has() { local x; for x in "${blockers[@]}"; do case $x in "$1"*) return 0 ;; esac; done; return 1; }
: > "$T/out.tsv"
while IFS=$'\x1f' read -r p fam spec base uncl; do
  family=$fam; blockers=(); targets=(); facts=null; note=""; ftruth=null; ltruth=null; summary_only=""
  chora=""; [ -z "$uncl" ] && chora=$(base_chora "$base")
  if [ "$chora" = MULTI ]; then uncl="several <name>_chora.deed files in '${base:-.}'"; chora=""; fi
  D="${base:+$base/}.machine_readable/descriptiles"
  CH="${chora:-${base:+$base/}<name>_chora.deed}"

  if [ -z "$uncl" ] && [ "$fam" != none ]; then
    # target groups: alternatives joined by |; an alternative is FILE or FILE#clause
    case $fam in
      CLADE) groups=("$CH" "$D/STATE.deed") ;;
      META|AGENTIC|NEUROSYM|STATE) groups=("$D/$fam.deed") ;;
      ECOSYSTEM) groups=("$D/ECOSYSTEM.deed|$CH#ecosystem") ;;
      PLAYBOOK) groups=("$CH#playbook") ;;
      BOT-DIRECTIVES) groups=("$CH#bot-directives") ;;
      AI-MANIFEST) groups=("$CH#manifest") ;;
      SCORECARD)
        if [ "${p##*/}" = rsr.scorecard.a2ml ]; then groups=("${base:+$base/}.machine_readable/scorecards/rsr-scorecard_praxis.deed")
        else groups=("$CH#assessment"); fi ;;
      RSR-CRITERIA) groups=("0-canon/rsr/rsr-criteria-v2_praxis.deed") ;;
    esac
    missing_groups=(); invalid=()
    for g in "${groups[@]}"; do
      sat=0; IFS='|' read -r -a alts <<< "$g"
      for a in "${alts[@]}"; do
        tp=${a%%#*}; cl=""; [ "$tp" != "$a" ] && cl=${a#*#}
        ex=false; lint=""; cp=""
        if [ -f "$ROOT/$tp" ]; then
          ex=true; lint_deed "$tp" "$base"; lint=$LINT
          if [ "$lint" = fail ]; then invalid+=("$tp"); fi
          if [ -n "$cl" ]; then
            ast_file "$tp"; cp=false
            if [ -n "$AST" ] && has_clause "$AST" "$cl"; then cp=true; fi
            [ "$cp" = true ] && [ "$lint" = ok ] && sat=1
          else
            [ "$lint" = ok ] && sat=1
          fi
        fi
        targets+=("$tp$S$cl$S$ex$S$lint$S$cp")
      done
      [ "$sat" = 1 ] || missing_groups+=("$g")
    done
    for t in "${invalid[@]}"; do
      blockers+=("lint-fail:$t")
    done
    if [ "${#invalid[@]}" -gt 0 ]; then ltruth=false; elif [ "${#targets[@]}" -gt 0 ]; then ltruth=true; fi

    compare=""
    case $fam in
      CLADE) compare=$JQ_CLADE ;;
      STATE) [ -n "${DECIDED[$p]:-}" ] && compare=$JQ_STATE ;;
      SCORECARD) [ -n "${DECIDED[$p]:-}" ] && compare=none ;;
    esac
    if [ "$compare" = none ]; then
      # The decision drops the per-criterion facts on purpose: nothing is
      # translated. The summary still has a target (an (assessment) clause, or
      # the RSR praxis deed), and nothing here compares its content. So an
      # absent target blocks, a present one leaves the file unchecked, and a
      # file on this path is never deletable-now unless a ruling drops it.
      facts='{"checked":0,"dropped":0,"legacy_chora":0,"missing":0,"present":0,"unlisted":0}'
      if [ "${#missing_groups[@]}" -gt 0 ]; then
        ftruth=false
        for g in "${missing_groups[@]}"; do blockers+=("no-target-deed:$g"); done
      else
        note=${note:-"the target exists, but the summary it holds is not compared with this record here"}
        blockers+=("facts-unchecked:$family")
      fi
      summary_only=1
    elif [ -n "$compare" ]; then
      fj=$(facts_json "$ROOT/$p")
      cast=""; sast=""
      if [ "${#invalid[@]}" -gt 0 ]; then
        note="a target deed fails deed_lint, so its facts cannot be read"
      elif [ -z "$fj" ]; then
        note="the record has a shape this reader does not read (not TOML-shaped)"
      else
        [ -n "$chora" ] && [ -f "$ROOT/$chora" ] && { ast_file "$chora"; cast=$AST; }
        [ -f "$ROOT/$D/STATE.deed" ] && { ast_file "$D/STATE.deed"; sast=$AST; }
        facts=$(jq -n -c -S --argjson f "$fj" \
          --slurpfile c "${cast:-/dev/null}" --slurpfile s "${sast:-/dev/null}" \
          "$compare $JQ_COMMON compare(\$f; (\$c[0] // null); (\$s[0] // null))")
      fi
    fi

    if [ -n "$summary_only" ]; then
      :  # settled above
    elif [ "$facts" != null ]; then
      fm=$(jq -r '.missing' <<< "$facts")
      if [ "$fm" -gt 0 ]; then ftruth=false; blockers+=("facts-missing:$fm"); else ftruth=true; missing_groups=(); fi
      if [ "$fm" -gt 0 ]; then
        # name the absent target deeds only when the comparison needed them
        for g in "${missing_groups[@]}"; do blockers+=("no-target-deed:$g"); done
        blockers+=("needs-kyx:$fam")
      fi
    elif [ -n "$compare" ]; then
      blockers+=("facts-unchecked:$family")
    elif [ "${#missing_groups[@]}" -gt 0 ]; then
      ftruth=false
      for g in "${missing_groups[@]}"; do blockers+=("no-target-deed:$g"); done
      blockers+=("needs-kyx:$fam")
    else
      note=${note:-"the target deeds exist, but this family's facts are not compared mechanically here"}
      blockers+=("facts-unchecked:$family")
    fi
  elif [ -z "$uncl" ]; then
    blockers+=("no-mapping-spec")
  fi

  # An owner ruling that drops the file settles conditions 1 and 2.
  if [ -n "${DROPPED[$p]:-}" ]; then blockers=(); ftruth=true; ltruth=null; fi
  if [ -n "${REQS[$p]:-}" ]; then IFS="$S" read -r -a extra <<< "${REQS[$p]}"; blockers+=("${extra[@]}"); fi
  # A dropped row may require a record line naming the exact path in a file of the tree.
  if [ -n "${RECS[$p]:-}" ]; then
    IFS="$S" read -r -a extra <<< "${RECS[$p]}"
    for rec in "${extra[@]}"; do
      named_in "$p" "$ROOT/$rec" || blockers+=("record-missing:$rec")
    done
  fi
  if [ -n "${RBLOCK[$p]:-}" ]; then
    IFS="$S" read -r -a extra <<< "${RBLOCK[$p]}"
    for b in "${extra[@]}"; do
      case $b in
        gap:*) [ "$ftruth" = true ] || blockers+=("${b#gap:}") ;;  # a gap matters only while facts are missing
        *) blockers+=("$b") ;;
      esac
    done
  fi

  # Condition 3: readers in this tree.
  bn=${p##*/}; rx=""; rn=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    blockers+=("reader:$r"); rx+="$r$S"
  done <<< "${RX[$p]:-}"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$S$rx" in *"$S$r$S"*) continue ;; esac
    blockers+=("name-reader:$r"); rn+="$r$S"
  done <<< "${RN[$bn]:-}"

  # Class, from the blockers.
  mapfile -t blockers < <(printf '%s\n' "${blockers[@]}" | grep . | LC_ALL=C sort -u || true)
  readerish=1
  for b in "${blockers[@]}"; do case $b in reader:*|name-reader:*|external-reader:*) ;; *) readerish=0 ;; esac; done
  if [ -n "$uncl" ]; then class="unclassified"; note=$uncl
  elif [ "${#blockers[@]}" -eq 0 ]; then class="deletable-now"
  elif [ "$readerish" = 1 ]; then class="covered-but-read"
  elif [ -n "${DROPPED[$p]:-}" ] || [ -n "${DECIDED[$p]:-}" ]; then class="decision-drops"
  elif [ "$fam" = none ]; then class="no-mapping-spec"
  elif [ -z "$chora" ]; then class="no-target-deed"
  elif has facts-unchecked:; then class="facts-unchecked"
  elif has needs-kyx:; then
    if [ -n "${KYX[$fam]:-}" ]; then class="needs-kyx-supported"; else class="needs-kyx-unsupported"; fi
  else class="ruling-needed"
  fi
  rtruth=true; for b in "${blockers[@]}"; do case $b in reader:*|name-reader:*|external-reader:*) rtruth=false ;; esac; done

  bytes=$(wc -c < "$ROOT/$p" | tr -d ' ')
  tj=$(printf '%s\n' "${targets[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\u001f")
        | {path: .[0], exists: (.[2] == "true")} + (if .[1] != "" then {clause: .[1], clause_present: (.[4] == "true")} else {} end)
        + (if .[3] != "" then {lint: .[3]} else {} end))')
  bj=$(printf '%s\n' "${blockers[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  printf '%s\t' "$p" "$bytes" "$fam" "$spec" "$chora" "$class" "$note" "$ftruth" "$ltruth" "$rtruth" \
    "$(printf '%s' "${RULIDS[$p]:-}" | tr "$S" '\n' | grep . | LC_ALL=C sort -u | tr '\n' "$S")" "$rx" "$rn" "$facts" "$tj" >> "$T/out.tsv"
  printf '%s\n' "$bj" >> "$T/out.tsv"
done < "$T/fam.tsv"

jq -R -c -S 'split("\t") as $c
  | def lst($s): $s | split("\u001f") | map(select(length > 0));
    def tri($s): if $s == "null" then null else ($s == "true") end;
  {path: $c[0], bytes: ($c[1] | tonumber), family: $c[2],
   mapping_spec: (if $c[3] == "" then null else $c[3] end),
   base_chora: (if $c[4] == "" then null else $c[4] end),
   class: $c[5], note: (if $c[6] == "" then null else $c[6] end),
   conditions: {facts: tri($c[7]), lint: tri($c[8]), readers: tri($c[9])},
   rulings: lst($c[10]), readers: {path: lst($c[11]), name: lst($c[12])},
   facts: ($c[13] | fromjson), target_deeds: ($c[14] | fromjson), blockers: ($c[15] | fromjson)}' \
  "$T/out.tsv" > "$T/out.jsonl"

# ── output ────────────────────────────────────────────────────────────────
CLASSES=(deletable-now covered-but-read needs-kyx-supported needs-kyx-unsupported no-target-deed \
  facts-unchecked ruling-needed decision-drops no-mapping-spec unclassified)

# The live counts (JCS): per class and per blocker kind, each a count of
# files out of `total`, and the deletable-now paths.
counts_json() {
  jq -s -c -S --argjson classes "$(printf '%s\n' "${CLASSES[@]}" | jq -R . | jq -s -c .)" '
    {total: length,
     classes: ([$classes[] as $c | {key: $c, value: (map(select(.class == $c)) | length)}] | from_entries),
     blocker_kinds: ([.[] | [.blockers[] | sub(":.*$"; "")] | unique[]] | group_by(.)
                     | map({key: .[0], value: length}) | from_entries),
     deletable_now: [.[] | select(.class == "deletable-now") | .path]}' "$T/out.jsonl"
}
# The command that regenerates the counts file with the same inputs.
regen_cmd() {
  local cmd="bash scripts/a2ml-retire-check.sh" r
  [ "$ROOT" = "$PWD" ] || cmd+=" --root $ROOT"
  [ -z "$REPO_ARG" ] || cmd+=" --repo $REPO_ARG"
  for r in "${RULINGS_ARG[@]}"; do cmd+=" --rulings $r"; done
  [ -z "$COUNTS_ARG" ] || cmd+=" --counts $COUNTS_ARG"
  printf '%s --write-counts' "$cmd"
}

case $MODE in
  json) cat "$T/out.jsonl" ;;
  write-counts)
    mkdir -p "$(dirname "$COUNTS")"
    counts_json > "$COUNTS"
    echo "a2ml-retire-check: wrote $COUNTS ($N file(s); $RULINGS_NOTE)" ;;
  table)
    jq -r '[.class, .path, (.blockers | join(", "))] | @tsv' "$T/out.jsonl" \
      | awk -F'\t' '{ printf "%-22s %s\n%22s   %s\n", $1, $2, "", ($3 == "" ? "(no blockers)" : $3) }'
    echo "a2ml-retire-check: $N file(s); $RULINGS_NOTE" ;;
  summary)
    echo "a2ml-retire-check: $N tracked A2ML file(s) under $ROOT; $RULINGS_NOTE"
    echo "by class:"
    for c in "${CLASSES[@]}"; do
      n=$(jq -r --arg c "$c" 'select(.class == $c) | .path' "$T/out.jsonl" | grep -c . || true)
      echo "  $c $n of $N"
    done
    echo "by blocker kind (files carrying it):"
    jq -r '[.blockers[] | sub(":.*$"; "")] | unique[]' "$T/out.jsonl" | sort | uniq -c \
      | awk -v n="$N" '{ printf "  %s %d of %d\n", $2, $1, n }'
    echo "by blocker (other than readers):"
    jq -r '.blockers[] | select(test("^(reader|name-reader):") | not)' "$T/out.jsonl" | sort | uniq -c \
      | awk -v n="$N" '{ printf "  %s %d of %d\n", $2, $1, n }' ;;
  check)
    failed=0
    n_deletable=$(jq -r 'select(.class == "deletable-now") | .path' "$T/out.jsonl" | grep -c . || true)
    n_uncl=$(jq -r 'select(.class == "unclassified") | .path' "$T/out.jsonl" | grep -c . || true)
    if [ "$n_deletable" -gt 0 ]; then
      failed=1
      echo "::error::$n_deletable A2ML file(s) meet all three deletion conditions, so they must go (one owner-visible commit each):"
      while IFS= read -r p; do
        echo "  git rm -- $p"
        if [ -f "$ROOT/$LEDGER_REL" ]; then
          grep -nxF -- "$p" "$ROOT/$LEDGER_REL" | sed "s|^\([0-9]*\):|  delete $LEDGER_REL:\1: |" || true
        fi
      done < <(jq -r 'select(.class == "deletable-now") | .path' "$T/out.jsonl")
    fi
    if [ "$n_uncl" -gt 0 ]; then
      failed=1
      echo "::error::$n_uncl A2ML file(s) could not be classified:"
      jq -r 'select(.class == "unclassified") | "  \(.path): \(.note)"' "$T/out.jsonl"
    fi
    # The live counts must be what the tree gives now.
    if [ ! -f "$COUNTS" ]; then
      failed=1; echo "::error::no counts file at $COUNTS: run $(regen_cmd)"
    elif ! jq -e -n --slurpfile a "$COUNTS" --argjson b "$(counts_json)" '$a == [$b]' >/dev/null 2>&1; then
      failed=1; echo "::error::counts are stale: $COUNTS differs from the tree; run $(regen_cmd)"
    fi
    # The ratchet (--base REV): no A2ML path may join. A path tracked now must
    # have been tracked at REV, or be an unchanged rename (git R100) of one, so
    # the total can only fall. Class counts are not ratcheted: files move
    # between blocked classes as rulings land and readers change.
    if [ -n "$BASE_REV" ]; then
      git -C "$ROOT" rev-parse --verify -q "$BASE_REV^{commit}" >/dev/null || die "--base $BASE_REV does not resolve to a commit in $ROOT"
      git -C "$ROOT" ls-tree -r -z --name-only "$BASE_REV" | tr '\0' '\n' | grep -E "$A2ML_RE" | LC_ALL=C sort > "$T/base" || true
      declare -A renamed=()
      while IFS= read -r -d '' st && IFS= read -r -d '' old && IFS= read -r -d '' new; do
        [ "$st" = R100 ] && renamed[$new]="$old"
      done < <(git -C "$ROOT" diff -z --find-renames=100% --diff-filter=R --name-status "$BASE_REV" 2>/dev/null)
      joined=()
      while IFS= read -r p; do
        if [ -n "${renamed[$p]:-}" ] && grep -qxF -- "${renamed[$p]}" "$T/base"; then continue; fi
        joined+=("$p")
      done < <(LC_ALL=C comm -13 "$T/base" "$T/a2ml")
      nb=$(grep -c . "$T/base" || true)
      if [ "${#joined[@]}" -gt 0 ]; then
        failed=1
        echo "::error::${#joined[@]} A2ML path(s) joined since $BASE_REV ($nb then, $N now); A2ML only shrinks:"
        printf '  %s\n' "${joined[@]}"
      fi
    fi
    [ "$failed" -eq 0 ] || exit 1
    echo "a2ml-retire-check: OK ($N file(s); none deletable now, none unclassified; counts current${BASE_REV:+; no A2ML path joined since $BASE_REV}; $RULINGS_NOTE)" ;;
esac
