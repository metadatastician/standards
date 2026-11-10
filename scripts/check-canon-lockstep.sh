#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-canon-lockstep.sh — GATE A.
#
# Proposed location: hyperpolymath/standards/scripts/check-canon-lockstep.sh
# Runs from:         .github/workflows/canon-spine-lockstep.yml
#
# This is the gate that makes `standards` BOUND BY `rsr-template-repo`.
#
# ---------------------------------------------------------------------------
# WHAT IT ENFORCES
#
#   HARD (always):
#   1  every sha256 in canon.lock [canon.artifacts] matches the working tree
#   2  touching a canon artefact forces a version bump
#
#   INFORMATIONAL unless --strict:
#   3  the spine deed (canon …) clause == canon.lock version + criteria + gates
#   4  the spine is GREEN against those criteria
#   5  the canon itself scores Gold on its own applicable set
#
#   See softfail() for why 3/4/5 must not be hard by default.
#
# Assertion 4 is the load-bearing one, and it is a deliberate reversal:
#
#     YOU MAY NOT TIGHTEN THE CRITERIA UNTIL THE REFERENCE IMPLEMENTATION
#     PASSES THEM.
#
# ---------------------------------------------------------------------------
# USAGE
#   check-canon-lockstep.sh [--canon DIR] [--spine DIR] [--base REF] [--strict]
#
#   --canon DIR   path to hyperpolymath/standards   (default: .)
#   --spine DIR   path to a cloned rsr-template-repo
#   --base REF    the ref to diff against for assertion 2 (default: origin/main)
#   --strict      promote assertions 3/4/5 from SKIP to FAIL
#
# EXIT
#   0  all enabled assertions passed
#   1  at least one assertion failed
#   2  setup error (missing file, unresolvable ref)
#
# DEPENDENCIES
#   bash        (no python - estate policy: see docs/JS-RUNTIME-POLICY.adoc,
#                NO-JAVASCRIPT-SOURCE-POLICY.adoc; bash + awk + git only)
#   awk, git, sha256sum, grep
# ---------------------------------------------------------------------------
set -uo pipefail

CANON="."
SPINE=""
BASE_REF="origin/main"
STRICT=0
FAILED=0
PASSED=0
SKIPPED=0
NOT_VERIFIED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --canon)  CANON="$2";    shift 2 ;;
    --spine)  SPINE="$2";    shift 2 ;;
    --base)   BASE_REF="$2"; shift 2 ;;
    --strict) STRICT=1;      shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

