#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# check-trusted-base.sh
#
# Implements the enforcement leg of the estate Trusted-Base Reduction Policy
# (docs/TRUSTED-BASE-REDUCTION-POLICY.adoc — standards#203).
#
# For every soundness-relevant escape hatch in a proof-bearing repo, verifies
# the hatch is one of:
#   (a) discharged — entry in `docs/proof-debt.md` §(a)
#   (b) budgeted   — entry in §(b) AND preceded by a `TRUSTED:` leading comment
#   (c) necessary  — entry in §(c) AND preceded by an `AXIOM:` leading comment
#   (d) debt       — entry in §(d) with deadline + owner (still counts as
#                    documented; CI passes but the entry is enumerated in the
#                    CI summary)
#
# ─────────────────────────────────────────────────────────────────────────────
# TWO TIERS — why detection was widened without red-boarding the estate
# ─────────────────────────────────────────────────────────────────────────────
# The original check recognised one class of marker per language. A development
# can be postulate-free and still be unsound — an Agda `{-# TERMINATING #-}`, a
# `--type-in-type`, a Lean `@[implemented_by]`, a Coq `Parameter`. Widening
# detection is therefore correct. Making every new marker an immediate hard
# failure is NOT correct, because the same token is a defect in one repository
# and a defensible choice in another:
#
#   * `{-# TERMINATING #-}` alongside a written termination argument is the
#     intended use of the pragma, not a hole;
#   * a `{!!}` goal in a work-in-progress module is a TODO, not a lie;
#   * `postulate` in a teaching example is the point of the example.
#
# So markers are split into two tiers:
#
#   CORE      The markers the gate has enforced since standards#211. Their
#             behaviour is UNCHANGED: undocumented -> non-zero exit.
#
#   EXTENDED  Every marker added by the 2026-10-30 widening. Their disposition
#             is decided by a budget, not by a binary:
#               mode=report   (DEFAULT) enumerate, annotate, exit 0
#               mode=budget   fail iff undocumented-extended > budget
#               mode=strict   fail iff undocumented-extended > 0
#             The default is `report` on purpose: a widening that reds 416
#             repositories on the day it lands teaches the estate to add
#             `.trusted-base-ignore` paths instead of reading the finding, and
#             the signal is gone. Repos opt into `budget` — with the number the
#             survey measured — and the budget may only ever shrink.
#
# ─────────────────────────────────────────────────────────────────────────────
# MARKERS
# ─────────────────────────────────────────────────────────────────────────────
# CORE
#   Coq      *.v       — `^Axiom`, `^Admitted`, `^admit.`
#   Lean     *.lean    — `\bsorry\b`, `^axiom`
#   Agda     *.agda    — `postulate`
#   Idris2   *.idr*    — `believe_me`, `really_believe_me`, `assert_total`,
#                        top-level `partial`, `%default partial`
#   F*       *.fst     — `assume val`, `admit_p`
#   Rust/Hs  *.rs|*.hs — `unsafePerformIO`, `unsafeCoerce`
#
# EXTENDED (2026-10-30, standards#1401)
#   Agda     — `{-# TERMINATING #-}`, `{-# NON_TERMINATING #-}`,
#              `{-# NON_COVERING #-}`, `--type-in-type`,
#              `--no-{termination,positivity,coverage,projection-likeness}-check`,
#              `--allow-unsolved-metas`, `primTrustMe`, `{!!}` hole
#   Idris2   — `?hole` (goals), plus the core set above
#   Lean     — `@[implemented_by]`, `@[extern]`, `native_decide`,
#              `Lean.trustCompiler` / `Lean.ofReduceBool`, `admit`,
#              top-level `unsafe def` / `partial def`
#   Coq      — `Parameter(s)`, `Conjecture(s)`, the `admit` and `give_up`
#              tactics without the trailing dot
#   Dafny    — `{:axiom}`
#   F*       — bare `assume`, `admit()`
#
# DELIBERATELY NOT DETECTED — each one would flag healthy code as sick:
#   * Idris2 `%default total`. Item is a *strictness* directive: it makes the
#     totality checker mandatory. The hole is `%default partial`. Flagging
#     `%default total` would red-board every well-disciplined Idris2 repo.
#   * Coq `Hypothesis` / `Variable` / `Context` inside a `Section`. These are
#     binders discharged at `Qed`, not axioms. A text scan cannot tell a
#     section binder from a file-scope axiom without a parser, and guessing
#     "axiom" is wrong in the overwhelmingly common case. `Parameter` and
#     `Conjecture` are the file-scope spellings, and those are detected.
#   * Agda `{-# BUILTIN #-}` / `{-# COMPILE #-}`, Lean `@[simp]`, `noncomputable`.
#     These change compilation, not the trusted base.
#   * Any of the above in a file listed in `.trusted-base-ignore`, or annotated
#     inline, or enumerated in the proof-debt index — the three discharge
#     routes below apply identically to both tiers.
#
# ─────────────────────────────────────────────────────────────────────────────
# DISCHARGE ROUTES (all three apply to BOTH tiers)
# ─────────────────────────────────────────────────────────────────────────────
#   1. inline leading comment, walking back through the comment block:
#        TRUSTED:   run-time soundness break, with a refutation budget
#        AXIOM:     metatheoretic assumption, with a citation
#        OWED:      proof-only / erased assumption (Idris2 `0`-multiplicity)
#        JUSTIFIED: reasoned argument accepted in place of a proof
#                   (the canonical token for `{-# TERMINATING #-}` + a
#                   written termination argument; see the policy doc)
#        DEBT:      known, owned and dated — see docs/proof-debt.md §(d)
#   2. enumeration in docs/proof-debt.md (or .adoc / PROOF-NEEDS.md)
#   3. path-fragment exemption in .trusted-base-ignore
#
# ─────────────────────────────────────────────────────────────────────────────
# BUDGET — `.trusted-base-budget` (repo root, optional)
# ─────────────────────────────────────────────────────────────────────────────
#   # The number the survey measured, never a number that makes the board green.
#   mode: budget
#   extended-undocumented: 37
#
#   mode: report | budget | strict        (default: report)
#   extended-undocumented: <integer>      (default: 0)
#
#   Ratchet: the budget may DECREASE in any commit; raising it is a policy
#   change and needs a `Ratchet-exception:` line in the commit message.
#
#   ⚠ THIS FILE IS NOT YET IN scripts/check-exemption-ratchet.sh LEDGERS, so
#   that direction of travel is a REVIEW obligation, not a mechanical one. The
#   ratchet compares ledger ENTRY COUNTS between the PR base and HEAD; a budget
#   is a single integer value, and scripts/count-ledger-entries.sh has no format
#   for it. Until that counter learns one (a `budget:` mode that emits the
#   `extended-undocumented` value) and `.trusted-base-budget` joins LEDGERS, a
#   raised ceiling is visible only in the diff. Do not describe this as enforced.
#
# Precedence: CLI flag > environment variable > .trusted-base-budget > default.
#   --extended-mode=report|budget|strict   (env TRUSTED_BASE_EXTENDED_MODE)
#   --tier=core|extended|all               (env TRUSTED_BASE_TIER)
#
# ─────────────────────────────────────────────────────────────────────────────
# OTHER MODES
# ─────────────────────────────────────────────────────────────────────────────
#   --list-markers   print the marker catalogue (TSV: language, tier, id,
#                    description) and exit 0. Single source of truth for the
#                    estate survey (scripts/estate-trusted-base-survey.sh).
#
# Exit codes:
#   0 — repo has no proof-bearing files; OR every CORE marker is documented and
#       the EXTENDED tier's disposition passes in the configured mode.
#   1 — at least one CORE marker is undocumented, or the extended budget is
#       exceeded in mode=budget|strict.
#   2 — invocation/environment error (including a malformed budget file).
#
# Wired into governance-reusable.yml as the `trusted-base` job. THE JOB NAME
# AND THE CALLER'S JOB KEY MUST NOT CHANGE: the required status context across
# the estate is derived from them. See docs/CICD-SIGNAL-DISCIPLINE.adoc.

