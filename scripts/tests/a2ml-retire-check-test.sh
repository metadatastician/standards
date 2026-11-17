#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# a2ml-retire-check-test.sh — fixture suite for scripts/a2ml-retire-check.sh.
#
# Every fixture is a throwaway tree built under mktemp; the A2ML record text
# is written there at run time, so no A2ML file is committed. Each case
# breaks exactly one of the three deletion conditions, applies one rulings
# row, or exercises one output mode. A final group runs the tool on this
# repository and compares its counts with the committed live counts file
# (.machine_readable/a2ml-retire-counts.json), so the counts cannot drift from
# the tree silently.
#
# Run: bash scripts/tests/a2ml-retire-check-test.sh
# Needs bun (deed_lint.js) and jq, as the tool does.

# The mutant sed expressions name the tool's own $ variables, unexpanded.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL="$SCRIPT_DIR/../a2ml-retire-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

for t in bun jq git; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t is required by this suite" >&2; exit 1; }
done

ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "      $2"; fail=$((fail + 1)); }

# ── fixture builders ───────────────────────────────────────────────────────
CHORA_UUID='00000000-0000-8000-8000-0000000000a1'
# A legacy CLADE record carries a version-5 id. It is assembled here so this
# file holds no UUID literal the v8 gate would have to exempt.
LEGACY_UUID="$(printf '%s-%s-%s-%s-%s' d9e987dc bb7b 51aa 839b 3d8bbfe774c3)"

chora() { # chora DIR [owner]
  cat > "$1/fixture_chora.deed" <<EOF
;; SPDX-License-Identifier: MPL-2.0
(repo-deed
  :schema-version "1.0.0"
  :canonical-name "fixture"
  :repo-uuid #uuid"$CHORA_UUID"
  :beholding-chora #uuid"00000000-0000-8000-8000-0000000000b2"
  (identity :owner "${2:-o}" :primary-forge github :prefixed-name "rm-fixture")
  (clade :primary rm :secondary () :assigned "2026-03-16" :rationale "")
  (forges :github "o/fixture" :gitlab "" :bitbucket "")
  (lineage :type standalone :parent "" :born "2026-03-16"))
EOF
}

