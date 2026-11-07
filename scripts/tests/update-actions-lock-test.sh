#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE="$SCRIPT_DIR/../update-actions-lock.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/.github/workflows" "$WORK/bin"
cat > "$WORK/.github/workflows/ci.yml" <<'EOF'
# SPDX-License-Identifier: MPL-2.0
# This workflow is managed by gh actions-lock.
name: CI
on: push
permissions: {}
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
EOF

cat > "$WORK/bin/fake-gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${2:-}" = "--verify-local" ]; then
  grep -q "actions/checkout@v7.0.1" \
    .github/workflows/actions.lock
  sed -i '1i# verifier-only mutation' .github/workflows/ci.yml
  case "${FAKE_VERIFY_FINDING:-}" in
    reusable-exact)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/reusable.yml","category":"stale","dependency":"hyperpolymath/standards@abc123"}]}'
      exit 1
      ;;
    reusable-wrong-ref)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/reusable.yml","category":"stale","dependency":"hyperpolymath/standards@wrong456"}]}'
      exit 1
      ;;
    reusable-non-stale)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/reusable.yml","category":"missing","dependency":"hyperpolymath/standards@abc123"}]}'
      exit 1
      ;;
    not-pinned-nothing)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/runonly.yml","category":"not-pinned","dependency":null},{"workflow":".github/workflows/localcall.yml","category":"not-pinned","dependency":null}]}'
      exit 1
      ;;
    not-pinned-remote)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/ci.yml","category":"not-pinned","dependency":null}]}'
      exit 1
      ;;
    not-pinned-with-dependency)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/runonly.yml","category":"not-pinned","dependency":"actions/checkout@v7.0.1"}]}'
      exit 1
      ;;
    local-action)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/localaction.yml","category":"local-action","dependency":null}]}'
      exit 1
      ;;
    malformed-success)
      printf '%s\n' 'not valid JSON'
      exit 0
      ;;
    valid-advisory)
      printf '%s\n' '{"valid":true,"findings":[{"workflow":".github/workflows/ci.yml","category":"sha-as-ref","severity":"warning","dependency":"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"}]}'
      exit 1
      ;;
    invalid-advisory-and-reusable)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/ci.yml","category":"sha-as-ref","severity":"warning","dependency":"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"},{"workflow":".github/workflows/reusable.yml","category":"stale","severity":"warning","dependency":"hyperpolymath/standards@abc123"}]}'
      exit 1
      ;;
    invalid-advisory-and-real-stale)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/ci.yml","category":"sha-as-ref","severity":"warning","dependency":"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"},{"workflow":".github/workflows/ci.yml","category":"stale","severity":"warning","dependency":"actions/upload-artifact@v4"}]}'
      exit 1
      ;;
    invalid-advisory-only)
      printf '%s\n' '{"valid":false,"findings":[{"workflow":".github/workflows/ci.yml","category":"sha-as-ref","severity":"warning","dependency":"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"}]}'
      exit 1
      ;;
    invalid-empty)
      printf '%s\n' '{"valid":false,"findings":[]}'
      exit 1
      ;;
    empty-stdout)
      exit 1
      ;;
    *)
      printf '%s\n' '{"valid":true,"findings":[]}'
      exit
      ;;
  esac
fi
grep -q '^# This workflow is managed by gh actions-lock.$' .github/workflows/ci.yml ||
  sed -i '1i# This workflow is managed by gh actions-lock.' .github/workflows/ci.yml
sed -i 's#actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1#actions/checkout@v7.0.1#' \
  .github/workflows/ci.yml
cat > .github/workflows/actions.lock <<'LOCK'
version: 'v0.0.2'
workflows:
    '.github/workflows/ci.yml':
        - 'actions/checkout@v7.0.1'
dependencies:
    'actions/checkout@v7.0.1':
        ref: 'v7.0.1'
        commit: 'sha1-3d3c42e5aac5ba805825da76410c181273ba90b1'
        owner_id: 1
        repo_id: 2
LOCK
EOF
chmod +x "$WORK/bin/fake-gh"

cd "$WORK"
GH_BIN="$WORK/bin/fake-gh" bash "$UPDATE" .github/workflows >/dev/null

grep -q 'uses: actions/checkout@v7.0.1' \
  .github/workflows/ci.yml
[ "$(grep -c '^# This workflow is managed by gh actions-lock.$' .github/workflows/ci.yml)" -eq 1 ]
grep -q "'actions/checkout@v7.0.1':" \
  .github/workflows/actions.lock

cp .github/workflows/ci.yml "$WORK/ci.before"
cp .github/workflows/actions.lock "$WORK/lock.before"
GH_BIN="$WORK/bin/fake-gh" bash "$UPDATE" .github/workflows >/dev/null
cmp -s "$WORK/ci.before" .github/workflows/ci.yml
cmp -s "$WORK/lock.before" .github/workflows/actions.lock

echo "PASS: Actions lock refresh keeps authoritative symbolic source and is idempotent"

