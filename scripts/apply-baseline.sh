#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# apply-baseline.sh — filter Hypatia findings against a per-repo baseline.
#
# Inputs:
#   $1 = path to findings JSON (array of {severity, rule_module, type, file, ...})
#   $2 = path to .hypatia-baseline.json (array of baseline entries, see schema)
#   $3 = mode: "advisory" | "blocking"  (default: advisory)
#
# Outputs (stdout):
#   Filtered findings JSON. Each finding gets one of:
#     - removed entirely (matched by baseline, no severity_override)
#     - kept with downgraded `severity` (matched, severity_override set)
#     - kept unchanged with `baseline_status: "new"`
#   Plus a top-level summary written to $GITHUB_STEP_SUMMARY if set.
#
# The advisory class (owner ruling 2026-11-17, hypatia#1204): a finding the
# scanner marks `"advisory": true` (WF026, WF027, RE011: flag-only rules) is
# reported in `findings_kept` like any other unacknowledged finding, and is
# never counted by the gate, at any threshold. Hypatia does not count it
# toward its own exit code either. Two limits keep the class from hiding a
# defect: only the JSON boolean `true` is the class, and it waives nothing
# at `high`, `critical` or an unknown severity.
#
# Exit codes:
#   0 = all unfiltered findings have severity below blocking threshold
#       or are of the advisory class (or advisory mode)
#   1 = one or more unfiltered findings >= high in blocking mode
#   2 = invalid input (missing files, malformed JSON, or a baseline that
#       violates the schema — see below)
#
# Dependencies: bash, jq.
#
# Schema enforcement: the baseline is structurally validated here, in jq,
# mirroring .machine_readable/hypatia-baseline.schema.json (required keys,
# file XOR file_pattern, closed key set, severity enums, rule_module/type/
# tracking_issue/expires_at shapes). This script is the single place every
# baseline passes through (both reusable workflows call it), so validating
# here needs no extra tooling or checkout — and a malformed baseline FAILS
# (exit 2) rather than silently matching nothing, which is how suppression
# bugs creep in. Keep this mirror in sync when the schema changes.

set -euo pipefail

FINDINGS_FILE="${1:-}"
BASELINE_FILE="${2:-}"
MODE="${3:-advisory}"
BLOCKING_THRESHOLD="${BLOCKING_THRESHOLD:-high}"
case "$MODE" in
  advisory|blocking) ;;
  *) echo "error: invalid baseline mode: $MODE" >&2; exit 2 ;;
esac
case "$BLOCKING_THRESHOLD" in
  info|low|medium|high|critical) ;;
  *) echo "error: invalid blocking threshold: $BLOCKING_THRESHOLD" >&2; exit 2 ;;
esac
TODAY="$(date -u +%Y-%m-%d)"

if [[ -z "$FINDINGS_FILE" || -z "$BASELINE_FILE" ]]; then
  echo "usage: apply-baseline.sh <findings.json> <.hypatia-baseline.json> [advisory|blocking]" >&2
  exit 2
fi

if [[ ! -f "$FINDINGS_FILE" ]]; then
  echo "error: findings file not found: $FINDINGS_FILE" >&2
  exit 2
fi

# Missing baseline is not an error — treat as empty array.
if [[ ! -f "$BASELINE_FILE" ]]; then
  BASELINE_JSON='[]'
else
  BASELINE_JSON="$(cat "$BASELINE_FILE")"
fi

FINDINGS_JSON="$(cat "$FINDINGS_FILE")"

# Validate inputs are JSON arrays.
echo "$FINDINGS_JSON" | jq -e 'type == "array"' >/dev/null || {
  echo "error: findings JSON is not an array" >&2
  exit 2
}
echo "$BASELINE_JSON" | jq -e 'type == "array"' >/dev/null || {
  echo "error: baseline JSON is not an array" >&2
  exit 2
}

