#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Reference checker for the RSR template-applicability model.
# Policy: ../TEMPLATE-APPLICABILITY-POLICY.adoc
# Data:   ../.machine_readable/template-capability-gates.toml
#
# Reads a target repo's (rsr-profile …) clause from its <repo>_chora.deed (or,
# as a legacy fallback, .machine_readable/rsr-profile.a2ml), resolves its
# effective capability set (preset capabilities + add - remove) against the
# gate table, and reports gated modules that are:
#   VESTIGIAL — present but the repo does not declare the gating capability.
#   MISSING   — the capability is declared but the module is absent.
# and the always-carried baseline files that are:
#   MISSING BASELINE — the policy says every repo carries it; this one does not.
#
# [baseline] had no reader at all until #1227: `grep -c baseline` on this file
# returned 0, so the table's "Always carried" rows were asserted by no
# executable and a repo could pass while missing its LICENSE.
#
# Usage: check-rsr-profile.sh [REPO_DIR] [owner/repo]
# Set RSR_REPOSITORY instead of the second argument to enforce the live
# Actions policy alongside the local capability profile.
# Exit:  0 OK | 1 violations | 2 setup error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATES="${RSR_GATES:-$SCRIPT_DIR/../.machine_readable/template-capability-gates.toml}"
REPO="${1:-.}"
LIVE_REPOSITORY="${2:-${RSR_REPOSITORY:-}}"
# The machine tree is `.machine_readable/` — canonical estate-wide by owner
# ruling (2026-09-17), and the spelling this repository has always used.
#
# This comment previously called the hyphenated form canonical "since 2026-08"
# and the dotted form LEGACY. The direction was wrong. The census in
# rsr-template-repo's docs/governance/TEMPLATE-LINEAGE-AUDIT.adoc records 48
# repositories on the dotted form against 9 hyphenated at the 2026-08
# divergence: un-hiding a quarter of one repo did not move the estate, and
# this file's own tolerance branch was the only evidence ever offered for it.
#
# The hyphenated branch is KEPT deliberately. It is not legacy scurf to be
# deleted once "the migration completes" — roughly 9 repos still carry it, and
# this checker is shared, so it must resolve both rather than fail either.
PROFILE="$REPO/.machine_readable/rsr-profile.a2ml"
[ -f "$PROFILE" ] || PROFILE="$REPO/machine-readable/rsr-profile.a2ml"

[ -f "$GATES" ] || { echo "ERROR: gates file not found: $GATES" >&2; exit 2; }

