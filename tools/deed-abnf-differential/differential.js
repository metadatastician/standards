#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
// hypatia: allow cicd_rules/javascript_detected -- conformance harness: apg-js is the ABNF engine; no AffineScript ABNF tooling exists yet
//
// Grammar-vs-gate differential for the DEED format.
//
//   bun differential.js [--cases N] [--seed S] [--edits E] [SEED.deed ...]
//
// deed.abnf is normative (D308); deed_lint.js is the gate that CI runs. This
// harness keeps them from drifting apart. It compiles deed.abnf (with the
// (egress …) clause profile, clauses/egress.abnf) using apg-js, mutates every
// committed deed with a seeded generator, and asks both the grammar and the
// gate for a verdict on each variant:
//
//   * the gate accepts what the grammar rejects   → FAIL (the gate is lenient)
//   * the gate rejects what the grammar accepts   → FAIL, unless the gate's
//     reason is one of its documented semantic checks (SEMANTIC below), which
//     the grammar does not express
//
// Every valid fixture must also be accepted by both, and every valid egress
// fixture's clause must parse as `egress-clause`. The run is deterministic for
// a given --seed, so a failure in CI reproduces locally with the same flags.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import apg from "apg-js";
import { validate } from "../../1-formats/deed/tools/deed_lint.js";

const { apgApi, apgLib } = apg;
const ROOT = resolve(import.meta.dir, "../..");
const ABNF = join(ROOT, "1-formats/deed/spec/abnf");
const FIXTURES = join(ROOT, "1-formats/deed/tools/fixtures");

// The gate's checks that are semantic, not grammatical (deed_lint.js
// validate): one STRING :schema-version, a non-empty SPDX payload, the
// ADR-008 profile-C shape of a #u8 body, no bare true/false/yes/no symbol
// where a boolean is meant (booleans are #t/#f), and the 998-octet line cap
// of v1.3.0. The #uuid literal is grammar, not a semantic check.
const SEMANTIC = [
  /form must carry exactly one :schema-version/,
  /:schema-version must be a STRING value/,
  /SPDX header line is empty/,
  /uuid8 body .* has no ":"/,
  /uuid8 domain .* must be non-empty printable ASCII/,
  /boolean meaning must use #t\/#f/,
  /a deed line is at most 998 octets/,
];

function args(argv) {
  const opts = { cases: 4000, seed: 20261104, edits: 3, seeds: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--cases") opts.cases = Number(argv[++i]);
    else if (a === "--seed") opts.seed = Number(argv[++i]);
    else if (a === "--edits") opts.edits = Number(argv[++i]);
    else opts.seeds.push(a);
  }
  return opts;
}

function compileGrammar() {
  // apg-js reads ASCII grammar text; non-ASCII occurs only in comments. The
  // RFC 5234 core rules the grammar uses are appended.
  const src =
    (readFileSync(join(ABNF, "deed.abnf"), "utf8") + "\n" +
      readFileSync(join(ABNF, "clauses/egress.abnf"), "utf8")).replace(/[^\x00-\x7f]/g, "?") +
    "\nSP = %x20\nDQUOTE = %x22\nALPHA = %x41-5A / %x61-7A\nDIGIT = %x30-39\n" +
    "VCHAR = %x21-7E\nCR = %x0D\nLF = %x0A\nCRLF = CR LF\n";
  const api = new apgApi(src);
  api.scan();
  if (!api.errors.length) api.parse();
  if (!api.errors.length) api.translate();
  if (!api.errors.length) api.attributes();
  if (api.errors.length) {
    console.error(api.errorsToAscii());
    process.exit(2);
  }
  return api.toObject();
}

// The grammar's UTF8-n rules are byte rules, so apg parses UTF-8 bytes.
function grammarAccepts(grammar, start, text) {
  return new apgLib.parser().parse(grammar, start, Array.from(Buffer.from(text, "utf8"))).success;
}

function gateVerdict(text) {
  try {
    validate(text);
    return { ok: true, why: "" };
  } catch (e) {
    return { ok: false, why: String(e.message || e) };
  }
}

// Sorted at every level, so a --seed picks the same documents on any
// filesystem and a CI failure reproduces locally.
function committedDeeds(dir, out = []) {
  for (const name of readdirSync(dir).sort()) {
    if (name === ".git" || name === "node_modules" || name === "target") continue;
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) {
      if (relative(ROOT, p).startsWith("1-formats/deed/tools/fixtures")) continue;
      committedDeeds(p, out);
    } else if (name.endsWith(".deed")) out.push(p);
  }
  return out;
}

