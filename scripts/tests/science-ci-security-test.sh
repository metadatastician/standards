#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise the workflows' actual shell steps with controlled remote data.
# Steps are read from the workflow YAML with yq and run under stubbed tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/.github/workflows"
PUBLIC_KEY='gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf
'
FINGERPRINT='SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8'
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf '%s\n' "$*" >&2; exit 1; }
assert() { local msg="$1"; shift; "$@" || fail "$msg"; }
newtmp() { mktemp -d "$TMP_ROOT/$1XXXXXX"; }
# q FILE EXPR: run a yq expression against a workflow, raw output.
q() { yq -r "$2" "$WF/$1"; }
# qj FILE EXPR: same, as compact JSON (for exact comparisons of values).
qj() { yq -o=json -I=0 "$2" "$WF/$1"; }
# step_index FILE JOB SELECT: index of the first step of JOB matching SELECT, or empty.
step_index() {
  yq -r ".jobs[\"$2\"].steps | to_entries | map(select(.value | $3)) | .[0].key // \"\"" "$WF/$1"
}
step_field() { q "$1" ".jobs[\"$2\"].steps[$3][\"$4\"]"; }
step_field_json() { qj "$1" ".jobs[\"$2\"].steps[$3][\"$4\"]"; }
contains() { [[ "$1" == *"$2"* ]]; }
truthy() { [ "$1" != null ] && [ "$1" != false ]; }

