#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# sonar-s7637-sync.sh -- keep the SonarCloud S7637 exception in line with
# .github/workflows/actions.lock (docs/EXEMPTION-MECHANISMS.adoc, Layer 6).
#
# RULE
#   A project whose GitHub repository carries .github/workflows/actions.lock on
#   its default branch has this entry in `sonar.issue.ignore.multicriteria`:
#     ruleKey githubactions:S7637, resourceKey .github/workflows/**
#   A project whose repository has no actions.lock must not have it. Every other
#   entry in the setting is kept.
#
# USAGE
#   scripts/sonar-s7637-sync.sh                 dry run over every project
#   scripts/sonar-s7637-sync.sh --project KEY   dry run for one project
#   scripts/sonar-s7637-sync.sh --apply         write the adds and removes
#   (--apply and --project combine). Manual tool: run it on request.
#
# PROJECT TO REPOSITORY
#   Read from SonarCloud itself: api/navigation/component returns the project's
#   GitHub binding in `alm.url`. A project with no binding is skipped and
#   reported; the tool never guesses a repository from the project key.
#
# CREDENTIALS
#   SonarCloud: env SONAR_TOKEN, sent as a Bearer token (required for --apply).
#   GitHub: `gh` if installed, else env GITHUB_TOKEN.
#
# FAILS LOUDLY
#   A read error on any project is reported and the run exits 1. An error is
#   never treated as "no lock". `api/settings/set` replaces the whole list, so
#   every existing own entry is sent again. Removing the last entry uses
#   `api/settings/reset`. Exit 2 is a usage error.
set -uo pipefail

SONAR="${SONAR_URL:-https://sonarcloud.io}"
ORG="${SONAR_ORG:-hyperpolymath}"
GHAPI="${GITHUB_API_URL:-https://api.github.com}"
KEY=sonar.issue.ignore.multicriteria
RULE=githubactions:S7637
RES='.github/workflows/**'
LOCK=.github/workflows/actions.lock

APPLY=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --project) [ $# -ge 2 ] || { echo "--project needs a key" >&2; exit 2; }; ONLY="$2"; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
if [ "$APPLY" = 1 ] && [ -z "${SONAR_TOKEN:-}" ]; then
  echo "--apply needs SONAR_TOKEN" >&2; exit 2
fi

# Call SonarCloud: sq METHOD PATH [curl args]. Fails (non-zero) on any HTTP error.
sq() {
  local m="$1" p="$2"; shift 2
  local auth=(); [ -n "${SONAR_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $SONAR_TOKEN")
  curl -sSf -X "$m" "${auth[@]}" "$SONAR/$p" "$@"
}

# GET a GitHub API path. Prints the body. Returns 0 ok, 44 on HTTP 404, 1 on any other error.
gh_get() {
  local out rc
  if command -v gh >/dev/null 2>&1; then
    out="$(gh api "$1" 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then printf '%s' "$out"; return 0; fi
    case "$out" in *"HTTP 404"*|*"Not Found"*) return 44 ;; esac
    echo "$out" >&2; return 1
  fi
  [ -n "${GITHUB_TOKEN:-}" ] || { echo "no gh and no GITHUB_TOKEN" >&2; return 1; }
  local tmp code; tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' "$GHAPI/$1")" || { rm -f "$tmp"; return 1; }
  out="$(cat "$tmp")"; rm -f "$tmp"
  case "$code" in 200) printf '%s' "$out"; return 0 ;; 404) return 44 ;; *) echo "HTTP $code for $1" >&2; return 1 ;; esac
}

# Print "yes" or "no" for the lock on the repo's default branch. Non-zero on error.
has_lock() {
  local repo="$1" body branch rc
  body="$(gh_get "repos/$repo")" || return 1
  branch="$(jq -er '.default_branch' <<<"$body")" || return 1
  gh_get "repos/$repo/contents/$LOCK?ref=$branch" >/dev/null; rc=$?
  case $rc in 0) echo yes ;; 44) echo no ;; *) return 1 ;; esac
}

# Handle one project. Prints one report line. Returns 0 ok, 1 error.
one() {
  local p="$1" nav repo lock cur own has act n
  nav="$(sq GET "api/navigation/component?component=$p")" || { echo "$p ERROR read-binding"; return 1; }
  repo="$(jq -r '(.alm.url // "") | sub("^https://github.com/";"") | sub("\\.git$";"")' <<<"$nav")" || { echo "$p ERROR parse-binding"; return 1; }
  if [ -z "$repo" ] || [[ "$repo" == http* ]]; then echo "$p SKIP no-github-binding"; return 0; fi
  lock="$(has_lock "$repo")" || { echo "$p $repo ERROR read-lock"; return 1; }
  cur="$(sq GET "api/settings/values?component=$p&keys=$KEY")" || { echo "$p $repo ERROR read-setting"; return 1; }
  # Own entries only: an inherited setting cannot be changed from the project.
  own="$(jq -c --arg k "$KEY" '[.settings[]? | select(.key==$k and .inherited!=true) | .fieldValues[]?]' <<<"$cur")" || { echo "$p $repo ERROR parse-setting"; return 1; }
  has=no
  [ "$(jq --arg r "$RULE" --arg s "$RES" '[.[] | select(.ruleKey==$r and .resourceKey==$s)] | length' <<<"$own")" != 0 ] && has=yes
  act=none
  [ "$lock" = yes ] && [ "$has" = no ] && act=add
  [ "$lock" = no ] && [ "$has" = yes ] && act=remove
  if [ "$act" != none ] && [ "$APPLY" = 1 ]; then
    if [ "$act" = add ]; then
      own="$(jq -c --arg r "$RULE" --arg s "$RES" '. + [{ruleKey:$r,resourceKey:$s}]' <<<"$own")"
    else
      own="$(jq -c --arg r "$RULE" --arg s "$RES" 'map(select((.ruleKey==$r and .resourceKey==$s)|not))' <<<"$own")"
    fi
    n="$(jq length <<<"$own")"
    if [ "$n" = 0 ]; then
      sq POST api/settings/reset --data-urlencode "keys=$KEY" --data-urlencode "component=$p" >/dev/null \
        || { echo "$p $repo ERROR write-reset"; return 1; }
    else
      local args=()
      while IFS= read -r fv; do args+=(--data-urlencode "fieldValues=$fv"); done < <(jq -c '.[]' <<<"$own")
      sq POST api/settings/set --data-urlencode "component=$p" --data-urlencode "key=$KEY" "${args[@]}" >/dev/null \
        || { echo "$p $repo ERROR write-set"; return 1; }
    fi
    act="$act (applied)"
  fi
  echo "$p $repo lock=$lock entry=$has action=$act"
}

projects=()
if [ -n "$ONLY" ]; then
  projects=("$ONLY")
else
  page=1
  while :; do
    resp="$(sq GET "api/projects/search?organization=$ORG&ps=500&p=$page")" || { echo "ERROR listing projects" >&2; exit 1; }
    while IFS= read -r k; do projects+=("$k"); done < <(jq -r '.components[].key' <<<"$resp")
    total="$(jq -r '.paging.total' <<<"$resp")"
    [ "${#projects[@]}" -ge "$total" ] && break
    [ "$(jq '.components|length' <<<"$resp")" = 0 ] && break
    page=$((page+1))
  done
fi

[ "$APPLY" = 1 ] && echo "mode: APPLY" || echo "mode: dry run (no writes)"
errs=0
for p in "${projects[@]}"; do one "$p" || errs=$((errs+1)); done
echo "projects=${#projects[@]} errors=$errs"
[ "$errs" = 0 ]
