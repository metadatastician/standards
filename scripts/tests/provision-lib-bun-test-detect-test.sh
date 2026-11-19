#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# provision-lib-bun-test-detect-test.sh — `provision-lib.sh lang-run test` runs
# `bun test` in a Bun repository that has test files and no "test" script,
# however many files the repository tracks.
#
# The lib decided that with `git ls-files | grep -qE '(\.|_)(test|spec)\.js…'`
# under `set -uo pipefail`. A test file early in the listing made grep -q exit
# while git was still writing a list above the 64 KiB pipe buffer; git died of
# SIGPIPE, the pipeline reported 141, and the test step was reported N/A and
# never ran: a green `just test` that tested nothing.
#
# Proves: with ~400 KB of tracked names after the test file, the step is
# `bun test`, five runs out of five; with no test file it is N/A (control);
# with a "test" script it is `bun run test` (control). `bun` is replaced by a
# stub on PATH that logs and exits 0, so no real test runs.
# Run: bash scripts/tests/provision-lib-bun-test-detect-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${LIB:-$SCRIPT_DIR/../../3-practice/provisioning/templates/build/just/provision-lib.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fail=$((fail + 1)); }

mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\necho "stub-bun $*"\n' > "$WORK/bin/bun"; chmod +x "$WORK/bin/bun"

# fixture <name> <package.json body> <tracked file count> [test file]
fixture() {
  local d="$WORK/$1" i
  mkdir -p "$d/zz"; git init -q "$d"
  printf '%s\n' "$2" > "$d/package.json"
  [ -n "${4:-}" ] && : > "$d/$4"
  for ((i = 1; i <= $3; i++)); do
    : > "$d/zz/a-tracked-file-whose-name-is-long-enough-to-fill-the-pipe-buffer-number-$i.txt"
  done
  git -C "$d" add -A
  printf '%s' "$d"
}
run_lib() { OUT="$(PATH="$WORK/bin:$PATH" PROVISION_ROOT="$1" bash "$LIB" lang-run test 2>&1)"; RC=$?; }

d=$(fixture big '{"name":"x"}' 4000 a.test.js)
for run in 1 2 3 4 5; do
  run_lib "$d"
  if grep -qF 'test [bun]: bun test' <<<"$OUT" && grep -qF 'stub-bun test' <<<"$OUT"; then
    ok "a test file among ~400 KB of tracked names runs bun test (run $run)"
  else ko "a test file among ~400 KB of tracked names: bun test did not run (run $run, exit $RC)"; fi
done

d=$(fixture none '{"name":"x"}' 1000)
run_lib "$d"
if grep -qF 'test: N/A' <<<"$OUT" && ! grep -qF 'stub-bun' <<<"$OUT"; then ok "control: no test file is N/A"
else ko "no test file: wanted N/A and no bun call (exit $RC)"; fi

d=$(fixture script '{"scripts":{"test":"true"}}' 1)
run_lib "$d"
if grep -qF 'test [bun]: bun run test' <<<"$OUT"; then ok "control: a \"test\" script runs bun run test"
else ko "\"test\" script: wanted bun run test (exit $RC)"; fi

echo
echo "provision-lib-bun-test-detect: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
