#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# prune-stale.sh — remove workflow-entry refs from .github/workflows/actions.lock
# that no `uses:` in that workflow references.
#
# ── Why pruning, and not demoting the check ─────────────────────────────────
# The per-repo lock-sync gate (check-lock-sync.sh) clause 2 hard-FAILs on
# "stale lockfile entries, no uses: references them". Measured 2026-09-22 on
# hyperpolymath/my-lang, that condition is NOT fatal to GitHub: six workflows there share
# the identical stale entry 'hyperpolymath/standards@08586a12…' and produce
# THREE different outcomes —
# secret-scanner + spark-theatre-gate success x3, governance + hypatia-scan
# failure x3 (jobs>0), mirror + scorecard startup_failure x3. One property,
# three outcomes, so the property is not the cause.
#
# So the gate reds on a harmless condition. There are two cures; this is the
# one that repairs rather than silences: make the lock true, and leave the gate
# strict. A `::warning::` or a demotion to advisory would be a vacuous gate.
#
# ── Why pruning is safe ─────────────────────────────────────────────────────
# A workflow entry is a per-path list of the refs GitHub validates for THAT
# workflow. Transitive dependencies live in the top-level `dependencies:` map,
# never in a per-workflow list, so removing a per-workflow ref cannot open a
# dangling edge — and check-lock-sync clause 3 re-verifies closure afterwards
# regardless. An entry whose ref is referenced by no `uses:` in its own file
# cannot be satisfying anything there.
#
# ── A THIRD oracle: the reviewed closure of remote reusable workflows ───────
# A ref reached only through a remote reusable workflow appears in NEITHER the
# workflow text NOR any local composite file, so both oracles above agree that
# nothing uses it and the entry is dropped — silently removing a dependency
# GitHub validates at startup for every caller. Measured shape:
# hyperpolymath/unified-dataset-vocab#81 records
# `actions/checkout@3d3c42e5…` under `.github/workflows/secret-scanner.yml` while
# the workflow only calls a reusable that uses it.
# So when `.github/workflows/actions-lock.closure.tsv` exists (written by
# check-reusable-closure.sh --write-baseline and reviewed in a pull request),
# every ref it records for a workflow is KEPT. `--closure FILE` overrides the
# path; `--no-closure` disables the oracle (only for a repository that has no
# remote reusable calls at all).
#
# ── Two independent oracles must agree before a ref is dropped ──────────────
#   1. the PARSER: no `uses:` in that workflow normalises to this owner/repo@ref
#      (same norm()/ck() semantics as check-lock-sync.sh);
#   2. the LITERAL GREP: the exact ref string does not occur anywhere in the
#      workflow file, comments included (`grep -F`).
# Disagreement means KEEP. A parser blind spot therefore cannot delete a needed
# entry (scripts/tests/prune-stale-test.sh plants exactly that blind spot).
#
# ── Refs used through a LOCAL composite action count as used ────────────────
# A local action (`uses: ./.github/actions/x`) has no dependency record of its
# own, so the actions it uses are listed in the CALLING workflow's entry; that
# is where `gh actions-lock` writes them. Both oracles therefore read the
# workflow plus every local composite action file it reaches (transitively).
# Reading the workflow alone dropped those refs (standards#1122).
#
# ── A key whose workflow file is gone is dropped whole ──────────────────────
# Retiring a workflow is the limit case: every ref under its key is stale, and
# the key itself names a file that does not exist, which check-lock-sync.sh
# rejects ("lockfile entry for a workflow file that does not exist"). Leaving
# `[]` is not enough. `gh actions-lock` would remove the key, but it is blind
# to refs used only by a local composite action and drops those records too
# (#947 deleted asana/push-signed-commits that way; #954 restored it). The
# same two-oracle rule applies: a key is dropped only when it matches no file
# the workflow glob found AND `-f` on that path fails. The pass is scoped to
# the workflows: section, because dependencies: keys share the same shape and
# are never files.
#
# Lock repair order: gh actions-lock → relock-sha-keys.sh → complete-job-refs.sh
# → close-lock.sh → prune-stale.sh (see complete-job-refs.sh).
#
# Exit 0 whether or not anything was pruned; exit 1 only on a structural error.

set -euo pipefail

