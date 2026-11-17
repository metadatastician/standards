#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# departures-test.sh — fixture suite for scripts/departures.sh, the departures
# ledger (3-practice/DEPARTURES.adoc). Every fixture is a throwaway git
# repository in a temp dir. It proves:
#   * every `validate` refusal, each naming its line, including check errors
#     that issue-evidence.sh reports and departures.sh maps back to the line;
#   * the three verdicts: present (every check holds), RESOLVED (a check no
#     longer holds, named) and unevaluated (none fails, one could not run);
#   * `check` fails on a RESOLVED row and on a malformed ledger, and passes on
#     present and unevaluated rows (positive and negative control);
#   * `prune` deletes exactly the RESOLVED rows, keeps every other line
#     byte for byte, is idempotent, and never touches a malformed ledger;
#   * injection attempts in every string field stay inert;
#   * the repository's own ledger validates and every row is present at HEAD;
#   * MUTANTS: this suite, run against copies of the script with the verdict
#     inverted or with prune widened to unevaluated rows, reports failures.
#
# Run: bash scripts/tests/departures-test.sh
# DEPARTURES_SH overrides the script under test (the mutants use it).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DS="${DEPARTURES_SH:-$SCRIPT_DIR/../departures.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

# ok LABEL: record a pass.
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
# ko LABEL: record a failure.
ko() { echo "FAIL: $1"; fail=$((fail + 1)); }
# verdict LABEL CMD...: PASS when CMD succeeds.
verdict() {
  local label="$1"
  shift
  if "$@"; then ok "$label"; else ko "$label"; fi
}
# run CMD...: sets OUT, ERR and RC.
run() {
  RC=0
  "$@" >"$WORK/out" 2>"$WORK/err" || RC=$?
  OUT="$(cat "$WORK/out")"
  ERR="$(cat "$WORK/err")"
}
# expect_rc LABEL WANT CMD...: PASS when CMD exits WANT.
expect_rc() {
  local label="$1" want="$2"
  shift 2
  run "$@"
  if [ "$RC" = "$want" ]; then ok "$label"
  else ko "$label — expected exit $want, got $RC; stderr: $(printf '%s' "$ERR" | head -3 | tr '\n' '|')"; fi
}
# expect_err LABEL NEEDLE CMD...: PASS on exit 2 with NEEDLE on stderr.
expect_err() {
  local label="$1" needle="$2"
  shift 2
  run "$@"
  if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -qF -- "$needle"; then ok "$label"
  else ko "$label — expected exit 2 with '$needle', got $RC; stderr: $(printf '%s' "$ERR" | head -3 | tr '\n' '|')"; fi
}
# out_line LINE: $OUT has exactly the line LINE.
out_line() { printf '%s\n' "$OUT" | grep -qFx -- "$1"; }
# out_has TEXT: $OUT contains TEXT.
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
# err_has TEXT: $ERR contains TEXT.
err_has() { printf '%s\n' "$ERR" | grep -qF -- "$1"; }
# rc_and WANT CMD...: RC is WANT and CMD succeeds.
rc_and() { local want="$1"; shift; [ "$RC" = "$want" ] && "$@"; }

# drow ID CHECKS_JSON [FIX] [EXTRA_JSON] — one canonical ledger line.
drow() {
  jq -c -S -n --arg id "$1" --argjson checks "$2" --arg fix "${3:-open}" --argjson extra "${4:-{\}}" \
    '{id: $id, repo: "o/r", ruling: "CLAUDE.md, Test rule", claim: "The defect is present.",
      checks: $checks, fix: $fix, added: "2026-11-17"} + $extra'
}
L="$WORK/departures.jsonl"
# ledger LINE...: writes the lines to $L.
ledger() { printf '%s\n' "$@" >"$L"; }

