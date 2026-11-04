#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Execute the actual reusable-workflow steps against success and failure controls.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if command -v ruby >/dev/null 2>&1; then
  ruby -ryaml -e '
    workflow = YAML.load_file(ARGV[0])
    steps = workflow.fetch("jobs").fetch("scan").fetch("steps")
    scan_runner = steps.find { |step| step["name"] == "Run Hypatia scan" }
    validator = steps.find { |step| step["id"] == "scan" }
    gate = steps.find { |step| step["id"] == "blocking-findings" }
    abort "blocking gate is not opt-in" unless gate.fetch("if") == "inputs.block-on-high"
    ["Relativize finding paths", "Filter SARIF through the baseline before upload", "Upload SARIF to code scanning", "Upload findings artifacts"].each do |name|
      s = steps.find { |step| step["name"] == name } or abort("missing step: #{name}")
      abort("#{name} must not use if: always() (standards#1050)") if s["if"].to_s.include?("always()")
    end
    pa_install = steps.find { |step| step["id"] == "panic-attack-install" } or abort("missing step: panic-attack-install")
    pa_run = steps.find { |step| step["id"] == "panic-attack" } or abort("missing step: panic-attack")
    fetch_filter = steps.index { |step| step["id"] == "fetch_filter" } or abort("missing step: fetch_filter")
    abort "panic-attack must run before the standards checkout" unless steps.index(pa_run) < fetch_filter
    File.write(ARGV[1] + "/scan.sh", scan_runner.fetch("run"))
    File.write(ARGV[1] + "/validate.sh", validator.fetch("run"))
    File.write(ARGV[1] + "/gate.sh", gate.fetch("run"))
    File.write(ARGV[1] + "/pa-install.sh", pa_install.fetch("run"))
    File.write(ARGV[1] + "/pa-run.sh", pa_run.fetch("run"))
  ' "$repo/.github/workflows/hypatia-scan-reusable.yml" "$tmp"
else
  awk -v out_dir="$tmp" '
    function flush_step() {
      if (step_name == "") return
      step_n++
      seen[step_name] = 1
      step_if_map[step_name] = step_if
      if (step_id == "panic-attack-install") {
        pa_install_seen = 1
        printf "%s", run_body > (out_dir "/pa-install.sh")
        close(out_dir "/pa-install.sh")
      }
      if (step_id == "panic-attack") {
        pa_run_idx = step_n
        printf "%s", run_body > (out_dir "/pa-run.sh")
        close(out_dir "/pa-run.sh")
      }
      if (step_id == "fetch_filter") fetch_filter_idx = step_n
      if (step_name == "Run Hypatia scan") {
        printf "%s", run_body > (out_dir "/scan.sh")
        close(out_dir "/scan.sh")
      }
      if (step_id == "scan") {
        printf "%s", run_body > (out_dir "/validate.sh")
        close(out_dir "/validate.sh")
      }
      if (step_id == "blocking-findings") {
        gate_if = step_if
        printf "%s", run_body > (out_dir "/gate.sh")
        close(out_dir "/gate.sh")
      }
    }
    /^      - name: / {
      flush_step()
      step_name = $0
      sub(/^      - name:[[:space:]]*/, "", step_name)
      step_id = ""; step_if = ""; run_body = ""; in_run = 0
      next
    }
    in_run {
      if ($0 ~ /^          / || $0 == "") {
        line = $0
        sub(/^          /, "", line)
        run_body = run_body line "\n"
        next
      } else {
        in_run = 0
      }
    }
    /^        id:[[:space:]]*/ {
      step_id = $0
      sub(/^        id:[[:space:]]*/, "", step_id)
      next
    }
    /^        if:[[:space:]]*/ {
      step_if = $0
      sub(/^        if:[[:space:]]*/, "", step_if)
      gsub(/^[\x27"]|[\x27"]$/, "", step_if)
      next
    }
    /^        run:[[:space:]]*\|$/ {
      in_run = 1
      next
    }
    END {
      flush_step()
      if (gate_if != "inputs.block-on-high") {
        print "blocking gate is not opt-in" > "/dev/stderr"
        exit 1
      }
      if (!pa_install_seen || !pa_run_idx || !fetch_filter_idx) {
        print "missing step: panic-attack-install, panic-attack or fetch_filter" > "/dev/stderr"
        exit 1
      }
      if (pa_run_idx > fetch_filter_idx) {
        print "panic-attack must run before the standards checkout" > "/dev/stderr"
        exit 1
      }
      split("Relativize finding paths|Filter SARIF through the baseline before upload|Upload SARIF to code scanning|Upload findings artifacts", req, "|")
      for (i in req) {
        n = req[i]
        if (!(n in seen)) {
          print "missing step: " n > "/dev/stderr"
          exit 1
        }
        if (index(step_if_map[n], "always()") > 0) {
          print n " must not use if: always() (standards#1050)" > "/dev/stderr"
          exit 1
        }
      }
    }
  ' "$repo/.github/workflows/hypatia-scan-reusable.yml"
