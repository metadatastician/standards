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
// (egress …), (anchor …), (contractiles …), edict, verb-descriptile, ecosystem and state clause profiles and the shared rules of
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
import { checkEcosystem, checkState, checkVerbDescriptile, choraRepoUuid, edictRuleIdsAt, FIXTURE_TODAY, LintError, rootChora, validate, verbOfDescriptile } from "../../1-formats/deed/tools/deed_lint.js";

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
  /'!' is allowed only directly after a rule's :id value in a contractile-deed/,
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
      readFileSync(join(ABNF, "clauses/anchor.abnf"), "utf8") + "\n" +
      readFileSync(join(ABNF, "clauses/contractiles.abnf"), "utf8") + "\n" +
      readFileSync(join(ABNF, "clauses/edict.abnf"), "utf8") + "\n" +
      readFileSync(join(ABNF, "clauses/verb-descriptile.abnf"), "utf8") + "\n" +
      readFileSync(join(ABNF, "clauses/ecosystem.abnf"), "utf8") + "\n" +
      readFileSync(join(ABNF, "clauses/state.abnf"), "utf8")).replace(/[^\x00-\x7f]/g, "?") +
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

// The source text of each top-level field of the form whose keyword is in
// `names`, from its ":" to the end of its value, comments between them kept.
// Strings and comments are skipped, so a ":project" inside a string or a
// comment, or inside a nested clause, is never taken for a field.
function topLevelFields(t, names) {
  const out = [];
  const skipString = (k) => { for (k++; k < t.length && t[k] !== '"'; k++) if (t[k] === "\\") k++; return k; };
  const skipComment = (k) => { while (k < t.length && t[k] !== "\n") k++; return k; };
  let depth = 0;
  for (let k = 0; k < t.length; k++) {
    const c = t[k];
    if (c === '"') k = skipString(k);
    else if (c === ";") k = skipComment(k);
    else if (c === "(") depth++;
    else if (c === ")") depth--;
    else if (c === ":" && depth === 1 && /[\s(]/.test(t[k - 1] ?? " ")) {
      const m = /^:([a-z][a-z0-9-]*)/.exec(t.slice(k));
      if (!m || !names.has(m[1])) continue;
      let v = k + m[0].length;
      // separators and comments before the value
      for (;;) {
        if (/\s/.test(t[v] ?? "")) v++;
        else if (t[v] === ";") v = skipComment(v) + 1;
        else break;
      }
      let end;
      if (t[v] === '"') end = skipString(v) + 1;
      else if (t[v] === "(") {
        let d = 0;
        for (end = v; end < t.length; end++) {
          if (t[end] === '"') end = skipString(end);
          else if (t[end] === ";") end = skipComment(end);
          else if (t[end] === "(") d++;
          else if (t[end] === ")" && --d === 0) { end++; break; }
        }
      } else {
        for (end = v; end < t.length && !/[\s);]/.test(t[end]); end++);
      }
      out.push(t.slice(k, end));
      k = end - 1;
    }
  }
  return out;
}

