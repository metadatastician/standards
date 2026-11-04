#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-exemption-ratchet.sh — exemption ledgers may SHRINK, never grow silently.
#
# WHY THIS EXISTS
# ---------------
# Every large CI failure this estate has diagnosed shares one shape: an
# exemption was added quietly and then never removed. The 2026-08-06 audit
# found, among 424 repositories:
#
#   * a gitleaks gate that had run with NO allowlist for months, then acquired
#     one, with nothing preventing that allowlist from growing to cover a real
#     secret later;
#   * 13,206 banned-language files, most of them declared once and forgotten;
#   * a `.hypatia-baseline.json` that absorbed 255 findings in a single commit,
#     converting a library's central guarantee into accepted debt;
#   * exemption files written in the WRONG FORMAT (hyperpolymath/proven) that
#     therefore suppressed nothing — nobody noticed for months, because a
#     suppression that does not work is silent in exactly the same way as one
#     that does.
#
# A gate that only checks the CURRENT state cannot catch any of that: each
# individual state is "valid". What matters is the DIRECTION OF TRAVEL. This
# check compares the pull request against its base and enforces:
#
#   1. NO SILENT GROWTH.       An exemption ledger may lose entries freely.
#                              Gaining entries requires an explicit, reviewed
#                              declaration in the commit message.
#   2. NO NEW ANONYMOUS DEBT.  Every new or changed .hypatia-baseline.json
#                              entry must carry a `note` or a `tracking_issue`.
#                              Legacy anonymous entries are tolerated only
#                              while identical as complete JSON values;
#                              touching one requires documenting it.
#   3. NO WILDCARD LEDGERS.    A `**` pattern in a banned-language ledger
#                              silently absorbs files added later, which turns
#                              a migration ledger into a permanent blind spot.
#                              Architectural exemptions may use patterns — in
#                              .hypatia-baseline.json, where a note explains
#                              them — but the migration ledger may not.
#
# THE ESCAPE HATCH IS DELIBERATE AND LOUD. Growth is sometimes correct: a
# newly vendored dependency, a newly discovered architectural boundary. To
# allow it, put a line in the commit message:
#
#     Ratchet-exception: <why this ledger must grow>
#
# That makes adding debt possible, attributable and reviewable — which is the
# whole point. A gate nobody can satisfy gets deleted; a gate that costs one
# honest sentence gets obeyed.
#
# EXIT CODES
#   0  ledgers shrank, held steady, or grew with a declared exception
#   1  a ledger grew without one, or an entry is anonymous, or a wildcard
#      appeared in a migration ledger
#   2  invalid invocation or unreadable input
set -euo pipefail

BASE_REF="${1:-}"
# How far out an acknowledgement may be dated. Long enough for a real migration
# window, short enough that every ack is re-read at least annually.
HORIZON_DAYS="${RATCHET_HORIZON_DAYS:-366}"
if [ -z "$BASE_REF" ]; then
  echo "usage: check-exemption-ratchet.sh <base-ref>" >&2
  exit 2
fi

fail=0

# Entry counting for TOML ledgers lives in a sibling script — see
# count-ledger-entries.sh for why it is not inlined. The workflow stages both
# files together. Overridable for testing; unset is a hard error at use, never
# a silent zero.
COUNTER="${COUNTER:-$(dirname "$0")/count-ledger-entries.sh}"
note() { printf '  %s\n' "$*"; }

