#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Static regression contract for the reusable governance boundaries.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GOVERNANCE="$ROOT/.github/workflows/governance-reusable.yml"
FOCUSED="$ROOT/.github/workflows/allowlist-preflight-reusable.yml"
DEED="$ROOT/.github/workflows/deed-conformance.yml"
FORK="$ROOT/.github/workflows/fork-governance-reusable.yml"
K9="$ROOT/.github/workflows/k9-conformance.yml"
RSR_SEED="$ROOT/9-archive/rhodium-standard-repositories/.github/workflows/allowlist-preflight.yml"
LOCK_HELPER="$ROOT/scripts/update-actions-lock.sh"
LOCK_GATE="$ROOT/scripts/check-actions-lock-gate.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# `set -e` + a command substitution is a silence trap: when the grep matches
# nothing it exits 1 and the assignment terminates the script BEFORE `fail()`
# can name the missing assertion — a contract test that cannot say why it
# failed is the same vacuous class it exists to catch. Capture, then assert.
helper_checkout="$(grep -F -A 18 -- '- name: Checkout the pinned Standards policy helpers' "$GOVERNANCE" || true)"
[ -n "$helper_checkout" ] ||
  fail "governance workflow has no step named 'Checkout the pinned Standards policy helpers'"
# Immutable either way: a literal 40-hex commit, or job.workflow_sha (the
# reusable's own commit, i.e. exactly the commit the caller pinned). A literal
# is still allowed by SHAPE — but it is a third pin that can rot, which is what
# happened for six weeks to 317101e03b8f, and check-standards-helper-pins.sh is
# what judges currency. This contract test judges that the step cannot float.
# shellcheck disable=SC2016
printf '%s\n' "$helper_checkout" | grep -Eq '^[[:space:]]*ref:[[:space:]]*(\$\{\{ job\.workflow_sha \}\}|[0-9a-f]{40})[[:space:]]*$' ||
  fail "governance helpers are not fetched from an immutable commit or job.workflow_sha"
if printf '%s\n' "$helper_checkout" | grep -Eq '^[[:space:]]*ref:[[:space:]]*(main|master|HEAD)[[:space:]]*$'; then
  fail "governance helper execution still follows a moving ref"
fi
# github.workflow_sha / github.sha name the CALLER's commit inside a called
# reusable, so they can never serve as this repository's helper source.
# shellcheck disable=SC2016
if printf '%s\n' "$helper_checkout" | grep -Eq 'ref:.*\$\{\{ github\.(workflow_sha|sha)'; then
  fail "governance helper source is the caller's commit, not this repository's"
fi

# The assertions above cover the step named `Checkout the pinned Standards
# policy helpers` — the DUPKEY helpers. The lock gate is staged by a DIFFERENT
# step, `Checkout standards for the lock gate`, and until now nothing in this
# file named it: the two steps share the nouns "checkout", "pinned" and
# "standards", so a name-match guard written for one proves nothing about the
# other. That gap is how the lock-gate pin sat at a pre-standards#946 commit
# while this test stayed green. Bind an assertion to the step itself.
#
# `grep -A N` cannot delimit the block: it is 19 lines today, so a fixed N is
# either short of the `ref:` or long enough to reach the NEXT step's `ref:` and
# assert against the wrong pin. Take the range from `- name:` to `- name:`.
lock_gate_block="$(awk '
  index($0, "- name: Checkout standards for the lock gate") { inblock = 1; indent = match($0, /-/); next }
  inblock && /^[[:space:]]*- name:/ && match($0, /-/) == indent { exit }
  inblock { print }
' "$GOVERNANCE")"
[ -n "$lock_gate_block" ] ||
  fail "governance workflow has no step named 'Checkout standards for the lock gate'"
# Immutable either way: a literal 40-hex commit, or job.workflow_sha (the
# reusable's own commit, i.e. exactly the caller's pin). Never a branch, and
# never github.workflow_sha / github.sha, which name the CALLER's commit.
printf '%s\n' "$lock_gate_block" | grep -Eq '^[[:space:]]*ref:[[:space:]]*([0-9a-f]{40}|\$\{\{ job\.workflow_sha \}\})[[:space:]]*$' ||
  fail "the lock gate is not staged from an immutable 40-hex commit or job.workflow_sha"