# Verification is mutating in released gh-actions-lock versions too. The safe
# verification mode must restore workflow bytes while leaving the lock intact.
cp .github/workflows/ci.yml "$WORK/ci.before-verify"
cp .github/workflows/actions.lock "$WORK/lock.before-verify"
GH_BIN="$WORK/bin/fake-gh" bash "$UPDATE" --verify-local .github/workflows >/dev/null
cmp -s "$WORK/ci.before-verify" .github/workflows/ci.yml
cmp -s "$WORK/lock.before-verify" .github/workflows/actions.lock
echo "PASS: Actions lock verification restores tool-authored workflow edits"

cat > .github/workflows/reusable.yml <<'EOF'
# SPDX-License-Identifier: MPL-2.0
name: Reusable caller
on: push
permissions: {}
jobs:
  governance:
    uses: hyperpolymath/standards/.github/workflows/governance-reusable.yml@abc123
EOF

sed -i "/^dependencies:/i\\    '.github/workflows/reusable.yml': []" .github/workflows/actions.lock
FAKE_VERIFY_FINDING=reusable-exact GH_BIN="$WORK/bin/fake-gh" \
  bash "$UPDATE" --verify-local .github/workflows >/dev/null
echo "PASS: exact reusable-workflow dependency is accepted"

if FAKE_VERIFY_FINDING=reusable-wrong-ref GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: wrong reusable-workflow ref was accepted" >&2
  exit 1
fi
echo "PASS: wrong reusable-workflow ref remains blocking"

if FAKE_VERIFY_FINDING=reusable-non-stale GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: non-stale reusable-workflow finding was accepted" >&2
  exit 1
fi
echo "PASS: non-stale reusable-workflow finding remains blocking"

# gh-actions-lock v0.2.0 reports `not-pinned` ("workflow has no lockfile entry",
# dependency null) for a workflow a v0.1.6-written lock omits. That is a false
# positive only when the workflow has nothing to pin: `run:` steps, or ./ calls.
cat > .github/workflows/runonly.yml <<'EOF'
# SPDX-License-Identifier: MPL-2.0
on: push
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF
cat > .github/workflows/localcall.yml <<'EOF'
# SPDX-License-Identifier: MPL-2.0
on: push
permissions: {}
jobs:
  a:
    uses: ./.github/workflows/runonly.yml
EOF
# Keep this verifier fixture consistent with the separate strict sync gate:
# even workflows with no external dependencies have explicit empty entries.
sed -i "/^dependencies:/i\\    '.github/workflows/runonly.yml': []" .github/workflows/actions.lock
sed -i "/^dependencies:/i\\    '.github/workflows/localcall.yml': []" .github/workflows/actions.lock
FAKE_VERIFY_FINDING=not-pinned-nothing GH_BIN="$WORK/bin/fake-gh" \
  bash "$UPDATE" --verify-local .github/workflows >/dev/null
echo "PASS: run-only and ./-only workflows accept explicit empty lock entries"

if FAKE_VERIFY_FINDING=not-pinned-remote GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: a workflow with a remote action and no lock entry was accepted" >&2
  exit 1
fi
echo "PASS: a workflow with a remote action and no lock entry remains blocking"

if FAKE_VERIFY_FINDING=not-pinned-with-dependency GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: a not-pinned dependency was accepted" >&2
  exit 1
fi
echo "PASS: a not-pinned dependency remains blocking"
rm -f .github/workflows/runonly.yml .github/workflows/localcall.yml
sed -i "/^    '.github\/workflows\/runonly.yml':/d; /^    '.github\/workflows\/localcall.yml':/d" .github/workflows/actions.lock

# v0.2.0 also reports every `uses: ./…` as `local-action`. The estate runs
# `./` (check-lock-sync.sh fails the `$/` rewrite instead), so the finding is
# accepted only when each `./` path exists in the checkout.
cat > .github/workflows/localaction.yml <<'EOF'
# SPDX-License-Identifier: MPL-2.0
on: push
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/thing
EOF
sed -i "/^dependencies:/i\\    '.github/workflows/localaction.yml': []" .github/workflows/actions.lock
if FAKE_VERIFY_FINDING=local-action GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: a ./ action that does not exist was accepted" >&2
  exit 1
fi
echo "PASS: a ./ action that does not exist remains blocking"
mkdir -p .github/actions/thing
FAKE_VERIFY_FINDING=local-action GH_BIN="$WORK/bin/fake-gh" \
  bash "$UPDATE" --verify-local .github/workflows >/dev/null
echo "PASS: a ./ action that exists in the checkout is accepted"
rm -rf .github/workflows/localaction.yml .github/actions
sed -i "/^    '.github\/workflows\/localaction.yml':/d" .github/workflows/actions.lock

# The same caller in KYAML (YAML-POLICY Y-3). A line matcher never saw the
# quoted value, so the exact dependency was rejected; the parser reads it.
cp .github/workflows/reusable.yml "$WORK/reusable.block"
cat > .github/workflows/reusable.yml <<'EOF'
# SPDX-License-Identifier: MPL-2.0
{
  name: "Reusable caller",
  on: "push",
  permissions: {},
  jobs: {
    governance: {
      uses: "hyperpolymath/standards/.github/workflows/governance-reusable.yml@abc123",
    },
  },
}
EOF
FAKE_VERIFY_FINDING=reusable-exact GH_BIN="$WORK/bin/fake-gh" \
  bash "$UPDATE" --verify-local .github/workflows >/dev/null
