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
            "dot-local.yml" "dollar-managed.yml" "dollar-unmanaged.yml" "dollar-managed-parent.yml" \
            "owner-stale.lock" "owner-clean.lock" "owner-nonstandards.lock" "owner-tag-key.lock" \
            "envpin-rows" "envpin-target-case" "envpin-bom" "envpin-explicit-key" "envpin-not-rewritten" \
            "health-startup" "health-zero-shape" "health-healthy" "health-ref-suffix" "health-inprogress-ignored" "health-tie-break" "health-pathless"; do
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

# M5a-d — the owner's ruling on ILLEGAL (2026-11-14): `./` local actions are never
# ILLEGAL; `$/` is legal in a file `gh actions-lock` manages and ILLEGAL elsewhere;
# `../` is ILLEGAL even in a managed file. Each mutant undoes one clause.
# (a) a single dot is illegal again: plain local actions would be reported and,
# under --repair-illegal, are legal refs the applier has no business touching.
kill_mutant illegal_dot_slash \
  's@\(\\\.\\\./\|@(\\.\\.?/|@' \
  "FAIL dot-local.yml"
# (b) the managed-file exemption never applies: gh actions-lock's own `$/` is reported.
kill_mutant managed_exempt_off \
  's@^  head -n 5 "\$1" 2>/dev/null \| grep -qE "\$ACTIONS_LOCK_MANAGED_RE"@  false@' \
  "FAIL dollar-managed.yml"
# (c) the exemption swallows `../` too: a parent-relative ref in a managed file would
# pass the census while GitHub still refuses it at parse time.
kill_mutant managed_exempts_parent \
  's@grep -vE "\$DOLLAR_USES_RE"@grep -vE "uses:"@' \
  "FAIL dollar-managed-parent.yml"
# (d) the repair ignores the managed-file exemption and rewrites a legal `$/` line.
kill_mutant repair_ignores_managed \
  's@^  if ! actions_lock_managed "\$f"; then@  if true; then@' \
  "FAIL repair rewrote"

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

# M10 — read the stamp from any line, not from its own (line 2 under the SPDX
# line, or legacy line 1). A body that merely quotes a stamp (a comment, a
# heredoc, a test fixture) would be reported as a copy.
kill_mutant content_stamp_anywhere \
  's@first=\$\(stamp_text "\$f"\)@first=$(grep -m1 "^# proven-cicd:" "$f" 2>/dev/null)@' \
  "FAIL content-not-first.yml"

# M10b — find the stamp on line 1 only, as before proven-cicd #116 moved it under
# the SPDX line. Every copy in the current layout then drops out of the census,
# and every current template is refused by --fix-content.
kill_mutant stamp_line_legacy_only \
  's@^    case "\$l2" in "# proven-cicd:"\*\) echo 2; return 0 ;; esac$@    :@' \
  "FAIL content-l2-behind.yml"

# M10c — hash every line but line 1, whatever the layout. In the current layout
# that hashes the stamp and skips the SPDX line, so a good template never
# matches its own stamp.
kill_mutant stamp_region_line_one \
  's@NR == sl \{ next \}@NR == 1 { next }@' \
  "FAIL template_ok refused a good line-2 template"