# --- fixture repository --------------------------------------------------------
R="$WORK/repo"
mkdir -p "$R/scripts" "$R/docs" "$R/legacy"
cd "$R" || exit 2
git init -q -b main .
git config user.email t@example.invalid
git config user.name test
git config commit.gpgsign false
printf 'defect A\ndefect B\n--count\n' >docs/a.adoc
printf 'old\n' >legacy/x.a2ml
printf '#!/usr/bin/env bash\nexit 0\n' >scripts/pass.sh
printf '#!/usr/bin/env bash\nexit 2\n' >scripts/cannot.sh
chmod +x scripts/pass.sh scripts/cannot.sh
git add .
git commit -qm "one: defects A and B"
C1="$(git rev-parse HEAD)"
printf 'defect A\n--count\n' >docs/a.adoc
git commit -qam "two: fix B"
C2="$(git rev-parse HEAD)"
git checkout -q -b gone
git rm -q legacy/x.a2ml
git commit -qm "the last legacy file goes"
GONE="$(git rev-parse HEAD)"
git checkout -q main

A_PRESENT="$(drow defect-a '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"^defect A$"}]')"
B_GONE="$(drow defect-b '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"^defect B$"}]' owner-only)"
UNEVAL="$(drow cannot-run '[{"kind":"script","path":"scripts/cannot.sh"}]' blocked '{"blocked_on":"a toolchain"}')"
MIXED="$(drow mixed '[{"kind":"path-present","path":"docs/a.adoc"},{"kind":"path-present","path":"docs/gone.adoc"}]')"

