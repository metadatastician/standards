#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# issue-evidence-workflow-test.sh — end-to-end harness for
# .github/workflows/issue-evidence-reusable.yml (3-practice/ISSUE-EVIDENCE.adoc).
#
# It extracts the `run:` bodies of every job with yq and runs them in job
# order against a fixture caller repository and a stand-in `gh`, with what
# GitHub Actions gives each job: its own workspace, RUNNER_TEMP, GITHUB_ENV,
# GITHUB_PATH, GITHUB_OUTPUT and step summary. The only channel from one job
# to the next is the job outputs the workflow declares, resolved as GitHub
# does (`${{ needs.J.outputs.K }}` from `${{ steps.S.outputs.K }}`). A
# checkout step is simulated: the caller is cloned from the fixture at the
# evaluated commit; the standards checkout and the `gh api` fetches at
# `job.workflow_sha` serve the scripts under test.
#
# It asserts:
#   (i)   the normal path: the decisions, and every close and reopen with its
#         comment (a close comment equals what render-comment writes, a
#         removed-row reopen equals what removed-rows writes);
#   (ii)  the attack of Codex's P1 on #1652: a ledger evidence script that,
#         when run, replaces the staged applier and evaluator in RUNNER_TEMP,
#         appends BASH_ENV to GITHUB_ENV, and edits every evaluated and plan
#         file it can reach, changes NO action and NO comment compared with
#         the same run where that script is benign;
#   (iii) no job but `scripts` runs code of the evaluated repository (each
#         evidence script leaves a mark naming the job it ran in);
#   (iv)  what the `scripts` job can still do by lying in its output: an
#         invented record is refused (nothing is applied); a flipped outcome
#         of a real script check changes that check's result and nothing else;
#   (v)   structure: no `${{ }}` inside any run: body, least privilege per
#         job, and the plan-building job never asks the evaluator to run a
#         script.
# A NEGATIVE CONTROL runs the harness against a mutant of the workflow whose
# plan-building job evaluates with the scripts again, and requires failures.
#
# IEW_REUSABLE, IEW_CALLER and IEW_SCRIPTS override the reusable, the caller
# and the scripts directory under test (to run the harness against an older
# commit). IEW_NEGATIVE_CONTROL=1 skips the negative control (no recursion).
#
# Run: bash scripts/tests/issue-evidence-workflow-test.sh
#
# This file quotes `${{ }}` expressions and fixture scripts as literal text.
# shellcheck disable=SC2016,SC1003
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="${IEW_REUSABLE:-$REPO_ROOT/.github/workflows/issue-evidence-reusable.yml}"
CALLER="${IEW_CALLER:-$REPO_ROOT/.github/workflows/issue-evidence.yml}"
SRC="${IEW_SCRIPTS:-$REPO_ROOT/scripts}"
for t in yq jq git sha256sum; do
  command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not found on PATH" >&2; exit 77; }
done
WORK="$(mktemp -d)"
if [ -n "${IEW_KEEP:-}" ]; then echo "keeping $WORK"; else trap 'rm -rf "$WORK"' EXIT; fi
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; fail=$((fail + 1)); }
verdict() {
  local label="$1"
  shift
  if "$@"; then ok "$label"; else ko "$label"; fi
}

R="o/r"
BOT="github-actions[bot]"
FAKE_WF_SHA="$(printf 'f%.0s' {1..40})"
LEDGER_PATH=".machine_readable/issue-evidence.jsonl"
MAXA=10
WFJ="$WORK/reusable.json"
yq -o=json . "$WF" >"$WFJ" || { echo "FAIL: $WF does not parse" >&2; exit 1; }

