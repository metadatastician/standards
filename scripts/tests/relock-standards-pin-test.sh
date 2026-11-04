#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -euo pipefail

# Regression test for relock-standards-pin.sh. Offline: a synthetic standards
# repository and a synthetic consumer lock, with known answers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELOCK="$SCRIPT_DIR/../relock-standards-pin.sh"
SYNC="$SCRIPT_DIR/../check-lock-sync.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# fail MESSAGE — report a failed assertion and stop the test.
fail() { echo "FAIL: $*" >&2; exit 1; }

# Synthetic standards: OLD's reusable uses checkout + old/dep; NEW's uses
# checkout + acme/tool, and NEW's own lock records acme/tool.
S="$T/standards"; git init -q -b main "$S"; git -C "$S" config user.email t@t; git -C "$S" config user.name t
mkdir -p "$S/.github/workflows"
cat > "$S/.github/workflows/x-reusable.yml" <<'Y'
on: { workflow_call: {} }
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111 # v1
      - uses: old/dep/sub@2222222222222222222222222222222222222222
Y
git -C "$S" add -A; git -C "$S" commit -q -m old; OLD=$(git -C "$S" rev-parse HEAD)
cat > "$S/.github/workflows/x-reusable.yml" <<'Y'
on: { workflow_call: {} }
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111 # v1
      - uses: acme/tool/sub@3333333333333333333333333333333333333333
Y
# A second reusable, called in the short-pin case only.
cat > "$S/.github/workflows/y-reusable.yml" <<'Y'
on: { workflow_call: {} }
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: zeta/only@7777777777777777777777777777777777777777
Y
cat > "$S/.github/workflows/actions.lock" <<'Y'
version: 'v0.0.3'
workflows:
    '.github/workflows/x-reusable.yml':
        - 'acme/tool@3333333333333333333333333333333333333333'
        - 'actions/checkout@1111111111111111111111111111111111111111'
dependencies:
    'acme/tool@3333333333333333333333333333333333333333':
        ref: 'v3'
        commit: 'sha1-3333333333333333333333333333333333333333'
        owner_id: 30
        repo_id: 31
    'actions/checkout@1111111111111111111111111111111111111111':
        ref: 'v1'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 10
        repo_id: 11
Y
git -C "$S" add -A; git -C "$S" commit -q -m new; NEW=$(git -C "$S" rev-parse HEAD)

# A consumer whose caller was re-pointed to NEW but whose lock is still on OLD.
consumer() {
  local d="$T/$1/.github/workflows"; rm -rf "${T:?}/${1:?}"; mkdir -p "$d"
  printf 'on: push\njobs:\n  call:\n    uses: hyperpolymath/standards/.github/workflows/x-reusable.yml@%s\n' "$NEW" > "$d/caller.yml"
  printf 'on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n' > "$d/own.yml"
  cat > "$d/actions.lock" <<Y
version: 'v0.0.3'
workflows:
    '.github/workflows/caller.yml':
        - 'hyperpolymath/standards@$OLD'
    '.github/workflows/own.yml':
        - 'actions/checkout@1111111111111111111111111111111111111111'
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
            - 'old/dep@2222222222222222222222222222222222222222'
    'old/dep@2222222222222222222222222222222222222222':
        ref: 'v2'
        commit: 'sha1-2222222222222222222222222222222222222222'
        owner_id: 20
        repo_id: 21
        uses:
            - 'old/sub@6666666666666666666666666666666666666666'
    'old/sub@6666666666666666666666666666666666666666':
        ref: 'v6'
        commit: 'sha1-6666666666666666666666666666666666666666'
        owner_id: 60
        repo_id: 61
    'unrelated/orphan@4444444444444444444444444444444444444444':
        ref: 'v4'
        commit: 'sha1-4444444444444444444444444444444444444444'
        owner_id: 40
        repo_id: 41
Y
  echo "$d"
}

