#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# self-test-rollup-test.sh — fixtures for scripts/self-test-rollup.sh.
# Run: bash scripts/tests/self-test-rollup-test.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
script="$root/scripts/self-test-rollup.sh"
A=$(printf 'a%.0s' $(seq 40)); B=$(printf 'b%.0s' $(seq 40))
fail=0

# case NAME EXPECT(0|1) L H EVENT RUN_SHA PR_HEAD_CMD
run() {
  local name=$1 want=$2 l=$3 h=$4 ev=$5 sha=$6 cmd=$7 rc
  LIGHT=$l HEAVY=$h EVENT_NAME=$ev PR_NUMBER=7 RUN_HEAD_SHA=$sha REPO=o/r PR_HEAD_CMD=$cmd \
    bash "$script" >/dev/null 2>&1
  rc=$?
  if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" = 1 ] && [ $rc -ne 0 ]; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $rc, wanted $want)"; fail=1
  fi
}

run "both success"                      0 success success pull_request "$A" "echo $A"
run "both success, no lookup needed"    0 success success push "" ""
run "failure stays failure"             1 failure success pull_request "$A" "echo $B"
run "failure beats cancelled+superseded" 1 failure cancelled pull_request "$A" "echo $B"
run "skipped is not success"            1 skipped success pull_request "$A" "echo $B"
run "cancelled, superseded -> neutral"  0 cancelled success pull_request "$A" "echo $B"
run "both cancelled, superseded"        0 cancelled cancelled pull_request "$A" "echo $B"
run "cancelled on current head fails"   1 cancelled success pull_request "$A" "echo $A"
run "cancelled on push fails"           1 cancelled success push "$A" "echo $B"
run "cancelled, lookup fails"           1 cancelled success pull_request "$A" "false"
run "cancelled, lookup garbage"         1 cancelled success pull_request "$A" "echo oops"
run "cancelled, lookup empty"           1 cancelled success pull_request "$A" "true"
run "cancelled, run sha unknown"        1 cancelled success pull_request "" "echo $B"
exit $fail
