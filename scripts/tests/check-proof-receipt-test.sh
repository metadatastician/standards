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
git -C "$R" merge -q --squash pr 2>/dev/null; git -C "$R" commit -qm squash
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

# write NAME SOURCE-COMMIT RECEIPT-COMMIT DIGEST MANIFEST ECHO
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
$5)
        (axioms)))
    (leg :prover rocq :route unavailable :reason "none yet")
    (leg :prover lean :route unavailable :reason "none yet")))
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

expect "exits 2 when REPO is not a clone" 2 "not a git clone" "$WORK/good_praxis.deed" "$WORK"
expect "exits 2 on bad usage" 2 "usage" "$WORK/good_praxis.deed"

echo "check-proof-receipt: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
