#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# relock-standards-pin.sh — move a consumer's actions.lock to the standards
# commit its reusable-workflow pins were just re-pointed at.
#
# WHY: both pin bumpers (propagate-workflow-pins.sh and the scheduled
# apply-workflow-pins-remote.sh) rewrite `uses: hyperpolymath/standards/...@SHA`
# in workflow YAML and nothing else. In a repo with an actions.lock that leaves
# the lock keyed to the OLD standards commit: per-workflow entries name a ref no
# `uses:` carries any more, and the standards dependency record still lists the
# actions the OLD reusables used. check-lock-sync.sh fails, and GitHub refuses
# such runs at startup (jobs=0; mirror.yml, standards 2026-09-22). Measured
# 2026-10-14: 200 of 368 governance callers carry an actions.lock, so a fix-mode
# applier run would have broken their reusable-calling workflows.
# `gh actions-lock` cannot repair it: v0.1.6 is blind to job-level `uses:`.
#
# WHAT IT WRITES, and nothing else:
#   * per-workflow entries hyperpolymath/standards@OLD -> @TARGET;
#   * the hyperpolymath/standards@TARGET dependency record, whose nested `uses:`
#     is every action the called reusables use AT TARGET (owner/repo@ref);
#   * records those actions need and the lock lacks, copied verbatim from
#     standards' own actions.lock at TARGET;
#   * removal of the OLD standards records, and of records that only they
#     kept alive (nothing else is pruned);
#   * dependency records in C-locale key order, as gh actions-lock writes them.
#
# A short pin that prefixes the target (as the applier leaves a FRESH one) is
# current: its own short-keyed record is left alone.
#
# FAIL-CLOSED: it works on a copy and leaves the lock untouched (exit 1) when a
# workflow still pins a standards reusable at another SHA, when the called
# reusable is not in standards at TARGET, when the OLD record is missing,
# when a needed record is in neither lock, or when a workflow's standards entries
# would not name exactly the refs it pins. A lock with a dangling edge is
# worse than a stale one: the stale one is at least reported by the gate.
#
# Usage: relock-standards-pin.sh --to <sha> [--standards <dir>] <workflows-dir>
#   <workflows-dir>  holds the workflow files and actions.lock: a repo's
#                    .github/workflows, or the applier's flat fetch directory.
#   --standards      a standards git checkout that contains <sha>; default
#                    $STANDARDS_DIR, else the checkout this script lives in.
# Exit: 0 relocked or nothing to do; 1 refused (lock untouched); 2 usage.
set -euo pipefail

TARGET="" SROOT="${STANDARDS_DIR:-}" WF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) TARGET="${2:-}"; shift 2 ;;
    --to=*) TARGET="${1#*=}"; shift ;;
    --standards) SROOT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
    -*) echo "relock-standards-pin: unknown option $1" >&2; exit 2 ;;
    *) WF="$1"; shift ;;
  esac
done
[ -n "$SROOT" ] || SROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$TARGET" =~ ^[0-9a-f]{40}$ ]] || { echo "relock-standards-pin: --to must be a full 40-hex SHA" >&2; exit 2; }
[ -n "$WF" ] && [ -d "$WF" ] || { echo "relock-standards-pin: workflows directory required" >&2; exit 2; }
git -C "$SROOT" cat-file -e "${TARGET}^{commit}" 2>/dev/null \
  || { echo "relock-standards-pin: standards commit $TARGET not in $SROOT" >&2; exit 2; }

L="$WF/actions.lock"
[ -f "$L" ] || { echo "relock-standards-pin: no actions.lock in $WF; nothing to relock"; exit 0; }
# refuse REASON... — report why the relock is refused and exit 1, lock untouched.
refuse() { echo "relock-standards-pin: REFUSED ($*); $L left untouched" >&2; exit 1; }

