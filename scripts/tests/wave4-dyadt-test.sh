#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -uo pipefail
#
# Wave-4 DYADT regression test.
#
# The whole point of DYADT is that it can REFUTE a false claim and does not
# confirm on the agent's say-so. This exercises confirm / refute / unverifiable
# and the incompatible-verifier + manual-only guards, plus the conformance suite.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
V="$ROOT/scripts/verify-claims.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }

# verdict_of <claims-file> <claim-id>  -> prints confirmed|refuted|unverifiable
verdict_of() {
  cd "$ROOT" && DYADT_ALLOW_UNVERIFIABLE=1 bash "$V" "$1" 2>/dev/null \
    | grep -oE "$2  (confirmed|REFUTED|unverifiable)" | awk '{print tolower($2)}' | head -1
}

echo "== confirm / refute (does not trust the statement) =="
cat > "$TMP/t.a2ml" <<'EOF'
[claims]
schema = "dyadt/claim@1"
actor = "test"
[[claim]]
id = "C1"
claim_class = "command-ran"
statement = "this command succeeds"
target = "true"
expect = "exit==0"
verifier = "command-transcript"
[[claim]]
id = "C2"
claim_class = "command-ran"
statement = "LIE: this command succeeds (it does not)"
target = "false"
expect = "exit==0"
verifier = "command-transcript"
EOF
[ "$(verdict_of "$TMP/t.a2ml" C1)" = confirmed ] && ok "true command confirmed" || bad "true command not confirmed"
[ "$(verdict_of "$TMP/t.a2ml" C2)" = refuted ]   && ok "false command REFUTED despite honest-sounding statement" || bad "false command not refuted"

echo "== guards =="
# incompatible verifier -> unverifiable
cat > "$TMP/i.a2ml" <<'EOF'
[claims]
schema = "dyadt/claim@1"
actor = "test"
[[claim]]
id = "C1"
claim_class = "pr-merged"
statement = "PR merged"
target = "o/r#1"
expect = "merged==true"
verifier = "command-transcript"
EOF
[ "$(verdict_of "$TMP/i.a2ml" C1)" = unverifiable ] && ok "incompatible verifier -> unverifiable" || bad "incompatible verifier not caught"

# licence claim -> unverifiable (manual-only)
cat > "$TMP/l.a2ml" <<'EOF'
[claims]
schema = "dyadt/claim@1"
actor = "test"
[[claim]]
id = "C1"
claim_class = "file-changed"
statement = "SPDX licence header added"
target = "x.rs"
expect = "contains:SPDX-License-Identifier"
verifier = "git-diff"
EOF
[ "$(verdict_of "$TMP/l.a2ml" C1)" = unverifiable ] && ok "licence claim -> manual-only unverifiable" || bad "licence claim not manual-only"