# --- the deed form: (rsr-profile …) in the repo's one <repo>_chora.deed ---
# A2ML is retired (D312/D313). The worked model, rsr-template-repo_chora.deed,
# carries its profile as an (rsr-profile …) clause of the repo deed (it has no
# .a2ml at all since rsr-template-repo#227), so the reference checker must
# read that clause or it cannot score the very repo the policy is modelled on.
# Resolution: the deed clause when the repo has exactly one *_chora.deed and
# that deed carries exactly one (rsr-profile …); else the .a2ml, as a LEGACY
# fallback for repos that have not folded their profile yet. Two deeds, or two
# clauses, is a defect, not a choice to make silently (same rule as deed_canon
# in check-canon-lockstep.sh).
#
# deed_strip <file>: the deed as one line with comments removed. A ";" outside
# a string starts a comment to line-end (deed.abnf); inside a string it is
# text. Same tokenizer as deed_canon, kept byte-identical there.
deed_strip() {
  awk 'BEGIN { bs = sprintf("%c", 92); dq = sprintf("%c", 34) } { o = ""; q = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (q && c == bs) { o = o c substr($0, i + 1, 1); i++; continue } if (c == dq) q = !q; else if (!q && c == ";") break; o = o c } printf "%s ", o }' "$1"
}
# deed_clause <head> : on stdin the stripped deed; prints each balanced
# "(<head> …)" form, one per line, nested forms included (lists and (notes …)
# sit inside the profile clause, so a flat [^()]* match cannot reach it).
# The outer scan tracks string state too: a "(rsr-profile …)" quoted inside
# a (notes …) is prose, not a clause, and must not be read as one.
deed_clause() {
  awk -v head="$1" 'BEGIN { dq = sprintf("%c", 34); bs = sprintf("%c", 92) }
  { s = $0; n = length(s); i = 1; inq = 0
    while (i <= n) {
      c0 = substr(s, i, 1)
      if (inq) { if (c0 == bs) i++; else if (c0 == dq) inq = 0; i++; continue }
      if (c0 == dq) { inq = 1; i++; continue }
      if (substr(s, i, length(head) + 1) == "(" head && substr(s, i + length(head) + 1, 1) ~ /[[:space:])]/) {
        d = 0; q = 0; o = ""
        for (j = i; j <= n; j++) { c = substr(s, j, 1)
          if (q && c == bs) { o = o c substr(s, j + 1, 1); j++; continue }
          if (c == dq) q = !q
          o = o c
          if (!q) { if (c == "(") d++; else if (c == ")") { d--; if (d == 0) break } } }
        print o; i = j + 1
      } else i++ } }'
}
# deed_fields : on stdin one comment-free clause on a single line, as emitted
# by deed_clause; prints the clause's OWN fields, one per
# line, tab-separated: "S key value" for a string, "Y key value" for a symbol
# or boolean, "U key body" for a uuid literal, "L key item" for each list item
# (strings unquoted), "LU key body" for a uuid literal inside a list (never a
# capability) and "E key" for an empty list. It walks tokens, so text
# inside a string is never read as a field, a sub-clause such as (notes …) is
# skipped whole. A key that repeats keeps its first value. Earlier regex
# readers leaked each of these.
# Escaped quotes and backslashes are decoded; other escapes stay literal.
# This extracts fields without validating DEED syntax.
deed_fields() {
  awk 'BEGIN { dq = sprintf("%c", 34); bs = sprintf("%c", 92); OFS = "\t" }
  # Return the string at s[i] and advance i past its closing quote, or return
  # the accumulated value without an error if the input ends first.
  function rstr(   v, e, x) { v = ""; i++
    while (i <= n) { e = substr(s, i, 1)
      # Only an escaped quote or backslash decodes. Every other escape stays
      # as written, backslash included: decoding the n, t or an unknown
      # escape to its bare letter would make "spi" + escaped n + "e" read as
      # spine. A real newline or tab would also break the one-field-per-line
      # output. Rejecting a malformed escape is the job of the deed lint.
      if (e == bs) { x = substr(s, i + 1, 1); v = v ((x == dq || x == bs) ? x : e x); i += 2; continue }
      if (e == dq) { i++; return v }
      v = v e; i++ }
    return v }
  # Return the atom at s[i], leaving i at its delimiter or the end of input.
  # Whitespace, parentheses and quotes delimit atoms; an empty atom is allowed.
  function ratom(   v, e) { v = ""
    while (i <= n) { e = substr(s, i, 1); if (e ~ /[[:space:]()]/ || e == dq) break; v = v e; i++ }
    return v }
  # Advance i past the parenthesized form at s[i], ignoring parentheses in
  # strings; consume the remaining input if the form is unbalanced.
  function skip(   d, e) { d = 0
    while (i <= n) { e = substr(s, i, 1)
      if (e == dq) { rstr(); continue }
      if (e == "(") d++; else if (e == ")") { d--; if (d == 0) { i++; return } }
      i++ } }
  # Print kind, the current key and v as tab-separated fields unless dup marks
  # a repeated key.
  function emit(kind, v) { if (!dup) print kind, key, v }
  { s = $0; n = length(s); i = 1
    while (i <= n && substr(s, i, 1) != "(") i++
    i++; ratom(); key = ""
    while (i <= n) { c = substr(s, i, 1)
      if (c ~ /[[:space:]]/) { i++; continue }
      if (c == ")") break
      if (c == dq) { v = rstr(); if (key != "") emit("S", v); key = ""; continue }
      if (c == "(") {
        if (key == "") { skip(); continue }
        i++; cnt = 0
        while (i <= n) { c = substr(s, i, 1)
          if (c ~ /[[:space:]]/) { i++; continue }
          if (c == ")") { i++; break }
          if (c == "(") { skip(); continue }
          if (c == dq) emit("L", rstr())
          else { a = ratom(); if (a ~ /^#u[0-9]+$/ && substr(s, i, 1) == dq) emit("LU", rstr()); else emit("L", a) }
          cnt++ }
        if (!cnt && !dup) print "E", key
        key = ""; continue }
      a = ratom()
      if (a == "") { i++; continue }
      if (substr(a, 1, 1) == ":") { key = substr(a, 2); dup = (key in seen); seen[key] = 1; continue }
      if (key != "") { if (a ~ /^#u[0-9]+$/ && substr(s, i, 1) == dq) emit("U", rstr()); else emit("Y", a) }
      key = "" }
    exit }'
}
# deed_ast_fields <deed> : the same field lines as deed_fields, built from
# the validated AST of the normative parser (deed_lint.js --ast-json, #1374)
# instead of the awk tokenizer. The AST decodes every escape; a decoded
# newline or tab is written back as the two characters \n or \t, so both
# paths emit identical lines. A deed that does not parse fails here, closed.
deed_ast() {
  local ast deed tooldir
  deed="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  tooldir="$(cd "$(dirname "$DEED_LINT")" && pwd)"
  # Bun reads bunfig.toml, preload included, from its working directory, and
  # the caller's tree is untrusted, so the parser runs from its own directory.
  ast="$(cd "$tooldir" && bun "./$(basename "$DEED_LINT")" --ast-json "$deed" 2>&1)" || {
    echo "ERROR: $1 does not parse as DEED: $ast" >&2; return 2; }
  printf '%s' "$ast"
}
deed_ast_fields() {
  local ast
  ast="${DEED_AST:-$(deed_ast "$1")}" || return 2
  printf '%s' "$ast" | jq -r '
    def s: gsub("\n"; "\\n") | gsub("\t"; "\\t");
    def atom: .[0] | IN("symbol", "integer", "boolean");
    def uuid: .[0] | IN("uuid5", "uuid8");
    [.. | arrays | select(.[0] == "clause" and .[1] == "rsr-profile")] as $c
    | if ($c | length) > 1 then "COUNT\t\($c | length)"
      elif ($c | length) == 0 then "COUNT\t0"
      else
        "COUNT\t1",
        ($c[0][2]
         | reduce .[] as $it ({seen: {}, out: []};
             if $it[0] == "field" and (.seen[$it[1]] | not)
             then .seen[$it[1]] = true | .out += [$it] else . end)
         | .out[] | .[1] as $k | .[2] as $v
         | if $v[0] == "string" then "S\t\($k)\t\($v[1] | s)"
           elif ($v | atom) then "Y\t\($k)\t\($v[1])"
           elif ($v | uuid) then "U\t\($k)\t"
           elif $v[0] == "list" then
             (if ($v[1] | length) == 0 then "E\t\($k)" else
               ($v[1][] | if .[0] == "string" then "L\t\($k)\t\(.[1] | s)"
                          elif atom then "L\t\($k)\t\(.[1])"
                          elif uuid then "LU\t\($k)\t"
                          else empty end) end)
           else empty end)
      end'
}
# deed_scalar <key> : field lines on stdin; print the first :<key> value
# followed by a newline if it is a string, otherwise nothing.
deed_scalar() { awk -F '\t' -v k="$1" '$1 == "S" && $2 == k && !done { print $3; done = 1 }'; }
# deed_list <key> : field lines on stdin; print the first :<key> list's items,
# strings unquoted, symbols as written, one per line. UUID literals and nested
# lists are omitted; absent, empty or non-list values produce no output.
deed_list() { awk -F '\t' -v k="$1" '$1 == "L" && $2 == k { print $3 }'; }

# Which parser reads the deed. RSR_DEED_PARSER=auto (the default) uses the
# validated AST when Bun and deed_lint.js are both present, and otherwise the
# awk tokenizer, with a notice naming the fallback. =ast requires the AST and
# is a setup error without it; =awk forces the tokenizer. The two produce the
# same field lines: scripts/tests/check-rsr-profile-test.sh runs its whole
# suite under each and asserts the same verdicts.
DEED_LINT="${DEED_LINT:-$SCRIPT_DIR/../1-formats/deed/tools/deed_lint.js}"
DEED_PARSER="${RSR_DEED_PARSER:-auto}"
case "$DEED_PARSER" in
  auto)
    if command -v bun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -f "$DEED_LINT" ]; then
      DEED_PARSER="ast"
    else
      DEED_PARSER="awk"
    fi ;;
  ast)
    command -v bun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -f "$DEED_LINT" ] || {
      echo "ERROR: RSR_DEED_PARSER=ast needs bun, jq and $DEED_LINT" >&2; exit 2; } ;;
  awk) ;;
  *) echo "ERROR: RSR_DEED_PARSER must be auto, ast or awk (got '$DEED_PARSER')" >&2; exit 2 ;;
