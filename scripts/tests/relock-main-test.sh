#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# relock-main-test.sh: the preflight of scripts/relock-main.sh fails loudly
# and quickly, never hangs, and the regeneration runs the documented steps in
# order and stops at the first that fails.
#
# Offline. Every outside tool (gh, jq, gawk, yq) is a stand-in on a sandbox
# PATH; the "remote" is a bare repository on disk.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../relock-main.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# ── a sandbox PATH: real basics, stand-ins for everything that talks out ──
SB="$WORK/bin"
mkdir -p "$SB"
for t in bash sh git timeout date grep sed sort uniq cat mkdir rm env dirname \
         basename tr head tail ls mktemp printf sleep wc cut awk; do
  p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$SB/$t"
done

cat >"$SB/gh" <<'EOF'
#!/usr/bin/env bash
mode="${STUB_GH:-ok}"
[ "$mode" = hang ] && { sleep 30; exit 0; }
case "$1 ${2:-}" in
  "auth status") [ "$mode" = noauth ] && { echo "You are not logged into any GitHub hosts." >&2; exit 1; }; exit 0 ;;
  "api rate_limit") [ "$mode" = ratelimited ] && { echo 0; exit 0; }; echo 4999; exit 0 ;;
  "extension list")
    case "$mode" in
      noext) : ;;
      oldext) printf 'gh actions-lock\tgithub/gh-actions-lock\tv0.1.6\n' ;;
      *) printf 'gh actions-lock\tgithub/gh-actions-lock\tv0.2.0\n' ;;
    esac
    exit 0 ;;
esac
if [ "$1" = actions-lock ]; then
  shift
  echo "gh-actions-lock $*" >>"$RELOCK_TEST_LOG"
  exit 0
fi
echo "stub gh: unexpected: $*" >&2
exit 3
EOF
for t in jq gawk; do printf '#!/usr/bin/env bash\nexit 0\n' >"$SB/$t"; done
cat >"$SB/yq" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_YQ:-mikefarah}" = mikefarah ]; then
  echo "yq (https://github.com/mikefarah/yq/) version v4.44.3"
else
  echo "yq 3.4.3"
fi
EOF
chmod +x "$SB"/gh "$SB"/jq "$SB"/gawk "$SB"/yq

# ── a remote with the scripts the sequence calls ──
ORIGIN="$WORK/origin.git"
SEED="$WORK/seed"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$SEED"
mkdir -p "$SEED/scripts" "$SEED/.github/workflows"
printf 'jobs:\n  x:\n    steps:\n      - run: gh extension install github/gh-actions-lock --pin v0.2.0\n' \
  >"$SEED/.github/workflows/regen.yml"
printf 'version: v0.0.3\n' >"$SEED/.github/workflows/actions.lock"
for s in relock-sha-keys complete-job-refs close-lock prune-stale check-lock-pin-contract check-lock-sync; do
  cat >"$SEED/scripts/$s.sh" <<EOF
#!/usr/bin/env bash
echo "$s" >>"\$RELOCK_TEST_LOG"
[ "\${STEP_HANG:-}" = "$s" ] && sleep 30
[ "\${FAIL_STEP:-}" = "$s" ] && exit 1
exit 0
EOF
  chmod +x "$SEED/scripts/$s.sh"
done
(cd "$SEED" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m seed \
  && git -c push.negotiate=false push -q "$ORIGIN" main) || { echo "fixture setup failed" >&2; exit 1; }

# fresh clone per case
clone() {
  local d="$WORK/case.$1"
  rm -rf "$d"
  git clone -q "$ORIGIN" "$d" || return 1
  git -C "$d" remote set-head origin -a >/dev/null 2>&1
  printf '%s' "$d"
}

# run CASE-NAME [VAR=VAL ...] -- ARGS: sets RC, OUT, SECS, REPO, LOGFILE
run() {
  local name=$1; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  REPO="$(clone "$name")" || { bad "$name: fixture clone"; return 1; }
  LOGFILE="$WORK/log.$name"
  : >"$LOGFILE"
  local t0 t1
  t0=$(date +%s)
  OUT="$(cd "$REPO" && env -i HOME="$WORK" PATH="$SB" RELOCK_TEST_LOG="$LOGFILE" \
        RELOCK_TIMEOUT=2 RELOCK_STEP_TIMEOUT=3 "${envs[@]}" \
        bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  t1=$(date +%s)
  SECS=$((t1 - t0))
}

has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

expect() { # name rc substring
  if [ "$RC" -eq "$2" ] && has "$3"; then ok "$1"
  else bad "$1" "rc=$RC (want $2); output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-300)"; fi
}

