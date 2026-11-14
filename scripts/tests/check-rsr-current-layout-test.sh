#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Source-layout controls, not proof or container-build certification.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/../check-rsr-profile.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
count=0

fixture() {
  local target="$work/$1"
  mkdir -p "$target/proofs/agda" "$target/www/.well-known"
  for file in README.adoc EXPLAINME.adoc LICENSE SECURITY.md CONTRIBUTING.adoc CODE_OF_CONDUCT.adoc CHANGELOG.adoc .gitignore Justfile; do
    printf 'Fixture for the native source-layout checker.\n' > "$target/$file"
  done
  printf 'Contact: mailto:fixture@example.invalid\n' > "$target/www/.well-known/security.txt"
  printf 'FROM scratch\n' > "$target/Containerfile"
  cat > "$target/proofs/agda/Witness.agda" <<'AGDA'
{-# OPTIONS --safe --without-K --cubical-compatible #-}
module Witness where
data Unit : Set where unit : Unit
witness : Unit
witness = unit
AGDA
  write_deed "$target" '(manifest :version "1.0.0" :project "fixture" :purpose "Native reader fixture")' '(meta :languages (Agda))'
  printf '%s' "$target"
}

write_deed() {
  cat > "$1/fixture_chora.deed" <<EOF
;; SPDX-License-Identifier: CC-BY-SA-4.0
(repo-deed
  :schema-version "1.0.0"
  :canonical-name "fixture"
  :repo-uuid #u8"gv-clade-index:github.com/fixture/fixture"
  :beholding-chora #u8"chora:estate/github.com/o"
  (rsr-profile :version "1.0.0" :capabilities ("agda" "formal-proofs" "container"))
  $2
  $3)
EOF
}

assert() {
  local label="$1" expected="$2" needle="$3" target="$4" mode="${5:-ast}" result status
  status=0
  result="$(RSR_DEED_PARSER="$mode" bash "$check" "$target" 2>&1)" || status=$?
  if [ "$status" != "$expected" ] || ! grep -qF -- "$needle" <<< "$result"; then
    printf 'FAIL: %s (wanted exit %s, got %s)\n%s\n' "$label" "$expected" "$status" "$result" >&2
    exit 1
  fi
  count=$((count + 1))
  printf 'PASS: %s\n' "$label"
}

d=$(fixture modern)
assert 'one substantive deed, actual Agda source and root Containerfile pass' 0 'rsr-profile check: OK' "$d"
assert 'unvalidated awk mode does not claim folded metadata conformance' 2 'cannot validate the deed' "$d" awk

d=$(fixture empty-proof-directory)
rm "$d/proofs/agda/Witness.agda"
assert 'an empty proof directory fails' 1 'MISSING (formal-proofs)' "$d"
printf 'Proofs are intended here.\n' > "$d/proofs/agda/README.adoc"
assert 'a prose-only proof directory fails' 1 'MISSING (formal-proofs)' "$d"
: > "$d/proofs/agda/Empty.agda"
assert 'an empty Agda file fails' 1 'MISSING (formal-proofs)' "$d"

d=$(fixture traditional-proof-layout)
mkdir -p "$d/verification/proofs"
mv "$d/proofs/agda/Witness.agda" "$d/verification/proofs/Witness.agda"
assert 'the traditional proof layout still accepts real source' 0 'rsr-profile check: OK' "$d"

d=$(fixture missing-container)
rm "$d/Containerfile"
mkdir "$d/container"
assert 'an empty container directory fails' 1 'MISSING (container)' "$d"
: > "$d/container/Containerfile"
assert 'an empty Containerfile fails' 1 'MISSING (container)' "$d"
printf 'FROM scratch\n' > "$d/container/Containerfile"
assert 'the traditional Containerfile location still passes' 0 'rsr-profile check: OK' "$d"

for variant in missing empty wrong-project quoted nested duplicate; do
  d=$(fixture "manifest-$variant")
  case "$variant" in
    missing) manifest='' ;;
    empty) manifest='(manifest)' ;;
    wrong-project) manifest='(manifest :version "1.0.0" :project "another-repo" :purpose "Wrong identity")' ;;
    quoted) manifest='(notes :example "(manifest :version 1)")' ;;
    nested) manifest='(notes (manifest :version "1.0.0" :project "fixture" :purpose "Nested decoy"))' ;;
    duplicate) manifest='(manifest :version "1.0.0" :project "fixture" :purpose "First") (manifest :version "1.0.0" :project "fixture" :purpose "Second")' ;;
  esac
  write_deed "$d" "$manifest" '(meta :languages (Agda))'
  assert "$variant manifest does not replace the baseline obligation" 1 'MISSING BASELINE: 0-AI-MANIFEST' "$d"
done

for field in canonical-name project version purpose; do
  for variant in duplicate wrong-type; do
    d=$(fixture "manifest-$field-$variant")
    if [ "$field" = canonical-name ]; then
      if [ "$variant" = duplicate ]; then
        sed -i 's/:canonical-name "fixture"/:canonical-name "fixture" :canonical-name "another-repo"/' "$d/fixture_chora.deed"
      else
        sed -i 's/:canonical-name "fixture"/:canonical-name (fixture)/' "$d/fixture_chora.deed"
      fi
    else
      case "$field" in
        project) value='"fixture"' ;;
        version) value='"1.0.0"' ;;
        purpose) value='"Native reader fixture"' ;;
      esac
      if [ "$variant" = duplicate ]; then
        sed -i "/(manifest /s/:$field $value/:$field $value :$field $value/" "$d/fixture_chora.deed"
      else
        sed -i "/(manifest /s/:$field $value/:$field (invalid-type)/" "$d/fixture_chora.deed"
      fi
    fi
    assert "$variant $field does not establish a manifest" 1 'MISSING BASELINE: 0-AI-MANIFEST' "$d"
  done
done

for variant in missing empty quoted nested; do
  d=$(fixture "description-$variant")
  case "$variant" in
    missing) description='' ;;
    empty) description='(meta)' ;;
    quoted) description='(notes :example "(meta :languages (Agda))")' ;;
    nested) description='(notes (meta :languages (Agda)))' ;;
  esac
  write_deed "$d" '(manifest :version "1.0.0" :project "fixture" :purpose "Native reader fixture")' "$description"
  assert "$variant descriptions do not replace the baseline obligation" 1 'MISSING BASELINE: .machine_readable/descriptiles/' "$d"
done

d=$(fixture malformed)
printf '(' >> "$d/fixture_chora.deed"
assert 'a malformed deed fails native parsing' 2 'does not parse as DEED' "$d"
d=$(fixture duplicate-deed)
cp "$d/fixture_chora.deed" "$d/second_chora.deed"
assert 'a second repo deed fails closed' 2 'one-deed-per-repo' "$d"
printf 'Current-layout controls: %s passed.\n' "$count"
