#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# complete-job-refs-test.sh — fixture suite for scripts/complete-job-refs.sh.
# The planted positive is a job-level reusable ref that `gh actions-lock`
# v0.1.6 does not write; the negatives are refs that must NOT be added (a
# comment, a local `./` reusable, a step-level action).
#
# Run: bash scripts/tests/complete-job-refs-test.sh
# TARGET=<path> runs the suite against another copy (used for mutant checks).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET:-$SCRIPT_DIR/../complete-job-refs.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
A=1111111111111111111111111111111111111111
S=5555555555555555555555555555555555555555

# ok: record and print a passing assertion.
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
# bad: record and print a failing assertion.
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
# run: execute the target inside fixture repo $1, capturing all output.
run() { (cd "$WORK/$1" && bash "$TARGET") 2>&1; }

# mkrepo: create fixture repo $1 with job-level, local, step-level and commented-out refs.
mkrepo() {
  local d="$WORK/$1/.github/workflows"; mkdir -p "$d"
  cat > "$d/ci.yml" <<EOF
jobs:
  call:
    uses: hyperpolymath/standards/.github/workflows/governance-reusable.yml@$S
  local:
    uses: ./.github/workflows/local.yml
  steps:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$A
      # uses: other/repo/.github/workflows/x.yml@$A
EOF
  printf 'jobs:\n  b:\n    uses: "o/r/.github/workflows/y.yml@v2"\n' > "$d/other.yml"
  printf 'jobs: {}\n' > "$d/local.yml"
}

echo "=== adds the job-level refs, and nothing else ==="
mkrepo t1
cat > "$WORK/t1/.github/workflows/actions.lock" <<EOF
version: 'v0.0.3'
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@$A'
    '.github/workflows/other.yml': []
dependencies:
    'actions/checkout@$A':
        ref: '$A'
EOF
out=$(run t1); st=$?
L="$WORK/t1/.github/workflows/actions.lock"
[ "$st" = 0 ] && grep -qxF "        - 'hyperpolymath/standards@$S'" "$L" && ok "job-level ref added (exit 0)" || bad "job-level ref added — st=$st $out"
grep -qxF "        - 'o/r@v2'" "$L" && ! grep -qF "    '.github/workflows/other.yml': []" "$L" \
  && ok "quoted ref fills an empty [] entry" || bad "quoted ref fills an empty [] entry"
! grep -qF 'other/repo' "$L" && ok "commented-out ref not added" || bad "commented-out ref not added"
! grep -qF "        - './.github/workflows/local.yml'" "$L" && ok "local ./ reusable not added as a dependency" || bad "local ./ reusable not added as a dependency"
grep -qxF "    '.github/workflows/local.yml': []" "$L" && ok "local callee receives an explicit empty workflow key" || bad "local callee receives an explicit empty workflow key"
[ "$(grep -cxF "        - 'actions/checkout@$A'" "$L")" = 1 ] && ok "existing step ref kept, not duplicated" || bad "existing step ref kept, not duplicated"
grep -qxF "        ref: '$A'" "$L" && ok "dependencies: section untouched" || bad "dependencies: section untouched"
cp "$L" "$WORK/t1.before"; out=$(run t1)
cmp -s "$L" "$WORK/t1.before" && grep -qF 'newly present in workflows section: 0' <<<"$out" \
  && ok "idempotent: second run changes nothing" || bad "idempotent: second run changes nothing — $out"

echo "=== a workflow with no lock entry gets one ==="
mkrepo t2
cat > "$WORK/t2/.github/workflows/actions.lock" <<EOF
version: 'v0.0.3'
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@$A'
dependencies:
EOF
run t2 >/dev/null
L="$WORK/t2/.github/workflows/actions.lock"
grep -qxF "    '.github/workflows/other.yml':" "$L" && grep -qxF "        - 'o/r@v2'" "$L" \
  && ok "missing workflow entry is created" || bad "missing workflow entry is created"
[ "$(sed -n '/^dependencies:/=' "$L")" -gt "$(sed -n "/other.yml/=" "$L")" ] \
  && ok "created entry stays inside workflows:" || bad "created entry stays inside workflows:"

