#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Tests for .githooks/validate-codeql.sh, the pre-commit gate.
#
# ⚠ TEST 1 IS THE REASON THIS EXISTS. The validator detected languages with
#
#     HAS_RS=$(find "$SCAN_PATH" -name "*.rs" 2>/dev/null | head -1)
#
# under `set -euo pipefail`. `head` exits after one line; `find` then writes
# into a closed pipe, is killed by SIGPIPE, the pipeline reports 141, `pipefail`
# propagates that to the assignment, and `set -e` terminates the script with NO
# OUTPUT — on a perfectly valid repository. Measured: 6 of 6 runs exit 141
# against this repo, and the gate blocked every commit while printing nothing.
#
# WHAT ACTUALLY TRIGGERS IT — and the reason the first version of this test was
# vacuous. It is not the number of matches; it is whether `find` still has
# output pending once `head` is gone. A 20-file fixture in a shallow tree fits
# in the 64K pipe buffer, so find finishes writing and exits 0 and the BUGGY
# validator PASSES. The fixture below emits ~86KB of paths, exceeding the pipe
# buffer, which makes the SIGPIPE deterministic rather than a scheduling race:
# measured 5/5 exit 141 buggy, 5/5 exit 0 fixed. Any future edit that shrinks
# this fixture silently disarms the test.
#
# ⚠ WHAT THIS TEST DOES NOT CLAIM. The `[[ "$HAS_PY" ]] && ! grep -q ... && echo`
# lines were also converted to `if` blocks, but that is hygiene, NOT a bug fix:
# those lists sit at TOP LEVEL, and `set -e` does not exit on a short-circuited
# AND-OR list there (verified: `set -e; X=""; [[ "$X" ]] && echo never; echo
# SURVIVED` prints SURVIVED). The same form IS fatal as the last command of a
# function, which is the separate, genuine bug fixed in
# .githooks/validate-spdx-workflows.sh — see that test. Tests 5-7 below are
# therefore guards against regression, and they pass against the old code too.
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/.githooks/validate-codeql.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0

ck() { # name expected_exit scan_path
  local out rc
  out="$(INPUT_PATH="$3" bash "$HOOK" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ]; then printf '  ok    %s (exit %s)\n' "$1" "$rc"; pass=$((pass+1))
  else printf '  FAIL  %s (expected exit %s, got %s) output=%s\n' "$1" "$2" "$rc" "${out:-<none>}"; fail=$((fail+1)); fi
}

# mk <dir> <codeql languages literal, or NONE for no codeql.yml> <ext...>
# Deliberately long path segments and 400 directories per extension: the point
# is BYTES of find output, not file count. See the header.
mk() {
  local d="$T/$1"; shift
  local langs="$1"; shift
  mkdir -p "$d/.github/workflows"
  if [ "$langs" != NONE ]; then
    printf "name: CodeQL\njobs:\n  analyze:\n    strategy:\n      matrix:\n        language: %s\n" "$langs" \
      > "$d/.github/workflows/codeql.yml"
  fi
  local ext i sub
  for ext in "$@"; do
    for i in $(seq 1 400); do
      sub="$d/src/deeply_nested_package_directory_$i/submodule_component_$i"
      mkdir -p "$sub"
      : > "$sub/source_file_number_$i.$ext"
      : > "$sub/another_source_file_$i.$ext"
    done
  done
}

# Guard the guard: if the fixture stops exceeding the pipe buffer, this test
# can no longer detect the bug it exists for, and must say so loudly.
assert_fixture_big_enough() { # dir ext
  local bytes
  bytes=$(find "$1" -name "*.$2" 2>/dev/null | wc -c)
  if [ "$bytes" -lt 70000 ]; then
    printf '  FAIL  fixture for *.%s emits only %s bytes; under the 64K pipe buffer this test CANNOT detect the SIGPIPE bug\n' "$2" "$bytes"
    fail=$((fail+1))
  else
    printf '  ok    fixture emits %s bytes of find output (> 64K pipe buffer)\n' "$bytes"
    pass=$((pass+1))
  fi
}

echo "[validate-codeql-test] $HOOK"

# 1. PLANTED POSITIVE — the regression. A valid repo whose find output exceeds
#    the pipe buffer. Exits 141 before the fix, 0 after.
mk good "['javascript']" js
assert_fixture_big_enough "$T/good" js
ck "PLANTED POSITIVE: valid large JS repo passes" 0 "$T/good"

# 2-3. The failure was 6/6, so one green run is not evidence of a fix.
ck "PLANTED POSITIVE repeat 2" 0 "$T/good"
ck "PLANTED POSITIVE repeat 3" 0 "$T/good"

# 4. Same shape on the .rs probe, which is the line that actually died in the
#    bash -x trace against this repo (HAS_RS, not HAS_JS).
mk bigrust "['actions']" rs
assert_fixture_big_enough "$T/bigrust" rs
ck "PLANTED POSITIVE: large Rust repo on ['actions'] passes" 0 "$T/bigrust"

# 5. No codeql.yml: gate not applicable, clean skip.
mk nocodeql NONE js
ck "no codeql.yml is a clean skip" 0 "$T/nocodeql"

# 6. The one real error the gate exists to raise: Rust in the CodeQL matrix.
#    CodeQL has no Rust support. The fix must not disarm this.
mk rustbad "['rust']" rs
ck "Rust listed in CodeQL matrix still FAILS" 1 "$T/rustbad"

# 7. Missing-language warning must be a warning, not an error.
mk pywarn "['actions']" py
ck "missing-language warning is non-fatal" 0 "$T/pywarn"
out7="$(INPUT_PATH="$T/pywarn" bash "$HOOK" 2>&1)"
if grep -q "WARNING: Python files" <<<"$out7"; then
  printf '  ok    warning text is actually emitted\n'; pass=$((pass+1))
else
  printf '  FAIL  warning text missing; output=%s\n' "${out7:-<none>}"; fail=$((fail+1))
fi

# 8. A repo with no tracked source files at all: every guard false.
mk emptylangs "['actions']"
ck "repo with no tracked source files passes" 0 "$T/emptylangs"

printf '[validate-codeql-test] %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