// The (egress …) clause's text. Strings and comments are skipped both while
// finding the clause and while balancing its parentheses: a comment may hold
// any text-char, a parenthesis included (`; disabled)`).
function egressText(t) {
  let depth = 0;
  let start = -1;
  for (let k = 0; k < t.length; k++) {
    const c = t[k];
    if (c === '"') {
      for (k++; k < t.length && t[k] !== '"'; k++) if (t[k] === "\\") k++;
    } else if (c === ";") {
      while (k < t.length && t[k] !== "\n") k++;
    } else if (c === "(") {
      if (start < 0 && t.startsWith("(egress", k) && /[\s)]/.test(t[k + 7] ?? "")) start = k;
      if (start >= 0) depth++;
    } else if (c === ")" && start >= 0 && --depth === 0) {
      return t.slice(start, k + 1);
    }
  }
  return null;
}

const opts = args(process.argv.slice(2));
const grammar = compileGrammar();
const failures = [];
const fail = (kind, detail) => failures.push({ kind, detail });

// 1. Fixtures: every valid fixture passes both; every valid egress fixture's
//    clause parses as egress-clause.
for (const [dir, clause] of [["valid", false], ["egress/valid", true]]) {
  for (const name of readdirSync(join(FIXTURES, dir)).sort()) {
    const text = readFileSync(join(FIXTURES, dir, name), "utf8");
    if (!grammarAccepts(grammar, "deed", text)) fail("fixture rejected by deed.abnf", `${dir}/${name}`);
    const gate = gateVerdict(text);
    if (!gate.ok) fail("fixture rejected by deed_lint.js", `${dir}/${name}: ${gate.why}`);
    if (clause) {
      const e = egressText(text);
      // A deed without the clause is valid; a clause it has must parse.
      if (e !== null && !grammarAccepts(grammar, "egress-clause", e)) fail("egress fixture rejected by egress.abnf", `${dir}/${name}`);
    }
  }
}

// 2. Mutation differential over the committed deeds and the valid fixtures
//    (or the given seeds).
const validFixtures = ["valid", "egress/valid"].flatMap((dir) =>
  readdirSync(join(FIXTURES, dir)).sort().map((name) => join(FIXTURES, dir, name)),
);
const seedFiles = opts.seeds.length ? opts.seeds : [...committedDeeds(ROOT), ...validFixtures];
const texts = seedFiles.map((f) => readFileSync(f, "utf8"));
let state = opts.seed >>> 0;
const rnd = (k) => {
  state = (Math.imul(state, 1103515245) + 12345) & 0x7fffffff;
  return state % k;
};
// Edits aimed at the grammar's boundaries: separators and line-ends,
// comments, quoting, brackets, # forms, control and non-ASCII characters.
const ALPHABET = [" ", "  ", "\n", "\r", "\r\n", "\t", ";", ";c\n", "'", '"', "(", ")", ":", "#", "#t", "#u8", "#u5", "#uuid", "-4", "-8",
  "x", "Z", "7", "-", "_", ".", "\\", "\\n", "\\r", "\x7f", "\x01", "é", "©", "\u0085", "", "", ""];
const variants = [...texts];
for (let k = 0; k < opts.cases; k++) {
  let t = texts[rnd(texts.length)];
  const edits = 1 + rnd(opts.edits);
  for (let e = 0; e < edits; e++) {
    const at = rnd(t.length + 1);
    const del = rnd(3) === 0 ? rnd(3) : 0;
    t = t.slice(0, at) + ALPHABET[rnd(ALPHABET.length)] + t.slice(at + del);
  }
  variants.push(t);
}

let accepted = 0;
const lenient = [];
const strict = [];
for (const t of variants) {
  const abnf = grammarAccepts(grammar, "deed", t);
  const gate = gateVerdict(t);
  if (abnf) accepted++;
  if (gate.ok && !abnf) lenient.push(t);
  if (!gate.ok && abnf && !SEMANTIC.some((re) => re.test(gate.why))) strict.push({ t, why: gate.why });
}
const shortest = (xs, key = (x) => x) => [...xs].sort((a, b) => key(a).length - key(b).length).slice(0, 3);
for (const t of shortest(lenient)) fail("deed_lint.js accepts what deed.abnf rejects", JSON.stringify(t));
for (const x of shortest(strict, (x) => x.t)) fail("deed_lint.js rejects what deed.abnf accepts", `${x.why}\n    ${JSON.stringify(x.t)}`);

console.log(
  `deed-abnf-differential: ${seedFiles.length} seed deeds, ${variants.length} variants ` +
    `(seed ${opts.seed}), deed.abnf accepts ${accepted}; ` +
    `gate lenient on ${lenient.length}, gate stricter (non-semantic) on ${strict.length}`,
);
if (failures.length) {
  for (const f of failures) console.log(`FAIL ${f.kind}: ${f.detail}`);
  process.exit(1);
}
console.log("PASS: deed_lint.js and deed.abnf agree");