fi
export GITHUB_OUTPUT="$tmp/output" GITHUB_STEP_SUMMARY="$tmp/summary"
cd "$tmp"
check() {
  local name=$1 expected=$2 payload=$3 actual
  if [[ "$payload" = MISSING ]]; then
    rm -f hypatia-findings.json
  else
    printf '%s' "$payload" > hypatia-findings.json
  fi
  if bash validate.sh >result.log 2>&1; then
    # Fixture for the authoritative renderer's severity projection. The
    # separate controls below exercise malformed SARIF and historical echoes.
    jq '{version:"2.1.0", runs:[{tool:{driver:{name:"Hypatia"}}, results:
      [.[] | {ruleId:"hypatia/control/planted", level:
        (if .severity == "critical" or .severity == "high" then "error"
         elif .severity == "medium" then "warning" else "note" end)}]}]}' \
      hypatia-findings.json > hypatia.sarif
    if bash gate.sh >>result.log 2>&1; then actual=0; else actual=$?; fi
  else
    actual=$?
  fi
  if [[ "$actual" -ne "$expected" ]]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$name" "$expected" "$actual"
    cat result.log
    exit 1
  fi
  printf 'PASS: %s\n' "$name"
}
check 'clean scan (empty findings array) passes' 0 '[]'
check 'low, warn, and informational findings pass' 0 '[{"severity":"low"},{"severity":"warn"},{"severity":"info"}]'
check 'high finding blocks' 1 '[{"severity":"high"}]'
check 'critical finding blocks' 1 '[{"severity":"critical"}]'
check 'missing artifact refuses' 2 MISSING
check 'empty artifact refuses' 2 ''
check 'whitespace-only artifact refuses' 2 $'   \n'
check 'truncated JSON refuses' 2 '[{"severity":'
check 'object is not a findings array' 2 '{}'
check 'null is not a findings array' 2 'null'
check 'unknown severity refuses' 2 '[{"severity":"unknown"}]'
check 'missing severity refuses' 2 '[{}]'
check 'multiple JSON documents refuse' 2 '[] []'
check 'newline-separated JSON documents refuse' 2 $'[]\n[{"severity":"high"}]'

