#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# check-doctrine-coverage.sh — every prose invariant must say whether a gate
# enforces it, or that nothing does.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS
#
# This estate writes its rules down first: CICD-SIGNAL-DISCIPLINE, the trusted-base
# policy, the Debtfile spec, the exemption mechanisms. Then the code catches up.
# The gap between those two events is invisible, and it is where the damage is
# done: a document states an invariant, readers rely on it, and nothing enforces
# it — so the document is not a rule, it is a claim about a rule.
#
# The failure mode has a shape, and it showed up three times in one pull request
# (standards#1378):
#
#   * a policy table said the extended tier exits 1 in `budget` mode. It exits 0
#     inside the budget. A review bot caught the document, not the code.
#   * a reference-implementation paragraph said a scan "fails the build". It
#     exits 0 without `--strict`.
#   * a budget was described as ratcheted by `check-exemption-ratchet.sh`. That
#     script cannot see the file at all: it compares ledger ENTRY COUNTS and a
#     budget is one integer.
#
# All three are prose asserting enforcement that does not exist. None of them is
# detectable by a linter over the code, because the defect is in the *link*
# between the prose and the code. That link is what this checks.
#
# WHAT IT IS NOT
#
# It does not check whether the enforcement is any good. It cannot: "this script
# mentions the invariant" is not "this script enforces it". What it can do is
# make the claim explicit, machine-readable and reviewable, and refuse silence.
# A wrong `Enforced-by:` is a one-line lie in a diff; an untagged invariant is a
# hole nobody ever looks at.
#
# ─────────────────────────────────────────────────────────────────────────────
# HOW A DOCUMENT PARTICIPATES
#
# Opt-in, per document, exactly once:
#
#   // doctrine-coverage: on
#
# Opt-in rather than automatic because adoption has to be incremental: a
# repository that has never tagged anything must not be red-boarded the day the
# gate is installed (the same reasoning as `scripts/check-retired-names.sh`
# being a no-op without a register).
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT COUNTS AS AN INVARIANT
#
# A section heading whose text is normative:
#
#   starts with Never / Always / No / Do not / Don't / Distinguish / Reject /
#   Refuse / Every / Nothing, or contains must / never / always / every /
#   nothing as a whole word (case-insensitive).
#
# Then the section (heading up to the next heading of the same or a higher
# level) must carry EXACTLY ONE of:
#
#   Enforced-by: scripts/some-gate.sh
#   Review-only: <why no gate can or does catch this>
#
# Both may be written as AsciiDoc comments (`// Enforced-by: ...`) so the tag
# does not appear in the rendered document. The machine does not care which form
# is used; a reader of the diff does, and a hidden tag in a rendered page is
# still a visible claim in a review.
#
# Rules for each, all of which fail the gate:
#
#   * no tag                      — silence is the defect
#   * both tags                   — the claim is ambiguous
#   * Enforced-by path missing    — a dangling claim
#   * Enforced-by path is a doc   — a document enforcing nothing
#   * Enforced-by path never names this document (basename) or the invariant
#     (slug)                     — a claim pointing at an unrelated file
#   * Review-only reason < 40 chars, or TODO / TBD / n/a / none
#                                 — a shrug wearing a tag
#   * a tag on a section that is not normative
#                                 — a stray tag, which usually means an invariant
#                                   was renamed and its tag was left behind
#
# KNOWN LIMITATION, STATED: a MUST buried in a sentence is not detected. This
# checks the headings people re-read and cite, which is where the drift lives.
# Widening it is a change to the keyword list, deliberately, not an accident.
#
# ─────────────────────────────────────────────────────────────────────────────
# USAGE
#
#   check-doctrine-coverage.sh [--path DIR|FILE]...   (default: docs)
#                              [--report]   never fail; print the inventory
#                              [--list]     print one line per invariant
#   -h, --help
#
# Exit: 0 clean (or --report), 1 problems found, 2 usage or configuration error.
#
# Shell + awk + grep only. No Python (estate policy).
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

