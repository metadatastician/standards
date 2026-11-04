#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Tests for filter-sarif-by-baseline.sh.
#
# ⚠ THE FAIL-OPEN TESTS ARE THE IMPORTANT ONES. This script decides which
# security alerts reach the security tab. Every failure mode must upload the
# SARIF UNFILTERED — suppressing more than the baseline says, or silently
# emitting an empty SARIF, would hide real findings. "Filtered nothing" is a
# safe failure; "filtered everything" is not.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../filter-sarif-by-baseline.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0

ck() { # name expected_count actual_count
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s (expected %s results, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

mk_sarif() {
  cat > "$T/in.sarif" <<'EOF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Hypatia"}},"results":[
 {"ruleId":"hypatia/code_safety/unwrap_without_check","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/a.rs"}}}]},
 {"ruleId":"hypatia/code_safety/unwrap_without_check","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/b.rs"}}}]},
 {"ruleId":"hypatia/cicd_rules/banned_language_file","locations":[{"physicalLocation":{"artifactLocation":{"uri":"tools/x.py"}}}]}
]}]}
EOF
}
mk_findings() {
  cat > "$T/f.json" <<'EOF'
[{"severity":"low","rule_module":"code_safety","type":"unwrap_without_check","file":"src/a.rs"},
 {"severity":"low","rule_module":"code_safety","type":"unwrap_without_check","file":"src/b.rs"},
 {"severity":"critical","rule_module":"cicd_rules","type":"banned_language_file","file":"tools/x.py"}]
EOF
}
count() { jq '[.runs[]?.results[]?]|length' "$1"; }

# ── 1. a baselined finding is removed ───────────────────────────────────
mk_sarif; mk_findings
echo '[{"severity":"low","rule_module":"code_safety","type":"unwrap_without_check","file":"src/a.rs"}]' > "$T/b.json"
bash "$S" "$T/in.sarif" "$T/f.json" "$T/b.json" "$T/out.sarif" >/dev/null 2>&1
ck "a baselined finding is removed from the SARIF" 2 "$(count "$T/out.sarif")"

# ── 2. an UNbaselined finding survives ──────────────────────────────────
ck "unbaselined findings survive" 1 \
   "$(jq '[.runs[].results[]|select(.ruleId=="hypatia/cicd_rules/banned_language_file")]|length' "$T/out.sarif")"

# ── 3. file_pattern matching works ──────────────────────────────────────
mk_sarif; mk_findings
echo '[{"severity":"low","rule_module":"code_safety","type":"unwrap_without_check","file_pattern":"src/*.rs"}]' > "$T/b.json"
bash "$S" "$T/in.sarif" "$T/f.json" "$T/b.json" "$T/out.sarif" >/dev/null 2>&1
ck "file_pattern removes both matching results" 1 "$(count "$T/out.sarif")"

# ── 4. severity is part of the key (baseline says low, finding is critical) ──
mk_sarif; mk_findings
echo '[{"severity":"low","rule_module":"cicd_rules","type":"banned_language_file","file":"tools/x.py"}]' > "$T/b.json"
bash "$S" "$T/in.sarif" "$T/f.json" "$T/b.json" "$T/out.sarif" >/dev/null 2>&1
ck "a severity mismatch does NOT suppress" 3 "$(count "$T/out.sarif")"

# ── 5-7. every failure mode must FAIL OPEN ──────────────────────────────
mk_sarif; mk_findings
bash "$S" "$T/in.sarif" "$T/f.json" "$T/does-not-exist.json" "$T/out.sarif" >/dev/null 2>&1
ck "missing baseline leaves the SARIF untouched" 3 "$(count "$T/out.sarif")"

mk_sarif; mk_findings
echo 'this is not json' > "$T/bad.json"
bash "$S" "$T/in.sarif" "$T/f.json" "$T/bad.json" "$T/out.sarif" >/dev/null 2>&1
ck "an INVALID baseline leaves the SARIF untouched" 3 "$(count "$T/out.sarif")"

mk_sarif
echo '[]' > "$T/empty.json"
echo '[{"severity":"low","rule_module":"code_safety","type":"unwrap_without_check","file":"src/a.rs"}]' > "$T/b.json"
bash "$S" "$T/in.sarif" "$T/empty.json" "$T/b.json" "$T/out.sarif" >/dev/null 2>&1
ck "no findings to match leaves the SARIF untouched" 3 "$(count "$T/out.sarif")"

# ── 8. paths differing only by a ./ prefix still match ──────────────────
mk_sarif
cat > "$T/f.json" <<'EOF'
[{"severity":"low","rule_module":"code_safety","type":"unwrap_without_check","file":"./src/a.rs"}]
EOF
echo '[{"severity":"low","rule_module":"code_safety","type":"unwrap_without_check","file":"./src/a.rs"}]' > "$T/b.json"
bash "$S" "$T/in.sarif" "$T/f.json" "$T/b.json" "$T/out.sarif" >/dev/null 2>&1
ck "a leading ./ does not defeat path matching" 2 "$(count "$T/out.sarif")"

# ── 9. a SARIF with no results is handled ───────────────────────────────
echo '{"version":"2.1.0","runs":[]}' > "$T/in.sarif"
mk_findings
echo '[{"severity":"low","rule_module":"code_safety","type":"unwrap_without_check","file":"src/a.rs"}]' > "$T/b.json"
bash "$S" "$T/in.sarif" "$T/f.json" "$T/b.json" "$T/out.sarif" >/dev/null 2>&1
ck "an empty SARIF survives filtering" 0 "$(count "$T/out.sarif")"

