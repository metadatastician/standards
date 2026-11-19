#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# retire-phantom-contexts-test.sh -- scripts/retire-phantom-contexts.sh must
# remove ONLY the phantom context, never another rule or field, and refuse
# every case where it cannot see or own what it would overwrite.
#
#   phantom-only  CI/gate is the only context    -> rule dropped, rest identical
#   mixed         CI/gate + scan / gitleaks      -> only CI/gate removed
#   clean         scan / gitleaks only           -> CLEAN, no write
#   org           phantom in an org ruleset      -> ORG-INHERITED, no write
#   nosource      list entry without source_type -> REFUSED, no write
#   disabled      phantom in a disabled ruleset  -> DISABLED-SKIPPED, no write
#   nobypass      GET omits bypass_actors        -> REFUSED, no write
# Negative control: report mode writes nothing.
#
# No network: `gh` is a stub on PATH that answers from fixtures.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$here/scripts/retire-phantom-contexts.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

fx="$tmp/fx"; mkdir -p "$fx" "$tmp/puts" "$tmp/bin"
base='"target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[]'
rsc() { printf '{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"do_not_enforce_on_create":false,"required_status_checks":[%s]}}' "$1"; }
other='{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request","parameters":{"required_review_thread_resolution":true,"required_approving_review_count":0}},{"type":"code_coverage","parameters":{"minimum_coverage":80,"max_coverage_drop":5}}'

echo "{\"id\":1,\"name\":\"Branch-Floor\",\"enforcement\":\"active\",$base,\"rules\":[$other,$(rsc '{"context":"CI/gate"}')]}" > "$fx/phantom-only.1"
echo "{\"id\":2,\"name\":\"Branch-Floor\",\"enforcement\":\"active\",$base,\"rules\":[$other,$(rsc '{"context":"CI/gate"},{"context":"scan / gitleaks","integration_id":15368}')]}" > "$fx/mixed.2"
echo "{\"id\":3,\"name\":\"Secret-Scan-Floor\",\"enforcement\":\"active\",$base,\"rules\":[$(rsc '{"context":"scan / gitleaks","integration_id":15368}')]}" > "$fx/clean.3"
echo "{\"id\":4,\"name\":\"EstateBranching\",\"enforcement\":\"active\",$base,\"rules\":[$(rsc '{"context":"CI/gate"}')]}" > "$fx/org.4"
echo "{\"id\":5,\"name\":\"Branch-Floor\",\"enforcement\":\"active\",$base,\"rules\":[$(rsc '{"context":"CI/gate"}')]}" > "$fx/nosource.5"
echo "{\"id\":6,\"name\":\"Branch-Floor\",\"enforcement\":\"disabled\",$base,\"rules\":[$(rsc '{"context":"CI/gate"}')]}" > "$fx/disabled.6"
echo "{\"id\":7,\"name\":\"Branch-Floor\",\"enforcement\":\"active\",\"target\":\"branch\",\"conditions\":{},\"rules\":[$(rsc '{"context":"CI/gate"}')]}" > "$fx/nobypass.7"
# Second-round fixtures (review of #1640): a phantom and a retired rule in DIFFERENT
# rulesets; a phantom on page 2 of the listing; a ruleset edited between read and
# write; a backup that cannot be written.
echo "{\"id\":8,\"name\":\"Branch-Floor\",\"enforcement\":\"active\",$base,\"rules\":[$(rsc '{"context":"CI/gate"}')]}" > "$fx/split.8"
echo "{\"id\":9,\"name\":\"Optimus-Extras\",\"enforcement\":\"active\",$base,\"rules\":[{\"type\":\"code_coverage\",\"parameters\":{\"minimum_coverage\":80}}]}" > "$fx/split.9"
echo "{\"id\":10,\"name\":\"Secret-Scan-Floor\",\"enforcement\":\"active\",$base,\"rules\":[$(rsc '{"context":"scan / gitleaks"}')]}" > "$fx/paged.10"
echo "{\"id\":11,\"name\":\"Branch-Floor\",\"enforcement\":\"active\",$base,\"rules\":[$(rsc '{"context":"CI/gate"}')]}" > "$fx/paged.11"
echo "{\"id\":12,\"name\":\"Branch-Floor\",\"enforcement\":\"active\",$base,\"rules\":[{\"type\":\"deletion\"},$(rsc '{"context":"CI/gate"}')]}" > "$fx/racy.12"
echo "{\"id\":13,\"name\":\"Branch-Floor\",\"enforcement\":\"active\",$base,\"rules\":[$(rsc '{"context":"CI/gate"}')]}" > "$fx/badbackup.13"

