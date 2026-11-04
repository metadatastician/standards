#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The Radicle key must not be inherited by downloaded Rust/build code.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
yq_bin=${YQ_BIN:-yq}
command -v "$yq_bin" >/dev/null && command -v jq >/dev/null || { echo 'yq v4 and jq required' >&2; exit 2; }
"$yq_bin" -o=json '.jobs."mirror-radicle"' "$root/.github/workflows/mirror-reusable.yml" > "$tmp/job.json"
jq -e --arg secret '${{ secrets.RADICLE_KEY }}' '
  (has("env") | not) and
  ([.steps[] | select(.env.RADICLE_KEY == $secret) | .name] | sort == ["Check Radicle configuration", "Mirror to Radicle"]) and
  all(.steps[] | select(.name != "Check Radicle configuration" and .name != "Mirror to Radicle");
      (tojson | contains("${{ secrets.RADICLE_KEY") | not)) and
  all(.steps[] | select(.name == "Setup Rust" or .name == "Install Radicle" or .name == "Mirror to Radicle");
      .if == "steps.radicle.outputs.configured == '\''true'\''") and
  ([.steps[] | select(.name == "Skipped (RADICLE_KEY not configured)" and
      .if == "steps.radicle.outputs.configured != '\''true'\''")] | length == 1)
' "$tmp/job.json" >/dev/null || { echo 'Radicle key scope or missing-key guards changed' >&2; exit 1; }
for name in 'Check Radicle configuration' 'Install Radicle' 'Mirror to Radicle'; do
  jq -r --arg name "$name" '.steps[] | select(.name == $name) | .run' "$tmp/job.json" > "$tmp/$name.sh"
  [ -s "$tmp/$name.sh" ] || { echo "missing step: $name" >&2; exit 1; }
  bash -n "$tmp/$name.sh"
done
secret=$'example-private-key\nsecond-line'
for configured in true false; do
  : > "$tmp/output"
  key="$secret"; [ "$configured" = true ] || key=''
  RADICLE_KEY="$key" GITHUB_OUTPUT="$tmp/output" bash "$tmp/Check Radicle configuration.sh" > "$tmp/stdout" 2> "$tmp/stderr"
  [ "$(cat "$tmp/output")" = "configured=$configured" ]
  [ ! -s "$tmp/stdout" ] && [ ! -s "$tmp/stderr" ] || { echo 'configuration step logged sensitive data' >&2; exit 1; }
done
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${RADICLE_KEY+x}" != x ] || { echo 'key leaked to cargo install' >&2; exit 1; }
[ "$*" = 'install radicle-cli --locked' ]
SH
cat > "$tmp/bin/rad" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${RADICLE_KEY+x}" != x ] || { echo 'key leaked as rad process environment' >&2; exit 1; }
[ "$*" = 'sync --announce' ]
[ "$(stat -c '%a' "$HOME/.radicle/keys/radicle")" = 600 ]
cmp -s "$HOME/.radicle/keys/radicle" "$EXPECTED_FILE"
printf 'verified\n' > "$RAD_PROBE"
SH
chmod +x "$tmp/bin/cargo" "$tmp/bin/rad"
printf '%s\n' "$secret" > "$tmp/expected-key"
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" GITHUB_PATH="$tmp/github-path" EXPECTED_FILE="$tmp/expected-key" RAD_PROBE="$tmp/rad-probe"
env -u RADICLE_KEY bash "$tmp/Install Radicle.sh"
RADICLE_KEY="$secret" bash "$tmp/Mirror to Radicle.sh"
[ -s "$RAD_PROBE" ] || { echo 'radicle verification was swallowed by the advisory sync step' >&2; exit 1; }
echo 'PASS: Radicle key is step-scoped, never exported to cargo or rad, and missing-key runs skip installation'