echo "=== refs used through local composite actions (standards#1122) ==="
c="$WORK/comp"; mkdir -p "$c/.github/workflows" "$c/.github/actions/outer" "$c/.github/actions/inner"
cat > "$c/.github/workflows/ci.yml" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$A
      - uses: ./.github/actions/outer
EOF
printf '{ runs: { using: composite, steps: [\n  { uses: "o/direct@%s", },\n  { uses: ./.github/actions/inner, },\n  { uses: "docker://alpine:3", },\n], }, }\n' "$A" > "$c/.github/actions/outer/action.yml"
printf 'runs:\n  using: composite\n  steps:\n    - uses: o/nested/sub@%s # v1\n' "$S" > "$c/.github/actions/inner/action.yml"
printf "version: 'v0.0.3'\nworkflows:\n    '.github/workflows/ci.yml':\n        - 'actions/checkout@%s'\ndependencies:\n" "$A" > "$c/.github/workflows/actions.lock"
out=$(run comp)
grep -qxF "        - 'o/direct@$A'" "$c/.github/workflows/actions.lock" \
  && ok "a local composite's ref is added to the calling workflow (KYAML-quoted)" || bad "a local composite's ref is added — $out"
grep -qxF "        - 'o/nested@$S'" "$c/.github/workflows/actions.lock" \
  && ok "a nested composite's subpath ref is added as owner/repo@ref" || bad "a nested composite's subpath ref is added — $out"
! grep -qF "alpine" "$c/.github/workflows/actions.lock" \
  && ok "a docker:// use in a composite is not added" || bad "a docker:// use in a composite is not added"
cp "$c/.github/workflows/actions.lock" "$WORK/comp.before"; run comp >/dev/null
cmp -s "$c/.github/workflows/actions.lock" "$WORK/comp.before" \
  && ok "idempotent with composites" || bad "idempotent with composites"

echo "=== the local-composite block is the same in all three scripts ==="
block() { awk '/^# ── local composite actions \(identical block/{p=1} p{print} /^# ── end of the shared block/{exit}' "$1"; }
b1="$(block "$SCRIPT_DIR/../complete-job-refs.sh")"
if [ -n "$b1" ] && [ "$b1" = "$(block "$SCRIPT_DIR/../prune-stale.sh")" ] && [ "$b1" = "$(block "$SCRIPT_DIR/../check-lock-sync.sh")" ]; then
  ok "complete-job-refs, prune-stale and check-lock-sync agree on what a workflow reaches"
else
  bad "the local-composite block differs between complete-job-refs, prune-stale and check-lock-sync"
fi

helper() { awk -v name="$2() {" '$0 == name {p=1} p{print} p && /^}$/ {exit}' "$1"; }
for function in lock_yaml_json lock_uses; do
  expected="$(helper "$SCRIPT_DIR/../complete-job-refs.sh" "$function")"
  consistent=true
  for script in prune-stale check-lock-sync close-lock; do
    [ -n "$expected" ] && [ "$expected" = "$(helper "$SCRIPT_DIR/../$script.sh" "$function")" ] || consistent=false
  done
  "$consistent" && ok "$function agrees across all four readers" || bad "$function differs between readers"
done
expected="$(helper "$SCRIPT_DIR/../complete-job-refs.sh" lock_write_section)"
consistent=true
for script in prune-stale close-lock; do
  [ -n "$expected" ] && [ "$expected" = "$(helper "$SCRIPT_DIR/../$script.sh" lock_write_section)" ] || consistent=false
done
"$consistent" && ok "all three YAML section writers agree" || bad "YAML section writers differ"

echo "=== owner/repo case: an existing entry covers a differently cased uses: ==="
mkdir -p "$WORK/t5/.github/workflows"
printf 'jobs:\n  a:\n    runs-on: x\n    steps:\n      - uses: Swatinem/rust-cache@v2\n      - uses: o/r@V3\n' \
  > "$WORK/t5/.github/workflows/c.yml"
cat > "$WORK/t5/.github/workflows/actions.lock" <<EOF
version: 'v0.0.3'
workflows:
    '.github/workflows/c.yml':
        - 'o/r@v3'
        - 'swatinem/rust-cache@v2'
dependencies:
    'swatinem/rust-cache@v2':
        ref: 'v2'
