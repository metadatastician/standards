#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Tests for scripts/check-gate-tiers.sh.
#
# The script is entirely network-driven, so the fixtures arrive through a stub
# `gh` placed ahead of the real one on PATH. That makes this an integration test
# over the real control flow, not a re-implementation of it.
#
# Every assertion below is paired with a case that must NOT fire, so a check
# that has stopped discriminating shows up as a failure rather than as silence.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
SCRIPT=scripts/check-gate-tiers.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
have() { if grep -q "$1" <<<"$OUT"; then ok "$2"; else bad "$2"; fi; }
lack() { if grep -q "$1" <<<"$OUT"; then bad "$2"; else ok "$2"; fi; }

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT

# --- workflow fixtures -------------------------------------------------------
mk() { printf 'name: %s\non:\n  pull_request:\njobs:\n%s\n' "$1" "$2"; }

wf_gate_ok=$(mk '🔴 Wired gate'   '  build:\n    name: Wired Gate Job\n    runs-on: ubuntu-latest\n    steps:\n      - name: step-name-must-be-ignored\n        run: "true"')
wf_gate_bad=$(mk '🔴 Unwired gate' '  build:\n    name: Unwired Gate Job\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"')
wf_advisory=$(mk '⚪ Advisory'      '  advise:\n    name: Advisory Job\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"')
wf_untiered=$(mk 'Plain workflow'  '  ghost:\n    name: Untiered Required Job\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"')

b64() { printf '%b' "$1" | base64 -w0 2>/dev/null || printf '%b' "$1" | base64; }

cat > "$STUB/gh" <<STUBEOF
#!/usr/bin/env bash
# Stub gh. Answers only the endpoints check-gate-tiers.sh actually calls.
ARGS="\$*"
case "\$ARGS" in
  *"/actions/workflows"*)
    printf '%s\t%s\n' '🔴 Wired gate'    '.github/workflows/gate-ok.yml'
    printf '%s\t%s\n' '🔴 Unwired gate'  '.github/workflows/gate-bad.yml'
    printf '%s\t%s\n' '⚪ Advisory'       '.github/workflows/advisory.yml'
    printf '%s\t%s\n' 'Plain workflow'   '.github/workflows/untiered.yml' ;;
  *"/contents/.github/workflows/gate-ok.yml"*)   printf '%s' "$(b64 "$wf_gate_ok")" ;;
  *"/contents/.github/workflows/gate-bad.yml"*)  printf '%s' "$(b64 "$wf_gate_bad")" ;;
  *"/contents/.github/workflows/advisory.yml"*)  printf '%s' "$(b64 "$wf_advisory")" ;;
  *"/contents/.github/workflows/untiered.yml"*)  printf '%s' "$(b64 "$wf_untiered")" ;;
  *"/branches/"*"/protection"*)
    # 404 shape: body on STDOUT, non-zero exit. The script must not ingest this.
    echo '{"message":"Branch not protected","status":"404"}'; exit 1 ;;
  *"/rulesets/"*)
    cat <<'JSON'
{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[
  {"context":"Wired Gate Job"},
  {"context":"Advisory Job"},
  {"context":"Untiered Required Job"},
  {"context":"App Provided Check"},
  {"context":"Nothing Emits This"}
]}}]}
JSON
    ;;
  *"/rulesets"*)              echo 1 ;;
  # The app check reports ONLY on the older commit. A head-only lookback
  # therefore calls it a phantom — that is what the window assertion detects.
  *"/commits/older00/check-runs"*) echo "App Provided Check" ;;
  *"/commits/"*"/check-runs"*)    : ;;
  *"/commits/"*"/status"*)        : ;;
  *"/commits?"*)
    # Honour per_page so a narrowed lookback window really does see less.
    case "\$ARGS" in
      *"per_page=1 "*|*per_page=1) printf 'head1234\n' ;;
      *)           printf 'head1234\nolder00\n' ;;
    esac ;;
  *"/commits/"*)                  echo head1234 ;;
  *) echo main ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/gh"

echo "check-gate-tiers.sh"
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" acme/widget 2>&1)

# --- forward pass ---
have 'GATE_NOT_REQUIRED.*Unwired gate'          'forward: a 🔴 gate with no required job is reported'
lack 'GATE_NOT_REQUIRED.*Wired gate'            'forward: a correctly-wired 🔴 gate is NOT reported'
have 'ADVISORY_IS_REQUIRED'                     'forward: a ⚪ advisory that IS required is reported'

# --- reverse pass (the behaviour this test exists for) ---
have 'UNTIERED_REQUIRED.*Untiered Required Job' 'reverse: required context from an untiered workflow is reported'
have 'ORPHAN_REQUIRED.*Nothing Emits This'      'reverse: a context nothing emits is reported as a phantom'
have 'EXTERNAL_REQUIRED.*App Provided Check'    'reverse: an app-provided context is EXTERNAL, not a phantom'
lack 'ORPHAN_REQUIRED.*App Provided Check'      'reverse: an app-provided context is NOT called a phantom'

# --- the 404-body leak that produced a bogus phantom ---
# NOTE ON WHAT THIS PROVES. It asserts the OUTCOME, not either mechanism.
# Two independent things now stop the leak: the exit-status guard around
# `gh api`, and the `jq` key filter, which discards a 404 body whether or not
# the guard is there. Removing the guard alone does NOT turn this red — so do
# not read a green here as a test of the guard. It is a regression fence on the
# symptom that appeared in the field (a JSON body reported as a phantom context).
lack 'Branch not protected'                     'no 404 body reaches the output (outcome, not mechanism)'

# --- anti-vacuity ---
have 'tier coverage 3/4 workflows (🔴=2)'      'coverage line states the denominator and the 🔴 count'
lack 'NO_TIERS_DECLARED'                        'a repo that DOES declare a 🔴 gate is not flagged'

# --- job parsing ---
lack 'step-name-must-be-ignored'                'a step-level name: is never mistaken for a job name'

if [ "$FAIL" -ne 0 ]; then
  printf "\n--- captured output ---\n%s\n-----------------------\n" "$OUT" >&2
fi
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
