#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# pre-commit-continue-test.sh — .githooks/pre-commit runs every check and then
# decides, however many of them fail.
#
# The hook runs under `set -e`. Its validator helpers used to return 1 after
# counting a failure, which at top level ended the hook at the first failing
# validator: a missing gitleaks stopped every later check and the ERRORS
# summary. Each case runs the real hook in a temporary git repository whose
# validators are stubs that log their name and exit as told.
#
# Proves: a failing validator, required or not, still fails the hook (exit 1,
# the FAILED summary with the error count); every later validator still runs;
# a clean run passes (positive control); a missing REQUIRED validator still
# fails closed.
#
# Run: bash scripts/tests/pre-commit-continue-test.sh
# HOOK overrides the hook under test (used to show the defect on an old copy).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK:-$SCRIPT_DIR/../../.githooks/pre-commit}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0

ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fail=$((fail + 1)); }

# The validators the hook dispatches, in its order.
VALIDATORS=(validate-gitleaks.sh validate-lint-format.sh validate-ledger-prune.sh
  validate-k9.sh validate-spdx.sh validate-spdx-workflows.sh validate-sha-pins.sh
  validate-actions-lock.sh validate-permissions.sh validate-codeql.sh
  validate-bot-directives.sh)

# fixture <name> [failing validator…] — a repository with the real hook, a
# stub for every validator (the named ones exit 1) and one staged file.
fixture() {
  local d="$WORK/$1" v; shift
  rm -rf "$d"; mkdir -p "$d/.githooks"
  git init -q "$d"
  cp "$HOOK" "$d/.githooks/pre-commit"
  for v in "${VALIDATORS[@]}"; do
    printf '#!/usr/bin/env bash\necho "%s" >> "%s"\nexit 0\n' "$v" "$d.log" > "$d/.githooks/$v"
    chmod +x "$d/.githooks/$v"
  done
  for v in "$@"; do
    printf '#!/usr/bin/env bash\necho "%s" >> "%s"\nexit 1\n' "$v" "$d.log" > "$d/.githooks/$v"
  done
  : > "$d.log"
  printf 'echo hi\n' > "$d/a.sh"
  git -C "$d" add a.sh
  printf '%s' "$d"
}

# run_hook <dir> — sets OUT and RC.
run_hook() {
  OUT="$(cd "$1" && bash .githooks/pre-commit 2>&1)"; RC=$?
  OUT="$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')"
}
ran() { grep -qxF -- "$2" "$1.log"; }

d=$(fixture clean); run_hook "$d"
if [ "$RC" -eq 0 ] && grep -qF "All pre-commit checks PASSED" <<<"$OUT" && ran "$d" validate-bot-directives.sh; then
  ok "positive control: every validator passes, the hook passes"
else ko "positive control (exit $RC)"; fi

d=$(fixture gitleaks validate-gitleaks.sh); run_hook "$d"
if [ "$RC" -eq 1 ] && grep -qF "Pre-commit check FAILED with 1 error(s)" <<<"$OUT"; then
  ok "a failing REQUIRED validator (gitleaks) still fails the hook, with the summary"
else ko "failing gitleaks: wanted exit 1 and the FAILED summary, got exit $RC"; fi
if ran "$d" validate-lint-format.sh && ran "$d" validate-k9.sh && ran "$d" validate-bot-directives.sh; then
  ok "every later validator still runs after gitleaks fails"
else ko "later validators did not run after gitleaks failed: $(tr '\n' ' ' < "$d.log")"; fi

d=$(fixture two validate-gitleaks.sh validate-k9.sh); run_hook "$d"
if [ "$RC" -eq 1 ] && grep -qF "Pre-commit check FAILED with 2 error(s)" <<<"$OUT" && ran "$d" validate-bot-directives.sh; then
  ok "two failures (required and advisory) are both counted"
else ko "two failures: wanted exit 1 and 2 error(s), got exit $RC"; fi

d=$(fixture missing); rm "$d/.githooks/validate-gitleaks.sh"; run_hook "$d"
if [ "$RC" -eq 1 ] && grep -qF "REQUIRED validator 'validate-gitleaks.sh' is missing" <<<"$OUT" \
   && grep -qF "FAILED with 1 error(s)" <<<"$OUT" && ran "$d" validate-k9.sh; then
  ok "a missing REQUIRED validator fails closed, and the rest still run"
