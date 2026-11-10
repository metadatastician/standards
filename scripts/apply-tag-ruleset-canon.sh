#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# apply-tag-ruleset-canon.sh — converge every non-archived estate repository on
# the canonical immutable-tags ruleset (config/rulesets/immutable-tags.json).
#
# WHY THIS EXISTS
#   On 2026-09-11 a deployment wave wrote a tag ruleset carrying a `creation`
#   rule with ZERO bypass actors onto 372 repositories, which makes it
#   impossible to create ANY tag in those repositories. The damage persisted
#   because no committed script in this repository globs config/rulesets/ — so
#   nothing ever re-converged the estate. A one-shot sweep would have cured the
#   data and left that root cause intact. This applier IS the cure: it is the
#   invariant, not the repair.
#
# IDENTITY — READ BEFORE EDITING
#   Per config/README.adoc: "Identity is the target, never the name ... an
#   existing ruleset is PUT by id and keeps whatever name it has." A tag ruleset
#   is therefore identified as: target == "tag" AND
#   conditions.ref_name.include == ["~ALL"] exactly. The `name` field is NEVER
#   used to classify, and is sent ONLY on a POST that creates a new ruleset —
#   sending it on a PUT would silently rename the ruleset. Measured 2026-09-15:
#   372 repos named `Immutable-Tags` were BLOCKED, 26 with that SAME name were
#   not, 2 named `Immutable Tags` were healthy. The name is noise.
#
# RULESETS ARE ADDITIVE
#   Bypass is per-ruleset. A repository holding a healthy ruleset AND a
#   zero-bypass rival still refuses every tag (proven on awesome-gleam and
#   awesome-zig, which each hold two and both return HTTP 422). So "this repo
#   already has a good ruleset" is never grounds to skip it, and a duplicate
#   must be reconciled by DELETING the rival, not by correcting one of them.
#   config/README.adoc: "Exactly one such ruleset must exist; zero or two is a
#   verifier failure." Duplicates therefore FAIL CLOSED here and are reported;
#   deletion happens only under the explicit --reconcile-duplicates flag.
#
# Inputs (environment):
#   GH_TOKEN                 required. Must hold administration:write on every
#                            target repository. GITHUB_TOKEN from a workflow is
#                            repo-scoped and WILL NOT DO.
#   CANON_FILE               optional. Default config/rulesets/immutable-tags.json
#   ESTATE_ORGS              optional. Space-separated orgs to union in.
#                            Default "metadatastician" when UNSET. Set but
#                            empty means NO orgs: the hyperpolymath step of
#                            tag-ruleset-canon.yml sets it to '' because its
#                            App token cannot write metadatastician repos.
#
# Inputs (flags):
#   --apply                  perform writes. WITHOUT IT THIS SCRIPT ONLY REPORTS.
#   --limit N                process at most N repositories (pilot runs).
#   --repo OWNER/NAME        process exactly one repository (repeatable).
#   --reconcile-duplicates   delete zero-bypass rival tag rulesets where a
#                            healthy sibling exists. Off by default.
#   --revive-disabled        allow a PUT to a ruleset whose enforcement is
#                            `disabled`, which RE-ENABLES it. Off by default:
#                            disabled is a deliberate human act, not drift.
#   --no-verify              skip the real-tag-ref verification probe.
#   --skip-user              do not enumerate the credential's own repositories
#                            (user/repos, or installation/repositories under an
#                            App token); use only ESTATE_ORGS.
#                            An App installation token is scoped to ONE owner, so
#                            covering a user and an org needs one run per
#                            credential. This flag makes that composable.
#
# Outputs:
#   A TSV report on stdout: repo <TAB> state <TAB> detail
#   A one-line-per-class summary on stderr.
#
# Exit codes:
#   0  every target repository is CONVERGED (and verified, unless --no-verify)
#   2  drift remains, or one or more repositories FAILED
#   3  credential is absent or lacks administration:write (fails BEFORE any
#      sweep, so a missing secret can never present as a clean run)
#   4  a target repository needs a bypass actor whose GitHub App is not
#      installed on that owner. This is LOUD ON PURPOSE: falling back to an
#      admin-only body would re-create the two-variant canon this estate has
#      explicitly rejected.
#
# Dependencies: bash 4+, gh (authenticated), jq.
#
set -euo pipefail

