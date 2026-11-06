#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# close-lock.sh — make actions.lock TRANSITIVELY CLOSED.
#
# MEASURED on hyperpolymath/cicd-squabbler#101: GitHub rejects a run at startup
# (jobs=0) when the lockfile contains a DANGLING edge — a ref named under
# `workflows:` or inside another record's nested `uses:` that has no top-level
# record of its own. Three workflows that ran with jobs on `pull_request` on
# 2026-09-21 went startup_failure once a job-level ref was listed without
# closure, and adding the record but not its nested refs' records did not cure
# it. metadatastician/burble's working lockfile has zero dangling edges.
#
# Records for actions are written as leaves, without a nested `uses:` list.
#
# A record for a REUSABLE WORKFLOW is not a leaf. MEASURED on
# hyperpolymath/palimpsest-license#177 (2026-10-14): with the job-level
# `hyperpolymath/standards@<sha>` refs listed and LEAF records for them, GitHub
# refused Governance, Hypatia Security Scan and Secret Scanner at startup
# (startup_failure, no jobs) while every step-only workflow started. In the
# estate locks whose reusable callers do start (hyperpolymath/my-lang,
# metadatastician/burble), that record's nested `uses:` is exactly the union of
# the external `uses:` of the workflow files called at that ref, each written as
# the lock key `owner/repo@ref` (a sub-path such as `/init` dropped; local `./`,
# `$/` and `docker://` refs excluded). So every job-level call
# `owner/repo/.github/workflows/<file>@<ref>` in this repository, and every such
# call inside a called file, is read at <ref>, and the record `owner/repo@<ref>`
# is written, or completed where an earlier run left it a leaf or short, with
# that union. The refs it names are then closed by the passes like any other
# edge. A called file that cannot be read is SKIPPED: no record is written or
# changed for its ref and the exit is 3, so a leaf is never written where a list
# is owed.
#
# Lock repair order: gh actions-lock → relock-sha-keys.sh → complete-job-refs.sh
# → close-lock.sh → prune-stale.sh (see complete-job-refs.sh).
#
# Every value taken from the API is SHAPE-checked before it is written: a 40-hex
# commit, two integer ids, and a workflow file with a top-level `jobs:`. On an
# HTTP error `gh api` can put the error body on stdout, and a record built from
# `{"message"…` would be a present-but-unresolvable entry, which is fatal where
# an absent one is merely dangling. A ref that cannot be resolved is SKIPPED,
# reported, and makes the exit 3.
# CHECK MODE: `close-lock.sh --check [DIR | LOCKFILE]` reports the dangling
# edges the passes below would close, and does nothing else: no network, no
# writes. Exit 0 when the lock is closed, 1 when any edge dangles, 2 when there
# is no lock to read. Owner/repo compare case-insensitively, as GitHub's
# lockfile parser canonicalises them (#1294, #1314); refs compare exactly.
# Hypatia reports the same defect as invalid_actions_lock (#963). Run by
# lock-selfcheck.sh and the pre-commit hook; its contract is the corpus in
# scripts/tests/fixtures/actions-lock-closure/.
#
# MOVED TAGS. A leaf record for a SHA-pinned action takes as its `ref:` a tag
# that points at that SHA now. A record whose `ref:` is the SHA itself is
# rejected by runner verification (standards#1271), so none is written. An
# action that moves its tags (dtolnay/rust-toolchain moves `v1`) leaves old pins
# with no tag at all. MEASURED on hyperpolymath/standards run 39286638218
# (2026-10-19 16:36 UTC): the runner said "Using locked action versions from the
# workflow's lockfile", downloaded dtolnay/rust-toolchain@e2a55d2… from a record
# with `ref: 'v1'`, and the step passed. By then `v1` was already 683b588
# (Dependabot moved standards to it at 14:45 UTC, e926751). So a record whose
# `ref:` names a tag that has since moved is accepted. When no current tag points
# at the SHA, and only when the tag listing itself succeeded, one of these is
# tried, in order:
#   1. the record for the same key in the lock as it stood BEFORE
#      `gh actions-lock` rewrote it (`--prior FILE`; regen-dependabot-locks.sh
#      passes it), used only when its commit is that SHA and its owner and repo
#      ids are the ones the API returns now;
#   2. the record for that key in the CALLED repository's own actions.lock, at
#      the ref it is called at, for each reusable whose external `uses:` names
#      the key. This is the lock GitHub validates the called workflow against,
#      and at a SHA pin it cannot change. It closes callers of
#      standards@75bd5994, whose call site comments the pin `# stable` (a
#      branch) and whose own lock records it as `ref: 'v1'`. The same commit
#      and id checks apply;
#   3. the `# <tag>` comment at a call site of that SHA, in this repository's
#      workflows or in a called workflow read below.
# The candidate's `ref:` is written only when it is a tag in that repository
# NOW and its current commit descends from the SHA (compare status `ahead` or
# `identical`). That holds when a tag moved forward past the pin. A branch name
# (`# stable`), a deleted tag, a self-SHA ref and a commit the tag never reached
# are refused, and the key SKIPs with exit 3 as before.
#
# GH_BIN overrides the `gh` binary (the test suite uses an offline stub).
set -euo pipefail
CHECK=0; PRIOR=""
while :; do
  case "${1:-}" in
    --check) CHECK=1; shift ;;
    --prior) PRIOR="${2:?close-lock: --prior needs a FILE}"; shift 2 ;;
    *) break ;;
  esac