if printf '%s\n' "$lock_gate_block" | grep -Eq '^[[:space:]]*ref:[[:space:]]*main[[:space:]]*$'; then
  fail "the lock gate follows moving main"
fi
# Shape is not currency: a well-formed SHA can still point at stale tooling, and
# did. The freshness predicate needs git history, so it runs as its own Self
# Test step; assert here only that it still exists and is still wired in.
[ -f "$ROOT/scripts/check-lock-gate-pin-freshness.sh" ] ||
  fail "the lock-gate pin freshness guard is missing — shape alone cannot detect a stale pin"
grep -Fq 'check-lock-gate-pin-freshness.sh' "$ROOT/.github/workflows/self-test.yml" ||
  fail "the lock-gate pin freshness guard is not executed by Self Test"

if grep -Fq 'bash scripts/update-actions-lock.sh --verify-local' "$GOVERNANCE"; then
  fail "reusable governance still assumes a consumer-local Standards helper"
fi
# The workflow no longer names `--verify-local` directly: it stages both
# helpers into RUNNER_TEMP and runs the gate, which delegates to the
# authoritative verifier. Assert that composition, and follow the
# `--verify-local` literal to where it now lives.
# RUNNER_TEMP is an asserted workflow literal.
# shellcheck disable=SC2016
grep -Fq 'ACTIONS_LOCK_VERIFIER="$RUNNER_TEMP/update-actions-lock.sh"' "$GOVERNANCE" ||
  fail "reusable governance does not point the lock gate at the staged pinned verifier"
# shellcheck disable=SC2016
grep -Fq 'bash "$RUNNER_TEMP/check-actions-lock-gate.sh"' "$GOVERNANCE" ||
  fail "reusable governance does not execute the staged pinned lock gate"
[ -f "$LOCK_GATE" ] || fail "lock gate script is missing from the pinned helper set"
# VERIFIER is an asserted script literal.
# shellcheck disable=SC2016
grep -Fq 'bash "$VERIFIER" --verify-local' "$LOCK_GATE" ||
  fail "lock gate does not delegate to the authoritative verifier with --verify-local"

for workflow in "$GOVERNANCE" "$FOCUSED"; do
  grep -Fq 'Live Actions policy (credentialed advisory)' "$workflow" ||
    fail "$workflow lacks the distinct live-policy advisory job"
  grep -Fq "if: \${{ env.GH_TOKEN == '' }}" "$workflow" ||
    fail "$workflow does not report a missing optional credential"
  grep -Fq "if: \${{ env.GH_TOKEN != '' }}" "$workflow" ||
    fail "$workflow can run the live API without a credential guard"
  # rc is an asserted workflow-script literal.
  # shellcheck disable=SC2016
  grep -Fq 'if [ "$rc" -eq 3 ]; then' "$workflow" ||
    fail "$workflow conflates API unavailability with a policy verdict"
done

