#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# verdict-grid-test.sh — the findings-family grid never turns missing or
# unreadable evidence into a clean row, grades the worst finding present,
# keeps explicit scope exclusions grey, and compares revisions only under one
# profile. docs/VERDICT-GRID-SPEC.adoc is the contract under test.
#
# Run: bash scripts/tests/verdict-grid-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRID="$SCRIPT_DIR/../verdict-grid.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() {
  local label="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $label ($got)"; pass=$((pass + 1))
  else
    echo "FAIL: $label expected=$expected got=$got"; fail=$((fail + 1))
  fi
}
# Existing grid controls use a synthetic SARIF projection of the raw fixture.
# Tests that exercise projection/baselines explicitly supply --hypatia-sarif.
render() {
  local out="$1" raw="" explicit=false sarif="$1.fixture.sarif"; shift
  local args=("$@") i
  for ((i=0; i<${#args[@]}; i++)); do
    [ "${args[i]}" = --hypatia ] && raw="${args[i+1]}"
    [ "${args[i]}" = --hypatia-sarif ] && explicit=true
  done
  if [ -n "$raw" ] && [ "$explicit" = false ]; then
    if jq -e -s 'length == 1 and (.[0] | type == "array")' "$raw" >/dev/null 2>&1; then
      jq '{version:"2.1.0",runs:[{tool:{driver:{name:"Hypatia"}},results:
        [.[] | {ruleId:("hypatia/" + (.rule_module // "r") + "/" + (.type // "t")),
          level:(if .severity == "critical" or .severity == "high" then "error"
                 elif .severity == "medium" or .severity == "warn" then "warning"
                 elif .severity == "info" or .severity == "low" then "note" else "invalid" end),
          message:{text:(.reason // "")}, locations:[{physicalLocation:{artifactLocation:{uri:(.file // "")}}}],
          properties:{"hypatia.severity":.severity,"hypatia.originalLine":.line,"hypatia.class":.type}}]}]}' "$raw" > "$sarif"
    else
      cp "$raw" "$sarif"
    fi
    args+=(--hypatia-sarif "$sarif")
  fi
  bash "$GRID" render --out "$out" "${args[@]}" >/dev/null
}
state() { jq -r .state "$1/report.json"; }
row() { jq -r --arg id "$2" '.reporters[] | select(.id == $id) | .state' "$1/report.json"; }

hyp_clean="$WORK/hyp-clean.json";    echo '[]' > "$hyp_clean"
hyp_crit="$WORK/hyp-crit.json";      echo '[{"severity":"critical","rule_module":"cicd_rules","type":"banned_language_file","file":"a.ts","reason":"x"},{"severity":"warn","rule_module":"r","type":"t","file":"b","reason":"y"}]' > "$hyp_crit"
hyp_med="$WORK/hyp-med.json";        echo '[{"severity":"medium","rule_module":"r","type":"t","file":"b","reason":"y"}]' > "$hyp_med"
hyp_info="$WORK/hyp-info.json";      echo '[{"severity":"info","rule_module":"r","type":"t","file":"b","reason":"y"}]' > "$hyp_info"
hyp_bad="$WORK/hyp-bad.json";        echo 'not json' > "$hyp_bad"
hyp_odd="$WORK/hyp-odd.json";        echo '[{"severity":"catastrophic","rule_module":"r","type":"t","reason":"y"}]' > "$hyp_odd"
pan_ran="$WORK/pan-ran.json";        echo '{"status":"ran","tool":"panic-attack","ref":"abc","reason":null,"exit_code":0,"report":{"weak_points":[{"category":"ProofDrift","file":"t.jl","severity":"Medium","description":"d"},{"category":"X","file":"s","severity":"Critical","description":"e","suppressed":true}]}}' > "$pan_ran"
pan_not="$WORK/pan-not.json";        echo '{"status":"not_run","tool":"panic-attack","ref":"abc","reason":"cargo is not available","exit_code":null,"counts":null,"report":null}' > "$pan_not"
pan_clean="$WORK/pan-clean.json";    echo '{"status":"ran","tool":"panic-attack","ref":"abc","reason":null,"exit_code":0,"report":{"weak_points":[]}}' > "$pan_clean"
pons_ran="$WORK/pons-ran.json";      echo '{"status":"ran","tool":"pons-asinorum","ref":"def","reason":null,"exit_code":0,"report":{"findings":[{"rule_id":"unreachable-after-jump","tier":"T0","evidence":"HEURISTIC","severity":"WARN","location":{"file":"a.tsx","line_start":4},"message":"m"}]}}' > "$pons_ran"
pons_clean="$WORK/pons-clean.json";  echo '{"status":"ran","tool":"pons-asinorum","ref":"def","reason":null,"exit_code":0,"report":{"findings":[]}}' > "$pons_clean"
pons_hollow="$WORK/pons-hollow.json"; echo '{"status":"ran","tool":"pons-asinorum","ref":"def"}' > "$pons_hollow"

# 1. No evidence at all is orange, never green, and the badge says so.
render "$WORK/o1"
check "no evidence is indeterminate" orange "$(state "$WORK/o1")"
check "badge colour follows the state" orange "$(jq -r .color "$WORK/o1/badge.json")"
check "missing scanner output is an error row" error "$(jq -r '.reporters[] | select(.id == "hypatia") | .status' "$WORK/o1/report.json")"

# 2. A known critical beats every other state, including missing evidence.
render "$WORK/o2" --hypatia "$hyp_crit" --panic "$pan_not"
check "critical finding is purple" purple "$(state "$WORK/o2")"
check "warn counts as medium" 1 "$(jq '.reporters[0].counts.medium' "$WORK/o2/report.json")"
check "not_run envelope is orange" orange "$(row "$WORK/o2" panic-attack)"
check "badge message names the worst grade" critical "$(jq -r .message "$WORK/o2/badge.json")"

# 3. Malformed or unrecognised evidence is orange.
render "$WORK/o3" --hypatia "$hyp_bad" --panic "$pan_clean" --pons "$pons_clean"
check "unparseable findings are indeterminate" orange "$(state "$WORK/o3")"
render "$WORK/o3b" --hypatia "$hyp_odd" --panic "$pan_clean" --pons "$pons_clean"
check "unknown severity is indeterminate" orange "$(row "$WORK/o3b" hypatia)"
render "$WORK/o3c" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_hollow"
check "a ran envelope without a report is indeterminate" orange "$(row "$WORK/o3c" pons-asinorum)"

# 4. Grades below critical: red, yellow, blue, green; suppressed points are not counted.
render "$WORK/o4" --hypatia "$hyp_med" --panic "$pan_ran" --pons "$pons_ran"
check "medium is yellow" yellow "$(state "$WORK/o4")"
check "suppressed weak points are not counted" 0 "$(jq '.reporters[] | select(.id == "panic-attack") | .counts.critical' "$WORK/o4/report.json")"
check "pons WARN is medium" yellow "$(row "$WORK/o4" pons-asinorum)"
render "$WORK/o5" --hypatia "$hyp_info" --panic "$pan_clean" --pons "$pons_clean"
check "info only is blue" blue "$(state "$WORK/o5")"
render "$WORK/o6" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_clean"
check "all clean is green" green "$(state "$WORK/o6")"

# 5. Fleet rows: enrolled-without-report is orange, not-enrolled is grey with a reason,
#    a report-back supplies its own row, and grey never masks a finding.
mkdir -p "$WORK/backs"
echo '{"reporter":"rhodibot","title":"rhodibot (RSR)","status":"ran","ref":"r1","findings":[{"rule_id":"RSR-001","severity":"error","file":"README.adoc","message":"missing"}]}' > "$WORK/backs/rhodibot.json"
echo '{"reporters":{"rhodibot":{"enrolled":true},"panicbot":{"title":"panicbot","enrolled":true},"glambot":{"enrolled":false,"reason":"no served HTML"}}}' > "$WORK/enrol.json"
render "$WORK/o7" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_clean" --report-backs "$WORK/backs" --enrolment "$WORK/enrol.json"
check "fleet error severity is high" red "$(row "$WORK/o7" rhodibot)"
check "enrolled member without a report-back is orange" orange "$(row "$WORK/o7" panicbot)"
check "member not enrolled is grey" grey "$(row "$WORK/o7" glambot)"
# ⚠ CONTRACT CHANGE (scope + gate separation, 2026-10-24). The lane state used
# to be the worst row of ANY kind, so an advisory fleet report-back could turn
# the lane red while every gating check was green. It is now the worst GATING
# row; the advisory worst is surfaced on the next line and must name the red.
check "an advisory red does not set the gating state" green "$(state "$WORK/o7")"
check "the advisory red is still reported and named" yes \
  "$(grep -q 'Advisory: .*worst .*' "$WORK/o7/report.md" && grep -q '🔴' "$WORK/o7/report.md" && echo yes)"
check "advisory severity totals explicitly name the grid scope" yes \
  "$(grep -q 'Advisory: .*critical, .*high in grid scope.*reported, never grading' "$WORK/o7/report.md" && echo yes)"
# A global advisory may still carry critical/high standing debt while the
# delta-scoped suffix correctly reports zero graded findings.
pan_scope="$WORK/pan-scope.json"
cat > "$pan_scope" <<'JSON'
{"status":"ran","tool":"panic-attack","ref":"abc","reason":null,"exit_code":0,"report":{"weak_points":[
 {"category":"C1","file":"legacy/one.rs","severity":"Critical","description":"standing"},
 {"category":"C2","file":"legacy/two.rs","severity":"Critical","description":"standing"},
 {"category":"C3","file":"legacy/three.rs","severity":"Critical","description":"standing"},
 {"category":"C4","file":"legacy/four.rs","severity":"Critical","description":"standing"},
 {"category":"C5","file":"legacy/five.rs","severity":"Critical","description":"standing"},
 {"category":"H1","file":"legacy/six.rs","severity":"High","description":"standing"}
]}}
JSON
printf '%s\n' 'src/touched.adoc' > "$WORK/advisory-changed.txt"
render "$WORK/o7-scope" --hypatia "$hyp_clean" --panic "$pan_scope" --pons "$pons_clean" \
  --changed "$WORK/advisory-changed.txt"
check "standing panic criticals stay out of scoped advisory suffix" 0 \
  "$(jq '.advisory.critical' "$WORK/o7-scope/report.json")"
check "standing panic highs stay out of scoped advisory suffix" 0 \
  "$(jq '.advisory.high' "$WORK/o7-scope/report.json")"
check "the standing panic criticals remain fully reported" 5 \
  "$(jq --arg id panic-attack '.reporters[] | select(.id == $id) | .counts_standing.critical' "$WORK/o7-scope/report.json")"
check "the standing panic high remains fully reported" 1 \
  "$(jq --arg id panic-attack '.reporters[] | select(.id == $id) | .counts_standing.high' "$WORK/o7-scope/report.json")"
check "the advisory header calls its zero counts grid-scoped" yes \
  "$(grep -q 'Advisory: .*0 critical, 0 high in grid scope' "$WORK/o7-scope/report.md" && echo yes)"
check "the row details still disclose the standing severity counts" yes \
  "$(grep -q '5 critical, 1 high' "$WORK/o7-scope/report.md" && echo yes)"
check "the row itself is still red, and marked advisory" yes \
  "$(grep -q '| rhodibot (RSR) | advisory | 🔴' "$WORK/o7/report.md" && echo yes)"
check "the grey reason is shown" yes "$(grep -q 'no served HTML' "$WORK/o7/report.md" && echo yes)"
echo 'nonsense' > "$WORK/enrol-bad.json"
render "$WORK/o8" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_clean" --enrolment "$WORK/enrol-bad.json" 2>/dev/null
# The enrolment manifest governs which ADVISORY fleet members should report.
# Breaking it no longer reddens the lane -- the gating row is independent -- but
# it must remain visible as missing advisory evidence, never as clean.
check "an unreadable enrolment manifest still surfaces as missing evidence" yes \
  "$(grep -q 'Advisory: .*🟠 indeterminate' "$WORK/o8/report.md" && echo yes)"
mkdir "$WORK/malformed-backs"
printf '%s\n' '{"status":"ran","findings":null}' > "$WORK/malformed-backs/no-findings.json"
printf '%s\n' '{"status":"ran","findings":[42]}' > "$WORK/malformed-backs/bad-finding.json"
printf '%s\n' '{"reporter":42,"status":"ran","findings":[]}' > "$WORK/malformed-backs/bad-id.json"
printf '%s\n' '{"reporter":"","status":"ran","findings":[]}' > "$WORK/malformed-backs/empty-id.json"
render "$WORK/malformed-backs-out" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_clean" --report-backs "$WORK/malformed-backs"
for id in no-findings bad-finding bad-id empty-id; do
  check "malformed report-back $id is an orange row" orange "$(row "$WORK/malformed-backs-out" "$id")"
done
check "malformed advisory rows do not erase a valid gating result" green "$(state "$WORK/malformed-backs-out")"

# 6. Escaping: untrusted text cannot break the table or inject markup.
echo '[{"severity":"high","rule_module":"r","type":"t</details><script>x</script>","file":"a|b","reason":"line one\nline two"}]' > "$WORK/hyp-esc.json"
render "$WORK/o9" --hypatia "$WORK/hyp-esc.json" --panic "$pan_clean" --pons "$pons_clean"
check "markup is escaped" 0 "$(grep -c '<script>' "$WORK/o9/report.md" || true)"
check "pipes are escaped" 1 "$(grep -c 'a&#124;b' "$WORK/o9/report.md")"

# 7. The delta column: same profile and PR, different commit; otherwise no comparison.
render "$WORK/d1" --hypatia "$hyp_crit" --panic "$pan_clean" --pons "$pons_clean" --pr 7 --sha aaaa
check "no earlier PR grid is explained" 3 "$(grep -c 'no comparable baseline (no prior PR grid or unreadable snapshot)' "$WORK/d1/report.md")"
render "$WORK/d2" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_clean" --pr 7 --sha bbbb --previous "$WORK/d1/report.md"
check "fewer blocking findings is an improvement" 1 "$(grep -c '↑ improved (1 fewer blocking)' "$WORK/d2/report.md")"
render "$WORK/d3" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_clean" --pr 7 --sha bbbb --previous "$WORK/d2/report.md"
check "the same commit is not compared with itself" 0 "$(grep -c 'improved' "$WORK/d3/report.md" || true)"
check "same commit is specifically identified" 3 "$(grep -c 'same commit (no revision comparison)' "$WORK/d3/report.md")"
render "$WORK/d4" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_clean" --pr 8 --sha cccc --previous "$WORK/d1/report.md"
check "another PR is no baseline" 3 "$(grep -c 'no comparable baseline' "$WORK/d4/report.md")"
check "cross PR comparison is specifically refused" 3 "$(grep -c 'no comparable baseline (different PR)' "$WORK/d4/report.md")"
render "$WORK/d5" --hypatia "$hyp_clean" --panic "$pan_not" --pons "$pons_clean" --pr 7 --sha dddd --previous "$WORK/d1/report.md"
check "a changed evidence status is not an improvement" 1 "$(grep -c '— evidence changed' "$WORK/d5/report.md")"
check "baseline round-trips" aaaa "$(bash "$GRID" baseline "$WORK/d1/report.md" | jq -r .sha)"
check "a garbled baseline reads as null" null "$(printf '<!-- verdict-grid-baseline:xxxx -->' > "$WORK/garbled.md"; bash "$GRID" baseline "$WORK/garbled.md")"
old_baseline=$(bash "$GRID" baseline "$WORK/d1/report.md" | jq -c '.schema = 2' | base64 -w0)
printf '<!-- verdict-grid-baseline:%s -->\n' "$old_baseline" > "$WORK/schema2.md"
render "$WORK/d-old" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_clean" --pr 7 --sha old --previous "$WORK/schema2.md"
check "schema-2 raw JSON counts are not compared with schema-3 SARIF counts" 3 "$(grep -c 'no comparable baseline' "$WORK/d-old/report.md")"
check "schema mismatch is named" 3 "$(grep -c 'no comparable baseline (schema changed)' "$WORK/d-old/report.md")"

# 8. Scope: what the grid is allowed to GRADE.
#    The failures that matter here are the quiet ones -- a delta grid that
#    silently grades everything (a verdict that never moves) and an exclusion
#    that swallows a finding it should not have matched.
printf 'scripts/touched.sh\n' > "$WORK/changed.txt"
cat > "$WORK/hyp-mixed.json" <<'JSON'
[
 {"severity":"medium","rule_module":"cp","type":"t","file":"scripts/touched.sh","reason":"in scope"},
 {"severity":"critical","rule_module":"cp","type":"t","file":"scripts/untouched.sh","reason":"standing"},
 {"severity":"high","rule_module":"cp","type":"t","file":"9-archive/old.adoc","reason":"frozen"}
]
JSON
render "$WORK/s1" --hypatia "$WORK/hyp-mixed.json" --panic "$WORK/pan_clean" --pons "$WORK/pons_clean" \
  --changed "$WORK/changed.txt" --exclude-prefix 9-archive/
check "delta scope grades only the touched file" yellow "$(row "$WORK/s1" hypatia)"
check "the standing critical does not grade" 0 "$(jq -r '.reporters[] | select(.id=="hypatia") | .counts.critical' "$WORK/s1/report.json")"
check "the standing critical IS counted" 1 "$(jq -r '.reporters[] | select(.id=="hypatia") | .counts_standing.critical' "$WORK/s1/report.json")"
check "the excluded finding is neither graded nor standing" 1 "$(jq -r '.reporters[] | select(.id=="hypatia") | .counts_excluded.high' "$WORK/s1/report.json")"
check "the identity line states the scope" yes \
  "$(grep -q 'scope: this change (1 file' "$WORK/s1/report.md" && echo yes)"
check "the identity line names the exclusion" yes \
  "$(grep -q 'excludes .*9-archive/' "$WORK/s1/report.md" && echo yes)"
check "the standing finding is named in the accordion" yes \
  "$(grep -q 'further finding(s) in files this change does not touch' "$WORK/s1/report.md" && echo yes)"
# The workflow filters archive results out of the gate/upload SARIF. A
# baseline-filtered pre-scope copy supplies only excluded inventory.
bash "$SCRIPT_DIR/../filter-sarif-by-scope.sh" "$WORK/s1.fixture.sarif" "$WORK/scoped.sarif" 9-archive/ >/dev/null
render "$WORK/s-prescope" --hypatia "$WORK/hyp-mixed.json" --hypatia-sarif "$WORK/scoped.sarif" \
  --hypatia-sarif-unscoped "$WORK/s1.fixture.sarif" --panic "$pan_clean" --pons "$pons_clean" \
  --changed "$WORK/changed.txt" --exclude-prefix 9-archive/
check "pre-scope excluded high stays out of the grade" yellow "$(row "$WORK/s-prescope" hypatia)"
check "pre-scope excluded high remains in the inventory" 1 "$(jq '.reporters[] | select(.id=="hypatia") | .counts_excluded.high' "$WORK/s-prescope/report.json")"
check "excluded findings do not enter the unique graded total" 1 "$(jq '.unique_total' "$WORK/s-prescope/report.json")"
# If the scope filter fails open, the same excluded result is in both inputs;
# it must not be counted twice. Multiplicity within one source is preserved.
render "$WORK/s-prescope-open" --hypatia "$WORK/hyp-mixed.json" --hypatia-sarif "$WORK/s1.fixture.sarif" \
  --hypatia-sarif-unscoped "$WORK/s1.fixture.sarif" --panic "$pan_clean" --pons "$pons_clean" --exclude-prefix 9-archive/
check "fail-open scope results are not duplicated" 1 "$(jq '.reporters[] | select(.id=="hypatia") | .counts_excluded.high' "$WORK/s-prescope-open/report.json")"
jq '.runs[0].results += [.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri == "9-archive/old.adoc")]' \
  "$WORK/s1.fixture.sarif" > "$WORK/prescope-dupe.sarif"
render "$WORK/s-prescope-dupe" --hypatia "$WORK/hyp-mixed.json" --hypatia-sarif "$WORK/s1.fixture.sarif" \
  --hypatia-sarif-unscoped "$WORK/prescope-dupe.sarif" --panic "$pan_clean" --pons "$pons_clean" --exclude-prefix 9-archive/
check "distinct excluded occurrences are preserved" 2 "$(jq '.reporters[] | select(.id=="hypatia") | .counts_excluded.high' "$WORK/s-prescope-dupe/report.json")"
# Nonexcluded evidence in a pre-scope-only file never becomes graded.
jq '.runs[0].results += [{ruleId:"hypatia/extra/high",level:"error",properties:{"hypatia.severity":"critical"},locations:[{physicalLocation:{artifactLocation:{uri:"scripts/touched.sh"}}}]}]' \
  "$WORK/s1.fixture.sarif" > "$WORK/prescope-extra.sarif"
render "$WORK/s-prescope-extra" --hypatia "$WORK/hyp-mixed.json" --hypatia-sarif "$WORK/scoped.sarif" \
  --hypatia-sarif-unscoped "$WORK/prescope-extra.sarif" --panic "$pan_clean" --pons "$pons_clean" \
  --changed "$WORK/changed.txt" --exclude-prefix 9-archive/
check "pre-scope-only nonexcluded results never grade" yellow "$(row "$WORK/s-prescope-extra" hypatia)"
render "$WORK/s-prescope-missing" --hypatia "$WORK/hyp-mixed.json" --hypatia-sarif "$WORK/scoped.sarif" \
  --hypatia-sarif-unscoped "$WORK/not-there.sarif" --panic "$pan_clean" --pons "$pons_clean" --exclude-prefix 9-archive/
check "missing requested pre-scope inventory is explicit" orange "$(row "$WORK/s-prescope-missing" hypatia)"
printf 'not json\n' > "$WORK/prescope-invalid.sarif"
render "$WORK/s-prescope-invalid" --hypatia "$WORK/hyp-mixed.json" --hypatia-sarif "$WORK/scoped.sarif" \
  --hypatia-sarif-unscoped "$WORK/prescope-invalid.sarif" --panic "$pan_clean" --pons "$pons_clean" --exclude-prefix 9-archive/
check "malformed requested pre-scope inventory is explicit" orange "$(row "$WORK/s-prescope-invalid" hypatia)"
jq '(.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri == "9-archive/old.adoc") | .locations[0].physicalLocation.artifactLocation.uri) |= "./" + .' \
  "$WORK/s1.fixture.sarif" > "$WORK/prescope-dot.sarif"
render "$WORK/s-prescope-dot" --hypatia "$WORK/hyp-mixed.json" --hypatia-sarif "$WORK/scoped.sarif" \
  --hypatia-sarif-unscoped "$WORK/prescope-dot.sarif" --panic "$pan_clean" --pons "$pons_clean" --exclude-prefix 9-archive/
check "pre-scope paths are normalized before exclusion matching" 1 "$(jq '.reporters[] | select(.id=="hypatia") | .counts_excluded.high' "$WORK/s-prescope-dot/report.json")"
# A SARIF result with several locations is excluded by the gate filter only
# when ALL locations are under the prefix. A first archived location cannot
# conceal a second live (or unknown) location from the grid.
jq '(.runs[0].results[] | select(.level == "error" and .properties["hypatia.severity"] == "high") | .locations) +=
    [{physicalLocation:{artifactLocation:{uri:"scripts/touched.sh"}}}]' "$WORK/s1.fixture.sarif" > "$WORK/multiloc.sarif"
bash "$SCRIPT_DIR/../filter-sarif-by-scope.sh" "$WORK/multiloc.sarif" "$WORK/multiloc-gate.sarif" 9-archive/ >/dev/null
render "$WORK/s-multiloc" --hypatia "$WORK/hyp-mixed.json" --hypatia-sarif "$WORK/multiloc-gate.sarif" \
  --hypatia-sarif-unscoped "$WORK/multiloc.sarif" --panic "$pan_clean" --pons "$pons_clean" \
  --changed "$WORK/changed.txt" --exclude-prefix 9-archive/
check "mixed-location high grades when its live location is touched" red "$(row "$WORK/s-multiloc" hypatia)"
check "mixed-location high is not reported as fully excluded" 0 "$(jq '.reporters[] | select(.id=="hypatia") | .counts_excluded.high' "$WORK/s-multiloc/report.json")"
jq '(.runs[0].results[] | select(.level == "error" and .properties["hypatia.severity"] == "high") | .locations) += [{}]' \
  "$WORK/s1.fixture.sarif" > "$WORK/multiloc-unknown.sarif"
bash "$SCRIPT_DIR/../filter-sarif-by-scope.sh" "$WORK/multiloc-unknown.sarif" "$WORK/multiloc-unknown-gate.sarif" 9-archive/ >/dev/null
render "$WORK/s-multiloc-unknown" --hypatia "$WORK/hyp-mixed.json" --hypatia-sarif "$WORK/multiloc-unknown-gate.sarif" \
  --hypatia-sarif-unscoped "$WORK/multiloc-unknown.sarif" --panic "$pan_clean" --pons "$pons_clean" \
  --changed "$WORK/changed.txt" --exclude-prefix 9-archive/
check "an unknown additional location is graded rather than hidden" red "$(row "$WORK/s-multiloc-unknown" hypatia)"

render "$WORK/s2" --hypatia "$WORK/hyp-mixed.json" --panic "$WORK/pan_clean" --pons "$WORK/pons_clean"
check "without --changed the whole repository is graded" purple "$(row "$WORK/s2" hypatia)"
check "whole-repo mode says so" yes "$(grep -q 'scope: whole repository' "$WORK/s2/report.md" && echo yes)"

# A finding with no path cannot be shown to be outside the change: it grades.
printf '[{"severity":"high","rule_module":"cp","type":"t","file":"","reason":"no path"}]' > "$WORK/hyp-nopath.json"
render "$WORK/s3" --hypatia "$WORK/hyp-nopath.json" --panic "$WORK/pan_clean" --pons "$WORK/pons_clean" \
  --changed "$WORK/changed.txt"
check "a location-less finding is graded, not silently standing" red "$(row "$WORK/s3" hypatia)"

# Exclusion applies in whole-repo mode too: frozen history is out of scope
# whether or not the change touched it.
render "$WORK/s4" --hypatia "$WORK/hyp-mixed.json" --panic "$WORK/pan_clean" --pons "$WORK/pons_clean" \
  --exclude-prefix 9-archive/
check "exclusion applies without delta scoping" purple "$(row "$WORK/s4" hypatia)"
check "...and the excluded row is not counted as graded" 0 \
  "$(jq -r '.reporters[] | select(.id=="hypatia") | .counts.high' "$WORK/s4/report.json")"

# An unreadable changed-file list is a usage error, never a silent whole-repo
# run: grading the repository when the caller asked for a delta would colour the
# PR for debt it did not introduce, with nothing to say which question was asked.
# (Under `set -e` the failing call is read with `||`, never bare.)
rc=0
bash "$GRID" render --out "$WORK/s5" --hypatia "$WORK/hyp-mixed.json" \
  --changed "$WORK/does-not-exist.txt" >/dev/null 2>&1 || rc=$?
check "a missing changed-file list exits 2..." 2 "$rc"
check "...and writes no report to be misread" no \
  "$(if [ -f "$WORK/s5/report.json" ]; then echo yes; else echo no; fi)"

# A scope change invalidates the comparison rather than faking one.
render "$WORK/s6" --hypatia "$WORK/hyp-mixed.json" --panic "$WORK/pan_clean" --pons "$WORK/pons_clean" --pr 9 --sha s1
render "$WORK/s7" --hypatia "$WORK/hyp-mixed.json" --panic "$WORK/pan_clean" --pons "$WORK/pons_clean" --pr 9 --sha s2 \
  --changed "$WORK/changed.txt" --previous "$WORK/s6/report.md"
check "a change of scope is not a comparable baseline" 3 "$(grep -c 'no comparable baseline' "$WORK/s7/report.md")"
check "scope mismatch is named" 3 "$(grep -c 'no comparable baseline (scope changed)' "$WORK/s7/report.md")"
# Exclusion changes alter the profile, but changing the PR file list does not.
printf 'scripts/another.sh\n' > "$WORK/changed-next.txt"
render "$WORK/s8" --hypatia "$WORK/hyp-mixed.json" --panic "$pan_clean" --pons "$pons_clean" --pr 9 --sha s3 \
  --changed "$WORK/changed.txt" --exclude-prefix 9-archive/ --exclude-prefix vendor/
render "$WORK/s9" --hypatia "$WORK/hyp-mixed.json" --panic "$pan_clean" --pons "$pons_clean" --pr 9 --sha s4 \
  --changed "$WORK/changed-next.txt" --exclude-prefix vendor/ --exclude-prefix 9-archive/ --exclude-prefix vendor/ --previous "$WORK/s8/report.md"
check "changed paths, prefix order and duplicates do not invalidate the scope profile" "$(jq -r .profile "$WORK/s8/report.json")" "$(jq -r .profile "$WORK/s9/report.json")"
check "a changed-file list can compare to the previous run" 0 "$(grep -c 'no comparable baseline' "$WORK/s9/report.md" || true)"
render "$WORK/s10" --hypatia "$WORK/hyp-mixed.json" --panic "$pan_clean" --pons "$pons_clean" --pr 9 --sha s5 \
  --changed "$WORK/changed-next.txt" --exclude-prefix vendor/ --previous "$WORK/s8/report.md"
check "changed excluded prefixes invalidate the profile" 3 "$(grep -c 'no comparable baseline' "$WORK/s10/report.md")"
check "profile mismatch is named" 3 "$(grep -c 'no comparable baseline (scanner or policy profile changed)' "$WORK/s10/report.md")"

echo
# 11. The grid grades the exact SARIF set the blocking gate sees, not the
# raw JSON's historical alert echoes or findings removed by a baseline.
cat > "$WORK/raw-alerts.json" <<'JSON'
[{"rule_module":"code_scanning_alerts","type":"CSA003","severity":"critical","file":"old.rs","line":9,"reason":"historical"},
 {"rule_module":"dependabot_alerts","type":"DA001","severity":"high","file":"dep.lock","line":2,"reason":"alert"},
 {"rule_module":"code_safety","type":"removed_by_baseline","severity":"high","file":"old.rs","line":3,"reason":"accepted"},
 {"rule_module":"workflow_audit","type":"reusable_call_to_moved_repository","severity":"low","advisory":true,"file":".github/workflows/a.yml","line":1,"reason":"moved"}]
JSON
cat > "$WORK/empty.sarif" <<'JSON'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[]}]}
JSON
render "$WORK/projected" --hypatia "$WORK/raw-alerts.json" --hypatia-sarif "$WORK/empty.sarif" --panic "$pan_clean" --pons "$pons_clean"
check "raw critical echo and baselined high do not grade" green "$(row "$WORK/projected" hypatia)"
check "alert-derived raw inventory is separately counted" 2 "$(jq '.hypatia_alerts.total' "$WORK/projected/report.json")"
check "alert inventory names each alert module" 1 "$(jq '.hypatia_alerts.by_module.code_scanning_alerts' "$WORK/projected/report.json")"
check "alert inventory is labelled raw and not an extra total" yes "$(grep -q 'Raw Hypatia alert-derived observations: 2' "$WORK/projected/report.md" && echo yes)"
check "WF028 is surfaced separately without grading" yes "$(grep -q 'JSON-only below-threshold advisories: 1' "$WORK/projected/report.md" && grep -q 'WF028' "$WORK/projected/report.md" && echo yes)"
render "$WORK/missing-sarif" --hypatia "$hyp_clean" --hypatia-sarif "$WORK/missing" --panic "$pan_clean" --pons "$pons_clean"
check "missing SARIF is orange even if raw JSON is clean" orange "$(row "$WORK/missing-sarif" hypatia)"
# A syntactically valid but structurally broken JSON inventory cannot crash the
# renderer or make the raw alert inventory look complete.
echo '[{"severity":"high"}, "not-a-finding"]' > "$WORK/malformed-inventory.json"
render "$WORK/malformed-inventory" --hypatia "$WORK/malformed-inventory.json" --hypatia-sarif "$WORK/empty.sarif" --panic "$pan_clean" --pons "$pons_clean"
check "malformed JSON inventory is disclosed as unavailable" false "$(jq '.hypatia_alerts.available' "$WORK/malformed-inventory/report.json")"
check "valid SARIF still grades independently of malformed inventory" green "$(row "$WORK/malformed-inventory" hypatia)"
# A valid SARIF skeleton with malformed nested fields is orange, not a jq
# crash which would leave the summary without any state.
for badfield in properties locations message; do
  jq --arg field "$badfield" '.runs[0].results = [{ruleId:"hypatia/x/y",level:"error",($field):42}]' "$WORK/empty.sarif" > "$WORK/bad-$badfield.sarif"
  render "$WORK/bad-$badfield-out" --hypatia "$hyp_clean" --hypatia-sarif "$WORK/bad-$badfield.sarif" --panic "$pan_clean" --pons "$pons_clean"
  check "malformed SARIF $badfield is indeterminate" orange "$(row "$WORK/bad-$badfield-out" hypatia)"
done
jq '.runs[0].results = [{ruleId:"hypatia/x/y",level:"warning",properties:false}]' "$WORK/empty.sarif" > "$WORK/bad-bool.sarif"
render "$WORK/bad-bool-out" --hypatia "$hyp_clean" --hypatia-sarif "$WORK/bad-bool.sarif" --panic "$pan_clean" --pons "$pons_clean"
check "false SARIF properties are malformed, not absent" orange "$(row "$WORK/bad-bool-out" hypatia)"
render "$WORK/unverified" --hypatia "$hyp_clean" --hypatia-sarif "$WORK/empty.sarif" --hypatia-baseline-unverified --panic "$pan_clean" --pons "$pons_clean"
check "unverified baseline filtering is orange" orange "$(row "$WORK/unverified" hypatia)"

# 12. Corroboration is deliberately conservative: only a known relative
# path, real line and matching class/CWE merge; severity is the worst. Each
# reporter's row retains its own count, including duplicates within a row.
cat > "$WORK/overlap.sarif" <<'JSON'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[
 {"ruleId":"hypatia/security/unsafe_block","level":"error","message":{"text":"one"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"./src/a.rs"}}}],"properties":{"hypatia.severity":"high","hypatia.originalLine":12,"hypatia.class":"CWE-079"}}]}]}
