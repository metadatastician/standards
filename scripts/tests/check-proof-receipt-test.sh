#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves scripts/check-proof-receipt.sh checks the warrant of PROOF-POLICY
# §8.5.3 with git: a receipt earned on a pull-request commit and carried to
# its squash commit by an echo passes, and each forged or broken case fails
# for its own reason.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/check-proof-receipt.sh"
DIGEST="$ROOT/scripts/proof-inputs-sha256.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
# expect LABEL EXIT FRAGMENT|- ARGS...
expect() {
  local label=$1 want_rc=$2 want_msg=$3; shift 3
  local out rc=0
  out=$(bash "$CHECK" "$@" 2>&1) || rc=$?
  if [ "$rc" != "$want_rc" ]; then bad "$label (exit $rc, want $want_rc)"; printf '%s\n' "$out" | sed 's/^/        /' | head -20; return; fi
  if [ "$want_msg" != - ] && ! grep -qF -- "$want_msg" <<<"$out"; then bad "$label (no \"$want_msg\")"; printf '%s\n' "$out" | sed 's/^/        /' | head -20; return; fi
  ok "$label"
}

R="$WORK/repo"
git init -q -b main "$R"
git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
mkdir -p "$R/src"
printf 'module A where\n' >"$R/src/A.agda"
printf 'name: x\ninclude: src\n' >"$R/x.agda-lib"
printf 'readme\n' >"$R/README.adoc"
git -C "$R" add -A; git -C "$R" commit -qm base

# A pull request: the receipt is earned on S, then docs change; a squash makes I.
git -C "$R" checkout -q -b pr
printf -- '-- proof\n' >>"$R/src/A.agda"; git -C "$R" commit -qam proof
S=$(git -C "$R" rev-parse HEAD)
printf 'docs\n' >>"$R/README.adoc"; git -C "$R" commit -qam docs
git -C "$R" checkout -q main
git -C "$R" merge -q --squash pr >/dev/null 2>&1; git -C "$R" commit -qm squash
I=$(git -C "$R" rev-parse HEAD)
# A commit off main whose input differs from S.
git -C "$R" checkout -q -b forged "$I"
printf -- '-- changed\n' >>"$R/src/A.agda"; git -C "$R" commit -qam forged
F=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main

PATHS=(src/A.agda x.agda-lib)
D=$(bash "$DIGEST" -C "$R" "$S" "${PATHS[@]}")
TREE_I=$(bash "$DIGEST" -C "$R" "$I")
manifest() { # COMMIT -> (file …) entries
  bash "$DIGEST" -C "$R" --manifest "$1" "${PATHS[@]}" | while read -r h p; do
    printf '        (file :path "%s" :sha256 "%s")\n' "$p" "$h"
  done
}
MANIFEST_S=$(manifest "$S")

# write NAME SOURCE-COMMIT RECEIPT-COMMIT DIGEST MANIFEST ECHO [IMPORTS] [CONTROLS]
write() {
  cat >"$WORK/$1_praxis.deed" <<EOF
;; SPDX-License-Identifier: CC-BY-SA-4.0
(praxis-deed
  :schema-version "1.0.0"
  :canonical-name "t"
  :profile proof-receipt
  :repository "o/t"
  :source-commit "$2"
$6
  (claim :id "T-1" :pwg PWG-3 :foundation-diverse #f
    (leg :prover agda :route source :token proven :state AGDA-VERIFIED
      (receipt :run "https://ci/run/1" :commit "$3" :checker "agda 2.6.4.3"
        :invocation "agda --safe --without-K --cubical-compatible"
        :inputs-sha256 "$4" :state current
        (inputs-manifest
$5)${7:-}
        (axioms)))
    (leg :prover rocq :route unavailable :reason "none yet")
    (leg :prover lean :route unavailable :reason "none yet")${8:-}))
EOF
}
ECHO_IN="  (echo :source \"$S\" :image \"$I\" :witness inputs-sha256 (inputs :prover agda :sha256 \"$D\"))"

write good "$I" "$S" "$D" "$MANIFEST_S" "$ECHO_IN"
expect "a receipt carried to its squash commit by an echo passes" 0 "every check holds" --branch main "$WORK/good_praxis.deed" "$R"

write direct "$S" "$S" "$D" "$MANIFEST_S" ""
expect "a :source-commit that is not on the default branch fails" 1 "is not on main" --branch main "$WORK/direct_praxis.deed" "$R"

