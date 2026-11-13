#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# test_conformance_advisory.sh — the `advisory` input of deed-conformance.yml and
# k9-conformance.yml. Governance calls both with advisory on, so no caller turns
# red at once; direct callers keep enforcing (default false).
#
#   1. both declare `advisory` as an optional boolean, default false;
#   2. k9-conformance's job asks for `contents: read` only: a nested call from
#      governance inherits a caller token with no pull-requests scope, and a
#      reusable asking for more makes the whole run fail at startup;
#   3. every k9 step (and the deed lint step) tolerates failure under advisory;
#   4. the k9 Gate step exits 0 on a red grid when advisory, exits 1 when not;
#   5. the deed warning step turns `FAIL path: msg` lines into annotations.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/.github/workflows/deed-conformance.yml"
K="$ROOT/.github/workflows/k9-conformance.yml"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

rb() { ruby -ryaml -e "$1" "${@:2}"; }

for f in "$D" "$K"; do
  n=$(basename "$f")
  got=$(rb 'i=YAML.load_file(ARGV[0])[true]["workflow_call"]["inputs"]["advisory"]; puts [i["type"], i["required"], i["default"]].join(",")' "$f" 2>&1)
  [ "$got" = "boolean,false,false" ] && ok "$n declares advisory (boolean, optional, default false)" || bad "$n advisory input is '$got'"
done

perms=$(rb 'puts YAML.load_file(ARGV[0])["jobs"]["validate"]["permissions"].keys.sort.join(",")' "$K")
[ "$perms" = "contents" ] && ok "k9 job asks for contents only (nested-call safe)" || bad "k9 job permissions are '$perms'"

miss=$(rb 'puts YAML.load_file(ARGV[0])["jobs"]["validate"]["steps"].reject{|s| s["continue-on-error"].to_s.include?("inputs.advisory")}.map{|s| s["name"]||s["uses"]}.join("|")' "$K")
[ -z "$miss" ] && ok "every k9 step tolerates failure under advisory" || bad "k9 steps without advisory tolerance: $miss"

lint=$(rb 'puts YAML.load_file(ARGV[0])["jobs"]["lint"]["steps"].find{|s| s["id"]=="lint"}["continue-on-error"]' "$D")
[[ "$lint" == *inputs.advisory* ]] && ok "deed lint step tolerates failure under advisory" || bad "deed lint step: '$lint'"

# Gate step
rb 'puts YAML.load_file(ARGV[0])["jobs"]["validate"]["steps"].find{|s| s["name"]=="Gate"}["run"]' "$K" > "$WORK/gate.sh"
for st in red orange; do
  STATE=$st ADVISORY=true FAIL_ON_INDETERMINATE=true bash "$WORK/gate.sh" > "$WORK/o" 2>&1; rc=$?
  { [ $rc -eq 0 ] && grep -q '^::warning::K9 conformance (advisory)' "$WORK/o"; } && ok "gate: $st + advisory exits 0 with a warning" || bad "gate: $st + advisory rc=$rc: $(cat "$WORK/o")"
done
STATE=red ADVISORY=false FAIL_ON_INDETERMINATE=false bash "$WORK/gate.sh" >/dev/null 2>&1; [ $? -eq 1 ] && ok "gate: red without advisory still fails" || bad "gate: red without advisory did not fail"
STATE= ADVISORY=true FAIL_ON_INDETERMINATE=false bash "$WORK/gate.sh" > "$WORK/o" 2>&1; { [ $? -eq 0 ] && grep -q 'no verdict' "$WORK/o"; } && ok "gate: no verdict + advisory warns, exits 0" || bad "gate: empty verdict + advisory"

# deed warning step
rb 'puts YAML.load_file(ARGV[0])["jobs"]["lint"]["steps"].find{|s| s["name"]=="Advisory findings as warnings"}["run"]' "$D" > "$WORK/deedwarn.sh"
export RUNNER_TEMP="$WORK"
printf 'PASS ./a_chora.deed\nFAIL ./b_chora.deed: line 1: deed must begin with an SPDX header\nFAIL ./b_chora.deed: line 1: deed must begin with an SPDX header\n' > "$WORK/deed-lint.log"
bash "$WORK/deedwarn.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && grep -q '^::warning file=b_chora.deed::deed conformance (advisory): line 1' "$WORK/o" && [ "$(grep -c '^::warning file=' "$WORK/o")" = 1 ] && grep -q '2 finding(s)' "$WORK/o"; } \
  && ok "deed: FAIL lines become one deduplicated annotation each, with the count" || bad "deed warning step: $(cat "$WORK/o")"
: > "$WORK/deed-lint.log"; bash "$WORK/deedwarn.sh" > "$WORK/o" 2>&1
grep -q 'did not run to completion' "$WORK/o" && ok "deed: an empty log says the check did not complete" || bad "deed: empty log message"

# Escaping: a path with a comma and a colon must not break the property list.
printf 'FAIL ./a,b:c_chora.deed: line 1: bad\n' > "$WORK/deed-lint.log"
bash "$WORK/deedwarn.sh" > "$WORK/o" 2>&1
grep -q '^::warning file=a%2Cb%3Ac_chora.deed::deed conformance (advisory): line 1: bad' "$WORK/o" \
  && ok "deed: , and : in a path are escaped in the annotation property" || bad "deed path escaping: $(cat "$WORK/o")"

# No error-severity annotation in advisory mode (the runner keeps ::error:: even under continue-on-error).
for spec in "$K:validate:Enumerate the committed K9 files, the changed files and ledger growth" "$D:lint:lint every committed deed"; do
  file="${spec%%:*}"; rest="${spec#*:}"; job="${rest%%:*}"; step="${rest#*:}"
  body=$(rb 'puts YAML.load_file(ARGV[0])["jobs"][ARGV[1]]["steps"].find{|s| s["name"]==ARGV[2]}["run"]' "$file" "$job" "$step")
  # every ::error:: line must be switched on ADVISORY via the ${sev} variable
  bare=$(printf '%s\n' "$body" | grep -c '::error::' || true)
  [ "$bare" = 0 ] && grep -q 'sev=error; \[ "\$ADVISORY" = "true" \] && sev=warning' <<<"$body" \
    && ok "$(basename "$file"): '$step' downgrades its annotation to a warning under advisory" \
    || bad "$(basename "$file"): '$step' still has a bare ::error:: ($bare)"
done

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
