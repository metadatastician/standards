#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# apply-baseline-test.sh — regression test for apply-baseline.sh's
# file_pattern glob handling.
#
# The original implementation referenced `.file_pattern` inside `test(...)`,
# where jq rebinds `.` to test's input (a string), causing a "Cannot index
# string" error that was silently masked by `select(...)`'s error-tolerance
# and produced an always-matches result. This test pins both the exact-file
# and glob paths so the regression cannot recur.
#
# Run: bash scripts/tests/apply-baseline-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLY="${APPLY_BASELINE_TARGET:-$SCRIPT_DIR/../apply-baseline.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
COUNTS_JQ='"\(.findings_suppressed | length),\(.findings_kept | length)"'

assert_status() {
  local label="$1" findings="$2" baseline="$3" expected="$4"
  local got
  got=$(bash "$APPLY" "$findings" "$baseline" advisory \
    | jq -r "$COUNTS_JQ")
  if [ "$got" = "$expected" ]; then
    echo "PASS: $label  (suppressed,kept=$got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $label  expected=$expected got=$got"
    fail=$((fail + 1))
  fi
}

# === Case 1: exact `file` match ===
cat > "$WORK/findings1.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"src/Legacy.kt"}]
EOF
cat > "$WORK/baseline1.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"src/Legacy.kt"}]
EOF
assert_status "exact file match suppresses" \
  "$WORK/findings1.json" "$WORK/baseline1.json" "1,0"

# === Case 2: file_pattern `examples/**` matches nested file ===
cat > "$WORK/findings2.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"examples/kotlin/Nop.kt"}]
EOF
cat > "$WORK/baseline2.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file_pattern":"examples/**"}]
EOF
assert_status "file_pattern matches nested file" \
  "$WORK/findings2.json" "$WORK/baseline2.json" "1,0"

# === Case 2b: severity tier — a `warn` acknowledgement still matches the
# same finding now emitted as `medium` (hypatia#895), and vice versa; a
# different tier must not match. Real shape from standards' own baseline.
cat > "$WORK/findings2b.json" <<'EOF'
[{"severity":"medium","rule_module":"research_extensions","type":"RE001","file":".github/workflows/mirror-reusable.yml"}]
EOF
cat > "$WORK/baseline2b-warn.json" <<'EOF'
[{"severity":"warn","rule_module":"research_extensions","type":"RE001","file":".github/workflows/mirror-reusable.yml"}]
EOF
cat > "$WORK/baseline2b-high.json" <<'EOF'
[{"severity":"high","rule_module":"research_extensions","type":"RE001","file":".github/workflows/mirror-reusable.yml"}]
EOF
cat > "$WORK/findings2b-warn.json" <<'EOF'
[{"severity":"warn","rule_module":"research_extensions","type":"RE001","file":".github/workflows/mirror-reusable.yml"}]
EOF
cat > "$WORK/baseline2b-medium.json" <<'EOF'
[{"severity":"medium","rule_module":"research_extensions","type":"RE001","file":".github/workflows/mirror-reusable.yml"}]
EOF
assert_status "warn acknowledgement matches a medium finding" \
  "$WORK/findings2b.json" "$WORK/baseline2b-warn.json" "1,0"
assert_status "medium acknowledgement matches a warn finding" \
  "$WORK/findings2b-warn.json" "$WORK/baseline2b-medium.json" "1,0"
assert_status "a different tier does not match" \
  "$WORK/findings2b.json" "$WORK/baseline2b-high.json" "0,1"

# Exercise baseline mode too: aliases must suppress before thresholding, but
# only `warn`/`medium` are compatibility-equivalent. `info` and
# `informational` remain distinct emitted labels.
printf '[]\n' > "$WORK/empty.json"
assert_gate() {
  local label="$1" findings="$2" baseline="$3" threshold="$4" expected_status="$5" expected_counts="$6"
  local status=0 got
  BLOCKING_THRESHOLD="$threshold" bash "$APPLY" "$findings" "$baseline" blocking \
    >"$WORK/gate.out" 2>"$WORK/gate.err" || status=$?
  got=$(jq -r "$COUNTS_JQ" "$WORK/gate.out")
  if [[ "$status" -eq "$expected_status" && "$got" == "$expected_counts" ]]; then
    echo "PASS: $label (exit=$status, suppressed/kept=$got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $label expected exit=$expected_status counts=$expected_counts; got exit=$status counts=$got"
    cat "$WORK/gate.err"
    fail=$((fail + 1))
  fi
}

