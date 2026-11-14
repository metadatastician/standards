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
  STATE=$st ADVISORY=true FAIL_ON_INDETERMINATE=true bash -e -o pipefail "$WORK/gate.sh" > "$WORK/o" 2>&1; rc=$?
  { [ $rc -eq 0 ] && grep -q '^::warning::K9 conformance (advisory)' "$WORK/o"; } && ok "gate: $st + advisory exits 0 with a warning" || bad "gate: $st + advisory rc=$rc: $(cat "$WORK/o")"
done
STATE=red ADVISORY=false FAIL_ON_INDETERMINATE=false bash -e -o pipefail "$WORK/gate.sh" >/dev/null 2>&1; [ $? -eq 1 ] && ok "gate: red without advisory still fails" || bad "gate: red without advisory did not fail"
STATE= ADVISORY=true FAIL_ON_INDETERMINATE=false bash -e -o pipefail "$WORK/gate.sh" > "$WORK/o" 2>&1; { [ $? -eq 0 ] && grep -q 'no verdict' "$WORK/o"; } && ok "gate: no verdict + advisory warns, exits 0" || bad "gate: empty verdict + advisory"

# deed warning step
# The warning step is scripts/conformance-deed.sh warn (one implementation, shared with the template).
printf 'exec bash "%s" warn\n' "$ROOT/scripts/conformance-deed.sh" > "$WORK/deedwarn.sh"
export RUNNER_TEMP="$WORK"
printf 'PASS ./a_chora.deed\nFAIL ./b_chora.deed: line 1: deed must begin with an SPDX header\nFAIL ./b_chora.deed: line 1: deed must begin with an SPDX header\n' > "$WORK/deed-lint.log"
bash -e -o pipefail "$WORK/deedwarn.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && grep -q '^::warning file=b_chora.deed::deed conformance (advisory): line 1' "$WORK/o" && [ "$(grep -c '^::warning file=' "$WORK/o")" = 1 ] && grep -q '2 finding(s)' "$WORK/o"; } \
  && ok "deed: FAIL lines become one deduplicated annotation each, with the count" || bad "deed warning step: $(cat "$WORK/o")"
: > "$WORK/deed-lint.log"; bash -e -o pipefail "$WORK/deedwarn.sh" > "$WORK/o" 2>&1
grep -q 'did not run to completion' "$WORK/o" && ok "deed: an empty log says the check did not complete" || bad "deed: empty log message"

# Escaping: a path with a comma and a colon must not break the property list.
printf 'FAIL ./a,b:c_chora.deed: line 1: bad\n' > "$WORK/deed-lint.log"
bash -e -o pipefail "$WORK/deedwarn.sh" > "$WORK/o" 2>&1
grep -q '^::warning file=a%2Cb%3Ac_chora.deed::deed conformance (advisory): line 1: bad' "$WORK/o" \
  && ok "deed: , and : in a path are escaped in the annotation property" || bad "deed path escaping: $(cat "$WORK/o")"

# No error-severity annotation in advisory mode (the runner keeps ::error:: even under continue-on-error).
for spec in "$K:validate:Enumerate the committed K9 files, the changed files and ledger growth" "$D:lint:lint every committed deed"; do
  file="${spec%%:*}"; rest="${spec#*:}"; job="${rest%%:*}"; step="${rest#*:}"
  if [ "$file" = "$D" ]; then body=$(cat "$ROOT/scripts/conformance-deed.sh")  # the lint body lives in the shared script
  else body=$(rb 'puts YAML.load_file(ARGV[0])["jobs"][ARGV[1]]["steps"].find{|s| s["name"]==ARGV[2]}["run"]' "$file" "$job" "$step"); fi
  # every ::error:: line must be switched on ADVISORY via the ${sev} variable
  bare=$(printf '%s\n' "$body" | grep -c '::error::' || true)
  [ "$bare" = 0 ] && grep -q 'sev=error; \[ "\$ADVISORY" = "true" \] && sev=warning' <<<"$body" \
    && ok "$(basename "$file"): '$step' downgrades its annotation to a warning under advisory" \
    || bad "$(basename "$file"): '$step' still has a bare ::error:: ($bare)"
