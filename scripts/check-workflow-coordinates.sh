#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Refuse executable uses:/repository: coordinates for a moved repository.
# Parse YAML rather than grepping comments, run scripts, or quoted/flow scalars.
set -euo pipefail
workflows=${1:-.github/workflows}
yq_bin=${YQ_BIN:-yq}
[ -d "$workflows" ] || { echo "missing workflow directory: $workflows" >&2; exit 2; }
command -v "$yq_bin" >/dev/null && command -v jq >/dev/null || { echo 'yq v4 and jq are required' >&2; exit 2; }
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
found=0 bad=0
while IFS= read -r -d '' file; do
  found=$((found + 1))
  # explode resolves YAML aliases/merge keys, so an anchored job or checkout
  # is checked just like an inline scalar. A parsing error is not a clean scan.
  if ! "$yq_bin" -o=json 'explode(.)' "$file" > "$tmp"; then
    echo "cannot parse workflow: $file" >&2; bad=1; continue
  fi
  if ! jq -e -s 'length > 0' "$tmp" >/dev/null; then
    echo "empty workflow: $file" >&2; bad=1; continue
  fi
  # Only job/step uses and action/reusable inputs can execute coordinates.
  # Other `repository` keys (environment metadata, strategy data, etc.) are
  # ordinary YAML and must not make historical text a blocking violation.
  refs=$(jq -r '
    .jobs // {} | select(type == "object") | .[] | select(type == "object") |
    (.uses?, .with.repository?,
     (.steps // [] | select(type == "array") | .[] | select(type == "object") |
      (.uses?, .with.repository?))) | strings
  ' "$tmp")
  if printf '%s\n' "$refs" | grep -iE '^[[:space:]]*hyperpolymath/standards([/@[:space:]]|$)' >/dev/null; then
    echo "former-owner executable coordinate in $file:" >&2
    printf '%s\n' "$refs" | grep -iE '^[[:space:]]*hyperpolymath/standards([/@[:space:]]|$)' >&2
    bad=1
  fi
done < <(find "$workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
[ "$found" -gt 0 ] || { echo 'no workflow YAML found' >&2; exit 2; }
[ "$bad" -eq 0 ] || exit 1
echo "OK: $found workflow(s) have no former-owner uses:/repository: coordinates"