state_deed() { # state_deed DIR [present-token]
  mkdir -p "$1/.machine_readable/descriptiles"
  cat > "$1/.machine_readable/descriptiles/STATE.deed" <<EOF
;; SPDX-License-Identifier: MPL-2.0
(descriptile-deed
  :schema-version "1.0.0"
  :canonical-name "fixture"
  :of-chora #uuid"$CHORA_UUID"
  :affirmed "2026-11-17" :affirmed-by agent
  (status :phase active :since "2026-03-16" :present ${2:-#t} :aliases () :merged-into ""
          :superseded-by "" :successors () :ended ""
          (history (entry :phase active :since "2026-03-16" :note "n")))
  (maturity :level experimental))
EOF
}

meta_deed() {
  mkdir -p "$1/.machine_readable/descriptiles"
  cat > "$1/.machine_readable/descriptiles/META.deed" <<EOF
;; SPDX-License-Identifier: MPL-2.0
(descriptile-deed
  :schema-version "1.0.0"
  :canonical-name "fixture"
  :of-chora #uuid"$CHORA_UUID"
  :affirmed "2026-11-17" :affirmed-by agent
  :version "0.1.0")
EOF
}

# The A2ML record text, generated here and never committed.
clade_record() { # clade_record FILE
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '# SPDX-License-Identifier: MPL-2.0' '[identity]' \
    "uuid = \"$LEGACY_UUID\"" 'primary-forge = "github"' \
    'primary-owner = "o"' 'canonical-name = "fixture"' 'prefixed-name = "rm-fixture"' \
    '[clade]' 'primary = "rm"' 'secondary = []' 'assigned = "2026-03-16"' 'rationale = ""' \
    '[forges]' 'github = "o/fixture"' 'gitlab = ""' 'bitbucket = ""' \
    '[lineage]' 'type = "standalone"' 'parent = ""' 'born = "2026-03-16"' \
    '[status]' 'phase = "active"' 'since = "2026-03-16"' 'present = true' 'aliases = []' \
    'merged-into = ""' 'superseded-by = ""' 'successors = [' '  # none' ']' 'ended = ""' \
    '[[status.history]]' 'phase = "active"' 'since = "2026-03-16"' 'note = "n"' > "$1"
}
state_record() { # state_record FILE
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '[metadata]' 'status = "active"' '[position]' 'phase = "active"' \
    'maturity = "experimental"' '[route-to-mvp]' 'milestones = []' > "$1"
}
plain_record() { mkdir -p "$(dirname "$1")"; printf '[metadata]\nversion = "1.0.0"\n' > "$1"; }

ledger() { # ledger DIR PATH...
  mkdir -p "$1/.machine_readable"; shift_dir=$1; shift
  { echo '# ledger'; printf '%s\n' "$@"; } > "$shift_dir/.machine_readable/a2ml-legacy-allow.txt"
}

# The deletable tree: a CLADE record whose every fact is in the chora deed
# and STATE.deed, both valid, and nothing that names the file.
deletable_tree() {
  local d="$WORK/$1"; mkdir -p "$d"
  chora "$d"; state_deed "$d"; clade_record "$d/.machine_readable/CLADE.a2ml"
  ledger "$d" ".machine_readable/CLADE.a2ml"
  printf '%s' "$d"
}

NO_RULINGS="$WORK/no-rulings.jsonl"; : > "$NO_RULINGS"
run() { bash "$TOOL" --rulings "${RULINGS:-$NO_RULINGS}" "$@"; }
row() { # row DIR PATH -> the --json object of PATH
  run --root "$1" --json | jq -c --arg p "$2" 'select(.path == $p)'
}
has_blocker() { jq -e --arg b "$1" '.blockers | index($b) != null' >/dev/null; }
class_is()    { jq -e --arg c "$1" '.class == $c' >/dev/null; }

# ── cases (each returns 0 when the tool behaves) ───────────────────────────
c_deletable() {
  local d r; d=$(deletable_tree deletable)
  r=$(row "$d" .machine_readable/CLADE.a2ml)
  printf '%s' "$r" | class_is deletable-now \
    && printf '%s' "$r" | jq -e '.blockers == [] and .facts.checked == 26 and .facts.missing == 0 and .facts.dropped == 1' >/dev/null
}
c_check_fails_on_deletable() {
  local d out; d=$(deletable_tree check-del)
  run --root "$d" --write-counts >/dev/null || return 1
  out=$(run --root "$d" --check 2>&1); [ $? -eq 1 ] || return 1
  grep -qF 'git rm -- .machine_readable/CLADE.a2ml' <<<"$out" \
    && grep -qF '.machine_readable/a2ml-legacy-allow.txt:2: .machine_readable/CLADE.a2ml' <<<"$out"
}
c_fact_missing() {
  local d r; d=$(deletable_tree factmiss); chora "$d" "someone-else"
  r=$(row "$d" .machine_readable/CLADE.a2ml)
  printf '%s' "$r" | has_blocker 'facts-missing:1' && printf '%s' "$r" | has_blocker 'needs-kyx:CLADE' \
    && printf '%s' "$r" | class_is needs-kyx-unsupported
}
c_target_absent() {
  local d r; d=$(deletable_tree noState); rm "$d/.machine_readable/descriptiles/STATE.deed"
  r=$(row "$d" .machine_readable/CLADE.a2ml)
  printf '%s' "$r" | has_blocker 'no-target-deed:.machine_readable/descriptiles/STATE.deed' \
    && printf '%s' "$r" | has_blocker 'facts-missing:11'
}
c_lint_fails() {
  local d r; d=$(deletable_tree lintfail); state_deed "$d" "true"
  r=$(row "$d" .machine_readable/CLADE.a2ml)
  printf '%s' "$r" | has_blocker 'lint-fail:.machine_readable/descriptiles/STATE.deed' \
    && ! printf '%s' "$r" | class_is deletable-now
}
c_reader() {
  local d r; d=$(deletable_tree reader); mkdir -p "$d/scripts"
  printf '#!/bin/sh\ncat .machine_readable/CLADE.a2ml\n' > "$d/scripts/use.sh"
  r=$(row "$d" .machine_readable/CLADE.a2ml)
  printf '%s' "$r" | jq -e '.blockers == ["reader:scripts/use.sh"]' >/dev/null \
    && printf '%s' "$r" | class_is covered-but-read
}
c_check_passes_when_read() {
  local d; d=$(deletable_tree check-read); mkdir -p "$d/scripts"
  printf 'x=CLADE.a2ml\n' > "$d/scripts/use.sh"
  run --root "$d" --write-counts >/dev/null && run --root "$d" --check >/dev/null 2>&1
}
c_name_reader() {
  local d r; d=$(deletable_tree namereader); mkdir -p "$d/scripts"
  printf 'f=CLADE.a2ml\n' > "$d/scripts/use.sh"
  r=$(row "$d" .machine_readable/CLADE.a2ml)
  printf '%s' "$r" | jq -e '.blockers == ["name-reader:scripts/use.sh"]' >/dev/null
}
c_prose_is_not_a_reader() {
  local d r; d=$(deletable_tree prose)
  printf 'See .machine_readable/CLADE.a2ml\n' > "$d/NOTES.adoc"
  r=$(row "$d" .machine_readable/CLADE.a2ml); printf '%s' "$r" | class_is deletable-now
}
c_unchecked_never_deletable() {
  local d r; d="$WORK/unchecked"; mkdir -p "$d"; chora "$d"; meta_deed "$d"
  plain_record "$d/.machine_readable/descriptiles/META.a2ml"
  r=$(row "$d" .machine_readable/descriptiles/META.a2ml)
  printf '%s' "$r" | jq -e '.blockers == ["facts-unchecked:META"] and .class == "facts-unchecked"' >/dev/null \
    && run --root "$d" --write-counts >/dev/null && run --root "$d" --check >/dev/null 2>&1
}
c_no_chora() {
  local d r; d="$WORK/nochora"; mkdir -p "$d"
  plain_record "$d/.machine_readable/descriptiles/META.a2ml"
  r=$(row "$d" .machine_readable/descriptiles/META.a2ml)
  printf '%s' "$r" | class_is no-target-deed && printf '%s' "$r" | has_blocker 'needs-kyx:META'
}
c_no_spec() {
  local d r; d="$WORK/nospec"; mkdir -p "$d"; plain_record "$d/data/registry.a2ml"
  r=$(row "$d" data/registry.a2ml)
  printf '%s' "$r" | jq -e '.blockers == ["no-mapping-spec"] and .class == "no-mapping-spec" and .family == "none"' >/dev/null
}
c_ruling_flips_class() {
  local d before after; d="$WORK/ruled"; mkdir -p "$d"
  plain_record "$d/old/format/.machine_readable/descriptiles/META.a2ml"
  before=$(row "$d" old/format/.machine_readable/descriptiles/META.a2ml)
  printf '%s\n' '{"date":"2026-11-17","id":"t-drop","kind":"dropped","match":"^old/format/","recorded":"test","summary":"s"}' > "$WORK/drop.jsonl"
  after=$(RULINGS="$WORK/drop.jsonl" row "$d" old/format/.machine_readable/descriptiles/META.a2ml)
  printf '%s' "$before" | class_is no-target-deed && printf '%s' "$after" | class_is deletable-now \
    && printf '%s' "$after" | jq -e '.rulings == ["t-drop"]' >/dev/null
}
c_ruling_condition() {
  local d r; d="$WORK/ruledreq"; mkdir -p "$d"; plain_record "$d/old/x.a2ml"
  printf '%s\n' '{"date":"2026-11-17","id":"t-drop","kind":"dropped","match":"^old/","recorded":"test","requires":"links-redirected","summary":"s"}' > "$WORK/dropreq.jsonl"
  r=$(RULINGS="$WORK/dropreq.jsonl" row "$d" old/x.a2ml)
  printf '%s' "$r" | jq -e '.blockers == ["ruling-condition:links-redirected"] and .class == "decision-drops"' >/dev/null
}
c_spec_gap_and_kyx_family() {
  local d r1 r2; d="$WORK/eco"; mkdir -p "$d"; chora "$d"
  plain_record "$d/.machine_readable/descriptiles/ECOSYSTEM.a2ml"
  r1=$(row "$d" .machine_readable/descriptiles/ECOSYSTEM.a2ml)
  printf '%s\n' '{"date":"2026-11-14","family":"ECOSYSTEM","id":"t-kyx","kind":"kyx-family","recorded":"test","summary":"s"}' \
    '{"date":"2026-10-27","id":"t-gap","key":"old-shape","kind":"spec-gap","match":"ECOSYSTEM\\.a2ml$","recorded":"test","summary":"s"}' > "$WORK/eco.jsonl"
  r2=$(RULINGS="$WORK/eco.jsonl" row "$d" .machine_readable/descriptiles/ECOSYSTEM.a2ml)
  printf '%s' "$r1" | class_is needs-kyx-unsupported && printf '%s' "$r2" | class_is needs-kyx-supported \
    && printf '%s' "$r2" | has_blocker 'spec-gap:old-shape' \
    && printf '%s' "$r2" | has_blocker 'no-target-deed:.machine_readable/descriptiles/ECOSYSTEM.deed|fixture_chora.deed#ecosystem'
}
c_external_reader_and_ruling_needed() {
  local d r; d=$(deletable_tree ext)
  printf '%s\n' '{"date":"2026-10-27","id":"t-ext","key":"hyp-s010","kind":"external-reader","match":"CLADE\\.a2ml$","recorded":"test","summary":"s"}' > "$WORK/ext.jsonl"
  r=$(RULINGS="$WORK/ext.jsonl" row "$d" .machine_readable/CLADE.a2ml)
  printf '%s' "$r" | jq -e '.blockers == ["external-reader:hyp-s010"] and .class == "covered-but-read"' >/dev/null || return 1
  printf '%s\n' '{"date":"2026-11-13","id":"t-rn","key":"k","kind":"ruling-needed","match":"CLADE\\.a2ml$","recorded":"test","summary":"s"}' > "$WORK/rn.jsonl"
  r=$(RULINGS="$WORK/rn.jsonl" row "$d" .machine_readable/CLADE.a2ml)
  printf '%s' "$r" | jq -e '.blockers == ["ruling-needed:k"] and .class == "ruling-needed"' >/dev/null
}
c_state_decision() {
  local d r1 r2; d="$WORK/state"; mkdir -p "$d"; chora "$d"; state_deed "$d"
  state_record "$d/.machine_readable/descriptiles/STATE.a2ml"
  r1=$(row "$d" .machine_readable/descriptiles/STATE.a2ml)
  printf '%s\n' '{"date":"2026-11-10","family":"STATE","id":"t-b","kind":"decision","recorded":"test","summary":"s"}' > "$WORK/state.jsonl"
  r2=$(RULINGS="$WORK/state.jsonl" row "$d" .machine_readable/descriptiles/STATE.a2ml)
  printf '%s' "$r1" | jq -e '.blockers == ["facts-unchecked:STATE"]' >/dev/null \
    && printf '%s' "$r2" | jq -e '.class == "deletable-now" and .facts.checked == 2 and .facts.missing == 0' >/dev/null
}
c_unclassified_fails_check() {
  local d out; d=$(deletable_tree twochora); cp "$d/fixture_chora.deed" "$d/other_chora.deed"
  out=$(run --root "$d" --json 2>/dev/null | jq -r 'select(.path == ".machine_readable/CLADE.a2ml") | .class')
  [ "$out" = unclassified ] || return 1
  run --root "$d" --check >/dev/null 2>&1; [ $? -eq 1 ]
}
c_bun_absent_fails_closed() {
  local d out; d=$(deletable_tree nobun)
  out=$(BUN=/nonexistent/bun run --root "$d" --json 2>&1); [ $? -eq 2 ] && grep -qF 'bun is required' <<<"$out"
}
c_bad_rulings_refused() {
  local d; d=$(deletable_tree badrul)
  printf '%s\n' '{"id":"x","kind":"wishful"}' > "$WORK/bad.jsonl"
  RULINGS="$WORK/bad.jsonl" run --root "$d" --json >/dev/null 2>&1; [ $? -eq 2 ]
}
c_json_is_canonical() {
  local d out; d=$(deletable_tree jcs); out=$(run --root "$d" --json) || return 1
  [ -n "$out" ] && [ "$out" = "$(printf '%s\n' "$out" | jq -c -S .)" ]
}
c_summary_denominators() {
  local d out; d=$(deletable_tree summ); plain_record "$d/data/registry.a2ml"
  out=$(run --root "$d" --summary) || return 1
  grep -qF 'deletable-now 1 of 2' <<<"$out" && grep -qF 'no-mapping-spec 1 of 2' <<<"$out"
}
c_git_tracked_only() {
  local d r; d=$(deletable_tree gitmode); git -C "$d" init -q; plain_record "$d/untracked.a2ml"
  git -C "$d" add .machine_readable fixture_chora.deed
  r=$(run --root "$d" --json | jq -r '.path' | paste -sd' ')
  [ "$r" = ".machine_readable/CLADE.a2ml" ]
}

# ── live counts, the --base ratchet, several rulings files, record lines ──
# A clean tree: one file that a script reads (covered-but-read), so --check
# has nothing to report but the counts and the ratchet.
read_tree() {
  local d; d=$(deletable_tree "$1"); mkdir -p "$d/scripts"
  printf 'x=CLADE.a2ml\n' > "$d/scripts/use.sh"; printf '%s' "$d"
}
c_counts_written_and_current() {
  local d; d=$(read_tree counts)
  run --root "$d" --write-counts >/dev/null || return 1
  jq -e '.total == 1 and .classes["covered-but-read"] == 1 and .classes["deletable-now"] == 0
         and .blocker_kinds["name-reader"] == 1 and .deletable_now == []' "$d/.machine_readable/a2ml-retire-counts.json" >/dev/null \
    && [ "$(cat "$d/.machine_readable/a2ml-retire-counts.json")" = "$(jq -c -S . "$d/.machine_readable/a2ml-retire-counts.json")" ] \
    && run --root "$d" --check >/dev/null 2>&1
}
c_counts_missing_fails() {
  local d out; d=$(read_tree nocounts)
  out=$(run --root "$d" --check 2>&1); [ $? -eq 1 ] && grep -qF 'no counts file' <<<"$out" \
    && grep -qF -- '--write-counts' <<<"$out"
}
c_counts_stale_fails() {
  local d out; d=$(read_tree stale)
  run --root "$d" --write-counts >/dev/null || return 1
  plain_record "$d/data/registry.a2ml"                    # the tree changed; the counts did not
  out=$(run --root "$d" --check 2>&1); [ $? -eq 1 ] || return 1
  grep -qF 'counts are stale' <<<"$out" && grep -qF -- "--root $d" <<<"$out" \
    && grep -qF -- '--write-counts' <<<"$out"
}
# A git tree at two commits: <name> with the read file and current counts.
git_tree() {
  local d; d=$(read_tree "$1"); git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t add -A >/dev/null
  run --root "$d" --write-counts >/dev/null; git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base; printf '%s' "$d"
}
commit_all() { run --root "$1" --write-counts >/dev/null; git -C "$1" add -A; git -C "$1" -c user.email=t@t -c user.name=t commit -q -m next >/dev/null; }
c_base_same_tree_passes() {
  local d; d=$(git_tree base0); run --root "$d" --base HEAD --check >/dev/null 2>&1
}
c_base_joined_path_fails() {
  local d out; d=$(git_tree base1); plain_record "$d/data/new.a2ml"; git -C "$d" add -A; commit_all "$d"
  out=$(run --root "$d" --base HEAD~1 --check 2>&1); [ $? -eq 1 ] && grep -qF 'joined since HEAD~1' <<<"$out" \
    && grep -qF '  data/new.a2ml' <<<"$out"
}
c_base_deletion_and_rename_pass() {
  local d; d=$(git_tree base2); plain_record "$d/data/a.a2ml"; git -C "$d" add -A; commit_all "$d"
  git -C "$d" mv data/a.a2ml data/b.a2ml; commit_all "$d"
  run --root "$d" --base HEAD~1 --check >/dev/null 2>&1 || return 1
  git -C "$d" rm -q data/b.a2ml; commit_all "$d"
  run --root "$d" --base HEAD~2 --check >/dev/null 2>&1
}
c_base_swap_fails() {  # one file leaves, another joins: the total holds, the join still fails
  local d; d=$(git_tree base3); plain_record "$d/data/a.a2ml"; git -C "$d" add -A; commit_all "$d"
  git -C "$d" rm -q data/a.a2ml; mkdir -p "$d/data"; printf '[x]\ny = "z"\n' > "$d/data/c.a2ml"; git -C "$d" add -A; commit_all "$d"
  run --root "$d" --base HEAD~1 --check >/dev/null 2>&1; [ $? -eq 1 ]
}
c_two_rulings_files_add() {
  local d a b r1 r2; d="$WORK/two"; mkdir -p "$d"; plain_record "$d/old/x.a2ml"
  a="$WORK/two-a.jsonl"; b="$WORK/two-b.jsonl"
  printf '%s\n' '{"date":"2026-11-17","id":"t-drop","kind":"dropped","match":"^old/","recorded":"test","summary":"s"}' > "$a"
  printf '%s\n' '{"date":"2026-11-17","id":"t-rn","key":"k","kind":"ruling-needed","match":"^old/","recorded":"test","summary":"s"}' > "$b"
  r1=$(bash "$TOOL" --root "$d" --rulings "$a" --rulings "$b" --json)
  r2=$(bash "$TOOL" --root "$d" --rulings "$b" --rulings "$a" --json)
  printf '%s' "$r1" | jq -e '.blockers == ["ruling-needed:k"] and .class == "decision-drops" and .rulings == ["t-drop","t-rn"]' >/dev/null \
    && [ "$r1" = "$r2" ]
}
c_rulings_id_twice_refused() {
  local d a; d="$WORK/twoid"; mkdir -p "$d"; plain_record "$d/old/x.a2ml"; a="$WORK/twoid.jsonl"
  printf '%s\n' '{"date":"2026-11-17","id":"t-drop","kind":"dropped","match":"^old/","recorded":"test","summary":"s"}' > "$a"
  bash "$TOOL" --root "$d" --rulings "$a" --rulings "$a" --json >/dev/null 2>&1; [ $? -eq 2 ]
}
c_rulings_missing_file_refused() {
  local d; d="$WORK/norulfile"; mkdir -p "$d"; plain_record "$d/x.a2ml"
  bash "$TOOL" --root "$d" --rulings "$WORK/absent.jsonl" --json >/dev/null 2>&1; [ $? -eq 2 ]
}
c_record_line() {
  local d r1 r2 r3; d="$WORK/record"; mkdir -p "$d/9-archive"; plain_record "$d/old/x.a2ml"
  printf '%s\n' '{"date":"2026-11-17","id":"t-drop","kind":"dropped","match":"^old/","record":"9-archive/REMOVED.adoc","recorded":"test","summary":"s"}' > "$WORK/rec.jsonl"
  r1=$(RULINGS="$WORK/rec.jsonl" row "$d" old/x.a2ml)
  printf '* `new/old/x.a2ml` held something else\n' > "$d/9-archive/REMOVED.adoc"
  r2=$(RULINGS="$WORK/rec.jsonl" row "$d" old/x.a2ml)
  printf '* `old/x.a2ml` held one table\n' >> "$d/9-archive/REMOVED.adoc"
  r3=$(RULINGS="$WORK/rec.jsonl" row "$d" old/x.a2ml)
  printf '%s' "$r1" | jq -e '.blockers == ["record-missing:9-archive/REMOVED.adoc"]' >/dev/null \
    && printf '%s' "$r2" | jq -e '.blockers == ["record-missing:9-archive/REMOVED.adoc"]' >/dev/null \
    && printf '%s' "$r3" | class_is deletable-now
}

check() { if "$2"; then ok "$1"; else bad "$1"; fi; }

echo "=== the three deletion conditions ==="
check "all three conditions hold: deletable-now, 26 facts checked, 1 dropped by spec" c_deletable
check "--check fails on a deletable file and prints the git rm and ledger line"    c_check_fails_on_deletable
check "condition 1: one differing fact is facts-missing:1 and needs kyX"           c_fact_missing
check "condition 1: an absent target deed is named, its facts counted missing"     c_target_absent
check "condition 2: an invalid target deed blocks (lint-fail)"                      c_lint_fails
check "condition 3: a script naming the path blocks; class covered-but-read"        c_reader
check "--check passes when nothing is deletable"                                    c_check_passes_when_read
check "condition 3: a script naming only the basename blocks (name-reader)"         c_name_reader
check "prose that names the path is not a reader"                                   c_prose_is_not_a_reader
echo "=== honesty and classes ==="
check "a target that exists but whose comparison is not mechanised is never deletable" c_unchecked_never_deletable
check "no chora deed: no-target-deed, and the family needs kyX"                    c_no_chora
check "no spec covers the path: no-mapping-spec"                                    c_no_spec
check "two chora deeds: unclassified, and --check fails"                            c_unclassified_fails_check
echo "=== the rulings file ==="
check "a 'dropped' row flips no-target-deed to deletable-now"                      c_ruling_flips_class
check "a 'dropped' row with a precondition blocks on it"                           c_ruling_condition
check "spec-gap and kyx-family rows: blocker named, class needs-kyx-supported"     c_spec_gap_and_kyx_family
check "external-reader and ruling-needed rows block"                               c_external_reader_and_ruling_needed
check "STATE: unchecked without its decision row; with it, 2 facts compared"       c_state_decision
check "a malformed rulings file is refused (exit 2)"                               c_bad_rulings_refused
echo "=== modes and setup ==="
check "bun absent: exit 2 with a message, never a skip"                            c_bun_absent_fails_closed
check "--json is JCS (sorted keys, compact)"                                        c_json_is_canonical
check "--summary prints counts with denominators"                                   c_summary_denominators
check "in a git work tree only tracked files are classed"                           c_git_tracked_only
echo "=== live counts and the --base ratchet ==="
check "--write-counts writes JCS counts; --check passes when they are current"     c_counts_written_and_current
check "--check fails when the counts file is missing, naming the command"          c_counts_missing_fails
check "--check fails when the counts are stale, printing the exact command"       c_counts_stale_fails
check "--base: the same tree passes (negative control)"                            c_base_same_tree_passes
check "--base: a joined A2ML path fails and is named"                              c_base_joined_path_fails
check "--base: a deletion and an unchanged rename (R100) pass"                     c_base_deletion_and_rename_pass
check "--base: a swap (one leaves, one joins) fails though the total holds"        c_base_swap_fails
echo "=== several rulings files, record lines ==="
check "two --rulings files add rows; effects unite; order does not matter"        c_two_rulings_files_add
check "an id given twice across --rulings files is refused (exit 2)"              c_rulings_id_twice_refused
check "a named --rulings file that does not exist is refused (exit 2)"            c_rulings_missing_file_refused
check "a record line blocks until the record names the exact path"                c_record_line

# ── mutants ────────────────────────────────────────────────────────────────
mutant() { # mutant <sed-expr> <label> <case-fn>
  local expr=$1 label=$2 fn=$3 m saved
  [ -f "$TOOL" ] || { bad "mutant (): the tool is missing"; return; }
  m="$WORK/mutant-$(basename "$TOOL")"; sed "$expr" "$TOOL" > "$m"
  if ! bash -n "$m" || cmp -s "$m" "$TOOL"; then bad "mutant ($label) is invalid or identical — it proves nothing"; return; fi
  saved=$TOOL; TOOL=$m
  if "$fn"; then bad "mutant survived ($label)"; else ok "mutant killed ($label)"; fi
  TOOL=$saved
}
echo "=== mutants ==="
mutant 's/^\( *\)blockers+=("reader:\$r")/\1:/' "readers are ignored" c_reader
mutant 's/^\( *\)blockers+=("facts-unchecked:\$family")/\1:/' "an unchecked target counts as covered" c_unchecked_never_deletable
mutant 's/\[ "\$n_deletable" -gt 0 \]/false/' "--check passes past a deletable file" c_check_fails_on_deletable
mutant 's/^\( *\)blockers+=("lint-fail:\$t")/\1:/' "lint failures are ignored" c_lint_fails
mutant 's/if \[ "\${#joined\[@\]}" -gt 0 \]; then/if false; then/' "--base lets a joined path through" c_base_joined_path_fails
mutant 's/^    elif ! jq -e -n --slurpfile a/    elif false && ! jq -e -n --slurpfile a/' "stale counts pass" c_counts_stale_fails
mutant 's/named_in "\$p" "\$ROOT\/\$rec" ||/true ||/' "a missing record line is ignored" c_record_line

# ── this repository ────────────────────────────────────────────────────────
echo "=== this repository ==="
COUNTS="$REPO_ROOT/.machine_readable/a2ml-retire-counts.json"
live="$WORK/live.jsonl"
if bash "$TOOL" --root "$REPO_ROOT" --json > "$live" 2>"$WORK/live.err"; then
  ok "the tool runs on this repository"
  n_tracked=$(git -C "$REPO_ROOT" ls-files | grep -cE '\.a2ml(\.in|\.template|\.v[0-9]+\.template)?$')
  n_rows=$(wc -l < "$live")
  if [ "$n_rows" = "$n_tracked" ]; then ok "it classes every tracked A2ML file ($n_rows of $n_tracked)"
  else bad "it classes $n_rows rows for $n_tracked tracked A2ML files"; fi
  if jq -e 'select(.class == "unclassified")' "$live" >/dev/null; then bad "a tracked file is unclassified" "$(jq -r 'select(.class == "unclassified") | .path' "$live" | head -3)"
  else ok "no tracked file is unclassified"; fi
  # The live counts file must be what the tree gives now.
  if bash "$TOOL" --root "$REPO_ROOT" --counts "$WORK/live-counts.json" --write-counts >/dev/null 2>&1 \
     && [ -f "$COUNTS" ] && jq -e -n --slurpfile a "$COUNTS" --slurpfile b "$WORK/live-counts.json" '$a == $b' >/dev/null; then
    ok "the committed counts file equals the counts of the tree"
  else bad "$COUNTS differs from the tree: run bash scripts/a2ml-retire-check.sh --write-counts in the same commit"; fi
  if [ -f "$COUNTS" ] && [ "$(cat "$COUNTS")" = "$(jq -c -S . "$COUNTS")" ]; then ok "the counts file is JCS"
  else bad "the counts file is missing or not JCS"; fi
  # The gate on this repository: --check fails exactly when the counts list a
  # deletable-now file (each waits on its owner-visible deletion commit).
  bash "$TOOL" --root "$REPO_ROOT" --check >/dev/null 2>&1; st=$?
  n_del=$(jq -r '.deletable_now | length' "$COUNTS" 2>/dev/null || echo -1)
  if { [ "$n_del" -gt 0 ] && [ "$st" -eq 1 ]; } || { [ "$n_del" -eq 0 ] && [ "$st" -eq 0 ]; }; then
    ok "--check on this repository agrees with the counts ($n_del deletable-now, exit $st)"
  else bad "--check exited $st on this repository, but the counts list $n_del deletable-now file(s)"; fi
else
  bad "the tool failed on this repository" "$(head -3 "$WORK/live.err")"
fi

echo
echo "a2ml-retire-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
