#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# relock-main.sh: regenerate .github/workflows/actions.lock on a new branch
# from the default branch, after checking everything it needs first.
#
# Why this exists: run by hand, `gh actions-lock` and `git clone` over SSH can
# prompt for a passphrase and then sit with no message when the network, the
# SSH port or the login is not there. This script checks each of those first,
# with a time limit on every network call, and stops with a plain message that
# says what is missing and what to run. It never prompts.
#
# What it runs is the documented sequence (docs/GOVERNANCE-SOURCE-HANDOFF.adoc,
# docs/ACTIONS-LOCK-CLOSURE-POLICY.adoc):
#
#   gh actions-lock --no-migrate-local-actions --no-narrow
#   scripts/relock-sha-keys.sh
#   scripts/complete-job-refs.sh
#   scripts/close-lock.sh
#   scripts/prune-stale.sh
#   scripts/check-lock-pin-contract.sh
#   scripts/check-lock-sync.sh
#
# It commits nothing and pushes nothing: the result is left on the new branch
# for a person to review. The lock file is written only by the tools above,
# never by hand.
#
# Usage: scripts/relock-main.sh [--check-only] [--branch NAME]
#   --check-only   run the checks, change nothing
#   --branch NAME  the branch to create (default relock/actions-lock-YYYYMMDD)
#
# Environment:
#   RELOCK_TIMEOUT       seconds allowed for each network check (default 20)
#   RELOCK_STEP_TIMEOUT  seconds allowed for each step of the sequence
#                        (default 900)
#
# Exit: 0 ready or done; 1 a step of the sequence failed; 2 a check failed;
#       64 usage.
set -uo pipefail

CHECK_ONLY=0
BRANCH="relock/actions-lock-$(date -u +%Y%m%d)"
T="${RELOCK_TIMEOUT:-20}"
ST="${RELOCK_STEP_TIMEOUT:-900}"

usage() { echo "usage: relock-main.sh [--check-only] [--branch NAME]" >&2; exit 64; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --branch) [ "$#" -ge 2 ] || usage; BRANCH=$2; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

say() { printf 'relock-main: %s\n' "$*"; }
stop() { # message, then what to do
  printf 'relock-main: STOP: %s\n' "$1" >&2
  [ -n "${2:-}" ] && printf '  what to do: %s\n' "$2" >&2
  exit 2
}

# Run a command with the network time limit; report a timeout as one.
net() {
  timeout "$T" "$@"
  local rc=$?
  [ "$rc" -eq 124 ] && return 124
  return "$rc"
}

# Never prompt: a prompt with no one able to answer is the hang this replaces.
export GIT_TERMINAL_PROMPT=0
export GH_PROMPT_DISABLED=1
: "${GIT_SSH_COMMAND:=ssh -o BatchMode=yes -o ConnectTimeout=10}"
export GIT_SSH_COMMAND

# 1. not under sudo
if [ -n "${SUDO_USER:-}" ]; then
  stop "this is running under sudo, so as root, and root has neither your SSH key nor your gh login" \
       "run it again without sudo"
fi

# 2. tools
missing=()
for t in git gh jq gawk yq timeout; do
  command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [ "${#missing[@]}" -gt 0 ]; then
  stop "missing tool(s): ${missing[*]}" \
       "install them (gawk and jq from your package manager; yq from https://github.com/mikefarah/yq)"
fi
yqv="$(yq --version 2>&1)"
case "$yqv" in
  *mikefarah*) : ;;
  *) stop "yq is not mikefarah's Go yq (found: $yqv); the lock scripts need that one" \
          "install it from https://github.com/mikefarah/yq and put it first on PATH" ;;
esac

# 3. a clean checkout of a repository that carries the sequence
top="$(git rev-parse --show-toplevel 2>/dev/null)" || stop "not inside a git repository" \
  "cd into your clone of the repository first"
cd "$top" || stop "cannot enter $top"
steps=(relock-sha-keys complete-job-refs close-lock prune-stale check-lock-pin-contract check-lock-sync)
for s in "${steps[@]}"; do
  [ -f "scripts/$s.sh" ] || stop "scripts/$s.sh is missing here" \
    "run this from a clone of a repository that carries the lock scripts (metadatastician/standards)"
done
[ -f .github/workflows/actions.lock ] || stop "no .github/workflows/actions.lock here"
dirty="$(git status --porcelain)"
[ -z "$dirty" ] || stop "the working tree is not clean" \
  "commit or set aside your changes first (git status shows them)"