set -u

TIER_CATALOGUE="$(cat <<'CATALOGUE'
coq	core	coq-axiom-or-admit	^Axiom | ^Admitted | ^admit.
coq	extended	coq-parameter-or-conjecture	^Parameter | ^Conjecture (file-scope axioms under another name)
coq	extended	coq-admit-tactic	admit / give_up without the trailing dot
lean	core	lean-sorry-or-axiom	sorry | ^axiom
lean	extended	lean-implemented-by	@[implemented_by] (proof swapped for unverified implementation at runtime)
lean	extended	lean-extern	@[extern] (opaque body, no kernel term)
lean	extended	lean-native-decide	native_decide / Lean.trustCompiler / Lean.ofReduceBool (trusts the compiler, not the kernel)
lean	extended	lean-admit-tactic	admit (alias of sorry)
lean	extended	lean-unsafe-or-partial-def	unsafe def | partial def
agda	core	agda-postulate	postulate
agda	extended	agda-terminating-pragma	{-# TERMINATING #-} / {-# NON_TERMINATING #-}
agda	extended	agda-non-covering-pragma	{-# NON_COVERING #-}
agda	extended	agda-unsound-flag	--type-in-type / --no-*-check / --allow-unsolved-metas
agda	extended	agda-primtrustme	primTrustMe
agda	extended	agda-hole	{!!}
idris2	core	idris-believe-or-assert	believe_me | really_believe_me | assert_total
idris2	core	idris-partial	top-level partial | %default partial
idris2	extended	idris-hole	?hole (unsolved goal)
fstar	core	fstar-assume-or-admit	assume val | admit_p
fstar	extended	fstar-assume-or-admit-bare	bare assume | admit()
dafny	extended	dafny-axiom	{:axiom}
rust-hs	core	rust-or-hs-unsafe	unsafePerformIO | unsafeCoerce
CATALOGUE
)"

# Print the script's header comments as usage text.
usage() {
  sed -n '2,160p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p'
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing. The historical invocation is a single positional path
# (`bash standards/scripts/check-trusted-base.sh caller`), so a lone non-flag
# argument must keep working exactly as before.
# ─────────────────────────────────────────────────────────────────────────────
repo_root="."
cli_mode=""
cli_tier=""

for arg in "$@"; do
  case "$arg" in
    --extended-mode=*) cli_mode="${arg#*=}" ;;
    --tier=*)          cli_tier="${arg#*=}" ;;
    --list-markers)    printf '%s\n' "$TIER_CATALOGUE"; exit 0 ;;
    -h|--help)         usage; exit 0 ;;
    --*)
      echo "ERROR: unknown option '$arg'" >&2
      exit 2 ;;
    *) repo_root="$arg" ;;
  esac
done

cd "$repo_root" || { echo "ERROR: cannot cd to $repo_root" >&2; exit 2; }

# ─────────────────────────────────────────────────────────────────────────────
# Resolve tier and extended-mode: CLI > env > .trusted-base-budget > default.
# ─────────────────────────────────────────────────────────────────────────────
budget_mode="report"
budget_extended=0
budget_file_seen=false

