#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# k9-grid-test.sh — the conformance-family grid for the K9 lane never turns
# missing, skipped or unreadable evidence into a clean row, honours the
# shrink-only debt ledger exactly as CONFORMANCE-REPORTING.adoc states it,
# keeps routed files and an empty corpus grey, refuses an exemption the PR
# adds without a Ratchet-exception, compares revisions only under one profile
# (renderer, validator commit, ledger, lane, corpus), and writes I-JSON/JCS
# artifacts. docs/VERDICT-GRID-SPEC.adoc
# and 1-formats/k9/tools/CONFORMANCE-REPORTING.adoc are the contracts under test.
#
# Run: bash scripts/tests/k9-grid-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRID="$SCRIPT_DIR/../k9-grid.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() {
  local label="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $label ($got)"; pass=$((pass + 1))
  else
    echo "FAIL: $label expected=$expected got=$got"; fail=$((fail + 1))
  fi
}
render() { bash "$GRID" render --out "$1" "${@:2}" >/dev/null; }
state() { jq -r .state "$1/report.json"; }
cat_state() { jq -r --arg id "$2" '.categories[] | select(.id == $id) | .state' "$1/report.json"; }
reason() { jq -r --arg id "$2" '[.categories[].items[] | select(.id == $id)][0].reason' "$1/report.json"; }

# One validator record per line, in k9-validate.sh --json shape.
rec() { # rec FILE VERDICT FINDINGS_JSON
  jq -nc --arg f "$1" --arg v "$2" --argjson fd "$3" \
    '{file: $f, dialect: "component", contract_version: "1.0.0", verdict: $v,
      errors: ([$fd[] | select(.severity == "error")] | length),
      warnings: ([$fd[] | select(.severity == "warning")] | length),
      skipped: ([$fd[] | select(.severity == "skipped")] | length), findings: $fd}'
}
E_S002='[{"severity":"error","rule":"K9-S002","layer":"L1","message":"component_type missing"}]'
E_N002='[{"severity":"skipped","rule":"K9-N002","layer":"L2","message":"contract not typechecked"}]'
E_N002_ERR='[{"severity":"error","rule":"K9-N002","layer":"L2","message":"the normative contract itself failed to typecheck"}]'
S_C001='[{"severity":"skipped","rule":"K9-C001","layer":"L3","message":"no verifier ran"}]'
W_ONE='[{"severity":"warning","rule":"K9-W001","layer":"L1","message":"description is short"}]'

printf '%s\n' a.k9.ncl b.k9.ncl > "$WORK/expected"
printf '%s\n' a.k9.ncl > "$WORK/expected-a"
: > "$WORK/expected-none"
printf '%s\n' b.k9.ncl > "$WORK/ledger-b"
printf '# comment\n\nb.k9.ncl\n' > "$WORK/ledger-b-commented"
printf '%s\n' b.k9.ncl > "$WORK/changed-b"

ok_selftest="$WORK/selftest-ok.log"
printf 'ok   one\nok   two\n\nself-test: all assertions passed\n' > "$ok_selftest"
bad_selftest="$WORK/selftest-bad.log"
printf 'ok   one\nFAIL two\n' > "$bad_selftest"
: > "$WORK/empty.log"
printf 'error: type mismatch\n' > "$WORK/typecheck-bad.log"

good_evidence=(--selftest "$ok_selftest" --selftest-code 0 --typecheck "$WORK/empty.log" --typecheck-code 0 --corpus-code 0)