# M10d — say nothing about a stamp off its line. A copy whose stamp was pushed
# down a line (or lost) silently leaves the content census.
kill_mutant misplaced_stamp_silent \
  's@^      if \[ -n "\$stray" \]; then$@      if false; then@' \
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
# Codex findings on #1602, one mutant each: the target must be compared
# case-insensitively, only a child of `env:` counts, and a `#` inside a quoted value
# is not a comment. Each is killed by a known-answer control, not by a stub case.
kill_mutant envpin_target_case_ignored 's@tgt = tolower\(target\)@tgt = target@' "FAIL envpin-target-case"
kill_mutant envpin_context_ignored 's@ && parent == "env" && !inmx\)@ \&\& !inmx)@' "FAIL envpin-rows"
kill_mutant envpin_quote_hash_stripped 's@if \(c == "\\047" \|\| c == "\\""\) \{@if (0) {@' "FAIL envpin-rows"
# Second Codex round on #1602: whitespace after the colon, multi-line quoted scalars,
# and a block-scalar value must each be handled, not misread or silent.
kill_mutant envpin_space_trim_dropped 's@ sub\(/\^\[\[:space:\]\]\+/, "", rest\)@@' "FAIL envpin-rows"
kill_mutant envpin_multiline_quote_read 's@^    inq != "" \{ if@    inq == "NEVER" { if@' "FAIL envpin-rows"
kill_mutant envpin_block_scalar_silent 's@if \(tracked\) outr\(sprintf\("ENV-PIN-UNJUDGED\\t%s L%d value is a block scalar@if (0) outr(sprintf("ENV-PIN-UNJUDGED\\t%s L%d value is a block scalar@' "FAIL envpin-rows"
# Third Codex round on #1602: an anchor or tag before a scalar must not hide the scalar
# style (a multi-line quote, a block scalar) nor the value itself.
kill_mutant envpin_anchor_value_kept 's@; rest = props\(rest\)@@' "FAIL envpin-rows"
kill_mutant envpin_anchor_hides_quote 's@bp = props\(body\);@bp = body;@' "FAIL envpin-rows"
# Fourth Codex round on #1602: a flow collection that runs over several lines must be
# tracked to its closing bracket (its lines are not keys), and a tracked key whose own
# value is one must be reported, not skipped.
kill_mutant envpin_flow_multiline_read 's@^    flow > 0 \{ flow@    flow > 99 { flow@' "FAIL envpin-rows"
kill_mutant envpin_flow_value_silent 's@if \(tracked\) outr\(sprintf\("ENV-PIN-UNJUDGED\\t%s L%d value is a flow collection@if (0) outr(sprintf("ENV-PIN-UNJUDGED\\t%s L%d value is a flow collection@' "FAIL envpin-rows"
# Fifth Codex round on #1602: a bracket inside a comment or a quoted scalar is not flow
# structure, so it must not end (or open) a flow collection early.
kill_mutant envpin_flow_comment_counted 's@else if \(ch == "#" && prev ~ /\[\[:space:\]\]/\) break@else if (0) break@' "FAIL envpin-rows"
kill_mutant envpin_flow_quote_counted 's@else if \(\(ch == "\\047" \|\| ch == "\\""\) && isb\) q = ch@else if (0) q = ch@' "FAIL envpin-rows"
# Seventh Codex round on #1602: an anchor or tag on a mapping key, a CR or trailing
# whitespace after a block-scalar header, and a quote that stays open across the lines
# of a flow collection must each be handled.
kill_mutant envpin_key_props_kept 's@match\(bp, /\^\[A-Za-z_\]@match(body, /^[A-Za-z_]@' "FAIL envpin-rows"
kill_mutant envpin_trailing_space_kept 's@^    \{ sub\(/\[\[:space:\]\]\+\$/, ""\) \}$@    { }@' "FAIL envpin-rows"
kill_mutant envpin_flow_quote_reset 's@n = length\(line\); q = fq; d = 0@n = length(line); q = ""; d = 0@' "FAIL envpin-rows"
# Eighth Codex/CodeRabbit round on #1602: a BOM, an apostrophe inside a plain scalar of a
# flow collection, a quoted structural key, and the closing quote of a quoted value.
kill_mutant envpin_bom_kept 's@^    NR == 1 \{ sub\("\^\\357\\273\\277", ""\) \}$@    NR == 1 { }@' "FAIL envpin-bom"
kill_mutant envpin_apostrophe_quote 's@ && isb\) q = ch@) q = ch@' "FAIL envpin-rows"
kill_mutant envpin_quoted_key_ignored 's@match\(bp, /\^"\(@match(bp, /^NEVER"(@' "FAIL envpin-rows"
kill_mutant envpin_quote_escape_first 's@q = qend\(val\)@q = index(substr(val, 2), c) + 1@' "FAIL envpin-rows"
# Ninth round on #1602: a block scalar as a sequence item, a plain scalar that continues on
# the next line, and YAML explicit mapping keys (not parsed, and said so).
kill_mutant envpin_seq_blockscalar_read 's@skip = n0; next@next@' "FAIL envpin-rows"
kill_mutant envpin_plain_continuation_ignored 's@if \(n > pn\) outr\(pcont, pv\); else outr\(pend, pv\)@outr(pend, pv)@' "FAIL envpin-rows"
kill_mutant envpin_explicit_key_silent 's@if \(!xwarn\) \{ xwarn = 1; outr@if (0) { xwarn = 1; outr@' "FAIL envpin-explicit-key"
# Tenth round on #1602: a doubled single quote inside a flow scalar, and escapes in a
# double-quoted key.
kill_mutant envpin_flow_doubled_quote 's@if \(q == "\\047" && substr\(line, i \+ 1, 1\) == "\\047"\) i\+\+; else q = ""@q = ""@' "FAIL envpin-rows"
kill_mutant envpin_key_escape_literal 's@key = unesc\(substr\(key, 2, length\(key\) - 2\)\)@key = substr(key, 2, length(key) - 2)@' "FAIL envpin-rows"
# Eleventh round on #1602: a matrix axis named env is not an environment map, and
# escapes in a double-quoted pin value are decoded.
kill_mutant envpin_matrix_env_read 's@ && !inmx\)@)@' "FAIL envpin-rows"
kill_mutant envpin_value_escape_literal 's@if \(c == "\\""\) val = unesc\(val\)@@' "FAIL envpin-rows"

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
  # $GH_FIX/own_envpin: each repository also holds that workflow, named env-pin.yml.
  [ -f "$GH_FIX/own_envpin" ] && extra=$(printf '%s' "$extra" | jq --rawfile s "$GH_FIX/own_envpin" '. + [{name: "env-pin.yml", type: "blob", object: {text: $s}}]')
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
  # missing_<name> in $GH_FIX: that repository does not exist (404), as for a typo,
  # a rename or a repository this credential cannot see.
  [ -f "$GH_FIX/missing_${p##*/}" ] && refuse 404 "Not Found"
  f=false; [ -f "$GH_FIX/fork_${p##*/}" ] && f=true
  j="{\"fork\": $f, \"default_branch\": \"main\"}"
  if [ -n "$jqx" ]; then printf '%s' "$j" | jq -r "$jqx"; else printf '%s' "$j"; fi
  exit 0
