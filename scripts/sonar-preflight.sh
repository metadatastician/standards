#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# sonar-preflight.sh — say WHY a SonarCloud CI scan cannot run, before the
# scanner fails with a message that does not.
#
# WHY THIS EXISTS (measured 2026-11-17)
# -------------------------------------
# Two estate repositories had a red `SonarQube` check that looked alike and
# had nothing in common:
#
#   hyperpolymath/lithoglyph   SONAR_TOKEN empty on every run, main included,
#                              and sonar-project.properties names project
#                              `hyperpolymath_lithoglyph`, which does not
#                              exist: the repo's real project, analysed by
#                              Automatic Analysis, is `hyperpolymath_lithoglyphdb`.
#                              The scanner said: "Fail to load the list of
#                              plugins installed on the server: Not authorized
#                              or organization not found" (exit 3).
#   metadatastician/marid      SONAR_TOKEN present and REJECTED. The scanner
#                              said: "Failed to query JRE metadata ... HTTP 403
#                              Forbidden" (exit 1). The project still sits in
#                              the `hyperpolymath` organisation after the repo
#                              moved to `metadatastician`.
#
# Neither message names the cause, so each red reads as "SonarQube is flaky"
# and gets ignored. The template's answer was a presence guard that turns an
# empty token into a green skip, which hides the first case and cannot see the
# second. This script fails LOUDLY instead, with one named class per cause, and
# lets the scan run whenever the credentials are good.
#
# ONE TRAP, MEASURED: `api/authentication/validate` answers {"valid":true} to an
# ANONYMOUS request. A validity probe sent without a token passes. The empty
# token is therefore classified before any request is made.
#
# Classes (written to $GITHUB_OUTPUT as `class=`):
#
#   ok                    the scan may run; a scan failure after this is the
#                         scan's own (a finding, a quality gate, or a server
#                         refusal such as Automatic Analysis being enabled).
#   secrets-withheld      Dependabot or fork PR run: GitHub passes no Actions
#                         secrets. Not a repository fault. Exit 0, with a
#                         notice; the push run on the default branch scans.
#   token-absent          no SONAR_TOKEN reached the job.                 exit 1
#   token-rejected        SonarCloud says the token is not valid.         exit 1
#   organization-missing  sonar.organization does not exist.              exit 1
#   project-missing       sonar.projectKey does not exist.                exit 1
#   project-forbidden     valid token, but it cannot see the project.     exit 1
#   project-org-mismatch  the project lives in another organisation.      exit 1
#   config-missing        no organisation or project key configured.     exit 1
#   config-invalid        a key or organisation with illegal characters.  exit 1
#   server-unavailable    SonarCloud unreachable, 5xx or 429: a server or
#                         quota problem, not this repository's config.    exit 1
#
# Inputs (environment):
#   SONAR_TOKEN           the secret; may be empty.
#   SONAR_ORGANIZATION    overrides sonar.organization from the properties file.
#   SONAR_PROJECT_KEY     overrides sonar.projectKey from the properties file.
#   SONAR_HOST_URL        default https://sonarcloud.io
#   SONAR_PROPERTIES      default sonar-project.properties
#   GITHUB_ACTOR, GITHUB_EVENT_NAME, GITHUB_REPOSITORY, PR_HEAD_REPOSITORY
#                         to recognise runs that GitHub gives no secrets.
#
# The token never appears on a command line: it goes to curl in a header file
# with mode 600 that is removed on exit. Egress: only the SonarCloud host the
# scanner itself contacts.
#
# Usage: sonar-preflight.sh            (no arguments; reads the environment)
# Test:  scripts/tests/sonar-preflight-test.sh (stubbed curl, every class)

set -euo pipefail

HOST="${SONAR_HOST_URL:-https://sonarcloud.io}"
HOST="${HOST%/}"
PROPS="${SONAR_PROPERTIES:-sonar-project.properties}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
body="$work/body"
hdr="$work/auth-header"

