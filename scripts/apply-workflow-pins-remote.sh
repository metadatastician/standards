#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# apply-workflow-pins-remote.sh — the scheduled APPLIER for standards
#   reusable-workflow pins across the whole estate.
#
# WHY THIS EXISTS, and why it is not `propagate-workflow-pins.sh`:
#
#   `scripts/propagate-workflow-pins.sh` already holds the proven rewrite core,
#   but it walks LOCAL CHECKOUTS and deliberately never commits. That makes it a
#   human-driven, one-repo-at-a-time tool. A cure landed in `standards` therefore
#   does NOT propagate: measured 2026-09-15, 28 of 29 live remote callers are
#   SHA-pinned and exactly one (`affinescript`) tracks `@main`. A pinned caller
#   never sees a fix until something re-points its pin.
#
#   This script is that something. It is an APPLIER, not a sweep (owner ruling
#   STD-R-3): it runs on a cadence, re-points pins, and is expected to run again.
#   A sweep is a one-shot mass mutation; an applier converges.
#
# WHAT A PIN CAN BE (four classes, not one — this is the hard-won part):
#   FRESH      pinned at the target SHA. Nothing to do.
#   BEHIND     pinned at some other real standards commit. Re-point.
#   DEAD-REF   pinned at a SHA that is NOT a commit in standards at all. These
#              exist (e.g. `awesome-idris2`). Cause: a squash-merge made the
#              intermediate commit unaddressable as a cross-repo workflow ref.
#              The workflow fails with `failure`, 0 jobs, and name == path — the
#              same signature as three other faults, so the signature alone
#              never proves the cause.
#   ILLEGAL    `uses: ../../...` or `uses: $/...`. Rejected at PARSE time, so the
#              run dies before any job starts. Seeded into repos by RSR templates
#              (issue #808). Repaired only under --repair-illegal.
#   MOVED      a SHA pin still under the former owner (`hyperpolymath/standards/…`).
#              GitHub does not follow the transfer for `jobs.<id>.uses`, so the
#              run dies at plan time ("workflow was not found") even when the SHA
#              is FRESH. Rewritten to the canonical owner with the same relock.
#              Combines with FRESH or BEHIND; a repo moves all its pins at once.
#   TRACKING   `@main` or another non-SHA ref. Gets cures for free; also
#              unpinned, which the estate's own policy forbids. Reported, not
#              rewritten, because re-pointing it is a policy change, not a fix.
#
# SAFETY PROPERTIES (do not weaken any of these):
#   * READ-ONLY by default. --fix is required to write anything.
#   * The target SHA is proven REACHABLE FROM standards' main before any write.
#     Mere existence is NOT enough: on 2026-09-04 a squash-merged intermediate
#     commit was addressable through the contents API but unusable as a
#     cross-repo reusable-workflow ref, and pinning to it broke 251 active
#     workflow files across 70 repos.
#   * KNOWN-ANSWER CONTROLS run every time. If a control misclassifies, the run
#     ABORTS before writing. A census with no control is a census you cannot
#     distinguish from a broken one.
#   * Commits are made with createCommitOnBranch so they are GitHub-"Verified".
#     Measured 2026-09-15: required_signatures is the dominant campaign blocker
#     (6 of 9 campaign heads unsigned). An unsigned applier opens PRs that can
#     never merge, which is worse than opening none.
#   * Shell-only: no Python, no Ruby.
#   * THE LOCK FOLLOWS THE PINS. A repo's actions.lock is fetched with its
#     workflows and re-keyed by scripts/relock-standards-pin.sh in the same
#     commit; a lock that cannot follow (fail-closed refusal) means the repo is
#     reported LOCK-REFUSED and not landed. Pins without their lock stop the
#     workflows at startup, which is worse than leaving them behind.
#
# Usage:
#   bash scripts/apply-workflow-pins-remote.sh [options]
#     --fix               open PRs (default: audit only, writes nothing)
#     --repair-illegal    also rewrite ILLEGAL `../` refs (implies more risk)
#     --to <sha>          target SHA (default: resolved from standards main)
#     --owners <a,b>      owners to walk (default: hyperpolymath,metadatastician,catachresis-colloquium)
#     --only <repo>       restrict to one repo (for testing)
#     --out <file>        write the TSV census here (default: stdout)
#     --limit <n>         stop after n repos (for smoke runs). In --fix mode n
#                         counts repos the run tries to LAND a PR in, not repos
#                         walked: a canary of 5 that walks 5 already-FRESH repos
#                         and opens nothing tests nothing.
#     --ensure-squabbler  also add the CICD Squabbler gate (a thin caller of
#                         standards' cicd-squabbler-reusable.yml at the target)
#                         where a repo has none, in the SAME PR as the re-pin
#     --proven-sha <sha>  also report stamped proven-cicd content (see below)
#                         against proven/manifest.json of
#                         hyperpolymath/proven-cicd-and-workflows at this
#                         40-hex commit. READ-ONLY in every mode.
#     --self-test         run the pure-function controls and exit
#
# PROVEN CONTENT (--proven-sha; census only, never rewritten here):
#   proven-cicd-and-workflows publishes stamped workflow bodies. A stamped copy's
#   first line is `# proven-cicd: <artifact>@<MAJOR.MINOR.PATCH> sha256:<hex>`.
#   The copy itself detects edits (drift); only a sweep against the published
#   manifest can see that a copy is STALE. Each stamped file gets its own census
#   row, with a status of its own, never joined to the pin status column:
#     BEHIND-CONTENT     stamp version older than the manifest's
#     CONTENT-CURRENT    stamp version equal to the manifest's
#     CONTENT-AHEAD      stamp version newer than the manifest at --proven-sha
#     CONTENT-UNLISTED   the manifest does not list the artifact
#     CONTENT-MALFORMED  a `# proven-cicd:` first line that is not a valid stamp
#   An unreadable or invalid manifest at --proven-sha degrades loudly: the pin
#   census still runs, one CONTENT-CENSUS-FAILED row replaces the content rows,
#   and the run exits 1 at the end. A content census with no manifest is not
#   evidence, and an outage at proven-cicd must not blind the pin census.
#   Rewriting a stale copy is a separate mode, not built here.
#   A stamped copy detects edits to its hashed body by sha256. proven-cicd's
#   stamped bodies carry no standards reusable pins in that region; if one ever
#   did, a --fix re-pin here would trip the copy's own drift check, so the
#   rewrite mode must skip stamped files and report them with a status of its own.
#
# ENSURE-SQUABBLER (why it rides with the re-pin, never ahead of it):
#   The squabbler's `chains` job FAILS on a dead upstream. Added to a repo that
#   still calls a dead standards pin (a bad-lock SHA, or the former owner), it
#   would add one more red check to every such repo. So it is added only when,
#   after this run's rewrite, every standards pin in the repo is at the target:
#   a repo with a TRACKING ref, or an ILLEGAL ref this run will not repair, is
#   reported SQUABBLER-DEFERRED and left without it. Forks are third-party code
#   and are never given one (SQUABBLER-FORK). A repo that already has a
#   squabbler workflow is SQUABBLER-PRESENT. The new file is relocked with the
#   pins (relock-standards-pin.sh adds its lock entry), so it lands whole or
#   not at all.

set -uo pipefail

# The shared ancestry assertion (D5c): every pin bumper calls the same one.
# shellcheck source-path=SCRIPTDIR source=lib/pin-ancestry.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/pin-ancestry.sh"

# The canonical owner since the transfer (standards#1390). Pins under the
# former owner never resolve as `jobs.<id>.uses`, so the applier moves them.
STANDARDS_REPO="metadatastician/standards"
FORMER_OWNER="hyperpolymath"
TARGET_SHA="${STANDARDS_TARGET_SHA:-}"
DO_FIX=0
REPAIR_ILLEGAL=0
OWNERS="hyperpolymath,metadatastician,catachresis-colloquium"
ONLY_REPO=""
OUT_FILE=""
LIMIT=0
ENSURE_SQUABBLER=0
SQUABBLER_FILE="cicd-squabbler.yml"
BRANCH_NAME="chore/re-point-standards-workflow-pins"
# The standards checkout this script runs from: the relock reads reusables and
# standards' own actions.lock AT THE TARGET from it.
STANDARDS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOCK="$(dirname "${BASH_SOURCE[0]}")/relock-standards-pin.sh"
# Proven content (--proven-sha). Empty PROVEN_SHA means the content census is off.
PROVEN_REPO="hyperpolymath/proven-cicd-and-workflows"
PROVEN_SHA=""
PROVEN_MANIFEST=""

log() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# PURE CORE — no network, no filesystem outside the file argument.
# Everything below this banner is unit-testable offline, and tests/ does so.
# ---------------------------------------------------------------------------

# A standards reusable-workflow reference, pinned to a hex SHA.
PIN_RE='(hyperpolymath|metadatastician)/standards/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml@[0-9a-fA-F]{7,40}'
# The same reference pinned to anything at all (SHA, branch, tag).
ANYREF_RE='(hyperpolymath|metadatastician)/standards/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml@[A-Za-z0-9._/-]+'
# A `uses:` that can never parse: relative, or the `$/` form that
# `gh actions-lock` once invented. Both are rejected before any job starts.
ILLEGAL_RE='^[[:space:]]*uses:[[:space:]]*['"'"'"]?(\.\.?/|\$/)'

# Echo every standards pin SHA found in $1, one per line.
pin_shas() {
  grep -hoE "$PIN_RE" "$1" 2>/dev/null | sed -E 's/.*@([0-9a-fA-F]+)$/\1/'
}

# Echo every standards ref that is NOT a hex SHA (branch/tag tracking).
tracking_refs() {
  grep -hoE "$ANYREF_RE" "$1" 2>/dev/null \
    | sed -E 's/.*@(.+)$/\1/' \
    | grep -vE '^[0-9a-fA-F]{7,40}$' || true
}

# Echo every illegal `uses:` line in $1 (line-number prefixed).
illegal_uses() {
  grep -nE "$ILLEGAL_RE" "$1" 2>/dev/null || true
}

# classify_file <file> <target_sha>
# Echoes ONE token per distinct condition found, newline separated, from:
#   ILLEGAL TRACKING BEHIND FRESH MOVED NONE
# A file can be several at once (e.g. BEHIND and ILLEGAL); every applicable
# token is emitted. NONE means the file references standards not at all.
#
# NOTE: DEAD-REF is deliberately NOT decided here. Distinguishing a real-but-old
# commit from one that does not exist requires the network, and keeping this
# function pure is what makes it testable. refine_behind() upgrades it later.
classify_file() {
  local f="$1" target="$2" emitted=0

  if [ -n "$(illegal_uses "$f")" ]; then
    echo ILLEGAL; emitted=1
  fi
  if [ -n "$(tracking_refs "$f")" ]; then
    echo TRACKING; emitted=1
  fi

  local sha behind=0 fresh=0
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # A short pin is compared on its own length: `@abc1234` and the 40-char
    # target are the same commit when the short form is a prefix. Treating a
    # legitimate short pin as BEHIND would rewrite it every single run and the
    # applier would never converge.
    if [ "${target:0:${#sha}}" = "$sha" ]; then fresh=1; else behind=1; fi
  done < <(pin_shas "$f")

  [ "$behind" -eq 1 ] && { echo BEHIND; emitted=1; }
  [ "$fresh"  -eq 1 ] && { echo FRESH;  emitted=1; }
  # A SHA pin still under the former owner never resolves as a job-level
  # `uses:` ("workflow was not found"), even at the target SHA, so it needs a
  # rewrite on its own. Tracking refs are reported, not moved (see TRACKING).
  if grep -qE "${FORMER_OWNER}/standards/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml@[0-9a-fA-F]{7,40}" "$f" 2>/dev/null; then
    echo MOVED; emitted=1
  fi
  [ "$emitted" -eq 0 ] && echo NONE
  return 0
}

# --- proven content (pure) ----------------------------------------------------

# A valid stamp line, as proven-cicd-and-workflows scripts/proven-stamp.sh writes it.
# Each version component is bounded to nine digits: version_cmp compares them
# as shell integers, which wrap at 2^63, so an unbounded component could make a
# copy far ahead (or a stale copy against such a manifest) read CURRENT.
STAMP_RE='^# proven-cicd: ([a-z0-9][a-z0-9-]*)@([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9}) sha256:[0-9a-f]{64}$'

# version_cmp <a> <b> — echo lt, eq or gt, comparing MAJOR.MINOR.PATCH as
# numbers. A lexical compare reads 0.10.0 as older than 0.9.0.
version_cmp() {
  local a="$1" b="$2" i x y
  local -a av bv
  IFS=. read -r -a av <<< "$a"
  IFS=. read -r -a bv <<< "$b"
  for i in 0 1 2; do
    x=$((10#${av[$i]})); y=$((10#${bv[$i]}))
    if [ "$x" -lt "$y" ]; then echo lt; return 0; fi
    if [ "$x" -gt "$y" ]; then echo gt; return 0; fi
  done
  echo eq
}

# manifest_tsv <manifest.json> — validate a proven-cicd/manifest/v1 document
# and echo `artifact<TAB>version` per artifact. Non-zero, and nothing on
# stdout, when the document is not a valid manifest: the caller fails closed.
manifest_tsv() {
  jq -er '
    if .schema == "proven-cicd/manifest/v1"
       and (.artifacts | type == "array" and length > 0)
       and all(.artifacts[]; (.artifact | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
                             and (.version | type == "string" and test("^[0-9]{1,9}\\.[0-9]{1,9}\\.[0-9]{1,9}$")))
       and ([.artifacts[].artifact] | length == (unique | length))
    then .artifacts[] | "\(.artifact)\t\(.version)"
    else error("not a valid proven-cicd/manifest/v1") end' "$1" 2>/dev/null
}

# content_state <file> <manifest-tsv-file> — for a stamped file, echo ONE line
# `STATUS<TAB>DETAIL`; for a file with no `# proven-cicd:` first line, echo
# nothing. Statuses are listed under PROVEN CONTENT in the header.
content_state() {
  local f="$1" m="$2" first artifact have want
  first=$(head -n 1 "$f" 2>/dev/null) || return 0
  case "$first" in "# proven-cicd:"*) ;; *) return 0 ;; esac
  if ! [[ $first =~ $STAMP_RE ]]; then
    printf 'CONTENT-MALFORMED\t-\n'; return 0
  fi
  artifact="${BASH_REMATCH[1]}"
  have="${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
  want=$(awk -F'\t' -v a="$artifact" '$1 == a { print $2; exit }' "$m")
  if [ -z "$want" ]; then
    printf 'CONTENT-UNLISTED\t%s@%s\n' "$artifact" "$have"; return 0
  fi
  case "$(version_cmp "$have" "$want")" in
    lt) printf 'BEHIND-CONTENT\t%s@%s -> %s\n' "$artifact" "$have" "$want" ;;
    eq) printf 'CONTENT-CURRENT\t%s@%s\n' "$artifact" "$have" ;;
    gt) printf 'CONTENT-AHEAD\t%s@%s > %s\n' "$artifact" "$have" "$want" ;;
    # Unreachable while version_cmp answers lt, eq or gt; fail loud if it ever does not.
    *)  printf 'CONTENT-MALFORMED\t-\n' ;;
  esac
}

# needs_rewrite <classification> — true when fix mode must re-point the file's
# pins: some pin is BEHIND the target, or still under the former owner (MOVED).
needs_rewrite() {
  case ",$1," in *,BEHIND,*|*,MOVED,*) return 0 ;; esac
  return 1
}

# rewrite_pins <file> <target_sha> — re-point every standards SHA pin, in place,
# under the canonical owner. Only a standards reusable path and the SHA after
# its `@` are touched. Idempotent.
rewrite_pins() {
  local f="$1" target="$2"
  sed -E -i "s#(hyperpolymath|metadatastician)/standards/(\.github/workflows/[A-Za-z0-9._-]+\.ya?ml@)[0-9a-fA-F]{7,40}#${STANDARDS_REPO}/\2${target}#g" "$f"
}

