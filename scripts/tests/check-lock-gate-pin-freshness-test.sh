#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Mutants for scripts/check-lock-gate-pin-freshness.sh.
#
# Every control builds a THROWAWAY git repository with real commits, so the
# freshness comparison is exercised against genuine history with no network and
# no dependence on this repo's own state. A control that asserted against the
# real tree would go green or red for reasons unrelated to the mutation.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-lock-gate-pin-freshness.sh"
[ -f "$GUARD" ] || { echo "FAIL: guard not found at $GUARD" >&2; exit 1; }

pass=0
fail=0

check() { # name expected_rc actual_rc [haystack needle]
  local name="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    echo "FAIL: $name — expected rc=$want, got rc=$got" >&2
    fail=$((fail + 1))
    return
  fi
  if [ "$#" -ge 5 ] && ! printf '%s' "$4" | grep -Fq -- "$5"; then
    echo "FAIL: $name — rc was right but the message never mentioned '$5'" >&2
    echo "----- output -----" >&2; printf '%s\n' "$4" >&2; echo "------------------" >&2
    fail=$((fail + 1))
    return
  fi
  echo "ok: $name"
  pass=$((pass + 1))
}

refute() { # name haystack needle
  local name="$1"
  if printf '%s' "$2" | grep -Fq -- "$3"; then
    echo "FAIL: $name — output mentioned '$3' and must not" >&2
    fail=$((fail + 1))
    return
  fi
  echo "ok: $name"
  pass=$((pass + 1))
}

# Build a repo whose helper changed in the SECOND commit, plus an unrelated file
# that also changed, so path-scoping can be told apart from "any divergence".
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1
git init --quiet -b main .
git config user.email t@example.invalid
git config user.name t
mkdir -p scripts .machine_readable
echo v1 > scripts/update-actions-lock.sh
echo v1 > scripts/check-actions-lock-gate.sh
echo v1 > .machine_readable/lock-allow.txt
echo v1 > UNRELATED.md
git add -A && git commit --quiet -m c1
OLD="$(git rev-parse HEAD)"
echo v2 > scripts/update-actions-lock.sh
echo v2 > UNRELATED.md
git add -A && git commit --quiet -m c2
NEW="$(git rev-parse HEAD)"
# A third commit touching ONLY the unrelated file, to prove path-scoping.
echo v3 > UNRELATED.md
git add -A && git commit --quiet -m c3
NEWEST="$(git rev-parse HEAD)"

# $1 = the `ref:` value; $2 (optional) = step name override.
write_fixture() {
  local ref="$1" name="${2:-Checkout standards for the lock gate}"
  mkdir -p "$WORK/.github/workflows"
  cat > "$WORK/.github/workflows/governance-reusable.yml" <<YAML
jobs:
  gate:
    steps:
      - name: A preceding step that also has a ref
        uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with:
          ref: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      - name: $name
        uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with:
          repository: metadatastician/standards
          ref: $ref
          path: .standards-lock
          sparse-checkout: |
            scripts/check-actions-lock-gate.sh
            scripts/update-actions-lock.sh
            .machine_readable/lock-allow.txt
          sparse-checkout-cone-mode: false
      - name: A following step with a decoy ref
        uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with:
          ref: cccccccccccccccccccccccccccccccccccccccc
YAML
  export LOCK_GATE_WORKFLOW="$WORK/.github/workflows/governance-reusable.yml"
}

run() { bash "$GUARD" "$@" 2>&1; }

# 1. The real defect: the pin predates a helper change that is already on main.
write_fixture "$OLD"
out="$(run "$NEW")"; rc=$?
check "stale pin is refused" 1 "$rc" "$out" "scripts/update-actions-lock.sh"

# 2. And it must not name files outside the staged scope. UNRELATED.md differs
#    between the two commits too; if it appears, the guard is diffing the whole
#    tree and every rebase would redden it.
refute "stale report is path-scoped (never names UNRELATED.md)" "$out" "UNRELATED.md"

# 3. The cured state passes.
write_fixture "$NEW"
out="$(run "$NEW")"; rc=$?
check "fresh pin is accepted" 0 "$rc" "$out" "PASS"

# 4. Path-scoping: an unrelated commit on top must NOT fail a fresh pin.
#    Without this, every rebase would redden the gate and the guard would be
#    turned off rather than obeyed.
write_fixture "$NEW"
out="$(run "$NEWEST")"; rc=$?
check "unrelated divergence does not fail it" 0 "$rc" "$out" "PASS"

# 5. A moving ref is refused — the whole point of pinning.
write_fixture "main"
out="$(run "$NEW")"; rc=$?
check "ref: main is refused" 1 "$rc" "$out" "not an immutable 40-hex commit"

# 6. A short/abbreviated SHA is refused.
write_fixture "${NEW:0:12}"
out="$(run "$NEW")"; rc=$?
check "abbreviated sha is refused" 1 "$rc" "$out" "not an immutable 40-hex commit"

# 7. Renaming the step must FAIL, not vacuously pass. This is the exact way the
#    existing contract test lost its subject: it greps a step name, and a step
#    that no longer matches simply stops being checked.
write_fixture "$NEW" "Checkout standards for something else"
out="$(run "$NEW")"; rc=$?
check "renamed step fails loudly" 1 "$rc" "$out" "lost its subject"

# 8. A pin that cannot be resolved must FAIL, never skip.
write_fixture "dddddddddddddddddddddddddddddddddddddddd"
out="$(run "$NEW")"; rc=$?
check "unresolvable pin fails, not skips" 1 "$rc" "$out" "does not pass on an unverifiable pin"

# 9. No ref: at all.
mkdir -p "$WORK/.github/workflows"
cat > "$WORK/.github/workflows/governance-reusable.yml" <<'YAML'
jobs:
  gate:
    steps:
      - name: Checkout standards for the lock gate
        uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with:
          repository: metadatastician/standards
          sparse-checkout: |
            scripts/update-actions-lock.sh
YAML
export LOCK_GATE_WORKFLOW="$WORK/.github/workflows/governance-reusable.yml"
out="$(run "$NEW")"; rc=$?
check "missing ref: is refused" 1 "$rc" "$out" "would follow the default branch"

# 11. The reusable's own commit is fresh by construction and needs no compare.
write_fixture '${{ job.workflow_sha }}'
out="$(run "$NEW")"; rc=$?
check "job.workflow_sha is accepted" 0 "$rc" "$out" "fresh by construction"

# 12. The CALLER's commit is not the reusable's: both forms stay refused.
write_fixture '${{ github.workflow_sha }}'
out="$(run "$NEW")"; rc=$?
check "github.workflow_sha (caller's) is refused" 1 "$rc" "$out" "not an immutable 40-hex commit"
write_fixture '${{ github.sha }}'
out="$(run "$NEW")"; rc=$?
check "github.sha (caller's) is refused" 1 "$rc" "$out" "not an immutable 40-hex commit"

# 10. Staging nothing must not be a free pass.
cat > "$WORK/.github/workflows/governance-reusable.yml" <<YAML
jobs:
  gate:
    steps:
      - name: Checkout standards for the lock gate
        uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with:
          ref: $NEW
          path: .standards-lock
YAML
out="$(run "$NEW")"; rc=$?
check "empty staged scope is refused" 1 "$rc" "$out" "stages no sparse-checkout paths"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "PASS: lock-gate pin freshness guard refuses a stale pin and cannot be silenced by renaming its subject"
