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

# Differential run. With no parser forced, the whole suite runs once under
# the awk tokenizer and once under the validated AST (deed_lint.js
# --ast-json), and every assertion must hold under both. A forced mode
# (RSR_DEED_PARSER=awk|ast) runs that mode only.
if [ -z "${RSR_DEED_PARSER:-}" ]; then
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _modes="awk"
  if command -v bun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
     && [ -f "$_here/../../1-formats/deed/tools/deed_lint.js" ]; then
    _modes="awk ast"
  else
    echo "NOTE: bun, jq or deed_lint.js unavailable; the AST half of the differential run is skipped"
  fi
  _rc=0
  for _m in $_modes; do
    echo "######## RSR_DEED_PARSER=$_m"
    RSR_DEED_PARSER=$_m bash "${BASH_SOURCE[0]}" || _rc=1
  done
  exit "$_rc"
fi
MODE="$RSR_DEED_PARSER"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../check-rsr-profile.sh"
# An explicit RSR_DEED_PARSER=auto resolves exactly as the resolver does, so
# the expectations below follow the parser that will actually run.
if [ "$MODE" = auto ]; then
  if command -v bun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
     && [ -f "${DEED_LINT:-$SCRIPT_DIR/../../1-formats/deed/tools/deed_lint.js}" ]; then
    MODE="ast"
  else
    MODE="awk"
  fi
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

