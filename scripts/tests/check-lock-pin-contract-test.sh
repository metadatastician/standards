#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Regression corpus for scripts/check-lock-pin-contract.sh.
#
# The fixtures reproduce the REPRESENTATIONS observed in this repository's own
# history, not invented shapes:
#   * the runner-invalid raw-SHA `ref` measured at standards fad242d3
#     (metadatastician/svalinn run 40108154356, "invalid lockfile pin"), and
#     the corrected `ref: v7.0.1` + `sha1-` form measured at 1725bebd;
#   * the caller-side reusable edge (`metadatastician/standards@<sha>` with a
#     nested `uses:`) that standards#1290 states is legitimate as-is;
#   * the tag-keyed record (`actions/setup-python@v2`) measured at fad242d3.
#
# A fixture that passes when the guard is broken and a fixture that fails when
# it is correct are both failures. Every case asserts the exact exit code.
#
# Exit: 0 all cases behave; 2 the guard cannot be exercised (no yq/jq).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-lock-pin-contract.sh"
SELF_REPO='metadatastician/standards'

command -v yq >/dev/null 2>&1 || { echo 'SKIP(2): yq not installed' >&2; exit 2; }
yq --version 2>/dev/null | grep -q mikefarah || { echo 'SKIP(2): mikefarah yq v4 required' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'SKIP(2): jq not installed' >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sha='3d3c42e5aac5ba805825da76410c181273ba90b1'
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# One leaf record. $1 schema, $2 ref (raw YAML), $3 commit (raw YAML).
# Records are written in the shape gh-actions-lock emits and close-lock.sh
# reads: 4-space quoted record keys, 8-space quoted list items. A fixture in
# any other shape would test this guard against a file the closure delegate
# cannot read.
leaf() {
  printf 'version: %s\nworkflows:\n    '\''.github/workflows/a.yml'\'':\n        - '\''actions/checkout@%s'\''\ndependencies:\n    '\''actions/checkout@%s'\'':\n        ref: %s\n        commit: %s\n        owner_id: 44036562\n        repo_id: 197814629\n' \
    "$1" "$sha" "$sha" "$2" "$3" > "$tmp/lock.yml"
}

# assert <label> <expected-rc> [guard args...]
assert() {
  local label=$1 expected=$2; shift 2
  local rc=0 out
  out="$(bash "$GUARD" "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne "$expected" ]; then
    printf '%s\n' "$out" | sed 's/^/    /'
    bad "$label (wanted exit $expected, got $rc)"
  else
    ok "$label"
  fi
}

# ── representation: the defect and its cure ──────────────────────────────
leaf v0.0.3 "\"$sha\"" "\"sha1-$sha\""
assert 'historical runner-invalid raw-SHA ref is rejected' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

leaf v0.0.3 'v7.0.1' "\"sha1-$sha\""
assert 'corrected reviewed tag with matching commit is accepted' 0 "$tmp/lock.yml" --self-repo "$SELF_REPO"

leaf v0.0.2 'v7.0.1' "\"sha1-$sha\""
assert 'v0.0.2 schema representation is supported' 0 "$tmp/lock.yml" --self-repo "$SELF_REPO"

leaf v0.0.3 'v7.0.1' 'sha1-ffffffffffffffffffffffffffffffffffffffff'
assert 'commit disagreeing with the pinned SHA is rejected' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

leaf v0.0.3 'v7.0.1' "\"$sha\""
assert 'commit without the sha1- algorithm is rejected' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

leaf v0.0.3 "''" "\"sha1-$sha\""
assert 'empty ref is rejected' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

leaf v0.0.3 'null' "\"sha1-$sha\""
assert 'null ref is rejected' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# ── the standards#1290 exemption, and its exact boundary ─────────────────
# selfreusable RECORD-REF uses|leaf REPO [caller|nocaller]
# The guard now requires IDENTITY, not just a `uses:` list: the record must be
# called as a job-level reusable workflow by some workflow beside the lock, or a
# composite action's transitive `uses:` list would buy the raw-SHA exemption.
selfreusable() {  # $1 record ref, $2 "uses" or "leaf", $3 repo, $4 caller (default)
  rm -f "$tmp/mirror.yml"
  {
    printf 'version: v0.0.3\nworkflows:\n    '\''.github/workflows/mirror.yml'\'':\n        - '\''%s@%s'\''\ndependencies:\n' "$3" "$sha"
    printf '    '\''%s@%s'\'':\n        ref: %s\n        commit: sha1-%s\n        owner_id: 297579217\n        repo_id: 1116521501\n' \
      "$3" "$sha" "$1" "$sha"
    if [ "$2" = uses ]; then
      printf "        uses:\n            - 'actions/checkout@%s'\n" "$sha"
      printf "    'actions/checkout@%s':\n        ref: v7.0.1\n        commit: sha1-%s\n        owner_id: 44036562\n        repo_id: 197814629\n" "$sha" "$sha"
    fi
  } > "$tmp/lock.yml"
  if [ "$2" = uses ] && [ "${4:-caller}" = caller ]; then
    printf 'name: mirror\non: [push]\njobs:\n  m:\n    uses: %s/.github/workflows/mirror-reusable.yml@%s\n' "$3" "$sha" > "$tmp/mirror.yml"
  fi
}

