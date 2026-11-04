#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# Regression test for scripts/check-retired-names.sh — the mechanical half of a
# repository rename (0-canon/CANONICAL-NAMES.adoc § "What a repository rename
# mechanically entails").
#
# The load-bearing properties, in order:
#   * a repository with no register is a NO-OP, not a failure (most of the
#     estate has never renamed anything);
#   * a register with no entries is a FAILURE under --strict (a rename with no
#     record is the state the gate exists to prevent);
#   * a surviving retired name fails --strict and passes report-only;
#   * the allowlist is an exact-path historical record, not a glob escape hatch;
#   * --spellings finds a spelling the register did not enumerate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-retired-names.sh"

[ -f "$SCRIPT" ] || { echo "FATAL: cannot locate $SCRIPT" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

NEW_REPO="$(mktemp -d)"
trap 'rm -rf "$NEW_REPO"' EXIT

mk() { # mk <dir> — a fresh git repository with one committed file
  local d="$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@example.invalid && git config user.name t )
}

run() { # run <dir> [args...]
  local d="$1"; shift
  ( cd "$d" && bash "$SCRIPT" "$@" 2>&1 )
}

# ── 1. no register => no-op ──────────────────────────────────────────────────
mk "$NEW_REPO/plain"
printf 'nothing to see\n' > "$NEW_REPO/plain/README.adoc"
( cd "$NEW_REPO/plain" && git add -A && git commit -qm base )
out=$(run "$NEW_REPO/plain"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'no retired-name register'; then
  ok "no register is a clean no-op"
else
  bad "no register should be a no-op (rc=$rc)"; printf '%s\n' "$out"
fi

# ── 2. empty register under --strict => failure ─────────────────────────────
mk "$NEW_REPO/empty"
mkdir -p "$NEW_REPO/empty/docs/naming"
cat > "$NEW_REPO/empty/docs/naming/retired-names.txt" <<'EOF'
# The register exists but records nothing.
EOF
( cd "$NEW_REPO/empty" && git add -A && git commit -qm base )
out=$(run "$NEW_REPO/empty" --strict); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'declares no retired names'; then
  ok "empty register fails under --strict"
else
  bad "empty register should fail under --strict (rc=$rc)"; printf '%s\n' "$out"
fi

# ── 3. surviving retired name: report-only passes, --strict fails ───────────
mk "$NEW_REPO/dirty"
mkdir -p "$NEW_REPO/dirty/docs/naming" "$NEW_REPO/dirty/src"
cat > "$NEW_REPO/dirty/docs/naming/retired-names.txt" <<'EOF'
JuliaPackage-Reuse-Audit.jl
juliapackage-reuse-audit
EOF
printf 'const OLD = "juliapackage-reuse-audit_init"\n' > "$NEW_REPO/dirty/src/ffi.zig"
( cd "$NEW_REPO/dirty" && git add -A && git commit -qm base )

out=$(run "$NEW_REPO/dirty"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'report-only'; then
  ok "tree mode defaults to report-only"
else
  bad "tree mode should be report-only by default (rc=$rc)"; printf '%s\n' "$out"
fi

out=$(run "$NEW_REPO/dirty" --strict); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'src/ffi.zig'; then
  ok "--strict fails and names the offending file"
else
  bad "--strict should fail naming src/ffi.zig (rc=$rc)"; printf '%s\n' "$out"
fi

# ── 4. allowlist is an exact path, not a prefix ─────────────────────────────
cat > "$NEW_REPO/dirty/docs/naming/retired-names-allowlist.txt" <<'EOF'
# The changelog records the rename.
CHANGELOG.adoc
EOF
printf 'Renamed from JuliaPackage-Reuse-Audit.jl\n' > "$NEW_REPO/dirty/CHANGELOG.adoc"
( cd "$NEW_REPO/dirty" && git add -A && git commit -qm allow )

out=$(run "$NEW_REPO/dirty" --strict); rc=$?
if [ "$rc" -eq 1 ] && ! printf '%s' "$out" | grep -q 'CHANGELOG.adoc:'; then
  ok "allowlisted file is exempt and the real violation still fails"
else
  bad "allowlist exemption wrong (rc=$rc)"; printf '%s\n' "$out"
fi

# A path that merely STARTS with an allowlisted path must not be exempt.
printf 'juliapackage-reuse-audit again\n' > "$NEW_REPO/dirty/CHANGELOG.adoc.bak"
( cd "$NEW_REPO/dirty" && git add -A && git commit -qm bak )
out=$(run "$NEW_REPO/dirty" --strict); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'CHANGELOG.adoc.bak'; then
  ok "allowlist does not act as a path prefix"
else
  bad "allowlist acted as a prefix (rc=$rc)"; printf '%s\n' "$out"
fi
rm -f "$NEW_REPO/dirty/CHANGELOG.adoc.bak"
( cd "$NEW_REPO/dirty" && git add -A && git commit -qm rm-bak >/dev/null 2>&1 || true )

# ── 4b. a retired name in a DIRECTORY or FILE NAME is a violation ───────────
mk "$NEW_REPO/pathname"
mkdir -p "$NEW_REPO/pathname/docs/naming" "$NEW_REPO/pathname/juliapackage-reuse-audit-old"
cat > "$NEW_REPO/pathname/docs/naming/retired-names.txt" <<'EOF'
juliapackage-reuse-audit
EOF
printf 'clean contents\n' > "$NEW_REPO/pathname/juliapackage-reuse-audit-old/README.adoc"
( cd "$NEW_REPO/pathname" && git add -A && git commit -qm base )
out=$(run "$NEW_REPO/pathname" --strict); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'retired name in the path itself'; then
  ok "a retired name in a path name is a violation"
else
  bad "path-name scan missed the retired directory name (rc=$rc)"; printf '%s\n' "$out"
fi

# ── 5. --spellings finds a spelling the register never listed ───────────────
mk "$NEW_REPO/spell"
mkdir -p "$NEW_REPO/spell/docs/naming" "$NEW_REPO/spell/docs"
cat > "$NEW_REPO/spell/docs/naming/retired-names.txt" <<'EOF'
juliapackage-reuse-audit
EOF
# The register lists the hyphenated lowercase spelling only; the tree carries
# the underscore-upper variant a literal scan cannot see.
printf 'See JULIAPACKAGE_REUSE_AUDIT for the old tool name.\n' > "$NEW_REPO/spell/docs/notes.adoc"
( cd "$NEW_REPO/spell" && git add -A && git commit -qm base )

out=$(run "$NEW_REPO/spell" --spellings); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'unregistered spelling'; then
  ok "--spellings reports a spelling the register missed, without failing"
else
  bad "--spellings missed the unregistered spelling (rc=$rc)"; printf '%s\n' "$out"
fi

# ── 6. diff mode: inherited text passes, an added line fails ────────────────
mk "$NEW_REPO/diffmode"
mkdir -p "$NEW_REPO/diffmode/docs/naming"
cat > "$NEW_REPO/diffmode/docs/naming/retired-names.txt" <<'EOF'
juliapackage-reuse-audit
EOF
printf 'grandfathered juliapackage-reuse-audit mention\n' > "$NEW_REPO/diffmode/legacy.txt"
( cd "$NEW_REPO/diffmode" && git add -A && git commit -qm base )
out=$(run "$NEW_REPO/diffmode" --diff HEAD); rc=$?
if [ "$rc" -eq 0 ]; then
  ok "diff mode ignores inherited text"
else
  bad "diff mode failed on inherited text (rc=$rc)"; printf '%s\n' "$out"
fi

printf 'juliapackage-reuse-audit added now\n' > "$NEW_REPO/diffmode/new.txt"
( cd "$NEW_REPO/diffmode" && git add -A && git commit -qm add )
out=$(run "$NEW_REPO/diffmode" --diff HEAD~1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'new.txt'; then
  ok "diff mode fails on an added retired name"
else
  bad "diff mode missed an added retired name (rc=$rc)"; printf '%s\n' "$out"
fi

# ── 6b. diff mode: an added PATH is a reintroduction too ────────────────────
# `+++ b/` used to be bookkeeping only, so a clean file added inside a
# retired-name directory passed diff mode while whole-tree mode rejected the
# identical tree. A rename that re-adds the old directory is the common case.
mkdir -p "$NEW_REPO/diffmode/juliapackage-reuse-audit"
printf 'clean contents\n' > "$NEW_REPO/diffmode/juliapackage-reuse-audit/README.adoc"
( cd "$NEW_REPO/diffmode" && git add -A && git commit -qm addpath )
out=$(run "$NEW_REPO/diffmode" --diff HEAD~1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'added path'; then
  ok "diff mode fails on an added path carrying a retired name"
else
  bad "diff mode missed a retired name in an added path (rc=$rc)"; printf '%s\n' "$out"
fi

# A modified inherited path is not a new path, even when its content changes.
printf 'another clean line\n' >> "$NEW_REPO/diffmode/juliapackage-reuse-audit/README.adoc"
out=$(run "$NEW_REPO/diffmode" --diff HEAD); rc=$?
if [ "$rc" -eq 0 ]; then
  ok "diff mode permits clean edits to an inherited retired-name path"
else
  bad "diff mode rejected an inherited path (rc=$rc)"; printf '%s\n' "$out"
fi
( cd "$NEW_REPO/diffmode" && git add -A && git commit -qm editpath )

# Binary additions have no +++ text header; use a path containing spaces too.
printf 'binary\0content\n' > "$NEW_REPO/diffmode/juliapackage-reuse-audit/binary file.bin"
git -C "$NEW_REPO/diffmode" add -A
out=$(run "$NEW_REPO/diffmode" --diff HEAD); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'added path juliapackage-reuse-audit/binary file.bin'; then
  ok "diff mode detects an added binary path with spaces"
else
  bad "diff mode missed an added binary path (rc=$rc)"; printf '%s\n' "$out"
fi
git -C "$NEW_REPO/diffmode" commit -qm binary

printf 'rename content\n' > "$NEW_REPO/diffmode/clean-source.txt"
( cd "$NEW_REPO/diffmode" && git add -A && git commit -qm source && git mv clean-source.txt juliapackage-reuse-audit/renamed.txt )
out=$(run "$NEW_REPO/diffmode" --diff HEAD); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'added path juliapackage-reuse-audit/renamed.txt'; then
  ok "diff mode detects a renamed destination path"
else
  bad "diff mode missed a renamed destination (rc=$rc)"; printf '%s\n' "$out"
fi

# ── 6c. diff mode: an unresolvable base is a failure, not a clean tree ──────
# The old pipeline discarded `git diff`'s status inside a process substitution
# and suppressed its stderr, so a typo or a shallow checkout produced zero
# lines and the gate printed OK.
out=$(run "$NEW_REPO/diffmode" --diff no-such-ref-xyz); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'does not resolve'; then
  ok "diff mode fails closed on an unresolvable base"
else
  bad "unresolvable diff base should exit 2 (rc=$rc)"; printf '%s\n' "$out"
fi

# ── 6d. --spellings normalises the PATH, not only the contents ──────────────
# A capitalisation (`JuliaPackage_Reuse_Audit/`) is in the gate's reach; the
# old pass tokenised file contents only, so one underscore moved the finding
# outside the scan.
mkdir -p "$NEW_REPO/spell/JuliaPackage_Reuse_Audit"
mkdir -p "$NEW_REPO/spell/docs/naming"
printf 'juliapackage-reuse-audit\n' > "$NEW_REPO/spell/docs/naming/retired-names.txt"
printf 'clean contents\n' > "$NEW_REPO/spell/JuliaPackage_Reuse_Audit/README.adoc"
( cd "$NEW_REPO/spell" && git init -q && git config user.email t@example.invalid && git config user.name t && git add -A && git commit -qm base )
out=$(run "$NEW_REPO/spell" --spellings); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'in the PATH'; then
  ok "spellings scan normalises the path"
else
  bad "spellings scan missed a spelling in the path (rc=$rc)"; printf '%s\n' "$out"
fi

# ── 7. usage errors are exit 2, and the register location is configurable ───
out=$(run "$NEW_REPO/plain" --nonsense); rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown flag exits 2"; else bad "unknown flag should exit 2 (rc=$rc)"; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