sarif_check() {
  local name=$1 expected=$2 payload=$3 actual
  if [[ "$payload" = MISSING ]]; then
    rm -f hypatia.sarif
  else
    printf '%s' "$payload" > hypatia.sarif
  fi
  if bash gate.sh >result.log 2>&1; then actual=0; else actual=$?; fi
  if [[ "$actual" -ne "$expected" ]]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$name" "$expected" "$actual"
    cat result.log
    exit 1
  fi
  printf 'PASS: %s\n' "$name"
}
clean='{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[]}]}'
printf '%s' '[{"rule_module":"code_scanning_alerts","type":"CSA003","severity":"high"}]' > hypatia-findings.json
sarif_check 'historical echo does not block a clean current scan' 0 "$clean"
sarif_check 'missing SARIF refuses' 2 MISSING
sarif_check 'empty SARIF refuses' 2 ''
sarif_check 'truncated SARIF refuses' 2 '{"version":'
sarif_check 'multiple SARIF documents refuse' 2 "$clean $clean"
sarif_check 'empty runs refuse' 2 '{"version":"2.1.0","runs":[]}'
sarif_check 'missing results refuse' 2 '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}}}]}'
sarif_check 'unknown result level refuses' 2 '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[{"ruleId":"control","level":"unknown"}]}]}'
sarif_check 'malformed SARIF properties refuse' 2 '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[{"ruleId":"control","level":"warning","properties":42}]}]}'
sarif_check 'boolean SARIF properties refuse' 2 '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[{"ruleId":"control","level":"warning","properties":false}]}]}'
sarif_check 'malformed SARIF locations refuse' 2 '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[{"ruleId":"control","level":"warning","locations":42}]}]}'
printf '%s' '[]' > .hypatia-baseline.json
sarif_check 'baseline without validator refuses' 2 "$clean"
mkdir scripts
cp "$repo/scripts/apply-baseline.sh" scripts/apply-baseline.sh
printf '%s' '[]' > hypatia-findings.gating.json
sarif_check 'unconfirmed baseline filtering refuses' 2 "$clean"
export HYPATIA_BASELINE_FILTERED=true
sarif_check 'valid baseline accepted' 0 "$clean"
printf '%s' '{}' > .hypatia-baseline.json
sarif_check 'malformed baseline refuses even without findings' 2 "$clean"
rm -f .hypatia-baseline.json hypatia-findings.gating.json
unset HYPATIA_BASELINE_FILTERED

# CLI adapter contract controls (standards#1054): empty, warn, high, and crash fixtures
mkdir -p "$tmp/home/hypatia"
cat > "$tmp/home/hypatia/hypatia-cli.sh" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
printf 'scan\n' >> "$SCAN_LOG"
case "${FIXTURE_MODE:-}" in
  advisory)
    if [ "${HYPATIA_ADVISORY:-false}" = true ]; then
      printf '%s\n' '[{"severity":"low","advisory":true,"rule_module":"workflow_audit","type":"reusable_call_to_moved_repository","file":"ci.yml"},{"severity":"critical","rule_module":"code_scanning_alerts","type":"CSA003","file":"old.yml"}]'
    else
      printf '%s\n' '[{"severity":"critical","rule_module":"code_scanning_alerts","type":"CSA003","file":"old.yml"}]'
    fi
    ;;
  empty)
    if [[ "${HYPATIA_FORMAT:-}" = "json" ]]; then
      printf '[]\n'
    else
      printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[]}]}\n'
    fi
    ;;
  warn)
    if [[ "${HYPATIA_FORMAT:-}" = "json" ]]; then
      printf '[{"severity":"warn","rule_module":"research_extensions","type":"RE001","file":"ci.yml"}]\n'
    else
      printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[{"ruleId":"hypatia/RE001","level":"warning"}]}]}\n'
    fi
    ;;
  high)
    if [[ "${HYPATIA_FORMAT:-}" = "json" ]]; then
      printf '[{"severity":"high","rule_module":"workflow_hardening","type":"WH001","file":"ci.yml"}]\n'
    else
      printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[{"ruleId":"hypatia/WH001","level":"error"}]}]}\n'
    fi
    ;;
  crash)
    printf '[]\n'
    exit 1
    ;;
esac
CLI
chmod +x "$tmp/home/hypatia/hypatia-cli.sh"
# Offline mock for Mix: assert the captured JSON is projected, not rescanned.
# Real Hypatia.SARIF is additionally exercised by the integration canary job.
mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/mix" <<'MIX'
#!/usr/bin/env bash
set -euo pipefail
jq '{version:"2.1.0", runs:[{tool:{driver:{name:"Hypatia"}}, results:
  [.[] | select(.rule_module != "code_scanning_alerts") |
   select(.severity == "critical" or .severity == "high" or .severity == "medium" or .severity == "warn") |
   {ruleId:("hypatia/" + .rule_module + "/" + .type),
    level:(if .severity == "critical" or .severity == "high" then "error" else "warning" end)}]}]}' "$FINDINGS_PATH"
