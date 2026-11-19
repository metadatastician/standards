#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Offline tests for scripts/fix-required-context-name.sh.
#
# The script edits branch protection, so the branches that matter are the
# refusals: every one of them exists to stop a well-meaning run from dropping
# nineteen required checks while appearing to fix one. A fake `gh` on PATH
# (via $GH) serves fixtures and records whether a write was attempted, so no
# test touches a real ruleset.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../fix-required-context-name.sh"
pass=0; fail=0

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

ctx() { jq -c '.' ; }

# A faithful slice of ruleset 23787415: one checks rule, 20 contexts, five rules.
base() {
  jq -n --arg old "$1" --arg new "$2" --argjson both "$3" '$ctxs |
    [$ctxs[] | {context: ., integration_id: 15368}] as $list' 2>/dev/null
}

mk_ruleset() { # $1=old context present (1/0)  $2=new context present (1/0)
  # Pure jq: inline Python is banned in this repository
  # (scripts/tests/check-inline-python-test.sh), and a fixture generator is not
  # a good enough reason to open the door.
  jq -n --argjson o "$1" --argjson n "$2" '
    (["CodeQL", "SPARK Theatre Gate"]
     + [range(0;17) | "governance / filler \(.)"]
     + (if $o == 1 then ["scan / Hypatia Neurosymbolic Analysis"] else [] end)
     + (if $n == 1 then ["Hypatia verdict grid / Hypatia Neurosymbolic Analysis"] else [] end)) as $ctx
    | {name: "main gate: append-only + required checks + signatures + scanning",
       target: "branch", enforcement: "active",
       bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}],
       conditions: {ref_name: {exclude: [], include: ["~DEFAULT_BRANCH"]}},
       rules: [
         {type: "deletion"},
         {type: "non_fast_forward"},
         {type: "required_status_checks", parameters: {
           strict_required_status_checks_policy: false,
           do_not_enforce_on_create: false,
           required_status_checks: [$ctx[] | {context: ., integration_id: 15368}]}},
         {type: "pull_request", parameters: {required_approving_review_count: 0}},
         {type: "required_signatures"}
       ]}'
}

# Fake `gh`: `api repos/R/rulesets/N` serves $FIXTURE, unless a write has
# happened, in which case it serves $WRITTEN. `api -X PUT ... --input FILE`
# records the payload and flips the switch. $REFUSE=1 makes the write 403.
install_gh() {
  cat >"$work/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
method=GET
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --input) payload="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ "$method" = PUT ]; then
  cp "${payload:?}" "$PUT_CAPTURE"
  if [ "${REFUSE:-0}" = 1 ]; then
    echo '{"message":"Resource not accessible by integration","status":"403"}' >&2
    exit 1
  fi
  cp "$PUT_CAPTURE" "$WRITTEN"
fi
if [ -s "${WRITTEN:-/dev/null}" ]; then cat "$WRITTEN"; else cat "$FIXTURE"; fi
SH
  chmod +x "$work/gh"
}

# Sets $out and $rc in the CALLER. Deliberately not `out="$(run ...)"`: a
# command substitution runs in a subshell, so the exit status captured inside
# would never reach the assertion.
out=""; rc=0
run() { # fixture-file [arg]
  : >"$work/written"
  FIXTURE="$1" WRITTEN="$work/written" PUT_CAPTURE="$work/payload.json" \
    REFUSE="${REFUSE:-0}" GH="$work/gh" PATH="$work/bin:$PATH" \
    COUNT_TARGET="${COUNT_TARGET:-}" COUNT_VALUE="${COUNT_VALUE:-}" \
    bash "$script" "${2:-}" >"$work/out" 2>&1
  rc=$?
  out="$(cat "$work/out")"
}

check() { local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "PASS $label"
  else fail=$((fail+1)); echo "FAIL $label — want exit $want, got $got"; fi; }

check_says() { local label="$1" want="$2" out="$3"
  if grep -qF "$want" <<<"$out"; then pass=$((pass+1)); echo "PASS $label"
  else fail=$((fail+1)); echo "FAIL $label — output lacks: $want"; printf '%s\n' "$out" | tail -3; fi; }

install_gh

