#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Reference checker for the RSR template-applicability model.
# Policy: ../TEMPLATE-APPLICABILITY-POLICY.adoc
# Data:   ../.machine_readable/template-capability-gates.toml
#
# Reads a target repo's .machine_readable/rsr-profile.a2ml, resolves its
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
# deed_scalar <key> : read deed_fields input; print the first :<key> value
# followed by a newline if it is a string, otherwise nothing. String escapes
# follow deed_fields.
deed_scalar() { deed_fields | awk -F '\t' -v k="$1" '$1 == "S" && $2 == k && !done { print $3; done = 1 }'; }
# deed_list <key> : read deed_fields input; print the first :<key> list's items,
# strings unquoted, symbols as written, one per line. UUID literals and nested
# lists are omitted; absent, empty or non-list values produce no output.
# String escapes follow deed_fields.
deed_list() { deed_fields | awk -F '\t' -v k="$1" '$1 == "L" && $2 == k { print $3 }'; }

DEED=""; DEED_PROFILE=""
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
  _clauses="$(deed_strip "$DEED" | deed_clause rsr-profile)"
  _n="$(printf '%s\n' "$_clauses" | grep -c '^(rsr-profile' || true)"
  if [ "${_n:-0}" -gt 1 ]; then
    echo "ERROR: $DEED carries $_n (rsr-profile …) clauses, need exactly 1" >&2; exit 2
  elif [ "${_n:-0}" -eq 1 ]; then
    DEED_PROFILE="$_clauses"
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
    */) [ -d "$REPO/${key%/}" ] ;;
    *'*'*) ( shopt -s globstar nullglob; compgen -G "$REPO/$key" >/dev/null ) ;;
    *) [ -e "$REPO/$key" ] ;;
  esac
}

echo "repo:    $REPO"
echo "profile: ${PRESET:+preset=$PRESET }${DIRECT:+direct-capabilities} <- $SOURCE"
echo "effective capabilities: $(printf '%s\n' "$EFFECTIVE" | paste -sd ' ' -)"
echo

# A spine (template) repo legitimately carries capability-gated modules it does
# not declare - it ships them for the repos minted from it. [carrier] lists them.
# $ROLE was read with the rest of the profile above, from whichever source won.
CARRIER=""
# role = "spine": a template legitimately carries modules it does not declare,
# because it ships them for the repos minted from it.
# role = "canon": hyperpolymath/standards legitimately carries modules whose
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
