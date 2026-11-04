#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression suite for scripts/apply-branch-autodelete.sh
#
# A `gh` shim on PATH answers from fixtures and keeps per-repo state, so a
# PATCH followed by a read-back is exercised for real. Every write is appended
# to $GH_FIX/PATCH.log, so "wrote nothing" is checkable. An unplanned API path
# exits 9, so code reaching for an endpoint it should not fails loudly.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SUT="$ROOT/scripts/apply-branch-autodelete.sh"
[ -r "$SUT" ] || { echo "FATAL: script under test missing: $SUT"; exit 2; }

PASS=0; FAIL=0
# Record a passing assertion and print its description.
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
# Record a failing assertion and print its expected and actual values.
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
# Compare expected and actual values, then record the assertion result.
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

WORK="$(mktemp -d -t autodelete-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; FIX="$WORK/fix"; mkdir -p "$BIN" "$FIX/state"

cat > "$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
# Fixture-backed gh: `api [--paginate] [-X PATCH] PATH [-F k=v] [--jq EXPR]`.
args=("$@"); jqf="."; path=""; method=GET
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jqf="${args[i+1]}"; i=$((i+1)) ;;
    -X) method="${args[i+1]}"; i=$((i+1)) ;;
    -F) i=$((i+1)) ;;
    api|--paginate) ;;
    *) path="${args[i]}" ;;
  esac
done
if [ "$method" = PATCH ]; then
  r="${path#repos/}"
  echo "$r" >> "$GH_FIX/PATCH.log"
  [ -e "$GH_FIX/stuck/${r//\//_}" ] || echo true > "$GH_FIX/state/${r//\//_}"
  echo '{}'; exit 0
fi
case "$path" in
  user) f=user.json ;;
  user/memberships/orgs) f=orgs.json ;;
  user/repos*) f=userrepos.json ;;
  orgs/*/repos*) o="${path#orgs/}"; f="org_${o%%/*}.json" ;;
  repos/*) r="${path#repos/}"; s="$GH_FIX/state/${r//\//_}"
           [ -f "$s" ] || exit 9
           jq -r "{delete_branch_on_merge: $(cat "$s")} | $jqf" <<<'{}'; exit 0 ;;
  *) echo "unexpected path: $path" >&2; exit 9 ;;
esac
[ -f "$GH_FIX/$f" ] || { echo "no fixture: $f" >&2; exit 9; }
jq -r "$jqf" "$GH_FIX/$f"
SHIM
chmod +x "$BIN/gh"

# Reset the fixtures to the standard estate: one user, one admin org, one
# member-only org, one pending org; a fork, an archived repo, the 007 repo.
seed() {
  rm -rf "$FIX/state" "$FIX/stuck" "$FIX/PATCH.log"; mkdir -p "$FIX/state" "$FIX/stuck"
  echo '{"login":"hyperpolymath"}' > "$FIX/user.json"
  echo '[{"state":"active","role":"admin","organization":{"login":"orgA"}},
         {"state":"active","role":"member","organization":{"login":"thirdparty"}},
         {"state":"pending","role":"admin","organization":{"login":"pendingorg"}}]' > "$FIX/orgs.json"
  echo '[{"full_name":"hyperpolymath/a","fork":false,"archived":false},
         {"full_name":"hyperpolymath/ok","fork":false,"archived":false},
         {"full_name":"hyperpolymath/fork","fork":true,"archived":false},
         {"full_name":"hyperpolymath/old","fork":false,"archived":true},
         {"full_name":"hyperpolymath/007","fork":false,"archived":false}]' > "$FIX/userrepos.json"
  echo '[{"full_name":"orgA/x","fork":false,"archived":false},
         {"full_name":"orgA/y","fork":false,"archived":false}]' > "$FIX/org_orgA.json"
  echo '[{"full_name":"orgB/z","fork":false,"archived":false}]' > "$FIX/org_orgB.json"
  echo false > "$FIX/state/hyperpolymath_a"; echo true > "$FIX/state/hyperpolymath_ok"
  echo true > "$FIX/state/orgA_x";          echo false > "$FIX/state/orgA_y"
  echo false > "$FIX/state/orgB_z"
}
# Run the script under test with the shim on PATH; stdout and stderr merged.
run() { GH_FIX="$FIX" PATH="$BIN:$PATH" bash "$SUT" "$@" 2>&1; }
# Count the PATCH calls the shim logged (0 when none).
patches() { [ -f "$FIX/PATCH.log" ] && wc -l < "$FIX/PATCH.log" | tr -d ' ' || echo 0; }

echo "== report-only (default)"
seed; out="$(run)"; rc=$?
check "exit 0" 0 "$rc"
check "nothing written" 0 "$(patches)"
check "lists the two repos that are off" "OFF  hyperpolymath/a|OFF  orgA/y" \
  "$(grep '^OFF' <<<"$out" | paste -sd'|' -)"
check "walks only the user and the admin org" "Owners: hyperpolymath,orgA" "$(grep '^Owners' <<<"$out")"

echo "== --apply"
seed; out="$(run --apply)"; rc=$?
check "exit 0" 0 "$rc"
check "patches exactly the two" "hyperpolymath/a|orgA/y" "$(paste -sd'|' - < "$FIX/PATCH.log")"
check "reports both as ON after read-back" "2" "$(grep -c '^ON' <<<"$out")"
for r in fork old 007; do
  check "never touches hyperpolymath/$r" "" "$(grep "hyperpolymath/$r\$" "$FIX/PATCH.log")"
done

echo "== idempotent"
out="$(run --apply)"; rc=$?
check "second run exits 0" 0 "$rc"
check "second run says all done" "Every repository already auto-deletes merged branches." "$(tail -1 <<<"$out")"
check "second run writes nothing new" 2 "$(patches)"

echo "== read-back failure is reported"
seed; touch "$FIX/stuck/orgA_y"; out="$(run --apply)"; rc=$?
check "exit 1 when a write does not stick" 1 "$rc"
check "names the repo that failed" "FAIL orgA/y (did not read back true)" "$(grep '^FAIL' <<<"$out")"

echo "== --owners overrides discovery"
seed; out="$(run --owners orgB)"; rc=$?
check "exit 0" 0 "$rc"
check "walks only the named owner" "OFF  orgB/z" "$(grep '^OFF' <<<"$out")"

echo "== usage"
seed; run --bogus >/dev/null; check "unknown argument exits 2" 2 "$?"

echo
echo "apply-branch-autodelete-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
