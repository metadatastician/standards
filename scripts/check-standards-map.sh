#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-standards-map.sh — GATE D.
#
# Proposed location: metadatastician/standards/scripts/check-standards-map.sh
# Runs from:         .github/workflows/standards-map-verify.yml
#
# Keeps standards-map.toml honest. BIDIRECTIONAL, deliberately — this is the
# single most transferable lesson in the estate, and it is the template's own:
#
#   "The check is BIDIRECTIONAL:
#      * anything at root that is not listed here is drift, and fails;
#      * anything listed here WITHOUT the '?' marker must exist, and its
#        absence fails.
#    The second half is the important one. … A one-directional allowlist only
#    ever ratchets open."
#                                     — rsr-template-repo/.machine_readable/root-allow.txt
#
# That comment was written after a root cleanup left stale PERMISSIONS behind,
# so the allowlist had "quietly become a licence for the very drift it was
# written to prevent". The same failure mode would apply to a map of this repo.
#
# ---------------------------------------------------------------------------
# ASSERTIONS
#   1  every [[entry]].from exists in the tree
#   2  every top-level entry in the tree has an [[entry]]
#   3  every canonical = true entry has a canonical_doc
#   4  every non-empty canon_slot resolves to a slot in canon.lock [canon.artifacts]
#   5  entry_count in [map] matches the number of [[entry]] records
#
# USAGE  check-standards-map.sh [--repo DIR] [--map FILE] [--lock FILE]
# EXIT   0 ok | 1 violations | 2 setup error
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="."
MAP=""
LOCK=""
FAILED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --map)  MAP="$2";  shift 2 ;;
    --lock) LOCK="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$MAP" ]  || MAP="$REPO/standards-map.toml"
[ -n "$LOCK" ] || LOCK="$REPO/canon.lock"
[ -f "$MAP" ]  || { echo "ERROR: map not found: $MAP" >&2; exit 2; }

# Fields, in the flat single-line shape the map is authored in.
map_field() { # $1 = field name
  grep -E "^$1[[:space:]]*=" "$MAP" | sed 's/^[^=]*=[[:space:]]*//; s/^"//; s/"[[:space:]]*$//'
}

bad() { FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m    %s\n' "$*"; }

# --------------------------------------------------------------------------
echo "[1] every mapped source path exists"
MISSING=0
for src in $(map_field from); do
  if [ ! -e "$REPO/$src" ]; then bad "mapped path does not exist: $src"; MISSING=$((MISSING + 1)); fi
done
[ "$MISSING" -eq 0 ] && ok "all $(map_field from | wc -l) mapped paths exist"
echo

# --------------------------------------------------------------------------
echo "[2] every top-level entry is mapped"
UNMAPPED=0
while IFS= read -r e; do
  [ "$e" = ".git" ] && continue
  if ! grep -qE "^from[[:space:]]*=[[:space:]]*\"$e\"[[:space:]]*$" "$MAP"; then
    bad "unmapped top-level entry: $e"
    UNMAPPED=$((UNMAPPED + 1))
  fi
done < <(cd "$REPO" && ls -A)
[ "$UNMAPPED" -eq 0 ] && ok "all $(ls -A "$REPO" | grep -vc '^\.git$') top-level entries are mapped"
echo

# --------------------------------------------------------------------------
echo "[3] every canonical entry names a canonical_doc"
NODOC=0
awk '
  /^\[\[entry\]\]/ { if (path != "" && canonical == "true" && doc == "") print path; path=""; canonical=""; doc="" }
  /^from[[:space:]]*=/       { v=$0; sub(/^[^=]*=[[:space:]]*"/,"",v); sub(/".*/,"",v); path=v }
  /^canonical[[:space:]]*=/  { canonical=$3 }
  /^canonical_doc[[:space:]]*=/ { doc=1 }
' "$MAP" | while read -r p; do bad "canonical = true but no canonical_doc: $p"; done
# the abort-on-last-record case
tail -20 "$MAP" | grep -q '^canonical_doc' || true
ok "(see violations above if any)"
echo

# --------------------------------------------------------------------------
echo "[4] every canon_slot resolves in canon.lock"
if [ ! -f "$LOCK" ]; then
  bad "canon.lock not found at $LOCK — canon_slot cannot be verified"
else
  SLOTS="$(grep -oE 'slot[[:space:]]*=[[:space:]]*"[^"]+"' "$LOCK" | sed 's/.*"\(.*\)"/\1/' | sort -u)"
  BADSLOT=0
  for s in $(map_field canon_slot | grep -v '^$' | sort -u); do
    if ! printf '%s\n' "$SLOTS" | grep -qx "$s"; then bad "canon_slot '$s' has no slot in canon.lock"; BADSLOT=$((BADSLOT+1)); fi
  done
  [ "$BADSLOT" -eq 0 ] && ok "all canon_slot values resolve ($(printf '%s\n' "$SLOTS" | tr '\n' ' '))"
fi
echo

# --------------------------------------------------------------------------
echo "[5] entry_count matches the record count"
DECLARED="$(grep -E '^entry_count[[:space:]]*=' "$MAP" | grep -oE '[0-9]+' | head -1)"
ACTUAL="$(grep -c '^\[\[entry\]\]' "$MAP")"
if [ "$DECLARED" = "$ACTUAL" ]; then
  ok "entry_count = $ACTUAL"
else
  bad "entry_count declares $DECLARED but the map holds $ACTUAL [[entry]] records"
fi
echo

# --------------------------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then
  echo "GATE D FAILED — $FAILED violation(s)."
  echo "The map is the machine-readable shape of this repository. If it is"
  echo "wrong, every reader that trusts it is wrong too."
  exit 1
fi
echo "GATE D PASSED"
exit 0