esac

# The (rsr-profile …) keys are owned by one grammar,
# 1-formats/deed/spec/abnf/clauses/rsr-profile.abnf (A7 J39), and an unknown
# key refuses the clause rather than being skipped. The AST path asks the
# module's own checker (deed_lint.js --rsr-profile). The awk path checks this
# copy, which scripts/tests/check-rsr-profile-test.sh holds equal to
# `deed_lint.js --rsr-profile-keys`.
RSR_PROFILE_KEYS=":version :spec :declares-against :role :preset :capabilities :add :remove (notes) (layout)"
# deed_subclauses : on stdin one comment-free clause on a single line, as
# emitted by deed_clause; prints the head of each clause nested directly in
# it, one per line. A parenthesis right after a :keyword opens that field's
# list value, not a clause, and parentheses inside strings are text.
deed_subclauses() {
  awk 'BEGIN { dq = sprintf("%c", 34); bs = sprintf("%c", 92) }
  { s = $0; n = length(s); d = 0; q = 0; kw = 0
    for (i = 1; i <= n; i++) { c = substr(s, i, 1)
      if (q) { if (c == bs) i++; else if (c == dq) { q = 0; if (d == 1) kw = 0 } continue }
      if (c == dq) { q = 1; continue }
      if (c ~ /[[:space:]]/) continue
      if (c == "(") { d++
        if (d == 2) {
          if (kw) { kw = 0; continue }
          h = ""; j = i + 1
          while (j <= n && substr(s, j, 1) !~ /[[:space:]()]/ && substr(s, j, 1) != dq) { h = h substr(s, j, 1); j++ }
          print h } }
      else if (c == ")") d--
      else if (d == 1) {
        a = ""; while (i <= n && substr(s, i, 1) !~ /[[:space:]()]/ && substr(s, i, 1) != dq) { a = a substr(s, i, 1); i++ }
        i--; kw = (substr(a, 1, 1) == ":") } }
    exit }'
}
# deed_notes_faults : on stdin one comment-free (rsr-profile …) clause on a
# single line; prints one line per fault inside its (notes …): anything but
# :<name> "…" pairs (a nested clause, a list, a bare value, a dangling key) or
# a name given twice. Prints nothing when every (notes …) is prose only.
deed_notes_faults() {
  awk 'BEGIN { dq = sprintf("%c", 34); bs = sprintf("%c", 92) }
  function atom(   a) { a = ""
    while (i <= n && substr(s, i, 1) !~ /[[:space:]()]/ && substr(s, i, 1) != dq) { a = a substr(s, i, 1); i++ }
    return a }
  { s = $0; n = length(s); d = 0; q = 0; innotes = 0; key = ""
    for (i = 1; i <= n; i++) { c = substr(s, i, 1)
      if (q) { if (c == bs) i++; else if (c == dq) q = 0; continue }
      if (c ~ /[[:space:]]/) continue
      if (c == dq) { q = 1
        if (innotes && d == 2) { if (key == "") print "a value with no :name"; key = "" }
        continue }
      if (c == "(") { d++
        if (d == 2) { i++; h = atom(); i--
          if (h == "notes") { innotes = 1; key = ""; split("", seen) } }
        else if (innotes && d == 3) print "a nested form"
        continue }
      if (c == ")") { if (innotes && d == 2) { if (key != "") print "a dangling :" key; innotes = 0 }; d--; continue }
      a = atom(); i--
      if (innotes && d == 2) {
        if (substr(a, 1, 1) == ":") {
          if (key != "") print "a non-string value for :" key
          key = substr(a, 2); if (key in seen) print "a repeated :" key; seen[key] = 1 }
        else { print "a bare value " a; key = "" } } }
    exit }'
}
# --- (layout …): where this repo keeps a gated module (owner ruling 2026-11-16,
# rsr-template-repo#421) ---
# The gate table names WHAT a capability owes and where it lives by default.
# Before this clause the defaults were the only locations the checker knew,
# so a repo that kept its ABI package at src/interface/abi.ipkg (the spine
# does) was MISSING a root abi.ipkg it was never meant to have, and the only
# "fixes" were moving the file or editing the canon's table. A
# (layout (module :gate "<row alternative>" :at ("<path>" …))) binds one row to
# the paths this tree uses, so the layout and the check cannot drift apart:
#   * declared capability: every :at path must exist (MISSING otherwise); the
#     row's default locations are not consulted, the deed is authoritative;
#   * undeclared capability: a present :at path, like a present default, is
#     VESTIGIAL ([carrier] still exempts a spine), and an absent one is STALE,
#     because a binding that names nothing is the drift this clause removes;
#   * an :at path is the same kind of artefact as the row names: the same file
#     name (a matching one for a glob row), and a directory for a directory row.
#     A binding that names no [gates] row, a [baseline] row, or a row twice is a
#     profile defect (exit 2), like an unknown preset.
#
# layout_bindings : on stdin one comment-free (rsr-profile …) clause on a
# single line, as emitted by deed_clause; prints "B<TAB>gate<TAB>path" for each
# :at path of each (module …) in its (layout …), in order, or one
# "F<TAB>reason" line for the first structural fault (the AST path asks the
# module, deed_lint.js --rsr-profile, for the same refusals). Strings decode
# only \" and \\, as deed_fields does; another escape stays literal and then
# fails layout_path_fault, as its decoded form does on the AST path.
layout_bindings() {
  awk 'BEGIN { dq = sprintf("%c", 34); bs = sprintf("%c", 92); OFS = "\t" }
  function fault(m) { print "F", m; exit }
  { s = $0; n = length(s); nt = 0; i = 1
    while (i <= n) { c = substr(s, i, 1)
      if (c ~ /[[:space:]]/) { i++; continue }
      if (c == "(" || c == ")") { tok[++nt] = c; i++; continue }
      if (c == dq) { v = ""; i++
        while (i <= n) { e = substr(s, i, 1)
          if (e == bs) { x = substr(s, i + 1, 1); v = v ((x == dq || x == bs) ? x : e x); i += 2; continue }
          if (e == dq) { i++; break }
          v = v e; i++ }
        tok[++nt] = "S" v; continue }
      v = ""; while (i <= n) { e = substr(s, i, 1); if (e ~ /[[:space:]()]/ || e == dq) break; v = v e; i++ }
      tok[++nt] = "A" v }
    # tok[1] "(" tok[2] "Arsr-profile"; walk its members at depth 1.
    t = 3; layouts = 0
    while (t <= nt && tok[t] != ")") {
      if (tok[t] == "(") {
        if (tok[t + 1] != "Alayout") { t = endof(t) + 1; continue }
        if (++layouts > 1) fault("(rsr-profile …) carries (layout …) once")
        t += 2; modules = 0
        while (t <= nt && tok[t] != ")") {
          if (tok[t] != "(" || tok[t + 1] != "Amodule") fault("(rsr-profile (layout …)) holds (module …) clauses only (J39: an unknown key refuses the clause)")
          t += 2; modules++; gate = ""; hasgate = 0; hasat = 0; na = 0; split("", at)
          while (t <= nt && tok[t] != ")") {
            k = tok[t]
            if (k == "A:gate") {
              if (hasgate++) fault("(rsr-profile (layout (module …))) carries :gate once")
              if (substr(tok[t + 1], 1, 1) != "S" || tok[t + 1] == "S") fault("(rsr-profile (layout (module :gate))) must be a non-empty string")
              gate = substr(tok[t + 1], 2); t += 2; continue }
            if (k == "A:at") {
              if (hasat++) fault("(rsr-profile (layout (module …))) carries :at once")
              if (tok[t + 1] != "(") fault("(rsr-profile (layout (module :at))) must be a non-empty list of strings")
              t += 2
              while (t <= nt && tok[t] != ")") {
                if (substr(tok[t], 1, 1) != "S") fault("(rsr-profile (layout (module :at))) must be a non-empty list of strings")
                p = substr(tok[t], 2)
                for (q = 1; q <= na; q++) if (at[q] == p) fault("(rsr-profile (layout (module :at))) names \"" p "\" once")
                at[++na] = p; t++ }
              if (na == 0) fault("(rsr-profile (layout (module :at))) must be a non-empty list of strings")
              t++; continue }
            if (k == "(") fault("(rsr-profile (layout (module …))) holds :gate and :at only")
            fault("(rsr-profile (layout (module …))) has no field " substr(k, 2) " (J39: an unknown key refuses the clause)") }
          if (!hasgate) fault("(rsr-profile (layout (module …))) is missing :gate")
          if (!hasat) fault("(rsr-profile (layout (module …))) is missing :at")
          if (gate in seen) fault("(rsr-profile (layout …)) binds :gate \"" gate "\" once")
          seen[gate] = 1
          for (q = 1; q <= na; q++) out[++no] = gate OFS at[q]
          t++ }
        if (!modules) fault("(rsr-profile (layout …)) binds at least one (module …)")
        t++; continue }
      # A keyword then its value; a list value is skipped whole.
      if (tok[t + 1] == "(") { t = endof(t + 1) + 1 } else t += 2 }
    for (q = 1; q <= no; q++) print "B", out[q]
    exit }
  function endof(u,   d) { d = 0
    for (; u <= nt; u++) { if (tok[u] == "(") d++; else if (tok[u] == ")") { d--; if (d == 0) return u } }
    return nt }'
}
# layout_bindings_ast : the same "B" lines from the validated AST, whose
# structure deed_lint.js --rsr-profile has already checked.
layout_bindings_ast() {
  printf '%s' "$DEED_AST" | jq -r '
    def s: gsub("\n"; "\\n") | gsub("\t"; "\\t");
    [.. | arrays | select(.[0] == "clause" and .[1] == "rsr-profile")][0][2][]
    | select(.[0] == "clause" and .[1] == "layout") | .[2][]
    | select(.[0] == "clause" and .[1] == "module") | .[2] as $m
    | ([$m[] | select(.[0] == "field" and .[1] == "gate")][0][2][1]) as $g
    | [$m[] | select(.[0] == "field" and .[1] == "at")][0][2][1][]
    | "B\t\($g | s)\t\(.[1] | s)"'
}
# layout_path_fault <path> : why an :at path is not a concrete repo-relative
# path, or nothing. The same rule as deed_lint.js layoutPathFault.
layout_path_fault() {
  local p="$1" seg
  [ -n "$p" ] || { echo "is empty"; return; }
  case "$p" in /*) echo "is absolute"; return ;; esac
  case "$p" in *[\*\?\[\]\|]*) echo "is a pattern, not a path (no *, ?, [, ] or |)"; return ;; esac
  if [[ "$p" == *[[:cntrl:]]* || "$p" == *\\* ]]; then echo "holds a control character or a backslash"; return; fi
  local -a segs
  IFS='/' read -r -a segs <<< "${p%/}"
  [[ "${p%/}" == */ || "${p%/}" == *//* ]] && { echo "has an empty segment"; return; }
  for seg in "${segs[@]}"; do
    [ -n "$seg" ] || { echo "has an empty segment"; return; }
    case "$seg" in .|..) echo "has a . or .. segment"; return ;; esac
  done
}

