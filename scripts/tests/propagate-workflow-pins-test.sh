#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -euo pipefail

# Regression test for propagate-workflow-pins.sh.

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROP="$SCRIPT_DIR/../propagate-workflow-pins.sh"

OLD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# A real local commit graph makes reachability part of every test. The
# propagation primitive must reject a SHA that merely exists on a feature
# branch: GitHub cannot resolve such a SHA as a cross-repo reusable workflow.
UPSTREAM="$TEST_DIR/standards"
git init -q -b main "$UPSTREAM"
git -C "$UPSTREAM" config user.email t@t
git -C "$UPSTREAM" config user.name t
touch "$UPSTREAM/reusable.yml"
git -C "$UPSTREAM" add reusable.yml
git -C "$UPSTREAM" commit -q -m main
TARGET=$(git -C "$UPSTREAM" rev-parse HEAD)
git -C "$UPSTREAM" checkout -q -b feature
touch "$UPSTREAM/feature-only"
git -C "$UPSTREAM" add feature-only
git -C "$UPSTREAM" commit -q -m feature
ORPHAN=$(git -C "$UPSTREAM" rev-parse HEAD)
git -C "$UPSTREAM" checkout -q main
export STANDARDS_DIR="$UPSTREAM"

PASS=0; TOTAL=0

# try DESC CMD [ARGS...] — runs CMD as a real command (no eval); PASS on exit 0.
try() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@"; then echo "PASS: $desc"; PASS=$((PASS + 1)); else echo "FAIL: $desc"; fi
}

# Small eval-free predicates usable as `try` commands.
contains()      { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
not_contains()  { case "$2" in *"$1"*) return 1 ;; *) return 0 ;; esac; }
fresh_only()    { contains FRESH "$1" && not_contains BEHIND "$1"; }
file_has()      { grep -q "$2" "$1"; }
staged_has()    { git -C "$1" diff --cached --name-only | grep -q "$2"; }

mk_consumer() { # dir [owner] — owner defaults to the canonical one
  local owner="${2:-metadatastician}"
  mkdir -p "$1/.github/workflows"
  cat > "$1/.github/workflows/governance.yml" <<EOF
name: Governance
on: push
jobs:
  governance:
    uses: ${owner}/standards/.github/workflows/governance-reusable.yml@${OLD}
EOF
  cat > "$1/.github/workflows/scorecard.yml" <<EOF
name: Scorecard
on: push
jobs:
  scorecard:
    # a non-standards action pin that MUST be left untouched
    steps:
      - uses: actions/checkout@${OLD}
    uses: ${owner}/standards/.github/workflows/scorecard-reusable.yml@${OLD}
EOF
}

# ── 1. AUDIT mode reports BEHIND and does not modify files ──────────────────
R="$TEST_DIR/audit"; mk_consumer "$R"
OUT=$(bash "$PROP" --to "$TARGET" "$R")
try "audit reports BEHIND" contains BEHIND "$OUT"
try "audit leaves file unchanged" file_has "$R/.github/workflows/governance.yml" "governance-reusable.yml@${OLD}"

# ── 2. FIX rewrites the standards pins to the target ────────────────────────
R="$TEST_DIR/fix"; mk_consumer "$R"
bash "$PROP" --fix --to "$TARGET" "$R" >/dev/null
try "fix bumps governance pin" file_has "$R/.github/workflows/governance.yml" "governance-reusable.yml@${TARGET}"
try "fix bumps scorecard pin"  file_has "$R/.github/workflows/scorecard.yml"  "scorecard-reusable.yml@${TARGET}"
try "fix keeps the canonical owner" file_has "$R/.github/workflows/governance.yml" "metadatastician/standards/.github/workflows/governance-reusable.yml@${TARGET}"

# ── 3. Non-standards action pins are NOT touched ────────────────────────────
try "actions/checkout pin untouched" file_has "$R/.github/workflows/scorecard.yml" "actions/checkout@${OLD}"

# ── 4. After fix, audit reports FRESH (idempotent) ──────────────────────────
OUT=$(bash "$PROP" --to "$TARGET" "$R")
try "post-fix audit reports FRESH" fresh_only "$OUT"

# ── 5. Re-running fix is a no-op (idempotent) ───────────────────────────────
BEFORE=$(cat "$R/.github/workflows/governance.yml")
bash "$PROP" --fix --to "$TARGET" "$R" >/dev/null
try "fix is idempotent" test "$(cat "$R/.github/workflows/governance.yml")" = "$BEFORE"