MIX
chmod +x "$tmp/fakebin/mix"
export SCAN_LOG="$tmp/scan-count"

adapter_check() {
  local name=$1 mode=$2 expected=$3 actual
  rm -f hypatia-findings.json hypatia.sarif "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY" "$SCAN_LOG"
  if HOME="$tmp/home" PATH="$tmp/fakebin:$PATH" FIXTURE_MODE="$mode" bash scan.sh >result.log 2>&1; then
    if bash validate.sh >>result.log 2>&1; then
      if bash gate.sh >>result.log 2>&1; then actual=0; else actual=$?; fi
    else
      actual=$?
    fi
  else
    actual=$?
  fi
  if [[ "$actual" -ne "$expected" ]]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$name" "$expected" "$actual"
    cat result.log
    exit 1
  fi
  [ "$(wc -l < "$SCAN_LOG")" -eq 1 ] || { echo "FAIL: scanner did not run exactly once" >&2; exit 1; }
  printf 'PASS: %s\n' "$name"
}
adapter_check 'CLI adapter empty fixture produces zero-result SARIF and passes' empty 0
adapter_check 'CLI adapter warn fixture produces warning SARIF and passes' warn 0
adapter_check 'CLI adapter high fixture produces error SARIF and blocks' high 1
adapter_check 'CLI adapter crash fixture fails closed even if [] was written' crash 1
HYPATIA_ADVISORY=true adapter_check 'opt-in advisory stays out of SARIF gating' advisory 0
jq -e 'any(.[]; .type == "reusable_call_to_moved_repository" and .advisory == true)' hypatia-findings.json >/dev/null || { echo 'FAIL: WF028 missing from JSON' >&2; exit 1; }
jq -e '[.runs[].results[]] | length == 0' hypatia.sarif >/dev/null || { echo 'FAIL: advisory or meta echo entered SARIF' >&2; exit 1; }
HYPATIA_ADVISORY=false adapter_check 'default advisory off' advisory 0
jq -e 'all(.[]; .type != "reusable_call_to_moved_repository")' hypatia-findings.json >/dev/null || { echo 'FAIL: default JSON includes WF028' >&2; exit 1; }

# panic-attack controls. The step is advisory: it never fails the job, and it
# never writes a bare `[]`. A skip or a failure must be an explicit status.
export PANIC_ATTACK_SHA=410a8f821ea8297833162565b50a298f787815da
fail() { printf 'FAIL: %s\n' "$1"; cat result.log; exit 1; }

cat > "$tmp/fake-panic-attack" <<'PA'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" = "assail . --output" ]] || { echo "unexpected args: $*" >&2; exit 64; }
echo "Running assail analysis on: ."
case "${PA_FIXTURE:-}" in
  clean) printf '{"schema_version":"2.5","weak_points":[]}\n' > "$4" ;;
  findings) printf '%s\n' '{"schema_version":"2.5","weak_points":[{"severity":"Critical"},{"severity":"High"},{"severity":"High","suppressed":true},{"severity":"Medium"},{"severity":"Low"}]}' > "$4" ;;
  crash) echo "assail crashed" >&2; exit 3 ;;
  timed-out) exit 124 ;;
  no-report) ;;
  bad-severity) printf '{"weak_points":[{"severity":"Severe"}]}\n' > "$4" ;;
esac
PA
chmod +x "$tmp/fake-panic-attack"

