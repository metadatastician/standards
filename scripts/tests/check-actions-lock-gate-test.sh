#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# check-actions-lock-gate-test.sh — fixture suite for scripts/check-actions-lock-gate.sh,
# the `actions-lock-verify` GATE. Every branch is driven on both sides of the
# grace cutoff. The "lockfile present" branches use a stub verifier so the
# planted positive (a verifier that says the lock is bad → gate RED) runs
# without `gh actions-lock` installed.
#
# Run: bash scripts/tests/check-actions-lock-gate-test.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../check-actions-lock-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

assert() {
  local label="$1" want="$2" needle="$3"; shift 3
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" != "$want" ]; then
    echo "FAIL: $label — expected exit $want, got $status"
    echo "      output: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  if [ "$needle" != "-" ] && ! grep -qF "$needle" <<<"$out"; then
    echo "FAIL: $label — exit $status correct, but output lacked '$needle'"
    echo "      output: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
    fail=$((fail + 1)); return
  fi
  echo "PASS: $label"; pass=$((pass + 1))
}

# mkwf <name> <pinned|unpinned> [lock]
mkwf() {
  local d="$WORK/$1/.github/workflows"; mkdir -p "$d"
  if [ "$2" = pinned ]; then
    printf 'jobs:\n  call:\n    uses: hyperpolymath/standards/.github/workflows/x.yml@3d3c42e5aac5ba805825da76410c181273ba90b1\n  a:\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n      - uses: ./local\n' > "$d/ci.yml"
  else
    printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n' > "$d/ci.yml"
  fi
  [ "${3:-}" = lock ] && : > "$d/actions.lock"
  printf '%s' "$d"
}
OK_VERIFIER="$WORK/verifier-ok.sh";  printf '#!/usr/bin/env bash\necho stub-verifier-ok; exit 0\n' > "$OK_VERIFIER"
BAD_VERIFIER="$WORK/verifier-bad.sh"; printf '#!/usr/bin/env bash\necho stub-verifier-BAD; exit 1\n' > "$BAD_VERIFIER"
BEFORE="2026-09-15"; AFTER="2026-10-01"

echo "=== lockfile present ==="
d=$(mkwf a pinned lock)
assert "lock + verifier OK → 0"          0 "coverage verified"        env ACTIONS_LOCK_VERIFIER="$OK_VERIFIER"  bash "$GATE" "$d"
assert "lock + verifier BAD → 1 (planted positive)" 1 "verification FAILED" env ACTIONS_LOCK_VERIFIER="$BAD_VERIFIER" bash "$GATE" "$d"
assert "lock + verifier missing → 2"     2 "verifier not found"       env ACTIONS_LOCK_VERIFIER="$WORK/nope.sh"  bash "$GATE" "$d"
assert "lock + unpinned refs: verifier decides, not the grep" 0 "stub-verifier-ok" env ACTIONS_LOCK_VERIFIER="$OK_VERIFIER" bash "$GATE" "$(mkwf b unpinned lock)"

echo "=== no lockfile ==="
d=$(mkwf c pinned)
assert "no lock, pinned, before cutoff → 0 NOT YET ENFORCED" 0 "NOT YET ENFORCED" env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"
assert "no lock, pinned, before cutoff emits ::warning"      0 "::warning::"      env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"
assert "no lock, pinned, on cutoff → 3 (ledgerable debt)"     3 "MISSING-LOCK DEBT" env LOCK_TODAY="$AFTER" bash "$GATE" "$d"
assert "no lock, pinned, custom cutoff honoured → 3"         3 "::error::"        env LOCK_TODAY="2026-09-03" ENFORCE_ACTIONS_LOCK_FROM="2026-09-02" bash "$GATE" "$d"
d=$(mkwf e unpinned)
assert "no lock, unpinned, before cutoff → 1 (no grace for unpinned)" 1 "not SHA-pinned" env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"
assert "no lock, unpinned, after cutoff → 1"                          1 "not SHA-pinned" env LOCK_TODAY="$AFTER"  bash "$GATE" "$d"
# Canon reusables are remote refs too, under either owner: they get no
# floating-ref exemption, even inside the missing-lock grace window.
for ref in hyperpolymath/standards/.github/workflows/x.yml@main metadatastician/standards/.github/workflows/x.yml@main; do
  d=$(mkwf remote pinned)
  printf '  remote:\n    uses: %s\n' "$ref" >> "$d/ci.yml"
  assert "no lock, $ref, before cutoff → 1" 1 "uses: $ref" env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"
  assert "no lock, $ref, after cutoff → 1"  1 "uses: $ref" env LOCK_TODAY="$AFTER"  bash "$GATE" "$d"
