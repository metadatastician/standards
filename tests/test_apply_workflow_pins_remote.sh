#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test_apply_workflow_pins_remote.sh — regression suite for the pin applier.
#
# This suite is MUTATION-BASED on purpose. A green run of the applier's own
# controls proves only that the controls agree with the code; it does not prove
# the controls can DETECT anything. So every mutant below reintroduces a real
# defect verbatim and asserts the suite turns red. A mutant that stays green is
# a control that was never testing what its name claims.
#
# Trap already paid for once: a syntactically INVALID mutant fails for the wrong
# reason and every control "fails" on a parse error, which reads as success.
# Each mutant is therefore `bash -n`-checked BEFORE its redness is believed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLIER="${SCRIPT_DIR}/../scripts/apply-workflow-pins-remote.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*" >&2; rc=1; }

# --- 0. the script must exist, parse, and be committed executable ------------
echo "== 0. shape =="
[ -f "$APPLIER" ] || { echo "FATAL: applier not found at $APPLIER" >&2; exit 1; }
bash -n "$APPLIER" && pass "applier parses" || fail "applier does not parse"

# A suite committed 100644 passes every local run (`bash script` ignores the
# mode) and dies in CI at exit 126 before a single control runs.
if git -C "${SCRIPT_DIR}/.." ls-files -s -- tests/test_apply_workflow_pins_remote.sh 2>/dev/null | grep -q '^100755'; then
  pass "this test is committed executable (100755)"
elif ! git -C "${SCRIPT_DIR}/.." rev-parse --git-dir >/dev/null 2>&1; then
  pass "not a git checkout; mode check skipped"
else
  # Not yet staged is acceptable while authoring; a wrong mode is not.
  if git -C "${SCRIPT_DIR}/.." ls-files -- tests/test_apply_workflow_pins_remote.sh 2>/dev/null | grep -q .; then
    fail "test is tracked but NOT 100755 — it will exit 126 in CI"
  else
    pass "test not yet tracked; mode will be checked once added"
  fi
fi
if git -C "${SCRIPT_DIR}/.." ls-files -s -- scripts/apply-workflow-pins-remote.sh 2>/dev/null | grep -q '^100644'; then
  fail "applier is tracked 100644 — it must be executable"
else
  pass "applier mode acceptable"
fi

# --- 1. the applier's own controls must pass unmutated -----------------------
echo "== 1. baseline: unmutated controls =="
if bash "$APPLIER" --self-test >"$TMP/base.out" 2>&1; then
  pass "baseline controls green"
else
  fail "baseline controls RED — fix the applier before reading any mutant"
  sed 's/^/    /' "$TMP/base.out" >&2
fi
for want in "fresh.yml" "behind.yml" "illegal.yml" "tracking.yml" "none.yml" "short.yml"; do
  grep -q "PASS $want" "$TMP/base.out" && pass "control present: $want" \
    || fail "control MISSING from baseline: $want (a control that never runs is not a control)"
done

# --- 2. mutants --------------------------------------------------------------
# kill <name> <sed-expr> <expected-substring-in-red-output>
kill_mutant() {
  # NOTE: `local a="$1" m="${a}"` does NOT work — bash expands every word of the
  # `local` builtin's argument list BEFORE assigning any of them, so `${a}` is
  # unset there. Assign on separate lines. (Cost one red herring to find.)
  local name="$1" expr="$2" want="$3"
  local m="$TMP/mutant_${name}.sh"
  cp "$APPLIER" "$m"
  sed -E -i "$expr" "$m"

  if cmp -s "$APPLIER" "$m"; then
    fail "mutant '$name' changed NOTHING — the sed did not match, so nothing was tested"
    return
  fi
  if ! bash -n "$m" 2>"$TMP/${name}.parse"; then
    fail "mutant '$name' is SYNTACTICALLY INVALID — its redness would be meaningless"
    sed 's/^/    /' "$TMP/${name}.parse" >&2
    return
  fi

  if bash "$m" --self-test >"$TMP/${name}.out" 2>&1; then
    fail "mutant '$name' stayed GREEN — no control detects this defect"
  elif grep -qF "$want" "$TMP/${name}.out"; then
    pass "mutant '$name' killed by the right control"
  else
    fail "mutant '$name' died, but not at '$want' — the wrong control fired"
    sed 's/^/    /' "$TMP/${name}.out" >&2
  fi
}