# rsr_profile_closed : refuse the clause on any key outside the module's set.
rsr_profile_closed() {
  local out tooldir deed k
  if [ "$DEED_PARSER" = ast ]; then
    deed="$(cd "$(dirname "$DEED")" && pwd)/$(basename "$DEED")"
    tooldir="$(cd "$(dirname "$DEED_LINT")" && pwd)"
    out="$(cd "$tooldir" && bun "./$(basename "$DEED_LINT")" --rsr-profile "$deed" 2>&1)" || {
      echo "ERROR: $DEED: $(printf '%s\n' "$out" | sed -n 's/^FAIL [^:]*: //p' | head -1)" >&2; return 2; }
    return 0
  fi
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case " $RSR_PROFILE_KEYS " in *" $k "*) ;; *)
      echo "ERROR: $DEED: (rsr-profile …) has no ${k#(} key (A7 J39: an unknown key refuses the clause; the set is clauses/rsr-profile.abnf's)" >&2
      return 2 ;; esac
  done <<< "$(printf '%s\n' "$_fields" | awk -F '\t' 'NF && $2 != "" { print ":" $2 }'
              printf '%s\n' "$_clauses" | head -1 | deed_subclauses | awk 'NF { print "(" $0 ")" }')"
  # (notes …) holds prose only: the AST path has the module check it; here the
  # awk path looks inside it too, so a nested form there cannot hide (#1605).
  local fault
  fault="$(printf '%s\n' "$_clauses" | head -1 | deed_notes_faults | head -1)"
  if [ -n "$fault" ]; then
    echo "ERROR: $DEED: (rsr-profile (notes …)) holds prose only, :<name> \"…\" each once, but has $fault (A7 J39)" >&2
    return 2
  fi
  return 0
}