assert_gate "legacy warn ack suppresses current medium at blocking threshold" \
  "$WORK/findings2b.json" "$WORK/baseline2b-warn.json" high 0 "1,0"
assert_gate "legacy medium ack suppresses warn at blocking threshold" \
  "$WORK/findings2b-warn.json" "$WORK/baseline2b-medium.json" high 0 "1,0"
cat > "$WORK/findings-informational.json" <<'EOF'
[{"severity":"informational","rule_module":"research_extensions","type":"RE001","file":"ci.yml"}]
EOF
cat > "$WORK/baseline-info.json" <<'EOF'
[{"severity":"info","rule_module":"research_extensions","type":"RE001","file":"ci.yml"}]
EOF
cat > "$WORK/baseline-informational.json" <<'EOF'
[{"severity":"informational","rule_module":"research_extensions","type":"RE001","file":"ci.yml"}]
EOF
assert_status "informational baseline severity is accepted and matches exactly" \
  "$WORK/findings-informational.json" "$WORK/baseline-informational.json" "1,0"
assert_gate "info and informational are not conflated" \
  "$WORK/findings-informational.json" "$WORK/baseline-info.json" info 1 "0,1"
printf '%s\n' '[{"severity":"warn"}]' > "$WORK/findings-warn.json"
printf '%s\n' '[{"severity":"informational"}]' > "$WORK/findings-informational-only.json"
assert_gate "warn blocks at medium threshold" \
  "$WORK/findings-warn.json" "$WORK/empty.json" medium 1 "0,1"
assert_gate "warn does not block at high threshold" \
  "$WORK/findings-warn.json" "$WORK/empty.json" high 0 "0,1"
assert_gate "informational blocks at info threshold" \
  "$WORK/findings-informational-only.json" "$WORK/empty.json" info 1 "0,1"
assert_gate "informational does not block at low threshold" \
  "$WORK/findings-informational-only.json" "$WORK/empty.json" low 0 "0,1"

# Source severities and override targets are separate schema enums. A valid
# downgrade is carried through the output and then ranked for the gate.
cat > "$WORK/findings-override.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"src/Legacy.kt"}]
EOF
cat > "$WORK/baseline-override-low.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"src/Legacy.kt","severity_override":"low"}]
EOF
assert_gate "low override downgrades a matching high finding" \
  "$WORK/findings-override.json" "$WORK/baseline-override-low.json" high 0 "0,1"
if [[ "$(jq -r '.findings_kept[0] | [.severity,.baseline_status] | join(",")' "$WORK/gate.out")" == "low,downgraded" ]]; then
  echo "PASS: low override is visible as a downgraded finding"
  pass=$((pass + 1))
else
  echo "FAIL: low override was not preserved in output"
  fail=$((fail + 1))
fi
cat > "$WORK/baseline-override-info.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"src/Legacy.kt","severity_override":"info"}]
EOF
assert_gate "info override blocks at info but not low threshold" \
  "$WORK/findings-override.json" "$WORK/baseline-override-info.json" info 1 "0,1"
assert_gate "info override remains below low threshold" \
  "$WORK/findings-override.json" "$WORK/baseline-override-info.json" low 0 "0,1"
cat > "$WORK/baseline-override-advisory.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"src/Legacy.kt","severity_override":"advisory"}]
EOF
assert_gate "advisory override does not block info threshold" \
  "$WORK/findings-override.json" "$WORK/baseline-override-advisory.json" info 0 "0,1"
for override in warn informational 7; do
  jq -n --arg override "$override" '[{severity:"high",rule_module:"cicd_rules",type:"banned_language_file",file:"src/Legacy.kt",severity_override:$override}]' > "$WORK/baseline-invalid-override.json"
  status=0
  bash "$APPLY" "$WORK/findings-override.json" "$WORK/baseline-invalid-override.json" advisory >/dev/null 2>&1 || status=$?
  if [[ "$status" -eq 2 ]]; then
    echo "PASS: invalid severity_override rejected with schema exit 2: $override"
    pass=$((pass + 1))
  else
    echo "FAIL: severity_override $override returned $status (expected 2)"
    fail=$((fail + 1))
  fi
done

