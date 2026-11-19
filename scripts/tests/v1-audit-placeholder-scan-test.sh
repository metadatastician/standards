#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# v1-audit-placeholder-scan-test.sh — 3-practice/release-pre-flight/v1-audit.sh
# reports placeholder fuzz/bench artefacts however many there are.
#
# The audit (set -euo pipefail) asked `find … | grep -q .`. With more than a
# pipe buffer of matching paths, grep -q exited at the first, find died of
# SIGPIPE, the pipeline reported 141 and the audit printed "PASS: no
# placeholder fuzz/bench artifact files found". The listing after the blocker
# was `find … | head -n 20`, which under set -e would end the audit at the
# same race. Each case runs the real script on a fixture tree.
#
# Proves: 1500 placeholder files (~150 KB of paths) give the blocker, and the
# audit still reaches its summary, five runs out of five; one placeholder gives
# the blocker (control); none gives the PASS line (control).
# Does not cover: the rest of the audit (its Audit Surfaces section is
# unreachable today: it calls an undefined function, see the report).
# Run: bash scripts/tests/v1-audit-placeholder-scan-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="${AUDIT:-$SCRIPT_DIR/../../3-practice/release-pre-flight/v1-audit.sh}"
command -v rg >/dev/null || { echo "COULD NOT RUN: the audit needs ripgrep (rg)" >&2; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fail=$((fail + 1)); }

# fixture <name> <count> — a tree with <count> */fuzz/placeholder.txt files.
fixture() {
  local d="$WORK/$1" i
  mkdir -p "$d"
  for ((i = 1; i <= $2; i++)); do
    mkdir -p "$d/a-directory-name-long-enough-to-fill-the-pipe-buffer-$i/fuzz"
    : > "$d/a-directory-name-long-enough-to-fill-the-pipe-buffer-$i/fuzz/placeholder.txt"
  done
  printf '%s' "$d"
}
run_audit() { OUT="$(bash "$AUDIT" "$1" 2>&1)"; RC=$?; }
blocked() { grep -qF "BLOCKER: placeholder fuzz or benchmark artifacts present" <<<"$OUT" \
  && ! grep -qF "PASS: no placeholder fuzz/bench artifact files found" <<<"$OUT" \
  && grep -qF "Summary:" <<<"$OUT"; }

d=$(fixture many 1500)
for run in 1 2 3 4 5; do
  run_audit "$d"
  if blocked; then ok "1500 placeholder files give the blocker and the audit reaches its summary (run $run)"
  else ko "1500 placeholder files: wanted the blocker and a summary (run $run, exit $RC)"; fi
done

d=$(fixture one 1); run_audit "$d"
if blocked; then ok "control: one placeholder file gives the blocker"; else ko "one placeholder: wanted the blocker (exit $RC)"; fi

d=$(fixture none 0); run_audit "$d"
if grep -qF "PASS: no placeholder fuzz/bench artifact files found" <<<"$OUT"; then ok "control: no placeholder file passes the scan"
else ko "no placeholder: wanted the PASS line (exit $RC)"; fi

echo
echo "v1-audit-placeholder-scan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