EOF
run t5 >/dev/null; st=$?
L5="$WORK/t5/.github/workflows/actions.lock"
[[ "$st" = 0 ]] && grep -qxF "        - 'swatinem/rust-cache@v2'" "$L5" && ! grep -qF "'Swatinem/rust-cache@v2'" "$L5" \
  && ok "owner case differs only → existing entry kept, no second spelling" \
  || bad "owner case differs only → existing entry kept, no second spelling (st=$st)"
grep -qxF "        - 'o/r@V3'" "$L5" && grep -qxF "        - 'o/r@v3'" "$L5" \
  && ok "ref case differs → both refs kept (refs are case-sensitive)" \
  || bad "ref case differs → both refs kept (refs are case-sensitive)"

echo "=== a lock that already holds both spellings keeps the one with a record ==="
mkdir -p "$WORK/t6/.github/workflows"
cp "$WORK/t5/.github/workflows/c.yml" "$WORK/t6/.github/workflows/c.yml"
cat > "$WORK/t6/.github/workflows/actions.lock" <<EOF
version: 'v0.0.3'
workflows:
    '.github/workflows/c.yml':
        - 'Swatinem/rust-cache@v2'
        - 'o/r@v3'
        - 'swatinem/rust-cache@v2'
dependencies:
    'swatinem/rust-cache@v2':
        ref: 'v2'
EOF
run t6 >/dev/null; st=$?
L6="$WORK/t6/.github/workflows/actions.lock"
[[ "$st" = 0 ]] && grep -qxF "        - 'swatinem/rust-cache@v2'" "$L6" && ! grep -qF "'Swatinem/rust-cache@v2'" "$L6" \
  && ok "both spellings present → the dependency-backed one survives" \
  || bad "both spellings present → the dependency-backed one survives (st=$st)"

echo "=== a tag containing @ keeps its case (split at the first @) ==="
mkdir -p "$WORK/t7/.github/workflows"
printf 'jobs:\n  a:\n    runs-on: x\n    steps:\n      - uses: o/r@Release@2026\n' > "$WORK/t7/.github/workflows/c.yml"
cat > "$WORK/t7/.github/workflows/actions.lock" <<EOF
version: 'v0.0.3'
workflows:
    '.github/workflows/c.yml':
        - 'o/r@release@2026'
dependencies:
EOF
run t7 >/dev/null; st=$?
L7="$WORK/t7/.github/workflows/actions.lock"
[[ "$st" = 0 ]] && grep -qxF "        - 'o/r@Release@2026'" "$L7" && grep -qxF "        - 'o/r@release@2026'" "$L7" \
  && ok "o/r@Release@2026 and o/r@release@2026 are different refs → both kept" \
  || bad "o/r@Release@2026 and o/r@release@2026 are different refs → both kept (st=$st)"

echo "=== structural ==="
mkdir -p "$WORK/empty/.github/workflows"
printf 'jobs:\n  test:\n    steps:\n      - run: echo ok\n' > "$WORK/empty/.github/workflows/run.yml"
cp "$WORK/empty/.github/workflows/run.yml" "$WORK/empty/.github/workflows/callee.yml"
printf 'jobs:\n  child:\n    uses: ./.github/workflows/callee.yml\n' > "$WORK/empty/.github/workflows/caller.yml"
printf 'version: v0.0.3\nworkflows: {}\ndependencies: {}\n' > "$WORK/empty/.github/workflows/actions.lock"
run empty >/dev/null; st=$?
[ "$st" = 0 ] && yq -o=json '.' "$WORK/empty/.github/workflows/actions.lock" | jq -e '.workflows | length == 3 and all(.[]; . == [])' >/dev/null \
  && ok "run-only and local-only workflows receive empty keys from an empty generator map" \
  || bad "run-only and local-only workflows receive empty keys from an empty generator map"