# 1. Known answer.
D=$(consumer ok)
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null
L="$D/actions.lock"
grep -q "^        - 'hyperpolymath/standards@$NEW'\$" "$L" || fail "workflow entry not re-keyed"
grep -q "$OLD" "$L" && fail "OLD standards commit still in the lock"
grep -q "^    'hyperpolymath/standards@$NEW':\$" "$L" || fail "no record for the new pin"
grep -q "^    'acme/tool@3333333333333333333333333333333333333333':\$" "$L" || fail "needed record not copied from standards' lock"
grep -q "old/dep@" "$L" && fail "record only the OLD reusable used was not pruned"
grep -q "old/sub@" "$L" && fail "record kept alive only by a pruned record was not pruned"
grep -q "unrelated/orphan@" "$L" || fail "an orphan the OLD record never named was pruned"
grep -q "owner_id: 6759885" "$L" || fail "owner_id not carried over"
[ "$(awk '/^dependencies:$/{f=1;next} f && /^    \x27/' "$L" | LC_ALL=C sort -c 2>&1; echo $?)" = 0 ] || fail "dependency records not in C-locale key order"
if command -v gawk >/dev/null 2>&1; then
  sed -i '/unrelated\/orphan/,/repo_id: 41/d' "$L"   # the gate checks closure, not unrelated orphans
  bash "$SYNC" "$D" >/dev/null 2>&1 || fail "check-lock-sync.sh rejects the relocked lock"
fi
echo "  PASS known answer (re-key, record rebuilt, needed record copied, OLD-only records pruned transitively, unrelated orphan kept)"

# Copied self-SHA leaf refs must not survive a repin to repaired Standards.
D=$(consumer stale-leaf)
sed -i "s/ref: 'v1'/ref: '1111111111111111111111111111111111111111'/" "$D/actions.lock"
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null
grep -q "ref: '1111111111111111111111111111111111111111'" "$D/actions.lock" && fail "copied self-SHA leaf survived repin"
grep -q "ref: 'v1'" "$D/actions.lock" || fail "corrected symbolic ref missing"
echo "  PASS copied self-SHA leaf refreshed from defining lock"

D=$(consumer stale-identity)
sed -i "s/ref: 'v1'/ref: '1111111111111111111111111111111111111111'/; s/repo_id: 11$/repo_id: 999/" "$D/actions.lock"
cp "$D/actions.lock" "$T/identity-before"
if bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >"$T/identity-log" 2>&1; then fail "identity mismatch accepted"; fi
cmp -s "$D/actions.lock" "$T/identity-before" || fail "refusal changed consumer lock"
grep -q 'identity mismatch' "$T/identity-log" || fail "wrong refusal reason"
echo "  PASS identity mismatch refused without changing lock"

# Empty grep matches used to trigger `set -e` before the fail-closed refusal.
D=$(consumer missing-local-identity)
sed -i "s/ref: 'v1'/ref: '1111111111111111111111111111111111111111'/; /commit: 'sha1-1111111111111111111111111111111111111111'/d; /owner_id: 10$/d; /repo_id: 11$/d" "$D/actions.lock"
cp "$D/actions.lock" "$T/missing-local-before"
if bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >"$T/missing-local-log" 2>&1; then fail "missing local identity accepted"; fi
cmp -s "$D/actions.lock" "$T/missing-local-before" || fail "missing local identity refusal changed consumer lock"
grep -q 'identity mismatch' "$T/missing-local-log" || fail "missing local identity did not reach refusal"
echo "  PASS missing local identity refused without changing lock"

# Exercise the other grep assignment too: a target Standards record with no
# identity fields must reach the same explicit refusal, not exit on grep status.
cp "$S/.github/workflows/actions.lock" "$T/source-lock-with-identity"
sed -i "/commit: 'sha1-1111111111111111111111111111111111111111'/d; /owner_id: 10$/d; /repo_id: 11$/d" "$S/.github/workflows/actions.lock"
git -C "$S" add .github/workflows/actions.lock .github/workflows/x-reusable.yml
git -C "$S" commit -q -m missing-source-identity
NEW_WITHOUT_ID=$(git -C "$S" rev-parse HEAD)
NEW_SAVE=$NEW; NEW=$NEW_WITHOUT_ID
D=$(consumer missing-source-identity)
sed -i "s/ref: 'v1'/ref: '1111111111111111111111111111111111111111'/" "$D/actions.lock"
cp "$D/actions.lock" "$T/missing-source-before"
if bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >"$T/missing-source-log" 2>&1; then fail "missing source identity accepted"; fi
cmp -s "$D/actions.lock" "$T/missing-source-before" || fail "missing source identity refusal changed consumer lock"
grep -q 'identity mismatch' "$T/missing-source-log" || fail "missing source identity did not reach refusal"
NEW=$NEW_SAVE
cp "$T/source-lock-with-identity" "$S/.github/workflows/actions.lock"
echo "  PASS missing source identity refused without changing lock"

