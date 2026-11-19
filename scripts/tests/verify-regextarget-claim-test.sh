#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Tests for verify-regextarget-claim.sh.
#
# ⚠ WHAT THIS FILE IS ACTUALLY FOR. verify-regextarget-claim.sh is itself a
# gate: it measures whether an anchored value regex suppresses a gitleaks
# `generic-api-key` finding, because the estate once believed it did not and
# steered every repo toward blunt `paths` allowlists on that false basis. A
# measuring gate is only as good as its ABORTS -- if it can be made to report a
# confident answer on a contaminated or mis-versioned instrument, it reproduces
# exactly the wrong belief it exists to disprove.
#
# So these cases do not test the gitleaks semantics (that is the script's own
# job, and it needs a real gitleaks). They test that the script REFUSES to
# answer when it cannot answer honestly. Every case drives the script with a
# STUB gitleaks, so the guards are exercised deterministically on any host,
# with or without gitleaks installed.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/verify-regextarget-claim.sh"
[ -x "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found or not executable" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

# A stub gitleaks. Reports $STUB_VERSION for `version`, and for `detect` writes
# $STUB_REPORT to whatever --report-path it was handed.
make_stub() { # make_stub <path> <version> <report-json>
  local p="$1"
  cat > "$p" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "version" ]; then printf '%s\n' "$STUB_VERSION"; exit 0; fi
rp=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--report-path" ]; then rp="${2:-}"; fi
  shift
done
[ -n "$rp" ] && printf '%s' "$STUB_REPORT" > "$rp"
exit 0
STUB
  chmod +x "$p"
  export STUB_VERSION="$2"
  export STUB_REPORT="$3"
}

check() { # check <name> <wanted-rc> <wanted-substring> <env-prefix...> -- runs SCRIPT
  local name="$1" want_rc="$2" want_txt="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want_rc" ] && grep -qF "$want_txt" <<<"$out"; then
    printf '  ok    %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$name"
    printf '        wanted rc=%s containing: %s\n' "$want_rc" "$want_txt"
    printf '        got    rc=%s: %s\n' "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
    fail=$((fail + 1))
  fi
}

PINNED=8.18.4
ONE_FINDING='[{"RuleID":"generic-api-key","Match":"Key : Ed25519_Private_Key;","Secret":"Ed25519_Private_Key"}]'

# 1. No gitleaks at all must ABORT (rc 2), not silently skip. A gate that
#    vanishes when its tool is absent is the estate's commonest fake green.
check "absent gitleaks aborts, does not skip" 2 "gitleaks not found" \
  env GITLEAKS="$TMP/does-not-exist" "$SCRIPT"

# 2. A non-pinned gitleaks must ABORT. These results are version-specific;
#    answering on an unpinned build is how a stale claim gets re-confirmed.
make_stub "$TMP/gl" "8.18.3" "$ONE_FINDING"
check "version drift aborts by default" 2 "CI pins $PINNED" \
  env GITLEAKS="$TMP/gl" STUB_VERSION=8.18.3 STUB_REPORT="$ONE_FINDING" "$SCRIPT"

# 3. ...but the documented override must actually get PAST that guard, or the
#    escape hatch is decorative. The assertion is deliberately narrow: it says
#    the run reached the MEASUREMENT phase (it printed the control rule), not
#    that the whole script succeeded. A constant stub cannot satisfy the five
#    semantic expectations that follow -- only a real gitleaks can -- so the
#    script correctly ends non-zero here, and asserting rc=0 would be a lie.
check "GITLEAKS_ALLOW_VERSION_DRIFT=1 reaches measurement" 1 "control: rule=generic-api-key" \
  env GITLEAKS="$TMP/gl" GITLEAKS_ALLOW_VERSION_DRIFT=1 \
      STUB_VERSION=8.18.3 STUB_REPORT="$ONE_FINDING" "$SCRIPT"

# 3b. And the override must still WARN -- a silent override is how a
#     version-specific result gets quoted later as if it were pinned.
check "override still warns about the drift" 1 "WARNING: measuring on 8.18.3" \
  env GITLEAKS="$TMP/gl" GITLEAKS_ALLOW_VERSION_DRIFT=1 \
      STUB_VERSION=8.18.3 STUB_REPORT="$ONE_FINDING" "$SCRIPT"

# 4. THE CONTAMINATION GUARD -- the reason the script has a control at all.
#    If the instrument reports zero findings for the control fixture, a WORKING
#    allowlist entry is indistinguishable from an inert one, which is the most
#    likely origin of the original false claim. It must abort, never measure.
check "control with 0 findings aborts (contaminated instrument)" 2 "control expected exactly 1 finding" \
  env GITLEAKS="$TMP/gl" STUB_VERSION="$PINNED" STUB_REPORT='[]' "$SCRIPT"

# 5. Same for a control that fires the WRONG rule: the fixture is then no
#    longer measuring generic-api-key, so every later count is off-target.
check "control firing the wrong rule aborts" 2 "control fired" \
  env GITLEAKS="$TMP/gl" STUB_VERSION="$PINNED" \
      STUB_REPORT='[{"RuleID":"aws-access-token","Match":"x","Secret":"x"}]' "$SCRIPT"

# 6. Two findings is also contamination (config or report inside --source).
check "control with 2 findings aborts" 2 "control expected exactly 1 finding" \
  env GITLEAKS="$TMP/gl" STUB_VERSION="$PINNED" \
      STUB_REPORT='[{"RuleID":"generic-api-key","Match":"a","Secret":"a"},{"RuleID":"generic-api-key","Match":"b","Secret":"b"}]' \
      "$SCRIPT"

echo
echo "=== SUMMARY ==="
echo "Pass: $pass"
echo "Fail: $fail"
[ "$fail" -eq 0 ]
