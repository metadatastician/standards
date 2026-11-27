#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# post-pin-bump-hook-test.sh — offline known-answer tests for the post-pin-bump
# hook (Option A) in scripts/regen-dependabot-locks.sh: phase 1 (apply defers a
# repository that carries scripts/post-pin-bump.sh), phase 2 (hook-prepare runs
# the hook under `env -i`, with a timeout, and records what it changed) and
# phase 3 (hook-apply treats that result as UNTRUSTED, re-derives the bump, reads
# .github/post-pin-bump.paths from the default branch and commits only
# allow-listed files).
#
# The repair scripts and `gh` are stubbed exactly as in
# regen-dependabot-locks-test.sh; the hook itself is REAL and runs for real, so
# what is tested is the pipeline from a hook's bytes to a commit. A refusal is
# only a pass when nothing at all was committed.
#
# Run: bash scripts/tests/post-pin-bump-hook-test.sh

# The hook bodies below are deliberately single-quoted: they run later, in the hook.
# shellcheck disable=SC2016,SC1091
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
# has <label> <needle> <haystack>
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — '$2' not in '$3'" ;; esac; }

# --- stubs -----------------------------------------------------------------
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for s in relock-sha-keys complete-job-refs prune-stale close-lock update-actions-lock check-lock-sync check-lock-pin-contract; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLS/$s.sh"
done
cat > "$TOOLS/bump-action-pins.sh" <<'STUB'
#!/usr/bin/env bash
cd "$1" || exit 2
case "${BUMP_ACTION:-edit}" in
  edit)  sed -i 's/@1111111111111111111111111111111111111111/@5555555555555555555555555555555555555555/' .github/workflows/ci.yml
         printf '.github/workflows/ci.yml\ta/b\t111111111111\t555555555555\tbumped\n' ;;
  edit2) sed -i 's/@1111111111111111111111111111111111111111/@6666666666666666666666666666666666666666/' .github/workflows/ci.yml
         printf '.github/workflows/ci.yml\ta/b\t111111111111\t666666666666\tbumped\n' ;;
esac
exit 0
STUB

