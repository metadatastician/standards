#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# test_governance_reusable_shape.sh — structural guards on
# .github/workflows/governance-reusable.yml (spec 2026-09-02-cicd-regularisation
# §6.2, §6.4; PR 2a). These are the properties a red MUST be able to name:
#
#   1. CONTEXT FREEZE: the set of reusable job `name:` values is exactly the
#      frozen list. Every live ruleset types "<caller job id> / <job name>"; a
#      rename turns that context into a phantom on ~350 repos. Adding a job is
#      allowed (it adds a context); renaming or removing one is not, until the
#      applier (step 3) derives contexts from emitted check-runs.
#   2. Every job honours `inputs.runs-on` (no hardcoded runner).
#   3. `actions-lock-verify` is its own job, runs the tested gate script, and
#      checks standards out at an explicit reviewed helper SHA, never
#      at a floating `main`.
#   4. The lock check no longer hides inside workflow-lint.
#   5. `continue-on-error: true` appears only in the jobs listed as advisory or
#      on a fetch step whose absence a later step turns into ::error.
#   6. Every advisory job name is excluded from ruleset derivation via
#      config/rulesets/gates.json never_required_contexts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/.github/workflows/governance-reusable.yml"
G="$ROOT/config/rulesets/gates.json"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# job block extractor: lines of job <id> (from "  <id>:" to the next "  <id>:")
job_block() { awk -v id="$1" '$0=="  "id":" {p=1; print; next} p && /^  [a-zA-Z_][a-zA-Z0-9_-]*:$/ {exit} p {print}' "$F"; }

# Restrict job discovery to jobs: so workflow_call is not counted as a job.
job_ids() { sed -n '/^jobs:/,$p' "$F" | grep -oP '^  \K[a-zA-Z_][a-zA-Z0-9_-]*(?=:$)'; }

# 1. context freeze
FROZEN="Check Workflow Staleness
Allowlist Preflight
Live Actions policy (credentialed advisory)
Validate Hypatia Baseline
Language / package anti-pattern policy
Guix packaging policy (Nix retired)
Security policy checks
Code quality + docs
Well-Known (RFC 9116 + RSR)
Workflow security linter
Actions lockfile verify
Trusted-base reduction policy
Licence consistency
Exemption ratchet
Debt ratchet
UUID v7 conformance
UUID v8 conformance
No new A2ML
Existing A2ML (advisory)
JS runtimes — environment provisions Bun first
JS runtimes — \${{ matrix.runtime }}"
ACTUAL=$(grep -P '^    name: ' "$F" | sed 's/^    name: //')
if [ "$(printf '%s' "$FROZEN" | sort)" = "$(printf '%s' "$ACTUAL" | sort)" ]; then ok "job names match the frozen context list ($(printf '%s\n' "$ACTUAL" | wc -l) jobs)"
else bad "job names drifted from the frozen list — renames create phantom contexts estate-wide"; diff <(printf '%s\n' "$FROZEN" | sort) <(printf '%s\n' "$ACTUAL" | sort); fi

# 2. runs-on
if grep -q 'runs-on: ubuntu-latest' "$F"; then bad "hardcoded runs-on present (inputs.runs-on ignored)"; else ok "every job uses inputs.runs-on"; fi
njobs=$(job_ids | wc -l); nro=$(grep -c 'runs-on: ${{ inputs.runs-on }}' "$F")
[ "$njobs" -eq "$nro" ] && ok "runs-on count ($nro) equals job count ($njobs)" || bad "runs-on count $nro != job count $njobs"

# 3. actions-lock-verify job
B=$(job_block actions-lock-verify)
[ -n "$B" ] && ok "actions-lock-verify job exists" || bad "actions-lock-verify job missing"
printf '%s' "$B" | grep -q 'check-actions-lock-gate.sh' && ok "actions-lock-verify runs the tested gate script" || bad "actions-lock-verify does not run check-actions-lock-gate.sh"
printf '%s' "$B" | grep -Eq 'ref: ([0-9a-f]{40}|\$\{\{ job\.workflow_sha \}\})$' && ok "actions-lock-verify pins standards at an immutable commit" || bad "actions-lock-verify standards checkout not pinned to an immutable commit"
printf '%s' "$B" | grep -q 'ref: main' && bad "actions-lock-verify floats a standards checkout at main" || ok "actions-lock-verify has no floating ref: main"
printf '%s' "$B" | grep -q 'ACTIONS_LOCK_VERIFIER=' && ok "gate is pointed at the fetched verifier" || bad "ACTIONS_LOCK_VERIFIER not set for the gate"

# 4. workflow-lint no longer carries the lock step
W=$(job_block workflow-lint)
printf '%s' "$W" | grep -v '^ *#' | grep -q -- '--verify-local' && bad "workflow-lint still runs the lock verifier (should be its own context)" || ok "lock verification moved out of workflow-lint"
printf '%s' "$W" | grep -q 'LOCK_SCRIPT' && bad "workflow-lint still copies the lock verifier" || ok "workflow-lint no longer fetches update-actions-lock.sh"

# 5. continue-on-error allow-list
ALLOWED="language-policy quality workflow-lint"
viol=0
for id in $(job_ids); do
  case " $ALLOWED " in *" $id "*) continue;; esac
  if job_block "$id" | grep -q 'continue-on-error: true'; then echo "  continue-on-error in gate job: $id"; viol=1; fi
done
[ "$viol" -eq 0 ] && ok "continue-on-error confined to {$ALLOWED}" || bad "continue-on-error leaked into a gate job"

# 6. advisory jobs excluded from derivation
for n in "Live Actions policy (credentialed advisory)" "Code quality + docs" "Allowlist Preflight"; do
  jq -e --arg n "$n" '.never_required_contexts | index($n)' "$G" >/dev/null && ok "gates.json never_required_contexts has '$n'" || bad "gates.json never_required_contexts lacks '$n'"
done

echo; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
