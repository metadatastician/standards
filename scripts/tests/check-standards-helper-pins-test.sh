#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Regression corpus for scripts/check-standards-helper-pins.sh.
#
# Each fixture is a workflow that stages a helper out of
# metadatastician/standards, varying only the `ref:`. The mutation set is the
# set of answers a workflow author actually reaches for — including the two
# that LOOK pinned and are not (`github.sha` is the caller's commit; a bare
# input can be a branch) — plus the freshness predicate, exercised against a
# throwaway git repository whose history this test controls.
#
# Exit: 0 all cases behave; 2 the guard cannot be exercised (no yq/jq).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-standards-helper-pins.sh"
command -v yq >/dev/null 2>&1 || { echo 'SKIP(2): yq not installed' >&2; exit 2; }
yq --version 2>/dev/null | grep -q mikefarah || { echo 'SKIP(2): mikefarah yq v4 required' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'SKIP(2): jq not installed' >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo 'SKIP(2): git not installed' >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# workflow <ref-yaml> [repository]
workflow() {
  mkdir -p "$tmp/wf"
  rm -f "$tmp/wf"/*.yml
  printf 'name: fixture\non: workflow_call\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - name: Stage helpers\n        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n        with:\n          repository: %s\n          ref: %s\n          path: .standards\n          sparse-checkout: |\n            scripts\n          sparse-checkout-cone-mode: false\n' \
    "${2:-metadatastician/standards}" "$1" > "$tmp/wf/fixture.yml"
}

assert() {  # label expected-rc args...
  local label=$1 want=$2; shift 2
  local got=0 out
  out="$(cd "$tmp" && bash "$GUARD" "$@" 2>&1)" || got=$?
  if [ "$got" -ne "$want" ]; then
    printf '%s\n' "$out" | sed 's/^/    /'
    bad "$label (wanted exit $want, got $got)"
  else
    ok "$label"
  fi
}

# ── floating refs ────────────────────────────────────────────────────────
workflow 'main'
assert 'a branch ref is rejected' 1 wf
workflow 'master'
assert 'master is rejected' 1 wf
workflow 'v7.0.1'
assert 'a tag ref is rejected (it can move)' 1 wf
workflow 'HEAD'
assert 'HEAD is rejected' 1 wf

# ── the two shapes that look pinned and are not ──────────────────────────
workflow '${{ github.sha }}'
assert 'github.sha (the CALLER commit) is rejected' 1 wf
workflow '${{ github.workflow_sha }}'
assert 'github.workflow_sha (the CALLER workflow file) is rejected' 1 wf
workflow '${{ inputs.standards-ref }}'
assert 'a bare input ref is rejected' 1 wf
workflow '${{ inputs.canon-ref || job.workflow_sha }}'
assert 'an input with a job.workflow_sha fallback is accepted' 0 wf

# ── missing ref: actions/checkout silently follows the default branch ────
mkdir -p "$tmp/wf"
rm -f "$tmp/wf"/*.yml
printf 'name: fixture\non: workflow_call\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n        with:\n          repository: metadatastician/standards\n          path: .standards\n' > "$tmp/wf/fixture.yml"
assert 'a standards checkout with no ref is rejected' 1 wf

# ── the pinned shapes ────────────────────────────────────────────────────
workflow '${{ job.workflow_sha }}'
assert 'job.workflow_sha is accepted' 0 wf

# ── scope: another repository is not this guard's subject ────────────────
workflow 'main' 'someother/project'
assert 'a non-standards checkout is not scanned (vacuous population stated)' 0 wf

# ── an unreadable workflow is UNEXAMINED, never clean ────────────────────
mkdir -p "$tmp/wf"
rm -f "$tmp/wf"/*.yml
printf 'jobs: [\n' > "$tmp/wf/broken.yml"
assert 'an unparseable workflow fails the guard' 1 wf

# ── freshness of a literal pin, over the paths the step stages ───────────
repo="$tmp/hist"
mkdir -p "$repo/scripts" "$repo/.github/workflows"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m root
printf 'v1\n' > "$repo/scripts/gate.sh"
printf 'v1\n' > "$repo/scripts/other.sh"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@example.invalid -c user.name=t commit -q -m 'add gates'
pinned="$(git -C "$repo" rev-parse HEAD)"
printf 'v2\n' > "$repo/scripts/gate.sh"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@example.invalid -c user.name=t commit -q -m 'change gate'
head="$(git -C "$repo" rev-parse HEAD)"

mkdir -p "$repo/.github/workflows"
mkpin() {  # $1 = pin, $2 = sparse path
  printf 'name: fixture\non: workflow_call\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n        with:\n          repository: metadatastician/standards\n          ref: %s\n          path: .standards\n          sparse-checkout: |\n            %s\n          sparse-checkout-cone-mode: false\n' "$1" "$2" > "$repo/.github/workflows/fixture.yml"
}

mkpin "$head" scripts/gate.sh
# Run from inside the history repo so --compare resolves against it.
got=0
( cd "$repo" && bash "$GUARD" .github/workflows --compare "$head" ) >/dev/null 2>&1 || got=$?
[ "$got" -eq 0 ] && ok 'fresh literal pin passes when the guard runs inside that repository' \
  || bad "fresh literal pin failed inside its own repository (exit $got)"

mkpin "$pinned" scripts/gate.sh
got=0
out="$( cd "$repo" && bash "$GUARD" .github/workflows --compare "$head" 2>&1 )" || got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -q 'stale: scripts/gate.sh'; then
  ok 'a literal pin that is stale over its staged path is rejected'
else
  printf '%s\n' "$out" | sed 's/^/    /'
  bad "a stale literal pin was not rejected over its staged path (exit $got)"
fi

# Same stale pin, but staging a path that did NOT change: the predicate is
# path-scoped precisely so an unrelated commit cannot redden a correct pin.
mkpin "$pinned" scripts/other.sh
got=0
( cd "$repo" && bash "$GUARD" .github/workflows --compare "$head" ) >/dev/null 2>&1 || got=$?
[ "$got" -eq 0 ] && ok 'staleness is path-scoped: an unchanged staged path stays fresh' \
  || bad "a pin whose staged path did not change was reported stale (exit $got)"

# ── not-inspected states ─────────────────────────────────────────────────
workflow '${{ job.workflow_sha }}'
got=0
mkdir -p "$tmp/noyq"
for tool in jq git bash dirname tr grep sed awk mktemp head printf; do
  p="$(command -v "$tool" 2>/dev/null)" && ln -sf "$p" "$tmp/noyq/$tool"
done
out="$( cd "$tmp" && env PATH="$tmp/noyq" /bin/bash "$GUARD" wf 2>&1 )" || got=$?
[ "$got" -eq 2 ] && ok 'a PATH without yq exits 2' || { printf '%s\n' "$out" | sed 's/^/    /'; bad "no-yq PATH gave exit $got, wanted 2"; }

got=0
out="$( cd "$tmp" && bash "$GUARD" no-such-dir 2>&1 )" || got=$?
[ "$got" -eq 2 ] && ok 'a missing workflow directory is UNINSPECTED' || { printf '%s\n' "$out" | sed 's/^/    /'; bad "missing directory gave exit $got, wanted 2"; }

# ── positive control: this repository ────────────────────────────────────
got=0
out="$( cd "$ROOT" && bash "$GUARD" .github/workflows 2>&1 )" || got=$?
if [ "$got" -eq 0 ]; then
  ok "this repository's own workflows pass the guard"
else
  printf '%s\n' "$out" | grep -E '::error' | sed 's/^/    /'
  bad "this repository's own workflows fail the guard (exit $got)"
fi

echo
echo "check-standards-helper-pins: passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