echo "=== validate: every refusal names its line ==="
ledger "$A_PRESENT"
expect_rc "a good row validates" 0 bash "$DS" validate "$L"
: >"$L"
expect_rc "an empty ledger validates" 0 bash "$DS" validate "$L"
ledger "$A_PRESENT" "$(drow defect-a '[{"kind":"path-present","path":"x"}]')"
expect_err "duplicate id" "departures.jsonl:2: duplicate id: the same id is already on line 1" bash "$DS" validate "$L"
ledger "$(drow 'Bad_Id' '[{"kind":"path-present","path":"x"}]')"
expect_err "id that is not a slug" ":1: id must be a lower-case slug" bash "$DS" validate "$L"
ledger "$(drow "$(printf 'a%.0s' $(seq 65))" '[{"kind":"path-present","path":"x"}]')"
expect_err "id longer than 64" ":1: id must be a lower-case slug" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' | jq -c 'del(.ruling)')"
expect_err "missing field" ':1: missing field "ruling"' bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' open '{"where":["x"]}')"
expect_err "unknown field" ':1: unknown field "where"' bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' wontfix)"
expect_err "fix outside the vocabulary" ':1: fix is not in the vocabulary: "wontfix"' bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' blocked)"
expect_err "blocked without blocked_on" ":1: fix blocked requires blocked_on" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' open '{"blocked_on":"x"}')"
expect_err "blocked_on without fix blocked" ":1: blocked_on is allowed only with fix blocked" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' open '{"repo":"no-slash"}')"
expect_err "repo that is not OWNER/NAME" ":1: repo must be OWNER/NAME" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' open '{"added":"2026-02-30"}')"
expect_err "impossible date" ":1: added must be a real calendar date" bash "$DS" validate "$L"
ledger "$(drow x1 '[]')"
expect_err "empty checks" ":1: checks must be a non-empty array" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' open "{\"claim\":\"$(printf 'c%.0s' $(seq 601))\"}")"
expect_err "claim longer than 600" ":1: claim is longer than 600 characters" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' open '{"claim":"a <!-- x --> b"}')"
expect_err "claim with a comment delimiter" ":1: claim contains an HTML comment delimiter" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"x"}]' open '{"ruling":"a --> b"}')"
expect_err "ruling with a comment delimiter" ":1: ruling contains an HTML comment delimiter" bash "$DS" validate "$L"
# Check errors come from issue-evidence.sh and are mapped back to this ledger.
ledger "$A_PRESENT" "$(drow x2 '[{"kind":"path-anywhere","path":"x"}]')"
expect_err "unknown check kind (delegated, mapped to the line)" "departures.jsonl:2: checks[0].kind is not in the vocabulary" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"grep-present","path":"x","pattern":"a("}]')"
expect_err "invalid ERE (delegated)" "departures.jsonl:1: pattern is not a valid POSIX ERE" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"path-present","path":"../x"}]')"
expect_err "path with .. (delegated)" 'departures.jsonl:1: checks[0].path has an empty, "." or ".." component' bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"script","path":"docs/a.adoc"}]')"
expect_err "script outside scripts/ (delegated)" "checks[0].path must be under scripts/ or tests/" bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"script","path":"scripts/pass.sh","args":["-x"]}]')"
expect_err "script args are refused (delegated)" 'checks[0]: unknown field "args"' bash "$DS" validate "$L"
ledger "$(drow x1 '[{"kind":"script","path":"scripts/not-there.sh"}]')"
expect_rc "validate does not read the tree: an absent script is schema-valid" 0 bash "$DS" validate "$L"
ledger "$A_PRESENT" "$(drow x2 '[{"kind":"path-present","path":"x"}]' | jq -c '{id} + .')"
expect_err "non-JCS line" ":2: not JCS canonical" bash "$DS" validate "$L"
ledger "$A_PRESENT" "not json"
expect_err "non-JSON line" ":2: not a single JSON value" bash "$DS" validate "$L"
ledger "$A_PRESENT" "" "$(drow x2 '[{"kind":"path-present","path":"x"}]')"
expect_err "blank line" ":2: blank line" bash "$DS" validate "$L"
ledger "$A_PRESENT" '[1]'
expect_err "a line that is not an object" ":2: the line is not a JSON object" bash "$DS" validate "$L"
printf '%s' "$A_PRESENT" >"$L"
expect_err "missing final line feed" ":1: missing final line feed" bash "$DS" validate "$L"
printf '%s\n' "$(drow x1 '[{"kind":"path-present","path":"x"}]' open '{"claim":"café"}' | sed 's/é/\xff/')" >"$L"
expect_err "invalid UTF-8" ":1: not valid UTF-8" bash "$DS" validate "$L"
printf '%s\n\0\n' "$A_PRESENT" >"$L"
expect_err "NUL byte" "contains a NUL byte" bash "$DS" validate "$L"
expect_err "a missing ledger" "ledger not found" bash "$DS" validate "$WORK/none.jsonl"
for f in id ruling claim blocked_on pattern; do
  case "$f" in
    id) r="$(drow "$(printf 'a\nb')" '[{"kind":"path-present","path":"x"}]')" ;;
    ruling) r="$(drow x1 '[{"kind":"path-present","path":"x"}]' open '{"ruling":"a\nb"}')" ;;
    claim) r="$(drow x1 '[{"kind":"path-present","path":"x"}]' open '{"claim":"a\nb"}')" ;;
    blocked_on) r="$(drow x1 '[{"kind":"path-present","path":"x"}]' blocked '{"blocked_on":"a\nb"}')" ;;
    pattern) r="$(drow x1 '[{"kind":"grep-present","path":"x","pattern":"a\nb"}]')" ;;
  esac
  ledger "$r"
  run bash "$DS" validate "$L"
  if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -qE 'control character|lower-case slug'; then ok "a newline in $f is refused"
  else ko "a newline in $f — rc=$RC stderr=$(printf '%s' "$ERR" | head -2 | tr '\n' '|')"; fi
done

echo "=== verdicts: present, RESOLVED, unevaluated ==="
ledger "$A_PRESENT" "$B_GONE" "$UNEVAL" "$MIXED"
run bash "$DS" report "$L"
verdict "report exits 0 with RESOLVED rows" [ "$RC" = 0 ]
verdict "a row whose checks all hold is present" out_line "present      defect-a  [open]"
verdict "a row whose check no longer holds is RESOLVED, the check named" \
  out_line 'RESOLVED     defect-b  [owner-only]  no longer holds: [0] grep-present docs/a.adoc'
