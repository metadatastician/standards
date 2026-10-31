#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# prune-stale-test.sh — fixture suite for scripts/prune-stale.sh. The planted
# positive is a stale per-workflow ref that must be dropped; the planted parser
# blind spot is a ref whose exact string survives only in a comment, which the
# parser cannot see and the literal-grep oracle must veto.
#
# Run: bash scripts/tests/prune-stale-test.sh
# TARGET=<path> runs the suite against another copy (used for mutant checks).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET:-$SCRIPT_DIR/../prune-stale.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
S=5555555555555555555555555555555555555555

# ok: record and print a passing assertion.
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
# bad: record and print a failing assertion.
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

d="$WORK/r/.github/workflows"; mkdir -p "$d"
cat > "$d/ci.yml" <<EOF
jobs:
  call:
    uses: hyperpolymath/standards/.github/workflows/governance-reusable.yml@$S
  a:
    steps:
      - uses: actions/checkout@$A # v6
      - uses: github/codeql-action/init@$B
EOF
cat > "$d/old.yml" <<'EOF'
jobs:
  a:
    steps:
      - run: true   # previously o/kept@v1
EOF
cat > "$d/actions.lock" <<EOF
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@$A'
        - 'actions/setup-node@$A'
        - 'github/codeql-action@$B'
        - 'hyperpolymath/standards@$S'
    '.github/workflows/old.yml':
        - 'o/gone@v1'
        - 'o/kept@v1'
    '.github/workflows/empty.yml':
        - 'o/gone@v1'
    '.github/workflows/retired.yml':
        - 'o/gone@v1'
    '.github/workflows/retired-empty.yml': []
dependencies:
    'actions/setup-node@$A':
        ref: '$A'
        commit: 'sha1-$A'
EOF
printf 'jobs:\n  a:\n    steps:\n      - run: true\n' > "$d/empty.yml"
L="$d/actions.lock"

out=$(cd "$WORK/r" && bash "$TARGET" 2>&1); st=$?
[ "$st" = 0 ] && ok "exit 0" || bad "exit 0 (got $st) — $out"
! grep -qF "        - 'actions/setup-node@$A'" "$L" && ok "stale step ref pruned (planted positive)" || bad "stale step ref pruned (planted positive)"
grep -qxF "        - 'actions/checkout@$A'" "$L" && ok "used step ref kept" || bad "used step ref kept"
grep -qxF "        - 'github/codeql-action@$B'" "$L" && ok "subpath ref (codeql-action/init) kept" || bad "subpath ref (codeql-action/init) kept"
grep -qxF "        - 'hyperpolymath/standards@$S'" "$L" && ok "job-level reusable ref kept" || bad "job-level reusable ref kept"
grep -qxF "        - 'o/kept@v1'" "$L" && grep -qF 'oracle disagrees, KEEPING o/kept@v1' <<<"$out" \
  && ok "comment-only ref vetoed by the literal-grep oracle" || bad "comment-only ref vetoed by the literal-grep oracle"
! grep -qF "o/gone@v1" "$L" && ok "stale refs dropped from both workflows" || bad "stale refs dropped from both workflows"
grep -qxF "    '.github/workflows/empty.yml': []" "$L" && ok "emptied entry becomes []" || bad "emptied entry becomes []"
! grep -qF "retired.yml" "$L" && ok "key for a deleted workflow with refs dropped" || bad "key for a deleted workflow with refs dropped"
! grep -qF "retired-empty.yml" "$L" && ok "key for a deleted workflow already [] dropped" || bad "key for a deleted workflow already [] dropped"
grep -qxF "    'actions/setup-node@$A':" "$L" && grep -qxF "        commit: 'sha1-$A'" "$L" \
  && ok "dependencies: records untouched" || bad "dependencies: records untouched"
cp "$L" "$WORK/before"; out=$(cd "$WORK/r" && bash "$TARGET" 2>&1)
cmp -s "$L" "$WORK/before" && ok "idempotent: second run changes nothing" || bad "idempotent: second run changes nothing — $out"

g="$WORK/g/.github/workflows"; mkdir -p "$g"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@%s\n' "$A" > "$g/ci.yml"
printf 'workflows:\n    '\''.github/workflows/ci.yml'\'':\n        - '\''actions/checkout@%s'\''\n    '\''.github/workflows/gone.yml'\'': []\ndependencies:\n' "$A" > "$g/actions.lock"
(cd "$WORK/g" && bash "$TARGET") >/dev/null 2>&1
! grep -qF "gone.yml" "$g/actions.lock" && grep -qxF "        - 'actions/checkout@$A'" "$g/actions.lock" \
  && ok "only a deleted workflow [] key stale: key dropped, live ref kept" || bad "only a deleted workflow [] key stale: key dropped, live ref kept — $(cat "$g/actions.lock")"