PATHS=()
REPORT=false
LIST=false

while [ $# -gt 0 ]; do
  case "$1" in
    --path)      PATHS+=("${2:?--path needs a value}"); shift 2 ;;
    --path=*)    PATHS+=("${1#*=}"); shift ;;
    --report)    REPORT=true; shift ;;
    --list)      LIST=true; shift ;;
    -h|--help)   sed -n '2,110p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p'; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ ${#PATHS[@]} -eq 0 ] && PATHS=("docs")

for p in "${PATHS[@]}"; do
  [ -e "$p" ] || { echo "ERROR: no such path '$p'" >&2; exit 2; }
done

# Keywords that make a heading normative. Whole-word matches so `everything`
# does not drag in `every`, and `Mustfile` does not drag in `must`.
NORMATIVE_RE='(^|[^[:alnum:]_])(never|always|every|nothing|distinguish|reject|refuse|must|do not|don.t)([^[:alnum:]_]|$)'
NORMATIVE_START_RE='^(Never|Always|No|Do not|Don.t|Distinguish|Reject|Refuse|Every|Nothing)([^[:alnum:]_]|$)'

# Print a lowercase heading slug with anchor markup removed and runs of
# characters outside a-z and 0-9 replaced by hyphens.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/\[\[[^]]*\]\]//g; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

problems=0
inv_total=0
inv_enforced=0
inv_review=0

# Print a diagnostic and increment the problem count in the current shell.
problem() { printf '  %s\n' "$*"; problems=$((problems + 1)); }

files=()
while IFS= read -r f; do files+=("$f"); done < <(
  for p in "${PATHS[@]}"; do
    if [ -d "$p" ]; then find "$p" -type f -name '*.adoc'; else printf '%s\n' "$p"; fi
  done | sort -u
)

participating=0
for doc in "${files[@]}"; do
  grep -qE '^//+ *doctrine-coverage: *on' "$doc" 2>/dev/null || continue
  participating=$((participating + 1))

  # One record per heading: line number, level, text. `-1` is the document head
  # so a tag written before the first heading is still attributable (and then
  # reported as stray, which is what it is).
  headings="$(grep -nE '^=+ ' "$doc" | while IFS= read -r rec; do
      ln="${rec%%:*}"
      rest="${rec#*:}"
      eq="${rest%% *}"
      level=${#eq}
      heading="$(printf '%s' "$rest" | sed -E 's/^=+[[:space:]]*//')"
      printf '%s\t%s\t%s\n' "$ln" "$level" "$heading"
    done)"

  while IFS=$'\t' read -r ln level heading; do
    [ -z "${ln:-}" ] && continue
    # The body stops at the NEXT HEADING OF ANY LEVEL, not at the next heading
    # of the same-or-higher level. Otherwise a parent section swallows its
    # children's tags and is reported as a stray: `== Probe discipline` would
    # appear to carry the tag belonging to its `=== No fallback` child.
    next_ln=$(awk -F'\t' -v cur="$ln" '
      $1 > cur { print $1; exit }' <<< "$headings")
    end_ln=${next_ln:-$(( $(wc -l < "$doc") + 1 ))}

    body="$(sed -n "$((ln + 1)),$((end_ln - 1))p" "$doc")"
    slug="$(slugify "$heading")"

    is_inv=false
    if printf '%s' "$heading" | grep -qEi "$NORMATIVE_START_RE" \
    || printf '%s' "$heading" | grep -qEi "$NORMATIVE_RE"; then
      is_inv=true
    fi

    enforced_by="$(printf '%s\n' "$body" | sed -nE 's|^(// )?Enforced-by:[[:space:]]*||; t trim; b; :trim; s|[[:space:]]+$||; p' | head -1)"
    review_only="$(printf '%s\n' "$body" | sed -nE 's|^(// )?Review-only:[[:space:]]*||; t trim; b; :trim; s|[[:space:]]+$||; p' | head -1)"
    n_enforced="$(printf '%s\n' "$body" | grep -cE '^(// )?Enforced-by:[[:space:]]*')"
    n_review="$(printf '%s\n' "$body" | grep -cE '^(// )?Review-only:[[:space:]]*')"

    if ! $is_inv; then
      if [ "$n_enforced" -gt 0 ] || [ "$n_review" -gt 0 ]; then
        echo "$doc:$ln: stray tag on a heading that is not normative: \"$heading\""
        problem "line $ln: a tag sits on a section that states no invariant; retag or remove it"
      fi
      continue
    fi

    inv_total=$((inv_total + 1))
    $LIST && printf '%s:%s\t%s\t%s\n' "$doc" "$ln" "$slug" \
      "$([ "$n_enforced" -gt 0 ] && echo "enforced-by=$enforced_by" || echo "review-only")"

    if [ "$n_enforced" -eq 0 ] && [ "$n_review" -eq 0 ]; then
      echo "$doc:$ln: UNTAGGED invariant: \"$heading\""
      problem "add 'Enforced-by: <script>' or 'Review-only: <why nothing does>'"
      continue
    fi
    if { [ "$n_enforced" -gt 0 ] && [ "$n_review" -gt 0 ]; } \
      || [ "$n_enforced" -gt 1 ] || [ "$n_review" -gt 1 ]; then
      echo "$doc:$ln: AMBIGUOUS invariant: \"$heading\""
      problem "must carry exactly one Enforced-by or Review-only tag"
      continue
    fi

    if [ "$n_enforced" -gt 0 ]; then
      if [ ! -e "$enforced_by" ]; then
        echo "$doc:$ln: DANGLING claim: Enforced-by $enforced_by (no such path)"
        problem "the enforcing path does not exist"
        continue
      fi
      case "$enforced_by" in
        *.adoc|*.md)
          echo "$doc:$ln: CLAIM IS A DOCUMENT: Enforced-by $enforced_by"
          problem "a document cannot enforce anything; name the script, test or workflow"
          continue ;;
      esac
      base="$(basename "$doc")"
      if ! grep -qF "$base" "$enforced_by" 2>/dev/null \
      && ! grep -qiF "$slug" "$enforced_by" 2>/dev/null; then
        echo "$doc:$ln: UNLINKED claim: Enforced-by $enforced_by names neither \"$base\" nor \"$slug\""
        problem "the named file has no reference to this invariant; cite the doc or use the slug"
        continue
      fi
      inv_enforced=$((inv_enforced + 1))
    else
      reason_len=${#review_only}
      if [ "$reason_len" -lt 40 ]; then
        echo "$doc:$ln: THIN reason ($reason_len chars): Review-only $review_only"
        problem "a Review-only tag needs a reason a reader can act on (>= 40 chars)"
        continue
      fi
      case "$(printf '%s' "$review_only" | tr '[:upper:]' '[:lower:]')" in
        *todo*|*tbd*|"n/a"*|"none"*)
          echo "$doc:$ln: PLACEHOLDER reason: Review-only $review_only"
          problem "TODO/TBD/none is the untagged case wearing a tag"
          continue ;;
      esac
      inv_review=$((inv_review + 1))
    fi
  done <<< "$headings"
done

echo
printf '[doctrine] %s document(s) opted in; %s invariant(s): %s enforced, %s review-only\n' \
  "$participating" "$inv_total" "$inv_enforced" "$inv_review"

if [ "$inv_total" -eq 0 ] && [ "$participating" -gt 0 ]; then
  echo "[doctrine] NOTE: documents opted in but no normative heading was found."
  echo "[doctrine] That is a detection gap, not a clean bill: check the wording."
fi

if [ "$problems" -gt 0 ]; then
  echo "[FAIL] $problems problem(s): an invariant must say what enforces it, or admit nothing does."
  if $REPORT; then
    echo "[NOTE] report-only: re-run without --report to make this fatal."
    exit 0
  fi
  exit 1
fi

echo "[OK] every opted-in invariant states its enforcement status."
exit 0