echo "== 2. mutation kills =="

# M1 — classify by SHA pins only. This is the exact blind spot the older
# scripts/propagate-workflow-pins.sh still has: its PIN_RE cannot see an
# unparseable `uses: ../../`, so a repo full of them audits as clean. That
# population is issue #808.
kill_mutant illegal_blind \
  's@^  if \[ -n "\$\(illegal_uses "\$f"\)" \]; then@  if false; then@' \
  "FAIL illegal.yml"

# M2 — compare a pin to the target by exact string instead of by prefix. A
# legitimately short pin then reads BEHIND forever: the applier rewrites it, the
# rewrite is a no-op, and the next run finds it BEHIND again. An applier that
# never converges is just a sweep on a cron.
kill_mutant short_pin_never_converges \
  's@if \[ "\$\{target:0:\$\{#sha\}\}" = "\$sha" \]@if [ "$target" = "$sha" ]@' \
  "FAIL short.yml"

# M3 — drop branch/tag tracking detection. `affinescript` tracks `@main`;
# dropping TRACKING from the census makes the estate's one unpinned caller
# invisible to the policy that forbids unpinned callers.
kill_mutant tracking_blind \
  's@^  if \[ -n "\$\(tracking_refs "\$f"\)" \]; then@  if false; then@' \
  "FAIL tracking.yml"

# M4 — anchor the rewrite on the SHA rather than on the standards reusable PATH.
# It then re-points EVERY 40-hex pin in the file, including actions/checkout, at
# a standards commit. Catastrophic, and both the idempotency control and the
# hit-the-target control stay green through it — which is precisely why the
# third-party control had to be added. The rewrite now matches either owner
# (it migrates the former one), so the anchor is two groups, (owner) and
# (path); the mutant empties both. `%` delimits the mutant so the `\|` in the
# pattern stays a literal pipe under sed -E.
kill_mutant rewrite_overreaches \
  's%s#\(hyperpolymath\|metadatastician\)/standards/\(\\\.github/workflows/\[A-Za-z0-9\._-\]\+\\\.ya\?ml@\)%s#()()%' \
  "FAIL rewrite overreached"

# M5 — the illegal repair emits a ref with no SHA. A "repair" that leaves the
# workflow still unparseable converts a visible failure into a repaired-looking
# one, which is strictly worse than not repairing it.
kill_mutant illegal_repair_still_illegal \
  's@\@\$\{target\}@\@@g' \
  "FAIL illegal repair"

