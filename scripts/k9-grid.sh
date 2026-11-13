#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# k9-grid.sh — render the compact verdict grid for the K9-DEED conformance lane.
# Policy and anatomy: docs/VERDICT-GRID-SPEC.adoc. Logic: scripts/lib/k9-grid.jq.
# The lane that calls it: .github/workflows/k9-conformance.yml.
#
# Usage:
#   k9-grid.sh render --out DIR --results FILE [evidence] [identity]
#     evidence
#       --results FILE        k9-validate.sh --json output, one record per line
#       --expected FILE       the files the lane set out to check, one per line
#       --ledger FILE         the caller's .machine_readable/k9-contract-debt.txt
#       --ledger-growth FILE  ledger entries the PR adds with no Ratchet-exception
#                             naming the ledger, one per line: they exempt nothing
#       --changed FILE        files the PR touches, one per line
#       --base-unresolved     the PR base/head range could not be diffed
#       --require-files       an empty corpus is a failing row, not a grey one
#       --selftest LOG --selftest-code N     validator --self-test evidence
#       --typecheck LOG --typecheck-code N   nickel typecheck of the contract
#       --corpus-code N       the validator's exit status over the corpus
#       --coord-results FILE  coordination.k9 validator records, one JSON object per line:
#                             {"file":PATH,"verdict":"pass"|"fail","message":TEXT}. Gives the
#                             coordination.k9 files their own grid category; a file the K9
#                             validator routed to the coordination dialect with no record here
#                             is indeterminate, never green
#       --previous FILE       body of the previous grid comment (delta column)
#     identity
#       --lane NAME           grid lane (default: k9)
#       --sha SHA --run ID --url URL --pr N --repo OWNER/NAME
#       --canon-ref SHA       the metadatastician/standards commit that supplied the validator
#   k9-grid.sh baseline FILE
#     Print the baseline embedded in a previous comment body, or null.
#
# Outputs in DIR: report.json (structured), report.md (the grid), badge.json
# (shields.io endpoint schema). The two JSON files are I-JSON serialised as
# JCS (3-practice/JSON-POLICY.adoc): through `ijson-jcs canon` when it is on
# PATH, else jq's sorted compact form, which is byte-identical for the ASCII,
# integer-only documents this renderer emits. Exit 0 when a report was
# rendered, whatever its verdict; exit 2 on a usage error. Gating is the
# caller's decision, made from report.json, never from this exit code.
#
# Dependencies: bash, jq, sha256sum, base64. Optional: ijson-jcs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JQ_LIB="$SCRIPT_DIR/lib/k9-grid.jq"

# Print the invocation summary to stderr and terminate with status 2.
usage() { sed -n '5,38p' "$0" >&2; exit 2; }

# A path list file to a JSON array; a missing file is an empty list, and so
# is a file of comments and blanks (grep's no-match exit is not an error).
list_json() {
  if [ -n "${1:-}" ] && [ -f "$1" ]; then
    { grep -vE '^[[:space:]]*(#|$)' "$1" || true; } | jq -R . | jq -s .
  else
    echo '[]'
  fi
}

# A log file plus exit status to {code, output}; a missing log is null code.
# An omitted status is also null; a status in a present log that jq cannot
# parse as a number causes an error to reach the caller.
evidence_json() {
  local log="${1:-}" code="${2:-}"
  if [ -n "$log" ] && [ -f "$log" ]; then
    jq -Rs --arg code "$code" '{output: ., code: (if $code == "" then null else ($code | tonumber) end)}' "$log"
  else
    jq -n '{output: "", code: null}'
  fi
}

# results.jsonl to a JSON array; a line that is not JSON is kept as evidence
# of malformed validator output rather than dropped.
results_json() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || { echo '[]'; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
      printf '%s\n' "$line"
    else
      jq -n --arg l "$line" '{malformed: $l}'
    fi
  done < "$file" | jq -s .
}

# coordination.k9 records to a JSON array, or null when the lane supplied no
# such evidence (null keeps the category out of a grid with no routed file).
# A line that is not JSON is kept as malformed evidence.
coord_json() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || { echo null; return; }
  results_json "$file"
}

# Serialise JSON from stdin to stdout with one final LF, preferring ijson-jcs
# and falling back to jq's sorted compact form. Serialiser errors propagate.
canon_json() {
  # ijson-jcs canon emits the JCS bytes with no final newline; the policy
  # wants exactly one. sed adds one only when it is missing.
  if command -v ijson-jcs >/dev/null 2>&1; then
    ijson-jcs canon | sed -e '$a\'
  else
    jq -S -c . | sed -e '$a\'
  fi
}

