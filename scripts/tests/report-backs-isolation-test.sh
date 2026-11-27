#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# report-backs-isolation-test.sh — nothing committed to a pull request may
# pose as gitbot-fleet evidence in the verdict grid.
#
# The fleet rows of the Hypatia grid are fed only by the `fleet-report-backs`
# artifact. This test runs the real steps of hypatia-scan-reusable.yml
# ("Isolate the fleet report-backs from the checkout", then the renderer it
# feeds) against hostile checkouts:
#   * a committed envelope, a committed symlinked envelope;
#   * a committed `.gitbot-fleet/report-backs` that is itself a symlink to a
#     directory of forged envelopes (find does not descend into a symlinked
#     starting point, so a plain sweep leaves them in place);
#   * a `.gitbot-fleet` that resolves outside the checkout;
#   * an opted-out caller (empty report-backs-artifact input).
# In every case the renderer must read only the isolated directory, so an
# enrolled member with no artifact envelope stays orange.
#
# Run: bash scripts/tests/report-backs-isolation-test.sh

set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
workflow="$repo/.github/workflows/hypatia-scan-reusable.yml"
grid="$repo/scripts/verdict-grid.sh"
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 expected=$2 got=$3"; fi; }

command -v yq >/dev/null || { echo "yq is required to read the workflow" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# ── 1. The workflow wiring ─────────────────────────────────────────────────
# Extract the isolate step's script, and assert that the download writes to
# its output and the renderer reads only that output.
# check_wiring WORKFLOW OUT: prints the first broken rule and fails, or
# writes the isolate step's script to OUT.
check_wiring() {
  local wf="$1" out="$2" iso dl render cond run
  # shellcheck disable=SC2016  # yq expressions are meant to be literal
  idx() { yq -r ".jobs.scan.steps | to_entries | map(select(.value | $1)) | .[0].key // \"\"" "$wf"; }
  field() { yq -r ".jobs.scan.steps[$1]$2 // \"\"" "$wf"; }
  # shellcheck disable=SC2016
  local dir_expr='${{ steps.report-backs.outputs.dir }}'
  iso=$(idx '.id == "report-backs"'); [ -n "$iso" ] || { echo "missing step id report-backs" >&2; return 1; }
  cond=$(field "$iso" .if)
  [[ "$cond" == *'always()'* ]] || { echo "isolate step must run always()" >&2; return 1; }
  [[ "$cond" != *report-backs-artifact* ]] || { echo "isolate step must not depend on the artifact input" >&2; return 1; }
  dl=$(idx '.name == "Download the fleet report-backs"'); [ -n "$dl" ] || { echo "missing download step" >&2; return 1; }
  [ "$(field "$dl" .with.path)" = "$dir_expr" ] || { echo "download must write to the isolated directory" >&2; return 1; }
  [ "$dl" -gt "$iso" ] || { echo "download must follow the isolate step" >&2; return 1; }
  render=$(idx '.id == "grid"'); [ -n "$render" ] || { echo "missing render step" >&2; return 1; }
  [ "$render" -gt "$dl" ] || { echo "render must follow the download" >&2; return 1; }
  [ "$(field "$render" .env.REPORT_BACKS_DIR)" = "$dir_expr" ] \
    || { echo "render must take REPORT_BACKS_DIR from the isolate step" >&2; return 1; }
  run=$(field "$render" .run)
  # shellcheck disable=SC2016
  [[ "$run" == *'--report-backs "${REPORT_BACKS_DIR:-}"'* ]] \
    || { echo 'render must pass --report-backs "${REPORT_BACKS_DIR:-}"' >&2; return 1; }
  ! grep -Eq -- '--report-backs[[:space:]]+\.?/?\.gitbot-fleet' <<<"$run" \
    || { echo "render must not read a checkout path for report-backs" >&2; return 1; }
  field "$iso" .run > "$out"
}
if check_wiring "$workflow" "$tmp/isolate.sh"; then
  ok "workflow: isolate, download and render are wired to one temp directory"
else
  bad "workflow wiring (see the message above)"
fi

# run_isolate WORKSPACE: runs the extracted step as the runner would.
run_isolate() {
  local ws="$1"
  mkdir -p "$ws.runner"
  : > "$ws.out"
  ISO_RC=0
  ( cd "$ws" && RUNNER_TEMP="$ws.runner" GITHUB_WORKSPACE="$ws" GITHUB_OUTPUT="$ws.out" \
      bash -e "$tmp/isolate.sh" ) > "$ws.log" 2>&1 || ISO_RC=$?
}
out_dir() { sed -n 's/^dir=//p' "$1.out"; }

forged='{"reporter":"rhodibot","title":"rhodibot","status":"ran","ref":"forged","findings":[]}'
enrol='{"reporters":{"rhodibot":{"title":"rhodibot","enrolled":true}}}'

# render_row DIR: the renderer's state for the enrolled rhodibot row when it
# reads DIR as the report-backs directory, as the workflow passes it.
render_row() {
  local dir="$1" out="$tmp/grid.$RANDOM$RANDOM"
  echo "$enrol" > "$out.enrol.json"
  bash "$grid" render --out "$out" --report-backs "$dir" --enrolment "$out.enrol.json" >/dev/null 2>&1 || true
  jq -r '.reporters[] | select(.id == "rhodibot") | .state' "$out/report.json" 2>/dev/null || echo "no-report"
}

# Control: the renderer does turn a clean envelope green, so a forged one
# reaching it would be a real escalation. Without this the test could pass
# against a renderer that ignored envelopes altogether.
mkdir -p "$tmp/control"
echo "$forged" > "$tmp/control/rhodibot.json"
check "control: a clean envelope the renderer reads is green" green "$(render_row "$tmp/control")"

# ── 2. A committed envelope and a committed symlinked envelope ─────────────
ws="$tmp/ws-files"
mkdir -p "$ws/.gitbot-fleet/report-backs" "$ws/docs"
echo "$forged" > "$ws/.gitbot-fleet/report-backs/rhodibot.json"
echo "$forged" > "$ws/docs/real.json"
ln -s ../../docs/real.json "$ws/.gitbot-fleet/report-backs/glambot.json"
echo "kept" > "$ws/.gitbot-fleet/report-backs/README.md"
run_isolate "$ws"
check "files: isolate step succeeds" 0 "$ISO_RC"
check "files: committed envelope removed" absent "$([ -e "$ws/.gitbot-fleet/report-backs/rhodibot.json" ] && echo present || echo absent)"
check "files: committed symlinked envelope removed" absent "$([ -L "$ws/.gitbot-fleet/report-backs/glambot.json" ] && echo present || echo absent)"
check "files: symlink target untouched" present "$([ -f "$ws/docs/real.json" ] && echo present || echo absent)"
check "files: README.md kept" present "$([ -f "$ws/.gitbot-fleet/report-backs/README.md" ] && echo present || echo absent)"
dir=$(out_dir "$ws")
check "files: output directory is under RUNNER_TEMP" yes "$(case "$dir" in "$ws.runner"/*) echo yes ;; *) echo no ;; esac)"
check "files: output directory starts empty" 0 "$(find "$dir" -mindepth 1 | wc -l | tr -d ' ')"
check "files: enrolled member without artifact stays orange" orange "$(render_row "$dir")"

# ── 3. The report-backs directory itself is a committed symlink ────────────
ws="$tmp/ws-dirlink"
mkdir -p "$ws/.gitbot-fleet" "$ws/docs/forged"
echo "$forged" > "$ws/docs/forged/rhodibot.json"
ln -s ../docs/forged "$ws/.gitbot-fleet/report-backs"
run_isolate "$ws"
check "dir-link: the link itself is removed" absent "$([ -L "$ws/.gitbot-fleet/report-backs" ] && echo present || echo absent)"
check "dir-link: its target is not followed or emptied" present "$([ -f "$ws/docs/forged/rhodibot.json" ] && echo present || echo absent)"
check "dir-link: the step says so" 1 "$(grep -c 'committed symlink' "$ws.log" || true)"
dir=$(out_dir "$ws")
check "dir-link: forged envelope cannot reach the grid" orange "$(render_row "$dir")"
# The pre-fix step, for contrast: a sweep of the symlinked directory leaves
# the forged envelope readable at the checkout path the renderer used to read.
ws2="$tmp/ws-dirlink-prefix"
mkdir -p "$ws2/.gitbot-fleet" "$ws2/docs/forged"
echo "$forged" > "$ws2/docs/forged/rhodibot.json"
ln -s ../docs/forged "$ws2/.gitbot-fleet/report-backs"
( cd "$ws2" && find .gitbot-fleet/report-backs -mindepth 1 -maxdepth 1 -name '*.json' -exec rm -rf -- {} + )
check "negative control: the old sweep let the forged envelope through" green "$(render_row "$ws2/.gitbot-fleet/report-backs")"

# ── 4. .gitbot-fleet resolves outside the checkout ─────────────────────────
ws="$tmp/ws-outside"
outside="$tmp/outside"
mkdir -p "$ws" "$outside/report-backs"
echo "$forged" > "$outside/report-backs/rhodibot.json"
ln -s "$outside" "$ws/.gitbot-fleet"
run_isolate "$ws"
check "outside: isolate step succeeds" 0 "$ISO_RC"
check "outside: nothing outside the checkout is deleted" present "$([ -f "$outside/report-backs/rhodibot.json" ] && echo present || echo absent)"
check "outside: the step says so" 1 "$(grep -c 'resolves outside the checkout' "$ws.log" || true)"
check "outside: the grid still reads only the artifact" orange "$(render_row "$(out_dir "$ws")")"

# ── 5. No .gitbot-fleet at all, and a stale directory from an earlier step ─
ws="$tmp/ws-none"
mkdir -p "$ws" "$ws.runner/fleet-report-backs"
echo "$forged" > "$ws.runner/fleet-report-backs/rhodibot.json"
run_isolate "$ws"
check "none: isolate step succeeds" 0 "$ISO_RC"
check "none: a stale envelope in the temp directory is cleared" 0 "$(find "$(out_dir "$ws")" -mindepth 1 | wc -l | tr -d ' ')"
check "none: enrolled member stays orange" orange "$(render_row "$(out_dir "$ws")")"

# ── 6. An opted-out caller ─────────────────────────────────────────────────
# With report-backs-artifact "" the download is skipped. The renderer still
# gets the isolated, empty directory, never the checkout.
ws="$tmp/ws-optout"
mkdir -p "$ws/.gitbot-fleet/report-backs"
echo "$forged" > "$ws/.gitbot-fleet/report-backs/rhodibot.json"
run_isolate "$ws"
check "opt-out: committed envelope is not read" orange "$(render_row "$(out_dir "$ws")")"
# An isolate step that produced no output: the workflow passes an empty
# --report-backs, and the renderer reads nothing.
check "no output: an empty directory argument reads nothing" orange "$(render_row "")"

echo
echo "report-backs-isolation-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