PIN_RE='(hyperpolymath|metadatastician)/standards/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml@[0-9a-fA-F]+'
shopt -s nullglob
wfs=("$WF"/*.yml "$WF"/*.yaml)
shopt -u nullglob
# standards_pins FILE... — every standards reusable pin in the files, as the
# scan always matched it (block, flow or quoted-key `uses`), except on full-line
# comments: reusables carry commented caller examples (`#   uses: …@<old sha>`)
# that no run resolves, and counting them refused every relock of standards'
# own callers.
standards_pins() { grep -hvE '^[[:space:]]*#' "$@" 2>/dev/null | grep -oE "$PIN_RE"; }
pins=$(standards_pins "${wfs[@]}" | sort -u || true)
# A short pin (7+ hex) that prefixes TARGET names TARGET: the applier counts it
# FRESH and leaves it as written, and the lock keys it by that short ref in a
# record of its own, which is left as it is. Only full pins feed TARGET's record.
full="" stale="" COORD=""
for p in $pins; do
  repo=${p%%/.github/workflows/*}
  if [ -n "$COORD" ] && [ "$repo" != "$COORD" ]; then
    refuse "mixed standards owners in live workflow calls ($COORD and $repo); normalise workflows before relocking"
  fi
  COORD="$repo"
  r=${p##*@}
  if [ "$r" = "$TARGET" ]; then full="$full $p"
  elif [ "${#r}" -lt 7 ] || [ "${TARGET:0:${#r}}" != "$r" ]; then stale="$stale $p"
  fi
done
[ -z "$stale" ] || refuse "workflows still pin other standards commits:$stale"

oldrefs=$(grep -oE "'(hyperpolymath|metadatastician)/standards@[0-9a-f]{40}'" "$L" | tr -d "'" | LC_ALL=C sort -u | grep -vx "${COORD}@${TARGET}" || true)
if [ -z "$oldrefs" ]; then echo "relock-standards-pin: lock already keyed to standards@${TARGET:0:12}"; exit 0; fi
[ -n "$full" ] || refuse "lock names standards commits but no workflow pins standards@${TARGET:0:12} in full"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
q="'"

# rec_body KEY FILE — print the dependency record KEY (header and body) from FILE.
# KEY is the unquoted owner/repo@ref. A missing record produces no output and
# succeeds; a file read error propagates awk's non-zero status.
rec_body() { awk -v k="    ${q}$1${q}:" '$0==k{f=1;print;next} f&&/^    [^ ]/{exit} f' "$2"; }

# GitHub's lockfile parser folds owner/repo case and keeps the ref as written:
# 'Swatinem/rust-cache@X' and 'swatinem/rust-cache@X' are one key, and two
# records for it with different metadata make the whole lock unparseable
# ("duplicate action key ... after canonicalization"). Lookups and the closure
# check compare keys that way.
# fold — read owner/repo@ref lines; print each with owner/repo lower-cased.
fold() { awk '{ i = index($0, "@"); if (i) print tolower(substr($0, 1, i - 1)) substr($0, i); else print }'; }
# lock_key KEY FILE — print the dependency key in FILE naming the same pin as
# KEY, in FILE's own spelling; nothing if FILE has none.
lock_key() {
  local want; want=$(printf '%s\n' "$1" | fold)
  awk -v q="$q" -v w="$want" 'index($0, "    " q) == 1 && /@/ && /:$/ {
      k = substr($0, 6, length($0) - 7); i = index(k, "@")
      if (tolower(substr(k, 1, i - 1)) substr(k, i) == w) { print k; exit } }' "$2"
}

# Actions the called reusables use at TARGET, normalised to owner/repo@ref.
: > "$tmp/uses"
for p in $full; do
  path=${p#${COORD}/}; path=${path%@*}
  git -C "$SROOT" show "${TARGET}:${path}" > "$tmp/reusable" 2>/dev/null || refuse "$path is not in standards at ${TARGET:0:12}"
  sed 's/[[:space:]]#.*$//' "$tmp/reusable" \
    | grep -oE "^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*['\"]?[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[^[:space:]'\"]+" \
    | sed -E "s/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*['\"]?//; s#^([^/]+/[^/@]+)[^@]*@#\1@#" >> "$tmp/uses" || true
done
grep -Ev '^(hyperpolymath|metadatastician)/standards@' "$tmp/uses" | LC_ALL=C sort -u > "$tmp/uses.s" || true

# owner_id / repo_id come from an OLD record; without one the lock was already dangling.
ids=""
for o in $oldrefs; do ids=$(rec_body "$o" "$L" | grep -E '^        (owner_id|repo_id):' || true); [ -n "$ids" ] && break; done
[ -n "$ids" ] || refuse "no standards@OLD dependency record to take owner_id/repo_id from"
if [ "$COORD" = "metadatastician/standards" ]; then
  # A transfer keeps the repository ID but changes the owner account ID.
  printf '%s\n' "$ids" | grep -qx '        repo_id: 1116521501' || refuse "standards repository ID mismatch during owner transfer"
  ids=$(printf '%s\n' "$ids" | sed 's/^        owner_id: .*/        owner_id: 297579217/')
fi

# Records the OLD standards records kept alive: the pruning candidates.
: > "$tmp/cand"
for o in $oldrefs; do rec_body "$o" "$L" | grep -oE "^            - '[^']+'" | sed -E "s/^ +- '|'$//g" >> "$tmp/cand" || true; done

cp "$L" "$tmp/lock"
for o in $oldrefs; do
  sed -i "s|^        - '$o'\$|        - '${COORD}@$TARGET'|" "$tmp/lock"
  awk -v k="    ${q}${o}${q}:" '$0==k{s=1;next} s&&/^    [^ ]/{s=0} !s' "$tmp/lock" > "$tmp/l" && mv "$tmp/l" "$tmp/lock"
done
awk -v k="    ${q}${COORD}@$TARGET${q}:" '$0==k{s=1;next} s&&/^    [^ ]/{s=0} !s' "$tmp/lock" > "$tmp/l" && mv "$tmp/l" "$tmp/lock"
{ printf "    '%s@%s':\n        ref: '%s'\n        commit: 'sha1-%s'\n" "$COORD" "$TARGET" "$TARGET" "$TARGET"
  printf '%s\n' "$ids"
  if [ -s "$tmp/uses.s" ]; then echo "        uses:"; sed "s|.*|            - '&'|" "$tmp/uses.s"; fi
} >> "$tmp/lock"

# Records the new pin needs: from this lock, else verbatim from standards' own.
git -C "$SROOT" show "${TARGET}:.github/workflows/actions.lock" > "$tmp/slock" 2>/dev/null || : > "$tmp/slock"
while read -r u; do
  [ -n "$u" ] || continue
  # The consumer's record may spell owner/repo differently; it is still this pin's.
  key=$(lock_key "$u" "$tmp/lock")
  existing=""; [ -z "$key" ] || existing=$(rec_body "$key" "$tmp/lock")
  if [[ -n "$existing" ]]; then
    pin=${u##*@}
    if [[ "$pin" =~ ^[0-9a-f]{40}$ ]] && printf '%s\n' "$existing" | grep -qxF "        ref: '$pin'"; then
      # A consumer can retain a poisoned copy after Standards repairs its own
      # record. Refresh only ref:, and only with identical commit and IDs.
      skey=$(lock_key "$u" "$tmp/slock")
      repaired=""; [ -z "$skey" ] || repaired=$(rec_body "$skey" "$tmp/slock")
      symbolic=$(printf '%s\n' "$repaired" | sed -n "s/^        ref: '\([^']*\)'$/\1/p")
      [[ -n "$symbolic" && ! "$symbolic" =~ ^[0-9a-fA-F]{40}$ ]] \
        || refuse "no symbolic repair for $u in target Standards lock"
      local_identity=$(printf '%s\n' "$existing" | grep -E '^        (commit|owner_id|repo_id):' || true)
      source_identity=$(printf '%s\n' "$repaired" | grep -E '^        (commit|owner_id|repo_id):' || true)
      [[ "$local_identity" == "$source_identity" \
        && "$(printf '%s\n' "$source_identity" | wc -l)" -eq 3 ]] \
        || refuse "identity mismatch while repairing $u"
      awk -v k="    '$key':" -v replacement="        ref: '$symbolic'" '
        $0 == k { selected = 1; print; next }
        /^    [^ ]/ { selected = 0 }
        selected && /^        ref:/ { print replacement; next }
        { print }
      ' "$tmp/lock" > "$tmp/repaired.lock"
      mv "$tmp/repaired.lock" "$tmp/lock"
    fi
    continue
  fi
  skey=$(lock_key "$u" "$tmp/slock")
  r=""; [ -z "$skey" ] || r=$(rec_body "$skey" "$tmp/slock")
  [ -n "$r" ] || refuse "no record for $u in this lock or in standards' own lock at ${TARGET:0:12}"
  printf '%s\n' "$r" >> "$tmp/lock"
done < "$tmp/uses.s"

# Prune candidates nothing references any more (to a fixed point).
# deps_line FILE — print the one-based line number of each exact dependencies:
# header. Returns non-zero if no header is found or the file cannot be read.
deps_line() { grep -n '^dependencies:$' "$1" | cut -d: -f1; }
while :; do
  n=$(deps_line "$tmp/lock")
  grep -oE "^ {8,12}- '[^']+'" "$tmp/lock" | sed -E "s/^ +- '|'$//g" | fold | LC_ALL=C sort -u > "$tmp/edges"
  pruned=0
  while read -r c; do
    [ -n "$c" ] || continue
    printf '%s\n' "$c" | fold | grep -qxFf - "$tmp/edges" && continue
    tail -n +"$((n+1))" "$tmp/lock" > "$tmp/deps"
    c=$(lock_key "$c" "$tmp/deps"); [ -n "$c" ] || continue
    rec_body "$c" "$tmp/lock" | grep -oE "^            - '[^']+'" | sed -E "s/^ +- '|'$//g" >> "$tmp/cand" || true
    awk -v k="    ${q}$c${q}:" '$0==k{s=1;next} s&&/^    [^ ]/{s=0} !s' "$tmp/lock" > "$tmp/l" && mv "$tmp/l" "$tmp/lock"
    pruned=1
  done < <(LC_ALL=C sort -u "$tmp/cand")
  [ "$pruned" = 1 ] || break
done

# Dependency records in C-locale key order (portable awk: tag lines, sort, strip).
n=$(deps_line "$tmp/lock")
head -n "$n" "$tmp/lock" > "$tmp/out"
tail -n +"$((n+1))" "$tmp/lock" \
  | awk -v q="$q" 'index($0, "    " q) == 1 { key = $0 } { printf "%s\t%08d\t%s\n", key, NR, $0 }' \
  | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n | cut -f3- >> "$tmp/out"

# Closure: every ref the lock names must have a record of its own.
n=$(deps_line "$tmp/out")
grep -oE "^ {8,12}- '[^']+'" "$tmp/out" | sed -E "s/^ +- '|'$//g" | fold | LC_ALL=C sort -u > "$tmp/edges"
tail -n +"$((n+1))" "$tmp/out" | grep -oE "^    '[^']+':" | sed -E "s/^    '|':$//g" | fold | LC_ALL=C sort -u > "$tmp/recs"
dangling=$(LC_ALL=C comm -23 "$tmp/edges" "$tmp/recs")
[ -z "$dangling" ] || refuse "result would have dangling edges: ${dangling//$'\n'/ }"

# Each workflow's standards entries must name exactly the refs its pins carry.
# The gates match an entry to a `uses:` by its ref as written, so an entry
# re-keyed to TARGET for a workflow that pins a short ref is a desync they reject.
for w in "${wfs[@]}"; do
  want=$(standards_pins "$w" | sed -E 's#^(hyperpolymath|metadatastician)/standards/.*@#\1/standards@#' | LC_ALL=C sort -u || true)
  have=$(awk -v k="    '.github/workflows/${w##*/}':" '$0==k{f=1;next} f&&!/^        - /{exit} f' "$tmp/out" \
    | grep -oE "'(hyperpolymath|metadatastician)/standards@[0-9a-fA-F]+'" | tr -d "'" | LC_ALL=C sort -u || true)
  [ "$want" = "$have" ] || refuse "${w##*/}: lock entries [${have//$'\n'/ }] would not match its pins [${want//$'\n'/ }]"
done

cat "$tmp/out" > "$L"
echo "relock-standards-pin: $L keyed to ${COORD}@${TARGET:0:12} (from $(echo $oldrefs | sed 's/\([0-9a-f]\{12\}\)[0-9a-f]*/\1/g'))"