# --- the stand-in gh ------------------------------------------------------------
# State lives in $GHS: HEAD (the default branch's head), issues/N.json and
# issues/N.timeline, and the record of writes (ACTIONS.log, body-ACTION-N.txt).
BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$GHS/CALLS.log"
nf() { echo "gh: Not Found (HTTP 404): $1" >&2; exit 1; }
sub="${1:-}"
shift || true
case "$sub" in
  api)
    jqf="" path=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --jq) jqf="$2"; shift 2 ;;
        -H | --header | -X | --method) shift 2 ;;
        -*) shift ;;
        *) [ -n "$path" ] || path="$1"; shift ;;
      esac
    done
    out="$GHS/.out"
    case "$path" in
      "repos/$GHS_REPO") printf '{"default_branch":"main","full_name":"%s"}\n' "$GHS_REPO" >"$out" ;;
      "repos/$GHS_REPO/git/ref/heads/main")
        printf '{"object":{"sha":"%s","type":"commit"},"ref":"refs/heads/main"}\n' "$(cat "$GHS/HEAD")" >"$out" ;;
      "repos/$GHS_REPO/issues/"*"/timeline?per_page=100")
        n="${path#"repos/$GHS_REPO/issues/"}"
        n="${n%%/*}"
        [ -f "$GHS/issues/$n.timeline" ] || nf "$path"
        cp "$GHS/issues/$n.timeline" "$out" ;;
      "repos/$GHS_REPO/issues/"*)
        n="${path##*/}"
        [ -f "$GHS/issues/$n.json" ] || nf "$path"
        cp "$GHS/issues/$n.json" "$out" ;;
      "repos/metadatastician/standards/contents/scripts/"*"?ref=$GHS_WF_SHA")
        f="${path#repos/metadatastician/standards/contents/scripts/}"
        f="${f%%\?*}"
        case "$f" in issue-evidence.sh | issue-evidence-apply.sh) ;; *) nf "$path" ;; esac
        [ -f "$GHS_SRC/$f" ] || nf "$path"
        cp "$GHS_SRC/$f" "$out" ;;
      "repos/$GHS_REPO/contents/"*"?ref="*)
        p="${path#"repos/$GHS_REPO/contents/"}"
        ref="${p##*\?ref=}"
        p="${p%%\?ref=*}"
        git -C "$GHS_ORIGIN" cat-file -e "$ref:$p" 2>/dev/null || nf "$path"
        git -C "$GHS_ORIGIN" show "$ref:$p" >"$out" ;;
      *) echo "stand-in gh: unexpected api path: $path" >&2; exit 1 ;;
    esac
    if [ -n "$jqf" ]; then jq -r "$jqf" "$out"; else cat "$out"; fi
    ;;
  issue)
    verb="${1:-}"
    shift || true
    if [ "$verb" = list ]; then
      jqf=""
      while [ "$#" -gt 0 ]; do
        case "$1" in --jq) jqf="$2"; shift 2 ;; *) shift ;; esac
      done
      cat "$GHS"/issues/*.json | jq -c -s 'map(select(.state == "open") | {number})' >"$GHS/.out"
      if [ -n "$jqf" ]; then jq -r "$jqf" "$GHS/.out"; else cat "$GHS/.out"; fi
      exit 0
    fi
    n="${1:-}"
    shift || true
    reason="" body=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) reason="$2"; shift 2 ;;
        --comment) body="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$verb" in
      close | reopen)
        printf '%s %s %s\n' "$verb" "$n" "$reason" >>"$GHS/ACTIONS.log"
        printf '%s' "$body" >"$GHS/body-$verb-$n.txt" ;;
      *) echo "stand-in gh: unexpected issue verb: $verb" >&2; exit 1 ;;
    esac
    ;;
  *) echo "stand-in gh: unexpected call: $sub $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$BIN/gh"

# --- the fixture caller repository ------------------------------------------------
# row N DISPOSITION CHECKS: one canonical ledger line.
row() {
  jq -c -S -n --argjson n "$1" --arg d "$2" --argjson c "$3" --arg r "$R" \
    '{issue: $n, repo: $r, disposition: $d, claim: "Claim of row \($n) @someone.", checks: $c,
      evidence: ["evidence for \($n)"], added: "2026-11-17"}'
}
ROW1="$(row 1 landed '[{"kind":"path-present","path":"README.adoc"}]')"
ROW2="$(row 2 superseded '[{"kind":"script","path":"scripts/pass.sh"},{"kind":"path-present","path":"README.adoc"}]')"
ROW3="$(row 3 landed '[{"kind":"script","path":"scripts/fail.sh"}]')"
ROW4="$(row 4 moot '[{"kind":"path-present","path":"gone.txt"},{"kind":"path-present","path":"README.adoc"}]')"
ROW5="$(row 5 landed '[{"kind":"path-present","path":"README.adoc"}]')"
ROW6="$(row 6 landed '[{"kind":"script","path":"scripts/cannot.sh"}]')"
ROW7="$(row 7 landed '[{"kind":"script","path":"scripts/evidence.sh"},{"kind":"path-present","path":"README.adoc"}]')"
hash_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# The benign and the malicious evidence script for row 7. The malicious one
# exits 0 like the benign one, and meanwhile attacks whatever runs after it in
# the same job: it replaces the staged applier and evaluator (new inodes, so
# the running evaluator is not disturbed), persists through BASH_ENV in
# GITHUB_ENV, and from there edits every evaluated and plan file it can find.
write_evidence_script() { # FILE benign|evil
  if [ "$2" = benign ]; then
    printf '#!/usr/bin/env bash\n: >"${IEW_MARKS:?}/${IEW_JOB:?}"\nexit 0\n' >"$1"
    return
  fi
  cat >"$1" <<'EVIL'
#!/usr/bin/env bash
: >"${IEW_MARKS:?}/${IEW_JOB:?}"
t="${RUNNER_TEMP:-}"
[ -n "$t" ] && [ -d "$t" ] || exit 0
e="$t/.e"
mkdir -p "$e"
cat >"$e/apply.sh" <<'W'
#!/usr/bin/env bash
real="$(dirname "$0")/.e/issue-evidence-apply.sh"
if [ "${1:-}" = select ]; then
  bash "$real" "$@" || exit
  printf '%s\n' '{"action":"close","body":"PWNED","close_reason":"completed","disposition":"landed","issue":999,"reason":"evidence-holds","repo":"o/r"}'
  exit 0
fi
exec bash "$real" "$@"
W
cat >"$e/evaluator.sh" <<'W'
#!/usr/bin/env bash
real="$(dirname "$0")/.e/issue-evidence.sh"
if [ "${1:-}" = render-comment ]; then
  bash "$real" "$@" || exit
  printf '\nPWNED'
  exit 0
fi
exec bash "$real" "$@"
W
cat >"$e/env.sh" <<'W'
e="$RUNNER_TEMP/.e"
for s in issue-evidence-apply.sh:apply.sh issue-evidence.sh:evaluator.sh; do
  f="$RUNNER_TEMP/${s%%:*}"
  [ -f "$f" ] || continue
  cmp -s "$f" "$e/${s#*:}" && continue
  cp "$f" "$e/${s%%:*}"
  cp "$e/${s#*:}" "$f.new" && mv "$f.new" "$f"
done
[ "${1:-}" = install-only ] && exit 0
for f in "$RUNNER_TEMP"/*evaluated* "$RUNNER_TEMP"/*plan*; do
  [ -f "$f" ] || continue
  sed -i -e 's/"failed":\[0\],"holds":false,"issue":3,/"failed":[],"holds":true,"issue":3,/' \
    -e 's/issue-evidence:\*\* closing/issue-evidence:** PWNED closing/' "$f"
done
W
RUNNER_TEMP="$t" bash "$e/env.sh" install-only
[ -n "${GITHUB_ENV:-}" ] && printf 'BASH_ENV=%s\n' "$e/env.sh" >>"$GITHUB_ENV"
exit 0
EVIL
}

make_origin() { # DIR benign|evil
  local d="$1"
  mkdir -p "$d/scripts" "$d/.machine_readable"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name test
  git -C "$d" config commit.gpgsign false
  printf '= Fixture\n' >"$d/README.adoc"
  write_evidence_script "$d/scripts/pass.sh" benign
  printf '#!/usr/bin/env bash\n: >"${IEW_MARKS:?}/${IEW_JOB:?}"\nexit 1\n' >"$d/scripts/fail.sh"
  printf '#!/usr/bin/env bash\n: >"${IEW_MARKS:?}/${IEW_JOB:?}"\nexit 2\n' >"$d/scripts/cannot.sh"
  write_evidence_script "$d/scripts/evidence.sh" "$2"
  chmod +x "$d"/scripts/*.sh
  printf '%s\n' "$ROW1" "$ROW2" "$ROW3" "$ROW4" "$ROW5" "$ROW6" "$ROW7" >"$d/$LEDGER_PATH"
  git -C "$d" add -A
  git -C "$d" commit -q -m "ledger with row 5"
  printf '%s\n' "$ROW1" "$ROW2" "$ROW3" "$ROW4" "$ROW6" "$ROW7" >"$d/$LEDGER_PATH"
  git -C "$d" commit -q -am "remove row 5"
}

# timeline WORD...: mark:HASH (a bot comment carrying the marker), closed:WHO.
timeline() {
  local w out="[]" item
  for w in "$@"; do
    case "$w" in
      mark:*) item="$(jq -c -n --arg b "$BOT" --arg h "${w#mark:}" \
        '{event: "commented", user: {login: $b}, actor: {login: $b}, body: ("**issue-evidence:** closing.\n\n<!-- issue-evidence-bot: row-sha256=" + $h + " -->")}')" ;;
      closed:*) item="$(jq -c -n --arg u "${w#closed:}" '{event: "closed", actor: {login: $u}}')" ;;
    esac
    out="$(jq -c --argjson it "$item" '. + [$it]' <<<"$out")"
  done
  printf '%s\n' "$out"
}
gh_issue() { # N open|closed TIMELINE
  local closer=null
  [ "$2" = closed ] && closer="$(jq -c '[.[] | select(.event == "closed")] | last | {login: .actor.login}' <<<"$3")"
  jq -c -n --argjson n "$1" --arg s "$2" --argjson c "$closer" '{number: $n, state: $s, closed_by: $c}' >"$GHS/issues/$1.json"
  printf '%s\n' "$3" >"$GHS/issues/$1.timeline"
}

# --- running the workflow -----------------------------------------------------------
# resolve VALUE: a value with no expression as is; a whole-value `${{ E }}`
# resolved as GitHub would for this run; anything else is a failure.
resolve() {
  local v="$1" e id key
  case "$v" in
    '${{ '*' }}') e="${v#'${{ '}"; e="${e%' }}'}" ;;
    *'${{'*) return 1 ;;
    *) printf '%s' "$v"; return 0 ;;
  esac
  case "$e" in
    github.repository) printf '%s' "$R" ;;
    github.sha) printf '%s' "$EVAL_SHA" ;;
    github.token) printf 'fake-token' ;;
    job.workflow_sha) printf '%s' "$FAKE_WF_SHA" ;;
    inputs.ledger) printf '%s' "$LEDGER_PATH" ;;
    inputs.max_actions) printf '%s' "$MAXA" ;;
    inputs.apply) printf 'true' ;;
    steps.*.outputs.*)
      id="${e#steps.}" id="${id%%.*}" key="${e##*.outputs.}"
      cat "$JD/steps/$id/$key" 2>/dev/null || true ;;
    needs.*.outputs.*)
      id="${e#needs.}" id="${id%%.*}" key="${e##*.outputs.}"
      cat "$RUN/needs/$id/$key" 2>/dev/null || true ;;
    needs.*.result)
      id="${e#needs.}" id="${id%%.*}"
      cat "$RUN/needs/$id/RESULT" 2>/dev/null || printf 'skipped' ;;
    *) return 1 ;;
  esac
}

# parse_kv FILE DIR: the GitHub key=value / key<<DELIM file format, one file
# per key in DIR (a later write of a key wins, as on GitHub).
parse_kv() {
  local line key delim val
  mkdir -p "$2"
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_-]*)\<\<(.+)$ ]]; then
      key="${BASH_REMATCH[1]}" delim="${BASH_REMATCH[2]}" val=""
      local first=1
      while IFS= read -r line; do
        [ "$line" = "$delim" ] && break
        if [ "$first" = 1 ]; then val="$line" first=0; else val="$val"$'\n'"$line"; fi
      done
      printf '%s' "$val" >"$2/$key"
    elif [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      printf '%s' "${BASH_REMATCH[2]}" >"$2/${BASH_REMATCH[1]}"
    fi
  done <"$1"
}

# job_if_holds JOB: the job-level `if:` (a conjunction of the terms below).
job_if_holds() {
  local cond term lhs op rhs val
  cond="$(jq -r --arg j "$1" '.jobs[$j].if // ""' "$WFJ")"
  cond="${cond#'${{ '}" cond="${cond%' }}'}"
  [ -n "$cond" ] || return 0
  while [ -n "$cond" ]; do
    term="${cond%% && *}"
    if [ "$term" = "$cond" ]; then cond=""; else cond="${cond#* && }"; fi
    case "$term" in
      inputs.apply | '!cancelled()' | 'always()') ;;
      *' == '* | *' != '*)
        if [[ "$term" == *' == '* ]]; then op='=='; else op='!='; fi
        lhs="${term%% "$op" *}" rhs="${term#* "$op" }"
        rhs="${rhs#\'}" rhs="${rhs%\'}"
        val="$(resolve "\${{ $lhs }}")" || { ko "harness: cannot resolve '$lhs' in the if: of job $1"; return 1; }
        if [ "$op" = '==' ]; then [ "$val" = "$rhs" ] || return 1; else [ "$val" != "$rhs" ] || return 1; fi
        ;;
      *) ko "harness: unsupported term '$term' in the if: of job $1"; return 1 ;;
    esac
  done
}

# simulate_checkout STEP-JSON: actions/checkout, as this workflow uses it.
simulate_checkout() {
  local s="$1" repo ref path
  repo="$(resolve "$(jq -r '.with.repository // ""' <<<"$s")")" || return 1
  ref="$(resolve "$(jq -r '.with.ref // ""' <<<"$s")")" || return 1
  path="$(jq -r '.with.path // ""' <<<"$s")"
  if [ "$repo" = "$R" ]; then
    [ "$ref" = "$EVAL_SHA" ] || { echo "caller checkout at '$ref', not the evaluated commit" >&2; return 1; }
    git clone -q "$GHS_ORIGIN" "$WS/$path" && git -C "$WS/$path" checkout -q --detach "$ref"
  elif [ "$repo" = metadatastician/standards ]; then
    [ "$ref" = "$FAKE_WF_SHA" ] || { echo "standards checkout at '$ref', not job.workflow_sha" >&2; return 1; }
    [ -n "$path" ] || return 1
    local f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      mkdir -p "$WS/$path/$(dirname "$f")"
      cp "$SRC/$(basename "$f")" "$WS/$path/$f" || return 1
    done < <(jq -r '.with["sparse-checkout"] // ""' <<<"$s")
  else
    echo "checkout of an unexpected repository: $repo" >&2
    return 1
  fi
}

# run_job JOB: every step of JOB on a fresh "runner".
run_job() {
  local job="$1" n i s run uses ifc id rc=0 failed=0 k v key
  JD="$RUN/jobs/$job"
  WS="$JD/ws"
  mkdir -p "$WS" "$JD/temp" "$JD/steps" "$JD/envd" "$RUN/needs/$job"
  : >"$JD/path.acc"
  : >"$JD/summary.md"
  n="$(jq --arg j "$job" '.jobs[$j].steps | length' "$WFJ")"
  for ((i = 0; i < n; i++)); do
    s="$(jq -c --arg j "$job" --argjson i "$i" '.jobs[$j].steps[$i]' "$WFJ")"
    ifc="$(jq -r '.if // ""' <<<"$s")"
    case "$ifc" in
      "") [ "$failed" = 0 ] || continue ;;
      'always()' | '${{ always() }}') ;;
      *) ko "harness: unsupported step if '$ifc' in job $job"; failed=1; continue ;;
    esac
    id="$(jq -r '.id // ""' <<<"$s")"
    uses="$(jq -r '.uses // ""' <<<"$s")"
    run="$(jq -r '.run // ""' <<<"$s")"
    rc=0
    if [ -n "$uses" ]; then
      case "$uses" in
        actions/checkout@*) simulate_checkout "$s" >"$JD/step-$i.log" 2>&1 || rc=$? ;;
        *) echo "unexpected action $uses" >"$JD/step-$i.log"; rc=1 ;;
      esac
    else
      local envs=() p
      p="$BIN:$PATH0"
      while IFS= read -r k; do [ -n "$k" ] && p="$k:$p"; done <"$JD/path.acc"
      envs=("HOME=$JD/home" "PATH=$p" "LC_ALL=C" "TMPDIR=$JD/tmp" "CI=true"
        "RUNNER_TEMP=$JD/temp" "GITHUB_WORKSPACE=$WS" "GITHUB_ENV=$JD/env-$i" "GITHUB_PATH=$JD/path-$i"
        "GITHUB_OUTPUT=$JD/out-$i" "GITHUB_STEP_SUMMARY=$JD/summary.md" "GITHUB_REF=refs/heads/main"
        "GITHUB_SHA=$EVAL_SHA" "GITHUB_REPOSITORY=$R"
        "GHS=$GHS" "GHS_REPO=$R" "GHS_ORIGIN=$GHS_ORIGIN" "GHS_SRC=$SRC" "GHS_WF_SHA=$FAKE_WF_SHA"
        "IEW_MARKS=$RUN/marks" "IEW_JOB=$job")
      mkdir -p "$JD/home" "$JD/tmp"
      for k in "$JD"/envd/*; do
        [ -f "$k" ] || continue
        key="$(basename "$k")"
        case "$key" in GITHUB_* | RUNNER_* | GHS* | IEW_*) continue ;; esac
        envs+=("$key=$(cat "$k")")
      done
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        v="$(resolve "$(jq -r --arg k "$k" '.env[$k]' <<<"$s")")" || { ko "harness: unresolved env $k in job $job step $i"; failed=1; continue 2; }
        envs+=("$k=$v")
      done < <(jq -r '.env // {} | keys[]' <<<"$s")
      : >"$JD/env-$i"
      : >"$JD/path-$i"
      : >"$JD/out-$i"
      printf '%s\n' "$run" >"$JD/step-$i.sh"
      (cd "$WS" && env -i "${envs[@]}" bash -e "$JD/step-$i.sh") >"$JD/step-$i.log" 2>&1 || rc=$?
      parse_kv "$JD/env-$i" "$JD/envd"
      cat "$JD/path-$i" >>"$JD/path.acc"
      [ -z "$id" ] || parse_kv "$JD/out-$i" "$JD/steps/$id"
    fi
    if [ "$rc" != 0 ]; then
      failed=1
      printf '%s\n' "$job step $i ($(jq -r '.name // ""' <<<"$s")) exited $rc" >>"$RUN/failures"
    fi
  done
  while IFS= read -r k; do
    v="$(jq -r --arg j "$job" --arg k "$k" '.jobs[$j].outputs[$k]' "$WFJ")"
    resolve "$v" >"$RUN/needs/$job/$k" || ko "harness: unresolved output $k of job $job"
  done < <(jq -r --arg j "$job" '.jobs[$j].outputs // {} | keys[]' "$WFJ")
  if [ "$failed" = 0 ]; then echo success >"$RUN/needs/$job/RESULT"; else echo failure >"$RUN/needs/$job/RESULT"; fi
}

# run_workflow NAME benign|evil [FORGE]: a whole run on a fresh fixture. FORGE
# names a function that rewrites the scripts job's outputs after it ran (the
# job lying about its results).
run_workflow() {
  local name="$1" variant="$2" forge="${3:-}" jobs=() done_jobs=" " job progress needs ok_needs nd
  RUN="$WORK/$name"
  GHS="$RUN/gh"
  GHS_ORIGIN="$RUN/origin"
  mkdir -p "$GHS/issues" "$RUN/marks" "$RUN/needs"
  : >"$GHS/CALLS.log"
  : >"$GHS/ACTIONS.log"
  : >"$RUN/failures"
  make_origin "$GHS_ORIGIN" "$variant"
  EVAL_SHA="$(git -C "$GHS_ORIGIN" rev-parse HEAD)"
  printf '%s' "$EVAL_SHA" >"$RUN/sha"
  printf '%s\n' "$EVAL_SHA" >"$GHS/HEAD"
  for nd in 1 2 3 6 7 999; do gh_issue "$nd" open "[]"; done
  gh_issue 4 closed "$(timeline "mark:$(hash_of "$ROW4")" "closed:$BOT")"
  gh_issue 5 closed "$(timeline "mark:$(hash_of "$ROW5")" "closed:$BOT")"
  mapfile -t jobs < <(jq -r '.jobs | keys[]' "$WFJ")
  progress=1
  while [ "$progress" = 1 ]; do
    progress=0
    for job in "${jobs[@]}"; do
      case "$done_jobs" in *" $job "*) continue ;; esac
      needs="$(jq -r --arg j "$job" '.jobs[$j].needs // [] | if type == "string" then [.] else . end | .[]' "$WFJ")"
      ok_needs=1
      for nd in $needs; do
        case "$done_jobs" in *" $nd "*) ;; *) continue 2 ;; esac
        [ "$(cat "$RUN/needs/$nd/RESULT")" = success ] || ok_needs=0
      done
      done_jobs="$done_jobs$job "
      progress=1
      mkdir -p "$RUN/needs/$job"
      if [ "$ok_needs" = 1 ] && job_if_holds "$job"; then
        run_job "$job"
        if [ "$job" = scripts ] && [ -n "$forge" ]; then "$forge"; fi
      else
        echo skipped >"$RUN/needs/$job/RESULT"
      fi
    done
  done
}

# The writes, one per line ("reopen N" has no reason; trailing blanks dropped).
actions_of() { sed "s/ *$//" "$WORK/$1/gh/ACTIONS.log"; }
bodies_of() { # NAME: every comment written, with its file name; the run's
  # evaluated commit (each fixture is a fresh repository) reads <commit>.
  local f sha
  sha="$(cat "$WORK/$1/sha")"
  for f in "$WORK/$1"/gh/body-*.txt; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$(basename "$f")"
    sed "s/$sha/<commit>/g" "$f"
    printf '\n'
  done
}

PATH0="$PATH"
EXPECTED_ACTIONS="close 1 completed
close 2 not planned
reopen 4
close 7 completed
reopen 5"

echo "=== structure ==="
bad_runs="$(jq -r '[.jobs[] | .steps[] | .run // empty | select(contains("${{"))] | length' "$WFJ")"
verdict "no run: body of the reusable contains \${{ }}" [ "$bad_runs" = 0 ]
bad_runs="$(yq -o=json . "$CALLER" | jq -r '[.jobs[] | .steps[]? | .run // empty | select(contains("${{"))] | length')"
verdict "no run: body of the caller contains \${{ }}" [ "$bad_runs" = 0 ]
verdict "the caller runs on a change to either script (F3)" \
  test "$(yq -o=json '.on.push.paths' "$CALLER" | jq -r '[.[] | select(. == "scripts/issue-evidence.sh" or . == "scripts/issue-evidence-apply.sh")] | length')" = 2
verdict "a scripts job exists and holds only contents: read" \
  test "$(jq -c '.jobs.scripts.permissions // "none"' "$WFJ")" = '{"contents":"read"}'
verdict "the evaluate job holds no write permission" \
  test "$(jq -r '[.jobs.evaluate.permissions // {} | .[] | select(. == "write")] | length' "$WFJ")" = 0
verdict "the apply job checks nothing out (no uses: step)" \
  test "$(jq -r '[.jobs.apply.steps[] | select(has("uses"))] | length' "$WFJ")" = 0
# Every evaluator call in the plan-building job runs no script: `evaluate`
# only with supplied outcomes, `decide` only from evaluate records, and no
# `render-comment` or `lint` at all (both would evaluate the ledger).
ev_runs="$(jq -r '.jobs.evaluate.steps[] | .run // empty' "$WFJ" | tr -d '\\' | tr '\n' ' ' | sed 's/  */ /g')"
ev_calls="$(grep -oE 'bash "\$RUNNER_TEMP/issue-evidence\.sh" [a-z-]+[^|>]*' <<<"$ev_runs" || true)"
verdict "the evaluate job calls the evaluator" [ -n "$ev_calls" ]
bad_calls="$(grep -vE '^bash "\$RUNNER_TEMP/issue-evidence\.sh" (validate |candidates |evaluate .*--script-results |decide .*--evaluated )' <<<"$ev_calls" || true)"
verdict "every evaluator call in the evaluate job runs no script (validate, candidates, evaluate --script-results, decide --evaluated)" \
  [ -z "$bad_calls" ]