CANON_FILE="${CANON_FILE:-config/rulesets/immutable-tags.json}"
ESTATE_ORGS="${ESTATE_ORGS-metadatastician}"   # no colon: an explicit '' means no orgs
APPLY=0 RECONCILE=0 VERIFY=1 LIMIT=0 SKIP_USER=0 REVIVE_DISABLED=0
declare -a ONLY_REPOS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)                APPLY=1 ;;
    --reconcile-duplicates) RECONCILE=1 ;;
    --revive-disabled)      REVIVE_DISABLED=1 ;;
    --no-verify)            VERIFY=0 ;;
    --skip-user)            SKIP_USER=0; SKIP_USER=1 ;;
    --limit)                LIMIT="${2:?--limit needs a number}"; shift ;;
    --repo)                 ONLY_REPOS+=("${2:?--repo needs OWNER/NAME}"); shift ;;
    -h|--help)              sed -n '2,70p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 64 ;;
  esac
  shift
done

die()  { echo "FATAL: $*" >&2; exit 2; }
note() { echo "[canon] $*" >&2; }

command -v gh >/dev/null || die "gh not on PATH"
command -v jq >/dev/null || die "jq not on PATH"
[ -f "$CANON_FILE" ] || die "canon file not found: $CANON_FILE (run from the repo root)"

# ---------------------------------------------------------------------------
# The canonical body. Read from the file so this script can never drift from
# the declared canon — the file is the single source of truth, not this script.
# ---------------------------------------------------------------------------
jq -e '.target == "tag"' "$CANON_FILE" >/dev/null \
  || die "$CANON_FILE is not a tag ruleset"
jq -e '.conditions.ref_name.include == ["~ALL"]' "$CANON_FILE" >/dev/null \
  || die "$CANON_FILE does not target ~ALL; the identity rule would not match it"
jq -e '[.rules[].type] | index("creation")' "$CANON_FILE" >/dev/null \
  || die "$CANON_FILE has no creation rule; it cannot be the immutable-tags canon"
jq -e '(.bypass_actors | length) >= 1' "$CANON_FILE" >/dev/null \
  || die "$CANON_FILE has ZERO bypass actors — that is the defect, not the cure"

CANON_POST=$(jq -c '.' "$CANON_FILE")
# A PUT body omits `name`: an existing ruleset keeps whatever name it has.
CANON_PUT=$(jq -c 'del(.name)' "$CANON_FILE")
# The canonical actor set, as a sorted comparable key.
CANON_ACTORS=$(jq -r '[.bypass_actors[] | "\(.actor_type):\(.actor_id)"] | sort | join(",")' "$CANON_FILE")
CANON_RULES=$(jq -r '[.rules[].type] | sort | join(",")' "$CANON_FILE")
note "canon: actors=[$CANON_ACTORS] rules=[$CANON_RULES]"

# ---------------------------------------------------------------------------
# CREDENTIAL GATE. A nonexistent secret resolves to an empty string and a loop
# over it succeeds at nothing while reporting green. So: prove the credential
# can WRITE a ruleset before enumerating anything. `gh api rate_limit` is not a
# write-readiness probe and neither is any read.
# ---------------------------------------------------------------------------
# Accept EITHER an explicit token (how CI supplies the App mint) OR an already
# authenticated gh CLI (how an operator runs it by hand; the credential lives in
# ~/.config/gh/hosts.yml, never in the environment). Requiring GH_TOKEN alone
# made this script unrunnable outside a workflow, which is how an applier ends
# up never being run at all. Requiring NEITHER is the defect: an absent secret
# resolves to an empty string in silence and the sweep writes nothing while
# reporting success.
# A credential probe must answer the question its CONSUMER asks -- "can I make
# authenticated API calls?" -- and `gh auth status` does NOT. MEASURED 2026-09-15
# 03:09Z: while this account was merely RATE-LIMITED, `gh auth status` reported
#   "X Failed to log in ... The token in ~/.config/gh/hosts.yml is invalid."
# and told the operator to re-authenticate. The token was perfectly valid. Trusting
# that verdict makes this script abort with a FATAL that is FALSE, and sends the
# operator to `gh auth login`, destroying a working credential to cure a condition
# that clears itself on the next reset. (`gh api rate_limit` is no help either: it
# is exempt from the limit and answered remaining=4999 while every other read 403'd.)
# So classify the probe THREE ways, on the response body, never on gh's own verdict:
#   authenticated / rate-limited-but-authenticated / genuinely-uncredentialled.
INSTALLATION=0
if [ -n "${GH_TOKEN:-}" ]; then
  note "credential: GH_TOKEN from the environment"
  # An App installation token (GitHub prefix ghs_) belongs to ONE installation,
  # on ONE owner. It cannot call user/repos at all: that endpoint needs a user
  # identity, and an installation has none. It also cannot write any repo
  # outside its installation. The workflow mints one such token per owner, so
  # both the target list and the write probe below must come from the
  # installation itself, never from a user endpoint or a fixed repo name.
  case "$GH_TOKEN" in
    ghs_*) INSTALLATION=1
           note "credential: an App installation token; targets come from installation/repositories" ;;
  esac