WF_DIR=".github/workflows"
CLOSURE=""
CLOSURE_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --closure)
      [ "$#" -ge 2 ] || {
        echo "prune-stale: --closure needs a file" >&2
        exit 2
      }
      [ -n "$2" ] && [ -f "$2" ] || {
        echo "prune-stale: closure manifest is not a regular file: $2" >&2
        exit 2
      }
      CLOSURE="$2"; CLOSURE_SET=1; shift 2 ;;
    --no-closure) CLOSURE_SET=1; CLOSURE=""; shift ;;
    *) WF_DIR="$1"; shift ;;
  esac
done
[ "$CLOSURE_SET" -eq 1 ] || { [ -f "$WF_DIR/actions-lock.closure.tsv" ] && CLOSURE="$WF_DIR/actions-lock.closure.tsv"; }
LOCK="$WF_DIR/actions.lock"

AWK=""
for cand in gawk awk; do
  if command -v "$cand" >/dev/null 2>&1 \
     && echo x | "$cand" '{ if (match($0, /(x)/, m) && m[1] == "x") exit 0; exit 1 }' 2>/dev/null; then
    AWK="$cand"; break
  fi
done
[ -n "$AWK" ] || { echo "prune-stale: FATAL: need gawk (3-arg match)" >&2; exit 1; }
[ -f "$LOCK" ] || { echo "prune-stale: FATAL: no lockfile at $LOCK" >&2; exit 1; }

shopt -s nullglob
mapfile -t WORKFLOWS < <(printf '%s\n' "$WF_DIR"/*.yml "$WF_DIR"/*.yaml | sort -u)
[ "${#WORKFLOWS[@]}" -gt 0 ] || { echo "prune-stale: FATAL: no workflows under $WF_DIR" >&2; exit 1; }

# ── local composite actions (identical block in check-lock-sync.sh, ─────────
# ── prune-stale.sh and complete-job-refs.sh; they must agree) ─────────────────
# reach_files WORKFLOW prints WORKFLOW and every local composite action file
# (`uses: ./dir` -> dir/action.yml or dir/action.yaml) it reaches, transitively,
# each once. A local reusable workflow (`./….yml`) is a lock entry of its own,
# so it is not followed. Paths resolve from the repository root, as GitHub
# resolves them from the workspace.
LC_ROOT="$(cd "$WF_DIR/../.." 2>/dev/null && pwd)" || LC_ROOT=.
# local_action_paths FILE: the path after `./` of every local `uses:` in FILE.
local_action_paths() {
  awk -v q="'" '{
    line = $0; sub(/[[:space:]]+#.*$/, "", line)
    if (!match(line, /^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*/)) next
    raw = substr(line, RLENGTH + 1)
    sub("[\"" q "],[[:space:]]*$", "", raw)
    gsub("^[\"" q "]|[\"" q "]$", "", raw); sub(/[[:space:]]+$/, "", raw)
    if (substr(raw, 1, 2) == "./") print substr(raw, 3)
  }' "$1"
}
reach_files() {
  local -A seen=()
  local queue=("$1") f rel a
  while [ "${#queue[@]}" -gt 0 ]; do
    f="${queue[0]}"; queue=("${queue[@]:1}")
    [ -n "${seen[$f]:-}" ] && continue
    seen[$f]=1
    printf '%s\n' "$f"
    while IFS= read -r rel; do
      rel="${rel%/}"
      case "$rel" in *.yml|*.yaml) continue ;; esac
      for a in "$LC_ROOT/$rel/action.yml" "$LC_ROOT/$rel/action.yaml"; do
        if [ -f "$a" ]; then queue+=("$a"); break; fi
      done
    done < <(local_action_paths "$f")
  done
}
# ── end of the shared block ───────────────────────────────────────────────────

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# reach.tsv: "file<TAB>lock key" — each file whose uses: count for that entry.
for wf in "${WORKFLOWS[@]}"; do
  while IFS= read -r f; do printf '%s\t.github/workflows/%s\n' "$f" "${wf##*/}"; done < <(reach_files "$wf")
done > "$TMP/reach.tsv"
mapfile -t SCAN < <(cut -f1 "$TMP/reach.tsv" | LC_ALL=C sort -u)

