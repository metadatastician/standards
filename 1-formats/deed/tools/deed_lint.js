#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
// The DEED conformance validator, plain JavaScript (bun, zero dependencies).
// It began as a port of deed_lint.py, which was deleted on 2026-11-13.
const DOC = String.raw`deed-lint — conformance validator for the DEED grammar (deed.abnf v2.0.0).

Stdlib-only. Implements the normative grammar faithfully:
  * header = 1* spdx-line                 (";;" SP "SPDX-" …)
  * form   = "(" doc-head 1*(sep (field/clause)) [sep] ")"
  * doc-head ∈ {estate-deed, repo-deed, estate-atlas-deed, praxis-deed,
                contractile-deed, descriptile-deed}
  * field  = keyword sep value [sep "!"]  ("!" only after a rule's :id in a contractile-deed, J17)
  * clause = "(" symbol *(sep (field/clause)) [sep] ")"
  * value  = string / symbol / integer / boolean / uuid5 / uuid8 / uuid / quoted / list
  * boolean = #t | #f  (lowercase ONLY; true/false/1/0 are parse errors)
  * uuid5 = %s"#u5" string                (body is the RFC 4122 §4.3 NAME input)
  * uuid8 = %s"#u8" string                (body is the ADR-008 profile C preimage
                                          domain ":" name; domain = 1*%x21-7E minus ":")
  * uuid  = %s"#uuid" DQUOTE uuid-hex DQUOTE  (opaque id, lowercase 8-4-4-4-12 hex,
                                          version 5 or 8, variant 10)
  * escapes exactly {" \\ \n \t}      (\r, \uXXXX and all others INVALID)
  * sep    = 1*(SP / line-end / comment)  (HTAB is INVALID — K9-consistent)
  * symbol = ALPHA *(ALPHA/DIGIT/./"*"//"<"/">"/"="/"!"/"?"/"+"/"-"/"_")
  * quoted = "'" (symbol / list)          (only symbols/lists may be quoted)
Semantic checks (validator-enforced, per grammar):
  * :schema-version STRING exactly once at form top level
  * entire input consumed
  * no line longer than 998 octets, line-end excluded (v1.3.0)
  * filename↔doc-head dispatch (estate-first side condition, stem≠"estate")

Usage: deed_lint.js FILE...     exit 0 iff all files conform
       deed_lint.js --self-test
       deed_lint.js --egress FILE...           (egress …) clause profile (ADR-009)
       deed_lint.js --egress-fixtures DIR      DIR/valid pass the profile, DIR/invalid fail it
       deed_lint.js --anchor [--template] FILE...
                                              (anchor …) clause profile (DRAFT, A7; ruling Q11);
                                              --template: the template's own deed, which keeps {{TOKEN}}s
       deed_lint.js --anchor-fixtures DIR      DIR/valid pass the profile, DIR/invalid fail it (both required)
       deed_lint.js --contractiles [--root DIR] FILE...
                                              (contractiles …) clause profile (DRAFT, A7 8.2; YC01 to YC05);
                                              --root: the repo root, where every named file must exist
       deed_lint.js --contractiles-fixtures DIR DIR/valid pass the profile, DIR/invalid fail it (both required)
       deed_lint.js --edict FILE...           the edict form of a contractile-deed (DRAFT, A7 8.1, 8.4, 8.5)
       deed_lint.js --edict-fixtures DIR      DIR/{valid,invalid}/<case>/<Verb>file.deed (both required)
       deed_lint.js --verb-descriptile FILE... [--root DIR]
                                              a verb descriptile, INTENT.deed to BUST.deed (DRAFT, A7 7.3, 8.5);
                                              with --root, each :witnesses must name a rule of the verb's edict (YD02)
                                              and :of-chora must equal the root chora's :repo-uuid (YD08)
       deed_lint.js --verb-descriptile-fixtures DIR DIR/{valid,invalid}/<case>/<VERB>.deed [+ <Verb>file.deed]
       deed_lint.js --ecosystem FILE... [--root DIR] [--strict]
                                              ECOSYSTEM.deed (DRAFT, A7 7.2, YD07); --root checks :project and
                                              :of-chora against the chora deed; --strict requires (related :uuid) (J12)
       deed_lint.js --ecosystem-fixtures DIR  DIR/{valid,invalid}/<case>/ECOSYSTEM.deed [+ <repo>_chora.deed, STRICT]
       deed_lint.js --state FILE... [--root DIR] [--strict]
                                              STATE.deed (DRAFT, A7 7.2, J3, J15); --root checks :of-chora against the
                                              chora deed (YD08) and warns on a chora (status …) or (maturity …), which
                                              --strict refuses (YF03)
       deed_lint.js --state-fixtures DIR      DIR/{valid,invalid}/<case>/STATE.deed [+ <repo>_chora.deed, STRICT]
       deed_lint.js --contractile-registry --root DIR [--owner O/N] [--out FILE] [--check]
                                              generate the A5 contractile rule registry from the six edicts (A7 J13)
       deed_lint.js --ast-json FILE           emit the validated AST as JSON (integer lexemes stay strings)
       deed_lint.js --mustfile-json FILE      validate the Mustfile check profile and emit records
       deed_lint.js --proof-receipt-json FILE validate a proof receipt (PROOF-POLICY §8.5), derive
                                              each claim's PWG, refuse a recorded grade that differs
                                              (receipts, axioms and echoes: §8.5.1 to §8.5.2)
`;

import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

const SYMBOL_START = /^[A-Za-z]$/;
const SYMBOL_CONT = /^[A-Za-z0-9.*/<>=!?+_-]$/;

/** Python-style repr() of a string, used so messages match the Python linter. */
function pyRepr(s) {
  const q = s.includes("'") && !s.includes('"') ? '"' : "'";
  let out = q;
  for (const ch of s) {
    const o = ch.codePointAt(0);
    if (ch === "\\") out += "\\\\";
    else if (ch === q) out += "\\" + q;
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (o < 0x20 || o === 0x7f) out += "\\x" + o.toString(16).padStart(2, "0");
    else out += ch;
  }
  return out + q;
}

/** A single conformance failure with a 1-based line number. */
export class LintError extends Error {
  /** Build an error from its message and 1-based line number. */
  constructor(msg, line) {
    super(msg);
    this.name = "LintError";
    this.msg = msg;
    this.line = line;
  }

  /** Render as `line N: message`, like the Python __str__. */
  toString() {
    return `line ${this.line}: ${this.msg}`;
  }
}

/** Cursor over the source text. */
class Lexer {
  /** Create a lexer positioned at the start of `text`. */
  constructor(text) {
    this.t = text;
    this.i = 0;
    this.n = text.length;
    // The doc-head and the open clause heads, outermost first: J17 allows "!"
    // only on a rule's :id in a contractile-deed, which needs both.
    this.docHead = null;
    this.stack = [];
  }

  /** 1-based line number of offset `at` (default: current position). */
  line(at = null) {
    const end = at === null ? this.i : at;
    let c = 1;
    for (let k = 0; k < end && k < this.n; k++) if (this.t[k] === "\n") c++;
    return c;
  }

  /** Character at offset i+k, or "" past the end. */
  peek(k = 0) {
    const j = this.i + k;
    return j < this.n ? this.t[j] : "";
  }

  /** token-sep = 1*(SP / line-end / comment). Returns 1 if any separator was seen, else 0. */
  skipSep() {
    let seen = 0;
    while (this.i < this.n) {
      const c = this.t[this.i];
      if (c === " ") {
        this.i += 1;
        seen = 1;
      } else if (c === "\n") {
        this.i += 1;
        seen = 1;
      } else if (c === "\r") {
        if (this.t.slice(this.i, this.i + 2) === "\r\n") {
          this.i += 2;
          seen = 1;
        } else {
          throw new LintError("bare CR is not a line-end (CRLF or LF only)", this.line());
        }
      } else if (c === ";") {
        // comment = ";" *text-char line-end
        const start = this.i;
        while (this.i < this.n && this.t[this.i] !== "\r" && this.t[this.i] !== "\n") this.i += 1;
        if (this.i >= this.n) {
          throw new LintError("comment has no line-end: a comment runs to CRLF or LF", this.line(start));
        }
        checkTextChars(this, start + 1, this.i, "comment");
        seen = 1;
      } else {
        break;
      }
    }
    return seen;
  }
}

/**
 * text-char = VCHAR / SP / UTF8-2 / UTF8-3 / UTF8-4: throw on a C0 control
 * character or DEL in lx.t[from, to).
 */
function checkTextChars(lx, from, to, where) {
  for (let k = from; k < to; k++) {
    const o = lx.t.charCodeAt(k);
    if (o < 0x20 || o === 0x7f) {
      throw new LintError(
        `${where} holds control character U+${o.toString(16).toUpperCase().padStart(4, "0")}`,
        lx.line(k),
      );
    }
  }
}

/** string = DQUOTE *( str-char / escape ) DQUOTE ; exactly 4 escapes. */
function lexString(lx) {
  const start = lx.i;
  const out = [];
  lx.i += 1;
  for (;;) {
    if (lx.i >= lx.n) throw new LintError("unterminated string", lx.line(start));
    const c = lx.t[lx.i];
    if (c === '"') {
      lx.i += 1;
      return ["string", out.join("")];
    }
    if (c === "\\") {
      if (lx.i + 1 >= lx.n) throw new LintError("dangling backslash", lx.line(start));
      const e = lx.t[lx.i + 1];
      if (e !== '"' && e !== "\\" && e !== "n" && e !== "t") {
        throw new LintError(
          `illegal escape \\${pyRepr(e)} — only \\" \\\\ \\n \\t exist in DEED ` +
            "(\\r and \\uXXXX are parse errors; embed non-ASCII as raw UTF-8)",
          lx.line(start),
        );
      }
      out.push(e === "n" ? "\n" : e === "t" ? "\t" : e);
      lx.i += 2;
      continue;
    }
    const o = c.codePointAt(0);
    if (o < 0x20 || o === 0x7f) {
      throw new LintError(
        `raw control character U+${o.toString(16).toUpperCase().padStart(4, "0")} inside string (use legal escapes)`,
        lx.line(),
      );
    }
    out.push(c);
    lx.i += 1;
  }
}

/** Lex an optionally negative decimal integer; retain its exact digits as a string.
 * Keeping the lexeme rather than a JS Number avoids losing precision for large
 * DEED integers when consumers inspect the validated AST. */
function lexNumber(lx) {
  const m = /^-?[0-9]+/.exec(lx.t.slice(lx.i));
  if (m) {
    lx.i += m[0].length;
    return ["integer", m[0]];
  }
  return null;
}

/** Lex a symbol (ALPHA followed by symbol-continuation chars); returns ["symbol", s] or null. */
function lexSymbol(lx) {
  if (!SYMBOL_START.test(lx.peek())) return null;
  let j = lx.i + 1;
  while (j < lx.n && SYMBOL_CONT.test(lx.t[j])) j += 1;
  const s = lx.t.slice(lx.i, j);
  lx.i = j;
  return ["symbol", s];
}

/** True if c is an ASCII digit. */
function isDigit(c) {
  return c !== "" && c >= "0" && c <= "9";
}

/**
 * Enforce the uuid8 body rule: an ADR-008 profile C preimage domain ":" name,
 * whose domain (before the first ":") is non-empty printable ASCII.
 */
function checkUuid8Body(body, line) {
  const colon = body.indexOf(":");
  if (colon < 0) {
    throw new LintError(
      `uuid8 body ${pyRepr(body)} has no ":" — it must be a profile C preimage "domain:name"`,
      line,
    );
  }
  const domain = body.slice(0, colon);
  if (!/^[\x21-\x7e]+$/.test(domain)) {
    throw new LintError(
      `uuid8 domain ${pyRepr(domain)} must be non-empty printable ASCII (ADR-008 profile C)`,
      line,
    );
  }
}

/**
 * Enforce uuid-hex (deed.abnf v1.3.0): 8-4-4-4-12 lowercase hex, version
 * nibble 5 or 8, variant nibble 8, 9, a or b. All of it is grammar, not a
 * semantic check, so the messages stay out of the differential's list.
 */
function checkOpaqueUuid(body, line) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(body)) {
    throw new LintError(
      `uuid literal body ${pyRepr(body)} must be 8-4-4-4-12 lowercase hex`,
      line,
    );
  }
  if (body[14] !== "5" && body[14] !== "8") {
    throw new LintError(
      `uuid literal ${pyRepr(body)} has version ${body[14]}; only 5 and 8 are legal`,
      line,
    );
  }
  if (!"89ab".includes(body[19])) {
    throw new LintError(
      `uuid literal ${pyRepr(body)} has variant nibble ${body[19]}; it must be 8, 9, a or b (variant 10)`,
      line,
    );
  }
}

/** Identity fields (CHORA-SPEC 7.1): a #u5 literal in any of them is an error (owner ruling Q2). */
export const IDENTITY_FIELDS = new Set([
  "repo-uuid", "estate-uuid", "forge-uuid", "beholding-chora", "of-chora",
  "uuid", "estate", "base", "forge", "repo",
]);

/** #-forms: #u5"name" (uuid5), #u8"domain:name" (uuid8), #uuid"<id>" (uuid) or #t / #f (boolean); anything else is a parse error. */
function lexHashForm(lx) {
  if (lx.t.startsWith("#uuid", lx.i)) {
    const line = lx.line();
    lx.i += 5;
    if (lx.peek() !== '"') {
      throw new LintError('uuid literal must be followed immediately by a string: #uuid"<id>"', line);
    }
    const start = lx.i;
    lexString(lx);
    // uuid-hex has no escapes: check the raw body between the quotes.
    const body = lx.t.slice(start + 1, lx.i - 1);
    checkOpaqueUuid(body, line);
    return ["uuid", body];
  }
  const two = lx.t.slice(lx.i, lx.i + 3);
  if (two.startsWith("#u5")) {
    lx.i += 3;
    if (lx.peek() !== '"') {
      throw new LintError('uuid5 must be followed immediately by a string: #u5"name"', lx.line());
    }
    const name = lexString(lx)[1];
    return ["uuid5", name]; // the name is kept: a clause profile may derive the id it names
  }
  if (two.startsWith("#u8")) {
    const line = lx.line();
    lx.i += 3;
    if (lx.peek() !== '"') {
      throw new LintError('uuid8 must be followed immediately by a string: #u8"domain:name"', line);
    }
    const body = lexString(lx)[1];
    checkUuid8Body(body, line);
    // The preimage is kept: a clause profile derives its id to compare, e.g. (anchor (parents …)).
    return ["uuid8", body];
  }
  if (two.slice(0, 2) === "#t" || two.slice(0, 2) === "#f") {
    // A token-sep or a paren ends the boolean. A comment is a token-sep
    // (deed.abnf), so `#t; note` is legal too.
    const nxt = lx.peek(2);
    if (nxt && !" \r\n();".includes(nxt)) {
      const tok = lx.t.slice(lx.i + 2, lx.i + 24).trim().split(/\s+/)[0].slice(0, 20);
      throw new LintError(
        `booleans are exactly #t/#f (got ${pyRepr(two + tok)}); true/false/1/0 are parse errors`,
        lx.line(),
      );
    }
    lx.i += 2;
    // The lexeme is the two characters; `two` also holds the one after it.
    return ["boolean", two.slice(0, 2)];
  }
  throw new LintError('unrecognised #-form: only #t, #f, #u5"…", #u8"…", #uuid"…" are legal', lx.line());
}

/**
 * list = "(" [token-sep] [value *(token-sep value)] [token-sep] ")" — returns
 * ["list", items]. Values after the first must be separated.
 */
function lexList(lx) {
  lx.i += 1;
  const items = [];
  for (;;) {
    const sep = lx.skipSep();
    if (lx.peek() === ")") {
      lx.i += 1;
      return ["list", items];
    }
    if (items.length > 0 && !sep) throw new LintError("list values must be separated", lx.line());
    items.push(lexValue(lx));
  }
}

/** quoted = "'" value, where only symbols and lists may be quoted. */
function lexQuoted(lx) {
  lx.i += 1;
  const nxt = lx.peek();
  if (nxt && " \r\n;".includes(nxt)) {
    throw new LintError("nothing may come between ' and the symbol or list it quotes", lx.line());
  }
  const v = lexValue(lx);
  if (v[0] !== "symbol" && v[0] !== "list") {
    throw new LintError(`only symbols and lists may be quoted, not ${v[0]}`, lx.line());
  }
  return ["quoted", v];
}

/** integer token; rejects a number run straight into identifier characters. */
function lexIntegerToken(lx) {
  const v = lexNumber(lx);
  const nxt = lx.peek();
  if (nxt && (SYMBOL_CONT.test(nxt) || /^\p{L}$/u.test(nxt))) {
    throw new LintError("malformed token: number followed by identifier characters", lx.line());
  }
  return v;
}

/** value = string / symbol / integer / boolean / uuid5 / uuid8 / uuid / quoted / list */
function lexValue(lx) {
  const c = lx.peek();
  if (c === '"') return lexString(lx);
  if (c === "#") return lexHashForm(lx);
  if (c === "(") return lexList(lx);
  if (c === "'") return lexQuoted(lx);
  if (c === ":") throw new LintError("stray keyword — a keyword may only lead a field", lx.line());
  if (isDigit(c) || (c === "-" && isDigit(lx.peek(1)))) return lexIntegerToken(lx);
  const v = lexSymbol(lx);
  if (v) return v;
  throw new LintError(
    `cannot lex value starting at ${pyRepr(c)} ('=' as a field separator is not a deed)`,
    lx.line(),
  );
}

/** field = ":" keyword sep value, or clause = "(" symbol *(field / clause) ")". */
function lexFieldOrClause(lx) {
  const c = lx.peek();
  if (c === ":") {
    lx.i += 1;
    const kw = lexSymbol(lx);
    if (!kw) throw new LintError("malformed keyword: ':' must be followed by a symbol", lx.line());
    if (!lx.skipSep()) {
      throw new LintError(`keyword :${kw[1]} must be followed by a separator before its value`, lx.line());
    }
    const val = lexValue(lx);
    if (val[0] === "symbol" && ["true", "false", "yes", "no"].includes(val[1])) {
      // Grammar note: "Never true, false, yes, no." These lex as symbols, so the
      // ban is enforced here as a value-level semantic rule.
      throw new LintError(
        `boolean meaning must use #t/#f — bare symbol ${pyRepr(val[1])} is forbidden as a value`,
        lx.line(),
      );
    }
    // Owner ruling Q2 (2026-11-14, CHORA-SPEC 7.1): a #u5 literal in an
    // identity field is an error in every mode; #u8 and #uuid are accepted.
    // The same field names as scripts/check-uuid-v8.sh.
    if (val[0] === "uuid5" && IDENTITY_FIELDS.has(kw[1])) {
      throw new LintError(
        `identity field :${kw[1]} carries a #u5 literal; write #uuid"<v8 id>" or #u8"domain:name" (owner ruling Q2, CHORA-SPEC 7.1)`,
        lx.line(),
      );
    }
    // A1 V8 and T30: an identity field carries version 8; a version 5 inside
    // #uuid there is v5-identity, an error in every mode (as check-uuid-v8.sh).
    if (val[0] === "uuid" && IDENTITY_FIELDS.has(kw[1]) && val[1][14] !== "8") {
      throw new LintError(
        `identity field :${kw[1]} carries a version ${val[1][14]} id (v5-identity); an identity field carries version 8 (CHORA-SPEC 7.1, T30)`,
        lx.line(),
      );
    }
    // field = keyword token-sep value [token-sep bang] (v1.5.0, A7 J17). "!" can
    // start no field, clause or value, so it is read here or nowhere. It is a
    // bang only when a separator or ")" follows it; "!x" is not a token.
    const save = lx.i;
    if (lx.skipSep() && lx.peek() === "!") {
      const after = lx.peek(1);
      if (after === "" || after === " " || after === "\n" || after === "\r" || after === ";" || after === ")") {
        const line = lx.line();
        const ok = lx.docHead === "contractile-deed" && lx.stack.length === 1 && lx.stack[0] === "rule" && kw[1] === "id";
        if (!ok) {
          throw new LintError("'!' is allowed only directly after a rule's :id value in a contractile-deed (A7 J17)", line);
        }
        lx.i += 1;
        return ["field", kw[1], val, true];
      }
    }
    lx.i = save;
    return ["field", kw[1], val];
  }
  if (c === "(") {
    lx.i += 1;
    const head = lexSymbol(lx);
    if (!head) {
      throw new LintError("clause '(' must be followed immediately by a clause symbol (no separator)", lx.line());
    }
    const items = [];
    lx.stack.push(head[1]);
    for (;;) {
      // clause = "(" symbol *(token-sep (field / clause)) [token-sep] ")"
      const sep = lx.skipSep();
      if (lx.peek() === ")") {
        lx.i += 1;
        lx.stack.pop();
        return ["clause", head[1], items];
      }
      if (lx.peek() === "" && lx.i >= lx.n) {
        throw new LintError(`unbalanced parens: clause (${head[1]}) never closes`, lx.line());
      }
      if (!sep) {
        throw new LintError(`clause (${head[1]}) needs a separator before each field or clause`, lx.line());
      }
      items.push(lexFieldOrClause(lx));
    }
  }
  if (c === "") throw new LintError("unexpected end of input (unbalanced parens)", lx.line());
  throw new LintError(`expected field (':keyword …') or clause ('(symbol …)'), got ${pyRepr(c)}`, lx.line());
}

