#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test_apply_workflow_pins_remote.sh — regression suite for the pin applier.
#
# This suite is MUTATION-BASED on purpose. A green run of the applier's own
# controls proves only that the controls agree with the code; it does not prove
# the controls can DETECT anything. So every mutant below reintroduces a real
# defect verbatim and asserts the suite turns red. A mutant that stays green is
# a control that was never testing what its name claims.
#
# Trap already paid for once: a syntactically INVALID mutant fails for the wrong
# reason and every control "fails" on a parse error, which reads as success.
# Each mutant is therefore `bash -n`-checked BEFORE its redness is believed.

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLIER="${SCRIPT_DIR}/../scripts/apply-workflow-pins-remote.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*" >&2; rc=1; }

# --- 0. the script must exist, parse, and be committed executable ------------
echo "== 0. shape =="
[ -f "$APPLIER" ] || { echo "FATAL: applier not found at $APPLIER" >&2; exit 1; }
bash -n "$APPLIER" && pass "applier parses" || fail "applier does not parse"

# A suite committed 100644 passes every local run (`bash script` ignores the
# mode) and dies in CI at exit 126 before a single control runs.
if git -C "${SCRIPT_DIR}/.." ls-files -s -- tests/test_apply_workflow_pins_remote.sh 2>/dev/null | grep -q '^100755'; then
  pass "this test is committed executable (100755)"
elif ! git -C "${SCRIPT_DIR}/.." rev-parse --git-dir >/dev/null 2>&1; then
  pass "not a git checkout; mode check skipped"
else
  # Not yet staged is acceptable while authoring; a wrong mode is not.
  if git -C "${SCRIPT_DIR}/.." ls-files -- tests/test_apply_workflow_pins_remote.sh 2>/dev/null | grep -q .; then
    fail "test is tracked but NOT 100755 — it will exit 126 in CI"
  else
    pass "test not yet tracked; mode will be checked once added"
  fi
fi
if git -C "${SCRIPT_DIR}/.." ls-files -s -- scripts/apply-workflow-pins-remote.sh 2>/dev/null | grep -q '^100644'; then
  fail "applier is tracked 100644 — it must be executable"
else
  pass "applier mode acceptable"
fi

# --- 1. the applier's own controls must pass unmutated -----------------------
echo "== 1. baseline: unmutated controls =="
if bash "$APPLIER" --self-test >"$TMP/base.out" 2>&1; then
  pass "baseline controls green"
else
  fail "baseline controls RED — fix the applier before reading any mutant"
  sed 's/^/    /' "$TMP/base.out" >&2
fi
for want in "fresh.yml" "behind.yml" "illegal.yml" "tracking.yml" "none.yml" "short.yml" \
            "manifest.json" "bad-schema.json" "bad-version.json" "bad-dup.json" "bad-empty.json" \
            "bad-json.json" "content-behind.yml" "content-current.yml" "content-ahead.yml" \
            "content-wide.yml" "content-unlisted.yml" "content-malformed.yml" "content-not-first.yml" \
            "bad-huge.json" "content-huge.yml" \
            "owner-stale.lock" "owner-clean.lock" "owner-nonstandards.lock" "owner-tag-key.lock"; do
  grep -q "PASS $want" "$TMP/base.out" && pass "control present: $want" \
    || fail "control MISSING from baseline: $want (a control that never runs is not a control)"
done

# --- 2. mutants --------------------------------------------------------------
# kill <name> <sed-expr> <expected-substring-in-red-output>
kill_mutant() {
  # NOTE: `local a="$1" m="${a}"` does NOT work — bash expands every word of the
  # `local` builtin's argument list BEFORE assigning any of them, so `${a}` is
  # unset there. Assign on separate lines. (Cost one red herring to find.)
  local name="$1" expr="$2" want="$3"
  local m="$TMP/mutant_${name}.sh"
  cp "$APPLIER" "$m"
  sed -E -i "$expr" "$m"

  if cmp -s "$APPLIER" "$m"; then
    fail "mutant '$name' changed NOTHING — the sed did not match, so nothing was tested"
    return
  fi
  if ! bash -n "$m" 2>"$TMP/${name}.parse"; then
    fail "mutant '$name' is SYNTACTICALLY INVALID — its redness would be meaningless"
    sed 's/^/    /' "$TMP/${name}.parse" >&2
    return
  fi

  if bash "$m" --self-test >"$TMP/${name}.out" 2>&1; then
    fail "mutant '$name' stayed GREEN — no control detects this defect"
  elif grep -qF "$want" "$TMP/${name}.out"; then
    pass "mutant '$name' killed by the right control"
  else
    fail "mutant '$name' died, but not at '$want' — the wrong control fired"
    sed 's/^/    /' "$TMP/${name}.out" >&2
  fi
}

echo "== 2. mutation kills =="

# M1 — classify by SHA pins only. This is the exact blind spot the older
# scripts/propagate-workflow-pins.sh still has: its PIN_RE cannot see an
# unparseable `uses: ../../`, so a repo full of them audits as clean. That
# population is issue #808.
kill_mutant illegal_blind \
  's@^  if \[ -n "\$\(illegal_uses "\$f"\)" \]; then@  if false; then@' \
  "FAIL illegal.yml"

# M2 — compare a pin to the target by exact string instead of by prefix. A
# legitimately short pin then reads BEHIND forever: the applier rewrites it, the
# rewrite is a no-op, and the next run finds it BEHIND again. An applier that
# never converges is just a sweep on a cron.
kill_mutant short_pin_never_converges \
  's@if \[ "\$\{target:0:\$\{#sha\}\}" = "\$sha" \]@if [ "$target" = "$sha" ]@' \
  "FAIL short.yml"

# M3 — drop branch/tag tracking detection. `affinescript` tracks `@main`;
# dropping TRACKING from the census makes the estate's one unpinned caller
# invisible to the policy that forbids unpinned callers.
kill_mutant tracking_blind \
  's@^  if \[ -n "\$\(tracking_refs "\$f"\)" \]; then@  if false; then@' \
  "FAIL tracking.yml"

# M4 — anchor the rewrite on the SHA rather than on the standards reusable PATH.
# It then re-points EVERY 40-hex pin in the file, including actions/checkout, at
# a standards commit. Catastrophic, and both the idempotency control and the
# hit-the-target control stay green through it — which is precisely why the
# third-party control had to be added. The rewrite now matches either owner
# (it migrates the former one), so the anchor is two groups, (owner) and
# (path); the mutant empties both. `%` delimits the mutant so the `\|` in the
# pattern stays a literal pipe under sed -E.
kill_mutant rewrite_overreaches \
  's%s#\(hyperpolymath\|metadatastician\)/standards/\(\\\.github/workflows/\[A-Za-z0-9\._-\]\+\\\.ya\?ml@\)%s#()()%' \
  "FAIL rewrite overreached"

# M5 — the illegal repair emits a ref with no SHA. A "repair" that leaves the
# workflow still unparseable converts a visible failure into a repaired-looking
# one, which is strictly worse than not repairing it.
kill_mutant illegal_repair_still_illegal \
  's@\@\$\{target\}@\@@g' \
  "FAIL illegal repair"

