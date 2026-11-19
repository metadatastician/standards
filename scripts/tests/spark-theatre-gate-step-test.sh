#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# spark-theatre-gate-step-test.sh — the "Scan for SPARK proof theatre" step of
# .github/workflows/spark-theatre-gate.yml, run as GitHub runs it.
#
# The step body is extracted with yq (never copied by hand) and run with
# `bash -e`, the shell GitHub uses for a `run:` step with no `shell:`, in a
# temporary repository of Ada fixtures.
#
# Proves: a SPARK_Mode-On unit whose header claims proof, with no prover in
# the repository, fails the step (positive control); a SPARK_Mode-Off unit and
# a repository that runs gnatprove pass (negative controls); and a claiming
# unit whose SPARK_Mode line is followed by more than a pipe buffer of code
# still fails, five runs out of five. The step used to read
# `grep -vE … "$f" | grep -qE "$sparkon_re" || continue` under pipefail: grep
# -q exits at the match, the filter still writing dies of SIGPIPE, the
# pipeline reports 141 and the unit was skipped, so the gate passed.
#
# Does not cover: the T2 zero-contract path, or the workflow's triggers.
# Run: bash scripts/tests/spark-theatre-gate-step-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${WF:-$SCRIPT_DIR/../../.github/workflows/spark-theatre-gate.yml}"
command -v yq >/dev/null || { echo "FAIL: yq (mikefarah v4) is required" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fail=$((fail + 1)); }

STEP="$WORK/step.sh"
yq -e '.jobs["spark-theatre-gate"].steps[] | select(.name == "Scan for SPARK proof theatre") | .run' "$WF" > "$STEP" \
  || { echo "FAIL: could not extract the step body from $WF" >&2; exit 1; }
[ -s "$STEP" ] || { echo "FAIL: empty step body" >&2; exit 1; }

# fixture <name> — an empty repository directory; prints its path.
fixture() { local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/src" "$d/.github/workflows"; printf '%s' "$d"; }
# claiming_unit <file> <code lines after the SPARK_Mode line>
claiming_unit() {
  { printf -- '-- This unit is formally verified.\npragma SPARK_Mode (On);\npackage Big is\n'
    local i
    for ((i = 1; i <= $2; i++)); do printf '   Value_%d : constant Integer := %d;  -- padding line\n' "$i" "$i"; done
    printf 'end Big;\n'; } > "$1"
}
# run_step <dir> — sets OUT and RC.
run_step() { OUT="$(cd "$1" && SCAN_PATHS=. ENFORCE_T2=off bash -e "$STEP" 2>&1)"; RC=$?; }

d=$(fixture claim); claiming_unit "$d/src/big.ads" 1; run_step "$d"
if [ "$RC" -eq 1 ] && grep -qF "T1 SPARK theatre" <<<"$OUT"; then ok "positive control: a small claiming unit with no prover fails"
else ko "small claiming unit: wanted exit 1 and a T1 error, got exit $RC"; fi

d=$(fixture off); printf -- '-- formally verified\npragma SPARK_Mode (Off);\npackage P is end P;\n' > "$d/src/p.ads"; run_step "$d"
if [ "$RC" -eq 0 ]; then ok "negative control: SPARK_Mode Off passes"; else ko "SPARK_Mode Off: wanted exit 0, got exit $RC"; fi

d=$(fixture prover); claiming_unit "$d/src/big.ads" 1
printf 'jobs: {prove: {steps: [{run: "gnatprove -P x.gpr"}]}}\n' > "$d/.github/workflows/prove.yml"; run_step "$d"
if [ "$RC" -eq 0 ]; then ok "negative control: a repository that runs gnatprove passes"; else ko "prover evidence: wanted exit 0, got exit $RC"; fi

d=$(fixture proverout); claiming_unit "$d/src/big.ads" 1; mkdir -p "$d/obj2"; : > "$d/obj2/gnatprove.out"; run_step "$d"
if [ "$RC" -eq 0 ]; then ok "negative control: a gnatprove.out in the tree passes"; else ko "gnatprove.out evidence: wanted exit 0, got exit $RC"; fi

# ~4000 lines of ~50 bytes after the match: well above the 64 KiB pipe buffer.
d=$(fixture large); claiming_unit "$d/src/big.ads" 4000
for run in 1 2 3 4 5; do
  run_step "$d"
  if [ "$RC" -eq 1 ] && grep -qF "T1 SPARK theatre" <<<"$OUT"; then
    ok "a claiming unit with ~200 KB after its SPARK_Mode line fails (run $run)"
  else ko "a claiming unit above the pipe buffer was skipped (run $run): wanted exit 1, got exit $RC"; fi
done

echo
echo "spark-theatre-gate-step: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
