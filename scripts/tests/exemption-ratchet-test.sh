#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves check-exemption-ratchet.sh CAN FAIL, and fails for the right reasons.
#
# This estate's recurring defect is the gate that cannot fail — `just proof-check`
# recipes exiting 0 with no prover installed, `continue-on-error` on the primary
# secret scanner, a linter that never parsed its input. A ratchet that always
# passes would be worse than no ratchet, because it would license exactly the
# silent growth it claims to prevent. So every branch is exercised here, in both
# directions.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-exemption-ratchet.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"; git init -q .; git config user.email t@example.com; git config user.name T

# Reproduce the adoption case that exposed the defect: a repository already
# has many anonymous legacy entries. Unrelated work must not be blocked merely
# because those values predate the ratchet; only a new or changed anonymous
# value is a violation.
jq -n '[range(0; 44) | {
  severity: "medium",
  rule_module: "legacy",
  type: ("legacy-" + tostring),
  file: ("legacy-" + tostring + ".rs")
}] + [{
  severity: "high",
  rule_module: "m",
  type: "t",
  file: "a.rs",
  note: "why"
}]' > .hypatia-baseline.json
printf 'cicd_rules/banned_language_file:src/A.res\n' > .hypatia-ignore
git add -A; git commit -q -m base
BASE="$(git rev-parse HEAD)"

pass=0; fail=0
expect() { # expect <wanted-exit> <label>
  local want="$1" label="$2" got=0
  bash "$SCRIPT" "$BASE" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $label"
  else fail=$((fail+1)); echo "  FAIL  $label (wanted exit $want, got $got)"; fi
}

expect 0 "44 unchanged anonymous legacy entries pass"

# jq, not an interpreter: estate policy bans Python, and the JS runtime has
# already moved once. jq is what the rest of the estate's CI already uses.
jq '. + [{"severity":"low","rule_module":"m","type":"t2","file":"b.rs","note":"ok","expires_at":"2027-06-30"}]' \
   .hypatia-baseline.json > .baseline.tmp && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "grow"
expect 1 "silent growth fails"

git commit -q --amend -m "grow

Ratchet-exception: .hypatia-baseline.json — vendored upstream corpus"
expect 0 "declared growth passes"

# A declared exception licenses the GROWTH, not an undated acknowledgement.
# Without this the escape hatch would be a way to add permanent debt with a
# sentence of prose, which is the state the expiry rule exists to end.
git checkout -q "$BASE" -- .hypatia-baseline.json
jq '. + [{"severity":"low","rule_module":"m","type":"t4","file":"d.rs","note":"undated"}]' \
   .hypatia-baseline.json > .baseline.tmp && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "grow undated

Ratchet-exception: .hypatia-baseline.json — declared"
expect 1 "declared growth of an UNDATED entry still fails"

# ...and the date must be a date you could defend: in the past is a re-ack of
# nothing, and beyond the horizon defers the decision instead of dating it.
git checkout -q "$BASE" -- .hypatia-baseline.json
jq '. + [{"severity":"low","rule_module":"m","type":"t5","file":"e.rs","note":"stale","expires_at":"2020-01-01"}]' \
   .hypatia-baseline.json > .baseline.tmp && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "grow stale

Ratchet-exception: .hypatia-baseline.json — declared"
expect 1 "an entry dated in the PAST fails"

git checkout -q "$BASE" -- .hypatia-baseline.json
jq '. + [{"severity":"low","rule_module":"m","type":"t6","file":"f.rs","note":"forever","expires_at":"2199-01-01"}]' \
   .hypatia-baseline.json > .baseline.tmp && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "grow forever

Ratchet-exception: .hypatia-baseline.json — declared"
expect 1 "an entry dated beyond the horizon fails"

# Re-acking means a NEW date: pushing an existing entry's date further out is
# indistinguishable from keeping it forever unless the entry is re-verified,
# so a past date on an existing entry must not be grandfathered either.
git checkout -q "$BASE" -- .hypatia-baseline.json
jq '.[-1].expires_at = "2020-01-01"' .hypatia-baseline.json > .baseline.tmp \
  && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "expire a dated entry retroactively"
expect 1 "setting an existing entry's date into the past fails"

jq '. + [{"severity":"low","rule_module":"m","type":"t3","file":"c.rs"}]' \
   .hypatia-baseline.json > .baseline.tmp && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "anonymous

Ratchet-exception: .hypatia-baseline.json — declared"
expect 1 "anonymous entry fails even when growth is declared"

# Multiset semantics matter: one grandfathered value must not license an
# unlimited number of identical copies.
git checkout -q "$BASE" -- .hypatia-baseline.json .hypatia-ignore
jq '. + [.[0]]' .hypatia-baseline.json > .baseline.tmp \
  && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "duplicate anonymous legacy entry

Ratchet-exception: .hypatia-baseline.json — duplicate-control fixture"
expect 1 "appending a duplicate anonymous entry fails"

# A same-size rewrite is still new anonymous debt: comparing counts alone
# misses it. Full-value comparison must see the modified value.
git checkout -q "$BASE" -- .hypatia-baseline.json .hypatia-ignore
jq '.[0].severity = "high"' .hypatia-baseline.json > .baseline.tmp \
  && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "modify anonymous legacy entry"
expect 1 "modified anonymous entry fails without ledger growth"