# M6 — compare stamp versions as strings. 0.9.0 then reads as NEWER than
# 0.10.0, and a stale copy is reported AHEAD, so it is never refreshed.
kill_mutant content_lexical_version \
  's@\[ "\$x" -lt "\$y" \]@[[ "${av[$i]}" < "${bv[$i]}" ]]@; s@\[ "\$x" -gt "\$y" \]@[[ "${av[$i]}" > "${bv[$i]}" ]]@' \
  "FAIL content-wide.yml"

# M7 — every version compares equal. Every stale copy then reads CURRENT, which
# is the exact failure the content census exists to see.
kill_mutant content_behind_blind \
  's@^    if \[ "\$x" -lt "\$y" \]; then echo lt; return 0; fi$@    :@' \
  "FAIL content-behind.yml"

# M8 — accept any schema. A document that is not a proven-cicd manifest would
# then be read as one, and the census would judge copies against it.
kill_mutant manifest_schema_unchecked \
  's@\.schema == "proven-cicd/manifest/v1"@true@' \
  "FAIL bad-schema.json"

# M9 — accept a duplicated artifact. Which of its versions wins would depend on
# the order of the file, so a census could say CURRENT for a stale copy.
kill_mutant manifest_duplicate_accepted \
  's@and \(\[\.artifacts\[\]\.artifact\] \| length == \(unique \| length\)\)@@' \
  "FAIL bad-dup.json"

# M10 — read the stamp from any line, not the first. A body that merely quotes a
# stamp (a comment, a heredoc, a test fixture) would be reported as a copy.
kill_mutant content_stamp_anywhere \
  's@first=\$\(head -n 1 "\$f" 2>/dev/null\)@first=$(grep -m1 "^# proven-cicd:" "$f" 2>/dev/null)@' \
  "FAIL content-not-first.yml"

# M11 — judge any record's owner_id, not only standards'. hyperpolymath/cicd-suite
# legitimately carries the same account id, so the census would cry wolf on it.
kill_mutant owner_filter_widened \
  's@tolower\(a\[1\]\) ~ /\^\(hyperpolymath\|metadatastician\)\\/standards\$/@tolower(a[1]) ~ /./@' \
  "FAIL owner-nonstandards.lock"

# M12a — compare the repo slug case-sensitively. GitHub slugs are
# case-insensitive, so `Metadatastician/Standards@<sha>` with the former
# owner's id is the same stale record and must still be reported.
kill_mutant owner_case_sensitive \
  's@tolower\(a\[1\]\) ~ /\^@a[1] ~ /^@' \
  "FAIL owner-mixed-case.lock"

# M12b, M12c — the deed over-cap function: the cap is a strict greater-than on
# OCTETS (a 998-octet line is legal), and the line terminator is not counted.
kill_mutant deed_cap_off_by_one 's@if \(n > cap\)@if (n >= cap)@' "FAIL deed-exact.deed"
kill_mutant deed_counts_terminator 's@sub\(/\\r\$/, "", line\);@@' "FAIL deed-crlf.deed"

# M12 — drop the owner_id test. Every standards record would then read stale,
# including one that already carries the current owner's id.
kill_mutant owner_id_unchecked \
  's@ && \$2 == old@@' \
  "FAIL owner-clean.lock"

# M11, M12 — unbound the version components. version_cmp compares shell
# integers, which wrap at 2^63: 18446744073709551617.0.0 then equals 1.0.0, and
# a copy far ahead, or a stale copy against such a manifest, reads CURRENT.
kill_mutant content_stamp_unbounded \
  '/^STAMP_RE=/s@\{1,9\}@+@g' \
  "FAIL content-huge.yml"
kill_mutant manifest_version_unbounded \
  '/and \(\.version \| type == "string"/s@\{1,9\}@+@g' \
  "FAIL bad-huge.json"

