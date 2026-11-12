#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# k9-validate.sh — the CANONICAL K9 conformance validator.
#
# Implements 1-formats/k9/spec/K9-CONTRACT-SPEC.adoc v1.0.0 against the
# normative contract 1-formats/k9/spec/contract/k9_contract.ncl.
#
# ── WHY THIS IS LAYERED ─────────────────────────────────────────────────
#
# Four layers, each with a different authority. Collapsing them is how a
# lexical check quietly becomes an execution licence, which is the failure
# mode §12 of the spec exists to prevent.
#
#   L0  ENVELOPE      bytes only. Magic, encoding, line endings, SPDX, and the
#                     dialect discriminator. Always runnable: no toolchain.
#   L1  STRUCTURAL    a bounded lexical scan of the Nickel body for the fields
#                     the contract requires. Always runnable. PROVISIONAL:
#                     it is a screen, not a decision procedure, and §12.3
#                     forbids reporting conformance on L1 alone.
#   L2  SEMANTIC      the real thing — `nickel typecheck` of the envelope-
#                     stripped body against k9_contract.ncl. Needs `nickel`.
#   L3  CRYPTOGRAPHIC Ed25519 verification of the signature block. Needs an
#                     external verifier this script deliberately does not
#                     embed. Absent one, it reports 'Not_Run and says so.
#
# A check that could not run is reported as SKIPPED, never as a pass. With
# --strict, a SKIP fails the run. That is the defence against the estate's
# recurring "gate that could never fire" defect (standards#49, #64): a
# validator with no toolchain must not be able to report green.
#
# ── RULE IDS ────────────────────────────────────────────────────────────
# Every finding carries a stable id (K9-E*, K9-S*, K9-N*, K9-C*) so a fixture
# can name the rule it violates and a migration can name the rule it clears.
#
# ── USAGE ───────────────────────────────────────────────────────────────
#   k9-validate.sh [OPTIONS] FILE...
#   k9-validate.sh --fixtures DIR     valid/ must pass, invalid/ must fail
#   k9-validate.sh --self-test        built-in assertions, no fixtures needed
#
# OPTIONS
#   --layer L0|L1|L2|L3|all   run up to this layer (default: all)
#   --strict                  a SKIPPED check fails the run (exit 3)
#   --json                    one JSON object per file on stdout
#   --nickel PATH             the nickel binary (default: $K9_NICKEL or PATH)
#   --no-route                do not route out-of-scope dialects; report them
#   -q, --quiet               findings only
#
# EXIT  0 conforming · 1 violation · 2 usage error · 3 skipped under --strict
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SPEC_DIR="$(cd -- "$SCRIPT_DIR/../spec" && pwd)"
# K9_CONTRACT is a TEST SEAM and nothing else. K9-N002 says "the normative
# contract itself does not typecheck", and the only way to prove that check can
# still fire is to point the validator at a contract that is broken — which
# cannot be a committed file, because a broken committed contract breaks
# everything. --self-test uses this to do exactly that. No CI lane sets it: if
# it were set in production the gate would validate against whatever it was
# pointed at, so the self-test also asserts the default is the canonical path.
CONTRACT="$SPEC_DIR/contract/k9_contract.ncl"

CONTRACT_VERSION="1.0.0"
SCHEMA_MAJOR="1"

# §7 — the closed leash set. Mirrors k9_contract.ncl `leash_levels`; the
# --self-test mode asserts the two agree, so the mirror cannot drift.
# Values are carried TAGGED ('Kennel) because that is how they are written in
# a pedigree, and the comparison is against what the file says.
LEASH_LEVELS="'Kennel 'Yard 'Hunt"

# §8.1 — the closed core capability set. Mirrors `core_capabilities`.
CORE_CAPABILITIES="fs.read fs.write net.fetch process.spawn container.run secret.read deploy.apply rollback.apply"
EXTENSION_PREFIX="x-"

# The same two closed lists are also written down in the host-side files
# leash.ncl and capabilities.ncl, which this validator never loads — they carry
# `detect_level`, `check_level` and the handshake records a contract file has no
# business holding. MIGRATION-1058 M6 states that "--self-test asserts the
# mirrors agree, so it cannot drift silently". That was true of the bash
# constants above and false of these two files: nothing read them. --self-test
# now does.
K9_DIR="$(cd -- "$SPEC_DIR/.." && pwd)"
LEASH_NCL="$K9_DIR/leash.ncl"
CAPABILITIES_NCL="$K9_DIR/capabilities.ncl"

LAYER="all"
STRICT=0
JSON=0
QUIET=0
ROUTE=1
NICKEL="${K9_NICKEL:-}"
FIXTURES=""
SELFTEST=0

usage() { sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --layer) LAYER="${2:?--layer needs L0|L1|L2|L3|all}"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --json) JSON=1; shift ;;
    --nickel) NICKEL="${2:?--nickel needs a path}"; shift 2 ;;
    --no-route) ROUTE=0; shift ;;
    --fixtures) FIXTURES="${2:?--fixtures needs a directory}"; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "k9-validate: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done

case "$LAYER" in
  L0|L1|L2|L3|all) : ;;
  *) echo "k9-validate: --layer must be L0, L1, L2, L3 or all" >&2; exit 2 ;;
esac

layer_reached() {
  case "$LAYER" in
    all|L3) return 0 ;;
    L2) [ "$1" != "L3" ] ;;
    L1) [ "$1" = "L0" ] || [ "$1" = "L1" ] ;;
    L0) [ "$1" = "L0" ] ;;
  esac
}

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
[ -t 1 ] || { RED=''; GRN=''; YEL=''; BLU=''; NC=''; }

note() { [ "$QUIET" -eq 1 ] || [ "$JSON" -eq 1 ] || echo -e "${BLU}[k9]${NC} $*"; }

# ── per-file state ───────────────────────────────────────────────────────
F=""
DIALECT=""
HAS_MAGIC=0
ERRORS=0
WARNINGS=0
SKIPS=0
FINDINGS=()

err()  { FINDINGS+=("error|$1|$2|$3");   ERRORS=$((ERRORS + 1)); }
warn() { FINDINGS+=("warning|$1|$2|$3"); WARNINGS=$((WARNINGS + 1)); }
skip() { FINDINGS+=("skipped|$1|$2|$3"); SKIPS=$((SKIPS + 1)); }

emit_findings() {
  local f sev rule lay msg
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    [ -z "$f" ] && continue
    IFS='|' read -r sev rule lay msg <<< "$f"
    case "$sev" in
      error)   echo -e "${RED}ERROR${NC}   $rule [$lay] $F: $msg" >&2 ;;
      warning) echo -e "${YEL}WARN${NC}    $rule [$lay] $F: $msg" >&2 ;;
      skipped) echo -e "${YEL}SKIPPED${NC} $rule [$lay] $F: $msg" >&2 ;;
    esac
  done
}

emit_json() {
  local verdict="$1" f first=1 sev rule lay msg
  printf '{"file":"%s","dialect":"%s","contract_version":"%s","verdict":"%s","errors":%d,"warnings":%d,"skipped":%d,"findings":[' \
    "$F" "$DIALECT" "$CONTRACT_VERSION" "$verdict" "$ERRORS" "$WARNINGS" "$SKIPS"
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    [ -z "$f" ] && continue
    IFS='|' read -r sev rule lay msg <<< "$f"
    [ $first -eq 0 ] && printf ','
    first=0
    printf '{"severity":"%s","rule":"%s","layer":"%s","message":"%s"}' \
      "$sev" "$rule" "$lay" \
      "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  done
  printf ']}\n'
}

