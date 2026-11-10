#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# regen-dependabot-locks-test.sh — offline known-answer tests for
# scripts/regen-dependabot-locks.sh.
#
# The repair scripts it drives have their own suites, so they are stubbed here
# and each stub's verdict is set per case. What is under test is the bot's OWN
# logic: that it keeps only actions.lock, refuses every unsafe tree with a
# distinct verdict instead of committing it, filters PRs correctly, builds a
# commit that cannot land on a moved branch, and reports a missing credential
# rather than claiming a clean sweep.
#
# Run: bash scripts/tests/regen-dependabot-locks-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET:-$SCRIPT_DIR/../regen-dependabot-locks.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
# Record a passing case named $1.
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
# Record a failing case named $1.
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
# expect <label> <want> <got>
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }

# --- stubs -----------------------------------------------------------------
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for s in relock-sha-keys complete-job-refs prune-stale; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLS/$s.sh"
done
# close-lock also keeps a copy of the --prior lock it was given, when asked.
printf '#!/usr/bin/env bash\nif [ "${1:-}" = --prior ] && [ -n "${PRIOR_COPY:-}" ]; then cp "$2" "$PRIOR_COPY"; fi\nexit "${CLOSE_RC:-0}"\n' > "$TOOLS/close-lock.sh"
printf '#!/usr/bin/env bash\nexit "${VERIFY_RC:-0}"\n' > "$TOOLS/update-actions-lock.sh"
printf '#!/usr/bin/env bash\nexit "${SYNC_RC:-0}"\n' > "$TOOLS/check-lock-sync.sh"
printf '#!/usr/bin/env bash\nexit "${PIN_RC:-0}"\n' > "$TOOLS/check-lock-pin-contract.sh"

# The `gh` stub. `actions-lock` (update mode) applies $TOOL_ACTION to the cwd;
# `api graphql` records its stdin payload and answers with a commit oid.
cat > "$WORK/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = actions-lock ]; then
  case "${TOOL_ACTION:-none}" in
    bump)    echo "  - 'a/b@v2'" >> .github/workflows/actions.lock ;;
    rewrite) echo "  - 'a/b@v2'" >> .github/workflows/actions.lock
             sed -i 's/@1111111111111111111111111111111111111111/@v2/' .github/workflows/ci.yml
             echo junk > .github/workflows/new-by-tool.yml ;;
    dollar)  echo "  - '\$/.github/actions/x'" >> .github/workflows/actions.lock ;;
    fail)    exit 1 ;;
    partial) echo "  - 'a/b@v2'" >> .github/workflows/actions.lock; exit 1 ;;
    none)    : ;;
  esac
  exit 0
fi
if [ "$1" = api ] && [[ "$2" == repos/*/contents/* ]]; then
  case "${CONTENTS:-200}" in
    200) exit 0 ;;
    404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    *)   echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1 ;;
  esac
fi
if [ "$1 $2" = "api --paginate" ] && [[ "$3" == repos/*/pulls\?* ]]; then
  [ -n "${PULLS_FAIL:-}" ] && exit 1
  echo '[]'; exit 0
fi
if [ "$1 $2" = "api --paginate" ] && [[ "$3" == installation/repositories* ]]; then
  [ "$GH_TOKEN" = bad ] && exit 1
  echo "$GH_TOKEN/r"; exit 0
fi
if [ "$1 $2" = "api graphql" ]; then
  cat > "$GH_CAPTURE"
  echo 2222222222222222222222222222222222222222
  exit 0
fi
# Default-branch repair (REGEN_MAIN=1): repo metadata, heads, refs and PRs.
if [ "$1" = api ] && [ "$2" = repos/o/r ] && [ "$3" = --jq ]; then echo "${DEFAULT_BRANCH:-main}"; exit 0; fi
if [ "$1" = api ] && [ "$2" = repos/o/r/commits/chore/regenerate-actions-lock ]; then
  [ -n "${LEFTOVER_MSG:-}" ] || exit 1
  printf '%s\n' "$LEFTOVER_MSG"; exit 0