cat > "$WORK/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = actions-lock ]; then echo "  - 'a/b@v2'" >> .github/workflows/actions.lock; exit 0; fi
if [ "$1 $2" = "api --paginate" ] && [[ "$3" == repos/*/pulls\?* ]]; then echo "${PRS_JSON:-[]}"; exit 0; fi
if [ "$1 $2" = "api graphql" ]; then cat > "$GH_CAPTURE"; echo "graphql" >> "$GH_LOG"; echo 2222222222222222222222222222222222222222; exit 0; fi
if [ "$1" = api ] && [ "$2" = repos/o/r ] && [ "$3" = --jq ]; then case "$4" in .visibility) echo "${VIS:-public}" ;; *) echo main ;; esac; exit 0; fi
if [ "$1" = api ] && [[ "$2" == repos/o/r/commits/* ]]; then
  case "${4:-}" in *author*) echo 'estate-applier[bot]' ;; *) echo "$MAIN_SHA" ;; esac; exit 0
fi
if [ "$1 $2 $3" = "api -X POST" ] && [[ "$4" == repos/*/git/refs ]]; then exit 0; fi
if [ "$1 $2 $3" = "api -X POST" ] && [[ "$4" == repos/*/pulls ]]; then echo "POST-PR" >> "$GH_LOG"; echo 42; exit 0; fi
exit 1
EOF
chmod +x "$WORK/gh"
export GH_BIN="$WORK/gh" REGEN_TOOLS="$TOOLS" GH_CAPTURE="$WORK/payload.json" GH_LOG="$WORK/gh.log" APPLIER_SLUG=estate-applier
export HOOK_SANDBOX=none

# shellcheck source=../regen-dependabot-locks.sh
source "$TARGET"

# Clone the local fixture instead of github.com; the rest is the real code.
clone_branch() { git clone --quiet "$FIXTURE" "$1" 2>/dev/null; }

# fixture <name> <hook body|-> <allow-list text|->: a repository with a workflow
# and its lock; a hook and an allow-list unless given as '-'. deps.lock is the
# file a well-behaved hook rewrites.
fixture() {
  local d="$WORK/repo-$1"
  rm -rf "$d"; mkdir -p "$d/.github/workflows" "$d/scripts" "$d/docs"
  git -C "$d" init --quiet
  printf 'jobs:\n  a:\n    steps:\n      - uses: a/b@1111111111111111111111111111111111111111 # v1\n' > "$d/.github/workflows/ci.yml"
  printf "workflows:\n  '.github/workflows/ci.yml':\n  - 'a/b@v1'\n" > "$d/.github/workflows/actions.lock"
  echo 'old' > "$d/deps.lock"
  echo 'x' > "$d/docs/keep.txt"
  if [ "$2" != - ]; then printf '%s\n' "$2" > "$d/$HOOK_SCRIPT"; fi
  if [ "$3" != - ]; then printf '%s\n' "$3" > "$d/$HOOK_PATHS"; fi
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit --quiet -m init
  printf '%s' "$d"
}

GOOD_HOOK='echo "new from $(grep -o "@[0-9a-f]\{12\}" .github/workflows/ci.yml | head -1)" > deps.lock'
ALLOW='deps.lock'

# pipeline <name> <hook body|-> <allow|->: phases 1 and 2 for real, leaving the
# result in $RES and the deferral in $DEFER. Phase 3 is run by the caller.
pipeline() {
  FIXTURE="$(fixture "$1" "$2" "$3")"
  MAIN_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"; export MAIN_SHA
  DEFER="$WORK/defer-$1"; RES="$WORK/res-$1"; rm -rf "$DEFER" "$RES"; mkdir -p "$DEFER"
  : > "$GH_LOG"; rm -f "$GH_CAPTURE"
  P1="$(HOOK_DEFER_DIR="$DEFER" bump_main o/r '[]' 2>/dev/null)"
  HOOK_DEFER_DIR="$DEFER" HOOK_RESULT_DIR="$RES" hook_prepare >/dev/null 2>&1
}
# phase3 [env...]: run phase 3 on $RES with a token for owner o.
res1() { find "$RES" -mindepth 1 -maxdepth 1 -type d | head -1; }
phase3() { ( for a in "$@"; do export "${a?}"; done; REGEN_TOKENS="o=tok" HOOK_DEFER_DIR="$DEFER" HOOK_RESULT_DIR="$RES" hook_apply_main 2>&1 ); }
commit_paths() { jq -r '.variables.in.fileChanges.additions | map(.path) | sort | join(",")' "$GH_CAPTURE" 2>/dev/null; }
n_calls() { grep -c "^$1\$" "$GH_LOG" 2>/dev/null || true; }
nothing_committed() { [ ! -e "$GH_CAPTURE" ] && [ "$(n_calls graphql)" = 0 ] && [ "$(n_calls POST-PR)" = 0 ]; }

# === phase 1: apply defers a hook repository ================================
pipeline p1 "$GOOD_HOOK" "$ALLOW"
expect "a hook repo is deferred, not given a PR" "o/r@main	hook-deferred" "$P1"
expect "…no commit and no PR in phase 1" yes "$(nothing_committed && echo yes || echo no)"
d1="$(find "$DEFER" -mindepth 1 -maxdepth 1 -type d | head -1)"
expect "…the deferral carries a tree and a meta row" "yes" "$([ -f "$d1/tree.tar" ] && [ -f "$d1/meta.tsv" ] && echo yes || echo no)"
expect "…the meta row names repo, branch, head and a 64-hex pin hash" "o/r main $MAIN_SHA 1" \
  "$(awk -F'\t' '{print $1, $2, $3, ($4 ~ /^[0-9a-f]{64}$/)}' "$d1/meta.tsv")"
tree_list="$(tar -tf "$d1/tree.tar")"; tree_lock="$(tar -xOf "$d1/tree.tar" ./.github/workflows/actions.lock)"; tree_ci="$(tar -xOf "$d1/tree.tar" ./.github/workflows/ci.yml)"
tree_ok=no; case "$tree_list" in *./.git/*) ;; *) case "$tree_lock" in *a/b@v2*) case "$tree_ci" in *5555*) tree_ok=yes ;; esac ;; esac ;; esac
expect "…the tree holds the relocked lock, the bumped workflow and no .git" "yes" "$tree_ok"

FIXTURE="$(fixture p1plain - -)"; MAIN_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"; export MAIN_SHA; : > "$GH_LOG"; rm -f "$GH_CAPTURE"
out="$(HOOK_DEFER_DIR="$WORK/defer-plain" bump_main o/r '[]' 2>/dev/null)"
expect "with no hook the behaviour is unchanged: a PR is opened" "o/r@main	pr-opened #42 (2222222222222222222222222222222222222222)" "$out"
expect "…carrying the workflow and the lock only" ".github/workflows/actions.lock,.github/workflows/ci.yml" "$(commit_paths)"
expect "…and nothing was deferred" no "$([ -d "$WORK/defer-plain" ] && echo yes || echo no)"

FIXTURE="$(fixture p1nodefer "$GOOD_HOOK" "$ALLOW")"; MAIN_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"; export MAIN_SHA; : > "$GH_LOG"; rm -f "$GH_CAPTURE"
out="$(bump_main o/r '[]' 2>/dev/null)"
expect "a hook repo with nowhere to defer is refused, never PR'd with stale derived files" "o/r@main	bump-hook-not-deferred" "$out"
expect "…and nothing was committed" yes "$(nothing_committed && echo yes || echo no)"
out="$(DRY_RUN=1 bump_main o/r '[]' 2>/dev/null)"
expect "DRY_RUN says the repo would be deferred" "o/r@main	would-bump 1 (hook: deferred)" "$out"

# === phase 2: hook-prepare ==================================================
ENVHOOK='{ echo "argc=$#"; echo "pbb=${POST_PIN_BUMP:-}"; echo "tok=${GH_TOKEN:-}${GITHUB_TOKEN:-}${SECRET_THING:-}"; echo "home=${HOME:-}"; env | wc -l; } > deps.lock'
export SECRET_THING=leak GH_TOKEN=leak GITHUB_TOKEN=leak
pipeline p2 "$ENVHOOK" "$ALLOW"
unset SECRET_THING GH_TOKEN GITHUB_TOKEN
r1="$(res1)"
expect "the hook ran and was ok" ok "$(cat "$r1/status")"
got="$(cat "$r1/files/deps.lock")"
has "the hook got POST_PIN_BUMP=1" "pbb=1" "$got"
has "…and no arguments" "argc=0" "$got"
has "…and no token or other variable from the job" "tok=" "$got"
case "$got" in *leak*) bad "the hook saw a secret from the job's environment" ;; *) ok "…the job's secrets did not reach it" ;; esac
expect "…its whole environment is a handful of variables" yes "$([ "$(tail -1 <<<"$got")" -le 8 ] && echo yes || echo no)"
expect "a changed path is recorded with its mode" "100644 deps.lock" "$(tr '\0' ' ' < "$r1/changed.nul" | sed 's/ $//')"

pipeline p2fail 'echo oops; exit 3' "$ALLOW"
expect "a failing hook is recorded, with its code" "hook-failed rc=3" "$(cat "$(res1)/status")"
out="$(phase3)"; rc=$?
has "…and phase 3 refuses it loudly" "hook-refused: hook-failed rc=3" "$out"
expect "…failing the run" 1 "$rc"
expect "…with nothing committed" yes "$(nothing_committed && echo yes || echo no)"

pipeline p2slow 'sleep 20' "$ALLOW" >/dev/null
HOOK_TIMEOUT=1 HOOK_DEFER_DIR="$DEFER" HOOK_RESULT_DIR="$WORK/res-p2slow-b" hook_prepare >/dev/null 2>&1
expect "a hook that runs too long is killed and recorded" "hook-timeout" "$(cat "$(find "$WORK/res-p2slow-b" -mindepth 2 -maxdepth 2 -name status | head -1)")"

pipeline p2mix 'echo n > deps.lock; echo created > docs/new.txt; rm docs/keep.txt; ln -s /etc/passwd link; chmod +x deps.lock' "$ALLOW"
expect "adds, edits, deletions and symlinks are all recorded" "000000 docs/keep.txt|100644 docs/new.txt|100755 deps.lock|120000 link" \
  "$(tr '\0' '\n' < "$(res1)/changed.nul" | paste -d' ' - - | sort | paste -sd'|')"
expect "…a symlink's target is never copied into the result" no "$([ -e "$(res1)/files/link" ] && echo yes || echo no)"

# === phase 3: hook-apply ====================================================
pipeline ok "$GOOD_HOOK" "$ALLOW"
out="$(phase3)"; rc=$?
expect "an allow-listed change lands" 0 "$rc"
has "…as one PR" "o/r@main	pr-opened #42" "$out"
expect "…in ONE commit with the workflow, the lock and the hook's file" ".github/workflows/actions.lock,.github/workflows/ci.yml,deps.lock" "$(commit_paths)"
expect "…the hook's bytes are what is committed" "new from @555555555555" "$(jq -r '.variables.in.fileChanges.additions[] | select(.path=="deps.lock") | .contents' "$GH_CAPTURE" | base64 -d)"
expect "…guarded by the default head" "$MAIN_SHA" "$(jq -r .variables.in.expectedHeadOid "$GH_CAPTURE")"
has "…and the PR body names the hook file" "- deps.lock" "$(jq -r .variables.in.message.body "$GH_CAPTURE")"

pipeline quiet 'true' "$ALLOW"
out="$(phase3)"; rc=$?
expect "a hook with nothing to change still gets the plain bump PR" ".github/workflows/actions.lock,.github/workflows/ci.yml" "$(commit_paths)"

# refuse <label> <hook body> <allow text> <message fragment>: a refusal must say
# why, fail the run, and commit nothing at all.
refuse() {
  pipeline "r$RC" "$2" "$3"; out="$(phase3)"; rc=$?
  has "$1: refused loudly" "$4" "$out"
  expect "$1: run fails" 1 "$rc"
  expect "$1: nothing committed" yes "$(nothing_committed && echo yes || echo no)"
  RC=$((RC + 1))
}
RC=0
refuse "a path outside the allow-list" 'echo n > deps.lock; echo n > docs/keep.txt' "$ALLOW" "not in .github/post-pin-bump.paths: docs/keep.txt"
refuse "a repo with no allow-list file" "$GOOD_HOOK" - "not in .github/post-pin-bump.paths: deps.lock"
refuse "an empty allow-list" "$GOOD_HOOK" '# nothing' "not in .github/post-pin-bump.paths: deps.lock"
refuse "a workflow edit by the hook" 'echo "# pwned" >> .github/workflows/ci.yml' $'deps.lock\n.github/workflows/ci.yml' "invalid .github/post-pin-bump.paths"
refuse "…even when the allow-list does not name it" 'echo "# pwned" >> .github/workflows/ci.yml' "$ALLOW" "path not allowed: .github/workflows/ci.yml"
refuse "a rewrite of the hook's own script" 'echo "echo pwned" >> scripts/post-pin-bump.sh' "$ALLOW" "path not allowed: scripts/post-pin-bump.sh"
refuse "a rewrite of the allow-list by the hook" 'echo "docs/" >> .github/post-pin-bump.paths' "$ALLOW" "path not allowed: .github/post-pin-bump.paths"
refuse "an allow-list that reaches the workflows" 'true' $'.github/\ndeps.lock' "invalid .github/post-pin-bump.paths"
refuse "an allow-list with a traversal" 'true' '../outside' "invalid .github/post-pin-bump.paths"
refuse "an absolute allow-list pattern" 'true' '/etc/passwd' "invalid .github/post-pin-bump.paths"
refuse "a deletion" 'rm docs/keep.txt' 'docs/' "deletion: docs/keep.txt"
refuse "a symlink" 'ln -s /etc/passwd docs/link' 'docs/' "not a regular file (mode 120000): docs/link"
refuse "a new executable file" 'echo x > docs/run.sh; chmod +x docs/run.sh' 'docs/' "file mode change: docs/run.sh"
refuse "a changed mode on an existing file" 'chmod +x deps.lock' "$ALLOW" "file mode change: deps.lock"
refuse "an oversized file" 'head -c 1048577 /dev/zero | tr "\0" a > deps.lock' "$ALLOW" "over 1048576 bytes: deps.lock"
refuse "too many files" 'for i in $(seq 1 201); do echo $i > docs/f$i.txt; done' 'docs/' "more than 200 changed paths"

# A directory prefix in the allow-list covers everything below it, and only that.
pipeline dir 'echo a > docs/a.txt; mkdir docs/sub; echo b > docs/sub/b.txt' $'# generated docs\ndocs/'
out="$(phase3)"; rc=$?
expect "a directory prefix allows files below it" ".github/workflows/actions.lock,.github/workflows/ci.yml,docs/a.txt,docs/sub/b.txt" "$(commit_paths)"
pipeline dir2 'echo a > docs2.txt' 'docs/'
out="$(phase3)"
has "…but not a sibling that merely shares the name" "not in .github/post-pin-bump.paths: docs2.txt" "$out"

# --- forged results: phase 2's output is untrusted --------------------------
forge() { # forge <name>: a good result to tamper with
  pipeline "$1" "$GOOD_HOOK" "$ALLOW"; : > "$GH_LOG"; rm -f "$GH_CAPTURE"
}
forge f1; printf '100644\0../escape\0' > "$(res1)/changed.nul"; echo pwn > "$RES/escape"
out="$(phase3)"
has "a forged traversal path is refused" "path not allowed" "$out"
expect "…and nothing committed" yes "$(nothing_committed && echo yes || echo no)"

forge f2; rm "$(res1)/files/deps.lock"; ln -s /etc/hostname "$(res1)/files/deps.lock"
out="$(phase3)"
has "a symlink planted in the result files is refused" "unreadable or symlinked: deps.lock" "$out"
expect "…and nothing committed" yes "$(nothing_committed && echo yes || echo no)"

forge f3; rm -rf "$(res1)/files"; mkdir -p "$WORK/elsewhere"; echo big > "$WORK/elsewhere/deps.lock"; ln -s "$WORK/elsewhere" "$(res1)/files"
out="$(phase3)"
has "a symlinked files/ directory is refused" "unreadable or symlinked: deps.lock" "$out"

forge f4; printf '100644\0docs/injected.txt\0' > "$(res1)/changed.nul"; mkdir -p "$(res1)/files/docs"; echo i > "$(res1)/files/docs/injected.txt"
out="$(phase3)"
has "a path the allow-list on the default branch does not name is refused, whatever the result says" "not in .github/post-pin-bump.paths: docs/injected.txt" "$out"

forge f5; echo "ok" > "$(res1)/status"; printf 'o/r\tmain\t%s\tnothex\n' "$MAIN_SHA" | tee "$DEFER"/*/meta.tsv > "$(res1)/meta.tsv"
out="$(phase3)"
has "a malformed meta row is refused" "hook-bad-meta" "$out"
forge f5b; printf 'o/r; rm -rf /\tmain\t%s\t%s\n' "$MAIN_SHA" "$(printf '0%.0s' $(seq 64))" | tee "$DEFER"/*/meta.tsv > "$(res1)/meta.tsv"
out="$(phase3)"
has "a repo name with shell metacharacters is refused" "hook-bad-meta" "$out"

forge f6; sed -i "s/$MAIN_SHA/3333333333333333333333333333333333333333/" "$(res1)/meta.tsv" "$DEFER"/*/meta.tsv
out="$(phase3)"
has "a result for another head is stale" "hook-stale-head" "$out"
expect "…and nothing committed" yes "$(nothing_committed && echo yes || echo no)"

forge f7
out="$(phase3 BUMP_ACTION=edit2)"
has "a result for pins that have since moved is stale" "hook-stale-pins" "$out"
expect "…and nothing committed" yes "$(nothing_committed && echo yes || echo no)"

forge f8; : > "$(res1)/status"
out="$(phase3)"
has "a result with no status is refused" "hook-refused" "$out"

# --- reconciliation against the authoritative deferral ----------------------
forge s1; d_a="$(find "$DEFER" -mindepth 1 -maxdepth 1 -type d | head -1)"; d_b="$DEFER/d.OTHER"
mkdir -p "$d_b"; cp "$d_a/tree.tar" "$d_b/"; sed 's#^o/r#o/s#' "$d_a/meta.tsv" > "$d_b/meta.tsv"
cp "$d_b/meta.tsv" "$(res1)/meta.tsv"
out="$(phase3)"; rc=$?
has "a result carrying another deferred repo's row is refused" "hook-result-mismatch" "$out"
has "…and the deferral without a result is named" "hook-result-missing" "$out"
expect "…failing the run" 1 "$rc"
expect "…with nothing committed" yes "$(nothing_committed && echo yes || echo no)"

forge s2; rm -rf "$(res1)"
out="$(phase3)"; rc=$?
has "a missing result is a loud failure" "hook-result-missing" "$out"
expect "…failing the run" 1 "$rc"
expect "…with nothing committed" yes "$(nothing_committed && echo yes || echo no)"

forge s3; rr="$(res1)"; mkdir -p "$RES/0"; cp "$rr/meta.tsv" "$RES/0/meta.tsv"
out="$(phase3)"; rc=$?
has "an extra result (a name no deferral asked for) is named" "hook-result-extra: result '0'" "$out"
expect "…and fails the run" 1 "$rc"

forge s4; rr="$(res1)"; cp -r "$rr" "$RES/dup"
out="$(phase3)"; rc=$?
has "a duplicate of a real result under another name is extra" "hook-result-extra: result 'dup'" "$out"
expect "…and fails the run" 1 "$rc"

forge s5; rr="$(res1)"; ln -s "$rr" "$RES/linked"
out="$(phase3)"; rc=$?
has "a symlinked result entry is extra" "hook-result-extra: result 'linked'" "$out"

forge s6; mv "$(res1)" "$RES/0"
out="$(phase3)"; rc=$?
has "a result named 0 does not stand in for a deferral" "hook-result-missing" "$out"
has "…and is itself extra" "hook-result-extra: result '0'" "$out"

forge s7
out="$(phase3 PRS_JSON='[{"head":{"ref":"'"$BUMP_PR_BRANCH"'","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}}]')"; rc=$?
has "an already-open bump PR is a loud failure, not a quiet skip" "bump-pr-open: a bump PR is already open" "$out"
expect "…failing the run" 1 "$rc"

