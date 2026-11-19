#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# deep-recon-contract-test.sh — holds the deep-recon wiring to the two
# properties that make it trustworthy rather than decorative:
#
#   * pons gates ONLY at error severity and SPECULATIVE findings are
#     omitted, never gated on (the tool's own contract: never dress a
#     heuristic up as a proof). Lowering --fail-on, or dropping
#     --no-speculative, would break that silently;
#   * a scanner that cannot run, or produces nothing parseable, fails —
#     including panic-attack, whose findings are report-only this cycle.
#     "Report-only findings" must never decay into "report-only tool";
#   * both tools are pinned to 40-hex commits, the scope files
#     (.ponsignore, pons.toml) exist so exclusions are declared in the
#     open, and the workflows are in actions.lock.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
reusable="$root/.github/workflows/deep-recon-reusable.yml"
caller="$root/.github/workflows/deep-recon.yml"
lock="$root/.github/workflows/actions.lock"
pass=0; fail=0

t() { local label="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "PASS $label"
  else fail=$((fail+1)); echo "FAIL $label"; fi; }
# -e is load-bearing: several patterns start with `--` and would otherwise
# be parsed as grep flags, making `has` fail and `lacks` pass spuriously.
has()   { grep -qF -e "$2" "$1"; }
hasre() { grep -qE -e "$2" "$1"; }
lacks() { ! grep -qF -e "$2" "$1"; }
# Ignore comments and join shell continuations; global flags may precede
# the subcommand, so checking only `panic-attack attack` can pass blind.
has_subcommand() {
  local joined; joined=$(sed '/^[[:space:]]*#/d; :join; /\\$/ { N; s/\\\n[[:space:]]*/ /; b join; }' "$1")
  grep -qE -e "panic-attack[[:space:]]+(--[^[:space:]]+[[:space:]]+)*$2([[:space:]]|$)" <<<"$joined"
}
no_subcommand() { ! has_subcommand "$@"; }
planted="$(mktemp)"; trap 'rm -f "$planted"' EXIT
for subcommand in attack assault; do
  for options in '' '--headless '; do
    printf '      - run: panic-attack %s%s scripts\n' "$options" "$subcommand" > "$planted"
    t "matcher detects ${options}${subcommand}" has_subcommand "$planted" "$subcommand"
  done
done

for f in "$reusable" "$caller" "$root/pons.toml" "$root/.ponsignore"; do
  t "exists: ${f#$root/}" test -f "$f"
done

# Pons gating semantics.
t "pons fails only at error severity" has "$reusable" '--fail-on error'
t "pons omits speculative findings" has "$reusable" '--no-speculative'
t "pons does not gate at warn" lacks "$reusable" '--fail-on warn'
t "pons does not gate at info" lacks "$reusable" '--fail-on info'
t "pons SARIF must parse before upload" has "$reusable" "pons produced no parseable SARIF"
t "pons exit 2 fails" has "$reusable" 'scan did not complete (exit'
t "pons SARIF category is stable" has "$reusable" 'category: pons-asinorum'

# Panic: findings report-only, tool failure hard.
t "assail runs headless (CI-safe)" has "$reusable" '--headless'
t "assail report must parse as JSON" has "$reusable" 'not parseable JSON'
t "assail tool failure fails the job" has "$reusable" 'assail failed to run on'
t "assail never runs dynamic attacks in CI" no_subcommand "$reusable" attack
t "assail never assaults in CI" no_subcommand "$reusable" assault

# Pins and privilege.
t "pons rev default is 40-hex" hasre "$reusable" 'default: "[0-9a-f]{40}"'
t "panic rev is validated as 40-hex" has "$reusable" 'panic-rev must be a 40-hex commit'
t "pons rev is validated as 40-hex" has "$reusable" 'pons-rev must be a 40-hex commit'
t "caller holds no write grant beyond security-events" \
  bash -c 'w=$(grep -E ": write" "$1"); [ -z "$w" ] || ! grep -qv "security-events: write" <<<"$w"' _ "$caller"
t "caller is not a PR gate" lacks "$caller" 'pull_request:'
t "checkouts do not persist credentials" has "$reusable" 'persist-credentials: false'

# Scope honesty.
t ".ponsignore declares the archive exclusion" has "$root/.ponsignore" '9-archive/'
t "pons.toml carries identity, not blanket suppression" has "$root/pons.toml" '[identity]'
t "pons.toml has no allow entries yet" \
  bash -c '! grep -qE "^[[:space:]]*\[\[?suppress" "$1"' _ "$root/pons.toml"

# Lock coverage.
t "lock lists the reusable" has "$lock" "'.github/workflows/deep-recon-reusable.yml':"
t "lock lists the caller as pin-free" has "$lock" "'.github/workflows/deep-recon.yml': []"
t "lock carries the SARIF uploader pin" hasre "$lock" "'github/codeql-action@[0-9a-f]{40}'"

printf '\ndeep-recon contract tests: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
