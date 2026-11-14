#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -uo pipefail

# scripts/conformance-deed.sh `lint`: which deeds it lints, what require-files
# does, and how the severity follows ADVISORY. bun is a stub that records its
# arguments, so the test needs no network and no linter.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE="$ROOT/scripts/conformance-deed.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "$BUN_LOG"\n' > "$T/bin/bun"; chmod +x "$T/bin/bun"

run() { # run DIR [env...] -> sets rc, out
  local d="$1"; shift
  out=$(cd "$d" && env PATH="$T/bin:$PATH" BUN_LOG="$T/bun.log" RUNNER_TEMP="$d/.tmp" T=/lint "$@" bash -e -o pipefail "$LANE" lint 2>&1); rc=$?
}

# 1. the caller's deeds are linted; the canon checkouts are not
W="$T/w1"; mkdir -p "$W/.tmp" "$W/.deed-canon/x" "$W/.standards-checkout/y" "$W/sub"
: > "$W/a_chora.deed"; : > "$W/sub/b.deed"; : > "$W/.deed-canon/x/c.deed"; : > "$W/.standards-checkout/y/d.deed"
: > "$T/bun.log"; run "$W"
{ [ $rc -eq 0 ] && grep -q 'a_chora.deed' "$T/bun.log" && grep -q 'sub/b.deed' "$T/bun.log" \
  && ! grep -q 'c.deed' "$T/bun.log" && ! grep -q 'd.deed' "$T/bun.log"; } \
  && ok "lints the caller's deeds and never the .deed-canon / .standards-checkout copies" || bad "deed selection: rc=$rc log=$(cat "$T/bun.log") out=$out"
grep -q -- '--egress' "$T/bun.log" && ok "runs the (egress) profile pass too" || bad "no --egress pass"
grep -q -- '--rsr-scorecard' "$T/bun.log" && ok "runs the (rsr-scorecard) profile pass too" || bad "no --rsr-scorecard pass"

# 2. require-files: a repository with no deed fails, with the right severity
W="$T/w2"; mkdir -p "$W/.tmp"
run "$W" REQUIRE_FILES=true ADVISORY=false
{ [ $rc -eq 1 ] && grep -q '^::error::require-files' <<<"$out"; } && ok "require-files with no deed: error, exit 1" || bad "require-files enforced: rc=$rc $out"
run "$W" REQUIRE_FILES=true ADVISORY=true
{ [ $rc -eq 1 ] && grep -q '^::warning::require-files' <<<"$out" && ! grep -q '::error::' <<<"$out"; } && ok "advisory: the same finding is a warning, never ::error::" || bad "require-files advisory: rc=$rc $out"
run "$W"
{ [ $rc -eq 0 ] && grep -q 'nothing to lint' <<<"$out"; } && ok "no deed and no require-files: passes" || bad "no deed: rc=$rc $out"

# 3. T is required
W="$T/w3"; mkdir -p "$W/.tmp"
out=$(cd "$W" && env -u T RUNNER_TEMP="$W/.tmp" bash "$LANE" lint 2>&1); rc=$?
{ [ $rc -ne 0 ] && grep -q 'T must name' <<<"$out"; } && ok "a missing T is refused, not defaulted" || bad "missing T: rc=$rc $out"
bash "$LANE" bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "an unknown subcommand is a usage error (2)" || bad "usage exit status"

echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
