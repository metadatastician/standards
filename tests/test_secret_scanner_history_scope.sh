#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# test_secret_scanner_history_scope.sh — the history pass of the secret
# scanner is bounded on pull requests and full everywhere else, and it can
# still FAIL in both modes. (standards#1586)
#
# WHY THIS EXISTS
#
#   gitleaks' git mode, given no --log-opts, walks every commit on every
#   branch (`git log -p -U0 --full-history --all`). The reusable ran that on
#   every pull request, so the gate's cost grew with the repository's age
#   rather than the change, timed out on large repos, and was merged through.
#   The "History scope" step now picks the range from the event. A bounded
#   gate is only worth having if the bound cannot quietly become "nothing",
#   so every case here asserts what was scanned AND that a planted secret in
#   that scope still fails the step.
#
# WHAT IT TESTS AGAINST
#
#   Both step bodies ("History scope" and "Gitleaks secret scan — git
#   history (gating)") are extracted from the shipping reusable with yq and
#   run as written. Nothing is copied.
#
# Needs: git, yq (mikefarah v4), and gitleaks. When no gitleaks is on PATH
# and GITLEAKS_BIN is unset, the version and checksum pinned in the
# reusable's install step are downloaded and verified, so this test and the
# gate always use the same binary.
#
# Exit: 0 = all cases behaved, 1 = a case failed, 2 = a prerequisite is missing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REUSABLE="${1:-$ROOT/.github/workflows/secret-scanner-reusable.yml}"
BASELINE="$ROOT/config/gitleaks/estate-baseline.toml"

for tool in git yq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "::error::$tool is required" >&2; exit 2; }
done
[ -f "$REUSABLE" ] || { echo "::error::reusable not found at $REUSABLE" >&2; exit 2; }
[ -f "$BASELINE" ] || { echo "::error::estate baseline not found at $BASELINE" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export RUNNER_TEMP="$WORK/runner"
mkdir -p "$RUNNER_TEMP"

steps='.jobs.gitleaks.steps[]'
step_body() {
  yq -e "[$steps | select(.name == \"$1\")][0] | .run" "$REUSABLE"
}

# --- gitleaks: the pinned binary, or one the caller provides ---------------
if [ -n "${GITLEAKS_BIN:-}" ]; then
  cp "$GITLEAKS_BIN" "$RUNNER_TEMP/gitleaks"
elif command -v gitleaks >/dev/null 2>&1; then
  cp "$(command -v gitleaks)" "$RUNNER_TEMP/gitleaks"
else
  install="$(step_body 'Install gitleaks (pinned + checksum-verified)')" || {
    echo "::error::could not extract the gitleaks install step" >&2; exit 2; }
  if ! (cd "$RUNNER_TEMP" && bash -c "$install") >/dev/null 2>&1; then
    echo "::error::could not install the pinned gitleaks (network?)" >&2; exit 2
  fi
fi
chmod +x "$RUNNER_TEMP/gitleaks"

SCOPE_BODY="$(step_body 'History scope')" || { echo "::error::no 'History scope' step" >&2; exit 1; }
HIST_BODY="$(step_body 'Gitleaks secret scan — git history (gating)')" || {
  echo "::error::no history scan step" >&2; exit 1; }
printf '%s\n' "$SCOPE_BODY" > "$WORK/scope.sh"
printf '%s\n' "$HIST_BODY" > "$WORK/history.sh"

# A token shaped like a GitHub PAT, assembled at run time so that this file
# itself never contains one.
SECRET="ghp_$(printf 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8')"

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm "$2"; }

# repo with: an OLD secret committed then deleted on main, then clean work.
make_repo() {
  local r="$WORK/$1"
  rm -rf "$r"; mkdir -p "$r"
  git -C "$r" init -q -b main
  cp "$BASELINE" "$r/.gitleaks-estate.toml"
  echo "readme" > "$r/README.txt"; commit "$r" base
  printf 'token = "%s"\n' "$SECRET" > "$r/old.txt"; commit "$r" "old secret"
  rm "$r/old.txt"; commit "$r" "old secret removed"
  echo "$r"
}

# run_case NAME REPO EVENT [PR_BASE] [MG_BASE] -> sets RANGE, SCAN_RC
run_case() {
  local repo=$2 out
  out="$WORK/out.$1"
  : > "$WORK/gh_output"
  ( cd "$repo" && EVENT_NAME=$3 PR_BASE_SHA=${4:-} MG_BASE_SHA=${5:-} \
      GITHUB_OUTPUT="$WORK/gh_output" bash "$WORK/scope.sh" ) > "$out" 2>&1 || {
    RANGE="<scope step failed>"; SCAN_RC=99; cat "$out"; return; }
  RANGE="$(sed -n 's/^range=//p' "$WORK/gh_output")"
  ( cd "$repo" && SCAN_RANGE=$RANGE bash "$WORK/history.sh" ) >> "$out" 2>&1
  SCAN_RC=$?
}

