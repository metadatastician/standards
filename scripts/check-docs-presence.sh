#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# check-docs-presence.sh — gate on core repository documentation.
#
# Replaces the `::warning::`-only "Check documentation" step in
# governance-reusable.yml, which could not fail over any input (standards#505).
#
# SPLIT GATE (wave8 doctrine: promote honestly, no manufactured red noise).
# Blast radius measured 2026-07-21 over the 412 real repo-root callers of
# governance-reusable in the local estate checkout:
#
#   README        0/412 missing  -> BLOCKING NOW. Arming reds nobody.
#   LICENSE       0/412 missing  -> BLOCKING NOW. Arming reds nobody.
#   CONTRIBUTING 54/412 missing  -> WARN until the cutoff, then BLOCKING.
#
# The CONTRIBUTING cutoff is a real date that flips itself. It is not a flag
# defaulting to off: on the cutoff date this check starts failing with no
# further edit to this file. That is the difference between a scheduled gate
# and theatre.
#
# Accepted filenames follow the estate documentation policy (AsciiDoc is the
# default; GitHub-required community-health files stay Markdown):
#   README.adoc | README.md
#   LICENSE | LICENSE.txt | LICENSE.md
#   CONTRIBUTING.md | CONTRIBUTING.adoc
#     | .github/CONTRIBUTING.md | .github/CONTRIBUTING.adoc
#     | docs/CONTRIBUTING.md    | docs/CONTRIBUTING.adoc
#     | 3-practice/CONTRIBUTING.adoc
#
# .github/ and docs/ are accepted because GitHub itself auto-discovers a
# community-health file in either location, and repos in this estate have been
# deliberately relocating theirs there (launch-scaffolder d426ea4d: "the estate
# canonical location is .github/CONTRIBUTING.md, which GitHub auto-discovers").
# Before this change the gate asked "is there a CONTRIBUTING at the repo root?"
# while its consumers had been told to answer "is there a CONTRIBUTING GitHub
# can find?" -- a guard asking a different question than its consumer. A census
# of 516 local clones on 2026-09-22 found 19 repos reported missing that in fact
# carry the file under .github/ or docs/; 94 are genuinely missing it and are
# unaffected by this change. This strictly widens WHERE the gate looks; it does
# not weaken WHAT it asks.
#
# CONTRIBUTING.adoc at the repo root is accepted because the estate policy named
# above makes AsciiDoc the default, and it is what the estate actually uses:
# sampling 40 repos on 2026-09-18 found 32 carrying a root CONTRIBUTING.adoc and
# no CONTRIBUTING.md, versus 2 genuinely missing the document. Without it this
# gate failed 94% of the repos it reported as non-compliant, the day the
# CONTRIBUTING cutoff armed.
#
# Usage: check-docs-presence.sh [repo-root]
#
# Environment (test seams — the shipped policy is the default in each case):
#   ENFORCE_CONTRIBUTING_FROM   YYYY-MM-DD; enforcement begins ON this date.
#   DOCS_TODAY                  YYYY-MM-DD; overrides "now" so the pre-cutoff
#                               and post-cutoff branches are both testable.
#
# Exit: 0 = pass (or in-grace warning), 1 = policy failure or bad configuration.

set -euo pipefail

ROOT="${1:-.}"

# Enforcement begins ON this date (inclusive), estate-wide, for CONTRIBUTING.
ENFORCE_CONTRIBUTING_FROM="${ENFORCE_CONTRIBUTING_FROM:-2026-08-21}"
TODAY="${DOCS_TODAY:-$(date -u +%Y-%m-%d)}"

# A malformed date would make the lexicographic comparison below silently
# choose the grace branch forever — i.e. it would turn this gate back into the
# fake gate it replaces. Refuse to run rather than run un-armed.
valid_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}
require_date() {
  local name="$1" value="$2"
  if ! valid_date "$value"; then
    echo "::error::check-docs-presence: $name='$value' is not YYYY-MM-DD."
    echo "Refusing to run: an unparseable cutoff would silently disarm this gate."
    exit 1
  fi
}
require_date ENFORCE_CONTRIBUTING_FROM "$ENFORCE_CONTRIBUTING_FROM"
require_date DOCS_TODAY "$TODAY"

if [ ! -d "$ROOT" ]; then
  echo "::error::check-docs-presence: '$ROOT' is not a directory."
  exit 1
fi

# have <path>... -> 0 if any of the candidate paths exists, relative to the root.
have() {
  local f
  for f in "$@"; do
    [ -f "$ROOT/$f" ] && return 0
  done
  return 1
}

blocking_missing=""
grace_missing=""

have README.adoc README.md      || blocking_missing="$blocking_missing README"
have LICENSE LICENSE.txt LICENSE.md || blocking_missing="$blocking_missing LICENSE"

if ! have CONTRIBUTING.md CONTRIBUTING.adoc \
          .github/CONTRIBUTING.md .github/CONTRIBUTING.adoc \
          docs/CONTRIBUTING.md docs/CONTRIBUTING.adoc \
          3-practice/CONTRIBUTING.adoc; then
  # String comparison is sound here: YYYY-MM-DD sorts chronologically, and both
  # operands are format-validated above.
  if [[ "$TODAY" < "$ENFORCE_CONTRIBUTING_FROM" ]]; then
    grace_missing="CONTRIBUTING"
  else
    blocking_missing="$blocking_missing CONTRIBUTING"
  fi
fi

if [ -n "$grace_missing" ]; then
  echo "::warning::Missing docs (grace period):$grace_missing — this becomes a" \
       "BLOCKING failure on $ENFORCE_CONTRIBUTING_FROM (today is $TODAY)."
fi

if [ -n "$blocking_missing" ]; then
  echo "::error::Missing required documentation:$blocking_missing"
  echo
  echo "Required at the repository root (either extension where two are listed):"
  echo "  README.adoc      (or README.md)"
  echo "  LICENSE          (or LICENSE.txt / LICENSE.md)"
  echo
  echo "CONTRIBUTING is accepted at any location GitHub auto-discovers:"
  echo "  CONTRIBUTING.md          (or CONTRIBUTING.adoc)"
  echo "  .github/CONTRIBUTING.md  (or .github/CONTRIBUTING.adoc)"
  echo "  docs/CONTRIBUTING.md     (or docs/CONTRIBUTING.adoc)"
  echo "  3-practice/CONTRIBUTING.adoc"
  echo
  echo "Estate policy: docs are AsciiDoc by default; see metadatastician/standards."
  exit 1
fi

if [ -n "$grace_missing" ]; then
  # Never claim a pass while a required file is absent. The job is green only
  # because the cutoff has not arrived — say exactly that.
  echo "NOT YET ENFORCED: CONTRIBUTING is missing but inside the grace window."
  exit 0
fi

echo "✅ Core documentation present (README, LICENSE, CONTRIBUTING)"
