#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression: DEED Mustfile validation/execution must not mistake a multiline
# critical check for zero checks or silently green on malformed input.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
F="$TMP/checks_praxis.deed"

# The required CI gate must provision the canonical parser before invoking it.
WORKFLOW="$ROOT/.github/workflows/k9-contractile.yml"
setup_line="$(grep -nF "Install Bun for Mustfile enforcement and reporting" "$WORKFLOW" | cut -d: -f1)"
must_line="$(grep -nF "name: K9-SVC Validation" "$WORKFLOW" | cut -d: -f1)"
[ -n "$setup_line" ] && [ -n "$must_line" ] && [ "$setup_line" -lt "$must_line" ] || {
  echo "FAIL: Bun must be installed before the required Mustfile gate" >&2
  exit 1
}

good() {
  if ! "$@" >"$TMP/output" 2>&1; then
    cat "$TMP/output" >&2
    echo "FAIL: expected success: $*" >&2
    exit 1
  fi
}
bad() {
  if "$@" >"$TMP/output" 2>&1; then
    cat "$TMP/output" >&2
    echo "FAIL: expected nonzero: $*" >&2
    exit 1
  fi
}

cat >"$F" <<'DEED'
;; SPDX-License-Identifier: MPL-2.0
(praxis-deed
  :schema-version "1.0.0"
  (check
    :id critical-fails
    :severity critical
    :discharge run
    :body "false")
)
DEED
good bash "$ROOT/scripts/check-mustfile-structure.sh" "$F"
bad bash "$ROOT/scripts/run-mustfile.sh" "$F"
grep -q 'critical-fails' "$TMP/output"

cat >"$F" <<'DEED'
;; SPDX-License-Identifier: MPL-2.0
(praxis-deed :schema-version "1.0.0"
  (check
    :id advisory-fails
    :severity low
    :discharge run
    :body "false")
  (check :id manual-review :severity high :discharge verification :body "human attestation")
  (check :id true-check :severity critical :discharge run :body "true")
)
DEED
good bash "$ROOT/scripts/check-mustfile-structure.sh" "$F"
good bash "$ROOT/scripts/run-mustfile.sh" "$F"
grep -q 'WARN.*advisory-fails' "$TMP/output"
grep -q 'MANUAL.*manual-review' "$TMP/output"
grep -q 'PASS.*true-check' "$TMP/output"

# Structurally legal DEED, semantically invalid Mustfiles: all must fail both paths.
cat >"$F" <<'DEED'
;; SPDX-License-Identifier: MPL-2.0
(praxis-deed :schema-version "1.0.0")
DEED
bad bash "$ROOT/scripts/check-mustfile-structure.sh" "$F"
bad bash "$ROOT/scripts/run-mustfile.sh" "$F"

cat >"$F" <<'DEED'
;; SPDX-License-Identifier: MPL-2.0
(praxis-deed :schema-version "1.0.0"
  (check :id a :severity critcal :discharge run :body "true"))
DEED
bad bash "$ROOT/scripts/check-mustfile-structure.sh" "$F"
bad bash "$ROOT/scripts/run-mustfile.sh" "$F"

cat >"$F" <<'DEED'
;; SPDX-License-Identifier: MPL-2.0
(praxis-deed :schema-version "1.0.0"
  (check :id a :severity critical :discharge run :body "true")
  (check :id a :severity critical :discharge run :body "true"))
DEED
bad bash "$ROOT/scripts/check-mustfile-structure.sh" "$F"
bad bash "$ROOT/scripts/run-mustfile.sh" "$F"

cat >"$F" <<'DEED'
;; SPDX-License-Identifier: MPL-2.0
(praxis-deed :schema-version "1.0.0"
  (check :id a :severity critical :discharge run :body ""))
DEED
bad bash "$ROOT/scripts/check-mustfile-structure.sh" "$F"
bad bash "$ROOT/scripts/run-mustfile.sh" "$F"

# Invalid grammar must fail before execution, too.
printf 'not a deed\n' > "$F"
bad bash "$ROOT/scripts/check-mustfile-structure.sh" "$F"
bad bash "$ROOT/scripts/run-mustfile.sh" "$F"

echo 'PASS: Mustfile DEED grammar, semantics and runtime regressions'