# --- 3. fetch_workflows fails CLOSED -----------------------------------------
# A rate-limited repo used to come back as "no workflows": fetch_workflows
# returned 0 on every failure, so the census dropped the repo while `walked N`
# still counted it (2026-10-02). Only a 404 may read as "nothing here".
echo "== 3. fetch failures are reported, not swallowed =="
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api graphql"*) exit 1 ;;   # force the REST fallback
  "api repos/o/r/contents --jq"*)
    [ "${ROOT_FAIL:-}" = 1 ] && { echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1; }
    for f in ${ROOT:-}; do echo "$f"; done; exit 0 ;;
  *contents/*_chora.deed*)
    [ "${DEED_FAIL:-}" = 1 ] && { echo "gh: file too large (HTTP 403)" >&2; exit 1; }
    printf '(deed)\n'; exit 0 ;;
  *contents/.github/workflows/*)
    [ "${FILE_FAIL:-}" = 1 ] && { echo "gh: rate limit (HTTP 403)" >&2; exit 1; }
    echo 'on: push'; exit 0 ;;
  *contents/.github/workflows*)
    case "${LIST:-200}" in
      200) echo ci.yml; exit 0 ;;
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      *)   echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1 ;;
    esac ;;
esac
exit 1
EOF
chmod +x "$STUB/gh"
# fetch_case <label> <want-rc> <env...> — run fetch_workflows against the stub.
fetch_case() {
  local label="$1" want="$2"; shift 2
  local got
  env PATH="$STUB:$PATH" "$@" bash -c 'source "$1"; fetch_workflows o/r "$2"' _ \
      "${APPLIER_UNDER_TEST:-$APPLIER}" "$TMP/fetch.$label" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then pass "fetch: $label (rc=$got)"; else fail "fetch: $label — expected rc=$want, got rc=$got"; fi
}
fetch_case "listing ok"            0 LIST=200
fetch_case "no workflows dir (404)" 0 LIST=404
fetch_case "rate-limited listing"   1 LIST=403
fetch_case "file download fails"    1 LIST=200 FILE_FAIL=1
[ -s "$TMP/fetch.listing ok/ci.yml" ] && pass "fetch: file content written" || fail "fetch: ci.yml not written"

# The REST fallback reads the root deeds too: one root listing, then each non-estate
# `*_chora.deed` under its OWN name. A repository with none leaves no marker (no row);
# a listing or a read that fails leaves an .unread marker, never a silent "no deed".
deed_files() { ( cd "$1" 2>/dev/null && ls -A | grep '^\.deed-' | sort | tr '\n' ' ' ); }
deed_case() {
  local label="$1" want="$2"; shift 2
  local dir="$TMP/fetchd.$label"
  env PATH="$STUB:$PATH" "$@" bash -c 'source "$1"; fetch_workflows o/r "$2"' _ \
      "${APPLIER_UNDER_TEST:-$APPLIER}" "$dir" >/dev/null 2>&1
  local got; got=$(deed_files "$dir")
  if [ "$got" = "$want" ]; then pass "REST deeds: $label"; else fail "REST deeds: $label — expected '$want', got '$got'"; fi
}
deed_case "a deed under any stem is read; estate_chora.deed is ignored" ".deed-old-name_chora.deed " LIST=200 ROOT="old-name_chora.deed estate_chora.deed README.adoc"
deed_case "no root deed leaves no marker" "" LIST=200 ROOT="README.adoc"
deed_case "a failed root listing leaves a LISTING marker" ".deed-LISTING.unread " LIST=200 ROOT_FAIL=1
deed_case "a deed that cannot be read leaves an .unread marker" ".deed-x_chora.deed.unread " LIST=200 ROOT="x_chora.deed" DEED_FAIL=1

# Mutant: restore the old `return 0` on a failed listing. It must turn red.
M="$TMP/mutant_fail_open.sh"; cp "$APPLIER" "$M"
sed -i 's@^    return 1$@    return 0@' "$M"
if cmp -s "$APPLIER" "$M" || ! bash -n "$M"; then
  fail "fail-open mutant did not apply cleanly"
else
  out=$(APPLIER_UNDER_TEST="$M" fetch_case "MUTANT rate-limited listing" 1 LIST=403 2>&1)
  case "$out" in *FAIL*) pass "mutant 'fetch_fail_open' killed by the rate-limit control" ;;
                 *) fail "mutant 'fetch_fail_open' stayed GREEN" ;; esac
fi

# --- 4. list_repos sees every repository the credential can see ---------------
# Under a GitHub App installation token (ghs_), users/<o>/repos and
# orgs/<o>/repos return PUBLIC repositories only, so the private repositories the
# App can write never reached the census (finding 2026-10-08). The cure ADDS
# installation/repositories. It must not REPLACE the public listing: GITHUB_TOKEN
# is ghs_ too, its installation is one repository, and the scheduled audit runs
# on it while no App is configured.
echo "== 4. enumeration under App, GITHUB_TOKEN and PAT credentials =="
command -v jq >/dev/null || { fail "jq is required by section 4"; exit 1; }
T="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
LSTUB="$TMP/lstub"; mkdir -p "$LSTUB"
cat > "$LSTUB/gh" <<'EOF'
#!/usr/bin/env bash
# gh — test double serving repository listings and workflow trees from
# $GH_FIX, and modelling which token kinds may call installation/repositories.
echo "$*" >> "$GH_FIX/calls.log"
[ "${1:-} ${2:-}" = "auth status" ] && exit 0
[ "${1:-} ${2:-}" = "pr create" ] && { echo "https://github.com/stub/pull/1"; exit 0; }
[ "${1:-}" = api ] || exit 64
shift
path="" jqx="" gql=0 inp=0 qname=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q)     jqx="$2"; shift ;;
    --input)     inp=1 ;;
    -F)          case "${2:-}" in name=*) qname="${2#name=}" ;; esac; shift ;;
    -f|-H)       shift ;;
    -*)          ;;
    graphql)     gql=1 ;;
    *)           [ -n "$path" ] || path="$1" ;;
  esac
  shift
done
# refuse — fail the way gh does on a non-2xx response: message on stderr, rc 1.
refuse() { echo "gh: $2 (HTTP $1)" >&2; exit 1; }
if [ "$gql" = 1 ]; then
  # A createCommitOnBranch request arrives on stdin (--input -): keep it for
  # the test to inspect and answer with an oid.
  if [ "$inp" = 1 ]; then
    cat > "$GH_FIX/commit.json"
    echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}}'; exit 0
  fi
  # Every repository holds one workflow, pinned FRESH at $TARGET. If
  # $GH_FIX/own_squabbler exists, each repository also holds a
  # cicd-squabbler.yml with that text (a workflow of the repo's own).
  extra="[]"
  [ -f "$GH_FIX/own_squabbler" ] && extra=$(jq -Rs '[{name: "cicd-squabbler.yml", type: "blob", object: {text: .}}]' "$GH_FIX/own_squabbler")
  # $GH_FIX/own_lock: each repository also holds that actions.lock.
  [ -f "$GH_FIX/own_lock" ] && extra=$(printf '%s' "$extra" | jq --rawfile l "$GH_FIX/own_lock" '. + [{name: "actions.lock", type: "blob", object: {text: $l}}]')
  # $GH_FIX/own_lock_unread: the tree lists an actions.lock whose blob has no text.
  [ -f "$GH_FIX/own_lock_unread" ] && extra=$(printf '%s' "$extra" | jq '. + [{name: "actions.lock", type: "blob", object: {text: null}}]')
  # $GH_FIX/own_stamped: each repository also holds that stamped proven-cicd copy.
  [ -f "$GH_FIX/own_stamped" ] && extra=$(printf '%s' "$extra" | jq --rawfile s "$GH_FIX/own_stamped" '. + [{name: "proven-lock-gate.yml", type: "blob", object: {text: $s}}]')
  # $GH_FIX/own_deed: each repository has that root deed (named <repo>_chora.deed, or
  # the name in own_deed_name: a deed kept under a former repository name; the
  # conventional-name alias then reads null, as GitHub answers for a missing file).
  # own_deed_unread: the deed blob came back without text. own_estate_deed: the root
  # also holds estate_chora.deed (which the census must ignore).
  rootnames='[]'; deed_json=null
  deed_name="${qname}_chora.deed"; [ -f "$GH_FIX/own_deed_name" ] && deed_name=$(cat "$GH_FIX/own_deed_name")
  if [ -f "$GH_FIX/own_deed" ] || [ -f "$GH_FIX/own_deed_unread" ]; then
    rootnames=$(jq -n --arg n "$deed_name" '[{name: $n, type: "blob"}]')
    if [ "$deed_name" = "${qname}_chora.deed" ]; then
      [ -f "$GH_FIX/own_deed" ] && deed_json=$(jq -Rs '{text: ., isTruncated: false}' "$GH_FIX/own_deed")
      [ -f "$GH_FIX/own_deed_unread" ] && deed_json=$(jq -n '{text: null, isTruncated: false}')
    fi
  fi
  [ -f "$GH_FIX/own_estate_deed" ] && rootnames=$(printf '%s' "$rootnames" | jq '. + [{name: "estate_chora.deed", type: "blob"}]')
  jq -n --arg sha "$TARGET" --argjson extra "$extra" --argjson deed "$deed_json" --argjson rn "$rootnames" '{data: {repository: {deed: $deed, rootnames: {entries: $rn}, object: {entries: ([{name: "ci.yml", type: "blob",
    object: {text: ("jobs:\n  a:\n    uses: hyperpolymath/standards/.github/workflows/x.yml@" + $sha + "\n")}}] + $extra)}}}}'
  exit 0
fi
p="${path%%\?*}"
# repos/<owner>/<name> (exactly three segments): the repository itself, for
# --ensure-squabbler's fork test. fork_<name> in $GH_FIX makes it a fork.
if [[ "$p" =~ ^repos/[^/]+/[^/]+$ ]]; then
  f=false; [ -f "$GH_FIX/fork_${p##*/}" ] && f=true
  j="{\"fork\": $f, \"default_branch\": \"main\"}"
  if [ -n "$jqx" ]; then printf '%s' "$j" | jq -r "$jqx"; else printf '%s' "$j"; fi
  exit 0
fi
case "$p" in
  # The published proven-cicd manifest, served raw from $GH_FIX/proven_manifest.json.
  repos/hyperpolymath/proven-cicd-and-workflows/contents/proven/manifest.json)
    body="$GH_FIX/proven_manifest.json" ;;
  repos/*/contents/*_chora.deed)
    [ -f "$GH_FIX/own_deed_rest_fail" ] && refuse 403 "This API returns blobs up to 1 MB in size. The requested blob is too large"
    body="$GH_FIX/own_deed" ;;
  repos/*/commits/*)
    j='{"sha": "cccccccccccccccccccccccccccccccccccccccc"}'
    if [ -n "$jqx" ]; then printf '%s' "$j" | jq -r "$jqx"; else printf '%s' "$j"; fi; exit 0 ;;
  repos/*/git/ref/*) refuse 404 "Not Found" ;;
  repos/*/git/refs) echo '{}'; exit 0 ;;
  users/*/repos|orgs/*/repos)
    kind="${p%%/*}"; o="${p#*/}"; o="${o%/repos}"
    [ -f "$GH_FIX/${kind}_fail_$o" ] && refuse 403 "API rate limit exceeded"
    body="$GH_FIX/${kind}_$o.json" ;;
  installation/repositories)
    case "${GH_TOKEN:-}" in ghs_*) ;; *) refuse 403 "This endpoint requires an installation access token" ;; esac
    [ -f "$GH_FIX/inst_fail" ] && refuse 502 "Bad Gateway"
    body="$GH_FIX/inst.json" ;;
  *) refuse 404 "Not Found" ;;
