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
// (egress …) and (anchor …) clause profiles and the shared rules of
// clauses/common.abnf) using apg-js, mutates every
// committed deed with a seeded generator, and asks both the grammar and the
// gate for a verdict on each variant:
//
//   * the gate accepts what the grammar rejects   → FAIL (the gate is lenient)
//   * the gate rejects what the grammar accepts   → FAIL, unless the gate's
//     reason is one of its documented semantic checks (SEMANTIC below), which
//     the grammar does not express
//
// Every valid fixture must also be accepted by both, every valid egress or anchor
// fixture's clause must parse as its clause rule, and every anchor fixture
// listed in ANCHOR_GRAMMAR_REJECTS must be refused by anchor.abnf itself, so the
// grammar stays an oracle and not a description. The run is deterministic for
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
      readFileSync(join(ABNF, "clauses/egress.abnf"), "utf8") + "\n" +
      readFileSync(join(ABNF, "clauses/common.abnf"), "utf8") + "\n" +
      readFileSync(join(ABNF, "clauses/anchor.abnf"), "utf8")).replace(/[^\x00-\x7f]/g, "?") +
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

// The text of the first top-level-or-nested (<name> …) clause. Strings and
// comments are skipped both while finding the clause and while balancing its
// parentheses: a comment may hold any text-char, a parenthesis included
// (`; disabled)`).
function clauseText(t, name) {
  const open = "(" + name;
  let depth = 0;
  let start = -1;
  for (let k = 0; k < t.length; k++) {
    const c = t[k];
    if (c === '"') {
      for (k++; k < t.length && t[k] !== '"'; k++) if (t[k] === "\\") k++;
    } else if (c === ";") {
      while (k < t.length && t[k] !== "\n") k++;
    } else if (c === "(") {
      if (start < 0 && t.startsWith(open, k) && /[\s);]/.test(t[k + open.length] ?? "")) start = k;
      if (start >= 0) depth++;
    } else if (c === ")" && start >= 0 && --depth === 0) {
      return t.slice(start, k + 1);
    }
  }
  return null;
}

// Invalid anchor fixtures whose defect the grammar itself expresses. Each must
// be a valid deed whose (anchor …) clause anchor.abnf refuses. The others in
// fixtures/anchor/invalid/ break a SEMANTIC side condition of the profile
// (exactly-once, uniqueness, date and version shape, placement), which only
// deed_lint.js --anchor checks.
const ANCHOR_GRAMMAR_REJECTS = [
  "clade-in-anchor_chora.deed", "empty-authority_chora.deed", "empty-subclause_chora.deed",
  "id-in-anchor_chora.deed", "metadata-unknown_chora.deed", "parent-legacy-literal_chora.deed",
  "parent-relation-string_chora.deed", "parent-string_chora.deed", "parents-stray_chora.deed",
  "purpose-empty_chora.deed", "purpose-symbols_chora.deed", "satellite-string_chora.deed",
  "schema-symbol_chora.deed", "sem-files-boolean_chora.deed", "status-in-anchor_chora.deed",
  "sub-nested-clause_chora.deed", "wrong-schema_chora.deed",
];

const opts = args(process.argv.slice(2));
const grammar = compileGrammar();
const failures = [];
const fail = (kind, detail) => failures.push({ kind, detail });

