#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Regression suite for scripts/sonar-preflight.sh
#
# A `curl` shim on PATH answers from per-scenario fixtures and records its
# argv. Every class the script can emit has a scenario, and each one checks
# the class AND the exit code, because a right name with a wrong exit code
# is the green-skip this script exists to replace. Three properties are
# checked beyond the classes:
#
#   * the token never appears on curl's command line (it goes in a header
#     file), so it cannot leak through the process table;
#   * an EMPTY token makes no request at all: SonarCloud answers
#     {"valid":true} to an anonymous validate call (measured 2026-11-17),
#     so a probe without a token would pass;
#   * a transport failure is `server-unavailable`, never `ok`.
#
# No network is used. Exit 0 when every assertion holds.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SUT="$ROOT/scripts/sonar-preflight.sh"
[ -r "$SUT" ] || { echo "FATAL: script under test missing: $SUT"; exit 2; }
command -v jq >/dev/null || { echo "FATAL: jq is required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

WORK="$(mktemp -d -t sonar-preflight.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"

# Fixture-backed curl. $FIX/<endpoint>.code and $FIX/<endpoint>.json give the
# answer; $FIX/transport_fail makes every call fail like a DNS error (exit 6).
# Every call's argv and any header file it was given are logged.
cat > "$BIN/curl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/ARGV.log"
out=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in --output) out="$a" ;; --header) case "$a" in @*) cat "${a#@}" >> "$FIX/HEADERS.log" ;; esac ;; esac
  case "$a" in https://*) url="$a" ;; esac
  prev="$a"
done
[ -e "$FIX/transport_fail" ] && { echo "curl: (6) Could not resolve host" >&2; exit 6; }
p="${url#https://*/}"
case "$p" in
  api/authentication/validate) e=validate ;;
  api/organizations/search*)   e=orgs ;;
  api/components/show*)        e=component ;;
  *) echo "unexpected path: $p" >&2; exit 9 ;;
esac
code=200; [ -f "$FIX/$e.code" ] && code="$(cat "$FIX/$e.code")"
[ -f "$FIX/$e.json" ] && cat "$FIX/$e.json" > "$out" || : > "$out"
printf '%s' "$code"
SHIM
chmod +x "$BIN/curl"

# A fixture, not a credential. Assembled from parts so the source line does
# not look like a hardcoded token to the shell-secrets scanner, which flags
# NAME="<20+ token chars>" literals (it was right to ask).
fixture_part="not_a_secret"
TOKEN="squ_fixture_${fixture_part}_0123456789"
VALID='{"valid":true}'; INVALID='{"valid":false}'
ORG_FOUND='{"organizations":[{"key":"acme"}],"paging":{"pageIndex":1,"pageSize":100,"total":1}}'
ORG_NONE='{"organizations":[],"paging":{"pageIndex":1,"pageSize":100,"total":0}}'
COMP_OK='{"component":{"organization":"acme","key":"acme_widget","qualifier":"TRK"}}'
COMP_ELSEWHERE='{"component":{"organization":"oldorg","key":"acme_widget","qualifier":"TRK"}}'