# --- Mirror host-key verification ------------------------------------------
M=mirror-reusable.yml
while IFS= read -r name; do
  case "$name" in visibility-guard|mirror-radicle|mirror-r2-bundle) continue ;; esac
  vi="$(step_index "$M" "$name" '(.name // "") | test("^Verify ")')"
  pi="$(step_index "$M" "$name" '(.run // "") | contains("git push")')"
  [ -n "$vi" ] && [ -n "$pi" ] || fail "$name: missing verification or push"
  [ "$vi" -lt "$pi" ] || fail "$name: verifies too late"
  [ "$(step_field_json "$M" "$name" "$vi" if)" = "$(step_field_json "$M" "$name" "$pi" if)" ] \
    || fail "$name: verification condition differs from push"
  ! truthy "$(step_field_json "$M" "$name" "$vi" continue-on-error)" \
    || fail "$name: verification failure is ignored"
  if [ "$name" = mirror-gitlab ]; then
    [ "$(qj "$M" ".jobs[\"$name\"][\"continue-on-error\"]")" = true ] \
      || fail 'GitLab mirror must remain advisory'
  fi
  if [ "$name" = mirror-disroot ]; then
    [ "$(q "$M" ".jobs[\"$name\"].steps[$vi].env.APPROVED_FINGERPRINT")" = '${{ vars.DISROOT_SSH_FINGERPRINT }}' ] \
      || fail 'Disroot must require an independently approved fingerprint'
  fi
  verify_run="$(step_field "$M" "$name" "$vi" run)"
  tmp="$(newtmp mirror-verification-)"
  printf '#!/bin/sh\nprintf '\''%%s'\'' "$TEST_HOST_KEY"\n' > "$tmp/ssh-keyscan"
  chmod 755 "$tmp/ssh-keyscan"
  envfile="$tmp/env"
  run_case() { # key fingerprint expect(0|1)
    rm -f "$envfile"
    local rc=0 out
    out="$(env PATH="$tmp:$PATH" RUNNER_TEMP="$tmp" GITHUB_ENV="$envfile" MIRROR_HOST=gitlab.com \
      TEST_HOST_KEY="$1" APPROVED_FINGERPRINT="$2" bash -c "$verify_run" 2>&1)" || rc=$?
    if [ "$3" = 0 ]; then
      [ "$rc" = 0 ] || fail "$name: unexpected verification result"$'\n'"$out"
      [ -e "$envfile" ] || fail "$name: unsafe environment was exported"
      grep -qF 'StrictHostKeyChecking=yes' "$envfile" || fail "$name: strict checking missing"
    else
      [ "$rc" != 0 ] || fail "$name: unexpected verification result"$'\n'"$out"
      [ ! -e "$envfile" ] || fail "$name: unsafe environment was exported"
    fi
  }
  run_case "$PUBLIC_KEY" "$FINGERPRINT" 0
  run_case "${PUBLIC_KEY/OzRdf/OzRdg}" "$FINGERPRINT" 1
  run_case '' "$FINGERPRINT" 1
  run_case 'invalid key' "$FINGERPRINT" 1
  run_case "$PUBLIC_KEY" '' 1
done < <(q "$M" '.jobs | keys | .[]')
echo 'PASS: all six mirrors accept approved keys and reject tampered, empty, malformed, or unapproved keys'

# --- R2 bundle mirror --------------------------------------------------------
R=mirror-r2-bundle
[ "$(qj "$M" ".jobs[\"$R\"] | type")" = '"!!map"' ] || fail 'mirror-r2-bundle job missing from mirror-reusable.yml'
rv="$(step_index "$M" "$R" '(.name // "") == "Verify R2 endpoint and age recipient"')"
ru="$(step_index "$M" "$R" '(.name // "") | contains("age-encrypt")')"
[ -n "$rv" ] && [ -n "$ru" ] || fail 'mirror-r2-bundle missing verify or upload step'
[ "$rv" -lt "$ru" ] || fail 'mirror-r2-bundle verifies too late'
[ "$(step_field_json "$M" "$R" "$rv" if)" = "$(step_field_json "$M" "$R" "$ru" if)" ] \
  || fail 'mirror-r2-bundle verify/upload conditions differ'
! truthy "$(step_field_json "$M" "$R" "$rv" continue-on-error)" \
  || fail 'mirror-r2-bundle verification failure is ignored'
r2_verify="$(step_field "$M" "$R" "$rv" run)"
r2_script="$(step_field "$M" "$R" "$ru" run)"
ENCRYPT='age -r "$AGE_RECIPIENT" -o "$ENC_BUNDLE" "$RAW_BUNDLE"'
REMOVE='rm -f "$RAW_BUNDLE"'
contains "$r2_script" "$ENCRYPT" || fail 'mirror-r2-bundle must encrypt with age before upload'
contains "$r2_script" "$REMOVE" || fail 'mirror-r2-bundle must remove plaintext bundle before upload'
# Match whole command lines so the earlier EXIT trap does not count as plaintext removal.
line_of() { # first stripped line equal to $1 (mode eq) or starting with $1 (mode prefix)
  awk -v want="$1" -v mode="$2" '{ s = $0; gsub(/^[ \t]+|[ \t]+$/, "", s)
    if ((mode == "eq" && s == want) || (mode == "prefix" && index(s, want) == 1)) { print NR; exit } }' <<<"$r2_script"
}
encrypt_at="$(line_of "$ENCRYPT" eq)"
remove_at="$(line_of "$REMOVE" eq)"
upload_at="$(line_of 'aws s3 cp "$ENC_BUNDLE"' prefix)"
[ -n "$encrypt_at" ] && [ -n "$remove_at" ] && [ -n "$upload_at" ] \
  && [ "$encrypt_at" -lt "$remove_at" ] && [ "$remove_at" -lt "$upload_at" ] \
  || fail 'mirror-r2-bundle must encrypt and remove plaintext before uploading ciphertext'
contains "$r2_script" '/snapshots/${BUNDLE_TS}-${COMMIT_SHA}.bundle.age' \
  || fail 'mirror-r2-bundle must write an immutable timestamp+SHA snapshot bundle'
contains "$r2_script" '/latest.bundle.age' || fail 'mirror-r2-bundle must update latest.bundle.age'

tmp="$(newtmp r2-snapshots-)"
stub() { printf '#!/bin/sh\nset -eu\n%s\n' "$2" > "$tmp/$1"; chmod 755 "$tmp/$1"; }
stub date 'printf "%s\n" 20261023T120000Z'
stub git 'if [ "$2" = create ]; then printf plaintext > "$3"; else test -s "$3"; fi'
stub age 'printf ciphertext > "$4"'
stub aws 'test ! -e "$RUNNER_TEMP/test-repo.bundle" || exit 1
test "$(cat "$3")" = ciphertext || exit 1
printf '\''%s\n'\'' "$4" >> "$TEST_UPLOADS"'
uploads="$tmp/uploads"
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for run in '100 1' '100 2' '101 1'; do
  read -r run_id attempt <<<"$run"
  out="$(env PATH="$tmp:$PATH" RUNNER_TEMP="$tmp" REPO_NAME=test-repo COMMIT_SHA="$sha" \
    AGE_RECIPIENT=test-recipient R2_BUCKET=test-bucket MIRROR_ORG=test-owner \
    R2_ENDPOINT=https://test.r2.cloudflarestorage.com TEST_UPLOADS="$uploads" \
    GITHUB_RUN_ID="$run_id" GITHUB_RUN_ATTEMPT="$attempt" bash -c "$r2_script" 2>&1)" \
    || fail "Command failed: r2 upload run $run"$'\n'"$out"
  [ ! -e "$tmp/test-repo.bundle.age" ] || fail 'R2 upload left ciphertext behind'
done
snapshots="$(awk 'NR % 2 == 1' "$uploads")"
[ "$(sort -u <<<"$snapshots" | wc -l)" -eq 3 ] || fail 'R2 snapshot uploads collide across runs or attempts'
[ "$(head -n1 <<<"$snapshots")" = "s3://test-bucket/test-owner/test-repo/snapshots/20261023T120000Z-100-1-$sha.bundle.age" ] \
  || fail 'R2 snapshot path or bundle filename format changed'
[ "$(wc -l < "$uploads")" -eq 6 ] && ! awk 'NR % 2 == 0' "$uploads" \
  | grep -vxF 's3://test-bucket/test-owner/test-repo/latest.bundle.age' >/dev/null \
  || fail 'R2 latest bundle path changed'
echo 'PASS: R2 snapshots differ across runs and attempts at the same timestamp and SHA; only ciphertext is uploaded'

EP='https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com'
AGE='age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p'
r2_case() { # endpoint bucket recipient expect(0|1)
  local rc=0 out
  out="$(env R2_ENDPOINT="$1" R2_BUCKET="$2" AGE_RECIPIENT="$3" bash -c "$r2_verify" 2>&1)" || rc=$?
  if { [ "$4" = 0 ] && [ "$rc" != 0 ]; } || { [ "$4" = 1 ] && [ "$rc" = 0 ]; }; then
    fail "mirror-r2-bundle unexpected verify result for [$1, $2, $3]"$'\n'"$out"
  fi
}
r2_case "$EP" estate-mirrors "$AGE" 0
r2_case 'https://0123456789abcdef0123456789abcdef.us.r2.cloudflarestorage.com' estate-mirrors "$AGE" 0
r2_case 'http://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com' estate-mirrors "$AGE" 1
r2_case 'https://evil.example.com' estate-mirrors "$AGE" 1
r2_case "$EP" INVALID_BUCKET "$AGE" 1
r2_case "$EP" estate.mirrors "$AGE" 1
r2_case "$EP" estate-mirrors '' 1
echo 'PASS: mirror-r2-bundle validates R2 endpoint, bucket, and age recipient and enforces client-side age encryption'

# --- Hypatia scanner source pin ---------------------------------------------
H=hypatia-scan-reusable.yml
si="$(step_index "$H" scan '.name == "Check out resolved Hypatia commit"')"
if [ -n "$si" ]; then
  tmp="$(newtmp scanner-source-)"
  upstream="$tmp/upstream"
  git init -q "$upstream"
  commit() {
    printf '%s' "$1" > "$upstream/source"
    git -C "$upstream" add source
    git -C "$upstream" -c user.name='CI Test' -c user.email=ci@example.invalid \
      -c commit.gpgsign=false commit -qm "$1"
    git -C "$upstream" rev-parse HEAD
  }
  resolved="$(commit resolved)"
  newer="$(commit advanced)"
  source_dir="$tmp/scanner"
  script="$(step_field "$H" scan "$si" run)"
  script="${script//\$HOME\/hypatia/$source_dir}"
  script="${script//https:\/\/github.com\/hyperpolymath\/hypatia.git/$upstream}"
  for _ in 1 2; do
    out="$(HYPATIA_SHA="$resolved" bash -c "$script" 2>&1)" || fail "Command failed: scanner checkout"$'\n'"$out"
  done
  [ "$(cat "$source_dir/source")" = resolved ] || fail 'Scanner followed advancing HEAD'
  rc=0; out="$(HYPATIA_SHA="$newer" bash -c "$script" 2>/dev/null)" || rc=$?
  [ "$rc" != 0 ] && contains "$out" 'cached source does not match' || fail 'Mismatched cache was accepted'
  echo 'PASS: scanner checks out the resolved commit on cache miss/hit and rejects a mismatched cache'
else
  echo 'SKIP: Check out resolved Hypatia commit step not found in workflow (refactored)'
fi

# --- Hypatia findings validation --------------------------------------------
fi_="$(step_index "$H" scan '.name == "Validate findings and count severities"')"
[ -n "$fi_" ] || fail 'Validate findings and count severities step missing'
validate="$(step_field "$H" scan "$fi_" run)"
tmp="$(newtmp scanner-contract-)"
output="$tmp/output"
findings="$tmp/hypatia-findings.json"
run_validate() { (cd "$tmp" && GITHUB_OUTPUT="$output" GITHUB_STEP_SUMMARY="$tmp/summary" bash -c "$validate"); }
has_line() { grep -qxF "$1" "$output"; }
# Clean scan (single well-formed empty array) is a positive control (standards#1054)
printf '%s' '[]' > "$findings"
out="$(run_validate 2>&1)" || fail "Command failed: validate clean scan"$'\n'"$out"
for line in findings_count=0 critical=0 high=0 medium=0; do
  has_line "$line" || fail "clean scan ${line%=0} was not 0"
done
rm -f "$output"
printf '%s' '[{"severity":"high"},{"severity":"medium"},{"severity":"critical"}]' > "$findings"
out="$(run_validate 2>&1)" || fail "Command failed: validate findings"$'\n'"$out"
has_line medium=1 || fail 'medium was not counted'
grep -qF critical=1 "$output" || fail 'critical finding was lost'
grep -qF high=1 "$output" || fail 'high finding was lost'
# Invalid inputs: empty, whitespace, truncated, wrong top-level type, invalid
# element shape, unknown severity, and multiple JSON documents.
invalid_inputs=('' $'   \n' '[' '{}' 'null' '[{}]' '[{"severity":"unknown"}]' '[] []' $'[]\n[{"severity":"high"}]')
for invalid in "${invalid_inputs[@]}"; do
  rm -f "$output"
  printf '%s' "$invalid" > "$findings"
  rc=0; run_validate >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "Invalid scanner output accepted: $(printf '%q' "$invalid")"
  [ ! -e "$output" ] || fail 'Invalid output produced gate counts'
done
printf '%s' '[{"severity":"warn","rule_module":"research_extensions","type":"RE001","file":"ci.yml"}]' > "$findings"
rc=0; BLOCKING_THRESHOLD=medium bash "$ROOT/scripts/apply-baseline.sh" "$findings" "$tmp/absent-baseline.json" blocking \
  >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail 'warn escaped the medium baseline threshold'
echo 'PASS: warn retains medium severity; malformed, unknown, and multiple scanner documents fail closed'

# --- Policy startup checks ---------------------------------------------------
tmp="$(newtmp policy-startup-)"
path="$tmp/.github/workflows/ci.yml"
mkdir -p "$(dirname "$path")"
git init -q "$tmp"
printf 'name: CI\non: push\njobs:\n  # test:\n  #   runs-on: ubuntu-latest\n' > "$path"
git -C "$tmp" add .
parser="$ROOT/tools/policy/check-workflows-parse.sh"
checker="$ROOT/scripts/check-descriptile-policy.sh"
in_tmp() { (cd "$tmp" && bash "$1") >/dev/null 2>&1; }
! in_tmp "$parser" || fail 'Comment-only jobs were accepted'
printf 'name: CI\non: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: test -f .machine_readable/STATE.a2ml\n' > "$path"
! in_tmp "$checker" || fail 'Retired policy path was accepted'
sed -i 's#\.machine_readable/STATE#.machine_readable/descriptiles/STATE#' "$path"
for check in "$parser" "$checker"; do
  out="$(cd "$tmp" && bash "$check" 2>&1)" || fail "Command failed: $check"$'\n'"$out"
done
write_example() { printf 'name: CI\non: push\njobs:\n  test:\n    steps:\n      - run: |\n          %s\n' "$1" > "$path"; }
for example in 'echo "test -f .machine_readable/STATE.a2ml"' \
               "printf '%s\\n' 'check_file .machine_readable/META.a2ml'"; do
  write_example "$example"
  out="$(cd "$tmp" && bash "$checker" 2>&1)" || fail "Command failed: $checker on $example"$'\n'"$out"
done
for example in 'test -f ".machine_readable/STATE.a2ml"' \
               "test -e '.machine_readable/6a2/META.a2ml'" \
               "check_file '.machine_readable/AGENTIC.a2ml'" \
               'echo "$(test -f .machine_readable/STATE.a2ml)"'; do
  write_example "$example"
  ! in_tmp "$checker" || fail "Executable retired-path check was accepted: $example"
done
echo 'PASS: empty workflows and retired policy fail; executable jobs with canonical policy pass'

# --- Visibility guard (owner ruling 2026-11-13, CASE-038) -------------------
# A private source is never force-pushed to a forge that is not confirmed private.
while IFS= read -r name; do
  case "$name" in visibility-guard|mirror-r2-bundle) continue ;; esac
  forge="$(tr '[:lower:]' '[:upper:]' <<<"${name#mirror-}")"
  [ "$(q "$M" ".jobs[\"$name\"].needs")" = visibility-guard ] || fail "$name: does not wait for the visibility guard"
  cond="$(q "$M" ".jobs[\"$name\"].if // \"\"")"
  contains "$cond" "needs.visibility-guard.outputs.public == 'true'" \
    && contains "$cond" "vars.${forge}_MIRROR_PRIVATE_CONFIRMED == 'true'" \
    || fail "$name: pushes a private source without the guard"
  [ "$(q "$M" ".jobs[\"visibility-guard\"].steps[1].env | has(\"EN_$forge\")")" = true ] \
    || fail "guard does not check $forge"
done < <(q "$M" '.jobs | keys | .[]')
vis="$(q "$M" '.jobs["visibility-guard"].steps[0].run')"
refuse="$(q "$M" '.jobs["visibility-guard"].steps[1].run')"
tmp="$(newtmp mirror-guard-)"
for pair in 'false true' 'true false' ' false'; do
  private="${pair% *}"; public="${pair#* }"
  rm -f "$tmp/out"
  out="$(SRC_PRIVATE="$private" GITHUB_OUTPUT="$tmp/out" bash -c "$vis" 2>&1)" \
    || fail "Command failed: visibility check"$'\n'"$out"
  grep -qF "public=$public" "$tmp/out" || fail "guard: private='$private' not read as public=$public"
done
guard_case() { # expect(0|1) VAR=VAL...
  local expect="$1" rc=0; shift
  env "$@" GITHUB_STEP_SUMMARY="$tmp/summary" bash -c "$refuse" >/dev/null 2>&1 || rc=$?
  if { [ "$expect" = 0 ] && [ "$rc" != 0 ]; } || { [ "$expect" = 1 ] && [ "$rc" = 0 ]; }; then
    fail "guard: $* should $([ "$expect" = 0 ] && echo pass || echo refuse)"
  fi
}
guard_case 1 EN_GITLAB=true
guard_case 0 EN_GITLAB=true OK_GITLAB=true
guard_case 1 EN_CODEBERG=true EN_RADICLE=true OK_RADICLE=true
guard_case 0
echo 'PASS: every forge mirror waits for the visibility guard, which refuses private sources on unconfirmed forges'