verdict "a row whose script could not run is unevaluated, the check named" \
  out_line 'unevaluated  cannot-run  [blocked]  not evaluated: [0] script scripts/cannot.sh'
verdict "only the failing check of a multi-check row is named" \
  out_line 'RESOLVED     mixed  [open]  no longer holds: [1] path-present docs/gone.adoc'
verdict "the summary gives counts and the denominator" \
  out_has "4 of 4 rows evaluated at ${C2:0:12}"
verdict "the summary counts each verdict" out_has "1 present, 2 RESOLVED, 1 unevaluated"
run bash "$DS" report --ref "$C1" "$L"
verdict "at the parent commit the fixed defect is still present" out_line "present      defect-b  [owner-only]"
verdict "the summary names the evaluated commit" out_has "at ${C1:0:12}"
# A script runs only on a clean checkout equal to the commit (the asymmetry
# with every other check, kept from issue-evidence.sh): elsewhere unevaluated.
ledger "$(drow runs '[{"kind":"script","path":"scripts/pass.sh"}]')"
run bash "$DS" report "$L"
verdict "a script that exits 0 on the clean checkout holds" out_line "present      runs  [open]"
run bash "$DS" report --ref "$C1" "$L"
verdict "a script at a ref that is not the checkout is unevaluated, never present" \
  out_line 'unevaluated  runs  [open]  not evaluated: [0] script scripts/pass.sh'
printf 'dirty\n' >>docs/a.adoc
run bash "$DS" report "$L"
verdict "a script in a modified checkout is unevaluated" \
  out_line 'unevaluated  runs  [open]  not evaluated: [0] script scripts/pass.sh'
git checkout -q -- docs/a.adoc
# The idiom for "some tracked, non-empty file matches G": tree-grep-absent
# with a pattern no line can match holds exactly while G selects such a file.
ledger "$(drow legacy-left '[{"kind":"tree-grep-absent","glob":"**/*.a2ml","pattern":"a^"}]' blocked '{"blocked_on":"a translator"}')"
run bash "$DS" report "$L"
verdict "the any-file idiom is present while a matching file is tracked" out_line "present      legacy-left  [blocked]"
run bash "$DS" report --ref "$GONE" "$L"
verdict "the any-file idiom is RESOLVED when the last matching file goes" \
  out_line 'RESOLVED     legacy-left  [blocked]  no longer holds: [0] tree-grep-absent **/*.a2ml'
ledger "$A_PRESENT" "not json"
run bash "$DS" report "$L"
verdict "report on a malformed ledger exits 0 and says it is invalid" rc_and 0 out_has "INVALID"
ledger "$A_PRESENT"
expect_rc "an unresolvable --ref is an internal error (3)" 3 bash "$DS" report --ref no-such-ref "$L"
expect_err "an unknown option is a usage error" "unknown option" bash "$DS" report --bogus "$L"

echo "=== check: the gate (positive and negative control) ==="
ledger "$A_PRESENT" "$UNEVAL"
expect_rc "check passes when every row is present or unevaluated" 0 bash "$DS" check "$L"
ledger "$A_PRESENT" "$B_GONE"
run bash "$DS" check "$L"
verdict "check fails (1) on a RESOLVED row and names it" \
  rc_and 1 err_has "departures.jsonl:2: defect-b: RESOLVED"
