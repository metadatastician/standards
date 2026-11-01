#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# governance-canary-test.sh — do BOTH halves of governance work for this
# source, in the order the runner does them?
#
#   1. STARTUP. Would every caller of this source survive `Set up job`?
#      That is the half that failed silently and estate-wide: a record the
#      runner rejects kills the run before any policy step, so the failure
#      carries no finding and reads as "absent" rather than "failed".
#      MEASURED: metadatastician/svalinn run 40108154356 on standards
#      fad242d3 — 12 governance jobs, 1 step each, all dead.
#
#   2. POLICY. Given a startup-clean source, do the gates it ships actually
#      EXECUTE, and do they still fail the thing they exist to fail?
#      A setup-only green is not governance; a gate that cannot fail is not a
#      gate. Both directions are exercised on a canary consumer whose content
#      is pinned by digest in scripts/tests/fixtures/governance-canary/
#      MANIFEST.sha256 — if that fixture drifts, this test says so instead of
#      quietly measuring something else.
#
# WHAT THIS IS NOT
#   * Not a substitute for a run on GitHub. It reimplements the STARTUP
#     predicate from the contract (representation + closure + `uses:`
#     coverage) — the same predicate the measured failure violated — but it
#     cannot prove GitHub will accept an edit of that predicate.
#   * Not a full lock verifier: remote existence, tag movement and the
#     allowlist are other gates' jobs (check-action-pins-resolve.sh,
#     check-actions-lock-gate.sh, check-allowed-actions.sh).
#   * Not a consumer deployment. Consumer repinning is the post-publish step
#     in docs/GOVERNANCE-STARTUP-REPAIR.adoc.
#
# USAGE
#   governance-canary-test.sh [STANDARDS_REF]
#
#   With no argument the WORKING TREE is the source under test (the PR's own
#   merge preview, which is what a caller will pin). With a 40-hex ref or any
#   git revision, that commit is extracted with `git archive` and tested
#   instead — the post-publish check:
#
#       bash scripts/tests/governance-canary-test.sh <published-sha>
#
# EXIT
#   0 = startup clean AND both policy directions behaved
#   1 = a phase failed (named: STARTUP or POLICY)
#   2 = the canary could not be run (no yq/jq, unusable ref, missing fixture)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REF="${1:-}"
FIXTURE="$ROOT/scripts/tests/fixtures/governance-canary"