/** Parse the single top-level form; returns [docHead, items]. No separator after '('. */
function parseForm(lx) {
  if (lx.peek() !== "(") throw new LintError("a deed form must start with '('", lx.line());
  lx.i += 1;
  const head = lexSymbol(lx);
  const heads = [
    "estate-deed", "repo-deed", "estate-atlas-deed", "praxis-deed",
    "contractile-deed", "descriptile-deed",
  ];
  if (!head || !heads.includes(head[1])) {
    const got = head ? head[1] : lx.peek();
    throw new LintError(`invalid doc-head ${pyRepr(got)}; valid heads: ${heads.join(", ")}`, lx.line());
  }
  if (!lx.skipSep()) {
    throw new LintError(`doc-head ${head[1]} must be followed by a separator before the first field`, lx.line());
  }
  lx.docHead = head[1];
  const items = [];
  // The separator after the doc-head was consumed above.
  for (let first = true; ; first = false) {
    const sep = lx.skipSep() || first;
    if (lx.peek() === ")") {
      lx.i += 1;
      break;
    }
    if (lx.peek() === "") throw new LintError("unbalanced parens: form never closes", lx.line());
    if (!sep) throw new LintError("the form needs a separator before each field or clause", lx.line());
    items.push(lexFieldOrClause(lx));
  }
  const schema = items.filter((it) => it[0] === "field" && it[1] === "schema-version");
  if (schema.length !== 1) {
    throw new LintError(
      `form must carry exactly one :schema-version STRING field (found ${schema.length})`,
      lx.line(),
    );
  }
  if (schema[0][2][0] !== "string") throw new LintError(":schema-version must be a STRING value", lx.line());
  lx.skipSep();
  if (lx.i < lx.n) {
    throw new LintError("trailing content after the form's closing ')' — a deed is exactly one form", lx.line());
  }
  return [head[1], items];
}

/** header = 1*spdx-line; each ";; SPDX-" line must be non-empty. Returns the line count. */
function parseHeader(lx) {
  let count = 0;
  for (;;) {
    if (lx.t.startsWith(";; SPDX-", lx.i)) {
      const eol = lx.t.indexOf("\n", lx.i);
      if (eol === -1) throw new LintError("SPDX header line has no line-end", lx.line());
      const payload = lx.t.slice(lx.i + 8, eol);
      if (!payload.trim()) throw new LintError("SPDX header line is empty after ';; SPDX-'", lx.line());
      // spdx-line = ";;" SP "SPDX-" 1*text-char line-end (CRLF or LF)
      checkTextChars(lx, lx.i + 8, lx.t[eol - 1] === "\r" ? eol - 1 : eol, "SPDX header line");
      lx.i = eol + 1;
      count += 1;
      continue;
    }
    break;
  }
  if (count === 0) {
    throw new LintError(
      "deed must begin with at least one SPDX header line (';; SPDX-License-Identifier: …')",
      lx.line(),
    );
  }
  return count;
}

/** Longest line deed.abnf v1.3.0 allows, in octets, line-end excluded (RFC 2045 §2.8). */
export const MAX_LINE_OCTETS = 998;

/** Reject any line longer than MAX_LINE_OCTETS UTF-8 bytes before its CRLF or LF. */
function checkLineLength(text) {
  const enc = new TextEncoder();
  const lines = text.split("\n");
  for (let k = 0; k < lines.length; k++) {
    const body = lines[k].endsWith("\r") ? lines[k].slice(0, -1) : lines[k];
    if (body.length * 3 <= MAX_LINE_OCTETS) continue;
    const octets = enc.encode(body).length;
    if (octets > MAX_LINE_OCTETS) {
      throw new LintError(
        `line is ${octets} octets; a deed line is at most ${MAX_LINE_OCTETS} octets, line-end excluded`,
        k + 1,
      );
    }
  }
}

/**
 * The text with each ';' comment blanked to spaces, outside strings only. Line
 * breaks and offsets are kept, so a match index still gives its line.
 */
export function blankComments(text) {
  let out = "", inStr = false;
  for (let k = 0; k < text.length; k++) {
    const c = text[k];
    if (inStr) {
      out += c;
      if (c === "\\" && k + 1 < text.length) out += text[++k];
      else if (c === '"') inStr = false;
    } else if (c === '"') { inStr = true; out += c; }
    else if (c === ";") {
      while (k < text.length && text[k] !== "\n") { out += " "; k++; }
      if (k < text.length) out += "\n";
    } else out += c;
  }
  return out;
}

const FIELD_ALT = [...IDENTITY_FIELDS].join("|");
const U5_LEXICAL = new RegExp(`:(${FIELD_ALT})\\s+#u5"[^"]*"`, "g");
const UUID_LEXICAL = new RegExp(`:(${FIELD_ALT})\\s+#uuid"[0-9a-f]{8}-[0-9a-f]{4}-([0-9a-f])[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}"`, "g");

/**
 * The identity rule read lexically, as scripts/check-uuid-v8.sh reads it (owner
 * rulings Q2 and "by name", 2026-11-14, CHORA-SPEC 7.1): an identity field name
 * followed by #u5, or by a #uuid that is not version 8, is an error wherever it
 * appears, comments and strings included. Two views are read: the raw text, and
 * the text with comments blanked, so a comment between a field and its value
 * cannot hide the value.
 */
export function checkIdentityLexical(text) {
  const lineOf = (i) => { let ln = 1; for (let k = 0; k < i; k++) if (text[k] === "\n") ln++; return ln; };
  for (const view of [text, blankComments(text)]) {
    for (const m of view.matchAll(U5_LEXICAL)) {
      throw new LintError(
        `identity field :${m[1]} carries a #u5 literal; write #uuid"<v8 id>" or #u8"domain:name" (owner ruling Q2, CHORA-SPEC 7.1)`,
        lineOf(m.index),
      );
    }
    for (const m of view.matchAll(UUID_LEXICAL)) {
      if (m[2] === "8") continue;
      throw new LintError(
        `identity field :${m[1]} carries a version ${m[2]} id (v5-identity); an identity field carries version 8 (CHORA-SPEC 7.1, T30)`,
        lineOf(m.index),
      );
    }
  }
}

/** Validate DEED source text. Returns [head, items] on success; throws LintError. */
export function validate(text, filename = null) {
  const tab = text.indexOf("\t");
  if (tab !== -1) {
    let ln = 1;
    for (let k = 0; k < tab; k++) if (text[k] === "\n") ln++;
    throw new LintError("HTAB (tab) is an invalid separator anywhere in a deed (K9-consistent)", ln);
  }
  checkLineLength(text);
  const lx = new Lexer(text);
  parseHeader(lx);
  lx.skipSep();
  const [head, items] = parseForm(lx);
  checkIdentityLexical(text);
  if (filename) checkFilenameDispatch(filename, head);
  return [head, items];
}

// A7 J14 (deed.abnf v1.4.0): exact, case-sensitive file names.
export const CONTRACTILE_FILES = new Set(
  ["Intent", "Must", "Trust", "Adjust", "Dust", "Bust"].map((v) => `${v}file.deed`),
);
export const DESCRIPTILE_FILES = new Set(
  ["META", "STATE", "ECOSYSTEM", "AGENTIC", "NEUROSYM", "PLAYBOOK", "CLADE",
    "INTENT", "MUST", "TRUST", "ADJUST", "DUST", "BUST"].map((n) => `${n}.deed`),
);

/**
 * Check a parsed doc-head against the case-sensitive basename of `filename`.
 * Exact names take precedence: estate_chora.deed requires estate-deed,
 * ATLAS.deed requires estate-atlas-deed, and 0-AI-MANIFEST.deed requires
 * repo-deed. The J14 names are exact and case-sensitive too (deed.abnf
 * v1.4.0): <Verb>file.deed for the six verbs requires contractile-deed, and the thirteen ALL-CAPS descriptile
 * names (CLADE.deed among them) require descriptile-deed; mustfile.deed,
 * MUSTFILE.deed and Meta.deed match nothing. Otherwise, _praxis.deed selects
 * praxis-deed and _chora.deed selects repo-deed; stems may contain dots
 * (split on the final suffix).
 * Returns undefined on success.
 * @throws {LintError} At line 1 for an unrecognised filename, an empty or
 * illegal _chora.deed stem (only ASCII letters, digits, hyphens, dots and
 * underscores are allowed), or a doc-head mismatch.
 */
export function checkFilenameDispatch(filename, head) {
  const base = basename(filename);
  let want;
  if (base === "estate_chora.deed") {
    want = "estate-deed";
  } else if (base === "ATLAS.deed") {
    want = "estate-atlas-deed";
  } else if (base === "0-AI-MANIFEST.deed") {
    want = "repo-deed";
  } else if (CONTRACTILE_FILES.has(base)) {
    want = "contractile-deed";
  } else if (DESCRIPTILE_FILES.has(base)) {
    want = "descriptile-deed";
  } else if (base.endsWith("_praxis.deed")) {
    want = "praxis-deed";
  } else if (base.endsWith("_chora.deed")) {
    const stem = base.slice(0, -"_chora.deed".length);
    if (stem === "estate") return;
    if (!/^[A-Za-z0-9\-._]+$/.test(stem)) throw new LintError(`illegal deed filename stem ${pyRepr(stem)}`, 1);
    want = "repo-deed";
  } else {
    throw new LintError(
      `filename ${pyRepr(base)} matches no deed dispatch pattern ` +
        "(estate_chora.deed | ATLAS.deed | 0-AI-MANIFEST.deed | <Verb>file.deed | " +
        "<DESCRIPTILE>.deed | <stem>_chora.deed | <stem>_praxis.deed; the J14 names are case-sensitive)",
      1,
    );
  }
  if (head !== want) {
    throw new LintError(`doc-head/filename mismatch: ${base} dispatches to ${want} but parses as ${head}`, 1);
  }
}


/** Domain violations in an otherwise grammatical Mustfile deed. */
export class MustfileError extends LintError {
  constructor(msg) {
    super(msg, null);
    this.name = "MustfileError";
  }
  toString() { return this.msg; }
}

/**
 * Convert (check ...) clauses into records without relying on physical lines.
 * This profile validates required fields, values and uniqueness. It does NOT
 * execute commands; the Mustfile runner remains responsible for discharge.
 */
export function readMustfileChecks(text, filename = null) {
  const [head, items] = validate(text, filename);
  if (head !== "praxis-deed") throw new MustfileError("Mustfile must be a praxis-deed");
  const required = ["id", "severity", "discharge", "body"];
  const allowed = new Set([...required, "description"]);
  const topLevelFields = new Map([
    ["schema-version", new Set(["string"])],
    ["canonical-name", new Set(["string"])],
    ["beholding-chora", new Set(["uuid8", "uuid"])],
  ]);
  const seenTopLevel = new Set();
  const severities = new Set(["critical", "high", "medium", "low"]);
  const discharges = new Set(["run", "verification"]);
  const seen = new Set();
  const checks = [];
  for (const node of items) {
    if (node[0] === "field") {
      const [, key, value] = node;
      if (!topLevelFields.has(key)) throw new MustfileError("unknown top-level Mustfile field :" + key);
      if (seenTopLevel.has(key)) throw new MustfileError("duplicate top-level Mustfile field :" + key);
      if (!topLevelFields.get(key).has(value[0])) throw new MustfileError("invalid type for top-level :" + key);
      if (value[0] === "string" && value[1].trim() === "") throw new MustfileError("empty top-level :" + key);
      seenTopLevel.add(key);
      continue;
    }
    if (node[1] !== "check") throw new MustfileError("unexpected clause (" + node[1] + ") in Mustfile");
    const fields = new Map();
    for (const member of node[2]) {
      if (member[0] !== "field") throw new MustfileError("nested clauses are not valid in (check ...)");
      const key = member[1];
      if (!allowed.has(key)) throw new MustfileError("unknown (check ...) field :" + key);
      if (fields.has(key)) throw new MustfileError("duplicate (check ...) field :" + key);
      fields.set(key, member[2]);
    }
    for (const key of required) {
      if (!fields.has(key)) throw new MustfileError("(check ...) missing :" + key);
    }
    const get = (key, kind) => {
      const value = fields.get(key);
      if (value[0] !== kind) throw new MustfileError(":" + key + " must be a " + kind);
      return value[1];
    };
    const id = get("id", "symbol");
    const severity = get("severity", "symbol");
    const discharge = get("discharge", "symbol");
    const body = get("body", "string");
    if (!severities.has(severity)) throw new MustfileError("unknown severity: " + severity);
    if (!discharges.has(discharge)) throw new MustfileError("unknown discharge: " + discharge);
    if (body.trim() === "") throw new MustfileError("empty :body for " + id);
    if (fields.has("description") && fields.get("description")[0] !== "string") {
      throw new MustfileError(":description must be a string");
    }
    if (seen.has(id)) throw new MustfileError("duplicate check id: " + id);
    seen.add(id);
    checks.push({ id, severity, discharge, body });
  }
  if (checks.length === 0) throw new MustfileError("Mustfile contains no (check ...) clauses");
  return checks;
}

/** Domain violations in an otherwise grammatical proof-receipt deed. */
export class ProofReceiptError extends LintError {
  constructor(msg) {
    super(msg, null);
    this.name = "ProofReceiptError";
  }
  toString() { return this.msg; }
}

// The closed vocabularies of standards/3-practice/PROOF-POLICY.adoc: §5 tokens
// (canonical lowercase), §2.2 correspondence states, §8.2 grades, §8.4 receipt
// states, §8.5 leg routes, §8.5.2 echo witnesses, and the dispositions of
// docs/TRUSTED-BASE-REDUCTION-POLICY.adoc that a reported axiom can have.
// A value outside them is refused, never coerced.
export const PROOF_RECEIPT_VOCABULARY = {
  pwg: ["PWG-3", "PWG-2i", "PWG-2ii", "PWG-1", "ungraded"],
  token: ["proven", "proven-with-postulates", "tested-only", "argued", "open"],
  state: ["AGDA-PENDING", "AGDA-VERIFIED", "COQ-CHECKED", "LEAN-CHECKED", "BRIDGE-PENDING",
    "RECONCILED", "COUNTEREXAMPLE", "QUARANTINED"],
  route: ["source", "transported", "re-proved", "waived", "unavailable"],
  receiptState: ["current", "superseded", "regressed"],
  dttProvers: ["agda", "rocq", "lean"],
  disposition: ["b", "c", "debt"],
  echoWitness: ["inputs-sha256", "tree-sha256"],
  controlExpect: ["refused"],
};

/**
 * Read a proof receipt (PROOF-POLICY §8.5, the proof-receipt profile of
 * praxis-deed) into a plain record, and derive every claim's Proof Witness
 * Grade from its legs and their receipts (§8.2). A recorded :pwg that the
 * receipts do not support is refused: grades are derived, not asserted (§8.4).
 * The same holds for :foundation-diverse (§8.3). Every current receipt carries
 * its :inputs-sha256 and (inputs-manifest …) (§8.5.1) and its (axioms …) (§8.4). Top-level (echo …)
 * records (§8.5.2) let a receipt earned on a commit that a squash or rebase
 * rewrote count toward PWG-1 for its image. The reader checks only what the
 * text shows: the form of the records, that the rewrite is a function with no
 * cycle, and that every digest stated for one commit agrees. Whether the image
 * is on the default branch, and whether the digests really hold, is the duty of
 * a gate that has git (§8.5.3). Layout-independent: nothing here depends on
 * physical lines.
 */
