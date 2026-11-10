#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
// hypatia: allow cicd_rules/javascript_detected -- conformance gate: apg-js is the ABNF engine; no AffineScript ABNF tooling exists yet
//
// validate.js — conformance validator for coordination.k9 files.
//
//   bun validate.js FILE...         exit 0 iff every FILE conforms
//   bun validate.js --self-test     fixtures, the repo's own files, mutants,
//                                   and the v1.1 -> v1.2 extension check
//
// A file conforms when it parses as `k9-file` under the normative grammar,
// spec/abnf/coordination-k9-grammar_v1.2.abnf (through apg-js), and meets the
// schema rule the grammar cannot express (COORDINATION-K9-SPEC "Validation
// Rules", rule 11): `metadata` carries exactly one `schema: k9-coordination`.
// Rules 1-10 and 12 are the grammar's.
//
// --self-test also re-checks, on the committed grammar files, the side
// condition of `v11FilesAreV12Files` in proofs/GrammarExtension.idr: every
// rule v1.1 defines other than `body`, v1.2 defines identically, and the
// `body` lists the proof transcribes are the committed ones. With the proof,
// that makes every v1.1 file a v1.2 file (RFC 5234 semantics; that apg-js
// agrees with those semantics on this grammar is tested here, not proved).
// Exit 0 pass, 1 finding, 2 cannot run.
import { readFileSync, readdirSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import apg from "apg-js";

const { apgApi, apgLib } = apg;
const HERE = import.meta.dir;
const SPEC = resolve(HERE, "../../spec/abnf");
const GRAMMAR = join(SPEC, "coordination-k9-grammar_v1.2.abnf");
const GRAMMAR_V11 = join(SPEC, "coordination-k9-grammar_v1.1.abnf");
const REPO = resolve(HERE, "../../../..");
const CORE = [
  "ALPHA = %x41-5A / %x61-7A", "DIGIT = %x30-39", "DQUOTE = %x22", "SP = %x20",
  "HTAB = %x09", "VCHAR = %x21-7E", "CR = %x0D", "LF = %x0A", "CRLF = CR LF",
].join("\n");

/** Compile an ABNF file with apg-js. Non-ASCII occurs only in comments, which
 * apg-js rejects, so it is masked there; the RFC 5234 core rules are appended. */
function compile(path) {
  const text = readFileSync(path, "utf8").split("\n").map((l) => {
    const i = l.indexOf(";");
    return i < 0 ? l : l.slice(0, i) + l.slice(i).replace(/[^\x20-\x7e\t]/g, "?");
  }).join("\n");
  const api = new apgApi(`${text}\n${CORE}\n`.replace(/\r?\n/g, "\r\n"));
  api.generate();
  if (api.errors.length) throw new Error(`${path}: ${api.errorsToAscii()}`);
  return api.toObject();
}

/** Parse bytes as `k9-file`; return null on success, else the 1-based line
 * where the parser stopped. */
function grammarError(grammar, bytes) {
  const r = new apgLib.parser().parse(grammar, "k9-file", [...bytes]);
  if (r.success) return null;
  return Buffer.from(bytes.subarray(0, r.maxMatched)).toString("utf8").split("\n").length;
}

/** Rule 11: the metadata section carries exactly one `schema: k9-coordination`.
 * Called only on text the grammar accepted, so the section shape is known. */
function schemaError(text) {
  const lines = text.split(/\r?\n/);
  const start = lines.indexOf("metadata:");
  let n = 0, other = null;
  for (let i = start + 1; i < lines.length && lines[i].startsWith("  "); i++) {
    const m = /^ {2}schema: (.*)$/.exec(lines[i]);
    if (!m) continue;
    n++;
    if (m[1] !== "k9-coordination") other = m[1];
  }
  if (other !== null) return `metadata schema is ${JSON.stringify(other)}, not k9-coordination (rule 11)`;
  if (n !== 1) return `metadata must carry exactly one schema: k9-coordination, found ${n} (rule 11)`;
  return null;
}

/** Validate one file's bytes; return null when it conforms, else a reason. */
export function check(grammar, bytes) {
  const line = grammarError(grammar, bytes);
  if (line !== null) return `does not parse as k9-file under the v1.2 grammar (stops at line ${line})`;
  return schemaError(Buffer.from(bytes).toString("utf8"));
}

/** Rules of an ABNF file as name -> normalised definition: comments removed,
 * continuation lines joined, whitespace collapsed, and top-level alternatives
 * sorted, because RFC 5234 alternation is unordered (reordering alternatives
 * for ordered-choice parsers does not change the language). */
function rules(path) {
  const out = new Map();
  let name = null;
  for (const raw of readFileSync(path, "utf8").split("\n")) {
    const line = raw.replace(/;.*$/, "");
    if (!line.trim()) continue;
    const m = /^([A-Za-z][-A-Za-z0-9]*)\s*=(.*)$/.exec(line);
    if (m) { name = m[1]; out.set(name, m[2]); } else if (name) out.set(name, `${out.get(name)} ${line}`);
  }
  for (const [k, v] of out) out.set(k, split(v.replace(/\s+/g, " ").trim(), "/").sort().join(" / "));
  return out;
}

/** Split an ABNF definition on a top-level separator (" " for concatenation,
 * "/" for alternation), keeping [..], (..) and quoted strings whole. */
function split(def, sep) {
  const out = [];
  let depth = 0, cur = "", quote = false;
  for (const c of def) {
    if (c === '"') quote = !quote;
    if (!quote && (c === "[" || c === "(")) depth++;
    if (!quote && (c === "]" || c === ")")) depth--;
    if (c === sep && depth === 0 && !quote) { if (cur.trim()) out.push(cur.trim()); cur = ""; } else cur += c;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

/** Top-level elements of a concatenation. */
const elements = (def) => split(def, " ");

/** The side condition of GrammarExtension.idr: every v1.1 rule is in v1.2
 * unchanged, except that `body` may gain optional `[...]` elements; rules new in
 * v1.2 do not reuse a v1.1 name. Returns a list of violations. */
export function extensionViolations(oldPath, newPath) {
  const a = rules(oldPath), b = rules(newPath), bad = [];
  for (const [name, def] of a) {
    if (!b.has(name)) { bad.push(`v1.1 rule ${name} is missing from v1.2`); continue; }
    if (b.get(name) === def) continue;
    if (name !== "body") { bad.push(`v1.1 rule ${name} changed in v1.2`); continue; }
    // body: removing v1.2's extra optional elements must give v1.1's body back.
    const olds = elements(def), news = elements(b.get(name));
    let i = 0;
    for (const e of news) {
      if (i < olds.length && e === olds[i]) i++;
      else if (!e.startsWith("[")) bad.push(`body gained a non-optional element ${e}`);
    }
    if (i !== olds.length) bad.push("body lost or reordered a v1.1 element");
  }
  return bad;
}

/** The `body` element list proofs/GrammarExtension.idr transcribes under the
 * given name, written back as ABNF elements, or null when it is not found. */
function idrisBody(name) {
  const src = readFileSync(join(HERE, "proofs/GrammarExtension.idr"), "utf8");
  const m = new RegExp(`^${name} =\\n([\\s\\S]*?)\\n  \\]`, "m").exec(src);
  if (!m) return null;
  return [...m[1].matchAll(/(Ref|optSection) "([^"]+)"|gaps/g)]
    .map((x) => (x[0] === "gaps" ? "*gap" : x[1] === "Ref" ? x[2] : `[${x[2]} *gap]`));
}

function listK9(dir) {
  return readdirSync(dir).filter((f) => f.endsWith(".k9")).sort().map((f) => join(dir, f));
}

function selfTest() {
  const g = compile(GRAMMAR), g11 = compile(GRAMMAR_V11);
  let fail = 0;
  const ok = (cond, label) => { console.log(`${cond ? "ok  " : "FAIL"} ${label}`); if (!cond) fail++; };
  const valid = [join(REPO, "coordination.k9"), ...listK9(resolve(HERE, "../../examples")), ...listK9(join(HERE, "fixtures/valid"))];
  for (const f of valid) {
    const bytes = readFileSync(f);
    const why = check(g, bytes);
    ok(why === null, `accepts ${f.slice(REPO.length + 1)}${why ? ` — ${why}` : ""}`);
    const crlf = Buffer.from(bytes.toString("utf8").replace(/\n/g, "\r\n"));
    ok(check(g, crlf) === null, `accepts ${basename(f)} with CRLF line ends (rule 10)`);
    if (grammarError(g11, bytes) === null) ok(true, `${basename(f)} is also a v1.1 file`);
  }
  for (const f of listK9(join(HERE, "fixtures/invalid"))) {
    const text = readFileSync(f, "utf8");
    const want = /^# expect: (.*)$/m.exec(text)?.[1];
    const why = check(g, Buffer.from(text));
    ok(why !== null && want !== undefined && why.includes(want), `rejects ${basename(f)} (${want}) — got: ${why}`);
  }
  // Mutants of the repository's own file: each must be rejected.
  const root = readFileSync(join(REPO, "coordination.k9"), "utf8");
  const mutants = {
    "a --- separator after the header": root.replace(/\n\nmetadata:/, "\n---\nmetadata:"),
    "a tab instead of two spaces": root.replace("\n  schema:", "\n\tschema:"),
    "a quoted boolean": root.replace("auto_fix: false", 'auto_fix: "false"'),
    "a lower-case magic line": root.replace(/^K9!/, "k9!"),
    "a blank line inside a section": root.replace("\n  schema_version:", "\n\n  schema_version:"),
    "the wrong schema": root.replace("schema: k9-coordination", "schema: k9"),
  };
  for (const [label, text] of Object.entries(mutants)) {
    ok(text !== root && check(g, Buffer.from(text)) !== null, `rejects the root file with ${label}`);
  }
  const bad = extensionViolations(GRAMMAR_V11, GRAMMAR);
  ok(bad.length === 0, `v1.2 only adds optional elements to v1.1's body${bad.length ? `: ${bad.join("; ")}` : ""}`);
  // The proof's concrete step is about the body lists it transcribes; they
  // must be the committed grammars' bodies.
  for (const [v, path, name] of [["v1.1", GRAMMAR_V11, "bodyV11"], ["v1.2", GRAMMAR, "bodyV12"]]) {
    const want = elements(rules(path).get("body")).join(" "), got = idrisBody(name)?.join(" ");
    ok(got === want, `proofs/GrammarExtension.idr ${name} is the ${v} body${got === want ? "" : `: ${got} != ${want}`}`);
  }
  console.log(fail ? `self-test: ${fail} failure(s)` : "self-test: all assertions passed");
  return fail ? 1 : 0;
}

function main(argv) {
  if (argv[0] === "--self-test") return selfTest();
  if (!argv.length || argv[0].startsWith("-")) {
    console.error("usage: bun validate.js FILE... | --self-test");
    return 2;
  }
  const g = compile(GRAMMAR);
  let bad = 0;
  for (const f of argv) {
    let why;
    try { why = check(g, readFileSync(f)); } catch (e) { why = `cannot read: ${e.message}`; }
    console.log(why === null ? `PASS ${f}` : `FAIL ${f}: ${why}`);
    if (why !== null) bad++;
  }
  return bad ? 1 : 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
