#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Test the real workflow's ref resolver with fixed and floating canary inputs.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
workflow="$root/.github/workflows/hypatia-scan-reusable.yml"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
awk '/^      - name: Resolve advisory scanner commits$/{step=1} step && /^        run: \|$/{run=1; next}
  run && /^      - name:/{exit} run {if ($0 ~ /^          /) sub(/^          /, ""); print}' "$workflow" > "$tmp/resolve.sh"
[ -s "$tmp/resolve.sh" ] || { echo 'missing advisory scanner resolver' >&2; exit 1; }
mkdir "$tmp/bin"
cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *panic-attack.git*) printf '%s\tHEAD\n' 1111111111111111111111111111111111111111 ;;
  *pons-asinorum.git*) printf '%s\tHEAD\n' 2222222222222222222222222222222222222222 ;;
  *) exit 1 ;;
esac
GIT
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH" GITHUB_ENV="$tmp/env"
panic=410a8f821ea8297833162565b50a298f787815da
pons=bca1ea289a4f8a86bac6212731e6f8ec15c67ad4
: > "$GITHUB_ENV"
PANIC_REF="$panic" PONS_REF="$pons" bash "$tmp/resolve.sh" >/dev/null
grep -qx "PANIC_ATTACK_SHA=$panic" "$GITHUB_ENV"
grep -qx "PONS_SHA=$pons" "$GITHUB_ENV"
: > "$GITHUB_ENV"
PANIC_REF=HEAD PONS_REF=HEAD bash "$tmp/resolve.sh" >/dev/null
grep -qx 'PANIC_ATTACK_SHA=1111111111111111111111111111111111111111' "$GITHUB_ENV"
grep -qx 'PONS_SHA=2222222222222222222222222222222222222222' "$GITHUB_ENV"
: > "$GITHUB_ENV"
if PANIC_REF='bad; echo injected' PONS_REF="$pons" bash "$tmp/resolve.sh" >"$tmp/stdout" 2>"$tmp/stderr"; then
  echo 'invalid panic-ref was accepted' >&2; exit 1
fi
[ ! -s "$GITHUB_ENV" ] || { echo 'invalid ref partially set the environment' >&2; exit 1; }
grep -q '^::error::panic-ref must be a 40-hex commit SHA or HEAD$' "$tmp/stderr" || { echo 'panic-ref diagnostic missing' >&2; exit 1; }
[ ! -s "$tmp/stdout" ] || { echo 'error annotation was captured on stdout' >&2; exit 1; }
if PANIC_REF="$panic" PONS_REF=main bash "$tmp/resolve.sh" >"$tmp/stdout" 2>"$tmp/stderr"; then
  echo 'unpinned pons-ref was accepted' >&2; exit 1
fi
[ ! -s "$GITHUB_ENV" ] || { echo 'invalid pons ref partially set the environment' >&2; exit 1; }
grep -q '^::error::pons-ref must be a 40-hex commit SHA or HEAD$' "$tmp/stderr" || { echo 'pons-ref diagnostic missing' >&2; exit 1; }
[ ! -s "$tmp/stdout" ] || { echo 'error annotation was captured on stdout' >&2; exit 1; }
# These resolved SHAs must be the values used for cache/install/evidence, not
# the mutable input literal. Also lock the defaults to the agreed vetted pins.
grep -Fq "default: $panic" "$workflow"
grep -Fq "default: $pons" "$workflow"
grep -Fq 'default: adb2f41db34156cf81b2508f6596a10c7f076098' "$workflow"
grep -Fq 'default: adb2f41db34156cf81b2508f6596a10c7f076098' "$root/.github/workflows/governance-reusable.yml"
grep -Fq 'ref: adb2f41db34156cf81b2508f6596a10c7f076098' "$root/.github/workflows/self-test.yml"
grep -Fq "PANIC_ATTACK_SHA: $panic" "$root/.github/workflows/fork-governance.yml"
grep -Fq 'key: panic-attack-v1-${{ runner.os }}-${{ runner.arch }}-${{ env.PANIC_ATTACK_SHA }}' "$workflow"
grep -Fq 'key: pons-v1-${{ runner.os }}-${{ runner.arch }}-${{ env.PONS_SHA }}' "$workflow"
echo 'PASS: advisory scanner refs are validated, resolved, pinned and cache-keyed'
