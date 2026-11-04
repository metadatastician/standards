#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The one-scan projection needs both the cached escript and Mix module.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
awk '/^      - name: Build Hypatia scanner$/{step=1} step && /^        run: \|$/{run=1; next}
  run && /^      - name:/{exit} run {if ($0 ~ /^          /) sub(/^          /, ""); print}' \
  "$root/.github/workflows/hypatia-scan-reusable.yml" > "$tmp/build-step.sh"
[ -s "$tmp/build-step.sh" ] || { echo 'missing build workflow step' >&2; exit 1; }
mkdir -p "$tmp/bin" "$tmp/home/hypatia"
cat > "$tmp/bin/mix" <<'MIX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MIX_CALLS"
[ "${BREAK_BUILD:-false}" = false ] || exit 1
if [ "$*" = 'escript.build' ]; then
  mkdir -p _build/dev/lib/hypatia/ebin
  : > _build/dev/lib/hypatia/ebin/Elixir.Hypatia.SARIF.beam
  printf '#!/usr/bin/env bash\nexit 0\n' > hypatia
  chmod +x hypatia
fi
MIX
chmod +x "$tmp/bin/mix"
export HOME="$tmp/home" MIX_CALLS="$tmp/mix-calls" PATH="$tmp/bin:$PATH" MIX_ENV=dev
: > "$MIX_CALLS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/hypatia/hypatia"
chmod +x "$HOME/hypatia/hypatia"
bash "$tmp/build-step.sh"
grep -qx 'deps.get' "$MIX_CALLS" && grep -qx 'escript.build' "$MIX_CALLS"
: > "$MIX_CALLS"
bash "$tmp/build-step.sh"
[ ! -s "$MIX_CALLS" ] || { echo 'complete cache was rebuilt unnecessarily' >&2; exit 1; }
rm "$HOME/hypatia/_build/dev/lib/hypatia/ebin/Elixir.Hypatia.SARIF.beam"
if BREAK_BUILD=true bash "$tmp/build-step.sh" >/dev/null 2>&1; then
  echo 'failed SARIF module rebuild was accepted' >&2; exit 1
fi
echo 'PASS: partial Hypatia caches rebuild the compiled SARIF projection'