# 1. Every row clean -> green, and the artifacts are JCS.
{ rec a.k9.ncl pass '[]'; rec b.k9.ncl pass '[]'; } > "$WORK/r-clean"
render "$WORK/o1" --results "$WORK/r-clean" --expected "$WORK/expected" "${good_evidence[@]}" --sha 1111111111111111111111111111111111111111 --pr 7 --run 1
check "clean corpus is green" green "$(state "$WORK/o1")"
check "report.json is JCS (sorted, compact, one LF)" yes "$( [ "$(jq -S -c . "$WORK/o1/report.json"; echo)" = "$(cat "$WORK/o1/report.json")" ] && [ "$(tail -c1 "$WORK/o1/report.json" | od -An -c | tr -d ' ')" = '\n' ] && echo yes || echo no)"
check "badge.json uses the shields schema" "k9-deed L0–L2/conformant/brightgreen" "$(jq -r '"\(.label)/\(.message)/\(.color)"' "$WORK/o1/badge.json")"
check "report.md carries the lane marker" yes "$(grep -q '^<!-- verdict-grid:k9 regenerated on every run -->' "$WORK/o1/report.md" && echo yes || echo no)"
check "report.md carries a baseline" yes "$(grep -q '<!-- k9-baseline:' "$WORK/o1/report.md" && echo yes || echo no)"

# 2. A failing contract that is not ledgered is red.
{ rec a.k9.ncl pass '[]'; rec b.k9.ncl fail "$E_S002"; } > "$WORK/r-fail"
render "$WORK/o2" --results "$WORK/r-fail" --expected "$WORK/expected" "${good_evidence[@]}"
check "unledgered failure is red" red "$(state "$WORK/o2")"
check "the failing row names the rule" "K9-S002: component_type missing" "$(reason "$WORK/o2" b.k9.ncl)"

# 3. The same failure, ledgered and untouched by the PR, is advisory (yellow).
render "$WORK/o3" --results "$WORK/r-fail" --expected "$WORK/expected" --ledger "$WORK/ledger-b" "${good_evidence[@]}"
check "ledgered untouched failure is yellow" yellow "$(state "$WORK/o3")"
check "ledger comments and blank lines are ignored" yellow "$(render "$WORK/o3b" --results "$WORK/r-fail" --expected "$WORK/expected" --ledger "$WORK/ledger-b-commented" "${good_evidence[@]}"; state "$WORK/o3b")"

# 4. A ledgered file the PR touches must conform: red.
render "$WORK/o4" --results "$WORK/r-fail" --expected "$WORK/expected" --ledger "$WORK/ledger-b" --changed "$WORK/changed-b" "${good_evidence[@]}"
check "ledgered but changed failure is red" red "$(state "$WORK/o4")"

# 5. A ledgered file that now conforms is a stale exemption: red (shrink the ledger).
render "$WORK/o5" --results "$WORK/r-clean" --expected "$WORK/expected" --ledger "$WORK/ledger-b" "${good_evidence[@]}"
check "stale ledger entry is red" red "$(state "$WORK/o5")"
check "stale ledger reason" "Stale debt exemption: this file now conforms." "$(reason "$WORK/o5" b.k9.ncl)"

# 6. A skipped check is never a pass: orange.
{ rec a.k9.ncl pass '[]'; rec b.k9.ncl pass "$S_C001"; } > "$WORK/r-skip"
render "$WORK/o6" --results "$WORK/r-skip" --expected "$WORK/expected" "${good_evidence[@]}"
check "skipped finding is orange" orange "$(state "$WORK/o6")"
{ rec a.k9.ncl pass '[]'; rec b.k9.ncl pass "$E_N002"; } > "$WORK/r-n002"
render "$WORK/o6b" --results "$WORK/r-n002" --expected "$WORK/expected" "${good_evidence[@]}"
check "skipped contract typecheck is orange" orange "$(state "$WORK/o6b")"
{ rec a.k9.ncl pass '[]'; rec b.k9.ncl error "$E_N002_ERR"; } > "$WORK/r-n002e"
render "$WORK/o6c" --results "$WORK/r-n002e" --expected "$WORK/expected" "${good_evidence[@]}"
check "a K9-N002-only error is the validator's problem, not the file's: orange" orange "$(state "$WORK/o6c")"

