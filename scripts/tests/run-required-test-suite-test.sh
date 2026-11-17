#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Behavioral regression test for the fail-loud aggregate test-suite helper.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/scripts/run-required-test-suite.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() {
  echo "PASS: $1"
  pass=$((pass + 1))
}

bad() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

assert_case() { # label expected_status required_text command...
  local label="$1" expected_status="$2" required_text="$3"
  shift 3
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq "$expected_status" ] && grep -Fq "$required_text" <<<"$output" && ! grep -Fq 'SKIP' <<<"$output"; then
    ok "$label"
  else
    bad "$label (wanted exit $expected_status and '$required_text'; got exit $status: $output)"
  fi
}

mkdir -p "$TMP/suite" "$TMP/bin"
cat > "$TMP/bin/passing-tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/failing-tool" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
chmod +x "$TMP/bin/passing-tool" "$TMP/bin/failing-tool"

assert_case "available passing suite succeeds" 0 "PASS: passing suite" \
  env "PATH=$TMP/bin:$PATH" "$RUNNER" "passing suite" "$TMP/suite" passing-tool --test
assert_case "missing tool fails loudly" 127 "UNAVAILABLE: missing tool suite" \
  env "PATH=$TMP/bin:$PATH" "$RUNNER" "missing tool suite" "$TMP/suite" absent-tool --test
assert_case "failing test preserves its exit status" 23 "FAILED (exit 23): failing suite" \
  env "PATH=$TMP/bin:$PATH" "$RUNNER" "failing suite" "$TMP/suite" failing-tool --test
assert_case "missing target fails before tool invocation" 66 "MISSING TARGET: missing target suite" \
  env "PATH=$TMP/bin:$PATH" "$RUNNER" "missing target suite" "$TMP/absent" passing-tool --test

test_recipe="$(sed -n '/^test:/,/^# Regression test/p' "$ROOT/Justfile")"
if grep -Eq '\|\|[[:space:]]*echo.*SKIP|not available or tests failed' <<<"$test_recipe"; then
  bad "Justfile does not reintroduce a false-soft test aggregate"
else
  ok "Justfile does not reintroduce a false-soft test aggregate"
fi

echo "run-required-test-suite regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