forge s8
out="$(phase3 BUMP_ACTION=none)"; rc=$?
expect "a re-derivation that finds nothing to bump fails the run" 1 "$rc"

# --- a private or internal repository is never deferred ----------------------
for v in private internal unknownvalue; do
  FIXTURE="$(fixture priv "$GOOD_HOOK" "$ALLOW")"; MAIN_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"; export MAIN_SHA
  : > "$GH_LOG"; rm -f "$GH_CAPTURE"; rm -rf "$WORK/defer-priv"; mkdir -p "$WORK/defer-priv"
  out="$(VIS=$v HOOK_DEFER_DIR="$WORK/defer-priv" bump_main o/r '[]' 2>&1)"
  has "a $v repository with a hook is refused by name" "hook-refused-nonpublic: visibility is $v" "$out"
  expect "…nothing was deferred ($v)" 0 "$(find "$WORK/defer-priv" -mindepth 1 | wc -l | tr -d ' ')"
  expect "…and nothing committed ($v)" yes "$(nothing_committed && echo yes || echo no)"
done

# --- the sandbox: what the container is allowed to see ----------------------
cat > "$WORK/docker" <<'EOS'
#!/usr/bin/env bash
# Stub: log argv, then run the in-container command natively on the mounted tree.
printf '%s\n' "$@" > "$DOCKER_LOG"
[ "$1" = run ] || exit 0
src=""; args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  [ "${args[$i]}" = -v ] && src="${args[$((i+1))]%%:*}"
  i=$((i+1))
