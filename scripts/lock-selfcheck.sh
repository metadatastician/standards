#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# lock-selfcheck.sh — is a given `standards` commit SAFE TO PIN A CALLER TO?
#
# WHY THIS EXISTS
# ---------------
# `uses: org/repo/.github/workflows/x.yml@<sha>` is resolved at workflow
# STARTUP, and GitHub validates the callee against **the callee repo's own
# `.github/workflows/actions.lock` AS IT EXISTS AT THAT SHA**. If the reusable
# names an action ref the lock at that same SHA does not key, every caller dies
# before any job exists — and the failure is near-invisible:
#
#   * conclusion is `failure`, NOT `startup_failure`
#   * the run has ZERO jobs
#   * the run's `name` equals its `path`
#   * neither REST nor GraphQL carries a reason — only the run PAGE does
#
# Dependabot causes this routinely: it bumps a `uses:` inside a workflow and
# never regenerates the lockfile. So **capability is not monotonic in time** —
# the newest `standards` commit can be strictly less usable than an older one,
# and "bump every caller to HEAD" is exactly the wrong reflex.
#
# Before a pin sweep repairs N callers onto a target SHA, that SHA must pass
# this check. Otherwise the sweep converts N silently-ungated repos into N
# loudly-broken ones.
#
# USAGE
#   lock-selfcheck.sh <sha> [<sha>...]        # uses $STANDARDS_DIR or default
#   STANDARDS_DIR=/path/to/standards lock-selfcheck.sh <sha>
#
# Reads git objects ONLY (`git show`); never checks out, fetches, or writes.
# Safe against a checkout shared with a live concurrent writer.
#
# The lock at each SHA must also be CLOSED: every ref under workflows: and in a
# record's nested uses: has a top-level record (`close-lock.sh --check`,
# standards#963). A dangling edge is a third POISON verdict.
#
# EXIT: 0 if every SHA examined self-validates; 1 if any does not; 2 on misuse.
#
# ⚠ SCOPE LIMIT, STATED SO IT IS NOT MISREAD: this proves a commit is
# INTERNALLY CONSISTENT. It does NOT prove the commit is REACHABLE at the
# remote. A local object store can hold commits GitHub has since orphaned
# (a garbage-collected commit is the general case). Reachability is a
# SEPARATE probe and must be made against the remote: the orphan-pin probe in
# check-action-pins-resolve.sh (#782), which Governance runs in the
# "Workflow security linter" job. Both are needed: mirror.yml and ci-pipeline.yml
# pinned 427eb35c, which passed this check but sat only on a deleted PR
# branch, so every run of both died at startup (#1317).
#

set -uo pipefail

STANDARDS_DIR="${STANDARDS_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOCK_PATH='.github/workflows/actions.lock'

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <sha> [<sha>...]" >&2
  exit 2
fi

if ! git -C "$STANDARDS_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "FATAL: not a git repository: $STANDARDS_DIR" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="${TMPDIR:-/tmp}/lock-selfcheck.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# Normalise a `uses:` value to the key shape the lockfile uses:
#   github/codeql-action/upload-sarif@SHA  ->  github/codeql-action@SHA
#   actions/checkout@SHA                   ->  actions/checkout@SHA
# Local refs (./...) and docker:// refs are not lockfile-keyed and are skipped
# by the caller, not here.
normalise_ref() {
  printf '%s\n' "$1" | awk -F'@' '{
    n = split($1, p, "/")
    owner_repo = (n >= 2) ? p[1] "/" p[2] : $1
    print owner_repo "@" $2
  }'
}

overall_rc=0

# The workflows are read with yq (YAML-POLICY Y-1); without it nothing is examined.
if ! command -v yq >/dev/null 2>&1; then
  echo "lock-selfcheck: yq not found -- it reads the workflows (YAML-POLICY Y-1)" >&2
  exit 2
fi

