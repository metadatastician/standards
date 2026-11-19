#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# governance-gates-505-test.sh — fixture suite for the two governance gates
# promoted from theatre to real checks in standards#505:
#
#   scripts/check-docs-presence.sh   (was: `::warning::` only)
#   scripts/check-package-policy.sh  (was: unconditional `✅ ... passed`)
#
# Issue #505 requires each change be proved with BOTH a pass and a fail fixture
# before merge, and notes that `standards` CI does not exercise the reusable
# (callers pin a SHA) — so watching standards go green proves nothing. This
# suite is the proof: it drives every branch of both gates, on both sides of the
# grace cutoff, via the DOCS_TODAY / PKG_TODAY test seams.
#
# Run: bash scripts/tests/governance-gates-505-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCS="$SCRIPT_DIR/../check-docs-presence.sh"
PKG="$SCRIPT_DIR/../check-package-policy.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# assert <label> <expected-status> <expected-substring|-> <command...>
assert() {
  local label="$1" want="$2" needle="$3"; shift 3
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $status"
    echo "      output: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! grep -qF "$needle" <<<"$out"; then
    echo "FAIL: $label — exit $status correct, but output lacked '$needle'"
    echo "      output: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"
  pass=$((pass + 1))
}

mkrepo() {
  local d="$WORK/$1"; shift
  rm -rf "$d"; mkdir -p "$d"
  local f
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; : > "$d/$f"; done
  printf '%s' "$d"
}

# declare <repo-dir> <capability...> — write an rsr-profile declaring capabilities,
# so a fixture opts into the packaging criterion (gated, not universal).
declare() {
  local d="$1"; shift
  mkdir -p "$d/.machine_readable"
  local caps; caps="$(printf '"%s", ' "$@")"
  printf '[rsr-profile]\ncapabilities = [%s]\n' "${caps%, }" > "$d/.machine_readable/rsr-profile.a2ml"
}

BEFORE="2026-08-01"   # inside the grace window (cutoff 2026-08-21)
AFTER="2026-09-01"    # past the cutoff

echo "=== check-docs-presence.sh ==="

r=$(mkrepo docs-ok README.adoc LICENSE CONTRIBUTING.md)
assert "all docs present (pre-cutoff) passes" 0 "✅ Core documentation present" \
  env DOCS_TODAY="$BEFORE" "$DOCS" "$r"
assert "all docs present (post-cutoff) passes" 0 "✅ Core documentation present" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$r"

r=$(mkrepo docs-md README.md LICENSE.txt 3-practice/CONTRIBUTING.adoc)
assert "alternate extensions accepted" 0 "✅ Core documentation present" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$r"

# Regression: AsciiDoc is the estate default and a root CONTRIBUTING.adoc is the
# dominant real-world layout (32 of 34 sampled non-compliant repos). This used to
# fail, so the gate reported 94% false positives once the cutoff armed on
# 2026-08-21. The "alternate extensions" case above did not catch it because it
# only ever placed CONTRIBUTING.adoc under 3-practice/.
r=$(mkrepo docs-adoc-root README.adoc LICENSE CONTRIBUTING.adoc)
assert "root CONTRIBUTING.adoc accepted (regression: 94% false positives)" 0 \
  "✅ Core documentation present" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$r"
# ...and it must still be the grace-windowed document, not an unconditional pass.
assert "root CONTRIBUTING.adoc still warns pre-cutoff only when ABSENT" 0 \
  "NOT YET ENFORCED" \
  env DOCS_TODAY="$BEFORE" "$DOCS" "$(mkrepo docs-adoc-root-absent README.adoc LICENSE)"

# Regression: GitHub auto-discovers a community-health file under .github/ or
# docs/, and estate repos have been deliberately relocating theirs there
# (launch-scaffolder d426ea4d). The gate looked only at the repo root, so it
# reported those repos "missing" a file that is present and discoverable — a
# guard asking a different question than its consumer. A 516-clone census on
# 2026-09-22 found 19 such repos. Each of the four new paths gets its own case:
# a single .github/CONTRIBUTING.md case would pass even if only that one path
# had been added to the candidate list.
r=$(mkrepo docs-github-md README.adoc LICENSE .github/CONTRIBUTING.md)
assert ".github/CONTRIBUTING.md accepted (regression: launch-scaffolder#37)" 0 \
  "✅ Core documentation present" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$r"

r=$(mkrepo docs-github-adoc README.adoc LICENSE .github/CONTRIBUTING.adoc)
assert ".github/CONTRIBUTING.adoc accepted" 0 "✅ Core documentation present" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$r"

r=$(mkrepo docs-docsdir-md README.adoc LICENSE docs/CONTRIBUTING.md)
assert "docs/CONTRIBUTING.md accepted" 0 "✅ Core documentation present" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$r"

r=$(mkrepo docs-docsdir-adoc README.adoc LICENSE docs/CONTRIBUTING.adoc)
assert "docs/CONTRIBUTING.adoc accepted" 0 "✅ Core documentation present" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$r"