# Two severities of the same rule and file: suppress only the one actually
# acknowledged. In legacy SARIF without severity provenance, retain both.
cat > "$T/collision-findings.json" <<'EOF'
[{"severity":"critical","rule_module":"code_safety","type":"unsafe_block","file":"src/a.rs"},
 {"severity":"high","rule_module":"code_safety","type":"unsafe_block","file":"src/a.rs"}]
EOF
cat > "$T/collision-baseline.json" <<'EOF'
[{"severity":"critical","rule_module":"code_safety","type":"unsafe_block","file":"src/a.rs"}]
EOF
cat > "$T/collision.sarif" <<'EOF'
{"version":"2.1.0","runs":[{"results":[
 {"ruleId":"hypatia/code_safety/unsafe_block","properties":{"hypatia.severity":"critical"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/a.rs"}}}]},
 {"ruleId":"hypatia/code_safety/unsafe_block","properties":{"hypatia.severity":"high"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/a.rs"}}}]}
]}]}
EOF
bash "$S" "$T/collision.sarif" "$T/collision-findings.json" "$T/collision-baseline.json" "$T/out.sarif" >/dev/null 2>&1
ck "matching severity is suppressed, unacknowledged severity survives" high \
  "$(jq -r '.runs[0].results[0].properties["hypatia.severity"]' "$T/out.sarif")"
ck "one of two colliding findings survives" 1 "$(count "$T/out.sarif")"
jq 'del(.runs[].results[].properties)' "$T/collision.sarif" > "$T/legacy.sarif"
bash "$S" "$T/legacy.sarif" "$T/collision-findings.json" "$T/collision-baseline.json" "$T/out.sarif" >/dev/null 2>&1
ck "ambiguous legacy SARIF is left unfiltered" 2 "$(count "$T/out.sarif")"
# Extra results that are not accounted for by scanner JSON must never be
# suppressed just because one result has the same key.
jq '.runs[0].results += [.runs[0].results[0]]' "$T/collision.sarif" > "$T/extra.sarif"
bash "$S" "$T/extra.sarif" "$T/collision-findings.json" "$T/collision-baseline.json" "$T/out.sarif" >/dev/null 2>&1
ck "unaccounted duplicate results fail open" 3 "$(count "$T/out.sarif")"

# The blocking workflow needs affirmative evidence that filtering completed.
export GITHUB_OUTPUT="$T/filter-output"
: > "$GITHUB_OUTPUT"
mk_sarif; mk_findings
bash "$S" "$T/in.sarif" "$T/f.json" "$T/b.json" "$T/out.sarif" > "$T/filter.log" 2>&1
ck "successful filtering is reported" 'filtered=true' "$(cat "$GITHUB_OUTPUT")"
: > "$GITHUB_OUTPUT"
bash "$S" "$T/in.sarif" "$T/f.json" "$T/bad.json" "$T/out.sarif" > "$T/filter.log" 2>&1
ck "invalid baseline cannot report filtering success" '' "$(cat "$GITHUB_OUTPUT")"
: > "$GITHUB_OUTPUT"
APPLY_BASELINE="$T/missing-validator" bash "$S" "$T/in.sarif" "$T/f.json" "$T/b.json" "$T/out.sarif" > "$T/filter.log" 2>&1
ck "missing validator cannot report filtering success" '' "$(cat "$GITHUB_OUTPUT")"
: > "$GITHUB_OUTPUT"
bash "$S" "$T/in.sarif" "$T/empty.json" "$T/b.json" "$T/out.sarif" > "$T/filter.log" 2>&1
ck "completed zero-match filtering is reported" 'filtered=true' "$(cat "$GITHUB_OUTPUT")"
# A malformed or multiple-document response is not confirmation that zero
# findings were suppressed. Leave SARIF untouched and never arm the gate.
for payload in '{"findings_suppressed":null}' '{"findings_suppressed":[]} {"findings_suppressed":[]}'; do
  cat > "$T/invalid-validator" <<SCRIPT
#!/usr/bin/env bash
cat <<'JSON'
$payload
JSON
SCRIPT
  ck "invalid-response fixture emits its intended JSON" "$payload" "$(bash "$T/invalid-validator")"
  : > "$GITHUB_OUTPUT"
  APPLY_BASELINE="$T/invalid-validator" bash "$S" "$T/in.sarif" "$T/f.json" "$T/b.json" "$T/out.sarif" > "$T/filter.log" 2>&1
  ck "invalid matcher response leaves SARIF untouched" 3 "$(count "$T/out.sarif")"
  ck "invalid matcher response cannot claim success" '' "$(cat "$GITHUB_OUTPUT")"
done
cat > "$T/invalid-validator" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' '{"findings_suppressed":[]}'
exit 1
SCRIPT
matcher_status=0
matcher_response=$(bash "$T/invalid-validator") || matcher_status=$?
ck "failed matcher fixture returns nonzero" 1 "$matcher_status"
ck "failed matcher fixture emits valid JSON" '{"findings_suppressed":[]}' "$matcher_response"
: > "$GITHUB_OUTPUT"
APPLY_BASELINE="$T/invalid-validator" bash "$S" "$T/in.sarif" "$T/f.json" "$T/b.json" "$T/out.sarif" > "$T/filter.log" 2>&1
ck "failed matcher leaves SARIF untouched" 3 "$(count "$T/out.sarif")"
ck "failed matcher cannot claim success" '' "$(cat "$GITHUB_OUTPUT")"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