# rewrite_illegal <file> <target_sha> — turn an unparseable relative ref into a
# legal cross-repo pin. `../../.github/workflows/X.yml` was always MEANT to be
# the standards copy: RSR templates seeded it, and a relative `uses:` to a
# reusable workflow has no legal meaning in GitHub Actions at all (only
# `./.github/workflows/x.yml` and `owner/repo/...@ref` parse).
rewrite_illegal() {
  local f="$1" target="$2"
  sed -E -i \
    "s#(uses:[[:space:]]*)['\"]?(\.\./)+\.github/workflows/([A-Za-z0-9._-]+\.ya?ml)['\"]?#\1${STANDARDS_REPO}/.github/workflows/\3@${target}#g" \
    "$f"
  sed -E -i \
    "s#(uses:[[:space:]]*)['\"]?\\\$/\.github/workflows/([A-Za-z0-9._-]+\.ya?ml)['\"]?#\1${STANDARDS_REPO}/.github/workflows/\2@${target}#g" \
    "$f"
}

# squabbler_state <dir> <target_sha> <repair_illegal 0|1>, PRESENT, MISSING,
# or DEFERRED:<class,...>. Pure: reads the workflow files in <dir> only. Read
# after this run's rewrite, BEHIND and MOVED are gone; in audit mode they are
# still there but the same fix run would clear them, so they do not defer.
squabbler_state() {
  local dir="$1" t="$2" repair="$3" f cls blockers=""
  shopt -s nullglob
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    # PRESENT only when a non-comment line runs the gate: a `uses:` of
    # cicd-squabbler (reusable or action), `squabble chains`, or the template's
    # local action (.github/actions/squabble/). A file name or a comment that
    # mentions the squabbler is not a gate.
    # Inline comments are stripped first, and `squabble chains` or the local
    # action count only in command position (start of a run: value or after
    # ; && ||), so `echo "squabble chains"` is not a gate either.
    if grep -vE '^[[:space:]]*#' "$f" | sed -E 's/[[:space:]]+#.*$//' \
         | grep -qiE "^[[:space:]]*(-[[:space:]]+)?[\"']?uses[\"']?[[:space:]]*:[[:space:]]*[\"']?([^[:space:]]*cicd-squabbler|\./\.github/actions/squabble)|(^[[:space:]]*(-[[:space:]]+)?(run[[:space:]]*:[[:space:]]*)?|[;&|][[:space:]]*)(bash[[:space:]]+|sh[[:space:]]+)?(\./)?(squabble[[:space:]]+chains|\.github/actions/squabble/)"; then
      shopt -u nullglob; echo PRESENT; return 0
    fi
    for cls in $(classify_file "$f" "$t"); do
      case "$cls" in
        TRACKING) blockers="${blockers},TRACKING" ;;
        ILLEGAL) [ "$repair" -eq 1 ] || blockers="${blockers},ILLEGAL" ;;
      esac
    done
  done
  shopt -u nullglob
  if [ -n "$blockers" ]; then
    echo "DEFERRED:$(printf '%s' "${blockers#,}" | tr ',' '\n' | sort -u | paste -sd, -)"
  else
    echo MISSING
  fi
}