# ── the structural extractor ─────────────────────────────────────────────
#
# A bounded lexical scan emitting `FACT <path> <value>` and
# `ARRAY <path> <item>` triples for the Nickel body. It tracks brace/bracket
# depth to build a dotted path, which is what lets it tell
# `pedigree.security.leash` apart from a stray top-level `leash`.
#
# KNOWN LIMITATIONS, all deliberate and all of them the reason L1 is
# provisional rather than authoritative (§12.3):
#   * comments are stripped from the first `#`, so a `#` inside a string is
#     mis-handled;
#   * `m%" ... "%` multiline strings are skipped wholesale, so a key inside
#     one is not reported;
#   * a key and its `{` on separate lines are not joined.
# None of these can turn a non-conforming file into a PASS at L2, because L2
# re-derives every one of these facts from Nickel itself.
extract_facts() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function path(   i, p) { p = ""; for (i = 1; i <= depth; i++) p = p (i > 1 ? "." : "") stk[i]; return p }
    BEGIN { depth = 0; in_ml = 0 }
    {
      line = $0
      if (in_ml) { if (line ~ /"%/) in_ml = 0; next }
      if (line ~ /m%"/ && line !~ /"%/) { in_ml = 1; next }

      sub(/[ \t]*#.*$/, "", line)
      line = trim(line)
      if (line == "") next

      if (line ~ /^[\}\]][,;]?$/) { if (depth > 0) depth--; next }

      if (match(line, /^[A-Za-z_][A-Za-z0-9_."-]*[ \t]*=/)) {
        eq = index(line, "=")
        key = trim(substr(line, 1, eq - 1))
        gsub(/^"|"$/, "", key)
        val = trim(substr(line, eq + 1))
        sub(/[,;]$/, "", val)
        p = path()
        full = (p == "" ? key : p "." key)

        if (val ~ /\{$/)      { print "FACT\t" full "\t{"; stk[++depth] = key; next }
        if (val ~ /\[$/)      { print "FACT\t" full "\t["; stk[++depth] = key; next }

        # Single-line record: `metadata = { name = "x" }`. Split the inner
        # text on commas and emit one FACT per pair. A nested record inside a
        # one-liner would be mis-split; that is a documented L1 limitation.
        if (val ~ /^\{.*\}$/) {
          inner = substr(val, 2, length(val) - 2)
          m = split(inner, parts, ",")
          for (i = 1; i <= m; i++) {
            kv = trim(parts[i])
            e2 = index(kv, "=")
            if (kv == "" || e2 == 0) continue
            k2 = trim(substr(kv, 1, e2 - 1)); gsub(/^"|"$/, "", k2)
            print "FACT\t" full "." k2 "\t" trim(substr(kv, e2 + 1))
          }
          next
        }

        # Single-line array: `capabilities = ["a", "b"]` or `side_effects = []`.
        if (val ~ /^\[.*\]$/) {
          inner = substr(val, 2, length(val) - 2)
          m = split(inner, parts, ",")
          for (i = 1; i <= m; i++) {
            it = trim(parts[i])
            if (it != "") print "ARRAY\t" full "\t" it
          }
          next
        }

        print "FACT\t" full "\t" val
        next
      }

      if (depth > 0) {
        item = line
        sub(/[,;]$/, "", item)
        item = trim(item)
        if (item != "") print "ARRAY\t" path() "\t" item
      }
    }
  ' "$1"
}

# fact_get returns the value with any trailing comma already removed, so
# callers compare against `true` rather than `true,`.
fact_get() { awk -F'\t' -v want="$2" '$1 == "FACT" && $2 == want { print $3; exit }' "$1"; }
fact_paths() { awk -F'\t' '$1 == "FACT" { print $2 }' "$1"; }
array_items() { awk -F'\t' -v want="$2" '$1 == "ARRAY" && $2 == want { print $3 }' "$1"; }

unquote() { local s="$1"; s="${s#\"}"; s="${s%\"}"; printf '%s' "$s"; }
is_todo() { case "$1" in *TODO*|*FIXME*|*XXX*) return 0 ;; esac; return 1; }

# ════════════════════════════════════════════════════════════════════════
# L0 — ENVELOPE
# ════════════════════════════════════════════════════════════════════════
# Check the file at $1 for envelope and library-role violations, recording
# them in FINDINGS and ERRORS. Set HAS_MAGIC and DIALECT after the NUL check.
# Return 1 if the NUL check fails or the body is unclaimed; return 2 for the
# coordination dialect, whose grammar is not validated here; otherwise
# return 0. A zero status can still carry violations: callers must inspect
# ERRORS to determine whether the file passed.
check_l0() {
  local f="$1" first head5 body_start

  # K9-E002 — a component is text. A NUL byte means this is not a K9 file.
  if ! LC_ALL=C tr -d '\000' < "$f" | cmp -s - "$f"; then
    err K9-E002 L0 "file contains a NUL byte; not a text K9 component"
    return 1
  fi

  # K9-E003 — LF only. CRLF changes the magic line's bytes as seen by a
  # strict reader, and .gitattributes already mandates eol=repo-wide.
  if LC_ALL=C grep -qU $'\r' "$f"; then
    err K9-E003 L0 "file contains CR; K9 files are LF-only"
  fi

  # K9-E006 — no line longer than 998 octets, not counting the line end
  # (owner ruling I4, 2026-11-12). It is the RFC 5322 §2.1.1 bound and makes
  # the registered "8bit" encoding label exact. Octets, not characters, hence
  # LC_ALL=C; a CR before the LF is the line end (and K9-E003's business).
  local long
  long="$(LC_ALL=C awk '{ sub(/\r$/, "") } length($0) > 998 { print NR ":" length($0); exit }' "$f")"
  if [ -n "$long" ]; then
    err K9-E006 L0 "line ${long%%:*} is ${long#*:} octets; the limit is 998"
  fi

  # K9-E001 — the magic line. §3.1: exactly the three octets 0x4B 0x39 0x21
  # and nothing else on the line. `K9`, `k9!` and `K9! ` are all rejected: a
  # magic number with a tolerance is not a magic number.
  first="$(head -n 1 "$f")"
  if [ "$first" = 'K9!' ]; then
    HAS_MAGIC=1
  else
    HAS_MAGIC=0
    if printf '%s' "$first" | grep -qE '^[Kk]9!?[[:space:]]*$'; then
      err K9-E001 L0 "line 1 is '$first', not exactly 'K9!'"
    fi
  fi

  # K9-E004 — SPDX within the first five lines. Envelope metadata, so an L0
  # concern, and an ERROR: the estate licence gate treats a missing
  # identifier as a defect, not a nicety.
  head5="$(head -n 5 "$f")"
  if ! printf '%s\n' "$head5" | grep -q '^#[[:space:]]*SPDX-License-Identifier:'; then
    err K9-E004 L0 "no SPDX-License-Identifier in the first 5 lines"
  fi

  # K9-E005 — the dialect discriminator (§4.3). After the magic line and the
  # comment header, the first significant line decides the dialect. `{`, `[`,
  # `(`, `let`, a string, or a top-level `ident =` binding is a Nickel term. A
  # bare `key:` line (no `=`) or a `---` marker is YAML: with the magic line it
  # is routed to the coordination dialect, without it it claims nothing.
  #
  # `---` is NOT a coordination construct. Ruling D318 (coordination grammar
  # v1.1.1) keeps it invalid, so a magic-bearing file that opens with one is
  # routed to that grammar to be REJECTED there, as a malformed coordination
  # file rather than an unclaimed one. Before this fix a `---` file with no
  # magic was routed too, though the grammar requires `K9!` and so could never
  # accept it: every plain YAML document carrying a `.k9` suffix was waved
  # through as "out of scope" instead of failing K9-E005.
  if [ "$HAS_MAGIC" -eq 1 ]; then
    body_start="$(sed -n '2,$p' "$f" | grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*$' | head -n 1)"
  else
    body_start="$(grep -vE '^[[:space:]]*#' "$f" | grep -vE '^[[:space:]]*$' | head -n 1)"
  fi

  if printf '%s' "$body_start" | grep -qE '^-{3}'; then
    if [ "$HAS_MAGIC" -eq 1 ]; then DIALECT="coordination"; else DIALECT="unclaimed"; fi
  elif printf '%s' "$body_start" | grep -qE '^(\{|\[|\(|let[[:space:]]|")'; then
    if [ "$HAS_MAGIC" -eq 1 ]; then DIALECT="component"; else DIALECT="library"; fi
  elif printf '%s' "$body_start" | grep -qE '^[A-Za-z_][A-Za-z0-9_."-]*[[:space:]]*='; then
    # A Nickel binding. Note that a Nickel FILE must still be a single term,
    # so a top-level binding sequence is a defect — but it is a Nickel defect
    # and belongs at L1/L2, not to a dialect mismatch.
    if [ "$HAS_MAGIC" -eq 1 ]; then DIALECT="component"; else DIALECT="library"; fi
  elif printf '%s' "$body_start" | grep -qE '^[A-Za-z_][A-Za-z0-9_.-]*:'; then
    # A `key:` line: the coordination dialect permits one, and so did the
    # unclaimed session-management PROTOCOL.k9 stubs (renamed to PROTOCOL.yaml
    # by migration item M2). Only the magic line separates the two, so with no
    # magic this file claims nothing.
    if [ "$HAS_MAGIC" -eq 1 ]; then DIALECT="coordination"; else DIALECT="unclaimed"; fi
  else
    DIALECT="unclaimed"
  fi

  if [ "$DIALECT" = "unclaimed" ]; then
    if [ "$ROUTE" -eq 1 ]; then
      err K9-E005 L0 "suffix claims K9 but the body is neither a Nickel term nor the coordination dialect (first significant line: '${body_start:-<empty>}')"
    else
      err K9-E005 L0 "suffix claims K9 but the body is neither a Nickel term nor the coordination dialect"
    fi
    return 1
  fi

  if [ "$DIALECT" = "coordination" ]; then
    note "$f: dialect k9-coordination — governed by coordination-k9-grammar_v1.2.abnf, out of scope here"
    return 2
  fi

  # K9-S012 / K9-S014 — the envelope/role rule, checked at L0 because it IS
  # about the envelope. §11.2: an execution licence in a file with no magic is
  # unenforceable, because nothing downstream can detect it.
  if [ "$DIALECT" = "library" ]; then
    if grep -qE '^[[:space:]]{0,2}pedigree[[:space:]]*=' "$f"; then
      err K9-S012 L0 "no 'K9!' envelope but a top-level pedigree: a component without an envelope cannot be leashed"
    fi
    if grep -qE '^[[:space:]]{0,2}leash[[:space:]]*=' "$f"; then
      err K9-S014 L0 "no 'K9!' envelope but a top-level leash claim; a leash belongs in pedigree.security"
    fi
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════
# L1 — STRUCTURAL (lexical, PROVISIONAL)
# ════════════════════════════════════════════════════════════════════════
check_l1() {
  local f="$1" facts sv ct leash name lvl cap req deficit side n sig_req
  facts="$(mktemp)"
  extract_facts "$f" > "$facts"

  if [ "$DIALECT" = "library" ]; then
    # §11 — a library has no pedigree to check. Its obligations are the
    # negative one already enforced at L0, plus resolvable imports.
    check_imports "$f"
    rm -f "$facts"
    return 0
  fi

  # K9-S001 — a component declares a pedigree.
  if [ -z "$(fact_get "$facts" pedigree)" ]; then
    err K9-S001 L1 "no top-level 'pedigree' block"
    rm -f "$facts"
    return 0
  fi

  # K9-S002 — schema_version, and its major must match this contract's.
  sv="$(unquote "$(fact_get "$facts" pedigree.schema_version)")"
  if [ -z "$sv" ]; then
    err K9-S002 L1 "pedigree.schema_version is missing"
  else
    case "$sv" in
      "$SCHEMA_MAJOR".*)
        case "$sv" in
          *[!0-9.]*) err K9-S002 L1 "pedigree.schema_version '$sv' is not a numeric dot-triple" ;;
          *) : ;;
        esac ;;
      *) err K9-S002 L1 "pedigree.schema_version '$sv' is not readable by contract v$CONTRACT_VERSION (needs major $SCHEMA_MAJOR)" ;;
    esac
  fi

  # K9-S003 — component_type is required and must not be a placeholder.
  ct="$(unquote "$(fact_get "$facts" pedigree.component_type)")"
  if [ -z "$ct" ]; then
    err K9-S003 L1 "pedigree.component_type is missing (required by contract v$CONTRACT_VERSION §6.2)"
  elif is_todo "$ct"; then
    err K9-S003 L1 "pedigree.component_type is an unfilled placeholder: '$ct'"
  fi

  # K9-S004 — the leash tag must be in the closed set. Compared TAGGED, so
  # the message quotes exactly what the file says.
  leash="$(fact_get "$facts" pedigree.security.leash)"
  if [ -z "$leash" ]; then
    err K9-S004 L1 "pedigree.security.leash is missing"
  else
    lvl=0
    for l in $LEASH_LEVELS; do [ "$l" = "$leash" ] && lvl=1; done
    [ $lvl -eq 0 ] && err K9-S004 L1 "leash '$leash' is not in the closed set {$LEASH_LEVELS}"
  fi

  # K9-S014 — a leash claim outside pedigree.security. Same rule as the L0
  # library check, but reachable from a component too: a file may carry the
  # envelope and still declare its level somewhere no host reads. This is the
  # live shape of 9-archive/rhodium-standard-repositories/rsr-compliance-checklist.k9.ncl.
  if [ -n "$(fact_get "$facts" leash)" ]; then
    err K9-S014 L1 "top-level 'leash = $(fact_get "$facts" leash)' outside pedigree.security; a leash declared there is read by nothing"
  fi

  # K9-S005 — metadata.name.
  name="$(unquote "$(fact_get "$facts" pedigree.metadata.name)")"
  if [ -z "$name" ]; then
    err K9-S005 L1 "pedigree.metadata.name is missing"
  elif is_todo "$name"; then
    err K9-S005 L1 "pedigree.metadata.name is an unfilled placeholder: '$name'"
  fi

  # K9-S006 — every granted capability is a core name or an x- extension.
  while IFS= read -r cap; do
    [ -z "$cap" ] && continue
    cap="$(unquote "$cap")"
    if ! capability_ok "$cap"; then
      err K9-S006 L1 "capability '$cap' is neither a core name nor an '${EXTENSION_PREFIX}<vendor>.<path>' extension"
    fi
  done < <(array_items "$facts" pedigree.security.capabilities)

  # K9-S007 — the grant must cover what the security flags ask for.
  req="$(required_capabilities "$facts")"
  deficit=""
  for r in $req; do
    if ! array_items "$facts" pedigree.security.capabilities | grep -qxF "\"$r\""; then
      deficit="$deficit $r"
    fi
  done
  if [ -n "$deficit" ]; then
    err K9-S007 L1 "security flags request capabilities the grant does not cover:$deficit (default-deny: list them in pedigree.security.capabilities)"
  fi

  # K9-S008 / K9-S009 / K9-S010 — the Hunt-specific obligations. None of
  # these is relaxed relative to SPEC.adoc; K9-S007 and K9-S010 are new and
  # both make Hunt harder to reach, not easier.
  if [ "$leash" = "'Hunt" ]; then
    sig_req="$(fact_get "$facts" pedigree.security.signature_required)"
    if [ "$sig_req" != "true" ]; then
      err K9-S008 L1 "leash is 'Hunt but pedigree.security.signature_required is not true"
    fi
    # PRESENCE ONLY. This proves the file carries a signature block. It says
    # nothing about whether that signature verifies — that is K9-C001.
    if [ -z "$(fact_get "$facts" pedigree.signature)" ]; then
      err K9-S009 L1 "leash is 'Hunt but no pedigree.signature block is present (presence required here; verification is K9-C001)"
    fi
    n="$(array_items "$facts" pedigree.side_effects | grep -c . || true)"
    if [ "${n:-0}" -eq 0 ]; then
      err K9-S010 L1 "leash is 'Hunt but pedigree.side_effects is empty: full access must be described"
    else
      while IFS= read -r side; do
        [ -z "$side" ] && continue
        side="$(unquote "$side")"
        if is_todo "$side"; then
          err K9-S010 L1 "pedigree.side_effects contains an unfilled placeholder: $side"
        fi
      done < <(array_items "$facts" pedigree.side_effects)
    fi
  fi

  # K9-S011 — a recipes block is an execution surface, so it forces 'Hunt.
  if [ -n "$(fact_paths "$facts" | grep -E '^recipes(\.|$)' | head -n 1)" ] \
    && [ "$leash" != "'Hunt" ]; then
    err K9-S011 L1 "component declares a 'recipes' block at leash $leash; recipes are an execution surface and require 'Hunt"
  fi

  check_imports "$f"
  rm -f "$facts"
  return 0
}

