#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Regression test for scripts/check-doctrine-coverage.sh.
#
# The load-bearing properties, in order:
#   * a document that has not opted in is not touched at all (no red board on
#     adoption — the gate must be installable in a repository that has never
#     tagged anything);
#   * an invariant with no tag fails, because silence is the defect;
#   * an `Enforced-by:` claim must point at something that exists, is not a
#     document, and actually names the invariant or its document — otherwise the
#     claim is decoration;
#   * a `Review-only:` tag must carry a reason, not a shrug;
#   * a stray tag is a failure, because it usually means an invariant was
#     renamed and the tag was left pointing at prose.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/scripts/check-doctrine-coverage.sh"

[ -f "$SCRIPT" ] || { echo "FATAL: cannot locate $SCRIPT" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/docs" "$WORK/scripts"
printf '#!/usr/bin/env bash\n# enforces docs/RULES.adoc on purpose\nexit 0\n' > "$WORK/scripts/gate.sh"
printf '#!/usr/bin/env bash\n# implements the ledger rule\nexit 0\n' > "$WORK/scripts/other.sh"

# run <dir> [args...]
run() { local d="$1"; shift; ( cd "$d" && bash "$SCRIPT" "$@" 2>&1 ); }

# case <name> <expected-rc> <expected-substring> <doc-body>
case_() {
  local name="$1" want_rc="$2" want="$3" body="$4" summary="${5:-}"
  rm -rf "$WORK/docs"; mkdir -p "$WORK/docs"
  printf '%s\n' "$body" > "$WORK/docs/RULES.adoc"
  local out rc
  out="$(run "$WORK" --path docs)"; rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF "$want" \
    && { [ -z "$summary" ] || printf '%s' "$out" | grep -qF "$summary"; }; then
    ok "$name"
  else
    bad "$name (rc=$rc, wanted $want_rc / '$want')"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# 1. no opt-in: a document full of untagged invariants is not the gate's business
rm -rf "$WORK/docs"; mkdir -p "$WORK/docs"
cat > "$WORK/docs/RULES.adoc" <<'EOF'
= Rules

== Never do the bad thing

Text with no tag at all.
EOF
out="$(run "$WORK" --path docs)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '0 document(s) opted in'; then
  ok "a document without the opt-in marker is not scanned"
else
  bad "un-opted document should be ignored (rc=$rc)"; printf '%s\n' "$out"
fi

# 2. opt-in, untagged invariant
case_ "an opted-in untagged invariant fails" 1 "UNTAGGED invariant" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

Text with no tag at all.'

# 3. enforced-by that names the document
case_ "Enforced-by naming the document passes" 0 "every opted-in invariant states its enforcement status" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Enforced-by: scripts/gate.sh

Text.'

# 4. dangling path
case_ "Enforced-by with a missing path fails" 1 "DANGLING claim" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Enforced-by: scripts/does-not-exist.sh

Text.'

# 5. enforcing document is itself a document
# Pointed at the scanned document itself: it exists, so the doc-as-enforcer
# check is what must fire (a missing path is a different failure, tested above).
case_ "a document cannot enforce anything" 1 "CLAIM IS A DOCUMENT" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Enforced-by: docs/RULES.adoc

Text.'

# 6. a real script that has nothing to do with this invariant
case_ "an unrelated script is an unlinked claim" 1 "UNLINKED claim" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Enforced-by: scripts/other.sh

Text.'

# 7. both tags
case_ "carrying both tags is ambiguous" 1 "AMBIGUOUS invariant" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Enforced-by: scripts/gate.sh
// Review-only: also no gate can check this at all in any useful sense

Text.'

# Repeated tags of either kind are ambiguous, even when their values agree.
case_ "repeated Enforced-by tags fail" 1 "AMBIGUOUS invariant" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Enforced-by: scripts/gate.sh
// Enforced-by: scripts/gate.sh' "1 invariant(s): 0 enforced, 0 review-only"

case_ "repeated Review-only tags fail" 1 "AMBIGUOUS invariant" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Review-only: no mechanical oracle exists for this one; it needs human judgement
// Review-only: no mechanical oracle exists for this one; it needs human judgement' "1 invariant(s): 0 enforced, 0 review-only"

printf '# never-do-the-bad-thing\n' > "$WORK/scripts/slug-gate.sh"
case_ "a link by invariant slug passes without the document basename" 0 "1 enforced" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Enforced-by: scripts/slug-gate.sh'

case_ "trailing spaces and CRLF on an Enforced-by tag pass" 0 "1 enforced" \
$'= Rules\r\n// doctrine-coverage: on\r\n\r\n== Never do the bad thing\r\n\r\n// Enforced-by: scripts/gate.sh \t\r'

case_ "trailing spaces and CRLF on a Review-only tag pass" 0 "1 review-only" \
$'= Rules\r\n// doctrine-coverage: on\r\n\r\n== Never do the bad thing\r\n\r\n// Review-only: no mechanical oracle exists for this; it needs human judgement \t\r'

case_ "trailing whitespace does not make a thin reason valid" 1 "THIN reason" \
$'= Rules\n// doctrine-coverage: on\n\n== Never do the bad thing\n\n// Review-only: too short                               \r' "1 invariant(s): 0 enforced, 0 review-only"

# Invalid claims must not appear in covered summary counts.
case_ "invalid claims are excluded from covered totals" 1 "4 problem(s)" \
'= Rules
// doctrine-coverage: on

== Never do the first thing
// Enforced-by: scripts/missing.sh

== Never do the second thing
// Enforced-by: scripts/other.sh

== Never do the third thing
// Review-only: too short

== Never do the fourth thing
// Review-only: TODO replace this placeholder with a proper human review reason' "4 invariant(s): 0 enforced, 0 review-only"

# 8. thin reason
case_ "a two-word Review-only reason is a shrug" 1 "THIN reason" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Review-only: no gate

Text.'

# 9. placeholder reason
case_ "a TODO Review-only reason fails" 1 "PLACEHOLDER reason" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Review-only: TODO write a real reason for this one when there is time

Text.'

# 10. proper review-only
case_ "a reasoned Review-only tag passes" 0 "1 review-only" \
'= Rules
// doctrine-coverage: on

== Never do the bad thing

// Review-only: no mechanical oracle exists for this one; it is a per-repository judgement

Text.'

# 11. stray tag on a non-normative heading
case_ "a tag on a heading with no invariant fails" 1 "stray tag" \
'= Rules
// doctrine-coverage: on

== Background material

// Enforced-by: scripts/gate.sh

Text.'

# 12. a parent section with a tagged child is not a stray
case_ "a tagged child does not make its parent a stray" 0 "1 enforced" \
'= Rules
// doctrine-coverage: on

== Method notes

Text.

=== Never do the bad thing

// Enforced-by: scripts/gate.sh

Text.'

# 13. --report never fails
rm -rf "$WORK/docs"; mkdir -p "$WORK/docs"
printf '= Rules\n// doctrine-coverage: on\n\n== Never do the bad thing\n\nText.\n' > "$WORK/docs/RULES.adoc"
out="$(run "$WORK" --path docs --report)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'report-only'; then
  ok "--report reports without failing"
else
  bad "--report should exit 0 with a note (rc=$rc)"; printf '%s\n' "$out"
fi

# --list and --path=VALUE work together with a single file.
printf '= Rules\n// doctrine-coverage: on\n\n== Never do the bad thing\n// Enforced-by: scripts/gate.sh\n' > "$WORK/docs/RULES.adoc"
out="$(run "$WORK" --list --path=docs/RULES.adoc)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF $'docs/RULES.adoc:4\tnever-do-the-bad-thing\tenforced-by=scripts/gate.sh'; then
  ok "--list with --path=VALUE lists the selected invariant"
else
  bad "--list and --path=VALUE should select and list the file (rc=$rc)"; printf '%s\n' "$out"
fi

# 14. unknown flag
out="$(run "$WORK" --nonsense)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown flag exits 2"; else bad "unknown flag should exit 2 (rc=$rc)"; fi

# 15. missing path
out="$(run "$WORK" --path no-such-directory)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "a missing --path exits 2"; else bad "missing path should exit 2 (rc=$rc)"; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
