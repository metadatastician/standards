#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Proves check-copied-lock-step.sh finds a workflow that runs its own
# gh-actions-lock (raw release download or `gh extension install`), in block
# YAML and KYAML, names the pinned version, and stays quiet for prose, for a
# clean tree and for standards itself.
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-copied-lock-step.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
expect() { # expect <wanted-exit> <wanted-stdout> <label> <args...>
  local want="$1" out="$2" label="$3" got=0; shift 3
  bash "$SCRIPT" "$@" >"$WORK/out" 2>"$WORK/err" || got=$?
  if [ "$got" = "$want" ] && [ "$(cat "$WORK/out")" = "$out" ]; then
    pass=$((pass+1)); echo "  ok    $label"
  else
    fail=$((fail+1)); echo "  FAIL  $label (wanted exit $want, got $got)"
    sed 's/^/        out: /' "$WORK/out"; sed 's/^/        err: /' "$WORK/err"
  fi
}
repo() { rm -rf "$WORK/r"; mkdir -p "$WORK/r/.github/workflows"; }
TAB=$'\t'

repo
cat > "$WORK/r/.github/workflows/workflow-linter.yml" <<'YAML'
jobs:
  lint:
    steps:
      - name: Verify immutable action lockfile with the authoritative tool
        run: |
          curl -fsSL --retry 3 -o "$RUNNER_TEMP/gh-actions-lock" https://github.com/github/gh-actions-lock/releases/download/v0.1.6/linux-amd64
          "$RUNNER_TEMP/gh-actions-lock" --rescan --no-fix
YAML
expect 1 "o/r${TAB}.github/workflows/workflow-linter.yml${TAB}v0.1.6" \
  "the copied raw-download step is found with its version" "$WORK/r" o/r

cat > "$WORK/r/.github/workflows/regen.yml" <<'YAML'
jobs:
  a:
    steps:
      - run: gh extension install github/gh-actions-lock --pin v0.2.0
      - run: gh extension install github/gh-actions-lock
YAML
expect 1 "o/r${TAB}.github/workflows/regen.yml${TAB}unpinned,v0.2.0
o/r${TAB}.github/workflows/workflow-linter.yml${TAB}v0.1.6" \
  "a gh extension install is found, pinned and unpinned, one row per workflow" "$WORK/r" o/r

repo
cat > "$WORK/r/.github/workflows/lint.yml" <<'YAML'
{
  jobs: {
    lint: {
      steps: [
        {
          run: "curl -o x https://github.com/github/gh-actions-lock/releases/download/v0.1.6/linux-amd64\n./x --rescan --no-fix\n",
        },
      ],
    },
  },
}
YAML
expect 1 "o/r${TAB}.github/workflows/lint.yml${TAB}v0.1.6" "a KYAML run scalar is found" "$WORK/r" o/r

repo
cat > "$WORK/r/.github/workflows/workflow-linter.yml" <<'YAML'
jobs:
  lint:
    steps:
      # The step that stood here downloaded
      # https://github.com/github/gh-actions-lock/releases/download/v0.1.6/linux-amd64
      # and ran `gh extension install github/gh-actions-lock` -- now governance's.
      - run: echo ok
YAML
expect 0 "" "comment lines that name the tool are not a step" "$WORK/r" o/r

repo
printf 'jobs:\n  a:\n    steps:\n      - run: gh extension install github/gh-actions-lock --pin v0.2.0\n' \
  > "$WORK/r/.github/workflows/self-test.yml"
expect 0 "" "standards itself is skipped (its installs are the estate pin)" "$WORK/r" metadatastician/standards

rm -rf "$WORK/r"; mkdir -p "$WORK/r"
expect 0 "" "a repository without workflows is clean" "$WORK/r" o/r
expect 2 "" "a missing directory is a usage error" "$WORK/nope" o/r
expect 2 "" "no argument is a usage error"

echo
echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
