#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# report-back-model-test.sh — the renderer computes the ReportBack.idr model
# for gitbot-fleet rows, on every case of a bounded domain.
#
# 3-practice/fork-governance/proofs/ReportBack.idr proves the fleet-row
# properties for a model of `reportback`, `row` and `state`. Its `main`
# prints the model's colour for every case (report-back-cases.tsv): the eight
# envelopes that are not a clean `ran`, every `ran` envelope with 0, 1 or 2
# findings over 12 severity spellings x 3 scope buckets (1333 lists), and the
# three ways a member can have no envelope. This test writes each case as a
# real envelope, renders them all with the real renderer in delta scope, and
# requires every row to have the model's colour (PROOF-POLICY section 5:
# TESTED, the bound is that domain). CI's Idris2 job regenerates the table
# from the model and fails if it differs from the committed copy.
#
# Run: bash scripts/tests/report-back-model-test.sh

set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
grid="$repo/scripts/verdict-grid.sh"
cases="$repo/3-practice/fork-governance/proofs/report-back-cases.tsv"
expected_cases=1344
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
[ -f "$cases" ] || { echo "missing case table: $cases" >&2; exit 2; }

got_cases=$(grep -c . "$cases")
if [ "$got_cases" -ne "$expected_cases" ]; then
  echo "FAIL: case table has $got_cases lines, expected $expected_cases (regenerate it from ReportBack.idr)"
  exit 1
fi

backs="$tmp/backs"
mkdir -p "$backs"
printf 'g.txt\n' > "$tmp/changed.txt"

# finding JSON for one severity:bucket token. The bucket is set through the
# path: g.txt is in the changed list (graded), s.txt is not (standing), and
# x/ is a declared exclusion (excluded).
finding_json() {
  local sev="${1%%:*}" bucket="${1#*:}" file
  case "$bucket" in
    graded)   file=g.txt ;;
    standing) file=s.txt ;;
    excluded) file=x/e.txt ;;
    *) echo "bad bucket: $bucket" >&2; exit 2 ;;
  esac
  jq -cn --arg s "$sev" --arg f "$file" '{rule_id:"model/rule", severity:$s, file:$f, line:1, message:"m"}'
}

: > "$tmp/expect.tsv"
n=0
while IFS=$'\t' read -r env findings colour; do
  if [ "$env" = missing ]; then
    printf 'missing-%s\t%s\n' "$findings" "$colour" >> "$tmp/expect.tsv"
    continue
  fi
  n=$((n + 1))
  id=$(printf 'm%05d' "$n")
  f="$backs/$id.json"
  case "$env" in
    not_json)       printf 'not json\n' > "$f" ;;
    not_object)     printf '[]\n' > "$f" ;;
    bad_identity)   printf '{"findings":[],"reporter":"","status":"ran"}\n' > "$f" ;;
    ran_unreadable) printf '{"findings":"unreadable","status":"ran"}\n' > "$f" ;;
    not_run)        printf '{"reason":"r","status":"not_run"}\n' > "$f" ;;
    error)          printf '{"reason":"r","status":"error"}\n' > "$f" ;;
    not_applicable) printf '{"reason":"r","status":"not_applicable"}\n' > "$f" ;;
    other_status)   printf '{"status":"unheard-of"}\n' > "$f" ;;
    ran)
      items='[]'
      if [ "$findings" != "-" ]; then
        IFS=',' read -r -a toks <<< "$findings"
        items=$(for t in "${toks[@]}"; do finding_json "$t"; done | jq -cs .)
      fi
      jq -cn --argjson fs "$items" '{findings:$fs, ref:"model", status:"ran"}' > "$f" ;;
    *) echo "unknown envelope kind in case table: $env" >&2; exit 2 ;;
  esac
  printf '%s\t%s\n' "$id" "$colour" >> "$tmp/expect.tsv"
done < "$cases"

jq -n '{reporters: {
  "missing-enrolled":     {title: "missing-enrolled", enrolled: true},
  "missing-not_enrolled": {title: "missing-not_enrolled", enrolled: false, reason: "not for this repository"}
}}' > "$tmp/enrolment.json"
# missing-unlisted has neither an envelope nor a manifest entry.

bash "$grid" render --out "$tmp/out" --report-backs "$backs" --enrolment "$tmp/enrolment.json" \
  --changed "$tmp/changed.txt" --exclude-prefix x/ >/dev/null 2>"$tmp/render.err" \
  || { echo "FAIL: the renderer exited non-zero"; cat "$tmp/render.err"; exit 1; }

jq -r '.reporters[] | [.id, .state] | @tsv' "$tmp/out/report.json" > "$tmp/actual.tsv"

pass=0
fail=0
while IFS=$'\t' read -r id colour; do
  actual=$(awk -F'\t' -v id="$id" '$1 == id { print $2; found = 1 } END { if (!found) print "none" }' "$tmp/actual.tsv")
  if [ "$actual" = "$colour" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    [ "$fail" -le 20 ] && echo "FAIL: $id expected=$colour got=$actual ($(grep -m1 -n . "$backs/$id.json" 2>/dev/null | cut -c1-160))"
  fi
done < "$tmp/expect.tsv"

echo "report-back-model-test: $pass of $((pass + fail)) cases match ReportBack.idr, $fail differ"
[ "$fail" -eq 0 ]