command -v yq >/dev/null 2>&1 || { echo 'SKIP(2): yq not installed' >&2; exit 2; }
yq --version 2>/dev/null | grep -q mikefarah || { echo 'SKIP(2): mikefarah yq v4 required' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'SKIP(2): jq not installed' >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── The source under test ────────────────────────────────────────────────
SRC="$ROOT"
if [ -n "$REF" ]; then
  if ! git -C "$ROOT" rev-parse --verify --quiet "$REF^{commit}" >/dev/null; then
    echo "SKIP(2): '$REF' is not a commit in this clone" >&2
    exit 2
  fi
  SRC="$tmp/standards"
  mkdir -p "$SRC"
  git -C "$ROOT" archive "$REF" | tar -x -C "$SRC" 2>/dev/null ||
    { echo "SKIP(2): could not extract $REF" >&2; exit 2; }
  echo "source under test: $REF ($(git -C "$ROOT" rev-parse --short=12 "$REF"))"
  # The CONSUMER FIXTURE must come from the same revision as the source. Left
  # pointing at the working tree, one published SHA produced different verdicts
  # over time — and a commit could be approved using consumer inputs that were
  # never part of it.
  FIXTURE="$SRC/scripts/tests/fixtures/governance-canary"
else
  echo "source under test: working tree ($ROOT)"
fi
[ -f "$FIXTURE/MANIFEST.sha256" ] ||
  { echo "SKIP(2): canary fixture missing: $FIXTURE (it must be part of the source under test)" >&2; exit 2; }
echo "consumer fixture: ${FIXTURE#"$tmp"/}"

pass=0; fail=0; skipped=0
ok()   { echo "PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }
skip() { echo "SKIP: $1"; skipped=$((skipped + 1)); }

# A source that does not ship the control being exercised is a FINDING, not a
# pass and not a crash: a caller pinned there gets no such control. Named so
# the difference between "behaves" and "predates the guard" is legible.
have() { [ -f "$SRC/$1" ]; }

# ═══ PHASE 1 — STARTUP ═══════════════════════════════════════════════════
echo
echo "── STARTUP: would a caller survive 'Set up job'? ──"
STARTUP_RC=0

# 1a. every `uses:` has a record (the coverage half)
cov=0
out="$(cd "$SRC" && INPUT_PATH=. bash .githooks/validate-actions-lock.sh 2>&1)" || cov=$?
if [ "$cov" -eq 0 ]; then
  ok "every SHA-pinned uses: is keyed in this source's own actions.lock"
else
  printf '%s\n' "$out" | sed 's/^/    /'
  bad "uses: coverage failed (exit $cov) — a caller dies at startup"
  STARTUP_RC=1
fi

# 1a-bis. reached dependencies may be locked under the calling workflow or
# under the reusable's own record. check-lock-sync validates both supported
# locations; a direct record for every remote reusable call is not required.
sync=0
if ! have scripts/check-lock-sync.sh; then
  bad "this source ships no workflow lock-sync guard"
  STARTUP_RC=1
else
  out="$(bash "$SRC/scripts/check-lock-sync.sh" "$SRC/.github/workflows" 2>&1)" || sync=$?
  if [ "$sync" -eq 0 ]; then
    ok "workflow lock sync accepts both supported reusable dependency locations"
  else
    printf '%s\n' "$out" | sed 's/^/    /'
    bad "workflow lock sync failed (exit $sync)"
    STARTUP_RC=1
  fi
fi

# 1a-ter. every dependency the REVIEWED CLOSURE says is reached must still be
# locked in one of the two places the runner looks for it: this workflow's own
# entry, or the reusable record's nested `uses:`. check-lock-sync recognises a
# closure-backed entry as "referenced" (direction 2), which is what makes the
# unified-dataset-vocab#81 shape pass — but recognising an entry is not the same
# as requiring the reached dependency to be present. Delete a reusable entry and
# its record together and the lock stays closed, sync stays green, and the
# dependency is gone: the canary would still certify startup.
closure_baseline="$SRC/.github/workflows/actions-lock.closure.tsv"
if [ ! -f "$closure_baseline" ]; then
  bad "this source has no reviewed closure baseline, so Start up coverage cannot be certified against one"
  STARTUP_RC=1
else
  unlocked_reach=""
  reach_rows=0
  lockjson="$(yq -o json -I 0 '.' "$SRC/.github/workflows/actions.lock" 2>/dev/null)"
  while IFS=$'\t' read -r cwf cre ref; do
    case "$cwf" in ''|'#'*) continue ;; esac
    [ -n "$ref" ] || continue
    reach_rows=$((reach_rows + 1))
    # The two places the runner looks, and only these two: the CALLING
    # workflow's entry, or the nested `uses:` of the reusable THIS row names.
    # Scanning every record instead would accept a dependency that happens to
    # be locked for some unrelated reusable.
    locked="$(printf '%s' "$lockjson" | jq -r --arg wf "$cwf" --arg cre "$cre" --arg d "$ref" '
      ((.workflows[$wf] // []) | index($d)) != null
      or (((.dependencies // {})[$cre].uses) // [] | index($d) != null)' 2>/dev/null)"
    [ "$locked" = "true" ] || unlocked_reach="$unlocked_reach $cwf: $ref"
  done < "$closure_baseline"
  if [ "$reach_rows" -eq 0 ]; then
    bad "the reviewed closure baseline has no rows — a vacuous pass is not coverage"
    STARTUP_RC=1
  elif [ -n "$unlocked_reach" ]; then
    bad "reached dependencies recorded in NEITHER supported location (a caller dies at startup):$unlocked_reach"
    STARTUP_RC=1
  else
    ok "every reviewed reached dependency (${reach_rows} row(s)) is locked where the runner looks"
  fi
fi

# 1b. every record is one the runner accepts, and the lock is closed
contract=0
if ! have scripts/check-lock-pin-contract.sh; then
  bad "this source ships no lock-pin contract guard, so a caller pinned here has nothing enforcing it (the record-level class that killed svalinn run 40108154356)"
  STARTUP_RC=1
  contract=127
else
  out="$(cd "$SRC" && bash scripts/check-lock-pin-contract.sh .github/workflows/actions.lock 2>&1)" || contract=$?
  if [ "$contract" -eq 0 ]; then
    ok "actions.lock representation, provenance and closure are acceptable"
  else
    printf '%s\n' "$out" | sed 's/^/    /'
    bad "actions.lock contract failed (exit $contract) — the historical 'invalid lockfile pin' class"
    STARTUP_RC=1
  fi
fi

# 1c. negative controls. A canary that cannot go red proves nothing, so the
#     two measured startup killers are re-created and MUST be caught:
#     (i) a leaf whose ref repeats its own SHA (what killed svalinn);
#     (ii) a dangling closure edge (what killed palimpsest-license#177).
# The contract guard is in the source tree; run it from there so the control
# uses exactly the implementation under test.
poison_guard="$SRC/scripts/check-lock-pin-contract.sh"
# (i) the exact record shape measured at fad242d3: ref repeats the pin, on
#     the record whose rejection the runner named in the measured annotation.
if ! have scripts/check-lock-pin-contract.sh; then
  skip "negative controls need the source's own guard; this source ships none"
  pin_key=""
else
pin_key="$(yq -o json -I 0 '.' "$SRC/.github/workflows/actions.lock" |
  jq -r '.dependencies | keys[] | select(test("^actions/checkout@[0-9a-f]{40}$"))' | head -1)"
if [ -n "$pin_key" ]; then
  pin_sha="${pin_key##*@}"
  cp "$SRC/.github/workflows/actions.lock" "$tmp/lock.yml"
  awk -v key="'${pin_key}':" -v raw="'${pin_sha}'" '
    $0 == "    " key { inrec = 1; print; next }
    inrec && /^        ref: / && !done { print "        ref: " raw; done = 1; inrec = 0; next }
    { print }
  ' "$tmp/lock.yml" > "$tmp/lock.poison.yml"
  got=0
  out="$(bash "$poison_guard" "$tmp/lock.poison.yml" --self-repo metadatastician/standards 2>&1)" || got=$?
  if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF "ref repeats the commit SHA"; then
    ok "negative control: a leaf whose ref repeats its own SHA is caught ($pin_key)"
  else
    printf '%s\n' "$out" | tail -5 | sed 's/^/    /'
    bad "negative control: a raw-SHA ref was NOT caught (exit $got)"
    STARTUP_RC=1
  fi
else
  bad 'could not find a checkout record to poison — canary fixture unknown'
  STARTUP_RC=1
fi
fi

# (ii) a dangling edge: a workflows: entry naming a record that does not exist
#      (the shape that killed palimpsest-license#177 at startup).
if ! have scripts/check-lock-pin-contract.sh; then
  skip "dangling-edge control needs the source's own guard; this source ships none"
else
awk '
  /^workflows:$/ {
    print
    print "    '\''example-absent.yml'\'':"
    print "        - '\''example-absent/absent@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\''"
    next
  }
  { print }
' "$SRC/.github/workflows/actions.lock" > "$tmp/lock.dangling.yml"
got=0
out="$(bash "$poison_guard" "$tmp/lock.dangling.yml" --self-repo metadatastician/standards 2>&1)" || got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qiF "closure"; then
  ok "negative control: a dangling closure edge is caught"
else
  printf '%s\n' "$out" | tail -5 | sed 's/^/    /'
  bad "negative control: a dangling closure edge was NOT caught (exit $got)"
  STARTUP_RC=1
fi
fi

if [ "$STARTUP_RC" -eq 0 ]; then
  ok "STARTUP phase clean (both controls caught their defect)"
else
  bad "STARTUP phase not clean"
fi

# ═══ PHASE 2 — POLICY EXECUTION ══════════════════════════════════════════
echo
echo "── POLICY: do the shipped gates execute, and can they still fail? ──"
POLICY_RC=0

# The canary consumer is immutable: verify it against its recorded digests
# before measuring anything, so a drifted fixture cannot masquerade as a
# passing gate.
canary="$tmp/consumer"
cp -a "$FIXTURE/consumer" "$canary"
if (cd "$canary" && sha256sum --check --quiet "$FIXTURE/MANIFEST.sha256" >/dev/null 2>&1); then
  ok "canary consumer matches its recorded digests (immutable fixture)"
else
  (cd "$canary" && sha256sum --check "$FIXTURE/MANIFEST.sha256" 2>&1 | sed 's/^/    /')
  bad "canary consumer drifted from MANIFEST.sha256 — regenerate it deliberately, do not silence this"
  POLICY_RC=1
fi

# Run the gates the governance reusable actually ships, from THIS source, on
# the canary tree. Nothing here is continue-on-error: a red is the job's.
gate() {  # $1 label, $2 expected rc, $3 the gate's path inside the source, then the command
  local label=$1 want=$2 script=$3; shift 3
  local got=0 out
  if ! have "$script"; then
    bad "$label: this source does not ship $script, so the gate cannot execute at all"
    POLICY_RC=1
    return
  fi
  out="$("$@" 2>&1)" || got=$?
  if [ "$got" -eq "$want" ]; then
    ok "$label (exit $got)"
  else
    printf '%s\n' "$out" | tail -8 | sed 's/^/    /'
    bad "$label: expected exit $want, got $got"
    POLICY_RC=1
  fi
}

gate 'UUID gate accepts canary identifiers' 0 scripts/check-uuid-v8.sh \
  bash "$SRC/scripts/check-uuid-v8.sh" --strict "$canary"
gate 'duplicate-key linter accepts the canary workflow' 0 scripts/check-workflow-duplicate-keys.sh \
  bash "$SRC/scripts/check-workflow-duplicate-keys.sh" "$canary/.github/workflows"

# Fail direction: the same gates, on the same canary, with one seeded defect
# each. This is the half that a setup-only check cannot see.
seeded="$tmp/consumer-seeded"
cp -a "$canary" "$seeded"
# The defect is a version nibble, so build both identifiers from their parts:
# writing the rejected one out would put a non-v8 literal in this repository
# and redden the very gate the canary is exercising (measured 2026-10-31).
v8_id="$(printf '%s-%s-%s-%s-%s' 9f8e7d6c 5b4a 8812 9c3d 2b1a0f9e8d7c)"
v4_id="$(printf '%s-%s-%s-%s-%s' 9f8e7d6c 5b4a 4812 9c3d 2b1a0f9e8d7c)"
sed -i "s/$v8_id/$v4_id/" "$seeded/data/records.json"
gate 'UUID gate rejects a v4 identifier on the same canary' 1 scripts/check-uuid-v8.sh \
  bash "$SRC/scripts/check-uuid-v8.sh" --strict "$seeded"

seeded2="$tmp/consumer-seeded-dup"
cp -a "$canary" "$seeded2"
sed -i '0,/^    runs-on: ubuntu-latest$/s//    runs-on: ubuntu-latest\n    runs-on: ubuntu-24.04/' \
  "$seeded2/.github/workflows/ci.yml"
gate 'duplicate-key linter rejects a duplicated key on the same canary' 1 scripts/check-workflow-duplicate-keys.sh \
  bash "$SRC/scripts/check-workflow-duplicate-keys.sh" "$seeded2/.github/workflows"

# A gate the reusable EXECUTES must exist in the source, even where this canary
# cannot run it: `Check action pins resolve upstream` fails the governance job
# if the script is missing, so a source that does not ship it cannot be
# certified by a canary that never looked.
if have scripts/check-action-pins-resolve.sh; then
  ok "this source ships check-action-pins-resolve.sh (the reusable executes it)"
else
  bad "this source ships no scripts/check-action-pins-resolve.sh, and governance-reusable.yml runs it: the pin-resolution step fails for every caller"
  POLICY_RC=1
fi

if [ "$POLICY_RC" -eq 0 ]; then
  ok "POLICY phase clean for the gates this canary exercises"
else
  bad "POLICY phase not clean"
fi

# ═══ VERDICT ═════════════════════════════════════════════════════════════
echo
echo "governance-canary: passed=$pass failed=$fail (startup=${STARTUP_RC} policy=${POLICY_RC})"
[ "$fail" -eq 0 ] || exit 1
echo "CANARY GREEN: startup clean, and the gates listed above execute and still fail"
echo "what they exist to fail. NOT exercised here: scripts/check-action-pins-resolve.sh"
echo "(it asks GitHub whether each pin resolves, so it needs the network), other lock"
echo "verifiers, and allowlist admission. Those are exercised by the governance jobs"
echo "themselves; this canary does not stand in for them."
exit 0