esac
[ -f "$body" ] || refuse 404 "Not Found"
if [ -n "$jqx" ]; then jq -r "$jqx" "$body"; else cat "$body"; fi
EOF
chmod +x "$LSTUB/gh"

# Mutants are sourced, and the applier sources lib/ beside itself.
MUT="$TMP/mut"; mkdir -p "$MUT"
ln -s "$(cd "$(dirname "$APPLIER")" && pwd)/lib" "$MUT/lib"

# fixture_repos <file> <owner/name:archived>... — write a REST repository list.
fixture_repos() {
  local f="$1"; shift
  printf '%s\n' "$@" \
    | jq -R 'split(":") | {full_name: .[0], archived: (.[1] == "true")}' | jq -s . > "$f"
}

# new_case <label> — make a fixture directory holding the two-owner estate every
# case starts from, and print its path. hyperpolymath has a public and an
# archived repository, metadatastician one public one, and the App installation
# on hyperpolymath holds the public one, a PRIVATE one and an archived one.
new_case() {
  local d; d=$(mktemp -d "$TMP/list.$1.XXXX")
  fixture_repos "$d/users_hyperpolymath.json" hyperpolymath/pub-a:false hyperpolymath/old:true
  fixture_repos "$d/users_metadatastician.json" metadatastician/pub-c:false
  fixture_repos "$d/inst.repos" hyperpolymath/pub-a:false hyperpolymath/priv-b:false hyperpolymath/arch-p:true
  jq '{total_count: length, repositories: .}' "$d/inst.repos" > "$d/inst.json"
  echo "$d"
}

# run_list <dir> <token> <owners> <applier> — run list_repos against the listing
# stub; stdout to <dir>/out, stderr to <dir>/err, exit status to <dir>/rc.
run_list() {
  local d="$1"
  : > "$d/calls.log"
  # shellcheck disable=SC2016  # $1 and $2 are expanded by the inner shell
  env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN="$2" GITHUB_TOKEN= \
    bash -c 'source "$1"; OWNERS="$2"; list_repos' _ "$4" "$3" > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
}

# run_main <dir> <token> <applier> — run the whole applier in audit mode against
# the stub, with only the network ancestry proof stubbed out.
run_main() {
  local d="$1"
  : > "$d/calls.log"
  # shellcheck disable=SC2016  # $1 and $2 are expanded by the inner shell
  env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN="$2" GITHUB_TOKEN= TARGET="$T" \
    bash -c 'source "$1"; validate_target() { return 0; }; shift; main "$@"' _ "$3" \
      --to "$T" --owners hyperpolymath,metadatastician > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
}

# expect_list <label> <dir> <want-rc> <repo>... — require exactly these
# repositories, each once and sorted, and exactly this exit status.
expect_list() {
  local label="$1" d="$2" want_rc="$3"; shift 3
  local want got
  want=$(printf '%s\n' "$@" | sed '/^$/d' | sort)
  got=$(cat "$d/out")
  if [ "$(cat "$d/rc")" = "$want_rc" ] && [ "$got" = "$want" ]; then
    pass "list: $label"
  else
    fail "list: $label — rc=$(cat "$d/rc") (want $want_rc); got [${got//$'\n'/ }] want [${want//$'\n'/ }]"
  fi
}

# case_app <applier> — a dedicated App's token: the public listings plus the
# installation's private repository, archived ones dropped, each listed once.
case_app() {
  local d; d=$(new_case app)
  run_list "$d" ghs_app hyperpolymath,metadatastician "$1"
  expect_list "App token adds the installation's private repository" "$d" 0 \
    hyperpolymath/priv-b hyperpolymath/pub-a metadatastician/pub-c
}

# case_github_token <applier> — GITHUB_TOKEN is ghs_ too, and its installation
# is this one repository: the public listings must survive alongside it.
case_github_token() {
  local d; d=$(new_case gtok)
  fixture_repos "$d/users_hyperpolymath.json" hyperpolymath/pub-a:false hyperpolymath/standards:false
  fixture_repos "$d/inst.repos" hyperpolymath/standards:false
  jq '{total_count: length, repositories: .}' "$d/inst.repos" > "$d/inst.json"
  run_list "$d" ghs_gtok hyperpolymath,metadatastician "$1"
  expect_list "GITHUB_TOKEN keeps the public census" "$d" 0 \
    hyperpolymath/pub-a hyperpolymath/standards metadatastician/pub-c
}

# case_pat <applier> — a PAT keeps the public listings and never calls the
# installation endpoint, which would refuse it.
case_pat() {
  local d; d=$(new_case pat)
  run_list "$d" ghp_pat hyperpolymath,metadatastician "$1"
  expect_list "PAT lists the public repositories" "$d" 0 hyperpolymath/pub-a metadatastician/pub-c
  if grep -q 'installation/repositories' "$d/calls.log"; then
    fail "list: PAT called installation/repositories"
  else
    pass "list: PAT never calls installation/repositories"
  fi
}

# case_owner_filter <applier> — --owners narrows the census under an App token
# too: the installation's hyperpolymath repositories must not leak in.
case_owner_filter() {
  local d; d=$(new_case owners)
  run_list "$d" ghs_app metadatastician "$1"
  expect_list "--owners metadatastician admits no installation repo of hyperpolymath" "$d" 0 \
    metadatastician/pub-c
}

# case_org_fallback <applier> — an owner whose users/ listing 404s is listed
# through orgs/.
case_org_fallback() {
  local d; d=$(new_case orgs)
  mv "$d/users_metadatastician.json" "$d/orgs_metadatastician.json"
  run_list "$d" ghp_pat hyperpolymath,metadatastician "$1"
  expect_list "a users/ 404 falls back to orgs/" "$d" 0 hyperpolymath/pub-a metadatastician/pub-c
}

# case_inst_fail <applier> — a failed installation listing fails the whole
# enumeration, prints no repositories, and names the endpoint.
case_inst_fail() {
  local d; d=$(new_case instfail)
  touch "$d/inst_fail"
  run_list "$d" ghs_app hyperpolymath,metadatastician "$1"
  expect_list "a failed installation listing fails closed" "$d" 1
  if grep -q 'installation/repositories' "$d/err"; then
    pass "list: the failure names installation/repositories"
  else
    fail "list: the failure does not name installation/repositories"
  fi
}

# case_public_fail <applier> — an owner whose public listing fails on both
# endpoints fails the enumeration, even though the installation listing worked.
case_public_fail() {
  local d; d=$(new_case pubfail)
  touch "$d/users_fail_metadatastician" "$d/orgs_fail_metadatastician"
  run_list "$d" ghs_app hyperpolymath,metadatastician "$1"
  expect_list "a rate-limited owner fails closed, not empty" "$d" 1
  if grep -q 'metadatastician' "$d/err"; then
    pass "list: the failure names the owner"
  else
    fail "list: the failure does not name the owner"
  fi
}