# 2. Idempotent.
D=$(consumer idem); bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null
cp "$D/actions.lock" "$T/once"; bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null
cmp -s "$T/once" "$D/actions.lock" || fail "second run changed the lock"
echo "  PASS idempotent"

# A commented caller example pinned at another commit is not a pin.
D=$(consumer commented-example)
printf '# Caller example:\n#   uses: hyperpolymath/standards/.github/workflows/x-reusable.yml@%s\n' "$OLD" >> "$D/caller.yml"
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null 2>&1 || fail "a commented caller example at another commit refused the relock"
grep -q "^    'hyperpolymath/standards@$NEW':\$" "$D/actions.lock" || fail "commented example: no record for the new pin"
echo "  PASS a commented caller example at another commit is not counted as a pin"

# A flow-style (KYAML) call is still a pin.
D=$(consumer flow-style)
printf 'on: push\njobs: { call: { uses: "hyperpolymath/standards/.github/workflows/x-reusable.yml@%s" } }\n' "$NEW" > "$D/caller.yml"
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null 2>&1 || fail "a flow-style call refused the relock"
grep -q "^        - 'hyperpolymath/standards@$NEW'\$" "$D/actions.lock" || fail "flow-style: workflow entry not re-keyed"
echo "  PASS a flow-style call is counted as a pin"

# A quoted `uses` key is still a pin.
D=$(consumer quoted-key)
printf 'on: push\njobs:\n  call:\n    "uses": hyperpolymath/standards/.github/workflows/x-reusable.yml@%s\n' "$NEW" > "$D/caller.yml"
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null 2>&1 || fail "a quoted uses key refused the relock"
grep -q "^        - 'hyperpolymath/standards@$NEW'\$" "$D/actions.lock" || fail "quoted key: workflow entry not re-keyed"
echo "  PASS a quoted uses key is counted as a pin"

# 3. Refusals leave the lock byte-identical.
#
# Each mutator is a FUNCTION taking the consumer directory, not a shell string
# handed to `eval` (CWE-95; hypatia eval_in_shell). Nothing untrusted ever
# reached that `eval` — every case is fixed text in this file — but an `eval` in
# a test is a template for the next one, and the string form silently breaks the
# moment a fixture path grows a space or a quote.
refuse_case() { # name mutator-function
  local d; d=$(consumer "$1"); "$2" "$d"; cp "$d/actions.lock" "$T/before"
  if bash "$RELOCK" --to "$NEW" --standards "$S" "$d" >/dev/null 2>&1; then fail "$1: relock succeeded"; fi
  cmp -s "$T/before" "$d/actions.lock" || fail "$1: lock modified on refusal"
  echo "  PASS refused: $1"
}
mutate_still_on_old() { sed -i "s/@$NEW/@$OLD/" "$1/caller.yml"; }
refuse_case still-on-old mutate_still_on_old
BAD_PREFIX="${NEW:0:11}"
# Appends a hex digit (a string, not arithmetic), so the 12th char differs from NEW's.
if [ "${NEW:11:1}" = 0 ]; then BAD_PREFIX+="1"; else BAD_PREFIX+="0"; fi
mutate_different_prefix() { sed -i "s/@$NEW/@$BAD_PREFIX/" "$1/caller.yml"; }
refuse_case different-prefix mutate_different_prefix
mutate_mixed_commits() { cp "$1/caller.yml" "$1/other.yml"; sed -i "s/@$NEW/@$BAD_PREFIX/" "$1/other.yml"; }
refuse_case mixed-commits mutate_mixed_commits
mutate_overlong_pin() { sed -i "s/@$NEW/@${NEW}a/" "$1/caller.yml"; }
refuse_case overlong-pin mutate_overlong_pin
# A pin whose reusable needs a record that neither lock has: a commit NEW2
# whose reusable uses acme/tool at a ref standards' own lock does not record.
sed -i "s#acme/tool/sub@3333333333333333333333333333333333333333#acme/tool/sub@5555555555555555555555555555555555555555#" "$S/.github/workflows/x-reusable.yml"
git -C "$S" commit -qam new2; NEW2=$(git -C "$S" rev-parse HEAD)
mutate_record_nowhere() { sed -i "s/@$NEW/@$NEW2/" "$1/caller.yml"; NEW_SAVE=$NEW; NEW=$NEW2; }
refuse_case record-nowhere mutate_record_nowhere
NEW=$NEW_SAVE
mutate_no_old_record() { sed -i "/^    .hyperpolymath\/standards@$OLD.:/,/^            - .old\/dep/d" "$1/actions.lock"; }
refuse_case no-old-record mutate_no_old_record
mutate_short_pin_elsewhere() { sed -i "s/@$NEW/@${OLD:0:7}/" "$1/caller.yml"; }
refuse_case short-pin-elsewhere mutate_short_pin_elsewhere
# Under 7 hex is no pin the applier writes or reads, even when it prefixes NEW
# and the lock carries a matching entry and record for it.
# tiny DIR — add tiny.yml pinning a 6-hex prefix of NEW, with its lock entry.
tiny() {
  sed "s/@$NEW/@${NEW:0:6}/" "$1/caller.yml" > "$1/tiny.yml"
  sed -i "/^dependencies:\$/i\\    '.github/workflows/tiny.yml':\\n        - 'hyperpolymath/standards@${NEW:0:6}'" "$1/actions.lock"
  printf "    'hyperpolymath/standards@%s':\n        ref: '%s'\n        commit: 'sha1-%s'\n        owner_id: 6759885\n        repo_id: 1116521501\n" \
    "${NEW:0:6}" "${NEW:0:6}" "$NEW" >> "$1/actions.lock"
}
refuse_case short-pin-too-short tiny
# desync DIR — caller.yml now pins a short NEW ref but its lock entry still
# names OLD; full.yml pins NEW in full. Re-keying caller.yml's entry to the full
# NEW would not match its pin, which the gates reject.
desync() {
  cp "$1/caller.yml" "$1/full.yml"
  sed -i "s/@$NEW/@${NEW:0:12}/" "$1/caller.yml"
  sed -i "/^dependencies:\$/i\\    '.github/workflows/full.yml':\\n        - 'hyperpolymath/standards@$OLD'" "$1/actions.lock"
}
refuse_case short-pin-entry-desync desync

