#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# apply-tag-ruleset-canon-test.sh — behavioural tests for
# scripts/apply-tag-ruleset-canon.sh under per-owner GitHub App tokens.
#
# tests/test_tag_ruleset_canon.sh checks the applier's SOURCE for structural
# guards. This file RUNS the applier against a stub `gh` that models the three
# server facts tag-ruleset-canon.yml depends on once it mints one App
# installation token per owner (RULESET_APP_ID, 2026-10-08):
#
#   1. An installation token (prefix ghs_) cannot call user/repos: that endpoint
#      needs a user identity and an installation has none. The pre-fix applier
#      called it unconditionally, so under `set -e` the hyperpolymath step died
#      before examining a single repository.
#   2. An installation token can write only its own installation's repos. The
#      pre-fix write probe always self-PUT GITHUB_REPOSITORY
#      (hyperpolymath/standards), so the metadatastician step's apply run
#      stopped with a FALSE "credential cannot WRITE rulesets" (exit 3).
#   3. ESTATE_ORGS set to '' (the hyperpolymath step) must mean NO orgs. The
#      pre-fix `${ESTATE_ORGS:-metadatastician}` turned '' back into
#      metadatastician, so the hyperpolymath token also swept repos it cannot
#      write.
#
# Every guard is backed by a mutant that reintroduces the defect and must turn
# the matching case red, and the stub's own refusals are planted positives:
# a stub that never says no would make every case here pass vacuously.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APPLIER="$ROOT/scripts/apply-tag-ruleset-canon.sh"
CANON="$ROOT/config/rulesets/immutable-tags.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# ok — record and print a passing assertion.
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
# bad — record and print a failing assertion.
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

command -v jq >/dev/null || { echo "FAIL: jq is required by this test"; exit 1; }
[ -f "$APPLIER" ] || { echo "FAIL: applier missing: $APPLIER"; exit 1; }
[ -f "$CANON" ]   || { echo "FAIL: canon missing: $CANON"; exit 1; }

# ---------------------------------------------------------------------------
# The stub gh. Fixtures live in $GH_FIX; every call is appended to
# $GH_FIX/calls.log and every accepted write to $GH_FIX/writes.log.
# ---------------------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# gh — test double for `gh api`, serving reads from $GH_FIX and modelling which
# token kinds GitHub lets call which endpoint and write which repository.
set -uo pipefail
echo "$*" >> "$GH_FIX/calls.log"
[ "${1:-}" = "api" ] || { echo "stub gh: unsupported command: $*" >&2; exit 64; }
shift
method=GET path="" jqx=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method|-X) method="$2"; shift ;;
    --jq|-q)     jqx="$2"; shift ;;
    --input|-f|-F) shift ;;
    --paginate)  ;;
    -*)          ;;
    *)           [ -n "$path" ] || path="$1" ;;
  esac
  shift
done

# refuse — fail the way gh does on a non-2xx response: message on stderr, rc 1.
refuse() { echo "gh: $2 (HTTP $1)" >&2; exit 1; }

inst=0
case "${GH_TOKEN:-}" in ghs_*) inst=1 ;; esac
p="${path%%\?*}"
IFS=/ read -r seg1 owner name seg4 rid _ <<< "$p"

if [ "$method" != GET ]; then
  [ -f "$GH_FIX/deny_writes" ] && refuse 403 "Resource not accessible by integration"
  if [ "$inst" -eq 1 ]; then
    names=$(jq -r '.repositories[].full_name' "$GH_FIX/inst.json") || names=
  fi
  if [ "$inst" -eq 1 ] && ! grep -qxF -- "$owner/$name" <<<"$names"; then
    refuse 403 "Resource not accessible by integration"
  fi
  # An org-inherited ruleset is listed per repo but written at /orgs/...;
  # a per-repo PUT of it 404s (#1032).
  if [ "$seg4" = rulesets ] && [ -n "$rid" ] && [ -f "$GH_FIX/rs/${owner}__$name.json" ] \
     && jq -e --argjson id "$rid" 'any(.[]; .id == $id and .source_type == "Organization")' \
          "$GH_FIX/rs/${owner}__$name.json" >/dev/null; then
    refuse 404 "Not Found"
  fi
  echo "$method $p" >> "$GH_FIX/writes.log"
  echo '{}'; exit 0
fi

