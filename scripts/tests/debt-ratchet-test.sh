#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves check-debt-ratchet.sh CAN FAIL, and fails for the right reasons.
#
# Same standard as scripts/tests/exemption-ratchet-test.sh: this estate's
# recurring defect is the gate that cannot fail. A debt ratchet that always
# passed would license exactly the silent ceiling-creep it exists to prevent,
# while looking green. Every branch is exercised, in both directions.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-debt-ratchet.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"; git init -q .; git config user.email t@example.com; git config user.name T
mkdir -p .machine_readable

write_debtfile() { # write_debtfile <ceiling-a> <ceiling-b>
  cat > .machine_readable/Debtfile.a2ml <<EOF
# SPDX-License-Identifier: MPL-2.0
### alpha-debt
- description: first
- probe: echo 3
- count: 3
- ceiling: $1
- severity: high
- policy: remediable
- accepted-until: 2030-01-01

### beta-debt
- description: second
- probe: echo 5
- count: 5
- ceiling: $2
- severity: low
- policy: flag-only
- accepted-until: 2030-01-01
EOF
}

write_debtfile 3 5
git add -A; git commit -q -m base
BASE="$(git rev-parse HEAD)"

pass=0; fail=0
expect() { # expect <wanted-exit> <label>
  local want="$1" label="$2" got=0
  bash "$SCRIPT" "$BASE" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $label"
  else fail=$((fail+1)); echo "  FAIL  $label (wanted exit $want, got $got)"; fi
}

expect 0 "unchanged ceilings pass"

# --- rule 1: no silent raise ---
write_debtfile 9 5; git commit -aqm "raise alpha"
expect 1 "silently raised ceiling fails"

git commit -q --amend -m "raise alpha

Debt-exception: alpha-debt — vendored upstream tree adds files we do not own"
expect 0 "declared raise passes"

# A declaration is found however many declaration lines the message carries.
# declared_for read `printf … | grep -iE '^Debt-exception' | grep -qF ENTRY`
# under pipefail: with the matching line first and more than a pipe buffer of
# declarations, grep -q exited, the filter died of SIGPIPE, the pipeline
# reported 141 and a declared raise read as undeclared (a false block).
{ printf 'raise alpha\n\n'
  for i in $(seq 1 3000); do printf 'Debt-exception: alpha-debt — declared reason number %d\n' "$i"; done
} > "$WORK/long-msg"
git commit -q --amend -F "$WORK/long-msg"
for run in 1 2 3 4 5; do
  expect 0 "a declaration among ~170 KB of declaration lines licenses the raise (run $run)"
done
# Restore the short message so the cases below see the range they were written for.
git commit -q --amend -m "raise alpha

Debt-exception: alpha-debt — vendored upstream tree adds files we do not own"

# A declaration for a DIFFERENT entry must not license this one.
write_debtfile 9 11
git commit -aqm "raise beta under alpha's exception

Debt-exception: alpha-debt — vendored upstream tree adds files we do not own"
expect 1 "exception naming another entry does not license this one"

git commit -q --amend -m "raise both

Debt-exception: alpha-debt — vendored tree
Debt-exception: beta-debt — probe corrected to stop excluding generated output"
expect 0 "one declaration per raised entry passes"

# --- lowering is always free ---
git checkout -q "$BASE" -- .machine_readable/Debtfile.a2ml
write_debtfile 1 2; git commit -aqm "paid down"
expect 0 "lowered ceilings pass with no ceremony"

# --- rule 2: no silent deletion ---
# Reset the branch first. A declaration is scoped to the PR, not to a commit,
# so `git log BASE..HEAD` sees every trailer written above — including the
# `Debt-exception: beta-debt` from the raise cases, which would legitimately
# license the deletion below and make this case untestable.
git reset -q --hard "$BASE"
cat > .machine_readable/Debtfile.a2ml <<'EOF'
# SPDX-License-Identifier: MPL-2.0
### alpha-debt
- description: first
- probe: echo 3
- count: 3
- ceiling: 3
- severity: high
- policy: remediable
- accepted-until: 2030-01-01
EOF
git commit -aqm "drop beta"
expect 1 "deleting an entry fails — debt leaves by reaching zero, not by deletion"

git commit -q --amend -m "drop beta

Debt-exception: beta-debt — concern moved to the licensing register"
expect 0 "declared deletion passes"

# --- rule 3: adding an entry is welcome, no declaration needed ---
git reset -q --hard "$BASE"
write_debtfile 3 5
cat >> .machine_readable/Debtfile.a2ml <<'EOF'

### gamma-debt
- description: newly recorded
- probe: echo 7
- count: 7
- ceiling: 7
- severity: medium
- policy: remediable
- accepted-until: 2030-01-01
EOF
git commit -aqm "record new debt"
expect 0 "recording new debt passes without a declaration"

# --- a declaration naming nothing real is itself a failure ---
git commit -q --amend -m "record new debt

Debt-exception: no-such-entry — blanket permission attempt"
expect 1 "declaration naming no known entry fails (unparseable is never allowed)"

# --- adopting the Debtfile for the first time ---
rm -rf "$WORK"/.git; git init -q .; git config user.email t@example.com; git config user.name T
rm -f .machine_readable/Debtfile.a2ml
echo hi > README; git add -A; git commit -q -m "no debtfile"
BASE="$(git rev-parse HEAD)"
expect 0 "absent on both sides is not a failure"

write_debtfile 3 5; git add -A; git commit -q -m "adopt the Debtfile"
expect 0 "first adoption passes"

echo
echo "debt-ratchet-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