export function readProofReceipt(text, filename = null) {
  const [head, items] = validate(text, filename);
  const fail = (m) => { throw new ProofReceiptError(m); };
  if (head !== "praxis-deed") fail("a proof receipt must be a praxis-deed");
  const V = PROOF_RECEIPT_VOCABULARY;
  const HEX40 = /^[0-9a-f]{40}$/;
  const HEX64 = /^[0-9a-f]{64}$/;

  // Collect a clause's fields, refusing unknown, duplicate and mistyped ones.
  const fieldsOf = (where, members, spec, allowedClauses) => {
    const fields = new Map();
    const clauses = [];
    for (const m of members) {
      if (m[0] === "field") {
        const [, key, value] = m;
        if (!(key in spec)) fail(`unknown field :${key} in ${where}`);
        if (fields.has(key)) fail(`duplicate field :${key} in ${where}`);
        if (!spec[key].types.includes(value[0])) fail(`:${key} in ${where} must be a ${spec[key].types.join(" or ")}`);
        if (value[0] === "string" && value[1].trim() === "") fail(`empty :${key} in ${where}`);
        if (spec[key].oneOf && !spec[key].oneOf.includes(value[1])) {
          fail(`:${key} ${value[1]} in ${where} is not one of ${spec[key].oneOf.join(", ")}`);
        }
        fields.set(key, value[1]);
      } else {
        if (!allowedClauses.includes(m[1])) fail(`unexpected clause (${m[1]}) in ${where}`);
        clauses.push(m);
      }
    }
    for (const [key, s] of Object.entries(spec)) {
      if (s.required && !fields.has(key)) fail(`${where} is missing :${key}`);
    }
    return { fields, clauses };
  };

  const top = fieldsOf("the receipt", items, {
    "schema-version": { types: ["string"], required: true },
    "canonical-name": { types: ["string"], required: true },
    "beholding-chora": { types: ["uuid8", "uuid"] },
    profile: { types: ["symbol"], required: true, oneOf: ["proof-receipt"] },
    repository: { types: ["string"], required: true },
    "source-commit": { types: ["string"], required: true },
  }, ["trusted-base", "claim", "echo"]);
  const repository = top.fields.get("repository");
  const sourceCommit = top.fields.get("source-commit");
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) fail(`:repository must be OWNER/REPO, got "${repository}"`);
  if (!HEX40.test(sourceCommit)) fail(":source-commit must be the full 40-character lowercase commit");

  // §8.4: the prover's trusted base, by name and binding.
  const trustedBase = [];
  const tbClauses = top.clauses.filter((c) => c[1] === "trusted-base");
  if (tbClauses.length > 1) fail("more than one (trusted-base …) clause");
  for (const c of tbClauses) {
    const tb = fieldsOf("(trusted-base …)", c[2], {}, ["primitive"]);
    const seen = new Set();
    for (const p of tb.clauses) {
      const f = fieldsOf("(primitive …)", p[2], {
        prover: { types: ["symbol"], required: true },
        module: { types: ["string"], required: true },
        name: { types: ["string"], required: true },
        binding: { types: ["string"], required: true },
      }, []).fields;
      const key = `${f.get("prover")} ${f.get("module")} ${f.get("name")}`;
      if (seen.has(key)) fail(`duplicate trusted-base primitive ${key}`);
      seen.add(key);
      trustedBase.push({ prover: f.get("prover"), module: f.get("module"), name: f.get("name"), binding: f.get("binding") });
    }
    if (trustedBase.length === 0) fail("(trusted-base …) lists no (primitive …); omit the clause instead");
  }

  // §8.5.2: the echoes of a history rewrite f (pre-rewrite commit to commit on
  // the default branch). Each record is one source in the fibre over its image.
  const echoes = [];
  const echoOf = new Map();
  for (const c of top.clauses.filter((c) => c[1] === "echo")) {
    const e = fieldsOf("(echo …)", c[2], {
      source: { types: ["string"], required: true },
      image: { types: ["string"], required: true },
      witness: { types: ["symbol"], required: true, oneOf: V.echoWitness },
      "tree-sha256": { types: ["string"] },
    }, ["inputs"]);
    const source = e.fields.get("source"), image = e.fields.get("image"), witness = e.fields.get("witness");
    const where = `(echo :source ${source})`;
    if (!HEX40.test(source) || !HEX40.test(image)) fail(`${where}: :source and :image must be full 40-character lowercase commits`);
    if (source === image) fail(`${where}: :source and :image are the same commit`);
    if (source === sourceCommit) fail(`${where}: the :source-commit is on the default branch, so it is an image and never a source`);
    if (echoOf.has(source)) fail(`${where}: a source has one image only (the rewrite is a function)`);
    const inputs = {};
    if (witness === "tree-sha256") {
      if (!e.fields.has("tree-sha256")) fail(`${where}: :witness tree-sha256 needs :tree-sha256`);
      if (!HEX64.test(e.fields.get("tree-sha256"))) fail(`${where}: :tree-sha256 must be 64 lowercase hex digits`);
      if (e.clauses.length) fail(`${where}: :witness tree-sha256 carries no (inputs …)`);
    } else {
      if (e.fields.has("tree-sha256")) fail(`${where}: :witness inputs-sha256 carries no :tree-sha256`);
      if (e.clauses.length === 0) fail(`${where}: :witness inputs-sha256 needs at least one (inputs :prover … :sha256 …)`);
      for (const i of e.clauses) {
        const f = fieldsOf(`(inputs …) of ${where}`, i[2], {
          prover: { types: ["symbol"], required: true },
          sha256: { types: ["string"], required: true },
        }, []).fields;
        if (!HEX64.test(f.get("sha256"))) fail(`${where}: an (inputs …) :sha256 must be 64 lowercase hex digits`);
        if (f.get("prover") in inputs) fail(`${where}: two (inputs …) for ${f.get("prover")}`);
        inputs[f.get("prover")] = f.get("sha256");
      }
    }
    const rec = { source, image, witness, tree_sha256: e.fields.get("tree-sha256") ?? null, inputs };
    echoOf.set(source, rec);
    echoes.push(rec);
  }
  for (const e of echoes) {
    const seen = new Set([e.source]);
    for (let c = e.image; echoOf.has(c); c = echoOf.get(c).image) {
      if (seen.has(c)) fail(`(echo :source ${e.source}): the echoes form a cycle`);
      seen.add(c);
    }
  }
  // Every digest stated for one commit must agree, wherever it is stated.
  const inputsAt = new Map(); // "commit prover" -> digest
  const treeAt = new Map(); // commit -> digest
  const state = (map, key, value, what) => {
    if (map.has(key) && map.get(key) !== value) fail(`two different ${what} are stated for ${key}`);
    map.set(key, value);
  };
  for (const e of echoes) {
    if (e.witness === "tree-sha256") {
      state(treeAt, e.source, e.tree_sha256, "tree-sha256 digests");
      state(treeAt, e.image, e.tree_sha256, "tree-sha256 digests");
    }
    for (const [p, d] of Object.entries(e.inputs)) {
      state(inputsAt, `${e.source} ${p}`, d, "input digests");
      state(inputsAt, `${e.image} ${p}`, d, "input digests");
    }
  }

  // GitHub repository names are case-insensitive, and §8.6 names one alias:
  // the former owner of this repository. Two names are the same repository
  // when they agree after both. A gate with git also refuses an import clone
  // that holds the :source-commit (§8.5.3), which catches any other alias.
  const REPOSITORY_ALIASES = { "hyperpolymath/standards": "metadatastician/standards" };
  const canonicalRepository = (r) => REPOSITORY_ALIASES[r.toLowerCase()] ?? r.toLowerCase();
  const sameRepository = (a, b) => canonicalRepository(a) === canonicalRepository(b);
  // §8.5.1: a relative repository path, as a manifest line and a control name it.
  const checkPath = (who, path) => {
    if (/[\n\\]/.test(path)) fail(`${who} path "${path}" holds a newline or a backslash`);
    if (path.split("/").some((part) => part === "" || part === "." || part === "..")) {
      fail(`${who} path "${path}" must be relative to the repository root, with no empty, "." or ".." part`);
    }
  };
  // §8.5.1: a manifest, as (file :path … :sha256 …) entries in C byte order of
  // path. Returns the entries and the SHA-256 of the rebuilt manifest text.
  const readFiles = (who, label, members) => {
    const files = [];
    let previous = null;
    for (const e of fieldsOf(label, members, {}, ["file"]).clauses) {
      const ef = fieldsOf(`a (file …) of ${label}`, e[2], {
        path: { types: ["string"], required: true },
        sha256: { types: ["string"], required: true },
      }, []).fields;
      const path = ef.get("path"), sha = ef.get("sha256");
      if (!HEX64.test(sha)) fail(`${who} file "${path}": :sha256 must be 64 lowercase hex digits`);
      checkPath(who, path);
      const bytes = Buffer.from(path, "utf8");
      if (previous !== null) {
        const order = Buffer.compare(previous, bytes);
        if (order === 0) fail(`${who} path "${path}" is listed twice`);
        if (order > 0) fail(`${who} path "${path}" is out of order (sort in C byte order)`);
      }
      previous = bytes;
      files.push({ path, sha256: sha });
    }
    if (files.length === 0) fail(`${label} lists no (file …)`);
    const text = files.map((m) => `${m.sha256}  ${m.path}\n`).join("");
    return { files, digest: createHash("sha256").update(text, "utf8").digest("hex") };
  };
  // One (receipt …): of a leg, or of a control (§8.5.4). A leg receipt's digest
  // joins the per-commit agreement of §8.5.2; a control's input set differs
  // (it holds the refused file), so its digest does not.
  const readReceipt = (rw, where, prover, r, agree) => {
    const { fields: rf, clauses: rc } = fieldsOf(rw, r[2], {
      run: { types: ["string"], required: true },
      commit: { types: ["string"], required: true },
      checker: { types: ["string"], required: true },
      invocation: { types: ["string"], required: true },
      "inputs-sha256": { types: ["string"] },
      state: { types: ["symbol"], required: true, oneOf: V.receiptState },
      reason: { types: ["string"] },
    }, ["axioms", "inputs-manifest", "import"]);
    if (!HEX40.test(rf.get("commit"))) fail(`${where}: a receipt :commit must be the full 40-character commit`);
    if (rf.get("state") !== "current" && !rf.has("reason")) fail(`${where}: a ${rf.get("state")} receipt needs :reason`);
    const isCurrent = rf.get("state") === "current";
    // §8.5.1: the inputs digest, as the sorted manifest of §8.5.1 computes it.
    if (rf.has("inputs-sha256")) {
      if (!HEX64.test(rf.get("inputs-sha256"))) fail(`${rw}: :inputs-sha256 must be 64 lowercase hex digits`);
      if (agree) state(inputsAt, `${rf.get("commit")} ${prover}`, rf.get("inputs-sha256"), "input digests");
    } else if (isCurrent) fail(`${rw} is current and is missing :inputs-sha256 (§8.5.1)`);
    // §8.5.1: the manifest itself, so that a consumer recomputes the digest
    // with git alone. The reader rebuilds the manifest and checks that its
    // SHA-256 is the :inputs-sha256: the digest is derived, not asserted.
    const manifests = rc.filter((c) => c[1] === "inputs-manifest");
    if (manifests.length > 1) fail(`${rw} has more than one (inputs-manifest …)`);
    if (manifests.length === 0 && isCurrent) fail(`${rw} is current and is missing (inputs-manifest …) (§8.5.1)`);
    let inputsManifest = null;
    if (manifests.length === 1) {
      if (!rf.has("inputs-sha256")) fail(`${rw}: an (inputs-manifest …) needs :inputs-sha256`);
      const m = readFiles(`${rw}: manifest`, `${rw}: (inputs-manifest …)`, manifests[0][2]);
      if (m.digest !== rf.get("inputs-sha256")) {
        fail(`${rw}: :inputs-sha256 is not the SHA-256 of its (inputs-manifest …) (the manifest gives ${m.digest})`);
      }
      inputsManifest = m.files;
    }
    // §8.5.1: a pinned repository the run imported, with its own manifest.
    const imports = [];
    for (const c of rc.filter((c) => c[1] === "import")) {
      const fi = fieldsOf(`an (import …) of ${rw}`, c[2], {
        repository: { types: ["string"], required: true },
        commit: { types: ["string"], required: true },
        "inputs-sha256": { types: ["string"], required: true },
      }, ["file"]).fields;
      const repo = fi.get("repository");
      const iw = `${rw}: import ${repo}`;
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) fail(`${iw}: :repository must be OWNER/REPO`);
      if (sameRepository(repo, repository)) fail(`${iw}: a repository does not import itself; its files belong in (inputs-manifest …)`);
      if (imports.some((i) => sameRepository(i.repository, repo))) fail(`${iw} is listed twice (one pin per repository)`);
      if (!HEX40.test(fi.get("commit"))) fail(`${iw}: :commit must be the full 40-character lowercase commit`);
      if (!HEX64.test(fi.get("inputs-sha256"))) fail(`${iw}: :inputs-sha256 must be 64 lowercase hex digits`);
      const m = readFiles(`${iw} manifest`, `${iw}`, c[2].filter((x) => x[0] !== "field"));
      if (m.digest !== fi.get("inputs-sha256")) fail(`${iw}: :inputs-sha256 is not the SHA-256 of its files (they give ${m.digest})`);
      imports.push({ repository: repo, commit: fi.get("commit"), "inputs-sha256": fi.get("inputs-sha256"), files: m.files });
    }
    // §8.4: the axioms the checker reported, each with its disposition.
    const axiomClauses = rc.filter((c) => c[1] === "axioms");
    if (axiomClauses.length > 1) fail(`${rw} has more than one (axioms …)`);
    if (axiomClauses.length === 0 && isCurrent) fail(`${rw} is current and is missing (axioms …) (§8.4; write (axioms) when none were reported)`);
    let axioms = null;
    if (axiomClauses.length === 1) {
      axioms = [];
      const names = new Set();
      for (const a of fieldsOf(`(axioms …) of ${rw}`, axiomClauses[0][2], {}, ["axiom"]).clauses) {
        const af = fieldsOf(`an (axiom …) of ${rw}`, a[2], {
          name: { types: ["string"], required: true },
          disposition: { types: ["symbol"], required: true, oneOf: V.disposition },
        }, []).fields;
        if (names.has(af.get("name"))) fail(`${rw}: axiom "${af.get("name")}" is listed twice`);
        names.add(af.get("name"));
        axioms.push({ name: af.get("name"), disposition: af.get("disposition") });
      }
    }
    return { ...Object.fromEntries(rf), inputs_manifest: inputsManifest, imports, axioms };
  };

  const claims = [];
  const ids = new Set();
  for (const c of top.clauses.filter((c) => c[1] === "claim")) {
    const cl = fieldsOf("(claim …)", c[2], {
      id: { types: ["string"], required: true },
      pwg: { types: ["symbol"], required: true, oneOf: V.pwg },
      "foundation-diverse": { types: ["boolean"], required: true },
    }, ["leg", "control"]);
    const id = cl.fields.get("id");
    if (ids.has(id)) fail(`duplicate claim id "${id}"`);
    ids.add(id);
    const where = `claim "${id}"`;
    const legs = [];
    const provers = new Set();
    for (const l of cl.clauses.filter((x) => x[1] === "leg")) {
      const lf = fieldsOf(`a leg of ${where}`, l[2], {
        prover: { types: ["symbol"], required: true },
        route: { types: ["symbol"], required: true, oneOf: V.route },
        token: { types: ["symbol"], oneOf: V.token },
        state: { types: ["symbol"], oneOf: V.state },
        reason: { types: ["string"] },
      }, ["receipt"]);
      const prover = lf.fields.get("prover");
      if (provers.has(prover)) fail(`${where} has two ${prover} legs`);
      provers.add(prover);
      const route = lf.fields.get("route");
      if ((prover === "agda") !== (route === "source")) {
        fail(`${where}: route source belongs to the agda leg, and only to it (got ${prover} ${route})`);
      }
      const discharged = route === "source" || route === "transported" || route === "re-proved";
      if (discharged && (!lf.fields.has("token") || !lf.fields.has("state"))) {
        fail(`${where}: the ${prover} leg (${route}) needs :token and :state`);
      }
      if (!discharged && (lf.fields.has("token") || lf.fields.has("state") || lf.clauses.length)) {
        fail(`${where}: a ${route} ${prover} leg carries no :token, :state or receipts`);
      }
      if (!discharged && !lf.fields.has("reason")) fail(`${where}: a ${route} ${prover} leg needs :reason`);
      const receipts = lf.clauses.map((r) => readReceipt(`a receipt of the ${prover} leg of ${where}`, where, prover, r, true));
      if (receipts.filter((r) => r.state === "current").length > 1) fail(`${where}: the ${prover} leg has more than one current receipt`);
      legs.push({ prover, route, token: lf.fields.get("token") ?? null, state: lf.fields.get("state") ?? null,
        reason: lf.fields.get("reason") ?? null, receipts });
    }
    if (!provers.has("agda")) fail(`${where} has no agda leg`);
    // §8.5.4: negative controls, files the checker must refuse. They are
    // evidence that the check can fail. They are recorded, never graded.
    const controls = [];
    for (const k of cl.clauses.filter((x) => x[1] === "control")) {
      const kf = fieldsOf(`a control of ${where}`, k[2], {
        path: { types: ["string"], required: true },
        prover: { types: ["symbol"], required: true },
        expect: { types: ["symbol"], required: true, oneOf: V.controlExpect },
      }, ["receipt"]);
      const path = kf.fields.get("path"), prover = kf.fields.get("prover");
      const kw = `${where}: control ${prover} "${path}"`;
      checkPath(`${kw}:`, path);
      if (controls.some((x) => x.path === path && x.prover === prover)) fail(`${kw} is listed twice`);
      const receipts = kf.clauses.map((r) => readReceipt(`a receipt of ${kw}`, where, prover, r, false));
      if (receipts.length === 0) fail(`${kw} has no (receipt …)`);
      if (receipts.filter((r) => r.state === "current").length > 1) fail(`${kw} has more than one current receipt`);
      const cur = receipts.find((r) => r.state === "current");
      if (cur && !cur.inputs_manifest.some((m) => m.path === path)) fail(`${kw}: the refused file is not in its current receipt's (inputs-manifest …)`);
      controls.push({ path, prover, expect: kf.fields.get("expect"), receipts });
    }

    // §8.2: derive the grade. A leg counts when its kernel accepted it, it is
    // tied to the Agda statement as §2.2 requires, and it has a current receipt.
    // §8.4: a witness counts only if each axiom it reports is admissible under
    // disposition (c).
    const current = (l) => l.receipts.find((r) => r.state === "current");
    const kernelOk = (l) => (l.token === "proven" || l.token === "proven-with-postulates")
      && (!current(l) || current(l).axioms.every((a) => a.disposition === "c"));
    // §8.5.2: a receipt describes the :source-commit when its :commit is that
    // commit, or when a chain of echoes leads from its :commit to that commit and
    // every link agrees on this leg's inputs (a tree-sha256 link agrees on all).
    const describesSource = (l) => {
      const r = current(l);
      for (let c = r.commit; ; c = echoOf.get(c).image) {
        if (c === sourceCommit) return true;
        const e = echoOf.get(c);
        if (!e) return false;
        if (e.witness === "inputs-sha256" && e.inputs[l.prover] !== r["inputs-sha256"]) return false;
      }
    };
    const agda = legs.find((l) => l.prover === "agda");
    const canonical = (inv) => ["--safe", "--without-K"].every((f) => inv.split(/\s+/).includes(f))
      && (inv.split(/\s+/).includes("--cubical-compatible") || inv.split(/\s+/).includes("--cubical"));
    const agdaCounts = kernelOk(agda) && agda.state === "AGDA-VERIFIED" && current(agda) && canonical(current(agda).invocation);
    const recheck = legs.filter((l) => (l.prover === "rocq" || l.prover === "lean")
      && (l.route === "transported" || l.route === "re-proved") && kernelOk(l) && l.state === "RECONCILED" && current(l));
    let pwg = "ungraded";
    if (agdaCounts) {
      pwg = ["PWG-3", "PWG-2i", "PWG-2ii"][recheck.length];
      const counted = [agda, ...recheck];
      if (recheck.length === 2 && counted.every(describesSource)) pwg = "PWG-1";
    }
    if (pwg !== cl.fields.get("pwg")) {
      fail(`${where} records :pwg ${cl.fields.get("pwg")}, but its legs and receipts support ${pwg} (PROOF-POLICY §8.2, §8.4)`);
    }
    // §8.3: a kernel-checked witness outside the DTT family, with a current receipt.
    const diverse = legs.some((l) => !V.dttProvers.includes(l.prover) && kernelOk(l) && current(l));
    if (diverse !== (cl.fields.get("foundation-diverse") === "#t")) {
      fail(`${where} records :foundation-diverse ${cl.fields.get("foundation-diverse")}, but its legs support ${diverse ? "#t" : "#f"} (§8.3)`);
    }
    claims.push({ id, pwg, foundation_diverse: diverse, legs, controls });
  }
  if (claims.length === 0) fail("a proof receipt records at least one (claim …)");
  // A tree-sha256 link says the whole tree agrees, so every leg's inputs agree.
  for (const e of echoes.filter((e) => e.witness === "tree-sha256")) {
    for (const [key, d] of inputsAt) {
      const [commit, p] = key.split(" ");
      const other = commit === e.source ? e.image : commit === e.image ? e.source : null;
      if (other && inputsAt.has(`${other} ${p}`) && inputsAt.get(`${other} ${p}`) !== d) {
        fail(`(echo :source ${e.source}) states equal trees, but the ${p} input digests of its two commits differ`);
      }
    }
  }
  return { repository, source_commit: sourceCommit, trusted_base: trustedBase, echoes, claims };
}

const H = ";; SPDX-License-Identifier: CC-BY-SA-4.0\n";

