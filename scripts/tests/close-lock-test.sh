#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# close-lock-test.sh — fixture suite for scripts/close-lock.sh. Offline: a stub
# `gh` (GH_BIN) answers the two API calls the script makes. The planted
# positives are the two ways a lookup goes wrong — an HTTP error and a body of
# the wrong shape — and both must SKIP with exit 3 and write NO record.
#
# Run: bash scripts/tests/close-lock-test.sh
# TARGET=<path> runs the suite against another copy (used for mutant checks).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET:-$SCRIPT_DIR/../close-lock.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
C=3333333333333333333333333333333333333333

# ok: record and print a passing assertion.
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
# bad: record and print a failing assertion.
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Stub: repos/<o>/<n> → "7 9"; commits/v1 → $C; anything under o/missing → an
# HTTP error body on stdout, exit 1; anything under o/garbled → a truncated body
# on stdout, exit 0 (the {"messa shape AGENTS.md §5 records). Moved tags: the
# tag v1 of any o/ repo is at $C, $C descends from $A (compare `ahead`), $B is
# on another line (`diverged`), and no other tag exists. A contents/ call
# serves the file planted under $WORK/contents (its path with / ? = as _), or a
# 404 body with exit 1 when none is planted.
mkdir -p "$WORK/contents"
cat > "$WORK/gh" <<EOF
#!/usr/bin/env bash
case "\$2" in
  repos/o/garbled/contents/*) echo '{"messa'; exit 0 ;;
  repos/*/contents/*)
    f="$WORK/contents/\$(printf '%s' "\$2" | tr '/?=' '___')"
    if [ -f "\$f" ]; then cat "\$f"; else echo '{"message":"Not Found","status":"404"}'; exit 1; fi ;;
  repos/o/missing*) echo '{"message":"Not Found","status":"404"}'; exit 1 ;;
  repos/o/garbled*) echo '{"messa'; exit 0 ;;
  repos/o/untagged/tags*) exit 0 ;;
  repos/o/tagerror/tags*) echo 'v1.2.3'; exit 1 ;;
  repos/o/badtag/tags*) echo '{"message":"bad response"}'; exit 0 ;;
  repos/o/laterpage/tags*)
    case " \$* " in *' --paginate '*) echo 'v2.3.4' ;; *) exit 0 ;; esac ;;
  repos/o/a/tags*|repos/o/b/tags*|repos/o/c/tags*) echo 'v1.0.0' ;;
  repos/o/buildmeta/tags*) echo 'v1.2.3+build.4' ;;
  repos/o/releaseat/tags*) echo 'release@2026' ;;
  repos/o/flow-child/tags*|repos/o/r2/tags*) echo 'v1.0.0' ;;
  repos/o/leaf/tags*) printf 'v4\nv4.38.0\n' ;;
  repos/o/*/commits/tags/v1) echo $C ;;
  repos/o/*/commits/tags/*) echo '{"message":"No commit found"}'; exit 1 ;;
  repos/o/*/compare/$A...$C) echo ahead ;;
  repos/o/*/compare/*) echo diverged ;;
  repos/o/quoted/commits/release%272026) echo $C ;;
  repos/o/*/commits/v1) echo $C ;;
  repos/o/*/commits/*) echo '{"message":"No commit found"}'; exit 1 ;;
  repos/o/*) echo '7 9' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/gh"

# mklock <dir> <workflows-section-items...>; dependencies come from stdin
mklock() {
  local d="$WORK/$1/.github/workflows"; shift; mkdir -p "$d"
  { echo 'workflows:'; echo "    '.github/workflows/ci.yml':"
    for r in "$@"; do echo "        - '$r'"; done
    echo 'dependencies:'; cat; } > "$d/actions.lock"
  printf '%s' "$d"
}
# run: execute the target from the fixture repo root with the stub gh binary.
run() { (cd "$1/../.." && GH_BIN="$WORK/gh" bash "$TARGET") 2>&1; }

echo "=== closes a dangling workflows: edge ==="
d=$(mklock t1 "o/a@$A" </dev/null)
out=$(run "$d"); st=$?
[ "$st" = 0 ] && grep -qxF "    'o/a@$A':" "$d/actions.lock" && grep -qxF "        commit: 'sha1-$A'" "$d/actions.lock" \
  && grep -qxF '        owner_id: 7' "$d/actions.lock" && ok "SHA ref gets a record (exit 0)" || bad "SHA ref gets a record — st=$st $out"
out=$(run "$d"); grep -qF 'dangling refs: 0' <<<"$out" && ok "second run is a no-op" || bad "second run is a no-op — $out"

echo "=== resolves a tag through the commits endpoint ==="
d=$(mklock t2 "o/b@v1" </dev/null)
run "$d" >/dev/null
grep -qxF "        ref: 'v1'" "$d/actions.lock" && grep -qxF "        commit: 'sha1-$C'" "$d/actions.lock" \
  && ok "tag ref recorded with its resolved commit" || bad "tag ref recorded with its resolved commit"

echo "=== resolves a leaf SHA ref to its upstream semver tag (standards#1271) ==="
d=$(mklock t2b "o/leaf@$A" </dev/null)
run "$d" >/dev/null
grep -qxF "    'o/leaf@$A':" "$d/actions.lock" && grep -qxF "        ref: 'v4.38.0'" "$d/actions.lock" \
  && grep -qxF "        commit: 'sha1-$A'" "$d/actions.lock" \
  && ok "leaf SHA ref records upstream semver tag in ref: ('v4.38.0')" \
  || bad "leaf SHA ref records upstream semver tag in ref:"

echo "=== accepts a version tag with build metadata ==="
d=$(mklock buildmeta "o/buildmeta@$A" </dev/null)
out=$(run "$d"); st=$?
[[ "$st" == 0 ]] && grep -qxF "        ref: 'v1.2.3+build.4'" "$d/actions.lock" \
  && ok "build metadata tag is preserved" || bad "build metadata: st=$st $out"

echo "=== accepts a tag name containing @ ==="
d=$(mklock releaseat "o/releaseat@$A" </dev/null)
out=$(run "$d"); st=$?
[[ "$st" == 0 ]] && grep -qxF "        ref: 'release@2026'" "$d/actions.lock" \
  && ok "@ tag name is preserved" || bad "@ tag name: st=$st $out"

echo "=== leaf tag resolution fails closed ==="
for fixture in untagged tagerror badtag; do
  d=$(mklock "tag-$fixture" "o/$fixture@$A" </dev/null)
  cp "$d/actions.lock" "$WORK/tag-before"
  out=$(run "$d"); st=$?
  [ "$st" = 3 ] && cmp -s "$WORK/tag-before" "$d/actions.lock" \
    && ok "$fixture: exit 3 and no poisoned record" || bad "$fixture: st=$st $out"
done
d=$(mklock laterpage "o/laterpage@$A" </dev/null)
out=$(run "$d"); st=$?
[ "$st" = 0 ] && grep -qxF "        ref: 'v2.3.4'" "$d/actions.lock" \
  && ok "tag beyond first page is resolved" || bad "pagination: st=$st $out"

echo "=== closes a nested edge of an existing record ==="
d=$(mklock t3 "o/a@$A" <<EOF
    'o/a@$A':
        ref: '$A'
        commit: 'sha1-$A'
        owner_id: 7
        repo_id: 9
        uses:
            - 'o/b@$B'
EOF
)
run "$d" >/dev/null
grep -qxF "    'o/b@$B':" "$d/actions.lock" && ok "nested ref gets a record" || bad "nested ref gets a record"
[ "$(grep -oE "^    'o/[^']+'" "$d/actions.lock" | tr -d " '" | tr '\n' ,)" = "o/a@$A,o/b@$B," ] \
  && ok "records stay in key order" || bad "records stay in key order"

echo "=== planted positives: a failed or malformed lookup writes nothing ==="
d=$(mklock t4 "o/missing@$A" </dev/null); out=$(run "$d"); st=$?
[ "$st" = 3 ] && grep -qF 'SKIP o/missing' <<<"$out" && ! grep -qF 'message' "$d/actions.lock" \
  && ok "HTTP error → SKIP, exit 3, no record" || bad "HTTP error → SKIP, exit 3, no record — st=$st $out"
d=$(mklock t5 "o/garbled@$A" </dev/null); out=$(run "$d"); st=$?
[ "$st" = 3 ] && ! grep -qF 'messa' "$d/actions.lock" \
  && ok "malformed body (exit 0) → SKIP, exit 3, no record" || bad "malformed body (exit 0) → SKIP, exit 3, no record — st=$st"
d=$(mklock t6 "o/c@nosuchtag" </dev/null); out=$(run "$d"); st=$?
[ "$st" = 3 ] && ! grep -qF "o/c@nosuchtag':" "$d/actions.lock" \
  && ok "unresolvable tag → SKIP, exit 3, no record" || bad "unresolvable tag → SKIP, exit 3, no record — st=$st"

# mkwf <dir> <uses-values...>: a caller workflow ci.yml with one job-level
# reusable call per value.
mkwf() {
  local d="$WORK/$1/.github/workflows"; shift; mkdir -p "$d"
  { echo 'jobs:'; i=0; for u in "$@"; do i=$((i + 1)); printf '  j%s:\n    uses: %s\n' "$i" "$u"; done; } > "$d/ci.yml"
}
# plant <owner/repo> <path> <ref>: serve stdin as that file at that ref.
plant() { cat > "$WORK/contents/$(printf 'repos/%s/contents/%s?ref=%s' "$1" "$2" "$3" | tr '/?=' '___')"; }
# record <lock> <key>: print the record for key, header to last line.
record() { awk -v k="    '$2':" '/^dependencies:/{f=1} f && $0==k {p=1; print; next} f && p && /^    '\''/{p=0} p' "$1"; }

plant o/r .github/workflows/w.yml "$A" <<EOF
on: workflow_call
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: o/b@$B
      - uses: "o/c/sub@$C" # a sub-path and a comment
      - uses: ./local-action
      - uses: docker://alpine:3
EOF
WANT_R="    'o/r@$A':
        ref: '$A'
        commit: 'sha1-$A'
        owner_id: 7
        repo_id: 9
        uses:
            - 'o/b@$B'
            - 'o/c@$C'"

echo "=== a reusable-workflow record lists its called workflow's uses: ==="
d=$(mklock t8 "o/r@$A" </dev/null); mkwf t8 "o/r/.github/workflows/w.yml@$A"
out=$(run "$d"); st=$?
[ "$st" = 0 ] && [ "$(record "$d/actions.lock" "o/r@$A")" = "$WANT_R" ] \
  && ok "new reusable record carries the external uses:, keyed owner/repo@ref" || bad "new reusable record carries the external uses: — st=$st $out"
grep -qxF "    'o/b@$B':" "$d/actions.lock" && grep -qxF "    'o/c@$C':" "$d/actions.lock" \
  && ok "the refs it lists are closed" || bad "the refs it lists are closed"
cp "$d/actions.lock" "$WORK/t8.before"; out=$(run "$d")
grep -qF 'dangling refs: 0' <<<"$out" && cmp -s "$WORK/t8.before" "$d/actions.lock" \
  && ok "second run leaves the lock byte-identical" || bad "second run leaves the lock byte-identical — $out"

echo "=== a leaf record left by an earlier run is completed ==="
d=$(mklock t9 "o/r@$A" <<EOF
    'o/r@$A':
        ref: '$A'
        commit: 'sha1-$A'
        owner_id: 7
        repo_id: 9
EOF
)
mkwf t9 "o/r/.github/workflows/w.yml@$A"
out=$(run "$d"); st=$?
[ "$st" = 0 ] && [ "$(record "$d/actions.lock" "o/r@$A")" = "$WANT_R" ] && grep -qF "~ o/r@$A" <<<"$out" \
  && ok "leaf reusable record completed and reported" || bad "leaf reusable record completed and reported — st=$st $out"
grep -qxF "    'o/c@$C':" "$d/actions.lock" && ok "completed record's refs are closed" || bad "completed record's refs are closed"

echo "=== a reusable called from a reusable is read too ==="
plant o/r .github/workflows/w2.yml "$A" <<EOF
jobs:
  inner:
    uses: o/r2/.github/workflows/v.yml@$B
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: o/b@$B
EOF
plant o/r2 .github/workflows/v.yml "$B" <<EOF
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: o/c@$C
EOF
d=$(mklock t10 "o/r@$A" </dev/null); mkwf t10 "o/r/.github/workflows/w2.yml@$A"
out=$(run "$d"); st=$?
[ "$st" = 0 ] && record "$d/actions.lock" "o/r@$A" | grep -qxF "            - 'o/r2@$B'" \
  && record "$d/actions.lock" "o/r2@$B" | grep -qxF "            - 'o/c@$C'" \
  && grep -qxF "    'o/c@$C':" "$d/actions.lock" \
  && ok "nested reusable gets its own uses: list, and its refs are closed" || bad "nested reusable gets its own uses: list — st=$st $out"

echo "=== a reusable that uses no external action stays a leaf ==="
plant o/r .github/workflows/plain.yml "$A" <<EOF
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
d=$(mklock t11 "o/r@$A" </dev/null); mkwf t11 "o/r/.github/workflows/plain.yml@$A"
out=$(run "$d"); st=$?
[ "$st" = 0 ] && grep -qxF "    'o/r@$A':" "$d/actions.lock" && ! grep -qF 'uses:' "$d/actions.lock" \
  && ok "no external uses → leaf record (exit 0)" || bad "no external uses → leaf record — st=$st $out"

echo "=== planted positives: an unreadable called workflow writes and changes nothing ==="
d=$(mklock t12 "o/r@$A" </dev/null); mkwf t12 "o/r/.github/workflows/gone.yml@$A"
out=$(run "$d"); st=$?
[ "$st" = 3 ] && grep -qF "SKIP o/r@$A" <<<"$out" && ! grep -qxF "    'o/r@$A':" "$d/actions.lock" \
  && ok "404 on the called file → SKIP, exit 3, no leaf record" || bad "404 on the called file → SKIP, exit 3, no leaf record — st=$st $out"
d=$(mklock t13 "o/r@$A" <<EOF
    'o/r@$A':
        ref: '$A'
        commit: 'sha1-$A'
        owner_id: 7
        repo_id: 9
EOF
)
mkwf t13 "o/r/.github/workflows/gone.yml@$A"; cp "$d/actions.lock" "$WORK/t13.before"
out=$(run "$d"); st=$?
[ "$st" = 3 ] && cmp -s "$WORK/t13.before" "$d/actions.lock" \
  && ok "unreadable called file leaves an existing record untouched (exit 3)" || bad "unreadable called file leaves an existing record untouched — st=$st $out"
d=$(mklock t14 "o/garbled@$A" </dev/null); mkwf t14 "o/garbled/.github/workflows/w.yml@$A"
out=$(run "$d"); st=$?
[ "$st" = 3 ] && ! grep -qxF "    'o/garbled@$A':" "$d/actions.lock" \
  && ok "malformed called file (exit 0, no jobs:) → SKIP, exit 3" || bad "malformed called file → SKIP, exit 3 — st=$st $out"

# runp <workflows dir> <prior lock>: run with --prior.
runp() { (cd "$1/../.." && GH_BIN="$WORK/gh" bash "$TARGET" --prior "$2") 2>&1; }
# mkprior <name>: a pre-regeneration lock whose dependencies: come from stdin.
mkprior() { { echo 'dependencies:'; cat; } > "$WORK/$1.prior"; printf '%s' "$WORK/$1.prior"; }
# refused <label> <dir> <out> <st>: exit 3, the dangling key got no record.
refused() {
  [ "$4" = 3 ] && grep -qF "SKIP o/" <<<"$3" && ! grep -qE "^    'o/(untagged|tagerror)@" "$2/actions.lock" \
    && ok "$1" || bad "$1 — st=$4 $3"
}
# prior_rec <key> <ref> <commit-sha> <owner_id>: one prior record.
prior_rec() { printf "    '%s':\n        ref: '%s'\n        commit: 'sha1-%s'\n        owner_id: %s\n        repo_id: 9\n" "$1" "$2" "$3" "$4"; }

echo "=== moved tag: the pre-regeneration record supplies ref: ==="
d=$(mklock mv1 "o/untagged@$A" </dev/null); p=$(prior_rec "o/untagged@$A" v1 "$A" 7 | mkprior mv1)
out=$(runp "$d" "$p"); st=$?
[ "$st" = 0 ] && [ "$(record "$d/actions.lock" "o/untagged@$A")" = "    'o/untagged@$A':
        ref: 'v1'
        commit: 'sha1-$A'
        owner_id: 7
        repo_id: 9" ] && grep -qF "~ o/untagged@$A ref 'v1' from the prior lock record" <<<"$out" \
  && ok "prior record with a forward-moved tag → leaf record ref 'v1', reported" || bad "prior record → ref 'v1' — st=$st $out"
d=$(mklock mv2 "o/untagged@$A" </dev/null); p=$(prior_rec "O/Untagged@$A" v1 "$A" 7 | mkprior mv2)
out=$(runp "$d" "$p"); st=$?
[ "$st" = 0 ] && record "$d/actions.lock" "o/untagged@$A" | grep -qxF "        ref: 'v1'" \
  && ok "prior record key matches owner/repo case-insensitively" || bad "prior record case fold — st=$st $out"

echo "=== moved tag: planted positives — a prior record that does not qualify writes nothing ==="
d=$(mklock mvr1 "o/untagged@$A" </dev/null); p=$(prior_rec "o/untagged@$A" v1 "$B" 7 | mkprior mvr1)
out=$(runp "$d" "$p"); st=$?; refused "prior record for another commit → refused" "$d" "$out" "$st"
d=$(mklock mvr2 "o/untagged@$A" </dev/null); p=$(prior_rec "o/untagged@$A" v1 "$A" 8 | mkprior mvr2)
out=$(runp "$d" "$p"); st=$?; refused "prior record whose owner_id differs from the API → refused" "$d" "$out" "$st"
d=$(mklock mvr3 "o/untagged@$A" </dev/null); p=$(prior_rec "o/untagged@$A" "$A" "$A" 7 | mkprior mvr3)
out=$(runp "$d" "$p"); st=$?; refused "prior self-SHA ref → refused (standards#1271)" "$d" "$out" "$st"
grep -qF "the prior lock record ref '$A': not a symbolic tag name" <<<"$out" && ok "…refused by name, before any lookup" || bad "self-SHA prior reason — $out"
d=$(mklock mvr4 "o/untagged@$A" </dev/null); p=$(prior_rec "o/untagged@$A" gone "$A" 7 | mkprior mvr4)
out=$(runp "$d" "$p"); st=$?; refused "prior ref naming no current tag → refused" "$d" "$out" "$st"
d=$(mklock mvr5 "o/untagged@$B" </dev/null); p=$(prior_rec "o/untagged@$B" v1 "$B" 7 | mkprior mvr5)
out=$(runp "$d" "$p"); st=$?
[ "$st" = 3 ] && grep -qF 'does not descend from the pin (compare: diverged)' <<<"$out" && ! grep -qF "    'o/untagged@$B':" "$d/actions.lock" \
  && ok "prior tag whose commit does not descend from the pin → refused" || bad "diverged prior tag — st=$st $out"
d=$(mklock mvr6 "o/tagerror@$A" </dev/null); p=$(prior_rec "o/tagerror@$A" v1 "$A" 7 | mkprior mvr6)
cp "$d/actions.lock" "$WORK/mvr6.before"; out=$(runp "$d" "$p"); st=$?
[ "$st" = 3 ] && cmp -s "$WORK/mvr6.before" "$d/actions.lock" \
  && ok "failed tag listing → no fallback, exit 3, lock unchanged" || bad "failed tag listing must not fall back — st=$st $out"
d=$(mklock mvr7 "o/untagged@$A" </dev/null)
out=$(runp "$d" "$WORK/no-such.prior"); st=$?
[ "$st" = 1 ] && ok "--prior naming a missing file → exit 1" || bad "--prior missing file — st=$st $out"

echo "=== moved tag: the called repository's own lock supplies ref: ==="
# The standards@75bd5994 shape: the call site comments the pin `# stable` (a
# branch, refused), and the called repository's lock records it as ref: 'v1'.
D=4444444444444444444444444444444444444444
for r in "$A" "$B" "$C" "$D"; do
  plant o/q .github/workflows/w.yml "$r" <<EOF
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: o/untagged@$A # stable
EOF
done
prior_rec "o/untagged@$A" v1 "$A" 7 | mkprior qa >/dev/null; plant o/q .github/workflows/actions.lock "$A" < "$WORK/qa.prior"
prior_rec "o/untagged@$A" v1 "$B" 7 | mkprior qb >/dev/null; plant o/q .github/workflows/actions.lock "$B" < "$WORK/qb.prior"
prior_rec "o/untagged@$A" v1 "$A" 7 | plant o/q .github/workflows/actions.lock "$D"
d=$(mklock cl1 "o/q@$A" </dev/null); mkwf cl1 "o/q/.github/workflows/w.yml@$A"
out=$(run "$d"); st=$?
[ "$st" = 0 ] && record "$d/actions.lock" "o/untagged@$A" | grep -qxF "        ref: 'v1'" \
  && grep -qF "~ o/untagged@$A ref 'v1' from the lock of o/q@$A" <<<"$out" \
  && ok "called repository's lock record with a forward-moved tag → leaf record ref 'v1', reported" || bad "callee lock source — st=$st $out"

echo "=== moved tag: planted positives — a called repository's lock that does not qualify writes nothing ==="
d=$(mklock clr1 "o/q@$B" </dev/null); mkwf clr1 "o/q/.github/workflows/w.yml@$B"
out=$(run "$d"); st=$?
refused "callee lock record for another commit → refused" "$d" "$out" "$st"
grep -qF "the lock of o/q@$B: commit sha1-$B" <<<"$out" && grep -qF "call-site '# stable': no tag of that name" <<<"$out" \
  && ok "…and every refused candidate is named" || bad "callee lock refusal reasons — $out"
plant o/q .github/workflows/w.yml "$C" <<EOF
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: o/other@$A
EOF
plant o/q .github/workflows/actions.lock "$C" < "$WORK/qa.prior"
d=$(mklock clr2 "o/q@$C" "o/untagged@$A" </dev/null); mkwf clr2 "o/q/.github/workflows/w.yml@$C"
out=$(run "$d"); st=$?
refused "a record in the lock of a callee that does not use the key is not borrowed" "$d" "$out" "$st"
d=$(mklock clr3 "o/q@$D" </dev/null); mkwf clr3 "o/q/.github/workflows/w.yml@$D"
out=$(run "$d"); st=$?
refused "callee lock without a dependencies: section is not a source" "$d" "$out" "$st"
d=$(mklock clr4 "o/q@$A" </dev/null); mkwf clr4 "o/q/.github/workflows/w.yml@$A"
p=$(prior_rec "o/untagged@$A" gone "$A" 7 | mkprior clr4); out=$(runp "$d" "$p"); st=$?
[ "$st" = 0 ] && grep -qF "from the lock of o/q@$A" <<<"$out" \
  && ok "a refused prior record falls through to the called repository's lock" || bad "prior → callee lock fallthrough — st=$st $out"

echo "=== moved tag: a call-site '# <tag>' comment supplies ref: ==="
plant o/r .github/workflows/cm.yml "$A" <<EOF
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: o/untagged@$A # v1
EOF
d=$(mklock mc1 "o/r@$A" </dev/null); mkwf mc1 "o/r/.github/workflows/cm.yml@$A"
out=$(run "$d"); st=$?
[ "$st" = 0 ] && record "$d/actions.lock" "o/r@$A" | grep -qxF "            - 'o/untagged@$A'" \
  && record "$d/actions.lock" "o/untagged@$A" | grep -qxF "        ref: 'v1'" \
  && grep -qF "~ o/untagged@$A ref 'v1' from a call-site comment" <<<"$out" \
  && ok "comment in a called workflow → leaf record ref 'v1'" || bad "called-workflow comment — st=$st $out"
d=$(mklock mc2 "o/untagged@$A" </dev/null)
printf '{\n  jobs: {\n    a: {\n      steps: [\n        {\n          uses: "o/untagged@%s", # v1\n        },\n      ],\n    },\n  },\n}\n' "$A" > "$d/ci.yml"
out=$(run "$d"); st=$?
[ "$st" = 0 ] && record "$d/actions.lock" "o/untagged@$A" | grep -qxF "        ref: 'v1'" \
  && ok "KYAML comment in this repository's workflow → leaf record ref 'v1'" || bad "local KYAML comment — st=$st $out"
d=$(mklock mc3 "o/untagged@$A" </dev/null); p=$(prior_rec "o/untagged@$A" gone "$A" 7 | mkprior mc3)
printf 'jobs:\n  a:\n    steps:\n      - uses: o/untagged@%s # v1\n' "$A" > "$d/ci.yml"
out=$(runp "$d" "$p"); st=$?
[ "$st" = 0 ] && record "$d/actions.lock" "o/untagged@$A" | grep -qxF "        ref: 'v1'" && grep -qF 'from a call-site comment' <<<"$out" \
  && ok "a refused prior record falls through to the call-site comment" || bad "prior → comment fallthrough — st=$st $out"

echo "=== moved tag: planted positives — a call-site comment that does not qualify writes nothing ==="
d=$(mklock mcr1 "o/untagged@$A" </dev/null)
printf 'jobs:\n  a:\n    steps:\n      - uses: o/untagged@%s # stable\n' "$A" > "$d/ci.yml"
out=$(run "$d"); st=$?
refused "comment naming a branch, not a tag (# stable) → refused" "$d" "$out" "$st"
grep -qF "call-site '# stable': no tag of that name" <<<"$out" && ok "…and the refusal says why" || bad "refusal reason — $out"
d=$(mklock mcr2 "o/untagged@$B" </dev/null)
printf 'jobs:\n  a:\n    steps:\n      - uses: o/untagged@%s # v1\n' "$B" > "$d/ci.yml"
out=$(run "$d"); st=$?
[ "$st" = 3 ] && ! grep -qF "    'o/untagged@$B':" "$d/actions.lock" \
  && ok "comment tag whose commit does not descend from the pin → refused" || bad "diverged comment tag — st=$st $out"
d=$(mklock mcr3 "o/untagged@$A" </dev/null)
printf 'jobs:\n  a:\n    steps:\n      - uses: o/untagged@%s # %s\n' "$A" "$A" > "$d/ci.yml"
out=$(run "$d"); st=$?
refused "comment naming the SHA itself → refused (standards#1271)" "$d" "$out" "$st"
grep -qF "call-site '# $A': not a symbolic tag name" <<<"$out" && ok "…refused by name, before any lookup" || bad "self-SHA comment reason — $out"
d=$(mklock mcr4 "o/untagged@$A" </dev/null)
printf 'jobs:\n  a:\n    steps:\n      - uses: o/other@%s # v1\n' "$A" > "$d/ci.yml"
out=$(run "$d"); st=$?
refused "comment on another action's pin is not borrowed → refused" "$d" "$out" "$st"

echo "=== structural ==="
mkdir -p "$WORK/t7/.github/workflows"
(cd "$WORK/t7" && GH_BIN="$WORK/gh" bash "$TARGET") >/dev/null 2>&1; st=$?
[ "$st" = 1 ] && ok "no lockfile → exit 1" || bad "no lockfile → exit 1 (got $st)"

echo "=== --check: the closure corpus (#963 criterion 5) ==="
# expected.tsv is the contract Hypatia's ActionsLock.parse/1 also runs against
# (hyperpolymath/hypatia vendors a byte-identical copy). Each row: the exit
# code, and exactly the dangling refs the lock names, in the lock's spelling.
CORPUS="$SCRIPT_DIR/fixtures/actions-lock-closure"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh-calls"; exit 1\n' "$WORK" > "$WORK/gh-trap"
chmod +x "$WORK/gh-trap"; : > "$WORK/gh-calls"
rows=0
while IFS=$'\t' read -r file verdict dangling; do
  case "$file" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  lock="$CORPUS/$file"; before=$(sha256sum < "$lock")
  out=$(GH_BIN="$WORK/gh-trap" bash "$TARGET" --check "$lock" 2>&1); st=$?
  got=$(sed -n 's/^  \([^ ][^ ]*@[^ ]*\)$/\1/p' <<<"$out" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  want=$([[ "$dangling" == "-" ]] || printf '%s\n' $dangling | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  if [[ "$verdict" == "closed" ]]; then exp=0; else exp=1; fi
  [[ "$st" == "$exp" && "$got" == "$want" && "$(sha256sum < "$lock")" == "$before" ]] \
    && ok "$file: $verdict${want:+ ($want)}" || bad "$file: want exit $exp [$want], got exit $st [$got] — $out"
done < "$CORPUS/expected.tsv"
[[ "$rows" -ge 5 ]] && ok "corpus has $rows rows" || bad "corpus has only $rows rows"
[[ ! -s "$WORK/gh-calls" ]] && ok "--check made no gh call" || bad "--check called gh: $(cat "$WORK/gh-calls")"
GH_BIN="$WORK/gh-trap" bash "$TARGET" --check "$WORK/no-such.lock" >/dev/null 2>&1; st=$?
[[ "$st" == 2 ]] && ok "--check with no lock → exit 2" || bad "--check with no lock → exit 2 (got $st)"

echo "=== structured flow callers and called workflows retain nested closure ==="
plant o/flow .github/workflows/outer.yml "$A" <<EOF
{
  env: { uses: "o/not-a-dependency@v1", },
  jobs: {
    child: { uses: "o/flow-child/.github/workflows/inner.yml@$B", },
    build: { steps: [
      { uses: "o/b/subdir@$B", },
      { run: "echo uses: o/not-a-dependency@v1", },
    ], },
  },
}
EOF
plant o/flow-child .github/workflows/inner.yml "$B" <<EOF
{ jobs: { build: { steps: [ { uses: "o/c@$C", }, ], }, }, }
EOF
d="$WORK/flow/.github/workflows"; mkdir -p "$d"
printf 'version: v0.0.3\nworkflows: {}\ndependencies: {}\n' > "$d/actions.lock"
printf '{ jobs: { call: { uses: "o/flow/.github/workflows/outer.yml@%s", }, }, }\n' "$A" > "$d/ci.yml"
(cd "$d/../.." && bash "$SCRIPT_DIR/../complete-job-refs.sh") >/dev/null 2>&1; completed=$?
out=$(run "$d"); st=$?
[[ "$completed" == 0 && "$st" == 0 ]] && record "$d/actions.lock" "o/flow@$A" | grep -qxF "            - 'o/flow-child@$B'" \
  && record "$d/actions.lock" "o/flow-child@$B" | grep -qxF "            - 'o/c@$C'" \
  && ok "flow completion and close-lock retain nested reusable records" || bad "flow completion lost nested reusable records — st=$st $out"
record "$d/actions.lock" "o/flow@$A" | grep -qxF "            - 'o/b@$B'" \
  && ! grep -qF 'not-a-dependency' "$d/actions.lock" \
  && ok "flow step references count while environment/input examples do not" || bad "flow step/environment discrimination"
bash "$SCRIPT_DIR/../check-lock-sync.sh" "$d" >/dev/null 2>&1; st=$?
[[ "$st" == 0 ]] && ok "completed flow repair satisfies the strict sync gate" || bad "completed flow repair does not satisfy the strict sync gate"
record "$d/actions.lock" "o/flow-child@$B" | grep -qxF "        ref: 'v1.0.0'" \
  && ok "transitive reusable without a local caller records a symbolic tag" || bad "transitive reusable incorrectly received a raw-SHA exemption"

plant o/badflow .github/workflows/bad.yml "$A" <<'EOF'
jobs: {}
jobs: {}
EOF
d=$(mklock badflow "o/badflow@$A" </dev/null); mkwf badflow "o/badflow/.github/workflows/bad.yml@$A"
out=$(run "$d"); st=$?
[[ "$st" == 3 ]] && ! grep -qxF "    'o/badflow@$A':" "$d/actions.lock" \
  && ok "duplicate keys in called YAML cannot produce a leaf record" || bad "malformed called workflow was certified — st=$st $out"

cat > "$WORK/flow-check.lock" <<EOF
{ version: v0.0.3,
  workflows: { '.github/workflows/ci.yml': [ 'o/a@$A' ], },
  dependencies: {
    'o/a@$A': { ref: v1, commit: 'sha1-$A', owner_id: 7, repo_id: 9, uses: [ 'o/b@$B' ], },
  },
}
EOF
out=$(GH_BIN="$WORK/gh-trap" bash "$TARGET" --check "$WORK/flow-check.lock" 2>&1); st=$?
[[ "$st" == 1 ]] && grep -qxF "  o/b@$B" <<< "$out" \
  && ok "check mode reads flow-style transitive edges without network" || bad "check mode omitted a flow edge — st=$st $out"
yq -o=json '.' "$WORK/flow-check.lock" | jq --arg k "o/b@$B" --arg commit "sha1-$B" '.dependencies[$k] = {ref:"v1",commit:$commit,owner_id:7,repo_id:9}' > "$WORK/flow-closed.lock"
out=$(GH_BIN="$WORK/gh-trap" bash "$TARGET" --check "$WORK/flow-closed.lock" 2>&1); st=$?
[[ "$st" == 0 && ! -s "$WORK/gh-calls" ]] && ok "check mode accepts closed JSON/flow YAML without network" || bad "closed flow check failed — st=$st $out"

for location in map scalar; do
  if [[ "$location" == map ]]; then
    body=$(printf '      - { uses: "o/untagged@%s", } # v1\n' "$A")
  else
    body=$(printf '      - { uses: "o/untagged@%s", # v1\n        }\n' "$A")
  fi
  plant o/flowtag .github/workflows/ci.yml "$A" <<EOF
jobs:
  build:
    steps:
$body
EOF
  d=$(mklock "flowtag-$location" "o/flowtag@$A" </dev/null)
  mkwf "flowtag-$location" "o/flowtag/.github/workflows/ci.yml@$A"
  out=$(run "$d"); st=$?
  [[ "$st" == 0 ]] && yq -o=json '.' "$d/actions.lock" | jq -e --arg key "o/untagged@$A" '.dependencies[$key].ref == "v1"' >/dev/null \
    && ok "flow $location comment retains moved-tag evidence in called workflow" || bad "flow $location tag comment lost — st=$st $out"
done

d="$WORK/quoted/.github/workflows"; mkdir -p "$d"
printf 'jobs:\n  a:\n    steps:\n      - uses: "o/quoted@release\0472026"\n' > "$d/ci.yml"
cat > "$d/actions.lock" <<'EOF'
# SPDX-License-Identifier: MPL-2.0
version: v0.0.3
workflows: {.github/workflows/ci.yml: ["o/quoted@release'2026"]}
dependencies: {}
EOF
out=$(run "$d"); st=$?
[[ "$st" == 0 ]] && yq -o=json '.' "$d/actions.lock" | jq -e --arg key "o/quoted@release'2026" --arg ref "release'2026" --arg commit "sha1-$C" '.dependencies[$key].ref == $ref and .dependencies[$key].commit == $commit' >/dev/null \
  && ok "closure URL-encodes and YAML-encodes apostrophes in symbolic references" || bad "quoted closure corrupts the record — st=$st $out"
bash "$SCRIPT_DIR/../check-lock-sync.sh" "$d" >/dev/null 2>&1; st=$?
[[ "$st" == 0 ]] && grep -q '^# SPDX-License-Identifier: MPL-2.0' "$d/actions.lock" \
  && ok "quoted closure preserves the header and satisfies the strict checker" || bad "quoted closure fails the checker or loses its header"
cp "$d/actions.lock" "$WORK/quoted.before"; run "$d" >/dev/null
cmp -s "$WORK/quoted.before" "$d/actions.lock" && ok "quoted closure is byte-idempotent" || bad "quoted closure is not byte-idempotent"

for malformed in duplicate multiple syntax; do
  case "$malformed" in
    duplicate) printf 'workflows: {}\nworkflows: {}\ndependencies: {}\n' > "$WORK/uninspected.lock" ;;
    multiple) printf 'workflows: {}\ndependencies: {}\n---\nworkflows: {}\n' > "$WORK/uninspected.lock" ;;
    syntax) printf 'workflows: [\n' > "$WORK/uninspected.lock" ;;
  esac
  cp "$WORK/uninspected.lock" "$WORK/uninspected.before"
  GH_BIN="$WORK/gh-trap" bash "$TARGET" --check "$WORK/uninspected.lock" >/dev/null 2>&1; st=$?
  [[ "$st" == 2 ]] && cmp -s "$WORK/uninspected.before" "$WORK/uninspected.lock" && [[ ! -s "$WORK/gh-calls" ]] \
    && ok "unparseable $malformed lock is uninspected (exit 2), unchanged and offline" || bad "unparseable $malformed lock was misclassified"
done

echo "close-lock-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
