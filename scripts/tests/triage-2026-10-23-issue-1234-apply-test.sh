#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# triage-2026-10-23-issue-1234-apply-test.sh — regression tests for
# scripts/triage-2026-10-23-issue-1234-apply.sh and
# docs/reorg/2026-10-14-tidy/ISSUE-1234-CLOSEOUT-REPORT.adoc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUT="$SCRIPT_DIR/../triage-2026-10-23-issue-1234-apply.sh"
REPORT="$ROOT/docs/reorg/2026-10-14-tidy/ISSUE-1234-CLOSEOUT-REPORT.adoc"

[ -x "$SUT" ] || { echo "FAIL: $SUT is not executable" >&2; exit 1; }
bash -n "$SUT"
[ -f "$REPORT" ] || { echo "FAIL: $REPORT does not exist" >&2; exit 1; }

# 1. Verify A5 (D298) runs ?dry-run=true PUT before live PUT on both 23868655 and 23868851.
grep -q 'orgs/metadatastician/rulesets/\${id}?dry-run=true' "$SUT"
grep -q '23868655 23868851' "$SUT"
echo "PASS: A5 (D298) validates ?dry-run=true PUT before live PUT on 23868655 and 23868851"

# 2. Verify A1 (D16) strips 1561, 85455, and 946600 from all 10 target rulesets.
for id in 15402978 18110196 18874804 18875919 14968573 14968592 14968613 14968721 18110652 18110675; do
  grep -q ":$id" "$SUT" || { echo "FAIL: missing A1 ruleset $id in $SUT" >&2; exit 1; }
done
echo "PASS: all 10 A1 (D16) ruleset IDs are covered"

# 3. Verify A2 covers echidna stub fuzz_input.rs, A3 updates knot-knot pages.yml, and D332 covers 95 repos.
grep -q 'fuzz/fuzz_targets/fuzz_input.rs' "$SUT"
grep -q 'www/public' "$SUT"
grep -q 'ls-remote --exit-code --heads origin' "$SUT"
grep -q 'orgs/metadatastician/installations' "$SUT"
grep -q 'user/installations' "$SUT"
echo "PASS: A2 echidna stub, A3 knot-knot pages.yml, remote-branch resumability, and both owner installation endpoints are present"

# 4. Verify close-out report covers A1-A7, D304, D332, D335-D355, and reconciled Tier 4 (25) / Tier 5 (271) counts.
for marker in "A1 (D16)" "A2 (D14)" "A3 (D24)" "A4 (D97)" "A5 (D298)" "A6 (D67" "A7 (D330)" "B / D304" "B / D332" "D355" "All remaining 271 active public"; do
  grep -q "$marker" "$REPORT" || { echo "FAIL: missing '$marker' in $REPORT" >&2; exit 1; }
done
echo "PASS: close-out report contains all #1234 sections, ruling row D355, and reconciled 357-repo tier counts"

