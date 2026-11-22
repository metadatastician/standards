#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Produce a reviewable PUT body for the four retired constraints documented
# in config/README.adoc. This script never calls GitHub or changes a ruleset.
#
# Usage: plan-ruleset-constraint-repair.sh <live-ruleset.json> [--remove-uninstalled-app <verified-id>]
#
# It strips the retired constraint rules and, optionally, a confirmed-uninstalled
# app bypass. Supply an app ID only after GitHub rejects it as no longer
# installed. Removing a stale bypass tightens access; never infer app
# availability from its name. Any refusal exits 1 and prints nothing on stdout.
set -euo pipefail

usage='Usage: plan-ruleset-constraint-repair.sh <live-ruleset.json> [--remove-uninstalled-app <verified-id>]'
if ! { [ "$#" -eq 1 ] || { [ "$#" -eq 3 ] && [ "$2" = '--remove-uninstalled-app' ]; }; }; then
  echo "$usage" >&2
  exit 1
fi
app_id=null
if [ "$#" -eq 3 ]; then
  invalid_app_id() {
    echo "Expected the exact ID of an existing integration bypass rejected by GitHub" >&2
    exit 1
  }
  # Only a positive decimal integer can name an existing integration.
  LC_ALL=C
  [[ "$3" =~ ^\+?([0-9]+)$ ]] || invalid_app_id
  app_id=${BASH_REMATCH[1]}
  app_id=${app_id#"${app_id%%[!0]*}"}
  app_id=${app_id:-0}
  # Stay within the safe integer range of jq builds that use doubles.
  max_app_id=9007199254740991
  if (( ${#app_id} > ${#max_app_id} )) ||
     { (( ${#app_id} == ${#max_app_id} )) && [[ "$app_id" > "$max_app_id" ]]; }; then
    invalid_app_id
  fi
  (( app_id > 0 )) || invalid_app_id
fi

# shellcheck disable=SC2016 # jq program, not shell
jq --slurp --argjson app "$app_id" '
  def refuse(msg): error(msg);
  if length == 1 then .[0] else refuse("Expected exactly one JSON value") end
  | ["update", "required_deployments", "code_quality", "code_coverage"] as $retired
  | ["name", "target", "enforcement", "conditions", "bypass_actors", "rules"] as $writable
  | if (type == "object") and .target == "branch" and .enforcement == "active"
       and ((.conditions | type) == "object") and ((.conditions.ref_name | type) == "object")
       and .conditions.ref_name.include == ["~DEFAULT_BRANCH"]
       and .conditions.ref_name.exclude == [] and ((.rules | type) == "array")
    then . else refuse("Expected an active default-branch ruleset with no exclusions") end
  | if all(.rules[]; (type == "object") and ((.type | type) == "string"))
    then . else refuse("Malformed rule data; refusing a partial plan") end
  | if any(.rules[]; .type == "pull_request")
    then . else refuse("Missing pull-request protection") end
  | . as $source
  | with_entries(select(.key as $k | $writable | index($k)))
  | .rules = [$source.rules[] | select(.type as $t | $retired | index($t) | not)]
  | if $app == null then . else
      ($source.bypass_actors) as $actors
      | def stale: (type == "object") and .actor_type == "Integration" and .actor_id == $app;
      if ($app > 0) and (($actors | type) == "array") and all($actors[]; type == "object")
         and any($actors[]; stale)
      then .bypass_actors = [$actors[] | select(stale | not)]
      else refuse("Expected the exact ID of an existing integration bypass rejected by GitHub") end
    end
' -- "$1" || exit 1