if [ -f .trusted-base-budget ]; then
  budget_file_seen=true
  lineno=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))
    line="${raw%$'\r'}"
    # strip comments and surrounding whitespace
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$line" ] && continue
    key="${line%%:*}"
    val="${line#*:}"
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$key" in
      mode)
        case "$val" in
          report|budget|strict) budget_mode="$val" ;;
          *)
            echo "ERROR: .trusted-base-budget:$lineno: mode must be report|budget|strict, got '$val'" >&2
            exit 2 ;;
        esac ;;
      extended-undocumented)
        case "$val" in
          ''|*[!0-9]*)
            echo "ERROR: .trusted-base-budget:$lineno: extended-undocumented must be a non-negative integer, got '$val'" >&2
            exit 2 ;;
          *) budget_extended="$val" ;;
        esac ;;
      *)
        echo "ERROR: .trusted-base-budget:$lineno: unknown key '$key'" >&2
        exit 2 ;;
    esac
  done < .trusted-base-budget
fi

extended_mode="${cli_mode:-${TRUSTED_BASE_EXTENDED_MODE:-$budget_mode}}"
tier="${cli_tier:-${TRUSTED_BASE_TIER:-all}}"

case "$extended_mode" in
  report|budget|strict) ;;
  *) echo "ERROR: extended mode must be report|budget|strict, got '$extended_mode'" >&2; exit 2 ;;
esac
case "$tier" in
  core|extended|all) ;;
  *) echo "ERROR: tier must be core|extended|all, got '$tier'" >&2; exit 2 ;;
esac

want_core=false
want_extended=false
case "$tier" in
  core)     want_core=true ;;
  extended) want_extended=true ;;
  all)      want_core=true; want_extended=true ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Find all proof-bearing files (excluding vendored / build artefacts).
# ─────────────────────────────────────────────────────────────────────────────
PRUNE_PATHS=(-path '*/.git' -prune -o
             -path '*/.lake' -prune -o
             -path '*/_build' -prune -o
             -path '*/build' -prune -o
             -path '*/target' -prune -o
             -path '*/node_modules' -prune -o
             -path '*/dist' -prune -o
             -path '*/.venv' -prune -o
             -path '*/vendored' -prune -o)

proof_files=$(find . "${PRUNE_PATHS[@]}" -type f \( \
  -name '*.v'    -o -name '*.lean'  -o -name '*.agda' -o \
  -name '*.idr'  -o -name '*.idr2'  -o -name '*.fst'  -o \
  -name '*.dfy'  -o -name '*.tla'   -o -name '*.ads'  -o -name '*.adb' \) -print)

unsafe_files=$(find . "${PRUNE_PATHS[@]}" -type f \( \
  -name '*.rs' -o -name '*.hs' \) -print)

if [ -z "$proof_files" ]; then
  echo "[OK] No proof-bearing files in this repo; check-trusted-base.sh is a no-op."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Gather every marker — one row per (file, line, kind, tier, identifier).
# ─────────────────────────────────────────────────────────────────────────────
markers_tsv=$(mktemp)
trap 'rm -f "$markers_tsv"' EXIT

is_comment_line() {
  # Heuristic: line whose first non-whitespace chars are a comment marker.
  # Returns 0 (true) when the line is a comment.
  local trimmed
  trimmed="$(echo "$1" | sed -E 's/^[[:space:]]+//')"
  case "$trimmed" in
    --*|"||| "*|"|||"*|//*|/\**|"* "*|"(*"*|"#"*) return 0 ;;
  esac
  return 1
}

emit_marker() {
  # 1=file, 2=line, 3=kind, 4=tier, 5=identifier-or-context
  # Append a TSV row unless the tier is disabled or the context is a comment.
  # Return 0 for a skipped row, 1 for an unknown tier, or the append's status.
  #
  # Tier filtering happens here so that every downstream pass — documentation
  # check, exemption accounting, reporting — sees exactly one list.
  case "$4" in
    core)     $want_core     || return 0 ;;
    extended) $want_extended || return 0 ;;
    *) echo "INTERNAL ERROR: unknown tier '$4'" >&2; return 1 ;;
  esac
  # Skip if the line itself is a comment line (false positives — talking *about*
  # the construct rather than using it).
  if is_comment_line "$5"; then
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$markers_tsv"
}

# Coq comments nest and may span lines. A line-oriented grep sees prose inside
# `(* ... *)` as code whenever the interior line does not begin with a comment
# delimiter. Strip nested block comments and strings while preserving line
# count before looking for proof escape hatches. Coq permits multiline strings
# and escapes a quote as `""`, so string state spans lines and takes precedence
# over comment delimiters. An unterminated string emits a synthetic marker so
# malformed input fails closed instead of hiding the remainder of the file.
strip_coq_noncode() {
  awk '
    {
      line = $0; sub(/\r$/, "", line); out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1); pair = substr(line, i, 2)
        if (instr) {
          if (pair == "\"\"") { i += 2; continue }
          if (c == "\"") { instr = 0; i++; continue }
          i++; continue
        }
        if (c == "\"") { instr = 1; i++; continue }
        if (depth > 0) {
          if (pair == "(*") { depth++; i += 2; continue }
          if (pair == "*)") { depth--; i += 2; continue }
          i++; continue
        }
        if (pair == "(*") { depth++; i += 2; continue }
        out = out c; i++
      }
      print out
    }
    END {
      if (instr) print "Axiom __unterminated_coq_string"
    }
  ' "$1"
}