done
WF="${1:-.github/workflows}"
if [[ "$CHECK" -eq 1 && -f "$WF" ]]; then L="$WF"; else L="$WF/actions.lock"; fi
GH_BIN="${GH_BIN:-gh}"
if [[ ! -f "$L" ]]; then
  echo "close-lock: no $L" >&2
  [[ "$CHECK" -eq 1 ]] && exit 2
  exit 1
fi
if [[ -n "$PRIOR" && ! -f "$PRIOR" ]]; then
  echo "close-lock: no prior lock $PRIOR" >&2
  exit 1
fi
SC="$(mktemp -d)"; trap 'rm -rf "$SC"' EXIT
TAB="$(printf '\t')"
# Typed lock relations work for block and flow YAML and preserve quoting.
keys() { lock_yaml_json "$L" | jq -r '.dependencies // {} | keys[]' | LC_ALL=C sort -u; }
nested() { lock_yaml_json "$L" | jq -r '.dependencies // {} | .[] | .uses? // [] | .[]' | LC_ALL=C sort -u; }
wfrefs() { lock_yaml_json "$L" | jq -r '.workflows // {} | .[] | .[]' | LC_ALL=C sort -u; }
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
uses_values() { lock_uses "$1" | cut -f2-; }
uses_reusable_calls() { lock_uses "$1" | awk -F'\t' '$1 == "job" { print $2 }' | reusable_calls; }
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