expect_rc "the same ledger passes check at the commit before the fix" 0 bash "$DS" check --ref "$C1" "$L"
ledger "$A_PRESENT" "not json"
expect_rc "check fails (2) on a malformed ledger" 2 bash "$DS" check "$L"
ledger "$A_PRESENT" "$(drow other '[{"kind":"path-present","path":"docs/gone.adoc"}]' open '{"repo":"x/y"}')"
expect_rc "check --repo leaves another repository's rows unevaluated" 0 bash "$DS" check --repo o/r "$L"
expect_rc "check without --repo evaluates every row" 1 bash "$DS" check "$L"
run bash "$DS" report --repo O/R "$L"
verdict "report --repo matches case-insensitively and says how many rows it left out" \
  rc_and 0 out_has "1 of 2 rows evaluated"

echo "=== prune: deletes exactly the RESOLVED rows ==="
ledger "$A_PRESENT" "$B_GONE" "$UNEVAL" "$MIXED"
cp "$L" "$WORK/before.jsonl"
run bash "$DS" prune "$L"
verdict "prune exits 0" [ "$RC" = 0 ]
verdict "prune prints each removed row as LEDGER:LINE ID" \
  [ "$OUT" = "removed $L:2 defect-b
removed $L:4 mixed" ]
sed -n '1p;3p' "$WORK/before.jsonl" >"$WORK/want.jsonl"
verdict "prune keeps every other line byte for byte" cmp -s "$L" "$WORK/want.jsonl"
cp "$L" "$WORK/after1.jsonl"
run bash "$DS" prune "$L"
verdict "prune is idempotent: a second run removes nothing" rc_and 0 [ -z "$OUT" ]
verdict "prune is idempotent: a second run leaves the bytes alone" cmp -s "$L" "$WORK/after1.jsonl"
expect_rc "check passes after prune" 0 bash "$DS" check "$L"
ledger "$A_PRESENT" "$B_GONE" "not json"
cp "$L" "$WORK/bad.jsonl"
expect_rc "prune refuses a malformed ledger (2)" 2 bash "$DS" prune "$L"
verdict "prune leaves a malformed ledger untouched" cmp -s "$L" "$WORK/bad.jsonl"
ledger "$A_PRESENT" "$B_GONE"
cp "$L" "$WORK/ref.jsonl"
run bash "$DS" prune --ref "$C1" "$L"
verdict "prune at a ref where every row is present removes nothing" rc_and 0 cmp -s "$L" "$WORK/ref.jsonl"
ledger "$A_PRESENT" "$B_GONE" "$(drow other '[{"kind":"path-present","path":"docs/gone.adoc"}]' open '{"repo":"x/y"}')"
run bash "$DS" prune --repo o/r "$L"
verdict "prune --repo removes only that repository's RESOLVED rows" \
  rc_and 0 [ "$(jq -r .id "$L" | tr '\n' ' ')" = "defect-a other " ]

echo "=== injection attempts stay inert ==="
SENT="PWNED"
# sentinel_absent: no injection payload created its file.
sentinel_absent() { [ ! -e "$R/$SENT" ] && [ ! -e "$WORK/$SENT" ] && [ ! -e "$SCRIPT_DIR/$SENT" ]; }
# inert LABEL ROW: validate and check agree (both 2, or 0 then 0 or 1); no sentinel appears.
inert() {
  local label="$1" vrc
  ledger "$2"
  run bash "$DS" validate "$L"
  vrc="$RC"
  run bash "$DS" check "$L"
  if ! sentinel_absent; then ko "$label — SIDE EFFECT: $SENT exists"
  elif { [ "$vrc" = 2 ] && [ "$RC" = 2 ]; } || { [ "$vrc" = 0 ] && [ "$RC" -le 1 ]; }; then
    ok "$label (validate=$vrc check=$RC, no side effect)"
  else ko "$label — validate=$vrc check=$RC"; fi
}
for p in "\$(touch $SENT)" "\`touch $SENT\`" "; touch $SENT; rm -rf ." "x\" ; touch $SENT; #" "\$(rm -rf $R)"; do
  pj="$(jq -n --arg p "$p" '$p')"
  inert "id: $p" "$(drow "$p" '[{"kind":"path-present","path":"docs/a.adoc"}]')"
  inert "ruling: $p" "$(drow x1 '[{"kind":"path-present","path":"docs/a.adoc"}]' open "{\"ruling\":$pj}")"
  inert "claim: $p" "$(drow x1 '[{"kind":"path-present","path":"docs/a.adoc"}]' open "{\"claim\":$pj}")"
  inert "blocked_on: $p" "$(drow x1 '[{"kind":"path-present","path":"docs/a.adoc"}]' blocked "{\"blocked_on\":$pj}")"
  inert "repo: $p" "$(drow x1 '[{"kind":"path-present","path":"docs/a.adoc"}]' open "{\"repo\":$pj}")"
  inert "pattern: $p" "$(drow x1 "[{\"kind\":\"grep-present\",\"path\":\"docs/a.adoc\",\"pattern\":$pj}]")"
  inert "path: $p" "$(drow x1 "[{\"kind\":\"path-present\",\"path\":$pj}]")"
  inert "glob: $p" "$(drow x1 "[{\"kind\":\"tree-grep-absent\",\"glob\":$pj,\"pattern\":\"x\"}]")"
done
verdict "the fixture survived the rm -rf payloads" [ -d "$R/scripts" ]
ledger "$(drow x1 '[{"kind":"grep-present","path":"docs/a.adoc","pattern":"--count"}]')"
run bash "$DS" report "$L"
verdict "a leading - in a pattern is a pattern, never an option" out_line "present      x1  [open]"
verdict "the fixture checkout is still clean" [ -z "$(git status --porcelain)" ]

echo "=== the live ledger ==="
cd "$REPO_ROOT" || exit 2
LIVE=.machine_readable/departures.jsonl
expect_rc "the repository's own ledger validates" 0 bash "$DS" validate "$LIVE"
expect_rc "the repository's own ledger passes check at HEAD" 0 bash "$DS" check "$LIVE"
run bash "$DS" report "$LIVE"
rows="$(grep -c '' "$LIVE")"
verdict "every row of the live ledger is present at HEAD ($rows rows)" \
  rc_and 0 [ "$(printf '%s\n' "$OUT" | grep -c '^present ')" = "$rows" ]
cd "$R" || exit 2

if [ -z "${DEPARTURES_MUTANT:-}" ]; then
  echo "=== mutants: the suite kills a broken gate ==="
  mkdir -p "$WORK/mut"
  cp "$SCRIPT_DIR/../issue-evidence.sh" "$WORK/mut/issue-evidence.sh"
  # mutant LABEL SED_EXPR: the suite, run against the script with SED_EXPR applied, must fail.
  mutant() {
    local label="$1" m="$WORK/mut/departures.sh" rc=0 out nf
    sed -e "$2" "$DS" >"$m"
    if cmp -s "$DS" "$m"; then ko "mutant ($label): the mutation did not apply"; return; fi
    out="$(DEPARTURES_SH="$m" DEPARTURES_MUTANT=1 bash "$SCRIPT_DIR/$(basename "$0")" 2>&1)" || rc=$?
    nf="$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)"
    if [ "$rc" -ne 0 ] && [ "$nf" -gt 0 ]; then ok "mutant ($label) is killed ($nf failures)"
    else ko "mutant ($label) survived (exit $rc)"; fi
  }
  # 1. The verdict: a row whose check no longer holds reads as present.
  # shellcheck disable=SC2016  # sed program text, not shell
  mutant "RESOLVED reads as present" 's/(\.holds == false) as \$resolved/(.holds == "never") as $resolved/'
  # 2. prune: deletes unevaluated rows as well as RESOLVED ones.
  # shellcheck disable=SC2016  # sed program text, not shell
  mutant "prune widened to unevaluated rows" 's/select(\.status == "RESOLVED") | \.n/select(.status != "present") | .n/'
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