# case_main_app <applier> — end to end: under an App token the private
# repository is fetched and classified, and appears in the census.
case_main_app() {
  local d; d=$(new_case mainapp)
  run_main "$d" ghs_app "$1"
  if [ "$(cat "$d/rc")" = 0 ] && grep -qF "$(printf 'hyperpolymath/priv-b\tci.yml\tFRESH')" "$d/out"; then
    pass "main: the census classifies the private repository"
  else
    fail "main: private repository missing from the census (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/err" | tail -5 >&2
  fi
}

# case_main_fail <applier> — end to end: a failed enumeration stops the run,
# writes no census, and says the enumeration failed.
case_main_fail() {
  local d; d=$(new_case mainfail)
  touch "$d/inst_fail"
  run_main "$d" ghs_app "$1"
  if [ "$(cat "$d/rc")" = 1 ] && ! grep -q '^REPO' "$d/out" \
     && grep -q 'repository enumeration failed' "$d/err"; then
    pass "main: a failed enumeration stops the run before any census"
  else
    fail "main: failed enumeration not reported as such (rc=$(cat "$d/rc"))"
  fi
}

# case_main_squabbler <applier>, end to end, audit mode, --ensure-squabbler:
# a repo whose only standards pins are MOVED (one fix run clears them) reports
# SQUABBLER-MISSING, a fork reports SQUABBLER-FORK, and audit mode writes no
# caller file and opens nothing.
case_main_squabbler() {
  local d; d=$(new_case mainsq)
  touch "$d/fork_pub-c"
  : > "$d/calls.log"
  # shellcheck disable=SC2016  # $1 is expanded by the inner shell
  env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN=ghs_app GITHUB_TOKEN= TARGET="$T" \
    bash -c 'source "$1"; validate_target() { return 0; }; target_has_squabbler() { return 0; }; shift; main "$@"' _ "$1" \
      --to "$T" --owners hyperpolymath,metadatastician --ensure-squabbler > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tcicd-squabbler.yml\tSQUABBLER-MISSING')" "$d/out" \
     && grep -qF "$(printf 'metadatastician/pub-c\tcicd-squabbler.yml\tSQUABBLER-FORK')" "$d/out" \
     && ! grep -q 'graphql\|pulls\|git/refs' <(grep -v '^api graphql -f query=query' "$d/calls.log" | grep -v 'HEAD:.github/workflows'); then
    pass "main: --ensure-squabbler reports MISSING for a repo, FORK for a fork, and writes nothing in audit"
  else
    fail "main: --ensure-squabbler census wrong (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" >&2
  fi
}

# run_content <dir> <applier> [args...] — the whole applier in audit mode, with
# the network ancestry proof stubbed out and extra arguments passed through.
run_content() {
  local d="$1" a="$2"; shift 2
  : > "$d/calls.log"
  # shellcheck disable=SC2016  # $1 is expanded by the inner shell
  env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN=ghs_app GITHUB_TOKEN= TARGET="$T" \
    bash -c 'source "$1"; validate_target() { return 0; }; shift; main "$@"' _ "$a" \
      --to "$T" --owners hyperpolymath,metadatastician "$@" > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
}
P="dddddddddddddddddddddddddddddddddddddddd"
STAMP_HEX="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

# case_main_content <applier> — --proven-sha reads the manifest at that commit
# and gives a stale stamped copy its own BEHIND-CONTENT row, while the pin row
# of the same repository is unchanged.
case_main_content() {
  local d; d=$(new_case content)
  printf '{"schema":"proven-cicd/manifest/v1","artifacts":[{"artifact":"proven-lock-gate","version":"0.1.0","sha256":"x","template":"t","install_path":"p"}]}' \
    > "$d/proven_manifest.json"
  printf '# proven-cicd: proven-lock-gate@0.0.9 sha256:%s\nname: g\n' "$STAMP_HEX" > "$d/own_stamped"
  run_content "$d" "$1" --proven-sha "$P"
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tproven-lock-gate.yml\tBEHIND-CONTENT\tproven-lock-gate@0.0.9 -> 0.1.0')" "$d/out" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')" "$d/out" \
     && grep -qF "proven-cicd-and-workflows/contents/proven/manifest.json?ref=${P}" "$d/calls.log"; then
    pass "main: --proven-sha reports a stale stamped copy BEHIND-CONTENT, read at the pinned commit"
  else
    fail "main: content census wrong (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# case_main_content_fail <applier> — a lost manifest degrades loudly: the pin
# census completes, one CONTENT-CENSUS-FAILED row, no content rows, exit 1.
case_main_content_fail() {
  local d bad label
  # Two ways to lose the manifest: unreadable (404) and not a valid manifest.
  for bad in missing invalid; do
    d=$(new_case "contentfail-$bad")
    printf '# proven-cicd: proven-lock-gate@0.0.9 sha256:%s\nname: g\n' "$STAMP_HEX" > "$d/own_stamped"
    [ "$bad" = invalid ] && printf 'not json' > "$d/proven_manifest.json"
    run_content "$d" "$1" --proven-sha "$P"
    label="main: a manifest that is $bad degrades loudly (pin census complete, one CONTENT-CENSUS-FAILED row, exit 1)"
    if [ "$(cat "$d/rc")" = 1 ] && grep -q '^REPO' "$d/out" \
       && [ "$(grep -c 'CONTENT-CENSUS-FAILED' "$d/out")" = 1 ] \
       && grep -qF "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')" "$d/out" \
       && grep -qF "$(printf 'metadatastician/pub-c\tci.yml\tFRESH')" "$d/out" \
       && ! grep -qE 'BEHIND-CONTENT|CONTENT-CURRENT|CONTENT-UNLISTED' "$d/out" \
       && grep -q 'the content census did not run' "$d/err"; then
      pass "$label"
    else
      fail "$label — rc=$(cat "$d/rc")"
      sed 's/^/    /' "$d/out" >&2
    fi
  done
}

# case_main_content_off <applier> — without --proven-sha nothing changes: no
# manifest call, no content row.
case_main_content_off() {
  local d; d=$(new_case contentoff)
  printf '# proven-cicd: proven-lock-gate@0.0.9 sha256:%s\nname: g\n' "$STAMP_HEX" > "$d/own_stamped"
  run_content "$d" "$1"
  if [ "$(cat "$d/rc")" = 0 ] && ! grep -q 'CONTENT' "$d/out" \
     && ! grep -q 'proven-cicd-and-workflows' "$d/calls.log"; then
    pass "main: without --proven-sha there is no manifest call and no content row"
  else
    fail "main: content census ran without --proven-sha (rc=$(cat "$d/rc"))"
  fi
}