# Structural validation against the baseline schema (see header).
SCHEMA_ERRORS="$(jq -r '
  def known: ["severity","rule_module","type","file","file_pattern",
              "severity_override","expires_at","note","tracking_issue"];
  # Baseline severity vocabulary mirrors both the scanner validator and the
  # authoritative schema. `warn` is retained for old records; matching treats
  # it as the same tier as current scanner `medium` output.
  def sevs: ["critical","high","medium","warn","low","info","informational"];
  # Overrides are a distinct schema contract: aliases are valid source
  # severities, not valid override targets.
  def override_sevs: ["critical","high","medium","low","info","advisory"];
  [ to_entries[] | .key as $i | .value as $e |
    if ($e|type) != "object" then "entry[\($i)]: not an object"
    else (
      (["severity","type"][]
        | select(($e[.]|type) != "string")
        | "entry[\($i)]: required key \(.) missing or not a string"),
      # `rule_module` is the one key that admits a LIST as well as a string
      # (standards#966: one defect, two emitting modules, one acknowledgement).
      # Validated separately rather than being dropped from the required set —
      # a key that is merely absent from every check is not validated, it is
      # unchecked.
      (if ($e.rule_module|type) as $t | $t != "string" and $t != "array"
       then "entry[\($i)]: required key rule_module missing or not a string/array"
       else empty end),
      (if ($e.rule_module|type) == "array" and ($e.rule_module|length) == 0
       then "entry[\($i)]: rule_module list is empty — an entry that names no module matches nothing"
       else empty end),
      (if ($e.rule_module|type) == "array"
          and (($e.rule_module | unique | length) != ($e.rule_module | length))
       then "entry[\($i)]: rule_module list contains duplicate members"
       else empty end),
      (if ($e.rule_module|type) == "array"
       then ($e.rule_module[]
             | select(type != "string")
             | "entry[\($i)]: rule_module list member is not a string: \(tojson)")
       else empty end),
      (if (($e|has("file")) == ($e|has("file_pattern")))
       then "entry[\($i)]: exactly one of file / file_pattern is required"
       else empty end),
      ($e | keys[]
        | select(. as $k | known | index($k) | not)
        | "entry[\($i)]: unknown key \(.)"),
      (if ($e.severity|type) == "string" and ((sevs|index($e.severity))|not)
       then "entry[\($i)]: invalid severity \($e.severity)" else empty end),
      (if ($e.rule_module|type) == "array"
       then ($e.rule_module[]
             | select(type == "string")
             | select((test("^[a-z][a-z0-9_]*$"))|not)
             | "entry[\($i)]: rule_module list member fails pattern: \(.)")
       else empty end),
      (if ($e.rule_module|type) == "string"
          and (($e.rule_module|test("^[a-z][a-z0-9_]*$"))|not)
       then "entry[\($i)]: rule_module fails pattern: \($e.rule_module)"
       else empty end),
      # `type` accepts three shapes, and the third is not cosmetic:
      #   snake_case          — the Hypatia rule modules (unsafe_block, ...)
      #   SD007/HYP-S009 codes — structural_drift and canonical-home rules
      #   CamelCase           — SCORECARD PROBE NAMES (DependencyPinning,
      #                         BranchProtection, ...). Hypatia emits these
      #                         verbatim from Scorecard, and without this
      #                         alternative NO SCORECARD FINDING COULD BE
      #                         BASELINED BY ANY REPOSITORY — the validator
      #                         rejected the whole file with exit 2, which
      #                         reads as "your baseline is malformed" rather
      #                         than "this finding is unrepresentable".
      #                         Found 2026-08-06 in metadatastician/stapeln.
      (if ($e.type|type) == "string"
          and (($e.type|test("^([a-z][a-z0-9_]*|[A-Z]{2,3}(-[A-Z])?[0-9]{3}|[A-Z][A-Za-z0-9]+)$"))|not)
       then "entry[\($i)]: type fails pattern: \($e.type)" else empty end),
      (if ($e|has("file")) and ((($e.file|type) != "string") or ($e.file == ""))
       then "entry[\($i)]: file must be a non-empty string" else empty end),
      (if ($e|has("file_pattern"))
          and ((($e.file_pattern|type) != "string") or ($e.file_pattern == ""))
       then "entry[\($i)]: file_pattern must be a non-empty string"
       else empty end),
      (if ($e|has("severity_override"))
          and ((($e.severity_override|type) != "string")
               or ((override_sevs|index($e.severity_override))|not))
       then "entry[\($i)]: invalid severity_override \($e.severity_override|tojson)"
       else empty end),
      (if ($e|has("expires_at"))
          and ((($e.expires_at|type) != "string")
               or (($e.expires_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))|not))
       then "entry[\($i)]: expires_at must be an ISO date (YYYY-MM-DD)"
       else empty end),
      (if ($e|has("note")) and (($e.note|type) != "string")
       then "entry[\($i)]: note must be a string" else empty end),
      (if ($e|has("tracking_issue"))
          and ((($e.tracking_issue|type) != "string")
               or (($e.tracking_issue|test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$"))|not))
       then "entry[\($i)]: tracking_issue must look like owner/repo#N"
       else empty end)
    ) end
  ] | .[]
' <<<"$BASELINE_JSON")"

if [[ -n "$SCHEMA_ERRORS" ]]; then
  echo "error: baseline violates hypatia-baseline.schema.json:" >&2
  echo "$SCHEMA_ERRORS" >&2
  exit 2
fi

# Pre-filter baseline: drop expired entries (>=today).
ACTIVE_BASELINE="$(jq --arg today "$TODAY" '
  map(select((.expires_at // "9999-12-31") >= $today))
' <<<"$BASELINE_JSON")"

EXPIRED_COUNT="$(jq 'length' <<<"$BASELINE_JSON")"
ACTIVE_COUNT="$(jq 'length' <<<"$ACTIVE_BASELINE")"
EXPIRED_COUNT=$((EXPIRED_COUNT - ACTIVE_COUNT))

# Match each finding against the active baseline. Returns the matched
# baseline entry (or null) for each finding.
#
# Both documents reach jq as FILES (`--slurpfile`), never as `--argjson`
# values: one argument string is capped by the kernel (MAX_ARG_STRLEN,
# 128 KiB on Linux), and a scan of about 350 KB ended here with "Argument
# list too long", exit 126: a red job that named no finding.
ACTIVE_FILE="$(mktemp)"
trap 'rm -f "$ACTIVE_FILE"' EXIT
printf '%s\n' "$ACTIVE_BASELINE" > "$ACTIVE_FILE"
ANNOTATED="$(jq -n \
  --slurpfile findings_doc "$FINDINGS_FILE" \
  --slurpfile baseline_doc "$ACTIVE_FILE" '
  $findings_doc[0] as $findings | $baseline_doc[0] as $baseline |
  # Tokenise the two supported wildcards; every other character is literal.
  # No sentinel substitution: a real filename may contain DOUBLESTAR.
  def glob_regex:
    [scan("\\*\\*|\\*|[^*]")
     | if . == "**" then ".*"
       elif . == "*" then "[^/]*"
       elif inside(".\\+?^$()[]{}|") then "\\" + .
       else . end]
    | "\\A" + join("") + "\\z";
  # Two captures are essential here:
  #   `f as $finding` — without this, references like `f.file` inside the
  #   select() get re-evaluated against the current baseline entry (the
  #   re-bound `.`), not the finding. Binding $finding once captures the
  #   finding before we enter the map(select()) over the baseline.
  #
  #   `(.file_pattern? // null) as $pat` — inside `test(arg)` the dot
  #   rebinds to the input of test ($finding.file, a string), so
  #   referencing `.file_pattern` there would error with "Cannot index
  #   string". Capture the entry pattern first, then reference $pat
  #   inside the test() regex argument.
  # Hypatia emitted `warn` for advisory findings until hypatia#895
  # (2026-10-01), which now emits them as `medium`. Normalize only this
  # historical transition; all other severity labels remain distinct.
  def sev_tier: if . == "warn" then "medium" else . end;
  def match_entry(f):
    f as $finding
    | $baseline
    | map(select(
        (.severity | sev_tier) == ($finding.severity | sev_tier)
        # `rule_module` is a string OR a list of strings.
        #
        # ⚠ THE LIST FORM EXISTS BECAUSE ONE DEFECT CAN BE EMITTED BY TWO
        # MODULES. Hypatia raises `invalid_actions_lock` from BOTH
        # `workflow_audit` and `workflow_hardening` for a single desynced
        # lockfile. Under exact string equality an acknowledgement could
        # only ever name one of them, so the other stayed unsuppressed and
        # went on blocking — and it did, on `main`. The symptom is
        # especially misleading: the entry looks correct, the file matches,
        # the severity matches, and the finding is still kept.
        #
        # Normalising to a list here rather than duplicating the entry keeps
        # ONE acknowledgement per defect, which is what `expires_at` and
        # `tracking_issue` are actually about. Two entries for one defect
        # means two expiry dates for one decision.
        and (
          (.rule_module | if type == "array" then . else [.] end)
          | any(. == $finding.rule_module)
        )
        and .type == $finding.type
        and (
          (.file? // null) == $finding.file
          or (
            (.file_pattern? // null) as $pat
            | $pat != null
            and ($finding.file | test(
              $pat
              | glob_regex
            ))
          )
        )
      ))
    | first // null;

  $findings
  | map(
      . as $f
      | match_entry(.) as $m
      | if $m == null then
          . + {baseline_status: "new"}
        else
          . + {
            baseline_status: "acknowledged",
            baseline_note: ($m.note // null),
            baseline_tracking_issue: ($m.tracking_issue // null)
          }
          | if $m.severity_override then
              .severity = $m.severity_override
              | .baseline_status = "downgraded"
            else
              .
            end
        end
    )
')"

# Split into kept (will be evaluated by the gate) and suppressed (silently
# acknowledged, surfaced only in summary).
KEPT="$(jq '[.[] | select(.baseline_status != "acknowledged")]' <<<"$ANNOTATED")"
SUPPRESSED="$(jq '[.[] | select(.baseline_status == "acknowledged")]' <<<"$ANNOTATED")"

# Severity rank for blocking decision.
# Unknown severities are treated as critical to fail-safe.
rank() {
  case "$1" in
    critical) echo 5 ;;
    high)     echo 4 ;;
    medium|warn) echo 3 ;;
    low)      echo 2 ;;
    info|informational) echo 1 ;;
    advisory) echo 0 ;;
    *)        echo 5 ;;  # Unknown severity → critical rank
  esac
}

# The advisory class: see the header. A kept finding of the class is
# reported and never counted. The one jq definition is shared by the count
# below and by the annotations at the end, so they cannot disagree.
# shellcheck disable=SC2016  # a jq program: `$s` is jq's variable, not the shell's
ADVISORY_DEF='def advisory_class:
  .advisory == true and
  ((.severity // "") as $s
   | ["medium", "warn", "low", "info", "informational", "advisory"] | index($s) != null);'
GATED_SEVERITIES="$(jq -r "$ADVISORY_DEF"' .[] | select(advisory_class | not) | .severity' <<<"$KEPT")"
ADVISORY_COUNT="$(jq "$ADVISORY_DEF"' [.[] | select(advisory_class)] | length' <<<"$KEPT")"

THRESHOLD_RANK="$(rank "$BLOCKING_THRESHOLD")"
MAX_KEPT_RANK=0
BLOCKING_COUNT=0  # kept findings at or above the threshold (the gate message names these, not all kept)
while IFS= read -r sev; do
  [[ -n "$sev" ]] || continue
  r="$(rank "$sev")"
  if (( r > MAX_KEPT_RANK )); then MAX_KEPT_RANK=$r; fi
  if (( r >= THRESHOLD_RANK )); then BLOCKING_COUNT=$((BLOCKING_COUNT + 1)); fi
done <<<"$GATED_SEVERITIES"

KEPT_COUNT="$(jq 'length' <<<"$KEPT")"
SUPPRESSED_COUNT="$(jq 'length' <<<"$SUPPRESSED")"
TOTAL_COUNT="$(jq 'length' <<<"$FINDINGS_JSON")"

# Write summary if running inside Actions.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Hypatia baseline filter"
    echo
    echo "| | Count |"
    echo "|---|---|"
    echo "| Total findings | $TOTAL_COUNT |"
    echo "| Acknowledged by baseline | $SUPPRESSED_COUNT |"
    echo "| Remaining (kept for gate) | $KEPT_COUNT |"
    echo "| Advisory class (reported, never gating) | $ADVISORY_COUNT |"
    echo "| Expired baseline entries | $EXPIRED_COUNT |"
    echo
    echo "Mode: \`$MODE\` · Blocking threshold: \`$BLOCKING_THRESHOLD\`"
    if (( EXPIRED_COUNT > 0 )); then
      echo
      echo ":warning: $EXPIRED_COUNT baseline entries are past their \`expires_at\` and were ignored."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Always emit the annotated findings so downstream steps can use them.
# Derived from $ANNOTATED on stdin, not passed as arguments (see above).
jq '{
  findings_kept: [.[] | select(.baseline_status != "acknowledged")],
  findings_suppressed: [.[] | select(.baseline_status == "acknowledged")]
}' <<<"$ANNOTATED"

# Gate decision.
if [[ "$MODE" == "advisory" ]]; then
  exit 0
fi

if (( MAX_KEPT_RANK >= THRESHOLD_RANK )); then
  kept_note="$KEPT_COUNT kept in total"
  if (( ADVISORY_COUNT > 0 )); then kept_note+=", $ADVISORY_COUNT advisory and never gating"; fi
  echo "::error::Gate failed: $BLOCKING_COUNT unfiltered finding(s) at or above '$BLOCKING_THRESHOLD' ($kept_note)." >&2
  # ⚠ NAME THE FINDINGS. The summary line above says how many; it does not say
  # which, and the job log is not always readable (progress-log retention, a
  # fork PR, an API that returns EOF). The annotation API is, and it is the only
  # channel that survives into the pull request's Files-changed view — so every
  # finding that caused the failure is emitted as its own annotation. Without
  # this, diagnosing a red baseline gate means reproducing the scanner locally,
  # which is exactly the work the gate exists to avoid.
  printf '%s' "$ANNOTATED" | jq -r --arg th "$BLOCKING_THRESHOLD" "$ADVISORY_DEF"'
    def rank: {critical: 5, high: 4, medium: 3, warn: 3, low: 2, info: 1, informational: 1}[.] // 0;
    ($th | rank) as $min
    | .[]
    | select((.baseline_status // "new") == "new")
    | select(advisory_class | not)
    | select((.severity | rank) >= $min)
    | "::error file=\(.file // "hypatia"),line=\(.line // 1),title=\(.rule_module)/\(.type)::unfiltered \(.severity) finding \(.rule_module)/\(.type) in \(.file // "(no file)") -- add it to .hypatia-baseline.json with a note, or fix it"
  ' >&2 || true
  exit 1
fi

exit 0