# --- 3. fetch_workflows fails CLOSED -----------------------------------------
# A rate-limited repo used to come back as "no workflows": fetch_workflows
# returned 0 on every failure, so the census dropped the repo while `walked N`
# still counted it (2026-10-02). Only a 404 may read as "nothing here".
echo "== 3. fetch failures are reported, not swallowed =="
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api graphql"*) exit 1 ;;   # force the REST fallback
  *contents/.github/workflows/*)
    [ "${FILE_FAIL:-}" = 1 ] && { echo "gh: rate limit (HTTP 403)" >&2; exit 1; }
    echo 'on: push'; exit 0 ;;
  *contents/.github/workflows*)
    case "${LIST:-200}" in
      200) echo ci.yml; exit 0 ;;
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      *)   echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1 ;;
    esac ;;
esac
exit 1
EOF
chmod +x "$STUB/gh"
# fetch_case <label> <want-rc> <env...> — run fetch_workflows against the stub.
fetch_case() {
  local label="$1" want="$2"; shift 2
  local got
  env PATH="$STUB:$PATH" "$@" bash -c 'source "$1"; fetch_workflows o/r "$2"' _ \
      "${APPLIER_UNDER_TEST:-$APPLIER}" "$TMP/fetch.$label" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then pass "fetch: $label (rc=$got)"; else fail "fetch: $label — expected rc=$want, got rc=$got"; fi
}
fetch_case "listing ok"            0 LIST=200
fetch_case "no workflows dir (404)" 0 LIST=404
fetch_case "rate-limited listing"   1 LIST=403
fetch_case "file download fails"    1 LIST=200 FILE_FAIL=1
[ -s "$TMP/fetch.listing ok/ci.yml" ] && pass "fetch: file content written" || fail "fetch: ci.yml not written"

# Mutant: restore the old `return 0` on a failed listing. It must turn red.
M="$TMP/mutant_fail_open.sh"; cp "$APPLIER" "$M"
sed -i 's@^    return 1$@    return 0@' "$M"
if cmp -s "$APPLIER" "$M" || ! bash -n "$M"; then
  fail "fail-open mutant did not apply cleanly"
else
  out=$(APPLIER_UNDER_TEST="$M" fetch_case "MUTANT rate-limited listing" 1 LIST=403 2>&1)
  case "$out" in *FAIL*) pass "mutant 'fetch_fail_open' killed by the rate-limit control" ;;
                 *) fail "mutant 'fetch_fail_open' stayed GREEN" ;; esac
fi

# --- 4. list_repos sees every repository the credential can see ---------------
# Under a GitHub App installation token (ghs_), users/<o>/repos and
# orgs/<o>/repos return PUBLIC repositories only, so the private repositories the
# App can write never reached the census (finding 2026-10-08). The cure ADDS
# installation/repositories. It must not REPLACE the public listing: GITHUB_TOKEN
# is ghs_ too, its installation is one repository, and the scheduled audit runs
# on it while no App is configured.
echo "== 4. enumeration under App, GITHUB_TOKEN and PAT credentials =="
command -v jq >/dev/null || { fail "jq is required by section 4"; exit 1; }
T="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
LSTUB="$TMP/lstub"; mkdir -p "$LSTUB"
cat > "$LSTUB/gh" <<'EOF'
#!/usr/bin/env bash
# gh — test double serving repository listings and workflow trees from
# $GH_FIX, and modelling which token kinds may call installation/repositories.
echo "$*" >> "$GH_FIX/calls.log"
[ "${1:-} ${2:-}" = "auth status" ] && exit 0
[ "${1:-}" = api ] || exit 64
shift
path="" jqx="" gql=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q)     jqx="$2"; shift ;;
    -F|-f|-H)    shift ;;
    -*)          ;;
    graphql)     gql=1 ;;
    *)           [ -n "$path" ] || path="$1" ;;
  esac
  shift
done
# refuse — fail the way gh does on a non-2xx response: message on stderr, rc 1.
refuse() { echo "gh: $2 (HTTP $1)" >&2; exit 1; }
if [ "$gql" = 1 ]; then
  # Every repository holds one workflow, pinned FRESH at $TARGET.
  jq -n --arg sha "$TARGET" '{data: {repository: {object: {entries: [{name: "ci.yml", type: "blob",
    object: {text: ("jobs:\n  a:\n    uses: hyperpolymath/standards/.github/workflows/x.yml@" + $sha + "\n")}}]}}}}'
  exit 0
fi
p="${path%%\?*}"
case "$p" in
  users/*/repos|orgs/*/repos)
    kind="${p%%/*}"; o="${p#*/}"; o="${o%/repos}"
    [ -f "$GH_FIX/${kind}_fail_$o" ] && refuse 403 "API rate limit exceeded"
    body="$GH_FIX/${kind}_$o.json" ;;
  installation/repositories)
    case "${GH_TOKEN:-}" in ghs_*) ;; *) refuse 403 "This endpoint requires an installation access token" ;; esac
    [ -f "$GH_FIX/inst_fail" ] && refuse 502 "Bad Gateway"
    body="$GH_FIX/inst.json" ;;
  *) refuse 404 "Not Found" ;;
esac
[ -f "$body" ] || refuse 404 "Not Found"
if [ -n "$jqx" ]; then jq -r "$jqx" "$body"; else cat "$body"; fi
EOF
chmod +x "$LSTUB/gh"

# Mutants are sourced, and the applier sources lib/ beside itself.
MUT="$TMP/mut"; mkdir -p "$MUT"
ln -s "$(cd "$(dirname "$APPLIER")" && pwd)/lib" "$MUT/lib"

