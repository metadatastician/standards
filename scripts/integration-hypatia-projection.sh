#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise the ACTUAL reusable scan step with a fixture scanner and the real,
# built Hypatia SARIF module. HYPATIA_SOURCE must be a compiled pinned checkout.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source_dir=${HYPATIA_SOURCE:?point HYPATIA_SOURCE at a built Hypatia checkout}
source_dir=$(cd "$source_dir" && pwd)
command -v mix >/dev/null || { echo 'mix is required' >&2; exit 2; }
[ -d "$source_dir/_build" ] && [ -f "$source_dir/mix.exs" ] || { echo 'Hypatia has not been compiled' >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# Exercise the real pinned rule and CLI normalization against a tiny caller.
# The CLI emits the descriptive `type`, not the source rule's WF code.
mkdir -p "$tmp/rule-fixture/.github/workflows"
cat > "$tmp/rule-fixture/.github/workflows/governance.yml" <<'YAML'
on: push
jobs:
  governance:
    uses: hyperpolymath/standards/.github/workflows/governance-reusable.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
YAML
export WF_FIXTURE="$tmp/rule-fixture" WF_FINDING="$tmp/wf-finding.json"
(
  cd "$source_dir"
  mix run --no-start --no-compile -e '
    root = System.fetch_env!("WF_FIXTURE")
    findings = Hypatia.CLI.collect_findings(root, [:workflow_audit])
    [finding] = Enum.filter(findings, &(&1.rule_module == "workflow_audit" and &1.type == "reusable_call_to_moved_repository"))
    unless finding.advisory == true and finding.severity == "low" and finding.line == 4 and
           String.starts_with?(finding.replacement, "metadatastician/standards/"), do: raise "invalid WF028"
    {without, _} = Hypatia.CLI.report_sets([finding], %{severity: "medium", advisory: false})
    {with_advisory, blocking} = Hypatia.CLI.report_sets([finding], %{severity: "medium", advisory: true})
    unless without == [] and with_advisory == [finding] and blocking == [], do: raise "invalid advisory semantics"
    unless Hypatia.Rules.StandardsRepo.current() == "metadatastician/standards" and
           "hyperpolymath/standards" in Hypatia.Rules.StandardsRepo.former(), do: raise "invalid registry"
    wf = File.read!(Path.join(root, ".github/workflows/governance.yml"))
    canonical = String.replace(wf, "hyperpolymath/standards/", "metadatastician/standards/")
    unless Hypatia.Rules.WorkflowAudit.check_reusable_call_to_moved_repository(%{"governance.yml" => canonical}) == [],
      do: raise "canonical reusable was flagged"
    IO.puts(Jason.encode!(finding))
  '
) > "$WF_FINDING"
jq -e '.type == "reusable_call_to_moved_repository" and .advisory == true and .severity == "low"' "$WF_FINDING" >/dev/null
echo 'PASS: pinned Hypatia WF028, CLI advisory normalization and shared registry'
# Confirm the pinned RE001 rule sees the actual Radicle workflow's narrowly
# scoped secret as warning-level debt, not the previous shared-step high. The
# synthetic legacy control proves that this test detects the old exposure.
mkdir -p "$tmp/radicle-fixture/.github/workflows"
cp "$root/.github/workflows/mirror-reusable.yml" "$tmp/radicle-fixture/.github/workflows/mirror-reusable.yml"
cat > "$tmp/radicle-legacy.yml" <<'YAML'
on: workflow_call
jobs:
  mirror-radicle:
    runs-on: ubuntu-latest
    env:
      RADICLE_KEY: ${{ secrets.RADICLE_KEY }}
    steps:
      - run: cargo install radicle-cli --locked
YAML
export RADICLE_FIXTURE="$tmp/radicle-fixture" RADICLE_LEGACY="$tmp/radicle-legacy.yml"
(
  cd "$source_dir"
  mix run --no-start --no-compile -e '
    root = System.fetch_env!("RADICLE_FIXTURE")
    radicle = fn f -> f.file == ".github/workflows/mirror-reusable.yml" and
                       String.contains?(f.reason, "job `mirror-radicle`") end
    current = Hypatia.Rules.ResearchExtensions.re001_missing_harden_runner(root) |> Enum.filter(radicle)
    unless Enum.any?(current, &(&1.severity == :warn)) and not Enum.any?(current, &(&1.severity == :high)),
      do: raise "Radicle credentials still share a fetched-code step (or the RE001 debt was hidden)"
    File.cp!(System.fetch_env!("RADICLE_LEGACY"), Path.join(root, ".github/workflows/mirror-reusable.yml"))
    legacy = Hypatia.Rules.ResearchExtensions.re001_missing_harden_runner(root) |> Enum.filter(radicle)
    unless Enum.any?(legacy, &(&1.severity == :high)), do: raise "RE001 negative control failed"
  '
)
echo 'PASS: pinned Hypatia RE001 detects the old Radicle exposure but not the step-scoped fix'
mkdir -p "$tmp/home/hypatia" "$tmp/work"
for path in mix.exs mix.lock _build deps lib config; do
  [ ! -e "$source_dir/$path" ] || ln -s "$source_dir/$path" "$tmp/home/hypatia/$path"
done
cat > "$tmp/home/hypatia/hypatia-cli.sh" <<'SCANNER'
#!/usr/bin/env bash
set -euo pipefail
printf 'scan\n' >> "$SCAN_LOG"
[ "${HYPATIA_FORMAT:-}" = json ] && [ "${HYPATIA_SEVERITY:-}" = medium ] || exit 2
jq -n --arg adv "${HYPATIA_ADVISORY:-false}" --slurpfile wf "$WF_FINDING" '
  [{severity:"critical",rule_module:"code_scanning_alerts",type:"CSA003",file:"old.rs",line:7,reason:"historical echo"},
   {severity:"high",rule_module:"code_safety",type:"unsafe_block",file:"src/a.rs",line:12,reason:"real issue (1 occurrences, CWE-79, line 12)"},
   {severity:"medium",rule_module:"workflow_audit",type:"WF001",file:".github/workflows/a.yml",line:5,reason:"warning mentioning CWE-79"}]
   + (if $adv == "true" then [$wf[0]] else [] end)'
SCANNER
chmod +x "$tmp/home/hypatia/hypatia-cli.sh"
awk '/^      - name: Run Hypatia scan$/{step=1} step && /^        run: \|$/{run=1; next}
  run && /^      - name:/{exit} run {if ($0 ~ /^          /) sub(/^          /, ""); print}' \
  "$root/.github/workflows/hypatia-scan-reusable.yml" > "$tmp/scan.sh"
[ -s "$tmp/scan.sh" ] || { echo 'could not extract reusable scan step' >&2; exit 1; }
cd "$tmp/work"
# The built checkout's Hex/Mix archives live in the runner's original home.
# Keep them available when the fixture substitutes HOME for the scanner path.
export MIX_HOME="${MIX_HOME:-$HOME/.mix}" HEX_HOME="${HEX_HOME:-$HOME/.hex}"
export HOME="$tmp/home" SCAN_LOG="$tmp/scans"
HYPATIA_ADVISORY=false bash "$tmp/scan.sh"
[ "$(wc -l < "$SCAN_LOG")" -eq 1 ] || { echo 'scanner was invoked more than once' >&2; exit 1; }
jq -S . hypatia.sarif > "$tmp/without.sarif"
: > "$SCAN_LOG"
HYPATIA_ADVISORY=true bash "$tmp/scan.sh"
[ "$(wc -l < "$SCAN_LOG")" -eq 1 ] || { echo 'scanner was invoked more than once' >&2; exit 1; }
jq -S . hypatia.sarif > "$tmp/with.sarif"
cmp "$tmp/without.sarif" "$tmp/with.sarif" || { echo 'advisory opt-in changed SARIF' >&2; exit 1; }
jq -e 'any(.[]; .type == "reusable_call_to_moved_repository" and .advisory == true)' hypatia-findings.json >/dev/null
jq -e '.version == "2.1.0" and (.runs[0].tool.driver.name == "Hypatia") and
  (.runs[0].results | length == 2) and
  all(.runs[0].results[]; (.ruleId | contains("code_scanning_alerts") | not) and (.ruleId | contains("reusable_call_to_moved_repository") | not)) and
  any(.runs[0].results[]; .ruleId == "hypatia/code_safety/unsafe_block" and .level == "error" and
    .properties["hypatia.severity"] == "high" and .properties["hypatia.originalLine"] == 12 and
    .properties["hypatia.originalFile"] == "src/a.rs" and
    .properties["hypatia.class"] == "CWE-79" and (.partialFingerprints["hypatiaFindingHash/v1"] | length == 64)) and
  any(.runs[0].results[]; .ruleId == "hypatia/workflow_audit/WF001" and .properties["hypatia.class"] == "WF001")' \
  hypatia.sarif >/dev/null
# Exercise the same baseline filter and grid as the reusable on this real
# projection: the accepted high is absent from the SARIF/gate/row while the
# medium result remains, and the critical alert echo stays inventory only.
jq 'map(select(.severity == "critical" or .severity == "high" or .severity == "medium" or .severity == "warn"))' \
  hypatia-findings.json > hypatia-findings.gating.json
cat > baseline.json <<'JSON'
[{"severity":"high","rule_module":"code_safety","type":"unsafe_block","file":"src/a.rs"}]
JSON
: > "$tmp/filter-output"
APPLY_BASELINE="$root/scripts/apply-baseline.sh" GITHUB_OUTPUT="$tmp/filter-output" \
  bash "$root/scripts/filter-sarif-by-baseline.sh" hypatia.sarif hypatia-findings.gating.json baseline.json
[ "$(cat "$tmp/filter-output")" = 'filtered=true' ]
jq -e '(.runs[0].results | length == 1) and .runs[0].results[0].level == "warning"' hypatia.sarif >/dev/null
bash "$root/scripts/verdict-grid.sh" render --out "$tmp/grid" --hypatia hypatia-findings.json \
  --hypatia-sarif hypatia.sarif >/dev/null
jq -e '.state == "yellow" and (.reporters[0].counts.high == 0) and
  (.reporters[0].counts.medium == 1) and (.hypatia_alerts.total == 1) and
  (.hypatia_json_advisories.total == 1)' "$tmp/grid/report.json" >/dev/null
grep -q 'WF028' "$tmp/grid/report.md" || { echo 'WF028 advisory label missing from grid' >&2; exit 1; }
echo 'PASS: real Hypatia SARIF projects one scan, preserves fingerprints and excludes JSON-only advisory/meta findings'
echo 'PASS: baseline-filtered projection drives the grid while raw alert/advisory inventory stays separate'