# Print one baseline object from the last matching marker in the supplied
# comment file. Missing or empty files, absent markers, payloads over 32000
# encoded characters, decoding errors and invalid category counts yield null.
# Schema, profile and revision comparability are checked later by delta.
baseline_of() {
  local file="$1" b64
  [ -s "$file" ] || { echo null; return; }
  b64=$( { grep -o '<!-- k9-baseline:[A-Za-z0-9+/=]* -->' "$file" || true; } | tail -n1 \
        | sed 's/^<!-- k9-baseline://; s/ -->$//')
  if [ -z "$b64" ] || [ "${#b64}" -gt 32000 ]; then echo null; return; fi
  # Exactly one JSON value comes out, whatever the marker holds: the decoded
  # text is slurped and accepted only as a single object, and any decode or
  # validation failure is one null (not a value followed by a null). The
  # caller feeds this to --argjson, which rejects two values.
  local out
  out=$(printf '%s' "$b64" | base64 -d 2>/dev/null | jq -c -s '
    (if length == 1 then .[0] else null end)
    | if type == "object" and (.categories | type) == "array"
       and all(.categories[]; . as $c | ($c.id | type) == "string" and ($c.counts | type) == "object"
         and all(["passed", "failed", "indeterminate", "not_applicable", "advisory", "warnings"][]; . as $k
           | ($c.counts | has($k)) and ($c.counts[$k] | type) == "number" and $c.counts[$k] >= 0))
    then . else null end' 2>/dev/null) || out=null
  printf '%s\n' "${out:-null}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  baseline)
    [ -n "${1:-}" ] || usage
    baseline_of "$1"
    ;;
  render)
    out="" results="" expected="" ledger="" growth="" changed="" prev="" lane="k9"
    selftest="" selftest_code="" typecheck="" typecheck_code="" corpus_code="" coord=""
    base_resolved=true require_files=false sha="" run="local" url="" pr="local" repo="" canon=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) out="$2"; shift 2 ;;
        --results) results="$2"; shift 2 ;;
        --expected) expected="$2"; shift 2 ;;
        --ledger) ledger="$2"; shift 2 ;;
        --ledger-growth) growth="$2"; shift 2 ;;
        --changed) changed="$2"; shift 2 ;;
        --base-unresolved) base_resolved=false; shift ;;
        --require-files) require_files=true; shift ;;
        --selftest) selftest="$2"; shift 2 ;;
        --selftest-code) selftest_code="$2"; shift 2 ;;
        --typecheck) typecheck="$2"; shift 2 ;;
        --typecheck-code) typecheck_code="$2"; shift 2 ;;
        --corpus-code) corpus_code="$2"; shift 2 ;;
        --coord-results) coord="$2"; shift 2 ;;
        --previous) prev="$2"; shift 2 ;;
        --lane) lane="$2"; shift 2 ;;
        --sha) sha="$2"; shift 2 ;;
        --run) run="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        --pr) pr="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        --canon-ref) canon="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage ;;
      esac
    done
    [ -n "$out" ] && [ -n "$results" ] || usage
    [ -f "$JQ_LIB" ] || { echo "missing $JQ_LIB" >&2; exit 2; }
    mkdir -p "$out"

    previous=null
    [ -n "$prev" ] && previous=$(baseline_of "$prev")

    # The profile names what produced the grid: this renderer, the standards
    # commit that supplied validator and contract, the ledger, the lane and
    # the corpus the lane set out to check (as conformance-report.mjs does).
    # Two revisions compare only under the same profile, so a corpus that
    # gained or lost a file is never read as fewer or more failures.
    profile=$( { cat "$0" "$JQ_LIB"; [ -n "$ledger" ] && [ -f "$ledger" ] && cat "$ledger";
                 printf '%s\n' "$canon" "$lane"; list_json "$expected" | jq -c 'sort'; } | sha256sum | cut -d' ' -f1)

    dirty=false
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      [ -z "$sha" ] && sha=$(git rev-parse HEAD)
      git diff --quiet HEAD 2>/dev/null || dirty=true
    fi

    corpus_json=null
    [ -n "$corpus_code" ] && corpus_json="$corpus_code"

    jq -n --argjson results "$(results_json "$results")" --argjson expected "$(list_json "$expected")" \
      --argjson ledger "$(list_json "$ledger")" --argjson growth "$(list_json "$growth")" --argjson changed "$(list_json "$changed")" \
      --argjson base_resolved "$base_resolved" --argjson require_files "$require_files" --argjson selftest "$(evidence_json "$selftest" "$selftest_code")" \
      --argjson typecheck "$(evidence_json "$typecheck" "$typecheck_code")" --argjson corpus_code "$corpus_json" \
      --argjson coord "$(coord_json "$coord")" --arg profile "$profile" --arg lane "$lane" --arg sha "$sha" --arg run "$run" --arg url "$url" \
      --arg pr "$pr" --arg repo "$repo" --argjson dirty "$dirty" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg canon "$canon" \
      '{results: $results, expected: $expected, ledger: $ledger, ledger_growth: $growth, changed: $changed, base_resolved: $base_resolved, require_files: $require_files,
        selftest: $selftest, typecheck: $typecheck, corpus_code: $corpus_code, coord: $coord, profile: $profile,
        identity: {lane: $lane, sha: $sha, run: $run, url: $url, pr: $pr, repo: $repo, dirty: $dirty,
                   generated: $generated, canon_ref: $canon}}' \
      | jq --arg mode build --argjson previous null -f "$JQ_LIB" | canon_json > "$out/report.json"

    jq -r --arg mode render --argjson previous "$previous" -f "$JQ_LIB" "$out/report.json" > "$out/report.md"
    jq --arg mode badge --argjson previous null -f "$JQ_LIB" "$out/report.json" | canon_json > "$out/badge.json"

    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$out/report.md" >> "$GITHUB_STEP_SUMMARY"; fi
    if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "state=$(jq -r .state "$out/report.json")" >> "$GITHUB_OUTPUT"; fi
    cat "$out/report.md"
    ;;
  *) usage ;;
esac