[ -z "$bad_calls" ] || printf '  offending: %s\n' "$bad_calls"

echo "=== (i) normal path ==="
run_workflow normal benign
verdict "no job failed" [ ! -s "$WORK/normal/failures" ]
[ ! -s "$WORK/normal/failures" ] || sed 's/^/  /' "$WORK/normal/failures"
verdict "the closes and reopens are the decided ones, in plan order" [ "$(actions_of normal)" = "$EXPECTED_ACTIONS" ]
[ "$(actions_of normal)" = "$EXPECTED_ACTIONS" ] || actions_of normal | sed 's/^/  got: /'
REF="$WORK/ref"
git clone -q "$WORK/normal/origin" "$REF"
printf '{"disposition":"landed","failed":[],"holds":true,"issue":1,"repo":"o/r","unevaluated":[]}\n' >"$WORK/ev1.jsonl"
want1="$(cd "$REF" && bash "$SRC/issue-evidence.sh" render-comment --issue 1 --action close --repo "$R" --evaluated "$WORK/ev1.jsonl" "$LEDGER_PATH")"
verdict "the close comment of #1 is what render-comment writes" [ "$(cat "$WORK/normal/gh/body-close-1.txt" 2>/dev/null)" = "$want1" ]
printf '{"disposition":"moot","failed":[0],"holds":false,"issue":4,"repo":"o/r","unevaluated":[]}\n' >"$WORK/ev4.jsonl"
want4="$(cd "$REF" && bash "$SRC/issue-evidence.sh" render-comment --issue 4 --action reopen --repo "$R" --evaluated "$WORK/ev4.jsonl" "$LEDGER_PATH")"
verdict "the regression reopen comment of #4 is what render-comment writes" [ "$(cat "$WORK/normal/gh/body-reopen-4.txt" 2>/dev/null)" = "$want4" ]
body5="$(cat "$WORK/normal/gh/body-reopen-5.txt" 2>/dev/null)"
verdict "the removed-row reopen of #5 says the row was removed" grep -qF "the row was removed" <<<"$body5"
verdict "... and carries the marker of the row it closed on" \
  [ "$(tail -n 1 <<<"$body5")" = "<!-- issue-evidence-bot: row-sha256=$(hash_of "$ROW5") -->" ]
