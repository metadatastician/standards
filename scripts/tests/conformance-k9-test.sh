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
