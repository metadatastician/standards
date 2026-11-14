#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# test_k9_coordination_step.sh — the "Validate coordination.k9 files" step of
# k9-conformance.yml, run as the runner runs it (`bash -e -o pipefail`) with a
# fake `bun`. Exit status 1 is both the validator's finding status and what Bun
# uses for a crash, so a `fail` record needs the validator's own `FAIL <file>:`
# line; every other outcome must leave NO record (the file stays indeterminate).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="$ROOT/.github/workflows/k9-conformance.yml"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The coordination step is scripts/conformance-k9.sh coord (one implementation, shared with the template).
printf 'exec bash "%s" coord\n' "$ROOT/scripts/conformance-k9.sh" > "$WORK/step.sh"
[ -s "$WORK/step.sh" ] && ok "the coordination step is present" || { bad "no coordination step found"; exit 1; }

mkdir -p "$WORK/bin" "$WORK/repo/canon/2-protocols/k9-coordination/tools/validate"
# Fake bun: `bun install ...` succeeds; `bun <validate.js> <file>` behaves per $FAKE.
cat > "$WORK/bin/bun" <<'B'
#!/usr/bin/env bash
[ "$1" = install ] && exit 0
case "$FAKE" in
  pass)  echo "PASS $2"; exit 0 ;;
  fail)  echo "FAIL $2: line 3: expected section"; exit 1 ;;
  crash) echo "error: Cannot find module 'apg-js' from '/x/validate.js'"; exit 1 ;;
  cannot) echo "usage: bun validate.js FILE..."; exit 2 ;;
esac
B
chmod +x "$WORK/bin/bun"

run() { # run FAKE -> writes $WORK/coord-results.jsonl
  : > "$WORK/results.jsonl"
  printf '{"file":"coordination.k9","verdict":"routed"}\n' > "$WORK/results.jsonl"
  rm -f "$WORK/coord-results.jsonl"
  ( cd "$WORK/repo" && PATH="$WORK/bin:$PATH" FAKE="$1" RUNNER_TEMP="$WORK" CANON=canon bash -e -o pipefail "$WORK/step.sh" ) > "$WORK/out" 2>&1
}

run pass;  [ "$(jq -r .verdict "$WORK/coord-results.jsonl")" = pass ] && ok "PASS output with exit 0 records a pass" || bad "pass: $(cat "$WORK/coord-results.jsonl") $(cat "$WORK/out")"
run fail;  { [ "$(jq -r .verdict "$WORK/coord-results.jsonl")" = fail ] && jq -r .message "$WORK/coord-results.jsonl" | grep -q 'expected section'; } && ok "a FAIL line with exit 1 records a fail with its message" || bad "fail: $(cat "$WORK/coord-results.jsonl") $(cat "$WORK/out")"
run crash; { [ ! -s "$WORK/coord-results.jsonl" ] && grep -q 'no verdict on coordination.k9' "$WORK/out"; } && ok "a Bun crash (exit 1, no FAIL line) records nothing and warns" || bad "crash: $(cat "$WORK/coord-results.jsonl") $(cat "$WORK/out")"
run cannot; [ ! -s "$WORK/coord-results.jsonl" ] && ok "exit 2 (cannot run) records nothing" || bad "cannot: $(cat "$WORK/coord-results.jsonl")"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