assert_invalid_baseline() {
  local label="$1" content="$2" status=0
  printf '%s\n' "$content" > "$WORK/baseline-invalid.json"
  bash "$APPLY" "$WORK/findings-override.json" "$WORK/baseline-invalid.json" advisory >/dev/null 2>&1 || status=$?
  if [[ "$status" -eq 2 ]]; then
    echo "PASS: invalid baseline rejected with schema exit 2: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: invalid baseline $label returned $status (expected 2)"
    fail=$((fail + 1))
  fi
}
assert_invalid_baseline "duplicate rule_module array member" \
  '[{"severity":"high","rule_module":["cicd_rules","cicd_rules"],"type":"banned_language_file","file":"src/Legacy.kt"}]'
assert_invalid_baseline "non-string note" \
  '[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"src/Legacy.kt","note":1}]'
assert_invalid_baseline "unknown source severity" \
  '[{"severity":"urgent","rule_module":"cicd_rules","type":"banned_language_file","file":"src/Legacy.kt"}]'

# The gate message counts only findings at/above the threshold, while still
# reporting how many total findings remain for context.
printf '%s\n' '[{"severity":"high"},{"severity":"info"}]' > "$WORK/findings-mixed.json"
echo '[]' > "$WORK/empty-baseline.json"
if BLOCKING_THRESHOLD=high bash "$APPLY" "$WORK/findings-mixed.json" "$WORK/empty-baseline.json" blocking >"$WORK/gate.out" 2>"$WORK/gate.err"; then
  echo "FAIL: high finding did not block"
  fail=$((fail + 1))
elif grep -Fq "1 unfiltered finding(s) at or above 'high' (2 kept in total)" "$WORK/gate.err"; then
  echo "PASS: blocking diagnostic distinguishes threshold findings from total kept"
  pass=$((pass + 1))
else
  echo "FAIL: blocking diagnostic count is inaccurate"
  cat "$WORK/gate.err"
  fail=$((fail + 1))
fi

# === Case 3: file_pattern MUST NOT match unrelated file (regression
# against the always-matches bug from `.file_pattern` inside test()) ===
cat > "$WORK/findings3.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"src/Unrelated.kt"}]
EOF
assert_status "file_pattern does not over-match" \
  "$WORK/findings3.json" "$WORK/baseline2.json" "0,1"

