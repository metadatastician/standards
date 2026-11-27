#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -uo pipefail

# scripts/conformance-k9.sh: which K9 files `enumerate` selects (the canon
# checkouts are never the caller's own), that `selftest` and `validate` record
# their status for the later steps, and that an unknown subcommand is a usage
# error. The validator is a stub, so the test needs no network and no nickel.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE="${LANE_UNDER_TEST:-$ROOT/scripts/conformance-k9.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# A caller repository: its own K9 files plus both canon checkouts.
W="$T/w"; mkdir -p "$W/sub" "$W/.k9-canon/x" "$W/.standards-checkout/y" "$W/9-archive" "$W/.tmp"
git -C "$W" init -q -b main; git -C "$W" config user.email t@t; git -C "$W" config user.name t
for f in a.k9.ncl sub/b.k9 .k9-canon/x/c.k9.ncl .standards-checkout/y/d.k9 9-archive/e.k9; do : > "$W/$f"; done
git -C "$W" add -A; git -C "$W" commit -q -m init

enum() { # enum -> sets rc; leaves $W/.tmp/expected and $T/env
  : > "$T/env"; rm -f "$W/.tmp/expected"
  (cd "$W" && env RUNNER_TEMP="$W/.tmp" GITHUB_ENV="$T/env" GITHUB_EVENT_NAME=push BASE_SHA= HEAD_SHA=HEAD \
      LEDGER=.machine_readable/k9-contract-debt.txt ADVISORY=false bash "$LANE" enumerate >"$T/enum.out" 2>&1); rc=$?
}
enum
exp=$(cat "$W/.tmp/expected" 2>/dev/null)
{ [ $rc -eq 0 ] && grep -qx 'a.k9.ncl' <<<"$exp" && grep -qx 'sub/b.k9' <<<"$exp" \
  && ! grep -q 'k9-canon' <<<"$exp" && ! grep -q 'standards-checkout' <<<"$exp" && ! grep -q '9-archive' <<<"$exp"; } \
  && ok "enumerate selects the caller's K9 files, never the canon checkouts or 9-archive" || bad "enumerate selection: rc=$rc expected=[$exp] out=$(cat "$T/enum.out")"
grep -q '^BASE_UNRESOLVED=' "$T/env" && ok "enumerate records BASE_UNRESOLVED for the grid step" || bad "no BASE_UNRESOLVED in GITHUB_ENV"

# selftest and validate record their statuses with a stub validator
C="$T/canon"; mkdir -p "$C/1-formats/k9/tools"
cat > "$C/1-formats/k9/tools/k9-validate.sh" <<'V'
#!/usr/bin/env bash
case "$1" in --self-test) echo "self-test ran"; exit 0 ;; esac
printf '{"file":"%s","verdict":"pass"}\n' "${@: -1}"; exit "${STUB_RC:-0}"
V
: > "$T/env"
(cd "$W" && env CANON="$C" RUNNER_TEMP="$W/.tmp" GITHUB_ENV="$T/env" bash "$LANE" selftest >/dev/null 2>&1)
grep -qx 'SELFTEST_CODE=0' "$T/env" && ok "selftest records SELFTEST_CODE" || bad "selftest: $(cat "$T/env")"
: > "$T/env"
(cd "$W" && env CANON="$C" STUB_RC=3 RUNNER_TEMP="$W/.tmp" GITHUB_ENV="$T/env" bash "$LANE" validate >/dev/null 2>&1)
{ grep -qx 'CORPUS_CODE=3' "$T/env" && [ "$(wc -l < "$W/.tmp/results.jsonl")" -eq 2 ]; } \
  && ok "validate runs every enumerated file and records the worst exit status" || bad "validate: $(cat "$T/env") results=$(cat "$W/.tmp/results.jsonl" 2>/dev/null)"

# base: the lane's own checker on the base tree. A real renderer, a stub validator.
mkdir -p "$C/scripts/lib"; cp "$ROOT/scripts/k9-grid.sh" "$C/scripts/"; cp "$ROOT/scripts/lib/k9-grid.jq" "$C/scripts/lib/"
B="$T/b"; mkdir -p "$B"; git -C "$B" init -q -b main; git -C "$B" config user.email t@t; git -C "$B" config user.name t
: > "$B/a.k9.ncl"; git -C "$B" add -A; git -C "$B" commit -q -m one; B1=$(git -C "$B" rev-parse HEAD)
: > "$B/b.k9.ncl"; git -C "$B" add -A; git -C "$B" commit -q -m two; B2=$(git -C "$B" rev-parse HEAD)
mkdir -p "$B/.tmp"; : > "$B/.tmp/selftest.log"; : > "$B/.tmp/typecheck.log"
base() { # base BASE_SHA [EVENT]
  rm -rf "$B/.tmp/k9-base-grid" "$B/.tmp/base-error"; : > "$T/env"
  (cd "$B" && env CANON="$C" RUNNER_TEMP="$B/.tmp" GITHUB_ENV="$T/env" GITHUB_EVENT_NAME="${2:-pull_request}" BASE_SHA="$1" HEAD_SHA="$B2" \
      LEDGER=.machine_readable/k9-contract-debt.txt ADVISORY=false GITHUB_RUN_ID=1 GITHUB_REPOSITORY=x/y SELFTEST_CODE=0 TYPECHECK_CODE=0 \
      bash "$LANE" base >"$T/base.out" 2>&1); rc=$?
}
base ""
{ [ $rc -eq 0 ] && grep -q 'no base commit' "$B/.tmp/base-error"; } && ok "base: no base commit is said, not blank" || bad "base none: rc=$rc $(cat "$B/.tmp/base-error" 2>&1)"
base deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
{ [ $rc -eq 0 ] && grep -q 'cannot resolve the base commit' "$B/.tmp/base-error" && [ ! -d "$B/.tmp/k9-base-grid" ]; } && ok "base: an unresolvable base reports an error and no grid" || bad "base unresolvable: rc=$rc $(cat "$B/.tmp/base-error" 2>&1)"
base "$B1"
{ [ $rc -eq 0 ] && [ -s "$B/.tmp/k9-base-grid/report.json" ] && [ ! -e "$B/.tmp/base-error" ] && [ "$(jq -r .sha "$B/.tmp/k9-base-grid/report.json")" = "$B1" ]; } \
  && ok "base: a good base is graded with this checker and leaves its report" || bad "base good: rc=$rc $(cat "$T/base.out")"