# 4. the pinned tool version, read from the workflows
pins="$(grep -rhoE 'gh-actions-lock(/releases/download/| --pin )v[0-9]+\.[0-9]+\.[0-9]+' .github/workflows 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -u)"
npins="$(printf '%s' "$pins" | grep -c . )"
if [ "$npins" -eq 0 ]; then
  stop "no workflow pins a gh-actions-lock version, so there is nothing to match" \
       "check .github/workflows for the lock tooling step"
elif [ "$npins" -gt 1 ]; then
  stop "the workflows pin more than one gh-actions-lock version: $(printf '%s' "$pins" | tr '\n' ' ')" \
       "make them agree first (scripts/tests/gh-actions-lock-contract-test.sh holds them to one)"
fi
want="$pins"

# 5. gh login and the network, each with a time limit
net gh auth status >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 124 ]; then
  stop "gh auth status timed out after ${T}s: no network, or GitHub is unreachable from here" \
       "check your connection (and any VPN or proxy); the tool cannot run offline"
elif [ "$rc" -ne 0 ]; then
  stop "gh is not logged in to GitHub" "run: gh auth login"
fi
left="$(net gh api rate_limit --jq .resources.core.remaining 2>/dev/null)"
rc=$?
if [ "$rc" -eq 124 ]; then
  stop "the GitHub API timed out after ${T}s" "check your connection; the tool cannot run offline"
elif [ "$rc" -ne 0 ] || [ -z "$left" ]; then
  stop "the GitHub API did not answer" "run: gh api rate_limit   (to see the error)"
elif [ "$left" -lt 100 ]; then
  stop "the GitHub API rate limit is nearly used up ($left calls left)" "wait an hour and run this again"
fi

# 6. the extension, at the pinned version
ext="$(net gh extension list 2>/dev/null)"
rc=$?
[ "$rc" -eq 124 ] && stop "gh extension list timed out after ${T}s" "check your connection"
have="$(printf '%s\n' "$ext" | awk '/github\/gh-actions-lock/ { for (i = 1; i <= NF; i++) if ($i ~ /^v[0-9]/) print $i }' | head -n1)"
if [ -z "$have" ]; then
  stop "the gh actions-lock extension is not installed" \
       "run: gh extension install github/gh-actions-lock --pin $want"
elif [ "$have" != "$want" ]; then
  stop "gh actions-lock is $have, but the workflows here pin $want" \
       "run: gh extension remove actions-lock && gh extension install github/gh-actions-lock --pin $want"
fi

# 7. the remote, without prompting
net git fetch --quiet origin
rc=$?
if [ "$rc" -eq 124 ]; then
  stop "git fetch timed out after ${T}s" \
       "for an SSH remote, test with: ssh -T git@github.com   (if that hangs, port 22 is blocked; use: gh auth setup-git and an HTTPS remote)"
elif [ "$rc" -ne 0 ]; then
  stop "git fetch failed (it is not allowed to prompt)" \
       "for an SSH remote with a passphrase, run ssh-add first; or switch to HTTPS: gh auth setup-git"
fi
base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
git rev-parse --verify --quiet "$base" >/dev/null || stop "cannot find the default branch ($base)" \
  "run: git remote set-head origin -a"
if git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  stop "branch $BRANCH already exists" "pass another name with --branch, or delete it"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  say "ready: gh $have logged in, ${left} API calls left, base $base, branch $BRANCH would be created"
  exit 0
fi

# 8. the sequence
git switch --quiet -c "$BRANCH" "$base" || stop "could not create branch $BRANCH from $base"
say "on new branch $BRANCH from $base"

run_step() { # label, command...
  local label=$1; shift
  say "step $n of 7: $label"
  timeout "$ST" "$@"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      printf 'relock-main: FAILED at step %s of 7, %s: timed out after %ss\n' "$n" "$label" "$ST" >&2
    else
      printf 'relock-main: FAILED at step %s of 7, %s (exit %s)\n' "$n" "$label" "$rc" >&2
    fi
    printf '  the branch %s is left as it is for inspection.\n' "$BRANCH" >&2
    printf '  to discard it: git switch - && git branch -D %s\n' "$BRANCH" >&2
    exit 1
  fi
}

n=1; run_step "gh actions-lock" gh actions-lock --no-migrate-local-actions --no-narrow
for s in "${steps[@]}"; do
  n=$((n + 1)); run_step "$s" bash "scripts/$s.sh"
done

say "all seven steps passed. Changed files:"
git status --short
cat <<EOF

Next, by hand:
  1. Review the change:        git diff
  2. Commit it:                git commit -am "ci(actions.lock): regenerate on ${base#origin/}"
  3. Push and open a draft PR: git push -u origin $BRANCH && gh pr create --draft --fill
EOF