# 7. Unreadable or missing evidence is orange, never green.
{ rec a.k9.ncl pass '[]'; echo 'not json'; } > "$WORK/r-malformed"
render "$WORK/o7" --results "$WORK/r-malformed" --expected "$WORK/expected" "${good_evidence[@]}"
check "malformed validator output is orange" orange "$(state "$WORK/o7")"
{ rec a.k9.ncl pass '[]'; } > "$WORK/r-missing"
render "$WORK/o7b" --results "$WORK/r-missing" --expected "$WORK/expected" "${good_evidence[@]}"
check "a file without a result is orange" orange "$(state "$WORK/o7b")"
check "the missing file is named" "Validator did not return a result for this file." "$(reason "$WORK/o7b" b.k9.ncl)"
{ rec a.k9.ncl pass '[]'; rec a.k9.ncl pass '[]'; rec b.k9.ncl pass '[]'; } > "$WORK/r-dup"
render "$WORK/o7c" --results "$WORK/r-dup" --expected "$WORK/expected" "${good_evidence[@]}"
check "a duplicate result is orange" orange "$(state "$WORK/o7c")"
{ rec a.k9.ncl pass '[]'; rec b.k9.ncl pass '[]'; rec zzz.k9.ncl pass '[]'; } > "$WORK/r-extra"
render "$WORK/o7d" --results "$WORK/r-extra" --expected "$WORK/expected" "${good_evidence[@]}"
check "an unexpected result is orange" orange "$(state "$WORK/o7d")"
render "$WORK/o7e" --results "$WORK/r-clean" --expected "$WORK/expected" "${good_evidence[@]}" --base-unresolved
check "an unresolved PR range is orange" orange "$(state "$WORK/o7e")"
render "$WORK/o7f" --results "$WORK/r-clean" --expected "$WORK/expected" "${good_evidence[@]}" --corpus-code 1
check "a validator exit status with no finding to explain it is orange" orange "$(state "$WORK/o7f")"
check "a validator exit status explained by a red row stays red" red "$(render "$WORK/o7g" --results "$WORK/r-fail" --expected "$WORK/expected" "${good_evidence[@]}" --corpus-code 1; state "$WORK/o7g")"

# 7g. A validator exit status explained by a ledgered (advisory) failure is
#     yellow, not orange: the exit is the raw validator's, which fails
#     ledgered files too.
render "$WORK/o7h" --results "$WORK/r-fail" --expected "$WORK/expected" --ledger "$WORK/ledger-b" "${good_evidence[@]}" --corpus-code 1
check "a validator exit status explained by an advisory row stays yellow" yellow "$(state "$WORK/o7h")"
# 7i. A result without a file key is invalid evidence, never an abort.
{ rec a.k9.ncl pass '[]'; jq -nc '{verdict: "pass", findings: []}'; } > "$WORK/r-nofile"
render "$WORK/o7i" --results "$WORK/r-nofile" --expected "$WORK/expected" "${good_evidence[@]}"
check "a result with no file key is orange" orange "$(state "$WORK/o7i")"
check "a result with no file key is reported as validator output" "Unexpected, duplicate or invalid result." "$(reason "$WORK/o7i" "validator output")"

# 7j. Ledger growth without a Ratchet-exception buys no exemption: red.
render "$WORK/o7j" --results "$WORK/r-fail" --expected "$WORK/expected" --ledger "$WORK/ledger-b" --ledger-growth "$WORK/ledger-b" "${good_evidence[@]}"
check "an undeclared ledger addition is red" red "$(state "$WORK/o7j")"
check "the undeclared addition is a finding of its own" yes "$(reason "$WORK/o7j" "ledger + b.k9.ncl" | grep -q '^Added to the debt ledger in this PR with no Ratchet-exception' && echo yes || echo no)"
check "the file the addition names is graded as unledgered" false "$(jq -r '[.categories[].items[] | select(.id == "b.k9.ncl")][0].advisory' "$WORK/o7j/report.json")"
# 7k. A ledger path that is not a tracked K9 file is a stale exemption: red.
printf '%s\n' b.k9.ncl gone.k9.ncl > "$WORK/ledger-gone"
render "$WORK/o7k" --results "$WORK/r-fail" --expected "$WORK/expected" --ledger "$WORK/ledger-gone" "${good_evidence[@]}"
check "a ledger path outside the corpus is red" red "$(state "$WORK/o7k")"
check "the untracked ledger path is named" "Stale debt exemption: this path is not a tracked K9 file." "$(reason "$WORK/o7k" gone.k9.ncl)"