done

# Under the runner's `bash -e -o pipefail`, a log with no FAIL line, and a missing
# log, must still reach the closing warning and exit 0 (Codex P1 on #1519).
printf 'PASS ./a_chora.deed\n' > "$WORK/deed-lint.log"
bash -e -o pipefail "$WORK/deedwarn.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && grep -q 'did not run to completion' "$WORK/o"; } && ok "deed: a log with no FAIL line warns and exits 0 under -e -o pipefail" || bad "deed no-FAIL log: rc=$rc $(cat "$WORK/o")"
rm -f "$WORK/deed-lint.log"
bash -e -o pipefail "$WORK/deedwarn.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && grep -q 'did not run to completion' "$WORK/o"; } && ok "deed: a missing log warns and exits 0 under -e -o pipefail" || bad "deed missing log: rc=$rc $(cat "$WORK/o")"
step_coe=$(rb 'puts YAML.load_file(ARGV[0])["jobs"]["lint"]["steps"].find{|s| s["name"]=="Advisory findings as warnings"}["continue-on-error"]' "$D")
[ "$step_coe" = "true" ] && ok "deed: the annotation step cannot fail the advisory job" || bad "deed annotation step continue-on-error is '$step_coe'"

# A large log must not trip SIGPIPE under pipefail: the cap of 30 annotations
# is applied from a file, and the closing count still appears (Codex P2 on #1519).
awk 'BEGIN{for(i=1;i<=200000;i++) printf "FAIL ./d%06d_chora.deed: line 1: a rather long message so the pipe fills quickly %d\n", i, i}' > "$WORK/deed-lint.log"
bash -e -o pipefail "$WORK/deedwarn.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && [ "$(grep -c '^::warning file=' "$WORK/o")" = 30 ] && grep -q '200000 finding(s)' "$WORK/o"; } \
  && ok "deed: a huge FAIL log is capped at 30 annotations and still ends with the count (no SIGPIPE)" || bad "deed large log: rc=$rc $(tail -c 300 "$WORK/o")"

# A failed checkout under advisory leaves an empty workspace; it must be reported,
# not graded as "nothing to lint" or grey (Codex P2 on #1519).
STATE=grey ADVISORY=true CHECKOUT_OUTCOME=failure bash -e -o pipefail "$WORK/gate.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && grep -q 'a checkout step failed' "$WORK/o"; } && ok "k9 gate: a failed checkout with a grey grid warns that conformance did not run" || bad "k9 checkout failure: rc=$rc $(cat "$WORK/o")"
STATE=grey ADVISORY=true CANON_OUTCOME=failure bash -e -o pipefail "$WORK/gate.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && grep -q 'a checkout step failed' "$WORK/o"; } && ok "k9 gate: a failed canon checkout warns too" || bad "k9 canon failure: rc=$rc $(cat "$WORK/o")"
STATE=grey ADVISORY=true CHECKOUT_OUTCOME=success CANON_OUTCOME=skipped bash -e -o pipefail "$WORK/gate.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && ! grep -q 'checkout step failed' "$WORK/o"; } && ok "k9 gate: a successful (or skipped) checkout stays quiet on a grey grid" || bad "k9 clean checkout: rc=$rc $(cat "$WORK/o")"
cond=$(rb 'puts YAML.load_file(ARGV[0])["jobs"]["lint"]["steps"].find{|s| s["name"]=="Advisory findings as warnings"}["if"]' "$D")
{ [[ "$cond" == *steps.checkout.outcome* ]] && [[ "$cond" == *steps.canon.outcome* ]] && [[ "$cond" == *steps.bun.outcome* ]] && [[ "$cond" == *steps.lint.outcome* ]]; } \
  && ok "deed: the advisory warning step also runs when a checkout or setup step failed" || bad "deed warning condition: $cond"
ids=$(rb 'puts YAML.load_file(ARGV[0])["jobs"]["lint"]["steps"].map{|s| s["id"]}.compact.sort.join(",")' "$D")
[ "$ids" = "bun,canon,checkout,lint" ] && ok "deed: prerequisite steps carry the ids the condition reads" || bad "deed step ids: $ids"