DEED=""; DEED_PROFILE=""; DEED_AST=""; LAYOUT=""
_deeds=()
# estate_chora.deed is the estate-deed (deed.abnf filename dispatch reserves
# that exact stem), never a second repo deed, so it does not count here.
# dotglob would make the first glob match .github_chora.deed too, and the
# second would then count it twice. failglob would abort on whichever of
# the two patterns has no match, which is the normal case.
shopt -u dotglob failglob
for _d in "$REPO"/*_chora.deed "$REPO"/.*_chora.deed; do
  [ -f "$_d" ] || continue
  [ "$(basename "$_d")" = "estate_chora.deed" ] && continue
  _deeds+=("$_d")
done
if [ "${#_deeds[@]}" -gt 1 ]; then
  echo "ERROR: $REPO carries ${#_deeds[@]} *_chora.deed files; one-deed-per-repo (D312) expects exactly 1" >&2; exit 2
elif [ "${#_deeds[@]}" -eq 1 ]; then
  DEED="${_deeds[0]}"
  if [ "$DEED_PARSER" = ast ]; then
    DEED_AST="$(deed_ast "$DEED")" || exit 2
    _lines="$(deed_ast_fields "$DEED")" || exit 2
    _n="$(printf '%s\n' "$_lines" | awk -F '\t' '$1 == "COUNT" { print $2 }')"
    _fields="$(printf '%s\n' "$_lines" | grep -v '^COUNT' || true)"
  else
    [ "${RSR_DEED_PARSER:-auto}" = auto ] && [ -f "$DEED" ] && \
      echo "::notice title=rsr-profile::deed read with the awk tokenizer (bun, jq or $DEED_LINT unavailable); the validated AST path was not used" >&2
    _clauses="$(deed_strip "$DEED" | deed_clause rsr-profile)"
    _n="$(printf '%s\n' "$_clauses" | grep -c '^(rsr-profile' || true)"
    _fields="$(printf '%s\n' "$_clauses" | head -1 | deed_fields)"
  fi
  if [ "${_n:-0}" -gt 1 ]; then
    echo "ERROR: $DEED carries $_n (rsr-profile …) clauses, need exactly 1" >&2; exit 2
  elif [ "${_n:-0}" -eq 1 ]; then
    rsr_profile_closed || exit 2
    DEED_PROFILE="$_fields"
    [ -n "$DEED_PROFILE" ] || DEED_PROFILE=" "   # a clause with no fields is still a clause
    if [ "$DEED_PARSER" = ast ]; then
      LAYOUT="$(layout_bindings_ast)" || { echo "ERROR: $DEED: (rsr-profile (layout …)) could not be read from the AST" >&2; exit 2; }
    else
      LAYOUT="$(printf '%s\n' "$_clauses" | head -1 | layout_bindings)"
    fi
    _fault="$(printf '%s\n' "$LAYOUT" | awk -F '\t' '$1 == "F" { print $2; exit }')"
    if [ -n "$_fault" ]; then
      echo "ERROR: $DEED: $_fault" >&2; exit 2
    fi
  fi
fi
if [ -z "$DEED_PROFILE" ] && [ ! -f "$PROFILE" ]; then
  if [ -n "$DEED" ]; then
    echo "ERROR: no profile: $DEED has no (rsr-profile …) clause and there is no legacy $PROFILE" >&2
  else
    echo "ERROR: no profile at $PROFILE (and no *_chora.deed in $REPO to carry an (rsr-profile …) clause)" >&2
  fi
  exit 2
fi

# Body lines of a [section] (comments and blanks stripped).
section() { awk -v s="[$1]" '$0==s{f=1;next} /^\[/{f=0} f && !/^[[:space:]]*#/ && NF' "$2"; }
# "quoted" tokens on the line whose key is $1 (reads section body from stdin).
quoted_on_key() { grep -E "^[[:space:]]*$1[[:space:]]*=" | grep -oE '"[^"]+"' | tr -d '"' || true; }
# Same, but the array may span lines (`key = [` … `]`) with trailing comments —
# the shape rsr-template-repo ships in its rsr-profile.a2ml, and one the
# oracle's record-dialect parser accepts, so this checker must too. The gates
# file itself stays single-line (its own header mandates that discipline).
array_on_key() { # $1 = key; section body on stdin
  awk -v k="$1" '
    on        { sub(/#.*/, ""); print; if (/\]/) on=0; next }
    $0 ~ "^[[:space:]]*"k"[[:space:]]*=" { sub(/#.*/, ""); print; if (!/\]/) on=1 }
  ' | grep -oE '"[^"]+"' | tr -d '"' || true
}

# --- target profile ---
# Capability declaration is primary: a profile may list `capabilities = [...]`
# directly. `preset` is optional sugar — a named bundle expanded from the gate
# data. A profile must provide at least one of the two.
# Section may be [rsr-profile] (what rsr-template-repo ships) or [profile]
# (the original spelling here) — the normative oracle
# (hypatia Hypatia.Rules.RsrConformance.load_capabilities/1) accepts both,
# and this reference checker must not be stricter than the oracle.
if [ -n "$DEED_PROFILE" ]; then
  SOURCE="$DEED (rsr-profile …)"
  echo "deed parser: $DEED_PARSER" >&2
  PBODY=""
  PRESET="$(printf '%s\n' "$DEED_PROFILE" | deed_scalar preset)"
  DIRECT="$(printf '%s\n' "$DEED_PROFILE" | deed_list capabilities)"
  ADD="$(printf '%s\n' "$DEED_PROFILE" | deed_list add)"
  REMOVE="$(printf '%s\n' "$DEED_PROFILE" | deed_list remove)"
  ROLE="$(printf '%s\n' "$DEED_PROFILE" | deed_scalar role)"