# Count entries in a ledger at a given ref. Counting is per-format, because
# "lines" is wrong for JSON and "entries" is wrong for a text ledger.
count_at() {
  local ref="$1" path="$2"
  local blob
  blob="$(git show "${ref}:${path}" 2>/dev/null || true)"
  [ -z "$blob" ] && { echo 0; return; }
  case "$path" in
    *.json)
      printf '%s' "$blob" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0 ;;
    *.toml)
      # ⚠ ENTRY counting, not line counting — see count-ledger-entries.sh for
      # why, and for why it is a separate file rather than an inline
      # `python3 -c`. There is deliberately no `|| echo 0`: a counter that
      # cannot run must FAIL the check, because a count of 0 is
      # indistinguishable from an empty ledger, and empty is what passes.
      printf '%s' "$blob" | "${COUNTER:?COUNTER must point at count-ledger-entries.sh}" ;;
    *)
      # Comments and blank lines are not exemptions.
      #
      # ⚠ `|| true` is LOAD-BEARING. grep exits 1 when nothing matches, which is
      # exactly what a comments-only ledger produces — a perfectly legitimate
      # state, and the one a repository reaches when it finishes paying its debt
      # down. Under `set -euo pipefail` that exit propagated and killed the
      # script mid-report: it printed the first ledger's line, then exited 1
      # with no verdict at all. Exit 1 means "ratchet FAILED", so a repo that
      # had cleared its ledger would be reported as violating the ratchet, with
      # no reason given and nothing to fix. Regression reported on 2026-08-06:
      # https://github.com/hyperpolymath/standards/pull/588#discussion_r3731377032
      # Keep the no-match case successful so the gate reports its actual verdict.
      printf '%s' "$blob" | { grep -vEc '^\s*(#|$)' || true; } | tr -d ' \n' ;;
  esac
}

# Does the pull request declare that a SPECIFIC ledger must grow?
#
# ⚠ The declaration names its ledger. A single bare `Ratchet-exception:` used
# to license growth in ALL FOUR ledgers at once — so a PR that legitimately
# needed to add one gitleaks path also silently gained permission to grow the
# Hypatia baseline, the migration ledger and the root allowlist. The whole
# point is that each addition is seen; a blanket permit defeats it.
#
# Accepted forms:
#     Ratchet-exception: <ledger path> — <why>
#     Ratchet-exception(<ledger path>): <why>
# A declaration naming no known ledger is rejected rather than treated as
# blanket permission, because "unparseable" must never mean "allowed".
# Does the pull request declare that a SPECIFIC ledger may change?
# Checks both commit messages (for non-squash merges) and PR body (for squash merges
# where commit messages are lost).
declared_for() {
  local ledger="$1" msgs
  msgs="$(git log --format=%B "${BASE_REF}..HEAD" 2>/dev/null || true)"
  
  # Check commit messages
  if printf '%s' "$msgs" | grep -iE '^Ratchet-exception' | grep -qF "$ledger"; then
    return 0
  fi
  
  # Also check PR body if available (for squash merges where commit messages are discarded)
  if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
    local pr_body
    pr_body="$(jq -r '.pull_request.body // ""' "${GITHUB_EVENT_PATH}" 2>/dev/null || true)"
    if printf '%s' "$pr_body" | grep -iE '^Ratchet-exception' | grep -qF "$ledger"; then
      return 0
    fi
  fi
  
  return 1
}

LEDGERS=(
  ".hypatia-baseline.json"
  ".hypatia-ignore"
  ".gitleaks.toml"
  # `.machine_readable/root-allow.txt` was listed here while the file did not
  # exist in this repository (#908). count_at then returned 0 at base and 0 at
  # HEAD, so the entry could never fire: a five-line ledger entry that read as
  # a control and was not one. Root drift in this repo is covered by
  # standards-map.toml (scripts/check-standards-map.sh), which is bidirectional
  # and fails on an unlisted path. The ledger belongs to rsr-template-repo,
  # where the file exists; if this repo ever adopts one, add the entry back in
  # the same commit that creates the file.
  ".machine_readable/lock-allow.txt"
  ".machine_readable/pipeline-allow.txt"
  # The K9 debt ledger (1-formats/k9/tools/CONFORMANCE-REPORTING.adoc): the
  # k9-conformance lane also refuses an undeclared addition on its own.
  ".machine_readable/k9-contract-debt.txt"
  # The legacy A2ML ledger (scripts/check-a2ml-archived.sh): the live A2ML files
  # still waiting for kyX or an owner ruling. Every entry leaves when its file
  # is archived or translated; nothing joins it.
  ".machine_readable/a2ml-legacy-allow.txt"
)

echo "Exemption ratchet — comparing against ${BASE_REF}"
for path in "${LEDGERS[@]}"; do
  before="$(count_at "$BASE_REF" "$path")"
  after="$(count_at "HEAD" "$path")"
  [ "$before" = "0" ] && [ "$after" = "0" ] && continue
  if [ "$after" -gt "$before" ]; then
    if declared_for "$path"; then
      note "OK (declared)  ${path}: ${before} -> ${after}  [Ratchet-exception present]"
    else
      note "GREW           ${path}: ${before} -> ${after}"
      fail=1
    fi
  elif [ "$after" -lt "$before" ]; then
    note "SHRANK         ${path}: ${before} -> ${after}  <- debt paid down"
  else
    note "unchanged      ${path}: ${before}"
  fi