# 1. everything ready, --check-only: no branch, no step
run ready -- --check-only
expect "check-only on a ready machine passes" 0 "ready"
if [ ! -s "$LOGFILE" ]; then ok "check-only runs no step"; else bad "check-only runs no step" "$(cat "$LOGFILE")"; fi

# 2. under sudo
run sudo SUDO_USER=someone -- --check-only
expect "refuses to run under sudo" 2 "sudo"

# 3. a missing tool
mv "$SB/gawk" "$SB/gawk.off"
run nogawk -- --check-only
expect "names a missing tool" 2 "gawk"
mv "$SB/gawk.off" "$SB/gawk"

# 4. the wrong yq
run wrongyq STUB_YQ=python -- --check-only
expect "refuses a yq that is not mikefarah's" 2 "mikefarah"

# 5. gh not logged in
run noauth STUB_GH=noauth -- --check-only
expect "says gh is not logged in" 2 "gh auth login"

# 6. the network hangs: fails within seconds, never sits there
run hang STUB_GH=hang -- --check-only
expect "a hanging network call times out" 2 "timed out"
if [ "$SECS" -le 10 ]; then ok "a hanging network call ends in $SECS s"
else bad "a hanging network call ends quickly" "took $SECS s"; fi

# 7. extension absent: prints the pinned install command
run noext STUB_GH=noext -- --check-only
expect "gives the pinned install command" 2 "--pin v0.2.0"

# 8. extension at another version
run oldext STUB_GH=oldext -- --check-only
expect "names both versions on a mismatch" 2 "v0.1.6"

# 9. API rate limit exhausted
run ratelimit STUB_GH=ratelimited -- --check-only
expect "reports an exhausted API rate limit" 2 "rate limit"

# 10. dirty working tree
REPO="$(clone dirty)"; echo x >"$REPO/stray"
OUT="$(cd "$REPO" && env -i HOME="$WORK" PATH="$SB" RELOCK_TEST_LOG=/dev/null RELOCK_TIMEOUT=2 bash "$SCRIPT" --check-only 2>&1)"; RC=$?
expect "refuses a dirty working tree" 2 "not clean"

# 11. the full sequence, in order, on a new branch
run full -- --branch relock/test
expect "the full sequence succeeds" 0 "Next"
want="$(printf '%s\n' "gh-actions-lock --no-migrate-local-actions --no-narrow" relock-sha-keys \
  complete-job-refs close-lock prune-stale check-lock-pin-contract check-lock-sync)"
if [ "$(cat "$LOGFILE")" = "$want" ]; then ok "runs the seven steps in the documented order"
else bad "runs the seven steps in the documented order" "$(tr '\n' '|' <"$LOGFILE")"; fi
br="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
if [ "$br" = relock/test ]; then ok "works on the named branch"; else bad "works on the named branch" "$br"; fi
n="$(git -C "$REPO" rev-list --count origin/main..HEAD)"
if [ "$n" = 0 ]; then ok "commits nothing"; else bad "commits nothing" "$n commit(s)"; fi

# 12. a step fails: stop there, name it
run failstep FAIL_STEP=close-lock -- --branch relock/test
expect "names the step that failed" 1 "close-lock"
if [ "$(tail -n1 "$LOGFILE")" = close-lock ]; then ok "stops at the failed step"
else bad "stops at the failed step" "$(tr '\n' '|' <"$LOGFILE")"; fi

# 13. a step hangs: the step timeout ends it
run hangstep STEP_HANG=prune-stale -- --branch relock/test
expect "a hanging step is stopped and named" 1 "prune-stale"
if [ "$SECS" -le 12 ]; then ok "a hanging step ends in $SECS s"; else bad "a hanging step ends quickly" "took $SECS s"; fi

# 14. the branch already exists
REPO="$(clone exists)"; git -C "$REPO" branch -q --no-track relock/test origin/main
OUT="$(cd "$REPO" && env -i HOME="$WORK" PATH="$SB" RELOCK_TEST_LOG=/dev/null RELOCK_TIMEOUT=2 bash "$SCRIPT" --branch relock/test 2>&1)"; RC=$?
expect "refuses an existing branch" 2 "already exists"

# 15. workflows pin two versions
REPO="$(clone twopins)"
printf -- '- run: gh extension install github/gh-actions-lock --pin v0.1.6\n' >"$REPO/.github/workflows/other.yml"
git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q -m two
git -C "$REPO" push -q origin HEAD:main
OUT="$(cd "$REPO" && env -i HOME="$WORK" PATH="$SB" RELOCK_TEST_LOG=/dev/null RELOCK_TIMEOUT=2 bash "$SCRIPT" --check-only 2>&1)"; RC=$?
expect "refuses when workflows pin two versions" 2 "more than one"

# 16. unknown argument
run usage -- --frobnicate
expect "rejects an unknown argument" 64 "usage"

printf '\nrelock-main-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