# write_squabbler_caller <file> <target_sha>, the estate caller of the CICD
# Squabbler gate, pinned like every other standards reusable. Mirrors
# standards' own cicd-squabbler.yml (grants, the one optional credential,
# never `secrets: inherit`) minus its weekly schedule: hundreds of callers on
# one cron would all start in the same minute.
write_squabbler_caller() {
  cat > "$1" <<EOF
# SPDX-License-Identifier: MPL-2.0
# CICD Squabbler gate (doctrine 5: squabble, don't bypass). Added by the
# standards pin applier (scripts/apply-workflow-pins-remote.sh
# --ensure-squabbler); the applier keeps this pin current. \`chains\` blocks a
# dependency cycle or a dead upstream; \`fight\` reports and runs only with
# the optional Administration-read credential.
name: CICD Squabbler

on:
  pull_request:
  push:
    branches: [main, master]
  workflow_dispatch:

concurrency:
  group: \${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  squabble:
    permissions:
      contents: read
      pull-requests: read
      attestations: read
    uses: ${STANDARDS_REPO}/.github/workflows/cicd-squabbler-reusable.yml@$2
    with:
      pr-number: \${{ github.event.pull_request.number && format('{0}', github.event.pull_request.number) || '' }}
    secrets:
      ADMINISTRATION_READ_TOKEN: \${{ secrets.HYPATIA_SCAN_PAT }}
EOF
}

# ---------------------------------------------------------------------------
# SELF-TEST of the pure core. Runs offline. `--self-test` exits after this.
# These are the KNOWN-ANSWER CONTROLS: if any fails, every census this script
# could produce is untrustworthy, so it refuses to produce one.
# ---------------------------------------------------------------------------
self_test() {
  local d rc=0 t="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  d=$(mktemp -d)

  printf 'jobs:\n  a:\n    uses: metadatastician/standards/.github/workflows/x.yml@%s\n' "$t" > "$d/fresh.yml"
  printf 'jobs:\n  a:\n    uses: metadatastician/standards/.github/workflows/x.yml@%s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$d/behind.yml"
  printf 'jobs:\n  a:\n    uses: ../../.github/workflows/x.yml\n' > "$d/illegal.yml"
  printf 'jobs:\n  a:\n    uses: metadatastician/standards/.github/workflows/x.yml@main\n' > "$d/tracking.yml"
  printf 'jobs:\n  a:\n    runs-on: ubuntu-latest\n' > "$d/none.yml"
  printf 'jobs:\n  a:\n    uses: metadatastician/standards/.github/workflows/x.yml@%s\n' "${t:0:7}" > "$d/short.yml"
  # Former-owner pins: dead as job-level `uses:` even at the target SHA.
  printf 'jobs:\n  a:\n    uses: hyperpolymath/standards/.github/workflows/x.yml@%s\n' "$t" > "$d/moved-fresh.yml"
  printf 'jobs:\n  a:\n    uses: hyperpolymath/standards/.github/workflows/x.yml@%s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$d/moved-behind.yml"
  printf 'jobs:\n  a:\n    uses: hyperpolymath/standards/.github/workflows/x.yml@main\n' > "$d/moved-tracking.yml"
  # An unrelated repository that merely ends in /standards is not a standards pin.
  printf 'jobs:\n  a:\n    uses: someone/standards/.github/workflows/x.yml@%s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$d/other-owner.yml"

  check() {
    local file="$1" want="$2" got
    got=$(classify_file "$d/$file" "$t" | sort | tr '\n' ',' )
    if [ "$got" = "$want" ]; then
      echo "  PASS $file -> $got"
    else
      echo "  FAIL $file -> got '$got' want '$want'" >&2; rc=1
    fi
  }
  echo "control: classify_file"
  check fresh.yml    "FRESH,"
  check behind.yml   "BEHIND,"
  check illegal.yml  "ILLEGAL,"
  check tracking.yml "TRACKING,"
  check none.yml     "NONE,"
  # A short pin that PREFIXES the target is FRESH, not BEHIND. Without this the
  # applier rewrites the same file every run and never converges.
  check short.yml    "FRESH,"
  # A former-owner pin needs a rewrite even when its SHA is the target.
  check moved-fresh.yml    "FRESH,MOVED,"
  check moved-behind.yml   "BEHIND,MOVED,"
  # Tracking refs are reported, never rewritten, under either owner.
  check moved-tracking.yml "TRACKING,"
  check other-owner.yml    "NONE,"

  echo "control: needs_rewrite decides fix mode"
  local cls want_rw got_rw ok_rw=1
  for cls in "FRESH:no" "BEHIND:yes" "FRESH,MOVED:yes" "BEHIND,MOVED:yes" \
             "TRACKING:no" "ILLEGAL:no" "NONE:no" "BEHIND,DEAD-REF:yes"; do
    want_rw="${cls##*:}"; cls="${cls%:*}"
    if needs_rewrite "$cls"; then got_rw=yes; else got_rw=no; fi
    [ "$got_rw" = "$want_rw" ] || { echo "  FAIL needs_rewrite '$cls' -> $got_rw, want $want_rw" >&2; ok_rw=0; rc=1; }
  done
  [ "$ok_rw" -eq 1 ] && echo "  PASS rewrite for BEHIND or MOVED only"

  echo "control: rewrite_pins moves the owner and is then FRESH"
  rewrite_pins "$d/moved-fresh.yml" "$t"
  rewrite_pins "$d/moved-behind.yml" "$t"
  if grep -q "uses: metadatastician/standards/.github/workflows/x.yml@$t" "$d/moved-fresh.yml" \
     && grep -q "uses: metadatastician/standards/.github/workflows/x.yml@$t" "$d/moved-behind.yml" \
     && ! grep -q "hyperpolymath/" "$d/moved-fresh.yml" "$d/moved-behind.yml" \
     && [ "$(classify_file "$d/moved-behind.yml" "$t" | sort | tr '\n' ',')" = "FRESH," ]; then
    echo "  PASS former-owner pins moved to the canonical owner at the target"
  else
    echo "  FAIL owner move: $(cat "$d/moved-fresh.yml" "$d/moved-behind.yml")" >&2; rc=1
  fi

  echo "control: rewrite_pins is idempotent"
  rewrite_pins "$d/behind.yml" "$t"
  local after1 after2
  after1=$(cat "$d/behind.yml")
  rewrite_pins "$d/behind.yml" "$t"
  after2=$(cat "$d/behind.yml")
  if [ "$after1" = "$after2" ] && grep -q "@$t" "$d/behind.yml"; then
    echo "  PASS rewrite is idempotent and hit the target"
  else
    echo "  FAIL rewrite not idempotent" >&2; rc=1
  fi

  # A rewrite anchored on the SHA rather than on the standards reusable PATH
  # silently re-points every THIRD-PARTY action pin in the file as well. Nothing
  # else in this suite would notice: such a rewrite is still idempotent and the
  # file still contains the target SHA, so both other controls stay green.
  echo "control: rewrite_pins does not touch third-party pins"
  {
    echo 'jobs:'
    echo '  a:'
    echo '    steps:'
    echo '      - uses: actions/checkout@cccccccccccccccccccccccccccccccccccccccc'
    echo '    uses: hyperpolymath/standards/.github/workflows/x.yml@dddddddddddddddddddddddddddddddddddddddd'
  } > "$d/mixed.yml"
  rewrite_pins "$d/mixed.yml" "$t"
  if grep -q 'actions/checkout@cccccccccccccccccccccccccccccccccccccccc' "$d/mixed.yml" \
     && grep -q "standards/.github/workflows/x.yml@$t" "$d/mixed.yml"; then
    echo "  PASS third-party pin untouched, standards pin re-pointed"
  else
    echo "  FAIL rewrite overreached onto a third-party pin:" >&2
    sed 's/^/      /' "$d/mixed.yml" >&2; rc=1
  fi

  # The mutation input must be an OBJECT: a JSON-encoded string is rejected by
  # GitHub, and that defect made every --fix run fail until 2026-10-02.
  echo "control: commit_payload sends input as an object"
  local payload
  payload=$(commit_payload "o/r" "$t" 'head "q"' $'line1\nline2' "$d" fresh.yml)
  if printf '%s' "$payload" | jq -e --arg t "$t" '
       (.variables.input | type == "object")
       and .variables.input.expectedHeadOid == $t
       and .variables.input.message.headline == "head \"q\""
       and .variables.input.message.body == "line1\nline2"
       and (.variables.input.fileChanges.additions
            | length == 1 and .[0].path == ".github/workflows/fresh.yml")' >/dev/null \
     && [ "$(printf '%s' "$payload" | jq -r '.variables.input.fileChanges.additions[0].contents' | base64 -d)" = "$(cat "$d/fresh.yml")" ]; then
    echo "  PASS payload is an object with exact headline, body and contents"
  else
    echo "  FAIL commit_payload produced: $payload" >&2; rc=1
  fi

  echo "control: rewrite_illegal produces a LEGAL ref"
  rewrite_illegal "$d/illegal.yml" "$t"
  if grep -qE "uses: $PIN_RE" "$d/illegal.yml" && ! grep -qE "$ILLEGAL_RE" "$d/illegal.yml"; then
    echo "  PASS illegal ref became a legal pin"
  else
    echo "  FAIL illegal repair did not yield a legal pin: $(cat "$d/illegal.yml")" >&2; rc=1
  fi

  # The relock is what keeps a fix-mode PR from desyncing actions.lock; a
  # missing relock must stop the run, not silently land pins without locks.
  # Its own known-answer suite is scripts/tests/relock-standards-pin-test.sh.
  echo "control: squabbler_state and write_squabbler_caller"
  local sq ok_sq=1; mkdir -p "$d/sq"
  cp "$d/fresh.yml" "$d/sq/"; cp "$d/behind.yml" "$d/sq/"; cp "$d/moved-fresh.yml" "$d/sq/"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = MISSING ] || { echo "  FAIL BEHIND/MOVED must not defer (one run clears them)" >&2; ok_sq=0; }
  cp "$d/tracking.yml" "$d/sq/"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = "DEFERRED:TRACKING" ] || { echo "  FAIL a TRACKING ref must defer" >&2; ok_sq=0; }
  rm "$d/sq/tracking.yml"; printf 'jobs:\n  a:\n    uses: ../../.github/workflows/x.yml\n' > "$d/sq/ill.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = "DEFERRED:ILLEGAL" ] || { echo "  FAIL an unrepaired ILLEGAL ref must defer" >&2; ok_sq=0; }
  [ "$(squabbler_state "$d/sq" "$t" 1)" = MISSING ] || { echo "  FAIL an ILLEGAL ref this run repairs must not defer" >&2; ok_sq=0; }
  rm "$d/sq/ill.yml"; printf 'name: x\njobs:\n  a:\n    steps:\n      - run: squabble chains .\n' > "$d/sq/gate.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = PRESENT ] || { echo "  FAIL an existing squabble workflow must count as PRESENT" >&2; ok_sq=0; }
  rm "$d/sq/gate.yml"; printf 'on: push\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = MISSING ] || { echo "  FAIL a squabble*.yml file that runs no gate must not count as PRESENT" >&2; ok_sq=0; }
  printf '# see cicd-squabbler and squabble chains\non: push\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = MISSING ] || { echo "  FAIL a comment naming the squabbler must not count as PRESENT" >&2; ok_sq=0; }
  printf 'jobs:\n  s:\n    steps:\n      - run: bash .github/actions/squabble/run.sh\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = PRESENT ] || { echo "  FAIL the template local squabble action must count as PRESENT" >&2; ok_sq=0; }
  printf 'jobs:\n  s:\n    steps:\n      - run: echo "squabble chains ."\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = MISSING ] || { echo "  FAIL squabble chains inside an echo argument must not count as PRESENT" >&2; ok_sq=0; }
  printf 'jobs:\n  s:\n    steps:\n      - run: echo ready # squabble chains\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = MISSING ] || { echo "  FAIL squabble chains in an inline comment must not count as PRESENT" >&2; ok_sq=0; }
  printf 'jobs:\n  s:\n    steps:\n      - run: |\n          squabble chains . --follow 1\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = PRESENT ] || { echo "  FAIL squabble chains run in a block must count as PRESENT" >&2; ok_sq=0; }
  printf 'jobs:\n  s:\n    uses: hyperpolymath/cicd-squabbler/.github/workflows/x.yml@abc\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = PRESENT ] || { echo "  FAIL a uses: of cicd-squabbler must count as PRESENT" >&2; ok_sq=0; }
  printf 'jobs:\n  s:\n    uses : hyperpolymath/cicd-squabbler/.github/workflows/x.yml@abc\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = PRESENT ] || { echo "  FAIL a uses with whitespace before the colon must count as PRESENT" >&2; ok_sq=0; }
  printf 'jobs:\n  s:\n    steps:\n      - run : squabble chains .\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = PRESENT ] || { echo "  FAIL a run with whitespace before the colon must count as PRESENT" >&2; ok_sq=0; }
  printf 'jobs:\n  s:\n    steps:\n      - run: echo "uses : org/cicd-squabbler@main"\n' > "$d/sq/squabble.yml"
  [ "$(squabbler_state "$d/sq" "$t" 0)" = MISSING ] || { echo "  FAIL an echoed uses : line inside a run: value must not count as PRESENT" >&2; ok_sq=0; }
  rm "$d/sq/squabble.yml"
  write_squabbler_caller "$d/sqc.yml" "$t"
  sq=$(classify_file "$d/sqc.yml" "$t" | sort | tr '\n' ',')
  if [ "$sq" != "FRESH," ] \
     || ! grep -qE "^    uses: ${STANDARDS_REPO}/\.github/workflows/cicd-squabbler-reusable\.yml@$t\$" "$d/sqc.yml" \
     || grep -q 'secrets: inherit' "$d/sqc.yml" || grep -q 'schedule:' "$d/sqc.yml" \
     || ! grep -qF '${{ secrets.HYPATIA_SCAN_PAT }}' "$d/sqc.yml"; then
    echo "  FAIL the squabbler caller is not a FRESH canonical pin with only the named credential:" >&2
    sed 's/^/      /' "$d/sqc.yml" >&2; ok_sq=0
  fi
  [ "$ok_sq" -eq 1 ] && echo "  PASS state is PRESENT/MISSING/DEFERRED as specified; caller is FRESH, canonical, no inherit, no cron" || rc=1

  # Proven content: the manifest is validated, and each stamped copy gets the
  # one status its version earns. 0.10.0 against 0.9.0 catches a lexical compare.
  echo "control: proven content"
  local h; h=$(printf 'c%.0s' $(seq 64))
  cat > "$d/manifest.json" <<'JSON'
{"schema":"proven-cicd/manifest/v1","artifacts":[
 {"artifact":"proven-lock-gate","version":"0.1.0","sha256":"x","template":"t","install_path":"p"},
 {"artifact":"wide-gate","version":"0.10.0","sha256":"x","template":"t","install_path":"p"}]}
