#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -uo pipefail
#
# Wave-5 regression: the per-language testing guide lint must accept a
# template-conformant guide and reject one missing a required section.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="$ROOT/scripts/check-language-guide.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }

echo "== real guides pass =="
guide_out="$(bash "$CHK" 2>&1)"; guide_rc=$?
if [ "$guide_rc" -eq 0 ] && printf '%s\n' "$guide_out" | grep -q 'affinescript-testing-guide.adoc'; then
  ok "estate guides are discovered and pass structural lint"
else
  bad "estate guides were missed or failed lint"
fi
bash "$CHK" "$ROOT/4-readiness/toolchain-readiness-grades/testing/affinescript-testing-guide.adoc" >/dev/null 2>&1 && ok "affinescript guide valid" || bad "affinescript guide invalid"

echo "== rejects incomplete guides =="
# missing a required section
g="$TMP/foo-testing-guide.md"
printf '<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->\n# Foo\n## Requirement mapping\nR1 ... R9 ...\n## Tools\n## Recommended CI pipeline\n## Best practices\n## Resources\n' > "$g"
bash "$CHK" "$g" >/dev/null 2>&1 && bad "missing 'Known gaps' not caught" || ok "missing section rejected"
# missing SPDX header
g2="$TMP/bar-testing-guide.md"
printf '# Bar\n## Requirement mapping\nR1 R9\n## Tools\n## Recommended CI pipeline\n## Best practices\n## Known gaps\n## Resources\n' > "$g2"
bash "$CHK" "$g2" >/dev/null 2>&1 && bad "missing SPDX not caught" || ok "missing SPDX rejected"
# missing R1..R9 reference
g3="$TMP/baz-testing-guide.md"
printf '<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->\n# Baz\n## Requirement mapping\nno numbers here\n## Tools\n## Recommended CI pipeline\n## Best practices\n## Known gaps\n## Resources\n' > "$g3"
bash "$CHK" "$g3" >/dev/null 2>&1 && bad "missing R1..R9 not caught" || ok "missing R1..R9 rejected"

echo "== the stale duplicate snapshot is gone =="
[ ! -f "$ROOT/docs/language-testing-standards-v1.0.0-2024-04-14.adoc" ] && ok "duplicate snapshot removed" || bad "duplicate snapshot still present"
echo "== the standard is v2.0.0 with RFC-2119 =="
grep -q 'Version:\* 2.0.0' "$ROOT/4-readiness/toolchain-readiness-grades/testing/LANGUAGE-TESTING-STANDARDS.adoc" && grep -qi 'RFC-2119' "$ROOT/4-readiness/toolchain-readiness-grades/testing/LANGUAGE-TESTING-STANDARDS.adoc" && ok "standard refreshed to v2.0.0 RFC-2119" || bad "standard not refreshed"

echo
echo "Wave-5 language-guides regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