# fixture_repos <file> <owner/name:archived>... — write a REST repository list.
fixture_repos() {
  local f="$1"; shift
  printf '%s\n' "$@" \
    | jq -R 'split(":") | {full_name: .[0], archived: (.[1] == "true")}' | jq -s . > "$f"
}

# new_case <label> — make a fixture directory holding the two-owner estate every
# case starts from, and print its path. hyperpolymath has a public and an
# archived repository, metadatastician one public one, and the App installation
# on hyperpolymath holds the public one, a PRIVATE one and an archived one.
new_case() {
  local d; d=$(mktemp -d "$TMP/list.$1.XXXX")
  fixture_repos "$d/users_hyperpolymath.json" hyperpolymath/pub-a:false hyperpolymath/old:true
  fixture_repos "$d/users_metadatastician.json" metadatastician/pub-c:false
  fixture_repos "$d/inst.repos" hyperpolymath/pub-a:false hyperpolymath/priv-b:false hyperpolymath/arch-p:true
  jq '{total_count: length, repositories: .}' "$d/inst.repos" > "$d/inst.json"
  echo "$d"
}

# run_list <dir> <token> <owners> <applier> — run list_repos against the listing
# stub; stdout to <dir>/out, stderr to <dir>/err, exit status to <dir>/rc.
run_list() {
  local d="$1"
  : > "$d/calls.log"
  # shellcheck disable=SC2016  # $1 and $2 are expanded by the inner shell
  env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN="$2" GITHUB_TOKEN= \
    bash -c 'source "$1"; OWNERS="$2"; list_repos' _ "$4" "$3" > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
}

# run_main <dir> <token> <applier> — run the whole applier in audit mode against
# the stub, with only the network ancestry proof stubbed out.
run_main() {
  local d="$1"
  : > "$d/calls.log"
  # shellcheck disable=SC2016  # $1 and $2 are expanded by the inner shell
  env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN="$2" GITHUB_TOKEN= TARGET="$T" \
    bash -c 'source "$1"; validate_target() { return 0; }; shift; main "$@"' _ "$3" \
      --to "$T" --owners hyperpolymath,metadatastician > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
}

# expect_list <label> <dir> <want-rc> <repo>... — require exactly these
# repositories, each once and sorted, and exactly this exit status.
expect_list() {
  local label="$1" d="$2" want_rc="$3"; shift 3
  local want got
  want=$(printf '%s\n' "$@" | sed '/^$/d' | sort)
  got=$(cat "$d/out")
  if [ "$(cat "$d/rc")" = "$want_rc" ] && [ "$got" = "$want" ]; then
    pass "list: $label"
  else
    fail "list: $label — rc=$(cat "$d/rc") (want $want_rc); got [${got//$'\n'/ }] want [${want//$'\n'/ }]"
  fi
}

# case_app <applier> — a dedicated App's token: the public listings plus the
# installation's private repository, archived ones dropped, each listed once.
case_app() {
  local d; d=$(new_case app)
  run_list "$d" ghs_app hyperpolymath,metadatastician "$1"
  expect_list "App token adds the installation's private repository" "$d" 0 \
    hyperpolymath/priv-b hyperpolymath/pub-a metadatastician/pub-c
}

# case_github_token <applier> — GITHUB_TOKEN is ghs_ too, and its installation
# is this one repository: the public listings must survive alongside it.
case_github_token() {
  local d; d=$(new_case gtok)
  fixture_repos "$d/users_hyperpolymath.json" hyperpolymath/pub-a:false hyperpolymath/standards:false
  fixture_repos "$d/inst.repos" hyperpolymath/standards:false
  jq '{total_count: length, repositories: .}' "$d/inst.repos" > "$d/inst.json"
  run_list "$d" ghs_gtok hyperpolymath,metadatastician "$1"
  expect_list "GITHUB_TOKEN keeps the public census" "$d" 0 \
    hyperpolymath/pub-a hyperpolymath/standards metadatastician/pub-c
}

