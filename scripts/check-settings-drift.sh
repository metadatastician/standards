#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
set -eo pipefail
#
# For docs/REPO-SETTINGS.adoc § "Private repositories on a Free account",
# this report-only check skips security_and_analysis on private repositories.
# It neither applies settings nor classifies them as N/A.

# check-settings-drift.sh — detect estate settings moving without anyone noticing.
#
# ── The fault this catches ─────────────────────────────────────────────────
# Repository SETTINGS are not in git. Nothing reviews them, nothing diffs them,
# and a change leaves no artefact — no commit, no PR, no run. The estate is
# 97–100% compliant with `config/settings/repo.json` at any given moment, so
# re-applying the canon gains almost nothing. What is missing is anything that
# NOTICES when a setting moves.
#
# Measured 2026-09-14, the day this was written: the Actions allowlist on 239
# repositories changed from `allowed_actions=selected` with an EMPTY
# `patterns_allowed` and `verified_allowed=false`, to a 92-pattern allowlist
# with `verified_allowed=true` — between a census and the authorised write that
# was meant to fix it. The fix had already happened. Nobody could say when, by
# whom, or whether it was deliberate, because no instrument was watching.
# That is the whole argument for this script.
#
# ── Why an EMPTY allowlist is the highest-value check here ─────────────────
# An empty `patterns_allowed` refuses every third-party action, INCLUDING
# transitively through a reusable workflow, because actions are judged against
# the CALLER repo's allow-list. The run then dies at `startup_failure` with
# `jobs.total_count == 0` and emits NO check run — so a required context never
# reports and the repo looks GREENER than a healthy one. A settings change can
# therefore disarm CI estate-wide while every dashboard stays clean.
#
# ── Calibration: what a hit does and does not prove ────────────────────────
# A reported line means the live setting differs from canon. It does NOT prove
# anything is broken:
#   * `per_repo_deltas_allowed` keys are legitimately per-repo and are skipped.
#   * `security_and_analysis` is unavailable on private repos of a Free account;
#     canon itself carries `repo_private_overrides` for this. Skipped on private.
#   * An empty allowlist harms only repos that actually CALL a third-party
#     action. Measured 2026-09-14: of 61 such repos, 48 were genuinely broken
#     and 13 were CLEAR. This script reports the setting; it does not claim the
#     repo is dead.
# Conversely a CLEAN result is not proof CI is healthy — a startup failure can
# be EVENT-SPECIFIC and invisible in every setting and every file. Proven the
# same day: `sanctify-php` run 34768365915 (`push`, head a25c8edb) died with
# jobs=0, while run 34895780522 (`workflow_dispatch`, the SAME head a25c8edb)
# started 7 jobs and mirrored successfully. Identical bytes, identical settings.
#
# ── The subset rule (do not "fix" this into an equality check) ─────────────
# GitHub ECHOES BACK defaults it was never sent. Comparing canon to live by
# equality produces permanent false drift on keys nobody ever set. Every
# comparison here is CANON ⊆ LIVE, one key at a time. The same trap already
# cost two hard 422s when `config/rulesets/base.json` was PUT verbatim.
#
# ── What this is NOT ───────────────────────────────────────────────────────
# It REPORTS ONLY. It never writes a setting. Unattended cross-repo mutation is
# a human decision, and settings are exactly where that matters most.
#
# Usage:  check-settings-drift.sh [--owner OWNER] [--canon PATH] [--limit N]
# Output: TSV — repo <TAB> key <TAB> expected <TAB> actual
# Exit:   0 = no drift   1 = drift found   2 = usage / environment error

OWNER="hyperpolymath"
CANON="config/settings/repo.json"
LIMIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --canon) CANON="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '5,70p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v gh  >/dev/null || { echo "gh not found"  >&2; exit 2; }
command -v jq  >/dev/null || { echo "jq not found"  >&2; exit 2; }
[ -f "$CANON" ] || { echo "canon not found: $CANON" >&2; exit 2; }

DELTAS=$(jq -r '(.per_repo_deltas_allowed // [])[]' "$CANON" | tr '\n' ' ')
drift=0

emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; drift=1; }