else
  cred_probe=$(gh api user --jq '.login' 2>&1) || cred_probe_failed=1
  if [ "${cred_probe_failed:-0}" -eq 0 ] && [ -n "$cred_probe" ]; then
    note "credential: the authenticated gh CLI as '$cred_probe' (no GH_TOKEN in the environment)"
  elif printf '%s' "$cred_probe" | grep -qi 'rate limit exceeded'; then
    reset_at=$(gh api rate_limit --jq '.resources.core.reset|todate' 2>/dev/null || echo "unknown")
    cat >&2 <<RATE
FATAL: the credential is VALID but this account's API rate limit is EXHAUSTED.
Refusing to start: a sweep run now would book hundreds of repos as FAILED purely
because their reads 403'd, and that report would be indistinguishable from real
drift. Retry after the limit resets at: $reset_at
DO NOT run 'gh auth login' for this. The token is fine -- note that 'gh auth
status' MISREPORTS a rate-limited account as holding an invalid token, and
re-authenticating would throw away a working credential for no reason.
RATE
    exit 5
  else
    cat >&2 <<'NOCRED'
FATAL: no credential. Rulesets need administration:write on every target repo.
Neither GH_TOKEN is set nor is the gh CLI authenticated. A workflow GITHUB_TOKEN
is repo-scoped and cannot write rulesets at all. Refusing to run a sweep that
would silently write nothing.
  in CI    : supply GH_TOKEN from actions/create-github-app-token
  by hand  : gh auth login --insecure-storage
NOCRED
    exit 3
  fi
fi

probe_repo="${GITHUB_REPOSITORY:-metadatastician/standards}"
probe_body=$(mktemp); probe_out=$(mktemp); api_err=$(mktemp); inst_file=$(mktemp)
trap 'rm -f "$probe_body" "$probe_out" "$api_err" "$inst_file"' EXIT

inst_listed=0

# list_installation_repos — fill $inst_file with the non-archived full_names the
# App installation behind GH_TOKEN can reach, one per line; die if GitHub will
# not list them. Runs at most once: the write probe and the target enumeration
# both need the same set. Call it in the main shell, never inside $(...), or
# the once-only flag is lost with the subshell.
list_installation_repos() {
  [ "$inst_listed" -eq 1 ] && return 0
  gh api --paginate 'installation/repositories?per_page=100' \
    --jq '.repositories[] | select(.archived | not) | .full_name' > "$inst_file" \
    || die "could not list installation/repositories with the App token; the installation's repos are NOT examined"
  inst_listed=1
}

# tag_ruleset_id <repo> — echo the id of the first REPOSITORY-level tag ruleset
# on <repo>, or nothing. An org-inherited ruleset is listed here too, but it is
# written at /orgs/{org}/rulesets/{id}; a per-repo PUT of it 404s (#1032), and
# the probe would then report a capable credential as unable to write.
tag_ruleset_id() {
  gh api "repos/$1/rulesets" --paginate 2>/dev/null \
    | jq -r '.[]? | select(type == "object" and .target == "tag" and .source_type == "Repository") | .id' 2>/dev/null \
    | head -1 || true
}