/** The embedded self-test corpus (same 14 cases, order and expectations as the Python). */
export const SELF_TEST_CASES = [
  ["valid-minimal", true,
    H + '(repo-deed :schema-version "1.0.0" :canonical-name "x" :repo-uuid #u8"gv-clade-index:github.com/o/x" :beholding-chora #u8"chora:estate/github.com/o")\n'],
  ["valid-nested", true,
    H + '(repo-deed\n  :schema-version "1.0.0"\n:canonical-name "x" ; comment between\n  (lineage :type hub :parent "" :previous-names ()) )\n'],
  ["valid-booleans-uuid", true,
    H + '(repo-deed :schema-version "1.0.0" (status :present #t :ended #f :note "legal escapes: \\n and \\t and \\\\ and \\"q\\""))\n'],
  ["invalid-equals", false,
    H + '(repo-deed :schema-version "1.0.0" :canonical-name = "x")\n'],
  ["invalid-section", false,
    H + '(repo-deed :schema-version "1.0.0"\n[status]\nphase = "active")\n'],
  ["invalid-missing-schema", false,
    H + '(repo-deed :canonical-name "x")\n'],
  ["invalid-head", false,
    H + '(chora-deed :schema-version "1.0.0")\n'],
  ["invalid-true-literal", false,
    H + '(repo-deed :schema-version "1.0.0" (status :present true))\n'],
  ["invalid-tab", false,
    H + '(repo-deed\t:schema-version "1.0.0")\n'],
  ["invalid-escape-u", false,
    H + '(repo-deed :schema-version "1.0.0" (m :s "bad \\u0041"))\n'],
  ["invalid-trailing", false,
    H + '(repo-deed :schema-version "1.0.0") trailing\n'],
  ["invalid-no-header", false,
    '(repo-deed :schema-version "1.0.0")\n'],
  // Python labels this "invalid-string-after-head" then overrides index 12 to
  // this valid case (proves quoted lists, 007 and bare symbols parse).
  ["valid-quoted-list-symbols-007", true,
    H + '(repo-deed :schema-version "not-string-issue" :other 007 :sym github-actions :q \'(a b))\n'],
  ["invalid-unbalanced", false,
    H + '(repo-deed :schema-version "1.0.0" (status :present #t)\n'],
].map(([name, expectOk, src]) => ({ name, expectOk, src }));

/** Validate source; returns [ok, errorString]. */
// ─── (egress …) clause profile ─────────────────────────────────────────
// spec/abnf/clauses/egress.abnf v1.0.0 (prose: spec/EGRESS-CLAUSE-SPEC.adoc,
// decision: docs/decisions/ADR-009). Checks only what the profile adds to the
// grammar; a deed with no (egress …) clause passes. It lives in this file, not
// its own module, because the estate no-JS ratchet forbids adding a JS file.

/** A profile violation. The parsed AST carries no positions, so it names the field instead of a line. */
export class EgressError extends LintError {
  constructor(msg) {
    super(msg, null);
    this.name = "EgressError";
  }

  toString() {
    return this.msg;
  }
}

export const ENFORCEMENT = ["none", "harden-runner-audit", "harden-runner-block"];

// Every "." follows a non-empty name segment, as workflow-path in egress.abnf.
const WORKFLOW = /^\.github\/workflows\/(?:[A-Za-z0-9_-]+\.)+ya?ml$/;
const JOB_ID = /^[A-Za-z_][A-Za-z0-9_-]*$/;
// GitHub stores secret and variable names uppercase and matches them without
// regard to case, so a declaration uses the stored form: one spelling per name.
const SECRET = /^[A-Z_][A-Z0-9_]*$/;
// A label starts and ends with a letter or digit (RFC 1123 §2.1).
const LABEL = "[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?";
const HOST_PORT = new RegExp(`^(\\*\\.)?${LABEL}(\\.${LABEL})*(:([0-9]{1,5}))?$`);
const REQUIRED = ["workflow", "job", "secrets", "endpoints", "enforcement"];
const ALLOWED = new Set([...REQUIRED, "reason"]);

/** Collect string items of a list value, or throw naming the field. */
function stringList(val, field) {
  if (val[0] !== "list") throw new EgressError(`:${field} must be a list of strings`);
  return val[1].map((v) => {
    if (v[0] !== "string") throw new EgressError(`:${field} items must be strings, got ${v[0]}`);
    return v[1];
  });
}

/** Check one (job …) clause; returns {workflow, job, secrets, endpoints, enforcement}. */
function checkJob(items) {
  const seen = new Map();
  for (const it of items) {
    if (it[0] !== "field") throw new EgressError(`(job …) takes fields only, not a nested (${it[1]} …)`);
    if (!ALLOWED.has(it[1])) throw new EgressError(`(job …) has no field :${it[1]}`);
    if (seen.has(it[1])) throw new EgressError(`(job …) repeats :${it[1]}`);
    seen.set(it[1], it[2]);
  }
  for (const f of REQUIRED) if (!seen.has(f)) throw new EgressError(`(job …) is missing :${f}`);

  const str = (f) => {
    const v = seen.get(f);
    if (v[0] !== "string") throw new EgressError(`:${f} must be a string`);
    return v[1];
  };
  const workflow = str("workflow");
  if (!WORKFLOW.test(workflow)) throw new EgressError(`:workflow ${JSON.stringify(workflow)} is not .github/workflows/<name>.yml`);
  const job = str("job");
  if (!JOB_ID.test(job)) throw new EgressError(`:job ${JSON.stringify(job)} is not a GitHub job id`);
  if (seen.has("reason")) str("reason");

  const secrets = stringList(seen.get("secrets"), "secrets");
  if (secrets.length === 0) throw new EgressError(":secrets must not be empty");
  for (const s of secrets) {
    if (!SECRET.test(s)) {
      throw new EgressError(`secret name ${JSON.stringify(s)} is malformed (write it as GitHub stores it: uppercase letters, digits, "_")`);
    }
    if (s === "GITHUB_TOKEN") throw new EgressError("GITHUB_TOKEN is not listed: it is the job token, bounded by permissions:");
  }
  if (new Set(secrets).size !== secrets.length) throw new EgressError(":secrets has a duplicate");

  const endpoints = stringList(seen.get("endpoints"), "endpoints");
  for (const e of endpoints) {
    if (e.startsWith("secret:")) {
      const name = e.slice("secret:".length);
      if (!SECRET.test(name)) throw new EgressError(`endpoint ${JSON.stringify(e)} names a malformed secret`);
      if (!secrets.includes(name)) throw new EgressError(`endpoint ${JSON.stringify(e)} names a secret not in :secrets`);
      continue;
    }
    if (e.startsWith("var:")) {
      const name = e.slice("var:".length);
      if (!SECRET.test(name)) {
        throw new EgressError(`endpoint ${JSON.stringify(e)} names a malformed variable (uppercase, as GitHub stores it)`);
      }
      continue;
    }
    const m = HOST_PORT.exec(e);
    if (!m) throw new EgressError(`endpoint ${JSON.stringify(e)} is not host[:port], secret:NAME or var:NAME`);
    if (m[4] !== undefined && (Number(m[4]) < 1 || Number(m[4]) > 65535)) {
      throw new EgressError(`endpoint ${JSON.stringify(e)} has a port outside 1..65535`);
    }
  }

  const enf = seen.get("enforcement");
  if (enf[0] !== "symbol" || !ENFORCEMENT.includes(enf[1])) {
    throw new EgressError(`:enforcement must be one of the symbols ${ENFORCEMENT.join(", ")}`);
  }
  return { workflow, job, secrets, endpoints, enforcement: enf[1] };
}

/**
 * Check the (egress …) clause of deed source text. Returns the declared jobs
 * ([] when the deed has no egress clause); throws LintError on a grammar or
 * profile violation.
 */
export function checkEgress(text, filename = null) {
  const [head, items] = validate(text, filename);
  const clauses = items.filter((it) => it[0] === "clause" && it[1] === "egress");
  // The clause is honoured only at the top level, so one written anywhere
  // deeper would silently declare nothing. Refuse it instead.
  const nested = (list) =>
    list.some((it) => it[0] === "clause" && it[2].some((c) => (c[0] === "clause" && c[1] === "egress") || nested([c])));
  if (nested(items.filter((it) => !(it[0] === "clause" && it[1] === "egress")))) {
    throw new EgressError("(egress …) may appear only at the top level of a repo deed, not inside another clause");
  }
  if (clauses.length === 0) return [];
  if (head !== "repo-deed") throw new EgressError(`(egress …) belongs in a repo-deed, not a ${head}`);
  if (clauses.length > 1) throw new EgressError("a repo deed carries at most one (egress …) clause");

  const jobs = [];
  let policies = 0;
  for (const it of clauses[0][2]) {
    if (it[0] === "field" && it[1] === "policy") {
      if (it[2][0] !== "string") throw new EgressError(":policy must be a string");
      policies += 1;
    } else if (it[0] === "clause" && it[1] === "job") {
      jobs.push(checkJob(it[2]));
    } else {
      throw new EgressError(`(egress …) takes :policy and (job …) only, not ${it[0] === "field" ? ":" : "("}${it[1]}`);
    }
  }
  if (policies > 1) throw new EgressError("(egress …) repeats :policy");
  const keys = jobs.map((j) => `${j.workflow}#${j.job}`);
  if (new Set(keys).size !== keys.length) throw new EgressError("(egress …) lists the same workflow job twice");
  return jobs;
}

/** valid/ must pass the egress profile; invalid/ must fail it. Returns exit code. */
function egressFixtures(d) {
  let bad = 0;
  for (const [sub, expect] of [["valid", true], ["invalid", false]]) {
    let names = [];
    try {
      names = readdirSync(join(d, sub)).filter((n) => n.endsWith(".deed")).sort();
    } catch {
      // missing directory: nothing to check
    }
    for (const n of names) {
      const f = join(d, sub, n);
      let got = true;
      let err = "";
      try {
        checkEgress(readFileSync(f, "utf8"), f);
      } catch (e) {
        if (!(e instanceof LintError)) throw e;
        got = false;
        err = e.message;
      }
      if (got !== expect) bad += 1;
      console.log(`${got === expect ? "PASS " : "FAIL "}${f}` + (got === expect ? "" : `  (unexpected: ${err || "valid"})`));
    }
  }
  return bad ? 1 : 0;
}

/** --egress FILE...: profile-check each file; returns exit code. */
function egressFiles(files) {
  let bad = 0;
  for (const f of files) {
    try {
      const jobs = checkEgress(readFileSync(f, "utf8"), f);
      console.log(`OK   ${f} (${jobs.length} egress job${jobs.length === 1 ? "" : "s"})`);
    } catch (e) {
      if (!(e instanceof LintError)) throw e;
      bad += 1;
      console.log(`FAIL ${f}: ${e instanceof EgressError ? e.message : e.toString()}`);
    }
  }
  return bad ? 1 : 0;
}

// ─── (anchor …) clause profile ─────────────────────────────────────────
// spec/abnf/clauses/anchor.abnf v1.0.0 (DRAFT; prose: docs/estate-
// reconciliation/A7-contractiles-descriptiles-anchor.adoc; ruling Q11). Checks
// only what the profile adds to the grammar; a deed with no (anchor …) clause
// passes. In this file for the same reason as the egress profile.

/** A profile violation, named by field (the AST carries no positions). */
export class AnchorError extends LintError {
  constructor(msg) {
    super(msg, null);
    this.name = "AnchorError";
  }

  toString() {
    return this.msg;
  }
}

// The profile reads both majors (A7 J27): each clause is checked against the
// major its :schema declares. /1 is legacy (reported, still read); /2 renames
// (identity …) to (subject …) (J8) and drops (parents …), whose one home is
// ECOSYSTEM.deed (J26).
export const ANCHOR_SCHEMA = "hyperpolymath.anchor/2";
export const ANCHOR_SCHEMA_LEGACY = "hyperpolymath.anchor/1";
const ANCHOR_MAJOR = { [ANCHOR_SCHEMA_LEGACY]: 1, [ANCHOR_SCHEMA]: 2 };
const SEMVER = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const DATE = /^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/;
// The template's own deed keeps repo-init's tokens; a minted deed has none.
const MINT_TOKEN = /^\{\{[A-Z][A-Z0-9_]*\}\}$/;
const MINT_TOKEN_ANY = /\{\{[A-Z][A-Z0-9_]*\}\}/;

/** A YYYY-MM-DD string naming a day that exists (2026-02-31 does not). */
function isCalendarDate(s) {
  if (!DATE.test(s)) return false;
  const [y, m, d] = s.split("-").map(Number);
  const t = new Date(0);
  t.setUTCFullYear(y, m - 1, d); // not Date.UTC: it maps years 0 to 99 onto 1900 to 1999
  return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
}

/** A path inside the repo: relative, POSIX, no empty, "." or ".." segment. */
function isRepoRelative(p) {
  if (p === "" || p.startsWith("/") || p.includes("\\") || /^[A-Za-z]:/.test(p)) return false;
  return p.split("/").every((seg) => seg !== "" && seg !== "." && seg !== "..");
}