# 4. No lock: nothing to do.
D=$(consumer nolock); rm "$D/actions.lock"
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null || fail "no-lock repo was refused"
[ ! -e "$D/actions.lock" ] || fail "a lock was created"
echo "  PASS no actions.lock: nothing to do"

# 5. A short pin that prefixes NEW is current (the applier leaves it FRESH), at
# the lengths the applier reads (7..39 hex). Its workflow and its own record
# stay byte-identical, and only full pins feed NEW's record: zeta/only, used by
# the short-pinned reusable alone, must not join it.
for length in 7 12 39; do
  D=$(consumer "short-$length"); SHORT=${NEW:0:length}
  printf 'on: push\njobs:\n  call:\n    uses: hyperpolymath/standards/.github/workflows/y-reusable.yml@%s\n' "$SHORT" > "$D/short.yml"
  sed -i "/^dependencies:\$/i\\    '.github/workflows/short.yml':\\n        - 'hyperpolymath/standards@$SHORT'" "$D/actions.lock"
  cat >> "$D/actions.lock" <<Y
    'hyperpolymath/standards@$SHORT':
        ref: '$SHORT'
        commit: 'sha1-$NEW'
        owner_id: 6759885
        repo_id: 1116521501
        uses:
            - 'zeta/only@7777777777777777777777777777777777777777'
    'zeta/only@7777777777777777777777777777777777777777':
        ref: 'v7'
        commit: 'sha1-7777777777777777777777777777777777777777'
        owner_id: 70
        repo_id: 71