else ko "missing gitleaks: wanted exit 1, the refusal and the rest run, got exit $RC"; fi

d=$(fixture lang); printf 'package x\n' > "$d/x.go"; git -C "$d" add x.go; run_hook "$d"
if [ "$RC" -eq 1 ] && grep -qF "Go files not allowed" <<<"$OUT" && ran "$d" validate-k9.sh \
   && grep -qF "FAILED with 1 error(s)" <<<"$OUT"; then
  ok "a language-policy refusal is counted and the later validators run"
else ko "a staged .go file: wanted exit 1, the refusal and later validators, got exit $RC"; fi

# The actions.lock closure check must run when the lock is staged, however
# many other files the commit stages. The hook used to decide that with
# `git diff --cached --name-only … | grep -qxF "$LOCK_REL"` under pipefail:
# the lock sorts early, grep -q exits at it, git still writing a name list
# above the 64 KiB pipe buffer dies of SIGPIPE, the pipeline reports 141 and
# the check was skipped. A stub close-lock.sh that always fails stands in for
# a lock that fails closure; five runs, each must fail the hook.
d=$(fixture biglock)
mkdir -p "$d/scripts" "$d/.github/workflows" "$d/zz"
printf '#!/usr/bin/env bash\necho close-lock >> "%s"\nexit 1\n' "$d.log" > "$d/scripts/close-lock.sh"
printf 'lock\n' > "$d/.github/workflows/actions.lock"
for i in $(seq 1 1000); do
  : > "$d/zz/a-staged-file-whose-name-is-long-enough-to-fill-the-pipe-buffer-quickly-number-$i.txt"
done
git -C "$d" add -A
for run in 1 2 3 4 5; do
  : > "$d.log"; run_hook "$d"
  if [ "$RC" -eq 1 ] && ran "$d" close-lock && grep -qF "staged actions.lock failed the closure check" <<<"$OUT"; then
    ok "a staged actions.lock in a commit of 1000 files is checked for closure (run $run)"
  else OUT="exit $RC; log: $(tr '\n' ' ' < "$d.log")"; ko "staged actions.lock among 1000 files skipped the closure check (run $run)"; fi
done
# Controls: with the lock unstaged the closure check does not run (the hook
# passes); with a closure check that passes, the hook passes.
git -C "$d" rm -q --cached .github/workflows/actions.lock
: > "$d.log"; run_hook "$d"
if [ "$RC" -eq 0 ] && ! ran "$d" close-lock; then ok "an unstaged actions.lock is not checked (control)"
else ko "unstaged actions.lock: wanted exit 0 and no closure check, got exit $RC"; fi
git -C "$d" add .github/workflows/actions.lock
printf '#!/usr/bin/env bash\necho close-lock >> "%s"\nexit 0\n' "$d.log" > "$d/scripts/close-lock.sh"
: > "$d.log"; run_hook "$d"
if [ "$RC" -eq 0 ] && ran "$d" close-lock; then ok "a staged actions.lock that closes passes (control)"
else ko "staged actions.lock that closes: wanted exit 0 after the check, got exit $RC"; fi

# Mutants: the suite, run against a modified copy of the hook, must fail.
if [ -z "${PRE_COMMIT_MUTANT:-}" ]; then
  mutant() { # <label> <sed-expr>
    local m="$WORK/mutant-pre-commit" n
    sed "$2" "$HOOK" > "$m"
    if cmp -s "$m" "$HOOK" || ! bash -n "$m"; then OUT=""; ko "mutant ($1) is invalid or identical"; return; fi
    n=$(HOOK="$m" PRE_COMMIT_MUTANT=1 bash "$SCRIPT_DIR/$(basename "$0")" 2>&1 | grep -c '^FAIL:')
    if [ "$n" -gt 0 ]; then ok "mutant killed ($1): $n case(s) fail"; else OUT=""; ko "mutant survived ($1)"; fi
  }
  mutant "a helper aborts the hook again" 's/return 0  # counted in ERRORS.*/return 1/'
  mutant "a failure no longer fails the hook" '/FAILED with/,/exit 1/s/exit 1/exit 0/'
fi

echo
echo "pre-commit-continue: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