# 1. PR on a merge commit, clean change: only the PR is scanned, so the old
#    (already-on-main) secret does not block it.
r="$(make_repo pr_clean)"
git -C "$r" checkout -q -b feature
echo "clean" > "$r/feature.txt"; commit "$r" "clean feature"
git -C "$r" checkout -q main
git -C "$r" -c user.name=t -c user.email=t@example.invalid merge -q --no-ff feature -m merge
run_case pr_clean "$r" pull_request
[ "$RANGE" = "HEAD^1..HEAD" ] && [ "$SCAN_RC" -eq 0 ] \
  && ok "PR merge commit, clean change: DIFF scope, passes" \
  || bad "PR merge commit, clean change: range=$RANGE rc=$SCAN_RC"

# 2. PR that adds a secret and deletes it in a later commit: still caught.
r="$(make_repo pr_secret)"
git -C "$r" checkout -q -b feature
printf 'key = "%s"\n' "$SECRET" > "$r/new.txt"; commit "$r" "add secret"
rm "$r/new.txt"; commit "$r" "hide secret"
git -C "$r" checkout -q main
git -C "$r" -c user.name=t -c user.email=t@example.invalid merge -q --no-ff feature -m merge
run_case pr_secret "$r" pull_request
[ "$RANGE" = "HEAD^1..HEAD" ] && [ "$SCAN_RC" -ne 0 ] \
  && ok "PR adds then deletes a secret: DIFF scope, fails" \
  || bad "PR adds then deletes a secret: range=$RANGE rc=$SCAN_RC"

# 3. push to main: full history, so the old deleted secret is found.
r="$(make_repo push_full)"
run_case push_full "$r" push
[ "$RANGE" = "HEAD" ] && [ "$SCAN_RC" -ne 0 ] \
  && ok "push: FULL scope, finds the old secret" \
  || bad "push: range=$RANGE rc=$SCAN_RC"

# 4. schedule: full history too.
run_case schedule_full "$r" schedule
[ "$RANGE" = "HEAD" ] && [ "$SCAN_RC" -ne 0 ] \
  && ok "schedule: FULL scope, finds the old secret" \
  || bad "schedule: range=$RANGE rc=$SCAN_RC"

# 5. PR checkout that is not a merge commit, with a known base: base..HEAD.
r="$(make_repo pr_linear)"
base="$(git -C "$r" rev-parse HEAD)"
echo "clean" > "$r/x.txt"; commit "$r" "linear clean"
run_case pr_linear "$r" pull_request "$base"
[ "$RANGE" = "$base..HEAD" ] && [ "$SCAN_RC" -eq 0 ] \
  && ok "PR without merge commit: base..HEAD, passes" \
  || bad "PR without merge commit: range=$RANGE rc=$SCAN_RC"

# 6. PR whose base cannot be resolved: FULL, never nothing.
run_case pr_nobase "$r" pull_request "0000000000000000000000000000000000000000"
[ "$RANGE" = "HEAD" ] && [ "$SCAN_RC" -ne 0 ] \
  && ok "PR with unresolvable base: falls back to FULL" \
  || bad "PR with unresolvable base: range=$RANGE rc=$SCAN_RC"

# 7. An empty range (base == HEAD) falls back to FULL instead of scanning 0 commits.
run_case pr_empty "$r" pull_request "$(git -C "$r" rev-parse HEAD)"
[ "$RANGE" = "HEAD" ] && [ "$SCAN_RC" -ne 0 ] \
  && ok "PR with empty range: falls back to FULL" \
  || bad "PR with empty range: range=$RANGE rc=$SCAN_RC"

# 8. merge_group: base_sha..HEAD.
run_case mg "$r" merge_group "" "$base"
[ "$RANGE" = "$base..HEAD" ] && [ "$SCAN_RC" -eq 0 ] \
  && ok "merge_group: base_sha..HEAD" \
  || bad "merge_group: range=$RANGE rc=$SCAN_RC"

# 9. The history step refuses an empty scope rather than scanning nothing.
( cd "$r" && SCAN_RANGE='' bash "$WORK/history.sh" ) >/dev/null 2>&1 \
  && bad "history step accepted an empty SCAN_RANGE" \
  || ok "history step refuses an empty SCAN_RANGE"

echo
echo "history-scope: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
