#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# verdict-grid.sh — render the compact verdict grid for a findings lane.
# Policy and anatomy: docs/VERDICT-GRID-SPEC.adoc. Logic: scripts/lib/verdict-grid.jq.
#
# Usage:
#   verdict-grid.sh render --out DIR [sources] [identity]
#     sources
#       --hypatia FILE        Raw Hypatia findings array (alert/advisory counts only)
#       --hypatia-sarif FILE  Baseline/scope-filtered SARIF (authoritative grade)
#       --hypatia-sarif-unscoped FILE  Baseline-filtered SARIF before exclusions (report-only)
#       --hypatia-baseline-unverified  Baseline present but its SARIF filter did not complete
#       --panic FILE          panic-attack status envelope
#       --pons FILE           pons asinorum status envelope
#       --report-backs DIR    gitbot-fleet report-back envelopes, one *.json per member
#       --enrolment FILE      gitbot-fleet enrolment manifest for this repository
#       --previous FILE       body of the previous grid comment (delta column)
#     scope (what the grid GRADES; every finding is still reported and counted)
#       --changed FILE        newline-separated paths this change touches, as
#                             from `git diff --name-only base...head`. Switches
#                             the grid to delta mode: only findings in these
#                             files can move a row's colour. Without it the grid
#                             grades the whole repository, which means the
#                             verdict cannot change on an ordinary pull request.
#       --exclude-prefix P    repeatable. Findings whose path starts with P are
#                             reported but never graded, in either mode. For
#                             frozen history (9-archive/) that cannot be edited.
#     identity
#       --lane NAME           grid lane (default: hypatia)
#       --sha SHA --run ID --url URL --pr N --repo OWNER/NAME
#       --hypatia-ref SHA --panic-ref SHA --pons-ref SHA
#   verdict-grid.sh baseline FILE
#     Print the baseline embedded in a previous comment body, or null.
#
# Outputs in DIR: report.json (structured), report.md (the grid), badge.json
# (shields.io endpoint schema). Exit 0 when a report was rendered, whatever its
# verdict; exit 2 on a usage error. Gating is the caller's decision, made from
# report.json, never from this exit code.
#
# Dependencies: bash, jq, sha256sum, base64.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JQ_LIB="$SCRIPT_DIR/lib/verdict-grid.jq"

usage() { sed -n '5,30p' "$0" >&2; exit 2; }

# One source record per evidence file: present? valid JSON? parsed document.
source_record() {
  local kind="$1" name="$2" file="${3:-}"
  if [ -z "$file" ] || [ ! -e "$file" ]; then
    jq -n --arg k "$kind" --arg n "$name" '{kind: $k, name: $n, present: false, valid: false, doc: null}'
  elif [ -s "$file" ] && jq -e -s 'length == 1' "$file" >/dev/null 2>&1; then
    jq -c -s --arg k "$kind" --arg n "$name" '{kind: $k, name: $n, present: true, valid: true, doc: .[0]}' "$file"
  else
    jq -n --arg k "$kind" --arg n "$name" '{kind: $k, name: $n, present: true, valid: false, doc: null}'
  fi
}

baseline_of() {
  local file="$1" b64
  [ -s "$file" ] || { echo null; return; }
  b64=$( { grep -o '<!-- verdict-grid-baseline:[A-Za-z0-9+/=]* -->' "$file" || true; } | tail -n1 \
        | sed 's/^<!-- verdict-grid-baseline://; s/ -->$//')
  if [ -z "$b64" ] || [ "${#b64}" -gt 32000 ]; then echo null; return; fi
  printf '%s' "$b64" | base64 -d 2>/dev/null | jq -c '
    if type == "object" and (.reporters | type) == "array"
       and all(.reporters[]; (.id | type) == "string" and (.counts | type) == "object"
         and all(.counts[]; type == "number" and . >= 0))
    then . else null end' 2>/dev/null || echo null
}

