#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# fix-required-context-name.sh — repoint ONE required status check at the call
# site that actually publishes it on a pull request.
#
# WHY THIS EXISTS
# ---------------
# A required status check is matched by NAME. For a job that calls a reusable
# workflow, that name is `<caller job name> / <callee job name>`. Two workflows
# that run the same reusable therefore publish two different contexts, and a
# ruleset can require the one that only runs after merge.
#
# That is this repository's position today:
#
#   scan / Hypatia Neurosymbolic Analysis                  hypatia-scan.yml
#       ↑ named by ruleset 23787415                        push/schedule only
#   Hypatia verdict grid / Hypatia Neurosymbolic Analysis   fork-governance.yml
#       ↑ published on every pull_request                  same scanner
#
# The result is not a red pull request, it is an UNDECIDABLE one: #1336 reached
# 65 passing checks, a cleared reviewDecision and mergeable=MERGEABLE while
# mergeStateStatus stayed BLOCKED, because the required check can never appear.
# No rebase, re-run, or code change can satisfy it — the only route to `main`
# is the ruleset's `always` bypass, which discards the other nineteen required
# checks in the same action.
#
# `scripts/apply-branch-gates.sh` cannot fix this: it derives contexts from
# checks that actually run and then has to choose a ruleset, and it refuses
# because six active branch rulesets are additive and none is uniquely
# checks-only (correct — guessing which one to rewrite is how protection gets
# silently dropped). This script instead touches exactly one named context in
# exactly one named ruleset, and refuses if the before-state is not what it
# expects.
#
# NOT a rename to make a gate pass. The two names are the same scanner; the
# required one simply names a call site that cannot run while the pull request
# is open. The deep scan keeps its weekly `main` run.
#
# Requires `administration: write`. Installation tokens report repo admin=true
# and still get 403 here; run it with an admin-scoped user token.
#
# Usage:
#   scripts/fix-required-context-name.sh                     # report what would change
#   scripts/fix-required-context-name.sh --apply             # write it
#   REPO=owner/name RULESET=123 scripts/fix-required-context-name.sh

set -uo pipefail

REPO="${REPO:-metadatastician/standards}"
RULESET="${RULESET:-23787415}"
OLD_CONTEXT="${OLD_CONTEXT:-scan / Hypatia Neurosymbolic Analysis}"
NEW_CONTEXT="${NEW_CONTEXT:-Hypatia verdict grid / Hypatia Neurosymbolic Analysis}"

# The binary is injectable so scripts/tests/fix-required-context-name-test.sh
# can drive every refusal branch offline. Nothing else about the call changes.
GH="${GH:-gh}"

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

command -v "$GH" >/dev/null || { echo "'$GH' is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== $REPO ruleset $RULESET"

if ! "$GH" api "repos/$REPO/rulesets/$RULESET" >"$tmp/before.json" 2>"$tmp/err"; then
  echo "FATAL: cannot read the ruleset: $(head -1 "$tmp/err")" >&2
  echo "       (needs read access to the repository rules; a 403 here means the" >&2
  echo "        token cannot see protection at all, not that nothing is required)" >&2
  exit 1
fi

enforcement="$(jq -r '.enforcement' "$tmp/before.json")"
n_rules="$(jq -r '.rules | length' "$tmp/before.json")"
n_ctx="$(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]?] | length' "$tmp/before.json")"
has_old="$(jq -r --arg c "$OLD_CONTEXT" '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]? | select(.context==$c)] | length' "$tmp/before.json")"
has_new="$(jq -r --arg c "$NEW_CONTEXT" '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]? | select(.context==$c)] | length' "$tmp/before.json")"

printf '   name        %s\n' "$(jq -r '.name' "$tmp/before.json")"
printf '   enforcement %s\n' "$enforcement"
printf '   rules       %s (%s required context(s))\n' "$n_rules" "$n_ctx"

if [ "$enforcement" != "active" ]; then
  echo "FATAL: ruleset is '$enforcement', not 'active' — editing it would change" >&2
  echo "       nothing while looking like it did." >&2
  exit 1
fi

# Refuse rather than guess. Each of these means the world moved and a scripted
# single-field edit is no longer the right instrument.
if [ "$has_new" -gt 0 ] && [ "$has_old" -eq 0 ]; then
  echo "OK: already repaired — '$NEW_CONTEXT' is required, '$OLD_CONTEXT' is not."
  exit 0
fi
if [ "$has_old" -eq 0 ]; then
  echo "FATAL: '$OLD_CONTEXT' is not a required context in this ruleset." >&2
  echo "       Nothing to repoint; refusing to invent a change." >&2
  exit 1
fi
if [ "$has_new" -gt 0 ]; then
  echo "FATAL: both names are required. Remove '$OLD_CONTEXT' by hand:" >&2
  echo "       one of them can never be produced on a pull request." >&2
  exit 1
fi
if [ "$has_old" -gt 1 ]; then
  echo "FATAL: '$OLD_CONTEXT' appears $has_old times; this script replaces one." >&2
  exit 1
fi

jq --arg old "$OLD_CONTEXT" --arg new "$NEW_CONTEXT" '{
  name, target, enforcement, bypass_actors, conditions,
  rules: [.rules[] | if .type=="required_status_checks" then
    {type, parameters: (.parameters | .required_status_checks |=
      map(if .context==$old then .context=$new else . end))}
    else {type, parameters} end]
}' "$tmp/before.json" >"$tmp/after.json"