done
assert "missing workflows dir → 2" 2 "not found" bash "$GATE" "$WORK/does-not-exist/.github/workflows"

echo "=== no lockfile, KYAML and parser cases (YAML-POLICY Y-1) ==="
# The KYAML control is generated from the block fixture by yq itself, and must
# carry the same data, so a fail here is the gate's reading, not the fixture's.
d=$(mkwf k pinned)
yq -p yaml -o kyaml "$d/ci.yml" > "$d/ci.kyaml.tmp" && mv "$d/ci.kyaml.tmp" "$d/ci.yml"
kyaml_same=no
[ "$(yq -o json -I 0 "$d/ci.yml")" = "$(yq -o json -I 0 "$(mkwf k0 pinned)/ci.yml")" ] && kyaml_same=yes
assert "KYAML control: same data as the block fixture" 0 "yes" echo "$kyaml_same"
assert "KYAML control: really is flow style"          0 '"./local"' cat "$d/ci.yml"
assert "no lock, KYAML pinned, before cutoff → 0" 0 "NOT YET ENFORCED"  env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"
assert "no lock, KYAML pinned, after cutoff → 3"  3 "MISSING-LOCK DEBT" env LOCK_TODAY="$AFTER"  bash "$GATE" "$d"
d=$(mkwf ku unpinned)
yq -p yaml -o kyaml "$d/ci.yml" > "$d/ci.kyaml.tmp" && mv "$d/ci.kyaml.tmp" "$d/ci.yml"
assert "no lock, KYAML unpinned (mutant) → 1" 1 "uses: actions/checkout@v4" env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"

d=$(mkwf rb pinned)
# The heredoc line starts with `uses:`, so a line grep reads it as a step ref.
printf '  b:\n    steps:\n      - run: |\n          cat <<EOF\n          uses: actions/checkout@v4\n          EOF\n' >> "$d/ci.yml"
assert "a run: body line 'uses: x@v4' is not a ref → 0" 0 "NOT YET ENFORCED" env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"
d=$(mkwf jl pinned)
printf '  call:\n    uses: o/r/.github/workflows/w.yml@v1\n' >> "$d/ci.yml"
assert "a job-level reusable call by tag → 1" 1 "uses: o/r/.github/workflows/w.yml@v1" env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"
d=$(mkwf sh pinned)
printf '      - uses: actions/checkout@3d3c42e\n' >> "$d/ci.yml"
assert "a short SHA is not a pin → 1" 1 "uses: actions/checkout@3d3c42e" env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"

d=$(mkwf up pinned)
printf 'jobs:\n  a: [\n' > "$d/broken.yml"
assert "an unparseable workflow → 1 UNEXAMINED, never pinned" 1 "UNEXAMINED" env LOCK_TODAY="$AFTER" bash "$GATE" "$d"
d=$(mkwf qs pinned)
# An unclosed quote that swallows the file still parses: name becomes one long
# string and there is no jobs map, so the unpinned ref inside is never read.
printf 'name: "X\non: push\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n"\n' > "$d/swallowed.yml"
assert "a quote-swallowed workflow → 1, not a pass" 1 "has no jobs: map" env LOCK_TODAY="$BEFORE" bash "$GATE" "$d"

d=$(mkwf ny pinned)
assert "yq missing → 2"             2 "yq not found"   env YQ_BIN="$WORK/no-such-yq" bash "$GATE" "$d"
WRONG_YQ="$WORK/wrong-yq.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WRONG_YQ"; chmod +x "$WRONG_YQ"
assert "a yq that reads nothing → 2" 2 "cannot read uses: refs" env YQ_BIN="$WRONG_YQ" bash "$GATE" "$d"

echo; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