cmd="${1:-}"; shift || true
case "$cmd" in
  baseline)
    [ -n "${1:-}" ] || usage
    baseline_of "$1"
    ;;
  render)
    out="" hyp="" sarif="" unscoped_sarif="" unscoped_requested=false pan="" pon="" backs="" enrol="" prev="" lane="hypatia"
    baseline_verified=true
    sha="" run="local" url="" pr="local" repo="" href="" pref="" qref=""
    changed="" excludes=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) out="$2"; shift 2 ;;
        --hypatia) hyp="$2"; shift 2 ;;
        --hypatia-sarif) sarif="$2"; shift 2 ;;
        --hypatia-sarif-unscoped) unscoped_sarif="$2"; unscoped_requested=true; shift 2 ;;
        --hypatia-baseline-unverified) baseline_verified=false; shift ;;
        --panic) pan="$2"; shift 2 ;;
        --pons) pon="$2"; shift 2 ;;
        --report-backs) backs="$2"; shift 2 ;;
        --enrolment) enrol="$2"; shift 2 ;;
        --previous) prev="$2"; shift 2 ;;
        --lane) lane="$2"; shift 2 ;;
        --sha) sha="$2"; shift 2 ;;
        --run) run="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        --pr) pr="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        --hypatia-ref) href="$2"; shift 2 ;;
        --panic-ref) pref="$2"; shift 2 ;;
        --pons-ref) qref="$2"; shift 2 ;;
        --changed) changed="$2"; shift 2 ;;
        --exclude-prefix) excludes="${excludes}${2}"$'\n'; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage ;;
      esac
    done
    [ -n "$out" ] || usage
    [ -f "$JQ_LIB" ] || { echo "missing $JQ_LIB" >&2; exit 2; }
    mkdir -p "$out"

    sources=$(mktemp); trap 'rm -f "$sources"' EXIT
    {
      source_record hypatia hypatia "$hyp"
      source_record hypatia-sarif hypatia-sarif "$sarif"
      if [ "$unscoped_requested" = true ]; then
        source_record hypatia-unscoped-sarif hypatia-unscoped-sarif "$unscoped_sarif"
      fi
      source_record panic panic-attack "$pan"
      source_record pons pons-asinorum "$pon"
      if [ -n "$backs" ] && [ -d "$backs" ]; then
        for f in "$backs"/*.json; do
          [ -e "$f" ] || continue
          source_record report-back "$(basename "$f" .json)" "$f"
        done
      fi
    } | jq -s . > "$sources"

    enrolment=null
    if [ -n "$enrol" ]; then
      if [ -s "$enrol" ] && jq -e 'type == "object" and (.reporters | type) == "object"' "$enrol" >/dev/null 2>&1; then
        enrolment=$(jq -c . "$enrol")
      else
        # A malformed enrolment manifest is itself evidence that cannot be read.
        enrolment='{"reporters":{"gitbot-fleet enrolment":{"title":"gitbot-fleet enrolment","enrolled":true}}}'
        echo "warning: enrolment manifest unreadable; recorded as missing evidence" >&2
      fi
    fi

    previous=null
    [ -n "$prev" ] && previous=$(baseline_of "$prev")

    # ── scope ────────────────────────────────────────────────────────────────
    # A scope that cannot be read is a usage error, never a silent whole-repo
    # run: grading the repository when the caller asked for a delta would show
    # a red or purple verdict on a change that introduced nothing, and the
    # reader would have no way to tell which question was answered.
    scope_mode="whole-repo"
    if [ -n "$changed" ]; then
      [ -f "$changed" ] || { echo "changed-file list not found: $changed" >&2; exit 2; }
      scope_mode="delta"
    fi
    changed_json='[]'
    [ "$scope_mode" = "delta" ] && changed_json=$(jq -R -s 'split("\n") | map(select(length > 0))' "$changed")
    excludes_json=$(printf '%s' "$excludes" | jq -R -s 'split("\n") | map(select(length > 0))')
    scope=$(jq -n --arg mode "$scope_mode" --argjson changed "$changed_json" --argjson ex "$excludes_json" \
      '{mode: $mode, changed: $changed, excluded_prefixes: $ex}')

    # The stable scope definition participates in comparisons: changing an
    # exclusion changes the grading universe. The actual changed-file list is
    # revision data and must NOT invalidate every PR delta. Exclusion order and
    # duplicates do not change semantics, so canonicalise them for the hash.
    profile_scope=$(jq -c '{mode, excluded_prefixes: (.excluded_prefixes | unique | sort)}' <<< "$scope")
    profile=$( { cat "$0" "$JQ_LIB"; [ -n "$enrol" ] && [ -f "$enrol" ] && cat "$enrol"; printf '%s\n' "$href" "$pref" "$qref" "$lane" "$profile_scope"; } | sha256sum | cut -d' ' -f1)

    dirty=false
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      [ -z "$sha" ] && sha=$(git rev-parse HEAD)
      git diff --quiet HEAD 2>/dev/null || dirty=true
    fi

    jq -n --slurpfile sources "$sources" --argjson enrolment "$enrolment" \
      --arg profile "$profile" --arg lane "$lane" --arg sha "$sha" --arg run "$run" --arg url "$url" \
      --arg pr "$pr" --arg repo "$repo" --argjson dirty "$dirty" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg href "$href" --arg pref "$pref" --arg qref "$qref" \
      --argjson scope "$scope" --arg root "$PWD" --argjson baseline_verified "$baseline_verified" \
      '{sources: $sources[0], enrolment: $enrolment, profile: $profile, scope: $scope, root: $root,
        hypatia_baseline_verified: $baseline_verified,
        identity: {lane: $lane, sha: $sha, run: $run, url: $url, pr: $pr, repo: $repo, dirty: $dirty,
                   generated: $generated, refs: {hypatia: $href, panic: $pref, pons: $qref}}}' \
      | jq --arg mode build --argjson previous null -f "$JQ_LIB" > "$out/report.json"

    jq -r --arg mode render --argjson previous "$previous" -f "$JQ_LIB" "$out/report.json" > "$out/report.md"
    jq --arg mode badge --argjson previous null -f "$JQ_LIB" "$out/report.json" > "$out/badge.json"

    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$out/report.md" >> "$GITHUB_STEP_SUMMARY"; fi
    if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "state=$(jq -r .state "$out/report.json")" >> "$GITHUB_OUTPUT"; fi
    cat "$out/report.md"
    ;;
  *) usage ;;
esac