# 5. --dry-run must execute cleanly against a stub `gh` that refuses any write verb,
#    and must keep #306 and #1234 open while items are pending.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  api)
    if [ "${2:-}" = "--include" ] && [ "${3:-}" = repos/hyperpolymath/explore ]; then
      case "${TEST_EXPLORE:-absent}" in
        present) printf 'HTTP/2.0 200 OK\n\n{}\n'; exit 0 ;;
        absent) printf 'HTTP/2.0 404 Not Found\n\n{}\n'; exit 1 ;;
        *) printf 'HTTP/2.0 403 Forbidden\n\n{}\n'; exit 1 ;;
      esac
    fi
    if [ "${2:-}" = "-X" ]; then
      echo "FAIL: unexpected write call under --dry-run: gh $*" >&2
      exit 99
    fi
    case "${2:-}" in
      repos/hyperpolymath/*/rulesets/*)
        printf '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"rules":[{"type":"deletion"}],"bypass_actors":[{"actor_type":"Integration","actor_id":1561,"bypass_mode":"always"},{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"always"}]}\n'
        ;;
      repos/metadatastician/metadatastician-governance/rulesets/*)
        printf '{"name":"Branch-Floor","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_linear_history"}]}\n'
        ;;
      repos/metadatastician/knot-knot)
        printf 'false\n'
        ;;
      orgs/metadatastician/installations|user/installations)
        [ "${TEST_INSTALLATION_ERROR:-}" != "$2" ] || exit 1
        [ "$3" = --paginate ] && [ "$4" = --slurp ] && [ "$5" = --jq ]
        printf '%s\n' "${TEST_INSTALLATIONS:-[]}" | jq -r "$6"
        ;;
      repos/hyperpolymath/standards/issues/*)
        printf 'open\n'
        ;;
      repos/hyperpolymath/standards/contents/.github/workflows)
        [ "${TEST_WORKFLOWS:-}" != error ] || exit 1
        printf '%s\n' "${TEST_WORKFLOWS:-[]}" | jq -r "$4"
        ;;
      *)
        printf '{}\n'
        ;;
    esac
    ;;
  issue)
    [ -n "${TEST_CLOSE_LOG:-}" ] || exit 99
    printf '%s\n' "$3" >> "$TEST_CLOSE_LOG"
    ;;
  repo)
    [ "$2" = clone ] && [ -n "${TEST_CLONE_LOG:-}" ] || exit 99
    printf '%s\n' "$3" >> "$TEST_CLONE_LOG"
    mkdir -p "$4"
    ;;
  *)
    echo "FAIL: unexpected write call under --dry-run: gh $*" >&2
    exit 99
    ;;
esac
SHIM
chmod +x "$WORK/gh"

dry_out="$(PATH="$WORK:$PATH" bash "$SUT" --dry-run)"
grep -q 'D332 .github/settings.yml targets: 95' <<<"$dry_out"
grep -q '#306 kept open' <<<"$dry_out"
grep -q '#1234 kept open' <<<"$dry_out"
echo "PASS: --dry-run performs zero gh write calls, enumerates 95 D332 repos, and gates issue closure on convergence"

# 6. Exercise the actual close-out section with all earlier work converged.
#    Only the gh shim can close issues; no network or repository writes occur.
{
  printf 'set -euo pipefail\nDRY_RUN=0\nREPO=hyperpolymath/standards\nREPORT_REL=report.adoc\n'
  sed -n '/^run_gh()/,/^}/p' "$SUT"
  sed -n '/^A1_PENDING=0/,/^D332_PENDING=0/p' "$SUT"
  printf 'A3_PENDING=${TEST_A3_PENDING:-0}\n'
  sed -n '/^echo "== Section 6:/,$p' "$SUT"
} > "$WORK/closeout.sh"

close_log="$WORK/closed"
PATH="$WORK:$PATH" TEST_CLOSE_LOG="$close_log" bash "$WORK/closeout.sh" > "$WORK/closeout.out"
[ "$(cat "$close_log")" = 306 ] || { echo 'FAIL: A6 must hold #1234 open even when A3 is converged' >&2; exit 1; }
grep -q 'A6=1' "$WORK/closeout.out"
grep -q 'All 48 repositories' "$SUT"
echo "PASS: converged A3 closes #306 while unresolved A6 holds #1234 open"

for scenario in explore-present explore-error casket-pages.yml pages-archive.yml pages.yml existing-a3; do
  explore=absent workflows='[]' earlier_pending=0
  case "$scenario" in
    explore-present) explore=present ;;
    explore-error) explore=error ;;
    existing-a3) earlier_pending=1 ;;
    *) workflows="[{\"name\":\"$scenario\"}]" ;;
  esac
  : > "$close_log"
  PATH="$WORK:$PATH" TEST_CLOSE_LOG="$close_log" TEST_EXPLORE="$explore" \
    TEST_WORKFLOWS="$workflows" TEST_A3_PENDING="$earlier_pending" \
    bash "$WORK/closeout.sh" > "$WORK/closeout.out"
  [ ! -s "$close_log" ] || { echo "FAIL: premature closure for $scenario" >&2; exit 1; }
  grep -q '#306 kept open' "$WORK/closeout.out"
  grep -q '#1234 kept open' "$WORK/closeout.out"
done
if PATH="$WORK:$PATH" TEST_CLOSE_LOG="$close_log" TEST_WORKFLOWS=error \
  bash "$WORK/closeout.sh" > "$WORK/closeout.out"; then
  echo 'FAIL: D341 query failure must stop closure' >&2
  exit 1
fi
[ ! -s "$close_log" ]
echo "PASS: D329, each D341 workflow, existing A3 work, and failed queries prevent premature closure"

# 7. Execute Section 5 with independently installed/uninstalled owners. The
#    gh clone stub creates empty local fixtures, representing converged repos.
{
  printf 'set -euo pipefail\nDRY_RUN=${TEST_DRY_RUN:-0}\nWORK_TMP=$TEST_WORK_TMP\nD332_PENDING=0\n'
  sed -n '/^run_gh()/,/^}/p' "$SUT"
  sed -n '/^check_probot_installed()/,/^}/p' "$SUT"
  sed -n '/^echo "== Section 5 /,/^# Section 6 /p' "$SUT"
  printf 'printf "D332_PENDING=%%s\\n" "$D332_PENDING"\n'
} > "$WORK/settings.sh"

for hyper in 0 1; do
  for meta in 0 1; do
    installations="$(jq -nc --argjson hyper "$hyper" --argjson meta "$meta" '
      [{installations: [{app_id:1561, account:{login:"unrelated-owner"}},
                        {app_id:9999, account:{login:"hyperpolymath"}}]},
       {installations: ([{app_id:1561, account:{login:"hyperpolymath"}} | select($hyper == 1)] +
                        [{app_id:1561, account:{login:"metadatastician"}} | select($meta == 1)])}]')"
    clone_log="$WORK/cloned"
    : > "$clone_log"
    PATH="$WORK:$PATH" TEST_CLONE_LOG="$clone_log" TEST_WORK_TMP="$WORK" \
      TEST_INSTALLATIONS="$installations" bash "$WORK/settings.sh" > "$WORK/settings.out"
    pending=$((65 * hyper + 30 * meta))
    [ "$(wc -l < "$clone_log")" -eq "$((95 - pending))" ]
    grep -q "D332_PENDING=$pending" "$WORK/settings.out"
    if [ "$hyper" -eq 1 ] && grep -q '^hyperpolymath/' "$clone_log"; then
      echo 'FAIL: personal-owner cleanup began before uninstall' >&2; exit 1
    fi
    if [ "$meta" -eq 1 ] && grep -q '^metadatastician/' "$clone_log"; then
      echo 'FAIL: organisation cleanup began before uninstall' >&2; exit 1
    fi
  done
done
for endpoint in user/installations orgs/metadatastician/installations; do
  if PATH="$WORK:$PATH" TEST_CLONE_LOG="$clone_log" TEST_WORK_TMP="$WORK" \
    TEST_INSTALLATION_ERROR="$endpoint" bash "$WORK/settings.sh" > "$WORK/settings.out" 2>&1; then
    echo "FAIL: live installation query failure must stop cleanup: $endpoint" >&2; exit 1
  fi
  PATH="$WORK:$PATH" TEST_CLONE_LOG="$clone_log" TEST_WORK_TMP="$WORK" TEST_DRY_RUN=1 \
    TEST_INSTALLATION_ERROR="$endpoint" bash "$WORK/settings.sh" > "$WORK/settings.out"
  grep -q 'D332_PENDING=95' "$WORK/settings.out"
done
echo "PASS: each owner gates cleanup on its own uninstall, filters app/account across pages, and fails closed on query errors"