JSON
  if manifest_tsv "$d/manifest.json" > "$d/manifest.tsv" \
     && [ "$(cat "$d/manifest.tsv")" = "$(printf 'proven-lock-gate\t0.1.0\nwide-gate\t0.10.0')" ]; then
    echo "  PASS manifest.json -> 2 artifacts"
  else
    echo "  FAIL manifest.json was not read as 2 artifacts" >&2; rc=1
  fi
  printf '{"schema":"proven-cicd/manifest/v2","artifacts":[{"artifact":"a","version":"1.0.0"}]}' > "$d/bad-schema.json"
  printf '{"schema":"proven-cicd/manifest/v1","artifacts":[{"artifact":"a","version":"1.0"}]}' > "$d/bad-version.json"
  printf '{"schema":"proven-cicd/manifest/v1","artifacts":[{"artifact":"a","version":"1.0.0"},{"artifact":"a","version":"1.0.1"}]}' > "$d/bad-dup.json"
  printf '{"schema":"proven-cicd/manifest/v1","artifacts":[]}' > "$d/bad-empty.json"
  printf 'not json' > "$d/bad-json.json"
  # 2^64 + 1: a shell integer wraps to 1, so an unbounded component compares equal.
  printf '{"schema":"proven-cicd/manifest/v1","artifacts":[{"artifact":"a","version":"18446744073709551617.0.0"}]}' > "$d/bad-huge.json"
  local bad
  for bad in bad-schema bad-version bad-dup bad-empty bad-json bad-huge; do
    if manifest_tsv "$d/$bad.json" >/dev/null; then
      echo "  FAIL $bad.json was accepted as a manifest" >&2; rc=1
    else
      echo "  PASS $bad.json refused"
    fi
  done
  printf '# proven-cicd: proven-lock-gate@0.0.9 sha256:%s\nname: g\n' "$h" > "$d/content-behind.yml"
  printf '# proven-cicd: proven-lock-gate@0.1.0 sha256:%s\nname: g\n' "$h" > "$d/content-current.yml"
  printf '# proven-cicd: proven-lock-gate@0.2.0 sha256:%s\nname: g\n' "$h" > "$d/content-ahead.yml"
  printf '# proven-cicd: wide-gate@0.9.0 sha256:%s\nname: g\n' "$h" > "$d/content-wide.yml"
  printf '# proven-cicd: other-gate@1.0.0 sha256:%s\nname: g\n' "$h" > "$d/content-unlisted.yml"
  printf '# proven-cicd: proven-lock-gate@0.1 sha256:%s\nname: g\n' "$h" > "$d/content-malformed.yml"
  printf 'name: g\n# proven-cicd: proven-lock-gate@0.0.9 sha256:%s\n' "$h" > "$d/content-not-first.yml"
  printf '# proven-cicd: proven-lock-gate@18446744073709551617.0.0 sha256:%s\nname: g\n' "$h" > "$d/content-huge.yml"
  ccheck() {
    local file="$1" want="$2" got
    got=$(content_state "$d/$file" "$d/manifest.tsv" | cut -f1)
    if [ "$got" = "$want" ]; then
      echo "  PASS $file -> ${got:-(none)}"
    else
      echo "  FAIL $file -> got '$got' want '$want'" >&2; rc=1
    fi
  }
  ccheck content-behind.yml    BEHIND-CONTENT
  ccheck content-current.yml   CONTENT-CURRENT
  ccheck content-ahead.yml     CONTENT-AHEAD
  ccheck content-wide.yml      BEHIND-CONTENT
  ccheck content-unlisted.yml  CONTENT-UNLISTED
  ccheck content-malformed.yml CONTENT-MALFORMED
  # A component past nine digits would wrap in version_cmp and read CURRENT.
  ccheck content-huge.yml      CONTENT-MALFORMED
  # Only the first line is a stamp; a pin-only workflow has no content row.
  ccheck content-not-first.yml ""
  ccheck fresh.yml             ""

  echo "control: the lock relock is present"
  if [ -f "$RELOCK" ] && bash -n "$RELOCK"; then
    echo "  PASS $(basename "$RELOCK") present and parses"
  else
    echo "  FAIL $RELOCK missing or unparseable" >&2; rc=1
  fi

  rm -rf "$d"
  return $rc
}

# ---------------------------------------------------------------------------
# NETWORK LAYER
# ---------------------------------------------------------------------------

gh_ok() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }

# resolve_target — pick the SHA every consumer should point at.
# NEVER a feature-branch head: the applier would propagate unmerged work.
resolve_target() {
  [ -n "$TARGET_SHA" ] && { echo "$TARGET_SHA"; return 0; }
  gh api "repos/${STANDARDS_REPO}/commits/main" --jq '.sha' 2>/dev/null
}

# validate_target — prove the SHA is SAFE TO PIN A CALLER TO, in two halves.
#
# 1. Reachable from standards' main. Existence is not enough (see the
#    2026-09-04 squash-merge incident above). The comparison is done
#    SERVER-side so a shallow/partial clone cannot produce a false negative.
# 2. Self-consistent lock. GitHub validates every caller against the target's
#    OWN actions.lock, so a target whose lock carries a self-SHA leaf, an
#    unkeyed action ref or a dangling edge kills every repinned caller at
#    `Set up job` (standards fad242d3, 74d2f66f and 571cc734 are reachable and
#    each carry 10-12 self-SHA leaves; their callers fail with "invalid
#    lockfile pin"). lock-selfcheck.sh is the estate's answer to "is this SHA
#    safe to pin a caller to?"; a sweep onto a target it rejects turns N
#    quietly broken repos into N loudly broken ones. It reads git objects
#    only, so the target is fetched first when this checkout lacks it — in
#    audit mode too, since a census against an unsafe target is not evidence.
validate_target() {
  assert_pin_ancestry "$STANDARDS_REPO" "$1" main || return 1
  if ! git -C "$STANDARDS_ROOT" cat-file -e "${1}^{commit}" 2>/dev/null; then
    git -C "$STANDARDS_ROOT" fetch -q --depth=1 origin "$1" 2>/dev/null || {
      log "FATAL: ${1} is not in ${STANDARDS_ROOT} and could not be fetched; lock-selfcheck.sh needs it."
      return 1
    }
  fi
  if ! STANDARDS_DIR="$STANDARDS_ROOT" bash "$STANDARDS_ROOT/scripts/lock-selfcheck.sh" "$1" >&2; then
    log "FATAL: target ${1} fails lock-selfcheck.sh (or could not be examined); refusing to re-point any caller at it."
    return 1
  fi
}