# ── 6. --fix in a git repo stages a bump branch (no commit/push) ────────────
R="$TEST_DIR/gitrepo"; mk_consumer "$R"
git -C "$R" init -q
git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" add -A; git -C "$R" commit -q -m init
bash "$PROP" --fix --to "$TARGET" "$R" >/dev/null 2>&1
try "fix creates bump branch" test "$(git -C "$R" branch --show-current)" = "chore/bump-standards-pins"
try "fix stages the change (no commit)" staged_has "$R" governance.yml

# ── 7. Parent-dir mode processes multiple repos ─────────────────────────────
ROOT="$TEST_DIR/many"; mk_consumer "$ROOT/repoA"; mk_consumer "$ROOT/repoB"
OUT=$(bash "$PROP" --to "$TARGET" "$ROOT")
try "parent-dir mode sees repoA" contains repoA "$OUT"
try "parent-dir mode sees repoB" contains repoB "$OUT"

# ── 8. Existing but non-mainline target is refused before any rewrite ───────
R="$TEST_DIR/orphan"; mk_consumer "$R"
set +e
OUT=$(bash "$PROP" --fix --to "$ORPHAN" "$R" 2>&1)
RC=$?
set -e
try "feature-only target is rejected" test "$RC" -eq 2
try "rejected target leaves consumer unchanged" file_has "$R/.github/workflows/governance.yml" "governance-reusable.yml@${OLD}"
try "rejection explains default-branch reachability" contains "not reachable" "$OUT"

# ── 9. A stale origin/main must not hide a newer local main ──────────────────
git -C "$UPSTREAM" update-ref refs/remotes/origin/main "$TARGET"
touch "$UPSTREAM/mainline-newer"
git -C "$UPSTREAM" add mainline-newer
git -C "$UPSTREAM" commit -q -m mainline-newer
NEWER_TARGET=$(git -C "$UPSTREAM" rev-parse HEAD)
R="$TEST_DIR/stale-origin"; mk_consumer "$R"
set +e
OUT=$(bash "$PROP" --to "$NEWER_TARGET" "$R" 2>&1)
RC=$?
set -e
try "newer local main target survives stale origin/main" test "$RC" -eq 0
try "stale origin/main does not report unreachable" not_contains "not reachable" "$OUT"

# ── 10. A linked worktree retains the shared clone's shallow status ────────────
SHALLOW_REMOTE="$TEST_DIR/standards-remote.git"
SHALLOW_CLONE="$TEST_DIR/standards-shallow"
SHALLOW_WORKTREE="$TEST_DIR/standards-shallow-worktree"
FAKE_BIN="$TEST_DIR/fake-bin"
git init -q --bare "$SHALLOW_REMOTE"
git -C "$UPSTREAM" push -q "$SHALLOW_REMOTE" main
git -C "$SHALLOW_REMOTE" symbolic-ref HEAD refs/heads/main
git clone -q --depth 1 "file://$SHALLOW_REMOTE" "$SHALLOW_CLONE"
git -C "$SHALLOW_CLONE" fetch -q origin "$TARGET"
git -C "$SHALLOW_CLONE" worktree add -q -b reachability-test "$SHALLOW_WORKTREE" HEAD
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' '{"status":"ahead"}'
EOF
chmod +x "$FAKE_BIN/curl"
R="$TEST_DIR/shallow-consumer"; mk_consumer "$R"
set +e
OUT=$(STANDARDS_DIR="$SHALLOW_WORKTREE" PATH="$FAKE_BIN:$PATH" \
  bash "$PROP" --to "$TARGET" "$R" 2>&1)
RC=$?
set -e
try "linked shallow worktree defers to server reachability" test "$RC" -eq 0
try "linked shallow worktree does not report unreachable" not_contains "not reachable" "$OUT"

# ── 11. A refused relock restores the workflows and stages nothing ──────────
# The reusables are not in standards at the target, so the relock is refused.
# New pins over the old lock must be left neither in the index nor in the tree.
ROOT="$TEST_DIR/refused-many"
R="$ROOT/refused"; mk_consumer "$R"
cat > "$R/.github/workflows/actions.lock" <<EOF
version: 'v0.0.3'
workflows:
    '.github/workflows/governance.yml':
        - 'hyperpolymath/standards@$OLD'
    '.github/workflows/scorecard.yml':
        - 'hyperpolymath/standards@$OLD'