fi
if [ "$1" = api ] && [[ "$2" == repos/o/r/commits/* ]]; then echo "$MAIN_SHA"; exit 0; fi
if [ "$1 $2 $3" = "api -X POST" ] && [[ "$4" == repos/*/git/refs ]]; then
  echo "POST-REF $*" >> "$GH_LOG"; [ -n "${REF_EXISTS:-}" ] && exit 1; exit 0
fi
if [ "$1 $2 $3" = "api -X PATCH" ]; then echo "PATCH-REF $*" >> "$GH_LOG"; exit 0; fi
if [ "$1 $2 $3" = "api -X POST" ] && [[ "$4" == repos/*/pulls ]]; then
  echo "POST-PR $*" >> "$GH_LOG"; [ -n "${PR_FAIL:-}" ] && exit 1; echo 42; exit 0
fi
exit 1
EOF
chmod +x "$WORK/gh"
export GH_BIN="$WORK/gh" REGEN_TOOLS="$TOOLS" GH_CAPTURE="$WORK/payload.json"

# shellcheck source=../regen-dependabot-locks.sh
source "$TARGET"

# A fresh fixture repo: one SHA-pinned workflow and a lock.
fixture() {
  local d="$WORK/repo-$1"
  rm -rf "$d"; mkdir -p "$d/.github/workflows"
  git -C "$d" init --quiet
  printf 'jobs:\n  a:\n    steps:\n      - uses: a/b@1111111111111111111111111111111111111111 # v1\n' \
    > "$d/.github/workflows/ci.yml"
  printf "workflows:\n  '.github/workflows/ci.yml':\n  - 'a/b@v1'\n" > "$d/.github/workflows/actions.lock"
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit --quiet -m init
  printf '%s' "$d"
}

# --- regen_lock verdicts ---------------------------------------------------
d="$(fixture bump)"
expect "a lock-only change is 'changed'" changed "$(TOOL_ACTION=bump regen_lock "$d" 2>/dev/null)"
expect "…and only actions.lock differs" " M .github/workflows/actions.lock" "$(git -C "$d" status --porcelain)"

d="$(fixture rewrite)"
expect "tool workflow rewrites are discarded, lock kept" changed "$(TOOL_ACTION=rewrite regen_lock "$d" 2>/dev/null)"
expect "…the SHA pin in ci.yml survives" 1 "$(grep -c '@1111111111111111111111111111111111111111' "$d/.github/workflows/ci.yml")"
expect "…the tool's new file is removed" no "$([ -e "$d/.github/workflows/new-by-tool.yml" ] && echo yes || echo no)"

d="$(fixture dollar)"
expect "a \$/ ref in the lock is refused" corrupt "$(TOOL_ACTION=dollar regen_lock "$d" 2>/dev/null)"

d="$(fixture unres)"
expect "an unresolvable edge (close-lock exit 3) is refused" unresolvable "$(TOOL_ACTION=bump CLOSE_RC=3 regen_lock "$d" 2>/dev/null)"

# close-lock is handed the lock as it stood BEFORE gh actions-lock rewrote it,
# so a leaf whose tag moved can keep its old ref: (close-lock.sh, MOVED TAGS).
d="$(fixture prior)"; cp "$d/.github/workflows/actions.lock" "$WORK/prior.want"
TOOL_ACTION=bump PRIOR_COPY="$WORK/prior.got" regen_lock "$d" >/dev/null 2>&1
expect "close-lock gets --prior: the pre-regeneration lock, byte for byte" yes \
  "$(cmp -s "$WORK/prior.want" "$WORK/prior.got" && ! cmp -s "$WORK/prior.got" "$d/.github/workflows/actions.lock" && echo yes || echo no)"
expect "…and the snapshot is not left in the checkout" " M .github/workflows/actions.lock" "$(git -C "$d" status --porcelain --untracked-files=all)"

d="$(fixture unver)"
expect "a lock the gate's verifier rejects is refused" unverified "$(TOOL_ACTION=bump VERIFY_RC=1 regen_lock "$d" 2>/dev/null)"

d="$(fixture toolfail)"
expect "a failing gh actions-lock is reported" tool-failed "$(TOOL_ACTION=fail regen_lock "$d" 2>/dev/null)"

# gh actions-lock exits 1 on a mutable @main ref it will not auto-pin, yet has
# rewritten the lock for everything else: continue, and let the verifier judge.
d="$(fixture partial)"
expect "a non-zero gh actions-lock that rewrote the lock still regenerates" changed "$(TOOL_ACTION=partial regen_lock "$d" 2>/dev/null)"
d="$(fixture partialunver)"
expect "…but the verifier still refuses a bad partial lock" unverified "$(TOOL_ACTION=partial VERIFY_RC=1 regen_lock "$d" 2>/dev/null)"

d="$(fixture current)"
expect "an already-current lock is 'current' (idempotent second run)" current "$(TOOL_ACTION=none regen_lock "$d" 2>/dev/null)"

d="$(fixture nolock)"; git -C "$d" rm --quiet .github/workflows/actions.lock
expect "a repo without actions.lock is skipped" no-lock "$(regen_lock "$d" 2>/dev/null)"

# standards#1122: composite repos are no longer refused; the repair chain and
# check-lock-sync.sh follow local composites, and the sync check decides.
d="$(fixture composite)"; mkdir -p "$d/.github/actions/x"
expect "a repo with local composite actions is regenerated" changed "$(TOOL_ACTION=bump regen_lock "$d" 2>/dev/null)"
d="$(fixture syncfail)"
expect "a lock check-lock-sync rejects is unverified, not committed" unverified "$(TOOL_ACTION=bump SYNC_RC=1 regen_lock "$d" 2>/dev/null)"

# A leaf whose ref: repeats its own SHA passes --verify-local (advisory
# `sha-as-ref`) and check-lock-sync, but the runner refuses it. The contract
# decides; a refusal (1) and a not-inspected (2) both stop the commit.
d="$(fixture pinbad)"
expect "a lock the pin contract rejects is unverified, not committed" unverified "$(TOOL_ACTION=bump PIN_RC=1 regen_lock "$d" 2>/dev/null)"
d="$(fixture pinuninspected)"
expect "a lock the pin contract cannot inspect is unverified, not committed" unverified "$(TOOL_ACTION=bump PIN_RC=2 regen_lock "$d" 2>/dev/null)"
d="$(fixture pinok)"
expect "control: the same bump with a passing contract is committed" changed "$(TOOL_ACTION=bump PIN_RC=0 regen_lock "$d" 2>/dev/null)"

# Planted control for the dirty guard: a repair step that writes anything
# besides the lock (after the restore has run) must stop the commit.
d="$(fixture dirty)"
printf '#!/usr/bin/env bash\necho x >> README.md\n' > "$TOOLS/prune-stale.sh"
expect "any change besides actions.lock is refused" dirty "$(TOOL_ACTION=bump regen_lock "$d" 2>/dev/null)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLS/prune-stale.sh"

# --- select_prs ------------------------------------------------------------
prs='[
 {"number":1,"draft":false,"user":{"login":"dependabot[bot]"},"head":{"ref":"dependabot/x","sha":"aaa","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}},
 {"number":2,"draft":false,"user":{"login":"someone"},"head":{"ref":"feat","sha":"bbb","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}},
 {"number":3,"draft":true,"user":{"login":"dependabot[bot]"},"head":{"ref":"dependabot/y","sha":"ccc","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}},
 {"number":4,"draft":false,"user":{"login":"dependabot[bot]"},"head":{"ref":"dependabot/z","sha":"ddd","repo":{"full_name":"fork/r"}},"base":{"repo":{"full_name":"o/r"}}}
]'
expect "only same-repo, non-draft Dependabot PRs are selected" "1	dependabot/x	aaa" "$(printf '%s' "$prs" | select_prs)"

# The pin applier's PRs rewrite `uses:` without the lock, so they are selected
# too, but only when a bot opened them on the applier's branch: a human on that
# branch name, or the applier bot on any other branch, is left alone.
prs='[
 {"number":5,"draft":false,"user":{"login":"estate-applier[bot]"},"head":{"ref":"chore/re-point-standards-workflow-pins","sha":"eee","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}},
 {"number":6,"draft":false,"user":{"login":"someone"},"head":{"ref":"chore/re-point-standards-workflow-pins","sha":"fff","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}},
 {"number":7,"draft":false,"user":{"login":"estate-applier[bot]"},"head":{"ref":"feat","sha":"ggg","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}}
]'
expect "the pin applier's PR is selected; same branch by a human, or the bot elsewhere, is not" \
  "5	chore/re-point-standards-workflow-pins	eee" "$(printf '%s' "$prs" | select_prs)"

# --- commit_lock -----------------------------------------------------------
d="$(fixture commit)"
oid="$(commit_lock o/r dependabot/x 3333333333333333333333333333333333333333 "$d")"
expect "commit_lock returns the new oid" 2222222222222222222222222222222222222222 "$oid"
expect "…guarded by expectedHeadOid" 3333333333333333333333333333333333333333 "$(jq -r .variables.in.expectedHeadOid "$GH_CAPTURE")"
expect "…writes exactly one file, the lock" ".github/workflows/actions.lock" "$(jq -r '.variables.in.fileChanges.additions | map(.path) | join(",")' "$GH_CAPTURE")"
expect "…with the lock's exact bytes" "$(base64 -w0 < "$d/.github/workflows/actions.lock")" "$(jq -r '.variables.in.fileChanges.additions[0].contents' "$GH_CAPTURE")"

# --- process_repo: only a 404 is a silent skip ---------------------------
expect "no lock (404) is skipped silently" "" "$(CONTENTS=404 process_repo o/r t)"
expect "a rate-limited lock probe is reported, not skipped" "o/r	api-error" "$(CONTENTS=403 process_repo o/r t 2>/dev/null)"
expect "a failed PR listing is reported" "o/r	api-error" "$(PULLS_FAIL=1 process_repo o/r t 2>/dev/null)"
expect "a repo with no open PRs prints nothing" "" "$(process_repo o/r t)"

# --- repair_main: a stale lock that already landed on the default branch ----
# Clone the local fixture instead of github.com; the rest is the real code.
clone_branch() { git clone --quiet "$FIXTURE" "$1" 2>/dev/null; }
export GH_LOG="$WORK/gh.log"
oid=2222222222222222222222222222222222222222
# fresh_main <name>: a new fixture as the default branch, an empty call log.
fresh_main() { FIXTURE="$(fixture "$1")"; MAIN_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"; export MAIN_SHA; : > "$GH_LOG"; rm -f "$GH_CAPTURE"; }

fresh_main stale
out="$(TOOL_ACTION=bump repair_main o/r '[]' 2>/dev/null)"
expect "a stale default-branch lock opens one repair PR" "o/r@main	pr-opened #42 ($oid)" "$out"
expect "…from the repair branch, created at the default head" 1 "$(grep -c "POST-REF .*ref=refs/heads/chore/regenerate-actions-lock .*sha=$MAIN_SHA" "$GH_LOG")"
expect "…its commit is guarded by the default head" "$MAIN_SHA" "$(jq -r .variables.in.expectedHeadOid "$GH_CAPTURE")"
expect "…lands on the repair branch" chore/regenerate-actions-lock "$(jq -r .variables.in.branch.branchName "$GH_CAPTURE")"
expect "…carries the repair headline, not the Dependabot one" "$REPAIR_HEADLINE" "$(jq -r .variables.in.message.headline "$GH_CAPTURE")"
expect "…writes only the lock" ".github/workflows/actions.lock" "$(jq -r '.variables.in.fileChanges.additions | map(.path) | join(",")' "$GH_CAPTURE")"
expect "…and the PR goes from the repair branch to the default branch" 1 "$(grep -c 'POST-PR .*head=chore/regenerate-actions-lock .*base=main' "$GH_LOG")"

fresh_main current
expect "a current default-branch lock opens nothing" "o/r@main	current" "$(TOOL_ACTION=none repair_main o/r '[]' 2>/dev/null)"
expect "…and touches no ref" 0 "$(grep -c . "$GH_LOG")"

fresh_main dry
expect "DRY_RUN reports the change" "o/r@main	changed" "$(DRY_RUN=1 TOOL_ACTION=bump repair_main o/r '[]' 2>/dev/null)"
expect "…and writes nothing" 0 "$(grep -c . "$GH_LOG")"

fresh_main unver
expect "a lock the verifier rejects is not proposed" "o/r@main	unverified" "$(VERIFY_RC=1 TOOL_ACTION=bump repair_main o/r '[]' 2>/dev/null)"
expect "…and no branch is created" 0 "$(grep -c . "$GH_LOG")"

fresh_main moved
expect "a default branch that moved under the clone is refused" "o/r@main	moved" "$(MAIN_SHA=4444444444444444444444444444444444444444 TOOL_ACTION=bump repair_main o/r '[]' 2>/dev/null)"

fresh_main open
open='[{"number":9,"draft":false,"user":{"login":"estate-applier[bot]"},"head":{"ref":"chore/regenerate-actions-lock","sha":"hhh","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}}]'
expect "an open repair PR is left to the PR sweep" "o/r@main	repair-pr-open" "$(TOOL_ACTION=bump repair_main o/r "$open" 2>/dev/null)"
expect "…which selects it, because a bot opened it on the repair branch" "9	chore/regenerate-actions-lock	hhh" "$(printf '%s' "$open" | select_prs)"
human='[{"number":10,"draft":false,"user":{"login":"someone"},"head":{"ref":"chore/regenerate-actions-lock","sha":"iii","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}}]'
expect "…but never a human's PR on that branch name" "" "$(printf '%s' "$human" | select_prs)"

fresh_main foreign
expect "an existing branch the script did not create is never moved" "o/r@main	repair-branch-exists" "$(REF_EXISTS=1 LEFTOVER_MSG='feat: someone else' TOOL_ACTION=bump repair_main o/r '[]' 2>/dev/null)"
expect "…no PATCH, no commit" "0 no" "$(grep -c PATCH-REF "$GH_LOG") $([ -e "$GH_CAPTURE" ] && echo yes || echo no)"

fresh_main leftover
out="$(REF_EXISTS=1 LEFTOVER_MSG="$REPAIR_HEADLINE"$'\n\n'"body" TOOL_ACTION=bump repair_main o/r '[]' 2>/dev/null)"
expect "a leftover repair branch of ours is reused" "o/r@main	pr-opened #42 ($oid)" "$out"
expect "…by force-moving it to the default head" 1 "$(grep -c "PATCH-REF .*git/refs/heads/chore/regenerate-actions-lock .*sha=$MAIN_SHA .*force=true" "$GH_LOG")"

fresh_main prfail
expect "a refused PR creation is reported with the commit" "o/r@main	pr-refused ($oid)" "$(PR_FAIL=1 TOOL_ACTION=bump repair_main o/r '[]' 2>/dev/null)"

fresh_main wired
expect "process_repo runs the default-branch repair only with REGEN_MAIN=1" "o/r@main	pr-opened #42 ($oid)" "$(REGEN_MAIN=1 TOOL_ACTION=bump process_repo o/r t 2>/dev/null)"
fresh_main unwired
expect "…and not without it" "" "$(TOOL_ACTION=bump process_repo o/r t 2>/dev/null)"

# --- missing credential ----------------------------------------------------
out="$(REGEN_TOKENS='' main 2>&1)"; rc=$?
expect "no token: exits 0" 0 "$rc"
expect "…and says nothing was examined" 1 "$(printf '%s' "$out" | grep -c 'Nothing was examined')"

# The exact string the workflow passes when the App is absent.
out="$(REGEN_TOKENS='hyperpolymath= metadatastician=' main 2>&1)"; rc=$?
expect "empty per-owner tokens (workflow shape): exits 0" 0 "$rc"
expect "…and names both owners as NOT examined" 2 "$(printf '%s' "$out" | grep -c 'NOT examined')"
expect "…and claims zero repositories" 1 "$(printf '%s' "$out" | grep -c '^examined 0 repositories$')"

# One owner's enumeration failure must not stop the other owner's sweep.
out="$(CONTENTS=404 REGEN_TOKENS='hyperpolymath=bad metadatastician=metadatastician' main 2>&1)"; rc=$?
expect "an owner's failed enumeration: exits non-zero" 1 "$rc"
expect "…names that owner as NOT examined" 1 "$(printf '%s' "$out" | grep -c "enumerate hyperpolymath's.*NOT examined")"
expect "…and still sweeps the other owner" 1 "$(printf '%s' "$out" | grep -c '^metadatastician: 1 repositories in scope$')"

# The clone URL must carry no credential (CWE-522).
expect "no token in any clone URL" 0 "$(grep -c 'x-access-token:\$token@' "$TARGET")"

echo
echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