fi
case "$p" in
  # The published proven-cicd manifest, served raw from $GH_FIX/proven_manifest.json.
  repos/hyperpolymath/proven-cicd-and-workflows/contents/proven/manifest.json)
    body="$GH_FIX/proven_manifest.json" ;;
  # The template --fix-content installs, served raw from $GH_FIX/proven_template.yml.
  repos/hyperpolymath/proven-cicd-and-workflows/contents/templates/proven-lock-gate.yml)
    body="$GH_FIX/proven_template.yml" ;;
  repos/*/contents/*_chora.deed)
    [ -f "$GH_FIX/own_deed_rest_fail" ] && refuse 403 "This API returns blobs up to 1 MB in size. The requested blob is too large"
    body="$GH_FIX/own_deed" ;;
  # Actions runs (the health block). $GH_FIX/runs.json is the answer for EVERY
  # repository (default: no runs); runs_fail makes the list refuse; jobs_<id>.json
  # answers a run's jobs and jobs_fail_<id> makes that read refuse.
  repos/*/actions/runs/*/jobs)
    jid="${p%/jobs}"; jid="${jid##*/}"
    [ -f "$GH_FIX/jobs_fail_$jid" ] && refuse 403 "Resource not accessible by integration"
    body="$GH_FIX/jobs_$jid.json" ;;
  repos/*/actions/runs)
    [ -f "$GH_FIX/runs_fail" ] && refuse 403 "Resource not accessible by integration"
    if [ -f "$GH_FIX/runs.json" ]; then body="$GH_FIX/runs.json"; else echo '{"workflow_runs": []}'; exit 0; fi ;;
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
# The applier finds its relock script beside itself, and its startup controls fail when it
# is missing. Without this link every case_main_* run against a mutant is red for that
# reason alone, and a no-op mutant would count as killed (it did, for every list_mutant).
ln -s "$(cd "$(dirname "$APPLIER")" && pwd)/relock-standards-pin.sh" "$MUT/relock-standards-pin.sh"

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
  printf '{"schema":"proven-cicd/manifest/v1","artifacts":[{"artifact":"proven-lock-gate","version":"0.1.0","sha256":"x","template":"templates/proven-lock-gate.yml","install_path":"p"}]}' \
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
  printf '{"schema":"proven-cicd/manifest/v1","artifacts":[{"artifact":"proven-lock-gate","version":"0.1.0","sha256":"x","template":"templates/proven-lock-gate.yml","install_path":"p"}]}' \
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

# stamp_into <applier> <out> <artifact> <version> <body> — write <out> as <body>
# under a valid stamp, hashed by the applier's own stamp_region_sha (the mirror
# of proven-cicd's scripts/proven-stamp.sh, itself under the self-test).
stamp_into() {
  local a="$1" out="$2" art="$3" ver="$4" body="$5" h
  printf '%s' "$body" > "$out.body"
  # shellcheck disable=SC2016  # $1 and $2 are expanded by the inner shell
  h=$(bash -c 'source "$1"; stamp_region_sha "$2"' _ "$a" "$out.body")
  { printf '# proven-cicd: %s@%s sha256:%s\n' "$art" "$ver" "$h"; cat "$out.body"; } > "$out"; rm -f "$out.body"
}
CO_OLD="1111111111111111111111111111111111111111"; CO_NEW="2222222222222222222222222222222222222222"
# content_fixture <applier> <dir> [extra template line] — manifest at 0.2.0, the
# template at 0.2.0, and a 0.1.0 copy in every repository whose local lines
# differ from the template's (an older suite pin, a checkout SHA Dependabot moved).
content_fixture() {
  local a="$1" d="$2" extra="${3:-}"
  printf '{"schema":"proven-cicd/manifest/v1","artifacts":[{"artifact":"proven-lock-gate","version":"0.2.0","sha256":"x","template":"templates/proven-lock-gate.yml","install_path":"p"}]}' \
    > "$d/proven_manifest.json"
  stamp_into "$a" "$d/proven_template.yml" proven-lock-gate 0.2.0 "$(printf 'name: gate\nenv:\n  # proven-cicd:local-next\n  PROVEN_SHA: "%s"\njobs:\n  g:\n    steps:\n      # proven-cicd:local-next\n      - uses: actions/checkout@%s # v4\n%s      - run: echo new\n' "$CO_NEW" "$CO_NEW" "$extra")"
  stamp_into "$a" "$d/own_stamped" proven-lock-gate 0.1.0 "$(printf 'name: gate\nenv:\n  # proven-cicd:local-next\n  PROVEN_SHA: "%s"\njobs:\n  g:\n    steps:\n      # proven-cicd:local-next\n      - uses: actions/checkout@%s # v5\n      - run: echo old\n' "$CO_OLD" "$CO_OLD")"
}

# case_main_content_refresh <applier> — --fix-content end to end: each stale copy
# is refreshed and lands in a PR on its own branch that holds ONLY that file.
# The copy keeps its local checkout SHA, takes the template body, moves
# PROVEN_SHA to --proven-sha, and carries the template's stamp. ci.yml, whose
# pin sits under the former owner (MOVED), is NOT re-pinned: pins are held.
case_main_content_refresh() {
  local d paths body; d=$(new_case contentrefresh)
  content_fixture "$1" "$d"
  run_content "$d" "$1" --fix-content --proven-sha "$P"
  paths=$(jq -r '.variables.input.fileChanges.additions[]?.path' "$d/commit.json" 2>/dev/null)
  body=$(jq -r '.variables.input.fileChanges.additions[0].contents' "$d/commit.json" 2>/dev/null | base64 -d 2>/dev/null)
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tproven-lock-gate.yml\tBEHIND-CONTENT\tproven-lock-gate@0.1.0 -> 0.2.0')" "$d/out" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tproven-lock-gate.yml\tCONTENT-REFRESHED\tproven-lock-gate@0.1.0 -> 0.2.0')" "$d/out" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\t-\tPR-OPENED\t')" "$d/out" \
     && [ "$paths" = ".github/workflows/proven-lock-gate.yml" ] \
     && [ "$(printf '%s\n' "$body" | head -n 1)" = "$(head -n 1 "$d/proven_template.yml")" ] \
     && printf '%s\n' "$body" | grep -qxF "      - uses: actions/checkout@${CO_OLD} # v5" \
     && printf '%s\n' "$body" | grep -qxF "  PROVEN_SHA: \"${P}\"" \
     && printf '%s\n' "$body" | grep -qxF '      - run: echo new' \
     && grep -qF 'refs/heads/chore/refresh-proven-cicd-content' "$d/calls.log" \
     && grep -qF 'chore(ci): refresh proven-cicd content to dddddddddddd' "$d/calls.log" \
     && [ "$(grep -c "contents/templates/proven-lock-gate.yml?ref=${P}" "$d/calls.log")" = 1 ] \
     && ! grep -qF 'chore/re-point-standards-workflow-pins' "$d/calls.log" \
     && ! grep -qF 'STAMPED-PIN-HELD' "$d/out"; then
    pass "main: --fix-content refreshes the stale copy alone (local SHA kept, PROVEN_SHA moved, template stamp), pins untouched, template read once"
  else
    fail "main: --fix-content refresh wrong (rc=$(cat "$d/rc")); committed: [${paths//$'\n'/ }]"
    sed 's/^/    /' "$d/out" >&2; tail -5 "$d/err" | sed 's/^/    /' >&2
  fi
}

# case_main_content_refresh_envpin <applier> — a refresh replaces the copy with the
# template, so an env pin it carried moves with it. The census reads the refreshed copy,
# so the run must also say what changed: one ENV-PIN-REFRESH-MOVED row per refreshed copy
# naming before and after. The comparison is on COMPLETE values, never the abbreviated
# ones of the report: a changed branch name, a changed expression and two commits that
# share their first 12 hex all count; an unchanged pin gives no row.
case_main_content_refresh_envpin() {
  local d old new want rows pair
  local c1="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" c2="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeef"
  local -a pairs=(
    "${c1}|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|3|a commit that moved"
    "main|release|3|a branch name that changed"
    "\${{ inputs.a }}|\${{ inputs.b }}|3|an expression that changed"
    "${c1}|${c2}|3|two commits that share their first 12 hex"
    "main|main|0|an unchanged value"
  )
  for pair in "${pairs[@]}"; do
    IFS='|' read -r old new want rows <<< "$pair"
    d=$(new_case contentrefreshenv)
    content_fixture "$1" "$d"
    stamp_into "$1" "$d/proven_template.yml" proven-lock-gate 0.2.0 "$(printf 'name: gate\nenv:\n  # proven-cicd:local-next\n  PROVEN_SHA: "%s"\n  CANON_REF: %s\njobs:\n  g:\n    steps:\n      - run: echo new\n' "$CO_NEW" "$new")"
    stamp_into "$1" "$d/own_stamped" proven-lock-gate 0.1.0 "$(printf 'name: gate\nenv:\n  # proven-cicd:local-next\n  PROVEN_SHA: "%s"\n  CANON_REF: %s\njobs:\n  g:\n    steps:\n      - run: echo old\n' "$CO_OLD" "$old")"
    run_content "$d" "$1" --fix-content --proven-sha "$P"
    if [ "$(cat "$d/rc")" = 0 ] && [ "$(grep -c 'ENV-PIN-REFRESH-MOVED' "$d/out")" = "$want" ] \
       && { [ "$want" = 0 ] || [ "$(grep -F 'ENV-PIN-REFRESH-MOVED' "$d/out" | grep -c 'before \[CANON_REF [A-Z]* [^;]*;\] after \[CANON_REF [A-Z]* [^;]*;\]')" = "$want" ]; }; then
      pass "main: a content refresh with ${rows} gives ${want} ENV-PIN-REFRESH-MOVED row(s)"
    else
      fail "main: refresh with ${rows}: want ${want} ENV-PIN-REFRESH-MOVED row(s), got $(grep -c 'ENV-PIN-REFRESH-MOVED' "$d/out") (rc=$(cat "$d/rc"))"
      sed 's/^/    /' "$d/out" >&2; tail -5 "$d/err" | sed 's/^/    /' >&2
    fi
  done
}

# case_main_content_refused <applier> <label> <setup> — a refresh that cannot be
# proven equal to the template is refused with a row, and nothing is committed.
case_main_content_refused() {
  local d; d=$(new_case contentrefused)
  content_fixture "$1" "$d" "${4:-}"
  eval "$3"
  run_content "$d" "$1" --fix-content --proven-sha "$P"
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tproven-lock-gate.yml\tCONTENT-REFRESH-REFUSED\t')" "$d/out" \
     && ! grep -q 'CONTENT-REFRESHED' "$d/out" && [ ! -e "$d/commit.json" ] && ! grep -q 'PR-OPENED' "$d/out"; then
    pass "main: --fix-content refuses $2 and commits nothing"
  else
    fail "main: --fix-content did not refuse $2 (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" >&2
  fi
}

# case_main_stamped_held <applier> — --fix never re-pins a stamped copy, even
# one whose standards pin is MOVED: its body is proven-cicd's, so a re-pin would
# make it drift from its stamp. It is held with a STAMPED-PIN-HELD row, and the
# commit carries ci.yml alone. With `l2` the copy is in the current layout (the
# stamp on line 2 under the SPDX line, proven-cicd #116); without it, legacy.
case_main_stamped_held() {
  local d root sha paths head=""
  [ "${2:-}" = l2 ] && head='# SPDX-License-Identifier: MPL-2.0\n'
  d=$(new_case stampedheld)
  root=$(mktemp -d "$TMP/stampedheld-root.XXXX")
  git -C "$root" init -q
  git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m target
  sha=$(git -C "$root" rev-parse HEAD)
  # shellcheck disable=SC2059  # $head is a printf fragment by design
  printf "${head}"'# proven-cicd: proven-lock-gate@0.1.0 sha256:%s\njobs:\n  a:\n    uses: hyperpolymath/standards/.github/workflows/x.yml@%s\n' "$STAMP_HEX" "$sha" > "$d/own_stamped"
  : > "$d/calls.log"
  # shellcheck disable=SC2016  # $1 and $2 are expanded by the inner shell
  env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN=ghs_app GITHUB_TOKEN= TARGET="$sha" \
    bash -c 'source "$1"; STANDARDS_ROOT="$2"; validate_target() { return 0; }; shift 2; main "$@"' _ "$1" "$root" \
      --to "$sha" --owners hyperpolymath,metadatastician --fix > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
  paths=$(jq -r '.variables.input.fileChanges.additions[]?.path' "$d/commit.json" 2>/dev/null)
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tproven-lock-gate.yml\tSTAMPED-PIN-HELD\t')" "$d/out" \
     && [ "$paths" = ".github/workflows/ci.yml" ]; then
    pass "main: --fix holds a stamped copy's MOVED pin (STAMPED-PIN-HELD, layout ${2:-legacy}) and commits ci.yml alone"
  else
    fail "main: --fix re-pinned a stamped copy (rc=$(cat "$d/rc")); committed: [${paths//$'\n'/ }]"
    sed 's/^/    /' "$d/out" >&2
  fi
}

# case_main_content_flags <applier> — --fix-content is content-only: combined
# with a pin mode, or without the commit to install, it refuses to start.
case_main_content_flags() {
  local d args label
  for args in "--fix-content --fix --proven-sha $P" "--fix-content --ensure-squabbler --proven-sha $P" \
              "--fix-content --repair-illegal --proven-sha $P" "--fix-content"; do
    d=$(new_case contentflags)
    # shellcheck disable=SC2086  # word splitting of $args is intended
    run_content "$d" "$1" $args
    label="main: '$args' refuses to start (exit 2, no census, no write)"
    if [ "$(cat "$d/rc")" = 2 ] && ! grep -q '^REPO' "$d/out" && [ ! -e "$d/commit.json" ]; then
      pass "$label"
    else
      fail "$label — rc=$(cat "$d/rc")"
    fi
  done
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

# case_main_envpin <applier> — env-var pins are counted for a workflow that has no
# `uses:` pin at all, judged against the target, and never rewritten.
case_main_envpin() {
  local d; d=$(new_case envpin)
  { printf 'jobs:\n  g:\n    runs-on: ubuntu-latest\n    env:\n'
    printf "      STANDARDS_PIN: '%s'\n" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    printf '      CANON_REF: %s\n' "$T"
    printf '      # STANDARDS_PIN: %s\n' "$T"
  } > "$d/own_envpin"
  run_content "$d" "$1" --only hyperpolymath/pub-a
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tenv-pin.yml\tENV-PIN-BEHIND\tSTANDARDS_PIN L5 bbbbbbbb (target aaaaaaaa)')" "$d/out" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tenv-pin.yml\tENV-PIN-FRESH\tCANON_REF L6 aaaaaaaa')" "$d/out" \
     && [ "$(grep -c 'ENV-PIN-' "$d/out")" = 2 ] \
     && ! grep -qE "$(printf '\t')env-pin\.yml$(printf '\t')(FRESH|BEHIND|NONE)" "$d/out"; then
    pass "main: env-var pins get their own rows (BEHIND/FRESH), commented lines are skipped, and the pin-free workflow gets no uses: row"
  else
    fail "main: env-var pin census wrong (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -8 >&2
  fi
}

# case_main_envpin_fix_untouched <applier> — under --fix the env-var pin is only
# reported. The stub's ci.yml still sits under the former owner (MOVED), so fix mode
# lands a re-pin commit for ci.yml; it must NOT carry the workflow whose only stale
# pin is an env var, and that workflow stays ENV-PIN-BEHIND.
case_main_envpin_fix_untouched() {
  local d root sha paths
  d=$(new_case envpinfix)
  root=$(mktemp -d "$TMP/envpinfix-root.XXXX")
  git -C "$root" init -q
  git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m target
  sha=$(git -C "$root" rev-parse HEAD)
  printf 'jobs:\n  g:\n    env:\n      STANDARDS_PIN: %s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$d/own_envpin"
  : > "$d/calls.log"
  # shellcheck disable=SC2016  # $1 and $2 are expanded by the inner shell
  env PATH="$LSTUB:$PATH" GH_FIX="$d" GH_TOKEN=ghs_app GITHUB_TOKEN= TARGET="$sha" \
    bash -c 'source "$1"; STANDARDS_ROOT="$2"; validate_target() { return 0; }; shift 2; main "$@"' _ "$1" "$root" \
      --to "$sha" --owners hyperpolymath,metadatastician --only hyperpolymath/pub-a --fix > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
  paths=$(jq -r '.variables.input.fileChanges.additions[]?.path' "$d/commit.json" 2>/dev/null)
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -q 'ENV-PIN-BEHIND' "$d/out" \
     && printf '%s\n' "$paths" | grep -qxF '.github/workflows/ci.yml' \
     && ! printf '%s\n' "$paths" | grep -qF 'env-pin.yml'; then
    pass "main: --fix never moves an env-var pin (the commit carries ci.yml only; env-pin.yml stays ENV-PIN-BEHIND)"
  else
    fail "main: --fix touched or mishandled an env-var pin (rc=$(cat "$d/rc"), paths: $(echo $paths))"
    sed 's/^/    /' "$d/out" >&2; tail -5 "$d/err" | sed 's/^/    /' >&2
  fi
}

# health_fixture <dir> — the Actions runs every repository answers with, and the
# jobs of each failed run. a.yml: startup_failure. b.yml: failed, name == path, 0
# jobs. c.yml: failed, a job named "…lockfile verify" failed. e.yml: failed, no
# lock job. f.yml: the unplannable SHAPE (name == path) but the run DID run jobs.
health_fixture() {
  local d="$1" sha="1111111111111111111111111111111111111111"
  jq -n --arg s "$sha" '{workflow_runs: [
    {id: 2,  status: "completed", conclusion: "startup_failure", name: "A", path: ".github/workflows/a.yml", created_at: "2026-11-12T00:00:00Z", head_sha: $s},
    {id: 5,  status: "completed", conclusion: "failure", name: ".github/workflows/b.yml", path: ".github/workflows/b.yml", created_at: "2026-11-12T00:00:00Z", head_sha: $s},
    {id: 6,  status: "completed", conclusion: "failure", name: "C", path: ".github/workflows/c.yml", created_at: "2026-11-12T00:00:00Z", head_sha: $s},
    {id: 9,  status: "completed", conclusion: "failure", name: "E", path: ".github/workflows/e.yml", created_at: "2026-11-12T00:00:00Z", head_sha: $s},
    {id: 10, status: "completed", conclusion: "failure", name: ".github/workflows/f.yml", path: ".github/workflows/f.yml", created_at: "2026-11-12T00:00:00Z", head_sha: $s}
  ]}' > "$d/runs.json"
  echo '{"total_count": 0, "jobs": []}' > "$d/jobs_5.json"
  echo '{"total_count": 2, "jobs": [{"name": "Governance / lockfile verify", "conclusion": "failure"}, {"name": "build", "conclusion": "success"}]}' > "$d/jobs_6.json"
  echo '{"total_count": 1, "jobs": [{"name": "build", "conclusion": "failure"}]}' > "$d/jobs_9.json"
  echo '{"total_count": 3, "jobs": [{"name": "build", "conclusion": "failure"}, {"name": "test", "conclusion": "success"}, {"name": "lint", "conclusion": "success"}]}' > "$d/jobs_10.json"
}

# case_main_health <applier> — the health block lists startup failures, the
# 0-job failure (only where the jobs endpoint agrees), and a lock-named job
# failure, beside the pin row; a failed run with neither gets no row.
case_main_health() {
  local d; d=$(new_case health)
  health_fixture "$d"
  run_content "$d" "$1" --only hyperpolymath/pub-a
  local ok=1 want
  for want in \
    'HEALTH-STARTUP-FAILURE	1 of the last 1 completed run(s) of this file ended startup_failure; latest run 2 at 2026-11-12T00:00:00Z (11111111)' \
    'HEALTH-ZERO-JOB	1 of the last 1 completed run(s) of this file failed with name == path; latest failed run 5 at 2026-11-12T00:00:00Z (11111111) ran 0 jobs' \
    'HEALTH-LOCK-FAILURE	failed job(s) with "lock" in the name in latest failed run 6 at 2026-11-12T00:00:00Z (11111111): Governance / lockfile verify (matched by job NAME; no log was read)' \
    "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')"; do
    grep -qF "$want" "$d/out" || { ok=0; echo "    missing: $want" >&2; }
  done
  # e.yml failed without a lock job and f.yml has the 0-job SHAPE but ran jobs:
  # neither may be reported.
  if [ "$ok" = 1 ] && [ "$(cat "$d/rc")" = 0 ] \
     && ! grep -qE "$(printf '\t')(e|f)\.yml$(printf '\t')HEALTH-" "$d/out"; then
    pass "main: health block lists startup, 0-job (jobs-confirmed) and lock-named failures; no row for a plain failure or an unconfirmed shape"
  else
    fail "main: health block census wrong (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -12 >&2
  fi
}

# case_main_health_unread <applier> — a runs list that cannot be read is
# HEALTH-UNREAD for every repository, never a clean bill, and the pin row is
# unaffected. A jobs read that fails is HEALTH-UNREAD for that file, not a
# 0-job row.
case_main_health_unread() {
  local d; d=$(new_case healthunread)
  health_fixture "$d"; : > "$d/runs_fail"
  run_content "$d" "$1"
  local n; n=$(grep -cF "$(printf '\t(actions runs)\tHEALTH-UNREAD\t')" "$d/out")
  local ok=0
  [ "$(cat "$d/rc")" = 0 ] && [ "$n" = 3 ] \
    && grep -qF "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')" "$d/out" && ok=1
  rm -f "$d/runs_fail"; : > "$d/jobs_fail_5"
  run_content "$d" "$1" --only hyperpolymath/pub-a
  if [ "$ok" = 1 ] && [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tb.yml\tHEALTH-UNREAD\tthe jobs of latest failed run 5 could not be read; not judged')" "$d/out" \
     && ! grep -q 'HEALTH-ZERO-JOB' "$d/out"; then
    pass "main: unreadable runs / jobs are HEALTH-UNREAD (every repository listed), never healthy and never a guessed 0-job row"
  else
    fail "main: health unread handling wrong (rc=$(cat "$d/rc"), runs-unread rows=$n of 3)"
    sed 's/^/    /' "$d/out" "$d/err" | tail -12 >&2
  fi
}

# case_main_health_paged <applier> — a failed run with more jobs than the first page
# (100) says so: the first page's lock failure is still listed, and a HEALTH-UNREAD
# row names how many of the jobs were read.
case_main_health_paged() {
  local d; d=$(new_case healthpaged)
  health_fixture "$d"
  echo '{"total_count": 150, "jobs": [{"name": "Governance / lockfile verify", "conclusion": "failure"}, {"name": "build", "conclusion": "success"}]}' > "$d/jobs_6.json"
  run_content "$d" "$1" --only hyperpolymath/pub-a
  if [ "$(cat "$d/rc")" = 0 ] \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tc.yml\tHEALTH-UNREAD\tonly 2 of the 150 jobs of latest failed run 6 were read (first page)')" "$d/out" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tc.yml\tHEALTH-LOCK-FAILURE\t')" "$d/out"; then
    pass "main: a run with more jobs than one page is HEALTH-UNREAD (jobs read of total), and the first page's lock failure is still listed"
  else
    fail "main: paged jobs not reported (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -10 >&2
  fi
}

# case_main_health_off <applier> — --no-health reads no run and writes no health row.
case_main_health_off() {
  local d; d=$(new_case healthoff)
  health_fixture "$d"
  run_content "$d" "$1" --only hyperpolymath/pub-a --no-health
  if [ "$(cat "$d/rc")" = 0 ] && ! grep -q 'HEALTH-' "$d/out" && ! grep -q 'actions/runs' "$d/calls.log" \
     && grep -qF "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')" "$d/out"; then
    pass "main: --no-health reads no Actions runs and writes no health row"
  else
    fail "main: --no-health still read runs or wrote rows (rc=$(cat "$d/rc"))"
  fi
}

# case_main_health_cap <applier> — more failed workflow files than HEALTH_JOBS_CAP
# (6) are not all read: the rest are said, not dropped.
case_main_health_cap() {
  local d i; d=$(new_case healthcap)
  jq -n '{workflow_runs: [range(1; 9) as $i | {id: (100 + $i), status: "completed", conclusion: "failure", name: "W\($i)", path: ".github/workflows/w\($i).yml", created_at: "2026-11-12T00:00:00Z", head_sha: "1111111111111111111111111111111111111111"}]}' > "$d/runs.json"
  for i in 1 2 3 4 5 6 7 8; do echo '{"total_count": 1, "jobs": [{"name": "build", "conclusion": "failure"}]}' > "$d/jobs_$((100+i)).json"; done
  run_content "$d" "$1" --only hyperpolymath/pub-a
  local n; n=$(grep -c 'HEALTH-UNREAD.*jobs-read cap (6 per repository)' "$d/out")
  if [ "$(cat "$d/rc")" = 0 ] && [ "$n" = 2 ] && [ "$(grep -c 'actions/runs/10[0-9]/jobs' "$d/calls.log")" = 6 ]; then
    pass "main: the jobs-read cap holds at 6 and the two unread files are listed as HEALTH-UNREAD"
  else
    fail "main: jobs-read cap wrong (rc=$(cat "$d/rc"), unread rows=$n, jobs reads=$(grep -c 'actions/runs/10[0-9]/jobs' "$d/calls.log"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -12 >&2
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

# case_main_only_missing <applier> — `--only` naming a repository that does not
# exist (or is not accessible) is a FATAL error, never a clean run that walked
# nothing; a malformed value is refused too; an existing repository is walked.
case_main_only_missing() {
  local d; d=$(new_case onlymissing)
  : > "$d/missing_nope"
  run_content "$d" "$1" --only hyperpolymath/nope
  local rc1; rc1=$(cat "$d/rc"); local e1="$d/err"
  if [ "$rc1" != 0 ] && grep -q 'not found or not accessible' "$e1" && ! grep -q 'ci.yml' "$d/out"; then
    pass "main: --only naming a nonexistent repository fails loudly (rc=$rc1), no census"
  else
    fail "main: --only on a nonexistent repository did not fail loudly (rc=$rc1)"
    sed 's/^/    /' "$d/out" "$d/err" | tail -6 >&2
  fi
  run_content "$d" "$1" --only not-a-slug
  if [ "$(cat "$d/rc")" != 0 ] && grep -q 'must be owner/name' "$d/err"; then
    pass "main: --only that is not owner/name is refused"
  else
    fail "main: a malformed --only was not refused (rc=$(cat "$d/rc"))"
  fi
  run_content "$d" "$1" --only hyperpolymath/pub-a
  if [ "$(cat "$d/rc")" = 0 ] && grep -qF "$(printf 'hyperpolymath/pub-a\tci.yml\tFRESH')" "$d/out"; then
    pass "main: --only on an existing repository walks exactly that repository"
  else
    fail "main: --only on an existing repository was not walked (rc=$(cat "$d/rc"))"
    sed 's/^/    /' "$d/out" "$d/err" | tail -6 >&2
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
case_main_only_missing "$APPLIER"
case_main_envpin "$APPLIER"
case_main_envpin_fix_untouched "$APPLIER"
case_main_health "$APPLIER"
case_main_health_unread "$APPLIER"
case_main_health_off "$APPLIER"
case_main_health_cap "$APPLIER"
case_main_health_paged "$APPLIER"
case_main_content_fix "$APPLIER"
case_main_content_refresh "$APPLIER"
case_main_content_refresh_envpin "$APPLIER"
case_main_content_refused "$APPLIER" "a template that does not match its own stamp" \
  'printf "      - run: injected\n" >> "$d/proven_template.yml"'
case_main_content_refused "$APPLIER" "a template stamped for another version than the manifest's" \
  'jq ".artifacts[0].version = \"0.3.0\"" "$d/proven_manifest.json" > "$d/m" && mv "$d/m" "$d/proven_manifest.json"'
case_main_content_refused "$APPLIER" "an unreadable template" 'rm "$d/proven_template.yml"'
case_main_content_refused "$APPLIER" "a copy whose local lines name another action" \
  'sed -i "s#actions/checkout@${CO_OLD}#evil/checkout@${CO_OLD}#" "$d/own_stamped"'
case_main_content_refused "$APPLIER" "a uses: change in a repository that carries actions.lock (content mode never relocks)" \
  'printf "version: v0.0.3\ndependencies: {}\n" > "$d/own_lock"' \
  '      - uses: actions/cache@3333333333333333333333333333333333333333 # v4\n'
case_main_content_flags "$APPLIER"
case_main_stamped_held "$APPLIER"
case_main_stamped_held "$APPLIER" l2

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
# LM_CTL caches, per case function, whether an UNMUTATED copy of the applier passes it in
# the mutant environment. A mutant is only meaningful against a case that is green there.
declare -A LM_CTL
# lm_red <output> — did a case report a failure? A line that STARTS with FAIL, not the bare
# substring: a passing label can contain it (one CONTENT-CENSUS-FAILED row), which made
# a green case look red and a no-op mutant look killed.
lm_red() { printf '%s\n' "$1" | grep -Eq '^[[:space:]]*FAIL[[:space:]]'; }
list_mutant() {
  local name="$1" expr="$2" fn="$3"
  local m="$MUT/mutant_${name}.sh" out
  if [ -z "${LM_CTL[$fn]:-}" ]; then
    local ctl="$MUT/control_${fn}.sh" outc
    cp "$APPLIER" "$ctl"
    outc=$("$fn" "$ctl" 2>&1)
    if lm_red "$outc"; then LM_CTL[$fn]=red; else LM_CTL[$fn]=green; fi
  fi
  if [ "${LM_CTL[$fn]}" = red ]; then
    fail "mutant '$name': the UNMUTATED copy is already red under $fn in the mutant environment, so a kill would prove nothing"; return
  fi
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
  if lm_red "$out"; then pass "mutant '$name' killed by $fn"
  else fail "mutant '$name' stayed GREEN under $fn"; fi
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
list_mutant envpin_refresh_value_dropped 's@a\[1\], st, \$3@a[1], st, "-"@' case_main_content_refresh_envpin
list_mutant envpin_refresh_move_silent 's@\[ "\$epb" = "\$epa" \] \|\|@true ||@' case_main_content_refresh_envpin
# A stamped copy in the current layout (stamp on line 2) is still held by --fix:
# a hold that only recognises the legacy line-1 stamp re-pins it and breaks its hash.
case_main_stamped_held_l2() { case_main_stamped_held "$1" l2; }
list_mutant stamped_hold_legacy_only 's@\[ "\$\(stamp_line_of "\$wf"\)" -gt 0 \]@[ "$(stamp_line_of "$wf")" -eq 1 ]@' case_main_stamped_held_l2
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
# An explicit --only repository must be checked for existence: this is what stops a
# typo from becoming a header-only census and a clean exit.
list_mutant only_existence_unchecked 's@if ! gh api "repos/\$\{ONLY_REPO\}"@if false \&\& gh api "repos/${ONLY_REPO}"@' case_main_only_missing
# Env-var pins: rows must be written (even for a pin-free workflow), BEHIND must be
# told from FRESH, commented lines must not count, and --fix must not move them.
list_mutant envpin_row_dropped 's@done < <\(env_pin_rows "\$wf" "\$TARGET_SHA"\)@done < <(true)@' case_main_envpin
list_mutant envpin_behind_as_fresh 's@if \(low == tgt\) row = sprintf\("ENV-PIN-FRESH@if (1) row = sprintf("ENV-PIN-FRESH@' case_main_envpin
# (No mutant for the comment-line guard: the key regex already rejects a line that starts
# with #, so removing the guard changes nothing observable. The commented fixture lines
# stay as a regression check, not a mutation target.)
list_mutant envpin_before_none_skip_lost 's@^      done < <\(env_pin_rows "\$wf" "\$TARGET_SHA"\)$@      done < <(classify_file "$wf" "$TARGET_SHA" | grep -qx NONE || env_pin_rows "$wf" "$TARGET_SHA")@' case_main_envpin
# Health block: each row kind must be written, a 0-job row needs the jobs endpoint's
# agreement, an unreadable answer must be said, the cap must hold, and --no-health
# must read nothing.
list_mutant health_startup_dropped 's@^    if \[ "\$nst" -gt 0 \]; then$@    if false; then@' case_main_health
list_mutant health_zero_unconfirmed 's@if \[ "\$fzs" = 1 \] && \[ "\$jt" = 0 \]; then@if [ "$fzs" = 1 ]; then@' case_main_health
list_mutant health_lock_dropped 's@^    if \[ -n "\$names" \]; then$@    if false; then@' case_main_health
list_mutant health_runs_unread_silent '/Actions runs could not be read/s@>> "\$tsv"@>/dev/null@' case_main_health_unread
list_mutant health_jobs_unread_silent '/the jobs of latest failed run/s@>> "\$tsv"@>/dev/null@' case_main_health_unread
list_mutant health_cap_ignored 's@if \[ "\$njobs" -ge "\$HEALTH_JOBS_CAP" \]; then@if false; then@' case_main_health_cap
list_mutant health_off_ignored 's@\[ "\$HEALTH" -eq 1 \] \|\| return 0@true@' case_main_health_off
list_mutant health_page_unnoticed 's@if \[ "\$jt" -gt "\$jn" \] 2>/dev/null; then@if false; then@' case_main_health_paged
# Codex findings on #1600: same-second runs pick the newest by id, and a run with no
# path is kept under a placeholder. Each is killed by a known-answer control.
kill_mutant health_tie_break_lost 's@sort_by\(\[\.created_at, \.id\]\)@sort_by(.created_at)@' "FAIL health-tie-break"
kill_mutant health_pathless_dropped 's@then "\(unknown workflow\)" else \. end@then "" else . end@' "FAIL health-pathless"
}

echo
if [ "$rc" -ne 0 ]; then echo "RESULT: FAILED" >&2; else echo "RESULT: all checks passed"; fi
exit $rc