# pa_check NAME STATUS JQ_ASSERTION [VAR=VALUE ...]: run the scan step with the
# given environment and check the envelope it writes.
pa_check() {
  local name=$1 status=$2 assertion=$3
  shift 3
  rm -f panic-attack-findings.json "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"
  env PA_BIN= PA_INSTALL_REASON= PA_FIXTURE= "$@" bash pa-run.sh > result.log 2>&1 \
    || fail "$name: the panic-attack step must never fail the job"
  jq -e --arg status "$status" --arg ref "$PANIC_ATTACK_SHA" \
    "type == \"object\" and .status == \$status and .tool == \"panic-attack\" and .ref == \$ref and ($assertion)" \
    panic-attack-findings.json > /dev/null 2>&1 \
    || { cat panic-attack-findings.json >> result.log 2>&1; fail "$name: envelope"; }
  grep -qx "status=$status" "$GITHUB_OUTPUT" || fail "$name: step output status=$status"
  if [[ "$status" = ran ]]; then
    if [[ "$assertion" = *'critical: 0, high: 0'* ]]; then
      ! grep -q '^::warning' result.log || fail "$name: a clean scan must not warn"
    else
      grep -q '^::warning title=panic-attack findings (advisory)::' result.log || fail "$name: findings must warn"
    fi
    grep -q '^## panic-attack assail (advisory, does not gate)' "$GITHUB_STEP_SUMMARY" || fail "$name: summary"
  else
    grep -q '^::warning title=panic-attack \(NOT RUN\|ERROR\)::' result.log || fail "$name: a $status scan must warn"
    grep -q 'this is \*\*not\*\* a pass' "$GITHUB_STEP_SUMMARY" || fail "$name: summary must say it is not a pass"
  fi
  printf 'PASS: %s\n' "$name"
}
pa_check 'panic-attack skip writes a not_run marker, not []' not_run \
  '.reason == "cargo is not available on this runner" and .exit_code == null and .counts == null and .report == null' \
  PA_INSTALL_REASON='cargo is not available on this runner'
pa_check 'panic-attack skip without an install reason is still not_run' not_run \
  '.reason == "panic-attack is not installed"'
pa_check 'panic-attack missing binary path is not_run' not_run \
  '.reason == "panic-attack is not installed"' PA_BIN="$tmp/no-such-binary"
pa_check 'panic-attack clean scan records ran with zero counts' ran \
  '.counts == {critical: 0, high: 0, medium: 0, low: 0} and .exit_code == 0 and .reason == null and .report.schema_version == "2.5"' \
  PA_BIN="$tmp/fake-panic-attack" PA_FIXTURE=clean
grep -qx 'critical=0' "$GITHUB_OUTPUT" && grep -qx 'high=0' "$GITHUB_OUTPUT" || fail 'clean scan outputs'
pa_check 'panic-attack findings are counted without suppressed ones and do not gate' ran \
  '.counts == {critical: 1, high: 1, medium: 1, low: 1} and (.report.weak_points | length) == 5' \
  PA_BIN="$tmp/fake-panic-attack" PA_FIXTURE=findings
pa_check 'panic-attack crash records error with its exit code' error \
  '.exit_code == 3 and .reason == "panic-attack assail exited 3" and .report == null' \
  PA_BIN="$tmp/fake-panic-attack" PA_FIXTURE=crash
grep -q 'assail crashed' result.log || fail 'crash output must be shown in the log'
pa_check 'panic-attack scan that hits the 5-minute cap records error' error \
  '.exit_code == 124 and .reason == "panic-attack assail did not finish within 5 minutes"' \
  PA_BIN="$tmp/fake-panic-attack" PA_FIXTURE=timed-out
pa_check 'panic-attack exit 0 without a report records error' error \
  '.exit_code == 0 and .reason == "panic-attack assail exited 0 without a valid report"' \
  PA_BIN="$tmp/fake-panic-attack" PA_FIXTURE=no-report
pa_check 'panic-attack report with an unknown severity records error' error \
  '.reason == "panic-attack assail exited 0 without a valid report"' \
  PA_BIN="$tmp/fake-panic-attack" PA_FIXTURE=bad-severity

# Install step: PATH is a directory holding only the tools the step needs, so
# "cargo is absent" and a fake cargo are both under the test's control.
pa_bin_dir="$tmp/pa-path"
mkdir -p "$pa_bin_dir"
for tool in grep timeout mkdir chmod rm; do
  ln -s "$(command -v "$tool")" "$pa_bin_dir/$tool"