# case_pat <applier> — a PAT keeps the public listings and never calls the
# installation endpoint, which would refuse it.
case_pat() {
  local d; d=$(new_case pat)
  run_list "$d" ghp_pat hyperpolymath,metadatastician "$1"
  expect_list "PAT lists the public repositories" "$d" 0 hyperpolymath/pub-a metadatastician/pub-c
  if grep -q 'installation/repositories' "$d/calls.log"; then
    fail "list: PAT called installation/repositories"
  else
    pass "list: PAT never calls installation/repositories"
  fi
}

# case_owner_filter <applier> — --owners narrows the census under an App token
# too: the installation's hyperpolymath repositories must not leak in.
case_owner_filter() {
  local d; d=$(new_case owners)
  run_list "$d" ghs_app metadatastician "$1"
  expect_list "--owners metadatastician admits no installation repo of hyperpolymath" "$d" 0 \
    metadatastician/pub-c
}

# case_org_fallback <applier> — an owner whose users/ listing 404s is listed
# through orgs/.
case_org_fallback() {
  local d; d=$(new_case orgs)
  mv "$d/users_metadatastician.json" "$d/orgs_metadatastician.json"
  run_list "$d" ghp_pat hyperpolymath,metadatastician "$1"
  expect_list "a users/ 404 falls back to orgs/" "$d" 0 hyperpolymath/pub-a metadatastician/pub-c
}

# case_inst_fail <applier> — a failed installation listing fails the whole
# enumeration, prints no repositories, and names the endpoint.
case_inst_fail() {
  local d; d=$(new_case instfail)
  touch "$d/inst_fail"
  run_list "$d" ghs_app hyperpolymath,metadatastician "$1"
  expect_list "a failed installation listing fails closed" "$d" 1
  if grep -q 'installation/repositories' "$d/err"; then
    pass "list: the failure names installation/repositories"
  else
    fail "list: the failure does not name installation/repositories"
  fi
}

# case_public_fail <applier> — an owner whose public listing fails on both
# endpoints fails the enumeration, even though the installation listing worked.
case_public_fail() {
  local d; d=$(new_case pubfail)
  touch "$d/users_fail_metadatastician" "$d/orgs_fail_metadatastician"
  run_list "$d" ghs_app hyperpolymath,metadatastician "$1"
  expect_list "a rate-limited owner fails closed, not empty" "$d" 1
  if grep -q 'metadatastician' "$d/err"; then
    pass "list: the failure names the owner"
  else
    fail "list: the failure does not name the owner"
  fi
}

# case_main_app <applier> — end to end: under an App token the private
# repository is fetched and classified, and appears in the census.
case_main_app() {
  local d; d=$(new_case mainapp)
  run_main "$d" ghs_app "$1"
  if [ "$(cat "$d/rc")" = 0 ] && grep -qF "$(printf 'hyperpolymath/priv-b\tci.yml\tFRESH')" "$d/out"; then
    pass "main: the census classifies the private repository"
  else
    fail "main: private repository missing from the census (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/err" | tail -5 >&2
  fi
}

# case_main_fail <applier> — end to end: a failed enumeration stops the run,
# writes no census, and says the enumeration failed.
case_main_fail() {
  local d; d=$(new_case mainfail)
  touch "$d/inst_fail"
  run_main "$d" ghs_app "$1"
  if [ "$(cat "$d/rc")" = 1 ] && ! grep -q '^REPO' "$d/out" \
     && grep -q 'repository enumeration failed' "$d/err"; then
    pass "main: a failed enumeration stops the run before any census"
  else
    fail "main: failed enumeration not reported as such (rc=$(cat "$d/rc"))"
  fi
}

# Planted positives: the stub must be able to say no, or every fail-closed case
# above could pass because nothing ever failed.
d=$(new_case planted)
if env GH_FIX="$d" GH_TOKEN=ghp_pat "$LSTUB/gh" api installation/repositories >/dev/null 2>&1; then
  fail "planted: stub let a PAT list installation/repositories"
else
  pass "planted: stub refuses installation/repositories to a PAT"
fi
touch "$d/users_fail_metadatastician"
if env GH_FIX="$d" GH_TOKEN=ghs_app "$LSTUB/gh" api users/metadatastician/repos >/dev/null 2>&1; then
  fail "planted: stub ignored a users_fail flag"