bash "$SCRIPT_DIR/../check-lock-sync.sh" "$WORK/empty/.github/workflows" >/dev/null 2>&1; st=$?
[ "$st" = 0 ] && ok "the repair result satisfies the strict checker without manual lock edits" || bad "the repair result satisfies the strict checker without manual lock edits"
cp "$WORK/empty/.github/workflows/actions.lock" "$WORK/empty.before"
run empty >/dev/null
cmp -s "$WORK/empty.before" "$WORK/empty/.github/workflows/actions.lock" && ok "empty-key completion is idempotent" || bad "empty-key completion is idempotent"
for local_use in ./.github/actions/missing ./.github/workflows/missing.yml; do
  mkdir -p "$WORK/missing/.github/workflows"
  printf 'jobs:\n  a:\n    steps:\n      - uses: %s\n' "$local_use" > "$WORK/missing/.github/workflows/ci.yml"
  printf 'version: v0.0.3\nworkflows: {}\ndependencies: {}\n' > "$WORK/missing/.github/workflows/actions.lock"
  cp "$WORK/missing/.github/workflows/actions.lock" "$WORK/missing.before"
  run missing >/dev/null; st=$?
  [ "$st" != 0 ] && cmp -s "$WORK/missing.before" "$WORK/missing/.github/workflows/actions.lock" \
    && ok "missing local use refuses repair without changing the lock: $local_use" \
    || bad "missing local use was accepted or changed the lock: $local_use"
done
mkrepo t3; printf 'dependencies:\n' > "$WORK/t3/.github/workflows/actions.lock"
run t3 >/dev/null; st=$?
[ "$st" != 0 ] && grep -qxF 'dependencies:' "$WORK/t3/.github/workflows/actions.lock" \
  && ok "no workflows: section → non-zero, lock unchanged" || bad "no workflows: section → non-zero, lock unchanged (st=$st)"
mkdir -p "$WORK/t4/.github/workflows"; run t4 >/dev/null; st=$?
[ "$st" = 1 ] && ok "no lockfile → exit 1" || bad "no lockfile → exit 1 (got $st)"

d="$WORK/quoted/.github/workflows"; mkdir -p "$d"
printf 'jobs:\n  a:\n    steps:\n      - uses: "o/r@release\0472026"\n' > "$d/ci.yml"
printf 'jobs: {a: {steps: [{run: echo}]}}\n' > "$d/quote'name.yml"
cat > "$d/actions.lock" <<'EOF'
# SPDX-License-Identifier: MPL-2.0
version: v0.0.3
workflows: {}
dependencies:
  "o/r@release'2026": {ref: "release'2026", commit: sha1-1111111111111111111111111111111111111111, owner_id: 7, repo_id: 9}
EOF
run quoted >/dev/null; st=$?
[ "$st" = 0 ] && yq -o=json '.' "$d/actions.lock" | jq -e --arg ref "o/r@release'2026" --arg file ".github/workflows/quote'name.yml" '.workflows[".github/workflows/ci.yml"] == [$ref] and .workflows[$file] == []' >/dev/null \
  && ok "completion encodes apostrophes in references and workflow keys" || bad "completion corrupts quoted scalars"
bash "$SCRIPT_DIR/../check-lock-sync.sh" "$d" >/dev/null 2>&1; st=$?
[ "$st" = 0 ] && grep -q '^# SPDX-License-Identifier: MPL-2.0' "$d/actions.lock" \
  && ok "quoted completion preserves the header and satisfies the strict checker" || bad "quoted completion fails the strict checker or loses its header"
cp "$d/actions.lock" "$WORK/quoted.before"; run quoted >/dev/null
cmp -s "$WORK/quoted.before" "$d/actions.lock" && ok "quoted completion is byte-idempotent" || bad "quoted completion is not byte-idempotent"

d="$WORK/file-action/.github/workflows"; mkdir -p "$d" "$WORK/file-action/.github/actions"
printf 'runs: {}\n' > "$WORK/file-action/.github/actions/plain.yml"
printf 'jobs: {test: {steps: [{uses: ./.github/actions/plain.yml}]}}\n' > "$d/ci.yml"
printf 'version: v0.0.3\nworkflows: {}\ndependencies: {}\n' > "$d/actions.lock"
cp "$d/actions.lock" "$WORK/file-action.before"
run file-action >/dev/null; st=$?
[[ "$st" != 0 ]] && cmp -s "$WORK/file-action.before" "$d/actions.lock" \
  && ok "completion refuses a regular YAML file used as an action without rewriting" || bad "completion accepted a file without action metadata"

echo "complete-job-refs-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