echo "PASS: exact reusable-workflow dependency is accepted from a KYAML caller"

if FAKE_VERIFY_FINDING=reusable-wrong-ref GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: wrong reusable-workflow ref was accepted from a KYAML caller" >&2
  exit 1
fi
echo "PASS: wrong reusable-workflow ref remains blocking from a KYAML caller"

# Text that only MENTIONS the reusable (a run: body) is not a reference.
cat > .github/workflows/reusable.yml <<'EOF'
# SPDX-License-Identifier: MPL-2.0
name: Reusable caller
on: push
permissions: {}
jobs:
  governance:
    runs-on: ubuntu-latest
    steps:
      - run: |
          uses: hyperpolymath/standards/.github/workflows/governance-reusable.yml@abc123
EOF
if FAKE_VERIFY_FINDING=reusable-exact GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: a run: body mentioning the reusable was accepted as a reference" >&2
  exit 1
fi
echo "PASS: a run: body mentioning the reusable is not a reference"
cp "$WORK/reusable.block" .github/workflows/reusable.yml

advisory_output="$(FAKE_VERIFY_FINDING=valid-advisory GH_BIN="$WORK/bin/fake-gh" \
  bash "$UPDATE" --verify-local .github/workflows)"
printf '%s\n' "$advisory_output" | grep -q '"category":"sha-as-ref"'
printf '%s\n' "$advisory_output" | grep -q 'valid with advisory finding'
echo "PASS: authoritative valid result accepts but preserves advisory findings"

if FAKE_VERIFY_FINDING=invalid-empty GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: contradictory invalid result with no findings was accepted" >&2
  exit 1
fi
echo "PASS: invalid result with no explainable findings fails closed"

# An advisory finding alongside the accepted reusable-workflow false positive
# must not block. Until 2026-09-22 every `sha-as-ref` became fatal the moment
# one real finding flipped `valid` to false, which held metadatastician/burble
# red on 7 advisories and skipped the secret-baseline controls behind it.
mixed_output="$(FAKE_VERIFY_FINDING=invalid-advisory-and-reusable GH_BIN="$WORK/bin/fake-gh" \
  bash "$UPDATE" --verify-local .github/workflows)"
printf '%s\n' "$mixed_output" | grep -q 'Accepted reusable-workflow lock coverage'
printf '%s\n' "$mixed_output" | grep -q 'advisory finding(s) recorded, not blocking'
echo "PASS: advisory finding alongside an accepted reusable false positive does not block"

# The exemption must key on CATEGORY, not severity: v0.1.6 marks `stale`
# `severity: warning` too, so a severity-based exemption would pass vacuously.
if FAKE_VERIFY_FINDING=invalid-advisory-and-real-stale GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: a real stale finding was hidden by the advisory exemption" >&2
  exit 1
fi
echo "PASS: a real stale finding still blocks alongside advisory findings"

if FAKE_VERIFY_FINDING=invalid-advisory-only GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: advisory findings alone were accepted as explaining valid:false" >&2
  exit 1
fi
echo "PASS: advisory findings alone cannot explain an invalid result"

if FAKE_VERIFY_FINDING=malformed-success GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: malformed successful verifier output was accepted" >&2
  exit 1
fi
if FAKE_VERIFY_FINDING=empty-stdout GH_BIN="$WORK/bin/fake-gh" \
   bash "$UPDATE" --verify-local .github/workflows >/dev/null 2>&1; then
  echo "FAIL: empty verifier stdout was accepted (jq -e empty-input hazard)" >&2
  exit 1
fi
echo "PASS: malformed verifier output fails closed"

# A failed refresh must restore both authored workflows and the previous
# lockfile; this is the production failure mode that left the original checkout
# half-rewritten when DNS resolution failed.
cp .github/workflows/ci.yml "$WORK/ci.before-failure"
cp .github/workflows/actions.lock "$WORK/lock.before-failure"
cat > "$WORK/bin/failing-gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sed -i '1i# This workflow is managed by gh actions-lock.' .github/workflows/ci.yml
sed -i 's#actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1#actions/checkout@v7.0.1#' \
  .github/workflows/ci.yml
printf 'partial lock\n' > .github/workflows/actions.lock
exit 1
EOF
chmod +x "$WORK/bin/failing-gh"

if GH_BIN="$WORK/bin/failing-gh" bash "$UPDATE" .github/workflows >/dev/null 2>&1; then
  echo "FAIL: simulated lock refresh unexpectedly succeeded" >&2
  exit 1
fi
cmp -s "$WORK/ci.before-failure" .github/workflows/ci.yml
cmp -s "$WORK/lock.before-failure" .github/workflows/actions.lock
echo "PASS: failed Actions lock refresh rolls back partial generated edits"