# case_main_content_fix <applier> — the content census is read-only in --fix
# too. The stub's ci.yml pin sits under the former owner, so fix mode does
# land a re-pin PR (FRESH,MOVED); that commit must carry ci.yml and must NOT
# carry the stale stamped copy, which is reported BEHIND-CONTENT and left alone.
case_main_content_fix() {
  local d root sha
  d=$(new_case contentfix)
  root=$(mktemp -d "$TMP/contentfix-root.XXXX")
  git -C "$root" init -q
  git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m target
  sha=$(git -C "$root" rev-parse HEAD)
  printf '{"schema":"proven-cicd/manifest/v1","artifacts":[{"artifact":"proven-lock-gate","version":"0.1.0","sha256":"x","template":"t","install_path":"p"}]}' \
    > "$d/proven_manifest.json"
  printf '# proven-cicd: proven-lock-gate@0.0.9 sha256:%s\nname: g\n' "$STAMP_HEX" > "$d/own_stamped"
  : > "$d/calls.log"
  # shellcheck disable=SC2016  # $1 and $2 are expanded by the inner shell
  env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN=ghs_app GITHUB_TOKEN= TARGET="$sha" \
    bash -c 'source "$1"; STANDARDS_ROOT="$2"; validate_target() { return 0; }; shift 2; main "$@"' _ "$1" "$root" \
      --to "$sha" --owners hyperpolymath,metadatastician --fix --proven-sha "$P" > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
  local paths
  paths=$(jq -r '.variables.input.fileChanges.additions[]?.path' "$d/commit.json" 2>/dev/null)
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tproven-lock-gate.yml\tBEHIND-CONTENT')" "$d/out" \
     && printf '%s\n' "$paths" | grep -qxF '.github/workflows/ci.yml' \
     && ! printf '%s\n' "$paths" | grep -qF 'proven-lock-gate.yml'; then
    pass "main: --fix re-pins ci.yml but never commits the stale stamped copy"
  else
    fail "main: --fix acted on a content row (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" >&2; tail -5 "$d/err" | sed 's/^/    /' >&2
  fi
}

# case_main_owner_stale <applier> — a standards lock record that still carries the
# former owner's id gets its own OWNER-ID-STALE row, and the pin row of the same
# repository is unchanged. (P is a 40-hex stand-in for a standards commit.)
case_main_owner_stale() {
  local d; d=$(new_case ownerstale)
  printf "version: 'v0.0.3'\ndependencies:\n    'metadatastician/standards@%s':\n        ref: '%s'\n        owner_id: 6759885\n" "$P" "$P" > "$d/own_lock"
  run_content "$d" "$1"
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tactions.lock\tOWNER-ID-STALE\t1 standards record(s) carry owner_id 6759885: metadatastician/standards@dddddddd')" "$d/out" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')" "$d/out"; then
    pass "main: a standards lock record under the former owner id is reported OWNER-ID-STALE"
  else
    fail "main: owner-id census wrong (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# case_main_owner_clean <applier> — a lock whose standards record carries the