# sha_is_commit <sha> — is this a real commit in standards?
# This is what separates BEHIND from DEAD-REF.
# target_has_squabbler <sha> - the squabbler reusable exists in standards at <sha>.
target_has_squabbler() {
  git -C "$STANDARDS_ROOT" cat-file -e "${1}:.github/workflows/cicd-squabbler-reusable.yml" 2>/dev/null
}

sha_is_commit() {
  gh api "repos/${STANDARDS_REPO}/commits/$1" --jq '.sha' >/dev/null 2>&1
}

# refine_behind <file> — echo DEAD-REF if ANY pin in the file names a SHA that
# is not a commit in standards; echo nothing otherwise.
refine_behind() {
  local sha
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    if ! sha_is_commit "$sha"; then echo "DEAD-REF:$sha"; fi
  done < <(pin_shas "$1" | sort -u)
}

# list_repos — print every non-archived repository of the owners in OWNERS that
# this credential can see, one full_name per line, sorted and deduplicated.
#
# Every credential gets each owner's PUBLIC listing. Under a GitHub App
# installation token (prefix ghs_) the installation's own repositories are ADDED
# to it: users/<o>/repos and orgs/<o>/repos return public repositories only to an
# installation, so the private repositories the App can write never reached the
# census. The installation listing never REPLACES the public one, because
# GITHUB_TOKEN is ghs_ too and its installation is this one repository; a
# replacement would shrink the audit-mode census to standards alone.
#
# Returns 1 and prints nothing when any listing fails. A rate-limited owner that
# silently contributed zero repositories would read as an owner with nothing to
# re-point, which is the same fail-open fetch_workflows was cured of.
list_repos() {
  local owner all part tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  all=$(mktemp); part=$(mktemp)
  for owner in ${OWNERS//,/ }; do
    # users/<o>/repos covers a user; if that fails the owner may be an org.
    if gh api "users/${owner}/repos" --paginate \
         --jq '.[] | select(.archived == false) | .full_name' > "$part" \
       || gh api "orgs/${owner}/repos" --paginate \
         --jq '.[] | select(.archived == false) | .full_name' > "$part"; then
      cat "$part" >> "$all"
    else
      log "FATAL: could not list the repositories of ${owner}: users/${owner}/repos and orgs/${owner}/repos both failed."; rm -f "$all" "$part"; return 1
    fi
  done
  case "$tok" in
    ghs_*)
      gh api --paginate 'installation/repositories?per_page=100' \
        --jq '.repositories[] | select(.archived | not) | .full_name' > "$part" \
        || { log "FATAL: an App installation token could not list installation/repositories."; rm -f "$all" "$part"; return 1; }
      # One installation belongs to one account; keep only the owners being
      # walked, so --owners narrows the census under an App token as well.
      for owner in ${OWNERS//,/ }; do
        awk -v o="${owner,,}/" 'index(tolower($0), o) == 1' "$part" >> "$all"
      done
      ;;
  esac
  sort -u "$all"
  rm -f "$all" "$part"
}

# fetch_workflows <owner/repo> <destdir> — download .github/workflows/*.yml,
# *.yaml and actions.lock, when present, into destdir.
# The REMOTE content is the only evidence: a local checkout can be arbitrarily
# stale, and reading one is what produced a false "285 callers track main"
# census on 2026-09-15.
# Returns 0 for a successful GraphQL response, including an empty tree. Blobs
# without text are skipped; decoding failures remove the destination file
# without changing the success status. In the REST fallback, returns 0 for
# a missing directory (HTTP 404), and 1 for other listing or download failures;
# files already downloaded remain in destdir on failure. Only a 404 is "no
# workflows": returning 0 on failure made a rate-limited repo vanish from the
# census while `walked N` still counted it (measured 2026-10-02, shared
# 5,000/h token exhausted mid-run).
fetch_workflows() {
  local repo="$1" dest="$2" owner="${1%%/*}" name="${1##*/}" resp
  mkdir -p "$dest"
  resp=$(mktemp)

  # ONE GraphQL call fetches every workflow file's text for a repo. The REST
  # contents API needs one call per FILE, which over 438 repos is ~2,600 calls
  # and roughly two hours; this is ~438 calls and minutes. The estate has a hard
  # 5,000/hour ceiling, so the cheaper shape is not an optimisation, it is what
  # makes an estate-wide census affordable at all.
  if gh api graphql \
       -f query='query($owner:String!,$name:String!){
         repository(owner:$owner,name:$name){
           object(expression:"HEAD:.github/workflows"){
             ... on Tree { entries { name type object { ... on Blob { text } } } }
           }
         }
       }' \
       -F owner="$owner" -F name="$name" > "$resp" 2>/dev/null; then
    local n b64
    while IFS=$'\t' read -r n b64; do
      [ -n "$n" ] || continue
      printf '%s' "$b64" | base64 -d > "${dest}/${n}" 2>/dev/null || rm -f "${dest}/${n}"
    done < <(jq -r '
        (.data.repository.object.entries // [])[]
        | select(.type == "blob")
        | select((.name | test("\\.ya?ml$")) or .name == "actions.lock")
        | select(.object.text != null)
        | "\(.name)\t\(.object.text | @base64)"' "$resp" 2>/dev/null)
    rm -f "$resp"
    # A repo with no .github/workflows yields an empty tree, which is a valid
    # answer, not a failure. Only fall back when the call itself failed.
    return 0
  fi
  rm -f "$resp"

  # REST fallback: slower, but survives a GraphQL outage or a repo shape the
  # query cannot express. The REMOTE content is the only evidence either way —
  # reading a local checkout is what produced a false "285 callers track main"
  # census on 2026-09-15.
  local fname listing
  if ! listing=$(gh api "repos/${repo}/contents/.github/workflows" \
                   --jq '.[] | select(.type == "file") | .name' 2>&1); then
    case "$listing" in *"HTTP 404"*) return 0 ;; esac
    return 1
  fi
  for fname in $(printf '%s\n' "$listing" | grep -E '\.ya?ml$|^actions\.lock$'); do
    gh api "repos/${repo}/contents/.github/workflows/${fname}" \
       -H 'Accept: application/vnd.github.raw' > "${dest}/${fname}" 2>/dev/null \
      || { rm -f "${dest}/${fname}"; return 1; }
  done
  return 0
}

# land_pr <repo> <dir> <files...> — create branch, commit VERIFIED, open PR.
# Uses createCommitOnBranch: it is cross-repo by construction and the resulting
# commit is GitHub-"Verified", which required_signatures rulesets demand.
land_pr() {
  local repo="$1" dir="$2"; shift 2
  local base_sha base_branch ref_exists head_oid created=0 resp oid pr

  base_branch=$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null) || return 1
  base_sha=$(gh api "repos/${repo}/commits/${base_branch}" --jq '.sha' 2>/dev/null) || return 1

  ref_exists=$(gh api "repos/${repo}/git/ref/heads/${BRANCH_NAME}" --jq '.object.sha' 2>/dev/null || true)
  # On a 404 gh prints the error BODY on stdout, so "something came back" is not
  # "the branch exists": only a 40-hex SHA is.
  if [[ "$ref_exists" =~ ^[0-9a-f]{40}$ ]]; then
    head_oid="$ref_exists"
  else
    gh api "repos/${repo}/git/refs" -X POST \
      -f "ref=refs/heads/${BRANCH_NAME}" -f "sha=${base_sha}" >/dev/null 2>&1 || return 1
    head_oid="$base_sha"; created=1
  fi

  # The message names what THIS change does and the run that made it. It used
  # to end with one fixed claude.ai session link, so every PR the App opened
  # pointed at a conversation that had nothing to do with it.
  local f pins=0 sq=0 msg_head msg_body run_line=""
  for f in "$@"; do
    case "$f" in "$SQUABBLER_FILE") sq=1 ;; actions.lock) ;; *) pins=1 ;; esac
  done
  if [ "$sq" -eq 1 ] && [ "$pins" -eq 1 ]; then
    msg_head="chore(ci): re-point standards pins to ${TARGET_SHA:0:12}; add the CICD Squabbler gate"
  elif [ "$sq" -eq 1 ]; then
    msg_head="chore(ci): add the CICD Squabbler gate (standards ${TARGET_SHA:0:12})"
  else
    msg_head="chore(ci): re-point standards reusable-workflow pins to ${TARGET_SHA:0:12}"
  fi
  [ -n "${GITHUB_RUN_ID:-}" ] && run_line=$(printf '\n\nRun: %s/%s/actions/runs/%s' \
    "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY:-$STANDARDS_REPO}" "$GITHUB_RUN_ID")
  msg_body="Opened by the standards pin applier (scripts/apply-workflow-pins-remote.sh)."
  [ "$pins" -eq 1 ] && msg_body=$(printf '%s\n\nRe-points this repository'"'"'s pinned references to %s reusable\nworkflows at %s, which is proven reachable from standards main and passes\nlock-selfcheck.sh.' "$msg_body" "$STANDARDS_REPO" "$TARGET_SHA")
  [ "$sq" -eq 1 ] && msg_body=$(printf '%s\n\nAdds .github/workflows/%s, the CICD Squabbler gate, pinned to the same\ncommit. Its chains job fails on a dependency cycle or a dead upstream.' "$msg_body" "$SQUABBLER_FILE")
  printf '%s\n' "$@" | grep -qx actions.lock && msg_body=$(printf '%s\n\nactions.lock is relocked in the same commit (scripts/relock-standards-pin.sh),\nso no workflow starts with a lock that does not match its pins.' "$msg_body")
  msg_body="${msg_body}${run_line}"

  # The request body goes in whole via --input. `-F input=<json>` sends the
  # JSON as a STRING, which GitHub rejects as an invalid CreateCommitOnBranchInput
  # — that is how this path failed on every repo until 2026-10-02.
  resp=$(commit_payload "$repo" "$head_oid" "$msg_head" "$msg_body" "$dir" "$@" \
           | gh api graphql --input - 2>&1)
  oid=$(printf '%s' "$resp" | jq -r '.data.createCommitOnBranch.commit.oid // empty' 2>/dev/null)
  if ! [[ "$oid" =~ ^[0-9a-f]{40}$ ]]; then
    log "  land: createCommitOnBranch failed for ${repo}: $(printf '%s' "$resp" | head -c 300)"
    # Do not leave an empty branch behind for the next run to trip over.
    [ "$created" = 1 ] && gh api -X DELETE "repos/${repo}/git/refs/heads/${BRANCH_NAME}" >/dev/null 2>&1
    return 1
  fi

  pr=$(gh pr create --repo "$repo" --head "$BRANCH_NAME" --base "$base_branch" \
        --title "$msg_head" --body "$msg_body" \
        2>/dev/null) || { log "  land: PR already open or creation failed for ${repo}"; return 1; }
  echo "$pr"
}