else
  pass "planted: stub fails a flagged users/ listing"
fi

case_app "$APPLIER"
case_github_token "$APPLIER"
case_pat "$APPLIER"
case_owner_filter "$APPLIER"
case_org_fallback "$APPLIER"
case_inst_fail "$APPLIER"
case_public_fail "$APPLIER"
case_main_app "$APPLIER"
case_main_fail "$APPLIER"

# --- 5. a reachable target is refused when its own lock fails lock-selfcheck --
# GitHub validates each caller against the TARGET's actions.lock, so a target
# that is reachable from main but whose lock the runner refuses (standards
# fad242d3: ten self-SHA leaves) must never be pinned. Ancestry is stubbed
# green and lock-selfcheck.sh is replaced by a stub whose verdict is set per
# case, so what is under test is validate_target's own wiring: a refusal (1)
# and a not-inspected (2) both stop the run; a pass lets it through.
echo "== 5. target self-check =="
# case_target_selfcheck <applier> <selfcheck-rc> <want-rc> <label>
case_target_selfcheck() {
  local root sha got=0
  root=$(mktemp -d "$TMP/selfcheck.XXXX")
  mkdir -p "$root/scripts"
  printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$root/scripts/lock-selfcheck.sh"
  git -C "$root" init -q
  git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m target
  sha=$(git -C "$root" rev-parse HEAD)
  # shellcheck disable=SC2016  # expanded by the inner shell
  bash -c 'source "$1"; STANDARDS_ROOT="$2"; assert_pin_ancestry() { return 0; }; validate_target "$3"' \
    _ "$1" "$root" "$sha" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$3" ]; then pass "target self-check: $4"; else fail "target self-check: $4 — rc=$got (want $3)"; fi
}
case_target_selfcheck "$APPLIER" 1 1 "a target lock-selfcheck rejects is refused"
case_target_selfcheck "$APPLIER" 2 1 "a target lock-selfcheck cannot examine is refused"
case_target_selfcheck "$APPLIER" 0 0 "control: a self-consistent reachable target is accepted"

# list_mutant <name> <sed-expr> <case-fn> — apply <sed-expr> to a copy of the
# applier, prove the edit landed and still parses, then require <case-fn> to
# report FAIL against it.
list_mutant() {
  local name="$1" expr="$2" fn="$3"
  local m="$MUT/mutant_${name}.sh" out
  cp "$APPLIER" "$m"
  sed -E -i "$expr" "$m"
  if cmp -s "$APPLIER" "$m"; then
    fail "mutant '$name' changed NOTHING — the sed did not match"; return
  fi
  if ! bash -n "$m" 2>"$MUT/${name}.parse"; then
    fail "mutant '$name' is SYNTACTICALLY INVALID — its redness would be meaningless"
    sed 's/^/    /' "$MUT/${name}.parse" >&2; return
  fi
  out=$("$fn" "$m" 2>&1)
  case "$out" in
    *FAIL*) pass "mutant '$name' killed by $fn" ;;
    *)      fail "mutant '$name' stayed GREEN under $fn" ;;
  esac
}

# shellcheck disable=SC2016  # the ${…} and $(…) below are sed text to match
{
list_mutant app_token_blind 's@^    ghs_\*\)$@    NOT_A_TOKEN_PREFIX*)@' case_app
list_mutant replace_not_union \
  '0,\@^  for owner in \$\{OWNERS//,/ \}; do$@s@@&\n    case "$tok" in ghs_*) continue ;; esac@' \
  case_github_token
list_mutant no_dedupe 's@^  sort -u "\$all"$@  cat "$all"@' case_app
list_mutant owner_filter_dropped "s@'index\\(tolower\\(\\\$0\\), o\\) == 1'@'1'@" case_owner_filter
list_mutant inst_failure_swallowed 's@\|\| \{ log "FATAL: an App installation token[^}]*\}@|| true@' case_inst_fail
list_mutant public_failure_swallowed 's@^      log "FATAL: could not list the repositories of.*$@      :@' case_public_fail
}

echo
if [ "$rc" -ne 0 ]; then echo "RESULT: FAILED" >&2; else echo "RESULT: all checks passed"; fi
exit $rc