# Idempotent self-write: PUT this repository's own matching tag ruleset back
# with the bytes it already has. Succeeds iff the credential holds
# administration:write, and changes nothing if it does.
# The probe is itself a write, so it runs only when we intend to write. A dry
# run must not mutate anything -- including harmlessly.
if [ "$APPLY" -eq 0 ]; then
  note "DRY RUN: skipping the write-capability probe; administration:write is UNVERIFIED in this run"
  probe_id=""
else
# An installation token can write only its own installation's repos. When the
# workflow's own repo (GITHUB_REPOSITORY) belongs to another owner, a self-PUT
# there is refused whatever the credential holds, and the run would stop on a
# false "cannot WRITE rulesets". So probe one of the installation's own repos.
if [ "$INSTALLATION" -eq 1 ]; then
  list_installation_repos
  if ! grep -qxF -- "$probe_repo" "$inst_file"; then
    note "probe: $probe_repo is outside this installation; probing one of the installation's own repos"
    probe_repo=""
    while read -r cand; do
      [ -n "$cand" ] || continue
      if [ -n "$(tag_ruleset_id "$cand")" ]; then probe_repo="$cand"; break; fi
    done < "$inst_file"
  fi
fi
probe_id=""
[ -z "$probe_repo" ] || probe_id=$(tag_ruleset_id "$probe_repo")
if [ -n "$probe_id" ] && [ "$probe_id" != "null" ]; then
  if ! gh api "repos/$probe_repo/rulesets/$probe_id" > "$probe_body" 2>"$probe_out"; then
    echo "FATAL: cannot even READ $probe_repo ruleset $probe_id:" >&2
    cat "$probe_out" >&2; exit 3
  fi
  jq -c '{enforcement, conditions, bypass_actors: [.bypass_actors[] | {actor_id, actor_type, bypass_mode}], rules: [.rules[] | {type}]}' \
    "$probe_body" > "$probe_body.put"
  if ! gh api --method PUT "repos/$probe_repo/rulesets/$probe_id" \
        --input "$probe_body.put" > /dev/null 2>"$probe_out"; then
    echo "FATAL: credential cannot WRITE rulesets. The probe was an idempotent self-PUT of $probe_repo ruleset $probe_id and GitHub refused it:" >&2
    sed 's/^/    /' "$probe_out" >&2
    echo "  Fix: supply a credential with administration:write (a GitHub App installation token, or a PAT with the repo administration scope). Not GITHUB_TOKEN." >&2
    rm -f "$probe_body.put"; exit 3
  fi
  rm -f "$probe_body.put"
  note "credential probe OK — administration:write confirmed by an idempotent self-PUT"
else
  note "WARNING: ${probe_repo:-no repo in this installation} has no repo-level tag ruleset to probe with; write capability is UNPROVEN"
fi
fi

# ---------------------------------------------------------------------------
# TARGET ENUMERATION. `users/{u}/repos` omits private repos and
# `user/repos?affiliation=owner` returns NO organisation repos — metadatastician
# is an ORGANISATION, not a second user. A census from either endpoint alone is
# silently single-owner and looks healthy. Union both, then print the count.
# The listing returns canonical full_names, which also sidesteps the trap that
# `gh api` follows a renamed repo's 307 on GET but NOT on PUT/POST/DELETE.
# ---------------------------------------------------------------------------
repos_file=$(mktemp); : > "$repos_file"
if [ "${#ONLY_REPOS[@]}" -gt 0 ]; then
  printf '%s\n' "${ONLY_REPOS[@]}" > "$repos_file"
  note "explicit target list: ${#ONLY_REPOS[@]} repo(s)"
else
  own_src="user/repos"
  if [ "$SKIP_USER" -eq 0 ]; then
    if [ "$INSTALLATION" -eq 1 ]; then
      own_src="installation/repositories"
      list_installation_repos
      cat "$inst_file" >> "$repos_file"
    else
      gh api --paginate 'user/repos?affiliation=owner&per_page=100' \
        --jq '.[] | select(.archived == false) | .full_name' >> "$repos_file" \
        || die "could not list user/repos; the owner's repos are NOT examined"
    fi
  fi
  n_user=$(wc -l < "$repos_file")
  for org in $ESTATE_ORGS; do
    gh api --paginate "orgs/$org/repos?per_page=100" \
      --jq '.[] | select(.archived == false) | .full_name' >> "$repos_file" || \
      note "WARNING: could not list org $org"
  done
  sort -u -o "$repos_file" "$repos_file"
  note "targets: $n_user from $own_src + orgs($ESTATE_ORGS) = $(wc -l < "$repos_file") unique non-archived repos"