capability_ok() {
  local n="$1" c
  for c in $CORE_CAPABILITIES; do [ "$c" = "$n" ] && return 0; done
  case "$n" in
    "$EXTENSION_PREFIX".*) return 1 ;;   # "x-.foo" has no vendor segment
    "$EXTENSION_PREFIX"*.*) return 0 ;;
  esac
  return 1
}

# §8.4 — capabilities the security flags request. Mirrors
# k9_contract.ncl `required_capabilities`; --self-test exercises both.
required_capabilities() {
  local facts="$1" out=""
  [ "$(fact_get "$facts" pedigree.security.allow_network)" = "true" ] && out="$out net.fetch"
  [ "$(fact_get "$facts" pedigree.security.allow_filesystem_write)" = "true" ] && out="$out fs.write"
  [ "$(fact_get "$facts" pedigree.security.allow_subprocess)" = "true" ] && out="$out process.spawn"
  printf '%s' "${out# }"
}

# §11.4 — every import must resolve. A dangling import is not a style
# problem: the component's pedigree is built by merging the imported file, so
# an unresolvable import means the pedigree a reviewer read is not the
# pedigree a host would evaluate.
check_imports() {
  local f="$1" dir imp cand
  dir="$(dirname "$f")"
  while IFS= read -r imp; do
    [ -z "$imp" ] && continue
    cand="$dir/$imp"
    if [ ! -f "$cand" ]; then
      err K9-S013 L1 "import \"$imp\" does not resolve to $cand"
    fi
  done < <(sed 's/#.*//' "$f" | grep -oE 'import[[:space:]]+"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/')
}

