#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves scripts/proof-inputs-sha256.sh computes the PROOF-POLICY §8.5.1
# digest: it equals the shell rebuild on a checkout, it does not depend on the
# order of the paths given, it changes when an input changes and not when a
# file outside the inputs changes, and it refuses what it must refuse.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/proof-inputs-sha256.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 ($2 != $3)"; fi; }
differ() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (both $2)"; fi; }
rc_is() { local label=$1 want=$2; shift 2; local rc=0; bash "$CHECK" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then ok "$label"; else bad "$label (exit $rc, want $want)"; fi; }

R="$WORK/repo"
git init -q "$R"
git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
mkdir -p "$R/src/Sub" "$R/docs"
printf 'module A where\n' >"$R/src/A.agda"
printf 'module Sub.B where\n' >"$R/src/Sub/B.agda"
printf 'name: x\ninclude: src\n' >"$R/x.agda-lib"
printf 'readme\n' >"$R/docs/README.adoc"
git -C "$R" add -A; git -C "$R" commit -qm one
C1=$(git -C "$R" rev-parse HEAD)

inputs=(src/A.agda src/Sub/B.agda x.agda-lib)
d1=$(bash "$CHECK" -C "$R" "$C1" "${inputs[@]}")
shell=$(cd "$R" && printf '%s\n' "${inputs[@]}" | LC_ALL=C sort | xargs -d '\n' sha256sum -- | sha256sum | cut -d' ' -f1)
same "matches the shell rebuild on a checkout" "$d1" "$shell"
same "does not depend on argument order" "$d1" "$(bash "$CHECK" -C "$R" "$C1" x.agda-lib ./src/Sub/B.agda src/A.agda)"
if [[ "$d1" =~ ^[0-9a-f]{64}$ ]]; then ok "is 64 lowercase hex"; else bad "is 64 lowercase hex ($d1)"; fi
m=$(bash "$CHECK" -C "$R" --manifest "$C1" "${inputs[@]}")
same "manifest is in C order of path" "$(printf '%s\n' "$m" | cut -c67-)" "$(printf 'src/A.agda\nsrc/Sub/B.agda\nx.agda-lib')"

# A change outside the inputs keeps the inputs digest and changes the tree digest.
t1=$(bash "$CHECK" -C "$R" "$C1")
printf 'more\n' >>"$R/docs/README.adoc"; git -C "$R" commit -qam two
C2=$(git -C "$R" rev-parse HEAD)
same "inputs digest holds across a docs-only change" "$d1" "$(bash "$CHECK" -C "$R" "$C2" "${inputs[@]}")"
differ "tree digest changes with any tracked file" "$t1" "$(bash "$CHECK" -C "$R" "$C2")"

# A change to an input changes the inputs digest.
printf -- '-- edit\n' >>"$R/src/A.agda"; git -C "$R" commit -qam three
differ "inputs digest changes with an input" "$d1" "$(bash "$CHECK" -C "$R" HEAD "${inputs[@]}")"

# A squash of the same tree onto another parent keeps the tree digest.
git -C "$R" checkout -q --orphan squashed "$C2"; git -C "$R" commit -qm squash
same "tree digest is the same for the same tree on another commit" "$(bash "$CHECK" -C "$R" "$C2")" "$(bash "$CHECK" -C "$R" squashed)"

rc_is "refuses a path that is not a file at the commit" 1 -C "$R" "$C1" src/Missing.agda
rc_is "refuses a directory" 1 -C "$R" "$C1" src
rc_is "refuses a repeated path" 1 -C "$R" "$C1" src/A.agda ./src/A.agda
rc_is "exits 2 on an unknown commit" 2 -C "$R" 0123456789abcdef0123456789abcdef01234567 src/A.agda
rc_is "exits 2 with no commit" 2 -C "$R"
printf 'x\n' >"$R/back\\slash"; git -C "$R" add -A; git -C "$R" commit -qm four
rc_is "refuses a path that holds a backslash" 1 -C "$R" HEAD 'back\slash'

echo "proof-inputs-sha256: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
