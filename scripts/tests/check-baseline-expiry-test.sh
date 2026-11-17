#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-baseline-expiry-test.sh — proves the expiry sweep can fail.
#
# Same reasoning as exemption-ratchet-test.sh: a check that cannot fail is
# worse than no check, because it certifies the property it never measured.
# The sweep is also the only thing that notices an undated entry, so every
# bucket and both directions of the exit code are pinned here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="${CHECK_BASELINE_EXPIRY:-$SCRIPT_DIR/../check-baseline-expiry.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TODAY="2026-10-24"
pass=0; fail=0

# run <baseline-json> [extra args...] -> sets OUT and RC
run() {
  local json="$1"; shift
  printf '%s\n' "$json" > "$WORK/b.json"
  set +e
  OUT="$(bash "$CHECK" --baseline "$WORK/b.json" --today "$TODAY" "$@" 2>&1)"
  RC=$?
  set -e
}

check() { # check <label> <condition-value>
  if [ "$2" = "1" ]; then
    printf '  ok    %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$1"; fail=$((fail + 1))
    printf '        exit=%s\n' "${RC:-?}"
    printf '%s\n' "${OUT:-}" | sed 's/^/        | /'
  fi
}

entry() { # entry <file> [expires_at]
  if [ -n "${2:-}" ]; then
    printf '{"severity":"high","rule_module":"m","type":"t","file":"%s","note":"n","expires_at":"%s"}' "$1" "$2"
  else
    printf '{"severity":"high","rule_module":"m","type":"t","file":"%s","note":"n"}' "$1"
  fi
}

echo "== counts and exit codes =="

run "[$(entry a.sh 2027-06-30)]"
check "a dated, current entry passes" "$([ "$RC" = 0 ] && echo 1)"
check "it reports the total" "$(grep -q '63\|1 entr' <<<"$OUT" && echo 1)"

run "[$(entry a.sh)]"
check "an UNDATED entry fails" "$([ "$RC" = 1 ] && echo 1)"
check "and names the entry" "$(grep -q 'm/t @ a.sh' <<<"$OUT" && echo 1)"
check "and says what to add" "$(grep -q 'expires_at' <<<"$OUT" && echo 1)"

run "[$(entry a.sh)]" --allow-undated
check "--allow-undated downgrades it to a warning" "$([ "$RC" = 0 ] && echo 1)"
check "  ...without hiding it" "$(grep -q 'UNDATED' <<<"$OUT" && echo 1)"

run "[$(entry a.sh 2026-10-23)]"
check "an entry that expired YESTERDAY fails" "$([ "$RC" = 1 ] && echo 1)"
check "  ...and says it no longer suppresses" \
  "$(grep -q 'no longer suppress' <<<"$OUT" && echo 1)"

# Today is not expired: apply-baseline.sh keeps `expires_at >= today`, so the
# sweep must agree with the gate to the day or the two report different truths.
run "[$(entry a.sh "$TODAY")]"
check "an entry expiring TODAY still suppresses and does not fail" "$([ "$RC" = 0 ] && echo 1)"
check "  ...but is reported as expiring" "$(grep -q 'EXPIRING' <<<"$OUT" && echo 1)"

echo
echo "== the warning window =="

run "[$(entry a.sh 2026-11-15)]"
check "inside 45d: reported" "$(grep -q 'EXPIRING' <<<"$OUT" && echo 1)"
check "inside 45d: passes" "$([ "$RC" = 0 ] && echo 1)"

run "[$(entry a.sh 2026-11-15)]" --warn-days 10
check "outside a narrowed window: not reported" \
  "$(! grep -q 'EXPIRING' <<<"$OUT" && echo 1)"
check "outside a narrowed window: still passes" "$([ "$RC" = 0 ] && echo 1)"

run "[$(entry a.sh 2026-12-22)]" --warn-days 59
check "the boundary day is inside the window" \
  "$(grep -q 'EXPIRING' <<<"$OUT" && echo 1)"

echo
echo "== mixed buckets do not mask each other =="

run "[$(entry a.sh 2027-06-30),$(entry b.sh),$(entry c.sh 2020-01-01),$(entry d.sh 2026-11-01)]"
check "four entries in four states fails" "$([ "$RC" = 1 ] && echo 1)"
check "  undated counted" "$(grep -q 'undated: 1' <<<"$OUT" && echo 1)"
check "  expired counted" "$(grep -q 'expired: 1' <<<"$OUT" && echo 1)"
check "  expiring counted" "$(grep -q '45d: 1' <<<"$OUT" && echo 1)"

echo
echo "== adoption and degenerate input =="

run "[]"
check "an empty baseline passes" "$([ "$RC" = 0 ] && echo 1)"

set +e
OUT="$(bash "$CHECK" --baseline "$WORK/does-not-exist.json" --today "$TODAY" 2>&1)"; RC=$?
set -e
check "a MISSING baseline passes (nothing is suppressed)" "$([ "$RC" = 0 ] && echo 1)"

run '{"not":"an array"}'
check "a non-array baseline is an input error, not a pass" "$([ "$RC" = 2 ] && echo 1)"

run "[$(entry a.sh 2027-06-30)]" --today "24/10/2026"
check "a malformed --today is an input error" "$([ "$RC" = 2 ] && echo 1)"

run "[$(entry a.sh 2027-06-30)]" --warn-days "soon"
check "a malformed --warn-days is an input error" "$([ "$RC" = 2 ] && echo 1)"

run "[$(entry a.sh 2027-06-30)]" --nonsense
check "an unknown flag is an input error" "$([ "$RC" = 2 ] && echo 1)"

echo
echo "== this repository =="
# The estate's own baseline must hold the property it now enforces on others.
set +e
OUT="$(bash "$CHECK" --today "$TODAY" --baseline "$SCRIPT_DIR/../../.hypatia-baseline.json" 2>&1)"; RC=$?
set -e
check "standards' own baseline has no undated entries" "$([ "$RC" = 0 ] && echo 1)"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" = "0" ]
