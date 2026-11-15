#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Canonical fail-closed shell test discovery used by CI and `just test`.
#
# SHELL_TEST_SHARD splits the suite across CI jobs without losing a test:
#   all    (default) every test; what `just test` runs.
#   heavy  only the files in HEAVY_TESTS below.
#   light  every test except HEAVY_TESTS.
# `light` and `heavy` together are exactly `all`. A HEAVY_TESTS entry that no
# longer exists fails the run, so a rename cannot silently drop a test out of
# both shards.
#
# HEAVY_TESTS holds the tests that dominate the wall time (mutation suites that
# run one mutant after another). Add a file here only with a measured reason;
# the slowest tests of every run are printed at the end.
set -uo pipefail

HEAVY_TESTS=(
  tests/test_apply_workflow_pins_remote.sh
)

shard="${SHELL_TEST_SHARD:-all}"
case "$shard" in
  all | heavy | light) ;;
  *)
    echo "ERROR: SHELL_TEST_SHARD must be all, heavy or light (got '$shard')." >&2
    exit 2
    ;;
esac

is_heavy() {
  local h
  for h in "${HEAVY_TESTS[@]}"; do
    [ "$h" = "$1" ] && return 0
  done
  return 1
}

mapfile -t ALL_TESTS < <(
  {
    find tests -maxdepth 1 -name '*.sh' -type f
    find scripts/tests -maxdepth 1 -name '*.sh' -type f
  } | sort
)

if [ "${#ALL_TESTS[@]}" -eq 0 ]; then
  echo "ERROR: no tests found under tests/ or scripts/tests/ — discovery is broken." >&2
  exit 1
fi

if [ "$shard" != all ]; then
  for h in "${HEAVY_TESTS[@]}"; do
    found=0
    for t in "${ALL_TESTS[@]}"; do
      [ "$t" = "$h" ] && found=1
    done
    if [ "$found" -eq 0 ]; then
      echo "ERROR: HEAVY_TESTS names $h, which does not exist — fix the list." >&2
      exit 1
    fi
  done
fi

TESTS=()
for t in "${ALL_TESTS[@]}"; do
  case "$shard" in
    all) TESTS+=("$t") ;;
    heavy) is_heavy "$t" && TESTS+=("$t") ;;
    light) is_heavy "$t" || TESTS+=("$t") ;;
  esac
done

if [ "${#TESTS[@]}" -eq 0 ]; then
  echo "ERROR: shard '$shard' selected no tests — discovery is broken." >&2
  exit 1
fi

echo "Discovered ${#TESTS[@]} test file(s)."
[ "$shard" = all ] || echo "Shard '$shard': ${#TESTS[@]} of ${#ALL_TESTS[@]} discovered."
failed=0
timings=()

for test_file in "${TESTS[@]}"; do
  echo "::group::$test_file"
  started=$SECONDS

  if bash "$test_file"; then
    echo "PASS $test_file"
  else
    status=$?
    echo "::error file=$test_file::$test_file failed (exit $status)"
    failed=$((failed + 1))
  fi

  timings+=("$((SECONDS - started)) $test_file")
  echo "::endgroup::"
done

echo
echo "Slowest test files (seconds):"
printf '%s\n' "${timings[@]}" | sort -rn | head -5

echo
if [ "$failed" -gt 0 ]; then
  echo "ERROR: $failed of ${#TESTS[@]} test file(s) failed." >&2
  exit 1
fi

echo "All ${#TESTS[@]} test file(s) passed."
