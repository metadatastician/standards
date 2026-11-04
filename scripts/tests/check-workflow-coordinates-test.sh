#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
checker="$root/scripts/check-workflow-coordinates.sh"
mkdir -p "$tmp/workflows"
cat > "$tmp/workflows/test.yml" <<'YAML'
# uses: hyperpolymath/standards/.github/workflows/old.yml@sha
env:
  repository: hyperpolymath/standards
jobs:
  local:
    uses: metadatastician/standards/.github/workflows/ok.yml@abc
    with:
      repository: metadatastician/standards
  descriptive:
    runs-on: ubuntu-latest
    env:
      repository: hyperpolymath/standards
    steps:
      - run: |
          echo 'repository: hyperpolymath/standards'
YAML
bash "$checker" "$tmp/workflows" >/dev/null
for old in \
  $'jobs:\n  bad:\n    uses: HyperPolymath/Standards/.github/workflows/a.yml@abc' \
  $'jobs:\n  bad:\n    uses: owner/reusable/.github/workflows/a.yml@abc\n    with: {"repository": "hyperpolymath/standards"}' \
  $'jobs:\n  bad:\n    steps:\n      - {uses: hyperpolymath/standards/action@abc}' \
  $'jobs:\n  bad:\n    steps:\n      - uses: actions/checkout@abc\n        with:\n          repository: >-\n            hyperpolymath/standards' \
  $'defaults: &bad {uses: hyperpolymath/standards/.github/workflows/a.yml@abc}\njobs: {check: {<<: *bad}}'; do
  printf '%s\n' "$old" > "$tmp/workflows/bad.yaml"
  if bash "$checker" "$tmp/workflows" >/dev/null 2>&1; then
    echo "FAIL: former-owner coordinate escaped: $old" >&2; exit 1
  fi
done
printf '%s\n' 'bad: [unterminated' > "$tmp/workflows/bad.yaml"
if bash "$checker" "$tmp/workflows" >/dev/null 2>&1; then
  echo 'FAIL: malformed YAML was accepted' >&2; exit 1
fi
rm "$tmp/workflows/bad.yaml"
bash "$checker" "$root/.github/workflows" >/dev/null
echo 'PASS: executable YAML coordinates are checked, comments and scripts are not'