# 8. Warnings are advisory: yellow, counted but not failed.
{ rec a.k9.ncl pass "$W_ONE"; rec b.k9.ncl pass '[]'; } > "$WORK/r-warn"
render "$WORK/o8" --results "$WORK/r-warn" --expected "$WORK/expected" "${good_evidence[@]}"
check "a warning is yellow" yellow "$(state "$WORK/o8")"
check "a warning does not count as failed" 0 "$(jq -r '.counts.failed' "$WORK/o8/report.json")"
check "a warning is counted" 1 "$(jq -r '.counts.warnings' "$WORK/o8/report.json")"

# 9. Routed files and an empty corpus are explicit scope exclusions: grey rows.
{ rec a.k9.ncl routed '[]'; } > "$WORK/r-routed"
render "$WORK/o9" --results "$WORK/r-routed" --expected "$WORK/expected-a" "${good_evidence[@]}"
check "a routed-only corpus is grey" grey "$(cat_state "$WORK/o9" corpus)"
check "a routed file with no coordination result is orange, never green" orange "$(state "$WORK/o9")"
check "and the coordination category says it is indeterminate" indeterminate "$(jq -r ".categories[] | select(.id == \"coord\") | .items[0].status" "$WORK/o9/report.json")"
jq -nc "{file: \"a.k9.ncl\", verdict: \"pass\", message: \"\"}" > "$WORK/coord-pass"
render "$WORK/o9a" --results "$WORK/r-routed" --expected "$WORK/expected-a" "${good_evidence[@]}" --coord-results "$WORK/coord-pass"
check "a routed file the coordination validator passes is green overall" green "$(state "$WORK/o9a")"
check "its own category is green" green "$(cat_state "$WORK/o9a" coord)"
jq -nc "{file: \"a.k9.ncl\", verdict: \"fail\", message: \"line 3: expected section\"}" > "$WORK/coord-fail"
render "$WORK/o9d" --results "$WORK/r-routed" --expected "$WORK/expected-a" "${good_evidence[@]}" --coord-results "$WORK/coord-fail"
check "a coordination grammar failure is red" red "$(state "$WORK/o9d")"
check "the reason is carried" "line 3: expected section" "$(jq -r ".categories[] | select(.id == \"coord\") | .items[0].reason" "$WORK/o9d/report.json")"
render "$WORK/o9b" --results "$WORK/expected-none" --expected "$WORK/expected-none" "${good_evidence[@]}"
check "an empty corpus is grey" grey "$(cat_state "$WORK/o9b" corpus)"
render "$WORK/o9c" --results "$WORK/expected-none" --expected "$WORK/expected-none" "${good_evidence[@]}" --require-files
check "an empty corpus under --require-files is red in the grid itself" red "$(state "$WORK/o9c")"
check "and the badge says so" failing "$(jq -r .message "$WORK/o9c/badge.json")"