[ "$(wc -l < "$B/.tmp/base/results.jsonl")" -eq 1 ] && ok "base: it validates the base tree's files (one), not the head's (two)" || bad "base tree files: $(cat "$B/.tmp/base/results.jsonl")"
[ -z "$(git -C "$B" worktree list | sed 1d)" ] && ok "base: the temporary worktree is removed" || bad "worktree left behind"
base "$B1" push
[ -s "$B/.tmp/k9-base-grid/report.json" ] && ok "base: a push compares with the commit it replaced" || bad "base push: $(cat "$B/.tmp/base-error" 2>&1)"


# enumerate: a declared ledger growth is found however long the messages are.
# The lane read `git log … | grep -iE '^Ratchet-exception' | grep -qF "$LEDGER"`
# under pipefail: with the matching line first and more than a pipe buffer of
# declarations, grep -q exited, the writers died of SIGPIPE, the pipeline
# reported 141 and a declared growth was annotated as undeclared. Five runs.
L="$T/l"; mkdir -p "$L/.machine_readable" "$L/.tmp"; git -C "$L" init -q -b main; git -C "$L" config user.email t@t; git -C "$L" config user.name t
: > "$L/a.k9.ncl"; : > "$L/.machine_readable/k9-contract-debt.txt"; git -C "$L" add -A; git -C "$L" commit -q -m base; L1=$(git -C "$L" rev-parse HEAD)
echo 'a.k9.ncl' > "$L/.machine_readable/k9-contract-debt.txt"
{ printf 'grow the k9 ledger\n\n'
  for i in $(seq 1 3000); do printf 'Ratchet-exception: .machine_readable/k9-contract-debt.txt — declared reason number %d\n' "$i"; done
} > "$T/long-msg"
git -C "$L" commit -qa -F "$T/long-msg"; L2=$(git -C "$L" rev-parse HEAD)
for run in 1 2 3 4 5; do
  : > "$T/env"
  (cd "$L" && env RUNNER_TEMP="$L/.tmp" GITHUB_ENV="$T/env" GITHUB_EVENT_NAME=push BASE_SHA="$L1" HEAD_SHA="$L2" \
      LEDGER=.machine_readable/k9-contract-debt.txt ADVISORY=false bash "$LANE" enumerate >"$T/enum.out" 2>&1); rc=$?
  { [ $rc -eq 0 ] && grep -qF 'grew by 1 entr(y/ies) under a declared Ratchet-exception' "$T/enum.out" \
    && [ ! -s "$L/.tmp/ledger-growth" ]; } \
    && ok "enumerate: a declaration among ~200 KB of declaration lines licenses ledger growth (run $run)" \
    || bad "enumerate: declared growth read as undeclared (run $run): rc=$rc $(tail -2 "$T/enum.out")"
done
git -C "$L" commit -q --amend -m "grow the k9 ledger, undeclared"; L2=$(git -C "$L" rev-parse HEAD); : > "$T/env"
(cd "$L" && env RUNNER_TEMP="$L/.tmp" GITHUB_ENV="$T/env" GITHUB_EVENT_NAME=push BASE_SHA="$L1" HEAD_SHA="$L2" \
    LEDGER=.machine_readable/k9-contract-debt.txt ADVISORY=false bash "$LANE" enumerate >"$T/enum.out" 2>&1); rc=$?
{ [ $rc -eq 0 ] && grep -qF 'with no Ratchet-exception naming it' "$T/enum.out" && [ -s "$L/.tmp/ledger-growth" ]; } \
  && ok "enumerate: undeclared ledger growth is annotated and exempts nothing (control)" \
  || bad "enumerate: undeclared growth control: rc=$rc $(tail -2 "$T/enum.out")"
bash "$LANE" bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "an unknown subcommand is a usage error (2)" || bad "usage exit status"

# mutant: without the .standards-checkout exclusion the selection control must fail
if [ -z "${LANE_UNDER_TEST:-}" ]; then
  sed 's#|\\.standards-checkout/##' "$ROOT/scripts/conformance-k9.sh" > "$T/mut.sh"
  cmp -s "$ROOT/scripts/conformance-k9.sh" "$T/mut.sh" && bad "mutant changed nothing"
  mkdir -p "$T/mutroot/scripts"; cp "$T/mut.sh" "$T/mutroot/scripts/conformance-k9.sh"
  if LANE_UNDER_TEST="$T/mutroot/scripts/conformance-k9.sh" bash "$0" >"$T/mut.out" 2>&1; then
    bad "the selection control did not catch a script without the .standards-checkout exclusion"
  else ok "a script without the .standards-checkout exclusion fails the selection control"; fi
fi

echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