# Documentation is debt reduction. Although the JSON value changed, its new
# form is no longer anonymous and therefore must pass -- but the same edit is
# now also the moment the entry gets a date. Requiring the date HERE is the
# whole adoption strategy: 23 undated entries in this repository became 0 not
# by a migration campaign but by making the next hand that touched one date it.
git checkout -q "$BASE" -- .hypatia-baseline.json .hypatia-ignore
jq '.[0].note = "legacy finding documented when touched"' \
  .hypatia-baseline.json > .baseline.tmp && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "document legacy entry"
expect 1 "documenting a legacy entry without dating it now fails"

git checkout -q "$BASE" -- .hypatia-baseline.json .hypatia-ignore
jq '.[0].note = "legacy finding documented when touched" | .[0].expires_at = "2027-06-30"' \
  .hypatia-baseline.json > .baseline.tmp && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "document and date legacy entry"
expect 0 "documenting a legacy anonymous entry AND dating it passes"

# Removing grandfathered debt is always allowed.
git checkout -q "$BASE" -- .hypatia-baseline.json .hypatia-ignore
jq 'del(.[0])' .hypatia-baseline.json > .baseline.tmp \
  && mv .baseline.tmp .hypatia-baseline.json
git commit -aqm "remove legacy entry"
expect 0 "deleting a legacy anonymous entry passes"

git checkout -q "$BASE" -- .hypatia-baseline.json
printf 'cicd_rules/banned_language_file:src/**\n' > .hypatia-ignore
git commit -aqm "wildcard"
expect 1 "wildcard in the migration ledger fails"

git checkout -q "$BASE" -- .hypatia-ignore
: > .hypatia-ignore
git commit -aqm "paid down"
expect 0 "shrinking passes"

# ⚠ A ledger emptied of entries but still carrying its explanatory header is
# the state a repository reaches when it has finished paying its debt down —
# the SUCCESS case. grep exits 1 on no match, and under `set -euo pipefail`
# that killed the script mid-report with exit 1, i.e. "ratchet FAILED", for a
# repository that had done exactly the right thing. The original test suite
# missed it because every case it exercised left at least one live entry.
printf '# ledger header, no entries left\n# all debt paid down\n' > .hypatia-ignore
git commit -aqm "comments-only ledger"
expect 0 "comments-only ledger passes (grep no-match must not abort)"

: > .hypatia-ignore
git commit -aqm "empty ledger"
expect 0 "completely empty ledger passes"

# ⚠ A declaration naming ONE ledger must not license growth in the others. A
# bare exception previously permitted all four at once, so a PR that
# legitimately added a gitleaks path silently gained permission to grow the
# Hypatia baseline too.
git checkout -q "$BASE" -- .hypatia-baseline.json .hypatia-ignore
printf 'cicd_rules/banned_language_file:src/A.res\ncicd_rules/banned_language_file:src/B.res\n' > .hypatia-ignore
git commit -aqm "grow the migration ledger

Ratchet-exception: .hypatia-baseline.json — wrong ledger named"
expect 1 "exception naming a DIFFERENT ledger does not license this one"

git commit -q --amend -m "grow the migration ledger

Ratchet-exception: .hypatia-ignore — correct ledger named"
expect 0 "exception naming THIS ledger licenses it"

# A declaration is found however many declaration lines the messages carry.
# declared_for read `printf … | grep -iE '^Ratchet-exception' | grep -qF LEDGER`
# under pipefail: with the matching line first and more than a pipe buffer of
# declarations, grep -q exited, the filter died of SIGPIPE, the pipeline
# reported 141 and a declared growth read as undeclared (a false block).
git checkout -q "$BASE" -- .hypatia-baseline.json .hypatia-ignore
printf 'cicd_rules/banned_language_file:src/A.res\ncicd_rules/banned_language_file:src/C.res\n' > .hypatia-ignore
{ printf 'grow the migration ledger\n\n'
  for i in $(seq 1 3000); do printf 'Ratchet-exception: .hypatia-ignore — declared reason number %d\n' "$i"; done
} > "$WORK/long-msg"
git commit -aq -F "$WORK/long-msg"
for run in 1 2 3 4 5; do
  expect 0 "a declaration among ~180 KB of declaration lines licenses growth (run $run)"
done


# ⚠ A wildcard on an early line of a LARGE migration ledger must still fail.
# The check used to read `grep -vE … .hypatia-ignore | grep -q '\*\*'` under
# `set -o pipefail`: grep -q exits at its first match, the filter still writing
# the rest of a file above the 64 KiB pipe buffer dies of SIGPIPE, the pipeline
# reports 141, and the wildcard read as absent, so the gate passed. Same entry
# count at both refs, so only the wildcard rule can fail it; five runs, because
# the old form lost the race on almost every run, not every one.
git checkout -q "$BASE" -- .hypatia-baseline.json
seq 1 6000 | sed 's|^|cicd_rules/banned_language_file:src/legacy/module-number-|; s|$|.res|' > .hypatia-ignore
git add -A; git commit -qm "large ledger, no wildcard"
BASE="$(git rev-parse HEAD)"
sed -i '1s|.*|cicd_rules/banned_language_file:docs/**|' .hypatia-ignore
git commit -aqm "large ledger, wildcard on line 1"
for run in 1 2 3 4 5; do
  expect 1 "wildcard on line 1 of a ledger above the pipe buffer fails (run $run)"
done
echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" = "0" ]