fi
[ -s "$repos_file" ] || die "target list is EMPTY — refusing to report a clean sweep over nothing"
if [ "$LIMIT" -gt 0 ]; then
  head -n "$LIMIT" "$repos_file" > "$repos_file.lim" && mv "$repos_file.lim" "$repos_file"
  note "pilot: limited to $(wc -l < "$repos_file") repos"
fi
[ "$APPLY" -eq 1 ] || note "DRY RUN — reporting only. Pass --apply to write."

declare -A COUNT=()
declare -a CHANGED=()
rc=0 app_missing=0 consecutive_403=0
report() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}"; COUNT[$2]=$(( ${COUNT[$2]:-0} + 1 )); }

# Verify by creating a REAL tag ref, then deleting it. A tag OBJECT posts fine
# even while creation is blocked; only the REF is refused, with a bare
# "422 Reference update failed" naming no rule. So the ref is the only honest
# score — never the ruleset read-back, never the name.
verify_tag_ref() {
  local repo="$1" probe="zz-canon-verify-$$-$RANDOM" sha out
  sha=$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null) || return 2
  sha=$(gh api "repos/$repo/commits/$sha" --jq '.sha' 2>/dev/null) || return 2
  out=$(gh api --method POST "repos/$repo/git/refs" \
          -f "ref=refs/tags/$probe" -f "sha=$sha" 2>&1) || {
    echo "$out" | head -1; return 1; }
  gh api --method DELETE "repos/$repo/git/refs/tags/$probe" >/dev/null 2>&1 || \
    note "WARNING: created verification tag $probe on $repo but could not delete it"
  return 0
}

