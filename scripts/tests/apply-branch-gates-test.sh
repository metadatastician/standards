#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# apply-branch-gates-test.sh — regression test for apply-branch-gates.sh.
#
# WHAT THIS PINS, AND WHY A PASSING SUITE WOULD NOT BE ENOUGH
#   The defect this script exists to prevent is a VACUOUS GATE: a
#   required_status_checks rule carrying an EMPTY context list. Such a rule
#   reports "this branch is protected" in every summary view while requiring
#   nothing at all — strictly worse than having no rule, because it is
#   indistinguishable from a working one.
#
#   A green suite proves nothing about that. So nine of the cases below are
#   MUTANTS: the applier is copied, the guard under test is deliberately
#   removed, and the suite must go RED. A mutant that survives means the
#   corresponding control is decorative.
#
# Run: bash scripts/tests/apply-branch-gates-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLIER="${BRANCH_GATES_TARGET:-$SCRIPT_DIR/../apply-branch-gates.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

# ------------------------------------------------------------------ fixtures
FIX="$WORK/fix"; mkdir -p "$FIX"
BIN="$WORK/bin"; mkdir -p "$BIN"

# A `gh` shim: maps an API path to a fixture file, honours --jq, records PUTs.
cat > "$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = api ] || exit 0
shift
METHOD=GET; JQF=''; APIPATH=''; INPUT=''
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift; METHOD="$1" ;;
    --jq) shift; JQF="$1" ;;
    --input) shift; INPUT="$1" ;;
    --paginate|--silent) : ;;
    -*) : ;;
    *) [ -n "$APIPATH" ] || APIPATH="$1" ;;
  esac
  shift
done
[ -n "$INPUT" ] && cp "$INPUT" "$GH_FIX/LAST_${METHOD}.json"
KEY=$(printf '%s' "$APIPATH" | tr '/?&=' '____')
if [ "$METHOD" = PUT ]; then printf '%s\n' "$APIPATH" >> "$GH_FIX/PUTS.log"; echo '{}'; exit 0; fi
if [ "$METHOD" = POST ]; then
  printf '%s\n' "$APIPATH" >> "$GH_FIX/POSTS.log"
  NEWID="${GH_POST_ID:-77}"
  # Model the server, do not stub it.  A created ruleset reads back at its OWN
  # path, so the POSTED body is written there as the fixture -- that is what
  # makes the applier's post-create re-GET a real round trip instead of a
  # tautology, and it is the seam GH_POST_DRIFT bends to exercise DRIFT.
  if [ -n "$INPUT" ]; then
    jq --argjson id "$NEWID" '.id=$id' "$INPUT" | jq "${GH_POST_DRIFT:-.}" \
      > "$GH_FIX/$(printf '%s' "$APIPATH/$NEWID" | tr '/?&=' '____').json"
  fi
  printf '{"id":%s}\n' "$NEWID"
  exit 0