# Lean sorry / axiom
#
# Matching must be COMMENT-AWARE. The previous implementation stripped only
# "string literals" from a single line, so a docstring that merely MENTIONS
# `sorry` -- e.g. a repo documenting that its own gate rejects smuggled
# sorries -- was reported as a soundness-relevant escape hatch, and the repo
# was then told to seed docs/proof-debt.md for a hatch that does not exist.
# Lean block comments nest and span lines, so per-line string stripping cannot
# see them. strip_lean_noncode() blanks line comments (--), nesting block
# comments and docstrings (/- -/, /-! -/, /-- -/) and string literals, while
# preserving line numbers so reported line numbers stay accurate.
#
# Failure direction is deliberate: string state is NOT carried across lines, so
# an odd quote over-flags rather than blanking the remainder of a file. For a
# soundness gate, over-flagging is safe and under-flagging is not.
strip_lean_noncode() {
  awk '
    {
      line = $0; sub(/\r$/, "", line); out = ""; i = 1; n = length(line); instr = 0
      while (i <= n) {
        c = substr(line, i, 1); c2 = substr(line, i, 2)
        if (depth > 0) {
          if (c2 == "-/") { depth--; i += 2; continue }
          if (c2 == "/-") { depth++; i += 2; continue }
          i++; continue
        }
        if (instr) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { instr = 0; i++; continue }
          i++; continue
        }
        if (c2 == "/-") { depth++; i += 2; continue }
        if (c2 == "--") { break }
        if (c == "\"") { instr = 1; i++; continue }
        out = out c; i++
      }
      print out
    }
  ' "$1"
}

# Agda / Idris2 share Haskell-style lexical structure: `--` line comments and
# NESTED `{- ... -}` block comments, plus string literals.
#
# The one thing that must survive is the Agda pragma `{-# ... #-}`, which
# begins with the block-comment opener. Blanking it would hide exactly the
# markers this widening adds (`{-# TERMINATING #-}`, `{-# NON_COVERING #-}`,
# and `{-# OPTIONS --type-in-type #-}`), so pragma text is copied through
# verbatim. Nested comments inside a pragma are not a thing worth supporting.
# Print the remaining text from the given file, retaining one output line per
# input line for marker locations. String state resets at each line.
strip_haskellish_noncode() {
  awk '
    {
      line = $0; sub(/\r$/, "", line); out = ""; i = 1; n = length(line); instr = 0
      while (i <= n) {
        c = substr(line, i, 1); c2 = substr(line, i, 2); c3 = substr(line, i, 3)
        if (depth > 0) {
          if (c2 == "-}") { depth--; i += 2; continue }
          if (c2 == "{-") { depth++; i += 2; continue }
          i++; continue
        }
        if (instr) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { instr = 0; i++; continue }
          i++; continue
        }
        if (pragma) {
          if (c3 == "#-}") { out = out c3; i += 3; pragma = 0; continue }
          out = out c; i++; continue
        }
        if (c3 == "{-#") { pragma = 1; out = out c3; i += 3; continue }
        if (c2 == "{-") { depth++; i += 2; continue }
        if (c2 == "--") { break }
        if (c == "\"") { instr = 1; i++; continue }
        out = out c; i++
      }
      print out
    }
  ' "$1"
}

# Print the given file without comments and strings, retaining line numbers.
strip_fstar_noncode() {
  # F* comment syntax is OCaml's, not Haskell's: `//` to end of line and
  # NESTED `(* ... *)` blocks. The shared Haskell stripper knows `--` and
  # `{- -}`, so handing it a .fst file left every `(* ... *)` block intact —
  # and a comment reading "we removed the admit() here" then counted as an
  # `admit()`. F* strings take backslash escapes.
  awk '
    {
      line = $0; sub(/\r$/, "", line); out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1); pair = substr(line, i, 2)
        if (depth > 0) {
          if (pair == "(*") { depth++; i += 2; continue }
          if (pair == "*)") { depth--; i += 2; continue }
          i++; continue
        }
        if (instr) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { instr = 0; i++; continue }
          i++; continue
        }
        if (pair == "//") { break }
        if (pair == "(*") { depth++; i += 2; continue }
        if (c == "\"") { instr = 1; i++; continue }
        out = out c; i++
      }
      print out
    }
  ' "$1"
}

# Print the given file without comments and strings, retaining line numbers.
strip_dafny_noncode() {
  # Dafny: `//` to end of line, NESTED `/* ... */`, ordinary strings with
  # backslash escapes, and verbatim strings (`@"...`') where `""` is a literal
  # quote. Without this, `{:axiom}` mentioned in prose — "do not use {:axiom}
  # in this module" — was counted as an axiom and could push a healthy file
  # into strict-mode failure or eat its budget.
  awk '
    {
      line = $0; sub(/\r$/, "", line); out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1); pair = substr(line, i, 2)
        if (depth > 0) {
          if (pair == "/*") { depth++; i += 2; continue }
          if (pair == "*/") { depth--; i += 2; continue }
          i++; continue
        }
        if (inverb) {
          if (pair == "\"\"") { i += 2; continue }
          if (c == "\"") { inverb = 0; i++; continue }
          i++; continue
        }
        if (instr) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { instr = 0; i++; continue }
          i++; continue
        }
        if (pair == "//") { break }
        if (pair == "/*") { depth++; i += 2; continue }
        if (pair == "@\"") { inverb = 1; i += 2; continue }
        if (c == "\"") { instr = 1; i++; continue }
        out = out c; i++
      }
      print out
    }
  ' "$1"
}