# ════════════════════════════════════════════════════════════════════════
# L2 — SEMANTIC (Nickel)
# ════════════════════════════════════════════════════════════════════════
nickel_bin() {
  if [ -n "$NICKEL" ]; then
    [ -x "$NICKEL" ] && { printf '%s' "$NICKEL"; return 0; }
    return 1
  fi
  command -v nickel 2>/dev/null && return 0
  return 1
}

# §3.6 — THE ENVELOPE-STRIP RULE.
#
# `K9!` on line 1 is not Nickel: this estate's own CI records that
# `nickel typecheck` dies at 1:3 on the `!` (.github/workflows/ci-pipeline.yml,
# `detect` step), which is why every `*.k9.ncl` here is excluded from Nickel
# checking today. Stripping the magic line — replacing it with a Nickel
# comment so line numbers do not move — is what makes the body checkable at
# all. Nothing about the component's meaning changes: the magic is envelope,
# and the envelope is not part of the term.
strip_envelope() {
  local f="$1" out="$2"
  if [ "$(head -n 1 "$f")" = 'K9!' ]; then
    { echo '# K9! (envelope magic, stripped for Nickel evaluation)'; tail -n +2 "$f"; } > "$out"
  else
    cat "$f" > "$out"
  fi
}

check_l2() {
  local f="$1" nb out body_tmp drv_tmp dir base
  if ! nb="$(nickel_bin)"; then
    skip K9-N001 L2 "nickel not available; Nickel semantics were NOT checked (a skip is not a pass)"
    skip K9-N002 L2 "nickel not available; the normative contract itself was not typechecked"
    return 0
  fi

  # K9-N002 — the contract must typecheck before it judges anything. A broken
  # contract that rejects everything would otherwise look like a very strict
  # validator rather than a broken one.
  if ! out="$("$nb" typecheck "$CONTRACT" 2>&1)"; then
    err K9-N002 L2 "the normative contract does not typecheck: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
    return 0
  fi

  # The stripped body and its driver are written BESIDE the original so that
  # the body's own relative `import`s still resolve. Both are removed on the
  # way out; a crash leaves at most two dotfiles, which is why they are dotted.
  dir="$(dirname "$f")"
  base=".k9-validate.$$.${RANDOM}"
  body_tmp="$dir/$base.body.ncl"
  drv_tmp="$dir/$base.driver.ncl"
  # shellcheck disable=SC2064
  trap "rm -f '$body_tmp' '$drv_tmp'" RETURN

  strip_envelope "$f" "$body_tmp"

  if [ "$DIALECT" = "library" ]; then
    # Static check only. A library is imported, never evaluated as a
    # component, and it may legitimately hold functions, which have no JSON
    # representation — so `export` would fail on a conforming library. What a
    # library must satisfy is the negative contract of §11 (no pedigree, no
    # leash), which L1 already establishes lexically.
    if ! out="$("$nb" typecheck "$body_tmp" 2>&1)"; then
      err K9-N001 L2 "library does not typecheck: $(printf '%s' "$out" | head -n 5 | tr '\n' ' ')"
    fi
  else
    # `k9_doc`, not `doc`: Nickel's lexer reserves `doc` (it is the metadata
    # keyword in `x | doc "..."`), and its `Ident` production admits only `or`,
    # `as` and `include` as contextual keywords. `let doc = ...` is a parse
    # error at the identifier, which is what four positive controls died on.
    # Keyword list: nickel 1.18.0 parser/src/lexer.rs.
    cat > "$drv_tmp" <<EOF
let K9 = import "$CONTRACT" in
let k9_doc = import "./$(basename "$body_tmp")" in
k9_doc | K9.Component
EOF
    # Two Nickel invocations, because they answer different questions.
    #
    # `typecheck` is documented in Nickel's own CLI as "typechecks the program
    # but does not run it". A Nickel CONTRACT (`|`) is enforced when a value
    # flows through it, and a predicate contract such as
    # `std.contract.from_predicate (is_semver_of …)` has no static type the
    # checker could reason about. Running only `typecheck` accepted both L2
    # negative controls — `schema_version = "1.0"` and `allow_network = "yes"`
    # — which is precisely the pair written to prove L2 sees what L1 cannot.
    #
    # `export` evaluates, and evaluation is what applies the contracts.
    if ! out="$("$nb" typecheck "$drv_tmp" 2>&1)"; then
      err K9-N001 L2 "component does not typecheck against K9.Component: $(printf '%s' "$out" | head -n 5 | tr '\n' ' ')"
    fi
    if ! out="$("$nb" export --format json "$drv_tmp" 2>&1 >/dev/null)"; then
      err K9-N001 L2 "component violates the K9.Component contract: $(printf '%s' "$out" | head -n 5 | tr '\n' ' ')"
    fi
  fi
  rm -f "$body_tmp" "$drv_tmp"
  return 0
}

# ════════════════════════════════════════════════════════════════════════
# L3 — CRYPTOGRAPHIC
# ════════════════════════════════════════════════════════════════════════
#
# §10.5 — this validator does NOT verify signatures and must not pretend to.
# Verifying an Ed25519 signature means trusting a key, and key trust is a host
# policy decision, not a file-format rule. What this layer does instead is
# state the consequence: with no verifier the verdict is 'Present_Unverified,
# the Hunt `signature` precondition is FALSE, and Hunt is unauthorised.
check_l3() {
  local f="$1" facts
  [ "$DIALECT" = "library" ] && return 0
  facts="$(mktemp)"
  extract_facts "$f" > "$facts"

  if [ -n "$(fact_get "$facts" pedigree.signature)" ]; then
    if [ -n "${K9_SIG_VERIFIER:-}" ] && [ -x "${K9_SIG_VERIFIER}" ]; then
      if "$K9_SIG_VERIFIER" "$f" >/dev/null 2>&1; then
        note "$f: signature verdict 'Verified (external verifier)"
      else
        err K9-C001 L3 "signature verdict 'Rejected by the external verifier"
      fi
    else
      skip K9-C001 L3 "signature block present but no verifier ran (set K9_SIG_VERIFIER); verdict is 'Present_Unverified, which does NOT authorise 'Hunt"
    fi
  fi
  rm -f "$facts"
  return 0
}

