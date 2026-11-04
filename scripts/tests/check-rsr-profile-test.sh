#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# check-rsr-profile-test.sh — fixture suite for scripts/check-rsr-profile.sh.
#
# Covers the three defects fixed on 2026-10-25:
#   #1228  the rust source row was root-anchored, so a cargo WORKSPACE could
#          never satisfy it and posted a permanent MISSING;
#   #1227  [baseline] had no reader at all — a repo could pass while missing
#          its LICENSE (the .well-known row also predated the www/ migration);
#   #1229  the baseline demanded 0-AI-MANIFEST.a2ml after the template retired
#          that spelling for .deed.
# Plus the carrier-list parse fix: the [carrier]/[canon] arrays are multi-line
# and were read with a single-line reader, so no entry ever applied.
#
# Run: bash scripts/tests/check-rsr-profile-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../check-rsr-profile.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

assert() { # label want-status needle cmd...
  local label="$1" want="$2" needle="$3"; shift 3
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $status"
    echo "      $(printf '%s' "$out" | grep -E '^  |FAIL' | head -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: $label — exit ok, output lacked '$needle'"
    echo "      $(printf '%s' "$out" | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

# repo <dir> — every baseline artefact, using the ALTERNATE spellings that the
# 2026-10 estate uses (.deed manifest, www/.well-known, district guides), so the
# fixtures also prove the alternations resolve.
repo() {
  local d="$WORK/$1"; mkdir -p "$d/.machine_readable/descriptiles" "$d/www/.well-known" "$d/3-practice"
  : > "$d/README.adoc"; : > "$d/EXPLAINME.adoc"; : > "$d/LICENSE"; : > "$d/SECURITY.md"
  : > "$d/3-practice/CONTRIBUTING.adoc"; : > "$d/3-practice/CODE_OF_CONDUCT.adoc"
  : > "$d/CHANGELOG.adoc"; : > "$d/0-AI-MANIFEST.deed"; : > "$d/.gitignore"; : > "$d/Justfile"
  : > "$d/www/.well-known/security.txt"
  # A CONFORMING rust single-crate scaffold by default, so every fixture starts
  # green and each test mutates exactly the one thing it is about. A repo that
  # declares `rust` owes all four rust rows, because declaring a capability is a
  # claim the module set backs up.
  mkdir -p "$d/src" "$d/.github/workflows"
  : > "$d/Cargo.toml"; : > "$d/Cargo.lock"; : > "$d/src/main.rs"
  : > "$d/.github/workflows/rust-ci.yml"
  printf '[rsr-profile]\nversion = "1.0.0"\ncapabilities = ["rust"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
  printf '%s' "$d"
}

echo "=== #1228 cargo workspace vs root-anchored glob ==="
d=$(repo ws)
mkdir -p "$d/crates/a/src" "$d/crates/b/src"
: > "$d/crates/a/Cargo.toml"; : > "$d/crates/a/Cargo.lock"; : > "$d/crates/a/src/lib.rs"
: > "$d/crates/b/Cargo.toml"; : > "$d/crates/b/Cargo.lock"; : > "$d/crates/b/src/lib.rs"
assert "workspace: nested src+manifest satisfies rust (was a permanent MISSING)" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

d=$(repo single)
assert "single crate at the root still passes (both layouts resolve)" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

d=$(repo ws2); rm -rf "$d/src" "$d/Cargo.toml"
mkdir -p "$d/crates/a/src"; : > "$d/crates/a/Cargo.toml"; : > "$d/crates/a/src/lib.rs"
assert "workspace with NO root manifest still passes (no root src/ required)" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

echo "=== #1227 baseline is enforced ==="
d=$(repo nolicence); rm "$d/LICENSE"
assert "missing LICENSE → MISSING BASELINE, exit 1" 1 "MISSING BASELINE" bash "$CHECK" "$d"

d=$(repo wellknown); rm -rf "$d/www/.well-known"; mkdir -p "$d/.well-known"; : > "$d/.well-known/security.txt"
assert ".well-known/ at the root still conforms (pre-migration repositories)" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

d=$(repo nomanifest); rm "$d/0-AI-MANIFEST.deed"; : > "$d/0-AI-MANIFEST.a2ml"
assert "#1229: 0-AI-MANIFEST.a2ml still conforms" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

d=$(repo nomd); rm "$d/0-AI-MANIFEST.deed"
assert "no AI manifest in either spelling fails" 1 "MISSING BASELINE" bash "$CHECK" "$d"

echo "=== vestigial detection still works ==="
d=$(repo vestigial)
printf '[rsr-profile]\nversion = "1.0.0"\ncapabilities = ["bash"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
assert "rust sources without the rust capability → VESTIGIAL" 1 "VESTIGIAL" bash "$CHECK" "$d"
assert "…and the verdict names the row readably, not as a raw alternation" 1 "Cargo.toml or */Cargo.toml" bash "$CHECK" "$d"

echo "=== carrier lists actually parse (multi-line arrays) ==="
d=$(repo canonrole)
printf '[rsr-profile]\nversion = "1.0.0"\nrole = "canon"\ncapabilities = ["rust"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
rm "$d/.github/workflows/rust-ci.yml"
assert "a canon row listed in [canon] is exempt from MISSING" 0 "served for downstream" bash "$CHECK" "$d"

d=$(repo spinecarrier)
printf '[rsr-profile]\nversion = "1.0.0"\nrole = "spine"\ncapabilities = ["bash"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
rm -f "$d/Cargo.toml" "$d/Cargo.lock" "$d/src/main.rs"
assert "a spine row listed in [carrier] is exempt from VESTIGIAL" 0 "carried for downstream" bash "$CHECK" "$d"

echo "=== the deed form: (rsr-profile …) in the one <repo>_chora.deed ==="
# repo_deed <dir> <clause-body>: a conforming scaffold whose profile lives in
# the repo deed, as rsr-template-repo ships it (no .a2ml at all since #227).
# The header is the minimal valid repo-deed; the clause body is the caller's.
repo_deed() {
  local d; d="$(repo "$1")"; rm -f "$d/.machine_readable/rsr-profile.a2ml"
  printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed\n  :schema-version "1.0.0"\n  :canonical-name "%s"\n  :repo-uuid #u5"github.com/o/%s"\n  :beholding-chora #u5"estate/chora"\n%b)\n' "$1" "$1" "$2" > "$d/${1}_chora.deed"
  printf '%s' "$d"
}
d=$(repo_deed deedonly '  (rsr-profile :version "1.0.0" :capabilities ("rust"))')
assert "deed-only repo: capabilities read from the clause" 0 "(rsr-profile …)" bash "$CHECK" "$d"
assert "…and the scaffold passes on them" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

d=$(repo_deed deedlines '  (rsr-profile\n    :version "1.0.0"\n    ; a comment line inside the clause\n    :capabilities (\n      "rust"   ; trailing comment\n      )\n    (notes :omitted-rationale "x ; not a comment"))')
assert "multi-line list, inline comments and a nested (notes …) all parse" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

d=$(repo_deed deedwins '  (rsr-profile :version "1.0.0" :capabilities ("rust"))')
printf '[rsr-profile]\nversion = "1.0.0"\ncapabilities = ["bash"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
assert "deed clause wins over a legacy .a2ml beside it" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

d=$(repo_deed deedvest '  (rsr-profile :version "1.0.0" :capabilities ("bash"))')
assert "deed-declared capabilities drive VESTIGIAL exactly as the a2ml did" 1 "VESTIGIAL" bash "$CHECK" "$d"

d=$(repo_deed deedspine '  (rsr-profile :version "1.0.0" :role "spine" :capabilities ("bash"))')
rm -f "$d/Cargo.toml" "$d/Cargo.lock" "$d/src/main.rs"
assert "role read from the deed: spine carrier exemption applies" 0 "carried for downstream" bash "$CHECK" "$d"

d=$(repo_deed deedpreset '  (rsr-profile :version "1.0.0" :preset "cli-tool")')
assert "preset read from the deed (unknown names still fail loudly)" 2 "unknown preset" bash "$CHECK" "$d"

d=$(repo_deed deedcomment '  ; (rsr-profile :version "1.0.0" :capabilities ("rust"))')
assert "a commented-out clause is not a profile, and no a2ml means no profile" 2 "no (rsr-profile" bash "$CHECK" "$d"

d=$(repo_deed deedfallback '')
printf '[rsr-profile]\nversion = "1.0.0"\ncapabilities = ["rust"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
assert "deed without the clause falls back to the legacy a2ml" 0 "legacy .a2ml" bash "$CHECK" "$d"

d=$(repo_deed deedtwice '  (rsr-profile :version "1.0.0" :capabilities ("rust"))\n  (rsr-profile :version "1.0.0" :capabilities ("bash"))')
assert "two (rsr-profile …) clauses is a defect, not a choice" 2 "need exactly 1" bash "$CHECK" "$d"

d=$(repo_deed deedtwo '  (rsr-profile :version "1.0.0" :capabilities ("rust"))')
cp "$d/deedtwo_chora.deed" "$d/other_chora.deed"
assert "two *_chora.deed files is a defect (one deed per repo, D312)" 2 "expects exactly 1" bash "$CHECK" "$d"

d=$(repo_deed deedestate '  (rsr-profile :version "1.0.0" :capabilities ("rust"))')
printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(estate-deed :schema-version "1.0.0" :canonical-name "estate" :estate-uuid #u5"estate/chora")\n' > "$d/estate_chora.deed"
assert "estate_chora.deed beside the repo deed is the estate-deed, not a second repo deed" 0 "deedestate_chora.deed (rsr-profile …)" bash "$CHECK" "$d"

d=$(repo_deed deedprose '  (notes :example "a profile looks like (rsr-profile :capabilities (\\"rust\\"))")')
printf '[rsr-profile]\nversion = "1.0.0"\ncapabilities = ["bash"]\n' > "$d/.machine_readable/rsr-profile.a2ml"
assert "profile-shaped text inside a deed string is prose: the legacy a2ml still wins" 1 "legacy .a2ml" bash "$CHECK" "$d"
assert "…and its capabilities are the a2ml's (bash → rust sources are VESTIGIAL)" 1 "VESTIGIAL" bash "$CHECK" "$d"

d=$(repo_deed deedproseonly '  (notes :example "(rsr-profile :capabilities (\\"rust\\"))")')
assert "profile-shaped text in a string with no a2ml is no profile at all" 2 "no (rsr-profile" bash "$CHECK" "$d"

d=$(repo_deed deednested '  (rsr-profile :version "1.0.0" (notes :example "write :capabilities (bash) here" :role "spine") :capabilities ("rust"))')
assert "fields are read from the profile clause itself, not from a nested (notes …) or its strings" 0 "effective capabilities: rust" bash "$CHECK" "$d"
assert "…and its :role is not the profile's role" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

# Role-sensitive: without the spine role the undeclared rust workflow is
# VESTIGIAL (exit 1); reading the nested :role would exempt it (exit 0).
d=$(repo_deed deednestedrole '  (rsr-profile :version "1.0.0" (notes :role "spine") :capabilities ("bash"))')
rm -f "$d/Cargo.toml" "$d/Cargo.lock" "$d/src/main.rs"
assert "a :role inside a nested clause does not make the repo a spine" 1 "VESTIGIAL" bash "$CHECK" "$d"

d=$(repo_deed deedstrfield '  (rsr-profile :version "1.0.0" :description "write :capabilities (bash) and :role \\"spine\\" here" :capabilities ("rust"))')
assert "field-shaped text inside a top-level string is not a field" 0 "effective capabilities: rust" bash "$CHECK" "$d"

d=$(repo_deed deedmultiline '  (rsr-profile\n    :version "1.0.0" ; a comment\n    :capabilities (\n      "rust"))\n')
assert "a clause head at line end and a list across lines resolve" 0 "effective capabilities: rust" bash "$CHECK" "$d"

d=$(repo dotdeed)
rm -f "$d/.machine_readable/rsr-profile.a2ml"
printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed :schema-version "1.0.0" :canonical-name ".github" :repo-uuid #u5"github.com/o/.github" :beholding-chora #u5"estate/chora"\n  (rsr-profile :version "1.0.0" :capabilities ("rust")))\n' > "$d/.github_chora.deed"
assert "a dot-prefixed repo deed (.github_chora.deed) is found" 0 ".github_chora.deed (rsr-profile …)" bash "$CHECK" "$d"

# Escapes and typed atoms (CodeRabbit and Codex on #1361).
d=$(repo_deed deedescrole '  (rsr-profile :version "1.0.0" :role "spi\\ne" :capabilities ("bash"))')
rm -f "$d/Cargo.toml" "$d/Cargo.lock" "$d/src/main.rs"
assert "an escaped \\n in :role does not alias spine" 1 "VESTIGIAL" bash "$CHECK" "$d"

d=$(repo_deed deedescremove '  (rsr-profile :version "1.0.0" :capabilities ("rust") :remove ("rus\\t"))')
assert "an escaped \\t in :remove does not remove rust" 0 "effective capabilities: rust" bash "$CHECK" "$d"

d=$(repo_deed deedescunkremove '  (rsr-profile :version "1.0.0" :capabilities ("rust") :remove ("r\\ust"))')
assert "an unknown escape in :remove does not remove rust" 0 "effective capabilities: rust" bash "$CHECK" "$d"

d=$(repo_deed deedescunkrole '  (rsr-profile :version "1.0.0" :role "s\\pine" :capabilities ("bash"))')
rm -f "$d/Cargo.toml" "$d/Cargo.lock" "$d/src/main.rs"
assert "an unknown escape in :role does not alias spine" 1 "VESTIGIAL" bash "$CHECK" "$d"

d=$(repo_deed deeduuiditem '  (rsr-profile :version "1.0.0" :capabilities (#u5"rust"))')
assert "a uuid literal in a list is not a capability" 2 "-" bash "$CHECK" "$d"

d=$(repo dotglob)
rm -f "$d/.machine_readable/rsr-profile.a2ml"
printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed :schema-version "1.0.0" :canonical-name ".github" :repo-uuid #u5"github.com/o/.github" :beholding-chora #u5"estate/chora"\n  (rsr-profile :version "1.0.0" :capabilities ("rust")))\n' > "$d/.github_chora.deed"
assert "with dotglob on, a dot-led deed is still one deed" 0 ".github_chora.deed (rsr-profile …)" bash -O dotglob "$CHECK" "$d"

d=$(repo_deed deedfailglob '  (rsr-profile :version "1.0.0" :capabilities ("rust"))')
assert "with failglob on, one unmatched deed pattern does not abort the scan" 0 "deedfailglob_chora.deed (rsr-profile …)" bash -O failglob "$CHECK" "$d"

echo "=== setup errors ==="
assert "no profile → 2" 2 "no profile at" bash "$CHECK" "$WORK/does-not-exist"
assert "missing gates table → 2" 2 "gates file not found" env RSR_GATES="$WORK/nope.toml" bash "$CHECK" "$(repo g)"

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
