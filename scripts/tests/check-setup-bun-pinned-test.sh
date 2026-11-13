#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
checker="$root/scripts/check-setup-bun-pinned.sh"
mkdir -p "$tmp/workflows"
cat > "$tmp/workflows/ok.yml" <<'YAML'
# uses: oven-sh/setup-bun@abc  (a comment is not a step)
jobs:
  a:
    steps:
      - uses: oven-sh/setup-bun@abc # v2
        with:
          bun-version: "1.4.2"
      - uses: actions/checkout@abc
      - run: |
          echo 'uses: oven-sh/setup-bun@abc'
YAML
bash "$checker" "$tmp/workflows" >/dev/null
for bad in \
  $'jobs:\n  a:\n    steps:\n      - uses: oven-sh/setup-bun@abc' \
  $'jobs:\n  a:\n    steps:\n      - uses: oven-sh/setup-bun@abc\n        with:\n          bun-version: latest' \
  $'jobs:\n  a:\n    steps:\n      - uses: oven-sh/setup-bun@abc\n        with:\n          bun-version: "1.x"' \
  $'jobs:\n  a:\n    steps:\n      - uses: oven-sh/setup-bun@abc\n        with:\n          bun-version-file: .bun-version' \
  $'jobs:\n  a:\n    steps:\n      - {uses: Oven-Sh/Setup-Bun@abc, with: {bun-version: canary}}' \
  $'defaults: &s {uses: oven-sh/setup-bun@abc}\njobs: {a: {steps: [{<<: *s}]}}'; do
  printf '%s\n' "$bad" > "$tmp/workflows/bad.yaml"
  if bash "$checker" "$tmp/workflows" >/dev/null 2>&1; then
    echo "FAIL: unpinned setup-bun escaped: $bad" >&2; exit 1
  fi
done
printf '%s\n' 'bad: [unterminated' > "$tmp/workflows/bad.yaml"
if bash "$checker" "$tmp/workflows" >/dev/null 2>&1; then
  echo 'FAIL: malformed YAML was accepted' >&2; exit 1
fi
rm "$tmp/workflows/bad.yaml"
bash "$checker" "$root/.github/workflows" >/dev/null
echo 'PASS: every setup-bun step names an exact bun-version'