# 9b. Coordination records follow the corpus's debt rules and are reconciled with
# the routed files (Codex review on #1516).
printf '%s\n' a.k9.ncl > "$WORK/ledger-a"
printf '%s\n' a.k9.ncl > "$WORK/changed-a"
render "$WORK/o9e" --results "$WORK/r-routed" --expected "$WORK/expected-a" "${good_evidence[@]}" --coord-results "$WORK/coord-fail" --ledger "$WORK/ledger-a"
check "a ledgered, untouched coordination failure is advisory (yellow), not red" yellow "$(state "$WORK/o9e")"
render "$WORK/o9f" --results "$WORK/r-routed" --expected "$WORK/expected-a" "${good_evidence[@]}" --coord-results "$WORK/coord-fail" --ledger "$WORK/ledger-a" --changed "$WORK/changed-a"
check "a ledgered coordination failure the PR touches is blocking (red)" red "$(state "$WORK/o9f")"
render "$WORK/o9g" --results "$WORK/r-routed" --expected "$WORK/expected-a" "${good_evidence[@]}" --coord-results "$WORK/coord-pass" --ledger "$WORK/ledger-a"
check "a ledgered coordination file that now conforms is a stale entry (red)" red "$(state "$WORK/o9g")"
jq -nc '{file: "stray.k9", verdict: "fail", message: "boom"}' > "$WORK/coord-stray"
{ cat "$WORK/coord-pass"; cat "$WORK/coord-stray"; } > "$WORK/coord-pass-stray"
render "$WORK/o9h" --results "$WORK/r-routed" --expected "$WORK/expected-a" "${good_evidence[@]}" --coord-results "$WORK/coord-pass-stray"
check "a record for a file that was not routed is indeterminate (orange), not red" orange "$(state "$WORK/o9h")"
{ cat "$WORK/coord-pass"; cat "$WORK/coord-pass"; } > "$WORK/coord-dup"
render "$WORK/o9i" --results "$WORK/r-routed" --expected "$WORK/expected-a" "${good_evidence[@]}" --coord-results "$WORK/coord-dup"
check "duplicate records for one routed file are indeterminate, never green" orange "$(state "$WORK/o9i")"

# 10. Self-test and typecheck evidence.
render "$WORK/o10" --results "$WORK/r-clean" --expected "$WORK/expected" --selftest "$bad_selftest" --selftest-code 1 --typecheck "$WORK/empty.log" --typecheck-code 0 --corpus-code 0
check "a failed self-test assertion is red" red "$(state "$WORK/o10")"
render "$WORK/o10b" --results "$WORK/r-clean" --expected "$WORK/expected" --selftest "$WORK/empty.log" --selftest-code 0 --typecheck "$WORK/empty.log" --typecheck-code 0 --corpus-code 0
check "a self-test with no assertion lines is orange" orange "$(state "$WORK/o10b")"
printf 'ok   one\n' > "$WORK/selftest-noend.log"
render "$WORK/o10c" --results "$WORK/r-clean" --expected "$WORK/expected" --selftest "$WORK/selftest-noend.log" --selftest-code 0 --typecheck "$WORK/empty.log" --typecheck-code 0 --corpus-code 0
check "a self-test without its completion line is orange" orange "$(state "$WORK/o10c")"
render "$WORK/o10d" --results "$WORK/r-clean" --expected "$WORK/expected" --selftest "$ok_selftest" --selftest-code 0 --typecheck "$WORK/typecheck-bad.log" --typecheck-code 1 --corpus-code 0
check "a failed contract typecheck is red" red "$(state "$WORK/o10d")"
render "$WORK/o10e" --results "$WORK/r-clean" --expected "$WORK/expected" --selftest "$ok_selftest" --selftest-code 0 --corpus-code 0
check "a typecheck that did not run is orange" orange "$(state "$WORK/o10e")"
render "$WORK/o10f" --results "$WORK/r-clean" --expected "$WORK/expected" --typecheck "$WORK/empty.log" --typecheck-code 0 --corpus-code 0
check "a self-test that did not run is orange" orange "$(state "$WORK/o10f")"