pass() { PASSED=$((PASSED + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
# skip()   — the check could not be RUN (missing tool, missing argument).
#            Always informational. --strict MUST NOT promote this: an absent
#            tool is not a lockstep deviation, and promoting it makes --strict
#            permanently red in any environment without `gh`/`hypatia`, which
#            trains people to ignore it.
skip() {
  SKIPPED=$((SKIPPED + 1))
  NOT_VERIFIED="$NOT_VERIFIED\n    - $*"
  printf '  \033[33mSKIP\033[0m  %s\n' "$*"
}

# Assertions 3, 4 and 5 are INFORMATIONAL unless --strict.
#
# canon.lock [canon.lockstep].order is "spine-adopts-then-canon-releases". The
# spine's adoption pins hashes that exist only in the unmerged canon PR, so the
# order needs a pending state: two-phase lockstep (1-formats/deed/vocabulary/
# canon.adoc, "Two-phase adoption"). The spine pins this PR's canon.lock and
# names it with :proposed-by; its own Canon lockstep accepts that while the PR
# is open. So canon-spine-lockstep.yml runs --strict on every pull request and
# push: a canon PR that changes canon.lock is not mergeable until the spine's
# main pins it. (Before 2026-11-09 CI ran this non-strict, because spine-first
# had no legal state; the canon then released ahead of the spine and turned it
# red, as #1424 did.) Without --strict, 3/4/5 stay informational for local use.
#
# softfail() — a REAL deviation. Promoted to a failure by --strict.
softfail() {
  if [ "$STRICT" -eq 1 ]; then fail "$*"
  else SKIPPED=$((SKIPPED + 1)); printf '  \033[33mINFO\033[0m  %s\n' "$*"; fi
}

LOCK="$CANON/canon.lock"
# Repo-relative twin of $LOCK. Assertion 2 passes the lock to `git diff`, whose
# pathspecs resolve against the repository root, not the filesystem: with
# --canon canon the pathspec "canon/canon.lock" matched nothing, `git diff
# --quiet` therefore reported "no change", and the gate accused a PR that had
# in fact bumped the lock of not bumping it.
LOCK_REL="${LOCK#"$CANON"/}"
[ -f "$LOCK" ] || { echo "ERROR: canon.lock not found at $LOCK" >&2; exit 2; }

# ---------------------------------------------------------------------------
# A minimal TOML reader. The estate mandates bash+awk (no Python, no Deno),
# and canon.lock is authored in a deliberately flat, single-line shape so that
# this is sufficient. This is the same discipline template-capability-gates.toml
# already imposes on itself ("Arrays are kept single-line so the checker can
# parse them with grep").
# ---------------------------------------------------------------------------

# toml_get <section> <key>   -> last assignment wins, comments stripped
toml_get() {
  awk -v want="[$1]" -v key="$2" '
    /^[[:space:]]*\[/ { cur=$0; gsub(/[[:space:]]/,"",cur); next }
    cur == want {
      line=$0; sub(/#.*/,"",line)
      if (line ~ "^[[:space:]]*"key"[[:space:]]*=") {
        sub(/^[^=]*=[[:space:]]*/,"",line); gsub(/[[:space:]]*$/,"",line)
        gsub(/^"|"$/,"",line); v=line
      }
    }
    END { if (v != "") print v }
  ' "$LOCK"
}

# The artefact records are inline tables that may SPAN LINES, e.g.
#
#   criteria = { path = "0-canon/rsr/rsr-criteria-v2.a2ml",   # from spec/
#                sha256 = "efd024ad…",
#                slot = "criteria", normative = true }
#
# so both readers below accumulate a record: they open on `<slot> = {`, take
# every line until the closing `}` (or a line that does not continue the
# record), strip comments, and join. Same problem, and the same solution, as
# check-rsr-profile.sh's array_on_key().
record() { # $1 = key name (criteria|gates|applicability|lifecycle|constitution)
  awk -v slot="$1" '
    /^[[:space:]]*#/ { next }
    $0 ~ "^[[:space:]]*" slot "[[:space:]]*=[[:space:]]*\\{" { on=1 }
    on {
      line=$0; sub(/#.*/, "", line); rec = rec " " line
      if (line ~ /}/) { on=0 }
    }
    END { sub(/^[[:space:]]*/, "", rec); print rec }
  ' "$LOCK"
}

# toml_hash <slot> -> sha256 from that record
toml_hash() {
  record "$1" | grep -oE 'sha256[[:space:]]*=[[:space:]]*"[0-9a-f]{64}"' \
             | grep -oE '[0-9a-f]{64}' | head -1
}

# toml_path <slot> -> path from that record
toml_path() {
  record "$1" | grep -oE 'path[[:space:]]*=[[:space:]]*"[^"]+"' \
             | sed 's/.*"\(.*\)"/\1/' | head -1
}

# sha256 of a path: file -> plain hash; directory -> git-ls-files method,
# matching the registry's own source_hash definition.
hash_path() {
  # $1 is a FILESYSTEM path, e.g. "$CANON/constitution/". Git pathspecs are
  # resolved relative to the repository root and know nothing about the
  # --canon prefix, so handing git "$CANON/constitution/" matched NOTHING;
  # `git ls-files` printed nothing and sha256sum faithfully hashed the EMPTY
  # stream — a plausible-looking digest for a directory that was never read.
  #
  # That is exactly why this gate reported "passed 8 failed 0 GATE A PASSED"
  # locally (invoked as `--canon .`, where "./constitution/" happens to match)
  # and "passed 6 failed 2 GATE A FAILED" in CI (invoked as `--canon canon`).
  # The verdict depended on the SPELLING of the argument, not on the repository.
  #
  # Two changes: strip the prefix before handing the path to git, and refuse to
  # hash an empty listing, so a wrong pathspec can never again look like a hash.
  local p="$1" rel="${1#"$CANON"/}"
  if [ -d "$p" ]; then
    local listing
    listing="$( cd "$CANON" && git ls-files -s -- "$rel" )"
    if [ -z "$listing" ]; then
      echo "  ERROR: git ls-files matched no files for '$rel' in $CANON" >&2
      return 1
    fi
    printf '%s\n' "$listing" | sha256sum | cut -d' ' -f1
  else
    sha256sum "$p" | cut -d' ' -f1
  fi
}

CANON_VERSION="$(toml_get canon version)"
echo "canon.lock: version=$CANON_VERSION  lock=$(sha256sum "$LOCK" | cut -d' ' -f1 | cut -c1-12)…"
echo

# ===========================================================================
# ASSERTION 1 — declared hashes match the working tree
# ===========================================================================
echo "[1] canon artefact hashes match the working tree"
for slot in criteria gates applicability lifecycle constitution; do
  want="$(toml_hash "$slot")"
  path="$(toml_path "$slot")"
  if [ -z "$want" ] || [ -z "$path" ]; then softfail "$slot: declared in [canon.artifacts] with no path/hash, or absent"; continue; fi
  if [ ! -e "$CANON/$path" ]; then
    fail "$slot: declared path does not exist: $path"
    continue
  fi
  if ! got="$(hash_path "$CANON/$path")"; then
    fail "$slot: could not hash '$path' — see the error above"
    continue
  fi
  if [ "$want" = "$got" ]; then
    pass "$slot  ${path}  $(echo "$got" | cut -c1-12)…"
  else
    fail "$slot  ${path}
         declared $(echo "$want" | cut -c1-16)…
         actual   $(echo "$got"  | cut -c1-16)…
         -> the law changed without re-releasing canon.lock (bump version + rewrite hash)"
  fi
done
echo

# ===========================================================================
# ASSERTION 2 — a canon artefact change forces a version bump
# ===========================================================================
echo "[2] canon artefact change forces a version bump"
if git -C "$CANON" rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1; then
  CHANGED=""
  for slot in criteria gates applicability lifecycle constitution; do
    p="$(toml_path "$slot")"; [ -n "$p" ] || continue
    if ! git -C "$CANON" diff --quiet "$BASE_REF"...HEAD -- "$p" 2>/dev/null; then
      CHANGED="$CHANGED $slot"
    fi
  done
  if [ -z "$CHANGED" ]; then
    pass "no canon artefact changed against $BASE_REF"
  elif ! git -C "$CANON" diff --quiet "$BASE_REF"...HEAD -- "$LOCK_REL" 2>/dev/null; then
    pass "canon artefacts changed ($CHANGED ) and canon.lock was bumped in the same PR"
  else
    fail "canon artefacts changed ($CHANGED ) but canon.lock is untouched
         -> any change to a file named in [canon.artifacts] is a CANON CHANGE.
            Bump [canon].version and rewrite the hash in the SAME commit."
  fi
else
  skip "cannot resolve $BASE_REF in $CANON"
fi
echo

# ===========================================================================
# ASSERTION 3 — the spine has adopted this canon
# ===========================================================================
# The pin's home is the spine deed's `(canon …)` clause
# (1-formats/deed/vocabulary/canon.adoc). It moved there from
# rsr-profile.a2ml [canon] because D43 freezes .a2ml writes, so that block
# could not follow a canon release (rsr-template-repo#215). The a2ml is still
# read as a LEGACY fallback, criteria only, so this gate keeps working against
# a spine that has not adopted the deed clause yet. Delete the fallback once
# no spine checkout lacks the clause.

# deed_canon <key> <deed-file>: print the value of :<key> from the
# deed's one (canon …) clause, or nothing when the clause or key is
# absent or the clause is not unique. A ";" outside a string starts a
# comment that runs to line-end (deed.abnf), whole-line or inline. The SAME function is in
# rsr-template-repo .github/workflows/dogfood-gate.yml and
# build/just/repo-init.just; keep the three identical.
deed_canon() {
    _clauses="$(awk 'BEGIN { bs = sprintf("%c", 92); dq = sprintf("%c", 34) } { o = ""; q = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (q && c == bs) { o = o c substr($0, i + 1, 1); i++; continue } if (c == dq) q = !q; else if (!q && c == ";") break; o = o c } printf "%s ", o }' "$2" | grep -oE '[(]canon[[:space:]][^()]*[)]')" || true
    _n="$(echo "$_clauses" | grep -c '(canon' || true)"
    if [ "$_n" != "1" ]; then
        echo "deed_canon: $2 carries ${_n:-0} (canon …) clauses, need exactly 1" >&2
        return 0
    fi
    echo "$_clauses" | grep -oE ':'"$1"'[[:space:]]+"[^"]*"' | head -1 | sed -E 's/^[^"]*"//; s/"$//' || true
}

# pin_row <name> <want> <got> <shape-regex>: compare one pin. A value of the
# wrong shape is a failure, never a pass: "" = "" is not lockstep.
pin_row() {
  if ! printf '%s' "$3" | grep -qxE "$4"; then
    softfail "spine deed :$1 is not well-formed (got '${3}')"
  elif ! printf '%s' "$2" | grep -qxE "$4"; then
    softfail "canon.lock $1 is not well-formed (got '${2}')"
  elif [ "$2" = "$3" ]; then
    pass "spine :$1 == canon.lock ($(echo "$3" | cut -c1-12)…)"
  else
    softfail "spine is on a DIFFERENT canon ($1)
         canon.lock  $(echo "$2" | cut -c1-16)…
         spine       $(echo "$3" | cut -c1-16)…
         -> adopt it in the spine FIRST: pin this canon.lock in the spine
            deed's (canon …) clause, name this canon PR with :proposed-by,
            merge that, then re-run this gate (canon.adoc, two-phase)."
  fi
}

# has_canon_clause <deed>: true when a non-comment line opens a (canon …)
# clause. One awk process, no pipe: `grep -v … | grep -q` under pipefail
# reported a large deed as having no clause, because grep -q exits at the
# first match and the writer's SIGPIPE made the pipeline false (CI read the
# 1114-line spine deed that way).
has_canon_clause() {
  awk 'BEGIN { bs = sprintf("%c", 92); dq = sprintf("%c", 34) } { o = ""; q = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (q && c == bs) { i++; continue } if (c == dq) { q = !q; o = o " "; continue } if (!q && c == ";") break; if (!q) o = o c } if (o ~ /[(]canon([[:space:]]|$)/) { found = 1; exit } } END { exit !found }' "$1"
}

echo "[3] spine declares the same canon pin"
if [ -z "$SPINE" ] || [ ! -d "$SPINE" ]; then
  skip "no --spine DIR given (set --strict in CI release jobs)"
else
  DEEDS=()
  for d in "$SPINE"/*_chora.deed; do [ -f "$d" ] && DEEDS+=("$d"); done
  HEX='[0-9a-f]{64}'
  if [ "${#DEEDS[@]}" -gt 1 ]; then
    softfail "spine carries ${#DEEDS[@]} *_chora.deed files; one-deed-per-repo (#837) expects exactly 1"
  elif [ "${#DEEDS[@]}" -eq 1 ] && has_canon_clause "${DEEDS[0]}"; then
    DEED="${DEEDS[0]}"
    echo "  reading $(basename "$DEED") (canon …)"
    pin_row version         "$CANON_VERSION"        "$(deed_canon version "$DEED")"         '[0-9]+\.[0-9]+\.[0-9]+'
    pin_row criteria-sha256 "$(toml_hash criteria)" "$(deed_canon criteria-sha256 "$DEED")" "$HEX"
    pin_row gates-sha256    "$(toml_hash gates)"    "$(deed_canon gates-sha256 "$DEED")"    "$HEX"
  else
    PROFILE="$SPINE/.machine_readable/rsr-profile.a2ml"
    # Hyphenated is the minority spelling, not a rejected one: this branch stays so
    # the ~9 repos still carrying it keep resolving.
    [ -f "$PROFILE" ] || PROFILE="$SPINE/machine-readable/rsr-profile.a2ml"
    if [ ! -f "$PROFILE" ]; then
      softfail "spine has no (canon …) deed clause and no rsr-profile.a2ml"
    else
      echo "  LEGACY: no (canon …) deed clause; reading rsr-profile.a2ml [canon] criteria only"
      GOT="$(grep -E '^[[:space:]]*criteria_sha256[[:space:]]*=' "$PROFILE" \
             | grep -oE "$HEX" | head -1)"
      if [ -z "$GOT" ]; then
        softfail "spine rsr-profile.a2ml has no [canon] criteria_sha256
         -> the spine still declares conformance in free text. The binding
            does not exist until this is a hash."
      else
        pin_row criteria-sha256 "$(toml_hash criteria)" "$GOT" "$HEX"
      fi
    fi
  fi
fi
echo

# ===========================================================================
# ASSERTION 4 — the reference implementation passes the criteria
# ===========================================================================
echo "[4] the spine is GREEN against these criteria"
if [ -z "$SPINE" ] || [ ! -d "$SPINE" ]; then
  skip "no --spine DIR given"
elif ! command -v gh >/dev/null 2>&1; then
  skip "gh not available; cannot read the spine's last dogfood-gate conclusion"
else
  # The oracle is hypatia's rsr-conformance family. Until it is implemented
  # (rsr-criteria-v2.a2ml [oracle] marks it "to be implemented"), the closest
  # available proxy is the spine's own dogfood-gate run. This assertion is
  # written against the PROXY and must be repointed when the oracle lands.
  SHA="$(git -C "$SPINE" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$SHA" ]; then
    skip "cannot resolve spine HEAD"
  else
    RC="$(gh run list --repo hyperpolymath/rsr-template-repo \
            --workflow dogfood-gate.yml --commit "$SHA" \
            --json conclusion --jq '.[0].conclusion' 2>/dev/null || true)"
    case "$RC" in
      success) pass "dogfood-gate is green at spine@$(echo "$SHA" | cut -c1-7)"
               ;;
      "")      skip "no dogfood-gate run found for spine@$(echo "$SHA" | cut -c1-7)"
               ;;
      *)       fail "dogfood-gate is '$RC' at spine@$(echo "$SHA" | cut -c1-7)
         -> THE REVERSAL: you may not tighten the criteria until the reference
            implementation passes them. Fix the spine, or revert this canon change." ;;
    esac
  fi
fi
echo

# ===========================================================================
# ASSERTION 5 — the canon satisfies its own law
# ===========================================================================
echo "[5] the canon scores Gold on its own applicable set"
# The canonical machine tree is `.machine_readable/`. This comment previously
# said the opposite — that the dotted form was "LEGACY" and tolerating it was a
# temporary shim. That was backwards. The census recorded in rsr-template-repo's
# docs/governance/TEMPLATE-LINEAGE-AUDIT.adoc at the 2026-08 divergence is 48
# repositories on the dotted form against 9 on the hyphenated one, and the
# "~300 minted repos" this comment used to cite as the reason for tolerating
# dotted are that same majority.
#
# So both branches below are permanent, not a shim. Dotted is canonical;
# hyphenated must still RESOLVE, never be rejected — a repo pinned to the
# minority spelling is not a repo with a broken gate.
# The canon's profile is resolved by the resolver it ships, so both carriers
# count exactly as they do for every other repo: the (rsr-profile …) clause of
# standards_chora.deed (where it has lived since 2026-11-05), or a legacy
# rsr-profile.a2ml. Reading the .a2ml here directly would make this assertion
# a second, divergent reader.
CANON_RESOLVED="$(bash "$CANON/scripts/check-rsr-profile.sh" "$CANON" 2>&1 || true)"
if ! grep -q '^effective capabilities:' <<<"$CANON_RESOLVED"; then
  softfail "the canon's rsr-profile could not be resolved — it cannot be scored by
       the checker it ships (scripts/check-rsr-profile.sh $(grep -m1 'ERROR' <<<"$CANON_RESOLVED" || echo 'printed no effective capabilities')).
       -> declare it in the (rsr-profile …) clause of standards_chora.deed;
          role \"canon\" needs [canon] in the gate table."
else
  ROLE="$(sed -n 's/^role:[[:space:]]*//p' <<<"$CANON_RESOLVED" | head -1)"
  [ "$ROLE" = unset ] && ROLE=""
  [ "$ROLE" = "canon" ] || softfail "canon rsr-profile role is '${ROLE:-unset}', expected 'canon'"
  [ "$ROLE" = "canon" ] && pass "canon rsr-profile declares role = \"canon\""

  if command -v mix >/dev/null 2>&1 && [ -d "$CANON/../hypatia" ]; then
    # mix hypatia.rsr_score reads the applicable set from the profile and emits
    # a scorecard. Exit 0 = at or above the required tier.
    if ( cd "$CANON/../hypatia" && mix hypatia.rsr_score "$CANON" --require gold ) >/dev/null 2>&1; then
      pass "hypatia rsr-conformance: canon is at Gold"
    else
      fail "hypatia rsr-conformance: canon is BELOW Gold on its applicable set"
    fi
  else
    skip "hypatia (the one normative oracle) not available; oracle is marked 'to be implemented'"
  fi
fi
echo

# ===========================================================================
echo "─────────────────────────────────────────────────────────────"
printf 'passed %d   failed %d   skipped %d\n' "$PASSED" "$FAILED" "$SKIPPED"
if [ -n "$NOT_VERIFIED" ]; then
  printf '\n\033[33mNOT VERIFIED\033[0m (these assertions did not run — a green result is NOT a full verification):'
  printf "$NOT_VERIFIED\n"
fi
if [ "$FAILED" -gt 0 ]; then
  echo
  echo "GATE A FAILED — the canon and the spine are not in lockstep."
  echo "This is not necessarily a bad change. It is very often a change made"
  echo "in the wrong ORDER. See [canon.lockstep].order in canon.lock:"
  echo "    spine-adopts-then-canon-releases"
  exit 1
fi
echo "GATE A PASSED"
exit 0