Y
  # short_rec LOCK — print the short pin's own dependency record from LOCK.
  short_rec() { awk -v k="    'hyperpolymath/standards@$SHORT':" '$0==k{f=1;print;next} f&&/^    [^ ]/{exit} f' "$1"; }
  short_rec "$D/actions.lock" > "$T/short-before"
  cp "$D/short.yml" "$T/short-wf-before"
  bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null || fail "$length-hex pin prefixing the target was refused"
  L="$D/actions.lock"
  cmp -s "$T/short-wf-before" "$D/short.yml" || fail "$length-hex pin: the workflow was rewritten"
  short_rec "$L" | cmp -s - "$T/short-before" || fail "$length-hex pin: its own record was changed"
  grep -q "^        - 'hyperpolymath/standards@$SHORT'\$" "$L" || fail "$length-hex pin: its workflow entry was re-keyed"
  grep -q "$OLD" "$L" && fail "$length-hex pin: OLD left in the lock"
  awk -v k="    'hyperpolymath/standards@$NEW':" '$0==k{f=1;next} f&&/^    [^ ]/{exit} f' "$L" | grep -q zeta/only \
    && fail "$length-hex pin: a reusable called only by the short pin fed the full record"
  grep -q "^    'zeta/only@7777777777777777777777777777777777777777':\$" "$L" || fail "$length-hex pin: its record's dependency was pruned"
  if command -v gawk >/dev/null 2>&1; then
    sed -i '/unrelated\/orphan/,/repo_id: 41/d' "$L"
    bash "$SYNC" "$D" >/dev/null 2>&1 || fail "$length-hex pin: check-lock-sync.sh rejects the relocked lock"
  fi
  echo "  PASS $length-hex pin prefixing the target: left as it is, full record from full pins only"
done


# 6. GitHub's lockfile parser folds owner/repo case: 'ACME/tool@<sha>' and
# 'acme/tool@<sha>' are one key, and two records for it with different
# metadata are a parse error ("duplicate action key ... after
# canonicalization"), which fails every run. A record the consumer already
# holds under another owner/repo spelling is the needed record: it is kept,
# never copied a second time. Measured on hyperpolymath/januskey, whose
# 'Swatinem/rust-cache@6323deb…' met standards' 'swatinem/rust-cache@6323deb…'.
# case_variant DIR REF — give DIR's lock a 'ACME/Tool' spelling of the record
# NEW's reusable needs, with ref: REF.
case_variant() {
  cat >> "$1/actions.lock" <<Y
    'ACME/Tool@3333333333333333333333333333333333333333':
        ref: '$2'
        commit: 'sha1-3333333333333333333333333333333333333333'
        owner_id: 30
        repo_id: 31
Y
}
# acme_keys LOCK — count the dependency keys naming acme/tool@333…, any case.
acme_keys() { grep -ciE "^    'acme/tool@3333333333333333333333333333333333333333':\$" "$1" || true; }
D=$(consumer case-kept); case_variant "$D" 'v3.0.1'
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null || fail "case variant: relock refused"
L="$D/actions.lock"
[ "$(acme_keys "$L")" = 1 ] || fail "case variant: the record is keyed $(acme_keys "$L") times (the parser rejects a duplicate)"
grep -q "^    'ACME/Tool@3333333333333333333333333333333333333333':\$" "$L" || fail "case variant: the consumer's spelling was not kept"
grep -q "ref: 'v3.0.1'" "$L" || fail "case variant: the consumer's symbolic ref was overwritten"
echo "  PASS record held under another owner/repo case is kept, not duplicated"

D=$(consumer case-self-sha); case_variant "$D" '3333333333333333333333333333333333333333'
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null || fail "case variant self-SHA: relock refused"
L="$D/actions.lock"
[ "$(acme_keys "$L")" = 1 ] || fail "case variant self-SHA: the record is keyed $(acme_keys "$L") times"
grep -q "ref: '3333333333333333333333333333333333333333'" "$L" && fail "case variant self-SHA: the self-SHA ref survived"
awk "/^    'ACME\\/Tool@3333333333333333333333333333333333333333':\$/{f=1;next} f&&/^    [^ ]/{exit} f" "$L" | grep -qx "        ref: 'v3'" \
  || fail "case variant self-SHA: not repaired to standards' symbolic ref"
echo "  PASS self-SHA record held under another owner/repo case is repaired in place"


# The record the consumer lacks is copied from standards' own lock, which may
# key it under another owner/repo spelling than the reusable's `uses:` edge.
# That is still the record: copied, not refused as missing.
cp "$S/.github/workflows/actions.lock" "$T/source-lock-before-case"
git -C "$S" show "$NEW:.github/workflows/x-reusable.yml" > "$S/.github/workflows/x-reusable.yml"
sed -i "s|^    'acme/tool@3333333333333333333333333333333333333333':\$|    'ACME/Tool@3333333333333333333333333333333333333333':|" "$S/.github/workflows/actions.lock"
git -C "$S" add .github/workflows/actions.lock .github/workflows/x-reusable.yml
git -C "$S" commit -q -m source-case-variant
NEW_SAVE=$NEW; NEW=$(git -C "$S" rev-parse HEAD)
D=$(consumer source-case)
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >"$T/source-case-log" 2>&1 || fail "source case variant: relock refused ($(cat "$T/source-case-log"))"
L="$D/actions.lock"
[ "$(acme_keys "$L")" = 1 ] || fail "source case variant: the record is keyed $(acme_keys "$L") times"
grep -q "ref: 'v3'" "$L" || fail "source case variant: the copied record lost its ref"
if command -v gawk >/dev/null 2>&1; then
  sed -i '/unrelated\/orphan/,/repo_id: 41/d' "$L"
  bash "$SYNC" "$D" >/dev/null 2>&1 || fail "source case variant: check-lock-sync.sh rejects the relocked lock"