cat > "$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
fx="$fx"; puts="$tmp/puts"; calls="$tmp/calls"
if [ "\$1 \$2" = "repo list" ]; then      # owner enumeration
  case "\$3" in
    fail) echo "o/phantom-only"; echo "HTTP 502" >&2; exit 1 ;;   # partial output, then failure
    *)    printf 'o/phantom-only\no/mixed\n' ;;
  esac; exit 0
fi
if [ "\$1 \$2" = "api -X" ]; then        # api -X PUT path --input file
  path=\$4; r=\${path#repos/o/}; r=\${r%%/*}; id=\${path##*/}
  cp "\$6" "\$puts/\$r.\$id"; jq ". + {id: \$id}" "\$6"; exit 0
fi
path=\${2%%\?*}
r=\${path#repos/o/}; r=\${r%%/*}
case "\$path" in
  repos/o/*/rulesets)
    case "\$r" in
      org)      echo '[{"id":4,"source_type":"Organization"}]' ;;
      nosource) echo '[{"id":5}]' ;;
      split)    echo '[{"id":8,"source_type":"Repository"},{"id":9,"source_type":"Repository"}]' ;;
      paged)    # Two pages, as gh --paginate prints them: the phantom is only on page 2.
                echo '[{"id":10,"source_type":"Repository"}]'
                [ "\$3" = "--paginate" ] && echo '[{"id":11,"source_type":"Repository"}]' ;;
      *)        id=\$(ls "\$fx" | awk -F. -v r="\$r" '\$1==r{print \$2}'); echo "[{\"id\":\$id,\"source_type\":\"Repository\"}]" ;;
    esac ;;
  repos/o/*/rulesets/*)
    id=\${path##*/}
    n=\$(( \$(cat "\$calls.\$r.\$id" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$calls.\$r.\$id"
    if [ -f "\$puts/\$r.\$id" ]; then jq ". + {id: \$id}" "\$puts/\$r.\$id"
    elif [ "\$r" = racy ] && [ "\$n" -ge 2 ]; then
      # Someone added non_fast_forward between the planning read and the write.
      jq '.rules += [{"type":"non_fast_forward"}]' "\$fx/\$r.\$id"
    else cat "\$fx/\$r.\$id"; fi ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"

args=(); for r in phantom-only mixed clean org nosource disabled nobypass; do args+=(--repo "o/$r"); done
row() { printf '%s\n' "$1" | awk -F'\t' -v r="o/$2" '$1==r{print $2}'; }

# --- report mode (negative control: no writes) ---
set +e; out=$(PATH="$tmp/bin:$PATH" bash "$script" "${args[@]}" 2>/dev/null); rc=$?; set -e
[ -z "$(ls "$tmp/puts")" ] && pass "report mode writes nothing" || bad "report mode wrote: $(ls "$tmp/puts")"
[ "$(row "$out" phantom-only)" = WOULD-RETIRE ] && pass "phantom-only reported WOULD-RETIRE" || bad "phantom-only: $(row "$out" phantom-only)"
grep -q 'also in this repo: code_coverage' <<<"$out" && pass "retired code_coverage is surfaced as a second blocker" || bad "code_coverage not surfaced"
[ "$(row "$out" clean)" = CLEAN ] && pass "a real context alone is CLEAN" || bad "clean: $(row "$out" clean)"
[ "$(row "$out" org)" = ORG-INHERITED ] && pass "org ruleset is ORG-INHERITED" || bad "org: $(row "$out" org)"
[ "$(row "$out" nosource)" = REFUSED ] && pass "absent source_type is REFUSED" || bad "nosource: $(row "$out" nosource)"
[ "$(row "$out" disabled)" = DISABLED-SKIPPED ] && pass "disabled ruleset is left alone" || bad "disabled: $(row "$out" disabled)"
[ "$(row "$out" nobypass)" = REFUSED ] && pass "unreadable bypass_actors is REFUSED" || bad "nobypass: $(row "$out" nobypass)"
[ "$rc" = 3 ] && pass "refusals exit 3" || bad "expected exit 3, got $rc"

# --- apply mode ---
set +e; out=$(PATH="$tmp/bin:$PATH" bash "$script" "${args[@]}" --apply --backup-dir "$tmp/bk" 2>/dev/null); set -e
[ "$(row "$out" phantom-only)" = RETIRED ] && pass "phantom-only RETIRED and verified" || bad "phantom-only apply: $(row "$out" phantom-only)"
[ "$(row "$out" mixed)" = RETIRED ] && pass "mixed RETIRED and verified" || bad "mixed apply: $(row "$out" mixed)"
p="$tmp/puts/phantom-only.1"
if [ -f "$p" ] && [ "$(jq -c '[.rules[].type]' "$p")" = '["deletion","non_fast_forward","pull_request","code_coverage"]' ]; then
  pass "emptied rule is dropped, every other rule kept in order"
else bad "phantom-only PUT body wrong: $(jq -c '[.rules[].type]' "$p" 2>/dev/null)"; fi
m="$tmp/puts/mixed.2"
if [ -f "$m" ] && [ "$(jq -c '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[]]' "$m")" = '[{"context":"scan / gitleaks","integration_id":15368}]' ]; then
  pass "only the phantom is removed; the real context keeps its integration_id"
else bad "mixed PUT body wrong"; fi
[ "$(jq -c '{bypass_actors,conditions,enforcement,name,target}' "$p")" = "$(jq -c '{bypass_actors,conditions,enforcement,name,target}' "$fx/phantom-only.1")" ] \
  && pass "non-rule fields are byte-identical" || bad "non-rule fields changed"
[ -f "$tmp/bk/o__phantom-only.1.json" ] && pass "live body backed up before the write" || bad "no backup written"
for r in clean org nosource disabled nobypass; do for f in "$tmp/puts/$r".*; do [ -e "$f" ] && bad "$r was written"; done; done
[ "$fail" = 0 ] && pass "no write to clean, org, nosource, disabled or nobypass"

# --- second round: findings from the #1640 review ---
reset() { rm -rf "$tmp/puts" "$tmp"/calls.*; mkdir -p "$tmp/puts"; }

# A phantom in one ruleset and a retired rule in ANOTHER: the retired rule is still reported.
reset; set +e; out=$(PATH="$tmp/bin:$PATH" bash "$script" --repo o/split 2>/dev/null); set -e
grep -q 'also in this repo: code_coverage' <<<"$out" \
  && pass "a retired rule in a separate ruleset is reported" || bad "split: retired rule not reported: $out"

# The phantom is on page 2 of the ruleset listing.
reset; set +e; out=$(PATH="$tmp/bin:$PATH" bash "$script" --repo o/paged 2>/dev/null); set -e
[ "$(row "$out" paged)" = WOULD-RETIRE ] && pass "a phantom on page 2 of the listing is found" || bad "paged: $(row "$out" paged)"

# The ruleset changes between the planning read and the write: refuse, write nothing.
reset; set +e; out=$(PATH="$tmp/bin:$PATH" bash "$script" --repo o/racy --apply --backup-dir "$tmp/bk" 2>/dev/null); rc=$?; set -e
if [ "$(row "$out" racy)" = REFUSED ] && [ ! -e "$tmp/puts/racy.12" ] && [ "$rc" = 3 ]; then
  pass "a ruleset edited after the read is refused and not overwritten"
else bad "racy: state $(row "$out" racy), rc $rc, written: $(ls "$tmp/puts")"; fi

# The backup cannot be written (a directory occupies its path): refuse, write nothing.
reset; mkdir -p "$tmp/bk2/o__badbackup.13.json"
set +e; out=$(PATH="$tmp/bin:$PATH" bash "$script" --repo o/badbackup --apply --backup-dir "$tmp/bk2" 2>/dev/null); set -e
if [ "$(row "$out" badbackup)" = REFUSED ] && [ ! -e "$tmp/puts/badbackup.13" ]; then
  pass "a failed backup stops the write"
else bad "badbackup: state $(row "$out" badbackup), written: $(ls "$tmp/puts")"; fi

# Owner enumeration fails after partial output: the run dies before any write.
reset; set +e; out=$(PATH="$tmp/bin:$PATH" bash "$script" --owner fail --repo o/mixed --apply --backup-dir "$tmp/bk" 2>/dev/null); rc=$?; set -e
if [ "$rc" = 2 ] && [ -z "$(ls "$tmp/puts")" ]; then
  pass "a failed owner listing stops the run before any write"
else bad "owner fail: rc $rc, written: $(ls "$tmp/puts")"; fi

# A --repos file whose last line has no trailing newline: the last repository is kept.
reset; printf 'o/clean\no/phantom-only' > "$tmp/repos.txt"
set +e; out=$(PATH="$tmp/bin:$PATH" bash "$script" --repos "$tmp/repos.txt" 2>/dev/null); set -e
[ "$(row "$out" phantom-only)" = WOULD-RETIRE ] && pass "the last line of --repos is read without a trailing newline" \
  || bad "repos file: last line dropped: $out"

[ "$fail" = 0 ] && echo "retire-phantom-contexts-test: all passed" || { echo "retire-phantom-contexts-test: FAILED"; exit 1; }