echo "== loud exit semantics =="
# a refuted claim makes the process exit non-zero (fail loudly)
cat > "$TMP/r.a2ml" <<'EOF'
[claims]
schema = "dyadt/claim@1"
actor = "test"
[[claim]]
id = "C1"
claim_class = "command-ran"
statement = "false succeeds"
target = "false"
expect = "exit==0"
verifier = "command-transcript"
EOF
( cd "$ROOT" && bash "$V" "$TMP/r.a2ml" >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "refuted claim fails loudly (non-zero exit)" || bad "refuted claim did not fail the run"

# an all-confirmed file exits 0
cat > "$TMP/g.a2ml" <<'EOF'
[claims]
schema = "dyadt/claim@1"
actor = "test"
[[claim]]
id = "C1"
claim_class = "command-ran"
statement = "true succeeds"
target = "true"
expect = "exit==0"
verifier = "command-transcript"
EOF
( cd "$ROOT" && bash "$V" "$TMP/g.a2ml" >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "all-confirmed file exits 0" || bad "all-confirmed file did not exit 0"

echo "== hardening (adversarial-review fixes) =="
mk() { printf '%s\n' "$2" > "$TMP/$1"; }
reason_of() { # file id
  cd "$ROOT" && DYADT_ALLOW_UNVERIFIABLE=1 bash "$V" "$1" 2>/dev/null \
    | grep -E "$2|<block" | grep -oE '(confirmed|REFUTED|unverifiable) *\[[^]]*\] *[a-z-]+' | head -1
}
# missing required field -> unverifiable, still counted
mk mf.a2ml '[claims]
[[claim]]
id = "C1"
claim_class = "command-ran"
expect = "exit==0"
verifier = "command-transcript"'
[[ "$(reason_of "$TMP/mf.a2ml" C1)" == unverifiable*missing-field ]] && ok "missing field -> unverifiable" || bad "missing field not caught"
# claim with no id is NOT silently dropped (appears as a block, unverifiable)
mk noid.a2ml '[claims]
[[claim]]
claim_class = "command-ran"
target = "true"
expect = "exit==0"
verifier = "command-transcript"'
( vout=$(cd "$ROOT" && DYADT_ALLOW_UNVERIFIABLE=1 bash "$V" "$TMP/noid.a2ml" 2>/dev/null) && grep -q 'no-id' <<<"$vout" ) && ok "missing id not silently dropped" || bad "missing id was dropped"
# empty pattern -> unverifiable (not an always-match confirm)
mk ep.a2ml '[claims]
[[claim]]
id = "C1"
claim_class = "file-changed"
target = "README.adoc"
expect = "contains:"
verifier = "git-diff"'
[[ "$(reason_of "$TMP/ep.a2ml" C1)" == unverifiable*empty-pattern ]] && ok "empty contains pattern -> unverifiable" || bad "empty pattern not caught"
# path traversal -> unverifiable
mk up.a2ml '[claims]
[[claim]]
id = "C1"
claim_class = "file-changed"
target = "../etc/passwd"
expect = "created"
verifier = "git-diff"'
[[ "$(reason_of "$TMP/up.a2ml" C1)" == unverifiable*unsafe-path ]] && ok "path traversal -> unverifiable" || bad "unsafe path not caught"
# unresolvable base -> unverifiable (not confident-wrong created)
mk nb.a2ml '[claims]
[[claim]]
id = "C1"
claim_class = "file-changed"
target = "README.adoc"
expect = "created"
verifier = "git-diff"'
r="$(cd "$ROOT" && DYADT_BASE=definitely-not-a-ref DYADT_ALLOW_UNVERIFIABLE=1 bash "$V" "$TMP/nb.a2ml" 2>/dev/null | grep -oE 'unverifiable *\[[^]]*\] *[a-z-]+' | head -1)"
[[ "$r" == unverifiable*no-base-ref ]] && ok "unresolvable base -> unverifiable" || bad "unresolvable base not caught (got: $r)"
# stderr marker must NOT confirm a stdout-contains claim
mk se.a2ml '[claims]
[[claim]]
id = "C1"
claim_class = "command-ran"
target = "echo marker >&2; true"
expect = "stdout-contains:marker"
verifier = "command-transcript"'
[[ "$(reason_of "$TMP/se.a2ml" C1)" == REFUTED* ]] && ok "stderr does not satisfy stdout-contains" || bad "stderr false-confirmed stdout claim"
# an always-matching contains: regex is not evidence (#461)
mk am.a2ml '[claims]
[[claim]]
id = "C1"
claim_class = "file-changed"
target = "README.adoc"
expect = "contains:.*"
verifier = "git-diff"'
[[ "$(reason_of "$TMP/am.a2ml" C1)" == unverifiable*trivial-pattern ]] && ok "always-matching contains: -> unverifiable" || bad "always-match pattern confirmed vacuously"

# licence claim phrased only in the statement is still manual-only
mk lic.a2ml '[claims]
[[claim]]
id = "C1"
claim_class = "command-ran"
statement = "added the SPDX licence header"
target = "true"
expect = "exit==0"
verifier = "command-transcript"'
[[ "$(reason_of "$TMP/lic.a2ml" C1)" == unverifiable*manual-only ]] && ok "licence-in-statement -> manual-only" || bad "licence-in-statement auto-confirmed"

echo "== conformance suite =="
bash "$ROOT/1-formats/sub-specs/did-you-actually-do-that/spec/conformance/run-conformance.sh" >/dev/null 2>&1 && ok "conformance vectors pass" || bad "conformance vectors failed"

echo
echo "Wave-4 DYADT regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
