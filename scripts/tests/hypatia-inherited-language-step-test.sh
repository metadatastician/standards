#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The inherited-language step of hypatia-scan-reusable.yml: the list fails
# closed, the filters use only the revision-matched helper, and the two
# opt-in inputs stay wired to the steps that honour them.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
workflow="$root/.github/workflows/hypatia-scan-reusable.yml"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
awk '/^      - name: Apply the inherited-language paths$/{step=1} step && /^        run: \|$/{run=1; next}
  run && /^      - name:/{exit} run {if ($0 ~ /^          /) sub(/^          /, ""); print}' \
  "$workflow" > "$tmp/step.sh"
[ -s "$tmp/step.sh" ] || { echo 'missing inherited-language workflow step' >&2; exit 1; }

cd "$tmp"; mkdir -p scripts config
fixture() {
  printf '%s\n' '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[
    {"ruleId":"hypatia/cicd_rules/banned_language_file","level":"error","locations":[{"physicalLocation":{"artifactLocation":{"uri":"frontend/a.ts"}}}]},
    {"ruleId":"hypatia/cicd_rules/banned_language_file","level":"error","locations":[{"physicalLocation":{"artifactLocation":{"uri":"frontend/fork-only.ts"}}}]}]}]}' > hypatia.sarif
  printf '%s\n' '[{"severity":"critical","rule_module":"cicd_rules","type":"banned_language_file","file":"frontend/a.ts"},
    {"severity":"critical","rule_module":"cicd_rules","type":"banned_language_file","file":"frontend/fork-only.ts"}]' > hypatia-findings.gating.json
  : > "$tmp/output"
}
sarif_count() { jq '[.runs[].results[]] | length' hypatia.sarif; }
export RUNNER_TEMP="$tmp/runner"; mkdir -p "$RUNNER_TEMP"
export GITHUB_OUTPUT="$tmp/output"
export INHERITED_LANGUAGE_PATHS=config/inherited.txt
printf '# received from upstream\nfrontend/a.ts\n' > config/inherited.txt

# A caller-local helper must never run against the gating projections.
printf '#!/usr/bin/env bash\ntouch "%s/used-caller-helper"\n' "$tmp" > scripts/inherited-language.sh
fixture
bash "$tmp/step.sh" >/dev/null
[ ! -e used-caller-helper ]
[ "$(sarif_count)" = 2 ]
[ ! -s "$tmp/output" ]
echo 'PASS: without the revision-matched helper nothing is excused and no list is announced'

mkdir -p .standards-checkout/scripts
cp "$root/scripts/inherited-language.sh" .standards-checkout/scripts/
fixture
bash "$tmp/step.sh" >/dev/null
[ ! -e used-caller-helper ]
[ "$(sarif_count)" = 1 ]
jq -e '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri == "frontend/fork-only.ts"' hypatia.sarif >/dev/null
jq -e 'length == 1 and .[0].file == "frontend/fork-only.ts"' hypatia-findings.gating.json >/dev/null
grep -qx "list=$RUNNER_TEMP/inherited-language-paths.txt" "$tmp/output"
[ "$(cat "$RUNNER_TEMP/inherited-language-paths.txt")" = frontend/a.ts ]
echo 'PASS: a valid list takes the one rule off the exact path in both gating projections'

printf 'frontend/a.ts\ntool.py\n' > config/inherited.txt
fixture
if bash "$tmp/step.sh" >/dev/null 2>&1; then echo 'ERROR: an unusable list did not fail the step' >&2; exit 1; fi
[ "$(sarif_count)" = 2 ]
jq -e 'length == 2' hypatia-findings.gating.json >/dev/null
[ ! -s "$tmp/output" ]
echo 'PASS: an unusable list fails the step and excuses nothing'

# The wiring that makes the two inputs mean something.
grep -Fq "if: \${{ inputs.inherited-language-paths != '' }}" "$workflow"
grep -Fq "if: \${{ inputs.sarif-upload-on-pull-request || github.event_name != 'pull_request' }}" "$workflow"
grep -Fq 'INHERITED_LANGUAGE_LIST: ${{ steps.inherited_language.outputs.list }}' "$workflow"
grep -Fq 'scope_args+=(--inherited-language-paths "$INHERITED_LANGUAGE_LIST")' "$workflow"
upload_if=$(awk '/^      - name: Upload SARIF to code scanning$/{step=1; next} step && /^      - name:/{exit} step && /^        if: /{print}' "$workflow")
[ -n "$upload_if" ]
echo 'PASS: both opt-in inputs are wired to the steps that honour them'
