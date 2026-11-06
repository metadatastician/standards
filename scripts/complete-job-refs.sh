#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# complete-job-refs.sh — add job-level reusable-workflow refs, and the refs a
# workflow uses through its local composite actions, to actions.lock.
# `gh actions-lock` v0.1.6 is blind to job-level `uses:` (upstream #129; v0.2.0
# still is, re-measured 2026-10-14), so the
# entries it cannot write are written here. Idempotent; run from a repo root.
#
# Lock repair order (each step idempotent, run from a repo root):
#   gh actions-lock  →  scripts/relock-sha-keys.sh  →  scripts/complete-job-refs.sh
#   →  scripts/close-lock.sh  →  scripts/prune-stale.sh
# relock-sha-keys re-keys tag-spelled entries to the inline SHA the YAML pins
# (GitHub compares lock and YAML as LITERAL strings); complete-job-refs adds the
# job-level reusable refs the tool cannot see, and the refs used through local
# composite actions (standards#1122); close-lock adds a record for every
# dangling edge, and gives each job-level reusable ref's record the `uses:` of
# the workflow it calls; prune-stale drops per-workflow refs nothing uses.
set -euo pipefail
WF="${1:-.github/workflows}"
L="$WF/actions.lock"
[ -f "$L" ] || { echo "complete-job-refs: no $L" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WANT="$TMP/want"; NEW="$TMP/new.lock"; DEPS="$TMP/deps"
# Local composite actions (standards#1122). A local action (`uses: ./dir`) has
# no dependency record of its own, so the actions it uses belong in the CALLING
# workflow's entry. gh actions-lock writes them there; prune-stale used to drop
# them. Adding them here makes the chain produce them whatever the tool did.
WF_DIR="$WF"
# ── local composite actions (identical block in check-lock-sync.sh, ─────────
# ── prune-stale.sh and complete-job-refs.sh; they must agree) ─────────────────
# reach_files WORKFLOW prints WORKFLOW and every local composite action file
# (`uses: ./dir` -> dir/action.yml or dir/action.yaml) it reaches, transitively,
# each once. A local reusable workflow (`./….yml`) is a lock entry of its own,
# so it is not followed. Paths resolve from the repository root, as GitHub
# resolves them from the workspace.
LC_ROOT="$(cd "$WF_DIR/../.." 2>/dev/null && pwd)" || LC_ROOT=.
# Parse one YAML document and reject duplicate mapping keys before converting
# to JSON. yq exposes node keys without discarding duplicates; JSON alone does
# not. jq handles typed fields after YAML comments, aliases and quoting decode.
lock_yaml_json() {
  command -v yq >/dev/null && command -v jq >/dev/null || {
    echo 'actions-lock: requires Mike Farah yq v4 and jq' >&2; return 1;
  }
  yq --version | grep -Eq 'github.com/mikefarah/yq/.*version v4\.' || {
    echo 'actions-lock: requires Mike Farah yq v4' >&2; return 1;
  }
  yq -o=json '[... | select(tag == "!!map") | keys]' "$1" |
    jq -se 'length == 1 and all(.[0][]; length == (unique | length))' >/dev/null || {
      echo "actions-lock: malformed YAML, multiple documents or duplicate mapping keys: $1" >&2; return 1;
    }
  yq -o=json '.' "$1" | jq -sce 'if length == 1 then .[0] else error("expected one YAML document") end'
}
# Only actual job/step fields count. Ordinary env/input maps, strings and
# block scalars can contain the word uses without declaring a dependency.
lock_uses() {
  lock_yaml_json "$1" | jq -r '
    def emit($kind):
      if has("uses") then .uses |
        if type != "string" or length == 0 or test("[\t\r\n]") then error("uses must be a nonempty single-line string")
        else [$kind, .] | @tsv end
      else empty end;
    if type != "object" then error("workflow/action must be a mapping") else
      (.jobs // {} | .[] | emit("job")),
      (.jobs // {} | .[] | .steps // [] | .[] | emit("step")),
      (.runs.steps? // [] | .[] | emit("step"))
    end'
}
local_action_paths() {
  lock_uses "$1" | awk -F'\t' 'substr($2, 1, 2) == "./" { print substr($2, 3) }'
}
reach_files() {
  local -A seen=()
  local queue=("$1") f rel a found paths
  while [ "${#queue[@]}" -gt 0 ]; do
    f="${queue[0]}"; queue=("${queue[@]:1}")
    [ -n "${seen[$f]:-}" ] && continue
    seen[$f]=1
    printf '%s\n' "$f"
    paths=$(local_action_paths "$f") || return 1
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      rel="${rel%/}"
      found=false
      for a in "$LC_ROOT/$rel/action.yml" "$LC_ROOT/$rel/action.yaml"; do
        if [ -f "$a" ]; then queue+=("$a"); found=true; break; fi
      done
      "$found" && continue
      case "$rel" in
        *.yml|*.yaml)
          [ -f "$LC_ROOT/$rel" ] || { echo "actions-lock: missing local workflow or action metadata: $rel" >&2; return 1; }
          continue ;;
      esac
      echo "actions-lock: missing local action metadata: $rel" >&2; return 1
    done <<< "$paths"
  done
}
# ── end of the shared block ───────────────────────────────────────────────────

# uses_values FILE: every `uses:` value in FILE, with a trailing comment, YAML
# quotes and a KYAML trailing comma stripped.
uses_values() { lock_uses "$1" | cut -f2-; }

# 1. enumerate each workflow's direct refs as well as reusable/composite refs.
# This completes workflow membership for actions already resolved elsewhere in
# the lock; it never resolves or changes a dependency digest. Offline verification
# must still reject any reference without its own dependency entry.
: > "$WANT"
for f in "$WF"/*.yml "$WF"/*.yaml; do
  [ -e "$f" ] || continue
  b=".github/workflows/$(basename "$f")"
  reach_files "$f" > "$TMP/reached" || exit 1
  set +e
  {
    uses_values "$f"
    tail -n +2 "$TMP/reached" | while IFS= read -r a; do uses_values "$a"; done
  } | while read -r u; do
      case "$u" in ./*|\$/*|docker://*|'') continue;; esac
      case "$u" in *@*) : ;; *) continue;; esac
      p="${u%%@*}"; r="${u#*@}"
      o=$(printf '%s' "$p" | cut -d/ -f1); n=$(printf '%s' "$p" | cut -d/ -f2)
      printf '%s\t%s/%s@%s\n' "$b" "$o" "$n" "$r"
    done
  set -e
done | LC_ALL=C sort -u >> "$WANT"

# The dependency keys already recorded. When one workflow entry holds two
# case spellings of the same owner/repo@ref, the one with a record is kept.
awk -v q="'" '/^dependencies:/ { d = 1; next }
  d && index($0, "    " q) == 1 && substr($0, length($0) - 1) == q ":" { print substr($0, 6, length($0) - 7) }' "$L" > "$DEPS"

# 2. rewrite the workflows: section, merging wanted job refs into each path entry
LC_ALL=C awk -v want="$WANT" -v deps="$DEPS" '
BEGIN { while ((getline l < want) > 0) { split(l, w, "\t"); WANT[w[1]] = WANT[w[1]] SUBSEP w[2] }
        while ((getline l < deps) > 0) DEP[l] = 1 }
# ck: the dedup key of a ref, split at the FIRST @ (owner/repo cannot contain
# one; a tag such as `release@2026` can). GitHub owner/repository names are
# case-insensitive; refs are not (the same rule as check-lock-sync.sh). An
# existing `swatinem/rust-cache@v2` entry therefore already covers
# `uses: Swatinem/rust-cache@v2`; adding the second spelling left a ref that
# close-lock then tried to resolve as a new repository.
function ck(s,   i) { i = index(s, "@"); return i ? tolower(substr(s, 1, i - 1)) substr(s, i) : s }
# keep: add ref a to out unless a case spelling of it is already there; of two
# spellings, the one with a dependency record wins (a lock written before the
# case fix can hold both, sorted capitalised-first).
function keep(a,   k) {
  if (a == "") return
  k = ck(a)
  if (!(k in seen)) { seen[k] = ++c; out[c] = a }
  else if ((a in DEP) && !(out[seen[k]] in DEP)) out[seen[k]] = a
}
# flush: write the current workflow entry, merged with its wanted refs, sorted and deduplicated.
function flush(   i, n, arr, j, k) {
  if (cur == "") return
  SEEN[cur] = 1
  n = split(items, arr, SUBSEP)
  c = 0; delete seen; delete out
  for (i = 1; i <= n; i++) keep(arr[i])
  if (cur in WANT) { n = split(WANT[cur], arr, SUBSEP)
    for (i = 1; i <= n; i++) keep(arr[i]) }
  if (c == 0) { printf "    '\''%s'\'': []\n", cur; cur = ""; items = ""; return }
  for (i = 1; i < c; i++) for (j = i + 1; j <= c; j++) if (out[j] < out[i]) { k = out[i]; out[i] = out[j]; out[j] = k }
  printf "    '\''%s'\'':\n", cur
  for (i = 1; i <= c; i++) printf "        - '\''%s'\''\n", out[i]
  cur = ""; items = ""
}
# rest: create entries for wanted workflow paths the lock has no entry for yet.
function rest(   k, ks, c, i, j, t) {
  c = 0; for (k in WANT) if (!(k in SEEN)) ks[++c] = k
  for (i = 1; i < c; i++) for (j = i + 1; j <= c; j++) if (ks[j] < ks[i]) { t = ks[i]; ks[i] = ks[j]; ks[j] = t }
  for (i = 1; i <= c; i++) { cur = ks[i]; items = ""; flush() }
}
/^workflows:[[:space:]]*$/ { print; inwf = 1; sawwf = 1; next }
inwf && /^[a-z_]+:/ { flush(); rest(); inwf = 0; print; next }
inwf {
  if (match($0, /^    '\''[^'\'']+'\'':/)) { flush()
    cur = $0; sub(/^    '\''/, "", cur); sub(/'\''.*$/, "", cur)
    items = ""
    next
  }
  if (match($0, /^        - '\''[^'\'']+'\''[[:space:]]*$/)) {
    it = $0; sub(/^        - '\''/, "", it); sub(/'\''[[:space:]]*$/, "", it)
    items = items SUBSEP it; next
  }
  next
}
{ print }
END {
  if (inwf) { flush(); rest() }
  if (!sawwf) for (k in WANT) { print "complete-job-refs: lock has no workflows: section" > "/dev/stderr"; exit 2 }
}
' "$L" > "$NEW"

added=$(LC_ALL=C comm -13 <(grep -oE "^        - '[^']+'" "$L" | sed "s/.*- '//;s/'$//" | LC_ALL=C sort -u) \
                 <(grep -oE "^        - '[^']+'" "$NEW" | sed "s/.*- '//;s/'$//" | LC_ALL=C sort -u) | wc -l)
cat "$NEW" > "$L"
echo "complete-job-refs: distinct refs newly present in workflows section: $added"