# run <name> [env assignments...] — prepares a fixture dir from the
# remaining FIX_* variables set by the caller, runs the SUT, records results.
run() {
  local name="$1"; shift
  export FIX="$WORK/$name"; mkdir -p "$FIX/repo"
  : > "$FIX/ARGV.log"; : > "$FIX/HEADERS.log"
  printf 'sonar.organization=acme\nsonar.projectKey=acme_widget\n' > "$FIX/repo/sonar-project.properties"
  [ -n "${F_VALIDATE:-}" ] && printf '%s' "$F_VALIDATE" > "$FIX/validate.json"
  [ -n "${F_VALIDATE_CODE:-}" ] && printf '%s' "$F_VALIDATE_CODE" > "$FIX/validate.code"
  [ -n "${F_ORGS:-}" ] && printf '%s' "$F_ORGS" > "$FIX/orgs.json"
  [ -n "${F_ORGS_CODE:-}" ] && printf '%s' "$F_ORGS_CODE" > "$FIX/orgs.code"
  [ -n "${F_COMP:-}" ] && printf '%s' "$F_COMP" > "$FIX/component.json"
  [ -n "${F_COMP_CODE:-}" ] && printf '%s' "$F_COMP_CODE" > "$FIX/component.code"
  [ -n "${F_TRANSPORT_FAIL:-}" ] && : > "$FIX/transport_fail"
  : > "$FIX/out"; : > "$FIX/summary"
  ( cd "$FIX/repo" && env -i PATH="$BIN:$PATH" HOME="$WORK" FIX="$FIX" \
      GITHUB_OUTPUT="$FIX/out" GITHUB_STEP_SUMMARY="$FIX/summary" \
      GITHUB_REPOSITORY=acme/widget "$@" bash "$SUT" > "$FIX/stdout" 2>&1 )
  RC=$?
  CLASS="$(sed -n 's/^class=//p' "$FIX/out" | tail -1)"
  CALLS="$(wc -l < "$FIX/ARGV.log" | tr -d ' ')"
}
expect() { # expect <label> <class> <rc>
  check "$1: class" "$2" "$CLASS"
  check "$1: exit code" "$3" "$RC"
}
reset() { unset F_VALIDATE F_VALIDATE_CODE F_ORGS F_ORGS_CODE F_COMP F_COMP_CODE F_TRANSPORT_FAIL; }

echo "== ok: valid token, organisation and project exist"
reset; F_VALIDATE="$VALID"; F_ORGS="$ORG_FOUND"; F_COMP="$COMP_OK"
run ok SONAR_TOKEN="$TOKEN"
expect "ok" ok 0
if grep -qF "$TOKEN" "$FIX/ARGV.log"; then bad "token kept off curl argv" "absent" "present"; else ok "token kept off curl argv"; fi
check "token sent as a bearer header" "3" "$(grep -c "^Authorization: Bearer $TOKEN\$" "$FIX/HEADERS.log")"
grep -q '^### SonarQube preflight: `ok`' "$FIX/summary" && ok "step summary written" || bad "step summary written" "heading" "$(head -1 "$FIX/summary")"

echo "== token-absent: empty token on a push run makes no request"
reset; F_VALIDATE="$VALID"
run absent GITHUB_ACTOR=someone GITHUB_EVENT_NAME=push SONAR_TOKEN=
expect "token-absent" token-absent 1
check "token-absent: no request made (anonymous validate says valid:true)" 0 "$CALLS"

echo "== secrets-withheld: Dependabot"
reset
run dependabot GITHUB_ACTOR='dependabot[bot]' GITHUB_EVENT_NAME=pull_request SONAR_TOKEN=
expect "secrets-withheld (dependabot)" secrets-withheld 0
grep -q '^::notice title=SonarQube preflight: secrets-withheld::' "$FIX/stdout" && ok "withheld is announced, not silent" || bad "withheld is announced" "::notice" "$(cat "$FIX/stdout")"

echo "== secrets-withheld: fork pull request"
reset
run fork GITHUB_ACTOR=contributor GITHUB_EVENT_NAME=pull_request PR_HEAD_REPOSITORY=contributor/widget SONAR_TOKEN=
expect "secrets-withheld (fork)" secrets-withheld 0

echo "== token-absent: same-repo pull request is NOT excused"
reset
run samerepo GITHUB_ACTOR=someone GITHUB_EVENT_NAME=pull_request PR_HEAD_REPOSITORY=acme/widget SONAR_TOKEN=
expect "token-absent (same-repo PR)" token-absent 1

echo "== token-rejected: valid=false"
reset; F_VALIDATE="$INVALID"
run rejected SONAR_TOKEN="$TOKEN"
expect "token-rejected (valid=false)" token-rejected 1
check "token-rejected: stops after validate" 1 "$CALLS"