# A stale ref with NO deleted workflow is the common case (a Dependabot bump).
# The deleted-workflow pass then reads an empty list first, and an `NR == FNR`
# guard is true for every line of the lock: the whole file was swallowed and
# the lock overwritten empty. The suite above always deletes a workflow, so it
# never reached this.
v="$WORK/v/.github/workflows"; mkdir -p "$v"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@%s\n' "$B" > "$v/ci.yml"
printf "version: 'v0.0.2'\nworkflows:\n    '.github/workflows/ci.yml':\n        - 'actions/checkout@%s'\n        - 'actions/checkout@%s'\ndependencies:\n    'actions/checkout@%s':\n        commit: 'sha1-%s'\n" "$A" "$B" "$B" "$B" > "$v/actions.lock"
(cd "$WORK/v" && bash "$TARGET") >/dev/null 2>&1
grep -qxF "version: 'v0.0.2'" "$v/actions.lock" && grep -qxF "        - 'actions/checkout@$B'" "$v/actions.lock" \
  && ! grep -qF "checkout@$A" "$v/actions.lock" && grep -qxF "        commit: 'sha1-$B'" "$v/actions.lock" \
  && ok "stale ref, no deleted workflow: lock kept whole, only the stale ref pruned" \
  || bad "stale ref, no deleted workflow: lock kept whole, only the stale ref pruned — $(wc -l < "$v/actions.lock") line(s) left"

# Local composite actions (standards#1122). A workflow's entry lists the refs
# its local composites use, nested ones included, because a local action has no
# record of its own. Those refs must survive; a ref no file uses must not. The
# composite refs have no literal match in the workflow file itself, so if the
# oracles do not follow the composites, both agree to drop them.
c="$WORK/c"; mkdir -p "$c/.github/workflows" "$c/.github/actions/outer" "$c/.github/actions/inner"
cat > "$c/.github/workflows/ci.yml" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$A
      - uses: ./.github/actions/outer
EOF
printf 'runs:\n  using: composite\n  steps:\n    - uses: "o/direct@%s",\n    - uses: ./.github/actions/inner/\n' "$B" > "$c/.github/actions/outer/action.yml"
printf 'runs:\n  using: composite\n  steps:\n    - uses: o/nested/sub@%s # v1\n' "$S" > "$c/.github/actions/inner/action.yaml"
cat > "$c/.github/workflows/actions.lock" <<EOF
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@$A'
        - 'o/direct@$B'
        - 'o/nested@$S'
        - 'o/unused@$A'
dependencies:
EOF
(cd "$c" && bash "$TARGET") >/dev/null 2>&1
grep -qxF "        - 'o/direct@$B'" "$c/.github/workflows/actions.lock" \
  && ok "ref used by a local composite kept (KYAML-quoted)" || bad "ref used by a local composite kept (KYAML-quoted)"
grep -qxF "        - 'o/nested@$S'" "$c/.github/workflows/actions.lock" \
  && ok "ref used by a nested local composite (action.yaml) kept" || bad "ref used by a nested local composite (action.yaml) kept"
! grep -qF "o/unused@" "$c/.github/workflows/actions.lock" \
  && ok "ref used by no workflow or composite still pruned" || bad "ref used by no workflow or composite still pruned"

# ── the reviewed closure vetoes pruning ──────────────────────────────────────
# A ref reached only through a REMOTE reusable workflow appears in neither the
# workflow text nor any local composite, so both oracles say "nothing uses it".
# hyperpolymath/unified-dataset-vocab#81 ships exactly this shape and runs.
# probe exactly as the script does: without an awk that has 3-argument match()
# prune-stale refuses to run at all, and asserting on an unmodified lock would
# report a vacuous pass.
GAWK_OK=0
for cand in gawk awk; do
  if command -v "$cand" >/dev/null 2>&1 \
     && echo x | "$cand" '{ if (match($0, /(x)/, m) && m[1] == "x") exit 0; exit 1 }' 2>/dev/null; then
    GAWK_OK=1; break
  fi
done
if [ "$GAWK_OK" -eq 0 ]; then
  echo "SKIP: no awk with 3-argument match() here, so prune-stale cannot run — its closure veto is NOT asserted in this sandbox (it runs on the runner)"
else
k="$WORK/k/.github/workflows"; mkdir -p "$k"
cat > "$k/secret-scanner.yml" <<EOF
jobs:
  scan:
    uses: hyperpolymath/cicd-suite/.github/workflows/secret-scanner-reusable.yml@$S
EOF
cat > "$k/actions.lock" <<EOF
workflows:
    '.github/workflows/secret-scanner.yml':
        - 'actions/checkout@$A'
        - 'o/unrelated@$B'
dependencies:
EOF
printf '.github/workflows/secret-scanner.yml\thyperpolymath/cicd-suite@%s\tactions/checkout@%s\n' "$S" "$A" \
  > "$k/actions-lock.closure.tsv"
(cd "$WORK/k" && bash "$TARGET") >/dev/null 2>&1
grep -qxF "        - 'actions/checkout@$A'" "$k/actions.lock" \
  && ok "ref reached through a remote reusable is kept by the closure manifest" \
  || bad "ref reached through a remote reusable is kept by the closure manifest"
! grep -qF "o/unrelated@" "$k/actions.lock" \
  && ok "the closure manifest does not keep a genuinely unrelated ref" \
  || bad "the closure manifest does not keep a genuinely unrelated ref"
(cd "$WORK/k" && bash "$TARGET" --no-closure) >/dev/null 2>&1
! grep -qF "actions/checkout@$A" "$k/actions.lock" \
  && ok "--no-closure restores the two-oracle behaviour (the ref is pruned)" \
  || bad "--no-closure restores the two-oracle behaviour (the ref is pruned)"

fi

mkdir -p "$WORK/n/.github/workflows"; (cd "$WORK/n" && bash "$TARGET") >/dev/null 2>&1; st=$?
[ "$st" = 1 ] && ok "no lockfile → exit 1" || bad "no lockfile → exit 1 (got $st)"

echo "prune-stale-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
