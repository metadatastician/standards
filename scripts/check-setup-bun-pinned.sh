#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Every oven-sh/setup-bun step must name an exact bun-version (x.y.z).
#
# Why: with no version, "latest", a range or a file, setup-bun lists every Bun
# tag through api.github.com/repos/oven-sh/bun/git/refs/tags on the workflow
# token (src/download-url.ts at the pinned v2.2.0). That spends the per-repo
# GITHUB_TOKEN budget that every other job in the push shares. MEASURED
# 2026-11-12 on standards 2ca1293: six workflows failed with "API rate limit
# exceeded for installation", two of them inside setup-bun. An exact version
# downloads from the release URL with no API call, and lets the Bun cache work.
set -euo pipefail
workflows=${1:-.github/workflows}
yq_bin=${YQ_BIN:-yq}
[ -d "$workflows" ] || { echo "missing workflow directory: $workflows" >&2; exit 2; }
command -v "$yq_bin" >/dev/null && command -v jq >/dev/null || { echo 'yq v4 and jq are required' >&2; exit 2; }
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
found=0 steps=0 bad=0
while IFS= read -r -d '' file; do
  found=$((found + 1))
  if ! "$yq_bin" -o=json 'explode(.)' "$file" > "$tmp"; then
    echo "cannot parse workflow: $file" >&2; bad=1; continue
  fi
  # One line per setup-bun step: "<job>\t<bun-version or empty>".
  rows=$(jq -r '
    .jobs // {} | select(type == "object") | to_entries[] |
    .key as $job | .value | select(type == "object") |
    .steps // [] | select(type == "array") | .[] | select(type == "object") |
    select((.uses // "") | type == "string" and test("^oven-sh/setup-bun@"; "i")) |
    [$job, ((.with // {})["bun-version"] // "" | tostring)] | @tsv
  ' "$tmp")
  [ -n "$rows" ] || continue
  while IFS=$'\t' read -r job version; do
    steps=$((steps + 1))
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$file: job '$job': setup-bun needs an exact bun-version (x.y.z), got '${version:-<none>}'" >&2
      bad=1
    fi
  done <<< "$rows"
done < <(find "$workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
[ "$found" -gt 0 ] || { echo 'no workflow YAML found' >&2; exit 2; }
[ "$bad" -eq 0 ] || exit 1
echo "OK: $steps setup-bun step(s) in $found workflow(s) name an exact bun-version"