fi
F="$GH_FIX/$KEY.json"
# A workflow definition with no fixture of its own is served from DEFAULT_WF,
# which reset_fix writes (a bare pull_request trigger). A case that models a
# FAILED contents read removes it: a missing fixture is an API failure.
case "$APIPATH" in
  repos/*/contents/.github/workflows/?*) [ -r "$F" ] || F="$GH_FIX/DEFAULT_WF.json" ;;
esac
[ -r "$F" ] || exit 1
if [ -n "$JQF" ]; then jq -r "$JQF" "$F"; else cat "$F"; fi
SHIM
chmod +x "$BIN/gh"

GATES="$WORK/gates-src.json"
cat > "$GATES" <<'G'
{ "version": 1,
  "profiles": {
    "base": { "applies_to": "every repo", "gate_workflows": ["governance.yml","codeql.yml","mirror.yml"] },
    "rust": { "detect": ["Cargo.toml"], "gate_workflows": ["rust-ci.yml"] },
    "ada":  { "detect": ["*.gpr"],      "gate_workflows": ["ada-ci.yml"] }
  },
  "never_required_workflows": ["mirror.yml"],
  "never_required_contexts": ["Allowlist Preflight","Code quality + docs"] }
G

mkfix() { printf '%s' "$2" > "$FIX/$(printf '%s' "$1" | tr '/?&=' '____').json"; }

DEFAULT_WF_JSON="{\"content\":\"$(printf 'on: [push, pull_request]\n' | base64 | tr -d '\n')\",\"encoding\":\"base64\"}"
reset_fix() { rm -f "$FIX"/*.json; cp "$GATES" "$WORK/gates.json"; : > "$FIX/PUTS.log"; : > "$FIX/POSTS.log"; printf '%s' "$DEFAULT_WF_JSON" > "$FIX/DEFAULT_WF.json"; }

run_applier() {           # run_applier <repo> [extra flags...]
  local repo="$1"; shift
  PATH="$BIN:$PATH" GH_FIX="$FIX" bash "${MUTANT:-$APPLIER}" \
    --gates-file "$WORK/gates.json" --repo "$repo" "$@" 2>"$WORK/err"
}

state_of() { tail -n +2 <<< "$1" | head -1 | cut -f2; }
detail_of() { tail -n +2 <<< "$1" | head -1 | cut -f3; }

# ================================================================ CASE 1
# POSITIVE CONTROL: contexts are derived from real jobs, never-required ones
# are stripped, and a never_required_workflow is not consulted at all.
reset_fix
R=acme/widget
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"},{"name":"codeql.yml"},{"name":"mirror.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"},{"name":"Cargo.toml"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/workflows/codeql.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":22}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"},{"name":"governance / Code quality + docs"},{"name":"Allowlist Preflight"}]}'
mkfix "repos/$R/actions/runs/22/jobs?per_page=100" '{"jobs":[{"name":"CodeQL Security Analysis"}]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"},{"id":8,"target":"tag","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Base","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}],"rules":[{"type":"deletion"},{"type":"required_signatures"}]}'

OUT=$(run_applier "$R")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "WOULD-GATE" ] && ok "control: state is WOULD-GATE" || bad "control: state=$S (want WOULD-GATE)"
case "$D" in *"governance / Governance"*) ok "control: derived the real job name" ;; *) bad "control: missing derived context — $D" ;; esac
case "$D" in *"CodeQL Security Analysis"*) ok "control: derived across two workflows" ;; *) bad "control: second workflow not derived" ;; esac
case "$D" in *"contexts=2"*) ok "control: exactly 2 contexts survive" ;; *) bad "control: wrong count — $D" ;; esac
case "$D" in *"excluded=["*"Code quality + docs"*) ok "control: never_required matched AFTER the ' / '" ;; *) bad "control: reusable-job-name exclusion missed — $D" ;; esac
# assert against the CONTEXT LIST only (after ":: "), not the excluded= report
CTXLIST="${D##*:: }"
case "$CTXLIST" in
  *"Allowlist Preflight"*|*"Code quality + docs"*) bad "control: a never_required context reached the rule — [$CTXLIST]" ;;
  *) ok "control: never_required contexts kept out of the rule — [$CTXLIST]" ;;
esac
[ -s "$FIX/PUTS.log" ] && bad "control: wrote WITHOUT --apply" || ok "control: report-only performed no PUT"

# ================================================================ CASE 2
# THE REFUSAL: zero derivable contexts must yield UNGATED and write nothing.
reset_fix
R=acme/norun
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'

OUT=$(run_applier "$R" --apply)
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "UNGATED" ] && ok "zero contexts: state is UNGATED" || bad "zero contexts: state=$S (want UNGATED)"
case "$D" in *"no_run=[governance.yml]"*) ok "zero contexts: the un-run workflow is named" ;; *) bad "zero contexts: no_run not reported — $D" ;; esac
[ -s "$FIX/PUTS.log" ] && bad "zero contexts: PUT happened despite --apply refusal" || ok "zero contexts: no PUT even with --apply"

# ---- MUTANT A: delete the zero-context refusal. The suite MUST go red. ----
MUT="$WORK/mutant-a.sh"
sed 's|if \[ "\$NCTX" -eq 0 \]; then|if false; then|' "$APPLIER" > "$MUT"
reset_fix
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
OUT=$(MUTANT="$MUT" run_applier "$R" --apply)
if [ "$(state_of "$OUT")" = "UNGATED" ]; then
  bad "MUTANT A SURVIVED: refusal removed yet still UNGATED — the control is decorative"
else
  ok "mutant A killed: without the refusal it becomes $(state_of "$OUT") and PUTs $(wc -l < "$FIX/PUTS.log") time(s)"
fi
if command grep -q 'required_status_checks' "$FIX/LAST_PUT.json" 2>/dev/null &&
   [ "$(jq '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks|length]|add // 0' "$FIX/LAST_PUT.json")" = "0" ]; then
  ok "mutant A wrote the VACUOUS empty-list rule — precisely the defect being guarded"
fi

# ================================================================ CASE 3
# EXACTNESS GUARD: a transform touching anything else must be REFUSED.
reset_fix
R=acme/widget
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}],"rules":[{"type":"deletion"},{"type":"required_signatures"}]}'

# MUTANT B: the body-builder also drops required_signatures.
MUTB="$WORK/mutant-b.sh"
python3 - "$APPLIER" "$MUTB" <<'MUTPY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = '| .rules = ((.rules // []) | map(select(.type!="required_status_checks")))'
new = '| .rules = ((.rules // []) | map(select(.type!="required_status_checks" and .type!="required_signatures")))'
open(dst, "w").write(s.replace(old, new, 1) if old in s else s)
MUTPY
if ! diff -q "$APPLIER" "$MUTB" >/dev/null; then
  OUT=$(MUTANT="$MUTB" run_applier "$R" --apply)
  if [ "$(state_of "$OUT")" = "REFUSED" ]; then
    ok "mutant B killed: dropping required_signatures is REFUSED by the exactness guard"
  else
    bad "MUTANT B SURVIVED: required_signatures silently dropped, state=$(state_of "$OUT")"
  fi
else
  bad "mutant B was not applied — the sed pattern no longer matches the applier"
fi

# ================================================================ CASE 4
# Rulesets are ADDITIVE: two active branch rulesets must fail closed.
reset_fix
R=acme/two
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"},{"id":10,"target":"branch","enforcement":"active","source_type":"Repository"}]'
OUT=$(run_applier "$R" --apply)
[ "$(state_of "$OUT")" = "AMBIGUOUS" ] && ok "two active branch rulesets: AMBIGUOUS, fail closed" || bad "two rulesets: state=$(state_of "$OUT") (want AMBIGUOUS)"
[ -s "$FIX/PUTS.log" ] && bad "two rulesets: wrote anyway" || ok "two rulesets: no PUT"

# ================================================================ CASE 5
# No active branch ruleset: report, never create one.
reset_fix
R=acme/none
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
mkfix "repos/$R/rulesets" '[{"id":8,"target":"tag","enforcement":"active","source_type":"Repository"},{"id":7,"target":"branch","enforcement":"disabled","source_type":"Repository"}]'
OUT=$(run_applier "$R" --apply)
[ "$(state_of "$OUT")" = "NORULESET" ] && ok "no active branch ruleset: NORULESET, nothing created" || bad "no ruleset: state=$(state_of "$OUT")"

# ================================================================ CASE 6
# Profile detection: a root-level glob (*.gpr) activates the ada profile.
reset_fix
R=acme/ada
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"},{"name":"ada-ci.yml"}]'
mkfix "repos/$R/contents" '[{"name":"thing.gpr"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/workflows/ada-ci.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":33}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
mkfix "repos/$R/actions/runs/33/jobs?per_page=100" '{"jobs":[{"name":"Ada Build"}]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
OUT=$(run_applier "$R")
case "$(detail_of "$OUT")" in *"Ada Build"*) ok "profile detect: *.gpr glob activated the ada profile" ;; *) bad "profile detect: ada gate missing — $(detail_of "$OUT")" ;; esac

# ================================================================ CASE 7
# Refuse an empty target list rather than report a clean sweep over nothing.
if PATH="$BIN:$PATH" GH_FIX="$FIX" bash "$APPLIER" --gates-file "$WORK/gates.json" --skip-user >/dev/null 2>&1; then
  bad "empty target list: exited 0 instead of refusing"
else
  ok "empty target list: refused"
fi


# ================================================================ CASE 8
# THE FAIL-OPEN REFUSAL: a derivation fetch that FAILS must never be read as
# "this workflow contributes no contexts". Measured 2026-09-22 on
# hyperpolymath/standards: a swallowed error dropped 2 of 18 required
# contexts and the run still reported GATED. A short gate is a weak gate,
# and nothing in the output said so.
#
# Fixture shape: governance.yml resolves and yields jobs; codeql.yml resolves
# to run 22 but its JOBS fixture is ABSENT, so the shim exits non-zero --
# exactly a transient API failure.
reset_fix
R=acme/flaky
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"},{"name":"codeql.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/workflows/codeql.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":22}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
# NOTE: no fixture for run 22's jobs -- the shim will exit 1.
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'

OUT=$(run_applier "$R" --apply)
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "REFUSED" ] && ok "flaky derive: state is REFUSED" || bad "flaky derive: state=$S (want REFUSED)"
case "$D" in *"derive_failed=["*"codeql.yml"*) ok "flaky derive: the failed workflow is NAMED, not silently absent" ;; *) bad "flaky derive: failure not reported — $D" ;; esac
[ -s "$FIX/PUTS.log" ] && bad "flaky derive: PUT a gate built from an incomplete read" || ok "flaky derive: no PUT even with --apply"

# ---- MUTANT C: delete the incomplete-read refusal. The suite MUST go red. ----
# This is the mutant that matters: without it the applier does not error, it
# writes a SHORTER gate and calls it success.
MUTC="$WORK/mutant-c.sh"
sed 's|if \[ -n "\$DERIVEFAIL" \]; then|if false; then|' "$APPLIER" > "$MUTC"
reset_fix
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"},{"name":"codeql.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/workflows/codeql.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":22}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
OUT=$(MUTANT="$MUTC" run_applier "$R" --apply)
if [ "$(state_of "$OUT")" = "REFUSED" ]; then
  bad "MUTANT C SURVIVED: refusal removed yet still REFUSED — the control is decorative"
else
  ok "mutant C killed: without the refusal it becomes $(state_of "$OUT") and PUTs $(wc -l < "$FIX/PUTS.log") time(s)"
fi
if [ -r "$FIX/LAST_PUT.json" ] &&
   [ "$(jq '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks|length]|add // 0' "$FIX/LAST_PUT.json")" = "1" ]; then
  ok "mutant C wrote the SHORTENED gate (1 context, not 2) — the silent weakening being guarded"
else
  bad "mutant C: expected a 1-context gate from the incomplete read"
fi

# ================================================================ CASE 9
# THE SAME FAIL-OPEN, POINTING THE OTHER WAY: --require-green asked the API
# only for the NON-green jobs, so "this run is entirely green" and "this run
# was not read" were the SAME observation -- zero lines -- and zero lines was
# read as greenness. There it does not shorten the gate; it ADMITS a context
# that was never shown to be green, which is how a red check ends up required
# and every PR blocks on it.
#
# Fixture shape: derive (per_page=1) resolves run 11, which has jobs. The
# greenness probe (per_page=3) additionally resolves run 12, whose jobs
# fixture EXISTS and is EMPTY -- a successful read of nothing, which the
# missing-fixture trick cannot simulate.
reset_fix
R=acme/zerojobs
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=3" '{"workflow_runs":[{"id":11},{"id":12}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance","conclusion":"success"}]}'
mkfix "repos/$R/actions/runs/12/jobs?per_page=100" '{"jobs":[]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'

OUT=$(run_applier "$R" --apply --require-green 3)
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "REFUSED" ] && ok "zero-job green probe: state is REFUSED" || bad "zero-job green probe: state=$S (want REFUSED)"
case "$D" in *"returned zero jobs"*) ok "zero-job green probe: the unread run is NAMED, not counted as green" ;; *) bad "zero-job green probe: not reported — $D" ;; esac
[ -s "$FIX/PUTS.log" ] && bad "zero-job green probe: PUT a gate whose greenness was never read" || ok "zero-job green probe: no PUT even with --apply"

# ---- MUTANT D: delete the zero-jobs guard from the GREENNESS probe only. ----
# Keyed on jobs2 so it cannot touch the derivation loop's jobs1 guard.
MUTD="$WORK/mutant-d.sh"
sed 's|if \[ ! -s "\$WORK/jobs2" \]; then|if false; then|' "$APPLIER" > "$MUTD"
if ! cmp -s "$MUTD" "$APPLIER"; then
  reset_fix
  mkfix "repos/$R" '{"default_branch":"main"}'
  mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
  mkfix "repos/$R/contents" '[{"name":"README.md"}]'
  mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
  mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=3" '{"workflow_runs":[{"id":11},{"id":12}]}'
  mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance","conclusion":"success"}]}'
  mkfix "repos/$R/actions/runs/12/jobs?per_page=100" '{"jobs":[]}'
  mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
  mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
  OUT=$(MUTANT="$MUTD" run_applier "$R" --apply --require-green 3)
  if [ "$(state_of "$OUT")" = "REFUSED" ]; then
    bad "MUTANT D SURVIVED: zero-jobs guard removed yet still REFUSED — the control is decorative"
  else
    ok "mutant D killed: without the guard it becomes $(state_of "$OUT") and PUTs $(wc -l < "$FIX/PUTS.log") time(s)"
  fi
  if [ -r "$FIX/LAST_PUT.json" ] &&
     [ "$(jq -r '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|join(",")' "$FIX/LAST_PUT.json")" = "governance / Governance" ]; then
    ok "mutant D REQUIRED a context whose greenness was never read — the silent admission being guarded"
  else
    bad "mutant D: expected the unverified context to be required anyway"
  fi
else
  bad "mutant D was not applied — the sed pattern no longer matches the applier"
fi

# =============================================================== CASE 10
# THE THIRD INSTANCE OF THE SAME CLASS, three lines above CASE 9's.  The
# greenness probe's RUNS query has the identical shape: a query that succeeds
# with {"workflow_runs":[]} leaves rids empty, so the per-run loop never
# executes, nothing is ever appended to "bad", and every context the workflow
# contributed is admitted as green.  Zero runs and zero BAD runs were the same
# observation.  Since the probe now iterates gatewf3 -- the workflows that DID
# contribute contexts, and therefore DID have a run -- an empty runs list here
# can only be a failed read.
reset_fix
R=acme/zeroruns
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=3" '{"workflow_runs":[]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance","conclusion":"success"}]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'

OUT=$(run_applier "$R" --apply --require-green 3)
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "REFUSED" ] && ok "zero-run green probe: state is REFUSED" \
  || bad "zero-run green probe: expected REFUSED, got '$S' ($D)"
case "$D" in
  *"green-runs-query-returned-none"*) ok "zero-run green probe: the unread workflow is NAMED, not counted as green" ;;
  *) bad "zero-run green probe: detail does not name the unread workflow: $D" ;;
esac
[ -s "$FIX/PUTS.log" ] && bad "zero-run green probe: PUT a gate whose greenness was never read" \
  || ok "zero-run green probe: no PUT even with --apply"

# =============================================================== CASE 11
# THE REGRESSION THE NAIVE FIX WOULD CAUSE, and the reason the probe iterates
# gatewf3 rather than gatewf2.  gatewf2 still holds every NORUN workflow, for
# which an empty runs list is the LEGITIMATE state, not a failed read.  A bare
# `[ -s rids ]` check over gatewf2 would turn every repo owning one run-less
# gate workflow into REFUSED under --require-green.  Note that NO per_page=3
# fixture exists for the NORUN workflow: the shim exits 1 on a missing fixture,
# so if the probe ever asks about it this case goes REFUSED and fails.
reset_fix
R=acme/norun-beside-good
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"},{"name":"codeql.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=3" '{"workflow_runs":[{"id":11},{"id":12}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance","conclusion":"success"}]}'
mkfix "repos/$R/actions/runs/12/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance","conclusion":"success"}]}'
mkfix "repos/$R/actions/workflows/codeql.yml/runs?branch=main&per_page=1" '{"workflow_runs":[]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'

OUT=$(run_applier "$R" --require-green 3)
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" != "REFUSED" ] && ok "NORUN beside a good workflow: not REFUSED (state=$S) — the run-less workflow is not a failed read" \
  || bad "NORUN beside a good workflow: REFUSED ($D) — the rids guard is scoped to gatewf2, not gatewf3"
case "$D" in
  *codeql.yml*) ok "NORUN beside a good workflow: the run-less workflow is reported by name" ;;
  *) bad "NORUN beside a good workflow: detail does not name codeql.yml: $D" ;;
esac

# ---- MUTANT E: delete the empty-runs guard from the greenness probe only. ----
# Keyed on rids so it cannot touch either jobs guard.
MUTE="$WORK/mutant-e.sh"
sed 's|if \[ ! -s "\$WORK/rids" \]; then|if false; then|' "$APPLIER" > "$MUTE"
chmod +x "$MUTE"
if ! cmp -s "$MUTE" "$APPLIER"; then
  reset_fix
  R=acme/zeroruns
  mkfix "repos/$R" '{"default_branch":"main"}'
  mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
  mkfix "repos/$R/contents" '[{"name":"README.md"}]'
  mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
  mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=3" '{"workflow_runs":[]}'
  mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance","conclusion":"success"}]}'
  mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
  mkfix "repos/$R/rulesets/9" '{"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
  OUT=$(MUTANT="$MUTE" run_applier "$R" --apply --require-green 3)
  if [ "$(state_of "$OUT")" = "REFUSED" ]; then
    bad "MUTANT E SURVIVED: empty-runs guard removed yet still REFUSED — the control is decorative"
  else
    ok "mutant E killed: without the guard it becomes $(state_of "$OUT") and PUTs $(wc -l < "$FIX/PUTS.log") time(s)"
  fi
  if [ -r "$FIX/LAST_PUT.json" ] &&
     [ "$(jq -r '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|join(",")' "$FIX/LAST_PUT.json")" = "governance / Governance" ]; then
    ok "mutant E REQUIRED a context across ZERO examined runs — the silent admission being guarded"
  else
    bad "mutant E: expected the unverified context to be required anyway"
  fi
else
  bad "mutant E was not applied — the sed pattern no longer matches the applier"
fi

# =============================================================== CASE 12
# THE ORG-INHERITED TRAP.  repos/{r}/rulesets RETURNS the org's rulesets
# alongside the repo's own.  An inherited one reads back IN FULL at
# repos/{r}/rulesets/{id} -- so every GET succeeds and nothing warns you --
# while the PUT to that same path 404s.  Measured 67 times on this estate, once
# per metadatastician repo reached by the org-level EstateBranching (18225024).
# The cure is at /orgs/{org}/rulesets/{id}, applied ONCE; issuing 67 doomed
# per-repo writes is not a smaller version of it.
# NOTE there is deliberately NO fixture for repos/$R/rulesets/18225024: the shim
# exits 1 on a missing fixture, so if the applier ever READS the inherited
# ruleset this case fails.  That absence is a free assertion.
reset_fix
R=acme/org-inherited
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
mkfix "repos/$R/rulesets" '[{"id":18225024,"name":"EstateBranching","target":"branch","enforcement":"active","source_type":"Organization","source":"metadatastician"}]'

OUT=$(run_applier "$R" --apply)
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "ORG-INHERITED" ] && ok "org-inherited: state is ORG-INHERITED" || bad "org-inherited: state=$S (want ORG-INHERITED) — an inherited ruleset was treated as writable"
case "$D" in *18225024*) ok "org-inherited: the inherited ruleset id is NAMED so the org-level cure is actionable" ;; *) bad "org-inherited: id not reported — $D" ;; esac
case "$D" in *"/orgs/"*) ok "org-inherited: the detail says WHERE the cure lives" ;; *) bad "org-inherited: detail does not point at the org endpoint — $D" ;; esac
[ -s "$FIX/PUTS.log" ] && bad "org-inherited: PUT issued despite --apply — this is the 404 being guarded" || ok "org-inherited: no PUT even with --apply"

# =============================================================== CASE 13
# THE REGRESSION THE NAIVE FIX WOULD CAUSE.  Rulesets are ADDITIVE, so a repo
# legitimately carries an inherited ruleset BESIDE its own.  Counting both as
# candidates turns that ordinary repo into AMBIGUOUS and it never gets gated.
# The repo-level one must be selected, and the inherited one REPORTED (it still
# enforces) rather than silently ignored.
# Again: no fixture for rulesets/18225024 -- reading it fails the case.
reset_fix
R=acme/org-plus-own
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
mkfix "repos/$R/rulesets" '[{"id":18225024,"name":"EstateBranching","target":"branch","enforcement":"active","source_type":"Organization"},{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Base","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"deletion"}]}'

OUT=$(run_applier "$R")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "WOULD-GATE" ] && ok "org beside own: state is WOULD-GATE — the repo-level ruleset was selected" || bad "org beside own: state=$S (want WOULD-GATE) — an additive inherited ruleset made an ordinary repo unreachable"
case "$D" in *"ruleset=9"*) ok "org beside own: the REPO-LEVEL id was chosen, not the org id" ;; *) bad "org beside own: wrong ruleset selected — $D" ;; esac
case "$D" in *"org_inherited=[18225024]"*) ok "org beside own: the inherited ruleset is still REPORTED — it enforces regardless" ;; *) bad "org beside own: inherited ruleset went unreported — $D" ;; esac

# =============================================================== CASE 14
# AN ABSENT DISCRIMINATOR REFUSES.  Writability is exactly what .source_type
# decides; defaulting a missing field to the writable arm is a silent 404.
reset_fix
R=acme/no-source-type
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active"}]'
mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'

OUT=$(run_applier "$R" --apply)
S=$(state_of "$OUT")
[ "$S" = "UNKNOWN" ] && ok "absent source_type: state is UNKNOWN — refuses rather than assuming repo-level" || bad "absent source_type: state=$S (want UNKNOWN)"
[ -s "$FIX/PUTS.log" ] && bad "absent source_type: PUT issued on an unclassifiable ruleset" || ok "absent source_type: no PUT even with --apply"

# ---- MUTANT F: delete the source_type filter, restoring the original defect. --
# The pre-fix line selected every active branch ruleset regardless of ownership.
MUTF="$WORK/mutant-f.sh"
sed 's|^  awk -F.\\t. ..1=="Repository".*> "\$WORK/ids"$|  cut -f2 "$WORK/active" > "$WORK/ids"|' "$APPLIER" > "$MUTF"
chmod +x "$MUTF"
if ! cmp -s "$MUTF" "$APPLIER" && bash -n "$MUTF" 2>/dev/null; then
  reset_fix
  R=acme/org-inherited
  mkfix "repos/$R" '{"default_branch":"main"}'
  mkfix "repos/$R/contents/.github/workflows" '[{"name":"governance.yml"}]'
  mkfix "repos/$R/contents" '[{"name":"README.md"}]'
  mkfix "repos/$R/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
  mkfix "repos/$R/actions/runs/11/jobs?per_page=100" '{"jobs":[{"name":"governance / Governance"}]}'
  mkfix "repos/$R/rulesets" '[{"id":18225024,"name":"EstateBranching","target":"branch","enforcement":"active","source_type":"Organization"}]'
  # the mutant WILL read the inherited ruleset, so it needs a fixture the fixed
  # applier must never ask for.
  mkfix "repos/$R/rulesets/18225024" '{"id":18225024,"name":"EstateBranching","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
  OUT=$(MUTANT="$MUTF" run_applier "$R" --apply)
  if [ "$(state_of "$OUT")" = "ORG-INHERITED" ]; then
    bad "MUTANT F SURVIVED: source_type filter removed yet still ORG-INHERITED — the control is decorative"
  else
    ok "mutant F killed: without the filter it becomes $(state_of "$OUT") and PUTs $(wc -l < "$FIX/PUTS.log") time(s)"
  fi
  if command grep -qxF "repos/$R/rulesets/18225024" "$FIX/PUTS.log" 2>/dev/null; then
    ok "mutant F PUT to the INHERITED ruleset's repo path — the 404 measured 67 times, reproduced"
  else
    bad "mutant F: expected a PUT to repos/$R/rulesets/18225024"
  fi
else
  bad "mutant F was not applied — the sed pattern no longer matches the applier"
fi

# =========================================================================
#  THE CREATE PATH (--create-gates / --no-integration-bypass)
#  Everything above this line exercises the UPDATE path against a ruleset
#  that already exists.  None of it touches the code that BRINGS ONE INTO
#  BEING, which is the riskier half: an update can only widen or narrow an
#  object the owner already chose to have, while a create writes a NEW
#  permanent gate onto a repository from a body this script supplies.
# =========================================================================

# The five fixture lines CASE 12/13/14 spell out in full, hoisted -- the create
# cases need them ten times over and the repetition would bury the assertions.
# Identical calls, identical helper (mkfix); nothing new is being modelled.
fix_repo() {                      # fix_repo <repo> [job-name]
  local r="$1" j="${2:-governance / Governance}"
  mkfix "repos/$r" '{"default_branch":"main"}'
  mkfix "repos/$r/contents/.github/workflows" '[{"name":"governance.yml"}]'
  mkfix "repos/$r/contents" '[{"name":"README.md"}]'
  mkfix "repos/$r/actions/workflows/governance.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":11}]}'
  mkfix "repos/$r/actions/runs/11/jobs?per_page=100" "$(jq -cn --arg n "$j" '{jobs:[{name:$n}]}')"
}

# The canon checks-only body, in the shape config/rulesets/gates-only.json
# commits: ONE rule, an EMPTY context list (this script is what fills it), and
# a short bypass list whose existence is the entire point of a separate object.
GO="$WORK/gates-only.json"
cat > "$GO" <<'GOC'
{ "name": "Gates", "target": "branch", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5,       "actor_type": "RepositoryRole", "bypass_mode": "pull_request" },
    { "actor_id": 1236702, "actor_type": "Integration",    "bypass_mode": "pull_request" },
    { "actor_id": 29110,   "actor_type": "Integration",    "bypass_mode": "pull_request" } ],
  "rules": [ { "type": "required_status_checks",
    "parameters": { "strict_required_status_checks_policy": false,
                    "do_not_enforce_on_create": false,
                    "required_status_checks": [] } } ] }
GOC

# A body carrying a HAND-TYPED context.  gates.json's whole doctrine is that a
# context is derived from an emitted check-run name and never typed, so this
# body must be refused even though it is otherwise well-formed.
GO_TYPED="$WORK/gates-only-typed.json"
jq '.rules[0].parameters.required_status_checks = [{"context":"CI / typed-by-hand","integration_id":15368}]' \
  "$GO" > "$GO_TYPED"

# A body whose bypass list is Integrations ONLY.  Stripping them empties it.
GO_INTONLY="$WORK/gates-only-intonly.json"
jq '.bypass_actors = [(.bypass_actors[] | select(.actor_type == "Integration"))]' "$GO" > "$GO_INTONLY"

# =============================================================== CASE 15
# ORG-INHERITED must NAME THE CURE.  CASE 12 proves the state and the org
# endpoint; what is asserted here is that the report tells the operator the one
# flag that changes the outcome, and names the body it would create from.  A
# refusal that does not say how to proceed is a dead end, not a guard.
reset_fix
R=acme/inherited-needs-cure
fix_repo "$R"
mkfix "repos/$R/rulesets" '[{"id":18225024,"name":"EstateBranching","target":"branch","enforcement":"active","source_type":"Organization"}]'

OUT=$(run_applier "$R" --gates-only-file "$GO")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "ORG-INHERITED" ] && ok "create/inherited: still ORG-INHERITED without the flag" || bad "create/inherited: state=$S (want ORG-INHERITED)"
case "$D" in *--create-gates*) ok "create/inherited: the detail names --create-gates as the cure" ;; *) bad "create/inherited: no cure pointer — $D" ;; esac
case "$D" in *"$GO"*) ok "create/inherited: the detail names the BODY it would create from" ;; *) bad "create/inherited: body path not named — $D" ;; esac
[ -s "$FIX/POSTS.log" ] && bad "create/inherited: POST issued without --create-gates" || ok "create/inherited: no POST without the flag"

# =============================================================== CASE 16
# NORULESET carries the same cure.  This is the arm paint-type is NOT in and
# the one every unprotected repo in the estate is, so a missing pointer here
# costs the most.
reset_fix
R=acme/bare-repo
fix_repo "$R"
mkfix "repos/$R/rulesets" '[]'

OUT=$(run_applier "$R" --gates-only-file "$GO")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "NORULESET" ] && ok "create/bare: state is NORULESET" || bad "create/bare: state=$S (want NORULESET)"
case "$D" in *--create-gates*) ok "create/bare: the detail names --create-gates as the cure" ;; *) bad "create/bare: no cure pointer — $D" ;; esac
[ -s "$FIX/POSTS.log" ] && bad "create/bare: POST issued without --create-gates" || ok "create/bare: no POST without the flag"

# =============================================================== CASE 17
# --create-gates WITHOUT --apply is a dry run, and a dry run that writes is the
# worst defect this suite can miss: it is invisible in the output and permanent
# on the server.  Assert the POST log is empty, not merely that the state reads
# WOULD-CREATE -- a state string is not evidence about network calls.
reset_fix
R=acme/would-create
fix_repo "$R"
mkfix "repos/$R/rulesets" '[]'

OUT=$(run_applier "$R" --create-gates --gates-only-file "$GO")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "WOULD-CREATE" ] && ok "would-create: state is WOULD-CREATE" || bad "would-create: state=$S (want WOULD-CREATE)"
case "$D" in *"ruleset=<new from $GO>"*) ok "would-create: the detail says it would create, and from which body" ;; *) bad "would-create: detail does not name the body — $D" ;; esac
case "$D" in *"governance / Governance"*) ok "would-create: the DERIVED context is shown before anything is written" ;; *) bad "would-create: context not reported — $D" ;; esac
[ -s "$FIX/POSTS.log" ] && bad "would-create: POST issued WITHOUT --apply — a dry run wrote to the server" || ok "would-create: no POST without --apply"

# =============================================================== CASE 18
# --apply --create-gates actually creates.  The assertions are on the POSTED
# BODY, not on the state string: the state is what the script says it did, the
# body is what the server was actually told.
reset_fix
R=acme/creates
fix_repo "$R"
mkfix "repos/$R/rulesets" '[]'

OUT=$(run_applier "$R" --apply --create-gates --gates-only-file "$GO")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "CREATED" ] && ok "create: state is CREATED" || bad "create: state=$S (want CREATED) — $D"
case "$D" in *"ruleset=77"*) ok "create: the NEW id from the POST response is reported" ;; *) bad "create: new id not reported — $D" ;; esac
command grep -qxF "repos/$R/rulesets" "$FIX/POSTS.log" 2>/dev/null \
  && ok "create: POST went to the collection endpoint, not to an id" \
  || bad "create: expected a POST to repos/$R/rulesets, got $(cat "$FIX/POSTS.log" 2>/dev/null)"
[ -s "$FIX/PUTS.log" ] && bad "create: a PUT was issued on the create path" || ok "create: no PUT on the create path"
[ "$(jq -r '.name' "$FIX/LAST_POST.json")" = "Gates" ] \
  && ok "create: the posted body keeps the canon name" \
  || bad "create: posted name is $(jq -r '.name' "$FIX/LAST_POST.json") (want Gates)"
[ "$(jq -cS '[.rules[].type]' "$FIX/LAST_POST.json")" = '["required_status_checks"]' ] \
  && ok "create: required_status_checks is the SOLE rule — the bypass list stays short on purpose" \
  || bad "create: posted rules are $(jq -cS '[.rules[].type]' "$FIX/LAST_POST.json")"
[ "$(jq -r '[.rules[0].parameters.required_status_checks[].context]|join(",")' "$FIX/LAST_POST.json")" = "governance / Governance" ] \
  && ok "create: the posted contexts are the DERIVED ones" \
  || bad "create: posted contexts are $(jq -c '[.rules[0].parameters.required_status_checks[].context]' "$FIX/LAST_POST.json")"
[ "$(jq '[.bypass_actors[]]|length' "$FIX/LAST_POST.json")" = 3 ] \
  && ok "create: without --no-integration-bypass the canon bypass list is posted VERBATIM" \
  || bad "create: bypass list was altered without the flag — $(jq -c '.bypass_actors' "$FIX/LAST_POST.json")"

# =============================================================== CASE 19
# --no-integration-bypass is owner ruling Q2, and it is a DIVERGENCE FROM
# COMMITTED CANON, so it must be visible in the output as well as in the body.
# RepositoryRole:5 is retained deliberately: it is what keeps the repository
# recoverable, and dropping it is the 2026-09-11 outage shape.
reset_fix
R=acme/no-int-bypass
fix_repo "$R"
mkfix "repos/$R/rulesets" '[]'

OUT=$(run_applier "$R" --apply --create-gates --no-integration-bypass --gates-only-file "$GO")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "CREATED" ] && ok "no-int-bypass: state is CREATED" || bad "no-int-bypass: state=$S (want CREATED) — $D"
case "$D" in *"bypass=no_integrations"*) ok "no-int-bypass: the divergence from canon is DECLARED in the report" ;; *) bad "no-int-bypass: divergence is silent — $D" ;; esac
[ "$(jq '[.bypass_actors[]|select(.actor_type=="Integration")]|length' "$FIX/LAST_POST.json")" = 0 ] \
  && ok "no-int-bypass: zero Integration actors in the posted body" \
  || bad "no-int-bypass: Integrations survived — $(jq -c '.bypass_actors' "$FIX/LAST_POST.json")"
[ "$(jq '[.bypass_actors[]|select(.actor_type=="RepositoryRole" and .actor_id==5)]|length' "$FIX/LAST_POST.json")" = 1 ] \
  && ok "no-int-bypass: RepositoryRole:5 is RETAINED — the repo stays recoverable" \
  || bad "no-int-bypass: RepositoryRole:5 was stripped too — that is the outage shape, not a strict gate"

# =============================================================== CASE 20
# --no-integration-bypass WITHOUT --create-gates must die at argument parsing.
# The update path may not touch bypass_actors at all: silently accepting the
# flag there would read as "the Integrations were stripped" while leaving the
# live ruleset exactly as it was.
reset_fix
R=acme/flag-misuse
fix_repo "$R"
mkfix "repos/$R/rulesets" '[]'

OUT=$(run_applier "$R" --apply --no-integration-bypass --gates-only-file "$GO"); RC=$?
[ "$RC" -ne 0 ] && ok "flag misuse: --no-integration-bypass alone exits non-zero ($RC)" || bad "flag misuse: rc=0 — the flag was silently accepted on the update path"
command grep -q 'create-gates' "$WORK/err" && ok "flag misuse: the error names the flag that would make it valid" || bad "flag misuse: unhelpful error — $(cat "$WORK/err")"
[ -s "$FIX/POSTS.log" ] && bad "flag misuse: a POST was issued" || ok "flag misuse: no POST"
[ -s "$FIX/PUTS.log" ] && bad "flag misuse: a PUT was issued" || ok "flag misuse: no PUT"

# =============================================================== CASE 21
# Stripping Integrations from a body whose bypass list is Integrations ONLY
# leaves ZERO bypass actors.  A branch ruleset with no bypass, under an org
# ruleset requiring code-owner review that the sole contributor cannot
# self-approve, deadlocks the repository outright.  REFUSE, never warn.
reset_fix
R=acme/would-empty-bypass
fix_repo "$R"
mkfix "repos/$R/rulesets" '[]'

OUT=$(run_applier "$R" --apply --create-gates --no-integration-bypass --gates-only-file "$GO_INTONLY")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "REFUSED" ] && ok "empty bypass: state is REFUSED — a zero-bypass ruleset is an outage, not a strict gate" || bad "empty bypass: state=$S (want REFUSED) — $D"
case "$D" in *"EMPTY bypass"*) ok "empty bypass: the reason names the empty list" ;; *) bad "empty bypass: reason unclear — $D" ;; esac
[ -s "$FIX/POSTS.log" ] && bad "empty bypass: a zero-bypass ruleset was POSTED" || ok "empty bypass: nothing was written"

# =============================================================== CASE 22
# THE CANON-SHAPE GUARD.  A committed body carrying a hand-typed context is the
# one thing gates.json forbids outright: contexts are derived from emitted
# check-run names, never typed, because a typed name that no job emits is a
# permanently unsatisfiable required check.
reset_fix
R=acme/typed-body
fix_repo "$R"
mkfix "repos/$R/rulesets" '[]'

OUT=$(run_applier "$R" --apply --create-gates --gates-only-file "$GO_TYPED")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "REFUSED" ] && ok "typed body: state is REFUSED by the canon-shape guard" || bad "typed body: state=$S (want REFUSED) — a hand-typed context was accepted as a create body"
case "$D" in *"canon checks-only body"*) ok "typed body: the reason names the shape that was violated" ;; *) bad "typed body: reason unclear — $D" ;; esac
[ -s "$FIX/POSTS.log" ] && bad "typed body: a non-canon body was POSTED" || ok "typed body: nothing was written"

# =============================================================== CASE 23
# TWO repo-level branch rulesets is the EXPECTED steady state after O6, so
# AMBIGUOUS there would make the applier permanently unable to maintain the
# very shape O6 prescribes.  SHAPE is the discriminator -- the gates ruleset is
# the one whose ONLY rule is required_status_checks.  Name classifies nothing.
reset_fix
R=acme/two-own-one-shaped
fix_repo "$R"
mkfix "repos/$R/rulesets" '[{"id":8,"target":"branch","enforcement":"active","source_type":"Repository"},{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/8" '{"id":8,"name":"Base","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"deletion"},{"type":"required_signatures"}]}'
mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Gates","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}],"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":false,"required_status_checks":[]}}]}'

OUT=$(run_applier "$R")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "WOULD-GATE" ] && ok "two own: the checks-only ruleset was selected by SHAPE" || bad "two own: state=$S (want WOULD-GATE) — the O6 steady state was treated as ambiguous"
case "$D" in *"picked_by=shape"*) ok "two own: the report says HOW it disambiguated" ;; *) bad "two own: no picked_by in detail — $D" ;; esac
case "$D" in *"ruleset=9"*) ok "two own: the checks-only id was chosen, not the baseline one" ;; *) bad "two own: wrong ruleset — $D" ;; esac

# ...and when NEITHER is uniquely checks-only, shape cannot decide and the only
# honest answer is to refuse.  Rulesets are additive; guessing writes a real gate
# onto the wrong object.
reset_fix
R=acme/two-own-none-shaped
fix_repo "$R"
mkfix "repos/$R/rulesets" '[{"id":8,"target":"branch","enforcement":"active","source_type":"Repository"},{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/8" '{"id":8,"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Other","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"non_fast_forward"}]}'

OUT=$(run_applier "$R" --apply)
S=$(state_of "$OUT")
[ "$S" = "AMBIGUOUS" ] && ok "two own, none shaped: AMBIGUOUS — refuses to guess" || bad "two own, none shaped: state=$S (want AMBIGUOUS)"
[ -s "$FIX/PUTS.log" ] && bad "two own, none shaped: a PUT was issued on a guess" || ok "two own, none shaped: no PUT even with --apply"

# =============================================================== CASE 24
# THE VACUOUS-GATE REFUSAL, ON THE CREATE PATH.  This is the defect the whole
# suite exists to prevent, and --create-gates is a NEW way to reach it: a
# required_status_checks rule carrying an empty context list, brought into
# being rather than written into an existing object.  Zero contexts must not
# create anything at all.
reset_fix
R=acme/create-zero-ctx
fix_repo "$R" "Allowlist Preflight"          # the only job is never-required
mkfix "repos/$R/rulesets" '[]'

OUT=$(run_applier "$R" --apply --create-gates --gates-only-file "$GO")
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "UNGATED" ] && ok "create/zero contexts: state is UNGATED — refuses to create a vacuous gate" || bad "create/zero contexts: state=$S (want UNGATED) — an empty rule was about to be created"
[ -s "$FIX/POSTS.log" ] && bad "create/zero contexts: a VACUOUS ruleset was POSTED" || ok "create/zero contexts: nothing was written"

# =============================================================== CASE 25
# POST-CREATE VERIFICATION.  rc=0 from a write is not evidence the write took
# effect -- measured estate-wide, a ruleset PUT returned 200 with an EMPTY BODY
# and had not applied.  The applier re-GETs and compares; these two arms bend
# the server's reply so that the comparison is a real round trip and not a
# tautology.  GH_POST_DRIFT is the seam.
reset_fix
R=acme/drift-contexts
fix_repo "$R"
mkfix "repos/$R/rulesets" '[]'
export GH_POST_DRIFT='.rules[0].parameters.required_status_checks = []'
OUT=$(run_applier "$R" --apply --create-gates --gates-only-file "$GO")
unset GH_POST_DRIFT
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "DRIFT" ] && ok "drift/contexts: a server that dropped the contexts is reported as DRIFT, not as CREATED" || bad "drift/contexts: state=$S (want DRIFT) — the post-create re-GET is a tautology"
case "$D" in *"contexts after create"*) ok "drift/contexts: the reason names WHICH field drifted" ;; *) bad "drift/contexts: reason unclear — $D" ;; esac

# The bypass list is the whole point of a checks-only ruleset, so a server-side
# default restoring the actors --no-integration-bypass just removed must not be
# reported as success.
reset_fix
R=acme/drift-bypass
fix_repo "$R"
mkfix "repos/$R/rulesets" '[]'
export GH_POST_DRIFT='.bypass_actors += [{"actor_id":1236702,"actor_type":"Integration","bypass_mode":"pull_request"}]'
OUT=$(run_applier "$R" --apply --create-gates --no-integration-bypass --gates-only-file "$GO")
unset GH_POST_DRIFT
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "DRIFT" ] && ok "drift/bypass: a server that restored an Integration is reported as DRIFT" || bad "drift/bypass: state=$S (want DRIFT) — the stripped actor came back unnoticed"
case "$D" in *"bypass_actors after create"*) ok "drift/bypass: the reason names WHICH field drifted" ;; *) bad "drift/bypass: reason unclear — $D" ;; esac

# ---- MUTANT G: delete the SHAPE discriminator from the two-ruleset arm. ------
# Without it the O6 steady state (baseline + checks-only) is unreachable: every
# such repo reports AMBIGUOUS and is never gated again.
MUTG="$WORK/mutant-g.sh"
cat > "$WORK/mut-g.sed" <<'SEDG'
s#^    if \[ "$(wc -l < "$WORK/shaped")" -eq 1 ]; then$#    if false; then#
SEDG
sed -f "$WORK/mut-g.sed" "$APPLIER" > "$MUTG"
chmod +x "$MUTG"
if ! cmp -s "$MUTG" "$APPLIER" && bash -n "$MUTG" 2>/dev/null; then
  reset_fix
  R=acme/two-own-one-shaped
  fix_repo "$R"
  mkfix "repos/$R/rulesets" '[{"id":8,"target":"branch","enforcement":"active","source_type":"Repository"},{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
  mkfix "repos/$R/rulesets/8" '{"id":8,"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
  mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Gates","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}],"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":false,"required_status_checks":[]}}]}'
  OUT=$(MUTANT="$MUTG" run_applier "$R")
  if [ "$(state_of "$OUT")" = "AMBIGUOUS" ]; then
    ok "mutant G killed: without the shape discriminator the O6 steady state becomes AMBIGUOUS"
  else
    bad "MUTANT G SURVIVED: shape discriminator removed yet still $(state_of "$OUT") — the control is decorative"
  fi
else
  bad "mutant G was not applied — the sed pattern no longer matches the applier"
fi

# ---- MUTANT H: neuter the canon-shape guard's EMPTY-CONTEXTS clause. ---------
# Flipping != to = inverts exactly that one clause: a typed-context body now
# passes the guard, and the canon body would not.  Only the typed case is run
# under the mutant, which is the point -- it must go from REFUSED to written.
MUTH="$WORK/mutant-h.sh"
cat > "$WORK/mut-h.sed" <<'SEDH'
s#|length' "$GATES_ONLY_FILE")" != '0'#|length' "$GATES_ONLY_FILE")" = '0'#
SEDH
sed -f "$WORK/mut-h.sed" "$APPLIER" > "$MUTH"
chmod +x "$MUTH"
if ! cmp -s "$MUTH" "$APPLIER" && bash -n "$MUTH" 2>/dev/null; then
  reset_fix
  R=acme/typed-body
  fix_repo "$R"
  mkfix "repos/$R/rulesets" '[]'
  OUT=$(MUTANT="$MUTH" run_applier "$R" --apply --create-gates --gates-only-file "$GO_TYPED")
  if [ "$(state_of "$OUT")" = "REFUSED" ]; then
    bad "MUTANT H SURVIVED: canon-shape guard neutered yet a typed-context body was still REFUSED — the guard is not what refuses it"
  else
    ok "mutant H killed: without the empty-contexts clause a typed-context body reaches $(state_of "$OUT") and POSTs $(wc -l < "$FIX/POSTS.log") time(s)"
  fi
  [ -s "$FIX/POSTS.log" ] && ok "mutant H wrote to the server from a non-canon body — the guard is load-bearing" \
                          || bad "mutant H: expected a POST from the neutered guard"
else
  bad "mutant H was not applied — the sed pattern no longer matches the applier"
fi

# ---- MUTANT I: neuter the empty-bypass refusal (-gt 0 becomes -ge 0). --------
# A zero-bypass branch ruleset is the shape of the 2026-09-11 tag outage.  If
# this control is decorative, --no-integration-bypass becomes a way to deadlock
# any repo whose canon bypass list happens to be Integrations only.
MUTI="$WORK/mutant-i.sh"
cat > "$WORK/mut-i.sed" <<'SEDI'
s#create.json")" -gt 0 ]#create.json")" -ge 0 ]#
SEDI
sed -f "$WORK/mut-i.sed" "$APPLIER" > "$MUTI"
chmod +x "$MUTI"
if ! cmp -s "$MUTI" "$APPLIER" && bash -n "$MUTI" 2>/dev/null; then
  reset_fix
  R=acme/would-empty-bypass
  fix_repo "$R"
  mkfix "repos/$R/rulesets" '[]'
  OUT=$(MUTANT="$MUTI" run_applier "$R" --apply --create-gates --no-integration-bypass --gates-only-file "$GO_INTONLY")
  if [ "$(state_of "$OUT")" = "REFUSED" ]; then
    bad "MUTANT I SURVIVED: empty-bypass refusal neutered yet still REFUSED — the control is decorative"
  else
    ok "mutant I killed: without the refusal it reaches $(state_of "$OUT")"
  fi
  if [ -s "$FIX/POSTS.log" ] && [ "$(jq '[.bypass_actors[]?]|length' "$FIX/LAST_POST.json")" = 0 ]; then
    ok "mutant I POSTED a ZERO-BYPASS branch ruleset — the 2026-09-11 outage shape, reproduced"
  else
    bad "mutant I: expected a POST carrying an empty bypass_actors list"
  fi
else
  bad "mutant I was not applied — the sed pattern no longer matches the applier"
fi

# =============================================================== CASE 26
# PR-REACHABILITY GUARD (standards#1040). A workflow with a green branch=$DEF
# run whose `on:` block has `# pull_request:` commented out (or is schedule/push
# only) MUST NOT have its jobs derived into required_status_checks: on a PR it
# never fires, leaving the required context permanently "Expected — Waiting for
# status to be reported" (measured on metadatastician/gsd-nerv#45 and
# hyperpolymath/echidna#52).
reset_fix
R=acme/schedule-only
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"codeql.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
SCHEDULE_WF_B64=$(printf '%s\n' 'name: CodeQL' 'on:' '  schedule:' '    - cron: "0 0 * * 0"' | base64 | tr -d '\n')
mkfix "repos/$R/contents/.github/workflows/codeql.yml" "{\"content\":\"$SCHEDULE_WF_B64\",\"encoding\":\"base64\"}"
mkfix "repos/$R/actions/workflows/codeql.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":22,"event":"schedule"}]}'
mkfix "repos/$R/actions/runs/22/jobs?per_page=100" '{"jobs":[{"name":"CodeQL Security Analysis"}]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}],"rules":[{"type":"deletion"}]}'
OUT=$(run_applier "$R" --apply)
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "UNGATED" ] && ok "pr-reachability (schedule run): state is UNGATED" || bad "pr-reachability (schedule run): state=$S (want UNGATED)"
case "$D" in *"no_pr_trigger=[codeql.yml]"*) ok "pr-reachability (schedule run): no_pr_trigger=[codeql.yml] reported" ;; *) bad "pr-reachability (schedule run): missing no_pr_trigger — $D" ;; esac
[ -s "$FIX/PUTS.log" ] && bad "pr-reachability (schedule run): PUT happened despite non-PR workflow" || ok "pr-reachability (schedule run): no PUT performed"

# Exact gsd-nerv#45 / echidna#52 shape: workflow YAML on $DEF has `# pull_request:` commented out.
reset_fix
R=acme/commented-pr-trigger
mkfix "repos/$R" '{"default_branch":"main"}'
mkfix "repos/$R/contents/.github/workflows" '[{"name":"codeql.yml"}]'
mkfix "repos/$R/contents" '[{"name":"README.md"}]'
COMMENTED_WF_B64=$(printf '%s\n' 'name: CodeQL' 'on:' '  push:' '    branches: [main]' '  # pull_request:' '  #   branches: [main]' '  schedule:' '    - cron: "0 0 * * 0"' | base64 | tr -d '\n')
mkfix "repos/$R/contents/.github/workflows/codeql.yml" "{\"content\":\"$COMMENTED_WF_B64\",\"encoding\":\"base64\"}"
mkfix "repos/$R/actions/workflows/codeql.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":22,"event":"push"}]}'
mkfix "repos/$R/actions/runs/22/jobs?per_page=100" '{"jobs":[{"name":"CodeQL / Analyze"}]}'
mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}],"rules":[{"type":"deletion"}]}'
OUT=$(run_applier "$R" --apply)
S=$(state_of "$OUT"); D=$(detail_of "$OUT")
[ "$S" = "UNGATED" ] && ok "pr-reachability (commented pull_request YAML): state is UNGATED" || bad "pr-reachability (commented pull_request YAML): state=$S (want UNGATED)"
case "$D" in *"no_pr_trigger=[codeql.yml]"*) ok "pr-reachability (commented pull_request YAML): no_pr_trigger=[codeql.yml] reported" ;; *) bad "pr-reachability (commented pull_request YAML): missing no_pr_trigger — $D" ;; esac
[ -s "$FIX/PUTS.log" ] && bad "pr-reachability (commented pull_request YAML): PUT happened" || ok "pr-reachability (commented pull_request YAML): no PUT performed"

# ---- MUTANT J: remove the PR-reachability check (#1040). ---------------------
# Without wf_triggers_on_pr, a push/schedule-only workflow's job context is
# derived from its branch=main run and written into required_status_checks,
# deadlocking every PR.
MUTJ="$WORK/mutant-j.sh"
sed 's/PRRC=0; wf_triggers_on_pr "\$R" "\$WFN" "\$DEF" || PRRC=\$?/PRRC=0/' "$APPLIER" > "$MUTJ"
chmod +x "$MUTJ"
if ! cmp -s "$MUTJ" "$APPLIER" && bash -n "$MUTJ" 2>/dev/null; then
  OUT=$(MUTANT="$MUTJ" run_applier "$R" --apply)
  if [ "$(state_of "$OUT")" = "UNGATED" ]; then
    bad "MUTANT J SURVIVED: PR-reachability check removed yet still UNGATED — the control is decorative"
  else
    ok "mutant J killed: without wf_triggers_on_pr it becomes $(state_of "$OUT") and writes the deadlocking context"
  fi
  if [ -s "$FIX/PUTS.log" ] && command grep -q 'CodeQL / Analyze' "$FIX/LAST_PUT.json" 2>/dev/null; then
    ok "mutant J wrote the non-PR 'CodeQL / Analyze' context into required_status_checks — #1040 reproduced"
  else
    bad "mutant J: expected LAST_PUT.json to carry the deadlocking 'CodeQL / Analyze' context"
  fi
else
  bad "mutant J was not applied — the sed pattern no longer matches the applier"
fi

# =============================================================== CASE 27
# PATH-FILTERED PR TRIGGERS (standards#1065, the #1040 residual). A workflow
# whose pull_request trigger carries `paths:`/`paths-ignore:` reports its
# check-runs only on PRs touching those paths; requiring its contexts blocks
# every other PR forever (metadatastician/paint-type codeql.yml). It must land
# in a named bucket, never in required_status_checks.
pr_case() {   # pr_case <repo> <workflow body (printf-escaped)>
  reset_fix
  R="$1"
  mkfix "repos/$R" '{"default_branch":"main"}'
  mkfix "repos/$R/contents/.github/workflows" '[{"name":"codeql.yml"}]'
  mkfix "repos/$R/contents" '[{"name":"README.md"}]'
  mkfix "repos/$R/contents/.github/workflows/codeql.yml" \
    "{\"content\":\"$(printf "$2" | base64 | tr -d '\n')\",\"encoding\":\"base64\"}"
  mkfix "repos/$R/actions/workflows/codeql.yml/runs?branch=main&per_page=1" '{"workflow_runs":[{"id":44,"event":"push"}]}'
  mkfix "repos/$R/actions/runs/44/jobs?per_page=100" '{"jobs":[{"name":"Agda proof (INV-3)"}]}'
  mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
  mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
  OUT=$(run_applier "$R")
  S=$(state_of "$OUT"); D=$(detail_of "$OUT")
}
expect_path_filtered() {   # expect_path_filtered <label>
  [ "$S" = "UNGATED" ] && ok "$1: state is UNGATED" || bad "$1: state=$S (want UNGATED) — $D"
  case "$D" in *"path_filtered=[codeql.yml]"*) ok "$1: path_filtered=[codeql.yml] reported" ;; *) bad "$1: missing path_filtered — $D" ;; esac
}

pr_case acme/paths-block 'on:\n  pull_request:\n    branches: [main]\n    paths:\n      - "verification/proofs/**"\n  push:\n    branches: [main]\n'
expect_path_filtered "path-filtered (block paths:)"
pr_case acme/paths-ignore 'on:\n  pull_request:\n    paths-ignore: ["docs/**"]\n'
expect_path_filtered "path-filtered (paths-ignore:)"
pr_case acme/paths-flow 'on:\n  pull_request: {branches: [main], paths: ["docs/**"]}\n'
expect_path_filtered "path-filtered (flow-style pull_request mapping)"
pr_case acme/paths-target 'on:\n  pull_request_target:\n    paths:\n      - src/**\n'
expect_path_filtered "path-filtered (pull_request_target)"

# Positive controls: a bare PR trigger is still derived, and a `paths:` under
# push (not under pull_request) does not filter the PR trigger.
pr_case acme/bare-pr 'on:\n  pull_request:\n    branches: [main]\n  push:\n    branches: [main]\n    paths: ["src/**"]\n'
[ "$S" = "WOULD-GATE" ] && ok "path-filter positive control: bare pull_request still derived" || bad "path-filter positive control: state=$S (want WOULD-GATE) — $D"
case "$D" in *"Agda proof (INV-3)"*) ok "path-filter positive control: context derived" ;; *) bad "path-filter positive control: context missing — $D" ;; esac
case "$D" in *"path_filtered="*) bad "path-filter positive control: push paths: wrongly filtered the PR trigger — $D" ;; *) ok "path-filter positive control: push paths: does not filter the PR trigger" ;; esac

# ---- MUTANT K: drop the path-filter verdict (#1065). -------------------------
MUTK="$WORK/mutant-k.sh"
sed 's/elif any(\$reach\[\]; \.path_filtered) then/elif false then/' "$APPLIER" > "$MUTK"
if ! cmp -s "$MUTK" "$APPLIER" && bash -n "$MUTK" 2>/dev/null; then
  pr_case acme/paths-block 'on:\n  pull_request:\n    paths:\n      - "verification/proofs/**"\n'
  OUT=$(MUTANT="$MUTK" run_applier "$R")
  if [ "$(state_of "$OUT")" = "WOULD-GATE" ] && [[ "$(detail_of "$OUT")" == *"Agda proof (INV-3)"* ]]; then
    ok "mutant K killed: without the path-filter verdict the deadlocking context is derived"
  else
    bad "MUTANT K SURVIVED: path-filter verdict removed yet the context is still kept out — $(detail_of "$OUT")"
  fi
else
  bad "mutant K was not applied — the sed pattern no longer matches the applier"
fi

# =============================================================== CASE 28
# THE TRIGGER IS READ BY A YAML PARSER, NOT BY KEY SPELLING. Quoted keys are
# valid YAML; a line matcher that knows only bare `paths:` reads a quoted one
# as no filter at all and derives a context that never reports on most PRs.
pr_case acme/paths-quoted-block 'on:\n  pull_request:\n    "paths": ["docs/**"]\n'
expect_path_filtered "path-filtered (quoted block key)"
pr_case acme/paths-quoted-flow 'on:\n  pull_request: {"paths": ["docs/**"]}\n'
expect_path_filtered "path-filtered (quoted flow key)"
pr_case acme/paths-ignore-squoted 'on:\n  pull_request:\n    \x27paths-ignore\x27:\n      - docs/**\n'
expect_path_filtered "path-filtered (single-quoted paths-ignore key)"
pr_case acme/paths-quoted-event '"on":\n  "pull_request":\n    "paths": ["docs/**"]\n'
expect_path_filtered "path-filtered (quoted on: and event keys)"

expect_reachable() {   # expect_reachable <label>
  [ "$S" = "WOULD-GATE" ] && ok "$1: state is WOULD-GATE" || bad "$1: state=$S (want WOULD-GATE) — $D"
  case "$D" in *"Agda proof (INV-3)"*) ok "$1: context derived" ;; *) bad "$1: context missing — $D" ;; esac
}
pr_case acme/on-seq 'on: [push, pull_request]\n'
expect_reachable "PR trigger (on: sequence)"
pr_case acme/on-str 'on: pull_request\n'
expect_reachable "PR trigger (on: string)"
pr_case acme/on-null-pr 'on:\n  pull_request:\n  push:\n    paths: ["src/**"]\n'
expect_reachable "PR trigger (null pull_request mapping)"

pr_case acme/no-pr 'on:\n  push:\n    branches: [main]\n  schedule:\n    - cron: "0 0 * * 0"\n'
[ "$S" = "UNGATED" ] && ok "no PR trigger: state is UNGATED" || bad "no PR trigger: state=$S (want UNGATED) — $D"
case "$D" in *"no_pr_trigger=[codeql.yml]"*) ok "no PR trigger: no_pr_trigger=[codeql.yml] reported" ;; *) bad "no PR trigger: missing no_pr_trigger — $D" ;; esac
pr_case acme/branch-miss 'on:\n  pull_request:\n    branches: ["release/*"]\n'
case "$D" in *"no_pr_trigger=[codeql.yml]"*) ok "PR trigger for another branch: no_pr_trigger reported" ;; *) bad "PR trigger for another branch: missing no_pr_trigger — $D" ;; esac

# A workflow definition that does not parse is a failed read, never "reachable"
# and never "no PR trigger": either verdict would be a guess.
pr_case acme/malformed 'on:\n  pull_request: [unclosed\n    paths: : x\n'
[ "$S" = "REFUSED" ] && ok "malformed workflow YAML: state is REFUSED" || bad "malformed workflow YAML: state=$S (want REFUSED) — $D"
case "$D" in *"derive_failed=[codeql.yml("*) ok "malformed workflow YAML: derive_failed names the workflow" ;; *) bad "malformed workflow YAML: derive_failed missing — $D" ;; esac
pr_case acme/empty-def ''
[ "$S" = "REFUSED" ] && ok "empty workflow definition: state is REFUSED" || bad "empty workflow definition: state=$S (want REFUSED) — $D"

# =============================================================== CASE 29
# AN UNREADABLE WORKFLOW DEFINITION IS A DERIVATION FAILURE. Run history can
# show that a workflow once ran on a PR; it cannot show that the workflow runs
# on EVERY PR, because a paths: filter lives only in the definition. So a
# failed contents read must REFUSE, not fall back to run history.
unreadable_case() {   # unreadable_case <repo> <run event> [contents fixture]
  reset_fix
  rm -f "$FIX/DEFAULT_WF.json"   # no definition is readable at all
  R="$1"
  mkfix "repos/$R" '{"default_branch":"main"}'
  mkfix "repos/$R/contents/.github/workflows" '[{"name":"codeql.yml"}]'
  mkfix "repos/$R/contents" '[{"name":"README.md"}]'
  [ -n "${3:-}" ] && mkfix "repos/$R/contents/.github/workflows/codeql.yml" "$3"
  mkfix "repos/$R/actions/workflows/codeql.yml/runs?branch=main&per_page=1" "{\"workflow_runs\":[{\"id\":44,\"event\":\"$2\"}]}"
  mkfix "repos/$R/actions/workflows/codeql.yml/runs?event=pull_request&per_page=1" '{"workflow_runs":[{"id":45}]}'
  mkfix "repos/$R/actions/runs/44/jobs?per_page=100" '{"jobs":[{"name":"Agda proof (INV-3)"}]}'
  mkfix "repos/$R/rulesets" '[{"id":9,"target":"branch","enforcement":"active","source_type":"Repository"}]'
  mkfix "repos/$R/rulesets/9" '{"id":9,"name":"Base","target":"branch","enforcement":"active","conditions":{},"bypass_actors":[],"rules":[{"type":"deletion"}]}'
  OUT=$(run_applier "$R" --apply)
  S=$(state_of "$OUT"); D=$(detail_of "$OUT")
}
expect_unreadable_refused() {   # expect_unreadable_refused <label>
  [ "$S" = "REFUSED" ] && ok "$1: state is REFUSED" || bad "$1: state=$S (want REFUSED) — $D"
  case "$D" in *"derive_failed=[codeql.yml("*) ok "$1: derive_failed names the workflow" ;; *) bad "$1: derive_failed missing — $D" ;; esac
  [ -s "$FIX/PUTS.log" ] && bad "$1: PUT happened from run history alone" || ok "$1: no PUT"
}
unreadable_case acme/unreadable-push push
expect_unreadable_refused "contents read failed (push run, PR runs exist)"
unreadable_case acme/unreadable-pr pull_request
expect_unreadable_refused "contents read failed (pull_request run)"
unreadable_case acme/too-large push '{"content":"","encoding":"none"}'
expect_unreadable_refused "contents not inline (encoding none)"
unreadable_case acme/bad-b64 push '{"content":"!!!not-base64!!!","encoding":"base64"}'
expect_unreadable_refused "contents not decodable"

# =============================================================== CASE 30
# yq is required, and it must be mikefarah yq v4: there is no regex fallback.
FAKEYQ="$WORK/fake-yq"; mkdir -p "$FAKEYQ"
printf '#!/usr/bin/env bash\necho "yq 3.4.1"\n' > "$FAKEYQ/yq"; chmod +x "$FAKEYQ/yq"
reset_fix
if PATH="$FAKEYQ:$BIN:$PATH" GH_FIX="$FIX" bash "$APPLIER" --gates-file "$WORK/gates.json" --repo acme/x >/dev/null 2>"$WORK/err"; then
  bad "non-mikefarah yq: exited 0 instead of refusing"
else
  command grep -q 'mikefarah yq v4' "$WORK/err" && ok "non-mikefarah yq: refused with a clear message" \
    || bad "non-mikefarah yq: refused without naming the requirement — $(cat "$WORK/err")"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
