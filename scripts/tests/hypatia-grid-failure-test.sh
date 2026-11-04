#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# A broken renderer or an unreadable requested scope must surface orange.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
awk '/^      - name: Render the verdict grid$/{step=1} step && /^        run: \|$/{run=1; next}
  run && /^      - name:/{exit} run {if ($0 ~ /^          /) sub(/^          /, ""); print}' \
  "$root/.github/workflows/hypatia-scan-reusable.yml" > "$tmp/grid-step.sh"
[ -s "$tmp/grid-step.sh" ] || { echo 'missing grid workflow step' >&2; exit 1; }
cd "$tmp"
export RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/output" GITHUB_STEP_SUMMARY="$tmp/summary"
export HEAD_SHA=abc GITHUB_RUN_ID=1 GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=owner/repo
export PR_NUMBER=local HYPATIA_REF=abc PANIC_ATTACK_SHA=def PONS_SHA=ghi SCOPE_MODE=whole-repo SCOPE_EXCLUDES=
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
bash "$tmp/grid-step.sh"
grep -qx 'state=orange' "$GITHUB_OUTPUT"
jq -e '.color == "orange" and .message == "indeterminate"' verdict-grid/badge.json >/dev/null
[ ! -e verdict-grid/report.json ]
mkdir -p .standards-grid/scripts
printf '#!/usr/bin/env bash\nprintf "stale" > verdict-grid/report.json\nexit 2\n' > .standards-grid/scripts/verdict-grid.sh
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
bash "$tmp/grid-step.sh"
grep -qx 'state=orange' "$GITHUB_OUTPUT"
[ ! -e verdict-grid/report.json ]
grep -q 'renderer failed' verdict-grid/report.md
# A renderer claiming success without a report is still missing evidence.
printf '#!/usr/bin/env bash\nexit 0\n' > .standards-grid/scripts/verdict-grid.sh
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
bash "$tmp/grid-step.sh"
grep -qx 'state=orange' "$GITHUB_OUTPUT"
grep -q 'no readable report' verdict-grid/report.md
# Exercise the real renderer with an unreadable requested delta scope too.
cp "$root/scripts/verdict-grid.sh" .standards-grid/scripts/
cp -R "$root/scripts/lib" .standards-grid/scripts/
export SCOPE_MODE=delta
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
bash "$tmp/grid-step.sh" >/dev/null 2>&1
grep -qx 'state=orange' "$GITHUB_OUTPUT"
[ ! -s verdict-grid/report.json ]
# `always()` also runs when the resolver failed before writing GITHUB_ENV.
# Missing scanner refs must not crash under `set -u` or erase the orange row.
unset PANIC_ATTACK_SHA PONS_SHA
export SCOPE_MODE=whole-repo
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
bash "$tmp/grid-step.sh" >/dev/null
grep -qx 'state=orange' "$GITHUB_OUTPUT"
jq -e '.state == "orange"' verdict-grid/report.json >/dev/null
# Exercise the actual workflow argument wiring: filtered gate SARIF grades,
# while its pre-scope snapshot supplies the excluded inventory only.
cat > hypatia.pre-scope.sarif <<'JSON'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[
 {"ruleId":"hypatia/r/live","level":"warning","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/live.rs"}}}]},
 {"ruleId":"hypatia/r/archive","level":"error","locations":[{"physicalLocation":{"artifactLocation":{"uri":"9-archive/old.rs"}}}]}
]}]}
JSON
jq '.runs[0].results |= map(select(.ruleId != "hypatia/r/archive"))' hypatia.pre-scope.sarif > hypatia.sarif
printf '[]\n' > hypatia-findings.json
export PANIC_ATTACK_SHA=def PONS_SHA=ghi SCOPE_EXCLUDES=9-archive/
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
bash "$tmp/grid-step.sh" >/dev/null
jq -e '.state == "yellow" and (.reporters[] | select(.id == "hypatia") | .counts.medium == 1 and .counts_excluded.high == 1)' verdict-grid/report.json >/dev/null
echo 'PASS: grid workflow reports excluded SARIF findings without grading them'
echo 'PASS: a missing or failed grid renderer produces an explicit orange state'