# Coq Axiom / Admitted (core) and Parameter / Conjecture / bare admit (extended)
echo "$proof_files" | grep -E '\.v$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_coq_noncode "$f" 2>/dev/null | grep -nE '^[[:space:]]*(Axiom|Admitted|admit\.)' | while IFS=: read -r ln rest; do
    orig="$(sed -n "${ln}p" "$f" 2>/dev/null)"
    # The language-aware pass already removed comments. Do not feed the
    # original line through the generic prefix heuristic: `(* note *) Admitted.`
    # is executable debt even though its original text begins with a comment.
    printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "coq-axiom-or-admit" "core" "$(echo "$orig" | head -c 80)" >> "$markers_tsv"
  done
done

echo "$proof_files" | grep -E '\.v$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_coq_noncode "$f" 2>/dev/null | grep -nE '^[[:space:]]*(Parameters?|Conjectures?)([[:space:]]|$)' | while IFS=: read -r ln rest; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "coq-parameter-or-conjecture" "extended" "$(echo "$rest" | head -c 80)" >> "$markers_tsv"
  done
done

echo "$proof_files" | grep -E '\.v$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_coq_noncode "$f" 2>/dev/null | grep -nE '(^|[^[:alnum:]_])admit([^[:alnum:]_]|$)|(^|[^[:alnum:]_])give_up([^[:alnum:]_]|$)' | while IFS=: read -r ln rest; do
    # A line-leading `admit.` is the documented core form and was already
    # reported by the core pass; do not count it twice. An `admit.` in the
    # MIDDLE of a line (`Proof. admit. Qed.`) is mid-line and is NOT caught by
    # the core pass's anchored pattern, so it is reported here.
    printf '%s' "$rest" | grep -qE '^[[:space:]]*admit\.' && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "coq-admit-tactic" "extended" "$(echo "$rest" | head -c 80)" >> "$markers_tsv"
  done
done

# Lean sorry / axiom (core) and the 2026-10-30 extended set
echo "$proof_files" | grep -E '\.lean$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_lean_noncode "$f" 2>/dev/null | grep -nE '\bsorry\b|^[[:space:]]*axiom[[:space:]]' | while IFS=: read -r ln rest; do
    # Report the ORIGINAL line text (the stripped form is only for matching)
    orig="$(sed -n "${ln}p" "$f" 2>/dev/null)"
    emit_marker "$f" "$ln" "lean-sorry-or-axiom" "core" "$(echo "$orig" | head -c 80)"
  done
done

echo "$proof_files" | grep -E '\.lean$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_lean_noncode "$f" 2>/dev/null \
    | grep -nE '@\[implemented_by|@\[extern\b|\bnative_decide\b|Lean\.(trustCompiler|ofReduceBool)|\badmit\b|^[[:space:]]*(unsafe|partial)[[:space:]]+def\b' \
    | while IFS=: read -r ln rest; do
        case "$rest" in
          *implemented_by*) kind="lean-implemented-by" ;;
          *"@[extern"*)     kind="lean-extern" ;;
          *native_decide*|*trustCompiler*|*ofReduceBool*) kind="lean-native-decide" ;;
          *[[:space:]]def*) kind="lean-unsafe-or-partial-def" ;;
          *)                kind="lean-admit-tactic" ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "$kind" "extended" "$(echo "$rest" | head -c 80)" >> "$markers_tsv"
      done
done

# Agda postulate (core)
echo "$proof_files" | grep -E '\.agda$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_haskellish_noncode "$f" 2>/dev/null | grep -nE '^[[:space:]]*postulate([[:space:]]|$)' | while IFS=: read -r ln rest; do
    emit_marker "$f" "$ln" "agda-postulate" "core" "$(echo "$rest" | head -c 80)"
  done
done

# Agda extended: pragmas that waive a check, flags that disable one, the
# builtin trust primitive, and explicit holes.
echo "$proof_files" | grep -E '\.agda$' | while read -r f; do
  [ -z "$f" ] && continue
  stripped="$(strip_haskellish_noncode "$f" 2>/dev/null)"
  printf '%s\n' "$stripped" \
    | grep -nE '\{-#[[:space:]]*(NON_TERMINATING|TERMINATING)[[:space:]]*#-\}' \
    | while IFS=: read -r ln rest; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "agda-terminating-pragma" "extended" "$(echo "$rest" | head -c 80)" >> "$markers_tsv"
      done
  printf '%s\n' "$stripped" \
    | grep -nE '\{-#[[:space:]]*NON_COVERING[[:space:]]*#-\}' \
    | while IFS=: read -r ln rest; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "agda-non-covering-pragma" "extended" "$(echo "$rest" | head -c 80)" >> "$markers_tsv"
      done
  printf '%s\n' "$stripped" \
    | grep -nE -- '--type-in-type|--no-(termination|positivity|coverage|projection-likeness)-check|--allow-unsolved-metas' \
    | while IFS=: read -r ln rest; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "agda-unsound-flag" "extended" "$(echo "$rest" | head -c 80)" >> "$markers_tsv"
      done
  printf '%s\n' "$stripped" \
    | grep -nF 'primTrustMe' \
    | while IFS=: read -r ln rest; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "agda-primtrustme" "extended" "$(echo "$rest" | head -c 80)" >> "$markers_tsv"
      done
  printf '%s\n' "$stripped" \
    | grep -nF '{!!}' \
    | while IFS=: read -r ln rest; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$ln" "agda-hole" "extended" "$(echo "$rest" | head -c 80)" >> "$markers_tsv"
      done
done

# Idris2 believe_me / assert_total / really_believe_me (core)
echo "$proof_files" | grep -E '\.(idr|idr2)$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_haskellish_noncode "$f" 2>/dev/null | grep -nE 'believe_me|really_believe_me|assert_total' | while IFS=: read -r ln rest; do
    emit_marker "$f" "$ln" "idris-believe-or-assert" "core" "$(echo "$rest" | head -c 80)"
  done