done
cd "$src" || exit 125
# the command is everything after the image
img=""; for i in "${!args[@]}"; do case "${args[$i]}" in "$HOOK_IMAGE") img=$i ;; esac; done
rest=("${args[@]:$((img+1))}")
exec env -i PATH=/usr/bin:/bin POST_PIN_BUMP=1 HOME=/tmp "${rest[@]}"
EOS
chmod +x "$WORK/docker"
export DOCKER_LOG="$WORK/docker.log"
pipeline sb "$GOOD_HOOK" "$ALLOW" >/dev/null
rm -rf "$WORK/res-sb2"
HOOK_SANDBOX=docker DOCKER_BIN="$WORK/docker" HOOK_IMAGE="img@sha256:$(printf 'a%.0s' $(seq 64))" HOOK_DEFER_DIR="$DEFER" HOOK_RESULT_DIR="$WORK/res-sb2" hook_prepare >/dev/null 2>&1
dl="$(tr '\n' ' ' < "$DOCKER_LOG" 2>/dev/null)"
has "the hook runs in a container" "run --rm" "$dl"
has "…with no network" "--network none" "$dl"
has "…as an unprivileged uid" "--user 65534:65534" "$dl"
has "…with every capability dropped" "--cap-drop ALL" "$dl"
has "…and no privilege escalation" "--security-opt no-new-privileges" "$dl"
has "…and a read-only root" "--read-only" "$dl"
mounts="$(grep -c '^-v$' "$DOCKER_LOG")"
expect "…with exactly one mount" 1 "$mounts"
case "$dl" in *"${RUNNER_TEMP:-/nonexistent-runner}"*|*_actions*|*"$DEFER"*|*docker.sock*) bad "…the mount list leaks runner state" ;; *) ok "…which is one tree copy, not the runner's state or the deferrals" ;; esac
case "$dl" in *--privileged*|*"--network host"*|*docker.sock*) bad "…no privileged or host-network flags" ;; *) ok "…no privileged or host-network flags" ;; esac
expect "…and the result is the same as an unsandboxed run" "new from @555555555555" "$(cat "$(find "$WORK/res-sb2" -name deps.lock | head -1)")"
out="$(HOOK_SANDBOX=docker DOCKER_BIN="$WORK/docker" HOOK_DEFER_DIR="$DEFER" HOOK_RESULT_DIR="$WORK/res-sb3" hook_prepare 2>&1)"
has "a missing HOOK_IMAGE is an error, not an unsandboxed run" "HOOK_IMAGE is not set" "$(cat "$WORK"/res-sb3/*/hook.log 2>/dev/null)$out"
out="$(GITHUB_ACTIONS=true HOOK_SANDBOX=none HOOK_DEFER_DIR="$DEFER" HOOK_RESULT_DIR="$WORK/res-sb4" hook_prepare 2>&1)"
has "HOOK_SANDBOX=none is refused on a runner" "refused on a runner" "$(cat "$WORK"/res-sb4/*/hook.log 2>/dev/null)$out"

# --- credentials -----------------------------------------------------------
forge t1
out="$(REGEN_TOKENS="other=tok" HOOK_DEFER_DIR="$DEFER" HOOK_RESULT_DIR="$RES" hook_apply_main 2>&1)"; rc=$?
has "a result for an owner with no installation token is named" "no installation token for 'o'" "$out"
expect "…and fails the run" 1 "$rc"
expect "…with nothing committed" yes "$(nothing_committed && echo yes || echo no)"

# --- DRY_RUN ---------------------------------------------------------------
pipeline dry "$GOOD_HOOK" "$ALLOW"
out="$(phase3 DRY_RUN=1)"; rc=$?
has "DRY_RUN reports what would land" "would-bump 1 (+1 hook file(s))" "$out"
expect "…and commits nothing" yes "$(nothing_committed && echo yes || echo no)"

echo
echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