/** ADR-008 profile C: the UUIDv8 a `#u8"domain:name"` literal names (scripts/uuid-v8.js). */
export function profileCOfBody(body) {
  const b = createHash("sha256").update(body, "utf8").digest().subarray(0, 16);
  b[6] = (b[6] & 0x0f) | 0x80; // version 8
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10
  const h = Buffer.from(b).toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// Top-level members: field name -> kind, and the clauses allowed.
const ANCHOR_FIELDS = { schema: "string", authority: "string", repo: "string", purpose: "str-list1" };
const ANCHOR_CLAUSES = new Set([
  "metadata", "identity", "subject", "semantic-authority", "implementation-policy", "golden-path",
  "satellite-policy", "semantic-authority-files", "ssg", "parents",
]);
// Clauses only one major allows (A7 J8, J26, J27).
const ANCHOR_ONLY_IN = {
  identity: [1, "is (subject …) in hyperpolymath.anchor/2 (A7 J8)"],
  parents: [1, "is gone in hyperpolymath.anchor/2: a parent is an ECOSYSTEM.deed (related … :relationship parent) entry (A7 J26)"],
  ssg: [1, "is gone in hyperpolymath.anchor/2: site-build configuration is META.deed's (ssg …) (A7 J29)"],
  subject: [2, "needs hyperpolymath.anchor/2; under /1 it is (identity …) (A7 J8)"],
};
// Fixed-member sub-clauses: clause -> {field: kind}. Every member at most once.
const ANCHOR_SUB = {
  metadata: { version: "semver", "last-updated": "date" },
  identity: { project: "string", kind: "string", "one-sentence": "string", domain: "string" },
  subject: { project: "string", kind: "string", "one-sentence": "string", domain: "string" },
  "semantic-authority": { policy: "string", owns: "str-list1" },
  "implementation-policy": { allowed: "str-list", forbidden: "str-list" },
  "golden-path": { "smoke-test-command": "str-list1", "success-criteria": "str-list1" },
  "satellite-policy": {
    "must-pin-upstream": "boolean", "must-declare-authority": "boolean",
    "must-have-anchor": "boolean", "must-have-golden-path": "boolean",
  },
  ssg: { engine: "string", "output-dir": "string", "boj-trigger": "boolean", cartridge: "string" },
};

/** Check value v of field `where` against kind; throws AnchorError. */
function anchorValue(v, kind, where, opts = {}) {
  const strings = () => {
    if (v[0] !== "list") throw new AnchorError(`${where} must be a list of strings`);
    for (const x of v[1]) if (x[0] !== "string") throw new AnchorError(`${where} items must be strings, got ${x[0]}`);
    return v[1];
  };
  switch (kind) {
    case "string":
      if (v[0] !== "string") throw new AnchorError(`${where} must be a string, got ${v[0]}`);
      return;
    case "boolean":
      if (v[0] !== "boolean") throw new AnchorError(`${where} must be #t or #f, got ${v[0]}`);
      return;
    case "str-list":
      strings();
      return;
    case "str-list1":
      if (strings().length === 0) throw new AnchorError(`${where} must not be empty`);
      return;
    case "semver":
      anchorValue(v, "string", where);
      if (!SEMVER.test(v[1])) throw new AnchorError(`${where} ${JSON.stringify(v[1])} is not MAJOR.MINOR.PATCH`);
      return;
    case "date":
      anchorValue(v, "string", where);
      if (MINT_TOKEN.test(v[1])) {
        if (!opts.template) {
          throw new AnchorError(`${where} ${JSON.stringify(v[1])} is an unfilled repo-init token; only the template's own deed (--template) keeps one`);
        }
        return;
      }
      if (!isCalendarDate(v[1])) throw new AnchorError(`${where} ${JSON.stringify(v[1])} is not a real YYYY-MM-DD date`);
      return;
    case "repo-path":
      anchorValue(v, "string", where);
      if (!isRepoRelative(v[1])) {
        throw new AnchorError(`${where} ${JSON.stringify(v[1])} is not a repo-relative path (non-empty, no leading "/", no "\\", no "." or ".." segment)`);
      }
      return;
    default:
      throw new Error(`anchor profile: unknown kind ${kind}`);
  }
}

/** Fields only, each known and at most once; returns Map name -> value. */
function anchorFields(items, allowed, where, opts = {}) {
  const seen = new Map();
  for (const it of items) {
    if (it[0] !== "field") throw new AnchorError(`${where} takes fields only, not a nested (${it[1]} …)`);
    if (allowed && !Object.hasOwn(allowed, it[1])) throw new AnchorError(`${where} has no field :${it[1]}`);
    if (seen.has(it[1])) throw new AnchorError(`${where} repeats :${it[1]}`);
    seen.set(it[1], it[2]);
    if (allowed) anchorValue(it[2], allowed[it[1]], `${where} :${it[1]}`, opts);
  }
  if (seen.size === 0) throw new AnchorError(`${where} is empty`);
  return seen;
}

/**
 * Check the (anchor …) clause of deed source text. Returns a summary
 * {authority, members, parents} (null when the deed has no anchor clause);
 * throws LintError on a grammar or profile violation. opts.template marks the
 * template's own deed, the one deed that may keep repo-init's {{TOKEN}}s.
 */
export function checkAnchor(text, filename = null, opts = {}) {
  const [head, items] = validate(text, filename);
  const isAnchor = (it) => it[0] === "clause" && it[1] === "anchor";
  const nested = (list) => list.some((it) => it[0] === "clause" && it[2].some((c) => isAnchor(c) || nested([c])));
  if (nested(items)) {
    throw new AnchorError("(anchor …) may appear only at the top level of a repo deed, not inside another clause");
  }
  const clauses = items.filter(isAnchor);
  if (clauses.length === 0) return null;
  if (head !== "repo-deed") throw new AnchorError(`(anchor …) belongs in a repo-deed, not a ${head}`);
  if (clauses.length > 1) throw new AnchorError("a repo deed carries at most one (anchor …) clause");

  // An unfilled repo-init placeholder anywhere in the clause marks an unminted
  // deed. Only the template's own deed (--template) keeps them.
  if (!opts.template) {
    const strs = (v) => (v[0] === "string" ? [v[1]] : v[0] === "list" ? v[1].flatMap(strs) : []);
    const walk = (list) => {
      for (const it of list) {
        if (it[0] === "clause") walk(it[2]);
        else for (const str of strs(it[2])) {
          if (MINT_TOKEN_ANY.test(str)) {
            throw new AnchorError(`(anchor …) :${it[1]} ${JSON.stringify(str)} holds an unfilled repo-init token; only the template's own deed (--template) keeps one`);
          }
        }
      }
    };
    walk(clauses[0][2]);
  }

  // A1: a deed carries one id. With two, a parent could match the one not compared.
  const owns = items.filter((it) => it[0] === "field" && it[1] === "repo-uuid");
  if (owns.length > 1) throw new AnchorError(`a repo deed carries one :repo-uuid; this one has ${owns.length}`);
  const own = owns[0];
  // The deed's own id as an opaque body, so a parent can be compared with it.
  // A legacy literal names the same id: #u8"domain:name" is its profile C id,
  // and #u5"github.com/o/x" is the birth path whose deed id is the profile C id
  // of "gv-clade-index:github.com/o/x" (A1 rule V8).
  const ownUuid = !own ? null
    : own[2][0] === "uuid" ? own[2][1]
    : own[2][0] === "uuid8" ? profileCOfBody(own[2][1])
    : own[2][0] === "uuid5" ? "u5"
    : null;
  // The declared major selects the rules (J27). A missing or unknown :schema
  // is reported after the members, as before; members are then read as /1.
  const schemaItem = clauses[0][2].find((it) => it[0] === "field" && it[1] === "schema");
  const major = (schemaItem && schemaItem[2][0] === "string" && ANCHOR_MAJOR[schemaItem[2][1]]) || 1;
  // A7 S2: a #u5 in an identity field is an error in every mode, so a #u5
  // :repo-uuid is refused before anything else, with or without (parents …).
  if (ownUuid === "u5") {
    throw new AnchorError("the deed's :repo-uuid is a #u5 literal; a version 5 id in an identity field is an error in every mode (A7 S2)");
  }
  const seen = new Set();
  const parents = [];
  for (const it of clauses[0][2]) {
    const key = (it[0] === "field" ? ":" : "(") + it[1];
    if (seen.has(key)) throw new AnchorError(`(anchor …) repeats ${key}${it[0] === "clause" ? " …)" : ""}`);
    seen.add(key);
    if (it[0] === "field") {
      if (!Object.hasOwn(ANCHOR_FIELDS, it[1])) throw new AnchorError(`(anchor …) has no field :${it[1]}`);
      anchorValue(it[2], ANCHOR_FIELDS[it[1]], `(anchor …) :${it[1]}`);
      continue;
    }
    if (!ANCHOR_CLAUSES.has(it[1])) throw new AnchorError(`(anchor …) has no clause (${it[1]} …)`);
    if (Object.hasOwn(ANCHOR_ONLY_IN, it[1]) && ANCHOR_ONLY_IN[it[1]][0] !== major) {
      throw new AnchorError(`(anchor (${it[1]} …)) ${ANCHOR_ONLY_IN[it[1]][1]}`);
    }
    const where = `(anchor (${it[1]} …))`;
    if (Object.hasOwn(ANCHOR_SUB, it[1])) {
      anchorFields(it[2], ANCHOR_SUB[it[1]], where, opts);
    } else if (it[1] === "semantic-authority-files") {
      for (const [k, v] of anchorFields(it[2], null, where)) anchorValue(v, "repo-path", `${where} :${k}`);
    } else {
      // (parents (parent :uuid #uuid"…" [:relation sym]) …)
      if (it[2].length === 0) throw new AnchorError(`${where} is empty`);
      // "A parent never names the deed itself" needs an id to compare with:
      // with none, every parent would pass that check unexamined.
      if (ownUuid === null) {
        throw new AnchorError(`${where} needs the deed's own :repo-uuid (#uuid or #u8) to check that no parent names the deed itself`);
      }
      for (const p of it[2]) {
        if (p[0] !== "clause" || p[1] !== "parent") throw new AnchorError(`${where} takes (parent …) clauses only`);
        const f = anchorFields(p[2], null, `${where} (parent …)`);
        for (const k of f.keys()) if (k !== "uuid" && k !== "relation") throw new AnchorError(`(parent …) has no field :${k}`);
        const u = f.get("uuid");
        if (!u) throw new AnchorError("(parent …) is missing :uuid");
        // A1 rule V8: a chora id in a deed is version 8; version 5 stays in
        // the registry. A #u8 names its profile C id; a #u5 is an error (S2).
        const pid = choraIdOf(u, (m) => new AnchorError(m), "(parent …) :uuid");
        if (pid === null) {
          throw new AnchorError(u[0] === "uuid"
            ? `(parent …) :uuid ${u[1]} is version ${u[1][14]}, not a version 8 chora id (A1 rule V8)`
            : `(parent …) :uuid must be a version 8 chora id, an opaque #uuid"…" or a #u8 literal, got ${u[0]}`);
        }
        if (f.has("relation") && f.get("relation")[0] !== "symbol") throw new AnchorError("(parent …) :relation must be a symbol");
        if (parents.includes(pid)) throw new AnchorError(`(parent …) names ${pid} twice`);
        if (pid === ownUuid) throw new AnchorError("(parent …) names the deed's own :repo-uuid");
        parents.push(pid);
      }
    }
  }
  for (const k of [":schema", ":authority"]) if (!seen.has(k)) throw new AnchorError(`(anchor …) is missing ${k}`);
  const field = (n) => clauses[0][2].find((it) => it[0] === "field" && it[1] === n)[2][1];
  if (!Object.hasOwn(ANCHOR_MAJOR, field("schema"))) {
    throw new AnchorError(`(anchor …) :schema must be ${JSON.stringify(ANCHOR_SCHEMA)} (or the legacy ${JSON.stringify(ANCHOR_SCHEMA_LEGACY)}), got ${JSON.stringify(field("schema"))}`);
  }
  if (field("authority") === "") throw new AnchorError("(anchor …) :authority must not be empty");
  return { authority: field("authority"), members: [...seen].sort(), parents, schema: field("schema"), legacy: major === 1 };
}

// ─── (contractiles …) clause profile ───────────────────────────────────
// spec/abnf/clauses/contractiles.abnf v1.0.0 (DRAFT; prose: docs/estate-
// reconciliation/A7-contractiles-descriptiles-anchor.adoc 8.2; rulings Q14, J6,
// J10; tests YC01 to YC05). Checks only what the profile adds to the grammar;
// a deed with no (contractiles …) clause is outside the profile. That the
// named files exist (YC02, YC03) is a repo check, run when opts.root is given.

export class ContractilesError extends LintError {
  constructor(msg) {
    super(msg, null);
    this.name = "ContractilesError";
  }

  toString() {
    return this.msg;
  }
}

/** The six verbs and the case each file name takes (A7 8.1, 8.2; J14). */
export const CONTRACTILE_VERBS = {
  intend: "Intent", must: "Must", trust: "Trust", adjust: "Adjust", dust: "Dust", bust: "Bust",
};

/** The three paths 8.2 names for a verb, relative to the repo root. */
export function contractilePaths(verb) {
  const cap = CONTRACTILE_VERBS[verb];
  return {
    declaration: `.machine_readable/contractiles/${verb}/${cap}file.deed`,
    runner: `.machine_readable/contractiles/${verb}/${verb}.k9.ncl`,
    reality: `.machine_readable/descriptiles/${cap.toUpperCase()}.deed`,
  };
}

const VERB_MEMBERS = ["name", "declaration", "runner", "reality"];

/**
 * Check the (contractiles …) clause of deed source text. Returns a summary
 * {verbs} (null when the deed has no contractiles clause); throws LintError on
 * a grammar or profile violation. opts.root, when given, is the repo root the
 * deed belongs to: the three files of each verb must exist under it.
 */
export function checkContractiles(text, filename = null, opts = {}) {
  const [head, items] = validate(text, filename);
  const isC = (it) => it[0] === "clause" && it[1] === "contractiles";
  const nested = (list) => list.some((it) => it[0] === "clause" && it[2].some((c) => isC(c) || nested([c])));
  if (nested(items)) {
    throw new ContractilesError("(contractiles …) may appear only at the top level of a repo deed, not inside another clause");
  }
  const clauses = items.filter(isC);
  if (clauses.length === 0) return null;
  if (head !== "repo-deed") throw new ContractilesError(`(contractiles …) belongs in a repo-deed, not a ${head}`);
  if (clauses.length > 1) throw new ContractilesError("a repo deed carries exactly one (contractiles …) clause (YC01)");

  const verbs = new Map();
  for (const entry of clauses[0][2]) {
    if (entry[0] !== "clause" || entry[1] !== "verb") {
      const what = entry[0] === "clause" ? `(${entry[1]} …)` : `:${entry[1]}`;
      throw new ContractilesError(`(contractiles …) takes (verb …) entries only, not ${what}; the deed attests where the parties are, never a verdict (J6)`);
    }
    const f = new Map();
    for (const m of entry[2]) {
      if (m[0] !== "field") throw new ContractilesError(`(verb …) takes fields only, not (${m[1]} …)`);
      if (!VERB_MEMBERS.includes(m[1])) {
        throw new ContractilesError(`(verb …) has no field :${m[1]}; a verdict, status or score is never written here (YC05)`);
      }
      if (f.has(m[1])) throw new ContractilesError(`(verb …) repeats :${m[1]}`);
      f.set(m[1], m[2]);
    }
    for (const k of VERB_MEMBERS) if (!f.has(k)) throw new ContractilesError(`(verb …) is missing :${k} (YC02)`);
    const name = f.get("name");
    if (name[0] !== "symbol" || !Object.hasOwn(CONTRACTILE_VERBS, name[1])) {
      throw new ContractilesError(`(verb …) :name must be one of the symbols ${Object.keys(CONTRACTILE_VERBS).join(" ")}`);
    }
    const verb = name[1];
    if (verbs.has(verb)) throw new ContractilesError(`(contractiles …) names the verb ${verb} twice (YC01)`);
    const want = contractilePaths(verb);
    for (const k of ["declaration", "runner", "reality"]) {
      const v = f.get(k);
      if (v[0] !== "string") throw new ContractilesError(`(verb :name ${verb}) :${k} must be a string`);
      if (v[1] !== want[k]) {
        throw new ContractilesError(`(verb :name ${verb}) :${k} must be ${JSON.stringify(want[k])}, got ${JSON.stringify(v[1])} (YC02)`);
      }
    }
    verbs.set(verb, want);
  }
  const missing = Object.keys(CONTRACTILE_VERBS).filter((v) => !verbs.has(v));
  if (missing.length) throw new ContractilesError(`(contractiles …) is missing the verb${missing.length > 1 ? "s" : ""} ${missing.join(", ")}; all six appear exactly once (YC01)`);

  // YC04, J10: a written :contractiles_required equals the derived set.
  const derived = Object.keys(CONTRACTILE_VERBS).map((v) => `.machine_readable/contractiles/${v}/`).sort();
  const walk = (list) => {
    for (const it of list) {
      if (it[0] === "clause") {
        walk(it[2]);
        continue;
      }
      if (it[1] !== "contractiles_required") continue;
      const v = it[2];
      if (v[0] !== "list" || v[1].some((x) => x[0] !== "string")) {
        throw new ContractilesError(":contractiles_required must be a list of strings (YC04)");
      }
      const got = [...new Set(v[1].map((x) => x[1]))].sort();
      if (got.length !== v[1].length || got.join("\n") !== derived.join("\n")) {
        throw new ContractilesError(`:contractiles_required must equal the set derived from (contractiles …): ${derived.map((d) => JSON.stringify(d)).join(" ")} (YC04, J10)`);
      }
    }
  };
  walk(items);

  if (opts.root) {
    for (const [verb, paths] of verbs) {
      for (const k of ["declaration", "runner", "reality"]) {
        if (!existsSync(join(opts.root, paths[k]))) {
          throw new ContractilesError(`(verb :name ${verb}) :${k} ${JSON.stringify(paths[k])} does not exist under ${opts.root} (${k === "reality" ? "YC03" : "YC02"})`);
        }
      }
    }
  }
  return { verbs: [...verbs.keys()] };
}

/** --contractiles [--root DIR] FILE...: profile-check each file; returns exit code. */
function contractilesFiles(files, opts = {}) {
  let bad = 0;
  for (const f of files) {
    let text;
    try {
      text = readFileSync(f, "utf8");
    } catch (e) {
      bad += 1;
      console.log(`FAIL ${f}: cannot read the file (${e.code || e.message})`);
      continue;
    }
    try {
      const c = checkContractiles(text, f, opts);
      console.log(`OK   ${f} (${c === null ? "no contractiles clause" : `contractiles, ${c.verbs.length} verbs`})`);
    } catch (e) {
      if (!(e instanceof LintError)) throw e;
      bad += 1;
      console.log(`FAIL ${f}: ${e.toString()}`);
    }
  }
  return bad ? 1 : 0;
}

// ─── The edict form of a contractile-deed ──────────────────────────────
// spec/abnf/clauses/edict.abnf v1.0.0 (DRAFT; prose: docs/estate-
// reconciliation/A7-contractiles-descriptiles-anchor.adoc 8.1, 8.4, 8.5;
// rulings W2, W7, W10, J5, J13, J17, J20). Checks what the profile adds to the
// grammar. A deed whose head is not contractile-deed is outside the profile.

export class EdictError extends LintError {
  constructor(msg) {
    super(msg, null);
    this.name = "EdictError";
  }

  toString() {
    return this.msg;
  }
}

const EDICT_ID = /^[A-Za-z0-9._-]+$/;
const SELECTOR_HEADS = new Set(["identity", "profile", "capabilities", "context"]);
const COMPARATORS = ["value", "at-least", "at-most"];

/** The verb a <Verb>file.deed name declares, or null (A7 8.1 table). */
export function verbOfFilename(filename) {
  if (!filename) return null;
  const b = basename(filename);
  for (const [verb, cap] of Object.entries(CONTRACTILE_VERBS)) if (b === `${cap}file.deed`) return verb;
  return null;
}

/**
 * Check the edict form of contractile-deed source text. Returns
 * {verb, rules: [{id, bang, text}]} (null for any other head); throws
 * LintError on a grammar or profile violation.
 */
export function checkEdict(text, filename = null) {
  const [head, items] = validate(text, filename);
  if (head !== "contractile-deed") return null;
  const fields = new Map();
  const rules = [];
  let envelope = 0;
  for (const it of items) {
    if (it[0] === "field") {
      if (it[3]) throw new EdictError(`'!' is allowed only on a rule's :id, not on :${it[1]}`);
      if (it[1] === "beholding-chora") {
        throw new EdictError(":beholding-chora names an estate chora; a contractile-deed names its repo with :of-chora (J20)");
      }
      if (!["schema-version", "canonical-name", "of-chora", "verb"].includes(it[1])) {
        throw new EdictError(`a contractile-deed has no field :${it[1]}`);
      }
      if (fields.has(it[1])) throw new EdictError(`a contractile-deed carries :${it[1]} once`);
      fields.set(it[1], it[2]);
      continue;
    }
    if (it[1] === "rule") rules.push(it[2]);
    else if (it[1] === "envelope") envelope += 1;
    else throw new EdictError(`a contractile-deed has no clause (${it[1]} …); its clauses are (rule …) and, in a Bustfile, (envelope …)`);
  }
  for (const k of ["canonical-name", "of-chora", "verb"]) if (!fields.has(k)) throw new EdictError(`a contractile-deed is missing :${k}`);
  if (fields.get("canonical-name")[0] !== "string") throw new EdictError(":canonical-name must be a string");
  const ofId = choraIdOf(fields.get("of-chora"), (m) => new EdictError(m), ":of-chora");
  if (ofId === null) {
    throw new EdictError(":of-chora must be the repo's version 8 chora id, an opaque #uuid\"…\" or a #u8 literal (J20, J28)");
  }
  const v = fields.get("verb");
  if (v[0] !== "symbol" || !Object.hasOwn(CONTRACTILE_VERBS, v[1])) {
    throw new EdictError(`:verb must be one of the symbols ${Object.keys(CONTRACTILE_VERBS).join(" ")}`);
  }
  const verb = v[1];
  const fileVerb = verbOfFilename(filename);
  if (fileVerb !== null && fileVerb !== verb) {
    throw new EdictError(`${basename(filename)} is the ${fileVerb} edict, but :verb is ${verb} (A7 8.1)`);
  }
  if (envelope > 0 && verb !== "bust") throw new EdictError("(envelope …) belongs only in a Bustfile (A7 8.5)");
  if (envelope > 1) throw new EdictError("a Bustfile carries at most one (envelope …)");
  for (const it of items) {
    if (it[0] !== "clause" || it[1] !== "envelope") continue;
    if (it[2].length === 0) throw new EdictError("(envelope) is empty; it takes at least one of :for, :not-for and :tolerance (A7 8.5)");
    const seen = new Set();
    for (const m of it[2]) {
      if (m[0] !== "field" || !["for", "not-for", "tolerance"].includes(m[1])) {
        throw new EdictError(`(envelope …) takes :for, :not-for and :tolerance only, not ${m[0] === "field" ? ":" + m[1] : "(" + m[1] + " …)"}`);
      }
      if (m[3]) throw new EdictError(`'!' is allowed only on a rule's :id, not on (envelope :${m[1]})`);
      if (seen.has(m[1])) throw new EdictError(`(envelope …) repeats :${m[1]}`);
      seen.add(m[1]);
      const ok = m[1] === "tolerance" ? m[2][0] === "string" : m[2][0] === "list" && m[2][1].every((x) => x[0] === "string");
      if (!ok) throw new EdictError(`(envelope :${m[1]}) must be ${m[1] === "tolerance" ? "a string" : "a list of strings"}`);
    }
  }

  const ids = new Set();
  const out = [];
  for (const members of rules) {
    const f = new Map();
    const c = new Map();
    let bang = false;
    for (const m of members) {
      const key = (m[0] === "field" ? ":" : "(") + m[1];
      if (m[0] === "field") {
        if (!["id", "text"].includes(m[1])) throw new EdictError(`(rule …) has no field :${m[1]}`);
        if (f.has(m[1])) throw new EdictError(`(rule …) repeats :${m[1]}`);
        f.set(m[1], m[2]);
        if (m[3]) bang = true;
      } else {
        if (!["applies-when", "requires"].includes(m[1])) throw new EdictError(`(rule …) has no clause ${key} …)`);
        if (c.has(m[1])) throw new EdictError(`(rule …) repeats (${m[1]} …)`);
        c.set(m[1], m[2]);
      }
    }
    for (const k of ["id", "text"]) if (!f.has(k)) throw new EdictError(`(rule …) is missing :${k}`);
    for (const k of ["applies-when", "requires"]) if (!c.has(k)) throw new EdictError(`(rule …) is missing (${k} …)`);
    const id = f.get("id");
    if (id[0] !== "string" || !EDICT_ID.test(id[1])) {
      throw new EdictError(`(rule :id …) must be a string of letters, digits, ".", "_" and "-" (an A5 name segment)`);
    }
    const where = `(rule :id ${JSON.stringify(id[1])})`;
    if (`contractile/${verb}/${id[1]}`.length > 200) throw new EdictError(`${where}: contractile/${verb}/${id[1]} is longer than 200 characters (A5 3.1)`);
    if (ids.has(id[1])) throw new EdictError(`${where} appears twice`);
    ids.add(id[1]);
    if (f.get("text")[0] !== "string" || f.get("text")[1] === "") throw new EdictError(`${where} :text must be a non-empty string`);
    if (bang && verb === "intend") throw new EdictError(`${where}: an Intentfile refuses "!"; it keeps room to explore (A7 8.4)`);

    const aw = c.get("applies-when");
    if (aw.length !== 1 || aw[0][0] !== "clause") throw new EdictError(`${where} (applies-when …) holds exactly one selector`);
    const sel = aw[0];
    if (sel[1] === "clade") {
      throw new EdictError(`${where} (applies-when (clade …)) is refused: a clade placement is an identity fact, and no edict hangs off it (W10)`);
    }
    if (sel[1] === "always") {
      if (sel[2].length) throw new EdictError(`${where} (always) takes nothing`);
    } else if (SELECTOR_HEADS.has(sel[1])) {
      if (!sel[2].length) throw new EdictError(`${where} (${sel[1]} …) needs at least one field`);
      const seen = new Set();
      for (const m of sel[2]) {
        if (m[0] !== "field") throw new EdictError(`${where} (${sel[1]} …) takes fields only`);
        if (m[3]) throw new EdictError(`'!' is allowed only on a rule's :id, not in a selector`);
        if (seen.has(m[1])) throw new EdictError(`${where} (${sel[1]} …) repeats :${m[1]}`);
        seen.add(m[1]);
      }
    } else {
      throw new EdictError(`${where} (applies-when (${sel[1]} …)): a selector is (always), (identity …), (profile …), (capabilities …) or (context …)`);
    }

    const rq = c.get("requires");
    if (rq.length !== 1 || rq[0][0] !== "clause") throw new EdictError(`${where} (requires …) holds exactly one requirement`);
    const req = rq[0];
    if (req[1] !== verb) throw new EdictError(`${where} (requires (${req[1]} …)) must test this verb's facts: (requires (${verb} …))`);
    const rm = new Map();
    for (const m of req[2]) {
      if (m[0] !== "field" || !["witness", ...COMPARATORS].includes(m[1])) {
        throw new EdictError(`${where} (requires (${verb} …)) takes :witness and one of :value, :at-least, :at-most`);
      }
      if (m[3]) throw new EdictError(`'!' is allowed only on a rule's :id, not in a requirement`);
      if (rm.has(m[1])) throw new EdictError(`${where} (requires (${verb} …)) repeats :${m[1]}`);
      rm.set(m[1], m[2]);
    }
    const w = rm.get("witness");
    if (!w || w[0] !== "string" || w[1] !== id[1]) {
      throw new EdictError(`${where} (requires (${verb} :witness …)) must name the rule's own :id ${JSON.stringify(id[1])} (J5)`);
    }
    if (COMPARATORS.filter((k) => rm.has(k)).length !== 1) {
      throw new EdictError(`${where} (requires (${verb} …)) takes exactly one of :value, :at-least and :at-most`);
    }
    out.push({ id: id[1], bang, text: f.get("text")[1] });
  }
  return { verb, ofChora: ofId, rules: out };
}

// ---------------------------------------------------------------------------
// The six verb descriptiles (A7 7.1, 7.3, 8.5; clauses/verb-descriptile.abnf).

export class VerbDescriptileError extends LintError {
  constructor(msg) {
    super(msg, null);
    this.name = "VerbDescriptileError";
  }

  toString() {
    return this.msg;
  }
}

const EVIDENCE = new Set(["draft", "designed", "assumed", "tested", "audited", "proven", "measured"]);
const BUST_GRADE = /^[ABCDEX][1-5]$/;
const FACT_FIELDS = ["witnesses", "evidence", "value", "source", "inherent", "residual", "justification"];

/** The verb an ALL-CAPS verb descriptile name declares, or null (A7 7.1, 8.1 table). */
export function verbOfDescriptile(filename) {
  if (!filename) return null;
  const b = basename(filename);
  for (const [verb, cap] of Object.entries(CONTRACTILE_VERBS)) if (b === `${cap.toUpperCase()}.deed`) return verb;
  return null;
}

/**
 * The chora id an identity value names, as a lowercase UUID body, for
 * comparison (A7 S2, J28): an opaque version 8 #uuid is its own body; a #u8
 * literal names the profile C id of its preimage; a #u5 is an error in every
 * mode (S2). Returns null for any other value; the caller words the error.
 */
export function choraIdOf(v, E, where) {
  if (v[0] === "uuid5") throw E(`${where} is a #u5 literal; a version 5 id in an identity field is an error in every mode (A7 S2)`);
  if (v[0] === "uuid8") return profileCOfBody(v[1]);
  if (v[0] === "uuid" && v[1][14] === "8") return v[1];
  return null;
}

/** The header fields every descriptile-deed carries (A7 7.1). */
const DESCRIPTILE_HEADER = ["schema-version", "canonical-name", "of-chora", "affirmed", "affirmed-by", "expires"];

/** The descriptile schema this profile reads (A7 Q5): major 1, minor 0. */
const DESCRIPTILE_SCHEMA = [1, 0];

/**
 * The fixed date the fixture runners and unit tests check :expires against
 * (YD06), so a committed fixture cannot age into failure. Production checks
 * use todayUtc().
 */
export const FIXTURE_TODAY = "2026-11-14";

/** Today, UTC, as YYYY-MM-DD. */
function todayUtc() {
  return new Date().toISOString().slice(0, 10);
}

/**
 * Check a descriptile-deed's header fields (A7 7.1): :canonical-name, a
 * version 8 :of-chora (J20; equal to repoUuid when given, YD08), and the
 * affirmation members, required by default (J4, YD06): no relaxation can be
 * written until the agentic module and the J19 receipt interface exist.
 * :expires, when present, must not have passed by today (YD06). The
 * :schema-version has three numeric segments and major 1; a higher minor is
 * read and warned (A7 Q5). Returns the warnings.
 */
function checkDescriptileHeader(fields, what, E, repoUuid, today) {
  const warnings = [];
  const sv = fields.get("schema-version");
  const m = sv && sv[0] === "string" ? /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(sv[1]) : null;
  if (!m) throw E(`:schema-version must have three numeric segments, as "1.0.0" (A7 Q5)`);
  if (Number(m[1]) !== DESCRIPTILE_SCHEMA[0]) {
    throw E(`:schema-version ${sv[1]} has major ${m[1]}; this profile reads major ${DESCRIPTILE_SCHEMA[0]} only (A7 Q5)`);
  }
  if (Number(m[2]) > DESCRIPTILE_SCHEMA[1]) {
    warnings.push(`:schema-version ${sv[1]} is a newer minor than ${DESCRIPTILE_SCHEMA.join(".")}; read under the ${DESCRIPTILE_SCHEMA.join(".")} rules (A7 Q5)`);
  }
  for (const k of ["canonical-name", "of-chora"]) if (!fields.has(k)) throw E(`${what} is missing :${k}`);
  if (fields.get("canonical-name")[0] !== "string") throw E(":canonical-name must be a string");
  const ofId = choraIdOf(fields.get("of-chora"), E, ":of-chora");
  if (ofId === null) throw E(":of-chora must be the repo's version 8 chora id, an opaque #uuid\"…\" or a #u8 literal (J20, J28)");
  if (repoUuid !== undefined && ofId !== repoUuid) {
    throw E(`:of-chora ${ofId} is not this repo's chora id ${repoUuid}, the :repo-uuid of its chora deed (YD08)`);
  }
  for (const k of ["affirmed", "affirmed-by"]) {
    if (!fields.has(k)) throw E(`${what} is missing :${k}; affirmation is required by default (J4, YD06)`);
  }
  for (const k of ["affirmed", "expires"]) {
    if (!fields.has(k)) continue;
    const v = fields.get(k);
    if (v[0] !== "string" || !isCalendarDate(v[1])) throw E(`:${k} must be a real YYYY-MM-DD date`);
  }
  if (fields.get("affirmed-by")[0] !== "symbol") throw E(":affirmed-by must be a symbol: owner, agent or the name of the check (A7 7.1)");
  if (fields.has("expires") && fields.get("expires")[1] < fields.get("affirmed")[1]) {
    throw E(":expires is before :affirmed");
  }
  if (fields.has("expires") && fields.get("expires")[1] < today) {
    throw E(`:expires ${fields.get("expires")[1]} has passed (today is ${today}); an expired descriptile is refused (YD06)`);
  }
  return warnings;
}

/**
 * Check a verb descriptile (INTENT.deed … BUST.deed). Returns
 * {verb, facts: [{witnesses, evidence}]}, or null when the file is not a
 * verb descriptile (another head, or another descriptile name). When
 * opts.ruleIds is a Set (the :id values of the verb's edict), every
 * :witnesses must be one of them (YD02). When opts.repoUuid is a string (the
 * :repo-uuid of the repo's chora deed), :of-chora must equal it (YD08).
 * Throws LintError on a violation.
 */
export function checkVerbDescriptile(text, filename, opts = {}) {
  const [head, items] = validate(text, filename);
  if (head !== "descriptile-deed") return null;
  const verb = verbOfDescriptile(filename);
  if (verb === null) return null;
  const E = (m) => new VerbDescriptileError(m);
  const fields = new Map();
  const facts = [];
  for (const it of items) {
    if (it[0] === "field") {
      if (it[3]) throw E(`'!' belongs only on a rule's :id in a contractile-deed, not on :${it[1]}`);
      if (it[1] === "beholding-chora") throw E(":beholding-chora names an estate chora; a descriptile-deed names its repo with :of-chora (J20)");
      if (!["schema-version", "canonical-name", "of-chora", "affirmed", "affirmed-by", "expires"].includes(it[1])) {
        throw E(`a verb descriptile has no field :${it[1]}`);
      }
      if (fields.has(it[1])) throw E(`a verb descriptile carries :${it[1]} once`);
      fields.set(it[1], it[2]);
      continue;
    }
    if (it[1] === "fact") facts.push(it[2]);
    else if (it[1] === "rule") throw E("a descriptile states what is; a (rule …) belongs in the verb's <Verb>file.deed (YF02, YL3)");
    else throw E(`a verb descriptile has no clause (${it[1]} …); its clauses are (fact …)`);
  }
  const warnings = checkDescriptileHeader(fields, "a verb descriptile", E, opts.repoUuid, opts.today ?? todayUtc());

  const seen = new Set();
  const out = [];
  for (const members of facts) {
    const f = new Map();
    for (const m of members) {
      if (m[0] !== "field") throw E(`(fact …) takes fields only, not (${m[1]} …)`);
      if (m[3]) throw E(`'!' belongs only on a rule's :id in a contractile-deed, not on (fact :${m[1]})`);
      if (!FACT_FIELDS.includes(m[1])) throw E(`(fact …) has no field :${m[1]}`);
      if (f.has(m[1])) throw E(`(fact …) repeats :${m[1]}`);
      f.set(m[1], m[2]);
    }
    const w = f.get("witnesses");
    if (!w) throw E("(fact …) is missing :witnesses, the :id of the rule it witnesses (J5)");
    if (w[0] !== "string" || !EDICT_ID.test(w[1])) throw E("(fact :witnesses …) must be a rule :id: a string of letters, digits, \".\", \"_\" and \"-\"");
    const where = `(fact :witnesses ${JSON.stringify(w[1])})`;
    if (`contractile/${verb}/${w[1]}`.length > 200) {
      throw E(`${where}: contractile/${verb}/${w[1]} is longer than 200 characters, so no rule can carry that id (A5 3.1)`);
    }
    if (seen.has(w[1])) throw E(`${where} appears twice; one fact per rule`);
    seen.add(w[1]);
    if (opts.ruleIds && !opts.ruleIds.has(w[1])) {
      throw E(`${where} names no rule in the ${verb} edict (YD02)`);
    }
    const ev = f.get("evidence");
    if (!ev) throw E(`${where} is missing :evidence (J5, A2 D2)`);
    if (ev[0] !== "symbol" || !EVIDENCE.has(ev[1])) throw E(`${where} :evidence must be one of ${[...EVIDENCE].join(" ")} (A2 D2, YD03)`);
    if (f.has("source") && (f.get("source")[0] !== "string" || !isRepoRelative(f.get("source")[1]))) {
      throw E(`${where} :source must be a repo-relative path`);
    }
    if (verb === "bust") {
      for (const k of ["inherent", "residual"]) {
        if (!f.has(k)) throw E(`${where} a Bust fact carries :${k}, a grade such as "C1" (A7 8.5)`);
        const g = f.get(k);
        if (g[0] !== "string" || !BUST_GRADE.test(g[1])) throw E(`${where} :${k} must be a grade: a letter A, B, C, D, E or X and a number 1 to 5 (A7 8.5)`);
      }
      if (f.has("value")) throw E(`${where} a Bust fact has no :value; its residual grade is the fact (A7 8.5)`);
      if (f.has("justification") && f.get("justification")[0] !== "string") throw E(`${where} :justification must be a string`);
    } else {
      if (!f.has("value")) throw E(`${where} is missing :value`);
      for (const k of ["inherent", "residual", "justification"]) {
        if (f.has(k)) throw E(`${where} :${k} belongs only in a Bust fact (A7 8.5)`);
      }
    }
    out.push({ witnesses: w[1], evidence: ev[1] });
  }
  return { verb, facts: out, warnings };
}

/**
 * The :repo-uuid of the one <repo>_chora.deed directly in dir, for YD08, or
 * undefined when dir holds none. Throws when there are several, or when the
 * id is neither a version 8 #uuid nor a #u8 literal (whose profile C id is
 * compared, A7 S2): a #u5 id is an error in every mode, so the check fails
 * rather than passing unchecked.
 */
export function choraRepoUuid(dir) {
  const c = rootChora(dir);
  return c === undefined ? undefined : c.uuid;
}

/**
 * The one <repo>_chora.deed directly in dir: {uuid, name, clauses}, or
 * undefined; clauses are its top-level clause names (YF03).
 * needName (the ecosystem profile, YD07) also requires exactly one string
 * :canonical-name; the YD08 id lookup alone does not, and name is then null
 * when the chora has none.
 */
export function rootChora(dir, { needName = false } = {}) {
  const choras = readdirSync(dir).filter((n) => n.endsWith("_chora.deed") && n !== "estate_chora.deed");
  if (choras.length === 0) return undefined;
  if (choras.length > 1) throw new VerbDescriptileError(`${dir} holds ${choras.length} chora deeds; YD08 needs exactly one`);
  const f = join(dir, choras[0]);
  const [, items] = validate(readFileSync(f, "utf8"), f);
  const us = items.filter((it) => it[0] === "field" && it[1] === "repo-uuid");
  if (us.length > 1) throw new VerbDescriptileError(`${choras[0]} carries :repo-uuid ${us.length} times; YD08 needs exactly one`);
  const u = us[0];
  const id = u ? choraIdOf(u[2], (m) => new VerbDescriptileError(m), `${choras[0]} :repo-uuid`) : null;
  if (id === null) {
    throw new VerbDescriptileError(`${choras[0]} has no version 8 :repo-uuid (#uuid or #u8), so :of-chora cannot be checked against it (YD08)`);
  }
  // YD07 compares against the chora's name, so when it is needed a chora
  // without exactly one string :canonical-name fails here rather than
  // skipping that check.
  const ns = items.filter((it) => it[0] === "field" && it[1] === "canonical-name");
  const named = ns.length === 1 && ns[0][2][0] === "string";
  if (needName && !named) {
    throw new VerbDescriptileError(`${choras[0]} must carry exactly one string :canonical-name to check against (YD07)`);
  }
  // The chora's top-level clause names, for YF03 (a chora (status …) or
  // (maturity …) after J15).
  const clauses = items.filter((it) => it[0] === "clause").map((it) => it[1]);
  return { uuid: id, name: named ? ns[0][2][1] : null, clauses };
}

/**
 * The rule ids of the verb's edict at path, for YD02. When repoUuid is given,
 * the edict's own :of-chora must equal it (YD08): facts are never joined
 * against another repo's rules.
 */
export function edictRuleIdsAt(p, repoUuid) {
  const r = checkEdict(readFileSync(p, "utf8"), p);
  if (repoUuid !== undefined && r.ofChora !== repoUuid) {
    throw new VerbDescriptileError(`${basename(p)} has :of-chora ${r.ofChora}, not this repo's chora id ${repoUuid} (YD08)`);
  }
  return new Set(r.rules.map((x) => x.id));
}

/** --verb-descriptile FILE... [--root DIR]: profile-check each file; returns exit code. */
function verbDescriptileFiles(files, root) {
  let bad = 0;
  for (const f of files) {
    try {
      const text = readFileSync(f, "utf8");
      const verb = verbOfDescriptile(f);
      let repoUuid;
      if (root) {
        repoUuid = choraRepoUuid(root);
        if (repoUuid === undefined) throw new VerbDescriptileError(`--root ${root} holds no <repo>_chora.deed to check :of-chora against (YD08)`);
      }
      const ruleIds = root && verb ? edictRuleIdsAt(join(root, contractilePaths(verb).declaration), repoUuid) : undefined;
      const r = checkVerbDescriptile(text, f, { ruleIds, repoUuid });
      console.log(`OK   ${f} (${r === null ? "not a verb descriptile" : `${r.verb} descriptile, ${r.facts.length} fact${r.facts.length === 1 ? "" : "s"}${ruleIds ? ", witnesses and :of-chora checked against the repo" : ""}`})`);
      for (const w of (r && r.warnings) || []) console.log(`WARN ${f}: ${w}`);
    } catch (e) {
      if (!(e instanceof LintError) && !e.code) throw e;
      bad += 1;
      // Name the file that could not be read: with --root it may be the
      // verb's edict, not the descriptile.
      console.log(`FAIL ${f}: ${e instanceof LintError ? e.toString() : `cannot read ${e.path ?? f} (${e.code})`}`);
    }
  }
  return bad ? 1 : 0;
}

/**
 * --verb-descriptile-fixtures DIR: DIR/{valid,invalid}/<case>/<VERB>.deed.
 * A case may also hold the verb's <Verb>file.deed, and then the witnesses are
 * checked against it (YD02), and a <repo>_chora.deed, and then :of-chora is
 * checked against its :repo-uuid (YD08). A missing or empty half is a setup error (2).
 */
function verbDescriptileFixtures(d) {
  let bad = 0;
  for (const [sub, expect] of [["valid", true], ["invalid", false]]) {
    let cases;
    try {
      cases = readdirSync(join(d, sub)).sort();
    } catch (e) {
      console.log(`ERROR ${join(d, sub)}: cannot read the fixture directory (${e.code || e.message})`);
      return 2;
    }
    if (cases.length === 0) {
      console.log(`ERROR ${join(d, sub)}: no fixture cases`);
      return 2;
    }
    for (const c of cases) {
      const dir = join(d, sub, c);
      const deeds = readdirSync(dir).filter((n) => verbOfDescriptile(n) !== null);
      if (deeds.length !== 1) {
        console.log(`ERROR ${dir}: a case holds exactly one verb descriptile`);
        return 2;
      }
      const f = join(dir, deeds[0]);
      const verb = verbOfDescriptile(f);
      const edict = join(dir, `${CONTRACTILE_VERBS[verb]}file.deed`);
      let got = true;
      let err = "";
      try {
        const repoUuid = choraRepoUuid(dir);
        const ruleIds = existsSync(edict) ? edictRuleIdsAt(edict, repoUuid) : undefined;
        if (checkVerbDescriptile(readFileSync(f, "utf8"), f, { ruleIds, repoUuid, today: FIXTURE_TODAY }) === null) throw new VerbDescriptileError("not a verb descriptile");
      } catch (e) {
        if (!(e instanceof LintError)) throw e;
        got = false;
        err = e.toString();
      }
      if (got !== expect) bad += 1;
      console.log(`${got === expect ? "PASS " : "FAIL "}${f}` + (got === expect ? "" : `  (unexpected: ${err || "valid"})`));
    }
  }
  return bad ? 1 : 0;
}

// ---------------------------------------------------------------------------
// ECOSYSTEM.deed (A7 7.2, YD07; clauses/ecosystem.abnf).

export class EcosystemError extends LintError {
  constructor(msg) {
    super(msg, null);
    this.name = "EcosystemError";
  }

  toString() {
    return this.msg;
  }
}

/**
 * The closed :relationship vocabulary (A7 7.2): the seven terms owner-ruled
 * 2026-09-19 in mappings/meta-ecosystem-to-repo-deed.adoc, and the four
 * DESCRIPTILE-SPEC observed (parent among them).
 */
export const ECOSYSTEM_RELATIONSHIPS = new Set([
  "standard-source", "build-tooling", "validation-tooling", "signing-tooling",
  "verification-tooling", "minted-from", "registry",
  "downstream-consumer", "sibling-language", "code-dependency", "parent",
]);
const ECOSYSTEM_STRINGS = ["project", "ecosystem", "position-type", "purpose", "pipeline-position", "chain", "pipeline-notes"];
const ECOSYSTEM_FIELDS = [...DESCRIPTILE_HEADER, ...ECOSYSTEM_STRINGS, "not", "coordination"];

/**
 * Check ECOSYSTEM.deed source text. Returns {project, related: [{name,
 * relationship, uuid}]}, or null for any other file or head. opts.repoUuid
 * and opts.choraName come from the repo's chora deed (YD08, YD07);
 * opts.strict requires :uuid on every (related …) (J12).
 */
export function checkEcosystem(text, filename, opts = {}) {
  const [head, items] = validate(text, filename);
  if (head !== "descriptile-deed" || basename(filename || "") !== "ECOSYSTEM.deed") return null;
  const E = (m) => new EcosystemError(m);
  const fields = new Map();
  const related = [];
  for (const it of items) {
    if (it[0] === "field") {
      if (it[3]) throw E(`'!' belongs only on a rule's :id in a contractile-deed, not on :${it[1]}`);
      if (it[1] === "beholding-chora") throw E(":beholding-chora names an estate chora; a descriptile-deed names its repo with :of-chora (J20)");
      if (!ECOSYSTEM_FIELDS.includes(it[1])) throw E(`ECOSYSTEM.deed has no field :${it[1]}`);
      if (fields.has(it[1])) throw E(`ECOSYSTEM.deed carries :${it[1]} once`);
      fields.set(it[1], it[2]);
      continue;
    }
    if (it[1] === "related") related.push(it[2]);
    else if (it[1] === "rule") throw E("a descriptile states what is; a (rule …) belongs in an edict (YF02, YL3)");
    else throw E(`ECOSYSTEM.deed has no clause (${it[1]} …); its clause is (related …)`);
  }
  const warnings = checkDescriptileHeader(fields, "ECOSYSTEM.deed", E, opts.repoUuid, opts.today ?? todayUtc());
  for (const k of ["project", "ecosystem", "position-type", "purpose"]) {
    if (!fields.has(k)) throw E(`ECOSYSTEM.deed is missing :${k} (A7 7.2)`);
  }
  for (const k of ECOSYSTEM_STRINGS) {
    if (fields.has(k) && (fields.get(k)[0] !== "string" || fields.get(k)[1] === "")) throw E(`:${k} must be a non-empty string`);
  }
  if (fields.has("not")) {
    const n = fields.get("not");
    if (n[0] !== "list" || !n[1].every((x) => x[0] === "string" && x[1] !== "")) throw E(":not must be a list of non-empty strings");
  }
  if (fields.has("coordination")) {
    const c = fields.get("coordination");
    // the hub repo's name as a symbol, or "" for a standalone repo (mappings/meta-ecosystem-to-repo-deed.adoc)
    if (!(c[0] === "symbol" || (c[0] === "string" && c[1] === ""))) {
      throw E(':coordination must be the hub repo\'s name as a symbol, or "" for a standalone repo');
    }
  }
  const project = fields.get("project")[1];
  const own = fields.get("canonical-name")[1];
  if (project !== own) throw E(`:project ${JSON.stringify(project)} must equal :canonical-name ${JSON.stringify(own)} (YD07)`);
  if (opts.choraName !== undefined && project !== opts.choraName) {
    throw E(`:project ${JSON.stringify(project)} must equal the chora deed's :canonical-name ${JSON.stringify(opts.choraName)} (YD07)`);
  }

  const seen = new Set();
  const out = [];
  for (const members of related) {
    const f = new Map();
    for (const m of members) {
      if (m[0] !== "field") throw E(`(related …) takes fields only, not (${m[1]} …)`);
      if (m[3]) throw E(`'!' belongs only on a rule's :id in a contractile-deed, not on (related :${m[1]})`);
      if (!["name", "relationship", "notes", "uuid"].includes(m[1])) throw E(`(related …) has no field :${m[1]}`);
      if (f.has(m[1])) throw E(`(related …) repeats :${m[1]}`);
      f.set(m[1], m[2]);
    }
    for (const k of ["name", "relationship", "notes"]) if (!f.has(k)) throw E(`(related …) is missing :${k} (A7 7.2)`);
    const name = f.get("name");
    if (name[0] !== "string" || name[1] === "") throw E("(related :name …) must be a non-empty string");
    const where = `(related :name ${JSON.stringify(name[1])})`;
    const rel = f.get("relationship");
    if (rel[0] !== "symbol" || !ECOSYSTEM_RELATIONSHIPS.has(rel[1])) {
      throw E(`${where} :relationship must be one of ${[...ECOSYSTEM_RELATIONSHIPS].join(" ")} (A7 7.2, YD07)`);
    }
    if (f.get("notes")[0] !== "string") throw E(`${where} :notes must be a string`);
    let uuid;
    if (f.has("uuid")) {
      const u = f.get("uuid");
      uuid = choraIdOf(u, E, `${where} :uuid`);
      if (uuid === null) throw E(`${where} :uuid must be the related repo's version 8 chora id, an opaque #uuid or a #u8 literal (J12, A7 S2)`);
    } else if (opts.strict) {
      throw E(`${where} needs :uuid, the related repo's chora id, in strict mode (J12)`);
    }
    const key = `${name[1]}\u0000${rel[1]}`;
    if (seen.has(key)) throw E(`${where} :relationship ${rel[1]} appears twice`);
    seen.add(key);
    out.push({ name: name[1], relationship: rel[1], uuid });
  }
  return { project, related: out, warnings };
}

/** --ecosystem FILE... [--root DIR] [--strict]: returns exit code. */
function ecosystemFiles(files, root, strict) {
  let bad = 0;
  for (const f of files) {
    try {
      const text = readFileSync(f, "utf8");
      let chora;
      if (root) {
        chora = rootChora(root, { needName: true });
        if (chora === undefined) throw new EcosystemError(`--root ${root} holds no <repo>_chora.deed to check against (YD07, YD08)`);
      }
      const r = checkEcosystem(text, f, { repoUuid: chora && chora.uuid, choraName: chora && chora.name, strict });
      console.log(`OK   ${f} (${r === null ? "not ECOSYSTEM.deed" : `${r.related.length} related${chora ? ", checked against the chora" : ""}${strict ? ", strict" : ""}`})`);
      for (const w of (r && r.warnings) || []) console.log(`WARN ${f}: ${w}`);
    } catch (e) {
      if (!(e instanceof LintError) && !e.code) throw e;
      bad += 1;
      console.log(`FAIL ${f}: ${e instanceof LintError ? e.toString() : `cannot read (${e.code})`}`);
    }
  }
  return bad ? 1 : 0;
}

/**
 * --ecosystem-fixtures DIR: DIR/{valid,invalid}/<case>/ECOSYSTEM.deed, with an
 * optional <repo>_chora.deed beside it (then YD07 and YD08 are checked against
 * it) and an optional file named STRICT (then the case runs in strict mode).
 */
function ecosystemFixtures(d) {
  let bad = 0;
  for (const [sub, expect] of [["valid", true], ["invalid", false]]) {
    let cases;
    try {
      cases = readdirSync(join(d, sub)).sort();
    } catch (e) {
      console.log(`ERROR ${join(d, sub)}: cannot read the fixture directory (${e.code || e.message})`);
      return 2;
    }
    if (cases.length === 0) {
      console.log(`ERROR ${join(d, sub)}: no fixture cases`);
      return 2;
    }
    for (const c of cases) {
      const dir = join(d, sub, c);
      const f = join(dir, "ECOSYSTEM.deed");
      if (!existsSync(f)) {
        console.log(`ERROR ${dir}: a case holds ECOSYSTEM.deed`);
        return 2;
      }
      let got = true;
      let err = "";
      try {
        const chora = rootChora(dir, { needName: true });
        const r = checkEcosystem(readFileSync(f, "utf8"), f, {
          repoUuid: chora && chora.uuid, choraName: chora && chora.name, strict: existsSync(join(dir, "STRICT")), today: FIXTURE_TODAY,
        });
        if (r === null) throw new EcosystemError("not ECOSYSTEM.deed");
      } catch (e) {
        if (!(e instanceof LintError)) throw e;
        got = false;
        err = e.toString();
      }
      if (got !== expect) bad += 1;
      console.log(`${got === expect ? "PASS " : "FAIL "}${f}` + (got === expect ? "" : `  (unexpected: ${err || "valid"})`));
    }
  }
  return bad ? 1 : 0;
}

// ---------------------------------------------------------------------------
// STATE.deed (A7 7.2, J3, J15, YF03; clauses/state.abnf).

export class StateError extends LintError {
  constructor(msg) {
    super(msg, null);
    this.name = "StateError";
  }

  toString() {
    return this.msg;
  }
}

/** The lifecycle phases, verbatim (CLADE-004/005; mappings/clade-to-repo-deed.adoc). */
export const STATE_PHASES = new Set(["reserved", "incubating", "active", "dormant", "merged", "superseded", "archived", "extinct"]);
/** The maturity levels (vocabulary/maturity.adoc). */
export const MATURITY_LEVELS = new Set(["experimental", "alpha", "beta", "production", "lts"]);

/**
 * The fields of one clause as a Map, each at most once and each named in
 * `allowed`; a nested clause is refused unless `nested` names it, and then
 * kept under its own name as ["clause", members].
 */
function stateMembers(members, where, allowed, E, nested = []) {
  const f = new Map();
  for (const m of members) {
    if (m[0] === "field") {
      if (m[3]) throw E(`'!' belongs only on a rule's :id in a contractile-deed, not on ${where} :${m[1]}`);
      if (!allowed.includes(m[1])) throw E(`${where} has no field :${m[1]}`);
    } else if (!nested.includes(m[1])) {
      throw E(`${where} has no clause (${m[1]} …)`);
    }
    const key = m[0] === "field" ? m[1] : `(${m[1]})`;
    if (f.has(key)) throw E(`${where} carries ${m[0] === "field" ? `:${m[1]}` : `(${m[1]} …)`} once`);
    f.set(key, m[2]);
  }
  return f;
}

function stateSymbol(f, k, set, where, E) {
  const v = f.get(k);
  if (v[0] !== "symbol" || !set.has(v[1])) throw E(`${where} :${k} must be one of ${[...set].join(" ")}, as a symbol`);
  return v[1];
}

function stateDate(f, k, where, E, { empty = false } = {}) {
  if (!f.has(k)) return;
  const v = f.get(k);
  if (v[0] === "string" && (isCalendarDate(v[1]) || (empty && v[1] === ""))) return;
  throw E(`${where} :${k} must be a real YYYY-MM-DD date${empty ? ' or ""' : ""}`);
}

function stateStrings(f, k, where, E) {
  if (!f.has(k)) return;
  const v = f.get(k);
  if (v[0] !== "list" || !v[1].every((x) => x[0] === "string")) throw E(`${where} :${k} must be a list of strings`);
}

/**
 * Check STATE.deed source text. Returns {phase, maturity, warnings}, or null
 * for any other file or head. opts.repoUuid comes from the repo's chora deed
 * (YD08); opts.choraClauses (the chora's top-level clause names) turns on
 * YF03: a chora (status …) or (maturity …) is warned, and refused when
 * opts.strict.
 */
export function checkState(text, filename, opts = {}) {
  const [head, items] = validate(text, filename);
  if (head !== "descriptile-deed" || basename(filename || "") !== "STATE.deed") return null;
  const E = (m) => new StateError(m);
  const fields = new Map();
  const clauses = { status: [], maturity: [] };
  for (const it of items) {
    if (it[0] === "field") {
      if (it[3]) throw E(`'!' belongs only on a rule's :id in a contractile-deed, not on :${it[1]}`);
      if (it[1] === "beholding-chora") throw E(":beholding-chora names an estate chora; a descriptile-deed names its repo with :of-chora (J20)");
      if (!DESCRIPTILE_HEADER.includes(it[1])) throw E(`STATE.deed has no field :${it[1]}; its facts are the (status …) and (maturity …) clauses (A7 7.2)`);
      if (fields.has(it[1])) throw E(`STATE.deed carries :${it[1]} once`);
      fields.set(it[1], it[2]);
      continue;
    }
    if (it[1] === "rule") throw E("a descriptile states what is; a (rule …) belongs in an edict (YF02, YL3)");
    if (it[1] === "state") throw E("there is no (state …) clause: the journal stays in docs/status/ROADMAP.adoc (J3)");
    if (!(it[1] in clauses)) throw E(`STATE.deed has no clause (${it[1]} …); its clauses are (status …) and (maturity …) (A7 7.2)`);
    clauses[it[1]].push(it[2]);
  }
  const warnings = checkDescriptileHeader(fields, "STATE.deed", E, opts.repoUuid, opts.today ?? todayUtc());
  if (clauses.status.length !== 1) throw E(`STATE.deed carries (status …) exactly once, not ${clauses.status.length} times (A7 7.2, J15)`);
  if (clauses.maturity.length > 1) throw E("STATE.deed carries (maturity …) at most once (vocabulary/maturity.adoc)");

  const s = stateMembers(clauses.status[0], "(status …)", ["phase", "since", "present", "aliases", "merged-into", "superseded-by", "successors", "ended"], E, ["history"]);
  if (!s.has("phase")) throw E("(status …) is missing :phase (A7 7.2)");
  const phase = stateSymbol(s, "phase", STATE_PHASES, "(status …)", E);
  stateDate(s, "since", "(status …)", E);
  stateDate(s, "ended", "(status …)", E, { empty: true });
  if (s.has("present") && s.get("present")[0] !== "boolean") throw E("(status …) :present must be #t or #f");
  for (const k of ["merged-into", "superseded-by"]) if (s.has(k) && s.get(k)[0] !== "string") throw E(`(status …) :${k} must be a string`);
  for (const k of ["aliases", "successors"]) stateStrings(s, k, "(status …)", E);
  for (const entry of s.get("(history)") || []) {
    if (entry[0] !== "clause" || entry[1] !== "entry") {
      throw E(`(history …) holds (entry …) clauses only, not ${entry[0] === "field" ? `:${entry[1]}` : `(${entry[1]} …)`}`);
    }
    const e = stateMembers(entry[2], "(history (entry …))", ["phase", "since", "note"], E);
    for (const k of ["phase", "since"]) if (!e.has(k)) throw E(`(history (entry …)) is missing :${k}`);
    stateSymbol(e, "phase", STATE_PHASES, "(history (entry …))", E);
    stateDate(e, "since", "(history (entry …))", E);
    if (e.has("note") && e.get("note")[0] !== "string") throw E("(history (entry …)) :note must be a string");
  }

  let maturity = null;
  if (clauses.maturity.length === 1) {
    const m = stateMembers(clauses.maturity[0], "(maturity …)", ["level", "since"], E);
    if (!m.has("level")) throw E("(maturity …) is missing :level (vocabulary/maturity.adoc)");
    maturity = stateSymbol(m, "level", MATURITY_LEVELS, "(maturity …)", E);
    stateDate(m, "since", "(maturity …)", E);
  }

  for (const c of ["status", "maturity"]) {
    if (!(opts.choraClauses || []).includes(c)) continue;
    const msg = `the chora deed still carries (${c} …), which moved to STATE.deed (J15, YF03)`;
    if (opts.strict) throw E(`${msg}; refused in strict mode`);
    warnings.push(`${msg}; read as a fallback for one release`);
  }
  return { phase, maturity, warnings };
}

/** --state FILE... [--root DIR] [--strict]: returns exit code. */
function stateFiles(files, root, strict) {
  let bad = 0;
  for (const f of files) {
    try {
      const text = readFileSync(f, "utf8");
      let chora;
      if (root) {
        chora = rootChora(root);
        if (chora === undefined) throw new StateError(`--root ${root} holds no <repo>_chora.deed to check against (YD08, YF03)`);
      }
      const r = checkState(text, f, { repoUuid: chora && chora.uuid, choraClauses: chora && chora.clauses, strict });
      console.log(`OK   ${f} (${r === null ? "not STATE.deed" : `phase ${r.phase}, maturity ${r.maturity ?? "unstated"}${chora ? ", checked against the chora" : ""}${strict ? ", strict" : ""}`})`);
      for (const w of (r && r.warnings) || []) console.log(`WARN ${f}: ${w}`);
    } catch (e) {
      if (!(e instanceof LintError) && !e.code) throw e;
      bad += 1;
      console.log(`FAIL ${f}: ${e instanceof LintError ? e.toString() : `cannot read (${e.code})`}`);
    }
  }
  return bad ? 1 : 0;
}

/**
 * --state-fixtures DIR: DIR/{valid,invalid}/<case>/STATE.deed, with an
 * optional <repo>_chora.deed beside it (then YD08 and YF03 are checked
 * against it) and an optional file named STRICT (then the case runs in
 * strict mode).
 */
function stateFixtures(d) {
  let bad = 0;
  for (const [sub, expect] of [["valid", true], ["invalid", false]]) {
    let cases;
    try {
      cases = readdirSync(join(d, sub)).sort();
    } catch (e) {
      console.log(`ERROR ${join(d, sub)}: cannot read the fixture directory (${e.code || e.message})`);
      return 2;
    }
    if (cases.length === 0) {
      console.log(`ERROR ${join(d, sub)}: no fixture cases`);
      return 2;
    }
    for (const c of cases) {
      const dir = join(d, sub, c);
      const f = join(dir, "STATE.deed");
      if (!existsSync(f)) {
        console.log(`ERROR ${dir}: a case holds STATE.deed`);
        return 2;
      }
      let got = true;
      let err = "";
      try {
        const chora = rootChora(dir);
        const r = checkState(readFileSync(f, "utf8"), f, {
          repoUuid: chora && chora.uuid, choraClauses: chora && chora.clauses, strict: existsSync(join(dir, "STRICT")), today: FIXTURE_TODAY,
        });
        if (r === null) throw new StateError("not STATE.deed");
      } catch (e) {
        if (!(e instanceof LintError)) throw e;
        got = false;
        err = e.toString();
      }
      if (got !== expect) bad += 1;
      console.log(`${got === expect ? "PASS " : "FAIL "}${f}` + (got === expect ? "" : `  (unexpected: ${err || "valid"})`));
    }
  }
  return bad ? 1 : 0;
}

/** --edict FILE...: profile-check each file; returns exit code. */
function edictFiles(files) {
  let bad = 0;
  for (const f of files) {
    let text;
    try {
      text = readFileSync(f, "utf8");
    } catch (e) {
      bad += 1;
      console.log(`FAIL ${f}: cannot read the file (${e.code || e.message})`);
      continue;
    }
    try {
      const r = checkEdict(text, f);
      console.log(`OK   ${f} (${r === null ? "not a contractile-deed" : `${r.verb} edict, ${r.rules.length} rule${r.rules.length === 1 ? "" : "s"}`})`);
    } catch (e) {
      if (!(e instanceof LintError)) throw e;
      bad += 1;
      console.log(`FAIL ${f}: ${e.toString()}`);
    }
  }
  return bad ? 1 : 0;
}

/**
 * --edict-fixtures DIR: DIR/valid/<case>/<Verb>file.deed must pass and
 * DIR/invalid/<case>/<Verb>file.deed must fail. Each case is a directory,
 * because an edict's file name is fixed by its verb (J14). A missing or empty
 * half is a setup error (2), never a pass.
 */
function edictFixtures(d) {
  let bad = 0;
  for (const [sub, expect] of [["valid", true], ["invalid", false]]) {
    let cases;
    try {
      cases = readdirSync(join(d, sub)).sort();
    } catch (e) {
      console.log(`ERROR ${join(d, sub)}: cannot read the fixture directory (${e.code || e.message})`);
      return 2;
    }
    if (cases.length === 0) {
      console.log(`ERROR ${join(d, sub)}: no fixture cases`);
      return 2;
    }
    for (const c of cases) {
      const deeds = readdirSync(join(d, sub, c)).filter((n) => n.endsWith(".deed"));
      if (deeds.length !== 1) {
        console.log(`ERROR ${join(d, sub, c)}: a case holds exactly one .deed`);
        return 2;
      }
      const f = join(d, sub, c, deeds[0]);
      let got = true;
      let err = "";
      try {
        checkEdict(readFileSync(f, "utf8"), f);
      } catch (e) {
        if (!(e instanceof LintError)) throw e;
        got = false;
        err = e.toString();
      }
      if (got !== expect) bad += 1;
      console.log(`${got === expect ? "PASS " : "FAIL "}${f}` + (got === expect ? "" : `  (unexpected: ${err || "valid"})`));
    }
  }
  return bad ? 1 : 0;
}

/**
 * valid/ must pass a clause profile; invalid/ must fail it. Returns exit code.
 * Both halves must exist and hold fixtures: a missing or empty half is a
 * setup error (2), never a pass. A fixture named template-* is the template's
 * own deed and is checked with {template: true}.
 */
function profileFixtures(d, check) {
  let bad = 0;
  for (const [sub, expect] of [["valid", true], ["invalid", false]]) {
    let names;
    try {
      names = readdirSync(join(d, sub)).filter((n) => n.endsWith(".deed")).sort();
    } catch (e) {
      console.log(`ERROR ${join(d, sub)}: cannot read the fixture directory (${e.code || e.message})`);
      return 2;
    }
    if (names.length === 0) {
      console.log(`ERROR ${join(d, sub)}: no .deed fixtures; a corpus needs both valid/ and invalid/ cases`);
      return 2;
    }
    for (const n of names) {
      const f = join(d, sub, n);
      let got = true;
      let err = "";
      try {
        check(readFileSync(f, "utf8"), f, { template: n.startsWith("template-") });
      } catch (e) {
        if (!(e instanceof LintError)) throw e;
        got = false;
        err = e.message;
      }
      if (got !== expect) bad += 1;
      console.log(`${got === expect ? "PASS " : "FAIL "}${f}` + (got === expect ? "" : `  (unexpected: ${err || "valid"})`));
    }
  }
  return bad ? 1 : 0;
}

/** --anchor FILE...: profile-check each file; returns exit code. */
function anchorFiles(files, opts = {}) {
  let bad = 0;
  for (const f of files) {
    let text;
    try {
      text = readFileSync(f, "utf8");
    } catch (e) {
      // One unreadable path is that file's failure, not the end of the batch.
      bad += 1;
      console.log(`FAIL ${f}: cannot read the file (${e.code || e.message})`);
      continue;
    }
    try {
      const a = checkAnchor(text, f, opts);
      console.log(`OK   ${f} (${a === null ? "no anchor clause" : `anchor, authority ${JSON.stringify(a.authority)}`})`);
      if (a && a.legacy) console.log(`WARN ${f}: legacy ${ANCHOR_SCHEMA_LEGACY}; move to ${ANCHOR_SCHEMA}: (identity …) becomes (subject …), (parents …) moves to ECOSYSTEM.deed and (ssg …) to META.deed (A7 J8, J26, J27, J29)`);
    } catch (e) {
      if (!(e instanceof LintError)) throw e;
      bad += 1;
      console.log(`FAIL ${f}: ${e instanceof AnchorError ? e.message : e.toString()}`);
    }
  }
  return bad ? 1 : 0;
}

function tryValidate(src, filename) {
  try {
    validate(src, filename);
    return [true, ""];
  } catch (e) {
    if (e instanceof LintError) return [false, e.toString()];
    throw e;
  }
}

/** Run the embedded corpus, printing PASS/FAIL per case; returns exit code. */
function selfTest() {
  let ok = true;
  for (const { name, expectOk, src } of SELF_TEST_CASES) {
    const [got, err] = tryValidate(src);
    const passed = got === expectOk;
    ok = ok && passed;
    const detail = passed ? "" : `  (expected ${expectOk ? "valid" : "error"}; got ${got ? "valid" : err})`;
    console.log(`${passed ? "PASS " : "FAIL "}${name}${detail}`);
  }
  console.log("SELF-TEST " + (ok ? "OK" : "FAILED"));
  return ok ? 0 : 1;
}

/** valid/ must parse; invalid/ must fail. Returns exit code. */
function fixtures(d) {
  let bad = 0;
  for (const [sub, expect] of [["valid", true], ["invalid", false]]) {
    let names = [];
    try {
      names = readdirSync(join(d, sub)).filter((n) => n.endsWith(".deed")).sort();
    } catch {
      // missing directory: nothing to check (Python glob yields no matches)
    }
    for (const n of names) {
      const f = join(d, sub, n);
      let got, err;
      try {
        [got, err] = tryValidate(readFileSync(f, "utf8"), f);
      } catch (e) {
        got = false;
        err = String(e.message);
      }
      if (got !== expect) bad += 1;
      console.log(`${got === expect ? "PASS " : "FAIL "}${f}` + (got === expect ? "" : `  (unexpected: ${err || "valid"})`));
    }
  }
  return bad ? 1 : 0;
}

/** CLI entry: dispatch on --self-test / --fixtures / file list; returns exit code. */

// ---------------------------------------------------------------------------
// --contractile-registry: generate the A5 rule registry of the `contractile`
// domain from a repo's six edicts (A7 J13, J13a).
//
//   bun deed_lint.js --contractile-registry --root DIR [--owner OWNER/NAME] [--out FILE] [--check]
//
// Reads .machine_readable/contractiles/<verb>/<Verb>file.deed under DIR for
// all six verbs (a missing edict is an error, A7 J13), checks each with deed_lint.js's edict profile, and
// writes one praxis-deed (A5 4.1) with one rule-def per rule:
//
//   :id "contractile/<verb>/<rule-id>"   :text   the rule's text
//   :class gate        for every must rule and every rule marked "!"
//   :class advisory    otherwise (A7 8.4)
//   :excusable-at repo :scope-form exact-paths :status active
//   :floor "A7 8.5"    on a bust rule: the estate floor, which no deviation lowers
//
// A rule that has left the edicts keeps its entry with :status retired, read
// from the registry as last written, and a retired id cannot return (A5 3.2).
// A rename is a retirement plus a new id here: the edict form records no
// supersession, so :supersedes links are not generated.
//
// :beholding-chora and the SPDX header are copied from the repo's own chora
// deed at DIR, so nothing is invented. --check regenerates in memory and exits
// 1 when the committed file differs (A7 J13: CI fails when regenerating
// changes the registry). Output order is fixed: the verbs in A7's order, the
// rules in file order.
const REGISTRY_OUT = ".machine_readable/contractiles/contractile_rules_praxis.deed";

function registryArgs(argv) {
  const o = { root: null, owner: "metadatastician/standards", out: null, check: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--root") o.root = argv[++i];
    else if (a === "--owner") o.owner = argv[++i];
    else if (a === "--out") o.out = argv[++i];
    else if (a === "--check") o.check = true;
    else throw new Error(`unknown argument ${a}`);
  }
  if (!o.root) throw new Error("--root DIR is required");
  if (!/^[^/\s]+\/[^/\s]+$/.test(o.owner || "")) throw new Error("--owner must be OWNER/NAME");
  return o;
}

/** A deed string literal for s: the four escapes deed.abnf allows. */
function deedStr(s) {
  return '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\t/g, "\\t") + '"';
}

/** Re-serialise an identity value from the AST, exactly as written. */
function idLiteral(v) {
  if (v[0] === "uuid") return `#uuid"${v[1]}"`;
  if (v[0] === "uuid8") return `#u8${deedStr(v[1])}`;
  if (v[0] === "uuid5") return `#u5${deedStr(v[1])}`;
  throw new Error(`:beholding-chora is a ${v[0]}, not a UUID literal`);
}

/** The repo's chora deed at root: its SPDX header lines and :beholding-chora. */
function readChora(root) {
  const choras = readdirSync(root).filter((n) => n.endsWith("_chora.deed") && n !== "estate_chora.deed");
  if (choras.length !== 1) throw new Error(`expected one <repo>_chora.deed at ${root}, found ${choras.length}`);
  const file = join(root, choras[0]);
  const text = readFileSync(file, "utf8");
  const [, items] = validate(text, file);
  const b = items.find((it) => it[0] === "field" && it[1] === "beholding-chora");
  if (!b) throw new Error(`${choras[0]} has no :beholding-chora`);
  const spdx = text.split("\n").filter((l) => /^;; SPDX-/.test(l));
  return { spdx, beholding: idLiteral(b[2]) };
}

/** One rule-def, fields in fixed order. */
function ruleDef(d) {
  const lines = [
    `    (rule-def`,
    `      :id ${deedStr(d.id)}`,
    `      :text ${deedStr(d.text)}`,
    `      :class ${d.class}`,
    `      :excusable-at ${d["excusable-at"]}`,
    `      :scope-form ${d["scope-form"]}`,
    `      :status ${d.status}`,
  ];
  if (d["superseded-by"] !== undefined) lines.push(`      :superseded-by ${deedStr(d["superseded-by"])}`);
  if (d.floor !== undefined) lines.push(`      :floor ${deedStr(d.floor)}`);
  return lines.join("\n") + ")";
}

/** The rule-defs of an earlier generated registry, as plain objects, in order. */
function priorDefs(prior, file) {
  if (prior === null) return [];
  const [, items] = validate(prior, file);
  const rules = items.find((it) => it[0] === "clause" && it[1] === "rules");
  if (!rules) return [];
  return rules[2]
    .filter((d) => d[0] === "clause" && d[1] === "rule-def")
    .map((d) => Object.fromEntries(d[2].filter((f) => f[0] === "field").map((f) => [f[1], f[2][1]])));
}

/**
 * Generate the registry text. prior is the registry as last committed (or
 * null): A5 3.2 says an id is never deleted or reused, so a rule that has left
 * the edicts stays, with :status retired, and an id that was retired cannot
 * come back as an active rule.
 */
export function generateContractileRegistry(root, owner, prior = null, priorFile = REGISTRY_OUT) {
  const { spdx, beholding } = readChora(root);
  const missing = Object.keys(CONTRACTILE_VERBS)
    .map((verb) => contractilePaths(verb).declaration)
    .filter((p) => !existsSync(join(root, p)));
  if (missing.length) throw new Error(`the registry is generated from all six edicts (A7 J13); missing: ${missing.join(", ")}`);
  const old = priorDefs(prior, priorFile);
  const retired = new Set(old.filter((d) => d.status === "retired").map((d) => d.id));
  const current = [];
  for (const verb of Object.keys(CONTRACTILE_VERBS)) {
    const p = join(root, contractilePaths(verb).declaration);
    const r = checkEdict(readFileSync(p, "utf8"), p);
    for (const rule of r.rules) {
      const id = `contractile/${verb}/${rule.id}`;
      if (retired.has(id)) throw new Error(`${id} was retired; a retired id is never reused (A5 3.2)`);
      current.push({
        id,
        text: rule.text,
        class: verb === "must" || rule.bang ? "gate" : "advisory",
        "excusable-at": "repo",
        "scope-form": "exact-paths",
        status: "active",
        floor: verb === "bust" ? "A7 8.5" : undefined,
      });
    }
  }
  const live = new Set(current.map((d) => d.id));
  const gone = old.filter((d) => !live.has(d.id)).map((d) => ({ ...d, status: "retired" }));
  const defs = [...current, ...gone].map(ruleDef);
  return [
    ...spdx,
    ";; GENERATED by 1-formats/deed/tools/deed_lint.js --contractile-registry from the six",
    ";; <Verb>file.deed edicts (A7 J13). Do not edit; regenerate.",
    "(praxis-deed",
    '  :schema-version "1.0.0"',
    '  :canonical-name "contractile-rules"',
    `  :beholding-chora ${beholding}`,
    `  (rule-domain :name "contractile" :owner ${deedStr(owner)})`,
    defs.length ? `  (rules\n${defs.join("\n")}))` : "  (rules))",
    "",
  ].join("\n");
}

function registryMain(argv) {
  let o;
  try {
    o = registryArgs(argv);
  } catch (e) {
    console.error(`usage: deed_lint.js --contractile-registry --root DIR [--owner OWNER/NAME] [--out FILE] [--check]\n${e.message}`);
    return 2;
  }
  const out = o.out || join(o.root, REGISTRY_OUT);
  const prior = existsSync(out) ? readFileSync(out, "utf8") : null;
  let text;
  try {
    text = generateContractileRegistry(o.root, o.owner, prior, out);
    validate(text, out);
  } catch (e) {
    console.error(`FAIL ${o.root}: ${e instanceof LintError ? e.toString() : e.message}`);
    return 1;
  }
  if (o.check) {
    const have = prior;
    if (have === text) {
      console.log(`OK   ${out} is up to date`);
      return 0;
    }
    console.log(`FAIL ${out} ${have === null ? "is missing" : "differs from the edicts"}; regenerate with deed_lint.js --contractile-registry --root ${o.root}`);
    return 1;
  }
  writeFileSync(out, text);
  console.log(`wrote ${out}`);
  return 0;
}


function main(argv) {
  if (argv.includes("--proof-receipt-json")) {
    if (argv.length !== 2 || argv[0] !== "--proof-receipt-json" || argv[1].startsWith("-")) {
      console.error("usage: deed_lint.js --proof-receipt-json FILE");
      return 2;
    }
    const file = argv[1];
    try {
      console.log(JSON.stringify(readProofReceipt(readFileSync(file, "utf8"), file)));
      return 0;
    } catch (e) {
      console.error("FAIL " + file + ": " + (e instanceof LintError ? e.toString() : e.message));
      return 1;
    }
  }
  if (argv.includes("--mustfile-json")) {
    if (argv.length !== 2 || argv[0] !== "--mustfile-json" || argv[1].startsWith("-")) {
      console.error("usage: deed_lint.js --mustfile-json FILE");
      return 2;
    }
    const file = argv[1];
    try {
      console.log(JSON.stringify(readMustfileChecks(readFileSync(file, "utf8"), file)));
      return 0;
    } catch (e) {
      console.error("FAIL " + file + ": " + (e instanceof LintError ? e.toString() : e.message));
      return 1;
    }
  }
  if (argv.includes("--ast-json")) {
    // One input and a clean stdout contract: consumers must never receive a
    // partial AST or a success-shaped empty result for invalid DEED input.
    if (argv.length !== 2 || argv[0] !== "--ast-json" || argv[1].startsWith("-")) {
      console.error("usage: deed_lint.js --ast-json FILE");
      return 2;
    }
    const file = argv[1];
    try {
      const [head, items] = validate(readFileSync(file, "utf8"), file);
      console.log(JSON.stringify({ head, items }));
      return 0;
    } catch (e) {
      console.error(`FAIL ${file}: ${e instanceof LintError ? e.toString() : e.message}`);
      return 1;
    }
  }
  if (argv.includes("--self-test")) return selfTest();
  if (argv.includes("--egress-fixtures")) {
    const d = argv[argv.indexOf("--egress-fixtures") + 1];
    if (d === undefined) {
      console.log("--egress-fixtures requires a DIR argument");
      return 2;
    }
    const rc = egressFixtures(d);
    console.log("EGRESS FIXTURES " + (rc === 0 ? "OK" : "FAILED"));
    return rc;
  }
  if (argv.includes("--anchor-fixtures")) {
    const d = argv[argv.indexOf("--anchor-fixtures") + 1];
    if (d === undefined) {
      console.log("--anchor-fixtures requires a DIR argument");
      return 2;
    }
    const rc = profileFixtures(d, checkAnchor);
    console.log("ANCHOR FIXTURES " + (rc === 0 ? "OK" : rc === 2 ? "NOT CHECKED" : "FAILED"));
    return rc;
  }
  if (argv.includes("--contractile-registry")) return registryMain(argv.filter((a) => a !== "--contractile-registry"));
  if (argv.includes("--ecosystem-fixtures")) {
    const d = argv[argv.indexOf("--ecosystem-fixtures") + 1];
    if (d === undefined) {
      console.log("--ecosystem-fixtures requires a DIR argument");
      return 2;
    }
    const rc = ecosystemFixtures(d);
    console.log("ECOSYSTEM FIXTURES " + (rc === 0 ? "OK" : rc === 2 ? "NOT CHECKED" : "FAILED"));
    return rc;
  }
  if (argv.includes("--ecosystem")) {
    const ri = argv.indexOf("--root");
    const root = ri >= 0 ? argv[ri + 1] : null;
    if (ri >= 0 && (root === undefined || root === "" || root.startsWith("-"))) {
      console.log("--root requires a DIR argument");
      return 2;
    }
    const files = argv.filter((a, i) => !a.startsWith("-") && !(ri >= 0 && i === ri + 1));
    if (files.length === 0) {
      console.log(DOC);
      return 2;
    }
    return ecosystemFiles(files, root, argv.includes("--strict"));
  }
  if (argv.includes("--state-fixtures")) {
    const d = argv[argv.indexOf("--state-fixtures") + 1];
    if (d === undefined) {
      console.log("--state-fixtures requires a DIR argument");
      return 2;
    }
    const rc = stateFixtures(d);
    console.log("STATE FIXTURES " + (rc === 0 ? "OK" : rc === 2 ? "NOT CHECKED" : "FAILED"));
    return rc;
  }
  if (argv.includes("--state")) {
    const ri = argv.indexOf("--root");
    const root = ri >= 0 ? argv[ri + 1] : null;
    if (ri >= 0 && (root === undefined || root === "" || root.startsWith("-"))) {
      console.log("--root requires a DIR argument");
      return 2;
    }
    const files = argv.filter((a, i) => !a.startsWith("-") && !(ri >= 0 && i === ri + 1));
    if (files.length === 0) {
      console.log(DOC);
      return 2;
    }
    return stateFiles(files, root, argv.includes("--strict"));
  }
  if (argv.includes("--verb-descriptile-fixtures")) {
    const d = argv[argv.indexOf("--verb-descriptile-fixtures") + 1];
    if (d === undefined) {
      console.log("--verb-descriptile-fixtures requires a DIR argument");
      return 2;
    }
    const rc = verbDescriptileFixtures(d);
    console.log("VERB DESCRIPTILE FIXTURES " + (rc === 0 ? "OK" : rc === 2 ? "NOT CHECKED" : "FAILED"));
    return rc;
  }
  if (argv.includes("--verb-descriptile")) {
    const ri = argv.indexOf("--root");
    const root = ri >= 0 ? argv[ri + 1] : null;
    if (ri >= 0 && (root === undefined || root === "" || root.startsWith("-"))) {
      console.log("--root requires a DIR argument");
      return 2;
    }
    const files = argv.filter((a, i) => !a.startsWith("-") && !(ri >= 0 && i === ri + 1));
    if (files.length === 0) {
      console.log(DOC);
      return 2;
    }
    return verbDescriptileFiles(files, root);
  }
  if (argv.includes("--edict-fixtures")) {
    const d = argv[argv.indexOf("--edict-fixtures") + 1];
    if (d === undefined) {
      console.log("--edict-fixtures requires a DIR argument");
      return 2;
    }
    const rc = edictFixtures(d);
    console.log("EDICT FIXTURES " + (rc === 0 ? "OK" : rc === 2 ? "NOT CHECKED" : "FAILED"));
    return rc;
  }
  if (argv.includes("--edict")) {
    const files = argv.filter((a) => !a.startsWith("-"));
    if (files.length === 0) {
      console.log(DOC);
      return 2;
    }
    return edictFiles(files);
  }
  if (argv.includes("--contractiles-fixtures")) {
    const d = argv[argv.indexOf("--contractiles-fixtures") + 1];
    if (d === undefined) {
      console.log("--contractiles-fixtures requires a DIR argument");
      return 2;
    }
    const rc = profileFixtures(d, checkContractiles);
    console.log("CONTRACTILES FIXTURES " + (rc === 0 ? "OK" : rc === 2 ? "NOT CHECKED" : "FAILED"));
    return rc;
  }
  if (argv.includes("--contractiles")) {
    const i = argv.indexOf("--root");
    const root = i === -1 ? null : argv[i + 1];
    if (i !== -1 && (root === undefined || root.startsWith("-"))) {
      console.log("--root requires a DIR argument");
      return 2;
    }
    const files = argv.filter((a, k) => !a.startsWith("-") && !(i !== -1 && k === i + 1));
    if (files.length === 0) {
      console.log(DOC);
      return 2;
    }
    return contractilesFiles(files, { root });
  }
  if (argv.includes("--anchor")) {
    const files = argv.filter((a) => !a.startsWith("-"));
    if (files.length === 0) {
      console.log(DOC);
      return 2;
    }
    return anchorFiles(files, { template: argv.includes("--template") });
  }
  if (argv.includes("--egress")) {
    const files = argv.filter((a) => !a.startsWith("-"));
    if (files.length === 0) {
      console.log(DOC);
      return 2;
    }
    return egressFiles(files);
  }
  if (argv.includes("--fixtures")) {
    const d = argv[argv.indexOf("--fixtures") + 1];
    if (d === undefined) {
      console.log("--fixtures requires a DIR argument");
      return 2;
    }
    const rc = fixtures(d);
    console.log("FIXTURES " + (rc === 0 ? "OK" : "FAILED"));
    return rc;
  }
  const files = argv.filter((a) => !a.startsWith("-"));
  if (files.length === 0) {
    console.log(DOC);
    return 2;
  }
  let bad = 0;
  for (const f of files) {
    try {
      validate(readFileSync(f, "utf8"), f);
      console.log(`OK   ${f}`);
    } catch (e) {
      bad += 1;
      console.log(`FAIL ${f}: ${e instanceof LintError ? e.toString() : e.message}`);
    }
  }
  return bad ? 1 : 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