# Last value of `key=value` (or `key: value`) in a Java properties file.
# Comment lines and surrounding blanks are ignored. Continuation lines are not
# supported: none of the estate's sonar-project.properties uses them for these
# two keys, and a key this script cannot read is reported, not guessed.
prop() {
  [ -f "$PROPS" ] || return 0
  awk -v k="$1" '
    /^[[:space:]]*[#!]/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, k) != 1) next
      rest = substr(line, length(k) + 1)
      if (rest !~ /^[[:space:]]*[=:]/) next
      sub(/^[[:space:]]*[=:][[:space:]]*/, "", rest)
      sub(/[[:space:]]+$/, "", rest)
      v = rest
    }
    END { if (v != "") print v }
  ' "$PROPS"
}

ORG="${SONAR_ORGANIZATION:-$(prop sonar.organization)}"
KEY="${SONAR_PROJECT_KEY:-$(prop sonar.projectKey)}"

finish() {
  local class="$1" exit_code="$2" detail="$3"
  echo "class=$class" >> "$OUT"
  {
    echo "### SonarQube preflight: \`$class\`"
    echo
    echo "| organisation | project key | host |"
    echo "|---|---|---|"
    echo "| \`${ORG:-?}\` | \`${KEY:-?}\` | $HOST |"
    echo
    echo "$detail"
  } >> "$SUMMARY"
  if [ "$exit_code" -eq 0 ] && [ "$class" = ok ]; then
    echo "SonarQube preflight: ok — $detail"
  elif [ "$exit_code" -eq 0 ]; then
    echo "::notice title=SonarQube preflight: $class::$detail"
  else
    echo "::error title=SonarQube preflight: $class::$detail"
  fi
  exit "$exit_code"
}

# GET $1 into $body; sets HTTP to the status code. A transport failure (DNS,
# TLS, timeout) is a server-side class, never a pass.
HTTP=000

# Print the string at jq path $1 of $body; fail (status, not exit) when the
# body is not JSON or the path is not a non-empty string. Callers decide the
# class: `x="$(field …)" || finish …`. It never calls finish itself, because
# inside $(…) that would exit only the subshell and the script would go on.
field() { jq -er "$1 | strings | select(length > 0)" "$body" 2>/dev/null; }

get() {
  local -a auth=()
  [ -s "$hdr" ] && auth=(--header "@$hdr")
  if ! HTTP="$(curl --silent --show-error --max-time 30 --proto '=https' \
        "${auth[@]}" --output "$body" --write-out '%{http_code}' "$1" 2>"$work/err")"; then
    finish server-unavailable 1 "Could not reach $HOST ($(head -c 200 "$work/err" | tr '\n' ' ')). This is a network or server problem, not this repository's configuration. Re-run later."
  fi
  case "$HTTP" in
    429|5??) finish server-unavailable 1 "$HOST answered HTTP $HTTP for $1. That is a server or quota problem, not this repository's configuration. Re-run later." ;;
  esac
}

# --- configuration ------------------------------------------------------------
if [ -z "$ORG" ] || [ -z "$KEY" ]; then
  finish config-missing 1 "No SonarCloud organisation or project key. Set sonar.organization and sonar.projectKey in $PROPS, or pass the organization and project-key inputs."
fi
# Keys and organisations are [A-Za-z0-9_.:-]; anything else would also reach
# the URL unescaped, so it is refused rather than encoded.
if printf '%s\n%s\n' "$ORG" "$KEY" | grep -Eq '[^A-Za-z0-9_.:-]'; then
  finish config-invalid 1 "Organisation '$ORG' or project key '$KEY' contains characters SonarCloud does not allow ([A-Za-z0-9_.:-])."
fi

# --- token: classify the EMPTY case before any request (see the trap above) ---
if [ -z "${SONAR_TOKEN:-}" ]; then
  is_pr=false
  case "${GITHUB_EVENT_NAME:-}" in pull_request|pull_request_review|pull_request_review_comment) is_pr=true ;; esac
  if [ "${GITHUB_ACTOR:-}" = "dependabot[bot]" ] \
     || { $is_pr && [ -n "${PR_HEAD_REPOSITORY:-}" ] && [ "${PR_HEAD_REPOSITORY}" != "${GITHUB_REPOSITORY:-}" ]; }; then
    finish secrets-withheld 0 "GitHub gives no Actions secrets to Dependabot or fork pull-request runs, so this run cannot scan. That is not a repository fault. The push run on the default branch scans."
  fi
  finish token-absent 1 "No SONAR_TOKEN reached this job. Add a SONAR_TOKEN Actions secret (repository or organisation) and pass it explicitly: \`secrets: { SONAR_TOKEN: \${{ secrets.SONAR_TOKEN }} }\`."
