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
  lock_uses "$1" | awk -F'\t' 'substr($2, 1, 2) == "./" { print $2 == "./" ? "." : substr($2, 3) }'
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
# Encode modified mappings with the YAML library, not interpolated quotes.
# Validate the round trip and preserve every value outside the chosen section.
lock_write_section() {
  local original=$1 section=$2 data=$3 staging expression status=1
  case "$section" in workflows|dependencies) ;; *) return 1 ;; esac
  jq -e 'type == "object"' "$data" >/dev/null || return 1
  staging=$(mktemp -d "$(dirname "$original")/.actions-lock-edit.XXXXXX") || return 1
  if [ "$section" = workflows ]; then
    expression='explode(.) | .workflows = load(strenv(LOCK_EDIT_DATA)) | (.workflows | ...) style="" | (.workflows | ... | select(tag == "!!str")) style="single"'
  else
    expression='explode(.) | .dependencies = load(strenv(LOCK_EDIT_DATA)) | (.dependencies | ...) style="" | (.dependencies[]? | key) style="single" | (.dependencies[]? | select(tag == "!!map") | select(has("ref")) | .ref) style="single" | (.dependencies[]? | select(tag == "!!map") | select(has("commit")) | .commit) style="single" | (.dependencies[]? | select(tag == "!!map") | select(has("hostname")) | .hostname) style="single" | (.dependencies[]? | select(tag == "!!map") | select(has("uses")) | .uses[]?) style="single"'
  fi
  if lock_yaml_json "$original" > "$staging/before.json" &&
     cp -p "$original" "$staging/new.lock" &&
     LOCK_EDIT_DATA="$data" yq -I=4 "$expression" "$original" > "$staging/new.lock" &&
     lock_yaml_json "$staging/new.lock" > "$staging/after.json" &&
     jq -ne --arg section "$section" --slurpfile before "$staging/before.json" --slurpfile after "$staging/after.json" --slurpfile wanted "$data" '
       $after[0][$section] == $wanted[0] and
       ($before[0] | del(.[$section])) == ($after[0] | del(.[$section]))
     ' >/dev/null; then
    mv -f "$staging/new.lock" "$original" && status=0
  else
    echo "actions-lock: refusing a rewrite that changes lock semantics outside $section" >&2
  fi
  rm -rf -- "$staging"
  return "$status"
}


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
  # Even an action-free workflow needs a key; an empty wanted ref emits [].
  printf '%s\t\n' "$b"
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

# Parse existing entries before merging so escaped refs survive another pass.
lock_yaml_json "$L" > "$TMP/before.json"
jq -e '.workflows | type == "object"' "$TMP/before.json" >/dev/null || {
  echo 'complete-job-refs: lock has no workflows mapping' >&2; exit 2;
}
jq -Rn '[inputs | split("\t") | {path:.[0], ref:(.[1] // "")}]' "$WANT" > "$TMP/wanted.json"
jq --slurpfile wanted "$TMP/wanted.json" '
  def norm: index("@") as $at | if $at == null then . else (.[:$at] | ascii_downcase) + .[$at:] end;
  (.dependencies // {} | keys) as $records |
  reduce $wanted[0][] as $row (.workflows;
    .[$row.path] = ((.[$row.path] // []) + (if $row.ref == "" then [] else [$row.ref] end))) |
  with_entries(.value |= (
    reduce .[] as $ref ({}; ($ref | norm) as $key |
       .[$key] as $kept | if $kept == null or (($records | index($ref)) != null and ($records | index($kept)) == null)
      then .[$key] = $ref else . end) | [.[]] | sort)) |
  to_entries | sort_by(.key) | from_entries
' "$TMP/before.json" > "$TMP/workflows.json"
added=$(jq -n --slurpfile before "$TMP/before.json" --slurpfile after "$TMP/workflows.json" '
  ([$after[0][] | .[]] | unique) - ([$before[0].workflows[] | (. // [])[]] | unique) | length')
lock_write_section "$L" workflows "$TMP/workflows.json"
echo "complete-job-refs: distinct refs newly present in workflows section: $added"