for SHA in "$@"; do
  echo "=============================================================="
  if ! git -C "$STANDARDS_DIR" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
    echo "SHA ${SHA}: ABSENT from local object store — cannot check"
    overall_rc=1
    continue
  fi
  SHORT=$(git -C "$STANDARDS_DIR" rev-parse --short=12 "$SHA")
  WHEN=$(git -C "$STANDARDS_DIR" show -s --format='%ci' "$SHA")
  SUBJ=$(git -C "$STANDARDS_DIR" show -s --format='%s' "$SHA")
  echo "SHA ${SHORT}  ${WHEN}"
  echo "     ${SUBJ}"

  if ! git -C "$STANDARDS_DIR" show "${SHA}:${LOCK_PATH}" > "$TMP/lock" 2>/dev/null; then
    # THIRD STATE, and not the same as POISON. With no lockfile there is
    # nothing for GitHub to validate the callee against, so a caller pinned
    # here does NOT die at startup -- it simply gets no immutable-action
    # guarantee. Predates the lock regime (which begins ~2026-08-03).
    # Reporting this as unsafe-to-pin would be a false alarm, so it does not
    # set the failure exit code.
    echo "  VERDICT: NO-LOCK — ${LOCK_PATH} does not exist at this SHA."
    echo "           NOT startup-fatal: with no lock there is nothing to"
    echo "           validate against. But callers pinned here get no"
    echo "           action-pinning guarantee either. Pre-dates the lock regime."
    continue
  fi

  # Parse the lock into "<workflow-path>\t<owner/repo@sha>" pairs.
  awk '
    /^workflows:/ { in_wf = 1; next }
    /^[a-z_]+:/   { in_wf = 0; next }
    !in_wf { next }
    # A workflow key line:  \x27.github/workflows/foo.yml\x27:
    /^[[:space:]]+\x27[^\x27]+\x27:/ {
      line = $0
      sub(/^[[:space:]]+\x27/, "", line)
      sub(/\x27:.*$/, "", line)
      cur = line
      next
    }
    # An entry line:  - \x27owner/repo@sha\x27
    /^[[:space:]]*-[[:space:]]*\x27[^\x27]+\x27/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*\x27/, "", line)
      sub(/\x27.*$/, "", line)
      if (cur != "") print cur "\t" line
    }
  ' "$TMP/lock" | sort -u > "$TMP/locked"

  # Parse dependencies: entries whose `ref:` equals their own 40-hex SHA pin
  # (self-SHA ref; rejected by the GitHub runner during Set up job, standards#1271).
  awk '
    /^dependencies:/ { in_dep = 1; next }
    /^[a-z_]+:/      { in_dep = 0; cur = ""; next }
    !in_dep { next }
    /^    \x27[^\x27]+\x27:$/ {
      cur = $0; sub(/^    \x27/, "", cur); sub(/\x27:$/, "", cur)
      next
    }
    cur != "" && /^        ref: \x27[^\x27]+\x27$/ {
      r = $0; sub(/^        ref: \x27/, "", r); sub(/\x27$/, "", r)
      n = index(cur, "@")
      pin = (n > 0) ? substr(cur, n + 1) : ""
      if (length(r) == 40 && r ~ /^[0-9a-fA-F]+$/ && tolower(r) == tolower(pin)) {
        print tolower(cur)
      }
      cur = ""
    }
  ' "$TMP/lock" | sort -u > "$TMP/self_sha_deps"

  locked_pairs=$(wc -l < "$TMP/locked")
  locked_wfs=$(cut -f1 "$TMP/locked" | sort -u | wc -l)

  # Enumerate the workflow files present at this SHA.
  git -C "$STANDARDS_DIR" ls-tree -r --name-only "$SHA" -- .github/workflows \
    | /usr/bin/grep -E '\.ya?ml$' | sort > "$TMP/wfs"
  n_wfs=$(wc -l < "$TMP/wfs")

  # The lockfile LOWERCASES the owner/repo it keys ('swatinem/rust-cache')
  # while the workflow writes the upstream casing ('Swatinem/rust-cache').
  # Same action, same SHA. Comparing case-sensitively invents defects, so
  # fold both sides before matching. (This cost one false 'POISON' on
  # rust-ci-reusable.yml before it was caught.)
  tr 'A-Z' 'a-z' < "$TMP/locked" > "$TMP/locked.lc"

  : > "$TMP/missing"
  : > "$TMP/self_sha_used"
  : > "$TMP/unkeyed_wf"
  : > "$TMP/scanned"
  : > "$TMP/unparsed"

  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    git -C "$STANDARDS_DIR" show "${SHA}:${wf}" 2>/dev/null > "$TMP/wfbody" || continue
    # Extract every `uses:` VALUE with the YAML parser (YAML-POLICY Y-1). A
    # line grep only sees block style: on a KYAML workflow it captured
    # `…@sha",` and reported a keyed ref as POISON. A file yq cannot parse is
    # recorded and fails the SHA below -- its refs went unexamined.
    # Measured 2026-10-01 on main: same 111 (workflow, ref) pairs as the grep.
    { yq -r '.. | select(tag == "!!map") | select(has("uses")) | .uses | select(tag == "!!str")' "$TMP/wfbody" \
        || printf '%s\n' "$wf" >> "$TMP/unparsed"; } \
      | while IFS= read -r ref; do
          [ -n "$ref" ] || continue
          case "$ref" in
            ./*|docker://*) continue ;;   # local / docker: not lockfile-keyed
          esac
          case "$ref" in
            *@*) : ;;
            *) continue ;;                # unpinned (no @) — a different defect
          esac
          # A reusable-workflow call carries a .yml before the @; the lockfile
          # keys ACTIONS, not reusable calls. Report those separately.
          before="${ref%@*}"
          case "$before" in
            *.yml|*.yaml) printf '%s\t%s\tREUSABLE-CALL\n' "$wf" "$ref" >> "$TMP/scanned"; continue ;;
          esac
          key=$(normalise_ref "$ref")
          printf '%s\t%s\tACTION\n' "$wf" "$key" >> "$TMP/scanned"
          key_lc=$(printf '%s' "$key" | tr 'A-Z' 'a-z')
          wf_lc=$(printf '%s' "$wf" | tr 'A-Z' 'a-z')
          # Two DIFFERENT questions, deliberately not conflated:
          #   (1) this workflow has NO entry in the lock at all  -> UNKEYED
          #   (2) this workflow IS keyed, but not for this ref   -> MISSING
          # Only (2) is proven to kill a caller at startup. (1) is reported
          # separately because the lock also carries explicit ': []' entries,
          # which proves absence and "uses nothing" are distinct states the
          # generator can express -- so absence means the generator never saw
          # the file, not that the file is forbidden actions.
          if ! /usr/bin/grep -qF "$(printf '%s\t' "$wf_lc")" "$TMP/locked.lc"; then
            printf '%s\t%s\n' "$wf" "$key" >> "$TMP/unkeyed_wf"
          elif ! /usr/bin/grep -qF "$(printf '%s\t%s' "$wf_lc" "$key_lc")" "$TMP/locked.lc"; then
            printf '%s\t%s\n' "$wf" "$key" >> "$TMP/missing"
          elif /usr/bin/grep -qxF "$key_lc" "$TMP/self_sha_deps"; then
            printf '%s\t%s\n' "$wf" "$key" >> "$TMP/self_sha_used"
          fi
        done
  done < "$TMP/wfs"

  n_actions=$(/usr/bin/grep -c 'ACTION$' "$TMP/scanned" 2>/dev/null || echo 0)
  n_reusable=$(/usr/bin/grep -c 'REUSABLE-CALL$' "$TMP/scanned" 2>/dev/null || echo 0)
  n_missing=$(sort -u "$TMP/missing" 2>/dev/null | wc -l)
  n_self_sha=$(sort -u "$TMP/self_sha_used" 2>/dev/null | wc -l)
  n_unkeyed=$(sort -u "$TMP/unkeyed_wf" 2>/dev/null | wc -l)
  n_unkeyed_wf=$(cut -f1 "$TMP/unkeyed_wf" 2>/dev/null | sort -u | wc -l)
  # Closure (standards#963): close-lock.sh --check exits 1 and lists, two-space
  # indented, every ref the lock names without a top-level record of its own.
  # Any other non-zero exit (2: no lock, an unparseable lock, or yq/jq missing)
  # means closure was not examined. That is UNEXAMINED, never a dangling edge.
  n_dangling=0
  closure_rc=0
  bash "$SCRIPT_DIR/close-lock.sh" --check "$TMP/lock" > "$TMP/closure" 2>&1 || closure_rc=$?
  if [[ "$closure_rc" -eq 1 ]]; then
    n_dangling=$(/usr/bin/grep -c '^  [^ ][^ ]*@[^ ]*$' "$TMP/closure" || true)
    # A dangling verdict that names no ref still fails.
    [[ "$n_dangling" -gt 0 ]] || n_dangling=1
  fi

  echo "  workflows at this SHA: ${n_wfs}   lockfile keys: ${locked_wfs} workflow(s), ${locked_pairs} pair(s)"
  echo "  action refs used: ${n_actions}   reusable-workflow calls (not lock-keyed): ${n_reusable}"
  if [ "$n_unkeyed" -gt 0 ]; then
    echo "  note: ${n_unkeyed_wf} workflow(s) have NO lock entry at all (${n_unkeyed} ref(s)) —"
    echo "        a separate question from the verdict below, and not counted in it:"
    cut -f1 "$TMP/unkeyed_wf" | sort -u | sed 's/^/          /'
  fi

  if [ -s "$TMP/unparsed" ]; then
    echo "  VERDICT: UNEXAMINED — yq could not parse $(sort -u "$TMP/unparsed" | wc -l) workflow(s); their refs were not checked:"
    sort -u "$TMP/unparsed" | sed 's/^/             /'
    overall_rc=1
  elif [[ "$closure_rc" -ne 0 && "$closure_rc" -ne 1 ]]; then
    echo "  VERDICT: UNEXAMINED — close-lock.sh --check exited ${closure_rc}; this SHA's lock closure was not checked:"
    sed 's/^/             /' "$TMP/closure"
    overall_rc=1
  elif [[ "$n_missing" -eq 0 && "$n_self_sha" -eq 0 && "$n_dangling" -eq 0 ]]; then
    echo "  VERDICT: SELF-CONSISTENT — every action ref used is keyed in this SHA's own lock, and the lock is closed."
    echo "           (Reachability at the remote is NOT proven by this check: see check-action-pins-resolve.sh.)"
  else
    if [ "$n_missing" -gt 0 ]; then
      echo "  VERDICT: POISON — ${n_missing} action ref(s) used but NOT keyed in this SHA's own lock."
      echo "           Any caller pinned here dies at startup with 0 jobs and no stated reason."
      sort -u "$TMP/missing" | while IFS=$'\t' read -r wf key; do
        echo "             ${wf}"
        echo "               uses  ${key}"
        locked_for=$(/usr/bin/grep -F "$(printf '%s\t' "$wf")" "$TMP/locked" | cut -f2 | sort -u | tr '\n' ' ')
        echo "               lock keys for this workflow: ${locked_for:-<none>}"
      done
    fi
    if [ "$n_self_sha" -gt 0 ]; then
      echo "  VERDICT: POISON — ${n_self_sha} action ref(s) carry a self-SHA ref: in dependencies: (standards#1271)."
      echo "           GitHub runner verification fails at Set up job ('invalid lockfile pin')."
      sort -u "$TMP/self_sha_used" | while IFS=$'\t' read -r wf key; do
        echo "             ${wf}"
        echo "               self-SHA ref  ${key}"
      done
    fi
    if [[ "$n_dangling" -gt 0 ]]; then
      echo "  VERDICT: POISON — ${n_dangling} dangling edge(s) in this SHA's own lock (standards#963)."
      echo "           Hypatia fails closed on it (invalid_actions_lock), and close-lock.sh records"
      echo "           GitHub refusing runs at startup for this shape (cicd-squabbler#101)."
      sed 's/^/           /' "$TMP/closure"
    fi
    overall_rc=1
  fi
done

echo "=============================================================="
if [ "$overall_rc" -eq 0 ]; then
  echo "ALL EXAMINED SHAs SELF-VALIDATE (examined: $#)"
else
  echo "AT LEAST ONE SHA IS UNSAFE TO PIN TO (examined: $#)"
fi
exit "$overall_rc"