# Standards-only bun steps are skipped when the Bun setup failed (CodeRabbit on #1519).
unguarded=$(rb 'puts YAML.load_file(ARGV[0])["jobs"]["lint"]["steps"].select{|s| s["if"].to_s.include?("1116521501") && s["run"].to_s =~ /(^|\s)bun(\s|$)/ && !s["if"].to_s.include?("steps.bun.outcome")}.map{|s| s["name"]}.join("|")' "$D")
[ -z "$unguarded" ] && ok "deed: every standards-only step that calls bun is guarded by the Bun setup outcome" || bad "deed: unguarded bun steps: $unguarded"

# The standards-only test steps turn a failure into a warning under advisory.
for name in "Renderer regression tests" "coordination.k9 validator self-test"; do
  # run the step's own logic with its command replaced by a failing one
  printf '%s\n' '#!/usr/bin/env bash' 'exit 3' > "$WORK/bad.sh"
  rb 'st=YAML.load_file(ARGV[0])["jobs"]["validate"]["steps"].find{|s| s["name"].to_s.start_with?(ARGV[1])}; r=st["run"].dup; r.sub!("bash scripts/tests/k9-grid-test.sh", "bash #{ARGV[2]}"); r.sub!("bun install --frozen-lockfile && bun validate.js --self-test", "bash #{ARGV[2]}"); puts r' "$K" "$name" "$WORK/bad.sh" > "$WORK/stepy.sh"
  ADVISORY=true bash -e -o pipefail "$WORK/stepy.sh" > "$WORK/o" 2>&1; rc=$?
  { [ $rc -eq 0 ] && grep -q '^::warning::.*advisory' "$WORK/o"; } && ok "k9: '$name' failure is a warning under advisory" || bad "k9 '$name' advisory: rc=$rc $(cat "$WORK/o")"
  ADVISORY=false bash -e -o pipefail "$WORK/stepy.sh" > "$WORK/o" 2>&1; rc=$?
  [ $rc -eq 3 ] && ok "k9: '$name' still fails (exit 3) without advisory" || bad "k9 '$name' enforcing: rc=$rc"
done

# Codex P2 on #1560: the warning step must not depend on the canon checkout it reports on.
rb 'puts YAML.load_file(ARGV[0])["jobs"]["lint"]["steps"].find{|s| s["name"]=="Advisory findings as warnings"}["run"]' "$D" > "$WORK/warnstep.sh"
LANE="$WORK/no-such-canon/scripts/conformance-deed.sh" RUNNER_TEMP="$WORK" bash -e -o pipefail "$WORK/warnstep.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && grep -q "^::warning::deed conformance (advisory): the conformance script could not be staged" "$WORK/o"; } \
  && ok "deed: with the canon checkout missing the warning step still warns (inline fallback), exit 0" || bad "deed warn step without the script: rc=$rc $(cat "$WORK/o")"
printf 'FAIL ./z_chora.deed: line 1: bad\n' > "$WORK/deed-lint.log"
LANE="$ROOT/scripts/conformance-deed.sh" RUNNER_TEMP="$WORK" bash -e -o pipefail "$WORK/warnstep.sh" > "$WORK/o" 2>&1; rc=$?
{ [ $rc -eq 0 ] && grep -q "^::warning file=z_chora.deed::deed conformance (advisory): line 1: bad" "$WORK/o"; } \
  && ok "deed: with the script present the warning step delegates to it" || bad "deed warn step with the script: rc=$rc $(cat "$WORK/o")"
paths=$(rb 'puts YAML.load_file(ARGV[0])[true]["push"]["paths"].join("|")' "$D" 2>/dev/null || rb 'puts YAML.load_file(ARGV[0])["on"]["push"]["paths"].join("|")' "$D")
{ [[ "$paths" == *scripts/conformance-deed.sh* ]] && [[ "$paths" == *scripts/tests/conformance-deed-test.sh* ]]; } \
  && ok "deed: a push touching only the extracted script or its test runs the workflow" || bad "deed push paths: $paths"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