read -r -d '' CAND <<'AWK' || true
function norm(r,   at, path, ref, n, parts) {
  at = 0
  for (n = length(r); n > 0; n--) { if (substr(r, n, 1) == "@") { at = n; break } }
  if (at == 0) return ""
  path = substr(r, 1, at - 1); ref = substr(r, at + 1)
  if (path == "" || ref == "") return ""
  if (substr(path, 1, 2) == "./" || substr(path, 1, 2) == "$/") return ""
  if (split(path, parts, "/") < 2) return ""
  return parts[1] "/" parts[2] "@" ref
}
function ck(r,   at, s) {
  at = 0
  for (s = length(r); s > 0; s--) { if (substr(r, s, 1) == "@") { at = s; break } }
  if (at == 0) return tolower(r)
  return tolower(substr(r, 1, at - 1)) substr(r, at)
}
BEGIN {
  while ((getline l < mapfile) > 0) { split(l, mp, "\t"); owners[mp[1]] = owners[mp[1]] SUBSEP mp[2] }
}
FILENAME == lockfile {
  if ($0 ~ /^workflows:[[:space:]]*$/)    { inwf = 1; next }
  if ($0 ~ /^[a-z_]+:/)                   { inwf = 0; next }
  if (!inwf) next
  if (match($0, /^    '([^']+)':/, m)) { cur = m[1]; next }
  if (match($0, /^        - '([^']+)'[[:space:]]*$/, m) && cur != "") {
    lockref[cur, ck(m[1])] = m[1]
  }
  next
}
# Every scanned file (a workflow, or a composite action it reaches) credits its
# uses: to each lock key that reaches it.
FNR == 1 { nown = split(substr(owners[FILENAME], 2), own, SUBSEP) }
{
  line = $0
  sub(/[[:space:]]+#.*$/, "", line)
  if (match(line, /^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*(.+)$/, m)) {
    raw = m[1]
    sub(/["'],[[:space:]]*$/, "", raw)   # KYAML comma after a quoted scalar, as in check-lock-sync.sh
    gsub(/^["']|["']$/, "", raw); gsub(/[[:space:]]+$/, "", raw)
    n = norm(raw)
    if (n != "") for (i = 1; i <= nown; i++) used[own[i], ck(n)] = 1
  }
}
END {
  for (k in lockref) {
    split(k, kp, SUBSEP)
    if (!(k in used)) printf "%s\t%s\n", kp[1], lockref[k]
  }
}
AWK

"$AWK" -v lockfile="$LOCK" -v mapfile="$TMP/reach.tsv" "$CAND" "$LOCK" "${SCAN[@]}" | LC_ALL=C sort -u > "$TMP/cand.tsv"

# ── keys whose workflow file is gone. Both oracles must agree. ─────────────
declare -A present=()
for wf in "${WORKFLOWS[@]}"; do present[".github/workflows/${wf##*/}"]=1; done
: > "$TMP/gone.txt"
while IFS= read -r key; do
  [ -n "${present[$key]:-}" ] && continue
  if [ -f "$WF_DIR/${key##*/}" ]; then
    printf '  ! oracle disagrees, KEEPING key %s (file present, not matched by the glob)\n' "$key"
    continue
  fi
  printf '%s\n' "$key" >> "$TMP/gone.txt"
done < <("$AWK" '
  /^workflows:[[:space:]]*$/ { inwf = 1; next }
  /^[a-z_]+:/                { inwf = 0; next }
  inwf && match($0, /^    '\''([^'\'']+)'\'':/, m) { print m[1] }' "$LOCK")

if [ ! -s "$TMP/cand.tsv" ] && [ ! -s "$TMP/gone.txt" ]; then
  echo "prune-stale: no stale workflow-entry refs; lockfile unchanged"
  exit 0
fi

# ── oracle 2: the literal grep, over the workflow and every composite action ─
# ── file it reaches. Disagreement => KEEP. ───────────────────────────────────
# literal_hit KEY REF: print the first file credited to KEY that contains REF.
literal_hit() {
  local f k
  while IFS=$'\t' read -r f k; do
    [ "$k" = "$1" ] || continue
    if [ -f "$f" ] && command grep -Fq -- "$2" "$f"; then printf '%s\n' "$f"; return 0; fi
  done < "$TMP/reach.tsv"
  return 1
}
# closure_keeps PATH REF: the reviewed closure names this dependency for this
# workflow. Compared case-insensitively on owner/repo, refs exact.
closure_keeps() {
  [ -n "$CLOSURE" ] && [ -f "$CLOSURE" ] || return 1
  awk -F'\t' -v p="$1" -v r="$2" '
    /^#/ || NF < 3 { next }
    {
      want = tolower(r); got = tolower($3)
      if (tolower($1) == tolower(p) && got == want) found = 1
    }
    END { exit(found ? 0 : 1) }' "$CLOSURE"
}
: > "$TMP/drop.tsv"
kept_by_oracle=0
kept_by_closure=0
while IFS=$'\t' read -r path ref; do
  if closure_keeps "$path" "$ref"; then
    printf '  ! closure manifest, KEEPING %s in %s (reached through a remote reusable)\n' "$ref" "$path"
    kept_by_closure=$((kept_by_closure + 1))
    continue
  fi
  if hit="$(literal_hit "$path" "$ref")"; then
    printf '  ! oracle disagrees, KEEPING %s in %s (literal string present in %s)\n' "$ref" "$path" "$hit"
    kept_by_oracle=$((kept_by_oracle + 1))
    continue
  fi
  printf '%s\t%s\n' "$path" "$ref" >> "$TMP/drop.tsv"
done < "$TMP/cand.tsv"

if [ ! -s "$TMP/drop.tsv" ] && [ ! -s "$TMP/gone.txt" ]; then
  echo "prune-stale: every candidate was vetoed by the literal-grep oracle; lockfile unchanged"
  exit 0
fi

read -r -d '' APPLY <<'AWK' || true
NR == FNR { drop[$1 SUBSEP $2] = 1; next }
{
  if ($0 ~ /^workflows:[[:space:]]*$/) { inwf = 1; print; next }
  if ($0 ~ /^[a-z_]+:/)                { inwf = 0; print; next }
  if (!inwf) { print; next }
  if (match($0, /^    '([^']+)':/, m)) { cur = m[1]; print; next }
  if (match($0, /^        - '([^']+)'[[:space:]]*$/, m) && cur != "") {
    if ((cur SUBSEP m[1]) in drop) { pruned++; next }
  }
  print
}
END { printf "prune-stale: pruned %d stale workflow-entry ref(s)\n", pruned + 0 > "/dev/stderr" }
AWK

if [ -s "$TMP/drop.tsv" ]; then
  "$AWK" -F'\t' "$APPLY" "$TMP/drop.tsv" "$LOCK" > "$TMP/new.lock"
else
  cat "$LOCK" > "$TMP/new.lock"
fi

# An entry left with no items must become an explicit empty list, or the YAML
# key would take a null value and the schema would reject it.
"$AWK" '
  # Scoped strictly to the workflows: section. A dependencies: record uses the
  # same "    '\''key'\'':" shape but its children are "        ref:" style, so an
  # unscoped pass would rewrite every dependency record to ": []" and orphan its
  # children. That bug was caught by the gitbot-fleet test, not by review.
  { lines[NR] = $0 }
  END {
    inwf = 0
    for (i = 1; i <= NR; i++) {
      if (lines[i] ~ /^workflows:[[:space:]]*$/) { inwf = 1; print lines[i]; continue }
      else if (lines[i] ~ /^[a-z_]+:/)           { inwf = 0; print lines[i]; continue }
      if (inwf && match(lines[i], /^    '\''[^'\'']+'\'':[[:space:]]*$/) \
          && (i == NR || lines[i+1] !~ /^        - /)) {
        sub(/:[[:space:]]*$/, ": []", lines[i])
      }
      print lines[i]
    }
  }' "$TMP/new.lock" > "$TMP/new2.lock"

# Drop each gone key with its items, again scoped to the workflows: section.
# The gone list is told apart by FILENAME, not by NR == FNR: gone.txt is
# usually EMPTY, and then NR == FNR holds for every line of the lock, which
# swallowed the whole file and wrote the lock back empty.
"$AWK" '
  FILENAME == ARGV[1] { gone[$0] = 1; next }
  /^workflows:[[:space:]]*$/ { inwf = 1; skip = 0; print; next }
  /^[a-z_]+:/                { inwf = 0; skip = 0; print; next }
  inwf && match($0, /^    '\''([^'\'']+)'\'':/, m) {
    skip = (m[1] in gone); if (skip) { dropped++; next }
  }
  skip && /^        - / { next }
  { skip = 0; print }
  END { if (dropped) printf "prune-stale: dropped %d key(s) for workflow files that no longer exist\n", dropped > "/dev/stderr" }
' "$TMP/gone.txt" "$TMP/new2.lock" > "$TMP/new3.lock"

if command -v diff >/dev/null 2>&1; then diff -u "$LOCK" "$TMP/new3.lock" | sed 's/^/   | /' || true; fi
cat "$TMP/new3.lock" > "$LOCK"
echo "prune-stale: done (oracle vetoes: $kept_by_oracle)"