while read -r repo; do
  [ -n "$repo" ] || continue
  # A list failure has TWO causes with OPPOSITE dispositions, and conflating them
  # makes this whole report untrustworthy. A free-plan owner's PRIVATE repo answers
  #   403 {"message":"Upgrade to GitHub Pro or make this repository public ..."}
  # even when permissions.admin is true. MEASURED 2026-09-15 over all 51 private
  # repos in the estate: 46/46 hyperpolymath -> 200, 5/5 metadatastician -> 403,
  # cause confirmed from the org itself (orgs/metadatastician .plan.name == "free").
  # The boundary is the OWNER'S PLAN, not the repository, so permissions.admin is
  # NOT a predictor. It is a PLAN CEILING, not a fault: no credential, no App
  # installation and no retry can lift it -- only a paid plan or making the repo
  # public. Reporting it as FAILED with rc=2 would leave the weekly workflow
  # PERMANENTLY red after every other repo converged, and a fail-loud signal that
  # can never go quiet is indistinguishable from noise inside a month. So it gets
  # its own terminal state, it is counted, and it does NOT move rc.
  if ! rs=$(gh api "repos/$repo/rulesets?per_page=100" --paginate 2>"$api_err"); then
    if grep -q 'Upgrade to GitHub Pro' "$api_err"; then
      report "$repo" "PLAN-EXCLUDED" \
        "rulesets are unavailable on a private repo of a free-plan owner; not a fault and not retryable"
    else
      report "$repo" "FAILED" \
        "cannot list rulesets: $(tr '\n' ' ' < "$api_err" | head -c 160)"
      rc=2
    fi
    continue
  fi

  # FAIL CLOSED ON ABSENT DISCRIMINATOR (#1032). A ruleset summary with no
  # `.source_type` cannot be classified as repo-level or org-inherited;
  # defaulting it into the writable arm would send a PUT that 404s.
  if printf '%s' "$rs" | jq -e 'any(.[]?; has("source_type") | not)' >/dev/null 2>&1; then
    report "$repo" "REFUSED-NO-SOURCE-TYPE" \
      "a ruleset carried no .source_type; cannot tell repo-level from org-inherited, failing closed"
    rc=2
    continue
  fi

  # Partition by .source_type BEFORE choosing a write target (#1032).
  # An org-inherited ruleset (source_type == "Organization") is returned by both
  # `GET /repos/{o}/{r}/rulesets` and `GET /repos/{o}/{r}/rulesets/{id}`, so the
  # READ path succeeds; only `PUT /repos/{o}/{r}/rulesets/{id}` 404s, because its
  # write endpoint is `/orgs/{org}/rulesets/{id}`. Never select an org ruleset
  # as a per-repo PUT candidate.
  org_tag_count=$(printf '%s' "$rs" | jq '[.[]? | select(.source_type=="Organization" and .target=="tag" and .enforcement=="active")] | length')

  # MUST be two-step. DO NOT "optimise" this into a single filtered list call.
  # The rulesets LIST endpoint returns a summary that omits `conditions`,
  # `rules` and `bypass_actors` entirely, so filtering the list on .conditions
  # matches NOTHING -- measured 0 of 178 live repos on 2026-09-09 -- which
  # silently turns every PUT into a POST and recreates the very duplicate-ruleset
  # outage this selector exists to prevent. Only GET .../rulesets/{id} carries
  # the shape. (Same finding as git-scripts PR #58.)
  ids=$(printf '%s' "$rs" | jq -r '.[] | select(.source_type=="Repository" and .target=="tag") | .id')
  matching=()
  for id in $ids; do
    d=$(gh api "repos/$repo/rulesets/$id" 2>/dev/null) || continue
    if printf '%s' "$d" | jq -e '.conditions.ref_name.include == ["~ALL"]' >/dev/null 2>&1; then
      matching+=("$id|$(printf '%s' "$d" | jq -c '{id,name,enforcement,
        actors: ([.bypass_actors[]? | "\(.actor_type):\(.actor_id)"] | sort | join(",")),
        nbypass: ([.bypass_actors[]?] | length),
        rules: ([.rules[].type] | sort | join(","))}')")
    fi
  done

  case "${#matching[@]}" in
  0)
    if [ "$org_tag_count" -gt 0 ]; then
      report "$repo" "ORG-INHERITED" \
        "$org_tag_count active org tag ruleset(s); cure at /orgs/{org}/rulesets/{id}, never per repo (#1032)"
      continue
    fi
    # No ruleset matches the identity rule: POST a fresh one. `name` IS sent here.
    if [ "$APPLY" -eq 0 ]; then report "$repo" "WOULD-CREATE" "no ~ALL tag ruleset"; rc=2; continue; fi
    out=$(printf '%s' "$CANON_POST" | gh api --method POST "repos/$repo/rulesets" --input - 2>&1) || {
      if printf '%s' "$out" | grep -q 'must be part of the ruleset source or owner organization'; then
        report "$repo" "FAILED-APP-NOT-INSTALLED" "$(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
        app_missing=1; rc=2; continue
      fi
      printf '%s' "$out" | grep -q '403' && consecutive_403=$((consecutive_403+1)) || consecutive_403=0
      report "$repo" "FAILED" "POST: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"; rc=2; continue
    }
    consecutive_403=0
    CHANGED+=("$repo"); report "$repo" "CREATED" "posted canon"
    ;;
  1)
    IFS='|' read -r id meta <<< "${matching[0]}"
    actors=$(printf '%s' "$meta" | jq -r '.actors')
    nbypass=$(printf '%s' "$meta" | jq -r '.nbypass')
    rules=$(printf '%s' "$meta" | jq -r '.rules')
    enf=$(printf '%s' "$meta" | jq -r '.enforcement')

    if [ "$actors" = "$CANON_ACTORS" ] && [ "$rules" = "$CANON_RULES" ] && [ "$enf" = "active" ]; then
      report "$repo" "CONVERGED" "id=$id"
      continue
    fi

    # DISABLED IS A DECISION, NOT DRIFT.
    # The identity rule is target+conditions; it deliberately ignores `name`,
    # and it also does not look at enforcement -- so a ruleset somebody
    # switched OFF still matches, and the canon body carries
    # "enforcement": "active". Without this guard the next scheduled run
    # silently switches it back on, and the only trace is a new version in
    # rulesets/{id}/history that nobody reads. That is not hypothetical: 375
    # branch rulesets across this estate were disabled on purpose on
    # 2026-09-22, and a tag-side applier with this shape would have undone the
    # equivalent decision without ever reporting that it had.
    # Repairing the SHAPE of a disabled ruleset is fine in principle; flipping
    # the ENFORCEMENT field is an owner decision, so it takes an explicit flag.
    if [ "$enf" != "active" ] && [ "$REVIVE_DISABLED" -eq 0 ]; then
      report "$repo" "DISABLED-NOT-REVIVED" "id=$id enforcement=$enf; the canon body would set it back to active. Pass --revive-disabled if that is intended."
      rc=2; continue
    fi
    # A PUT REPLACES bypass_actors. Where a repo carries MORE actors than canon,
    # flattening it would silently revoke bypass from apps we did not audit —
    # deed-ecosystem holds 12, nine of them Integrations. Report, never flatten.
    extra=$(printf '%s\n%s\n' "${actors//,/$'\n'}" "${CANON_ACTORS//,/$'\n'}" | sort | uniq -u)
    only_extra=1
    for a in ${CANON_ACTORS//,/ }; do
      printf '%s' ",$actors," | grep -q ",$a," || only_extra=0
    done
    if [ "$only_extra" -eq 1 ] && [ "$nbypass" -gt "$(printf '%s' "$CANON_ACTORS" | tr ',' '\n' | wc -l)" ]; then
      report "$repo" "SKIP-BYPASS-SUPERSET" "id=$id has $nbypass actors incl. all canon; a PUT would strip $(printf '%s' "$extra" | wc -w). Owner decision."
      continue
    fi

    if [ "$APPLY" -eq 0 ]; then
      report "$repo" "WOULD-PUT" "id=$id bypass=$nbypass rules=[$rules]"; rc=2; continue
    fi
    out=$(printf '%s' "$CANON_PUT" | gh api --method PUT "repos/$repo/rulesets/$id" --input - 2>&1) || {
      if printf '%s' "$out" | grep -q 'must be part of the ruleset source or owner organization'; then
        report "$repo" "FAILED-APP-NOT-INSTALLED" "id=$id $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
        app_missing=1; rc=2; continue
      fi
      printf '%s' "$out" | grep -q '403' && consecutive_403=$((consecutive_403+1)) || consecutive_403=0
      report "$repo" "FAILED" "PUT id=$id: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"; rc=2; continue
    }
    consecutive_403=0
    CHANGED+=("$repo"); report "$repo" "REPAIRED" "id=$id"
    ;;
  *)
    # Two or more rulesets match the identity rule. Because rulesets are
    # ADDITIVE, the most restrictive one wins and a healthy sibling grants
    # nothing — so this is a real outage, not cosmetic drift. config/README.adoc
    # makes "two" a verifier failure, so the default is to FAIL CLOSED and
    # report rather than guess which one the estate meant to keep.
    detail=$(printf '%s\n' "${matching[@]}" | sed 's/|/ /' | tr '\n' ' ')
    if [ "$RECONCILE" -eq 0 ] || [ "$APPLY" -eq 0 ]; then
      report "$repo" "DUPLICATE-FAIL-CLOSED" "${#matching[@]} matching tag rulesets: $detail (pass --reconcile-duplicates to delete zero-bypass rivals)"
      rc=2; continue
    fi
    kept="" ; deleted=0 ; failed=0
    for m in "${matching[@]}"; do
      IFS='|' read -r id meta <<< "$m"
      nb=$(printf '%s' "$meta" | jq -r '.nbypass')
      if [ "$nb" -eq 0 ]; then
        if out=$(gh api --method DELETE "repos/$repo/rulesets/$id" 2>&1); then
          deleted=$((deleted+1))
        else
          failed=$((failed+1))
          note "  $repo: could not delete rival $id: $(printf '%s' "$out" | tr '\n' ' ' | head -c 160)"
        fi
      else
        kept="${kept:+$kept,}$id"
      fi
    done
    if [ -z "$kept" ]; then
      report "$repo" "DUPLICATE-FAIL-CLOSED" "every matching ruleset had zero bypass; refusing to delete them all and leave the repo unprotected"
      rc=2; continue
    fi
    [ "$failed" -eq 0 ] || rc=2
    # The survivor is not necessarily canon. On awesome-gleam the healthy
    # sibling carried only RepositoryRole:5 and no Integration actor, so
    # deleting the rival alone would leave the repo non-canonical. Converge the
    # survivor in the SAME pass rather than relying on a later run.
    surv_put_ok=1
    for sid in ${kept//,/ }; do
      if ! out=$(printf '%s' "$CANON_PUT" | gh api --method PUT "repos/$repo/rulesets/$sid" --input - 2>&1); then
        surv_put_ok=0; rc=2
        if printf '%s' "$out" | grep -q 'must be part of the ruleset source or owner organization'; then
          app_missing=1
        fi
        note "  $repo: deleted the rival but could not converge survivor $sid: $(printf '%s' "$out" | tr '\n' ' ' | head -c 160)"
      fi
    done
    CHANGED+=("$repo")
    if [ "$surv_put_ok" -eq 1 ]; then
      report "$repo" "RECONCILED" "deleted $deleted rival(s), converged survivor id=$kept"
    else
      report "$repo" "RECONCILED-PARTIAL" "deleted $deleted rival(s) but survivor id=$kept is NOT canon"
    fi
    ;;
  esac

  if [ "$consecutive_403" -ge 5 ]; then
    note "STOPPING: 5 consecutive 403s. Contiguous failures at the tail of a bulk loop are the secondary rate limit, which is INVISIBLE to gh api rate_limit. This script is idempotent — re-run it to finish."
    rc=2; break
  fi
done < "$repos_file"

# ---------------------------------------------------------------------------
# VERIFICATION on repos we actually changed, scored on a real tag ref.
# ---------------------------------------------------------------------------
if [ "$VERIFY" -eq 1 ] && [ "$APPLY" -eq 1 ] && [ "${#CHANGED[@]}" -gt 0 ]; then
  note "verifying ${#CHANGED[@]} changed repo(s) by creating a REAL tag ref..."
  for repo in "${CHANGED[@]}"; do
    vr=0; err=$(verify_tag_ref "$repo") || vr=$?
    case "$vr" in
      0) report "$repo" "VERIFIED" "created and deleted a real tag ref" ;;
      2) report "$repo" "VERIFY-SKIPPED" "could not resolve a default-branch commit to tag" ;;
      *) report "$repo" "VERIFY-FAILED" "ruleset written but a real tag ref is STILL refused: ${err:-no body}"
         rc=2 ;;
    esac
  done