# current owner's id produces no actions.lock row at all.
case_main_owner_clean() {
  local d; d=$(new_case ownerclean)
  printf "version: 'v0.0.3'\ndependencies:\n    'metadatastician/standards@%s':\n        ref: '%s'\n        owner_id: 297579217\n" "$P" "$P" > "$d/own_lock"
  run_content "$d" "$1"
  if [ "$(cat "$d/rc")" = 0 ] \
     && ! grep -qF "$(printf 'hyperpolymath/pub-a\tactions.lock')" "$d/out" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')" "$d/out"; then
    pass "main: a standards lock record with the current owner id gets no row"
  else
    fail "main: a clean lock produced an owner-id row (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# case_main_owner_unread <applier> — a listed actions.lock that could not be read
# as text is reported OWNER-ID-UNREAD. It is never read as "no lock" (no row).
case_main_owner_unread() {
  local d; d=$(new_case ownerunread)
  : > "$d/own_lock_unread"
  run_content "$d" "$1"
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tactions.lock\tOWNER-ID-UNREAD\t')" "$d/out" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')" "$d/out"; then
    pass "main: a listed but unreadable actions.lock is reported OWNER-ID-UNREAD"
  else
    fail "main: an unreadable lock was not reported (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# case_main_deed_overcap <applier> — a root deed with a line over 998 octets gets its
# own DEED-OVERCAP row (count, line number, octet size) and the pin row of the same
# repository is unchanged.
case_main_deed_overcap() {
  local d; d=$(new_case deedover)
  { printf '(deed\n'; head -c 1159 /dev/zero | tr '\0' 'a'; printf '\n)\n'; } > "$d/own_deed"
  run_content "$d" "$1"
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tpub-a_chora.deed\tDEED-OVERCAP\t1 line(s) over 998 octets: L2=1159')" "$d/out" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')" "$d/out"; then
    pass "main: a root deed line over 998 octets is reported DEED-OVERCAP (with line and size)"
  else
    fail "main: deed over-cap census wrong (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# case_main_deed_clean <applier> — a root deed within the cap, and a repository with
# no root deed at all, produce no deed row.
case_main_deed_clean() {
  local d; d=$(new_case deedclean)
  printf '(deed\n  (identity))\n' > "$d/own_deed"
  run_content "$d" "$1"
  local ok=0
  [ "$(cat "$d/rc")" = 0 ] && ! grep -qF "_chora.deed" "$d/out" && ok=1
  rm -f "$d/own_deed"
  run_content "$d" "$1"
  { [ "$(cat "$d/rc")" = 0 ] && ! grep -qF "_chora.deed" "$d/out"; } || ok=0
  if [ "$ok" = 1 ]; then
    pass "main: an in-cap deed, and no deed at all, get no deed row"
  else
    fail "main: a clean or absent deed produced a row"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# case_main_deed_unread <applier> — a deed blob that came back without text is
# reported DEED-OVERCAP-UNREAD, never read as "no over-cap line".
case_main_deed_unread() {
  local d; d=$(new_case deedunread)
  : > "$d/own_deed_unread"
  run_content "$d" "$1"
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tpub-a_chora.deed\tDEED-OVERCAP-UNREAD\t')" "$d/out"; then
    pass "main: a deed that could not be read whole is reported DEED-OVERCAP-UNREAD"
  else
    fail "main: an unreadable deed was not reported (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# case_main_deed_renamed <applier> — a root deed that is NOT named after the repository
# (a repository renamed after its deed was minted) is still found and judged under its
# own file name; estate_chora.deed is ignored.
case_main_deed_renamed() {
  local d; d=$(new_case deedrenamed)
  { printf '(deed\n'; head -c 1159 /dev/zero | tr '\0' 'a'; printf '\n)\n'; } > "$d/own_deed"
  printf 'former-name_chora.deed' > "$d/own_deed_name"
  : > "$d/own_estate_deed"
  run_content "$d" "$1"
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tformer-name_chora.deed\tDEED-OVERCAP\t1 line(s) over 998 octets: L2=1159')" "$d/out" \
     && ! grep -qF 'estate_chora.deed' "$d/out"; then
    pass "main: a root deed under a former repository name is judged under its own name; estate_chora.deed is ignored"
  else
    fail "main: a differently named root deed was missed or estate_chora.deed was read (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# case_main_deed_rest_fail <applier> — a differently named deed that cannot be read is
# reported DEED-OVERCAP-UNREAD under its own name, not skipped.
case_main_deed_rest_fail() {
  local d; d=$(new_case deedrestfail)
  printf '(deed)\n' > "$d/own_deed"
  printf 'former-name_chora.deed' > "$d/own_deed_name"
  : > "$d/own_deed_rest_fail"
  run_content "$d" "$1"
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tformer-name_chora.deed\tDEED-OVERCAP-UNREAD\t')" "$d/out"; then
    pass "main: a differently named deed that could not be read is reported DEED-OVERCAP-UNREAD under its own name"
  else
    fail "main: an unreadable differently named deed was not reported (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# Planted positives: the stub must be able to say no, or every fail-closed case
# above could pass because nothing ever failed.
d=$(new_case planted)
if env GH_FIX="$d" GH_TOKEN=ghp_pat "$LSTUB/gh" api installation/repositories >/dev/null 2>&1; then
  fail "planted: stub let a PAT list installation/repositories"
else
  pass "planted: stub refuses installation/repositories to a PAT"
fi
touch "$d/users_fail_metadatastician"
if env GH_FIX="$d" GH_TOKEN=ghs_app "$LSTUB/gh" api users/metadatastician/repos >/dev/null 2>&1; then
  fail "planted: stub ignored a users_fail flag"
else
  pass "planted: stub fails a flagged users/ listing"
fi

case_app "$APPLIER"
case_github_token "$APPLIER"
case_pat "$APPLIER"
case_owner_filter "$APPLIER"
case_org_fallback "$APPLIER"
case_inst_fail "$APPLIER"
case_public_fail "$APPLIER"
case_main_app "$APPLIER"
case_main_fail "$APPLIER"
case_main_squabbler "$APPLIER"
case_main_content "$APPLIER"
case_main_content_fail "$APPLIER"
case_main_content_off "$APPLIER"
case_main_owner_stale "$APPLIER"
case_main_owner_clean "$APPLIER"
case_main_owner_unread "$APPLIER"
case_main_deed_overcap "$APPLIER"
case_main_deed_clean "$APPLIER"
case_main_deed_unread "$APPLIER"
case_main_deed_renamed "$APPLIER"
case_main_deed_rest_fail "$APPLIER"
case_main_content_fix "$APPLIER"

# Mutant: the census stays silent about an unreadable lock (the defect Codex found
# on #1565: it read as "this repository has no lock"). It must turn red.
M="$TMP/mutant_unread_silent.sh"; cp "$APPLIER" "$M"
sed -i -E 's@^    elif \[ -f "\$rdir/\.actions\.lock\.unread" \]; then$@    elif false; then@' "$M"
if cmp -s "$APPLIER" "$M"; then
  fail "unread-silent mutant did not apply cleanly"
else
  bash -n "$M" || fail "unread-silent mutant is syntactically invalid"
  ( case_main_owner_unread "$M" ) >"$TMP/unread_mut.out" 2>&1
  if grep -q '^  *FAIL\|FAIL' "$TMP/unread_mut.out"; then
    pass "mutant 'unread_silent' killed by the unreadable-lock case"
  else
    fail "mutant 'unread_silent' stayed GREEN"
  fi
fi

# A repository whose own cicd-squabbler.yml runs no gate is never overwritten:
# it is reported SQUABBLER-DEFERRED:NAME-TAKEN.
d=$(new_case owned)
printf 'name: mine\njobs:\n  lint:\n    runs-on: x\n    steps:\n      - run: echo lint\n' > "$d/own_squabbler"
: > "$d/calls.log"
# shellcheck disable=SC2016  # $1 is expanded by the inner shell
env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN=ghs_app GITHUB_TOKEN= TARGET="$T" \
  bash -c 'source "$1"; validate_target() { return 0; }; target_has_squabbler() { return 0; }; shift; main "$@"' _ "$APPLIER" \
    --to "$T" --owners hyperpolymath --ensure-squabbler > "$d/out" 2> "$d/err"
if grep -qF "$(printf 'hyperpolymath/pub-a\tcicd-squabbler.yml\tSQUABBLER-DEFERRED:NAME-TAKEN')" "$d/out"; then
  pass "main: an own cicd-squabbler.yml without the gate is NAME-TAKEN, never overwritten"
else
  fail "main: an own cicd-squabbler.yml was not reported NAME-TAKEN"; sed 's/^/    /' "$d/out" >&2
fi

# --ensure-squabbler in FIX mode, end to end: a non-fork repo with no gate gets
# the caller committed (createCommitOnBranch payload captured by the stub) with
# the canonical uses line pinned at the target, its lock entry written by the
# real relock against a synthetic standards checkout, and a PR opened.
d=$(new_case fixsq)
SQS="$d/standards"; git init -q -b main "$SQS"; git -C "$SQS" config user.email t@t; git -C "$SQS" config user.name t
mkdir -p "$SQS/.github/workflows"
for r in x.yml cicd-squabbler-reusable.yml; do
  printf 'on: { workflow_call: {} }\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111 # v1\n' > "$SQS/.github/workflows/$r"
done
cat > "$SQS/.github/workflows/actions.lock" <<'Y'
version: 'v0.0.3'
workflows:
    '.github/workflows/cicd-squabbler-reusable.yml':
        - 'actions/checkout@1111111111111111111111111111111111111111'
    '.github/workflows/x.yml':
        - 'actions/checkout@1111111111111111111111111111111111111111'
dependencies:
    'actions/checkout@1111111111111111111111111111111111111111':
        ref: 'v1'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 10
        repo_id: 11
Y
git -C "$SQS" add -A; git -C "$SQS" commit -q -m sq; SQT=$(git -C "$SQS" rev-parse HEAD)
# The repository's ci.yml (served by the stub) calls x.yml at the target.
cat > "$d/own_lock" <<Y
version: 'v0.0.3'
workflows:
    '.github/workflows/ci.yml':
        - 'hyperpolymath/standards@$SQT'
dependencies:
    'actions/checkout@1111111111111111111111111111111111111111':
        ref: 'v1'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 10
        repo_id: 11
    'hyperpolymath/standards@$SQT':
        ref: '$SQT'
        commit: 'sha1-$SQT'
        owner_id: 6759885
        repo_id: 1116521501
        uses:
            - 'actions/checkout@1111111111111111111111111111111111111111'
Y
: > "$d/calls.log"
# shellcheck disable=SC2016  # $1 and $2 are expanded by the inner shell
env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN=ghs_app GITHUB_TOKEN= TARGET="$SQT" \
  bash -c 'source "$1"; STANDARDS_ROOT="$2"; validate_target() { return 0; }; shift 2; main "$@"' _ "$APPLIER" "$SQS" \
    --to "$SQT" --owners hyperpolymath --fix --ensure-squabbler > "$d/out" 2> "$d/err"
rc_fixsq=$?
sqcaller=$(jq -r '.variables.input.fileChanges.additions[] | select(.path == ".github/workflows/cicd-squabbler.yml") | .contents' "$d/commit.json" 2>/dev/null | base64 -d 2>/dev/null)
sqlock=$(jq -r '.variables.input.fileChanges.additions[] | select(.path == ".github/workflows/actions.lock") | .contents' "$d/commit.json" 2>/dev/null | base64 -d 2>/dev/null)
if [ "$rc_fixsq" = 0 ] \
   && grep -qF "$(printf 'hyperpolymath/pub-a\tcicd-squabbler.yml\tSQUABBLER-ADDED')" "$d/out" \
   && printf '%s\n' "$sqcaller" | grep -qxF "    uses: metadatastician/standards/.github/workflows/cicd-squabbler-reusable.yml@$SQT" \
   && printf '%s\n' "$sqlock" | grep -qxF "    '.github/workflows/cicd-squabbler.yml':" \
   && grep -q '^pr create ' "$d/calls.log" \
   && grep -qF "$(printf 'hyperpolymath/pub-a\t-\tPR-OPENED')" "$d/out"; then
  pass "main: --fix --ensure-squabbler commits the caller pinned at the target, writes its lock entry and opens the PR"
else
  fail "main: --fix --ensure-squabbler did not commit caller + lock entry (rc=$rc_fixsq)"
  sed 's/^/    /' "$d/out" >&2; tail -5 "$d/err" | sed 's/^/    /' >&2
  printf '%s\n' "$sqcaller" | sed 's/^/    caller: /' >&2
fi

# --ensure-squabbler against a target with no squabbler reusable stops the
# run before any census or write (a caller pinned there could never start).
d=$(new_case nosq)
: > "$d/calls.log"
# shellcheck disable=SC2016  # $1 is expanded by the inner shell
env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN=ghs_app GITHUB_TOKEN= TARGET="$T" \
  bash -c 'source "$1"; validate_target() { return 0; }; target_has_squabbler() { return 1; }; shift; main "$@"' _ "$APPLIER" \
    --to "$T" --owners hyperpolymath --ensure-squabbler > "$d/out" 2> "$d/err"
rc_nosq=$?
if [ "$rc_nosq" = 1 ] && ! grep -q '^REPO' "$d/out" && grep -q 'has no .github/workflows/cicd-squabbler-reusable.yml' "$d/err"; then
  pass "main: --ensure-squabbler refuses a target with no squabbler reusable"
else
  fail "main: a target with no squabbler reusable was not refused (rc=$rc_nosq)"
fi

# --- 5. a reachable target is refused when its own lock fails lock-selfcheck --
# GitHub validates each caller against the TARGET's actions.lock, so a target
# that is reachable from main but whose lock the runner refuses (standards
# fad242d3: ten self-SHA leaves) must never be pinned. Ancestry is stubbed
# green and lock-selfcheck.sh is replaced by a stub whose verdict is set per
# case, so what is under test is validate_target's own wiring: a refusal (1)
# and a not-inspected (2) both stop the run; a pass lets it through.
echo "== 5. target self-check =="
# case_target_selfcheck <applier> <selfcheck-rc> <want-rc> <label>
case_target_selfcheck() {
  local root sha got=0
  root=$(mktemp -d "$TMP/selfcheck.XXXX")
  mkdir -p "$root/scripts"
  printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$root/scripts/lock-selfcheck.sh"
  git -C "$root" init -q
  git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m target
  sha=$(git -C "$root" rev-parse HEAD)
  # shellcheck disable=SC2016  # expanded by the inner shell
  bash -c 'source "$1"; STANDARDS_ROOT="$2"; assert_pin_ancestry() { return 0; }; validate_target "$3"' \
    _ "$1" "$root" "$sha" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$3" ]; then pass "target self-check: $4"; else fail "target self-check: $4 — rc=$got (want $3)"; fi
}
case_target_selfcheck "$APPLIER" 1 1 "a target lock-selfcheck rejects is refused"
case_target_selfcheck "$APPLIER" 2 1 "a target lock-selfcheck cannot examine is refused"
case_target_selfcheck "$APPLIER" 0 0 "control: a self-consistent reachable target is accepted"

# list_mutant <name> <sed-expr> <case-fn> — apply <sed-expr> to a copy of the
# applier, prove the edit landed and still parses, then require <case-fn> to
# report FAIL against it.
list_mutant() {
  local name="$1" expr="$2" fn="$3"
  local m="$MUT/mutant_${name}.sh" out
  cp "$APPLIER" "$m"
  sed -E -i "$expr" "$m"
  if cmp -s "$APPLIER" "$m"; then
    fail "mutant '$name' changed NOTHING — the sed did not match"; return
  fi
  if ! bash -n "$m" 2>"$MUT/${name}.parse"; then
    fail "mutant '$name' is SYNTACTICALLY INVALID — its redness would be meaningless"
    sed 's/^/    /' "$MUT/${name}.parse" >&2; return
  fi
  out=$("$fn" "$m" 2>&1)
  case "$out" in
    *FAIL*) pass "mutant '$name' killed by $fn" ;;
    *)      fail "mutant '$name' stayed GREEN under $fn" ;;
  esac
}

# shellcheck disable=SC2016  # the ${…} and $(…) below are sed text to match
{
list_mutant app_token_blind 's@^    ghs_\*\)$@    NOT_A_TOKEN_PREFIX*)@' case_app
list_mutant replace_not_union \
  '0,\@^  for owner in \$\{OWNERS//,/ \}; do$@s@@&\n    case "$tok" in ghs_*) continue ;; esac@' \
  case_github_token
list_mutant no_dedupe 's@^  sort -u "\$all"$@  cat "$all"@' case_app
list_mutant owner_filter_dropped "s@'index\\(tolower\\(\\\$0\\), o\\) == 1'@'1'@" case_owner_filter
list_mutant inst_failure_swallowed 's@\|\| \{ log "FATAL: an App installation token[^}]*\}@|| true@' case_inst_fail
list_mutant public_failure_swallowed 's@^      log "FATAL: could not list the repositories of.*$@      :@' case_public_fail
list_mutant fork_not_checked 's@^          true\) sqst=FORK ;;$@          true) sqst=MISSING ;;@' case_main_squabbler
# Proven content: the census must fail closed without its manifest, must read
# the manifest at the pinned commit (not at whatever main is now), and must
# write the content row it computed.
list_mutant content_fail_quiet '/the content census did not run/{n;s@exit 1@:@}' case_main_content_fail
list_mutant content_fail_row_dropped '/printf -- .-.t-.tCONTENT-CENSUS-FAILED/d' case_main_content_fail
list_mutant content_fail_stops_pin_census 's@^      log "ERROR: \$\{content_failed\}.*@&; exit 1@' case_main_content_fail
list_mutant content_manifest_unpinned 's@\?ref=\$\{PROVEN_SHA\}@@' case_main_content
list_mutant content_row_dropped 's@cst=\$\(content_state "\$wf" "\$PROVEN_MANIFEST"\)@cst=""@' case_main_content
list_mutant content_row_writes 's@\[ -n "\$cst" \] \&\& printf@[ -n "$cst" ] \&\& changed+=("$base"); [ -n "$cst" ] \&\& printf@' case_main_content_fix
# Owner ids: the census must read the lock it was given (not skip it), and must
# say nothing when there is nothing to say.
list_mutant owner_row_dropped 's@ost=\$\(lock_owner_state "\$rdir/actions\.lock"\)@ost=""@' case_main_owner_stale
list_mutant owner_row_always 's@\[ -n "\$ost" \] && printf@true \&\& printf@' case_main_owner_clean
# Deed over-cap census: the row must be written, must not be written for a clean
# deed, and an unreadable deed must be said, not skipped.
list_mutant deed_row_dropped 's@dst=\$\(deed_overcap "\$dfile"\)@dst=""@' case_main_deed_overcap
list_mutant deed_row_always 's@\[ -n "\$dst" \] && printf@true \&\& printf@' case_main_deed_clean
list_mutant deed_unread_silent 's@^        \*\.unread\)$@        *.unread-never)@' case_main_deed_unread
# estate_chora.deed is not a repository deed: dropping its exclusion must be caught.
list_mutant deed_estate_not_excluded 's@ \| select\(\. != "estate_chora\.deed"\)@@' case_main_deed_renamed
}

echo
if [ "$rc" -ne 0 ]; then echo "RESULT: FAILED" >&2; else echo "RESULT: all checks passed"; fi
exit $rc