done

# 2. No new or changed anonymous baseline entries.
#
# This is deliberately a ratchet, not an instantaneous cleanliness gate. A
# repository may already have anonymous legacy entries when it adopts the
# shared workflow. Failing every unrelated PR until all of that historic debt
# is documented makes the gate impossible to introduce and encourages blanket
# bypasses. Instead, compare complete JSON values as a multiset:
#
#   * an unchanged anonymous value is grandfathered;
#   * adding an anonymous value fails;
#   * changing any field on an anonymous value fails (the old value vanished
#     and a new undocumented value appeared);
#   * adding a note/tracking_issue, or deleting an entry, is debt reduction and
#     passes;
#   * duplicate values are counted, so appending a second identical anonymous
#     entry cannot hide behind one grandfathered copy.
if [ -f .hypatia-baseline.json ]; then
  base_baseline="$(mktemp)"
  trap 'rm -f "$base_baseline"' EXIT
  if git cat-file -e "${BASE_REF}:.hypatia-baseline.json" 2>/dev/null; then
    git show "${BASE_REF}:.hypatia-baseline.json" > "$base_baseline"
  else
    printf '[]\n' > "$base_baseline"
  fi

  anon_delta="$(jq -n \
    --slurpfile before "$base_baseline" \
    --slurpfile after .hypatia-baseline.json '
      def anonymous:
        (has("note") | not) and (has("tracking_issue") | not);

      ($before[0]) as $base
      | ($after[0]) as $head
      | if (($base | type) != "array" or ($head | type) != "array") then
          error(".hypatia-baseline.json must contain a JSON array at base and HEAD")
        else
          ([ $base[] | select(anonymous) ]
            | group_by(.)
            | map({entry: .[0], count: length})) as $base_groups
          | ([ $head[] | select(anonymous) ]
            | group_by(.)
            | map({entry: .[0], count: length})) as $head_groups
          | [ $head_groups[] as $new
              | (($base_groups
                  | map(select(.entry == $new.entry) | .count)
                  | first) // 0) as $old_count
              | select($new.count > $old_count)
              | {entry: $new.entry, added: ($new.count - $old_count)} ]
        end
    ')"
  rm -f "$base_baseline"
  trap - EXIT

  anon="$(printf '%s\n' "$anon_delta" | jq '[.[].added] | add // 0')"
  if [ "${anon:-0}" -gt 0 ]; then
    note "ANONYMOUS      .hypatia-baseline.json: ${anon} new or changed entr(y|ies) carry neither a note nor a tracking_issue"
    printf '%s\n' "$anon_delta" | jq -r \
      '.[] | "                 \(.added)x \(.entry | tojson)"'
    note "               Every exemption touched now must say what it is. Add \`note\` explaining"
    note "               what the finding actually is, or \`tracking_issue\` naming the"
    note "               work that discharges it."
    fail=1
  fi
fi

# 2b. NO NEW UNDATED DEBT.
# An acknowledgement with no `expires_at` is a decision nobody will revisit:
# apply-baseline.sh can only tighten a gate on a date, so an undated entry
# suppresses its finding for as long as the file exists. Measured 2026-10-24
# in this repository: 63 entries, 23 undated, 7 of them literally "Baseline
# permanently".
#
# The rule applies to NEW OR CHANGED entries only, using the same multiset-of-
# complete-values comparison as 2 above. Requiring a date from every entry
# would fail every other repository in the estate on its next pull request —
# a gate that cannot be satisfied gets deleted, and this one costs one date.
# Existing undated entries are grandfathered while byte-identical; touching one
# (including to re-ack it) means dating it.
#
# A date is not a formality here. It is checked for shape, for being in the
# future, and for being inside the horizon: an ack dated 2199 delegates the
# decision to nobody in particular, which is the undated case wearing a date.
if [ -f .hypatia-baseline.json ]; then
  ratchet_base="$(mktemp)"
  trap 'rm -f "$ratchet_base"' EXIT
  if git cat-file -e "${BASE_REF}:.hypatia-baseline.json" 2>/dev/null; then
    git show "${BASE_REF}:.hypatia-baseline.json" > "$ratchet_base"
  else
    printf '[]\n' > "$ratchet_base"
  fi

  undated_delta="$(jq -n \
    --slurpfile before "$ratchet_base" \
    --slurpfile after .hypatia-baseline.json \
    --arg today "$(date -u +%Y-%m-%d)" \
    --argjson horizon "$HORIZON_DAYS" '
      ($today | strptime("%Y-%m-%d") | mktime) as $now
      | def day_diff: ((. | strptime("%Y-%m-%d") | mktime) - $now) / 86400 | floor;
      def verify:
        if (has("expires_at") | not) then "no expires_at"
        elif ((.expires_at | type) != "string") then "expires_at is not a string"
        elif (.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)
          then "expires_at is not YYYY-MM-DD"
        else
          (.expires_at | day_diff) as $d
          | if $d < 0 then "expired on \(.expires_at) — re-acking means a new date, not the old one"
            elif $d > $horizon then "expires_at \(.expires_at) is \($d) days out (horizon: \($horizon)) — that defers the decision rather than dating it"
            else null end
        end;

      ($before[0]) as $base
      | ($after[0]) as $head
      | if (($base | type) != "array" or ($head | type) != "array") then
          error(".hypatia-baseline.json must contain a JSON array at base and HEAD")
        else
          ([ $base[] ] | group_by(.) | map({entry: .[0], count: length})) as $bg
          | ([ $head[] ] | group_by(.) | map({entry: .[0], count: length})) as $hg
          | [ $hg[] as $new
              | (($bg | map(select(.entry == $new.entry) | .count) | first) // 0) as $old
              | select($new.count > $old)
              | { entry: $new.entry, added: ($new.count - $old) }
              | . + { problem: (.entry | verify) }
              | select(.problem != null) ]
        end
    ')" || {
      note "UNREADABLE     .hypatia-baseline.json could not be compared with $BASE_REF"
      fail=1
      undated_delta="[]"
    }
  rm -f "$ratchet_base"
  trap - EXIT

  bad="$(printf '%s\n' "$undated_delta" | jq 'length' 2>/dev/null || echo 0)"
  if [ "${bad:-0}" -gt 0 ]; then
    note "EXPIRY         .hypatia-baseline.json: ${bad} new or changed entr(y|ies) have no usable expires_at"
    printf '%s\n' "$undated_delta" | jq -r \
      '.[] | "                 \(.problem)\n                   \(.entry.rule_module)/\(.entry.type) @ \(.entry.file // .entry.file_pattern // "?")"'
    note "               Every acknowledgement now must date itself. Pick a date you"
    note "               expect to be able to defend the finding until — the horizon is"
    note "               ${HORIZON_DAYS} days — and put what you checked in \`note\`."
    fail=1
  fi
fi

# 3. No wildcards in the MIGRATION ledger.
# .hypatia-ignore records work that is meant to disappear. A `**` there absorbs
# files added later, so the ledger silently grows while appearing to hold
# steady — the failure this whole check exists to prevent. Architectural
# exemptions belong in .hypatia-baseline.json with a note explaining them.
if [ -f .hypatia-ignore ]; then
  if grep -vE '^\s*(#|$)' .hypatia-ignore | grep -q '\*\*'; then
    note "WILDCARD       .hypatia-ignore contains a '**' pattern"
    grep -vE '^\s*(#|$)' .hypatia-ignore | grep '\*\*' | sed 's/^/                 /'
    note "               A migration ledger must list paths individually so it can"
    note "               only shrink. Put architectural exemptions in"
    note "               .hypatia-baseline.json with a note instead."
    fail=1
  fi
fi

echo
if [ "$fail" = "0" ]; then
  echo "Exemption ratchet: OK."
else
  cat <<'MSG'
Exemption ratchet: FAILED.

An exemption ledger grew, or an exemption does not say what it is.

If the growth is correct — a newly vendored dependency, a newly discovered
architectural boundary — declare it in the commit message:

    Ratchet-exception: vendored upstream foo/ at v1.2.3; its test corpus
    contains credential-shaped fixtures by design

If it is not correct, remove the finding rather than the report.
MSG
fi
exit "$fail"
