#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves run-debtfile.sh CAN FAIL, and — most importantly — that a BROKEN
# PROBE fails rather than reporting zero.
#
# That single property is why this mechanism is worth having. A probe that
# returns 0 on error is indistinguishable from zero debt, and zero is the state
# that passes. Every gate in this estate that ever lied did it that way: the
# proof-check recipe exiting 0 with no prover installed, the linter that never
# parsed its input, the ledger counter whose `grep -c` returned 1 on an
# all-comments file. A Debtfile whose probes silently failed would report a
# spotless repo forever.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/run-debtfile.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0
expect() { # expect <wanted-exit> <label>   (Debtfile content on stdin)
  local want="$1" label="$2" got=0
  cat > Debtfile.a2ml
  bash "$SCRIPT" Debtfile.a2ml >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $label"
  else fail=$((fail+1)); echo "  FAIL  $label (wanted exit $want, got $got)"; fi
}

entry() { # entry <probe> <count> <ceiling> [accepted-until]
  cat <<EOF
### alpha
- description: d
- probe: $1
- count: $2
- ceiling: $3
- severity: high
- policy: remediable
- taxonomy-choice: non-default
- taxonomy-default-arm: adapt-proven-idris2-test
- taxonomy-non-default-arm: write-local-test
- taxonomy-departure-reason: the host API is not supported by the proven suite
- accepted-until: ${4:-2030-01-01}
EOF
}

expect 0 "measured equal to ceiling holds" < <(entry 'echo 4' 4 4       )
expect 0 "measured below ceiling is paid-down, not a failure" < <(entry 'echo 2' 4 4       )
expect 0 "measured zero is resolved" < <(entry 'echo 0' 4 4       )
expect 1 "measured above ceiling breaches" < <(entry 'echo 9' 4 4       )

# The load-bearing cases.
expect 1 "a probe exiting non-zero FAILS (it must not read as zero debt)" < <(entry 'exit 3' 4 4             )
expect 1 "a probe printing a non-integer FAILS" < <(entry 'echo not-a-number' 4 4  )
expect 1 "a probe printing nothing FAILS" < <(entry 'echo' 4 4               )
expect 1 "a probe whose command does not exist FAILS" < <(entry 'no-such-command-xyzzy' 4 4)

# An entry with no probe at all — the structural validator owns this, but the
# runner must not treat it as a silent pass either.
expect 1 "an entry with no probe FAILS in the runner too" <<'EOF'
### alpha
- description: d
- count: 4
- ceiling: 4
- severity: high
- policy: remediable
- accepted-until: 2030-01-01
EOF

# Time-boxed acceptance.
expect 1 "an expired acceptance fails even while holding under its ceiling" < <(entry 'echo 4' 4 4 '2020-01-01')
expect 0 "an unexpired acceptance passes" < <(entry 'echo 4' 4 4 '2099-01-01')

# `grep -c` on a no-match input exits 1 — the exact trap that broke the
# exemption ratchet once. A probe written that way must fail loudly here, not
# be papered over by the runner.
expect 1 "a grep -c probe with no matches FAILS rather than reporting 0" < <(entry 'printf "a\nb\n" | grep -c zzz' 0 0)
expect 0 "the same probe guarded with || true is correct and passes" < <(entry 'printf "a\nb\n" | { grep -c zzz || true; }' 0 0)

# --write lowers a ceiling that has been paid down, and never raises one.
entry 'echo 2' 4 4 > Debtfile.a2ml
bash "$SCRIPT" --write Debtfile.a2ml >/dev/null 2>&1 || true
if grep -q '^- ceiling: 2$' Debtfile.a2ml &&
   grep -q '^- count: 2$' Debtfile.a2ml &&
   grep -q '^- taxonomy-default-arm: adapt-proven-idris2-test$' Debtfile.a2ml &&
   grep -q '^- taxonomy-non-default-arm: write-local-test$' Debtfile.a2ml &&
   grep -q '^- taxonomy-departure-reason: the host API is not supported by the proven suite$' Debtfile.a2ml; then
  pass=$((pass+1)); echo "  ok    --write updates measurements and preserves taxonomy-choice fields"
else
  fail=$((fail+1)); echo "  FAIL  --write did not ratchet down"; sed -n '1,20p' Debtfile.a2ml
fi

# Governance metadata validated by check-debtfile-structure.sh is opaque to the
# runner and must survive its targeted count/ceiling rewrite unchanged.
entry 'echo 2' 4 4 > Debtfile.a2ml
cat >> Debtfile.a2ml <<'EOF'
- taxonomy-choice: non-default
- taxonomy-default-arm: adapt the proven Idris2 test
- taxonomy-non-default-arm: retain the temporary local test
- taxonomy-departure-reason: upstream fixture is gated on the next release
EOF
bash "$SCRIPT" --write Debtfile.a2ml >/dev/null 2>&1 || true
if grep -q '^- taxonomy-choice: non-default$' Debtfile.a2ml \
  && grep -q '^- taxonomy-default-arm: adapt the proven Idris2 test$' Debtfile.a2ml \
  && grep -q '^- taxonomy-non-default-arm: retain the temporary local test$' Debtfile.a2ml \
  && grep -q '^- taxonomy-departure-reason: upstream fixture is gated on the next release$' Debtfile.a2ml; then
  pass=$((pass+1)); echo "  ok    --write preserves testing-taxonomy choice metadata"
else
  fail=$((fail+1)); echo "  FAIL  --write changed testing-taxonomy choice metadata"; sed -n '1,24p' Debtfile.a2ml
fi

entry 'echo 9' 4 4 > Debtfile.a2ml
bash "$SCRIPT" --write Debtfile.a2ml >/dev/null 2>&1 || true
if grep -q '^- ceiling: 4$' Debtfile.a2ml; then
  pass=$((pass+1)); echo "  ok    --write never raises a ceiling, even when debt grew"
else
  fail=$((fail+1)); echo "  FAIL  --write raised a ceiling"; sed -n '1,20p' Debtfile.a2ml
fi

# A grown probe must never leave behind a file check-debtfile-structure.sh
# rejects (standards#955): --write refuses to write a count above its ceiling,
# so the writer and its validator can never disagree. The breach is still
# loud — the run exits 1 and the count stays where it was.
STRUCTURE="${SCRIPT%run-debtfile.sh}check-debtfile-structure.sh"
entry 'echo 9' 4 4 > Debtfile.a2ml
got=0; bash "$SCRIPT" --write Debtfile.a2ml >/dev/null 2>&1 || got=$?
if [ "$got" = 1 ] && grep -q '^- count: 4$' Debtfile.a2ml && grep -q '^- ceiling: 4$' Debtfile.a2ml; then
  if bash "$STRUCTURE" Debtfile.a2ml >/dev/null 2>&1; then
    pass=$((pass+1)); echo "  ok    --write refuses a breaching count and emits a file the structure check accepts"
  else
    fail=$((fail+1)); echo "  FAIL  --write emitted a file check-debtfile-structure.sh rejects"; sed -n '1,20p' Debtfile.a2ml
  fi
else
  fail=$((fail+1)); echo "  FAIL  --write on a grown probe: want exit 1 with count/ceiling 4/4 untouched, got exit $got"; sed -n '1,20p' Debtfile.a2ml
fi

got=0; bash "$SCRIPT" no-such-file.a2ml >/dev/null 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass+1)); echo "  ok    a missing Debtfile exits 2, distinct from a probe failure"
else fail=$((fail+1)); echo "  FAIL  missing file (wanted exit 2, got $got)"; fi

echo
echo "run-debtfile-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