done
# ins_check NAME EXPECTED_OUTPUT_LINE HOME_DIR
ins_check() {
  local name=$1 expected=$2 home=$3
  rm -f "$GITHUB_OUTPUT"
  env PATH="$pa_bin_dir" HOME="$home" "$BASH" pa-install.sh > result.log 2>&1 \
    || fail "$name: the install step must never fail the job"
  grep -qxF "$expected" "$GITHUB_OUTPUT" || { cat "$GITHUB_OUTPUT" >> result.log 2>&1; fail "$name: expected $expected"; }
  if [[ "$expected" = reason=* ]]; then
    grep -q '^::warning title=panic-attack not installed::' result.log || fail "$name: must warn"
    ! grep -q '^bin=' "$GITHUB_OUTPUT" || fail "$name: must not output a binary"
    [[ ! -e "$home/.panic-attack" ]] || fail "$name: a failed install must leave nothing to cache"
  fi
  printf 'PASS: %s\n' "$name"
}
ins_check 'install without cargo reports why' \
  'reason=cargo is not available on this runner' "$tmp/home-empty"
mkdir -p "$tmp/home-stale/.panic-attack/bin"
cp "$tmp/fake-panic-attack" "$tmp/home-stale/.panic-attack/bin/panic-attack"
printf '[v1]\n"panic-attack 2.5.5 (git+https://github.com/hyperpolymath/panic-attack?rev=%s#%s)" = ["panic-attack"]\n' \
  0000000000000000000000000000000000000000 0000000000000000000000000000000000000000 > "$tmp/home-stale/.panic-attack/.crates.toml"
ins_check 'install does not trust a cached binary from another commit' \
  'reason=cargo is not available on this runner' "$tmp/home-stale"
mkdir -p "$tmp/home-cached/.panic-attack/bin"
cp "$tmp/fake-panic-attack" "$tmp/home-cached/.panic-attack/bin/panic-attack"
printf '[v1]\n"panic-attack 2.5.5 (git+https://github.com/hyperpolymath/panic-attack?rev=%s#%s)" = ["panic-attack"]\n' \
  "$PANIC_ATTACK_SHA" "$PANIC_ATTACK_SHA" > "$tmp/home-cached/.panic-attack/.crates.toml"
ins_check 'install uses a cached binary built from the pinned commit' \
  "bin=$tmp/home-cached/.panic-attack/bin/panic-attack" "$tmp/home-cached"

# A fake cargo: records its arguments, then fails, builds nothing, or installs.
cat > "$pa_bin_dir/cargo" <<CARGO
#!$BASH
printf '%s\n' "\$@" > "$tmp/cargo-args"
case "\$FAKE_CARGO" in
  fail) exit 101 ;;
  empty) exit 0 ;;
esac
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = --root ]; then root=\$2; fi
  shift
done
mkdir -p "\$root/bin"
printf '#!/bin/sh\n' > "\$root/bin/panic-attack"
chmod +x "\$root/bin/panic-attack"
CARGO
chmod +x "$pa_bin_dir/cargo"
FAKE_CARGO=fail ins_check 'install reports a failed source build' \
  "reason=source build at $PANIC_ATTACK_SHA failed or exceeded 10 minutes" "$tmp/home-fail"
FAKE_CARGO=empty ins_check 'install reports a build that left no binary' \
  "reason=no binary after the source build at $PANIC_ATTACK_SHA" "$tmp/home-empty-build"
FAKE_CARGO=ok ins_check 'install builds the pinned commit' \
  "bin=$tmp/home-built/.panic-attack/bin/panic-attack" "$tmp/home-built"
for arg in install --git https://github.com/hyperpolymath/panic-attack --rev "$PANIC_ATTACK_SHA" --locked --root; do
  grep -qxF -- "$arg" "$tmp/cargo-args" || fail "cargo install must be called with $arg"
done
printf 'PASS: %s\n' 'install pins the commit and the lockfile'