// Invalid anchor fixtures whose defect the grammar itself expresses. Each must
// be a valid deed whose (anchor …) clause anchor.abnf refuses. The others in
// fixtures/anchor/invalid/ break a SEMANTIC side condition of the profile
// (exactly-once, uniqueness, date and version shape, placement), which only
// deed_lint.js --anchor checks.
const ANCHOR_GRAMMAR_REJECTS = [
  "clade-in-anchor_chora.deed", "empty-authority_chora.deed", "empty-subclause_chora.deed",
  "id-in-anchor_chora.deed", "metadata-unknown_chora.deed",
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
for (const [dir, clause] of [["valid", null], ["heads/valid", null], ["bang/valid", null], ["egress/valid", "egress"], ["anchor/valid", "anchor"], ["contractiles/valid", "contractiles"]]) {
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
// Invalid contractiles fixtures whose defect contractiles.abnf itself expresses:
// a member outside the four of A7 8.2 (a verdict included, YC05), a verb name
// that is not one of the six symbols, and an empty clause. The others break a
// SEMANTIC side condition (each verb once, each member once, the exact paths,
// placement, :contractiles_required), which only deed_lint.js --contractiles
// checks.
const CONTRACTILES_GRAMMAR_REJECTS = [
  "clause-field-bad_chora.deed", "empty-bad_chora.deed", "sub-clause-bad_chora.deed",
  "unknown-verb-bad_chora.deed", "verb-string-bad_chora.deed", "verdict-field-bad_chora.deed",
];
for (const name of CONTRACTILES_GRAMMAR_REJECTS) {
  const text = readFileSync(join(FIXTURES, "contractiles/invalid", name), "utf8");
  if (!grammarAccepts(grammar, "deed", text)) fail("contractiles invalid fixture is not a valid deed", name);
  const e = clauseText(text, "contractiles");
  if (e === null) fail("contractiles invalid fixture has no (contractiles …) clause", name);
  else if (grammarAccepts(grammar, "contractiles-clause", e)) fail("contractiles.abnf accepts a fixture it must refuse", name);
}
// And the converse: every invalid fixture NOT listed breaks only a semantic
// side condition, so the grammar accepts its clause. A fixture added to the
// corpus must be sorted into one list or the other.
for (const name of readdirSync(join(FIXTURES, "contractiles/invalid")).sort()) {
  if (CONTRACTILES_GRAMMAR_REJECTS.includes(name)) continue;
  const text = readFileSync(join(FIXTURES, "contractiles/invalid", name), "utf8");
  if (!grammarAccepts(grammar, "deed", text)) fail("contractiles invalid fixture is not a valid deed", name);
  const e = clauseText(text, "contractiles");
  if (e !== null && !grammarAccepts(grammar, "contractiles-clause", e)) fail("contractiles.abnf refuses a fixture listed as semantic only", name);
}

// J17's bang (deed.abnf v1.5.0). Each invalid bang fixture is either refused
// by the grammar itself (a second bang, "!" glued to a value or to a word) or
// accepted by it and refused only by the gate's SEMANTIC placement check. Both
// lists are exhaustive, so a new fixture must be filed in one.
{
  const grammarRejects = ["Adjustfile.deed", "Intentfile.deed", "Trustfile.deed"];
  const semanticOnly = ["Bustfile.deed", "Dustfile.deed", "Mustfile.deed", "rules_praxis.deed", "top_chora.deed"];
  for (const name of readdirSync(join(FIXTURES, "bang/invalid")).sort()) {
    const text = readFileSync(join(FIXTURES, "bang/invalid", name), "utf8");
    const g = grammarAccepts(grammar, "deed", text);
    if (grammarRejects.includes(name)) {
      if (g) fail("deed.abnf accepts a bang fixture it must refuse", name);
    } else if (semanticOnly.includes(name)) {
      if (!g) fail("deed.abnf refuses a bang fixture listed as semantic only", name);
    } else fail("bang invalid fixture is in neither list", name);
    if (gateVerdict(text).ok) fail("deed_lint.js accepts an invalid bang fixture", name);
  }
}

// The edict form (A7 8.1, clauses/edict.abnf). Its fixtures are one case per
// directory, because an edict's file name is fixed by its verb. Every valid
// case is a valid deed for both, and each of its (rule …) clauses parses as
// edict-rule (and its (envelope …) as bust-envelope). Each invalid case is
// filed in one of two exhaustive lists: the grammar refuses its first rule,
// or the grammar accepts it and only deed_lint.js --edict refuses it.
const edictCases = (sub) => readdirSync(join(FIXTURES, "edict", sub)).sort().map((c) => {
  const dir = join(FIXTURES, "edict", sub, c);
  const name = readdirSync(dir).find((n) => n.endsWith(".deed"));
  return { c, file: join(dir, name), text: readFileSync(join(dir, name), "utf8") };
});
const allClauses = (t, name) => {
  const out = [];
  let rest = t;
  for (let e = clauseText(rest, name); e !== null; e = clauseText(rest, name)) {
    out.push(e);
    rest = rest.slice(rest.indexOf(e) + e.length);
  }
  return out;
};
for (const { c, text } of edictCases("valid")) {
  if (!grammarAccepts(grammar, "deed", text)) fail("edict valid fixture rejected by deed.abnf", c);
  const gate = gateVerdict(text);
  if (!gate.ok) fail("edict valid fixture rejected by deed_lint.js", `${c}: ${gate.why}`);
  for (const r of allClauses(text, "rule")) if (!grammarAccepts(grammar, "edict-rule", r)) fail("edict.abnf refuses a valid rule", `${c}: ${r.slice(0, 60)}`);
  for (const r of allClauses(text, "envelope")) if (!grammarAccepts(grammar, "bust-envelope", r)) fail("edict.abnf refuses a valid envelope", c);
}
{
  // A Bust envelope with no member: bust-envelope needs 1*envelope-member.
  const envelopeRejects = ["envelope-empty"];
  const grammarRejects = ["always-with-field", "clade-selector", "rule-extra-field", "two-selectors", "unknown-selector"];
  const semanticOnly = ["beholding-chora", "duplicate-id", "empty-text", "envelope-not-bust", "id-space", "intend-bang",
    "missing-requires", "missing-text", "no-comparator", "requires-other-verb", "selector-bang",
    "two-comparators", "unknown-clause", "verb-filename-mismatch", "witness-other"];
  for (const { c, text } of edictCases("invalid")) {
    const rule = clauseText(text, "rule");
    if (envelopeRejects.includes(c)) {
      const env = clauseText(text, "envelope");
      if (env === null || grammarAccepts(grammar, "bust-envelope", env)) fail("edict.abnf accepts an envelope it must refuse", c);
    } else if (grammarRejects.includes(c)) {
      if (rule === null || grammarAccepts(grammar, "edict-rule", rule)) fail("edict.abnf accepts a rule it must refuse", c);
    } else if (semanticOnly.includes(c)) {
      if (rule !== null && !grammarAccepts(grammar, "edict-rule", rule)) fail("edict.abnf refuses a rule listed as semantic only", c);
    } else fail("edict invalid fixture is in neither list", c);
  }
}

// The six verb descriptiles (A7 7.3, 8.5, clauses/verb-descriptile.abnf). One
// case per directory, as the edict form: DIR/{valid,invalid}/<case>/<VERB>.deed,
// with the verb's <Verb>file.deed beside it when the case checks YD02. Every
// valid case is a valid deed for both, passes the profile, and each (fact …)
// parses as verb-fact. Each invalid case is filed in one of two exhaustive
// lists: the grammar refuses its first fact, or the grammar accepts it (or it
// has no fact) and only deed_lint.js --verb-descriptile refuses it.
{
  const cases = (sub) => readdirSync(join(FIXTURES, "verb-descriptile", sub)).sort().map((c) => {
    const dir = join(FIXTURES, "verb-descriptile", sub, c);
    const name = readdirSync(dir).find((n) => verbOfDescriptile(n) !== null);
    const edict = readdirSync(dir).find((n) => /file\.deed$/.test(n));
    return { c, dir, file: join(dir, name), text: readFileSync(join(dir, name), "utf8"), edict: edict ? join(dir, edict) : null };
  });
  const profile = ({ dir, file, text, edict }) => {
    try {
      const repoUuid = choraRepoUuid(dir);
      const ruleIds = edict ? edictRuleIdsAt(edict, repoUuid) : undefined;
      return checkVerbDescriptile(text, file, { ruleIds, repoUuid, today: FIXTURE_TODAY }) !== null;
    } catch (e) {
      if (!(e instanceof LintError)) throw e;
      return false;
    }
  };
  for (const k of cases("valid")) {
    if (!grammarAccepts(grammar, "deed", k.text)) fail("verb descriptile valid fixture rejected by deed.abnf", k.c);
    if (!profile(k)) fail("verb descriptile valid fixture rejected by deed_lint.js --verb-descriptile", k.c);
    for (const f of allClauses(k.text, "fact")) if (!grammarAccepts(grammar, "verb-fact", f)) fail("verb-descriptile.abnf refuses a valid fact", `${k.c}: ${f.slice(0, 60)}`);
  }
  const grammarRejects = ["bust-grade-letter", "bust-grade-zero", "evidence-numeric", "evidence-unknown", "fact-clause-member", "fact-extra-field"];
  const semanticOnly = ["affirmed-by-string", "affirmed-impossible", "beholding-chora", "bust-missing-residual", "bust-value",
    "duplicate-witness", "edict-other-chora", "expired", "expires-before-affirmed", "inherent-outside-bust", "missing-affirmed", "missing-affirmed-by",
    "missing-evidence", "missing-value", "missing-witnesses", "of-chora-mismatch", "of-chora-u8-mismatch", "repo-uuid-twice", "rule-in-descriptile", "schema-major", "schema-not-version", "source-absolute",
    "unknown-clause", "witness-space", "witness-too-long", "witness-unknown"];
  for (const k of cases("invalid")) {
    if (!gateVerdict(k.text).ok) fail("verb descriptile invalid fixture is not a valid deed (YD01)", k.c);
    if (profile(k)) fail("deed_lint.js --verb-descriptile accepts an invalid fixture", k.c);
    const fact = clauseText(k.text, "fact");
    if (grammarRejects.includes(k.c)) {
      if (fact === null || grammarAccepts(grammar, "verb-fact", fact)) fail("verb-descriptile.abnf accepts a fact it must refuse", k.c);
    } else if (semanticOnly.includes(k.c)) {
      if (fact !== null && !grammarAccepts(grammar, "verb-fact", fact)) fail("verb-descriptile.abnf refuses a fact listed as semantic only", k.c);
    } else fail("verb descriptile invalid fixture is in neither list", k.c);
  }
}

// ECOSYSTEM.deed (A7 7.2, clauses/ecosystem.abnf). One case per directory:
// DIR/{valid,invalid}/<case>/ECOSYSTEM.deed, with an optional chora deed (YD07,
// YD08) and STRICT marker (J12) beside it. Every valid case is a valid deed for
// both, passes the profile, and each (related …) parses as eco-related and
// each ecosystem field as ecosystem-field. Each invalid case is filed in one of
// three exhaustive lists: the grammar refuses its first (related …), the
// grammar refuses one of its ecosystem fields, or only the profile refuses it.
{
  const ECO_FIELDS = new Set(["project", "ecosystem", "position-type", "purpose", "not", "pipeline-position", "chain", "pipeline-notes", "coordination"]);
  const fieldsOf = (t) => topLevelFields(t, ECO_FIELDS);
  const cases = (sub) => readdirSync(join(FIXTURES, "ecosystem", sub)).sort().map((c) => {
    const dir = join(FIXTURES, "ecosystem", sub, c);
    return { c, dir, file: join(dir, "ECOSYSTEM.deed"), text: readFileSync(join(dir, "ECOSYSTEM.deed"), "utf8") };
  });
  const profile = ({ dir, file, text }) => {
    try {
      const ch = rootChora(dir, { needName: true });
      const strict = readdirSync(dir).includes("STRICT");
      return checkEcosystem(text, file, { repoUuid: ch && ch.uuid, choraName: ch && ch.name, strict, today: FIXTURE_TODAY }) !== null;
    } catch (e) {
      if (!(e instanceof LintError)) throw e;
      return false;
    }
  };
  for (const k of cases("valid")) {
    if (!grammarAccepts(grammar, "deed", k.text)) fail("ecosystem valid fixture rejected by deed.abnf", k.c);
    if (!profile(k)) fail("ecosystem valid fixture rejected by deed_lint.js --ecosystem", k.c);
    for (const r of allClauses(k.text, "related")) if (!grammarAccepts(grammar, "eco-related", r)) fail("ecosystem.abnf refuses a valid (related …)", `${k.c}: ${r.slice(0, 60)}`);
    for (const f of fieldsOf(k.text)) if (!grammarAccepts(grammar, "ecosystem-field", f)) fail("ecosystem.abnf refuses a valid field", `${k.c}: ${f.slice(0, 60)}`);
  }
  const relatedRejects = ["related-clause-member", "related-extra-field", "relationship-string", "relationship-unknown"];
  const fieldRejects = ["coordination-string", "not-not-list"];
  const semanticOnly = ["beholding-chora", "chora-no-name", "empty-purpose", "expired", "missing-affirmed", "missing-project", "missing-purpose",
    "of-chora-mismatch", "project-mismatch", "project-not-chora", "related-duplicate", "related-missing-notes",
    "rule-in-descriptile", "strict-no-uuid", "unknown-clause", "unknown-field"];
  for (const k of cases("invalid")) {
    if (!gateVerdict(k.text).ok) fail("ecosystem invalid fixture is not a valid deed (YD01)", k.c);
    if (profile(k)) fail("deed_lint.js --ecosystem accepts an invalid fixture", k.c);
    const r = clauseText(k.text, "related");
    if (relatedRejects.includes(k.c)) {
      if (r === null || grammarAccepts(grammar, "eco-related", r)) fail("ecosystem.abnf accepts a (related …) it must refuse", k.c);
    } else if (fieldRejects.includes(k.c)) {
      if (fieldsOf(k.text).every((f) => grammarAccepts(grammar, "ecosystem-field", f))) fail("ecosystem.abnf accepts every field of a case it must refuse", k.c);
    } else if (semanticOnly.includes(k.c)) {
      if (r !== null && !grammarAccepts(grammar, "eco-related", r)) fail("ecosystem.abnf refuses a (related …) listed as semantic only", k.c);
      for (const f of fieldsOf(k.text)) if (!grammarAccepts(grammar, "ecosystem-field", f)) fail("ecosystem.abnf refuses a field listed as semantic only", `${k.c}: ${f.slice(0, 60)}`);
    } else fail("ecosystem invalid fixture is in neither list", k.c);
  }
}

// STATE.deed (A7 7.2, J3, J15, YF03; clauses/state.abnf). One case per
// directory: DIR/{valid,invalid}/<case>/STATE.deed, with an optional chora deed
// (YD08, YF03) and STRICT marker beside it. Every valid case is a valid deed
// for both, passes the profile, and its (status …) parses as state-status and
// its (maturity …) as state-maturity. Each invalid case is filed in one of
// three exhaustive lists: the grammar refuses its first (status …), the
// grammar refuses its first (maturity …), or only the profile refuses it.
{
  const cases = (sub) => readdirSync(join(FIXTURES, "state", sub)).sort().map((c) => {
    const dir = join(FIXTURES, "state", sub, c);
    return { c, dir, file: join(dir, "STATE.deed"), text: readFileSync(join(dir, "STATE.deed"), "utf8") };
  });
  const profile = ({ dir, file, text }) => {
    try {
      const ch = rootChora(dir);
      const strict = readdirSync(dir).includes("STRICT");
      return checkState(text, file, { repoUuid: ch && ch.uuid, choraClauses: ch && ch.clauses, strict, today: FIXTURE_TODAY }) !== null;
    } catch (e) {
      if (!(e instanceof LintError)) throw e;
      return false;
    }
  };
  for (const k of cases("valid")) {
    if (!grammarAccepts(grammar, "deed", k.text)) fail("state valid fixture rejected by deed.abnf", k.c);
    if (!profile(k)) fail("state valid fixture rejected by deed_lint.js --state", k.c);
    for (const r of allClauses(k.text, "status")) if (!grammarAccepts(grammar, "state-status", r)) fail("state.abnf refuses a valid (status …)", `${k.c}: ${r.slice(0, 60)}`);
    for (const r of allClauses(k.text, "maturity")) if (!grammarAccepts(grammar, "state-maturity", r)) fail("state.abnf refuses a valid (maturity …)", `${k.c}: ${r.slice(0, 60)}`);
  }
  const statusRejects = ["aliases-not-list", "ended-not-date", "entry-phase-unknown", "entry-unknown-field", "history-field",
    "phase-string", "phase-unknown", "present-string", "since-not-date", "status-unknown-field"];
  const maturityRejects = ["level-string", "level-unknown", "maturity-unknown-field"];
  const semanticOnly = ["beholding-chora", "entry-missing-since", "expired", "history-twice", "maturity-in-chora-strict", "maturity-twice",
    "missing-affirmed", "missing-level", "missing-phase", "missing-status", "of-chora-mismatch", "phase-twice", "rule-in-descriptile",
    "since-impossible", "state-clause", "status-in-chora-strict", "status-twice", "unknown-clause", "unknown-field"];
  for (const k of cases("invalid")) {
    if (!gateVerdict(k.text).ok) fail("state invalid fixture is not a valid deed (YD01)", k.c);
    if (profile(k)) fail("deed_lint.js --state accepts an invalid fixture", k.c);
    const st = clauseText(k.text, "status");
    const mt = clauseText(k.text, "maturity");
    if (statusRejects.includes(k.c)) {
      if (st === null || grammarAccepts(grammar, "state-status", st)) fail("state.abnf accepts a (status …) it must refuse", k.c);
    } else if (maturityRejects.includes(k.c)) {
      if (mt === null || grammarAccepts(grammar, "state-maturity", mt)) fail("state.abnf accepts a (maturity …) it must refuse", k.c);
    } else if (semanticOnly.includes(k.c)) {
      for (const r of allClauses(k.text, "status")) if (!grammarAccepts(grammar, "state-status", r)) fail("state.abnf refuses a (status …) listed as semantic only", k.c);
      for (const r of allClauses(k.text, "maturity")) if (!grammarAccepts(grammar, "state-maturity", r)) fail("state.abnf refuses a (maturity …) listed as semantic only", k.c);
    } else fail("state invalid fixture is in neither list", k.c);
  }
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
    ["affirm-member", ":affirmed-by deed-lint", true], ["affirm-member", ":affirmed-by owner-review", true],
    ["affirm-member", ":affirmed-by agent-check", true], ["affirm-member", ':affirmed-by "owner"', false],
    ["affirm-member", ":affirmed #t", false], ["affirm-member", ":AFFIRMED \"2026-11-13\"", false],
    ["str-list1", "()", false], ["str-list1", '( "a" "b" )', true], ["str-list", "()", true],
  ];
  for (const [rule, text, want] of cases) {
    if (grammarAccepts(grammar, rule, text) !== want) fail(`common.abnf ${want ? "refuses" : "accepts"} ${rule}`, text);
  }
}

// The J14 file names (deed.abnf v1.4.0). The gate dispatches on the file name
// before parsing, so deed-filename is held to the same names as
// checkFilenameDispatch, case variants included. The heads/ fixtures must be
// deeds by deed.abnf, and the gate must accept heads/valid and refuse
// heads/invalid under their own names. <stem>_chora.deed and _praxis.deed are
// not probed here: apg-js repeats possessively, so `stem` (which admits "_"
// and ".") swallows the suffix; RFC 5234 ABNF backtracks and accepts them.
{
  const names = [
    ["Mustfile.deed", true], ["Bustfile.deed", true], ["Intentfile.deed", true], ["STATE.deed", true],
    ["CLADE.deed", true], ["MUST.deed", true], ["ANCHOR.deed", false], ["mustfile.deed", false],
    ["MUSTFILE.deed", false], ["Meta.deed", false], ["State.deed", false], ["anchor.deed", false],
    ["Clade.deed", false], ["Statefile.deed", false], ["ATLAS.deed", true],
  ];
  for (const [name, want] of names) {
    if (grammarAccepts(grammar, "deed-filename", name) !== want) fail(want ? "deed.abnf refuses a file name it must accept" : "deed.abnf accepts a file name it must refuse", name);
  }
  for (const dir of ["heads/valid", "heads/invalid"]) {
    for (const name of readdirSync(join(FIXTURES, dir)).sort()) {
      const text = readFileSync(join(FIXTURES, dir, name), "utf8");
      let gate = true;
      try { validate(text, name); } catch { gate = false; }
      if (gate !== (dir === "heads/valid")) fail(`gate ${gate ? "accepts" : "refuses"} a heads fixture under its own name`, `${dir}/${name}`);
      if (!grammarAccepts(grammar, "deed", text)) fail("heads fixture is not a deed by deed.abnf", `${dir}/${name}`);
    }
  }
}

// 2. Mutation differential over the committed deeds and the valid fixtures
//    (or the given seeds).
const validFixtures = ["valid", "heads/valid", "bang/valid", "egress/valid", "anchor/valid", "contractiles/valid"].flatMap((dir) =>
  readdirSync(join(FIXTURES, dir)).sort().map((name) => join(FIXTURES, dir, name)),
);
const edictValid = readdirSync(join(FIXTURES, "edict/valid")).sort().flatMap((c) =>
  readdirSync(join(FIXTURES, "edict/valid", c)).filter((n) => n.endsWith(".deed")).map((n) => join(FIXTURES, "edict/valid", c, n)));
const seedFiles = opts.seeds.length ? opts.seeds : [...committedDeeds(ROOT), ...validFixtures, ...edictValid];
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
