#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# remove-ruleset-bypass.sh — remove `always` bypass actors from branch rulesets.
#
# WHY THIS EXISTS
# ---------------
# On 2026-10-24 the bypass was removed from `23787415` (main gate), which is the
# ruleset that had actually been used to merge red. Three other active branch
# rulesets were left alone, and two of them still matter less than they look:
#
#   24255701  Require-Linear-History   required_linear_history   ← the real gap
#   24587723  Lock-Floor               2 status checks           ← duplicated
#   24309995  Secret-Scan-Floor        1 status check            ← duplicated
#
# Lock-Floor and Secret-Scan-Floor require contexts that `23787415` also
# requires, and `23787415` now has no bypass, so their bypasses discard nothing
# that is not still required next door. `required_linear_history` is the only
# rule in the repository that lives in exactly one ruleset — so its bypass is
# the difference between "append-only merging is enforced" and "append-only
# merging is advice for an admin".
#
# The duplicated ones are still worth clearing: a redundant bypass is a bypass
# waiting to become load-bearing the day somebody removes that check from the
# main gate.
#
# WHAT IT REFUSES
# ---------------
# * a ruleset that is not `active` (editing it changes nothing while looking
#   like it did) — reported and skipped rather than written;
# * a payload that would change anything other than `bypass_actors` — the rules,
#   conditions, name, target and enforcement are asserted identical before send;
# * a read-back that disagrees with the intent.
#
# Removing every bypass means the emergency path is disabling the ruleset
# deliberately, which is an auditable act rather than a silent merge. That is
# the trade this makes, and it is stated in the output rather than assumed.
#
# Requires `administration: write`. Installation tokens report repo admin=true
# and still get 403 on ruleset writes; use an admin user token.
#
# Usage:
#   scripts/remove-ruleset-bypass.sh                    # report; writes nothing
#   scripts/remove-ruleset-bypass.sh --apply            # remove from all targeted
#   ONLY=24255701 scripts/remove-ruleset-bypass.sh --apply
#   REPO=owner/name scripts/remove-ruleset-bypass.sh

set -uo pipefail

REPO="${REPO:-metadatastician/standards}"
ONLY="${ONLY:-}"          # space-separated ruleset ids; empty = every active branch ruleset
GH="${GH:-gh}"            # injectable for scripts/tests/remove-ruleset-bypass-test.sh

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