dependencies:
    'hyperpolymath/standards@$OLD':
        ref: '$OLD'
        commit: 'sha1-$OLD'
        owner_id: 1
        repo_id: 2
EOF
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" add -A; git -C "$R" commit -q -m init
printf '\n# staged edit\n' >> "$R/.github/workflows/governance.yml"
git -C "$R" add .github/workflows/governance.yml
printf '\n# unstaged edit\n' >> "$R/.github/workflows/governance.yml"
git -C "$R" diff --cached --binary > "$TEST_DIR/index-before"
cp "$R/.github/workflows/actions.lock" "$TEST_DIR/lock-before"
cp "$R/.github/workflows/governance.yml" "$TEST_DIR/governance-before"
cp "$R/.github/workflows/scorecard.yml" "$TEST_DIR/scorecard-before"
mk_consumer "$ROOT/success"
set +e
OUT=$(bash "$PROP" --fix --to "$TARGET" "$ROOT" 2>&1)
RC=$?
set -e
git -C "$R" diff --cached --binary > "$TEST_DIR/index-after"
try "refused relock exits nonzero" test "$RC" -eq 1
try "refused relock is reported" contains LOCK-REFUSED "$OUT"
try "refused relock leaves lock unchanged" cmp -s "$TEST_DIR/lock-before" "$R/.github/workflows/actions.lock"
try "refused relock preserves index without staging pins" cmp -s "$TEST_DIR/index-before" "$TEST_DIR/index-after"
try "refused relock leaves branch unchanged" test "$(git -C "$R" branch --show-current)" = main
try "refused relock retains staged workflow edit" file_has "$R/.github/workflows/governance.yml" '# staged edit'
try "refused relock retains unstaged workflow edit" file_has "$R/.github/workflows/governance.yml" '# unstaged edit'
try "refused relock restores an edited workflow byte for byte" cmp -s "$TEST_DIR/governance-before" "$R/.github/workflows/governance.yml"
try "refused relock restores an unedited workflow byte for byte" cmp -s "$TEST_DIR/scorecard-before" "$R/.github/workflows/scorecard.yml"
try "refused relock reports skipped staging" contains 'staging skipped' "$OUT"
try "refused relock does not prevent other repo fixes" file_has "$ROOT/success/.github/workflows/governance.yml" "governance-reusable.yml@${TARGET}"

# ── 12. A pin under the former owner is moved to the canonical owner ────────
# Actions does not redirect a job-level `uses:` across a repository transfer,
# so hyperpolymath/standards/...@<any sha> never resolves.
R="$TEST_DIR/former-owner"; mk_consumer "$R" hyperpolymath
OUT=$(bash "$PROP" --to "$TARGET" "$R")
try "former-owner pin is reported BEHIND" contains BEHIND "$OUT"
bash "$PROP" --fix --to "$TARGET" "$R" >/dev/null
try "former-owner pin moved to canonical owner at target" file_has "$R/.github/workflows/governance.yml" "metadatastician/standards/.github/workflows/governance-reusable.yml@${TARGET}"
try "no former-owner pin survives the fix" not_contains "hyperpolymath/standards" "$(cat "$R"/.github/workflows/*.yml)"

# ── 13. A former-owner pin already AT the target is still not FRESH ─────────
R="$TEST_DIR/former-owner-at-target"; mk_consumer "$R" hyperpolymath
sed -i "s#standards/\(.github/workflows/[a-z-]*\.yml\)@${OLD}#standards/\1@${TARGET}#" "$R"/.github/workflows/*.yml
OUT=$(bash "$PROP" --to "$TARGET" "$R")
try "former-owner pin at target is not FRESH" contains BEHIND "$OUT"
bash "$PROP" --fix --to "$TARGET" "$R" >/dev/null
try "former-owner pin at target is moved" file_has "$R/.github/workflows/scorecard.yml" "metadatastician/standards/.github/workflows/scorecard-reusable.yml@${TARGET}"

echo "----------------------------------------"
echo "$PASS/$TOTAL test cases passed."
[ "$PASS" -eq "$TOTAL" ] || { echo "Some propagation tests FAILED."; exit 1; }
echo "All propagation tests passed!"
exit 0
