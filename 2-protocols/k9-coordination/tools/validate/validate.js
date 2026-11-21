#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
// hypatia: allow cicd_rules/javascript_detected -- conformance gate: apg-js is the ABNF engine; no AffineScript ABNF tooling exists yet
//
// validate.js — conformance validator for coordination.k9 files.
//
//   bun validate.js FILE...              exit 0 iff every FILE conforms
//   bun validate.js --self-test          fixtures, the repo's own files, mutants,
//                                        and the v1.1 -> v1.2 -> v1.3 extension checks
//   bun validate.js --compile-reach FILE print the reach section of a conforming
//                                        FILE as reach.json (canonical bytes)
//
// A file conforms when it parses as `k9-file` under the normative grammar,
// spec/abnf/coordination-k9-grammar_v1.3.abnf (through apg-js), and meets the
// schema rules the grammar cannot express (COORDINATION-K9-SPEC "Validation
// Rules"): rule 11, `metadata` carries exactly one `schema: k9-coordination`,
// and, when the file has a reach section, rules 15, 17 and 20 to 23.
// Rules 1-10, 12 and 16 are the grammar's. Before either, every line must be at
// most 998 octets, not counting its CR and LF (rule 14; the constraint the
// grammar states in its header, owner ruling I4, 2026-11-12).
//
// v1.2 -> v1.3 adds one optional element (reach) to `body`. The self-test
// checks that side condition on the committed grammars with the same check
// as v1.1 -> v1.2. The Idris transcription in proofs/GrammarExtension.idr
// covers v1.1 -> v1.2 only; extending it to v1.3 is open work.
//
// --self-test also re-checks, on the committed grammar files, the side
// condition of `v11FilesAreV12Files` in proofs/GrammarExtension.idr: every
// rule v1.1 defines other than `body`, v1.2 defines identically, and the
// `body` lists the proof transcribes are the committed ones. With the proof,
// that makes every string the v1.1 grammar derives one the v1.2 grammar
// derives (RFC 5234 semantics; that apg-js agrees with those semantics on
// this grammar is tested here, not proved). The proof and the check cover
// the ABNF productions only: rule 14's line limit is outside both, so a v1.1
// file with a line over 998 octets is not a conforming v1.2 file.
// Exit 0 pass, 1 finding, 2 cannot run.
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import apg from "apg-js";

const { apgApi, apgLib } = apg;
const HERE = import.meta.dir;
const SPEC = resolve(HERE, "../../spec/abnf");
const GRAMMAR = join(SPEC, "coordination-k9-grammar_v1.3.abnf");
const GRAMMAR_V12 = join(SPEC, "coordination-k9-grammar_v1.2.abnf");
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

/** Longest line the format admits, in octets, excluding the line end. RFC
 * 5322 Section 2.1.1 sets the same bound; it is what makes the registered
 * "8bit" encoding label exact (RFC 2045 Section 2.8). */
export const MAX_LINE_OCTETS = 998;

/** Rule 14: return null when no line exceeds MAX_LINE_OCTETS, else a reason
 * naming the first line that does. Lines end at LF; a CR before the LF is part
 * of the line end, not of the line. */
function lineLengthError(bytes) {
  let start = 0, line = 1;
  for (let i = 0; i <= bytes.length; i++) {
    if (i < bytes.length && bytes[i] !== 0x0a) continue;
    let end = i;
    if (end > start && bytes[end - 1] === 0x0d && i < bytes.length) end--;
    if (end - start > MAX_LINE_OCTETS) {
      return `line ${line} is ${end - start} octets, over the ${MAX_LINE_OCTETS}-octet line limit (rule 14)`;
    }
    start = i + 1;
    line++;
  }
  return null;
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
  const long = lineLengthError(bytes);
  if (long !== null) return long;
  const line = grammarError(grammar, bytes);
  if (line !== null) return `does not parse as k9-file under the v1.3 grammar (stops at line ${line})`;
  const text = Buffer.from(bytes).toString("utf8");
  return schemaError(text) ?? reachError(text);
}

