#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# check-package-policy-test.sh — fixture suite for scripts/check-package-policy.sh.
#
# The gate applies only where the repo's profile declares reproducible-build
# or container. Until standards#1353 the profile was discovered only as
# .machine_readable/rsr-profile.a2ml, so a deed-only repository (the worked
# model shape) declaring a packaging capability and shipping no packaging
# exited 0: the declared capability was never enforced (Codex finding on
# #1353). Every case runs past the grace cutoff so a violation is a failure.
#
# Run: bash scripts/tests/check-package-policy-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../check-package-policy.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
export PKG_TODAY="2026-09-01"   # after ENFORCE_PACKAGE_POLICY_FROM (2026-08-21)

assert() { # label want-status needle cmd...
  local label="$1" want="$2" needle="$3"; shift 3
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $status"
    echo "      $(printf '%s' "$out" | tail -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: $label — exit ok, output lacked '$needle'"
    echo "      $(printf '%s' "$out" | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

# repo <name>: a bare tree with no packaging artefact at all.
repo() { local d="$WORK/$1"; mkdir -p "$d/.machine_readable"; printf '%s' "$d"; }
# deed <dir> <name> <clause-body>: a minimal valid repo-deed with the body.
deed() {
  printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed\n  :schema-version "1.0.0"\n  :canonical-name "%s"\n  :repo-uuid #u5"github.com/o/%s"\n  :beholding-chora #u5"estate/chora"\n%b)\n' "$2" "$2" "$3" > "$1/${2}_chora.deed"
}

echo "=== legacy a2ml profile (unchanged behaviour) ==="
d=$(repo a2ml-declared)
printf '[rsr-profile]\nversion = "1.0.0"\ncapabilities = ["reproducible-build"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
assert "a2ml declares reproducible-build, nothing ships → violation" 1 "Package policy violation" bash "$GATE" "$d"

d=$(repo a2ml-none)
printf '[rsr-profile]\nversion = "1.0.0"\ncapabilities = ["bash"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
assert "a2ml declares no packaging capability → not applicable" 0 "Packaging not applicable" bash "$GATE" "$d"

echo "=== deed-era profile: (rsr-profile …) on the repo deed ==="
d=$(repo deed-declared)
deed "$d" deeddeclared '  (rsr-profile :version "1.0.0" :capabilities ("reproducible-build"))'
assert "deed declares reproducible-build, nothing ships → violation (was a silent 0)" 1 "Package policy violation" bash "$GATE" "$d"

d=$(repo deed-container)
deed "$d" deedcontainer '  (rsr-profile :version "1.0.0" :capabilities ("container"))'
assert "deed declares container, nothing ships → violation" 1 "Package policy violation" bash "$GATE" "$d"

d=$(repo deed-satisfied)
deed "$d" deedsatisfied '  (rsr-profile :version "1.0.0" :capabilities ("reproducible-build"))'
printf '(use-modules (guix packages))\n(package (name "x"))\n' > "$d/guix.scm"
assert "deed declares reproducible-build and a real guix.scm ships → primary detected" 0 "Guix package management detected" bash "$GATE" "$d"

d=$(repo deed-noclause)
deed "$d" deednoclause '  (notes :x "no profile here")'
assert "deed without the clause → not applicable, no warning about an unreadable profile" 0 "Packaging not applicable" bash "$GATE" "$d"

d=$(repo deed-commented)
deed "$d" deedcommented '  ; (rsr-profile :version "1.0.0" :capabilities ("container"))'
assert "a commented-out clause is not a profile" 0 "Packaging not applicable" bash "$GATE" "$d"

d=$(repo deed-estate-only)
printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(estate-deed :schema-version "1.0.0" :canonical-name "estate" :estate-uuid #u5"estate/chora" (rsr-profile :capabilities ("container")))\n' > "$d/estate_chora.deed"
assert "estate_chora.deed is not a repo deed, so its text is not a profile" 0 "Packaging not applicable" bash "$GATE" "$d"

d=$(repo deed-wins)
deed "$d" deedwins '  (rsr-profile :version "1.0.0" :capabilities ("bash"))'
printf '[rsr-profile]\nversion = "1.0.0"\ncapabilities = ["reproducible-build"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
assert "a2ml beside a deed clause: the resolver's precedence (deed) decides, so no packaging is required" 0 "Packaging not applicable" bash "$GATE" "$d"

echo "=== discovery must agree with the resolver (CodeRabbit and Codex on #1357) ==="
d=$(repo deed-head-eol)
deed "$d" deedheadeol '  (rsr-profile\n    :version "1.0.0"\n    :capabilities ("container"))\n'
assert "clause head at the end of a line is still the clause" 1 "Package policy violation" bash "$GATE" "$d"

d=$(repo deed-semicolon)
deed "$d" deedsemicolon '  (notes :author "Smith; Jr.") (rsr-profile :version "1.0.0" :capabilities ("container"))\n'
assert "a ; inside a string before the clause is text, not a comment" 1 "Package policy violation" bash "$GATE" "$d"

d=$(repo deed-large)
{ printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed :schema-version "1.0.0" :canonical-name "deedlarge" :repo-uuid #u5"github.com/o/deedlarge" :beholding-chora #u5"estate/chora"\n  (rsr-profile :version "1.0.0" :capabilities ("container"))\n  (notes\n'
  awk 'BEGIN { for (i = 0; i < 25000; i++) printf "    :n%d \"%s\"\n", i, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }'
  printf '  ))\n'; } > "$d/deedlarge_chora.deed"
assert "a large deed (profile first, then 1.5 MB) is still discovered under pipefail" 1 "Package policy violation" bash "$GATE" "$d"

d=$(repo deed-dotname)
deed "$d" .github '  (rsr-profile :version "1.0.0" :capabilities ("container"))\n'
assert "a dot-prefixed repo deed (.github_chora.deed) is discovered" 1 "Package policy violation" bash "$GATE" "$d"

d=$(repo deed-head-comment)
deed "$d" deedheadcomment '  (rsr-profile; the profile\n    :version "1.0.0"\n    :capabilities ("container"))\n'
assert "a comment straight after the clause head still separates it" 1 "Package policy violation" bash "$GATE" "$d"

d=$(repo deed-failglob)
deed "$d" deedfailglob '  (rsr-profile :version "1.0.0" :capabilities ("container"))\n'
assert "with failglob on, discovery still finds the deed" 1 "Package policy violation" bash -O failglob "$GATE" "$d"

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
