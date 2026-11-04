#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The gating SARIF may only be modified by this reusable's scope helper.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
awk '/^      - name: Filter SARIF by declared scope$/{step=1} step && /^        run: \|$/{run=1; next}
  run && /^      - name:/{exit} run {if ($0 ~ /^          /) sub(/^          /, ""); print}' \
  "$root/.github/workflows/hypatia-scan-reusable.yml" > "$tmp/scope-step.sh"
[ -s "$tmp/scope-step.sh" ] || { echo 'missing scope workflow step' >&2; exit 1; }
cd "$tmp"; mkdir scripts
printf '#!/usr/bin/env bash\ntouch used-caller-helper\n' > scripts/filter-sarif-by-scope.sh
printf '%s\n' '{"version":"2.1.0","runs":[{"results":[{"ruleId":"hypatia/x/y","level":"error","locations":[{"physicalLocation":{"artifactLocation":{"uri":"9-archive/old.rs"}}}]}]}]}' > hypatia.sarif
export SCOPE_EXCLUDES=9-archive/
bash "$tmp/scope-step.sh" >/dev/null
[ ! -e used-caller-helper ]
jq -e '.runs[0].results | length == 1' hypatia.sarif >/dev/null
mkdir -p .standards-checkout/scripts
cp "$root/scripts/filter-sarif-by-scope.sh" .standards-checkout/scripts/
bash "$tmp/scope-step.sh" >/dev/null
jq -e '.runs[0].results | length == 0' hypatia.sarif >/dev/null
jq -e '.runs[0].results | length == 1' hypatia.pre-scope.sarif >/dev/null
[ ! -e used-caller-helper ]
echo 'PASS: scope filtering preserves pre-scope evidence and uses only the revision-matched helper'