# ════════════════════════════════════════════════════════════════════════
validate_one() {
  F="$1"; DIALECT=""; HAS_MAGIC=0
  ERRORS=0; WARNINGS=0; SKIPS=0; FINDINGS=()
  # F is the logical name (JSON, messages); FP is the path the checks hand to
  # cmp, head, sed, grep and dirname. A name that starts with `-` would be read
  # as an option by those, so it is given a ./ prefix here and nowhere else.
  local FP="$F"
  case "$FP" in -*) FP="./$FP" ;; esac

  if [ ! -f "$FP" ]; then
    err K9-E000 L0 "no such file"
    if [ "$JSON" -eq 1 ]; then emit_json "error"; else emit_findings; fi
    return 1
  fi

  check_l0 "$FP"
  local rc=$?
  if [ $rc -eq 2 ]; then
    # Routed out of scope: examined, and handed to the spec that governs it.
    # That is neither a pass nor a failure of THIS contract.
    [ "$JSON" -eq 1 ] && emit_json "routed"
    return 0
  fi
  if [ "$DIALECT" = "unclaimed" ]; then
    if [ "$JSON" -eq 1 ]; then emit_json "error"; else emit_findings; fi
    return 1
  fi

  layer_reached L1 && check_l1 "$FP"
  layer_reached L2 && check_l2 "$FP"
  layer_reached L3 && check_l3 "$FP"

  local verdict="pass"
  [ "$ERRORS" -gt 0 ] && verdict="fail"
  if [ "$JSON" -eq 1 ]; then
    emit_json "$verdict"
  else
    emit_findings
    if [ "$ERRORS" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
      echo -e "${GRN}OK${NC}      $F (dialect=$DIALECT, warnings=$WARNINGS, skipped=$SKIPS)"
    fi
  fi

  [ "$ERRORS" -gt 0 ] && return 1
  [ "$STRICT" -eq 1 ] && [ "$SKIPS" -gt 0 ] && return 3
  return 0
}

# ════════════════════════════════════════════════════════════════════════
# --self-test — assertions that do not depend on the fixture corpus
# ════════════════════════════════════════════════════════════════════════
SELFTEST_FAILS=0
t() { # t <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo -e "${GRN}ok${NC}   $1"
  else
    echo -e "${RED}FAIL${NC} $1: expected '$2', got '$3'"
    SELFTEST_FAILS=$((SELFTEST_FAILS + 1))
  fi
}
expect_ok()  { if "$@"; then t "$* accepted" ok ok; else t "$* accepted" ok no; fi; }
expect_bad() { if "$@"; then t "$* rejected" no ok; else t "$* rejected" no no; fi; }

# Run built-in assertions for contract mirrors, extraction, validation, and
# dialect routing; return nonzero if any assertion fails.
self_test() {
  local n tmp facts stripped

  echo "== the bash mirrors cannot drift from the normative contract =="
  n="$(grep -oE "leash_levels = \[[^]]*\]" "$CONTRACT" | grep -oE "'[A-Za-z]+" | tr '\n' ' ' | sed 's/ $//')"
  t "leash_levels mirrors k9_contract.ncl" "$LEASH_LEVELS" "$n"
  n="$(awk '/core_capabilities = \[/,/^  \]/' "$CONTRACT" | grep -oE '"[a-z]+\.[a-z]+"' | tr -d '"' | tr '\n' ' ' | sed 's/ $//')"
  t "core_capabilities mirrors k9_contract.ncl" "$CORE_CAPABILITIES" "$n"
  t "contract_version mirrors k9_contract.ncl" "$CONTRACT_VERSION" \
    "$(grep -oE 'contract_version = "[^"]+"' "$CONTRACT" | sed 's/.*"\(.*\)"/\1/')"
  t "schema_major mirrors k9_contract.ncl" "$SCHEMA_MAJOR" \
    "$(grep -oE 'schema_major = "[^"]+"' "$CONTRACT" | sed 's/.*"\(.*\)"/\1/')"

  echo "== the host-side .ncl mirrors cannot drift either (M6) =="
  # Every value below is extracted as DATA — the enum literal and the array
  # literal — and never from a comment, so rewriting the prose that documents
  # a list cannot satisfy the assertion that checks it.
  local cn hp
  t "leash.ncl SecurityLevel mirrors k9_contract.ncl" \
    "$(grep -oE "leash_levels = \[[^]]*\]" "$CONTRACT" | grep -oE "'[A-Za-z]+" | tr '\n' ' ' | sed 's/ $//')" \
    "$(grep -oE "let SecurityLevel = \[\|[^]]*\|\]" "$LEASH_NCL" | grep -oE "'[A-Za-z]+" | tr '\n' ' ' | sed 's/ $//')"
  cn="$(awk '/core_capabilities = \[/,/^  \]/' "$CONTRACT" | grep -oE '"[a-z]+\.[a-z]+"' | tr -d '"' | tr '\n' ' ' | sed 's/ $//')"
  t "capabilities.ncl core mirrors k9_contract.ncl" "$cn" \
    "$(awk '/^  core = \[/,/^  \]/' "$CAPABILITIES_NCL" | grep -oE '"[a-z]+\.[a-z]+"' | tr -d '"' | tr '\n' ' ' | sed 's/ $//')"
  # §9.2 — Hunt needs all five, always. This is a closed set: a precondition
  # removed from the contract must fail here rather than quietly weaken Hunt.
  hp="$(awk '/hunt_preconditions = \[/,/^  \]/' "$CONTRACT" | grep -oE '"[a-z_]+"' | tr -d '"' | tr '\n' ' ' | sed 's/ $//')"
  t "hunt_preconditions is exactly the five, closed (§9.2)" \
    "signature policy sandbox dry_run capability_grant" "$hp"
  # §9.2 — the gate's BEHAVIOUR, not just its list of names. HuntGate.idr
  # proves the gate's properties for a model of authorize_hunt; this checks
  # both Nickel copies compute that model on all 32 evidence inputs (32 x 2 =
  # 64). A skip is not a pass: without nickel this assertion fails.
  local hg nbin
  if nbin="$(nickel_bin)"; then
    hg="$(cd "$SPEC_DIR/proofs" && "$nbin" export hunt-gate-exhaustive.ncl 2>&1 \
      | grep -oE '"cases_checked": [0-9]+' | grep -oE '[0-9]+$' || true)"
  else
    hg="nickel not available"
  fi
  t "authorize_hunt matches the HuntGate.idr model on every input, both copies (§9.2)" \
    "64" "$hg"
  # §7 — the leash taxonomy is likewise closed, in both directions.
  t "the leash taxonomy is exactly three, closed (§7)" \
    "'Kennel 'Yard 'Hunt" \
    "$(grep -oE "leash_levels = \[[^]]*\]" "$CONTRACT" | grep -oE "'[A-Za-z]+" | tr '\n' ' ' | sed 's/ $//')"

  echo "== capability arithmetic (§8) =="
  expect_ok  capability_ok "fs.read"
  expect_ok  capability_ok "rollback.apply"
  expect_ok  capability_ok "x-acme.gpu.alloc"
  expect_bad capability_ok "x-acme"
  expect_bad capability_ok "x-.gpu"
  expect_bad capability_ok "fs.delete"
  expect_bad capability_ok ""

  echo "== the extractor =="
  tmp="$(mktemp --suffix=.k9.ncl)"
  cat > "$tmp" <<'EOF'