else
  SOURCE="$PROFILE (legacy .a2ml)"
  PBODY="$(section rsr-profile "$PROFILE")"
  [ -n "$PBODY" ] || PBODY="$(section profile "$PROFILE")"
  PRESET="$(printf '%s\n' "$PBODY" | quoted_on_key preset | sed -n 1p)"
  DIRECT="$(printf '%s\n' "$PBODY" | array_on_key capabilities)"
  ADD="$(printf '%s\n' "$PBODY" | array_on_key add)"
  REMOVE="$(printf '%s\n' "$PBODY" | array_on_key remove)"
  # Read role from $PBODY, which already falls back from [rsr-profile] to
  # [profile]. Re-reading [rsr-profile] directly lost the role for any repo
  # using the [profile] spelling the script otherwise supports.
  ROLE="$(printf '%s\n' "$PBODY" | quoted_on_key role | sed -n 1p || true)"
fi
[ -n "$PRESET$DIRECT" ] || { echo "ERROR: profile declares neither 'capabilities' nor 'preset' ($SOURCE)" >&2; exit 2; }

# --- preset's base capabilities, if a preset is named ---
PRESETCAPS=""
if [ -n "$PRESET" ]; then
  PRESETCAPS="$(section presets "$GATES" | quoted_on_key "$PRESET")"
  [ -n "$PRESETCAPS" ] || { echo "ERROR: unknown preset '$PRESET' (not in $GATES [presets])" >&2; exit 2; }
fi

# --- effective capabilities = capabilities + presetcaps + add - remove ---
EFFECTIVE="$(printf '%s\n%s\n%s\n' "$DIRECT" "$PRESETCAPS" "$ADD" | sort -u | sed '/^$/d')"
if [ -n "$REMOVE" ]; then
  EFFECTIVE="$(comm -23 <(printf '%s\n' "$EFFECTIVE") <(printf '%s\n' "$REMOVE" | sort -u))"
fi
has_cap() { printf '%s\n' "$EFFECTIVE" | grep -qx "$1"; }

# Presence of a module path: file, dir/ (trailing slash), or glob (contains *).
#
# A row may list ALTERNATIVES separated by '|', satisfied if ANY of them exists.
# Without this every row was an independent AND, which is why the table demanded
# both build/guix.scm AND flake.nix for one capability - contradicting criterion
# 1.2.1 ("Nix fallback only") and making `reproducible-build` unsatisfiable for
# any repo that had correctly retired Nix. Alternation is what that table always
# meant; it just had no way to say it.
proof_sources_present() {
  local directory="$REPO/${1%/}"
  [ -d "$directory" ] || return 1
  # Structural source evidence only. Successful proof checking still needs
  # prover receipts; empty directories, empty files and prose cannot satisfy it.
  [ -n "$(find "$directory" -type f -size +0c \
    \( -name '*.agda' -o -name '*.lagda' -o -name '*.lagda.md' \
       -o -name '*.lagda.rst' -o -name '*.lagda.tex' -o -name '*.idr' \
       -o -name '*.lean' -o -name '*.v' -o -name '*.thy' -o -name '*.fst' \
       -o -name '*.dfy' -o -name '*.why' -o -name '*.smt2' \) -print -quit)" ]
}

present() {
  local key="$1" alt
  if [[ "$key" == *"|"* ]]; then
    local -a alts
    IFS='|' read -r -a alts <<< "$key"
    for alt in "${alts[@]}"; do
      present "$alt" && return 0
    done
    return 1
  fi
  case "$key" in
    verification/proofs/|proofs/agda/) proof_sources_present "$key" ;;
    Containerfile|container/Containerfile|build/container/Containerfile) [ -s "$REPO/$key" ] ;;
    */) [ -d "$REPO/${key%/}" ] ;;
    *'*'*) ( shopt -s globstar nullglob; compgen -G "$REPO/$key" >/dev/null ) ;;
    *) [ -e "$REPO/$key" ] ;;
  esac
}

# present_at <path> <cap> : presence of one (layout …)-bound path. The shape
# obligations the table's literal rows carry in present() follow the artefact,
# not its location: a Containerfile is non-empty wherever it lives, and a
# formal-proofs directory holds prover sources wherever it lives.
present_at() {
  local p="$1" cap="$2" base="${1%/}"
  base="${base##*/}"
  if [ "$cap" = formal-proofs ] && [[ "$p" == */ ]]; then proof_sources_present "$p"
  elif [ "$base" = Containerfile ]; then [ -s "$REPO/$p" ]
  elif [[ "$p" == */ ]]; then [ -d "$REPO/${p%/}" ]
  else [ -f "$REPO/$p" ]; fi
}