# 11. Revision comparison: only under one profile, same PR, different commit.
render "$WORK/o11a" --results "$WORK/r-fail" --expected "$WORK/expected" "${good_evidence[@]}" --sha 1111111111111111111111111111111111111111 --pr 7
render "$WORK/o11b" --results "$WORK/r-clean" --expected "$WORK/expected" "${good_evidence[@]}" --sha 2222222222222222222222222222222222222222 --pr 7 --previous "$WORK/o11a/report.md"
check "delta reports the fixed row" yes "$(grep -q 'K9 live corpus.*| ↑ improved (1 fewer blocking failures)' "$WORK/o11b/report.md" && echo yes || echo no)"
render "$WORK/o11c" --results "$WORK/r-clean" --expected "$WORK/expected" "${good_evidence[@]}" --sha 1111111111111111111111111111111111111111 --pr 7 --previous "$WORK/o11a/report.md"
check "same commit is not compared" yes "$(grep -q 'no comparable baseline' "$WORK/o11c/report.md" && echo yes || echo no)"
render "$WORK/o11d" --results "$WORK/r-clean" --expected "$WORK/expected" "${good_evidence[@]}" --sha 2222222222222222222222222222222222222222 --pr 8 --previous "$WORK/o11a/report.md"
check "another PR is not compared" yes "$(grep -q 'no comparable baseline' "$WORK/o11d/report.md" && echo yes || echo no)"
render "$WORK/o11e" --results "$WORK/r-clean" --expected "$WORK/expected" "${good_evidence[@]}" --sha 2222222222222222222222222222222222222222 --pr 7 --lane other --previous "$WORK/o11a/report.md"
check "another profile is not compared" yes "$(grep -q 'no comparable baseline' "$WORK/o11e/report.md" && echo yes || echo no)"
render "$WORK/o11f" --results "$WORK/r-warn" --expected "$WORK/expected" "${good_evidence[@]}" --sha 1111111111111111111111111111111111111111 --pr 7
render "$WORK/o11g" --results "$WORK/r-clean" --expected "$WORK/expected" "${good_evidence[@]}" --sha 2222222222222222222222222222222222222222 --pr 7 --previous "$WORK/o11f/report.md"
check "delta reports a cleared warning" yes "$(grep -q 'K9 live corpus.*| ↑ fewer warnings' "$WORK/o11g/report.md" && echo yes || echo no)"
# A ledgered failure the PR starts touching goes from advisory to blocking with
# the failed count unchanged: that is a regression, not "fewer advisories".
render "$WORK/o11i" --results "$WORK/r-fail" --expected "$WORK/expected" --ledger "$WORK/ledger-b" "${good_evidence[@]}" --sha 1111111111111111111111111111111111111111 --pr 7
render "$WORK/o11j" --results "$WORK/r-fail" --expected "$WORK/expected" --ledger "$WORK/ledger-b" --changed "$WORK/changed-b" "${good_evidence[@]}" --sha 2222222222222222222222222222222222222222 --pr 7 --previous "$WORK/o11i/report.md"
check "advisory becoming blocking is a regression" yes "$(grep -q 'K9 live corpus.*| ↓ regressed (1 more blocking failures)' "$WORK/o11j/report.md" && echo yes || echo no)"
render "$WORK/o11k" --results "$WORK/r-fail" --expected "$WORK/expected" --ledger "$WORK/ledger-b" "${good_evidence[@]}" --sha 3333333333333333333333333333333333333333 --pr 7 --previous "$WORK/o11j/report.md"
check "blocking becoming advisory is an improvement" yes "$(grep -q 'K9 live corpus.*| ↑ improved (1 fewer blocking failures)' "$WORK/o11k/report.md" && echo yes || echo no)"
printf '%s\n' a.k9.ncl b.k9.ncl c.k9.ncl > "$WORK/expected-abc"
{ rec a.k9.ncl pass '[]'; rec b.k9.ncl pass '[]'; rec c.k9.ncl pass '[]'; } > "$WORK/r-clean-abc"
render "$WORK/o11h" --results "$WORK/r-clean-abc" --expected "$WORK/expected-abc" "${good_evidence[@]}" --sha 2222222222222222222222222222222222222222 --pr 7 --previous "$WORK/o11a/report.md"
check "a corpus that gained a file is not compared" yes "$(grep -q 'K9 live corpus.*| — no comparable baseline' "$WORK/o11h/report.md" && echo yes || echo no)"
check "baseline of garbage is null" null "$(printf 'no marker here\n' > "$WORK/garbage"; bash "$GRID" baseline "$WORK/garbage")"
check "baseline of a corrupt marker is null" null "$(printf '<!-- k9-baseline:bm90anNvbg== -->\n' > "$WORK/corrupt"; bash "$GRID" baseline "$WORK/corrupt")"
check "baseline of a real report round-trips" 7 "$(bash "$GRID" baseline "$WORK/o11a/report.md" | jq -r .pr)"
# A marker is whatever the last comment held: two objects, or an object with
# trailing junk, must still yield exactly one value (null), never two.
two=$(printf '{"categories":[]}{"categories":[]}' | base64 -w0)
printf '<!-- k9-baseline:%s -->\n' "$two" > "$WORK/two-objects"
check "baseline of two objects is one null" "null" "$(bash "$GRID" baseline "$WORK/two-objects" | tr '\n' '|' | sed 's/|$//')"
junk="$(printf '{"categories":[]}' | base64 -w0)="
printf '<!-- k9-baseline:%s -->\n' "$junk" > "$WORK/trailing-junk"
check "baseline with trailing junk is one value" 1 "$(bash "$GRID" baseline "$WORK/trailing-junk" | wc -l)"
render "$WORK/o11l" --results "$WORK/r-clean" --expected "$WORK/expected" "${good_evidence[@]}" --sha 2222222222222222222222222222222222222222 --pr 7 --previous "$WORK/two-objects"
check "a forged two-object baseline still renders" yes "$(grep -q 'no comparable baseline' "$WORK/o11l/report.md" && echo yes || echo no)"

