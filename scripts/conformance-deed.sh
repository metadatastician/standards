#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# conformance-deed.sh — the caller-relevant part of the DEED conformance lane,
# as ONE implementation. .github/workflows/deed-conformance.yml (the reusable)
# and the template's inline governance both call it, so the two cannot drift.
# Owner ruling Q6 (2026-11-14): the checks live in the deprecated reusable AND
# in the template's inline jobs.
#
# Usage:
#   conformance-deed.sh lint   lint every committed *.deed with the linter in $T
#   conformance-deed.sh warn   turn the lint log's `FAIL <path>: <msg>` lines into
#                              ::warning:: annotations (advisory mode only; the
#                              caller decides when to run it)
#
# Environment:
#   T              directory holding deed_lint.js (required)
#   REQUIRE_FILES  "true": a repository with no .deed file fails (default false)
#   ADVISORY       "true": annotations are warnings, not errors (default false)
#   RUNNER_TEMP    scratch directory; the lint log is $RUNNER_TEMP/deed-lint.log
#
# The checkout of the standards canon (.deed-canon, .standards-checkout) is
# never linted as the caller's own deeds. Needs bun on PATH. GitHub runs a step
# with `bash -e -o pipefail`; every no-match grep below is guarded.
set -euo pipefail
: "${RUNNER_TEMP:=$(mktemp -d)}"
: "${REQUIRE_FILES:=false}" "${ADVISORY:=false}"

cmd_lint() {
  : "${T:?T must name the directory holding deed_lint.js}"
  find . -name '*.deed' -not -path './.deed-canon/*' -not -path './.standards-checkout/*' -not -path './1-formats/deed/tools/fixtures/invalid/*' -not -path './1-formats/deed/tools/fixtures/heads/invalid/*' -not -path './1-formats/deed/tools/fixtures/bang/invalid/*' -not -path './1-formats/deed/tools/fixtures/edict/invalid/*' -print | sort > "$RUNNER_TEMP/deeds"
  if [ ! -s "$RUNNER_TEMP/deeds" ]; then
    if [ "$REQUIRE_FILES" = "true" ]; then
      # Advisory mode must not attach error-severity annotations.
      sev=error; [ "$ADVISORY" = "true" ] && sev=warning
      echo "::${sev}::require-files is set and no committed .deed file was found"
      exit 1
    fi
    echo "no committed .deed files — nothing to lint"
    exit 0
  fi
  echo "linting $(wc -l < "$RUNNER_TEMP/deeds") file(s)"
  xargs bun "$T/deed_lint.js" < "$RUNNER_TEMP/deeds" 2>&1 | tee -a "$RUNNER_TEMP/deed-lint.log"
  # The (egress …) clause profile (ADR-009). A deed without the clause
  # passes. Its invalid fixtures are grammatical deeds, so they are
  # excluded here rather than from the grammar lint above.
  grep -v '^\./1-formats/deed/tools/fixtures/egress/invalid/' "$RUNNER_TEMP/deeds" \
    | xargs bun "$T/deed_lint.js" --egress 2>&1 | tee -a "$RUNNER_TEMP/deed-lint.log"
}

cmd_warn() {
  # GitHub runs this with `bash -e -o pipefail`: every no-match grep
  # below is guarded, so a run with no FAIL line (a missing log, or
  # require-files with no deed) still reaches its closing warning.
  # deed_lint prints `FAIL <path>: <message>`. Annotate each (capped,
  # GitHub shows few), then say plainly that nothing was enforced.
  log="$RUNNER_TEMP/deed-lint.log"
  [ -f "$log" ] || : > "$log"
  n=$( { grep -c '^FAIL ' "$log" || true; } | head -n 1)
  # Sort to a file, then cap from the file: `sort | head` would give sort a
  # SIGPIPE (141) once head has its 30 lines, which pipefail turns into a
  # failed step before the closing count.
  { grep '^FAIL ' "$log" || true; } | sort -u > "$RUNNER_TEMP/deed-fails.txt"
  head -n 30 "$RUNNER_TEMP/deed-fails.txt" | while IFS= read -r line; do
    rest="${line#FAIL }"; path="${rest%%: *}"; msg="${rest#*: }"
    # Workflow-command escaping: the property needs % CR LF : , and
    # the data part needs % CR LF (toolkit escapeProperty / escapeData).
    path="${path#./}"
    path="${path//'%'/%25}"; path="${path//$'\r'/%0D}"; path="${path//$'\n'/%0A}"; path="${path//:/%3A}"; path="${path//,/%2C}"
    msg="${msg//'%'/%25}"; msg="${msg//$'\r'/%0D}"; msg="${msg//$'\n'/%0A}"
    printf '::warning file=%s::deed conformance (advisory): %s\n' "$path" "$msg"
  done
  if [ "${n:-0}" -eq 0 ]; then
    echo "::warning::deed conformance (advisory): the check did not run to completion (no finding was recorded); see the step log. Not enforced."
  else
    echo "::warning::deed conformance (advisory): ${n} finding(s); not enforced. Fix them, then call deed-conformance.yml with advisory: false to enforce."
  fi
}

case "${1:-}" in
  lint) cmd_lint ;;
  warn) cmd_warn ;;
  *) sed -n '5,24p' "$0" >&2; exit 2 ;;
esac
