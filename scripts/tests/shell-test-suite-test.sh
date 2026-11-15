#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves run-shell-test-suite.sh CAN FAIL, and fails for the right reasons.
#
# This runner is the gate that makes every other test count. If it passed on
# zero discovered tests, or swallowed a failing test, every suite behind it
# would be green by construction. Each fixture tree below is built in a scratch
# directory, so this test never re-enters the real suite.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/run-shell-test-suite.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
expect() { # expect <wanted-exit> <label>   (runs the suite with cwd = $WORK/t)
  local want="$1" label="$2" got=0
  (cd "$WORK/t" && SHELL_TEST_SHARD=all bash "$SCRIPT") >"$WORK/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $label"
  else fail=$((fail+1)); echo "  FAIL  $label (wanted exit $want, got $got)"; sed 's/^/        /' "$WORK/out"; fi
}
said() { # said <label> <fixed-string>   (asserts on the last run's output)
  if grep -qF -- "$2" "$WORK/out"; then pass=$((pass+1)); echo "  ok    $1"
  else fail=$((fail+1)); echo "  FAIL  $1 (output lacks: $2)"; fi
}
fresh() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; }
t_pass() { mkdir -p "$(dirname "$WORK/t/$1")"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/t/$1"; }
t_fail() { mkdir -p "$(dirname "$WORK/t/$1")"; printf '#!/usr/bin/env bash\nexit 3\n' > "$WORK/t/$1"; }

fresh
expect 1 "no test directories at all fails closed"
said "the zero-discovery failure says discovery is broken" "discovery is broken"

fresh; mkdir -p "$WORK/t/tests" "$WORK/t/scripts/tests"
expect 1 "empty test directories fail closed"

fresh; t_pass tests/a.sh
expect 0 "one passing test under tests/ passes"

fresh; t_pass scripts/tests/a.sh
expect 0 "one passing test under scripts/tests/ passes"

fresh; t_pass tests/a.sh; t_pass scripts/tests/b.sh
expect 0 "passing tests in both directories pass"
said "both directories are discovered" "Discovered 2 test file(s)."

fresh; t_pass tests/a.sh; t_fail scripts/tests/b.sh; t_pass scripts/tests/c.sh
expect 1 "one failing test among passing ones fails the run"
said "the failing test is named with its exit status" "scripts/tests/b.sh failed (exit 3)"
said "the failure count is reported" "1 of 3 test file(s) failed."

fresh; t_fail tests/a.sh; t_fail scripts/tests/b.sh
expect 1 "every test failing fails the run"
said "both failures are counted" "2 of 2 test file(s) failed."

fresh; t_pass tests/a.sh; printf 'exit 0\n' > "$WORK/t/tests/notes.txt"
expect 0 "non-.sh files are not run as tests"
said "only the .sh file is discovered" "Discovered 1 test file(s)."

# Sharding: light + heavy must equal all, and a stale heavy entry must fail.
shard_expect() { # shard_expect <shard> <wanted-exit> <label>
  local got=0
  (cd "$WORK/t" && SHELL_TEST_SHARD="$1" bash "$SCRIPT") >"$WORK/out" 2>&1 || got=$?
  if [ "$got" = "$2" ]; then pass=$((pass+1)); echo "  ok    $3"
  else fail=$((fail+1)); echo "  FAIL  $3 (wanted exit $2, got $got)"; sed 's/^/        /' "$WORK/out"; fi
}

fresh; t_pass tests/a.sh; t_pass tests/test_apply_workflow_pins_remote.sh
shard_expect light 0 "light shard runs the tests outside HEAVY_TESTS"
said "light shard leaves the heavy test out" "Shard 'light': 1 of 2"
if grep -qF "test_apply_workflow_pins_remote" "$WORK/out"; then fail=$((fail+1)); echo "  FAIL  light shard ran a heavy test"; else pass=$((pass+1)); echo "  ok    light shard ran no heavy test"; fi
shard_expect heavy 0 "heavy shard runs the heavy test"
said "heavy shard selects only the heavy test" "Shard 'heavy': 1 of 2"

fresh; t_pass tests/a.sh
shard_expect heavy 1 "a heavy entry that does not exist fails closed"
said "the stale entry is named" "does not exist"

fresh; t_pass tests/a.sh
shard_expect bogus 2 "an unknown shard is refused"

fresh; t_fail tests/test_apply_workflow_pins_remote.sh; t_pass tests/a.sh
shard_expect light 0 "a failing heavy test does not fail the light shard"
shard_expect heavy 1 "a failing heavy test fails the heavy shard"

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