write forged "$F" "$S" "$D" "$MANIFEST_S" "  (echo :source \"$S\" :image \"$F\" :witness inputs-sha256 (inputs :prover agda :sha256 \"$D\"))"
expect "a forged echo whose image changed an input fails" 1 "image: the manifest does not hold at $F" --branch forged "$WORK/forged_praxis.deed" "$R"

# A receipt whose manifest is self-consistent but false at its commit.
FAKE=$(printf '        (file :path "src/A.agda" :sha256 "%s")\n        (file :path "x.agda-lib" :sha256 "%s")\n' "$(printf '%064d' 1)" "$(printf '%064d' 2)")
FAKE_D=$(printf '%s  src/A.agda\n%s  x.agda-lib\n' "$(printf '%064d' 1)" "$(printf '%064d' 2)" | sha256sum | cut -d' ' -f1)
write fake "$I" "$S" "$FAKE_D" "$FAKE" "  (echo :source \"$S\" :image \"$I\" :witness inputs-sha256 (inputs :prover agda :sha256 \"$FAKE_D\"))"
expect "a manifest that is false at the receipt's commit fails" 1 "receipt: the manifest does not hold at $S" --branch main "$WORK/fake_praxis.deed" "$R"

MISSING=0123456789abcdef0123456789abcdef01234567
write missing "$I" "$MISSING" "$D" "$MANIFEST_S" "  (echo :source \"$MISSING\" :image \"$I\" :witness inputs-sha256 (inputs :prover agda :sha256 \"$D\"))"
expect "a source commit that is not in the clone fails" 1 "commit $MISSING is not in" --branch main "$WORK/missing_praxis.deed" "$R"

# tree-sha256: the PR head and the squash commit have the same tree.
H=$(git -C "$R" rev-parse pr)
write tree "$I" "$H" "$(bash "$DIGEST" -C "$R" "$H" "${PATHS[@]}")" "$(manifest "$H")" \
  "  (echo :source \"$H\" :image \"$I\" :witness tree-sha256 :tree-sha256 \"$TREE_I\")"
expect "a tree-sha256 echo over an equal tree passes" 0 "tree-sha256 holds at $I" --branch main "$WORK/tree_praxis.deed" "$R"

write treebad "$I" "$S" "$D" "$MANIFEST_S" "  (echo :source \"$S\" :image \"$I\" :witness tree-sha256 :tree-sha256 \"$TREE_I\")"
expect "a tree-sha256 echo over different trees fails" 1 "tree-sha256 at $S is" --branch main "$WORK/treebad_praxis.deed" "$R"

write unparsable "$I" "$S" "$D" "" "$ECHO_IN"
expect "a receipt the reader refuses fails" 1 "FAIL reader" --branch main "$WORK/unparsable_praxis.deed" "$R"