# === Case 4: single-segment * does not cross / ===
cat > "$WORK/findings4a.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"vendor/acme/legacy.java"}]
EOF
cat > "$WORK/findings4b.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file":"vendor/acme/deep/legacy.java"}]
EOF
cat > "$WORK/baseline4.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"banned_language_file","file_pattern":"vendor/*/legacy.java"}]
EOF
assert_status "single * matches one segment" \
  "$WORK/findings4a.json" "$WORK/baseline4.json" "1,0"
assert_status "single * does not cross slash" \
  "$WORK/findings4b.json" "$WORK/baseline4.json" "0,1"

# === Case 5: empty baseline keeps the finding ===
echo '[]' > "$WORK/empty.json"
assert_status "empty baseline keeps finding" \
  "$WORK/findings2.json" "$WORK/empty.json" "0,1"

# === Case 6: emitted hyphenated Hypatia rule IDs are representable ===
cat > "$WORK/findings6.json" <<'EOF'
[{"severity":"medium","rule_module":"implementation_inside_canon","type":"HYP-S009","file":"spec/Cargo.toml"}]
EOF
cat > "$WORK/baseline6.json" <<'EOF'
[{"severity":"medium","rule_module":"implementation_inside_canon","type":"HYP-S009","file":"spec/Cargo.toml"}]
EOF
assert_status "hyphenated HYP-S009 rule type is valid and matches" \
  "$WORK/findings6.json" "$WORK/baseline6.json" "1,0"

# A malformed doubled separator must remain invalid.
cat > "$WORK/baseline6-invalid.json" <<'EOF'
[{"severity":"medium","rule_module":"implementation_inside_canon","type":"HYP--S009","file":"spec/Cargo.toml"}]
EOF
if bash "$APPLY" "$WORK/findings6.json" "$WORK/baseline6-invalid.json" advisory >/dev/null 2>&1; then
  echo "FAIL: malformed HYP--S009 rule type was accepted"
  fail=$((fail + 1))
else
  echo "PASS: malformed HYP--S009 rule type is rejected"
  pass=$((pass + 1))
fi

# Regex metacharacters and the former sentinel must remain literal glob text.
for literal in 'src/foo.rs' 'src/a+b(1)[2]{x}^$?.rs' 'src/DOUBLESTAR.rs'; do
  jq -n --arg file "$literal" '[{severity:"high",rule_module:"cicd_rules",type:"banned_language_file",file:$file}]' > "$WORK/literal.json"
  jq -n --arg pattern "$literal" '[{severity:"high",rule_module:"cicd_rules",type:"banned_language_file",file_pattern:$pattern}]' > "$WORK/literal-baseline.json"
  assert_status "literal glob matches itself: $literal" "$WORK/literal.json" "$WORK/literal-baseline.json" "1,0"
done
jq -n '[{severity:"high",rule_module:"cicd_rules",type:"banned_language_file",file_pattern:"src/foo.rs"}]' > "$WORK/literal-baseline.json"
for unrelated in 'src/fooXrs' $'src/foo.rs\nother'; do
  jq -n --arg file "$unrelated" '[{severity:"high",rule_module:"cicd_rules",type:"banned_language_file",file:$file}]' > "$WORK/unrelated.json"
  assert_status "literal glob rejects unrelated path" "$WORK/unrelated.json" "$WORK/literal-baseline.json" "0,1"
done

assert_invalid_option() {
  local label="$1" mode="$2" threshold="$3" status=0
  BLOCKING_THRESHOLD="$threshold" bash "$APPLY" "$WORK/findings1.json" "$WORK/empty.json" "$mode" > "$WORK/invalid.out" 2> "$WORK/invalid.err" || status=$?
  if [[ "$status" -eq 2 ]]; then
    echo "PASS: $label rejected as invalid configuration"
    pass=$((pass + 1))
  else
    echo "FAIL: $label returned $status (expected 2)"
    cat "$WORK/invalid.err"
    fail=$((fail + 1))
  fi
}
# ═══════════════════════════════════════════════════════════════════════
# List-valued `rule_module` (standards#966)
#
# ONE DEFECT CAN BE EMITTED BY TWO RULE MODULES. Hypatia raises
# `invalid_actions_lock` from BOTH `workflow_audit` and `workflow_hardening`
# for a single desynced lockfile. Under the old exact-string equality an
# acknowledgement could only name one of them, so the other stayed
# unsuppressed and went on blocking `main` — while the entry looked correct
# in every visible respect: right file, right severity, right type.
# ═══════════════════════════════════════════════════════════════════════

# The real-world reproduction. Two findings, one defect, ONE entry.
cat > "$WORK/findings-2mod.json" <<'EOF'
[{"severity":"high","rule_module":"workflow_audit","type":"invalid_actions_lock","file":".github/workflows/actions.lock"},
 {"severity":"high","rule_module":"workflow_hardening","type":"invalid_actions_lock","file":".github/workflows/actions.lock"}]
EOF
cat > "$WORK/baseline-2mod.json" <<'EOF'
[{"severity":"high","rule_module":["workflow_audit","workflow_hardening"],"type":"invalid_actions_lock","file_pattern":"**actions.lock"}]
EOF
assert_status "one list entry suppresses BOTH emitting modules" \
  "$WORK/findings-2mod.json" "$WORK/baseline-2mod.json" "2,0"

# Each member individually. A list that only ever matched its first element
# would pass the case above by luck if the findings were ordered kindly.
cat > "$WORK/findings-mod2only.json" <<'EOF'
[{"severity":"high","rule_module":"workflow_hardening","type":"invalid_actions_lock","file":".github/workflows/actions.lock"}]
EOF
assert_status "list matches a NON-FIRST member" \
  "$WORK/findings-mod2only.json" "$WORK/baseline-2mod.json" "1,0"

# The over-match control. A list must not become a wildcard.
cat > "$WORK/findings-3rd.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"invalid_actions_lock","file":".github/workflows/actions.lock"}]
EOF
assert_status "list does NOT suppress a module it omits" \
  "$WORK/findings-3rd.json" "$WORK/baseline-2mod.json" "0,1"

# A one-element list must behave exactly like the bare string.
cat > "$WORK/baseline-1list.json" <<'EOF'
[{"severity":"high","rule_module":["workflow_audit"],"type":"invalid_actions_lock","file_pattern":"**actions.lock"}]
EOF
assert_status "single-element list == the string form (matches)" \
  "$WORK/findings-mod2only.json" "$WORK/baseline-1list.json" "0,1"
cat > "$WORK/findings-mod1only.json" <<'EOF'
[{"severity":"high","rule_module":"workflow_audit","type":"invalid_actions_lock","file":".github/workflows/actions.lock"}]
EOF
assert_status "single-element list == the string form (rejects)" \
  "$WORK/findings-mod1only.json" "$WORK/baseline-1list.json" "1,0"

# The string form must be untouched. This is the compatibility control for
# all 212 existing entries, every one of which uses a bare string.
cat > "$WORK/baseline-str.json" <<'EOF'
[{"severity":"high","rule_module":"workflow_audit","type":"invalid_actions_lock","file_pattern":"**actions.lock"}]
EOF
assert_status "bare string form still matches" \
  "$WORK/findings-mod1only.json" "$WORK/baseline-str.json" "1,0"
assert_status "bare string form still rejects the other module" \
  "$WORK/findings-mod2only.json" "$WORK/baseline-str.json" "0,1"

# ── MUTANT ────────────────────────────────────────────────────────────
# Restore the exact-equality comparison and assert the two-module case
# REGRESSES to half-suppressed. Without this, every assertion above would
# pass identically against an implementation that ignored the list entirely
# and matched on severity+type+file alone.
MUTANT="$WORK/apply-baseline-mutant.sh"
# Mutate the membership test to "first element only". This is the most
# plausible wrong implementation of a list match, and it is invisible to any
# assertion that happens to put the matching module first.
sed 's/| any(\. == \$finding\.rule_module)/| .[0] == $finding.rule_module/' \
  "$APPLY" > "$MUTANT"
chmod +x "$MUTANT"

if ! grep -q '\.\[0\] == \$finding\.rule_module' "$MUTANT"; then
  echo "FAIL: MUTANT was not applied — the sed anchor no longer matches apply-baseline.sh"
  fail=$((fail + 1))
elif ! bash -n "$MUTANT" 2>/dev/null; then
  echo "FAIL: MUTANT is not valid bash; the regression control did not execute"
  fail=$((fail + 1))
else
  # Non-first member must now be MISSED.
  mutant_got=$(bash "$MUTANT" "$WORK/findings-mod2only.json" "$WORK/baseline-2mod.json" advisory \
    | jq -r "$COUNTS_JQ")
  if [ "$mutant_got" = "0,1" ]; then
    echo "PASS: MUTANT (first element only) misses the non-first module — any() IS load-bearing"
    pass=$((pass + 1))
  else
    echo "FAIL: MUTANT expected 0,1 got $mutant_got — the list assertions do not depend on any()"
    fail=$((fail + 1))
  fi
  # And the two-module case must regress to half-suppressed: exactly the
  # #966 symptom, reproduced on demand.
  mutant_both=$(bash "$MUTANT" "$WORK/findings-2mod.json" "$WORK/baseline-2mod.json" advisory \
    | jq -r "$COUNTS_JQ")
  if [ "$mutant_both" = "1,1" ]; then
    echo "PASS: MUTANT reproduces the #966 symptom (half-suppressed, entry looks correct)"
    pass=$((pass + 1))
  else
    echo "FAIL: MUTANT expected 1,1 got $mutant_both"
    fail=$((fail + 1))
  fi
fi

# A list member that is not a valid module name must be REJECTED, not
# silently ignored. The validator is a gate, so it needs its own negative.
cat > "$WORK/baseline-badmember.json" <<'EOF'
[{"severity":"high","rule_module":["workflow_audit","Workflow-Hardening"],"type":"invalid_actions_lock","file_pattern":"**actions.lock"}]
EOF
if bash "$APPLY" "$WORK/findings-mod1only.json" "$WORK/baseline-badmember.json" advisory >/dev/null 2>&1; then
  echo "FAIL: a malformed rule_module list member was accepted"
  fail=$((fail + 1))
else
  echo "PASS: malformed rule_module list member rejected"
  pass=$((pass + 1))
fi

# An empty list names no module, so it can match nothing. Accepting it would
# create an entry that silently never applies.
cat > "$WORK/baseline-emptylist.json" <<'EOF'
[{"severity":"high","rule_module":[],"type":"invalid_actions_lock","file_pattern":"**actions.lock"}]
EOF
if bash "$APPLY" "$WORK/findings-mod1only.json" "$WORK/baseline-emptylist.json" advisory >/dev/null 2>&1; then
  echo "FAIL: an empty rule_module list was accepted"
  fail=$((fail + 1))
else
  echo "PASS: empty rule_module list rejected"
  pass=$((pass + 1))
fi

# --- The SHIPPED ledger, not a fixture -------------------------------------
# #963: the shipped ledger used to carry ONE invalid_actions_lock ack naming
# both workflow_audit and workflow_hardening (`**actions.lock`), for
# asana/push-signed-commits' floating transitive actions/setup-python@v2.
# #1233 replaced the action and #1238 dropped both records from actions.lock,
# so the ack was removed. While it stood, `**actions.lock` muted ANY new
# invalid_actions_lock until 2026-12-22. These assertions run against the real
# .hypatia-baseline.json so that restoring the ack reds this suite instead of
# quietly muting the next lock defect.
SHIPPED="$SCRIPT_DIR/../../.hypatia-baseline.json"
if [ ! -f "$SHIPPED" ]; then
  echo "FAIL: shipped baseline not found at $SHIPPED"
  fail=$((fail + 1))
else
  got=$(jq -r '[.[] | select(.type == "invalid_actions_lock")] | length' "$SHIPPED")
  if [[ "$got" == "0" ]]; then
    echo "PASS: shipped ledger holds NO invalid_actions_lock ack"
    pass=$((pass + 1))
  else
    echo "FAIL: shipped invalid_actions_lock acks: expected 0, got $got"
    fail=$((fail + 1))
  fi

  # Both emission paths, with their DIFFERENT file values — `actions.lock`
  # from workflow_audit and the full path from WH004 — must reach the gate.
  cat > "$WORK/findings-shipped-pair.json" <<'EOF'
[{"severity":"high","rule_module":"workflow_audit","type":"invalid_actions_lock","file":"actions.lock"},
 {"severity":"high","rule_module":"workflow_hardening","type":"invalid_actions_lock","file":".github/workflows/actions.lock"}]
EOF
  assert_status "shipped ledger KEEPS both emission paths" \
    "$WORK/findings-shipped-pair.json" "$SHIPPED" "0,2"

  # Nothing else hypatia says about actions.lock is muted either.
  cat > "$WORK/findings-shipped-other.json" <<'EOF'
[{"severity":"high","rule_module":"workflow_audit","type":"shell_download","file":"actions.lock"},
 {"severity":"high","rule_module":"workflow_lint","type":"invalid_actions_lock","file":"actions.lock"}]
EOF
  assert_status "shipped ledger does NOT suppress other types or modules" \
    "$WORK/findings-shipped-other.json" "$SHIPPED" "0,2"
fi

# ═══════════════════════════════════════════════════════════════════════
# The advisory class never gates (owner ruling 2026-11-17, hypatia#1204)
#
# Hypatia marks a flag-only finding `advisory: true` (WF026, WF027, RE011)
# and never counts it toward its own exit code. This gate used to reject it
# all the same: in `blocking` mode at threshold `info`, 133 unbaselined
# `research_extensions/RE011` findings failed "Baseline validation" on this
# repository. The class now decides, not the severity: an advisory finding
# at medium or below is reported in `findings_kept` and is never counted.
# The class cannot waive a high or a critical, and only the JSON boolean
# `true` is the class.
# ═══════════════════════════════════════════════════════════════════════

# assert_class_gate <label> <findings> <baseline> <threshold> <want-rc> [<stderr needle>]
# Runs the gate in blocking mode; leaves stdout in gate.out, stderr in gate.err.
assert_class_gate() {
  local label="$1" findings="$2" baseline="$3" threshold="$4" want="$5" needle="${6:-}" status=0
  BLOCKING_THRESHOLD="$threshold" bash "$APPLY" "$findings" "$baseline" blocking \
    > "$WORK/gate.out" 2> "$WORK/gate.err" || status=$?
  if [[ "$status" -ne "$want" ]]; then
    echo "FAIL: $label  expected exit $want, got $status"
    sed 's/^/      | /' "$WORK/gate.err" | cut -c1-240 | head -5
    fail=$((fail + 1)); return 0
  fi
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" "$WORK/gate.err"; then
    echo "FAIL: $label  exit $status as expected, but stderr lacks: $needle"
    fail=$((fail + 1)); return 0
  fi
  echo "PASS: $label  (exit $status)"
  pass=$((pass + 1))
}

RE011='"rule_module":"research_extensions","type":"RE011","line":3'
printf '[{"severity":"medium","advisory":true,%s,"file":"scripts/a.sh"}]\n' "$RE011" > "$WORK/adv-medium.json"
printf '[{"severity":"medium",%s,"file":"scripts/a.sh"}]\n' "$RE011" > "$WORK/plain-medium.json"
printf '[{"severity":"medium","advisory":"true",%s,"file":"scripts/a.sh"}]\n' "$RE011" > "$WORK/adv-string.json"
printf '[{"severity":"medium","advisory":false,%s,"file":"scripts/a.sh"}]\n' "$RE011" > "$WORK/adv-false.json"
printf '[{"severity":"high","advisory":true,%s,"file":"scripts/a.sh"}]\n' "$RE011" > "$WORK/adv-high.json"
printf '[{"severity":"critical","advisory":true,%s,"file":"scripts/a.sh"}]\n' "$RE011" > "$WORK/adv-critical.json"
printf '[{"severity":"bogus","advisory":true,%s,"file":"scripts/a.sh"}]\n' "$RE011" > "$WORK/adv-unknown.json"
printf '[{"severity":"warn","advisory":true,%s,"file":"scripts/a.sh"},{"severity":"low","advisory":true,%s,"file":"scripts/b.sh"},{"severity":"info","advisory":true,%s,"file":"scripts/c.sh"}]\n' \
  "$RE011" "$RE011" "$RE011" > "$WORK/adv-lower.json"
printf '[{"severity":"medium","advisory":true,%s,"file":"scripts/advisory-one.sh"},{"severity":"low","rule_module":"code_safety","type":"todo_marker","line":9,"file":"scripts/plain-one.sh"}]\n' \
  "$RE011" > "$WORK/adv-mixed.json"

assert_class_gate "an advisory medium finding does not fail the gate at info" \
  "$WORK/adv-medium.json" "$WORK/empty.json" info 0
got=$(jq -r "$COUNTS_JQ" "$WORK/gate.out")
if [ "$got" = "0,1" ]; then
  echo "PASS: the advisory finding is still reported in findings_kept"; pass=$((pass + 1))
else
  echo "FAIL: the advisory finding left findings_kept (suppressed,kept=$got)"; fail=$((fail + 1))
fi
assert_class_gate "CONTROL: the same finding without the class fails the gate" \
  "$WORK/plain-medium.json" "$WORK/empty.json" info 1 "Gate failed: 1 unfiltered"
assert_class_gate "the string \"true\" is not the class" \
  "$WORK/adv-string.json" "$WORK/empty.json" info 1
assert_class_gate "advisory: false is not the class" \
  "$WORK/adv-false.json" "$WORK/empty.json" info 1
assert_class_gate "the class cannot waive a high" \
  "$WORK/adv-high.json" "$WORK/empty.json" info 1 "Gate failed: 1 unfiltered"
assert_class_gate "the class cannot waive a critical" \
  "$WORK/adv-critical.json" "$WORK/empty.json" critical 1
assert_class_gate "the class cannot waive an unknown severity (ranked critical)" \
  "$WORK/adv-unknown.json" "$WORK/empty.json" critical 1
assert_class_gate "advisory warn, low and info do not fail the gate" \
  "$WORK/adv-lower.json" "$WORK/empty.json" info 0
assert_class_gate "one advisory and one plain finding: the plain one fails the gate" \
  "$WORK/adv-mixed.json" "$WORK/empty.json" info 1 "Gate failed: 1 unfiltered"
if grep -qF "scripts/plain-one.sh" "$WORK/gate.err" && ! grep -qF "scripts/advisory-one.sh" "$WORK/gate.err"; then
  echo "PASS: only the plain finding is named in the annotations"; pass=$((pass + 1))
else
  echo "FAIL: the annotations do not name exactly the plain finding"; cat "$WORK/gate.err"; fail=$((fail + 1))
fi
if grep -qF "1 advisory" "$WORK/gate.err"; then
  echo "PASS: the gate message counts the advisory finding apart"; pass=$((pass + 1))
else
  echo "FAIL: the gate message does not say how many findings were advisory"; fail=$((fail + 1))
fi

# The baseline still acknowledges an advisory finding like any other.
printf '[{"severity":"medium",%s,"file":"scripts/a.sh"}]\n' '"rule_module":"research_extensions","type":"RE011"' > "$WORK/baseline-re011.json"
assert_status "an advisory finding is acknowledged by a matching entry" \
  "$WORK/adv-medium.json" "$WORK/baseline-re011.json" "1,0"

# The step summary says how many findings were advisory.
: > "$WORK/summary.md"
GITHUB_STEP_SUMMARY="$WORK/summary.md" BLOCKING_THRESHOLD=info \
  bash "$APPLY" "$WORK/adv-mixed.json" "$WORK/empty.json" advisory > /dev/null
if grep -qE '^\| Advisory class \(reported, never gating\) \| 1 \|$' "$WORK/summary.md"; then
  echo "PASS: the step summary counts the advisory class"; pass=$((pass + 1))
else
  echo "FAIL: the step summary has no advisory row"; cat "$WORK/summary.md"; fail=$((fail + 1))
fi

# MUTANT: the gate with the exemption removed must fail the first case above,
# or these assertions do not depend on it.
ADV_MUTANT="$WORK/apply-baseline-advisory-mutant.sh"
sed 's/\.advisory == true and/false and/' "$APPLY" > "$ADV_MUTANT"
if cmp -s "$ADV_MUTANT" "$APPLY" || ! bash -n "$ADV_MUTANT"; then
  echo "FAIL: the advisory mutant is identical or invalid — it proves nothing"; fail=$((fail + 1))
else
  status=0
  BLOCKING_THRESHOLD=info bash "$ADV_MUTANT" "$WORK/adv-medium.json" "$WORK/empty.json" blocking \
    > /dev/null 2>&1 || status=$?
  if [ "$status" -eq 1 ]; then
    echo "PASS: MUTANT killed (without the exemption the advisory finding gates)"; pass=$((pass + 1))
  else
    echo "FAIL: MUTANT survived (exit $status)"; fail=$((fail + 1))
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# Findings larger than one argument string
#
# The findings and the baseline used to reach jq as `--argjson` values. One
# argument is capped by the kernel (MAX_ARG_STRLEN, 128 KiB on Linux), so a
# scan of about 350 KB (393 findings on this repository) ended with
# "Argument list too long", exit 126: a red job that names no finding. Both
# now reach jq as files.
# ═══════════════════════════════════════════════════════════════════════
jq -n '[range(800) | {severity: "medium", rule_module: "research_extensions", type: "RE011",
        line: ., file: "scripts/f\(.).sh", reason: ("x" * 400)}]' > "$WORK/big-findings.json"
jq '[.[] | {severity, rule_module, type, file, note: ("n" * 400)}]' "$WORK/big-findings.json" > "$WORK/big-baseline.json"
for f in big-findings.json big-baseline.json; do
  if [ "$(wc -c < "$WORK/$f")" -gt 300000 ]; then
    echo "PASS: $f is larger than one argument string ($(wc -c < "$WORK/$f") bytes)"; pass=$((pass + 1))
  else
    echo "FAIL: $f is too small to prove anything"; fail=$((fail + 1))
  fi
done
assert_class_gate "800 unbaselined findings fail the gate, not the shell" \
  "$WORK/big-findings.json" "$WORK/empty.json" info 1 "Gate failed: 800 unfiltered"
assert_class_gate "800 findings against 800 entries pass" \
  "$WORK/big-findings.json" "$WORK/big-baseline.json" info 0
got=$(jq -r "$COUNTS_JQ" "$WORK/gate.out")
if [ "$got" = "800,0" ]; then
  echo "PASS: every one of the 800 is acknowledged"; pass=$((pass + 1))
else
  echo "FAIL: expected 800,0 got $got"; fail=$((fail + 1))
fi

# ── Review of #1668: two ways the change above could fail open ──────────
# An empty severity is an unknown severity (rank critical), not "no finding".
printf '[{"severity":"","rule_module":"code_safety","type":"x","file":"a.sh"}]\n' > "$WORK/sev-empty.json"
printf '[{"severity":"","advisory":true,"rule_module":"code_safety","type":"x","file":"a.sh"}]\n' > "$WORK/sev-empty-adv.json"
assert_class_gate "an empty severity gates as unknown, even at critical" \
  "$WORK/sev-empty.json" "$WORK/empty.json" critical 1 "Gate failed: 1 unfiltered"
assert_class_gate "the class does not waive an empty severity" \
  "$WORK/sev-empty-adv.json" "$WORK/empty.json" critical 1
assert_class_gate "no findings at all pass" \
  "$WORK/empty.json" "$WORK/empty.json" info 0
# One findings document, one baseline document. `--slurpfile` reads every
# document in a file; taking the first would drop a finding in the second.
printf '[]\n[{"severity":"critical","rule_module":"code_safety","type":"x","file":"a.sh"}]\n' > "$WORK/two-docs.json"
assert_class_gate "a second findings document is invalid input, not ignored" \
  "$WORK/two-docs.json" "$WORK/empty.json" info 2
printf '[]\n[]\n' > "$WORK/two-baselines.json"
assert_class_gate "a second baseline document is invalid input" \
  "$WORK/plain-medium.json" "$WORK/two-baselines.json" info 2

assert_invalid_option "invalid mode" bypass high
assert_invalid_option "invalid threshold" blocking nonsense

echo
echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