command -v "$GH" >/dev/null || { echo "'$GH' is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "== $REPO"

if ! "$GH" api "repos/$REPO/rulesets" >"$tmp/list.json" 2>"$tmp/err"; then
  echo "FATAL: cannot list rulesets: $(head -1 "$tmp/err")" >&2
  echo "       (403 here means the token cannot see protection at all, not that" >&2
  echo "        none exists)" >&2
  exit 1
fi

# Filter the list locally rather than with `gh --jq`: the fetch above already
# returned it, and a local jq keeps this working against any gh version and any
# wrapper that does not pass --jq through.
ids="$(jq -r '.[] | select(.target=="branch" and .source_type=="Repository") | .id' "$tmp/list.json")"
if [ -n "$ONLY" ]; then
  for id in $ONLY; do
    if ! grep -qxF "$id" <<<"$ids"; then
      echo "FATAL: targeted ruleset $id is not a repository-owned branch ruleset" >&2
      exit 1
    fi
  done
  ids="$ONLY"
fi
[ -z "$ids" ] && { echo "no branch rulesets to inspect"; exit 0; }

# Never rewrite a bypass away by accident on a ruleset that is currently doing
# something we do not understand: this refuses on any surprise.
changed=0; skipped=0; target=0

for id in $ids; do
  if ! "$GH" api "repos/$REPO/rulesets/$id" >"$tmp/rs.json" 2>"$tmp/err"; then
    if [ -n "$ONLY" ]; then
      echo "FATAL: cannot read targeted ruleset $id: $(head -1 "$tmp/err")" >&2
      exit 1
    fi
    echo "SKIP $id — cannot read it: $(head -1 "$tmp/err")" >&2
    skipped=$((skipped+1)); continue
  fi

  name="$(jq -r '.name' "$tmp/rs.json")"
  enforcement="$(jq -r '.enforcement' "$tmp/rs.json")"
  if ! jq -e '.bypass_actors | type == "array"' "$tmp/rs.json" >/dev/null 2>&1; then
    echo "FATAL: bypass actors for $id are unknown — expected an array" >&2
    exit 1
  fi
  n_bypass="$(jq -r '.bypass_actors | length' "$tmp/rs.json")"

  if [ "$n_bypass" -eq 0 ]; then
    printf '  ok    %-9s %-58s no bypass\n' "$id" "$name"
    continue
  fi

  actors="$(jq -r '[.bypass_actors[] | "\(.actor_type):\(.actor_id)=\(.bypass_mode)"] | join(", ")' "$tmp/rs.json")"

  if [ "$enforcement" != "active" ]; then
    printf '  SKIP  %-9s %-58s bypass=[%s] but enforcement=%s\n' "$id" "$name" "$actors" "$enforcement"
    skipped=$((skipped+1)); continue
  fi

  target=$((target+1))
  printf '  FIX   %-9s %-58s bypass=[%s]\n' "$id" "$name" "$actors"

  # Build the writable payload ONCE, then derive the before/after pair from it.
  # Comparing the payload against the raw API response is wrong: the response
  # also carries read-only fields (`id`, `node_id`, `_links`, `created_at`,
  # `source`, `current_user_can_bypass`) that are not part of a PUT body, so that
  # comparison fails on a payload that is in fact correct. The assertion that
  # matters is that MY transformation changed nothing but bypass_actors, so the
  # two sides must both be payloads built the same way from the same source.
  jq '{name, target, enforcement, conditions, rules, bypass_actors}' \
    "$tmp/rs.json" >"$tmp/before-payload.json"
  jq '.bypass_actors = []' "$tmp/before-payload.json" >"$tmp/payload.json"

  if ! diff -q \
      <(jq -S 'del(.bypass_actors)' "$tmp/before-payload.json") \
      <(jq -S 'del(.bypass_actors)' "$tmp/payload.json") >/dev/null; then
    echo "FATAL: payload would change more than bypass_actors for $id. Refusing." >&2
    exit 1
  fi
  if [ "$(jq -r '.bypass_actors|length' "$tmp/payload.json")" -ne 0 ]; then
    echo "FATAL: payload still carries bypass actors for $id. Refusing." >&2
    exit 1
  fi

  if [ "$APPLY" -eq 0 ]; then
    changed=$((changed+1)); continue
  fi

  if ! "$GH" api -X PUT "repos/$REPO/rulesets/$id" --input "$tmp/payload.json" >/dev/null 2>"$tmp/err"; then
    echo "FATAL: write refused for $id:" >&2
    sed 's/^/       /' "$tmp/err" >&2
    echo "       'Resource not accessible by integration' means an installation" >&2
    echo "       token: admin=true is not administration:write. Use a user token." >&2
    exit 1
  fi

  # Verify against the server, and treat an unverifiable result as a failure.
  # A GET that fails leaves an empty file; jq then yields empty strings, and
  # `[ "" -ne 0 ]` is a *syntax* error that evaluates false — so the mismatch
  # branch is skipped and the script would print "verified" after performing no
  # verification at all. The request must succeed, the response must parse,
  # and the complete writable ruleset must match the intended payload.
  if ! "$GH" api "repos/$REPO/rulesets/$id" >"$tmp/verify.json" 2>"$tmp/err"; then
    echo "FATAL: could not read back $id after writing it — protection is UNVERIFIED" >&2
    sed 's/^/       /' "$tmp/err" >&2
    exit 1
  fi
  if ! jq -e '.bypass_actors | type == "array"' "$tmp/verify.json" >/dev/null 2>&1; then
    echo "FATAL: read-back for $id is not a ruleset payload — protection is UNVERIFIED" >&2
    exit 1
  fi
  v_rules="$(jq -r '.rules|length' "$tmp/verify.json" 2>/dev/null)"
  if ! jq -e --slurpfile intended "$tmp/payload.json" '
    {name, target, enforcement, conditions, rules, bypass_actors} == $intended[0]
  ' "$tmp/verify.json" >/dev/null 2>&1; then
    echo "FATAL: read-back mismatch for $id — writable ruleset differs from intended payload" >&2
    exit 1
  fi
  echo "        verified: 0 bypass actors, $v_rules rules unchanged"
  changed=$((changed+1))
done

echo
if [ "$APPLY" -eq 0 ]; then
  if [ "$target" -eq 0 ]; then
    echo "REPORT-ONLY: no active branch ruleset carries a bypass actor."
  else
    echo "REPORT-ONLY: $target ruleset(s) would lose their bypass. Re-run with --apply."
    echo "The emergency path becomes: disable the ruleset deliberately (audited),"
    echo "not merge through it silently."
  fi
else
  echo "done: $changed ruleset(s) updated, $skipped skipped."
fi