fi
( umask 077; printf 'Authorization: Bearer %s\n' "$SONAR_TOKEN" > "$hdr" )

# --- token validity -----------------------------------------------------------
get "$HOST/api/authentication/validate"
# Not `.valid // empty`: jq's `//` treats `false` as absent, which turned the
# one answer this probe exists for (valid=false) into "no answer".
valid="$(jq -r 'if type == "object" and has("valid") then .valid | tostring else empty end' "$body" 2>/dev/null || true)"
if [ "$HTTP" = 401 ] || [ "$HTTP" = 403 ] || [ "$valid" = false ]; then
  finish token-rejected 1 "SonarCloud rejected SONAR_TOKEN (HTTP $HTTP, valid=${valid:-?}): it is revoked, expired or mistyped. Generate a new token in SonarCloud and replace the secret."
fi
if [ "$HTTP" != 200 ] || [ "$valid" != true ]; then
  finish server-unavailable 1 "Unexpected answer from $HOST/api/authentication/validate (HTTP $HTTP). Treated as a server problem; re-run, and report it if it persists."
fi

# --- organisation -------------------------------------------------------------
get "$HOST/api/organizations/search?organizations=$ORG"
if [ "$HTTP" != 200 ]; then
  finish server-unavailable 1 "Unexpected answer from organizations/search (HTTP $HTTP)."
fi
org_keys="$(jq -er '.organizations | arrays | map(.key) | join(" ")' "$body" 2>/dev/null)" \
  || finish server-unavailable 1 "organizations/search answered HTTP 200 without an organizations list (not JSON, or no .organizations). Treated as a server problem; re-run, and report it if it persists."
if ! printf ' %s ' "$org_keys" | grep -qF " $ORG "; then
  finish organization-missing 1 "SonarCloud has no organisation '$ORG'. Fix sonar.organization. If the repository moved between GitHub organisations, its SonarCloud project did not move with it."
fi

# --- project ------------------------------------------------------------------
get "$HOST/api/components/show?component=$KEY"
case "$HTTP" in
  200) ;;
  404) finish project-missing 1 "SonarCloud has no project '$KEY' (organisation '$ORG'). Create it in SonarCloud, or fix sonar.projectKey." ;;
  401|403) finish project-forbidden 1 "The token is valid but cannot see project '$KEY'. The token's account has no access to it, for example because the project stayed in another organisation after a repository transfer." ;;
  *) finish server-unavailable 1 "Unexpected answer from components/show (HTTP $HTTP)." ;;
esac
# Require one project response before reading project and organisation metadata.
if ! jq -e -s '
  length == 1 and (.[0] |
    type == "object" and (.component | type == "object") and
    (.component.key | type == "string" and length > 0))
' "$body" >/dev/null 2>&1; then
  finish server-unavailable 1 "Unexpected project response from components/show (HTTP $HTTP): invalid JSON or missing project structure. Re-run, and report it if it persists."
fi
# A 200 is evidence only if the body says which project and organisation it
# describes; `{}` or a non-JSON page must not read as "the project exists".
shown_key="$(field '.component.key')" \
  || finish server-unavailable 1 "components/show answered HTTP 200 without a project key (not JSON, or no .component.key). Treated as a server problem; re-run, and report it if it persists."
[ "$shown_key" = "$KEY" ] \
  || finish server-unavailable 1 "components/show answered for project '$shown_key', not '$KEY'. Treated as a server problem; re-run, and report it if it persists."
actual="$(field '.component.organization')" \
  || finish server-unavailable 1 "components/show answered HTTP 200 without the project's organisation. Treated as a server problem; re-run, and report it if it persists."
if [ "$actual" != "$ORG" ]; then
  finish project-org-mismatch 1 "Project '$KEY' belongs to organisation '$actual', but the configuration says '$ORG'. Move the project, or fix sonar.organization and sonar.projectKey together."
fi

finish ok 0 "token valid, organisation '$ORG' and project '$KEY' exist and are visible to the token."
