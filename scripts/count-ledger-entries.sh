#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# count-ledger-entries.sh — count exemption ENTRIES in a ledger read from stdin.
# Used by the exemption ratchet.
#
# WHY THIS IS A SEPARATE FILE. It was first embedded in the ratchet as an inline
# interpreter one-liner. The matching needs both `'''` and `"` for TOML's string
# forms, and passing that through a single-quoted shell argument mangled it. A
# `|| echo 0` fallback then swallowed the error, so the count silently became 0
# on both sides of the comparison and the ledger was skipped entirely — a check
# that reported OK while measuring nothing.
#
# ⚠ NO FALLBACK. If this cannot run, the ratchet must fail. A counter that
# returns 0 on error is indistinguishable from an empty ledger, and "empty" is
# the state that passes.
#
# The rule this implements: docs/DEBTFILE-SPEC.adoc § "No fallback".
#
# WHY ENTRIES AND NOT LINES, for TOML. A non-comment line count for
# `.gitleaks.toml` counts `paths = [`, the closing `]`, and every structural
# line. Reformatting one array across several lines then reads as growth, while
# adding an entry to an existing single-line array reads as no change at all.
# Both directions are wrong, and the second is the dangerous one: it lets an
# exemption be added invisibly.
#
# ⚠ SHELL, NOT PYTHON OR A JS RUNTIME. Estate policy bans Python outright, and
# the JS runtime has already moved once (Deno to Bun). A counter the ratchet
# depends on must not be invalidated by the next runtime change. awk is present
# wherever the ratchet runs.
#
# ⚠ AN EXPLICIT SCANNER, NOT A REGEX. awk has no non-greedy matching, so the
# array body and each string form are walked character by character. That is
# also why a comment containing a quote, or a `]` inside a string, cannot end
# the array early — the cases a regex port would get wrong.
set -uo pipefail

exec awk '
  # slurp: the arrays span lines, so the whole input is one record
  BEGIN { RS = "\x01"; total = 0 }

  {
    s = $0
    n = length(s)
    j = 1
    while (j <= n) {
      c = substr(s, j, 1)

      # ⚠ Outside an array, comments and strings must be skipped BEFORE
      # looking for a key. A commented-out `# paths = ["a"]` is not a ledger
      # entry, and neither is the text of a string that happens to contain
      # one. Scanning for the key first would count both.
      if (c == "#") { while (j <= n && substr(s, j, 1) != "\n") j++; continue }
      if (c == "\x27" || c == "\"") {
        q = c
        if (substr(s, j, 3) == "\x27\x27\x27") {
          j += 3
          while (j <= n && substr(s, j, 3) != "\x27\x27\x27") j++
          j += 3
        } else {
          j++
          while (j <= n && substr(s, j, 1) != q && substr(s, j, 1) != "\n") j++
          j++
        }
        continue
      }

      # a key only starts at the beginning of a line or after whitespace
      prev = (j == 1) ? "\n" : substr(s, j - 1, 1)
      if (prev != "\n" && prev != " " && prev != "\t") { j++; continue }
      if (!match(substr(s, j), /^(paths|regexes)[ \t]*=[ \t]*\[/)) { j++; continue }

      j += RLENGTH          # position just past the opening bracket
      depth = 1

      while (j <= n && depth > 0) {
        c  = substr(s, j, 1)
        c3 = substr(s, j, 3)

        if (c == "#") {                       # comment: run to end of line
          while (j <= n && substr(s, j, 1) != "\n") j++
          continue
        }
        if (c3 == "\x27\x27\x27") {           # literal multiline string
          total++
          j += 3
          while (j <= n && substr(s, j, 3) != "\x27\x27\x27") j++
          j += 3
          continue
        }
        if (c == "\x27") {                    # literal string
          total++
          j++
          while (j <= n && substr(s, j, 1) != "\x27" && substr(s, j, 1) != "\n") j++
          j++
          continue
        }
        if (c == "\"") {                      # basic string
          total++
          j++
          while (j <= n && substr(s, j, 1) != "\"" && substr(s, j, 1) != "\n") j++
          j++
          continue
        }
        if (c == "[") depth++
        else if (c == "]") depth--
        j++
      }
    }
  }

  END { print total }
'