# external_refs: read `uses:` values on stdin; print each external one as its
# lock key owner/repo@ref.
external_refs() {
  awk '/^\.\// || /^\$\// || /^docker:\/\// || !/@/ { next }
       { at = index($0, "@"); n = split(substr($0, 1, at - 1), a, "/")
         if (n >= 2 && a[1] != "" && a[2] != "") print a[1] "/" a[2] "@" substr($0, at + 1) }'
}
# reusable_calls: read `uses:` values on stdin; print "owner/repo@ref<TAB>path"
# for each call of a workflow file in another repository.
reusable_calls() {
  awk '{ at = index($0, "@"); if (!at) next; p = substr($0, 1, at - 1)
         if (p !~ /^[^.\/$][^\/]*\/[^\/]+\/\.github\/workflows\/[^\/]+\.ya?ml$/) next
         split(p, a, "/"); print a[1] "/" a[2] "@" substr($0, at + 1) "\t" substr(p, length(a[1]) + length(a[2]) + 3) }'
}
# keyfile KEY: a file name for KEY's owed nested refs.
keyfile() { printf '%s' "$1" | sha256sum | cut -c1-32; }
uri() { jq -rn --arg value "$1" '$value | @uri'; }
recordable_tag() {
  case "$1" in ''|'@'|-*|refs/*) return 1 ;; esac
  printf '%s' "$1" | grep -qE '^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$|-g[0-9a-fA-F]{4,}$' && return 1
  git check-ref-format "refs/tags/$1" >/dev/null 2>&1
}
# fold: lowercase the owner/repo part of each owner/repo@ref on stdin.
fold() { awk '{ at = index($0, "@"); if (at) print tolower(substr($0, 1, at - 1)) substr($0, at); else print tolower($0) }'; }
# Comments belong to the actual job/step node or its uses scalar. A flow map
# can carry its tag after the closing brace instead of after the scalar.
uses_tags() {
  lock_yaml_json "$1" >/dev/null || return 1
  yq -o=json '(.jobs[]?, .jobs[]?.steps[]?, .runs.steps[]?) | select(tag == "!!map" and has("uses")) | [.uses, (.uses | line_comment), line_comment]' "$1" |
    jq -sr '
      .[] | select(.[0] | type == "string") | .[0] as $use |
      ($use | index("@")) as $at | select($at != null) |
      $use[:$at] as $path | $use[$at+1:] as $sha |
      select(($sha | test("^[0-9a-fA-F]{40}$")) and ($path | startswith("./") or startswith("$/") or startswith("docker://") | not)) |
      ($path | split("/")) as $parts | select(($parts | length) >= 2) |
      (if .[1] != "" then .[1] else .[2] end | capture("^\\s*(?<tag>\\S+)")? | .tag) as $tag |
      select($tag != null) | [($parts[0]+"/"+$parts[1]+"@"+$sha),$tag] | @tsv'
}

# lock_record FILE KEY: "ref<TAB>commit<TAB>owner_id<TAB>repo_id" of KEY's record
# in the lock FILE (owner/repo compared case-insensitively), or nothing.
lock_record() {
  [ -s "$1" ] || return 0
  local parsed
  parsed=$(lock_yaml_json "$1" 2>/dev/null) || return 0
  printf '%s' "$parsed" | jq -r --arg key "$(printf '%s\n' "$2" | fold)" '
    def norm: index("@") as $at | if $at == null then . else (.[:$at] | ascii_downcase) + .[$at:] end;
    .dependencies // {} | to_entries[] | select((.key | norm) == $key) | .value |
    select(type == "object" and (.ref | type == "string")) |
    [.ref, (.commit // ""), (.owner_id // ""), (.repo_id // "")] | @tsv'
}

# try_record LABEL FILE: when FILE holds a record for the leaf key $k whose
# commit is $sha, whose ids are $ids, and whose ref: is a tag that moved forward
# from $sha, set tag_ref and src. Otherwise add the reason to why and fail.
try_record() {
  local rr rc ro rp r
  IFS="$TAB" read -r rr rc ro rp <<<"$(lock_record "$2" "$k")" || true
  [ -n "$rr" ] || return 1
  if [ "$rc" != "sha1-$sha" ]; then why="$why; $1: commit $rc"
  elif [ "$ro $rp" != "$ids" ]; then why="$why; $1: ids $ro $rp, API $ids"
  elif r=$(moved_tag "$owner" "$name" "$sha" "$rr"); then tag_ref="$rr"; src="$1"; return 0
  else why="$why; $1 ref '$rr': $r"; fi
  return 1
}
# moved_tag OWNER NAME SHA TAG: succeed when TAG is a tag of OWNER/NAME now (not
# a branch, not a SHA) and its current commit descends from SHA, i.e. the tag
# moved forward past the pin. Otherwise print why on stdout and fail.
moved_tag() {
  local tsha st
  if ! recordable_tag "$4"; then
    echo "not a symbolic tag name"; return 1
  fi
  tsha=$("$GH_BIN" api "repos/$1/$2/commits/tags/$(uri "$4")" --jq .sha 2>/dev/null) || tsha=""
  if ! printf '%s' "$tsha" | grep -qxE '[0-9a-f]{40}'; then echo "no tag of that name"; return 1; fi
  st=$("$GH_BIN" api "repos/$1/$2/compare/$3...$tsha" --jq .status 2>/dev/null) || st=""
  case "$st" in ahead|identical) return 0 ;; esac
  echo "tag is at ${tsha:0:12}, which does not descend from the pin (compare: ${st:-failed})"; return 1
}

if [[ "$CHECK" -eq 1 ]]; then
  lock_yaml_json "$L" >/dev/null || exit 2
  keys | fold | LC_ALL=C sort -u > "$SC/have"
  { nested; wfrefs; } | LC_ALL=C sort -u > "$SC/want"
  : > "$SC/miss"
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    grep -qxF "$(printf '%s\n' "$k" | fold)" "$SC/have" || printf '%s\n' "$k" >> "$SC/miss"
  done < "$SC/want"
  n=$(wc -l < "$SC/miss")
  if [[ "$n" -eq 0 ]]; then
    echo "close-lock: closed (no dangling edges) in $L"
    exit 0
  fi
  echo "close-lock: NOT closed: $n dangling edge(s) in $L"
  sed 's/^/  /' "$SC/miss"
  echo "  Each is named under workflows: or in a record's nested uses: and has no"
  echo "  top-level record of its own. Repair: bash scripts/close-lock.sh (needs gh)."
  exit 1
fi

# ── reusable workflows: read each called file once, transitively ─────────────
mkdir -p "$SC/u" "$SC/cl"; : > "$SC/read"; : > "$SC/bad"; : > "$SC/more"; : > "$SC/ctags"
for f in "$WF"/*.yml "$WF"/*.yaml; do
  [ -e "$f" ] || continue
  uses_tags "$f" >> "$SC/ctags"
  uses_reusable_calls "$f"
done | LC_ALL=C sort -u > "$SC/calls"
while :; do
  LC_ALL=C comm -23 "$SC/calls" "$SC/read" > "$SC/todo"
  [ -s "$SC/todo" ] || break
  while IFS="$TAB" read -r k p; do
    [ -n "$k" ] || continue
    printf '%s\t%s\n' "$k" "$p" >> "$SC/read"
    owner="${k%%/*}"; rest="${k#*/}"; name="${rest%%@*}"; ref="${k#*@}"
    if "$GH_BIN" api "repos/$owner/$name/contents/$p?ref=$(uri "$ref")" -H 'Accept: application/vnd.github.raw' > "$SC/body" 2>/dev/null \
       && called_json=$(lock_yaml_json "$SC/body") \
       && printf '%s' "$called_json" | jq -e '.jobs | type == "object"' >/dev/null \
       && called_uses=$(lock_uses "$SC/body"); then
      printf '%s\n' "$called_uses" | cut -f2- | external_refs >> "$SC/u/$(keyfile "$k")"
      printf '%s\n' "$called_uses" | awk -F'\t' '$1 == "job" { print $2 }' | reusable_calls >> "$SC/more"
      uses_tags "$SC/body" >> "$SC/ctags"
      # The called repository's own lock at that ref. GitHub validates the called
      # workflow against it, and at a SHA pin it cannot change. A missing or
      # malformed one is simply not a source: lock_record reads records only
      # under a dependencies: section.
      cl="$SC/cl/$(keyfile "$k")"
      if [ ! -e "$cl" ]; then
        "$GH_BIN" api "repos/$owner/$name/contents/.github/workflows/actions.lock?ref=$(uri "$ref")" \
          -H 'Accept: application/vnd.github.raw' > "$cl" 2>/dev/null || : > "$cl"
      fi
    else
      echo "  SKIP $k (cannot read $p at $ref)"; echo "$k" >> "$SC/bad"
    fi
  done < "$SC/todo"
  LC_ALL=C sort -u -o "$SC/read" "$SC/read"
  cat "$SC/calls" "$SC/more" | LC_ALL=C sort -u > "$SC/calls.new"; mv "$SC/calls.new" "$SC/calls"; : > "$SC/more"
done
LC_ALL=C sort -u -o "$SC/bad" "$SC/bad"
# owed: "key<TAB>ref" per nested ref a readable reusable record must list, plus
# "key<TAB>" for each such key, so a reusable that uses no external action is
# still known (its record correctly stays a leaf).
: > "$SC/owed"
cut -f1 "$SC/calls" | LC_ALL=C sort -u | while read -r k; do
  grep -qxF "$k" "$SC/bad" && continue
  printf '%s\t\n' "$k"
  uf="$SC/u/$(keyfile "$k")"
  if [ -f "$uf" ]; then
    LC_ALL=C sort -u "$uf" | while read -r r; do printf '%s\t%s\n' "$k" "$r"; done
  fi
done | LC_ALL=C sort -u > "$SC/owed"
skipped=$(grep -c . "$SC/bad" || true)

# uses_block KEY: print the nested `uses:` lines owed by KEY's record (none for
# an action, or for a reusable that uses no external action).
uses_block() {
  awk -F'\t' -v k="$1" '$1 == k && $2 != "" { if (!h++) print "        uses:"; print "            - '\''" $2 "'\''" }' "$SC/owed"
}

# Complete known reusable records using parsed coordinates. Preserve all
# provenance fields; only their owed uses list changes in this phase.
lock_yaml_json "$L" > "$SC/before.json"
jq -Rn '
  def norm: index("@") as $at | (.[:$at] | ascii_downcase) + .[$at:];
  reduce inputs as $line ({}; ($line | split("\t")) as $row | ($row[0] | norm) as $key |
    .[$key] = ((.[$key] // []) + (if ($row[1] // "") == "" then [] else [$row[1]] end))) |
  with_entries(.value |= (unique | sort))
' "$SC/owed" > "$SC/owed.json"
jq --slurpfile owed "$SC/owed.json" '
  def norm: index("@") as $at | (.[:$at] | ascii_downcase) + .[$at:];
  .dependencies // {} | with_entries((.key | norm) as $key |
    if ($owed[0] | has($key)) then
      if ($owed[0][$key] | length) > 0 or (.value | has("uses"))
      then .value.uses = $owed[0][$key] else . end
    else . end)
' "$SC/before.json" > "$SC/dependencies.json"
if ! jq -ne --slurpfile before "$SC/before.json" --slurpfile after "$SC/dependencies.json" '($before[0].dependencies // {}) == $after[0]' >/dev/null; then
  lock_write_section "$L" dependencies "$SC/dependencies.json"
  while read -r k; do echo "  ~ $k (nested uses: completed from its called workflow)"; done < <(cut -f1 "$SC/owed" | LC_ALL=C sort -u)
fi

# ── close every dangling edge ─────────────────────────────────────────────────
for pass in 1 2 3 4 5 6; do
  keys > "$SC/have"
  { nested; wfrefs; } | LC_ALL=C sort -u > "$SC/want"
  LC_ALL=C comm -23 "$SC/want" "$SC/have" > "$SC/miss"
  n=$(wc -l < "$SC/miss")
  echo "close-lock: pass $pass — dangling refs: $n"
  [ "$n" -eq 0 ] && break
  : > "$SC/new"
  while read -r k; do
    [ -n "$k" ] || continue
    if grep -qxF "$k" "$SC/bad"; then
      echo "  SKIP $k (its called workflow is unreadable; no leaf record written)"; continue
    fi
    owner="${k%%/*}"; rest="${k#*/}"; name="${rest%%@*}"; ref="${k#*@}"
    ids=$("$GH_BIN" api "repos/$owner/$name" --jq '"\(.owner.id) \(.id)"') || ids=""
    if ! printf '%s' "$ids" | grep -qxE '[0-9]+ [0-9]+'; then
      echo "  SKIP $k (repo lookup failed or malformed)"; skipped=$((skipped + 1)); continue
    fi
    sha=""
    if printf '%s' "$ref" | grep -qxE '[0-9a-f]{40}'; then sha="$ref"
    else sha=$("$GH_BIN" api "repos/$owner/$name/commits/$(uri "$ref")" --jq .sha) || sha=""; fi
    if ! printf '%s' "$sha" | grep -qxE '[0-9a-f]{40}'; then
      echo "  SKIP $k (cannot resolve commit)"; skipped=$((skipped + 1)); continue
    fi
    rec_ref="$ref"
    if printf '%s' "$ref" | grep -qxE '[0-9a-f]{40}' && ! grep -qxF "$k$TAB" "$SC/owed"; then
      # Consume all pages before choosing a tag. An early pipeline exit can
      # SIGPIPE gh under pipefail and discard an otherwise valid result.
      tag_ref=""; listed=0; why=""
      if "$GH_BIN" api "repos/$owner/$name/tags?per_page=100" --paginate \
          --jq '.[] | select(.commit.sha == "'"$sha"'") | .name' > "$SC/tags" 2>/dev/null; then
        listed=1
        first_tag=""; preferred_tag=""
        while IFS= read -r candidate; do
          if recordable_tag "$candidate"; then
            [ -n "$first_tag" ] || first_tag="$candidate"
            if [ -z "$preferred_tag" ] && [[ "$candidate" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then preferred_tag="$candidate"; fi
          fi
        done < "$SC/tags"
        tag_ref="${preferred_tag:-$first_tag}"
      fi
      # No current tag points at the SHA: try a moved tag (see MOVED TAGS).
      if [ -z "$tag_ref" ] && [ "$listed" -eq 1 ]; then
        if [ -n "$PRIOR" ]; then try_record "the prior lock record" "$PRIOR" || true; fi
        if [ -z "$tag_ref" ]; then
          kf="$(printf '%s\n' "$k" | fold)"
          while IFS= read -r rk; do
            uf="$SC/u/$(keyfile "$rk")"
            if [ -f "$uf" ] && fold < "$uf" | grep -qxF "$kf"; then
              if try_record "the lock of $rk" "$SC/cl/$(keyfile "$rk")"; then break; fi
            fi
          done < <(cut -f1 "$SC/calls" | LC_ALL=C sort -u)
        fi
        if [ -z "$tag_ref" ]; then
          while IFS= read -r c; do
            [ -n "$c" ] || continue
            if r=$(moved_tag "$owner" "$name" "$sha" "$c"); then tag_ref="$c"; src="a call-site comment"; break; fi
            why="$why; call-site '# $c': $r"
          done < <(awk -F'\t' -v k="$(printf '%s\n' "$k" | fold)" 'BEGIN { OFS = "\t" }
                   { at = index($1, "@"); if (tolower(substr($1, 1, at - 1)) substr($1, at) == k) print ($2 ~ /^v?[0-9]+\.[0-9]+\.[0-9]+/ ? 0 : 1), $2 }' \
                   "$SC/ctags" | LC_ALL=C sort -u | cut -f2)
        fi
        [ -n "$tag_ref" ] && echo "  ~ $k ref '$tag_ref' from $src: no current tag points at the pin; the tag moved forward from it"
      fi
      if [ -z "$tag_ref" ]; then
        echo "  SKIP $k (cannot resolve a symbolic tag for leaf SHA${why:+$why})"
        skipped=$((skipped + 1))
        continue
      fi
      rec_ref="$tag_ref"
    fi
    refs=$(jq -Rn --arg key "$k" '[inputs | split("\t") | select(.[0] == $key and (.[1] // "") != "") | .[1]]' "$SC/owed")
    jq -cn --arg key "$k" --arg ref "$rec_ref" --arg sha "$sha" --argjson owner "${ids%% *}" --argjson repo "${ids##* }" --argjson uses "$refs" '
      {key:$key, value:({ref:$ref,commit:("sha1-" + $sha),owner_id:$owner,repo_id:$repo} +
        (if ($uses | length) > 0 then {uses:$uses} else {} end))}
    ' >> "$SC/new"
    echo "  + $k"
  done < "$SC/miss"
  [ -s "$SC/new" ] || break
  lock_yaml_json "$L" > "$SC/before.json"
  jq -s 'from_entries' "$SC/new" > "$SC/additions.json"
  jq --slurpfile additions "$SC/additions.json" '(.dependencies // {}) + $additions[0] | to_entries | sort_by(.key) | from_entries' "$SC/before.json" > "$SC/dependencies.json"
  lock_write_section "$L" dependencies "$SC/dependencies.json"

done
if [ "$skipped" -gt 0 ]; then
  echo "close-lock: $skipped ref(s) could not be resolved or read; lock is NOT closed" >&2
  exit 3
fi
if ! bash "${BASH_SOURCE[0]}" --check "$L"; then
  echo 'close-lock: repair did not establish closure; lock is NOT closed' >&2
  exit 3
fi
echo "close-lock: done"