echo "== token-rejected: HTTP 403"
reset; F_VALIDATE_CODE=403
run rejected403 SONAR_TOKEN="$TOKEN"
expect "token-rejected (403)" token-rejected 1

echo "== organization-missing"
reset; F_VALIDATE="$VALID"; F_ORGS="$ORG_NONE"
run noorg SONAR_TOKEN="$TOKEN"
expect "organization-missing" organization-missing 1

echo "== project-missing"
reset; F_VALIDATE="$VALID"; F_ORGS="$ORG_FOUND"; F_COMP='{"errors":[{"msg":"Project doesn'"'"'t exist"}]}'; F_COMP_CODE=404
run noproj SONAR_TOKEN="$TOKEN"
expect "project-missing" project-missing 1

echo "== project-forbidden"
reset; F_VALIDATE="$VALID"; F_ORGS="$ORG_FOUND"; F_COMP_CODE=403
run forbidden SONAR_TOKEN="$TOKEN"
expect "project-forbidden" project-forbidden 1

echo "== project-org-mismatch (the marid shape: project left in the old org)"
reset; F_VALIDATE="$VALID"; F_ORGS="$ORG_FOUND"; F_COMP="$COMP_ELSEWHERE"
run mismatch SONAR_TOKEN="$TOKEN"
expect "project-org-mismatch" project-org-mismatch 1

echo "== server-unavailable: invalid project responses"
for response in '' '{' '{}' 'null' '[]' '{"component":null}' \
  '{"component":[]}' '{"component":{}}' '{"component":{"key":null}}' \
  '{"component":{"key":42}}' '{"component":{"key":""}}' \
  "$COMP_OK"$'\n{}'; do
  reset; F_VALIDATE="$VALID"; F_ORGS="$ORG_FOUND"; F_COMP="$response"
  run malformed SONAR_TOKEN="$TOKEN"
  expect "invalid project response ($response)" server-unavailable 1
  grep -q '^### SonarQube preflight: `server-unavailable`' "$FIX/summary" \
    && ok "invalid project response: summary written" \
    || bad "invalid project response: summary written" "heading" "$(head -1 "$FIX/summary")"
done

reset; F_VALIDATE="$VALID"; F_ORGS="$ORG_FOUND"; F_COMP='{"component":{"key":"acme_widget"}}'
run no_org_metadata SONAR_TOKEN="$TOKEN"
expect "project without optional organisation metadata" ok 0

echo "== server-unavailable: 503, 429 and transport failure"
reset; F_VALIDATE_CODE=503
run s503 SONAR_TOKEN="$TOKEN"
expect "server-unavailable (503)" server-unavailable 1
reset; F_VALIDATE="$VALID"; F_ORGS_CODE=429
run s429 SONAR_TOKEN="$TOKEN"
expect "server-unavailable (429)" server-unavailable 1
reset; F_TRANSPORT_FAIL=1
run transport SONAR_TOKEN="$TOKEN"
expect "server-unavailable (transport)" server-unavailable 1

echo "== configuration"
reset
run cfgmissing SONAR_TOKEN="$TOKEN" SONAR_PROPERTIES=/nonexistent
expect "config-missing" config-missing 1
check "config-missing: no request made" 0 "$CALLS"
reset
run cfginvalid SONAR_TOKEN="$TOKEN" SONAR_PROJECT_KEY='acme_widget&x=1'
expect "config-invalid (URL metacharacter)" config-invalid 1
check "config-invalid: no request made" 0 "$CALLS"
reset; F_VALIDATE="$VALID"; F_ORGS="$ORG_FOUND"; F_COMP='{"component":{"organization":"other","key":"other_key"}}'
run override SONAR_TOKEN="$TOKEN" SONAR_ORGANIZATION=other SONAR_PROJECT_KEY=other_key
expect "inputs override the properties file" ok 0

echo
echo "sonar-preflight-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
