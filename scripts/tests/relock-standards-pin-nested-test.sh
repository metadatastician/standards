#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -euo pipefail

# relock-standards-pin.sh must record, in the consumer's TARGET dependency
# record, the actions a called standards reusable reaches THROUGH the standards
# reusables it itself calls (governance-reusable.yml nests deed-conformance.yml
# and k9-conformance.yml, standards Phase 0c). Offline: a synthetic standards
# repository and a synthetic consumer, with known answers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELOCK="$SCRIPT_DIR/../relock-standards-pin.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

S="$T/standards"; git init -q -b main "$S"; git -C "$S" config user.email t@t; git -C "$S" config user.name t
mkdir -p "$S/.github/workflows"
# OLD: g-reusable uses only checkout.
cat > "$S/.github/workflows/g-reusable.yml" <<'Y'
on: { workflow_call: {} }
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111 # v1
Y
git -C "$S" add -A; git -C "$S" commit -q -m old; OLD=$(git -C "$S" rev-parse HEAD)
# INNER: a standards reusable that uses acme/inner, at a commit g-reusable will pin.
cat > "$S/.github/workflows/k-reusable.yml" <<'Y'
on: { workflow_call: {} }
jobs:
  k:
    runs-on: ubuntu-latest
    steps:
      - uses: acme/inner@5555555555555555555555555555555555555555 # v5
Y
git -C "$S" add -A; git -C "$S" commit -q -m inner; INNER=$(git -C "$S" rev-parse HEAD)
# A local reusable (same commit) that uses acme/localdep.
cat > "$S/.github/workflows/l-reusable.yml" <<'Y'
on: { workflow_call: {} }
jobs:
  l:
    runs-on: ubuntu-latest
    steps:
      - uses: acme/localdep@8888888888888888888888888888888888888888 # v8
Y
# NEW: g-reusable calls k-reusable at INNER (by SHA) and l-reusable locally.
cat > "$S/.github/workflows/g-reusable.yml" <<Y
on: { workflow_call: {} }
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111 # v1
  nested:
    uses: hyperpolymath/standards/.github/workflows/k-reusable.yml@$INNER
  local:
    uses: ./.github/workflows/l-reusable.yml
Y
cat > "$S/.github/workflows/actions.lock" <<'Y'
version: 'v0.0.3'
workflows:
    '.github/workflows/g-reusable.yml':
        - 'actions/checkout@1111111111111111111111111111111111111111'
dependencies:
    'actions/checkout@1111111111111111111111111111111111111111':
        ref: 'v1'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 10
        repo_id: 11
    'acme/inner@5555555555555555555555555555555555555555':
        ref: 'v5'
        commit: 'sha1-5555555555555555555555555555555555555555'
        owner_id: 50
        repo_id: 51
    'acme/localdep@8888888888888888888888888888888888888888':
        ref: 'v8'
        commit: 'sha1-8888888888888888888888888888888888888888'
        owner_id: 80
        repo_id: 81
Y
git -C "$S" add -A; git -C "$S" commit -q -m new; NEW=$(git -C "$S" rev-parse HEAD)

D="$T/c/.github/workflows"; mkdir -p "$D"
printf 'on: push\njobs:\n  call:\n    uses: hyperpolymath/standards/.github/workflows/g-reusable.yml@%s\n' "$NEW" > "$D/caller.yml"
cat > "$D/actions.lock" <<Y
version: 'v0.0.3'
workflows:
    '.github/workflows/caller.yml':
        - 'hyperpolymath/standards@$OLD'
dependencies:
    'actions/checkout@1111111111111111111111111111111111111111':
        ref: 'v1'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 10
        repo_id: 11
    'hyperpolymath/standards@$OLD':
        ref: '$OLD'
        commit: 'sha1-$OLD'
        owner_id: 6759885
        repo_id: 1116521501
        uses:
            - 'actions/checkout@1111111111111111111111111111111111111111'
Y

bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null || fail "relock refused"
L="$D/actions.lock"
rec=$(awk -v k="    'hyperpolymath/standards@$NEW':" '$0==k{p=1;print;next} p&&/^    [^ ]/{p=0} p' "$L")
printf '%s\n' "$rec" | grep -q "'acme/inner@5555555555555555555555555555555555555555'" \
  || fail "the TARGET record's nested uses: lacks the action a NESTED standards reusable (by SHA) uses"
printf '%s\n' "$rec" | grep -q "'acme/localdep@8888888888888888888888888888888888888888'" \
  || fail "the TARGET record's nested uses: lacks the action a LOCAL ./ reusable uses"
printf '%s\n' "$rec" | grep -q "'actions/checkout@1111111111111111111111111111111111111111'" \
  || fail "the called reusable's own action is gone from the record"
grep -q "^    'acme/inner@5555555555555555555555555555555555555555':\$" "$L" || fail "no record copied for the nested action"
grep -q "^    'acme/localdep@8888888888888888888888888888888888888888':\$" "$L" || fail "no record copied for the local-reusable action"
bash "$SCRIPT_DIR/../close-lock.sh" --check "$D" >/dev/null 2>&1 || fail "the relocked lock is not closed"

