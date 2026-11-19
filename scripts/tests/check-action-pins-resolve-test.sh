#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
set -uo pipefail
#
# Regression cover for scripts/check-action-pins-resolve.sh.
#
# An unresolvable `uses:` produces NO check run at all — the job silently never
# runs, so the board looks green while the gate is simply absent. This checker
# is what stands between the estate and that failure mode, which means its own
# behaviour has to be pinned down precisely.
#
# The interesting property is not "does it find bad pins" but the DISTINCTION it
# draws between a determinate negative and an indeterminate answer:
#
#   404/422 from the commits endpoint  -> determinate; re-probe to say WHICH
#                                         thing is missing; counts as failure
#   403 / 5xx / network error          -> says NOTHING about the pin; must be
#                                         reported and must NOT fail the build
#
# Get that backwards in either direction and the tool is worthless: fail-closed
# on a rate limit and every consumer reddens for reasons unrelated to its code;
# fail-open silently and a genuinely dead pin sails through. It fails OPEN but
# ANNOUNCES itself, and this suite exists to hold it to that.
#
# The network is driven by a `curl` stub placed ahead of the real binary on
# PATH, keyed on the URL, so every branch is reachable offline and repeatably.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="$ROOT/scripts/check-action-pins-resolve.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }

# ── the curl stub ───────────────────────────────────────────────────────────
# The script calls: curl -sS -w $'\n%{http_code}' <headers> <url>, so the stub
# prints the body the case wants, a newline, and then the HTTP code — exactly
# the real api()'s capture contract (last line = code).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"
code="200"; body=""
[ -n "${STUB_URLLOG:-}" ] && printf '%s\n' "$url" >> "$STUB_URLLOG"
pad=""
# STUB_BIGBODY=1 emits a large PRETTY-PRINTED body (like GitHub's): an early
# newline (a piped `grep -q` matches and exits at once) followed by >64 KB of
# payload the stranded printf can then no longer write — EPIPE/SIGPIPE, and
# under pipefail the branch flips and the whole blob lands in $HTTP.
[ "${STUB_BIGBODY:-0}" = "1" ] && pad="$(printf '%*s' 150000 '' | tr ' ' x)"
mkbody() { # mkbody <key> <value> — compact one-liner, or PRETTY + 150 KB pad
  if [ -n "$pad" ]; then printf '{\n  "%s": "%s",\n  "pad": "%s"\n}' "$1" "$2" "$pad"
  else printf '{"%s":"%s"}' "$1" "$2"; fi
}
case "$url" in
  */compare/*) code="${STUB_COMPARE:-200}"; body="$(mkbody status "${STUB_COMPARE_STATUS:-behind}")" ;;
  */commits/*) code="${STUB_COMMITS:-200}";  body="$(mkbody sha object)" ;;
  *)           code="${STUB_REPO:-200}";     body="$(mkbody default_branch "${STUB_BRANCH:-main}")" ;;
esac
[ "$code" = "NETFAIL" ] && exit 22
printf '%s\n%s' "$body" "$code"
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222

# mk_repo <dir> — a target tree with one SHA-pinned external action
mk_repo() {
  local d="$1"; rm -rf "$d"; mkdir -p "$d/.github/workflows"
  cat > "$d/.github/workflows/ci.yml" <<YAML
name: ci
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@${SHA_A}
YAML
}

# mk_reusable <dir> <sha> — a target tree with ONE SHA-pinned reusable
# workflow call, the shape the #782 orphan class requires.
mk_reusable() {
  local d="$1" sha="$2"; rm -rf "$d"; mkdir -p "$d/.github/workflows"
  cat > "$d/.github/workflows/caller.yml" <<YAML
name: caller
jobs:
  scan:
    uses: hyperpolymath/standards/.github/workflows/secret-scanner-reusable.yml@${sha}
YAML
}

# expect <name> <expected-rc> <expected-substring> <target-dir>
expect() {
  local name=$1 want_rc=$2 want_sub=$3 target=$4 out rc
  out="$(bash "$CHK" "$target" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    bad "$name (rc=$rc, wanted $want_rc)"; printf '%s\n' "$out" | sed 's/^/       | /'; return
  fi
  if [ -n "$want_sub" ] && ! grep -qF -- "$want_sub" <<<"$out"; then
    bad "$name (rc ok but missing \"$want_sub\")"; printf '%s\n' "$out" | sed 's/^/       | /'; return
  fi
  ok "$name"
}

echo "== offline-decidable exits, taken before any network call =="

mkdir -p "$TMP/no-workflows"
expect "a target with no .github/workflows/ exits 0" 0 "nothing to check" "$TMP/no-workflows"

mkdir -p "$TMP/no-pins/.github/workflows"
cat > "$TMP/no-pins/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/local-thing
YAML
expect "tag pins and local refs are not SHA pins" 0 "No SHA-pinned external actions found" "$TMP/no-pins"

echo
echo "== determinate answers: the pin really is unresolvable =="

mk_repo "$TMP/r"

STUB_COMMITS=404 STUB_REPO=200 \
  expect "commits 404 + repo 200 is reported as SHA-NOT-FOUND" 1 "SHA-NOT-FOUND" "$TMP/r"

STUB_COMMITS=422 STUB_REPO=200 \
  expect "commits 422 is treated as determinate too" 1 "SHA-NOT-FOUND" "$TMP/r"

STUB_COMMITS=404 STUB_REPO=404 \
  expect "commits 404 + repo 404 is reported as REPO-NOT-FOUND" 1 "REPO-NOT-FOUND" "$TMP/r"

STUB_COMMITS=404 STUB_REPO=404 \
  expect "a determinate failure explains the remedy" 1 "Vendor the logic into this repo" "$TMP/r"

echo
echo "== indeterminate answers must NOT fail the build =="
# This is the property most easily lost in a refactor: an answer that says
# nothing about the pin must not be converted into a verdict about the pin.

STUB_COMMITS=403 \
  expect "a rate limit does not fail the build" 0 "::warning::UNVERIFIED" "$TMP/r"

STUB_COMMITS=403 \
  expect "a rate limit is explicitly not counted as a failure" 0 "NOT counted as failures" "$TMP/r"

STUB_COMMITS=500 \
  expect "a 5xx does not fail the build" 0 "::warning::UNVERIFIED" "$TMP/r"

STUB_COMMITS=NETFAIL \
  expect "a network failure surfaces as HTTP 000, not a verdict" 0 "HTTP 000" "$TMP/r"

STUB_COMMITS=404 STUB_REPO=500 \
  expect "a determinate negative with an unconfirmable repo is indeterminate" 0 "::warning::UNVERIFIED" "$TMP/r"

echo
echo "== orphan reusable pins — the four #782 witness SHAs =="
# Measured 2026-09 (estate census of 435 repos x 4 reusable workflows): every
# one of these answered 200 at the commits endpoint, and every row calling it
# died at graph resolution — 61 dead rows, zero alive. The four provenances:
#
#   7fdc2705…  squash-merge orphan: pin captured the PR head; the squash
#              discarded it. compare/main = diverged.
#   892497fe…  deleted unmerged branch; 0 PRs reference it. diverged.
#   46960521…  reachable from a LIVE remote branch, but not an ancestor of
#              main. compare/main = ahead.
#   5b1d0022…  prefix corruption — not an object at all. commits 404.
#
# The old predicate passed the first three, which is exactly the class this
# gate now exists to fail on.
SHA_W1=7fdc270500000000000000000000000000000000
SHA_W2=892497fe00000000000000000000000000000000
SHA_W3=4696052100000000000000000000000000000000
SHA_W4=5b1d002200000000000000000000000000000000
SHA_OK=81dbf2dd00000000000000000000000000000000

mk_reusable "$TMP/w1" "$SHA_W1"
STUB_COMMITS=200 STUB_COMPARE_STATUS=diverged \
  expect "witness 1 (7fdc2705… squash-merge orphan) fails as NOT-ANCESTOR" 1 "NOT-ANCESTOR" "$TMP/w1"

STUB_COMMITS=200 STUB_COMPARE_STATUS=diverged \
  expect "witness 1's failure line names the compare verdict" 1 "compare main → diverged" "$TMP/w1"

mk_reusable "$TMP/w2" "$SHA_W2"
STUB_COMMITS=200 STUB_COMPARE_STATUS=diverged \
  expect "witness 2 (892497fe… deleted branch) fails as NOT-ANCESTOR" 1 "NOT-ANCESTOR" "$TMP/w2"

mk_reusable "$TMP/w3" "$SHA_W3"
STUB_COMMITS=200 STUB_COMPARE_STATUS=ahead \
  expect "witness 3 (46960521… remote-branch-only, compare=ahead) fails as NOT-ANCESTOR" 1 "NOT-ANCESTOR" "$TMP/w3"

mk_reusable "$TMP/w4" "$SHA_W4"
STUB_COMMITS=404 STUB_REPO=200 \
  expect "witness 4 (5b1d0022… not an object) is still SHA-NOT-FOUND" 1 "SHA-NOT-FOUND" "$TMP/w4"

STUB_COMMITS=200 STUB_COMPARE=403 \
  expect "an indeterminate compare probe does NOT fail the build" 0 "::warning::UNVERIFIED" "$TMP/w3"

STUB_COMMITS=200 STUB_COMPARE=403 \
  expect "an indeterminate compare probe announces itself" 0 "ancestry: compare probe indeterminate" "$TMP/w3"

echo
echo "== ancestry probe semantics =="

mk_reusable "$TMP/ok" "$SHA_OK"
STUB_COMMITS=200 STUB_COMPARE_STATUS=behind \
  expect "a reusable pin that IS an ancestor passes (behind)" 0 "resolve upstream." "$TMP/ok"

STUB_COMMITS=200 STUB_COMPARE_STATUS=identical \
  expect "a reusable pin AT the default-branch tip passes (identical)" 0 "resolve upstream." "$TMP/ok"

STUB_COMMITS=200 STUB_COMPARE_STATUS=diverged STUB_REPO=404 \
  expect "an unprobeable default branch is indeterminate, not a verdict" 0 "ancestry: default-branch probe indeterminate" "$TMP/ok"

# The single most important guard against overreach: ordinary ACTION pins are
# fetched by object id at run time; a non-default-branch action commit works.
# The ancestry probe must NOT fire on them.
STUB_COMMITS=200 STUB_COMPARE_STATUS=diverged \
  expect "an action pin is never ancestry-probed (would false-fail real usage)" 0 "resolve upstream." "$TMP/r"

# …and prove it structurally: with only action pins present, the compare
# endpoint must not appear in the stub's access log at all.
: > "$TMP/urllog"
STUB_URLLOG="$TMP/urllog" STUB_COMMITS=200 \
  expect "action-only fixture passes" 0 "All 1 verifiable action pin(s) resolve upstream." "$TMP/r"
if grep -q "compare" "$TMP/urllog" 2>/dev/null; then
  bad "compare endpoint was called for an action-only fixture"
else
  ok "compare endpoint untouched for an action-only fixture"
fi

echo
echo "== large response bodies vs pipefail (the SIGPIPE trap) =="
# api() isolates the HTTP code from a body that can exceed 64 KB. If the
# isolation uses a `printf | grep -q` pipeline, grep exits on first match,
# printf dies on SIGPIPE, pipefail flips the branch, and the ENTIRE blob
# lands in the HTTP variable — making a healthy 200 look like an unknown
# status. Caught live against a 146 KB codeql-action compare body.
STUB_BIGBODY=1 STUB_COMMITS=200 \
  expect "a >64k commits body still parses its status code" 0 "All 1 verifiable action pin(s) resolve upstream." "$TMP/r"

STUB_BIGBODY=1 STUB_COMMITS=200 STUB_COMPARE_STATUS=behind \
  expect "a >64k compare body still yields its ancestry status" 0 "resolve upstream." "$TMP/ok"

STUB_BIGBODY=1 STUB_COMMITS=200 STUB_COMPARE_STATUS=diverged \
  expect "a >64k compare body still fails loud as NOT-ANCESTOR" 1 "NOT-ANCESTOR" "$TMP/w1"

echo
echo "== the happy path =="

STUB_COMMITS=200 \
  expect "a resolving pin passes" 0 "All 1 verifiable action pin(s) resolve upstream." "$TMP/r"

echo
echo "== pair extraction =="

# The same action pinned twice, plus a subpath pin, must collapse to the
# repository-level pairs actually worth one API call each.
rm -rf "$TMP/dedup"; mkdir -p "$TMP/dedup/.github/workflows"
cat > "$TMP/dedup/.github/workflows/a.yml" <<YAML
jobs:
  j:
    steps:
      - uses: actions/checkout@${SHA_A}
      - uses: actions/checkout@${SHA_A}
YAML
cat > "$TMP/dedup/.github/workflows/b.yml" <<YAML
jobs:
  j:
    steps:
      - uses: actions/checkout@${SHA_A}
YAML
STUB_COMMITS=200 \
  expect "a pin repeated across files is checked once" 0 "Checking 1 unique action pin(s)" "$TMP/dedup"

cat > "$TMP/dedup/.github/workflows/c.yml" <<YAML
jobs:
  j:
    steps:
      - uses: github/codeql-action/init@${SHA_B}
YAML
STUB_COMMITS=200 \
  expect "a subpath pin is resolved at the repository level" 0 "Checking 2 unique action pin(s)" "$TMP/dedup"

echo
echo "== YAML syntax independence (YAML-POLICY Y-1 / Y-3) =="

# A KYAML (flow-style) workflow quotes its values. The old line grep extracted
# NOTHING from it and reported "nothing to check" -- a dead pin sailed through.
rm -rf "$TMP/kyaml"; mkdir -p "$TMP/kyaml/.github/workflows"
cat > "$TMP/kyaml/.github/workflows/k.yml" <<YAML
{
  jobs: {
    j: {
      steps: [{
        uses: "actions/checkout@${SHA_A}", # v6
      }],
    },
  },
}
YAML
STUB_COMMITS=200 \
  expect "a KYAML pin is extracted and checked" 0 "Checking 1 unique action pin(s)" "$TMP/kyaml"
STUB_COMMITS=404 STUB_REPO=200 \
  expect "a dead KYAML pin fails (mutant: unresolvable SHA)" 1 "SHA-NOT-FOUND" "$TMP/kyaml"

# Text that merely mentions `uses:` -- a header usage example, a run: body --
# is not a ref GitHub resolves, and must not be probed.
rm -rf "$TMP/textual"; mkdir -p "$TMP/textual/.github/workflows"
cat > "$TMP/textual/.github/workflows/t.yml" <<YAML
# Usage:
#       uses: actions/checkout@${SHA_B}
jobs:
  j:
    steps:
      - run: |
          echo "uses: actions/checkout@${SHA_B}"
      - uses: actions/checkout@${SHA_A}
YAML
STUB_COMMITS=200 \
  expect "uses: in a comment or run: body is not a pin" 0 "Checking 1 unique action pin(s)" "$TMP/textual"

# A ref longer than 40 hex is not a commit SHA. The old unanchored grep
# truncated it to 40 and probed that instead -- which is how this suite's own
# witness fixtures carried 44-hex SHAs unnoticed until 2026-10-01.
rm -rf "$TMP/long"; mkdir -p "$TMP/long/.github/workflows"
cat > "$TMP/long/.github/workflows/l.yml" <<YAML
jobs:
  j:
    steps:
      - uses: actions/checkout@${SHA_A}abcd
YAML
expect "a 44-hex ref is not taken as a 40-hex pin" 0 "nothing to check" "$TMP/long"

# A file the parser rejects must fail closed: its pins would go unchecked.
rm -rf "$TMP/broken"; mkdir -p "$TMP/broken/.github/workflows"
printf 'jobs: {\n  j: [\n' > "$TMP/broken/.github/workflows/b.yml"
expect "an unparseable workflow fails closed" 1 "yq could not parse" "$TMP/broken"

echo
echo "check-action-pins-resolve regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