# --- resolve (layout …) bindings against the gate table ---
# BOUND_AT[<row key>] holds the row's :at paths, one per line; BOUND_GATE[<row
# key>] the alternative the deed named it by.
declare -A BOUND_AT=() BOUND_GATE=()
if [ -n "$LAYOUT" ]; then
  _gate_rows="$(section gates "$GATES" | while IFS= read -r _l; do
    _k="$(printf '%s' "$_l" | grep -oE '"[^"]+"' | sed -n 1p | tr -d '"')"
    [ -n "$_k" ] && printf '%s\n' "$_k"; done)"
  _baseline_rows="$(section baseline "$GATES" | array_on_key paths)"
  while IFS=$'\t' read -r _kind _gate _at; do
    [ "$_kind" = B ] || continue
    _why="$(layout_path_fault "$_at")"
    [ -z "$_why" ] || { echo "ERROR: $DEED: (rsr-profile (layout (module :at))) path \"$_at\" $_why" >&2; exit 2; }
    _row=""
    while IFS= read -r _k; do
      [ -n "$_k" ] || continue
      IFS='|' read -r -a _alts <<< "$_k"
      for _a in "${_alts[@]}"; do [ "$_a" = "$_gate" ] && { _row="$_k"; break 2; }; done
    done <<< "$_gate_rows"
    if [ -z "$_row" ]; then
      if printf '%s\n' "$_baseline_rows" | tr '|' '\n' | grep -qxF -- "$_gate"; then
        echo "ERROR: $DEED: (layout (module :gate \"$_gate\")) names a [baseline] row; only capability-gated [gates] rows are bound by (layout …)" >&2
      else
        echo "ERROR: $DEED: (layout (module :gate \"$_gate\")) names no [gates] row of $GATES; :gate is one alternative of a row, written as the table writes it" >&2
      fi
      exit 2
    fi
    if [ -n "${BOUND_GATE[$_row]+x}" ] && [ "${BOUND_GATE[$_row]}" != "$_gate" ]; then
      echo "ERROR: $DEED: (layout …) binds the row \"${_row//|/ or }\" twice (as \"${BOUND_GATE[$_row]}\" and \"$_gate\")" >&2; exit 2
    fi
    # Same kind of artefact: a directory for a directory alternative, a file
    # for a file one, and a name the alternative's last segment matches.
    _gb="${_gate%/}"; _gb="${_gb##*/}"; _ab="${_at%/}"; _ab="${_ab##*/}"
    _gk="file"; [[ "$_gate" == */ ]] && _gk="directory"
    _ak="file"; [[ "$_at" == */ ]] && _ak="directory"
    if [ "$_gk" != "$_ak" ]; then
      echo "ERROR: $DEED: (layout (module :gate \"$_gate\")) binds \"$_at\": a $_gk row is bound to a $_gk path (a directory path ends in /)" >&2
      exit 2
    fi
    # shellcheck disable=SC2053  # the row's last segment is a pattern on purpose
    if [[ "$_ab" != $_gb ]]; then
      echo "ERROR: $DEED: (layout (module :gate \"$_gate\")) binds \"$_at\", whose name does not match \"$_gb\": a binding moves a module, it never renames what the row asks for" >&2
      exit 2
    fi
    BOUND_GATE[$_row]="$_gate"
    BOUND_AT[$_row]+="$_at"$'\n'
  done <<< "$LAYOUT"
fi

# Folded baseline metadata is recognized from validated native AST nodes,
# never from a basename, a quoted example or an empty metadata directory.
# The legacy awk profile reader is retained, but it is not a DEED validator
# and cannot establish these folded-metadata alternatives.
deed_baseline_present() {
  local kind="$1"
  [ "$DEED_PARSER" = ast ] && [ -n "$DEED_AST" ] || return 1
  printf '%s' "$DEED_AST" | jq -e --arg kind "$kind" '
    def string_field($items; $key):
      [$items[] | select(.[0] == "field" and .[1] == $key)] as $fields
      | if ($fields | length) == 1 and $fields[0][2][0] == "string"
        then $fields[0][2][1] else "" end;
    def nonblank: type == "string" and test("\\S");
    def substantive:
      any(.. | arrays;
        .[0] == "field" and
        (.[2] | if .[0] == "string" then .[1] | nonblank
                elif .[0] == "list" then (.[1] | length) > 0
                else .[0] | IN("symbol", "integer", "boolean", "uuid5", "uuid8") end));
    .head == "repo-deed" and
    (if $kind == "manifest" then
       string_field(.items; "canonical-name") as $name
       | [.items[] | select(.[0] == "clause" and .[1] == "manifest")] as $records
       | if ($records | length) != 1 then false else
           ($name | nonblank) and
           (string_field($records[0][2]; "project") == $name) and
           (string_field($records[0][2]; "version") | nonblank) and
           (string_field($records[0][2]; "purpose") | nonblank)
         end
     else
       any(.items[];
         .[0] == "clause" and
         (.[1] | IN("meta", "ecosystem", "agentic", "neurosym", "playbook", "anchor", "clade", "state")) and
         substantive)
     end)' >/dev/null
}

echo "repo:    $REPO"
echo "profile: ${PRESET:+preset=$PRESET }${DIRECT:+direct-capabilities} <- $SOURCE"
echo "role:    ${ROLE:-unset}"
echo "effective capabilities: $(printf '%s\n' "$EFFECTIVE" | paste -sd ' ' -)"
echo "layout bindings: $(printf '%s\n' "$LAYOUT" | awk -F '\t' '$1 == "B" { n++ } END { print n + 0 }')"
echo

# A spine (template) repo legitimately carries capability-gated modules it does
# not declare - it ships them for the repos minted from it. [carrier] lists them.
# $ROLE was read with the rest of the profile above, from whichever source won.
CARRIER=""
# role = "spine": a template legitimately carries modules it does not declare,
# because it ships them for the repos minted from it.
# role = "canon": metadatastician/standards legitimately carries modules whose
# gating capability cannot apply to it — the criteria SSOT is the document that
# DEFINES the gates, not an instance of one; docs/proofs/ holds proof artefacts
# OF THE ESTATE, not proofs of the canon's own code; and *-reusable.yml are the
# gates every other repo CALLS and the canon SERVES.
#
# Without this the canon is unscorable BY CONSTRUCTION, which is the mechanical
# reason it has never carried an rsr-profile.a2ml at all. See [canon] in the
# gate table for the full rationale.
case "$ROLE" in
  spine)
    # array_on_key, not quoted_on_key: BOTH carrier sections are multi-line
    # (`paths = [` then one quoted entry per line), and quoted_on_key only reads
    # the key's own line — so every entry was invisible and the exemption this
    # branch exists to provide had never once applied.
    CARRIER="$(section carrier "$GATES" | array_on_key paths || true)"
    echo "role: spine - [carrier] paths exempt from VESTIGIAL"
    echo
    ;;
  canon)
    CARRIER="$(section canon "$GATES" | array_on_key paths || true)"
    echo "role: canon - [canon] paths exempt from VESTIGIAL"
    echo
    ;;
  "")
    ;;
  *)
    echo "WARNING: unknown role '$ROLE' - no carrier exemption applied" >&2
    ;;
esac
# A gate row may be an alternation ("a|b"); a carrier entry names ONE path.
# Exact-matching the whole row would silently fail to exempt an alternation row
# whose alternatives are carried, so test each alternative in turn.
is_carrier() {
  [ -n "$CARRIER" ] || return 1
  local alt
  local -a alts
  IFS='|' read -r -a alts <<< "$1"
  for alt in "${alts[@]}"; do
    printf '%s\n' "$CARRIER" | grep -qx "$alt" && return 0
  done
  return 1
}