# --- negative controls: what must NOT be walked ---------------------------
# scenario NAME (body of g-reusable.yml on stdin): commit it to the synthetic
# standards repo, relock a fresh caller at that commit, set $rec to the TARGET
# record. RELOCK_BIN selects the script (a mutant for the mutation checks).
scenario() {
  cat > "$S/.github/workflows/g-reusable.yml"
  git -C "$S" add -A; git -C "$S" commit -q --allow-empty -m "$1"
  local tgt dd; tgt=$(git -C "$S" rev-parse HEAD); dd="$T/$1/.github/workflows"; mkdir -p "$dd"
  printf 'on: push\njobs:\n  call:\n    uses: hyperpolymath/standards/.github/workflows/g-reusable.yml@%s\n' "$tgt" > "$dd/caller.yml"
  sed "s#^        - 'hyperpolymath/standards@.*#        - 'hyperpolymath/standards@$OLD'#" "$D/actions.lock" > "$dd/actions.lock"
  cat > "$dd/actions.lock" <<Y
version: 'v0.0.3'
workflows:
    '.github/workflows/caller.yml':
        - 'hyperpolymath/standards@$OLD'
dependencies:
    'actions/checkout@1111111111111111111111111111111111111111':
        ref: 'v1'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 10
        repo_id: 11
    'hyperpolymath/standards@$OLD':
        ref: '$OLD'
        commit: 'sha1-$OLD'
        owner_id: 6759885
        repo_id: 1116521501
        uses:
            - 'actions/checkout@1111111111111111111111111111111111111111'
Y
  timeout "${RELOCK_TIMEOUT:-60}" bash "${RELOCK_BIN:-$RELOCK}" --to "$tgt" --standards "$S" "$dd" >"$T/last.log" 2>&1 || { cat "$T/last.log" >&2; return 3; }
  rec=$(awk -v k="    'hyperpolymath/standards@$tgt':" '$0==k{p=1;print;next} p&&/^    [^ ]/{p=0} p' "$dd/actions.lock")
}
body() { # body CALL-LINE : a g-reusable.yml with one nested job
  printf 'on: { workflow_call: {} }\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111 # v1\n  n:\n    uses: %s\n' "$1"
}
GONE=0123456789abcdef0123456789abcdef01234567   # a commit the checkout does not hold
K=.github/workflows/k-reusable.yml

OWNER_BODY=$(body "evil/standards/$K@$INNER")
if scenario other-owner <<<"$OWNER_BODY" 2>/dev/null; then fail "a foreign-owner nested standards call was accepted"; fi
grep -q "evil/standards@" "$T/last.log" || fail "the foreign-owner refusal does not name the call"
scenario tag-form <<<"$(body "hyperpolymath/standards/$K@main")" || fail "relock refused (tag-form)"
! printf '%s\n' "$rec" | grep -q "acme/inner@" || fail "a @main nested call was walked"
scenario missing-sha <<<"$(body "hyperpolymath/standards/$K@$GONE")" || fail "relock refused (missing-sha)"
! printf '%s\n' "$rec" | grep -q "acme/inner@" || fail "an absent-commit nested call was walked"

# a cycle between two local reusables terminates and still records both
printf 'on: { workflow_call: {} }\njobs:\n  m:\n    uses: ./.github/workflows/l-reusable.yml\n' > "$S/.github/workflows/m-reusable.yml"
printf 'on: { workflow_call: {} }\njobs:\n  l:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: acme/localdep@8888888888888888888888888888888888888888 # v8\n  back:\n    uses: ./.github/workflows/m-reusable.yml\n' > "$S/.github/workflows/l-reusable.yml"
CYCLE_BODY=$(body "./.github/workflows/l-reusable.yml")
scenario cycle <<<"$CYCLE_BODY" || fail "relock hung or refused on a local reusable cycle"
printf '%s\n' "$rec" | grep -q "acme/localdep@" || fail "the cycle case lost the action"

# mutant: the cycle control must fail once the visited check is removed
grep -v '^  case " \$nvisited " in' "$RELOCK" > "$T/mut-visited.sh"
cmp -s "$RELOCK" "$T/mut-visited.sh" && fail "visited mutant changed nothing"
if RELOCK_TIMEOUT=10 RELOCK_BIN="$T/mut-visited.sh" scenario cycle-mut <<<"$CYCLE_BODY"; then
  fail "the cycle control did not catch a script without the visited check"
fi
# capability line: stable and side-effect free; a script without the flag (a mutant with it
# removed, so no git history is needed) reports nothing and exits non-zero
sed '/^    --capabilities)/d' "$RELOCK" > "$T/nocap.sh"
cmp -s "$RELOCK" "$T/nocap.sh" && fail "the capability mutant changed nothing"
if nocap=$(bash "$T/nocap.sh" --capabilities 2>/dev/null); then fail "a script without the flag exited 0"; fi
[ -z "$nocap" ] || fail "a script without the flag still reported a capability"
[ "$(bash "$RELOCK" --capabilities)" = "nested-reusable-walk=1" ] || fail "--capabilities does not report nested-reusable-walk=1"
echo "PASS: relock-standards-pin.sh records the actions reached through nested standards reusables (by SHA and local); foreign owners (refused), tag forms, absent commits and cycles are not walked"
