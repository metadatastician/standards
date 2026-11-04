#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
// Port of deed_lint.py to plain JavaScript (bun, zero dependencies).
const DOC = String.raw`deed-lint — conformance validator for the DEED grammar (deed.abnf v1.2.1).

Stdlib-only. Implements the normative grammar faithfully:
  * header = 1* spdx-line                 (";;" SP "SPDX-" …)
  * form   = "(" doc-head 1*(sep (field/clause)) [sep] ")"
  * doc-head ∈ {estate-deed, repo-deed, estate-atlas-deed, praxis-deed}
  * field  = keyword sep value            clause = "(" symbol *(sep (field/clause)) [sep] ")"
  * value  = string / symbol / integer / boolean / uuid5 / uuid8 / quoted / list
  * boolean = #t | #f  (lowercase ONLY; true/false/1/0 are parse errors)
  * uuid5 = %s"#u5" string                (body is the RFC 4122 §4.3 NAME input)
  * uuid8 = %s"#u8" string                (body is the ADR-008 profile C preimage
                                          domain ":" name; domain = 1*%x21-7E minus ":")
  * escapes exactly {" \\ \n \t}      (\r, \uXXXX and all others INVALID)
  * sep    = 1*(SP / line-end / comment)  (HTAB is INVALID — K9-consistent)
  * symbol = ALPHA *(ALPHA/DIGIT/./"*"//"<"/">"/"="/"!"/"?"/"+"/"-"/"_")
  * quoted = "'" (symbol / list)          (only symbols/lists may be quoted)
Semantic checks (validator-enforced, per grammar):
  * :schema-version STRING exactly once at form top level
  * entire input consumed
  * filename↔doc-head dispatch (estate-first side condition, stem≠"estate")

Usage: deed_lint.js FILE...     exit 0 iff all files conform
       deed_lint.js --self-test
       deed_lint.js --egress FILE...           (egress …) clause profile (ADR-009)
       deed_lint.js --egress-fixtures DIR      DIR/valid pass the profile, DIR/invalid fail it
       deed_lint.js --ast-json FILE           emit the validated AST as JSON (integer lexemes stay strings)
       deed_lint.js --mustfile-json FILE      validate the Mustfile check profile and emit records
`;

import { readdirSync, readFileSync } from "node:fs";
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

/** #-forms: #u5"name" (uuid5), #u8"domain:name" (uuid8) or #t / #f (boolean); anything else is a parse error. */
function lexHashForm(lx) {
  const two = lx.t.slice(lx.i, lx.i + 3);
  if (two.startsWith("#u5")) {
    lx.i += 3;
    if (lx.peek() !== '"') {
      throw new LintError('uuid5 must be followed immediately by a string: #u5"name"', lx.line());
    }
    lexString(lx);
    return ["uuid5", null];
  }
  if (two.startsWith("#u8")) {
    const line = lx.line();
    lx.i += 3;
    if (lx.peek() !== '"') {
      throw new LintError('uuid8 must be followed immediately by a string: #u8"domain:name"', line);
    }
    checkUuid8Body(lexString(lx)[1], line);
    return ["uuid8", null];
  }
  if (two.slice(0, 2) === "#t" || two.slice(0, 2) === "#f") {
    const nxt = lx.peek(2);
    if (nxt && !" \r\n()".includes(nxt)) {
      const tok = lx.t.slice(lx.i + 2, lx.i + 24).trim().split(/\s+/)[0].slice(0, 20);
      throw new LintError(
        `booleans are exactly #t/#f (got ${pyRepr(two + tok)}); true/false/1/0 are parse errors`,
        lx.line(),
      );
    }
    lx.i += 2;
    return ["boolean", two];
  }
  throw new LintError('unrecognised #-form: only #t, #f, #u5"…", #u8"…" are legal', lx.line());
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

/** value = string / symbol / integer / boolean / uuid5 / uuid8 / quoted / list */
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
    return ["field", kw[1], val];
  }
  if (c === "(") {
    lx.i += 1;
    const head = lexSymbol(lx);
    if (!head) {
      throw new LintError("clause '(' must be followed immediately by a clause symbol (no separator)", lx.line());
    }
    const items = [];
    for (;;) {
      // clause = "(" symbol *(token-sep (field / clause)) [token-sep] ")"
      const sep = lx.skipSep();
      if (lx.peek() === ")") {
        lx.i += 1;
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
  const heads = ["estate-deed", "repo-deed", "estate-atlas-deed", "praxis-deed"];
  if (!head || !heads.includes(head[1])) {
    const got = head ? head[1] : lx.peek();
    throw new LintError(`invalid doc-head ${pyRepr(got)}; valid heads: ${heads.join(", ")}`, lx.line());
  }
  if (!lx.skipSep()) {
    throw new LintError(`doc-head ${head[1]} must be followed by a separator before the first field`, lx.line());
  }
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

/** Validate DEED source text. Returns [head, items] on success; throws LintError. */
export function validate(text, filename = null) {
  const tab = text.indexOf("\t");
  if (tab !== -1) {
    let ln = 1;
    for (let k = 0; k < tab; k++) if (text[k] === "\n") ln++;
    throw new LintError("HTAB (tab) is an invalid separator anywhere in a deed (K9-consistent)", ln);
  }
  const lx = new Lexer(text);
  parseHeader(lx);
  lx.skipSep();
  const [head, items] = parseForm(lx);
  if (filename) checkFilenameDispatch(filename, head);
  return [head, items];
}

/**
 * Check a parsed doc-head against the case-sensitive basename of `filename`.
 * Exact names take precedence: estate_chora.deed requires estate-deed,
 * ATLAS.deed requires estate-atlas-deed, and 0-AI-MANIFEST.deed requires
 * repo-deed. Otherwise, _praxis.deed selects praxis-deed and _chora.deed
 * selects repo-deed; stems may contain dots (split on the final suffix).
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
        "(estate_chora.deed | ATLAS.deed | 0-AI-MANIFEST.deed | <stem>_chora.deed | <stem>_praxis.deed)",
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
    ["beholding-chora", new Set(["uuid5", "uuid8"])],
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

const H = ";; SPDX-License-Identifier: CC-BY-SA-4.0\n";

/** The embedded self-test corpus (same 14 cases, order and expectations as the Python). */
export const SELF_TEST_CASES = [
  ["valid-minimal", true,
    H + '(repo-deed :schema-version "1.0.0" :canonical-name "x" :repo-uuid #u5"github.com/o/x" :beholding-chora #u5"estate/chora")\n'],
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
function main(argv) {
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
