#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# check-launcher-standard-currency-test.sh -- fixture suite for the
# standards#960 AC4 drift gate.
#
# Discovery is by GLOB: scripts/run-shell-test-suite.sh does
#   find scripts/tests -maxdepth 1 -name '*.sh' -type f
# and runs each with `bash "$f"`, so this file needs no workflow wiring and is
# immune to the exit-126 non-executable trap. Grepping .github/workflows for
# this filename finds nothing and is the WRONG way to ask whether it runs.
#
# Run: bash scripts/tests/check-launcher-standard-currency-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$SCRIPT_DIR/../check-launcher-standard-currency.sh"
DEED="$REPO_ROOT/launcher/launcher-standard_praxis.deed"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
no()  { echo "FAIL: $1"; fail=$((fail + 1)); }

# assert_rc <label> <expected-rc> <command...>
assert_rc() {
  local label="$1" want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$label"; else no "$label (rc=$got, want $want)"; fi
}

echo "=== 0. the gate exists and is syntactically valid ==="
if [ -r "$GATE" ]; then ok "gate is readable"; else no "gate missing: $GATE"; fi
assert_rc "gate parses" 0 bash -n "$GATE"

echo
echo "=== 1. ANTI-DRIFT: the gate's default version tracks the real deed ==="
# This is the assertion that stops the checker from silently drifting away from
# the thing it checks. If the standard is bumped and this default is not, THIS
# test goes red in standards' own CI -- which is the only place that can notice.
deed_version="$(command grep -m1 -oE ':standard-version[[:space:]]+"[0-9]+\.[0-9]+\.[0-9]+"' "$DEED" \
                  | command grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
gate_default="$(command grep -m1 -oE '^CURRENT_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "$GATE" \
                  | command grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
if [ -n "$deed_version" ] && [ "$deed_version" = "$gate_default" ]; then
  ok "gate default v$gate_default == deed :standard-version v$deed_version"
else
  no "DRIFT: gate default is v${gate_default:-?} but the deed says v${deed_version:-?} -- update CURRENT_VERSION in $GATE"
fi

echo
echo "=== 2. the gate's premise still holds on disk ==="
if [ -f "$DEED" ]; then
  ok "canonical standard exists at launcher/launcher-standard_praxis.deed"
else
  no "canonical standard is MISSING -- the gate's cure text points at nothing"
fi
if [ -e "$REPO_ROOT/launcher/launcher-standard.a2ml" ]; then
  no "the retired launcher-standard.a2ml is back on disk -- the gate's premise is void"
else
  ok "retired launcher-standard.a2ml is absent, as #952 left it"
fi

echo
echo "=== 3. :standard-version is read, NOT :schema-version ==="
# A deed carries TWO versions. :schema-version is the DEED GRAMMAR (1.0.0);
# :standard-version is the document. Reading the first yields a number that
# looks like a NEWER spec, so the resulting error reads as an upgrade rather
# than as drift -- it is the quietest possible way to get this wrong. The
# fixture below makes the two impossible to confuse.
cat > "$WORK/fake_praxis.deed" <<'DEED'
(praxis-deed
  :schema-version   "1.0.0"
  :canonical-name   "launcher-standard"
  :standard-version "0.9.9")
DEED
out="$("$GATE" --root "$WORK" --standard "$WORK/fake_praxis.deed" 2>&1)" || true
if command grep -q 'expected=v0.9.9' <<<"$out"; then
  ok "--standard read :standard-version (0.9.9)"
elif command grep -q 'expected=v1.0.0' <<<"$out"; then
  no "--standard read :schema-version (1.0.0) -- WRONG FIELD"
else
  no "--standard produced no recognisable expected version: $out"
fi

echo
echo "=== 4. the two defect classes fail INDEPENDENTLY ==="
mkdir -p "$WORK/tree/docs/audits"
printf '# Compliant with launcher-standard.a2ml\n'                    > "$WORK/tree/retired-only.toml"
printf '# Compliant with launcher-standard_praxis.deed v0.3.0\n'      > "$WORK/tree/stale-only.toml"
printf '# Compliant with launcher-standard.a2ml v0.4.0\n'             > "$WORK/tree/retired-but-current.toml"
printf '# Compliant with launcher-standard_praxis.deed v0.4.0\n'      > "$WORK/tree/clean.toml"
printf '# Compliant with launcher-standard.a2ml v0.1.0\n'             > "$WORK/tree/docs/audits/rec-2026-05-26.adoc"
# 9-archive/ is frozen history: the worst mutant, archived at its original
# path, must NOT be reported. The allowlist glob is anchored at the tree root,
# so a sibling that merely starts with "9-archive" is still scanned.
mkdir -p "$WORK/tree/9-archive/a2ml/docs/audits" "$WORK/tree/9-archive-not"
printf '# Compliant with launcher-standard.a2ml v0.1.0\n'             > "$WORK/tree/9-archive/a2ml/docs/audits/rec-2026-05-26.adoc"
printf '# Compliant with launcher-standard.a2ml v0.1.0\n'             > "$WORK/tree/9-archive-not/live.toml"

out="$("$GATE" --root "$WORK/tree" --expect-version 0.4.0 2>&1)" || true

expect_hit() {
  if command grep -q "$1" <<<"$out"; then ok "detects: $2"; else no "MUTANT SURVIVED: $2"; fi
}
expect_miss() {
  if command grep -q "$1" <<<"$out"; then no "FALSE POSITIVE: $2"; else ok "clean: $2"; fi
}

expect_hit 'retired-filename  retired-only.toml'       'retired filename with no version'
expect_hit 'stale-version     stale-only.toml'         'stale version on the canonical filename'
expect_hit 'retired-filename  retired-but-current.toml' 'retired filename even at the current version'
expect_miss 'stale-version     retired-but-current'    'no spurious version defect when the version is current'
expect_miss 'clean.toml'                               'fully-current reference'
expect_miss 'docs/audits'                              'dated historical record is allowlisted'
expect_miss '9-archive/a2ml'                           'frozen 9-archive/ record is allowlisted'
expect_hit  'retired-filename  9-archive-not/live.toml' 'a sibling merely prefixed 9-archive is still scanned'

echo
echo "=== 5. exit codes ==="
assert_rc "defects present -> rc 1"    1 "$GATE" --root "$WORK/tree" --expect-version 0.4.0
mkdir -p "$WORK/empty"
assert_rc "no references -> rc 0"      0 "$GATE" --root "$WORK/empty" --expect-version 0.4.0
assert_rc "unknown argument -> rc 2"   2 "$GATE" --bogus
assert_rc "missing --root dir -> rc 2" 2 "$GATE" --root "$WORK/does-not-exist"
assert_rc "--help -> rc 0"             0 "$GATE" --help

echo
echo "=== 6. the gate's own self-test passes ==="
assert_rc "--self-test" 0 "$GATE" --self-test

echo
echo "=== 7. standards' own tree is clean under the allowlist ==="
# Not a tautology: the tree really does carry launcher-standard.a2ml in four
# places (the conversion mapping doc, two dated audit records, and the deed's
# own ;; provenance header). This asserts the allowlist absorbs exactly those
# and has not been widened into a blanket.
assert_rc "standards tree clean" 0 "$GATE" --root "$REPO_ROOT" --standard "$DEED"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] || exit 1
