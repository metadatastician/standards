#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# covers: check-actions-policy.sh set-allowed-actions.sh rsr-selfaudit.sh
# Regression fixtures for the live Actions policy detector/setter (#486).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../check-actions-policy.sh"
SET="$SCRIPT_DIR/../set-allowed-actions.sh"
SELF_AUDIT="$SCRIPT_DIR/../rsr-selfaudit.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CANON="$WORK/allowed-actions.json"
FAKE_GH="$WORK/gh"
PUT_LOG="$WORK/puts.log"

# Carries a documentation key on purpose: the setter must strip it before
# sending, because the API schema does not accept it.
printf '%s\n' '{"purpose":"doc key, must not be sent","github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":["owner/action@*"]}' > "$CANON"

cat > "$FAKE_GH" <<'FAKE'
#!/usr/bin/env bash
set -u
scenario="${POLICY_SCENARIO:-all-ok}"
args=" $* "

if [[ "$args" == *" -X PUT "* ]]; then
  [ -n "${PUT_LOG:-}" ] && printf '%s\n' "$args" >> "$PUT_LOG"
  # The payload install is the call that strands a repository when it fails.
  if [[ "$args" == *"/selected-actions"* ]] && [ "$scenario" = payload-fails ]; then
    echo "HTTP 403: API rate limit exceeded" >&2
    exit 1
  fi
  printf '%s\n' '{}'
  exit 0
fi

if [[ "$args" == *"/selected-actions "* ]]; then
  case "$scenario" in
    selected-empty) printf '%s\n' '{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":[]}' ;;
    selected-missing) printf '%s\n' '{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":["other/action@*"]}' ;;
    *) printf '%s\n' '{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":["owner/action@*","extra/action@*"]}' ;;
  esac
  exit 0
fi

case "$scenario" in
  api-unavailable) exit 4 ;;
  sha-off|setter-reset) printf '%s\n' '{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}' ;;
  selected-empty|selected-missing|selected-ok|setter-selected)
    printf '%s\n' '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}' ;;
  disabled) printf '%s\n' '{"enabled":false,"allowed_actions":"all","sha_pinning_required":true}' ;;
  *) printf '%s\n' '{"enabled":true,"allowed_actions":"all","sha_pinning_required":true}' ;;
esac
FAKE
chmod +x "$FAKE_GH"

pass=0
fail=0
expect() {
  local label="$1" want="$2" scenario="$3"; shift 3
  local out rc
  : > "$PUT_LOG"
  out="$(POLICY_SCENARIO="$scenario" GH_BIN="$FAKE_GH" PUT_LOG="$PUT_LOG" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then
    echo "PASS: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: $label (wanted $want, got $rc): $out"
    fail=$((fail + 1))
  fi
}

assert_log() {
  local label="$1" pattern="$2"
  if grep -qF -- "$pattern" "$PUT_LOG"; then
    echo "PASS: $label"; pass=$((pass + 1))
  else
    echo "FAIL: $label (no PUT matching '$pattern')"; cat "$PUT_LOG"; fail=$((fail + 1))
  fi
}

assert_rollback() {
  # A rollback is the SECOND permissions PUT: a flip to selected, then a
  # restore. Asserting merely that *some* PUT mentions `all` passes trivially
  # whenever the default posture IS all — a guard asking a different question
  # than its consumer. Assert the ORDER.
  if grep -q -- 'allowed_actions=selected' "$PUT_LOG" \
     && tail -1 "$PUT_LOG" | grep -q -- 'allowed_actions=all'; then
    echo "PASS: a failed payload install ROLLS BACK the posture flip"
    pass=$((pass + 1))
  else
    echo "FAIL: no rollback — expected a flip to selected, then a restore to all"
    cat "$PUT_LOG"
    fail=$((fail + 1))
  fi
}

assert_no_log() {
  local label="$1" pattern="$2"
  if grep -qF -- "$pattern" "$PUT_LOG"; then
    echo "FAIL: $label (unexpected PUT matching '$pattern')"; cat "$PUT_LOG"; fail=$((fail + 1))
  else
    echo "PASS: $label"; pass=$((pass + 1))
  fi
}

expect "all + SHA pinning passes" 0 all-ok "$CHECK" owner/repo "$CANON"
expect "API/authentication failure is unavailable, not a policy verdict" 3 api-unavailable "$CHECK" owner/repo "$CANON"
expect "SHA pinning off blocks" 1 sha-off "$CHECK" owner/repo "$CANON"
expect "disabled Actions blocks" 1 disabled "$CHECK" owner/repo "$CANON"
expect "empty selected allowlist blocks" 1 selected-empty "$CHECK" owner/repo "$CANON"
expect "selected allowlist missing canonical entry blocks" 1 selected-missing "$CHECK" owner/repo "$CANON"
expect "selected canonical superset passes" 0 selected-ok "$CHECK" owner/repo "$CANON"

# The estate canon (config/settings/repo.json) is allowed_actions=selected for
# every repository, so that is the setter's default posture.
expect "setter applies the estate default (selected) and verifies" 0 setter-selected \
  "$SET" owner/repo "$CANON"
expect "setter supports the deliberate ACTIONS_POSTURE=all relaxation" 0 all-ok \
  env ACTIONS_POSTURE=all "$SET" owner/repo "$CANON"
expect "setter refuses a read-back with SHA pinning reset" 1 setter-reset \
  env ACTIONS_POSTURE=all "$SET" owner/repo "$CANON"

# The disarming state this script exists to prevent: selected + empty list.
expect "setter refuses success when the allow-list reads back empty" 1 selected-empty \
  "$SET" owner/repo "$CANON"

# A repository already on `selected` must get the payload BEFORE the posture
# PUT: adding patterns to a live list only ever grants, so there is no window
# in which it is stricter than either end state.
expect "setter installs the payload first when no flip is needed" 0 setter-selected \
  "$SET" owner/repo "$CANON"
head -1 "$PUT_LOG" | grep -q -- '/selected-actions' \
  && { echo "PASS: payload PUT precedes the permissions PUT"; pass=$((pass + 1)); } \
  || { echo "FAIL: payload PUT did not come first"; cat "$PUT_LOG"; fail=$((fail + 1)); }

# THE REGRESSION THIS REWRITE EXISTS FOR. A flip was required, the payload
# install then failed, and the repository must NOT be left on `selected` with an
# empty allow-list — that state refuses every third-party action and makes
# required contexts stop reporting entirely.
expect "a failed payload install is reported as failure" 1 payload-fails \
  "$SET" owner/repo "$CANON"
assert_rollback

# Documentation keys in the canon file must never reach the API.
expect "setter strips documentation keys from the canon payload" 0 setter-selected \
  "$SET" owner/repo "$CANON"
assert_log "the payload PUT actually happened" '/selected-actions'
assert_no_log "no documentation key is sent to the API" 'doc key, must not be sent'

expect "RSR self-audit blocks an unpinned live policy" 1 sha-off \
  env RSR_REPOSITORY=owner/repo "$SELF_AUDIT" "$SCRIPT_DIR/../.."
expect "RSR self-audit accepts a compliant live policy" 0 all-ok \
  env RSR_REPOSITORY=owner/repo "$SELF_AUDIT" "$SCRIPT_DIR/../.."

echo "actions-policy-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