# CANON ⊆ LIVE for the flat repo block, skipping allowed per-repo deltas.
check_repo_block() {
  local repo="$1" live="$2" private="$3"
  local key exp act
  while IFS=$'\t' read -r key exp; do
    [ -z "$key" ] && continue
    case " $DELTAS " in *" $key "*) continue ;; esac
    act=$(echo "$live" | jq -r --arg k "$key" '.[$k] // "ABSENT" | tostring')
    [ "$act" = "$exp" ] || emit "$repo" "$key" "$exp" "$act"
  done < <(jq -r '.repo | to_entries[] | select(.value|type != "object")
                 | "\(.key)\t\(.value|tostring)"' "$CANON")

  # security_and_analysis is ABSENT from LIST endpoints — it needs the per-repo
  # GET, which $live already is. Skipped on private: canon's own
  # repo_private_overrides records that secret scanning is unavailable there.
  if [ "$private" != "true" ]; then
    while IFS=$'\t' read -r key exp; do
      [ -z "$key" ] && continue
      act=$(echo "$live" | jq -r --arg k "$key" '.security_and_analysis[$k].status // "ABSENT"')
      [ "$act" = "$exp" ] || emit "$repo" "security_and_analysis.$key" "$exp" "$act"
    done < <(jq -r '.repo.security_and_analysis | to_entries[]
                   | "\(.key)\t\(.value.status)"' "$CANON")
  fi
}

check_actions() {
  local repo="$1" perms sel exp_allowed n verified pinning
  perms=$(gh api "repos/$OWNER/$repo/actions/permissions" 2>/dev/null) || return 0

  exp_allowed=$(jq -r '.actions_permissions.allowed_actions' "$CANON")
  act=$(echo "$perms" | jq -r '.allowed_actions // "ABSENT"')
  # `all` is MORE permissive than canon, not drift toward breakage — report it
  # distinctly so a reader is never told a working repo is broken.
  if [ "$act" != "$exp_allowed" ]; then
    emit "$repo" "actions.allowed_actions" "$exp_allowed" "$act"
  fi

  pinning=$(echo "$perms" | jq -r '.sha_pinning_required // "ABSENT"')
  exp=$(jq -r '.actions_permissions.sha_pinning_required|tostring' "$CANON")
  [ "$pinning" = "$exp" ] || emit "$repo" "actions.sha_pinning_required" "$exp" "$pinning"

  # THE HIGH-VALUE CHECK: selected + empty patterns disarms CI silently.
  if [ "$act" = "selected" ]; then
    sel=$(gh api "repos/$OWNER/$repo/actions/permissions/selected-actions" 2>/dev/null) || return 0
    n=$(echo "$sel" | jq -r '(.patterns_allowed // []) | length')
    [ "$n" = "0" ] && emit "$repo" "actions.patterns_allowed" "non-empty" "EMPTY (refuses all third-party actions, incl. via reusables)"
    verified=$(echo "$sel" | jq -r '.verified_allowed // "ABSENT"')
    [ "$verified" = "false" ] && emit "$repo" "actions.verified_allowed" "true" "false (refuses even Marketplace-verified actions)"
  fi

  wf=$(gh api "repos/$OWNER/$repo/actions/permissions/workflow" 2>/dev/null) || return 0
  for k in default_workflow_permissions can_approve_pull_request_reviews; do
    exp=$(jq -r --arg k "$k" '.actions_workflow_permissions[$k]|tostring' "$CANON")
    act=$(echo "$wf" | jq -r --arg k "$k" '.[$k] // "ABSENT" | tostring')
    [ "$act" = "$exp" ] || emit "$repo" "actions_workflow.$k" "$exp" "$act"
  done
}

# Mirror forge enablement. Each forge job in mirror-reusable.yml is gated on
# `if: vars.<FORGE>_MIRROR_ENABLED == 'true'`, so a false variable makes the job
# SKIP — and a run whose every forge job skipped reports GREEN while backing up
# nowhere. Measured 2026-09-14 across the mirror fleet: ZERO repos had all seven
# enabled, and roughly a third had NONE. This is checked only where the repo
# actually calls mirror.yml, because the variable is meaningless otherwise.
FORGES="GITLAB BITBUCKET CODEBERG SOURCEHUT DISROOT GITEA RADICLE"
check_mirror_vars() {
  local repo="$1" vars f v
  gh api "repos/$OWNER/$repo/contents/.github/workflows/mirror.yml" >/dev/null 2>&1 || return 0
  vars=$(gh api "repos/$OWNER/$repo/actions/variables?per_page=100" 2>/dev/null) || return 0
  for f in $FORGES; do
    v=$(echo "$vars" | jq -r --arg n "${f}_MIRROR_ENABLED" '.variables[]|select(.name==$n)|.value' 2>/dev/null)
    [ "$v" = "true" ] || emit "$repo" "vars.${f}_MIRROR_ENABLED" "true" "${v:-ABSENT} (forge job SKIPS; run can report GREEN while mirroring nowhere)"
  done
}

printf 'repo\tkey\texpected\tactual\n'

# NOTE: process substitution, NOT a pipe. `gh repo list | while read` runs the
# loop in a SUBSHELL, so every `drift=1` set by emit() is discarded when the
# subshell exits and the script always reports success — a drift detector that
# can never report drift. That is the same shape as the estate's recurring
# "guard asks a different question than its consumer" fault, so it is spelled
# out here rather than left to be reintroduced by a later tidy-up.
i=0
while read -r repo; do
  i=$((i+1))
  [ "$LIMIT" != "0" ] && [ "$i" -gt "$LIMIT" ] && break
  live=$(gh api "repos/$OWNER/$repo" 2>/dev/null) || continue
  private=$(echo "$live" | jq -r '.private')
  check_repo_block  "$repo" "$live" "$private"
  check_actions     "$repo"
  check_mirror_vars "$repo"
done < <(gh repo list "$OWNER" --no-archived --limit 1000 --json name --jq '.[].name')

exit $drift