# The live detector and additive updater must compare the same estate payload;
# the separately maintained tree preflight policy is not a settings payload.
for entry in "$GOVERNANCE:actions-policy-live" "$FOCUSED:live-policy"; do
  workflow=${entry%:*}; job=${entry##*:}
  live_block=$(awk -v job="$job" '
    $0 == "  " job ":" {active=1; next}
    active && /^  [a-zA-Z0-9_-]+:/ {exit}
    active {print}' "$workflow")
  grep -Fq 'config/settings/actions-allowlist.json' <<< "$live_block" ||
    fail "$workflow live-policy job does not use the estate settings payload"
  if grep -Fq '.standards-checkout/rhodium-standard-repositories/actions-allowlist/allowed-actions.json' <<< "$live_block"; then
    fail "$workflow live-policy job still checks the stale tree policy"
  fi
done
grep -Fq '$SCRIPT_DIR/../config/settings/actions-allowlist.json' "$ROOT/scripts/check-actions-policy.sh" ||
  fail "live-policy detector default differs from the updater"

grep -Eq 'uses: hyperpolymath/standards/.github/workflows/allowlist-preflight-reusable.yml@[0-9a-f]{40}$' \
  "$RSR_SEED" || fail "RSR allowlist seed is not a thin immutable reusable-workflow caller"
if grep -Eq 'raw\.githubusercontent\.com/.*/main|curl[[:space:]]' "$RSR_SEED"; then
  fail "RSR allowlist seed still downloads executable policy from moving main"
fi

grep -Fq 'when actions.lock is present, gh actions-lock is authoritative' "$LOCK_HELPER" ||
  fail "lock helper does not state the authoritative-lock contract"
if grep -Fq 'relock-sha-keys.sh' "$LOCK_HELPER"; then
  fail "lock helper still rewrites generated lock keys around legacy inline SHAs"
fi

# Repository-transfer guard: canon self-recognition must not regress to the
# pre-transfer slug alone. GitHub's immutable repository ID survives a
# transfer/rename; either known slug remains a fallback for contexts where
# an ID is unavailable. An old-slug-only branch silently makes the canon
# take the consumer path in its own repository.
for workflow in "$GOVERNANCE" "$FOCUSED" "$DEED" "$FORK" "$K9"; do
  grep -Fq '1116521501' "$workflow" ||
    fail "$workflow does not recognise the canon by immutable repository ID"
  grep -Fq 'metadatastician/standards' "$workflow" ||
    fail "$workflow does not recognise the transferred standards slug"
  if grep -Eq "github\\.repository (==|!=) 'hyperpolymath/standards'( \\}\\})?$" "$workflow"; then
    fail "$workflow still has an old-slug-only repository identity branch"
  fi
  # shellcheck disable=SC2016
  if grep -Fq 'if [ "$GITHUB_REPOSITORY" = hyperpolymath/standards ]; then' "$workflow"; then
    fail "$workflow still has an old-slug-only shell identity branch"
  fi
done

# ── No third pin by default ──────────────────────────────────────────────
# MEASURED 2026-10-31: three steps staged helpers from the literal
# 317101e03b8f (2026-09-14) while main had moved 194 files under scripts/.
# A literal pin is permitted only where a comment records the scoped path it
# was chosen for; the scorecard reconciler is the one such site. Anything else
# must be job.workflow_sha so it cannot rot.
literals="$(grep -nE '^[[:space:]]*ref:[[:space:]]*[0-9a-f]{40}' "$GOVERNANCE" || true)"
unexplained="$(printf '%s\n' "$literals" | grep -vE '^(\s*)$' || true)"
if [ -n "$unexplained" ]; then
  fail "governance still stages a helper from a literal commit; use \${{ job.workflow_sha }} (a literal goes stale silently — standards#946/#1119/#1290's sibling class):
$unexplained"
fi

# The job workflow-identity properties are unavailable on GHES, where the
# expression resolves EMPTY and actions/checkout then follows the default
# branch. Each job that stages helpers from job.workflow_sha must assert the
# value before using it.
for job in 'language-policy' 'workflow-lint'; do
  block="$(awk -v id="$job" '$0=="  "id":" {p=1; next} p && /^  [a-zA-Z0-9_-]+:$/ {exit} p {print}' "$GOVERNANCE")"
  printf '%s\n' "$block" | grep -Fq "Assert this reusable's own commit resolved" ||
    fail "job '$job' stages helpers from job.workflow_sha without asserting it resolved"
  printf '%s\n' "$block" | grep -Fq "SELF_WORKFLOW_SHA" ||
    fail "job '$job' assertion does not read job.workflow_sha"
done

# The floating helper checkouts the same measurement found must stay fixed:
# a branch ref for a standards helper means one push to standards changes the
# behaviour of every already-pinned caller.
for workflow in "$GOVERNANCE" "$ROOT/.github/workflows/changelog-reusable.yml" \
                "$ROOT/.github/workflows/readme-derive-reusable.yml" \
                "$ROOT/.github/workflows/fork-governance-reusable.yml"; do
  if grep -nE '^[[:space:]]*-?[[:space:]]*ref:[[:space:]]*(main|master|HEAD)[[:space:]]*$' "$workflow" >/dev/null; then
    fail "$workflow still stages a standards helper from a moving branch"
  fi
  if grep -nE '^[[:space:]]*default:[[:space:]]*"?(main|master)"?[[:space:]]*$' "$workflow" >/dev/null; then
    fail "$workflow still defaults a standards source input to a moving branch"
  fi
done
grep -Fq 'scripts/check-standards-helper-pins.sh' "$ROOT/.github/workflows/self-test.yml" ||
  fail "the standards helper pin guard is not executed by Self Test"

echo "PASS: reusable governance uses one pinned implementation with focused and suite entry points"