# An imported sibling repository, pinned at a commit and given by --import.
SIB="$WORK/sibling"
git init -q -b main "$SIB"
git -C "$SIB" config user.email t@example.invalid; git -C "$SIB" config user.name t
git -C "$SIB" config commit.gpgsign false
printf 'module Algebra where\n' >"$SIB/Algebra.agda"
git -C "$SIB" add -A; git -C "$SIB" commit -qm sib
SC=$(git -C "$SIB" rev-parse HEAD)
SD=$(bash "$DIGEST" -C "$SIB" "$SC" Algebra.agda)
SH=$(bash "$DIGEST" -C "$SIB" --manifest "$SC" Algebra.agda | cut -d' ' -f1)
IMPORT="
        (import :repository \"o/sibling\" :commit \"$SC\" :inputs-sha256 \"$SD\"
          (file :path \"Algebra.agda\" :sha256 \"$SH\"))"
write imported "$I" "$S" "$D" "$MANIFEST_S" "$ECHO_IN" "$IMPORT"
expect "an import that holds in its clone passes" 0 "import o/sibling: the manifest holds at $SC" --branch main --import "o/sibling=$SIB" "$WORK/imported_praxis.deed" "$R"
expect "an import with no clone given fails" 1 "no clone given (--import o/sibling=DIR)" --branch main "$WORK/imported_praxis.deed" "$R"
printf -- '-- moved\n' >>"$SIB/Algebra.agda"; git -C "$SIB" commit -qam moved
SC2=$(git -C "$SIB" rev-parse HEAD)
write repinned "$I" "$S" "$D" "$MANIFEST_S" "$ECHO_IN" "${IMPORT//$SC/$SC2}"
expect "the --import name matches without regard to case" 0 "import o/sibling: the manifest holds at $SC" --branch main --import "O/Sibling=$SIB" "$WORK/imported_praxis.deed" "$R"
# A shallow clone of the home repository at an old home commit, under an alias.
SHALLOW="$WORK/shallow"; git clone -q --depth 1 --no-local --branch pr "file://$R" "$SHALLOW" 2>/dev/null
HC=$(git -C "$SHALLOW" rev-parse HEAD)
HIMPORT="
        (import :repository \"o/alias\" :commit \"$HC\" :inputs-sha256 \"$(bash "$DIGEST" -C "$SHALLOW" "$HC" src/A.agda)\"
          (file :path \"src/A.agda\" :sha256 \"$(bash "$DIGEST" -C "$SHALLOW" --manifest "$HC" src/A.agda | cut -d' ' -f1)\"))"
write shallowalias "$I" "$S" "$D" "$MANIFEST_S" "$ECHO_IN" "$HIMPORT"
expect "a shallow alias clone of the home repository fails" 1 "is in the home repository, so it is the home repository" --branch main --import "o/alias=$SHALLOW" "$WORK/shallowalias_praxis.deed" "$R"
SHALLOW_HOME="$WORK/shallowhome"; git clone -q --depth 1 --no-local --branch main "file://$R" "$SHALLOW_HOME" 2>/dev/null
expect "a shallow home clone cannot be checked (exit 2)" 2 "is a shallow clone" --branch HEAD --import "o/alias=$SHALLOW" "$WORK/shallowalias_praxis.deed" "$SHALLOW_HOME"
expect "an import whose clone is the home repository fails" 1 "its clone holds the home :source-commit" --branch main --import "o/sibling=$R" "$WORK/imported_praxis.deed" "$R"
expect "an import whose files differ at its pin fails" 1 "import o/sibling: the manifest does not hold at $SC2" --branch main --import "o/sibling=$SIB" "$WORK/repinned_praxis.deed" "$R"

# A negative control: the refused file is an input of its own receipt.
mkdir -p "$R/tests/reject"; printf 'module Bad where\n' >"$R/tests/reject/Bad.agda"
git -C "$R" add -A; git -C "$R" commit -qm control
K=$(git -C "$R" rev-parse HEAD)
KPATHS=(src/A.agda tests/reject/Bad.agda x.agda-lib)
KD=$(bash "$DIGEST" -C "$R" "$K" "${KPATHS[@]}")
KM=$(bash "$DIGEST" -C "$R" --manifest "$K" "${KPATHS[@]}" | while read -r h p; do printf '        (file :path "%s" :sha256 "%s")\n' "$p" "$h"; done)
control() { # DIGEST MANIFEST
  printf '\n    (control :path "tests/reject/Bad.agda" :prover agda :expect refused\n      (receipt :run "https://ci/run/2" :commit "%s" :checker "agda 2.6.4.3" :invocation "agda --safe" :inputs-sha256 "%s" :state current\n        (inputs-manifest\n%s)\n        (axioms)))' "$K" "$1" "$2"
}
write controlled "$I" "$S" "$D" "$MANIFEST_S" "$ECHO_IN" "" "$(control "$KD" "$KM")"
expect "a negative control whose manifest holds passes" 0 "agda control tests/reject/Bad.agda receipt: the manifest holds at $K" --branch main "$WORK/controlled_praxis.deed" "$R"
KFAKE=$(printf '%s\n' "$KM" | sed "s/\"[0-9a-f]\{64\}\")$/\"$(printf '%064d' 7)\")/")
KFD=$(printf '%s\n' "$KFAKE" | sed -n 's/.*:path "\([^"]*\)" :sha256 "\([^"]*\)").*/\2  \1/p' | sha256sum | cut -d' ' -f1)
write badcontrol "$I" "$S" "$D" "$MANIFEST_S" "$ECHO_IN" "" "$(control "$KFD" "$KFAKE")"
expect "a negative control whose manifest is false fails" 1 "control tests/reject/Bad.agda receipt: the manifest does not hold at $K" --branch main "$WORK/badcontrol_praxis.deed" "$R"

expect "exits 2 on a malformed --import" 2 "OWNER/REPO=DIR" --import nonsense "$WORK/good_praxis.deed" "$R"
expect "exits 2 when REPO is not a clone" 2 "not a git clone" "$WORK/good_praxis.deed" "$WORK"
expect "exits 2 on bad usage" 2 "usage" "$WORK/good_praxis.deed"

echo "check-proof-receipt: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