JSON
cat > "$WORK/overlap-pan.json" <<'JSON'
{"status":"ran","report":{"weak_points":[
 {"category":"PanicPath","cwe":"CWE-79","file":"src/./a.rs","line":12,"severity":"Critical","description":"two"},
 {"category":"PanicPath","cwe":"CWE-79","file":"src/a.rs","line":12,"severity":"High","description":"duplicate in same row"},
 {"category":"PanicPath","cwe":"CWE-79","file":"src/a.rs","severity":"High","description":"no line"},
 {"category":"PanicPath","cwe":"CWE-80","file":"src/a.rs","line":12,"severity":"High","description":"different class"}]}}
JSON
cat > "$WORK/overlap-pons.json" <<'JSON'
{"status":"ran","report":{"findings":[{"rule_id":"some-rule","cwe":79,"severity":"WARN","location":{"file":"src/a.rs","line_start":12},"message":"three"}]}}
JSON
render "$WORK/overlap" --hypatia "$hyp_clean" --hypatia-sarif "$WORK/overlap.sarif" --panic "$WORK/overlap-pan.json" --pons "$WORK/overlap-pons.json"
check "per-row panic counts are not deduplicated" 4 "$(jq '[.reporters[] | select(.id == "panic-attack") | .findings_graded[]] | length' "$WORK/overlap/report.json")"
check "six observations become four unique findings" 4 "$(jq '.unique_total' "$WORK/overlap/report.json")"
check "raw reporter observation total is retained" 6 "$(jq '.reported_total' "$WORK/overlap/report.json")"
check "three reporters corroborate the shared finding" 'hypatia,panic-attack,pons-asinorum' "$(jq -r '.unique_findings[] | select((.corroborated_by | length) == 3) | .corroborated_by | join(",")' "$WORK/overlap/report.json")"
check "deduplicated finding keeps worst severity" critical "$(jq -r '.unique_findings[] | select((.corroborated_by | length) == 3) | .severity' "$WORK/overlap/report.json")"
check "missing line is not correlated" 1 "$(jq '.uncorrelatable_total' "$WORK/overlap/report.json")"
# Decimal line numbers are not real source coordinates, even if two tools
# happen to repeat them; conservative correlation must keep both observations.
jq '.runs[0].results[0].properties["hypatia.originalLine"] = 12.5' "$WORK/overlap.sarif" > "$WORK/decimal.sarif"
jq '.report.findings[0].location.line_start = 12.5' "$WORK/overlap-pons.json" > "$WORK/decimal-pons.json"
render "$WORK/decimal-out" --hypatia "$hyp_clean" --hypatia-sarif "$WORK/decimal.sarif" --panic "$pan_clean" --pons "$WORK/decimal-pons.json"
check "fractional source lines are never corroborated" 2 "$(jq '.unique_total' "$WORK/decimal-out/report.json")"
check "fractional lines are recorded as uncorrelatable" 2 "$(jq '.uncorrelatable_total' "$WORK/decimal-out/report.json")"
# Hypatia's upstream SARIF renderer replaces an absolute path OUTSIDE the
# checkout with its basename. Its provenance must prevent that basename from
# corroborating a real in-repository path, without changing SARIF grading.
jq '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri = "a.rs" |
    .runs[0].results[0].properties["hypatia.originalFile"] = "/outside/a.rs"' "$WORK/overlap.sarif" > "$WORK/outside.sarif"
