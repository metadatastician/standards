#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression coverage for standards#496: session artefacts must be archived,
# while live testing guidance must remain inside a registry-listed spec home.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
pass=0
fail=0

ok() { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

assert_absent() {
  if [ ! -e "$ROOT/$1" ]; then ok "$1 absent from live tree"; else bad "$1 remains live"; fi
}

assert_present() {
  if [ -f "$ROOT/$1" ]; then ok "$1 preserved in archive/canonical home"; else bad "$1 missing"; fi
}

for retired in \
  stapeln.toml \
  contractile.just \
  audit-contractiles.sh \
  SECURITY_TRAINING_SUMMARY.md \
  2-protocols/axel/SONNET-TASKS.adoc \
  2-protocols/0-ai-gatekeeper/AI-GATEKEEPER-PROTOCOL-COMPLETE-2026-02-07.adoc \
  automation/K9-AUTOMATION-SPEC.a2ml \
  interop/CRG-TRG-RSR-MAPPING.a2ml \
  templates/TEMPLATE-VERSIONING-SPEC.a2ml \
  docs/language-testing-standards.adoc \
  docs/affinescript-testing-guide.adoc \
  docs/julia-testing-tools-guide.adoc \
  templates/language-testing-guide-TEMPLATE.adoc; do
  assert_absent "$retired"
done

for preserved in \
  docs/archive/scaffolding/stapeln.toml \
  docs/archive/scaffolding/contractile.just \
  docs/archive/scaffolding/audit-contractiles.sh \
  docs/archive/session-detritus/root/SECURITY_TRAINING_SUMMARY.md \
  docs/archive/session-detritus/axel-protocol/SONNET-TASKS.adoc \
  docs/archive/session-detritus/0-ai-gatekeeper-protocol/AI-GATEKEEPER-PROTOCOL-COMPLETE-2026-02-07.adoc \
  9-archive/a2ml/docs/archive/reorg-leftovers/K9-AUTOMATION-SPEC.a2ml \
  9-archive/a2ml/docs/archive/reorg-leftovers/CRG-TRG-RSR-MAPPING.a2ml \
  9-archive/a2ml/docs/archive/reorg-leftovers/TEMPLATE-VERSIONING-SPEC.a2ml \
  toolchain-readiness-grades/testing/LANGUAGE-TESTING-STANDARDS.adoc \
  toolchain-readiness-grades/testing/affinescript-testing-guide.adoc \
  toolchain-readiness-grades/testing/julia-testing-tools-guide.adoc \
  toolchain-readiness-grades/testing/language-testing-guide-TEMPLATE.adoc; do
  assert_present "$preserved"
done

if ! rg -q '^import\? "contractile\.just"' "$ROOT/Justfile"; then
  ok 'Justfile does not import retired generated output'
else
  bad 'Justfile imports retired generated output'
fi

if rg -q 'just setup-dev|just panic-scan' "$ROOT/QUICKSTART-DEV.adoc"; then
  bad 'developer quickstart retains unavailable recipes'
else
  ok 'developer quickstart names available recipes'
fi

if rg -q 'ZIGZAG-TESTING\.md' "$ROOT/TEST-NEEDS.adoc"; then
  bad 'TEST-NEEDS retains dangling Markdown link'
else
  ok 'TEST-NEEDS uses the existing AsciiDoc target'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