// --- Reach section (v1.3.0) ----------------------------------------------

/** Actions that may appear only under `never` (rule 15). */
const NEVER_ONLY = ["merge", "force_push", "delete_branch", "change_environment", "change_permissions", "sign_commit"];
/** Actions that need `access: write` on the grant (rule 23). */
const WRITE_ACTIONS = ["push_branch", "open_draft_pr", "close_pr"];
const LIMIT_BLOCKS = ["window", "extent", "ttl", "rate"];
const MAX_DAYS = 31;

/** The reach section's lines, from `reach:` to the end of the section, with
 * gap lines and line ends dropped; null when the file has none. Called only on
 * text the grammar accepted, so every kept line is a field line. */
function reachLines(text) {
  const lines = text.split(/\r?\n/);
  const start = lines.indexOf("reach:");
  if (start < 0) return null;
  const out = [];
  for (let i = start + 1; i < lines.length && lines[i].startsWith(" "); i++) {
    if (lines[i].trim() !== "") out.push(lines[i]); // space-only gap lines are dropped
  }
  return out;
}

/** Scalar text from the grammar's value forms: quoted strings are unescaped,
 * digit runs become numbers, everything else stays as written. */
function scalar(s) {
  if (s.startsWith('"')) return s.slice(1, -1).replace(/\\(["\\nt])/g, (_, c) => ({ n: "\n", t: "\t" })[c] ?? c);
  return /^[0-9]+$/.test(s) ? Number(s) : s;
}

/** Parse indented `key: value`, `key:` and `- item` lines into nested
 * objects and arrays. The grammar fixes every indent, so this needs no
 * general YAML handling. Returns [value, next index]. */
function parseNode(lines, i, ind) {
  const pad = " ".repeat(ind);
  if (lines[i]?.startsWith(`${pad}- `)) {
    const list = [];
    while (i < lines.length && lines[i].startsWith(`${pad}- `)) {
      const rest = lines[i].slice(ind + 2);
      const kv = /^([a-z_]+): (.*)$/.exec(rest);
      if (kv) {
        const [m, j] = parseMap(lines, i + 1, ind + 2, { [kv[1]]: scalar(kv[2]) });
        list.push(m); i = j;
      } else { list.push(scalar(rest)); i++; }
    }
    return [list, i];
  }
  return parseMap(lines, i, ind, {});
}

function parseMap(lines, i, ind, m) {
  const pad = " ".repeat(ind);
  while (i < lines.length && lines[i].startsWith(pad) && lines[i][ind] !== " " && lines[i][ind] !== "-") {
    const kv = /^([a-z_]+):(?: (.*))?$/.exec(lines[i].slice(ind));
    if (kv[2] !== undefined) { m[kv[1]] = scalar(kv[2]); i++; continue; }
    const next = lines[i + 1] ?? "";
    const childInd = next.length - next.trimStart().length;
    if (childInd <= ind) { m[kv[1]] = {}; i++; continue; } // empty block (rule 23)
    [m[kv[1]], i] = parseNode(lines, i + 1, childInd);
  }
  return [m, i];
}

/** The reach section as the object reach.json holds: roles keyed by name,
 * each role's limits lifted to the role, hours_utc and blackout ranges as
 * arrays. Null when the file has no reach section. */
export function reachObject(text) {
  const lines = reachLines(text);
  if (lines === null) return null;
  const [r] = parseMap(lines, 0, 2, {});
  const roles = {};
  for (const role of r.roles) {
    const { role: name, limits = {}, ...rest } = role;
    const out = { grants: rest.grants };
    for (const [k, v] of Object.entries(limits)) {
      if (k === "window") {
        const w = { ...v };
        if (typeof w.hours_utc === "string") w.hours_utc = w.hours_utc.split("-").map(Number);
        if (w.blackout) w.blackout = w.blackout.map((d) => d.split(".."));
        out.window = w;
      } else out[k] = v;
    }
    if (rest.never) out.never = rest.never;
    if (Object.hasOwn(roles, name)) roles[name] = null; // duplicate, caught by rule 23
    else roles[name] = out;
  }
  return { ...r, roles };
}

/** Canonical reach.json bytes: two-space JSON in section order, one final LF.
 * The admin pins the sha256 of exactly these bytes. */
export function compileReach(text) {
  const obj = reachObject(text);
  return obj === null ? null : `${JSON.stringify(obj, null, 2)}\n`;
}

const isDate = (s) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s)
  && Number.isFinite(Date.parse(`${s}T00:00:00Z`))
  && new Date(`${s}T00:00:00Z`).toISOString().startsWith(s);
const dayCount = (a, b) => (Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400000;

/** Rules 15, 17 and 20 to 23 for a file with a reach section; null when it
 * has none or meets them, else a reason. Called only on text the grammar
 * accepted. */
export function reachError(text) {
  const lines = reachLines(text);
  if (lines === null) return null;
  const rawVer = /^ {2}schema_version: (.*)$/m.exec(text)?.[1];
  const ver = rawVer === undefined ? undefined : String(scalar(rawVer));
  if (ver !== "1.3.0") return `a file with a reach section declares schema_version 1.3.0, not ${ver} (rule 22)`;
  const [r] = parseMap(lines, 0, 2, {});
  const { valid_from: vf, expires: ex } = r;
  if (!isDate(vf) || !isDate(ex)) return "reach valid_from and expires are calendar dates (rule 17)";
  const span = dayCount(vf, ex);
  if (span <= 0 || span > MAX_DAYS) return `reach expires ${span} days after valid_from; it must be 1 to ${MAX_DAYS} (rule 17)`;
  const names = new Set();
  for (const role of r.roles) {
    const who = `role ${role.role}`;
    if (names.has(role.role)) return `${who} appears twice (rule 23)`;
    names.add(role.role);
    const repos = new Set();
    for (const g of role.grants) {
      if (repos.has(g.repo)) return `${who} grants ${g.repo} twice (rule 23)`;
      repos.add(g.repo);
      if (new Set(g.actions).size !== g.actions.length) return `${who} lists an action twice on ${g.repo} (rule 23)`;
      const bad = g.actions.find((a) => NEVER_ONLY.includes(a));
      if (bad) return `${who} grants ${bad} on ${g.repo}; it may appear only under never (rule 15)`;
      const w = g.actions.find((a) => WRITE_ACTIONS.includes(a));
      if (w && g.access !== "write") return `${who} grants ${w} on ${g.repo} without access: write (rule 23)`;
      if ((g.paths || g.max_files_per_push !== undefined) && g.access !== "write") {
        return `${who} sets paths or max_files_per_push on read-only ${g.repo} (rule 23)`;
      }
    }
    const lim = role.limits ?? {};
    for (const b of LIMIT_BLOCKS) {
      if (lim[b] !== undefined && Object.keys(lim[b]).length === 0) return `${who} has an empty ${b} block (rule 23)`;
    }
    const win = lim.window ?? {};
    if (win.days && new Set(win.days).size !== win.days.length) return `${who} lists a day twice (rule 23)`;
    if (win.hours_utc !== undefined) {
      const [h0, h1] = win.hours_utc.split("-").map(Number);
      if (!(h0 < h1 && h1 <= 24)) return `${who} hours_utc ${win.hours_utc}: start is below end, end at most 24 (rule 20)`;
    }
    for (const d of win.blackout ?? []) {
      const [a, b] = d.split("..");
      if (!isDate(a) || !isDate(b) || a > b) return `${who} blackout ${d} is not a date range (rule 21)`;
      if (a < vf || b > ex) return `${who} blackout ${d} is outside ${vf} to ${ex} (rule 21)`;
    }
    if (role.never && new Set(role.never).size !== role.never.length) return `${who} lists a never action twice (rule 23)`;
  }
  return null;
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

/** The side condition of GrammarExtension.idr: every rule of the old grammar
 * is in the new one unchanged, except that `body` may gain optional `[...]`
 * elements; rules new in the new grammar do not reuse an old name. Used for
 * v1.1 -> v1.2 and v1.2 -> v1.3. Returns a list of violations. */
export function extensionViolations(oldPath, newPath, from = "v1.1", to = "v1.2") {
  const a = rules(oldPath), b = rules(newPath), bad = [];
  for (const [name, def] of a) {
    if (!b.has(name)) { bad.push(`${from} rule ${name} is missing from ${to}`); continue; }
    if (b.get(name) === def) continue;
    if (name !== "body") { bad.push(`${from} rule ${name} changed in ${to}`); continue; }
    // body: removing the new extra optional elements must give the old body back.
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
  const g = compile(GRAMMAR), g11 = compile(GRAMMAR_V11), g12 = compile(GRAMMAR_V12);
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
    if (grammarError(g12, bytes) === null) ok(true, `${basename(f)} is also a v1.2 file`);
    // A reach fixture's compiled form must match its committed reach.json.
    const json = join(HERE, "fixtures/reach", basename(f).replace(/\.k9$/, ".json"));
    if (existsSync(json)) {
      ok(compileReach(bytes.toString("utf8")) === readFileSync(json, "utf8"), `${basename(f)} compiles to fixtures/reach/${basename(json)}`);
    }
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
    "a project name that makes a 999-octet line": root.replace(/\n  name: "standards"/, `\n  name: "${"x".repeat(989)}"`),
  };
  for (const [label, text] of Object.entries(mutants)) {
    ok(text !== root && check(g, Buffer.from(text)) !== null, `rejects the root file with ${label}`);
  }
  const bad = extensionViolations(GRAMMAR_V11, GRAMMAR_V12);
  ok(bad.length === 0, `v1.2 only adds optional elements to v1.1's body${bad.length ? `: ${bad.join("; ")}` : ""}`);
  const bad13 = extensionViolations(GRAMMAR_V12, GRAMMAR, "v1.2", "v1.3");
  ok(bad13.length === 0, `v1.3 only adds optional elements to v1.2's body${bad13.length ? `: ${bad13.join("; ")}` : ""}`);
  // The proof's concrete step is about the body lists it transcribes; they
  // must be the committed grammars' bodies.
  for (const [v, path, name] of [["v1.1", GRAMMAR_V11, "bodyV11"], ["v1.2", GRAMMAR_V12, "bodyV12"]]) {
    const want = elements(rules(path).get("body")).join(" "), got = idrisBody(name)?.join(" ");
    ok(got === want, `proofs/GrammarExtension.idr ${name} is the ${v} body${got === want ? "" : `: ${got} != ${want}`}`);
  }
  console.log(fail ? `self-test: ${fail} failure(s)` : "self-test: all assertions passed");
  return fail ? 1 : 0;
}

function main(argv) {
  if (argv[0] === "--self-test") return selfTest();
  if (argv[0] === "--compile-reach" && argv.length === 2) {
    let text;
    try { text = readFileSync(argv[1]); } catch (e) { console.error(`cannot read: ${e.message}`); return 2; }
    const why = check(compile(GRAMMAR), text);
    if (why !== null) { console.error(`FAIL ${argv[1]}: ${why}`); return 1; }
    const json = compileReach(text.toString("utf8"));
    if (json === null) { console.error(`FAIL ${argv[1]}: no reach section`); return 1; }
    process.stdout.write(json);
    return 0;
  }
  if (!argv.length || argv[0].startsWith("-")) {
    console.error("usage: bun validate.js FILE... | --self-test | --compile-reach FILE");
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
