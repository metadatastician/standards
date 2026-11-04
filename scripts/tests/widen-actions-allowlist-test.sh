#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Offline API controls: widening must not prune or convert an all-posture repo.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *' -X PUT '* ]]; then
  echo PUT >> "$CALLS"
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --input ]; then cp "$2" "$LIVE"; break; fi
    shift
  done
  [ "${DROP_ON_PUT:-false}" = false ] || jq ' .patterns_allowed |= map(select(. != "old/custom@*"))' "$LIVE" > "$LIVE.x" && { [ ! -f "$LIVE.x" ] || mv "$LIVE.x" "$LIVE"; }
  if [ "${DROP_FLAG_ON_PUT:-false}" = true ]; then
    jq '.verified_allowed = false' "$LIVE" > "$LIVE.x" && mv "$LIVE.x" "$LIVE"
  fi
  if [ "${RAISE_FLAG_ON_PUT:-false}" = true ]; then
    jq '.github_owned_allowed = true' "$LIVE" > "$LIVE.x" && mv "$LIVE.x" "$LIVE"
  fi
elif [[ "$*" == *'/selected-actions'* ]]; then
  cat "$LIVE"
else
  jq -n --arg p "${POSTURE:-selected}" '{enabled:true,allowed_actions:$p,sha_pinning_required:false}'
fi
GH
chmod +x "$tmp/gh"
export GH_BIN="$tmp/gh" CALLS="$tmp/calls" LIVE="$tmp/live"
echo '{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":["new/workflow@*"]}' > "$tmp/canon"
reset() { echo '{"github_owned_allowed":false,"verified_allowed":true,"patterns_allowed":["old/custom@*"]}' > "$LIVE"; : > "$CALLS"; }
reset
bash "$root/scripts/widen-actions-allowlist.sh" owner/repo "$tmp/canon" >/dev/null
[ ! -s "$CALLS" ] || { echo 'dry run wrote settings' >&2; exit 1; }
POSTURE=all bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/canon" >/dev/null
[ ! -s "$CALLS" ] || { echo 'all posture was changed' >&2; exit 1; }
POSTURE=local_only bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/canon" >/dev/null
[ ! -s "$CALLS" ] || { echo 'local-only posture was changed' >&2; exit 1; }
if POSTURE=unexpected bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/canon" >/dev/null 2>&1; then
  echo 'unknown posture was silently skipped' >&2; exit 1
fi
[ ! -s "$CALLS" ] || { echo 'unknown posture wrote settings' >&2; exit 1; }
bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/canon" >/dev/null
jq -e '(.github_owned_allowed | not) and .verified_allowed and (.patterns_allowed | sort == ["new/workflow@*", "old/custom@*"])' "$LIVE" >/dev/null
# Even when canon enables both broad publishers, a deliberately restricted
# live repository must keep both flags false during a transfer.
reset
jq '.verified_allowed = false' "$LIVE" > "$tmp/live-new" && mv "$tmp/live-new" "$LIVE"
bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/canon" >/dev/null
jq -e '(.github_owned_allowed | not) and (.verified_allowed | not) and (.patterns_allowed | length == 2)' "$LIVE" >/dev/null
reset
if DROP_ON_PUT=true bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/canon" >/dev/null 2>&1; then
  echo 'read-back with a lost old pattern was accepted' >&2; exit 1
fi
reset
if DROP_FLAG_ON_PUT=true bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/canon" >/dev/null 2>&1; then
  echo 'read-back with a lost enabled flag was accepted' >&2; exit 1
fi
reset
if RAISE_FLAG_ON_PUT=true bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/canon" >/dev/null 2>&1; then
  echo 'read-back with an unexpectedly enabled flag was accepted' >&2; exit 1
fi
reset
cat "$LIVE" "$LIVE" > "$tmp/multi-live"
mv "$tmp/multi-live" "$LIVE"
if bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/canon" >/dev/null 2>&1; then
  echo 'multiple live JSON documents were accepted' >&2; exit 1
fi
[ ! -s "$CALLS" ] || { echo 'invalid live input wrote settings' >&2; exit 1; }
reset
echo '{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":[null]}' > "$tmp/bad"
if bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/bad" >/dev/null 2>&1; then
  echo 'malformed canon was accepted' >&2; exit 1
fi
[ ! -s "$CALLS" ] || { echo 'invalid input wrote settings' >&2; exit 1; }
cat "$tmp/canon" "$tmp/canon" > "$tmp/multiple"
if bash "$root/scripts/widen-actions-allowlist.sh" owner/repo --apply "$tmp/multiple" >/dev/null 2>&1; then
  echo 'multiple canonical JSON documents were accepted' >&2; exit 1
fi
[ ! -s "$CALLS" ] || { echo 'multiple JSON documents wrote settings' >&2; exit 1; }
echo 'PASS: selected-action widening is additive, verified and posture-preserving'