# commit_payload <repo> <head_oid> <headline> <body> <dir> <files...> — print the
# complete createCommitOnBranch GraphQL request body, with `input` as an OBJECT.
commit_payload() {
  local repo="$1" head_oid="$2" headline="$3" body="$4" dir="$5"; shift 5
  local f
  for f in "$@"; do
    jq -n --arg path ".github/workflows/$(basename "$f")" \
          --arg contents "$(base64 -w0 < "${dir}/${f}")" \
          '{path: $path, contents: $contents}'
  done | jq -s \
    --arg repo "$repo" --arg branch "$BRANCH_NAME" --arg oid "$head_oid" \
    --arg headline "$headline" --arg body "$body" '{
      query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
      variables: { input: {
        branch: { repositoryNameWithOwner: $repo, branchName: $branch },
        expectedHeadOid: $oid,
        message: { headline: $headline, body: $body },
        fileChanges: { additions: . } } } }'
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
# main [options] — audit remote standards pins and write a TSV census to
# stdout, or to --out. Under --fix, fetch the target commit locally if needed
# and create remote branches, commits and PRs for changed workflows and locks.
# Fetch, relock and PR failures become census statuses and processing continues;
# a relock failure prevents that repository's changes from being submitted.
# Recorded repository failures do not cause a non-zero exit status.
# Exits 1 on failed controls, authentication, target validation/fetch or repository
# enumeration, and 2 on an unknown option; --self-test exits with its test status.
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --fix) DO_FIX=1 ;;
      --repair-illegal) REPAIR_ILLEGAL=1 ;;
      --to) TARGET_SHA="$2"; shift ;;
      --owners) OWNERS="$2"; shift ;;
      --only) ONLY_REPO="$2"; shift ;;
      --out) OUT_FILE="$2"; shift ;;
      --limit) LIMIT="$2"; shift ;;
      --ensure-squabbler) ENSURE_SQUABBLER=1 ;;
      --proven-sha) PROVEN_SHA="$2"; shift ;;
      --self-test) self_test; exit $? ;;
      -h|--help) sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d'; exit 0 ;;
      *) log "unknown option: $1"; exit 2 ;;
    esac
    shift
  done

  # The controls run on EVERY invocation, not just --self-test. A census whose
  # classifier is broken is worse than no census, because it looks like data.
  log "== known-answer controls =="
  if ! self_test >&2; then
    log "FATAL: classifier controls failed. Refusing to produce a census."
    exit 1
  fi

  gh_ok || { log "FATAL: gh is not authenticated. Probe with 'gh api user' by EXIT CODE."; exit 1; }

  TARGET_SHA=$(resolve_target)
  [ -n "$TARGET_SHA" ] || { log "FATAL: could not resolve a target SHA."; exit 1; }
  validate_target "$TARGET_SHA" || exit 1
  # --to may name an older commit that predates the squabbler reusable; a
  # caller pinned there could never start (and with no lock, no relock would
  # catch it). validate_target has fetched the target into this checkout.
  if [ "$ENSURE_SQUABBLER" -eq 1 ] && ! target_has_squabbler "$TARGET_SHA"; then
    log "FATAL: --ensure-squabbler, but ${TARGET_SHA} has no .github/workflows/cicd-squabbler-reusable.yml; refusing to write callers to it."
    exit 1
  fi
  # The relock reads the target's reusables and lock from this checkout; a
  # shallow CI checkout may hold a different commit, so fetch it if needed.
  if [ "$DO_FIX" -eq 1 ] && ! git -C "$STANDARDS_ROOT" cat-file -e "${TARGET_SHA}^{commit}" 2>/dev/null; then
    git -C "$STANDARDS_ROOT" fetch -q --depth=1 origin "$TARGET_SHA" 2>/dev/null \
      || { log "FATAL: ${TARGET_SHA} is not in ${STANDARDS_ROOT} and could not be fetched; the lock relock needs it."; exit 1; }
  fi
  log "== target: ${TARGET_SHA} (reachable from ${STANDARDS_REPO} main; lock self-consistent) =="
  [ "$DO_FIX" -eq 1 ] && log "== MODE: --fix (will open PRs) ==" || log "== MODE: audit (writes nothing) =="

  # Proven content census: the manifest at the pinned commit. Without it the
  # content census DEGRADES LOUDLY: the pin census still runs, the census gets
  # one CONTENT-CENSUS-FAILED row instead of content rows, and the run exits 1
  # at the end. An outage at proven-cicd cannot blind the pin census, and a
  # content census with no manifest never reads as clean.
  local content_failed=""
  if [ -n "$PROVEN_SHA" ]; then
    [[ $PROVEN_SHA =~ ^[0-9a-f]{40}$ ]] \
      || { log "FATAL: --proven-sha must be a 40-hex commit, got '${PROVEN_SHA}'."; exit 1; }
    local mraw; mraw=$(mktemp); PROVEN_MANIFEST=$(mktemp)
    if ! gh api "repos/${PROVEN_REPO}/contents/proven/manifest.json?ref=${PROVEN_SHA}" \
           -H 'Accept: application/vnd.github.raw' > "$mraw" 2>/dev/null; then
      content_failed="proven/manifest.json unreadable at ${PROVEN_REPO}@${PROVEN_SHA}"
    elif ! manifest_tsv "$mraw" > "$PROVEN_MANIFEST"; then
      content_failed="proven/manifest.json at ${PROVEN_REPO}@${PROVEN_SHA} is not a valid proven-cicd/manifest/v1"
    fi
    rm -f "$mraw"
    if [ -n "$content_failed" ]; then
      rm -f "$PROVEN_MANIFEST"; PROVEN_MANIFEST=""
      log "ERROR: ${content_failed}. No content census; the pin census continues and the run will end red."
    else
      log "== proven content: $(wc -l < "$PROVEN_MANIFEST") artifact(s) at ${PROVEN_REPO}@${PROVEN_SHA} (census only) =="
    fi
  fi

  local tsv; tsv=$(mktemp)
  printf 'REPO\tWORKFLOW\tSTATUS\tDETAIL\n' > "$tsv"
  [ -n "$content_failed" ] && printf -- '-\t-\tCONTENT-CENSUS-FAILED\t%s\n' "$content_failed" >> "$tsv"

  WORKDIR=$(mktemp -d); trap 'rm -rf "${WORKDIR:-}"' EXIT
  local repos n=0
  if [ -n "$ONLY_REPO" ]; then
    repos="$ONLY_REPO"
  elif ! repos=$(list_repos); then
    log "FATAL: repository enumeration failed for ${OWNERS}. Refusing to report a partial census."
    exit 1
  fi
  [ -n "$repos" ] || { log "FATAL: enumerated zero repositories for ${OWNERS} (rate limit or auth?). Refusing to report an empty census."; exit 1; }

  local repo walked=0
  for repo in $repos; do
    # Audit: n counts repos walked. Fix: n counts repos a PR is attempted in.
    [ "$LIMIT" -gt 0 ] && [ "$n" -ge "$LIMIT" ] && break
    walked=$((walked+1)); [ "$DO_FIX" -eq 1 ] || n=$((n+1))
    local rdir="${WORKDIR}/$(echo "$repo" | tr '/' '_')"
    if ! fetch_workflows "$repo" "$rdir"; then
      log "  FETCH-FAILED ${repo}: workflows could not be read; NOT classified"
      printf '%s\t-\tFETCH-FAILED\t-\n' "$repo" >> "$tsv"
      continue
    fi
    local found=0 changed=() wf base st detail
    shopt -s nullglob
    for wf in "$rdir"/*.yml "$rdir"/*.yaml; do
      found=1
      base=$(basename "$wf")
      # A stamped proven-cicd copy gets its own row; it is never rewritten here.
      if [ -n "$PROVEN_MANIFEST" ]; then
        local cst
        cst=$(content_state "$wf" "$PROVEN_MANIFEST")
        [ -n "$cst" ] && printf '%s\t%s\t%s\n' "$repo" "$base" "$cst" >> "$tsv"
      fi
      st=$(classify_file "$wf" "$TARGET_SHA" | sort | tr '\n' ',' ); st="${st%,}"
      [ "$st" = "NONE" ] && continue
      detail=""
      case ",$st," in *,BEHIND,*)
        detail=$(refine_behind "$wf" | tr '\n' ' ')
        [ -n "$detail" ] && st="${st},DEAD-REF"
      ;; esac
      printf '%s\t%s\t%s\t%s\n' "$repo" "$base" "$st" "$detail" >> "$tsv"

      if [ "$DO_FIX" -eq 1 ]; then
        local before; before=$(cat "$wf")
        if needs_rewrite "$st"; then rewrite_pins "$wf" "$TARGET_SHA"; fi
        if [ "$REPAIR_ILLEGAL" -eq 1 ]; then
          case ",$st," in *,ILLEGAL,*) rewrite_illegal "$wf" "$TARGET_SHA" ;; esac
        fi
        [ "$before" != "$(cat "$wf")" ] && changed+=("$base")
      fi
    done
    shopt -u nullglob
    [ "$found" -eq 0 ] && [ "$ENSURE_SQUABBLER" -eq 0 ] && continue

    # The squabbler gate rides with the re-pin (see ENSURE-SQUABBLER above).
    if [ "$ENSURE_SQUABBLER" -eq 1 ]; then
      local sqst; sqst=$(squabbler_state "$rdir" "$TARGET_SHA" "$REPAIR_ILLEGAL")
      # A file of that name that does not run the gate is the repo's own
      # workflow: never overwrite it.
      [ "$sqst" = MISSING ] && [ -e "${rdir}/${SQUABBLER_FILE}" ] && sqst="DEFERRED:NAME-TAKEN"
      if [ "$sqst" = MISSING ]; then
        local isfork
        isfork=$(gh api "repos/${repo}" --jq '.fork' 2>/dev/null || echo unknown)
        case "$isfork" in
          false)
            if [ "$DO_FIX" -eq 1 ]; then
              write_squabbler_caller "${rdir}/${SQUABBLER_FILE}" "$TARGET_SHA"
              changed+=("$SQUABBLER_FILE"); sqst=ADDED
            fi ;;
          true) sqst=FORK ;;
          *) sqst="DEFERRED:FORK-UNKNOWN" ;;
        esac
      fi
      printf '%s\t%s\tSQUABBLER-%s\t-\n' "$repo" "$SQUABBLER_FILE" "$sqst" >> "$tsv"
    fi
    [ "$found" -eq 0 ] && [ "${#changed[@]}" -eq 0 ] && continue

    # The lock must follow the pins. Re-pointing `uses:` alone leaves
    # actions.lock keyed to the old standards commit: check-lock-sync.sh
    # rejects it and GitHub refuses the run at startup (jobs=0). Measured
    # 2026-10-14: 200 of 368 governance callers carry a lock, and this applier
    # used to fetch and commit only *.yml, so every fix-mode PR to one of them
    # would have stopped its reusable-calling workflows. relock is fail-closed;
    # a repo whose lock cannot follow is reported and NOT landed.
    if [ "$DO_FIX" -eq 1 ] && [ "${#changed[@]}" -gt 0 ] && [ -f "$rdir/actions.lock" ]; then
      local lock_before; lock_before=$(cat "$rdir/actions.lock")
      local relog relock_rc=0
      relog=$(bash "$RELOCK" --to "$TARGET_SHA" --standards "$STANDARDS_ROOT" "$rdir" 2>&1) || relock_rc=$?
      log "$relog"
      if [ "$relock_rc" -ne 0 ]; then
        log "  LOCK-REFUSED ${repo}: actions.lock cannot follow the new pins; NOT landed"
        printf '%s\t-\tLOCK-REFUSED\t%s\n' "$repo" "$(printf '%s' "$relog" | grep -m1 -o 'REFUSED ([^)]*)' | tr '\t' ' ')" >> "$tsv"
        continue
      fi
      # Leaves standards cannot repair stay as they were; the census names them,
      # because the workflows that use them still fail at startup until a lock
      # regeneration gives them a tag.
      if printf '%s' "$relog" | grep -q 'SELF-SHA-LEAF left'; then
        printf '%s\tactions.lock\tLEAF-UNREPAIRED\t%s\n' "$repo" \
          "$(printf '%s' "$relog" | sed -n 's/.*SELF-SHA-LEAF left[^:]*://p' | head -1 | sed 's/^ *//')" >> "$tsv"
      fi
      [ "$lock_before" != "$(cat "$rdir/actions.lock")" ] && changed+=("actions.lock")
    fi

    if [ "$DO_FIX" -eq 1 ] && [ "${#changed[@]}" -gt 0 ]; then
      n=$((n+1))
      local url
      if url=$(land_pr "$repo" "$rdir" "${changed[@]}"); then
        log "  OPENED ${repo}: ${url}"
        printf '%s\t-\tPR-OPENED\t%s\n' "$repo" "$url" >> "$tsv"
      else
        printf '%s\t-\tPR-FAILED\t-\n' "$repo" >> "$tsv"
      fi
    fi
  done

  log "== walked ${walked} repo(s); ${n} counted against --limit ${LIMIT} =="
  # Counts are reported at LANDED, never at PR-open: 545 merged/week means
  # throughput is fine; 249 PRs open and unmerged is an abandoned campaign.
  log "== summary by status =="
  awk -F'\t' 'NR>1{c[$3]++} END{for(k in c) printf "   %-28s %d\n", k, c[k]}' "$tsv" >&2

  if [ -n "$OUT_FILE" ]; then cp "$tsv" "$OUT_FILE"; log "== census: ${OUT_FILE} =="; else cat "$tsv"; fi
  rm -f "$tsv" "${PROVEN_MANIFEST:-}"
  if [ -n "$content_failed" ]; then
    log "FAILED: the content census did not run (${content_failed}); the pin census above is complete."
    exit 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