# 13. A findings array that holds something other than objects is not a
# gradeable record (orange), never a jq error that leaves no report.
{ rec a.k9.ncl pass '[]'; jq -nc '{file: "b.k9.ncl", verdict: "pass", findings: ["bad"]}'; } > "$WORK/r-bad-finding"
render "$WORK/o13a" --results "$WORK/r-bad-finding" --expected "$WORK/expected" "${good_evidence[@]}"
check "a non-object finding element is orange" orange "$(state "$WORK/o13a")"
check "the non-object finding names its file" "Unexpected, duplicate or invalid result." "$(reason "$WORK/o13a" b.k9.ncl)"

# 14. Contributor-controlled ids and validator text cannot write Markdown or
# HTML into the lane's own comment.
evil='![x](https://e.invalid/i)_[y]*.k9.ncl'
printf '%s\n' "$evil" > "$WORK/expected-evil"
rec "$evil" fail '[{"severity":"error","rule":"K9-S002","layer":"L1","message":"see <b>here</b> [z](https://e.invalid) \\ `x`"}]' > "$WORK/r-evil"
render "$WORK/o14" --results "$WORK/r-evil" --expected "$WORK/expected-evil" "${good_evidence[@]}"
check "markdown image syntax is escaped in the id" no "$(grep -q '!\[x\](' "$WORK/o14/report.md" && echo yes || echo no)"
check "the escaped id is still legible" yes "$(grep -q '&#33;&#91;x&#93;&#40;https://e.invalid/i&#41;&#95;&#91;y&#93;&#42;.k9.ncl' "$WORK/o14/report.md" && echo yes || echo no)"
check "markdown link syntax is escaped in the reason" no "$(grep -q '\[z\](https' "$WORK/o14/report.md" && echo yes || echo no)"
check "html and backslashes are escaped in the reason" yes "$(grep -q '&lt;b&gt;here&lt;/b&gt; &#91;z&#93;&#40;https://e.invalid&#41; &#92; &#96;x&#96;' "$WORK/o14/report.md" && echo yes || echo no)"
rec '@hyperpolymath/owners.k9.ncl' fail '[{"severity":"error","rule":"K9-S002","layer":"L1","message":"ping @someone"}]' > "$WORK/r-mention"
printf '%s\n' '@hyperpolymath/owners.k9.ncl' > "$WORK/expected-mention"
render "$WORK/o14b" --results "$WORK/r-mention" --expected "$WORK/expected-mention" "${good_evidence[@]}"
check "an @-mention in an id or a reason is not live" no "$(grep -q '@hyperpolymath\|@someone' "$WORK/o14b/report.md" && echo yes || echo no)"

# 12. Usage errors exit 2.
check "missing --results exits 2" 2 "$(bash "$GRID" render --out "$WORK/o12" >/dev/null 2>&1; echo $?)"
check "unknown subcommand exits 2" 2 "$(bash "$GRID" frobnicate >/dev/null 2>&1; echo $?)"

echo
echo "k9-grid-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