case "$p" in
  user/repos)
    [ "$inst" -eq 1 ] && refuse 403 "Resource not accessible by integration"
    body="$GH_FIX/user_repos.json" ;;
  installation/repositories)
    [ "$inst" -eq 1 ] || refuse 403 "This endpoint requires an installation access token"
    [ -f "$GH_FIX/inst_fail" ] && refuse 502 "Bad Gateway"
    body="$GH_FIX/inst.json" ;;
  orgs/*/repos)
    body="$GH_FIX/orgs_$owner.json" ;;
  repos/*/*/rulesets)
    body="$GH_FIX/rs/${owner}__$name.json" ;;
  repos/*/*/rulesets/*)
    body="$GH_FIX/rd/${owner}__${name}__$rid.json" ;;
  *) refuse 404 "Not Found" ;;
esac
[ -f "$body" ] || refuse 404 "Not Found"
if [ -n "$jqx" ]; then jq -r "$jqx" "$body"; else cat "$body"; fi
STUB
chmod +x "$BIN/gh"

# fixture_installation <fixdir> <owner/name:archived>... — write the
# installation/repositories body, plus user/repos and orgs/<owner>/repos bodies
# listing the same repositories.
fixture_installation() {
  local d="$1"; shift
  mkdir -p "$d/rs" "$d/rd"
  printf '%s\n' "$@" \
    | jq -R 'split(":") | {full_name: .[0], archived: (.[1] == "true")}' \
    | jq -s '{total_count: length, repositories: .}' > "$d/inst.json"
  jq '.repositories' "$d/inst.json" > "$d/user_repos.json"
  local o; o=$(jq -r '.repositories[0].full_name | split("/")[0]' "$d/inst.json")
  jq '.repositories' "$d/inst.json" > "$d/orgs_$o.json"
}

# fixture_ruleset <fixdir> <owner/name> <id> <source_type> — give the repo one
# active ~ALL tag ruleset in the canon's shape: its LIST summary and its
# GET-by-id detail.
fixture_ruleset() {
  local d="$1" repo="$2" id="$3" src="$4" key="${2//\//__}"
  mkdir -p "$d/rs" "$d/rd"
  jq -n --argjson id "$id" --arg src "$src" --arg repo "$repo" \
    '[{id: $id, name: "immutable-tags", target: "tag", source_type: $src,
       source: $repo, enforcement: "active"}]' > "$d/rs/$key.json"
  jq --argjson id "$id" --arg src "$src" '. + {id: $id, source_type: $src}' \
    "$CANON" > "$d/rd/${key}__$id.json"
}

# run_applier <script> <fixdir> <token> <estate_orgs> [args...] — run an
# applier against the stub; stdout goes to <fixdir>/out.tsv, stderr to
# <fixdir>/err, and the exit code to RC. GITHUB_REPOSITORY is the workflow's
# own repo, as in tag-ruleset-canon.yml.
run_applier() {
  local script="$1" fix="$2" tok="$3" orgs="$4"; shift 4
  rm -f "$fix/calls.log" "$fix/writes.log"; : > "$fix/calls.log"
  RC=0
  ( cd "$fix" && GH_FIX="$fix" GH_TOKEN="$tok" PATH="$BIN:$PATH" \
      CANON_FILE="$CANON" GITHUB_REPOSITORY=hyperpolymath/standards \
      ESTATE_ORGS="$orgs" bash "$script" "$@" ) > "$fix/out.tsv" 2> "$fix/err" || RC=$?
}

# targets_of <fixdir> — the repositories the last run reported on, one line.
targets_of() { cut -f1 "$1/out.tsv" | sort -u | tr '\n' ' '; }

# why <fixdir> — a one-line diagnostic for a failing case.
why() { echo "rc=$RC targets=[$(targets_of "$1")] err: $(tail -n 2 "$1/err" | tr '\n' ' ')"; }

# The hyperpolymath installation. gamma is archived and must never be a target.
# The metadatastician org listing is present so that a run which wrongly
# unions it in has something to find.
FA="$WORK/fix-user"
fixture_installation "$FA" hyperpolymath/alpha:false hyperpolymath/beta:false hyperpolymath/gamma:true
fixture_ruleset "$FA" hyperpolymath/alpha 11 Repository
fixture_ruleset "$FA" hyperpolymath/beta 12 Repository
fixture_ruleset "$FA" hyperpolymath/gamma 13 Repository
fixture_ruleset "$FA" hyperpolymath/standards 900 Repository
echo '[{"full_name":"metadatastician/delta","archived":false}]' > "$FA/orgs_metadatastician.json"
fixture_ruleset "$FA" metadatastician/delta 32 Repository

# The metadatastician installation. orgonly is listed FIRST and carries only an
# org-inherited tag ruleset, which the write probe must pass over.
# hyperpolymath/standards is readable but outside this installation.
FM="$WORK/fix-org"
fixture_installation "$FM" metadatastician/orgonly:false metadatastician/delta:false
fixture_ruleset "$FM" metadatastician/orgonly 31 Organization
fixture_ruleset "$FM" metadatastician/delta 32 Repository
fixture_ruleset "$FM" hyperpolymath/standards 900 Repository

# case_user_app <script> — the hyperpolymath step: App token, ESTATE_ORGS='',
# dry run. Targets are exactly the installation's non-archived repos, both
# CONVERGED, rc 0, and user/repos is never called.
case_user_app() {
  run_applier "$1" "$FA" ghs_hyperpolymath ''
  [ "$RC" -eq 0 ] \
    && [ "$(targets_of "$FA")" = "hyperpolymath/alpha hyperpolymath/beta " ] \
    && [ "$(grep -c $'\tCONVERGED\t' "$FA/out.tsv")" -eq 2 ] \
    && grep -q 'from installation/repositories' "$FA/err" \
    && ! grep -q 'user/repos' "$FA/calls.log"
}

# case_user_pat <script> — the same step under a PAT (the ESTATE_ADMIN_TOKEN
# fallback): targets still come from user/repos, archived repos excluded.
case_user_pat() {
  run_applier "$1" "$FA" ghp_personal ''
  [ "$RC" -eq 0 ] \
    && [ "$(targets_of "$FA")" = "hyperpolymath/alpha hyperpolymath/beta " ] \
    && grep -q 'from user/repos' "$FA/err" \
    && ! grep -q 'installation/repositories' "$FA/calls.log"
}

# case_pat_probe <script> — apply mode under a PAT keeps probing the workflow's
# own repo, as before this fix.
case_pat_probe() {
  run_applier "$1" "$FA" ghp_personal '' --apply --no-verify
  [ "$RC" -eq 0 ] \
    && [ "$(cat "$FA/writes.log" 2>/dev/null)" = "PUT repos/hyperpolymath/standards/rulesets/900" ]
}

# case_inst_fail <script> — when GitHub will not list the installation's repos,
# the run fails and says so; it never reports on an empty or partial set.
case_inst_fail() {
  touch "$FA/inst_fail"
  run_applier "$1" "$FA" ghs_hyperpolymath ''
  rm -f "$FA/inst_fail"
  [ "$RC" -ne 0 ] && [ ! -s "$FA/out.tsv" ] \
    && grep -q 'could not list installation/repositories' "$FA/err"
}

# case_org_probe <script> — the metadatastician step in apply mode, with
# GITHUB_REPOSITORY=hyperpolymath/standards. The probe must self-PUT a repo-level
# tag ruleset inside the installation (delta, not the org-inherited orgonly)
# and the run must succeed.
case_org_probe() {
  run_applier "$1" "$FM" ghs_metadatastician metadatastician --skip-user --apply --no-verify
  [ "$RC" -eq 0 ] \
    && [ "$(cat "$FM/writes.log" 2>/dev/null)" = "PUT repos/metadatastician/delta/rulesets/32" ] \
    && grep -q 'administration:write confirmed' "$FM/err" \
    && grep -q $'^metadatastician/delta\tCONVERGED\t' "$FM/out.tsv" \
    && grep -q $'^metadatastician/orgonly\tORG-INHERITED\t' "$FM/out.tsv"
}

# case_org_probe_denied <script> — the same run when GitHub refuses every write.
# The probe must still stop the run with exit 3: relocating the probe must not
# make it pass vacuously.
case_org_probe_denied() {
  touch "$FM/deny_writes"
  run_applier "$1" "$FM" ghs_metadatastician metadatastician --skip-user --apply --no-verify
  rm -f "$FM/deny_writes"
  [ "$RC" -eq 3 ] && grep -q 'credential cannot WRITE rulesets' "$FM/err"
}

# --- the stub can say no (planted positives) --------------------------------
if ( GH_FIX="$FA" GH_TOKEN=ghs_x "$BIN/gh" api 'user/repos?affiliation=owner&per_page=100' ) \
     >/dev/null 2>"$WORK/c1"; then
  bad "stub: an installation token was allowed to call user/repos; every case below is vacuous"
elif grep -q 'Resource not accessible by integration' "$WORK/c1"; then
  ok "stub: an installation token is refused user/repos (planted positive)"
else
  bad "stub: user/repos failed for the wrong reason: $(cat "$WORK/c1")"
fi
if ( GH_FIX="$FM" GH_TOKEN=ghs_x "$BIN/gh" api --method PUT \
       repos/hyperpolymath/standards/rulesets/900 --input /dev/null ) >/dev/null 2>&1; then
  bad "stub: an installation token was allowed to write outside its installation"
else
  ok "stub: an installation token is refused a write outside its installation (planted positive)"
fi
if ( GH_FIX="$FM" GH_TOKEN=ghs_x "$BIN/gh" api --method PUT \
       repos/metadatastician/orgonly/rulesets/31 --input /dev/null ) >/dev/null 2>&1; then
  bad "stub: a per-repo PUT of an org-inherited ruleset succeeded; GitHub answers 404"
else
  ok "stub: a per-repo PUT of an org-inherited ruleset is refused (planted positive)"
fi
rm -f "$FA/writes.log" "$FM/writes.log"

# --- the applier, as committed ----------------------------------------------
if case_user_app "$APPLIER"; then
  ok "App token: targets come from installation/repositories, archived excluded, ESTATE_ORGS='' adds no org, rc 0"
else
  bad "App token: the hyperpolymath step does not converge on its installation's repos — $(why "$FA")"
fi
if case_user_pat "$APPLIER"; then
  ok "PAT: targets still come from user/repos"
else
  bad "PAT: the user/repos path regressed — $(why "$FA")"
fi
if case_pat_probe "$APPLIER"; then
  ok "PAT: the write probe still self-PUTs the workflow's own repo"
else
  bad "PAT: the write probe moved — $(why "$FA") writes=[$(cat "$FA/writes.log" 2>/dev/null)]"
fi
if case_inst_fail "$APPLIER"; then
  ok "App token: a failed installation listing fails the run and names the endpoint"
else
  bad "App token: a failed installation listing was not reported — $(why "$FA")"
fi
if case_org_probe "$APPLIER"; then
  ok "org App token: the probe self-PUTs a repo-level ruleset inside its own installation, rc 0"
else
  bad "org App token: the write probe still fails outside the installation — $(why "$FM") writes=[$(cat "$FM/writes.log" 2>/dev/null)]"
fi
if case_org_probe_denied "$APPLIER"; then
  ok "org App token: a credential that cannot write still stops the run with exit 3"
else
  bad "org App token: a write-denied credential no longer fails the probe — $(why "$FM")"
fi

# --- mutants: each reintroduces one defect and must turn its case red --------
# mutant <name> <sed-expr> — write the applier with <sed-expr> applied to
# $WORK/<name>.sh and set MUT to its path; return 1 if the edit did not apply
# or the result does not parse, so that a red can only mean the guard.
mutant() {
  MUT="$WORK/$1.sh"
  sed "$2" "$APPLIER" > "$MUT"
  if cmp -s "$MUT" "$APPLIER"; then bad "mutant $1 was not applied; its pattern no longer matches"; return 1; fi
  if ! bash -n "$MUT" 2>/dev/null; then bad "mutant $1 is not valid bash"; return 1; fi
  return 0
}

# kill_mutant <mutant-name> <case> <what> — require <case> to FAIL on the mutant.
kill_mutant() {
  if "$2" "$MUT"; then bad "mutant $1 survived $2: $3"; else ok "mutant $1 killed by $2"; fi
}

if mutant no-installation 's/ghs_\*) INSTALLATION=1/ghs_NEVER*) INSTALLATION=1/'; then
  kill_mutant no-installation case_user_app "an App token that calls user/repos must not pass"
  kill_mutant no-installation case_org_probe "a probe of GITHUB_REPOSITORY under another owner's token must not pass"
fi
# shellcheck disable=SC2016 # the ${...} is sed text to match, not an expansion
if mutant empty-orgs-default 's/\${ESTATE_ORGS-metadatastician}/${ESTATE_ORGS:-metadatastician}/'; then
  kill_mutant empty-orgs-default case_user_app "ESTATE_ORGS='' must not fall back to metadatastician"
fi
if mutant probe-any-source 's/ and \.source_type == "Repository"//'; then
  kill_mutant probe-any-source case_org_probe "the probe must not pick an org-inherited ruleset"
fi
if mutant listing-swallowed 's/|| die "could not list installation/|| true # "could not list installation/'; then
  kill_mutant listing-swallowed case_inst_fail "a failed listing must be named, not left to an empty-list message"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