# 1. report-only shows the single-line diff and writes nothing
mk_ruleset 1 0 >"$work/old-only.json"
run "$work/old-only.json"; check "report-only exits 0" 0 "$rc"
check_says "report-only names the target context" "Hypatia verdict grid / Hypatia Neurosymbolic Analysis" "$out"
check_says "report-only says it did not write" "REPORT-ONLY" "$out"
if [ -s "$work/written" ]; then fail=$((fail+1)); echo "FAIL report-only wrote to the ruleset"
else pass=$((pass+1)); echo "PASS report-only wrote nothing"; fi

# 2. --apply writes, and the read-back is what is verified
run "$work/old-only.json" --apply; check "apply exits 0" 0 "$rc"
check_says "apply confirms the new context" "is now required" "$out"
n_written=$(jq -r '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[]?]|length' "$work/written" 2>/dev/null)
check "apply preserves the context count (20)" 20 "$n_written"
n_old=$(jq -r '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[]?|select(.context=="scan / Hypatia Neurosymbolic Analysis")]|length' "$work/written" 2>/dev/null)
check "apply removed the dead context" 0 "$n_old"
n_rules=$(jq -r '.rules|length' "$work/written" 2>/dev/null)
check "apply preserves the rule count (5)" 5 "$n_rules"
n_bypass=$(jq -r '.bypass_actors|length' "$work/written" 2>/dev/null)
check "apply preserves the bypass actors" 1 "$n_bypass"

# 3. already repaired: no-op success, and no write
mk_ruleset 0 1 >"$work/new-only.json"
run "$work/new-only.json" --apply; check "already-repaired exits 0" 0 "$rc"
check_says "already-repaired says so" "already repaired" "$out"
if [ -s "$work/written" ]; then fail=$((fail+1)); echo "FAIL already-repaired still wrote"
else pass=$((pass+1)); echo "PASS already-repaired wrote nothing"; fi

# 4. neither name present: refuse rather than invent a change
mk_ruleset 0 0 >"$work/neither.json"
run "$work/neither.json" --apply; check "neither-present exits 1" 1 "$rc"
check_says "neither-present refuses to invent" "refusing to invent" "$out"

# 5. both present: refuse, this needs a human
mk_ruleset 1 1 >"$work/both.json"
run "$work/both.json" --apply; check "both-present exits 1" 1 "$rc"
check_says "both-present asks for a manual decision" "Remove" "$out"

# 6. inactive ruleset: editing it would change nothing while looking like it did
mk_ruleset 1 0 | jq '.enforcement="evaluate"' >"$work/inactive.json"
run "$work/inactive.json" --apply; check "inactive exits 1" 1 "$rc"
check_says "inactive is refused" "not 'active'" "$out"

# 7. the API refuses the write (installation token): say what it means
REFUSE=1; run "$work/old-only.json" --apply; check "403 exits 1" 1 "$rc"
REFUSE=0
check_says "403 explains the installation-token trap" "installation token" "$out"

# Each query result must be validated independently. Simulate a jq query that
# produces no count or a non-numeric count while the other queries still work.
mkdir -p "$work/bin"
real_jq="$(command -v jq)"
cat >"$work/bin/jq" <<'SH'
#!/usr/bin/env bash
query="$*"
field=""
case "$query" in
  *verify.json*)
    case "$query" in
      *'Hypatia verdict grid / Hypatia Neurosymbolic Analysis'*) field=v_new ;;
      *'scan / Hypatia Neurosymbolic Analysis'*) field=v_old ;;
      *'required_status_checks[]?] | length'*) field=v_cnt ;;
    esac ;;
  *before.json*)
    case "$query" in *'required_status_checks[]?] | length'*) field=n_ctx ;; esac ;;
esac
if [ -n "$field" ] && [ "$field" = "$COUNT_TARGET" ]; then
  printf '%s' "$COUNT_VALUE"; exit 1
fi
exec "$REAL_JQ" "$@"
SH
chmod +x "$work/bin/jq"
export REAL_JQ="$real_jq"
for field in v_new v_old v_cnt n_ctx; do
  for value in '' invalid; do
    COUNT_TARGET="$field" COUNT_VALUE="$value" run "$work/old-only.json" --apply
    check "$field value '$value' exits 1" 1 "$rc"
    if [ "$field" = n_ctx ]; then
      check_says "invalid original count refused before write" "Refusing to send" "$out"
    else
      check_says "$field value '$value' is unverified" "UNVERIFIED" "$out"
    fi
  done
done

# 8. unknown argument is not silently ignored
run "$work/old-only.json" --force; check "unknown arg exits 2" 2 "$rc"

echo
echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
