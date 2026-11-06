#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression tests for issue #968: compare workflow refs in both directions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK_SCRIPT="$ROOT/scripts/check-lock-sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WF="$TMP/workflows"
mkdir -p "$WF"
pass=0
fail=0

expect() {
  local want="$1" label="$2" out rc=0
  out="$(bash "$CHECK_SCRIPT" "$WF" 2>&1)" || rc=$?
  if [ "$rc" -eq "$want" ]; then
    echo "PASS: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: $label (expected $want, got $rc)"
    printf '%s\n' "$out"
    fail=$((fail + 1))
  fi
}

cat > "$WF/test.yml" <<'YAML'
jobs:
  test:
    steps:
      - uses: Actions/Checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
YAML
expect 1 'missing lockfile fails closed'
cat > "$WF/actions.lock" <<'YAML'
workflows:
    '.github/workflows/test.yml':
        - 'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
dependencies:
    'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa':
        ref: 'v1'
        commit: 'sha1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        owner_id: 1
        repo_id: 2
YAML
expect 0 'repository names compare case-insensitively'
sed -i 's/Actions\/Checkout/actions\/checkout/' "$WF/test.yml"
expect 0 'matching block workflow is accepted'

cat > "$WF/test.yml" <<'YAML'
{
  jobs: {
    test: {
      steps: [
        {
          uses: "actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", # pinned
        },
        {
          uses: 'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        },
      ],
    },
  },
}
YAML
expect 0 'KYAML quoted refs exclude the trailing comma'
sed -i 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/g' "$WF/test.yml"
expect 1 'KYAML changed SHA remains a failure'

cat > "$WF/test.yml" <<'YAML'
jobs:
  test:
    uses: owner/repo/.github/workflows/test.yml@Release
YAML
cat > "$WF/actions.lock" <<'YAML'
workflows:
    '.github/workflows/test.yml':
        - 'Owner/Repo@Release'
dependencies:
    'Owner/Repo@Release':
        ref: 'Release'
        commit: 'sha1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        owner_id: 1
        repo_id: 2
YAML
expect 0 'job-level reusable workflow is checked and lock names normalised'
sed -i 's/@Release/@release/' "$WF/test.yml"
expect 1 'ref case remains significant'
sed -i 's/@release/@Release/' "$WF/test.yml"
sed -i "/^dependencies:/i\\        - 'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'" "$WF/actions.lock"
expect 1 'stale lock entries remain failures'
sed -i '/actions\/checkout/d' "$WF/actions.lock"
# An omitted job-level call is harmless (standards#968), but its workflow
# still needs an explicit key. An empty entry satisfies that separate rule.
cp "$WF/test.yml" "$WF/unlocked.yml"
expect 1 'job-level-only workflow still needs a lockfile key'
sed -i "/^dependencies:/i\\    '.github/workflows/unlocked.yml': []" "$WF/actions.lock"
expect 0 'job-level-only workflow accepts an explicit empty entry (standards#968)'
cat > "$WF/unlocked.yml" <<'YAML'
jobs:
  test:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
YAML
expect 1 'workflow missing from lock remains a failure (step-level)'
rm "$WF/unlocked.yml"
rm "$WF/test.yml"
expect 1 'deleted workflow lock entries remain failures'

# Local composite actions (standards#1122): the refs a local composite uses,
# nested composites included, are locked under the calling workflow.
R="$TMP/r"
WF="$R/.github/workflows"
mkdir -p "$WF" "$R/.github/actions/push" "$R/.github/actions/token"
cat > "$WF/smoke.yml" <<'YAML'
jobs:
  smoke:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      - uses: ./.github/actions/push
      - uses: ./.github/workflows/not-followed.yml
YAML
cat > "$R/.github/actions/push/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - uses: ./.github/actions/token
    - uses: asana/push-signed-commits@cccccccccccccccccccccccccccccccccccccccc # v1
YAML
cat > "$R/.github/actions/token/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - uses: "actions/create-github-app-token@dddddddddddddddddddddddddddddddddddddddd",
YAML
cat > "$WF/actions.lock" <<'YAML'
workflows:
    '.github/workflows/smoke.yml':
        - 'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        - 'actions/create-github-app-token@dddddddddddddddddddddddddddddddddddddddd'
        - 'asana/push-signed-commits@cccccccccccccccccccccccccccccccccccccccc'
dependencies:
    'actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa':
        ref: 'v1'
        commit: 'sha1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'actions/create-github-app-token@dddddddddddddddddddddddddddddddddddddddd':
        ref: 'v1'
        commit: 'sha1-dddddddddddddddddddddddddddddddddddddddd'
    'asana/push-signed-commits@cccccccccccccccccccccccccccccccccccccccc':
        ref: 'v1'
        commit: 'sha1-cccccccccccccccccccccccccccccccccccccccc'
YAML
expect 0 'refs used through local composites (nested, KYAML) count as used'
cp "$WF/actions.lock" "$TMP/full.lock"
# The planted negative from the issue: the two composite lines deleted.
sed -i '/^        - .*create-github-app-token/d; /^        - .*push-signed-commits/d' "$WF/actions.lock"
expect 1 'composite deps missing from the calling workflow entry fail'
cp "$TMP/full.lock" "$WF/actions.lock"
sed -i '/push-signed-commits/d' "$R/.github/actions/push/action.yml"
expect 1 'a ref no composite uses any more is stale'

# ── The unified-dataset-vocab#81 shape: the job-level reusable ref is absent
#    from the lock and the through-ref is recorded under the CALLING workflow.
#    Direction 1 permits it; direction 2 must not then call the through-ref a
#    stale entry, or the shape cannot pass this gate at all.
rm -f "$TMP/full.lock"
cat > "$WF/smoke.yml" <<'YAML'
jobs:
  scan:
    uses: hyperpolymath/cicd-suite/.github/workflows/secret-scanner.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
YAML
cat > "$WF/actions.lock" <<'YAML'
workflows:
    '.github/workflows/smoke.yml':
        - 'actions/checkout@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
dependencies:
    'actions/checkout@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb':
        ref: 'v1'
        commit: 'sha1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
YAML
expect 1 'a through-ref with no closure manifest and no uses: is stale'
printf '%s\t%s\t%s\n' '.github/workflows/smoke.yml' \
  'hyperpolymath/cicd-suite@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'actions/checkout@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  > "$WF/actions-lock.closure.tsv"
expect 0 'the reviewed closure backs the through-ref in direction 2'
# ...and the closure is not a blanket amnesty: a ref it does not name is still
# stale, so a wrong lock cannot hide behind a manifest.
rm "$WF/actions-lock.closure.tsv"
printf '%s\t%s\t%s\n' '.github/workflows/Smoke.yml' \
  'hyperpolymath/cicd-suite@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'actions/checkout@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  > "$WF/actions-lock.closure.tsv"
expect 1 'a case-different closure workflow does not excuse this one'
rm -f "$WF/actions-lock.closure.tsv" "$WF/smoke.yml"

printf '\ncheck-lock-sync regression: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