# Anti-overreach: widening WHERE the gate looks must not widen WHAT it asks.
# A CONTRIBUTING at an arbitrary depth is NOT discoverable by GitHub and must
# still block. Without this case the four above could be "satisfied" by a
# recursive find, which would silently pass the 94 genuinely-missing repos.
r=$(mkrepo docs-deep-nested README.adoc LICENSE src/internal/CONTRIBUTING.md)
assert "CONTRIBUTING at an undiscoverable path still BLOCKS" 1 \
  "Missing required documentation: CONTRIBUTING" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$r"

# README/LICENSE are BLOCKING NOW — the grace window must not shelter them.
r=$(mkrepo docs-no-readme LICENSE CONTRIBUTING.md)
assert "missing README fails even pre-cutoff" 1 "Missing required documentation: README" \
  env DOCS_TODAY="$BEFORE" "$DOCS" "$r"

r=$(mkrepo docs-no-licence README.adoc CONTRIBUTING.md)
assert "missing LICENSE fails even pre-cutoff" 1 "Missing required documentation: LICENSE" \
  env DOCS_TODAY="$BEFORE" "$DOCS" "$r"

# CONTRIBUTING is the grace-windowed one: the SAME repo must pass before the
# cutoff and fail after it. This pair is the proof the date actually flips.
r=$(mkrepo docs-no-contrib README.adoc LICENSE)
assert "missing CONTRIBUTING warns pre-cutoff (no pass claimed)" 0 "NOT YET ENFORCED" \
  env DOCS_TODAY="$BEFORE" "$DOCS" "$r"
assert "missing CONTRIBUTING BLOCKS post-cutoff" 1 "Missing required documentation: CONTRIBUTING" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$r"

# The cutoff is inclusive: enforcement begins ON the date.
assert "cutoff date itself enforces" 1 "Missing required documentation" \
  env DOCS_TODAY="2026-08-21" "$DOCS" "$r"
assert "day before cutoff still in grace" 0 "NOT YET ENFORCED" \
  env DOCS_TODAY="2026-08-20" "$DOCS" "$r"

# Anti-disarm: a malformed cutoff must refuse to run, not silently grace.
# --- Applicability (2026-10-01): packaging is gated on reproducible-build or
# container, per rsr-criteria-v2 1.2.1 / 1.2.3 / 8.1.4. Not universal.
r=$(mkrepo pkg-none-undeclared README.adoc)
assert "no packaging + no profile is NOT applicable (passes)" 0 "Packaging not applicable" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

r=$(mkrepo pkg-none-docs README.adoc)
declare "$r" docs-site
assert "no packaging + profile without the capability passes" 0 "Packaging not applicable" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

# stub_guix <path> — write a template-style guix.scm whose package has no source.
stub_guix() { printf '(package\n  (name "x")\n  (source #f))\n' > "$1"; }
r=$(mkrepo pkg-stub-undeclared README.adoc); mkdir -p "$r/build"; stub_guix "$r/build/guix.scm"
assert "stub guix.scm, capability undeclared: notice, pass" 0 "scaffold stub" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

r=$(mkrepo pkg-stub-declared README.adoc); mkdir -p "$r/build"; stub_guix "$r/build/guix.scm"
declare "$r" reproducible-build
assert "stub guix.scm, reproducible-build declared: BLOCKS (8.1.4)" 1 "scaffold stub" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

# Planted positive: declared container + TODO-only template must still fail.
r=$(mkrepo pkg-container-todo README.adoc)
printf 'FROM cgr.dev/chainguard/wolfi-base\n# TODO: RUN apk add ...\n' > "$r/Containerfile"
declare "$r" container
assert "declared container + TODO-only Containerfile BLOCKS" 1 "Package policy violation" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

# Every Containerfile is tried; .clusterfuzzlite/ never counts and never shadows.
r=$(mkrepo pkg-container-multi README.adoc)
mkdir -p "$r/.clusterfuzzlite" "$r/build/container"
printf 'FROM gcr.io/oss-fuzz-base/base-builder\nRUN echo fuzz\n' > "$r/.clusterfuzzlite/Containerfile"
printf 'FROM x\n# TODO\n' > "$r/Containerfile.template"
printf 'FROM x\nRUN true\n' > "$r/build/container/Containerfile"
declare "$r" container
assert "active Containerfile found past a stub; .clusterfuzzlite ignored" 0 "build/container/Containerfile" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

r=$(mkrepo pkg-fuzz-only README.adoc)
mkdir -p "$r/.clusterfuzzlite"
printf 'FROM gcr.io/oss-fuzz-base/base-builder\nRUN echo fuzz\n' > "$r/.clusterfuzzlite/Containerfile"
declare "$r" container
assert ".clusterfuzzlite/Containerfile alone does not satisfy" 1 "Package policy violation" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

