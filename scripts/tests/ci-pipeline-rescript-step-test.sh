#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# ci-pipeline-rescript-step-test.sh — the "ReScript build (warnings are
# errors) + format check" step of .github/workflows/ci-pipeline.yml, run as
# GitHub runs it.
#
# The step body is extracted with yq (never copied by hand) and run with
# `bash --noprofile --norc -eo pipefail`, the shell GitHub uses for
# `shell: bash`. bunx is a stub on PATH.
#
# Proves: when the CLI's `format --help` lists -check before more than a pipe
# buffer of help, the format gate runs and its failure fails the step, five
# runs out of five; when the help lacks -check, the step warns that the gate
# did not run and the summary says SKIPPED (control). The step used to probe
# with `bunx … format --help 2>&1 | grep -q -- '-check'`: grep -q exits at the
# match, a CLI still writing dies of SIGPIPE, the pipeline reports 141 under
# pipefail, and the format gate was skipped. The real CLI's help is small, so
# in practice that needs a help written in several writes and a slow reader;
# the stub makes it deterministic.
#
# Does not cover: the build half of the step, or the job's detect condition.
# Run: bash scripts/tests/ci-pipeline-rescript-step-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${WF:-$SCRIPT_DIR/../../.github/workflows/ci-pipeline.yml}"
command -v yq >/dev/null || { echo "FAIL: yq (mikefarah v4) is required" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fail=$((fail + 1)); }

STEP="$WORK/step.sh"
yq -e '.jobs.rescript.steps[] | select(.name == "ReScript build (warnings are errors) + format check") | .run' "$WF" > "$STEP" \
  || { echo "FAIL: could not extract the step body from $WF" >&2; exit 1; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/bunx" <<'STUBEOF'
#!/usr/bin/env bash
case "$*" in
  "--no-install rescript format --help")
    [ -n "${STUB_NO_CHECK:-}" ] || printf '  -check  Check formatting only\n'
    for i in $(seq 1 3000); do printf '  -option-%d  a help line long enough to fill the pipe buffer\n' "$i"; done ;;
  "--no-install rescript format -all -check") echo "stub: sources are not formatted"; exit 1 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$WORK/bin/bunx"

# run_step [env…] — sets OUT, RC and SUMMARY.
run_step() {
  : > "$WORK/summary"
  OUT="$(cd "$WORK" && env "$@" PATH="$WORK/bin:$PATH" GITHUB_STEP_SUMMARY="$WORK/summary" \
    bash --noprofile --norc -eo pipefail "$STEP" 2>&1)"; RC=$?
  SUMMARY="$(cat "$WORK/summary")"
}

for run in 1 2 3 4 5; do
  run_step STUB=1
  if [ "$RC" -eq 1 ] && grep -qF "format check: checked" <<<"$SUMMARY" \
     && grep -qF "ReScript sources are not formatted" <<<"$OUT"; then
    ok "-check listed before ~180 KB of help: the format gate runs and fails the step (run $run)"
  else ko "-check before ~180 KB of help: wanted exit 1 and a checked format gate, got exit $RC"; fi
done

run_step STUB_NO_CHECK=1
if [ "$RC" -eq 0 ] && grep -qF "SKIPPED" <<<"$SUMMARY" && grep -qF "format gate did NOT run" <<<"$OUT"; then
  ok "control: a help without -check is a warned skip"
else ko "help without -check: wanted exit 0 and a SKIPPED summary, got exit $RC"; fi

echo
echo "ci-pipeline-rescript-step: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