verdict "no comment notifies anyone (@ is made inert)" [ -z "$(bodies_of normal | grep -E '@[a-z]' || true)" ]
echo "=== (iii) only the scripts job runs repository code ==="
verdict "the evidence scripts ran in the scripts job" [ -e "$WORK/normal/marks/scripts" ]
verdict "no evidence script ran in the evaluate job" [ ! -e "$WORK/normal/marks/evaluate" ]
verdict "no evidence script ran in the apply job" [ ! -e "$WORK/normal/marks/apply" ]

echo "=== (ii) a malicious evidence script ==="
run_workflow attack evil
verdict "the attack run acts on the same issues, in the same order, as the benign run" \
  [ "$(actions_of attack)" = "$(actions_of normal)" ]
[ "$(actions_of attack)" = "$(actions_of normal)" ] || actions_of attack | sed 's/^/  got: /'
verdict "... never on an issue with no row (#999)" [ -z "$(grep -E '^[a-z]+ 999 ' "$WORK/attack/gh/ACTIONS.log" || true)" ]
verdict "... and writes the same comments, byte for byte" [ "$(bodies_of attack)" = "$(bodies_of normal)" ]
verdict "... with no injected text" [ -z "$(bodies_of attack | grep -F PWNED || true)" ]

echo "=== (iv) the scripts job lying in its output ==="
if jq -e '.jobs.scripts' "$WFJ" >/dev/null; then
  # An invented record (a script check that does not exist) is refused by the
  # evaluate job: nothing is planned or applied.
  forge_invented() {
    local f="$RUN/needs/scripts/results"
    jq -c '. + [{blob: "0000000000000000000000000000000000000000", check: 0, issue: 999,
      outcome: "holds", path: "scripts/pass.sh", repo: "o/r"}]' "$f" >"$f.new" && mv "$f.new" "$f"
  }
  run_workflow invented benign forge_invented
  verdict "an invented script result is refused: the evaluate job fails" \
    [ "$(cat "$WORK/invented/needs/evaluate/RESULT")" = failure ]
  verdict "... and nothing is applied" [ -z "$(actions_of invented)" ]
  # A flipped outcome of a real script check is that check's bit: row 3 now
  # holds, so #3 is closed with the comment rendered from the ledger row.
  forge_flip() {
    local f="$RUN/needs/scripts/results"
    jq -c 'map(if .issue == 3 then .outcome = "holds" else . end)' "$f" >"$f.new" && mv "$f.new" "$f"
  }
  run_workflow flipped benign forge_flip
  verdict "a flipped bit closes the row that bit belongs to, and nothing else changes" \
    [ "$(actions_of flipped)" = "close 1 completed
close 2 not planned
close 3 completed
reopen 4
close 7 completed
reopen 5" ]
  printf '{"disposition":"landed","failed":[],"holds":true,"issue":3,"repo":"o/r","unevaluated":[]}\n' >"$WORK/ev3.jsonl"
  want3="$(cd "$REF" && bash "$SRC/issue-evidence.sh" render-comment --issue 3 --action close --repo "$R" --evaluated "$WORK/ev3.jsonl" "$LEDGER_PATH")"
  verdict "... with the comment rendered from the ledger row, not from the scripts job" \
    [ "$(sed "s/$(cat "$WORK/flipped/sha")/<commit>/g" "$WORK/flipped/gh/body-close-3.txt" 2>/dev/null)" = "${want3//$(cat "$WORK/normal/sha")/<commit>}" ]
else
  ko "(iv) not run: the workflow has no scripts job"
fi

if [ -z "${IEW_NEGATIVE_CONTROL:-}" ]; then
  echo "=== negative control: a plan-building job that runs the scripts again ==="
  MUT="$WORK/mutant.yml"
  # The mutant drops the supplied outcomes, so `evaluate` runs every script
  # inside the job that builds the plan.
  yq '(.jobs.evaluate.steps[] | select(.run != null) | .run) |= sub(" --script-results \"\$RUNNER_TEMP/script-results.jsonl\""; "")' "$WF" >"$MUT"
  if cmp -s <(yq . "$WF") "$MUT"; then
    ko "negative control: the mutation did not apply (the step text changed?)"
  else
    nc_rc=0
    nc_out="$(IEW_REUSABLE="$MUT" IEW_NEGATIVE_CONTROL=1 bash "$SCRIPT_DIR/$(basename "$0")" 2>&1)" || nc_rc=$?
    nc_fail="$(printf '%s\n' "$nc_out" | grep -c '^FAIL:' || true)"
    if [ "$nc_rc" -ne 0 ] && [ "$nc_fail" -gt 0 ]; then
      ok "negative control: the mutant fails the harness ($nc_fail failures, exit $nc_rc)"
    else
      ko "negative control: the harness passed a workflow that runs scripts while building the plan (exit $nc_rc)"
    fi
  fi
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
