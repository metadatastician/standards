#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves scripts/check-uuid-v8-domains.sh passes the real ADR-008 profile C
# domain register and fails each planted defect for its own reason, so the
# gate can fail and says why.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/check-uuid-v8-domains.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); echo "  ok    $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; }

# expect <label> <exit> <message-fragment|-> <args...>
expect() {
  local label=$1 want_rc=$2 want_msg=$3; shift 3
  local out rc=0
  out=$(bash "$CHECK" "$@" 2>&1) || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then bad "$label (exit $rc, want $want_rc): $out"; return; fi
  if [ "$want_msg" != - ] && ! grep -qF -- "$want_msg" <<<"$out"; then
    bad "$label (no \"$want_msg\" in: $out)"; return
  fi
  ok "$label"
}

# plant <name> <jq filter over the real register> — writes it as JCS + LF.
plant() { jq -cS "$2" "$ROOT/docs/decisions/ADR-008-profile-c-domains.json" > "$WORK/$1.json"; }

echo "the real register"
expect "is valid" 0 "domain(s) valid"
expect "registers the domains its repos mint" 0 "registered" proof-goal prove-result echidnabot-proof-obligation gv-clade-index chora-registry
expect "an unregistered domain fails" 1 'domain "no-such-domain" is not registered' proof-goal no-such-domain

echo "planted defects, each named"
plant dup '.domains += [.domains[0]] | .domains |= sort_by(.domain)'
expect "a domain registered twice" 1 "strictly increasing" --registry "$WORK/dup.json"
plant unsorted '.domains |= reverse'
expect "domains out of order" 1 "strictly increasing" --registry "$WORK/unsorted.json"
plant colon '.domains[0].domain = "a:b"'
expect "a domain with \":\"" 1 "invalid domain" --registry "$WORK/colon.json"
plant space '.domains[0].domain = "a b"'
expect "a domain with a space" 1 "invalid domain" --registry "$WORK/space.json"
plant empty '.domains[0].domain = ""'
expect "an empty domain" 1 "invalid domain" --registry "$WORK/empty.json"
plant nopurpose '.domains[0] |= del(.purpose)'
expect "an entry without purpose" 1 "keys must be exactly" --registry "$WORK/nopurpose.json"
plant extra '.domains[0].owner = "x"'
expect "an entry with an extra key" 1 "keys must be exactly" --registry "$WORK/extra.json"
plant blankname '.domains[0].name = ""'
expect "an empty name" 1 "name must be a non-empty string" --registry "$WORK/blankname.json"
plant norepos '.domains[0].repos = []'
expect "no repos" 1 "repos must be a non-empty array" --registry "$WORK/norepos.json"
plant reporev '.domains[] |= (if (.repos | length) > 1 then .repos |= reverse else . end)'
expect "repos out of order" 1 "repos must be sorted and unique" --registry "$WORK/reporev.json"
plant badrepo '.domains[0].repos = ["not a repo"]'
expect "a repo that is not owner/repo" 1 "repos must be a non-empty array" --registry "$WORK/badrepo.json"
plant schema '.schema = "estate-uuid-v8-domains/2"'
expect "an unknown schema" 1 "schema must be" --registry "$WORK/schema.json"
plant toplevel '.note = "x"'
expect "an extra top-level key" 1 "top-level keys" --registry "$WORK/toplevel.json"

echo "planted byte-shape defects"
jq -S . "$ROOT/docs/decisions/ADR-008-profile-c-domains.json" > "$WORK/pretty.json"
expect "pretty-printed, not JCS" 1 "not in JCS form" --registry "$WORK/pretty.json"
jq -c . "$ROOT/docs/decisions/ADR-008-profile-c-domains.json" | sed 's/{"domains":\(.*\),"schema":\(.*\)}$/{"schema":\2,"domains":\1}/' > "$WORK/order.json"
expect "keys out of JCS order" 1 "not in JCS form" --registry "$WORK/order.json"
printf '%s' "$(cat "$ROOT/docs/decisions/ADR-008-profile-c-domains.json")" > "$WORK/nolf.json"
expect "no final LF" 1 "exactly one line" --registry "$WORK/nolf.json"
{ cat "$ROOT/docs/decisions/ADR-008-profile-c-domains.json"; echo; } > "$WORK/twolf.json"
expect "two final LFs" 1 "exactly one line" --registry "$WORK/twolf.json"
plant nonascii '.domains[0].purpose = "café"'
expect "non-ASCII text" 1 "printable ASCII" --registry "$WORK/nonascii.json"

echo "the check refuses to judge what it cannot read"
expect "a missing register" 2 "no register" --registry "$WORK/absent.json"
echo '{"domains": [' > "$WORK/broken.json"
expect "an unparseable register" 2 "does not parse" --registry "$WORK/broken.json"

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