selfreusable "$sha" uses "$SELF_REPO"
assert 'a reusable edge may repeat its pin in ref' 0 "$tmp/lock.yml" --self-repo "$SELF_REPO"

selfreusable "$sha" leaf "$SELF_REPO"
assert 'same repository, but a LEAF record: exemption does not apply' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# DOCTRINE CHANGE (review finding, 2026-10-31): the exemption used to be
# confined to this repository's own slug. That made the documented
# record-with-`uses:` closure shape IMPOSSIBLE for a third-party reusable:
# check-reusable-closure.sh requires a reusable record's `ref` to equal the ref
# the caller named, so a SHA-pinned call to `someoneelse/standards@<sha>` could
# only be recorded as `ref: <sha>` — which this guard then rejected. The test is
# now the SHAPE (a non-empty `uses:` list, `ref` exactly equal to the key's
# SHA), which is what the runner actually distinguishes; `--self-repo` labels
# the exemption as caller-side or third-party and no longer gates it.
selfreusable "$sha" uses 'someoneelse/standards'
assert "a third-party reusable edge is exempt on shape, not on identity" 0 "$tmp/lock.yml" --self-repo "$SELF_REPO"

selfreusable "$sha" uses "$SELF_REPO"
assert '--self-repo no longer gates the exemption (it labels it)' 0 "$tmp/lock.yml" --self-repo 'example/other'

# IDENTITY, not shape: a composite action carries a transitive `uses:` list too,
# so a record with uses: and ref==SHA is NOT exempt unless a workflow calls it as
# a job-level reusable. Without this, `actions/upload-pages-artifact@<sha>` could
# rewrite its ref to its own SHA and pass — the exact runner-invalid shape.
selfreusable "$sha" uses 'actions/upload-pages-artifact' nocaller
assert 'a composite-action record is NOT exempt on its uses: list alone' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# ...but the shape test still has hard boundaries. A `uses:` that is not a LIST
# is not an edge: treating a mapping as one granted the exemption to a record
# close-lock.sh sees no edge for.
{
  printf 'version: v0.0.3\ndependencies:\n    '\''%s@%s'\'':\n        ref: %s\n        commit: sha1-%s\n        owner_id: 297579217\n        repo_id: 1116521501\n        uses: {checkout: %s}\n' \
    "$SELF_REPO" "$sha" "$sha" "$sha" "actions/checkout@$sha"
} > "$tmp/lock.yml"
assert 'a non-list uses: is rejected, not treated as an edge' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# ...and the ref must be the SAME SHA as the key. A 40-hex ref that differs
# from the pin is the historical defect wearing an edge's clothes.
selfreusable '1111111111111111111111111111111111111111' uses "$SELF_REPO"
assert "a reusable edge whose ref is a different SHA is still rejected" 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# The repository was transferred; its ID did not change. A lock written before
# the transfer names the old slug for the same repository, and old locks are
# exactly what a pinned caller is judged by. Both slugs remain recognised — the
# label differs, the verdict does not.
selfreusable "$sha" uses 'hyperpolymath/standards'
assert 'a reusable edge written under the pre-transfer slug is exempt' 0 "$tmp/lock.yml"
assert 'and it is still exempt when --self-repo asks narrowly' 0 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# ── key shape: an `@` is not enough ──────────────────────────────────────
for bad in 'not-a-repo' '/repo' 'owner/repo/sub@'"$sha" 'owner@name/repo'; do
  printf 'version: v0.0.3\ndependencies:\n    '\''%s@%s'\'':\n        ref: v7.0.1\n        commit: sha1-%s\n        owner_id: 44036562\n        repo_id: 197814629\n' \
    "${bad%@*}" "$sha" "$sha" > "$tmp/lock.yml"
  assert "malformed key '$bad' is rejected" 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"
done