jq '.report.findings[0].location.file = "a.rs"' "$WORK/overlap-pons.json" > "$WORK/outside-pons.json"
render "$WORK/outside-out" --hypatia "$hyp_clean" --hypatia-sarif "$WORK/outside.sarif" --panic "$pan_clean" --pons "$WORK/outside-pons.json"
check "outside path collapsed to basename does not corroborate" 2 "$(jq '.unique_total' "$WORK/outside-out/report.json")"
check "outside path remains explicitly uncorrelatable" 1 "$(jq '.uncorrelatable_total' "$WORK/outside-out/report.json")"
# URI schemes are not repository-relative filesystem paths either.
jq '.runs[0].results[0].properties["hypatia.originalFile"] = "file:///tmp/a.rs"' "$WORK/outside.sarif" > "$WORK/uri.sarif"
render "$WORK/uri-out" --hypatia "$hyp_clean" --hypatia-sarif "$WORK/uri.sarif" --panic "$pan_clean" --pons "$WORK/outside-pons.json"
check "URI schemes cannot be used as repository-relative identity" 1 "$(jq '.uncorrelatable_total' "$WORK/uri-out/report.json")"
check "advisory critical cannot promote the gating row" red "$(state "$WORK/overlap")"

# 13. Fleet report-backs follow Kin Arbiter precedence, not file order.
mkdir -p "$WORK/priority"
for id in accessibilitybot zeta rhodibot echidnabot alpha glambot panicbot; do
  jq -n --arg id "$id" '{reporter:$id,status:"ran",findings:[]}' > "$WORK/priority/$id.json"
done
render "$WORK/priority-out" --hypatia "$hyp_clean" --panic "$pan_clean" --pons "$pons_clean" --report-backs "$WORK/priority"
check "fleet rows follow canonical Arbiter order with deterministic unknown tail" \
  'echidnabot,rhodibot,panicbot,glambot,accessibilitybot,alpha,zeta' \
  "$(jq -r '[.reporters[3:][] | .id] | join(",")' "$WORK/priority-out/report.json")"

echo "verdict-grid-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