fail=0
# A row key may be an alternation ("a|b"); print it readably in a verdict, since
# the raw form ("Cargo.toml|*/Cargo.toml|*/*/Cargo.toml") reads like a broken glob.
row_label() { printf '%s' "${1//|/ or }"; }
while IFS= read -r line; do
  path="$(printf '%s' "$line" | grep -oE '"[^"]+"' | sed -n 1p | tr -d '"')"
  cap="$(printf '%s' "$line" | grep -oE '"[^"]+"' | sed -n 2p | tr -d '"')"
  [ -n "$path" ] && [ -n "$cap" ] || continue
  if [ -n "${BOUND_GATE[$path]+x}" ]; then
    # A row the deed's (layout …) binds. The binding is a claim about THIS tree,
    # so no carrier exemption excuses a bound path that is not there.
    while IFS= read -r at; do
      [ -n "$at" ] || continue
      if has_cap "$cap"; then
        if present_at "$at" "$cap"; then
          echo "  bound by (layout): $(row_label "$path") -> $at"
        else
          echo "  MISSING ($cap): $at (bound by (layout) for $(row_label "$path"))"; fail=1
        fi
      elif ! present_at "$at" "$cap"; then
        echo "  STALE (layout): $at is bound for $(row_label "$path") but this tree does not carry it"; fail=1
      fi
    done <<< "${BOUND_AT[$path]}"
    # Undeclared capability: a present bound path or default is VESTIGIAL, as
    # it is for an unbound row; a binding never hides the table's defaults.
    if ! has_cap "$cap"; then
      _vest=""
      present "$path" && _vest="$(row_label "$path")"
      while IFS= read -r at; do
        [ -n "$at" ] && present_at "$at" "$cap" && _vest="${_vest:+$_vest, }$at"
      done <<< "${BOUND_AT[$path]}"
      if [ -n "$_vest" ]; then
        if is_carrier "$path"; then
          echo "  carried for downstream (no '$cap' capability, spine): $_vest"
        else
          echo "  VESTIGIAL (no '$cap' capability): $_vest"; fail=1
        fi
      fi
    fi
    continue
  fi
  if has_cap "$cap"; then
    if ! present "$path"; then
      # A carrier path is a gate the repo SERVES, not one it runs (the spine
      # ships rust-ci.yml so a Rust project minted from it has one; the canon
      # serves the same thing as rust-ci-reusable.yml). Carrier exemption
      # previously applied only to VESTIGIAL, so a carrier that declares the
      # capability was still failed for not running its own gift.
      if is_carrier "$path"; then
        echo "  served for downstream (no local '$cap' module needed): $(row_label "$path")"
      else
        echo "  MISSING ($cap): $(row_label "$path")"; fail=1
      fi
    fi
  else
    if present "$path"; then
      if is_carrier "$path"; then
        echo "  carried for downstream (no '$cap' capability, spine): $(row_label "$path")"
      else
        echo "  VESTIGIAL (no '$cap' capability): $(row_label "$path")"; fail=1
      fi
    fi
  fi
done < <(section gates "$GATES")

# --- baseline: always-carried paths, not capability-gated (#1227) ---
# The row is "a|b|c": satisfied if ANY alternative exists, exactly like a gate
# row, so a repo that retired a spelling is not failed for having retired it.
baseline_checked=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  baseline_checked=$((baseline_checked + 1))
  if [ -n "$DEED" ] && [ "$DEED_PARSER" != ast ] &&
     [[ "$key" == *0-AI-MANIFEST* || "$key" == *descriptiles/* ]] && ! present "$key"; then
    echo "ERROR: assessing folded baseline metadata needs RSR_DEED_PARSER=ast, bun and jq; the awk profile reader cannot validate the deed" >&2
    exit 2
  fi
  # The profile row names the .a2ml spellings. When the profile this run just
  # read came from the repo deed's (rsr-profile …) clause, that clause IS the
  # artefact the row asks for; failing the row would fail every deed-era repo,
  # the worked model first. The table itself should gain the deed spelling in
  # its next PATCH (as [baseline] gained 0-AI-MANIFEST.deed in #1229), which
  # is a canon release, not a checker change.
  if [ -n "$DEED_PROFILE" ] && [[ "$key" == *rsr-profile.a2ml* ]]; then
    echo "  baseline rsr-profile: satisfied by the (rsr-profile …) clause of $(basename "$DEED")"
    continue
  fi
  if [[ "$key" == *0-AI-MANIFEST* ]] && deed_baseline_present manifest; then
    echo "  baseline manifest: satisfied by the validated (manifest …) clause of $(basename "$DEED")"
    continue
  fi
  if [[ "$key" == *descriptiles/* ]] && deed_baseline_present descriptions; then
    echo "  baseline descriptiles: satisfied by substantive descriptive clauses of $(basename "$DEED")"
    continue
  fi
  present "$key" || { echo "  MISSING BASELINE: $(row_label "$key")"; fail=1; }
done < <(section baseline "$GATES" | array_on_key paths)

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'MSG'

rsr-profile check: FAIL — scaffold does not match declared capabilities.
Fix one of:
  * remove the vestigial module, OR
  * declare the capability in the repo deed's (rsr-profile …) clause (the
    legacy .machine_readable/rsr-profile.a2ml is still read where no clause
    exists; add a [rationale] line there), OR
  * add the missing module, OR
  * when the module exists elsewhere in the tree, bind its real location in
    the deed's (rsr-profile (layout (module :gate "<row>" :at ("<path>"))));
    a STALE binding names a path the tree no longer carries: fix or drop it, OR
  * for a MISSING BASELINE row, add the file (the table's [baseline].paths
    lists the estate spellings that conform; a district path only conforms if
    the table names it).
MSG
  exit 1
fi

if [ -n "$LIVE_REPOSITORY" ]; then
  echo "checking live Actions policy: $LIVE_REPOSITORY"
  bash "$SCRIPT_DIR/check-actions-policy.sh" "$LIVE_REPOSITORY"
fi
echo "rsr-profile check: OK — scaffold matches declared capabilities ($baseline_checked baseline path(s) present)."