fi
NEW=$NEW_SAVE
cp "$T/source-lock-before-case" "$S/.github/workflows/actions.lock"
echo "  PASS record standards' lock keys under another owner/repo case is copied, not refused"


# 7. Transferred canonical owner: the workflow and the dependency record must
# both use metadatastician, retaining repo_id and replacing the old owner_id.
D=$(consumer canonical-from-legacy)
sed -i 's#hyperpolymath/standards/\.github#metadatastician/standards/\.github#' "$D/caller.yml"
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null || fail "canonical transfer refused"
L="$D/actions.lock"
grep -q "^        - 'metadatastician/standards@$NEW'\$" "$L" || fail "canonical workflow ref not migrated"
grep -q "^    'metadatastician/standards@$NEW':\$" "$L" || fail "canonical record absent"
grep -A4 "^    'metadatastician/standards@$NEW':\$" "$L" | grep -qx '        owner_id: 297579217' || fail "canonical owner ID absent"
grep -A5 "^    'metadatastician/standards@$NEW':\$" "$L" | grep -qx '        repo_id: 1116521501' || fail "repository ID changed"
grep -q 'hyperpolymath/standards@' "$L" && fail "legacy records survived canonical transfer"
cp "$L" "$T/canonical-once"
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null || fail "canonical idempotent repeat refused"
cmp -s "$T/canonical-once" "$L" || fail "canonical repeat changed the lock"
echo "  PASS canonical owner transfer from legacy lock and idempotent retry"

# Canonical consumers that already have canonical (but old) records must work.
D=$(consumer canonical-existing)
sed -i 's#hyperpolymath/standards/\.github#metadatastician/standards/\.github#' "$D/caller.yml"
sed -i 's#hyperpolymath/standards@#metadatastician/standards@#g' "$D/actions.lock"
bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >/dev/null || fail "canonical existing lock refused"
grep -q "^    'metadatastician/standards@$NEW':\$" "$D/actions.lock" || fail "canonical old lock not updated"
echo "  PASS canonical-to-canonical SHA bump"

# Two different owners in live workflow callers are ambiguous; never mutate.
D=$(consumer mixed-owner)
cp "$D/caller.yml" "$D/other.yml"
sed -i 's#hyperpolymath/standards/\.github#metadatastician/standards/\.github#' "$D/caller.yml"
cp "$D/actions.lock" "$T/mixed-before"
if bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >"$T/mixed-log" 2>&1; then fail "mixed owners were accepted"; fi
cmp -s "$D/actions.lock" "$T/mixed-before" || fail "mixed-owner refusal changed lock"
grep -q 'mixed standards owners' "$T/mixed-log" || fail "missing explicit mixed-owner diagnosis"
echo "  PASS mixed owner coordinates refused without mutation"

# A canonical transfer with the wrong source repository identity is not safe.
D=$(consumer transfer-wrong-id)
sed -i 's#hyperpolymath/standards/\.github#metadatastician/standards/\.github#' "$D/caller.yml"
sed -i 's/repo_id: 1116521501/repo_id: 999999999/' "$D/actions.lock"
cp "$D/actions.lock" "$T/identity-transfer-before"
if bash "$RELOCK" --to "$NEW" --standards "$S" "$D" >"$T/identity-transfer-log" 2>&1; then fail "wrong transferred repository ID accepted"; fi
cmp -s "$D/actions.lock" "$T/identity-transfer-before" || fail "wrong identity modified lock"
grep -q 'repository ID mismatch' "$T/identity-transfer-log" || fail "wrong identity not diagnosed"
echo "  PASS wrong transferred repository identity refused"

echo "PASS: relock-standards-pin.sh"