done

# Idris2 top-level partial (core)
echo "$proof_files" | grep -E '\.(idr|idr2)$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_haskellish_noncode "$f" 2>/dev/null | grep -nE '^partial([[:space:]]|$)|^%default[[:space:]]+partial([[:space:]]|$)' | while IFS=: read -r ln rest; do
    emit_marker "$f" "$ln" "idris-partial" "core" "$(echo "$rest" | head -c 80)"
  done
done

# Idris2 holes (extended). `?name` is an unsolved goal; `_` and `%default total`
# are NOT holes and are deliberately absent from this pattern.
echo "$proof_files" | grep -E '\.(idr|idr2)$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_haskellish_noncode "$f" 2>/dev/null | grep -nE '(^|[^[:alnum:]_.?])\?[A-Za-z_][[:alnum:]_]*' | while IFS=: read -r ln rest; do
    # Route through emit_marker, not a bare write: `|||` Idris doc comments
    # survive the shared stripper (it knows `--` and `{- -}`), so a doc line
    # saying "the ?goal hole is discharged below" would otherwise be counted
    # as an unsolved hole. emit_marker applies the comment-line guard.
    emit_marker "$f" "$ln" "idris-hole" "extended" "$(echo "$rest" | head -c 80)"
  done
done

# F* assume val / admit_p (core) and the bare forms (extended).
# Look past blank and comment-only lines for val, retaining the assume line
# for documentation and reporting. A standalone assume remains extended.
echo "$proof_files" | grep -E '\.fst$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_fstar_noncode "$f" 2>/dev/null | awk '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        line = lines[i]; bare = line; continued = 0
        if (line ~ /(^|[^A-Za-z0-9_])assume[[:space:]]*$/) {
          j = i + 1
          while (j <= NR && lines[j] ~ /^[[:space:]]*$/) j++
          if (j <= NR && lines[j] ~ /^[[:space:]]*val([^A-Za-z0-9_]|$)/) {
            continued = 1
            sub(/assume[[:space:]]*$/, "", bare)
          }
        }
        if (continued || line ~ /assume[[:space:]]+val|admit_p/)
          printf "core\t%d\t%s\n", i, line
        gsub(/assume[[:space:]]+val/, " ", bare)
        if (bare ~ /(^|[^A-Za-z0-9_])admit[[:space:]]*\(\)|(^|[^A-Za-z0-9_])assume([^A-Za-z0-9_]|$)/)
          printf "extended\t%d\t%s\n", i, line
      }
    }
  ' | while IFS=$'\t' read -r tier_name ln rest; do
    case "$tier_name" in
      core) emit_marker "$f" "$ln" "fstar-assume-or-admit" "core" "$(echo "$rest" | head -c 80)" ;;
      extended) emit_marker "$f" "$ln" "fstar-assume-or-admit-bare" "extended" "$(echo "$rest" | head -c 80)" ;;
    esac
  done
done

# Dafny {:axiom} (extended). The policy has listed Dafny since #203 but no
# detector was ever wired; the omission was silent, which is the worst kind.
echo "$proof_files" | grep -E '\.dfy$' | while read -r f; do
  [ -z "$f" ] && continue
  strip_dafny_noncode "$f" 2>/dev/null | grep -nF '{:axiom}' | while IFS=: read -r ln rest; do
    emit_marker "$f" "$ln" "dafny-axiom" "extended" "$(echo "$rest" | head -c 80)"
  done
done

# Rust/Haskell soundness-relevant escapes (only inside src/)
if [ -n "$unsafe_files" ]; then
  echo "$unsafe_files" | head -2000 | while read -r f; do
    [ -z "$f" ] && continue
    grep -nE 'unsafePerformIO|unsafeCoerce' "$f" 2>/dev/null | while IFS=: read -r ln rest; do
      # Skip if this is a comment line
      case "$rest" in
        *"//"*"unsafePerformIO"*|*"--"*"unsafePerformIO"*)
          [ -n "$(echo "$rest" | grep -E '^[[:space:]]*//|^[[:space:]]*--')" ] && continue ;;
      esac
      emit_marker "$f" "$ln" "rust-or-hs-unsafe" "core" "$(echo "$rest" | head -c 80)"
    done
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# Tier filter, applied ONCE to the collected list rather than inside each
# detector. Several detectors write their rows directly (they have already
# stripped comments and strings, so the generic comment heuristic would be
# wrong for them); filtering in one place keeps the tier contract auditable
# instead of spread over fifteen loops.
# ─────────────────────────────────────────────────────────────────────────────
if ! $want_core || ! $want_extended; then
  core_flag=0; $want_core && core_flag=1
  ext_flag=0; $want_extended && ext_flag=1
  filtered_tsv="$(mktemp)"
  awk -F'\t' -v wc="$core_flag" -v we="$ext_flag" \
    '($4 == "core" && wc == 1) || ($4 == "extended" && we == 1)' \
    "$markers_tsv" > "$filtered_tsv"
  mv "$filtered_tsv" "$markers_tsv"
fi

core_count=$(awk -F'\t' '$4=="core"' "$markers_tsv" | wc -l)
extended_count=$(awk -F'\t' '$4=="extended"' "$markers_tsv" | wc -l)
marker_count=$((core_count + extended_count))

if [ "$marker_count" -eq 0 ]; then
  echo "[OK] No soundness-relevant escape hatches detected."
  exit 0
fi

echo "[INFO] Found $core_count core-tier and $extended_count extended-tier marker(s)."
if [ "$extended_count" -gt 0 ]; then
  echo "[INFO] Extended tier: mode=$extended_mode, budget=$budget_extended$($budget_file_seen && echo ' (from .trusted-base-budget)' || echo ' (default)')."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Verify each marker is documented:
#   - inline `TRUSTED:`/`AXIOM:`/`OWED:`/`JUSTIFIED:`/`DEBT:` leading comment, OR
#   - enumerated in docs/proof-debt.md (substring match on file:line OR on the
#     identifier captured)
# ─────────────────────────────────────────────────────────────────────────────
debt_docs=()
for cand in docs/proof-debt.md docs/proof-debt.adoc PROOF-NEEDS.md docs/PROOF-NEEDS.md; do
  if [ -f "$cand" ]; then
    debt_docs+=("$cand")
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Load `.trusted-base-ignore` if present (format mirrors `.hypatia-ignore`):
#   - lines starting with `#` are comments;
#   - each non-comment, non-blank line is a path-fragment substring that
#     exempts every marker whose file path contains the fragment.
# Use for: test fixtures that exist to be detected by the scanner, local
# worktree shadows (`.claude/worktrees/`), and other intentional self-scan
# noise. Per-site `TRUSTED:`/`AXIOM:` comments remain the preferred
# mechanism for one-off documented escapes; this file is for whole-path
# exemptions that carry a stated rationale.
# ─────────────────────────────────────────────────────────────────────────────
trusted_base_ignores=()
if [ -f .trusted-base-ignore ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Strip trailing whitespace/CR for cross-platform safety.
    line="${line%$'\r'}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|'#'*) ;;
      *) trusted_base_ignores+=("$line") ;;
    esac
  done < .trusted-base-ignore
  if [ ${#trusted_base_ignores[@]} -gt 0 ]; then
    echo "[INFO] Loaded ${#trusted_base_ignores[@]} pattern(s) from .trusted-base-ignore."
  fi
fi

# A missing proof-debt index is a hard failure ONLY when a core marker needs it.
# Extended markers are reported under the budget instead: the whole point of the
# tier split is that a repo is not failed by the act of widening the detector.
if [ ${#debt_docs[@]} -eq 0 ] && [ ${#trusted_base_ignores[@]} -eq 0 ] && [ "$core_count" -gt 0 ]; then
  echo "[ERROR] No docs/proof-debt.md (or equivalent) found, but $core_count escape hatches exist."
  echo "[ERROR] Seed one per the schema at hyperpolymath/standards/docs/TRUSTED-BASE-REDUCTION-POLICY.adoc."
  exit 1
fi

if [ ${#debt_docs[@]} -gt 0 ]; then
  echo "[OK] proof-debt document(s) found: ${debt_docs[*]}"
fi

# For each marker, check documentation
undocumented=0        # core, undocumented — still a hard failure
extended_undocumented=0
exempted=0
extended_exempted=0
documented=0
extended_documented=0

while IFS=$'\t' read -r f ln kind mtier ctx; do
  [ -z "$f" ] && continue
  # Strip leading ./
  f_clean="${f#./}"

  # 0. .trusted-base-ignore — substring match on the file path. Use for
  #    test fixtures, worktree shadows, and other intentional self-scan
  #    noise that should NOT need per-site documentation.
  is_exempted=false
  for pattern in ${trusted_base_ignores[@]+"${trusted_base_ignores[@]}"}; do
    case "$f_clean" in
      *"$pattern"*) is_exempted=true; break ;;
    esac
  done
  if $is_exempted; then
    if [ "$mtier" = "core" ]; then exempted=$((exempted + 1)); else extended_exempted=$((extended_exempted + 1)); fi
    continue
  fi

  # 1. Inline TRUSTED:/AXIOM:/OWED:/JUSTIFIED:/DEBT: comment in the preceding
  #    comment block. We walk backwards from the marker through consecutive
  #    comment lines (-- / // / ||| / # / * / (*) until we hit a non-comment
  #    line, then check the whole block for the magic word. A 5-line ceiling
  #    (the historical window) was too narrow for real Agda postulates with a
  #    7-15 line prose justification labelled `-- AXIOM:` on its opening line.
  #    See standards#296.
  #
  #    OWED: was documented as recognised by this script since the policy
  #    landed, but was not — every `||| OWED:`-annotated Idris2 assumption
  #    (280 of them in hyperpolymath/proven alone) therefore read as naked
  #    debt. Recognising it repairs a false finding; it does not relax a gate.
  walk_start="$ln"
  while [ "$walk_start" -gt 1 ]; do
    prev_ln=$(( walk_start - 1 ))
    prev_line="$(sed -n "${prev_ln}p" "$f" 2>/dev/null)"
    case "$prev_line" in
      *[!\ \	]*) ;;  # non-blank — fall through to comment test
      *)
        # blank line breaks the comment block.
        break
        ;;
    esac
    trimmed="$(echo "$prev_line" | sed -E 's/^[[:space:]]+//')"
    case "$trimmed" in
      --*|"|||"*|"|||"|"//"*|"/*"*|"*"*|"(*"*|"#"*)
        walk_start="$prev_ln"
        ;;
      *)
        break
        ;;
    esac
  done
  # Also bound by ln-15 as a sanity check — a 15-line "comment block"
  # without a magic word is almost certainly something other than a
  # documented escape hatch.
  hard_floor=$(( ln - 15 ))
  [ "$hard_floor" -gt "$walk_start" ] && walk_start="$hard_floor"
  [ "$walk_start" -lt 1 ] && walk_start=1
  if sed -n "${walk_start},${ln}p" "$f" 2>/dev/null | grep -qE 'TRUSTED:|AXIOM:|OWED:|JUSTIFIED:|DEBT:'; then
    if [ "$mtier" = "core" ]; then documented=$((documented + 1)); else extended_documented=$((extended_documented + 1)); fi
    continue
  fi

  # 2. Mention in ANY of the proof-debt documents — match on `<file>:<line>`
  #    substring, or on the file path alone (in which case we accept any
  #    reference).
  documented_in=""
  for doc in ${debt_docs[@]+"${debt_docs[@]}"}; do
    if grep -qF "$f_clean:$ln" "$doc" 2>/dev/null; then
      documented_in="$doc"
      break
    fi
    if grep -qF "$f_clean" "$doc" 2>/dev/null; then
      documented_in="$doc"
      break
    fi
  done
  if [ -n "$documented_in" ]; then
    if [ "$mtier" = "core" ]; then documented=$((documented + 1)); else extended_documented=$((extended_documented + 1)); fi
    continue
  fi

  # Undocumented.
  if [ "$mtier" = "core" ]; then
    echo "[ERROR] Undocumented escape hatch at $f_clean:$ln ($kind):"
    echo "        $ctx"
    echo "        Annotate with a 'TRUSTED:' or 'AXIOM:' leading comment,"
    echo "        enumerate in any of: ${debt_docs[*]:-<none>}, or"
    echo "        add a path-fragment to .trusted-base-ignore if this is"
    echo "        intentional self-scan noise (e.g. test fixture, worktree shadow)."
    undocumented=$((undocumented + 1))
  else
    # GitHub annotation so the finding is visible on the PR without failing it.
    # `::warning` (not `::error`) matches mode=report; the summary line below
    # is the machine-readable form for the estate board.
    echo "::warning file=${f_clean},line=${ln},title=trusted-base (extended): ${kind}::$ctx"
    echo "[EXTENDED] $f_clean:$ln ($kind)"
    echo "           $ctx"
    extended_undocumented=$((extended_undocumented + 1))
  fi
done < "$markers_tsv"

if [ "$extended_exempted" -gt 0 ]; then
  echo "[OK] $extended_exempted extended-tier marker(s) exempted via .trusted-base-ignore."
fi
if [ "$exempted" -gt 0 ]; then
  echo "[OK] $exempted marker(s) exempted via .trusted-base-ignore."
fi

# Machine-readable summary. Always emitted when markers exist, in every mode, so
# the estate board can trend the number without parsing prose.
echo "TRUSTED-BASE-SUMMARY tier=$tier core_total=$core_count core_undocumented=$undocumented core_documented=$documented core_exempted=$exempted extended_total=$extended_count extended_undocumented=$extended_undocumented extended_documented=$extended_documented extended_exempted=$extended_exempted extended_mode=$extended_mode extended_budget=$budget_extended"

core_failed=false
extended_failed=false

if [ "$undocumented" -gt 0 ]; then
  echo ""
  echo "[ERROR] $undocumented/$core_count escape hatch(es) are undocumented."
  echo "[ERROR] Each must be annotated inline, enumerated in one of: ${debt_docs[*]:-<none>}, or exempted via .trusted-base-ignore."
  echo "[ERROR] See https://github.com/hyperpolymath/standards/blob/main/docs/TRUSTED-BASE-REDUCTION-POLICY.adoc"
  core_failed=true
fi

case "$extended_mode" in
  report)
    if [ "$extended_undocumented" -gt 0 ]; then
      echo ""
      echo "[REPORT] extended-tier: $extended_undocumented/$extended_count marker(s) undocumented (mode=report; budget not enforced)."
      echo "[REPORT] This tier is report-and-budget, not fail-on-sight. To adopt it:"
      echo "[REPORT]   1. run scripts/estate-trusted-base-survey.sh and read the hit list;"
      echo "[REPORT]   2. add a .trusted-base-budget with 'mode: budget' and the measured number;"
      echo "[REPORT]   3. discharge findings down, never raise the budget."
      echo "[REPORT] See docs/TRUSTED-BASE-REDUCTION-POLICY.adoc § 'Extended tier'."
    fi ;;
  budget)
    if [ "$extended_undocumented" -gt "$budget_extended" ]; then
      echo ""
      echo "[ERROR] extended-tier: $extended_undocumented undocumented marker(s) exceed the declared budget of $budget_extended (.trusted-base-budget)."
      echo "[ERROR] Discharge a marker or lower the number; do not raise it."
      extended_failed=true
    else
      echo "[OK] extended-tier: $extended_undocumented/$budget_extended budgeted marker(s) undocumented."
    fi ;;
  strict)
    if [ "$extended_undocumented" -gt 0 ]; then
      echo ""
      echo "[ERROR] extended-tier: $extended_undocumented undocumented marker(s) (mode=strict permits none)."
      extended_failed=true
    else
      echo "[OK] extended-tier: no undocumented markers (mode=strict)."
    fi ;;
esac

if $core_failed || $extended_failed; then
  exit 1
fi

# The summary wording below is deliberately UNCHANGED from standards#211: the
# line is what a human (and, in a few repos, a `grep`) reads to confirm the core
# tier is clean, and a widening is the wrong reason to move it.
if [ "$exempted" -eq "$core_count" ] && [ "$core_count" -gt 0 ]; then
  echo "[OK] All $core_count escape hatch(es) handled (entirely via .trusted-base-ignore exemption)."
elif [ "$core_count" -gt 0 ]; then
  echo "[OK] All $core_count escape hatch(es) are documented (inline annotation, entry in: ${debt_docs[*]:-<none>}, or .trusted-base-ignore exemption)."
fi
if [ "$extended_count" -eq 0 ]; then
  echo "[OK] No extended-tier markers."
fi
exit 0