r=$(mkrepo pkg-bad-profile README.adoc)
mkdir -p "$r/.machine_readable"; printf '[rsr-profile]\nrole = "x"\n' > "$r/.machine_readable/rsr-profile.a2ml"
# An unresolvable profile fails closed and is named: reading it as "no
# capabilities" would let a repo that declares packaging pass with none
# shipped (Codex on #1608; this case used to warn and pass).
assert "unresolvable profile fails closed and is NAMED" 1 "cannot resolve the legacy profile .machine_readable/rsr-profile.a2ml" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"
# A profile defect must never redden a repo whose packaging is real.
: > "$r/guix.scm"
assert "unresolvable profile + real guix.scm passes before the profile is read" 0 "Guix package management detected" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"
rm "$r/guix.scm"
# Old-shape callers ship this script without its resolver: warn, never redden.
assert "missing capability resolver warns, reads as undeclared" 0 "capability resolver missing" \
  env PKG_TODAY="$AFTER" RSR_PROFILE_CHECKER=/nonexistent "$PKG" "$r"

assert "malformed cutoff refuses to run" 1 "is not YYYY-MM-DD" \
  env ENFORCE_CONTRIBUTING_FROM="soon" "$DOCS" "$r"
assert "missing repo root errors" 1 "is not a directory" \
  env DOCS_TODAY="$AFTER" "$DOCS" "$WORK/does-not-exist"

echo
echo "=== check-package-policy.sh ==="

r=$(mkrepo pkg-guix guix.scm)
assert "guix.scm passes" 0 "Guix package management detected" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

r=$(mkrepo pkg-manifest manifest.scm)
assert "manifest.scm passes" 0 "Guix package management detected" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

r=$(mkrepo pkg-nix flake.nix)
assert "Nix-only packaging BLOCKS after retirement" 1 "Nix-only packaging is not compliant" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

# Preserve the historical grace seam without reviving the retired policy: a
# pre-retirement Nix-only repo warns and makes no pass claim.
assert "Nix-only packaging warns before retirement" 0 "NOT YET ENFORCED" \
  env PKG_TODAY="2026-05-31" "$PKG" "$r"

# A Guix scaffold must not hide Nix-only packaging when no profile is present.
r=$(mkrepo pkg-nix-stub-undeclared flake.nix guix.scm)
stub_guix "$r/guix.scm"
assert "Nix + Guix stub, no profile: warns before retirement" 0 "NOT YET ENFORCED" \
  env PKG_TODAY="2026-05-31" "$PKG" "$r"
assert "Nix + Guix stub, no profile: BLOCKS on retirement cutoff" 1 "Nix-only packaging is not compliant" \
  env PKG_TODAY="2026-06-01" "$PKG" "$r"
assert "Nix + Guix stub, no profile: BLOCKS after retirement" 1 "Nix-only packaging is not compliant" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

# Same repo, both sides of the cutoff — the self-flipping proof.
r=$(mkrepo pkg-none README.adoc)
declare "$r" reproducible-build
assert "no packaging warns pre-cutoff (no pass claimed)" 0 "NOT YET ENFORCED" \
  env PKG_TODAY="$BEFORE" "$PKG" "$r"
assert "no packaging BLOCKS post-cutoff" 1 "Package policy violation" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

# Tightened predicate: a stray Guile file is not packaging. The replaced step
# accepted this via `find . -name "*.scm"`.
r=$(mkrepo pkg-stray-scm src/helpers.scm)
declare "$r" reproducible-build
assert "stray .scm does NOT satisfy the policy" 1 "Package policy violation" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

# Vendored trees must not satisfy the policy on the repo's behalf.
r=$(mkrepo pkg-vendored node_modules/foo/guix.scm)
declare "$r" reproducible-build
assert "guix.scm in node_modules does not count" 1 "Package policy violation" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

r=$(mkrepo pkg-deps deps/bar/flake.nix)
declare "$r" reproducible-build
assert "flake.nix in deps/ does not count" 1 "Package policy violation" \
  env PKG_TODAY="$AFTER" "$PKG" "$r"

assert "malformed cutoff refuses to run" 1 "is not YYYY-MM-DD" \
  env ENFORCE_PACKAGE_POLICY_FROM="2026-8-21" "$PKG" "$r"

# Regression: `find | head -1` under `set -o pipefail` takes SIGPIPE on trees
# big enough that find is still writing when head exits, which aborted the
# script under `set -e` and red the repo for no policy reason. Small fixtures
# cannot reproduce it — this one is deliberately large, and repeated, because
# the race is nondeterministic.
# The race needs find to still be WRITING when head exits, so the fixture needs
# many *matching* paths, not merely many files: a single match emits one line
# and head never closes the pipe early.
r=$(mkrepo pkg-large guix.scm)
mkdir -p "$r/deep"
for i in $(seq 1 4000); do
  mkdir -p "$r/deep/d$i"; : > "$r/deep/d$i/manifest.scm"
done
race_fail=0
for _ in $(seq 1 15); do
  PKG_TODAY="$AFTER" "$PKG" "$r" >/dev/null 2>&1 || race_fail=1
done
if [ "$race_fail" -eq 0 ]; then
  echo "PASS: large tree does not SIGPIPE-abort (15 runs)"
  pass=$((pass + 1))
else
  echo "FAIL: large tree SIGPIPE-aborted — pipefail race regression"
  fail=$((fail + 1))
fi

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] || exit 1