assert() { # label want-status needle cmd...
  local label="$1" want="$2" needle="$3"; shift 3
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $status"
    echo "      $(grep -E '^  |FAIL' <<<"$out" | head -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! grep -qF -- "$needle" <<<"$out"; then
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
  printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed\n  :schema-version "1.0.0"\n  :canonical-name "%s"\n  :repo-uuid #u8"gv-clade-index:github.com/o/%s"\n  :beholding-chora #u8"chora:estate/github.com/o"\n%b)\n' "$1" "$1" "$2" > "$d/${1}_chora.deed"
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

d=$(repo_deed deedcomment '  ; (rsr-profile :version "1.0.0" :capabilities ("rust"))\n')
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
printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(estate-deed :schema-version "1.0.0" :canonical-name "estate" :estate-uuid #u8"chora:estate/github.com/o")\n' > "$d/estate_chora.deed"
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

d=$(repo_deed deedstrfield '  (rsr-profile :version "1.0.0" :declares-against "write :capabilities (bash) and :role \\"spine\\" here" :capabilities ("rust"))')
assert "field-shaped text inside a top-level string is not a field" 0 "effective capabilities: rust" bash "$CHECK" "$d"

d=$(repo_deed deedmultiline '  (rsr-profile\n    :version "1.0.0" ; a comment\n    :capabilities (\n      "rust"))\n')
assert "a clause head at line end and a list across lines resolve" 0 "effective capabilities: rust" bash "$CHECK" "$d"

d=$(repo dotdeed)
rm -f "$d/.machine_readable/rsr-profile.a2ml"
printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed :schema-version "1.0.0" :canonical-name ".github" :repo-uuid #u8"gv-clade-index:github.com/o/.github" :beholding-chora #u8"chora:estate/github.com/o"\n  (rsr-profile :version "1.0.0" :capabilities ("rust")))\n' > "$d/.github_chora.deed"
assert "a dot-prefixed repo deed (.github_chora.deed) is found" 0 ".github_chora.deed (rsr-profile …)" bash "$CHECK" "$d"

# Escapes and typed atoms (CodeRabbit and Codex on #1361).
d=$(repo_deed deedescrole '  (rsr-profile :version "1.0.0" :role "spi\\ne" :capabilities ("bash"))')
rm -f "$d/Cargo.toml" "$d/Cargo.lock" "$d/src/main.rs"
assert "an escaped \\n in :role does not alias spine" 1 "VESTIGIAL" bash "$CHECK" "$d"

d=$(repo_deed deedescremove '  (rsr-profile :version "1.0.0" :capabilities ("rust") :remove ("rus\\t"))')
assert "an escaped \\t in :remove does not remove rust" 0 "effective capabilities: rust" bash "$CHECK" "$d"

# A string whose escapes decode to a newline then a field-shaped tail must
# stay one field (Codex and GitHub Advanced Security on #1411). The AST
# decodes \n and \t; written back raw, the tail would forge a record.
d=$(repo_deed deedforgerole '  (rsr-profile :version "1.0.0" :declares-against "x\\nS\\trole\\tspine" :capabilities ("bash"))')
rm -f "$d/Cargo.toml" "$d/Cargo.lock" "$d/src/main.rs"
assert "a \\n-led field-shaped tail in a string does not forge :role spine" 1 "VESTIGIAL" bash "$CHECK" "$d"

d=$(repo_deed deedforgeremove '  (rsr-profile :version "1.0.0" :declares-against "x\\nL\\tremove\\trust" :capabilities ("rust"))')
assert "a \\n-led field-shaped tail in a string does not forge a :remove item" 0 "effective capabilities: rust" bash "$CHECK" "$d"

d=$(repo_deed deedforgecount '  (rsr-profile :version "1.0.0" :declares-against "x\\nCOUNT\\t2" :capabilities ("rust"))')
assert "a \\n-led COUNT tail in a string does not forge a second clause" 0 "rsr-profile check: OK" bash "$CHECK" "$d"

# The caller's tree is untrusted: a bunfig.toml preload in the working
# directory must not run when the AST parser reads the deed (CodeRabbit on
# #1411). The resolver runs from inside the repo here, as the gate job does.
if [ "$MODE" = ast ]; then
  d=$(repo_deed deedbunfig '  (rsr-profile :version "1.0.0" :capabilities ("rust"))')
  printf 'preload = ["./preload.js"]\n' > "$d/bunfig.toml"
  printf 'require("fs").writeFileSync("%s/PRELOAD-RAN", "x");\n' "$d" > "$d/preload.js"
  assert "a caller bunfig.toml preload does not run in the deed parser" 0 "rsr-profile check: OK" bash -c 'cd "$1" && bash "$2" .' _ "$d" "$CHECK"
  if [ -e "$d/PRELOAD-RAN" ]; then echo "FAIL: …the caller's preload ran"; fail=$((fail + 1)); else echo "PASS: …and the caller's preload did not run"; pass=$((pass + 1)); fi
fi

d=$(repo_deed deedescunkremove '  (rsr-profile :version "1.0.0" :capabilities ("rust") :remove ("r\\ust"))')
if [ "$MODE" = ast ]; then
  assert "an unknown escape is not DEED: the AST path refuses the deed" 2 "does not parse as DEED" bash "$CHECK" "$d"
else
  assert "an unknown escape in :remove does not remove rust" 0 "effective capabilities: rust" bash "$CHECK" "$d"
fi

d=$(repo_deed deedescunkrole '  (rsr-profile :version "1.0.0" :role "s\\pine" :capabilities ("bash"))')
rm -f "$d/Cargo.toml" "$d/Cargo.lock" "$d/src/main.rs"
if [ "$MODE" = ast ]; then
  assert "an unknown escape in :role is not DEED: refused, never read as spine" 2 "does not parse as DEED" bash "$CHECK" "$d"
else
  assert "an unknown escape in :role does not alias spine" 1 "VESTIGIAL" bash "$CHECK" "$d"
fi

d=$(repo_deed deeduuiditem '  (rsr-profile :version "1.0.0" :capabilities (#u5"rust"))')
assert "a uuid literal in a list is not a capability" 2 "-" bash "$CHECK" "$d"

d=$(repo dotglob)
rm -f "$d/.machine_readable/rsr-profile.a2ml"
printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed :schema-version "1.0.0" :canonical-name ".github" :repo-uuid #u8"gv-clade-index:github.com/o/.github" :beholding-chora #u8"chora:estate/github.com/o"\n  (rsr-profile :version "1.0.0" :capabilities ("rust")))\n' > "$d/.github_chora.deed"
assert "with dotglob on, a dot-led deed is still one deed" 0 ".github_chora.deed (rsr-profile …)" bash -O dotglob "$CHECK" "$d"

d=$(repo_deed deedfailglob '  (rsr-profile :version "1.0.0" :capabilities ("rust"))')
assert "with failglob on, one unmatched deed pattern does not abort the scan" 0 "deedfailglob_chora.deed (rsr-profile …)" bash -O failglob "$CHECK" "$d"

# One grammar owns the clause's keys (A7 J39): an unknown field or clause
# refuses the clause, in both parser modes, and the awk path's copy of the key
# set is the module's.
d=$(repo_deed deedunkfield '  (rsr-profile :version "1.0.0" :description "x" :capabilities ("rust"))')
assert "an unknown (rsr-profile …) field refuses the clause" 2 "J39" bash "$CHECK" "$d"
d=$(repo_deed deedunkclause '  (rsr-profile :version "1.0.0" :capabilities ("rust") (extras :x "y"))')
assert "an unknown (rsr-profile …) sub-clause refuses the clause" 2 "J39" bash "$CHECK" "$d"
d=$(repo_deed deedunkparen '  (rsr-profile :version "1.0.0" :declares-against "(extras)" :capabilities ("rust"))')
assert "a parenthesis inside a string is not a sub-clause" 0 "rsr-profile check: OK" bash "$CHECK" "$d"
# (notes …) is prose only on both paths (Codex on #1605): a nested form or a
# repeated name inside it refuses the clause.
d=$(repo_deed deednotesnest '  (rsr-profile :version "1.0.0" :capabilities ("rust") (notes (more)))')
assert "a nested form inside (notes …) refuses the clause" 2 "prose only" bash "$CHECK" "$d"
d=$(repo_deed deednotesdup '  (rsr-profile :version "1.0.0" :capabilities ("rust") (notes :why "a" :why "b"))')
assert "a repeated name inside (notes …) refuses the clause" 2 "once" bash "$CHECK" "$d"
# A list after a :keyword is the field's value, never a sub-clause, even when
# its items are symbols. The module wants strings, which only the AST path
# can check; the awk path checks keys alone.
d=$(repo_deed deedsymlist '  (rsr-profile :version "1.0.0" :capabilities (rust))')
if [ "$MODE" = ast ]; then
  assert "a symbol capability list is refused by the module (strings only)" 2 "list of non-empty strings" bash "$CHECK" "$d"
else
  assert "a symbol capability list is a list, not a (rust) sub-clause" 0 "effective capabilities: rust" bash "$CHECK" "$d"
fi
_lint="${DEED_LINT:-$SCRIPT_DIR/../../1-formats/deed/tools/deed_lint.js}"
if command -v bun >/dev/null 2>&1 && [ -f "$_lint" ]; then
  _module="$(bun "$_lint" --rsr-profile-keys | tr '\n' ' ' | sed 's/ $//')"
  _script="$(sed -n 's/^RSR_PROFILE_KEYS="\(.*\)"$/\1/p' "$CHECK")"
  if [ -n "$_script" ] && [ "$_module" = "$_script" ]; then
    echo "PASS: the checker's key set is the module's (deed_lint.js --rsr-profile-keys)"; pass=$((pass + 1))
  else
    echo "FAIL: the checker's key set differs from the module's: script '$_script', module '$_module'"; fail=$((fail + 1))
  fi
fi

echo "=== (layout …): the deed declares where a gated module lives (owner ruling 2026-11-16) ==="
# abi_repo <name> <profile-body>: a conforming rust scaffold that also carries
# an ABI the spine's way, with its package in src/interface/, not the root.
abi_repo() {
  local d; d="$(repo_deed "$1" "$2")"
  mkdir -p "$d/src/interface/Abi" "$d/src/interface/generated"
  : > "$d/src/interface/abi.ipkg"; : > "$d/src/interface/Abi/Types.idr"
  printf '%s' "$d"
}
ABI_CAPS=':version "1.0.0" :capabilities ("rust" "abi")'
d=$(abi_repo layoutnone "  (rsr-profile $ABI_CAPS)")
assert "control: without a binding the table's root abi.ipkg is MISSING (rsr-template-repo#421)" 1 "MISSING (abi): abi.ipkg" bash "$CHECK" "$d"
d=$(abi_repo layoutok "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\" :at (\"src/interface/abi.ipkg\"))))")
assert "a bound abi.ipkg in src/interface/ satisfies the abi row" 0 "bound by (layout): abi.ipkg -> src/interface/abi.ipkg" bash "$CHECK" "$d"
assert "…and the scaffold passes" 0 "rsr-profile check: OK" bash "$CHECK" "$d"
d=$(abi_repo layoutgone "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\" :at (\"src/interface/abi.ipkg\"))))")
rm "$d/src/interface/abi.ipkg"
assert "a declared path that is missing fails loudly" 1 "MISSING (abi): src/interface/abi.ipkg (bound by (layout)" bash "$CHECK" "$d"
: > "$d/abi.ipkg"
assert "…and the table's default does not stand in for it: the deed is authoritative" 1 "MISSING (abi): src/interface/abi.ipkg" bash "$CHECK" "$d"
d=$(abi_repo layouttwoat "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\" :at (\"src/interface/abi.ipkg\" \"pkg/abi.ipkg\"))))")
assert "every :at path is owed, not any one of them" 1 "MISSING (abi): pkg/abi.ipkg" bash "$CHECK" "$d"
d=$(abi_repo layoutvest '  (rsr-profile :version "1.0.0" :capabilities ("rust") (layout (module :gate "abi.ipkg" :at ("src/interface/abi.ipkg"))))')
rm -rf "$d/src/interface/Abi" "$d/src/interface/generated"
assert "a bound path present without its capability is VESTIGIAL" 1 "VESTIGIAL (no 'abi' capability): src/interface/abi.ipkg" bash "$CHECK" "$d"
rm "$d/src/interface/abi.ipkg"
assert "a binding that names a path the tree no longer carries is STALE" 1 "STALE (layout): src/interface/abi.ipkg" bash "$CHECK" "$d"
d=$(abi_repo layoutspine '  (rsr-profile :version "1.0.0" :role "spine" :capabilities ("rust") (layout (module :gate ".github/workflows/rust-ci.yml" :at ("ci/rust-ci.yml"))))')
assert "a spine's [carrier] row does not excuse a missing bound path" 1 "MISSING (rust): ci/rust-ci.yml" bash "$CHECK" "$d"
d=$(repo_deed layoutglob '  (rsr-profile :version "1.0.0" :capabilities ("rust") (layout (module :gate "**/src/**/*.rs" :at ("src/main.rs"))))')
assert "a glob row binds to a path its last segment matches" 0 "bound by (layout): **/src/**/*.rs -> src/main.rs" bash "$CHECK" "$d"
d=$(repo_deed layoutglobkind '  (rsr-profile :version "1.0.0" :capabilities ("rust") (layout (module :gate "**/src/**/*.rs" :at ("src/main.c"))))')
: > "$d/src/main.c"
assert "…and refuses one it does not" 2 "does not match \"*.rs\"" bash "$CHECK" "$d"
d=$(repo_deed layoutcf '  (rsr-profile :version "1.0.0" :capabilities ("rust" "container") (layout (module :gate "Containerfile" :at ("deploy/Containerfile"))))')
mkdir -p "$d/deploy"; : > "$d/deploy/Containerfile"
assert "an empty bound Containerfile is MISSING: the shape follows the artefact, not its row" 1 "MISSING (container): deploy/Containerfile" bash "$CHECK" "$d"
echo 'FROM scratch' > "$d/deploy/Containerfile"
assert "…and a non-empty one satisfies it" 0 "bound by (layout): build/container/Containerfile or container/Containerfile or Containerfile -> deploy/Containerfile" bash "$CHECK" "$d"
d=$(repo_deed layoutproof '  (rsr-profile :version "1.0.0" :capabilities ("rust" "formal-proofs") (layout (module :gate "proofs/agda/" :at ("theory/agda/"))))')
mkdir -p "$d/theory/agda"; echo prose > "$d/theory/agda/README.adoc"
assert "a bound proof directory of prose only is MISSING" 1 "MISSING (formal-proofs): theory/agda/" bash "$CHECK" "$d"
echo "module T where" > "$d/theory/agda/T.agda"
assert "…and one with a prover source satisfies it" 0 "rsr-profile check: OK" bash "$CHECK" "$d"
# A binding the gate table cannot place is a profile defect (exit 2).
d=$(abi_repo layoutnorow "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.toml\" :at (\"src/interface/abi.toml\"))))")
assert "a :gate that names no [gates] row is refused" 2 "names no [gates] row" bash "$CHECK" "$d"
d=$(abi_repo layoutbase "  (rsr-profile $ABI_CAPS (layout (module :gate \"LICENSE\" :at (\"docs/LICENSE\"))))")
assert "a [baseline] row is not bindable" 2 "names a [baseline] row" bash "$CHECK" "$d"
d=$(abi_repo layoutrename "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\" :at (\"src/interface/other.ipkg\"))))")
: > "$d/src/interface/other.ipkg"
assert "a binding cannot rename what the row asks for" 2 "does not match \"abi.ipkg\"" bash "$CHECK" "$d"
d=$(abi_repo layoutkind "  (rsr-profile $ABI_CAPS (layout (module :gate \"src/interface/generated/\" :at (\"src/interface/gen\"))))")
: > "$d/src/interface/gen"
assert "a directory row is bound to a directory" 2 "a directory row is bound to a directory path" bash "$CHECK" "$d"
d=$(abi_repo layoutrowtwice "  (rsr-profile $ABI_CAPS (layout (module :gate \"src/interface/abi/\" :at (\"src/interface/Abi/\")) (module :gate \"src/interface/Abi/\" :at (\"src/interface/Abi/\"))))")
assert "one row bound twice, by two of its alternatives, is refused" 2 "twice" bash "$CHECK" "$d"
d=$(abi_repo layoutgatetwice "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\" :at (\"src/interface/abi.ipkg\")) (module :gate \"abi.ipkg\" :at (\"x/abi.ipkg\"))))")
assert "one :gate bound twice is refused" 2 "once" bash "$CHECK" "$d"
d=$(abi_repo layoutdotdot "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\" :at (\"../abi.ipkg\"))))")
assert "an :at path outside the repo is refused" 2 ". or .. segment" bash "$CHECK" "$d"
d=$(abi_repo layoutpattern "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\" :at (\"src/*/abi.ipkg\"))))")
assert "an :at pattern is refused: a binding names a path" 2 "is a pattern" bash "$CHECK" "$d"
d=$(abi_repo layoutesc "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\" :at (\"src\\\\ninterface/abi.ipkg\"))))")
assert "an escape in an :at path is refused on either parser" 2 "control character or a backslash" bash "$CHECK" "$d"
d=$(abi_repo layoutfield "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\" :at (\"src/interface/abi.ipkg\") :why \"x\")))")
assert "an unknown (module …) field refuses the clause (J39)" 2 "J39" bash "$CHECK" "$d"
d=$(abi_repo layoutother "  (rsr-profile $ABI_CAPS (layout (path :gate \"abi.ipkg\" :at (\"src/interface/abi.ipkg\"))))")
assert "a (layout …) member other than (module …) refuses the clause (J39)" 2 "(module …) clauses only" bash "$CHECK" "$d"
d=$(abi_repo layoutempty "  (rsr-profile $ABI_CAPS (layout))")
assert "an empty (layout) is refused" 2 "at least one (module" bash "$CHECK" "$d"
d=$(abi_repo layoutnoat "  (rsr-profile $ABI_CAPS (layout (module :gate \"abi.ipkg\")))")
assert "a (module …) without :at is refused" 2 "missing :at" bash "$CHECK" "$d"
d=$(abi_repo layoutprose "  (rsr-profile $ABI_CAPS :declares-against \"(layout (module :gate \\\\\"abi.ipkg\\\\\" :at (\\\\\"src/interface/abi.ipkg\\\\\")))\")")
assert "layout-shaped text in a string binds nothing" 1 "MISSING (abi): abi.ipkg" bash "$CHECK" "$d"

echo "=== setup errors ==="
assert "no profile → 2" 2 "no profile at" bash "$CHECK" "$WORK/does-not-exist"
assert "missing gates table → 2" 2 "gates file not found" env RSR_GATES="$WORK/nope.toml" bash "$CHECK" "$(repo g)"

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
if [ "$MODE" = ast ]; then
  bash "$SCRIPT_DIR/check-rsr-current-layout-test.sh"
fi
