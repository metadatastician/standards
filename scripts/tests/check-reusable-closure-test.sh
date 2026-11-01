#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Regression corpus for scripts/check-reusable-closure.sh.
#
# Every case is built from whole cloth in a throwaway directory and resolved
# from a CACHE directory, so the suite is offline, deterministic, and never
# reaches the network. The two shapes it must accept are the ones measured in
# the estate; the failures it must catch are the ones no other gate can see.
#
# Usage: bash scripts/tests/check-reusable-closure-test.sh
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF/../../scripts/check-reusable-closure.sh"
[ -f "$GUARD" ] || { echo "FAIL: guard not found at $GUARD"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
ok()   { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

SHA_A=$(printf 'a%.0s' {1..40})   # the reusable pin
SHA_B=$(printf 'b%.0s' {1..40})   # actions/checkout
SHA_C=$(printf 'c%.0s' {1..40})   # a second-level reusable
SHA_D=$(printf 'd%.0s' {1..40})   # reached only at depth 2
CICD=hyperpolymath/cicd-suite
STD=metadatastician/standards

# ── a cache that answers for the callee repositories ────────────────────────
CACHE="$tmp/cache"
cache_put() {  # $1 owner, $2 repo, $3 ref, $4 path, $5 body
  local p="$CACHE/$1/$2/$3/$(printf '%s' "$4" | tr '/' '_')"
  mkdir -p "$(dirname "$p")"; printf '%s\n' "$5" >"$p"
}
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/secret-scanner-reusable.yml \
'name: Secret Scanner
on: workflow_call
jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@'"$SHA_B"'
  rust-secrets:
    uses: hyperpolymath/cicd-suite/.github/workflows/nested.yml@'"$SHA_C"'
'
cache_put hyperpolymath cicd-suite "$SHA_C" .github/workflows/nested.yml \
'name: nested
on: workflow_call
jobs:
  inner:
    runs-on: ubuntu-latest
    steps:
      - uses: hyperpolymath/setup-rust@'"$SHA_D"'
'

# new_tree NAME: an empty repository skeleton with a lockfile header.
new_tree() {
  local d="$tmp/$1"
  mkdir -p "$d/.github/workflows"
  printf "version: 'v0.0.3'\nworkflows:\ndependencies:\n" >"$d/.github/workflows/actions.lock"
  printf '%s\n' "$d"
}

caller() {  # $1 tree, $2 ref
  cat >"$1/.github/workflows/secret-scanner.yml" <<YAML
name: Secret Scanner
on: [push]
jobs:
  scan:
    uses: $CICD/.github/workflows/secret-scanner-reusable.yml@$2
YAML
}

run_guard() {  # $1 tree, rest: args
  local d="$1"; shift
  ( cd "$d" && bash "$GUARD" .github/workflows --cache "$CACHE" --offline "$@" >"$tmp/out" 2>&1 )
}

expect() {  # $1 label, $2 wanted rc, rest: guard args (tree first)
  local label=$1 want=$2; shift 2
  local got=0
  run_guard "$@" || got=$?
  if [ "$got" -eq "$want" ]; then ok "$label (exit $got)"; else
    printf '%s\n' "---- output ----"; tail -12 "$tmp/out"; printf '%s\n' "----------------"
    bad "$label: wanted exit $want, got $got"
  fi
}

expect_msg() {  # $1 label, $2 needle
  if grep -qF -- "$2" "$tmp/out"; then ok "$1"; else
    printf '%s\n' "---- output ----"; tail -12 "$tmp/out"; printf '%s\n' "----------------"
    bad "$1: output does not contain: $2"
  fi
}

# ── 1. the estate shape: the through-ref lives in the reusable record ───────
d=$(new_tree estate); caller "$d" "$SHA_A"
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml':
dependencies:
    '$CICD@$SHA_A':
        ref: '$SHA_A'
        commit: 'sha1-$SHA_A'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'actions/checkout@$SHA_B'
            - 'hyperpolymath/setup-rust@$SHA_D'
YAML
printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
  ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "actions/checkout@$SHA_B" \
  ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "hyperpolymath/setup-rust@$SHA_D" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'the estate shape passes: a reusable record carrying its own uses:' 0 "$d"
expect_msg 'the reusable pin is reported as accepted, not silently ignored' "reaches it as a reusable at that commit"

# ── 2. the unified-dataset-vocab#81 shape: through-ref on the CALLER entry,
#      no reusable record at all. This is the gate reconciliation case. ─────
d=$(new_tree udv); caller "$d" "$SHA_A"
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml':
        - 'actions/checkout@$SHA_B'
        - 'hyperpolymath/setup-rust@$SHA_D'
dependencies:
    'actions/checkout@$SHA_B':
        ref: 'v7.0.1'
        commit: 'sha1-$SHA_B'
        owner_id: 44036562
        repo_id: 197814629
    'hyperpolymath/setup-rust@$SHA_D':
        ref: 'v1.2.3'
        commit: 'sha1-$SHA_D'
        owner_id: 6759885
        repo_id: 999
YAML
printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
  ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "actions/checkout@$SHA_B" \
  ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "hyperpolymath/setup-rust@$SHA_D" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'the udv#81 shape passes: through-refs on the calling entry, no reusable record' 0 "$d"
expect_msg 'an absent job-level reusable record is reported as allowed, with the measurement' 'not in this entry (allowed'

# ── 3. depth 2 is included: the second-level reusable's action must be
#      recorded too, or the closure is under-collected. ───────────────────
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml':
        - 'actions/checkout@$SHA_B'
dependencies:
    'actions/checkout@$SHA_B':
        ref: 'v7.0.1'
        commit: 'sha1-$SHA_B'
        owner_id: 44036562
        repo_id: 197814629
YAML
expect 'a ref reached at depth 2 and recorded nowhere is a failure' 1 "$d"
expect_msg 'the depth-2 miss names the ref' "hyperpolymath/setup-rust@$SHA_D"

# ── 3b. two DIFFERENT reusable files called at the SAME repo@ref are two
#       different closures. Collapsing them under one key under-collects. ────
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/second-reusable.yml \
'name: second
on: workflow_call
jobs:
  s:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/build-push-action@'"$SHA_D"'
'
d=$(new_tree twocalls)
cat >"$d/.github/workflows/both.yml" <<YAML
name: both
on: [push]
jobs:
  a:
    uses: $CICD/.github/workflows/secret-scanner-reusable.yml@$SHA_A
  b:
    uses: $CICD/.github/workflows/second-reusable.yml@$SHA_A
YAML
printf "version: 'v0.0.3'\nworkflows:\n    '.github/workflows/both.yml':\n        - 'actions/checkout@$SHA_B'\n        - 'docker/build-push-action@$SHA_D'\n        - 'hyperpolymath/setup-rust@$SHA_D'\ndependencies:\n" >"$d/.github/workflows/actions.lock"
printf '' >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'two reusable files at one repo@ref both contribute their closure' 0 "$d" --write-baseline
grep -q "docker/build-push-action@$SHA_D" "$d/.github/workflows/actions-lock.closure.tsv" \
  && ok 'the second file at the same ref was not dropped by cycle detection' \
  || bad 'cycle detection collapsed two files at the same repo@ref'

# ── 4. dropped closure: the call AND its record removed together. Nothing
#      dangles, the sync gate is green — only the reviewed baseline knows. ──
d=$(new_tree dropped); caller "$d" "$SHA_A"
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml':
        - 'actions/checkout@$SHA_B'
        - 'hyperpolymath/setup-rust@$SHA_D'
dependencies:
    'actions/checkout@$SHA_B':
        ref: 'v7.0.1'
        commit: 'sha1-$SHA_B'
        owner_id: 44036562
        repo_id: 197814629
    'hyperpolymath/setup-rust@$SHA_D':
        ref: 'v1.2.3'
        commit: 'sha1-$SHA_D'
        owner_id: 6759885
        repo_id: 999
YAML
# The ghost row is a dependency a previous review saw reached. Someone deleted
# the call site and the record in one commit; the lock is still closed.
cat >"$d/.github/workflows/actions-lock.closure.tsv" <<YAML
# reviewed closure
.github/workflows/secret-scanner.yml	$CICD@$SHA_A	actions/checkout@$SHA_B
.github/workflows/secret-scanner.yml	$CICD@$SHA_A	hyperpolymath/setup-rust@$SHA_D
.github/workflows/secret-scanner.yml	$CICD@$SHA_A	hyperpolymath/ghost-action@$(printf 'e%.0s' {1..40})
YAML
expect 'an edge and its target dropped together are caught by the baseline' 1 "$d"
expect_msg 'the dropped closure names what went missing' 'DROPPED CLOSURE'

# ── 5. malformed ref representations ───────────────────────────────────────
MAL="$(new_tree malformed)"
caller "$MAL" "main"
printf '%s\n' ".github/workflows/secret-scanner.yml	$CICD@main	actions/checkout@$SHA_B" \
  >"$MAL/.github/workflows/actions-lock.closure.tsv"
expect 'a branch ref on a job-level reusable call is refused' 1 "$MAL"
expect_msg 'the branch refusal says why it cannot be verified' 'is not SHA-pinned'

caller "$MAL" "$SHA_A"
cat >"$MAL/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml':
dependencies:
    '$CICD@$SHA_A':
        ref: 'v1.0.0'
        commit: 'sha1-$SHA_A'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'actions/checkout@$SHA_B'
            - 'hyperpolymath/setup-rust@$SHA_D'
YAML
expect 'a reusable record whose ref is not the requested ref is refused' 1 "$MAL"
expect_msg 'the ref-rewrite refusal names both values' "but the caller named '$SHA_A'"

# a leaf record carrying its own SHA as ref (the standards#1271 defect)
cat >"$MAL/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml':
        - 'actions/checkout@$SHA_B'
dependencies:
    'actions/checkout@$SHA_B':
        ref: '$SHA_B'
        commit: 'sha1-$SHA_B'
        owner_id: 44036562
        repo_id: 197814629
    '$CICD@$SHA_A':
        ref: '$SHA_A'
        commit: 'sha1-$SHA_A'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'actions/checkout@$SHA_B'
            - 'hyperpolymath/setup-rust@$SHA_D'
YAML
expect 'a leaf record whose ref repeats its own SHA is refused' 1 "$MAL"
expect_msg 'the self-SHA refusal names the runner error and the cure' "invalid lockfile pin"

# ── 6. a step-level ref missing from the calling entry ─────────────────────
d=$(new_tree stepmiss); caller "$d" "$SHA_A"
cat >>"$d/.github/workflows/secret-scanner.yml" <<'YAML'
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      - uses: reviewdog/action-shellcheck@cccccccccccccccccccccccccccccccccccccccc
YAML
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml':
        - 'actions/checkout@$SHA_B'
dependencies:
    'actions/checkout@$SHA_B':
        ref: 'v7.0.1'
        commit: 'sha1-$SHA_B'
        owner_id: 44036562
        repo_id: 197814629
YAML
printf '%s\t%s\t%s\n' ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "actions/checkout@$SHA_B" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'a step-level ref absent from the calling entry is refused' 1 "$d"
expect_msg 'the step-level refusal names the ref' 'reviewdog/action-shellcheck@'

# ── 7. not-inspected states are exit 2, never 0 ────────────────────────────
d=$(new_tree nobaseline); caller "$d" "$SHA_A"
expect 'a missing reviewed baseline is NOT INSPECTED, not a pass' 2 "$d"
expect_msg 'the missing baseline says how to create it' '--write-baseline'

d=$(new_tree nocache); caller "$d" "$SHA_C"   # cached only for .github/workflows/nested.yml
printf '%s\n' ".github/workflows/secret-scanner.yml	$CICD@$SHA_A	actions/checkout@$SHA_B" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'an unreadable callee is NOT INSPECTED, not a closed closure' 2 "$d"
expect_msg 'the unreadable callee is named' 'could not be read at'

mkdir -p "$d/empty"; printf 'version: v0.0.3\nworkflows:\ndependencies:\n' >"$d/empty/actions.lock"
  printf '' >"$d/empty/actions-lock.closure.tsv"
got=0; ( cd "$d" && bash "$GUARD" empty --cache "$CACHE" --offline >"$tmp/out" 2>&1 ) || got=$?
[ "$got" -eq 0 ] && ok 'a directory with no remote reusable call is a stated vacuous pass' \
  || bad "vacuous population: wanted 0, got $got"

d=$(new_tree unparsable)
printf 'jobs: [unclosed\n' >"$d/.github/workflows/broken.yml"
printf 'version: v0.0.3\nworkflows:\ndependencies:\n' >"$d/.github/workflows/actions.lock"
printf '' >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'an unparsable workflow is a failure, not a silent skip' 1 "$d"
expect_msg 'the parse failure is named' 'does not parse as YAML'

# ── 8. --write-baseline records what was reviewed, and removing a row is the
#      only way to change it ───────────────────────────────────────────────
d=$(new_tree writebase); caller "$d" "$SHA_A"
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml':
        - 'actions/checkout@$SHA_B'
        - 'hyperpolymath/setup-rust@$SHA_D'
dependencies:
    'actions/checkout@$SHA_B':
        ref: 'v7.0.1'
        commit: 'sha1-$SHA_B'
        owner_id: 44036562
        repo_id: 197814629
    'hyperpolymath/setup-rust@$SHA_D':
        ref: 'v1.2.3'
        commit: 'sha1-$SHA_D'
        owner_id: 6759885
        repo_id: 999
YAML
got=0; run_guard "$d" --write-baseline || got=$?
[ "$got" -eq 0 ] && ok "--write-baseline exits 0 after recording the closure" \
  || { tail -8 "$tmp/out"; bad "--write-baseline: wanted 0, got $got"; }
grep -q "actions/checkout@$SHA_B" "$d/.github/workflows/actions-lock.closure.tsv" \
  && ok 'the written baseline contains the resolved edge' \
  || bad 'the written baseline is missing the resolved edge'
expect 'the written baseline reproduces on the next run' 0 "$d"

# ── 8. a FLOATING ref reached through a pinned reusable is still a float ──
#      The recursion applied the immutability rule only at top level, so a
#      SHA-pinned callee could call another reusable at a branch and the
#      closure would describe whatever that branch pointed at today.
d=$(new_tree nestedfloat); caller "$d" "$SHA_A"
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/floaty.yml \
'name: floaty
on: workflow_call
jobs:
  f:
    uses: hyperpolymath/cicd-suite/.github/workflows/nested.yml@main
'
cat >"$d/.github/workflows/secret-scanner.yml" <<YAML
name: Secret Scanner
on: [push]
jobs:
  scan:
    uses: $CICD/.github/workflows/floaty.yml@$SHA_A
YAML
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml': []
dependencies:
    '$CICD@$SHA_A':
        ref: '$SHA_A'
        commit: 'sha1-$SHA_A'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'actions/checkout@$SHA_B'
YAML
printf '%s\t%s\t%s\n' ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "actions/checkout@$SHA_B" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'a nested reusable called at a branch is rejected' 1 "$d"
expect_msg 'the nested float is named, and says why it matters' 'nested job-level uses'
cp "$d/.github/workflows/actions-lock.closure.tsv" "$tmp/nestedfloat-baseline.tsv"
expect 'an aborted nested walk refuses to write the baseline' 1 "$d" --write-baseline
expect_msg 'the incomplete traversal explains why the baseline was preserved' 'traversal was incomplete'
if cmp -s "$tmp/nestedfloat-baseline.tsv" "$d/.github/workflows/actions-lock.closure.tsv"; then
  ok 'an aborted nested walk leaves the existing baseline unchanged'
else
  bad 'an aborted nested walk changed the existing baseline'
fi

# ── 9. a nested callee's LOCK RECORD must carry the ref that was named ────
d=$(new_tree nestedref); caller "$d" "$SHA_A"
cat >"$d/.github/workflows/secret-scanner.yml" <<YAML
name: Secret Scanner
on: [push]
jobs:
  scan:
    uses: $CICD/.github/workflows/secret-scanner-reusable.yml@$SHA_A
YAML
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml': []
dependencies:
    '$CICD@$SHA_A':
        ref: '$SHA_A'
        commit: 'sha1-$SHA_A'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'actions/checkout@$SHA_B'
            - 'hyperpolymath/setup-rust@$SHA_D'
    '$CICD@$SHA_C':
        ref: 'v2.0.0'
        commit: 'sha1-$SHA_C'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'hyperpolymath/setup-rust@$SHA_D'
YAML
printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
  ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "actions/checkout@$SHA_B" \
  ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "hyperpolymath/setup-rust@$SHA_D" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'a nested record whose ref was rewritten to a tag is rejected' 1 "$d"
expect_msg 'the rewritten nested ref is named' "carries ref: 'v2.0.0'"
cp "$d/.github/workflows/actions-lock.closure.tsv" "$tmp/nestedref-baseline.tsv"
expect 'a nested record/ref mismatch refuses to write the baseline' 1 "$d" --write-baseline
expect_msg 'the mismatched nested record explains why the baseline was preserved' 'traversal was incomplete'
if cmp -s "$tmp/nestedref-baseline.tsv" "$d/.github/workflows/actions-lock.closure.tsv"; then
  ok 'a nested record/ref mismatch leaves the existing baseline unchanged'
else
  bad 'a nested record/ref mismatch changed the existing baseline'
fi

# ── 10. a LOCAL call inside a remote reusable belongs to the CALLEE repo ──
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/local-caller.yml \
'name: local caller
on: workflow_call
jobs:
  l:
    uses: ./.github/workflows/helper.yml
'
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/helper.yml \
'name: helper
on: workflow_call
jobs:
  h:
    runs-on: ubuntu-latest
    steps:
      - uses: hyperpolymath/setup-rust@'"$SHA_D"'
'
d=$(new_tree localnested)
cat >"$d/.github/workflows/secret-scanner.yml" <<YAML
name: Secret Scanner
on: [push]
jobs:
  scan:
    uses: $CICD/.github/workflows/local-caller.yml@$SHA_A
YAML
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml': []
dependencies:
    '$CICD@$SHA_A':
        ref: '$SHA_A'
        commit: 'sha1-$SHA_A'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'hyperpolymath/setup-rust@$SHA_D'
YAML
printf '%s\t%s\t%s\n' ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "hyperpolymath/setup-rust@$SHA_D" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'a local call inside a remote reusable is traversed, not dropped' 0 "$d"

# ...and it is genuinely traversed: remove the dependency and the miss appears.
sed -i "/setup-rust/d" "$d/.github/workflows/actions.lock"
printf '# empty\n' >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'the local nested call really contributed its dependency (miss is caught)' 1 "$d"
expect_msg 'the dependency reached through the local call is named' "hyperpolymath/setup-rust@$SHA_D"

# ── 11. two top-level calls reaching the SAME nested file are two edges ───
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/first.yml \
'name: first
on: workflow_call
jobs:
  a:
    uses: hyperpolymath/cicd-suite/.github/workflows/nested.yml@'"$SHA_C"'
'
SHA_E=$(printf 'e%.0s' {1..40})   # a second top-level pin, same nested callee
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/first.yml \
'name: first
on: workflow_call
jobs:
  a:
    uses: hyperpolymath/cicd-suite/.github/workflows/nested.yml@'"$SHA_C"'
'
cache_put hyperpolymath cicd-suite "$SHA_E" .github/workflows/second2.yml \
'name: second
on: workflow_call
jobs:
  b:
    uses: hyperpolymath/cicd-suite/.github/workflows/nested.yml@'"$SHA_C"'
'
d=$(new_tree twotops)
cat >"$d/.github/workflows/secret-scanner.yml" <<YAML
name: Secret Scanner
on: [push]
jobs:
  scan:
    uses: $CICD/.github/workflows/first.yml@$SHA_A
  scan2:
    uses: $CICD/.github/workflows/second2.yml@$SHA_E
YAML
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml': []
dependencies:
    '$CICD@$SHA_A':
        ref: '$SHA_A'
        commit: 'sha1-$SHA_A'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'hyperpolymath/setup-rust@$SHA_D'
    '$CICD@$SHA_E':
        ref: '$SHA_E'
        commit: 'sha1-$SHA_E'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'hyperpolymath/setup-rust@$SHA_D'
    '$CICD@$SHA_C':
        ref: '$SHA_C'
        commit: 'sha1-$SHA_C'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'hyperpolymath/setup-rust@$SHA_D'
YAML
got=0; run_guard "$d" --write-baseline || got=$?
[ "$got" -eq 0 ] && ok 'two top-level calls reaching one nested file both resolve' \
  || { tail -8 "$tmp/out"; bad "two-top-level: wanted 0, got $got"; }
tops="$(awk -F'\t' '$1 !~ /^#/ && $3 ~ /setup-rust/ {print $2}' "$d/.github/workflows/actions-lock.closure.tsv" | sort -u | wc -l)"
[ "$tops" -eq 2 ] && ok 'both top-level edges are attributed to the shared nested file (not one)' \
  || bad "the shared nested file was attributed to $tops top-level edge(s), expected 2"
# The nested record's ref repeats its own SHA and no workflow calls it at top
# level: that must be ACCEPTED (it is the nested form of the same thing), not
# reported as the runner-invalid leaf shape.
if grep -q "repeats the record's own SHA" "$tmp/out"; then
  bad 'a nested reusable record was reported as a leaf raw-SHA defect'
else
  ok 'a nested reusable record whose ref repeats its SHA is accepted'
fi

# ── 12. the baseline is compared in BOTH directions ──────────────────────
#      A new remote edge recorded only in the lock is a change to what this
#      repository trusts; comparing only "did any reviewed row disappear" let
#      it through unreviewed.
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/simple.yml \
'name: simple
on: workflow_call
jobs:
  s:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@'"$SHA_B"'
'
d=$(new_tree reverse)
cat >"$d/.github/workflows/secret-scanner.yml" <<YAML
name: Secret Scanner
on: [push]
jobs:
  scan:
    uses: $CICD/.github/workflows/simple.yml@$SHA_A
YAML
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml':
        - 'actions/checkout@$SHA_B'
dependencies:
    'actions/checkout@$SHA_B':
        ref: 'v7.0.1'
        commit: 'sha1-$SHA_B'
        owner_id: 44036562
        repo_id: 197814629
YAML
printf '%s\t%s\t%s\n' ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "actions/checkout@$SHA_B" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'a reviewed baseline reproduces' 0 "$d"
# the same tree, with the reviewed row removed: the edge is now unreviewed
printf '# reviewed closure removed by the reviewer\n' >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'an edge reached but absent from the baseline is a failure' 1 "$d"
expect_msg 'the unreviewed edge is named' 'UNREVIEWED CLOSURE'

# ── 13. an option without a value is UNINSPECTED, not an infinite loop ────
d=$(new_tree optnoval); caller "$d" "$SHA_A"
got=0; run_guard "$d" --depth || got=$?
[ "$got" -eq 2 ] && ok '--depth with no value exits 2 instead of looping' \
  || bad "--depth with no value: wanted 2, got $got"
got=0; run_guard "$d" --baseline || got=$?
[ "$got" -eq 2 ] && ok '--baseline with no value exits 2' \
  || bad "--baseline with no value: wanted 2, got $got"

# ── 14. a `uses:` that is an ACTION INPUT is not a workflow call ──────────
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/with-input.yml \
'name: with input
on: workflow_call
jobs:
  w:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@'"$SHA_B"'
        with:
          uses: hyperpolymath/not-a-call@'"$SHA_D"'
'
d=$(new_tree withinput)
cat >"$d/.github/workflows/secret-scanner.yml" <<YAML
name: Secret Scanner
on: [push]
jobs:
  scan:
    uses: $CICD/.github/workflows/with-input.yml@$SHA_A
YAML
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml': []
dependencies:
    '$CICD@$SHA_A':
        ref: '$SHA_A'
        commit: 'sha1-$SHA_A'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'actions/checkout@$SHA_B'
YAML
printf '%s\t%s\t%s\n' ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "actions/checkout@$SHA_B" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'a with:-input named uses: is not treated as a workflow call' 0 "$d"
if grep -qF "hyperpolymath/not-a-call@$SHA_D" "$d/.github/workflows/actions-lock.closure.tsv" 2>/dev/null; then
  bad 'the with:-input value leaked into the closure rows'
else
  ok 'the with:-input value never enters the closure'
fi

# ── 15. a following option is a MISSING value, not a value ───────────────
# `--cache --offline` consumed the option as a directory and left offline mode
# off: a run that asked to prohibit network access made network requests.
d=$(new_tree optflip); caller "$d" "$SHA_A"
got=0; run_guard "$d" --cache --offline || got=$?
[ "$got" -eq 2 ] && ok '--cache followed by --offline is a missing value (exit 2)' \
  || bad "--cache --offline: wanted 2, got $got"
got=0; run_guard "$d" --baseline --write-baseline || got=$?
[ "$got" -eq 2 ] && ok '--baseline followed by --write-baseline is a missing value (exit 2)' \
  || bad "--baseline --write-baseline: wanted 2, got $got"
got=0; run_guard "$d" --depth -1 || got=$?
[ "$got" -eq 2 ] && ok 'a negative --depth is refused (exit 2)' \
  || bad "--depth -1: wanted 2, got $got"

# ── 16. a local COMPOSITE ACTION inside a remote reusable is not a workflow ──
# `uses: ./.github/actions/setup` used to be rewritten to
# `owner/repo/.github/actions/setup@sha` — an invented edge to the repository
# itself — while the actions the composite actually runs went uncollected.
cache_put hyperpolymath cicd-suite "$SHA_A" .github/workflows/with-composite.yml \
'name: with composite
on: workflow_call
jobs:
  c:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup
'
cache_put hyperpolymath cicd-suite "$SHA_A" .github/actions/setup/action.yml \
'name: setup
runs:
  using: composite
  steps:
    - uses: actions/checkout@'"$SHA_B"'
    - uses: hyperpolymath/setup-rust@'"$SHA_D"'
'
d=$(new_tree composite)
cat >"$d/.github/workflows/secret-scanner.yml" <<YAML
name: Secret Scanner
on: [push]
jobs:
  scan:
    uses: $CICD/.github/workflows/with-composite.yml@$SHA_A
YAML
cat >"$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/secret-scanner.yml': []
dependencies:
    '$CICD@$SHA_A':
        ref: '$SHA_A'
        commit: 'sha1-$SHA_A'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'actions/checkout@$SHA_B'
            - 'hyperpolymath/setup-rust@$SHA_D'
YAML
printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
  ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "actions/checkout@$SHA_B" \
  ".github/workflows/secret-scanner.yml" "$CICD@$SHA_A" "hyperpolymath/setup-rust@$SHA_D" \
  >"$d/.github/workflows/actions-lock.closure.tsv"
expect 'a local composite action inside a remote reusable is traversed' 0 "$d"
if grep -qF "$CICD/.github/actions/setup@" "$d/.github/workflows/actions-lock.closure.tsv"; then
  bad 'the composite action path was invented as a reached dependency'
else
  ok 'the composite action is not recorded as a bogus edge to the repository'
fi
if grep -qF "hyperpolymath/setup-rust@$SHA_D" "$d/.github/workflows/actions-lock.closure.tsv"; then
  ok 'the action the composite runs is collected'
else
  bad 'the action the composite runs is missing from the closure'
fi
# ...and an unreadable composite is UNRESOLVED, never silently empty.
rm -rf "$CACHE/hyperpolymath/cicd-suite/$SHA_A/.github_actions_setup_action.yml"
got=0; run_guard "$d" || got=$?
[ "$got" -eq 2 ] && ok 'an unreadable composite action is NOT INSPECTED (exit 2)' \
  || bad "unreadable composite: wanted 2, got $got"
cache_put hyperpolymath cicd-suite "$SHA_A" .github/actions/setup/action.yml \
'name: setup
runs:
  using: composite
  steps:
    - uses: actions/checkout@'"$SHA_B"'
    - uses: hyperpolymath/setup-rust@'"$SHA_D"'
'

printf '\n%s\n' "check-reusable-closure: passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
