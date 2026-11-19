#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -uo pipefail
#
# Wave-8 "tighten the gates" regression test.
#
# Every promoted gate must demonstrably BLOCK on bad input and PASS on good:
#   * apply-baseline.sh blocking mode: unbaselined high/critical finding fails;
#     baselined finding passes; EXPIRED baseline entry no longer suppresses.
#   * Mustfile PR gate: the exact commands k9-contractile.yml runs succeed on
#     this repo, and a broken Mustfile fails them (via the wave-1 runner).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AB="$ROOT/scripts/apply-baseline.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }
expect() { if [ "$2" -eq "$1" ]; then ok "$3 (exit $2)"; else bad "$3 (wanted $1, got $2)"; fi; }

echo "== apply-baseline.sh blocking gate =="
cat > "$TMP/findings.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"test_finding","file":"a/b.sh"}]
EOF

# (1) unbaselined high finding in blocking mode -> exit 1
printf '[]' > "$TMP/empty-baseline.json"
bash "$AB" "$TMP/findings.json" "$TMP/empty-baseline.json" blocking >/dev/null 2>&1
expect 1 $? "unbaselined high finding BLOCKS"

# (2) same finding, advisory mode -> exit 0 (reported, not gating)
bash "$AB" "$TMP/findings.json" "$TMP/empty-baseline.json" advisory >/dev/null 2>&1
expect 0 $? "advisory mode does not gate"

# (3) baselined finding (unexpired) -> suppressed, blocking passes
cat > "$TMP/baseline.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"test_finding","file":"a/b.sh","expires_at":"9999-12-31","note":"acknowledged for test"}]
EOF
bash "$AB" "$TMP/findings.json" "$TMP/baseline.json" blocking >/dev/null 2>&1
expect 0 $? "baselined finding passes blocking gate"

# (4) EXPIRED baseline entry no longer suppresses -> blocks again
cat > "$TMP/expired.json" <<'EOF'
[{"severity":"high","rule_module":"cicd_rules","type":"test_finding","file":"a/b.sh","expires_at":"2000-01-01","note":"expired"}]
EOF
bash "$AB" "$TMP/findings.json" "$TMP/expired.json" blocking >/dev/null 2>&1
expect 1 $? "expired baseline entry stops suppressing (blocks)"

# (5) low-severity unbaselined finding stays below the blocking threshold
cat > "$TMP/low.json" <<'EOF'
[{"severity":"low","rule_module":"cicd_rules","type":"test_finding","file":"a/b.sh"}]
EOF
bash "$AB" "$TMP/low.json" "$TMP/empty-baseline.json" blocking >/dev/null 2>&1
expect 0 $? "low-severity finding stays below blocking threshold"

echo "== Mustfile PR gate (exact k9-contractile.yml commands) =="
( cd "$ROOT" && bash scripts/check-mustfile-structure.sh >/dev/null 2>&1 )
expect 0 $? "structural check passes on this repo"
( cd "$ROOT" && bash scripts/run-mustfile.sh >/dev/null 2>&1 )
expect 0 $? "invariant execution passes on this repo"
# and it CAN fail: a Mustfile with a failing critical invariant blocks
printf '### x\n- run: test -f /nonexistent-wave8\n- severity: critical\n' > "$TMP/bad-must.a2ml"
( cd "$ROOT" && bash scripts/run-mustfile.sh "$TMP/bad-must.a2ml" >/dev/null 2>&1 )
expect 1 $? "failing critical invariant blocks"

echo "== affinescript-verify workflow shape =="
WF="$ROOT/.github/workflows/affinescript-verify.yml"
# job-level continue-on-error removed (the job can now fail)
if grep -q 'continue-on-error: true' <<<"$(awk '/^  verify:/,/^    steps:/' "$WF")"; then
  bad "job-level continue-on-error still present"
else
  ok "job-level continue-on-error removed"
fi
# added-file failures exit 1 (blocking branch exists)
grep -q 'exit 1' "$WF" && grep -q 'ADDED file — blocking' "$WF" \
  && ok "added-file blocking branch present" || bad "added-file blocking branch missing"
# toolchain-unavailable skip is loud (never silent green)
grep -q 'SKIPPED, not passed' "$WF" && ok "toolchain skip is loud" || bad "toolchain skip not loud"

echo
echo "Wave-8 gates regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