K9!
# SPDX-License-Identifier: MPL-2.0
{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "self-test",
    security = {
      leash = 'Kennel,
      allow_network = false,
      allow_filesystem_write = false,
      allow_subprocess = false,
    },
    metadata = { name = "self-test" },
    side_effects = [],
  },
}
EOF
  facts="$(mktemp)"
  extract_facts "$tmp" > "$facts"
  t "extracts pedigree.security.leash" "'Kennel" "$(fact_get "$facts" pedigree.security.leash)"
  t "extracts pedigree.component_type" '"self-test"' "$(fact_get "$facts" pedigree.component_type)"
  t "extracts pedigree.metadata.name" '"self-test"' "$(fact_get "$facts" pedigree.metadata.name)"
  t "pedigree leash is not reported as top-level leash" "" "$(fact_get "$facts" leash)"
  t "required_capabilities for a quiet component" "" "$(required_capabilities "$facts")"

  sed -i.bak 's/allow_network = false/allow_network = true/' "$tmp" && rm -f "$tmp.bak"
  extract_facts "$tmp" > "$facts"
  t "required_capabilities follows allow_network" "net.fetch" "$(required_capabilities "$facts")"

  echo "== the envelope strip keeps line numbers (§3.6) =="
  stripped="$(mktemp --suffix=.ncl)"
  strip_envelope "$tmp" "$stripped"
  t "line 1 becomes a comment" 1 "$(head -n 1 "$stripped" | grep -c '^#')"
  t "line count is preserved" "$(wc -l < "$tmp" | tr -d ' ')" "$(wc -l < "$stripped" | tr -d ' ')"
  t "schema_version stays on line 5" '    schema_version = "1.0.0",' "$(sed -n '5p' "$stripped")"
  rm -f "$tmp" "$facts" "$stripped"

  echo "== a name that starts with '-' is a path, not an option =="
  # The checks hand file names to cmp, head, sed, grep and dirname. A tracked
  # `-x.k9.ncl` must reach the same verdict as `x.k9.ncl`, and the JSON must
  # carry the name as given.
  local dashdir dashjson
  dashdir="$(mktemp -d)"
  cp "$SCRIPT_DIR/fixtures/valid/kennel-data.k9.ncl" "$dashdir/-dash.k9.ncl"
  dashjson="$(cd "$dashdir" && LAYER=L1 JSON=1 QUIET=1 validate_one "-dash.k9.ncl" 2>/dev/null || true)"
  t "dash-leading name: no L0 failure" "" "$(printf '%s' "$dashjson" | grep -o 'K9-E00[0-9]' | head -n 1)"
  t "dash-leading name: verdict pass at L1" 1 "$(printf '%s' "$dashjson" | grep -c '"verdict":"pass"')"
  t "dash-leading name: JSON keeps the logical name" 1 "$(printf '%s' "$dashjson" | grep -c '"file":"-dash.k9.ncl"')"
  rm -rf "$dashdir"

  echo "== L3: signature presence is not verification (§10) =="
  # No fixture can make a verifier appear, so the three verdicts a host can
  # reach are asserted here with a stub verifier instead. What is under test is
  # the code path, not the cryptography: this validator performs none.
  local stub_ok stub_bad hunt out
  stub_ok="$(mktemp)";  printf '#!/bin/sh\nexit 0\n' > "$stub_ok";  chmod +x "$stub_ok"
  stub_bad="$(mktemp)"; printf '#!/bin/sh\nexit 1\n' > "$stub_bad"; chmod +x "$stub_bad"
  hunt="$SCRIPT_DIR/fixtures/valid/hunt-fully-granted.k9.ncl"
  if [ -f "$hunt" ]; then
    QUIET=1
    unset K9_SIG_VERIFIER
    out="$(validate_one "$hunt" 2>&1 || true)"
    t "no verifier -> K9-C001 is SKIPPED, never a pass" 1 \
      "$(printf '%s' "$out" | grep -c 'SKIPPED K9-C001')"
    t "the skip states presence does not authorise 'Hunt" 1 \
      "$(printf '%s' "$out" | grep -c "does NOT authorise")"

    K9_SIG_VERIFIER="$stub_ok"
    out="$(validate_one "$hunt" 2>&1 || true)"
    unset K9_SIG_VERIFIER
    t "verifier accepts -> verdict 'Verified, no K9-C001 finding" 0 \
      "$(printf '%s' "$out" | grep -c 'K9-C001')"

    K9_SIG_VERIFIER="$stub_bad"
    out="$(validate_one "$hunt" 2>&1 || true)"
    unset K9_SIG_VERIFIER
    t "verifier refuses -> K9-C001 error, verdict 'Rejected" 1 \
      "$(printf '%s' "$out" | grep -c "K9-C001.*'Rejected")"

    # The three verdicts above are the *finding*. What they do not assert is
    # the CONSEQUENCE, and the consequence is the whole rule: §9.4 makes
    # `signature` a Hunt precondition, so a verifier that refuses must leave
    # the component non-conforming. An error finding that still exited 0 would
    # let a host treat the verdict as advisory — the same shape as a Hunt gate
    # satisfied by the mere presence of a signature field (§10.4).
    K9_SIG_VERIFIER="$stub_bad"
    local rej_json rej_rc
    QUIET=1; JSON=1
    rej_json="$(validate_one "$hunt" 2>/dev/null)"; rej_rc=$?
    JSON=0; QUIET=0
    unset K9_SIG_VERIFIER
    t "a refused signature exits non-zero" 1 \
      "$([ "$rej_rc" -ne 0 ] && echo 1 || echo 0)"
    t "and the file's verdict is fail, not pass" "fail" \
      "$(printf '%s' "$rej_json" | grep -oE '"verdict":"[a-z]+"' | head -1 | sed 's/.*:"//; s/"//')"
    QUIET=0
  else
    echo -e "${YEL}SKIP${NC} L3 assertions: $hunt not present"
  fi
  rm -f "$stub_ok" "$stub_bad"

  echo "== the fixture runner's attribution cannot be fooled by a filename =="
  # This block exists because of a real failure. A negative control's filename
  # contains its rule id, and attribution used to grep the human-readable
  # finding line — which echoes the path. So `L2-K9-N001-*.k9.ncl` "proved"
  # itself whenever ANY rule fired, including K9-N002 (the contract does not
  # typecheck). Both L2 controls reported ok on a contract that judged nothing.
  # The suite's whole purpose is catching gates that cannot fire, so the
  # predicate is asserted here rather than trusted.
  local impostor fired
  impostor="$SCRIPT_DIR/fixtures/invalid/L0-K9-E001-bad-magic.k9.ncl"
  if [ -f "$impostor" ]; then
    QUIET=1
    local sj="$JSON"; JSON=1
    fired="$(validate_one "$impostor" 2>/dev/null \
      | grep -oE '"severity":"error","rule":"K9-[A-Z][0-9]+","layer":"L[0-9]+"' \
      | sed -E 's/.*"rule":"(K9-[A-Z][0-9]+)","layer":"(L[0-9])"/\1 \2/' \
      | sort -u || true)"
    JSON="$sj"; QUIET=0

    # Every extracted pair must be well-formed, not merely "at least one": a
    # silently unmatched finding would vanish from the set and a control could
    # then fail to be attributed. (E001 fires twice — bad magic also leaves the
    # body unclaimed — so the count is compared, not asserted to be 1.)
    t "every extracted finding is well-formed rule+layer" \
      "$(printf '%s\n' "$fired" | grep -c . || true)" \
      "$(printf '%s\n' "$fired" | grep -cE '^[A-Z0-9-]+ L[0-9]$' || true)"
    t "the rule that really fired is attributed" 1 \
      "$(printf '%s\n' "$fired" | grep -cE '^K9-E001 L0$' || true)"
    # The assertion that was missing: a rule id present in the PATH but absent
    # from the findings must NOT satisfy the control.
    t "a rule named only in the filename is NOT attributed" 0 \
      "$(printf '%s\n' "$fired" | grep -cE '^K9-S004 L0$' || true)"
    # Nor may a skip satisfy it: only severity "error" counts. hunt-fully-granted
    # carries a signature block with no verifier, so K9-C001 is SKIPPED; if a
    # skip could satisfy a control, a missing toolchain would pass a gate.
    local hunt_json
    hunt_json="$(QUIET=1 JSON=1 validate_one "$SCRIPT_DIR/fixtures/valid/hunt-fully-granted.k9.ncl" 2>/dev/null || true)"
    t "K9-C001 is present as a skipped finding" 1 \
      "$(printf '%s' "$hunt_json" | grep -cE '"severity":"skipped","rule":"K9-C001"' || true)"
    t "and that same finding is NOT extractable as a rejection" 0 \
      "$(printf '%s' "$hunt_json" \
        | grep -oE '"severity":"error","rule":"K9-[A-Z][0-9]+","layer":"L[0-9]+"' \
        | grep -c 'K9-C001' || true)"
  else
    echo -e "${YEL}SKIP${NC} attribution assertions: $impostor not present"
  fi

  echo "== the dialect discriminator agrees with the coordination grammar (§4.3) =="
  # coordination-k9-grammar_v1.2.abnf requires `K9!` and has no `---`
  # production (D318). So no file without the magic may be routed there, and
  # one with it is routed only to be rejected by that grammar.
  local disc
  disc="$(mktemp --suffix=.k9)"
  for case in "magic ---:coordination" "magic metadata::coordination" "plain ---:unclaimed" "plain metadata::unclaimed"; do
    local shape="${case%:*}" want="${case##*:}" first
    first="${shape#* }"
    {
      [ "${shape%% *}" = magic ] && printf 'K9!\n'
      printf '# SPDX-License-Identifier: MPL-2.0\n%s\n' "$first"
      printf '  schema: k9-coordination\n'
    } > "$disc"
    QUIET=1 validate_one "$disc" >/dev/null 2>&1
    t "${shape%% *} file opening '$first' is $want" "$want" "$DIALECT"
  done
  rm -f "$disc"

  echo "== no Nickel reserved word is used as an identifier =="
  # D173 gives the body to Nickel's grammar rather than restating it in an
  # ABNF, which means Nickel's lexer is normative for identifiers and this
  # validator cannot see a violation the way it sees a missing field. Two such
  # violations cost CI runs to find: `let doc = ...` in the L2 driver, and a
  # `default = { ... }` recipe field in two fixtures. Nickel's `Ident`
  # production admits only `or`, `as` and `include` as contextual keywords, so
  # every other keyword is unusable as a binding or field name.
  # Keyword list: nickel 1.18.0 parser/src/lexer.rs.
  local k9_kw='as default doc else false forall force fun if import in match merge nix not_exported null optional priority rec then true'
  local kw_hits=0 kf k
  for kf in "$CONTRACT" "$SCRIPT_DIR"/fixtures/valid/* "$SCRIPT_DIR"/fixtures/invalid/*; do
    [ -f "$kf" ] || continue
    case "$kf" in *.sh|*.adoc) continue ;; esac
    for k in $k9_kw; do
      # Field or binding position only: `| default = x` is Nickel's default
      # marker and is correct, so a keyword preceded by `|` is not a hit.
      if grep -qE "(^[[:space:]]*|[{(,][[:space:]]*)$k[[:space:]]*=[^=]" "$kf" \
        || grep -qE "\blet[[:space:]]+$k[[:space:]]*=" "$kf"; then
        echo -e "${RED}FAIL${NC} $(basename "$kf") uses the Nickel keyword '$k' as an identifier"
        kw_hits=$((kw_hits + 1))
      fi
    done
  done
  t "the contract and all 29 fixtures avoid Nickel's reserved words" 0 "$kw_hits"

  echo "== K9-N002: a contract that does not typecheck judges nothing =="
  # N002 fired four times during #1058 — `Record`, then `Any`, then twice more
  # — and had no control proving it could still fire. Without one, a validator
  # that quietly stopped checking the contract would keep reporting files as
  # merely non-conforming instead of reporting ITSELF broken, which is the
  # more dangerous of the two failures.
  #
  # The broken contract cannot be a committed file, so it is generated here and
  # reached through the K9_CONTRACT seam. With no nickel binary the honest
  # assertion is the other half: N002 must be SKIPPED, never passed.
  local good_contract="$CONTRACT" broken n002_json n002_rc
  broken="$(mktemp --suffix=.ncl)"
  printf '# deliberately broken: `Record` is not a Nickel type\n{ x | Record }\n' > "$broken"
  local subject="$SCRIPT_DIR/fixtures/valid/kennel-data.k9.ncl"
  if [ -f "$subject" ]; then
    CONTRACT="$broken"
    QUIET=1; JSON=1
    n002_json="$(validate_one "$subject" 2>/dev/null)"; n002_rc=$?
    JSON=0; QUIET=0
    CONTRACT="$good_contract"
    if nickel_bin >/dev/null; then
      t "a broken contract raises K9-N002" 1 \
        "$(printf '%s' "$n002_json" | grep -cE '"severity":"error","rule":"K9-N002"')"
      # The point of the rule: when the contract is broken, L2 must make NO
      # claim about the file. Emitting K9-N001 here would be the contract's
      # failure being reported as the component's.
      t "and makes no K9-N001 claim about the component" 0 \
        "$(printf '%s' "$n002_json" | grep -cE '"rule":"K9-N001"')"
      t "and still fails the file rather than passing it" 1 \
        "$([ "$n002_rc" -ne 0 ] && echo 1 || echo 0)"
    else
      t "with no nickel, a broken contract is SKIPPED not passed" 1 \
        "$(printf '%s' "$n002_json" | grep -cE '"severity":"skipped","rule":"K9-N002"')"
      t "and is not reported as an error it could not establish" 0 \
        "$(printf '%s' "$n002_json" | grep -cE '"severity":"error","rule":"K9-N002"')"
    fi
  else
    echo -e "${YEL}SKIP${NC} K9-N002 assertions: $subject not present"
  fi
  rm -f "$broken"
  t "the contract path defaults to the canonical one (seam not left open)" \
    "$SPEC_DIR/contract/k9_contract.ncl" "$CONTRACT"

  echo "== K9-E000: an absent path is a usage error, never a pass =="
  # E000 cannot have a committed fixture — the file would have to not exist —
  # so the control lives here. It matters because "file not found" is the one
  # finding a gate can produce while checking nothing at all, and a runner that
  # mistook it for a pass would report an empty corpus as conforming.
  local absent absent_json absent_rc
  absent="$SCRIPT_DIR/fixtures/invalid/this-file-does-not-exist.k9.ncl"
  QUIET=1; JSON=1
  absent_json="$(validate_one "$absent" 2>/dev/null)"; absent_rc=$?
  JSON=0; QUIET=0
  t "a missing file raises K9-E000" 1 \
    "$(printf '%s' "$absent_json" | grep -cE '"severity":"error","rule":"K9-E000"')"
  t "and exits non-zero" 1 "$([ "$absent_rc" -ne 0 ] && echo 1 || echo 0)"

  # A name beginning `-` is handed to cmp, head, sed, grep and dirname, every
  # one of which would read it as an option; validate_one prefixes `./` for
  # exactly that reason. That prefix is already asserted above ("dash-leading
  # name: no L0 failure" / "verdict pass at L1"), and it is applied once before
  # any layer runs, so re-asserting it at full depth would prove nothing new.

  echo
  if [ $SELFTEST_FAILS -eq 0 ]; then
    echo -e "${GRN}self-test: all assertions passed${NC}"
    return 0
  fi
  echo -e "${RED}self-test: $SELFTEST_FAILS assertion(s) failed${NC}"
  return 1
}

# ════════════════════════════════════════════════════════════════════════
# --fixtures — positive AND negative controls
# ════════════════════════════════════════════════════════════════════════
#
# The negative controls are the point. A validator that accepts everything
# passes every positive fixture, so a suite of positives alone proves nothing;
# it is the invalid/ corpus that shows the gate can fire. Each invalid fixture
# is named `L<layer>-<rule>-<reason>.k9.ncl` so the runner asserts not only
# that the file was rejected, but that it was rejected BY THE RULE IT NAMES.
run_fixtures() {
  local dir="$1" fails=0 f base want_layer want_rule rc out npos=0 nneg=0
  local outer_strict="$STRICT"
  [ -d "$dir/valid" ] || { echo "k9-validate: no valid/ under $dir" >&2; return 2; }
  if [ ! -d "$dir/invalid" ]; then
    echo "k9-validate: no invalid/ under $dir — a suite with no negative controls proves nothing" >&2
    return 2
  fi

  # Fixture assertions are about CONFORMANCE VERDICTS, so a check that could
  # not run must not be able to fail a fixture: --strict's job here is the
  # end-of-run refusal below, not turning every positive control red because
  # no nickel binary happens to be installed. Without this, --strict on a
  # machine without Nickel reports "0 positive fixtures pass", which reads as
  # a broken corpus when it is a missing toolchain.
  STRICT=0

  echo "== positive controls (must pass) =="
  while IFS= read -r f; do
    npos=$((npos + 1))
    if out="$(validate_one "$f" 2>&1)"; then
      echo -e "${GRN}ok${NC}   $(basename "$f")"
    else
      rc=$?
      printf '%s\n' "$out" >&2
      echo -e "${RED}FAIL${NC} $(basename "$f") should conform (exit $rc)"
      fails=$((fails + 1))
    fi
  done < <(find "$dir/valid" -type f \( -name '*.k9.ncl' -o -name '*.k9' -o -name '*.ncl' \) | sort)
  if [ $npos -eq 0 ]; then
    echo -e "${RED}FAIL${NC} no positive fixtures found"; fails=$((fails + 1))
  fi

  echo
  echo "== negative controls (must fail, by the named rule) =="
  local nskipped=0
  while IFS= read -r f; do
    nneg=$((nneg + 1))
    base="$(basename "$f")"
    want_layer="${base%%-*}"
    want_rule="$(printf '%s' "${base#*-}" | grep -oE '^K9-[ESNC][0-9]+' || true)"

    # An L2-named fixture is rejected by Nickel and by nothing else — that is
    # the entire point of it. Without a nickel binary the runner cannot assert
    # that, and reporting FAIL would blame the corpus for a missing toolchain.
    # Report it as SKIPPED, count it separately, and let --strict (which
    # refuses to run at all without nickel) be what turns that into a failure.
    if [ "$want_layer" = "L2" ] && ! nickel_bin >/dev/null; then
      # Assert the half that CAN be asserted. An L2 control must be lexically
      # clean, or it is not testing L2 at all — it is an L1 fixture with the
      # wrong name, and it would keep "passing" after the L2 check broke.
      local saved_layer="$LAYER"
      LAYER="L1"
      if out="$(validate_one "$f" 2>&1)"; then
        echo -e "${YEL}SKIP${NC} $base — lexically clean as required; needs nickel to assert L2 rejection"
        nskipped=$((nskipped + 1))
      else
        printf '%s\n' "$out" >&2
        echo -e "${RED}FAIL${NC} $base is an L2 control but already fails at L1 — it is not testing L2"
        fails=$((fails + 1))
      fi
      LAYER="$saved_layer"
      continue
    fi

    # Attribution is read off the JSON findings, NOT off free text. The human
    # line is `ERROR <rule> [<layer>] <path>: <msg>`, and a negative control's
    # path deliberately CONTAINS its rule id — so grepping the human output for
    # K9-N001 matched the filename and the control "proved" itself no matter
    # which rule fired. The first CI run caught exactly that: the contract did
    # not typecheck, both L2 controls were rejected by K9-N002, and both still
    # reported ok. A gate that cannot fire is the defect class this suite
    # exists to prevent, so the assertion reads the structured verdict.
    local saved_json="$JSON"
    JSON=1
    out="$(validate_one "$f" 2>/dev/null)"; rc=$?
    JSON="$saved_json"

    if [ $rc -eq 0 ]; then
      echo -e "${RED}FAIL${NC} $base was ACCEPTED — the gate did not fire"
      fails=$((fails + 1))
      continue
    fi

    # Error findings only: a skip or a warning is not a rejection, and letting
    # one satisfy a negative control would let a missing toolchain pass a gate.
    local fired
    fired="$(printf '%s' "$out" \
      | grep -oE '"severity":"error","rule":"K9-[A-Z][0-9]+","layer":"L[0-9]+"' \
      | sed -E 's/.*"rule":"(K9-[A-Z][0-9]+)","layer":"(L[0-9])"/\1 \2/' \
      | sort -u || true)"

    # K9-N002 means the normative contract itself is broken, in which case no
    # L2 control can have proved anything — say that, not "wrong rule".
    if printf '%s' "$fired" | grep -q '^K9-N002 '; then
      echo -e "${RED}FAIL${NC} $base cannot assert $want_rule: the normative contract does not typecheck (K9-N002), so L2 rejected nothing on its own merits"
      printf '%s\n' "$out" >&2
      fails=$((fails + 1))
      continue
    fi

    if [ -n "$want_rule" ] && ! printf '%s\n' "$fired" | grep -qE "^$want_rule $want_layer$"; then
      printf '%s\n' "$out" >&2
      echo -e "${RED}FAIL${NC} $base was rejected, but not by $want_rule at $want_layer"
      [ -n "$fired" ] && echo "        fired instead: $(printf '%s\n' "$fired" | tr '\n' ';')" >&2
      fails=$((fails + 1))
      continue
    fi
    echo -e "${GRN}ok${NC}   $base (rejected by $want_rule at $want_layer)"
  done < <(find "$dir/invalid" -type f \( -name '*.k9.ncl' -o -name '*.k9' -o -name '*.ncl' \) | sort)
  if [ $nneg -eq 0 ]; then
    echo -e "${RED}FAIL${NC} no negative fixtures found"; fails=$((fails + 1))
  fi

  echo
  echo "fixtures: $npos positive, $nneg negative ($nskipped needing nickel), $fails failure(s)"
  STRICT="$outer_strict"
  [ $fails -eq 0 ] || return 1
  return 0
}

# ════════════════════════════════════════════════════════════════════════
main() {
  local total=0 bad=0 skipped_only=0 rc

  if [ "$SELFTEST" -eq 1 ]; then
    [ -f "$CONTRACT" ] || { echo "k9-validate: contract not found at $CONTRACT" >&2; exit 2; }
    self_test; exit $?
  fi

  if [ ! -f "$CONTRACT" ]; then
    echo "k9-validate: normative contract not found at $CONTRACT" >&2
    exit 2
  fi

  if [ -n "$FIXTURES" ]; then
    local want_strict="$STRICT"
    run_fixtures "$FIXTURES"; rc=$?
    STRICT="$want_strict"   # run_fixtures lowers it for the per-file verdicts
    if [ $rc -eq 0 ] && [ "$STRICT" -eq 1 ] && ! nickel_bin >/dev/null; then
      echo -e "${YEL}k9-validate: --strict, but no nickel binary — L2 semantics were never checked, so this run is not a conformance result${NC}" >&2
      exit 3
    fi
    exit $rc
  fi

  if [ $# -eq 0 ]; then usage >&2; exit 2; fi

  for F in "$@"; do
    total=$((total + 1))
    validate_one "$F"; rc=$?
    case $rc in
      0) : ;;
      3) skipped_only=1 ;;
      *) bad=$((bad + 1)) ;;
    esac
  done

  if [ "$bad" -gt 0 ]; then
    [ "$QUIET" -eq 1 ] || echo -e "${RED}k9-validate: $bad of $total file(s) non-conforming${NC}" >&2
    exit 1
  fi
  if [ "$skipped_only" -eq 1 ]; then
    echo -e "${YEL}k9-validate: conforming so far as it could check, but required checks were SKIPPED${NC}" >&2
    exit 3
  fi
  [ "$QUIET" -eq 1 ] || note "$total file(s) conforming at layer $LAYER (contract v$CONTRACT_VERSION)"
  exit 0
}

main "$@"