// 1. Fixtures: every valid fixture passes both; every valid egress or anchor
//    fixture's clause parses as its clause rule.
for (const [dir, clause] of [["valid", null], ["egress/valid", "egress"], ["anchor/valid", "anchor"]]) {
  for (const name of readdirSync(join(FIXTURES, dir)).sort()) {
    const text = readFileSync(join(FIXTURES, dir, name), "utf8");
    if (!grammarAccepts(grammar, "deed", text)) fail("fixture rejected by deed.abnf", `${dir}/${name}`);
    const gate = gateVerdict(text);
    if (!gate.ok) fail("fixture rejected by deed_lint.js", `${dir}/${name}: ${gate.why}`);
    if (clause) {
      const e = clauseText(text, clause);
      // A deed without the clause is valid; a clause it has must parse.
      if (e !== null && !grammarAccepts(grammar, `${clause}-clause`, e)) fail(`${clause} fixture rejected by ${clause}.abnf`, `${dir}/${name}`);
      // Only a fixture named no-<clause>_… may lack the clause. Any other that
      // yields none means clauseText missed it, and the grammar check was
      // silently skipped.
      if (e === null && !name.startsWith(`no-${clause}`)) fail(`${clause} fixture has no extractable (${clause} …) clause`, `${dir}/${name}`);
    }
  }
}
for (const name of ANCHOR_GRAMMAR_REJECTS) {
  const text = readFileSync(join(FIXTURES, "anchor/invalid", name), "utf8");
  if (!grammarAccepts(grammar, "deed", text)) fail("anchor invalid fixture is not a valid deed", name);
  const e = clauseText(text, "anchor");
  if (e === null) fail("anchor invalid fixture has no (anchor …) clause", name);
  else if (grammarAccepts(grammar, "anchor-clause", e)) fail("anchor.abnf accepts a fixture it must refuse", name);
}
// A version 5 parent id (A1 rule V8) is refused by anchor.abnf itself. Built at
// run time, not committed: the repo carries no version 5 UUID literal
// (scripts/check-uuid-v8.sh --strict).
{
  const v5 = `(anchor :schema "hyperpolymath.anchor/1" :authority "a" (parents (parent :uuid #uuid"00000000-0000-${"5"}000-8000-0000000000b1")))`;
  const v8 = v5.replace("-5000-", "-8000-");
  if (grammarAccepts(grammar, "anchor-clause", v5)) fail("anchor.abnf accepts a version 5 parent id", v5);
  if (!grammarAccepts(grammar, "anchor-clause", v8)) fail("anchor.abnf refuses a version 8 parent id", v8);
  // ABNF quoted strings are case-insensitive: an uppercase variant nibble must
  // still be refused, as deed_lint refuses it.
  const upper = v8.replace("-8000-0000000000b1", "-A000-0000000000b1");
  if (grammarAccepts(grammar, "anchor-clause", upper)) fail("anchor.abnf accepts an uppercase variant nibble", upper);
  const lower = v8.replace("-8000-0000000000b1", "-a000-0000000000b1");
  if (!grammarAccepts(grammar, "anchor-clause", lower)) fail("anchor.abnf refuses a lowercase variant nibble", lower);
}

// The shared rules of common.abnf (A7 7.1, M3). No clause uses date-string or
// affirm-member yet, so they are held to their own accept and refuse lists
// here. The calendar check (2026-02-31) is SEMANTIC and belongs to the linter.
{
  const cases = [
    ["date-string", '"2026-11-13"', true], ["date-string", '"2026-12-31"', true],
    ["date-string", '"2026-02-31"', true], ["date-string", '"2026-13-01"', false],
    ["date-string", '"2026-00-10"', false], ["date-string", '"2026-11-32"', false],
    ["date-string", '"2026-11-00"', false], ["date-string", '"2026-1-13"', false],
    ["date-string", "2026-11-13", false], ["date-string", '"2026-11-13T00:00"', false],
    ["affirm-member", ':affirmed "2026-11-13"', true], ["affirm-member", ':expires "2027-11-13"', true],
    ["affirm-member", ":affirmed-by owner", true], ["affirm-member", ":affirmed-by agent", true],
    ["affirm-member", ":affirmed-by deed-lint", true], ["affirm-member", ':affirmed-by "owner"', false],
    ["affirm-member", ":affirmed #t", false], ["affirm-member", ":AFFIRMED \"2026-11-13\"", false],
    ["str-list1", "()", false], ["str-list1", '( "a" "b" )', true], ["str-list", "()", true],
  ];
  for (const [rule, text, want] of cases) {
    if (grammarAccepts(grammar, rule, text) !== want) fail(`common.abnf ${want ? "refuses" : "accepts"} ${rule}`, text);
  }
}

// 2. Mutation differential over the committed deeds and the valid fixtures
//    (or the given seeds).
const validFixtures = ["valid", "egress/valid", "anchor/valid"].flatMap((dir) =>
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
const ALPHABET = [" ", "  ", "\n", "\r", "\r\n", "\t", ";", ";c\n", "'", '"', "(", ")", ":", "#", "#t", "#u8", "#u5", "#uuid", "-4", "-8", "-A", "-B",
  "x", "Z", "7", "-", "_", ".", "\\", "\\n", "\\r", "\x7f", "\x01", "é", "©", "\u0085", "", "", ""];
const variants = [...texts];
// Directed probes. ABNF quoted strings are case-insensitive (RFC 5234 2.3),
// so a letter in #uuid that must be lowercase needs %s. Random edits rarely
// land on the variant nibble, so probe it directly.
for (const v of "AB") {
  variants.push(`;; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed :schema-version "1.0.0" :repo-uuid #uuid"b32d6be4-73ba-873e-${v}d61-e57f43c75cd1")\n`);
}
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