elif [ "$VERIFY" -eq 0 ]; then
  note "verification SKIPPED by --no-verify: no repo in this run is scored on a real tag ref"
fi

if [ "${COUNT[PLAN-EXCLUDED]:-0}" -gt 0 ]; then
  cat >&2 <<PLAN

  ${COUNT[PLAN-EXCLUDED]} repo(s) are PLAN-EXCLUDED, NOT failed. Rulesets are a paid
  feature on a PRIVATE repository: a free-plan owner gets 403 "Upgrade to GitHub
  Pro or make this repository public" regardless of admin rights. These repos can
  NEVER converge on the current plan, so this run does not treat them as drift and
  does not fail because of them. To bring them to canon the OWNER must pick one of:
  upgrade the owning org/user plan, make the repo public, or transfer it to an
  owner on a paid plan. Until then they are a KNOWN, RECORDED exemption from canon.
PLAN
fi

echo "--- summary ---" >&2
for k in "${!COUNT[@]}"; do printf '  %5d  %s\n' "${COUNT[$k]}" "$k" >&2; done
rm -f "$repos_file"

if [ "$app_missing" -eq 1 ]; then
  cat >&2 <<'LOUD'

  ================================================================
  A bypass actor's GitHub App is NOT INSTALLED on a target owner.
  GitHub refused the canonical body with:
      "Actor <app> integration must be part of the ruleset source
       or owner organization"
  This script DELIBERATELY does not fall back to an admin-only
  body. Doing so would silently produce a second, weaker canon on
  those repositories -- the two-variant estate this owner has
  explicitly rejected. ONE body everywhere is the decision.
  ACTION REQUIRED BY THE OWNER: install the App on that owner.
  Nobody else can do it; an API token cannot install an App.
  ================================================================
LOUD
  exit 4
fi
exit "$rc"
