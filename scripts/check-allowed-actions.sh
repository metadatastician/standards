#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# check-allowed-actions.sh — make the un-squabble-able startup_failure legible.
#
# When a repo sets `allowed_actions: selected` (RSR default) and a workflow
# `uses:` an action or reusable-workflow the allowlist does not permit, the run
# dies at STARTUP with no job and no log — an opaque red you cannot "squabble"
# with (RSR-PHILOSOPHY: reach green by satisfying the gate, never admin-override).
#
# This offline check identifies refs not explicitly covered by the tree policy.
# It cannot verify Marketplace publisher status or the caller's live policy, so
# a gap is conservative rather than proof that GitHub would refuse the ref. It
# needs NO API and NO admin — safe in CI, in rhodibot, or locally.
#
# Usage:  check-allowed-actions.sh [ALLOWED_ACTIONS_JSON] [WORKFLOWS_DIR]
# Exit:   0 = every `uses:` is covered; 1 = one or more gaps (printed).
set -euo pipefail
CANON="${1:-rhodium-standard-repositories/actions-allowlist/allowed-actions.json}"
WF_DIR="${2:-.github/workflows}"

if [ ! -f "$CANON" ]; then
  # fall back to the published canonical list in standards
  CANON_URL="https://raw.githubusercontent.com/metadatastician/standards/main/rhodium-standard-repositories/actions-allowlist/allowed-actions.json"
  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  curl -fsSL "$CANON_URL" -o "$TMP" && CANON="$TMP" || { echo "!! no allowlist ($CANON)"; exit 2; }
fi

python3 - "$CANON" "$WF_DIR" <<'PY'
import json, sys, os, re, glob, fnmatch
canon = json.load(open(sys.argv[1]))
patterns = canon.get("patterns_allowed", [])
gh_owned = {"actions", "github"}  # github_owned_allowed

def covered(u):
    # $/ is gh actions-lock's inherently-pinned same-repo form (like ./).
    if u.startswith('./') or u.startswith('$/') or u.startswith('docker://'):
        return True
    action, sep, ref = u.partition('@')
    parts = action.split('/')
    if len(parts) < 2 or not sep:
        return False
    owner_repo = '/'.join(x.lower() for x in parts[:2])
    normalized_action = '/'.join([owner_repo] + parts[2:])
    owner = parts[0].lower()
    if owner in gh_owned and canon.get("github_owned_allowed", False):
        return True
    for pattern in patterns:
        base, has_ref, allowed_ref = pattern.partition('@')
        # Owner/repo is case-insensitive; refs are not. A path-specific
        # reusable pattern must match the *whole* path, not merely owner/repo.
        if has_ref and not fnmatch.fnmatchcase(ref, allowed_ref):
            continue
        segments = base.split('/')
        base = '/'.join([x.lower() for x in segments[:2]] + segments[2:])
        # Match the complete action path. A repository-only rule is not an
        # implicit grant to arbitrary actions in its subdirectories; owner/*
        # remains an explicit wildcard over those paths.
        if fnmatch.fnmatchcase(normalized_action, base):
            return True
    return False

uses = set()
for f in sorted(glob.glob(os.path.join(sys.argv[2], '*.yml')) +
                glob.glob(os.path.join(sys.argv[2], '*.yaml'))):
    for line in open(f, encoding='utf-8'):
        m = re.search(r'^\s*(?:-\s*)?uses:\s*([^\s#]+)', line)
        if m:
            uses.add(m.group(1).strip().strip('"\''))

gaps = sorted(u for u in uses if not covered(u))
for u in gaps:
    print(f"GAP  {u}   (review a narrow path/ref pattern and the effective live policy)")
print(f"checked {len(uses)} `uses:` refs across {sys.argv[2]} — {len(gaps)} not covered by the allowlist")
sys.exit(1 if gaps else 0)
PY
