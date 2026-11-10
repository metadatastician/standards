#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Hyperpolymath Estate — staged-secret scan (pre-commit)
# Source: https://github.com/metadatastician/standards
#
# Scans ONLY what is staged, so it runs in the time a commit can afford.
#
# FAILS CLOSED. If gitleaks is not installed this exits non-zero and prints the
# install line. It never returns 0 on "could not scan": "validator absent" and
# "no secrets found" produce exactly the same silence, and a gate that reports
# success having examined nothing is worse than no gate at all — it is a gate
# somebody trusts.
#
# --redact is NOT optional. --verbose without it prints the discovered secret
# to the terminal and into scrollback, CI logs and any `script`/tmux capture,
# which turns a near-miss into a second disclosure.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REPO_ROOT="${INPUT_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# Print the denominator. A scan whose input size is never shown cannot be
# told apart from a scan of nothing.
STAGED_COUNT="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -c . || true)"
echo "[gitleaks] staged files in scope: ${STAGED_COUNT}"

if [ "${STAGED_COUNT}" -eq 0 ]; then
  echo -e "${YELLOW}[gitleaks] nothing staged; no scan performed (this is not a pass).${NC}"
  exit 0
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  echo -e "${RED}[gitleaks] gitleaks is NOT installed — refusing to let a commit through unscanned.${NC}" >&2
  echo "" >&2
  echo "  Install one of:" >&2
  echo "    brew install gitleaks" >&2
  echo "    go install github.com/zricethezav/gitleaks/v8@latest" >&2
  echo "    https://github.com/gitleaks/gitleaks/releases  (pinned binary, verify sha256)" >&2
  echo "" >&2
  echo "  Deliberate override for this one commit: git commit --no-verify" >&2
  exit 1
fi

# Gitleaks moved staged scanning between major versions: 8.x exposes
# `protect --staged`, and newer releases expose `git --staged` while hiding
# `protect`. PROBE for the subcommand instead of assuming either one.
#
# ⚠ Do not hard-code `gitleaks git` here. MEASURED 2026-09-22 on the installed
# binary, whose subcommands are exactly: completion, detect, help, protect,
# version. `gitleaks git` exits 1 as an unknown command — and because the
# failure branch below treats ANY non-zero exit as a finding, that reports
# "SECRET DETECTED" and refuses every commit while having scanned NOTHING.
# A gate that has scanned nothing must never be able to look like either a
# pass or a finding.
if gitleaks git --help >/dev/null 2>&1; then
  GITLEAKS_STAGED=(gitleaks git --staged --verbose --redact)
elif gitleaks protect --help >/dev/null 2>&1; then
  GITLEAKS_STAGED=(gitleaks protect --staged --verbose --redact)
else
  echo -e "${RED}[gitleaks] installed gitleaks exposes neither 'git --staged' nor" >&2
  echo -e "  'protect --staged'. Refusing to report a pass from a scan that cannot run.${NC}" >&2
  exit 1
fi

if "${GITLEAKS_STAGED[@]}"; then
  echo -e "${GREEN}[gitleaks] no secrets detected in ${STAGED_COUNT} staged file(s).${NC}"
  exit 0
fi

echo "" >&2
echo -e "${RED}[gitleaks] SECRET DETECTED in staged changes — commit refused.${NC}" >&2
echo "  Values above are redacted; the rule id and location are not." >&2
echo "" >&2
echo "  If this is a real credential: rotate it FIRST, then unstage." >&2
echo "  If it is a false positive: add a scoped allow rule to .gitleaks.toml," >&2
echo "  or append the fingerprint to .gitleaksignore — never a blanket skip." >&2
exit 1