# The whole safety property: exactly one string changed, the rule count and the
# context count are identical, and nothing else in the ruleset moved.
n_after="$(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]?] | length' "$tmp/after.json")"
n_rules_after="$(jq -r '.rules | length' "$tmp/after.json")"
if [ "$n_after" != "$n_ctx" ] || [ "$n_rules_after" != "$n_rules" ]; then
  echo "FATAL: payload changed the shape of the ruleset ($n_rules→$n_rules_after rules," >&2
  echo "       $n_ctx→$n_after contexts). Refusing to send." >&2
  exit 1
fi

echo
echo "== context diff (whole ruleset; anything else changing is a bug)"
diff <(jq -r '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' "$tmp/before.json") \
     <(jq -r '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' "$tmp/after.json") \
  || true

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "REPORT-ONLY. Re-run with --apply to write this to $REPO."
  exit 0
fi

echo
echo "== applying"
if ! "$GH" api -X PUT "repos/$REPO/rulesets/$RULESET" --input "$tmp/after.json" >"$tmp/resp.json" 2>"$tmp/err"; then
  echo "FATAL: the API refused the write:" >&2
  sed 's/^/       /' "$tmp/err" >&2
  echo "       'Resource not accessible by integration' means the token is an" >&2
  echo "       installation token: it may report admin=true and still lack" >&2
  echo "       administration:write. Use an admin user token." >&2
  exit 1
fi

# Verify against the server, not against the payload we sent.
# Verify against the server, and treat an unverifiable result as a failure: a
# failed GET leaves an empty file, jq yields empty strings, and `[ "" -ne 1 ]`
# is a syntax error that evaluates false — which would skip the mismatch branch
# and print success after verifying nothing.
if ! "$GH" api "repos/$REPO/rulesets/$RULESET" >"$tmp/verify.json" 2>"$tmp/err"; then
  echo "FATAL: could not read back the ruleset after writing it — UNVERIFIED" >&2
  sed 's/^/       /' "$tmp/err" >&2
  exit 1
fi
if ! jq -e '.rules | type == "array"' "$tmp/verify.json" >/dev/null 2>&1; then
  echo "FATAL: read-back is not a ruleset payload — UNVERIFIED" >&2
  exit 1
fi
v_new="$(jq -r --arg c "$NEW_CONTEXT" '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]? | select(.context==$c)] | length' "$tmp/verify.json")"
v_old="$(jq -r --arg c "$OLD_CONTEXT" '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]? | select(.context==$c)] | length' "$tmp/verify.json")"
v_cnt="$(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]?] | length' "$tmp/verify.json")"
for count in "$v_new" "$v_old" "$v_cnt" "$n_ctx"; do
  case "$count" in
    ''|*[!0-9]*)
      echo "FATAL: read-back gave non-numeric counts — UNVERIFIED" >&2
      exit 1 ;;
  esac
done

if [ "$v_new" -ne 1 ] || [ "$v_old" -ne 0 ] || [ "$v_cnt" -ne "$n_ctx" ]; then
  echo "FATAL: read-back does not match what was intended." >&2
  echo "       new=$v_new old=$v_old contexts=$v_cnt (expected 1/0/$n_ctx)" >&2
  exit 1
fi

echo "OK: $NEW_CONTEXT is now required ($v_cnt contexts, unchanged);"
echo "    $OLD_CONTEXT is no longer required."
echo
echo "Next: the blocked pull request should become decidable on the next rule"
echo "evaluation. Re-check with: gh pr view <n> --json mergeStateStatus"
