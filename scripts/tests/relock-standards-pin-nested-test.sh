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
echo "PASS: relock-standards-pin.sh records the actions reached through nested standards reusables (by SHA and local)"
