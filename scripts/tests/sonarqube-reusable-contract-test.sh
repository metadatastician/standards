#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# sonarqube-reusable-contract-test.sh — holds sonarqube-reusable.yml to the
# properties that make its red mean something:
#
#   * the preflight runs before the scan, and the scan runs ONLY on `ok`, so
#     a credential fault can never reach the scanner's opaque exit codes;
#   * no `continue-on-error` anywhere: a fault is never quietly absorbed;
#   * the helper comes from this reusable's own commit (job.workflow_sha),
#     with the empty-SHA assertion, and is deleted before the scan;
#   * SONAR_TOKEN is a declared, optional workflow_call secret (so absence is
#     classified rather than a startup failure), never `secrets: inherit`;
#   * every action is pinned to a 40-hex commit and recorded in actions.lock.
#
# Exit 0 when every assertion holds.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
wf="$root/.github/workflows/sonarqube-reusable.yml"
lock="$root/.github/workflows/actions.lock"
helper="$root/scripts/sonar-preflight.sh"
pass=0; fail=0

t() { local label="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "PASS $label"
  else fail=$((fail+1)); echo "FAIL $label"; fi; }
# -e: some patterns start with `-`.
has()   { grep -qF -e "$2" "$1"; }
hasre() { grep -qE -e "$2" "$1"; }
# Non-comment lines only, so a comment cannot satisfy or violate a rule.
code()  { sed '/^[[:space:]]*#/d' "$wf"; }
code_has()   { code | grep -qF -e "$1"; }
code_lacks() { ! code | grep -qF -e "$1"; }
yqv()   { yq -r "$1" "$wf"; }
# The list under this workflow's `workflows:` key: from its 4-space key line
# up to the next 4-space key line (items are indented 8, so `[^ ]` matters).
in_lock_entry() {
  awk '/^    \x27\.github\/workflows\/sonarqube-reusable\.yml\x27:/ { f = 1; next }
       /^    [^ ]/ { f = 0 }
       f' "$lock" | grep -qiF -e "'$1'"
}

t "workflow exists"                     test -f "$wf"
t "helper exists and is executable"     test -x "$helper"
t "SPDX in the header block"            hasre "$wf" '^# SPDX-License-Identifier: MPL-2.0$'

if command -v yq >/dev/null 2>&1; then
  t "parses as YAML"                    yqv '.name'
  t "workflow_call trigger"             test "$(yqv '.on | has("workflow_call")')" = true
  t "SONAR_TOKEN declared, optional"    test "$(yqv '.on.workflow_call.secrets.SONAR_TOKEN.required')" = false
  t "top-level permissions read-only"   test "$(yqv '.permissions.contents')" = read
  steps_json="$(yq -o=json '.jobs.sonarqube.steps' "$wf")"
  pre_idx="$(jq '[.[].id] | index("preflight")' <<<"$steps_json")"
  scan_idx="$(jq '[.[].name] | index("SonarQube Scan")' <<<"$steps_json")"
  t "preflight step present"            test "$pre_idx" != null
  t "scan step present"                 test "$scan_idx" != null
  t "preflight runs before the scan"    test "$pre_idx" -lt "$scan_idx"
  t "scan gated on class == ok"         test "$(jq -r ".[$scan_idx].if" <<<"$steps_json")" = "steps.preflight.outputs.class == 'ok'"
  t "preflight is not conditional"      test "$(jq -r ".[$pre_idx].if // \"none\"" <<<"$steps_json")" = none
  t "class exported as job output"      test "$(yqv '.on.workflow_call.outputs.class.value')" = '${{ jobs.sonarqube.outputs.class }}'
else
  echo "SKIP structural checks: yq (mikefarah v4) not on PATH"
fi

t "no continue-on-error"                code_lacks "continue-on-error"
t "no secrets: inherit"                 code_lacks "secrets: inherit"
t "helper ref is job.workflow_sha"      code_has 'ref: ${{ job.workflow_sha }}'
t "empty workflow_sha is asserted"      code_has "grep -Eq '^[0-9a-f]{40}\$'"
t "helper tree deleted before scan"     code_has "rm -rf .standards-sonar"
t "credentials not persisted"           test "$(code | grep -c 'persist-credentials: false')" -ge 2

# Every `uses:` is a 40-hex pin, and each pin is in this workflow's lock entry.
uses="$(code | sed -nE 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*([^[:space:]#]+).*/\1/p')"
t "has uses: lines"                     test -n "$uses"
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  t "pinned: $ref"                      bash -c "printf '%s' '$ref' | grep -Eq '@[0-9a-f]{40}\$'"
  lc="$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')"
  t "in lock under this workflow: $lc"  in_lock_entry "$lc"
  t "lock record exists: $lc"           grep -qiF "    '$lc':" "$lock"
done <<<"$uses"

echo
echo "sonarqube-reusable-contract-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
