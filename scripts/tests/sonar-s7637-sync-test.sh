#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression suite for scripts/sonar-s7637-sync.sh
#
# `curl` and `gh` shims on PATH answer from fixtures. Every SonarCloud write
# (a POST) is appended to $FIX/WRITE.log, so "wrote nothing" is checkable. An
# unplanned request exits 9, so code reaching for an endpoint it should not
# fails loudly. No network is used.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SUT="$ROOT/scripts/sonar-s7637-sync.sh"
[ -r "$SUT" ] || { echo "FATAL: script under test missing: $SUT"; exit 2; }

PASS=0; FAIL=0
# Record a passing assertion and print its description.
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
# Record a failing assertion and print its expected and actual values.
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
# Compare expected and actual values, then record the assertion result.
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

WORK="$(mktemp -d -t sonar-s7637.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; FIX="$WORK/fix"; mkdir -p "$BIN" "$FIX"
export FIX

cat > "$BIN/curl" <<'SHIM'
#!/usr/bin/env bash
# Fixture-backed curl for SonarCloud. Fails with 22 (like curl -f) on a missing fixture.
method=GET; url=""
for a in "$@"; do
  case "$prev" in -X) method="$a" ;; esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
p="${url#*://*/}"
if [ "$method" = POST ]; then
  { echo "--- $p"; printf '%s\n' "$@"; } >> "$FIX/WRITE.log"
  exit 0
fi
comp="${p#*component=}"; comp="${comp%%&*}"
case "$p" in
  api/navigation/component*) f="nav_$comp.json" ;;
  api/settings/values*) f="set_$comp.json" ;;
  *) echo "unexpected path: $p" >&2; exit 9 ;;
esac
[ -f "$FIX/$f" ] || exit 22
cat "$FIX/$f"
SHIM

cat > "$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
# Fixture-backed gh api: repo lookup, and the lock file (404 when absent).
path="$2"; r="${path#repos/}"
case "$r" in
  */*/contents/*) r="${r%%/contents/*}"; k="${r//\//_}"
    [ -e "$FIX/ghfail_$k" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    [ -e "$FIX/lock_$k" ] && { echo '{"path":".github/workflows/actions.lock"}'; exit 0; }
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  */*) k="${r//\//_}"
    [ -e "$FIX/ghfail_$k" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    echo '{"default_branch":"main"}'; exit 0 ;;
esac
exit 9
SHIM
chmod +x "$BIN/curl" "$BIN/gh"

OTHER='{"ruleKey":"java:S1","resourceKey":"src/**"}'
S7637='{"ruleKey":"githubactions:S7637","resourceKey":".github/workflows/**"}'
# mkproj KEY OWNER/REPO HASLOCK(0|1) ENTRIES-JSON-ARRAY
mkproj() {
  local k="$1" r="$2"
  echo "{\"alm\":{\"url\":\"https://github.com/$r\"}}" > "$FIX/nav_$k.json"
  [ "$3" = 1 ] && : > "$FIX/lock_${r//\//_}"
  echo "{\"settings\":[{\"key\":\"sonar.issue.ignore.multicriteria\",\"fieldValues\":$4}]}" > "$FIX/set_$k.json"
}
mkproj padd   o/add   1 "[$OTHER]"
mkproj prem   o/rem   0 "[$OTHER,$S7637]"
mkproj plast  o/last  0 "[$S7637]"
mkproj pnone  o/none  1 "[$S7637]"
mkproj pro    o/ro    1 "[$OTHER]"
mkproj pgh    o/gh    1 "[$OTHER]"; : > "$FIX/ghfail_o_gh"
echo '{"alm":{"url":"https://github.com/o/noset"}}' > "$FIX/nav_pnoset.json"
echo '{}' > "$FIX/nav_pnobind.json"

# run ARGS...: run the tool with the shims; sets OUT and RC; clears the write log.
run() { rm -f "$FIX/WRITE.log"; OUT="$(PATH="$BIN:$PATH" SONAR_TOKEN=dummy "$SUT" "$@" 2>&1)"; RC=$?; }
writes() { grep -c '^--- ' "$FIX/WRITE.log" 2>/dev/null || true; }
has_arg() { grep -qxF -- "fieldValues=$1" "$FIX/WRITE.log"; }

echo "dry run"
run --project padd
check "dry run reports add" 1 "$(grep -c 'lock=yes entry=no action=add' <<<"$OUT")"
check "dry run exits 0" 0 "$RC"
check "dry run sends no write" "" "$(writes)"
run --project prem
check "dry run reports remove" 1 "$(grep -c 'lock=no entry=yes action=remove' <<<"$OUT")"
check "dry run remove sends no write" "" "$(writes)"

echo "add"
run --apply --project padd
check "add exits 0" 0 "$RC"
check "add posts to settings/set" 1 "$(grep -c '^--- api/settings/set' "$FIX/WRITE.log")"
has_arg "$S7637" && ok "add sends the S7637 entry" || bad "add sends the S7637 entry" present absent
has_arg "$OTHER" && ok "add keeps the other entry" || bad "add keeps the other entry" present absent

echo "remove"
run --apply --project prem
check "remove exits 0" 0 "$RC"
check "remove posts to settings/set" 1 "$(grep -c '^--- api/settings/set' "$FIX/WRITE.log")"
has_arg "$OTHER" && ok "remove keeps the other entry" || bad "remove keeps the other entry" present absent
has_arg "$S7637" && bad "remove drops the S7637 entry" absent present || ok "remove drops the S7637 entry"
run --apply --project plast
check "removing the last entry resets" 1 "$(grep -c '^--- api/settings/reset' "$FIX/WRITE.log")"
check "removing the last entry does not call set" 0 "$(grep -c '^--- api/settings/set' "$FIX/WRITE.log")"

echo "no change"
run --apply --project pnone
check "lock plus entry writes nothing" "" "$(writes)"
run --apply --project pro
check "unrelated entries with a lock add the entry once" 1 "$(writes)"

echo "errors"
run --apply --project pnoset
[ "$RC" != 0 ] && ok "setting read error exits non-zero" || bad "setting read error exits non-zero" non-zero 0
check "setting read error writes nothing" "" "$(writes)"
run --apply --project pgh
[ "$RC" != 0 ] && ok "GitHub error exits non-zero" || bad "GitHub error exits non-zero" non-zero 0
check "GitHub error is not treated as no lock" 0 "$(grep -c 'lock=no' <<<"$OUT")"
check "GitHub error writes nothing" "" "$(writes)"
run --apply --project pnobind
check "no binding is skipped and reported" 1 "$(grep -c 'SKIP no-github-binding' <<<"$OUT")"
check "no binding exits 0" 0 "$RC"

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