# ── key immutability, provenance, closure ────────────────────────────────
printf 'version: v0.0.3\ndependencies:\n    '\''actions/setup-python@v2'\'':\n        ref: v2\n        commit: sha1-%s\n        owner_id: 44036562\n        repo_id: 192625525\n' "$sha" > "$tmp/lock.yml"
assert 'a tag-keyed record (moving target) is rejected' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

printf 'version: v0.0.3\ndependencies:\n    '\''actions/checkout@%s'\'':\n        ref: v7.0.1\n        commit: sha1-%s\n' "$sha" "$sha" > "$tmp/lock.yml"
assert 'a record with no owner_id/repo_id provenance is rejected' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# One HALF of the provenance missing, in each direction. These are the cases a
# tab-separated row could not report: `read` treats a tab as IFS whitespace, so
# `owner_id<TAB><TAB>yes` collapsed and the surviving field borrowed the next
# column, leaving both ids non-empty and the record "conforming".
printf 'version: v0.0.3\ndependencies:\n    '\''actions/checkout@%s'\'':\n        ref: v7.0.1\n        commit: sha1-%s\n        owner_id: 44036562\n' "$sha" "$sha" > "$tmp/lock.yml"
assert 'a record with repo_id absent (owner_id present) is rejected' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"
printf 'version: v0.0.3\ndependencies:\n    '\''actions/checkout@%s'\'':\n        ref: v7.0.1\n        commit: sha1-%s\n        repo_id: 197814629\n' "$sha" "$sha" > "$tmp/lock.yml"
assert 'a record with owner_id absent (repo_id present) is rejected' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# A workflows: entry naming a ref with no top-level record: the startup-fatal
# dangling edge of close-lock.sh/cicd-squabbler#101. The representation is
# valid record-by-record; only closure catches it.
printf 'version: v0.0.3\nworkflows:\n    '\''.github/workflows/a.yml'\'':\n        - '\''actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9'\''\n        - '\''actions/checkout@%s'\''\ndependencies:\n    '\''actions/checkout@%s'\'':\n        ref: v7.0.1\n        commit: sha1-%s\n        owner_id: 44036562\n        repo_id: 197814629\n' "$sha" "$sha" "$sha" > "$tmp/lock.yml"
assert 'a dangling closure edge is rejected even with valid records' 1 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# ── not-inspected states are exit 2, never 0 or 1 ────────────────────────
leaf v99.0.0 'v7.0.1' "\"sha1-$sha\""
assert 'untested lock schema is UNINSPECTED' 2 "$tmp/lock.yml" --self-repo "$SELF_REPO"

printf 'version: v0.0.3\ndependencies: {}\n' > "$tmp/lock.yml"
assert 'empty population is not a pass' 2 "$tmp/lock.yml" --self-repo "$SELF_REPO"

printf 'version: v0.0.3\ndependencies: []\n' > "$tmp/lock.yml"
assert 'non-mapping dependencies is UNINSPECTED' 2 "$tmp/lock.yml" --self-repo "$SELF_REPO"

printf 'version: v0.0.3\ndependencies: [\n' > "$tmp/lock.yml"
assert 'malformed YAML is UNINSPECTED' 2 "$tmp/lock.yml" --self-repo "$SELF_REPO"

rm -f "$tmp/lock.yml"
assert 'a missing lock is not a pass' 2 "$tmp/lock.yml" --self-repo "$SELF_REPO"

# A PATH without yq must be exit 2: a guard that cannot read YAML has no
# verdict, and "no verdict" must never render as clean.
leaf v0.0.3 'v7.0.1' "\"sha1-$sha\""
rc=0
mkdir -p "$tmp/noyq"
for tool in jq git bash dirname tr grep sed awk mktemp head printf; do
  p="$(command -v "$tool" 2>/dev/null)" && ln -sf "$p" "$tmp/noyq/$tool"
done
out="$(env PATH="$tmp/noyq" /bin/bash "$GUARD" "$tmp/lock.yml" --self-repo "$SELF_REPO" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && ok 'a PATH without yq exits 2' || { printf '%s\n' "$out" | sed 's/^/    /'; bad "no-yq PATH gave exit $rc, wanted 2"; }

# ── positive control: this repository's own lock ─────────────────────────
rc=0
out="$(cd "$ROOT" && bash "$GUARD" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "this repository's own actions.lock satisfies the contract"
else
  printf '%s\n' "$out" | sed 's/^/    /'
  bad "the repository's own actions.lock does not satisfy the contract (exit $rc)"
fi

echo
echo "check-lock-pin-contract: passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
