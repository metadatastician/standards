// SPDX-License-Identifier: MPL-2.0
// bun test for deed_lint.js. Run: bun test 1-formats/deed/tools/
import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { cpSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { validate, blankComments, LintError, SELF_TEST_CASES, checkEgress, EgressError, checkAnchor, AnchorError, profileCOfBody, readMustfileChecks, MustfileError, readProofReceipt, ProofReceiptError, checkContractiles, ContractilesError, contractilePaths, CONTRACTILE_VERBS, checkEdict, EdictError, verbOfFilename, checkVerbDescriptile, VerbDescriptileError, verbOfDescriptile, choraRepoUuid, checkEcosystem, EcosystemError, ECOSYSTEM_RELATIONSHIPS } from "./deed_lint.js";
import { generateContractileRegistry as generateRegistry } from "./deed_lint.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const LINT = join(HERE, "deed_lint.js");
const FIX = join(HERE, "fixtures");
const HDR = ";; SPDX-License-Identifier: CC-BY-SA-4.0\n";

/** Run validate on source; returns null if valid, else the error message. */
function verdict(src, filename) {
  try {
    validate(src, filename);
    return null;
  } catch (e) {
    if (e instanceof LintError) return e.message;
    throw e;
  }
}

// Expected verdicts of the 14 embedded Python self-test cases (name, valid?).
const EXPECTED = [
  ["valid-minimal", true],
  ["valid-nested", true],
  ["valid-booleans-uuid", true],
  ["invalid-equals", false],
  ["invalid-section", false],
  ["invalid-missing-schema", false],
  ["invalid-head", false],
  ["invalid-true-literal", false],
  ["invalid-tab", false],
  ["invalid-escape-u", false],
  ["invalid-trailing", false],
  ["invalid-no-header", false],
  ["valid-quoted-list-symbols-007", true],
  ["invalid-unbalanced", false],
];

describe("embedded self-test cases", () => {
  test("14 cases, names and order match the Python", () => {
    expect(SELF_TEST_CASES.map((c) => [c.name, c.expectOk])).toEqual(EXPECTED);
  });
  for (const [name, ok] of EXPECTED) {
    test(`${name} -> ${ok ? "valid" : "error"}`, () => {
      const c = SELF_TEST_CASES.find((x) => x.name === name);
      expect(c).toBeDefined();
      expect(verdict(c.src) === null).toBe(ok);
    });
  }
});

// fixture filename -> regex the failure message must match (rule it names)
const RULE = {
  "incomment-control_chora.deed": /comment holds control character U\+0001/,
  "incomment-no-line-end_chora.deed": /comment has no line-end/,
  "indel-string_chora.deed": /raw control character U\+007F inside string/,
  "inheader-control_chora.deed": /SPDX header line holds control character U\+0001/,
  "inquote-space_chora.deed": /nothing may come between '/,
  "inequals_chora.deed": /'=' as a field separator/,
  "inescape-u_chora.deed": /illegal escape/,
  "inhead_chora.deed": /invalid doc-head/,
  "inmissing-schema_chora.deed": /exactly one :schema-version/,
  "inno-header_chora.deed": /at least one SPDX header/,
  "insection_chora.deed": /expected field/,
  "intab_chora.deed": /HTAB \(tab\)/,
  "intrailing_chora.deed": /trailing content/,
  "intrue-literal_chora.deed": /bare symbol 'true' is forbidden/,
  "inunbalanced_chora.deed": /unbalanced parens/,
  "inu5-identity_chora.deed": /identity field :repo-uuid carries a #u5 literal/,
  "inu7_chora.deed": /unrecognised #-form/,
  "inu8-empty-domain_chora.deed": /uuid8 domain '' must be non-empty/,
  "inu8-no-colon_chora.deed": /has no ":"/,
  "inu8-no-string_chora.deed": /uuid8 must be followed immediately by a string/,
  "inuuid-uppercase_chora.deed": /uuid literal body .* must be 8-4-4-4-12 lowercase hex/,
  "inuuid-short_chora.deed": /must be 8-4-4-4-12 lowercase hex/,
  "inuuid-no-string_chora.deed": /uuid literal must be followed immediately by a string/,
  "inline-999_chora.deed": /line is 999 octets; a deed line is at most 998 octets/,
  "inbot-bare-name_chora.deed": /expected field/,
};

describe("fixtures/valid", () => {
  for (const f of readdirSync(join(FIX, "valid")).filter((n) => n.endsWith(".deed")).sort()) {
    test(f, () => {
      const p = join(FIX, "valid", f);
      expect(verdict(readFileSync(p, "utf8"), p)).toBeNull();
    });
  }
});

describe("fixtures/invalid", () => {
  const files = readdirSync(join(FIX, "invalid")).filter((n) => n.endsWith(".deed")).sort();
  test("every invalid fixture has a rule mapping", () => {
    expect(files).toEqual(Object.keys(RULE).sort());
  });
  for (const f of files) {
    test(`${f} fails for its named rule`, () => {
      const p = join(FIX, "invalid", f);
      const msg = verdict(readFileSync(p, "utf8"), p);
      expect(msg).not.toBeNull();
      expect(msg).toMatch(RULE[f]);
    });
  }
});

describe("extra rules", () => {
  test("text-chars only: a bare CR or DEL in a header line or comment is refused", () => {
    const form = '(repo-deed :schema-version "1")\n';
    expect(verdict(";; SPDX-License-Identifier: CC-B\rY-SA-4.0\n" + form)).toMatch(/SPDX header line holds control character U\+000D/);
    expect(verdict(";; SPDX-License-Identifier: CC-BY-SA-4.0\r\n" + form)).toBeNull();
    expect(verdict(HDR + "; a \x7f\n" + form)).toMatch(/comment holds control character U\+007F/);
    expect(verdict(HDR + form + "; last comment\r\n")).toBeNull();
  });

  test("a separator before every field, clause and list value after the first", () => {
    const H = HDR + '(repo-deed :schema-version "1"';
    for (const ok of [' :a "x" :b "y")', " :a () :b ( ) :c (\n  x\n  ; c\n  y\n))", " (c :a \"x\") (d))", " (c\n:a 1))"]) {
      expect(verdict(H + ok + "\n")).toBeNull();
    }
    expect(verdict(H + ' :a "x":b "y")\n')).toMatch(/form needs a separator/);
    expect(verdict(H + ' :a "x"(c))\n')).toMatch(/form needs a separator/);
    expect(verdict(H + " :a 1(c))\n")).toMatch(/form needs a separator/);
    expect(verdict(H + ' (c :a "x")(d))\n')).toMatch(/form needs a separator/);
    expect(verdict(H + ' (c:a "x"))\n')).toMatch(/clause \(c\) needs a separator/);
    expect(verdict(H + ' (c :a "x"(d)))\n')).toMatch(/clause \(c\) needs a separator/);
    expect(verdict(H + ' :a ("A""B"))\n')).toMatch(/list values must be separated/);
    expect(verdict(H + " :a (x(y)))\n")).toMatch(/list values must be separated/);
  });

  test("quote: nothing between ' and what it quotes", () => {
    expect(verdict(HDR + "(repo-deed :schema-version \"1\" :a 'sym :b '(x y))\n")).toBeNull();
    expect(verdict(HDR + "(repo-deed :schema-version \"1\" :a ' sym)\n")).toMatch(/nothing may come between '/);
    expect(verdict(HDR + "(repo-deed :schema-version \"1\" :a ';c\nsym)\n")).toMatch(/nothing may come between '/);
  });

  test("filename dispatch mismatch", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1")\n', "x_praxis.deed")).toMatch(/doc-head\/filename mismatch/);
  });
  test("filename matching no pattern", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1")\n', "x.deed")).toMatch(/no deed dispatch pattern/);
  });
  test("canonical machine manifest selects repo-deed", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1")\n', "0-AI-MANIFEST.deed")).toBeNull();
    for (const head of ["estate-deed", "estate-atlas-deed", "praxis-deed"]) {
      expect(verdict(HDR + `(${head} :schema-version "1")\n`, "0-AI-MANIFEST.deed")).toMatch(/mismatch/);
    }
  });
  test("machine manifest filename is exact and case-sensitive", () => {
    for (const name of ["0-ai-manifest.deed", "0-AI-MANIFEST-copy.deed", "1-AI-MANIFEST.deed"]) {
      expect(verdict(HDR + '(repo-deed :schema-version "1")\n', name)).toMatch(/no deed dispatch pattern/);
    }
  });
  test("machine manifest clauses still require named fields", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" (purpose "text"))\n', "0-AI-MANIFEST.deed")).toMatch(/expected field/);
  });
  test("estate_chora.deed needs estate-deed", () => {
    expect(verdict(HDR + '(estate-deed :schema-version "1")\n', "estate_chora.deed")).toBeNull();
    expect(verdict(HDR + '(repo-deed :schema-version "1")\n', "estate_chora.deed")).toMatch(/mismatch/);
  });
  test("bare CR rejected", () => {
    expect(verdict(HDR + '(repo-deed\r:schema-version "1")\n')).toMatch(/bare CR/);
  });
  test("CRLF accepted", () => {
    expect(verdict(";; SPDX-License-Identifier: X\r\n(repo-deed\r\n :schema-version \"1\")\r\n")).toBeNull();
  });
  test("no trailing newline accepted", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1")')).toBeNull();
  });
  test("bad boolean token #true", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" :a #true)\n')).toMatch(/booleans are exactly/);
  });
  test("a comment ends a boolean, as it ends any token (deed.abnf token-sep)", () => {
    expect(verdict(HDR + "(repo-deed :schema-version \"1\" :a #t; note\n :b #f)\n")).toBeNull();
  });
  test("a boolean's lexeme is exactly #t or #f, whatever follows it", () => {
    const [, items] = validate(HDR + "(repo-deed :schema-version \"1\" :a #t; note\n :b #f)\n");
    const values = items.filter((it) => it[0] === "field" && it[1] !== "schema-version").map((it) => it[2]);
    expect(values).toEqual([["boolean", "#t"], ["boolean", "#f"]]);
  });
  test("non-string schema-version", () => {
    expect(verdict(HDR + "(repo-deed :schema-version 1)\n")).toMatch(/must be a STRING/);
  });
  test("number followed by identifier chars", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" :a 12ab)\n')).toMatch(/malformed token/);
  });
  test("validated AST preserves exact integer lexemes without JS precision loss", () => {
    const [head, items] = validate(HDR + '(repo-deed :schema-version "1" (entry\n :count 900719925474099312345\n :ceiling 0007\n :delta -12))', "sample_chora.deed");
    expect(head).toBe("repo-deed");
    expect(items[1]).toEqual(["clause", "entry", [
      ["field", "count", ["integer", "900719925474099312345"]],
      ["field", "ceiling", ["integer", "0007"]],
      ["field", "delta", ["integer", "-12"]],
    ]]);
  });
  test("only symbols/lists may be quoted", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" :a \'"s")\n')).toMatch(/may be quoted/);
  });
  test("unterminated string", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" :a "oops)')).toMatch(/unterminated string/);
  });
  test("uuid8: domain with a space is rejected", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" :id #u8"gv clade:x")\n')).toMatch(/uuid8 domain/);
  });
  test("uuid8: name is unconstrained (empty, or holding further colons)", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" :id #u8"d:")\n')).toBeNull();
    expect(verdict(HDR + '(repo-deed :schema-version "1" :id #u8"d:a:b c")\n')).toBeNull();
  });
  test("uuid8 is accepted inside a list and a clause", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" (c :ids (#u8"d:a" #u8"d:b")))\n')).toBeNull();
  });
  test("uuid5 stays legal alongside uuid8 (v1.1.0 is additive)", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" :a #u5"estate/chora" :b #u8"d:n")\n')).toBeNull();
  });
  test("uuid (v1.3.0): v5 and v8 are legal, in a field, a list and a clause", () => {
    // Assembled at runtime: scripts/check-uuid-v8.sh --strict scans this file
    // and rejects a literal version-5 UUID (see scripts/tests/uuid-v8-test.sh).
    const v5 = ["d9e987dc", "bb7b", "51aa", "839b", "3d8bbfe774c3"].join("-");
    expect(verdict(HDR + `(repo-deed :schema-version "1" :a #uuid"${v5}")\n`)).toBeNull();
    expect(verdict(HDR + '(repo-deed :schema-version "1" (c :ids (#uuid"b32d6be4-73ba-873e-9d61-e57f43c75cd1")))\n')).toBeNull();
  });
  test("uuid (v1.3.0): the literal admits versions 5 and 8 (identity fields want 8; the grammar admits both)", () => {
    for (const v of "58") {
      expect(verdict(HDR + `(repo-deed :schema-version "1" :a #uuid"b32d6be4-73ba-${v}73e-9d61-e57f43c75cd1")\n`)).toBeNull();
    }
  });
  test("uuid (v1.3.0): every variant nibble 8, 9, a, b is legal", () => {
    for (const v of "89ab") {
      expect(verdict(HDR + `(repo-deed :schema-version "1" :a #uuid"b32d6be4-73ba-873e-${v}d61-e57f43c75cd1")\n`)).toBeNull();
    }
  });
  test("uuid (v1.3.0): a variant nibble outside 8, 9, a, b is refused", () => {
    for (const v of "01234567cdef") {
      expect(verdict(HDR + `(repo-deed :schema-version "1" :a #uuid"b32d6be4-73ba-873e-${v}d61-e57f43c75cd1")\n`)).toMatch(new RegExp(`variant nibble ${v}`));
    }
  });
  test("uuid (v1.3.0): versions other than 5 and 8 are refused", () => {
    for (const v of "0123467") {
      expect(verdict(HDR + `(repo-deed :schema-version "1" :a #uuid"b32d6be4-73ba-${v}73e-9d61-e57f43c75cd1")\n`)).toMatch(/only 5 and 8/);
    }
  });
  test("uuid (v1.3.0): an escape, braces or a trailing character is refused", () => {
    expect(verdict(HDR + '(repo-deed :schema-version "1" :a #uuid"b32d6be4-73ba-873e-9d61-e57f43c75cd1\\n")\n')).toMatch(/lowercase hex/);
    expect(verdict(HDR + '(repo-deed :schema-version "1" :a #uuid"{b32d6be4-73ba-873e-9d61-e57f43c75cd1}")\n')).toMatch(/lowercase hex/);
    expect(verdict(HDR + '(repo-deed :schema-version "1" :a #uuidx"b32d6be4-73ba-873e-9d61-e57f43c75cd1")\n')).toMatch(/followed immediately by a string/);
  });
  test("line length (v1.3.0): 998 octets pass, 999 fail, counted in UTF-8 bytes", () => {
    const pad = (n) => "x".repeat(n);
    const line = (body) => `(repo-deed :schema-version "1" :n "${body}")`;
    const base = line("").length;
    expect(verdict(HDR + line(pad(998 - base)) + "\n")).toBeNull();
    expect(verdict(HDR + line(pad(998 - base)) + "\r\n")).toBeNull();
    expect(verdict(HDR + line(pad(999 - base)) + "\n")).toMatch(/line is 999 octets/);
    // "é" is 2 octets: 1 character fewer, same octet count.
    expect(verdict(HDR + line("é" + pad(997 - base)) + "\n")).toMatch(/line is 999 octets/);
    // The last line counts too, with no line-end.
    expect(verdict(HDR + line(pad(999 - base)))).toMatch(/line is 999 octets/);
  });
  test("line length (v1.3.0): a long comment or header line is refused too", () => {
    expect(verdict(HDR + ";" + "c".repeat(998) + "\n" + '(repo-deed :schema-version "1")\n')).toMatch(/at most 998 octets/);
  });
  test("error carries line number", () => {
    const e = (() => { try { validate(HDR + "(chora-deed)\n"); } catch (x) { return x; } })();
    expect(e.line).toBe(2);
    expect(String(e)).toMatch(/^line 2: /);
  });
});

/** Spawn `bun deed_lint.js ...args`; returns {code, out}. */
function cli(...args) {
  const r = Bun.spawnSync([process.execPath, LINT, ...args]);
  return { code: r.exitCode, out: r.stdout.toString() + r.stderr.toString() };
}

describe("Mustfile check profile", () => {
  const one = '(check :id alpha :severity critical :discharge run :body "false")';
  const doc = (clauses) => HDR + '(praxis-deed :schema-version "1" ' + clauses + ')';
  test("unknown top-level fields must fail closed", () => {
    expect(() => readMustfileChecks(doc(':typo-check "false" ' + one), "test_praxis.deed")).toThrow(/unknown top-level/);
    expect(() => readMustfileChecks(doc(':canonical-name #t ' + one), "test_praxis.deed")).toThrow(/invalid type/);
    expect(() => readMustfileChecks(doc(':canonical-name "x" :canonical-name "y" ' + one), "test_praxis.deed")).toThrow(/duplicate top-level/);
    expect(() => readMustfileChecks(doc(':canonical-name "must" :beholding-chora #u8"chora:estate/github.com/o" ' + one), "test_praxis.deed")).not.toThrow();
    // Owner ruling Q2 (CHORA-SPEC 7.1): #u5 in an identity field is an error.
    // The literal is assembled at runtime so scripts/check-uuid-v8.sh does not
    // read this test as a deed.
    const u5 = "#" + 'u5"estate/chora"';
    expect(() => readMustfileChecks(doc(':canonical-name "must" :beholding-chora ' + u5 + ' ' + one), "test_praxis.deed")).toThrow(/identity field :beholding-chora carries a #u5 literal/);
    // Outside an identity field #u5 stays legal, and a line break between the
    // field and its value does not hide it.
    expect(() => validate(HDR + '(praxis-deed :schema-version "1" :canonical-name "x" :alias ' + u5 + ')')).not.toThrow();
    expect(() => validate(HDR + '(praxis-deed :schema-version "1" :canonical-name "x" :beholding-chora\n  ' + u5 + ')')).toThrow(/carries a #u5 literal/);
    // The rule is lexical, as in check-uuid-v8.sh (owner ruling of 2026-11-14,
    // "by name"): a field name and #u5 in a comment or a string fail too, and a
    // comment between a field and its value does not hide the value.
    expect(() => validate(HDR + '(praxis-deed :schema-version "1" :canonical-name "x") ; :repo-uuid ' + u5 + '\n')).toThrow(/identity field :repo-uuid carries a #u5 literal/);
    // A string that only mentions the field, with escaped quotes, holds no #u5 literal.
    const u5Quoted = "#" + 'u5\\"estate/chora\\"';
    expect(() => validate(HDR + '(praxis-deed :schema-version "1" :canonical-name "x" :note ":estate ' + u5Quoted + '")')).not.toThrow();
    expect(() => validate(HDR + '(praxis-deed :schema-version "1" :canonical-name "x" :beholding-chora ; note\n  ' + u5 + ')')).toThrow(/carries a #u5 literal/);
    // A ';' inside a string is not a comment, so stripping comments invents no field.
    expect(() => validate(HDR + '(praxis-deed :schema-version "1" :canonical-name "x" :alias (":repo-uuid ; example" ' + u5 + '))')).not.toThrow();
    expect(blankComments('a "b;c" ; d\ne')).toBe('a "b;c"    \ne');
  });
  test("A7 S2: a #u5 in each identity field the A7 profiles read is refused before any profile runs", () => {
    // These were the fixtures own-u5, parent-legacy-literal, related-uuid-legacy
    // and of-chora-u5 (edict and verb descriptile). Q2 makes each a parse
    // error, so the cases live here, with the literal assembled at runtime
    // (scripts/check-uuid-v8.sh reads committed files by name).
    const u5 = "#" + 'u5"github.com/o/x"';
    const anchor = '(anchor :schema "hyperpolymath.anchor/1" :authority "a")';
    const cases = [
      ["repo-uuid", HDR + '(repo-deed :schema-version "1" :canonical-name "x" :repo-uuid ' + u5 + ' ' + anchor + ')'],
      ["uuid", HDR + '(repo-deed :schema-version "1" :canonical-name "x" (anchor :schema "hyperpolymath.anchor/1" :authority "a" (parents (parent :uuid ' + u5 + '))))'],
      ["uuid", HDR + '(descriptile-deed :schema-version "1" :canonical-name "x" (related :name "p" :relationship parent :notes "n" :uuid ' + u5 + '))'],
      ["of-chora", HDR + '(contractile-deed :schema-version "1" :canonical-name "x" :of-chora ' + u5 + ')'],
      ["of-chora", HDR + '(descriptile-deed :schema-version "1" :canonical-name "x" :of-chora ' + u5 + ')'],
    ];
    for (const [field, text] of cases) {
      expect(() => validate(text)).toThrow(new RegExp(`identity field :${field} carries a #u5 literal`));
    }
  });
  test("multiline critical check survives parsing and has an executable body", () => {
    const checks = readMustfileChecks(doc('(check\n :id alpha\n :severity critical\n :discharge run\n :body "false")'), "test_praxis.deed");
    expect(checks).toEqual([{ id: "alpha", severity: "critical", discharge: "run", body: "false" }]);
  });
  test("missing clauses, fields, unknown severities and empty bodies are rejected", () => {
    expect(() => readMustfileChecks(doc(''), "test_praxis.deed")).toThrow(/no \(check/);
    expect(() => readMustfileChecks(doc(one.replace(' :body "false"', '')), "test_praxis.deed")).toThrow(/missing :body/);
    expect(() => readMustfileChecks(doc(one.replace('critical', 'critcal')), "test_praxis.deed")).toThrow(/unknown severity/);
    expect(() => readMustfileChecks(doc(one.replace('"false"', '""')), "test_praxis.deed")).toThrow(/empty :body/);
    expect(() => readMustfileChecks(doc(one.replace('run', 'unverified')), "test_praxis.deed")).toThrow(/unknown discharge/);
  });
  test("duplicate IDs, repeated fields, unrecognised fields and nested checks fail closed", () => {
    expect(() => readMustfileChecks(doc(one + ' ' + one), "test_praxis.deed")).toThrow(/duplicate check id/);
    expect(() => readMustfileChecks(doc(one.replace(':severity critical', ':severity high :severity critical')), "test_praxis.deed")).toThrow(/duplicate .*field/);
    expect(() => readMustfileChecks(doc(one.replace(':body "false"', ':body "false" :extra #t')), "test_praxis.deed")).toThrow(/unknown .*field/);
    expect(() => readMustfileChecks(doc('(group ' + one + ')'), "test_praxis.deed")).toThrow(/unexpected clause/);
    expect(() => readMustfileChecks(doc(one.replace(' :body "false"', ' (nested :a "x") :body "false"')), "test_praxis.deed")).toThrow(/nested clauses/);
  });
  test("a syntactically valid repo-deed is not a Mustfile praxis-deed", () => {
    expect(() => readMustfileChecks(HDR + '(repo-deed :schema-version "1" ' + one + ')')).toThrow(MustfileError);
  });
});


describe("proof-receipt profile (PROOF-POLICY §8.5)", () => {
  const C = "0123456789abcdef0123456789abcdef01234567";
  const OTHER = "fedcba9876543210fedcba9876543210fedcba98";
  // §8.5.1 manifests: FILES is the default input set, FILES2 a changed one.
  // D and D2 are their digests, so a receipt's :inputs-sha256 is derived.
  const FILES = [["src/A.agda", "1".repeat(64)], ["src/Sub/B.agda", "2".repeat(64)], ["x.agda-lib", "3".repeat(64)]];
  const FILES2 = [["src/A.agda", "4".repeat(64)], ["src/Sub/B.agda", "2".repeat(64)], ["x.agda-lib", "3".repeat(64)]];
  const digestOf = (files) => createHash("sha256").update(files.map(([p, h]) => `${h}  ${p}\n`).join(""), "utf8").digest("hex");
  const manifest = (files) => `\n  (inputs-manifest${files.map(([p, h]) => `\n    (file :path "${p}" :sha256 "${h}")`).join("")})`;
  const D = digestOf(FILES), D2 = digestOf(FILES2), T = "c".repeat(64);
  const rcpt = (o = {}) => `\n(receipt :run "${o.run ?? "https://ci/run/1"}" :commit "${o.commit ?? C}" :checker "${o.checker ?? "agda 2.6.4.3"}"`
    + ` :invocation "${o.inv ?? "agda --safe --without-K --cubical-compatible"}"`
    + (o.digest === null ? "" : ` :inputs-sha256 "${o.digest ?? D}"`)
    + ` :state ${o.rstate ?? "current"}${o.reason ? ` :reason "${o.reason}"` : ""}`
    + (o.manifest === null || (o.manifest === undefined && o.digest === null) ? ""
      : o.manifest !== undefined ? o.manifest : manifest(o.digest === D2 ? FILES2 : FILES))
    + (o.axioms === null ? "" : ` ${o.axioms ?? "(axioms)"}`) + ")";
  const agda = (o = {}) => `\n(leg :prover agda :route source :token ${o.tok ?? "proven"} :state ${o.state ?? "AGDA-VERIFIED"} ${o.receipts ?? rcpt(o)})`;
  const recheck = (p, o = {}) => o.route === "unavailable" || o.route === "waived" || o.route === undefined && o.counted === false
    ? `\n(leg :prover ${p} :route ${o.route ?? "unavailable"} :reason "none yet")`
    : `\n(leg :prover ${p} :route ${o.route ?? "transported"} :token ${o.tok ?? "proven"} :state ${o.state ?? "RECONCILED"} ${rcpt({ checker: p, inv: p, commit: o.commit, digest: o.digest, axioms: o.axioms })})`;
  const claim = (pwg, legs, o = {}) => `(claim :id "${o.id ?? "T-1"}" :pwg ${pwg} :foundation-diverse ${o.fd ?? "#f"} ${legs})`;
  const doc = (claims, o = {}) => HDR + `(praxis-deed :schema-version "1.0.0" :canonical-name "r" :profile ${o.profile ?? "proof-receipt"}`
    + ` :repository "${o.repo ?? "hyperpolymath/x"}" :source-commit "${o.commit ?? C}" ${o.extra ?? ""} ${claims})`;
  const read = (src) => readProofReceipt(src, "x_praxis.deed");
  const none = recheck("rocq", { counted: false }) + " " + recheck("lean", { counted: false });

  test("the worked example derives to PWG-3 and reports its trusted base", () => {
    const r = readProofReceipt(readFileSync(join(FIX, "proof-receipt", "example_praxis.deed"), "utf8"), "example_praxis.deed");
    expect(r.claims.map((c) => [c.id, c.pwg, c.foundation_diverse])).toEqual([["T-1", "PWG-3", false]]);
    expect(r.trusted_base.map((p) => p.name)).toEqual(["Level", "lzero", "lsuc", "_⊔_"]);
  });
  test("the worked echo example derives to PWG-1 through its echo (§8.5.2)", () => {
    const r = readProofReceipt(readFileSync(join(FIX, "proof-receipt", "echo_praxis.deed"), "utf8"), "echo_praxis.deed");
    expect(r.claims.map((c) => c.pwg)).toEqual(["PWG-1"]);
    expect(r.echoes.map((e) => e.image)).toEqual([r.source_commit, r.source_commit]);
  });
  test("each grade is derived from the legs, and only that grade is accepted", () => {
    const rocqOk = recheck("rocq"), leanOk = recheck("lean");
    expect(read(doc(claim("PWG-3", agda() + " " + none))).claims[0].pwg).toBe("PWG-3");
    expect(read(doc(claim("PWG-2i", agda() + " " + rocqOk + " " + recheck("lean", { counted: false })))).claims[0].pwg).toBe("PWG-2i");
    expect(read(doc(claim("PWG-2ii", agda() + " " + rocqOk + " " + recheck("lean", { commit: OTHER })))).claims[0].pwg).toBe("PWG-2ii");
    expect(read(doc(claim("PWG-1", agda() + " " + rocqOk + " " + leanOk))).claims[0].pwg).toBe("PWG-1");
    expect(read(doc(claim("ungraded", agda({ tok: "open", state: "AGDA-PENDING" }) + " " + none))).claims[0].pwg).toBe("ungraded");
  });
  test("a recorded grade the receipts do not support is refused (grades are derived, not asserted)", () => {
    expect(() => read(doc(claim("PWG-2i", agda() + " " + none)))).toThrow(/records :pwg PWG-2i, but .* support PWG-3/);
    expect(() => read(doc(claim("PWG-3", agda() + " " + recheck("rocq") + " " + recheck("lean", { counted: false }))))).toThrow(/support PWG-2i/);
    expect(() => read(doc(claim("PWG-1", agda() + " " + recheck("rocq") + " " + recheck("lean", { commit: OTHER }))))).toThrow(/support PWG-2ii/);
  });
  test("what does not count: no §2.1 flags, no current receipt, BRIDGE-PENDING, argued", () => {
    expect(() => read(doc(claim("PWG-3", agda({ inv: "agda --safe --without-K" }) + " " + none)))).toThrow(/support ungraded/);
    expect(() => read(doc(claim("PWG-3", agda({ rstate: "superseded", reason: "old" }) + " " + none)))).toThrow(/support ungraded/);
    expect(() => read(doc(claim("PWG-2i", agda() + " " + recheck("rocq", { state: "BRIDGE-PENDING" }) + " " + recheck("lean", { counted: false }))))).toThrow(/support PWG-3/);
    expect(() => read(doc(claim("PWG-2i", agda() + " " + recheck("rocq", { tok: "argued" }) + " " + recheck("lean", { counted: false }))))).toThrow(/support PWG-3/);
    expect(read(doc(claim("PWG-3", agda({ inv: "agda --safe --without-K --cubical --erasure" }) + " " + none))).claims[0].pwg).toBe("PWG-3");
  });
  test("foundation diversity is derived too (§8.3)", () => {
    const isa = `(leg :prover isabelle :route re-proved :token proven :state RECONCILED ${rcpt({ checker: "isabelle", inv: "isabelle build" })})`;
    expect(read(doc(claim("PWG-3", agda() + " " + none + " " + isa, { fd: "#t" }))).claims[0].foundation_diverse).toBe(true);
    expect(() => read(doc(claim("PWG-3", agda() + " " + none + " " + isa)))).toThrow(/foundation-diverse #f, but .* #t/);
    expect(() => read(doc(claim("PWG-3", agda() + " " + none, { fd: "#t" })))).toThrow(/foundation-diverse #t/);
  });
  test("malformed receipts fail closed", () => {
    const ok = claim("PWG-3", agda() + " " + none);
    expect(() => read(doc(ok, { profile: "mustfile" }))).toThrow(/:profile mustfile/);
    expect(() => read(doc(ok, { commit: "0123456" }))).toThrow(/full 40-character/);
    expect(() => read(doc(ok, { repo: "just-a-name" }))).toThrow(/OWNER\/REPO/);
    expect(() => read(doc(ok, { extra: ':grade "3"' }))).toThrow(/unknown field :grade/);
    expect(() => read(doc(""))).toThrow(/at least one \(claim/);
    expect(() => read(doc(ok + "\n" + ok))).toThrow(/duplicate claim id/);
    expect(() => read(doc(claim("PWG-3", none)))).toThrow(/no agda leg/);
    expect(() => read(doc(claim("PWG-3", agda() + " " + agda())))).toThrow(/two agda legs/);
    expect(() => read(doc(claim("PWG-3", agda({ receipts: rcpt() + " " + rcpt() }) + " " + none)))).toThrow(/more than one current receipt/);
    expect(() => read(doc(claim("PWG-3", agda({ receipts: rcpt({ rstate: "superseded" }) + " " + rcpt() }) + " " + none)))).toThrow(/superseded receipt needs :reason/);
    expect(() => read(doc(claim("PWG-3", agda({ commit: "abc" }) + " " + none)))).toThrow(/receipt :commit/);
    expect(() => read(doc(claim("PWG-3", agda() + ' (leg :prover rocq :route unavailable :token proven :reason "x") ' + recheck("lean", { counted: false }))))).toThrow(/carries no :token/);
    expect(() => read(doc(claim("PWG-3", agda() + ' (leg :prover rocq :route unavailable) ' + recheck("lean", { counted: false }))))).toThrow(/needs :reason/);
    expect(() => read(doc(claim("PWG-3", agda() + ' (leg :prover rocq :route source :token proven :state RECONCILED) ' + recheck("lean", { counted: false }))))).toThrow(/route source belongs to the agda leg/);
    expect(() => read(doc(claim("PWG-3", agda({ tok: "verified" }) + " " + none)))).toThrow(/:token verified .* not one of/);
    expect(() => read(doc(claim("PWG-3", agda() + " " + none), { extra: '(trusted-base)' }))).toThrow(/lists no \(primitive/);
    expect(() => readProofReceipt(HDR + '(repo-deed :schema-version "1" :x "y")')).toThrow(ProofReceiptError);
  });
  test("§8.5.1: every current receipt carries a well-formed :inputs-sha256", () => {
    const one = (o) => read(doc(claim("PWG-3", agda(o) + " " + none)));
    expect(one({}).claims[0].legs[0].receipts[0]["inputs-sha256"]).toBe(D);
    expect(() => one({ digest: null })).toThrow(/is current and is missing :inputs-sha256/);
    expect(() => one({ digest: "A".repeat(64) })).toThrow(/:inputs-sha256 must be 64 lowercase hex/);
    expect(() => one({ digest: "a".repeat(63) })).toThrow(/:inputs-sha256 must be 64 lowercase hex/);
    expect(() => one({ digest: "a".repeat(40) })).toThrow(/:inputs-sha256 must be 64 lowercase hex/);
    // A kept receipt that is not current may predate the field.
    const old = rcpt({ commit: OTHER, rstate: "superseded", reason: "old", digest: null, axioms: null });
    expect(read(doc(claim("PWG-3", agda({ receipts: rcpt() + " " + old }) + " " + none))).claims[0].pwg).toBe("PWG-3");
    // One commit has one input digest per prover.
    const twice = rcpt({ rstate: "superseded", reason: "rerun", digest: D2 });
    expect(() => read(doc(claim("PWG-3", agda({ receipts: rcpt() + " " + twice }) + " " + none)))).toThrow(/two different input digests/);
  });
  test("§8.5.1: every current receipt carries its (inputs-manifest …), and the digest is derived from it", () => {
    const one = (o) => read(doc(claim("PWG-3", agda(o) + " " + none)));
    const r = one({}).claims[0].legs[0].receipts[0];
    expect(r.inputs_manifest.map((m) => m.path)).toEqual(["src/A.agda", "src/Sub/B.agda", "x.agda-lib"]);
    expect(() => one({ manifest: null })).toThrow(/is current and is missing \(inputs-manifest/);
    expect(() => one({ manifest: manifest(FILES) + manifest(FILES) })).toThrow(/more than one \(inputs-manifest/);
    expect(() => one({ manifest: "\n(inputs-manifest)" })).toThrow(/lists no \(file/);
    // The digest must be the SHA-256 of the manifest.
    expect(() => one({ manifest: manifest(FILES2) })).toThrow(/is not the SHA-256 of its \(inputs-manifest/);
    // Form of each entry.
    const h = "1".repeat(64);
    const bad = (files) => () => one({ digest: digestOf(files), manifest: manifest(files) });
    expect(bad([["x.agda-lib", h], ["src/A.agda", h]])).toThrow(/out of order/);
    expect(bad([["Z.agda", h], ["a.agda", h]])()).toBeTruthy(); // "Z" (0x5a) sorts before "a" (0x61) in byte order
    expect(bad([["a.agda", h], ["a.agda", h]])).toThrow(/listed twice/);
    expect(bad([["./a.agda", h]])).toThrow(/no empty, "\." or "\.\." part/);
    expect(bad([["/a.agda", h]])).toThrow(/no empty/);
    expect(bad([["src//a.agda", h]])).toThrow(/no empty/);
    expect(bad([["../a.agda", h]])).toThrow(/no empty/);
    expect(bad([["src/", h]])).toThrow(/no empty/);
    expect(() => one({ digest: digestOf([["a\\b", h]]), manifest: '\n(inputs-manifest (file :path "a\\\\b" :sha256 "' + h + '"))' })).toThrow(/newline or a backslash/);
    expect(bad([["a.agda", "A".repeat(64)]])).toThrow(/:sha256 must be 64 lowercase hex/);
    expect(() => one({ manifest: '\n(inputs-manifest (file :path "a.agda"))' })).toThrow(/missing :sha256/);
    expect(() => one({ manifest: '\n(inputs-manifest (entry :path "a.agda"))' })).toThrow(/unexpected clause \(entry\)/);
    // A manifest needs the digest it derives.
    const kept = rcpt({ commit: OTHER, rstate: "superseded", reason: "old", digest: null, manifest: manifest(FILES) });
    expect(() => read(doc(claim("PWG-3", agda({ receipts: rcpt() + " " + kept }) + " " + none)))).toThrow(/needs :inputs-sha256/);
    // Byte order, not UTF-16 order: U+FF5E sorts before U+10000 in UTF-16 but after it in UTF-8.
    expect(bad([["\u{10000}.agda", h], ["\uFF5E.agda", h]])).toThrow(/out of order/);
    expect(bad([["\uFF5E.agda", h], ["\u{10000}.agda", h]])()).toBeTruthy();
  });
  test("§8.5.2: two manifests for one commit and one prover cannot differ", () => {
    const other = rcpt({ rstate: "superseded", reason: "rerun", digest: D2 });
    expect(() => read(doc(claim("PWG-3", agda({ receipts: rcpt() + " " + other }) + " " + none)))).toThrow(/two different input digests/);
  });
  test("§8.5.1: an (import …) records a pinned repository with its own derived manifest", () => {
    const IC = "9".repeat(40), h = "5".repeat(64);
    const IFILES = [["src/Algebra.agda", h], ["x.agda-lib", "6".repeat(64)]];
    const imp = (o = {}) => `\n  (import :repository "${o.repo ?? "o/sibling"}" :commit "${o.commit ?? IC}" :inputs-sha256 "${o.digest ?? digestOf(o.files ?? IFILES)}"`
      + (o.files ?? IFILES).map(([p, x]) => `\n    (file :path "${p}" :sha256 "${x}")`).join("") + ")";
    const one = (imports) => read(doc(claim("PWG-3", agda({ manifest: manifest(FILES) + imports }) + " " + none)));
    const r = one(imp()).claims[0].legs[0].receipts[0];
    expect(r.imports).toEqual([{ repository: "o/sibling", commit: IC, "inputs-sha256": digestOf(IFILES),
      files: IFILES.map(([path, sha256]) => ({ path, sha256 })) }]);
    expect(one("").claims[0].legs[0].receipts[0].imports).toEqual([]);
    expect(() => one(imp({ digest: D }))).toThrow(/import o\/sibling: :inputs-sha256 is not the SHA-256 of its files/);
    expect(() => one(imp({ repo: "nope" }))).toThrow(/:repository must be OWNER\/REPO/);
    expect(() => one(imp({ repo: "hyperpolymath/x" }))).toThrow(/does not import itself/);
    expect(() => one(imp() + imp())).toThrow(/listed twice \(one pin per repository\)/);
    expect(() => one(imp({ commit: "abc" }))).toThrow(/:commit must be the full 40-character/);
    expect(() => one(imp({ files: [["b", h], ["a", h]] }))).toThrow(/import o\/sibling manifest path "a" is out of order/);
    expect(() => one(imp({ files: [["../a", h]] }))).toThrow(/no empty/);
    expect(() => one(imp({ files: [] }))).toThrow(/lists no \(file/);
    expect(() => one('\n  (import :repository "o/s" :commit "' + IC + '" (file :path "a" :sha256 "' + h + '"))')).toThrow(/missing :inputs-sha256/);
  });
  test("§8.5.4: a negative control is recorded, checked for form and never graded", () => {
    const REJ = [["src/A.agda", "1".repeat(64)], ["tests/reject/Bad.agda", "7".repeat(64)], ["x.agda-lib", "3".repeat(64)]];
    const ctl = (o = {}) => `\n  (control :path "${o.path ?? "tests/reject/Bad.agda"}" :prover ${o.prover ?? "agda"} :expect ${o.expect ?? "refused"}`
      + (o.receipts ?? rcpt({ digest: digestOf(o.files ?? REJ), manifest: manifest(o.files ?? REJ) })) + ")";
    const one = (controls, pwg = "PWG-3") => read(doc(claim(pwg, agda() + " " + none + controls)));
    const r = one(ctl()).claims[0];
    expect(r.pwg).toBe("PWG-3");
    expect(r.controls.map((c) => [c.path, c.prover, c.expect])).toEqual([["tests/reject/Bad.agda", "agda", "refused"]]);
    expect(one("").claims[0].controls).toEqual([]);
    // Never graded: a control does not raise or lower the grade.
    expect(() => one(ctl(), "PWG-2i")).toThrow(/support PWG-3/);
    // Its digest stays out of the per-commit agreement: same commit and prover, other inputs.
    expect(one(ctl()).claims[0].legs[0].receipts[0]["inputs-sha256"]).toBe(D);
    expect(() => one(ctl({ expect: "accepted" }))).toThrow(/:expect accepted .* not one of refused/);
    expect(() => one(ctl({ path: "./x.agda" }))).toThrow(/no empty/);
    expect(() => one(ctl() + ctl())).toThrow(/is listed twice/);
    expect(() => one(ctl({ receipts: "" }))).toThrow(/has no \(receipt/);
    expect(() => one(ctl({ files: FILES }))).toThrow(/the refused file is not in its current receipt/);
    expect(() => one(ctl({ receipts: rcpt({ digest: digestOf(REJ), manifest: manifest(REJ) }) + rcpt({ digest: digestOf(REJ), manifest: manifest(REJ) }) })))
      .toThrow(/more than one current receipt/);
    expect(() => one(ctl({ receipts: rcpt({ manifest: null }) }))).toThrow(/is missing \(inputs-manifest/);
    expect(() => one('\n  (control :path "tests/reject/Bad.agda" :expect refused)')).toThrow(/missing :prover/);
  });
  test("§8.4: every current receipt lists its axioms, and only disposition (c) counts", () => {
    const one = (axioms, pwg = "PWG-3") => read(doc(claim(pwg, agda({ axioms }) + " " + none)));
    expect(one("(axioms)").claims[0].legs[0].receipts[0].axioms).toEqual([]);
    expect(one('(axioms (axiom :name "funext" :disposition c))').claims[0].legs[0].receipts[0].axioms)
      .toEqual([{ name: "funext", disposition: "c" }]);
    expect(() => one(null)).toThrow(/is current and is missing \(axioms/);
    expect(() => one("(axioms) (axioms)")).toThrow(/more than one \(axioms/);
    expect(() => one('(axioms (axiom :name "x" :disposition a))')).toThrow(/:disposition a .* not one of b, c, debt/);
    expect(() => one('(axioms (axiom :name "x" :disposition c) (axiom :name "x" :disposition c))')).toThrow(/listed twice/);
    expect(() => one('(axioms (axiom :name "x"))')).toThrow(/missing :disposition/);
    expect(() => one('(axioms "x")')).toThrow();
    // An axiom that is debt or budgeted stops the leg from counting.
    expect(one('(axioms (axiom :name "x" :disposition debt))', "ungraded").claims[0].pwg).toBe("ungraded");
    expect(() => read(doc(claim("PWG-2i", agda() + " " + recheck("rocq", { axioms: '(axioms (axiom :name "x" :disposition b))' })
      + " " + recheck("lean", { counted: false }))))).toThrow(/support PWG-3/);
  });
  describe("§8.5.2: echoes of a history rewrite", () => {
    // S1 and S2 are pre-rewrite commits; C (the :source-commit) is their image.
    const S1 = "1111111111111111111111111111111111111111", S2 = "2222222222222222222222222222222222222222";
    const echo = (src, img, o = {}) => o.tree
      ? `\n(echo :source "${src}" :image "${img}" :witness tree-sha256 :tree-sha256 "${o.tree}")`
      : `\n(echo :source "${src}" :image "${img}" :witness inputs-sha256 ${(o.provers ?? ["agda", "rocq", "lean"]).map((p) => `(inputs :prover ${p} :sha256 "${o.d ?? D}")`).join(" ")})`;
    const legsAt = (commit) => agda({ commit }) + " " + recheck("rocq", { commit }) + " " + recheck("lean", { commit });
    const at = (commit, echoes, pwg = "PWG-1") => read(doc(claim(pwg, legsAt(commit)), { extra: echoes }));

    test("a receipt whose :commit has no echo and is not the :source-commit stops at PWG-2ii", () => {
      expect(at(S1, "", "PWG-2ii").claims[0].pwg).toBe("PWG-2ii");
      expect(() => at(S1, "")).toThrow(/records :pwg PWG-1, but .* support PWG-2ii/);
    });
    test("an echo whose inputs digest matches each leg lets the receipt count for its image", () => {
      const r = at(S1, echo(S1, C));
      expect(r.claims[0].pwg).toBe("PWG-1");
      expect(r.echoes).toEqual([{ source: S1, image: C, witness: "inputs-sha256", tree_sha256: null, inputs: { agda: D, rocq: D, lean: D } }]);
    });
    test("an echo without a matching witness does not count", () => {
      // The echo names no digest for the lean leg.
      expect(() => at(S1, echo(S1, C, { provers: ["agda", "rocq"] }))).toThrow(/support PWG-2ii/);
      // The echo's digest disagrees with the receipt at the same commit.
      expect(() => at(S1, echo(S1, C, { d: D2 }), "PWG-2ii")).toThrow(/two different input digests/);
    });
    test("a tree-sha256 echo covers every leg", () => {
      expect(at(S1, echo(S1, C, { tree: T })).claims[0].pwg).toBe("PWG-1");
    });
    test("echoes chain, and the fibre over one image holds several sources", () => {
      expect(at(S1, echo(S1, S2) + " " + echo(S2, C, { tree: T })).claims[0].pwg).toBe("PWG-1");
      expect(at(S1, echo(S1, C) + " " + echo(S2, C)).claims[0].pwg).toBe("PWG-1");
      // A chain that does not reach the :source-commit does not count.
      expect(() => at(S1, echo(S1, S2))).toThrow(/support PWG-2ii/);
    });
    test("the echo records themselves are checked", () => {
      const ok = claim("PWG-3", agda() + " " + none);
      const bad = (extra) => () => read(doc(ok, { extra }));
      expect(bad(echo(S1, C) + " " + echo(S1, S2))).toThrow(/one image only/);
      expect(bad(echo(S1, S1))).toThrow(/are the same commit/);
      expect(bad(echo(C, S1))).toThrow(/never a source/);
      expect(bad(echo(S1, S2) + " " + echo(S2, S1))).toThrow(/cycle/);
      expect(bad(echo("abc", C))).toThrow(/full 40-character/);
      expect(bad(`(echo :source "${S1}" :image "${C}" :witness tree-sha256)`)).toThrow(/needs :tree-sha256/);
      expect(bad(`(echo :source "${S1}" :image "${C}" :witness tree-sha256 :tree-sha256 "abc")`)).toThrow(/64 lowercase hex/);
      expect(bad(`(echo :source "${S1}" :image "${C}" :witness inputs-sha256)`)).toThrow(/at least one \(inputs/);
      expect(bad(`(echo :source "${S1}" :image "${C}" :witness tree)`)).toThrow(/:witness tree .* not one of/);
      expect(bad(`(echo :source "${S1}" :image "${C}" :witness inputs-sha256 :tree-sha256 "${T}" (inputs :prover agda :sha256 "${D}"))`)).toThrow(/carries no :tree-sha256/);
      expect(bad(`(echo :source "${S1}" :image "${C}" :witness inputs-sha256 (inputs :prover agda :sha256 "${D}") (inputs :prover agda :sha256 "${D}"))`)).toThrow(/two \(inputs/);
      expect(bad(echo(S1, S2, { tree: T }) + " " + echo(S2, C, { tree: "d".repeat(64) }))).toThrow(/two different tree-sha256/);
      expect(bad(echo(S1, C, { tree: T }) + " " + echo(S2, S1, { provers: ["agda"], d: D2 }))).toThrow(/input digests of its two commits differ/);
    });
  });
  test("--proof-receipt-json emits records for a valid receipt and no JSON otherwise", () => {
    const ok = cli("--proof-receipt-json", join(FIX, "proof-receipt", "example_praxis.deed"));
    expect(ok.code).toBe(0);
    expect(JSON.parse(ok.out).claims[0].pwg).toBe("PWG-3");
    const bad = cli("--proof-receipt-json", join(FIX, "valid", "minimal_chora.deed"));
    expect(bad.code).toBe(1);
    expect(bad.out).toMatch(/^FAIL /);
    expect(cli("--proof-receipt-json").code).toBe(2);
  });
});

describe("CLI", () => {
  test("--ast-json emits only validated, lossless structural data", () => {
    const p = join(FIX, "valid", "minimal_chora.deed");
    const r = cli("--ast-json", p);
    expect(r.code).toBe(0);
    const ast = JSON.parse(r.out);
    expect(ast.head).toBe("repo-deed");
    expect(ast.items.some((item) => item[0] === "field" && item[1] === "schema-version")).toBe(true);
  });
  test("--ast-json fails closed on invalid files, absent files, and ambiguous arguments", () => {
    const bad = cli("--ast-json", join(FIX, "invalid", "intab_chora.deed"));
    expect(bad.code).toBe(1);
    expect(bad.out).toContain("FAIL");
    expect(() => JSON.parse(bad.out)).toThrow();
    expect(cli("--ast-json", join(FIX, "not-found_chora.deed")).code).toBe(1);
    expect(cli("--ast-json").code).toBe(2);
    expect(cli("--ast-json", join(FIX, "valid", "minimal_chora.deed"), "extra.deed").code).toBe(2);
  });
  test("canonical machine manifest passes with its real filename", () => {
    const manifest = join(HERE, "../../../0-AI-MANIFEST.deed");
    const r = cli(manifest);
    expect(r.code).toBe(0);
    expect(r.out).toContain(`OK   ${manifest}`);
  });
  test("valid fixture exits 0", () => {
    const p = join(FIX, "valid", "minimal_chora.deed");
    const r = cli(p);
    expect(r.code).toBe(0);
    expect(r.out).toContain(`OK   ${p}`);
  });
  test("invalid fixture exits nonzero", () => {
    const p = join(FIX, "invalid", "intab_chora.deed");
    const r = cli(p);
    expect(r.code).not.toBe(0);
    expect(r.out).toContain(`FAIL ${p}: line 2: HTAB`);
  });
  test("mixed files exit nonzero", () => {
    expect(cli(join(FIX, "valid", "minimal_chora.deed"), join(FIX, "invalid", "intab_chora.deed")).code).toBe(1);
  });
  test("missing file exits nonzero", () => {
    expect(cli(join(FIX, "nope_chora.deed")).code).toBe(1);
  });
  test("no args prints usage, exit 2", () => {
    const r = cli();
    expect(r.code).toBe(2);
    expect(r.out).toContain("deed-lint");
  });
  test("--self-test exits 0", () => {
    const r = cli("--self-test");
    expect(r.code).toBe(0);
    expect(r.out).toContain("SELF-TEST OK");
  });
  test("--fixtures exits 0", () => {
    const r = cli("--fixtures", FIX);
    expect(r.code).toBe(0);
    expect(r.out).toContain("FIXTURES OK");
  });
});

// ─── (egress …) clause profile (ADR-009) ──────────────────────────────

const FIX_EGRESS = join(FIX, "egress");
const deeds = (sub) => readdirSync(join(FIX_EGRESS, sub)).filter((n) => n.endsWith(".deed")).sort();

describe("egress fixtures", () => {
  for (const n of deeds("valid")) {
    test(`valid/${n} passes`, () => {
      const f = join(FIX_EGRESS, "valid", n);
      expect(() => checkEgress(readFileSync(f, "utf8"), f)).not.toThrow();
    });
  }
  for (const n of deeds("invalid")) {
    // Every invalid fixture is a grammatical deed: it must fail on the
    // profile, never on deed.abnf, or it tests the wrong layer.
    test(`invalid/${n} is a valid deed but fails the profile`, () => {
      const f = join(FIX_EGRESS, "invalid", n);
      const src = readFileSync(f, "utf8");
      expect(() => validate(src, f)).not.toThrow();
      expect(() => checkEgress(src, f)).toThrow(EgressError);
    });
  }
});

describe("checkEgress result", () => {
  test("returns the declared jobs", () => {
    const f = join(FIX_EGRESS, "valid", "template-pair_chora.deed");
    const jobs = checkEgress(readFileSync(f, "utf8"), f);
    expect(jobs).toEqual([
      {
        workflow: ".github/workflows/push-email-notify.yml",
        job: "notify",
        secrets: ["SMTP_HOST", "SMTP_PORT", "SMTP_USER", "SMTP_PASS"],
        endpoints: ["secret:SMTP_HOST"],
        enforcement: "none",
      },
      {
        workflow: ".github/workflows/sonarqube.yml",
        job: "sonarqube",
        secrets: ["SONAR_TOKEN"],
        endpoints: ["sonarcloud.io", "*.sonarcloud.io:443", "var:SONAR_HOST"],
        enforcement: "harden-runner-block",
      },
    ]);
  });

  test("a deed without the clause declares nothing", () => {
    const f = join(FIX_EGRESS, "valid", "no-egress_chora.deed");
    expect(checkEgress(readFileSync(f, "utf8"), f)).toEqual([]);
  });

  test("the clause is refused outside a repo-deed", () => {
    const src = ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(praxis-deed :schema-version "1.0.0" (egress))\n';
    expect(() => checkEgress(src, "tool_praxis.deed")).toThrow(EgressError);
  });
});

describe("CLI --egress", () => {
  test("counts the declared jobs of a valid deed", () => {
    const p = join(FIX_EGRESS, "valid", "template-pair_chora.deed");
    const r = cli("--egress", p);
    expect(r.code).toBe(0);
    expect(r.out).toContain(`OK   ${p} (2 egress jobs)`);
  });
  test("a profile violation exits nonzero and names the field", () => {
    const p = join(FIX_EGRESS, "invalid", "github-token_chora.deed");
    const r = cli("--egress", p);
    expect(r.code).toBe(1);
    expect(r.out).toContain(`FAIL ${p}: GITHUB_TOKEN is not listed`);
  });
  test("--egress-fixtures passes on the egress corpus", () => {
    const r = cli("--egress-fixtures", FIX_EGRESS);
    expect(r.code).toBe(0);
    expect(r.out).toContain("EGRESS FIXTURES OK");
  });
});

// ─── (anchor …) clause profile (DRAFT, A7; ruling Q11) ─────────────────

const FIX_ANCHOR = join(FIX, "anchor");
const anchorDeeds = (sub) => readdirSync(join(FIX_ANCHOR, sub)).filter((n) => n.endsWith(".deed")).sort();

// Each invalid fixture names the one rule it breaks; the message pins it, so a
// fixture that starts failing for a different reason is caught.
const ANCHOR_WHY = {
  "clade-in-anchor_chora.deed": "has no field :clade",
  "date-bad_chora.deed": "is not a real YYYY-MM-DD date",
  "date-impossible_chora.deed": "is not a real YYYY-MM-DD date",
  "empty-authority_chora.deed": ":authority must not be empty",
  "empty-subclause_chora.deed": "(anchor (ssg …)) is empty",
  "id-in-anchor_chora.deed": "has no field :id",
  "metadata-unknown_chora.deed": "has no field :owner",
  "mint-token-minted_chora.deed": "unfilled repo-init token",
  "mint-token-repo_chora.deed": "unfilled repo-init token",
  "mint-token-subject_chora.deed": "unfilled repo-init token",
  "missing-authority_chora.deed": "is missing :authority",
  "missing-schema_chora.deed": "is missing :schema",
  "nested-anchor_chora.deed": "only at the top level",
  "parent-duplicate_chora.deed": "twice",
  "parent-no-own-id_chora.deed": "needs the deed's own :repo-uuid",
  "parent-no-uuid_chora.deed": "is missing :uuid",
  "parent-relation-string_chora.deed": ":relation must be a symbol",
  "parent-self_chora.deed": "the deed's own :repo-uuid",
  "parent-self-u8_chora.deed": "the deed's own :repo-uuid",
  "parent-string_chora.deed": "got string",
  "parents-stray_chora.deed": "takes (parent …) clauses only",
  "praxis-head_praxis.deed": "belongs in a repo-deed",
  "purpose-empty_chora.deed": ":purpose must not be empty",
  "purpose-symbols_chora.deed": "items must be strings",
  "repeated-clause_chora.deed": "repeats (ssg …)",
  "repeated-field_chora.deed": "repeats :authority",
  "repo-uuid-twice_chora.deed": "carries one :repo-uuid",
  "satellite-string_chora.deed": "must be #t or #f",
  "schema-symbol_chora.deed": ":schema must be a string",
  "sem-files-absolute_chora.deed": "is not a repo-relative path",
  "sem-files-boolean_chora.deed": ":spec must be a string",
  "sem-files-escape_chora.deed": "is not a repo-relative path",
  "status-in-anchor_chora.deed": "has no clause (status …)",
  "sub-nested-clause_chora.deed": "takes fields only",
  "two-anchors_chora.deed": "at most one (anchor …)",
  "v1-subject_chora.deed": "needs hyperpolymath.anchor/2",
  "v2-identity_chora.deed": "is (subject …) in hyperpolymath.anchor/2",
  "v2-parents_chora.deed": "is gone in hyperpolymath.anchor/2: a parent",
  "v2-ssg_chora.deed": "is gone in hyperpolymath.anchor/2: site-build",
  "version-two-segment_chora.deed": "is not MAJOR.MINOR.PATCH",
  "wrong-schema_chora.deed": '"hyperpolymath.anchor/1"',
};

describe("anchor fixtures", () => {
  for (const n of anchorDeeds("valid")) {
    test(`valid/${n} passes`, () => {
      const f = join(FIX_ANCHOR, "valid", n);
      expect(() => checkAnchor(readFileSync(f, "utf8"), f, { template: n.startsWith("template-") })).not.toThrow();
    });
  }
  test("every invalid fixture has a stated reason, and every reason a fixture", () => {
    expect(anchorDeeds("invalid")).toEqual(Object.keys(ANCHOR_WHY).sort());
  });
  for (const n of anchorDeeds("invalid")) {
    // A grammatical deed that fails only the profile, for its own reason.
    test(`invalid/${n} is a valid deed but fails the profile: ${ANCHOR_WHY[n]}`, () => {
      const f = join(FIX_ANCHOR, "invalid", n);
      const src = readFileSync(f, "utf8");
      expect(() => validate(src, f)).not.toThrow();
      let err = null;
      try {
        checkAnchor(src, f);
      } catch (e) {
        err = e;
      }
      expect(err).toBeInstanceOf(AnchorError);
      expect(err.message).toContain(ANCHOR_WHY[n]);
    });
  }
});

describe("--anchor FILE... batch", () => {
  test("an unreadable path fails that file and the batch goes on", () => {
    const ok = join(FIX_ANCHOR, "valid", "minimal_chora.deed");
    const r = cli("--anchor", "/nonexistent/missing_chora.deed", ok);
    expect(r.code).toBe(1);
    expect(r.out).toContain("FAIL /nonexistent/missing_chora.deed: cannot read the file (ENOENT)");
    expect(r.out).toContain(`OK   ${ok}`);
  });
});

describe("checkAnchor result", () => {
  test("a deed without the clause has no anchor", () => {
    const f = join(FIX_ANCHOR, "valid", "no-anchor_chora.deed");
    expect(checkAnchor(readFileSync(f, "utf8"), f)).toBeNull();
  });
  test("returns the authority, the members and the parent ids", () => {
    const f = join(FIX_ANCHOR, "valid", "translated_chora.deed");
    expect(checkAnchor(readFileSync(f, "utf8"), f)).toEqual({
      authority: "upstream-canonical",
      members: ["(golden-path", "(implementation-policy", "(metadata", "(parents", "(semantic-authority-files", "(ssg", ":authority", ":schema"],
      parents: ["00000000-0000-8000-8000-0000000000b1", "00000000-0000-8000-8000-0000000000b2"],
      schema: "hyperpolymath.anchor/1",
      legacy: true,
    });
  });
  test("a /2 clause is read under v2.0.0 and is not legacy (A7 J27)", () => {
    const f = join(FIX_ANCHOR, "valid", "v2-subject_chora.deed");
    const a = checkAnchor(readFileSync(f, "utf8"), f);
    expect(a.schema).toBe("hyperpolymath.anchor/2");
    expect(a.legacy).toBe(false);
    expect(a.members).toContain("(subject");
  });
  test("the /1 warning names every move to /2: identity, parents and ssg (A7 J26, J27, J29)", () => {
    const { code, out } = cli("--anchor", join(FIX_ANCHOR, "valid", "translated_chora.deed"));
    expect(code).toBe(0);
    expect(out).toContain("(identity …) becomes (subject …)");
    expect(out).toContain("(parents …) moves to ECOSYSTEM.deed");
    expect(out).toContain("(ssg …) to META.deed");
    expect(out).toContain("J29");
  });
  test("the template's own clause, mint tokens included, passes in template mode", () => {
    const f = join(FIX_ANCHOR, "valid", "template-a55669e_chora.deed");
    expect(checkAnchor(readFileSync(f, "utf8"), f, { template: true }).authority).toBe("upstream-canonical");
  });
  test("the same clause outside template mode fails on its first token", () => {
    const f = join(FIX_ANCHOR, "valid", "template-a55669e_chora.deed");
    expect(() => checkAnchor(readFileSync(f, "utf8"), f)).toThrow(/unfilled repo-init token/);
  });
  test("a version 5 parent id is refused (A1 rule V8)", () => {
    // Built at run time: the repo carries no version 5 UUID literal (check-uuid-v8.sh --strict).
    const v5 = "00000000-0000-" + "5" + "000-8000-0000000000b1";
    const src = `;; SPDX-License-Identifier: CC-BY-SA-4.0
(repo-deed :schema-version "1.0.0" :canonical-name "x" :repo-uuid #uuid"00000000-0000-8000-8000-0000000000a7" :beholding-chora #uuid"00000000-0000-8000-8000-00000000e57a"
  (identity :primary-forge github :owner "o")
  (anchor :schema "hyperpolymath.anchor/1" :authority "a" (parents (parent :uuid #uuid"${v5}"))))
`;
    // :uuid is an identity field (CHORA-SPEC 7.1), so the grammar pass already
    // refuses a version 5 there (T30), before the anchor profile looks at it.
    expect(() => validate(src)).toThrow(/identity field :uuid carries a version 5 id \(v5-identity\)/);
    expect(() => checkAnchor(src)).toThrow();
  });
  test("a version 5 #uuid in any identity field is v5-identity; version 8 is accepted (A1 T30)", () => {
    const v5 = "00000000-0000-" + "5" + "000-8000-0000000000b1";
    const deed = (id) => `;; SPDX-License-Identifier: CC-BY-SA-4.0
(repo-deed :schema-version "1.0.0" :canonical-name "x" :repo-uuid #uuid"${id}" :beholding-chora #uuid"00000000-0000-8000-8000-00000000e57a")
`;
    expect(() => validate(deed(v5))).toThrow(/identity field :repo-uuid carries a version 5 id/);
    expect(() => validate(deed("00000000-0000-8000-8000-0000000000a7"))).not.toThrow();
    // Outside an identity field a version 5 #uuid stays legal (the registry alias).
    expect(() => validate(`;; SPDX-License-Identifier: CC-BY-SA-4.0
(praxis-deed :schema-version "1" :canonical-name "x" (alias :registry-v5 #uuid"${v5}"))
`)).not.toThrow();
  });
  test("profile C of a #u8 body matches scripts/uuid-v8.js", () => {
    expect(profileCOfBody("gv-clade-index:github.com/hyperpolymath/standards")).toBe("b32d6be4-73ba-873e-9d61-e57f43c75cd1");
  });
  test("leap days: 2028-02-29 is a date, 2026-02-29 is not", () => {
    const deed = (d) => `;; SPDX-License-Identifier: CC-BY-SA-4.0
(repo-deed :schema-version "1.0.0" :canonical-name "x" :repo-uuid #uuid"00000000-0000-8000-8000-0000000000a7" :beholding-chora #uuid"00000000-0000-8000-8000-00000000e57a"
  (identity :primary-forge github :owner "o")
  (anchor :schema "hyperpolymath.anchor/1" :authority "a" (metadata :last-updated "${d}")))
`;
    expect(() => checkAnchor(deed("2028-02-29"))).not.toThrow();
    expect(() => checkAnchor(deed("2026-02-29"))).toThrow(/not a real/);
    // Years 0000 to 0099 are not shifted into the 1900s.
    expect(() => checkAnchor(deed("0099-12-31"))).not.toThrow();
    expect(() => checkAnchor(deed("0000-02-29"))).not.toThrow();
    expect(() => checkAnchor(deed("0001-02-29"))).toThrow(/not a real/);
  });
  test("a field named after an Object.prototype property is an unknown field, not a crash", () => {
    const deed = (inner) => `;; SPDX-License-Identifier: CC-BY-SA-4.0
(repo-deed :schema-version "1.0.0" :canonical-name "x" :repo-uuid #uuid"00000000-0000-8000-8000-0000000000a7" :beholding-chora #uuid"00000000-0000-8000-8000-00000000e57a"
  (identity :primary-forge github :owner "o")
  (anchor :schema "hyperpolymath.anchor/1" :authority "a" ${inner}))
`;
    for (const name of ["constructor", "toString", "hasOwnProperty", "valueOf"]) {
      expect(() => checkAnchor(deed(`(metadata :${name} "x")`))).toThrow(AnchorError);
      expect(() => checkAnchor(deed(`:${name} "x"`))).toThrow(AnchorError);
    }
  });
});

describe("CLI --anchor", () => {
  test("reports a valid anchor and a deed without one", () => {
    const a = join(FIX_ANCHOR, "valid", "minimal_chora.deed");
    const b = join(FIX_ANCHOR, "valid", "no-anchor_chora.deed");
    const r = cli("--anchor", a, b);
    expect(r.code).toBe(0);
    expect(r.out).toContain(`OK   ${a} (anchor, authority "upstream-canonical")`);
    expect(r.out).toContain(`OK   ${b} (no anchor clause)`);
  });
  test("a profile violation exits nonzero and names the rule", () => {
    const p = join(FIX_ANCHOR, "invalid", "clade-in-anchor_chora.deed");
    const r = cli("--anchor", p);
    expect(r.code).toBe(1);
    expect(r.out).toContain(`FAIL ${p}: (anchor …) has no field :clade`);
  });
  test("--anchor-fixtures passes on the anchor corpus", () => {
    const r = cli("--anchor-fixtures", FIX_ANCHOR);
    expect(r.code).toBe(0);
    expect(r.out).toContain("ANCHOR FIXTURES OK");
  });
  test("the opaque uuid literal keeps its body in --ast-json", () => {
    const r = cli("--ast-json", join(FIX_ANCHOR, "valid", "minimal_chora.deed"));
    const ast = JSON.parse(r.out);
    expect(ast.items.find((it) => it[1] === "repo-uuid")[2]).toEqual(["uuid", "00000000-0000-8000-8000-0000000000a7"]);
  });
});

// A7 J14 (deed.abnf v1.4.0): the three new heads, by exact, case-sensitive
// file name. MUSTFILE.deed and Meta.deed are tested here, not as fixtures,
// because a case-insensitive filesystem would fold them onto mustfile.deed.
describe("J14 file-name heads", () => {
  const form = (head) => `${HDR}(${head} :schema-version "1.0.0")\n`;
  const verbs = ["Intent", "Must", "Trust", "Adjust", "Dust", "Bust"];
  const names = ["META", "STATE", "ECOSYSTEM", "AGENTIC", "NEUROSYM", "PLAYBOOK", "CLADE",
    "INTENT", "MUST", "TRUST", "ADJUST", "DUST", "BUST"];
  test("every <Verb>file.deed is a contractile-deed", () => {
    for (const v of verbs) expect(verdict(form("contractile-deed"), `${v}file.deed`)).toBeNull();
  });
  test("every ALL-CAPS descriptile name is a descriptile-deed", () => {
    for (const n of names) expect(verdict(form("descriptile-deed"), `${n}.deed`)).toBeNull();
  });
  test("ANCHOR.deed and the anchor-deed head are gone (deed.abnf v2.0.0, A7 S1, J24)", () => {
    expect(verdict(form("repo-deed"), "ANCHOR.deed")).toMatch(/matches no deed dispatch pattern/);
    expect(verdict(form("anchor-deed"))).toMatch(/invalid doc-head/);
  });
  test("a wrong case matches no dispatch pattern", () => {
    for (const [f, h] of [["MUSTFILE.deed", "contractile-deed"], ["mustfile.deed", "contractile-deed"],
      ["Meta.deed", "descriptile-deed"], ["State.deed", "descriptile-deed"], ["anchor.deed", "repo-deed"],
      ["Clade.deed", "descriptile-deed"]]) {
      expect(verdict(form(h), f)).toMatch(/matches no deed dispatch pattern/);
    }
  });
  test("a J14 name with another head is a mismatch", () => {
    expect(verdict(form("descriptile-deed"), "Mustfile.deed")).toMatch(/dispatches to contractile-deed/);
    expect(verdict(form("contractile-deed"), "MUST.deed")).toMatch(/dispatches to descriptile-deed/);
    expect(verdict(form("descriptile-deed"), "x_chora.deed")).toMatch(/dispatches to repo-deed/);
  });
  test("a deed with no file name may carry any of the new heads", () => {
    for (const h of ["contractile-deed", "descriptile-deed"]) expect(verdict(form(h))).toBeNull();
  });
});

// A7 8.2: the (contractiles …) attestation clause (YC01 to YC05). The fixture
// corpus covers what the deed alone decides; --root checks that the named
// files exist (YC02, YC03), which needs a repo tree, so it is tested here.
const FIX_CONTRACTILES = join(FIX, "contractiles");

describe("contractiles fixtures", () => {
  test("valid/ passes and invalid/ fails the profile", () => {
    for (const [sub, ok] of [["valid", true], ["invalid", false]]) {
      const dir = join(FIX_CONTRACTILES, sub);
      const names = readdirSync(dir).filter((n) => n.endsWith(".deed"));
      expect(names.length).toBeGreaterThan(0);
      for (const n of names) {
        let got = true;
        try {
          checkContractiles(readFileSync(join(dir, n), "utf8"), join(dir, n));
        } catch (e) {
          if (!(e instanceof LintError)) throw e;
          got = false;
        }
        expect([n, got]).toEqual([n, ok]);
      }
    }
  });
  test("a deed without the clause is outside the profile", () => {
    const p = join(FIX_CONTRACTILES, "valid", "no-contractiles_chora.deed");
    expect(checkContractiles(readFileSync(p, "utf8"), p)).toBeNull();
  });
  test("the summary lists the six verbs", () => {
    const p = join(FIX_CONTRACTILES, "valid", "minimal_chora.deed");
    expect(checkContractiles(readFileSync(p, "utf8"), p).verbs.sort()).toEqual(Object.keys(CONTRACTILE_VERBS).sort());
  });
  test("intend takes Intentfile.deed and INTENT.deed", () => {
    expect(contractilePaths("intend")).toEqual({
      declaration: ".machine_readable/contractiles/intend/Intentfile.deed",
      runner: ".machine_readable/contractiles/intend/intend.k9.ncl",
      reality: ".machine_readable/descriptiles/INTENT.deed",
    });
  });
});

describe("contractiles --root (YC02, YC03)", () => {
  const deed = readFileSync(join(FIX_CONTRACTILES, "valid", "minimal_chora.deed"), "utf8");
  /** A repo tree holding every named file except those listed in `omit`. */
  function tree(omit = []) {
    const root = mkdtempSync(join(tmpdir(), "contractiles-"));
    for (const v of Object.keys(CONTRACTILE_VERBS)) {
      for (const [k, p] of Object.entries(contractilePaths(v))) {
        if (omit.includes(`${v}.${k}`)) continue;
        mkdirSync(join(root, dirname(p)), { recursive: true });
        writeFileSync(join(root, p), "");
      }
    }
    return root;
  }
  const run = (omit) => {
    const root = tree(omit);
    try {
      checkContractiles(deed, "x_chora.deed", { root });
      return null;
    } catch (e) {
      if (!(e instanceof ContractilesError)) throw e;
      return e.message;
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  };
  test("passes when all eighteen files exist", () => {
    expect(run([])).toBeNull();
  });
  test("declaration-missing-bad", () => {
    expect(run(["trust.declaration"])).toMatch(/\(verb :name trust\) :declaration ".*Trustfile.deed" does not exist .*\(YC02\)/);
  });
  test("no-runner-bad (the file)", () => {
    expect(run(["dust.runner"])).toMatch(/\(verb :name dust\) :runner .* does not exist .*\(YC02\)/);
  });
  test("reality-missing-bad / no-descriptile-bad", () => {
    expect(run(["intend.reality"])).toMatch(/\(verb :name intend\) :reality ".*INTENT.deed" does not exist .*\(YC03\)/);
  });
});

describe("CLI --contractiles", () => {
  test("reports a valid clause and a deed without one", () => {
    const a = join(FIX_CONTRACTILES, "valid", "minimal_chora.deed");
    const b = join(FIX_CONTRACTILES, "valid", "no-contractiles_chora.deed");
    const r = cli("--contractiles", a, b);
    expect(r.code).toBe(0);
    expect(r.out).toContain(`OK   ${a} (contractiles, 6 verbs)`);
    expect(r.out).toContain(`OK   ${b} (no contractiles clause)`);
  });
  test("--root names the missing file", () => {
    const a = join(FIX_CONTRACTILES, "valid", "minimal_chora.deed");
    const root = mkdtempSync(join(tmpdir(), "contractiles-"));
    try {
      const r = cli("--contractiles", "--root", root, a);
      expect(r.code).toBe(1);
      expect(r.out).toContain("does not exist under");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
  test("--root without a DIR is a usage error", () => {
    expect(cli("--contractiles", "--root").code).toBe(2);
  });
  test("--contractiles-fixtures passes on the corpus", () => {
    const r = cli("--contractiles-fixtures", FIX_CONTRACTILES);
    expect(r.code).toBe(0);
    expect(r.out).toContain("CONTRACTILES FIXTURES OK");
  });
});

// A7 J17 (deed.abnf v1.5.0): the bang token "!" marks a blocking rule. It may
// follow only the :id value of a top-level (rule …) in a contractile-deed.
describe("J17 bang", () => {
  const U = '#uuid"00000000-0000-8000-8000-0000000000a1"';
  const edict = (body) => `${HDR}(contractile-deed :schema-version "1.0.0" :canonical-name "x" :of-chora ${U} :verb must\n  ${body})\n`;
  test("a rule's :id may carry the bang, and the AST marks it", () => {
    const [, items] = validate(edict('(rule :id "m-a" ! :text "t")'), "Mustfile.deed");
    const id = items.find((it) => it[1] === "rule")[2].find((f) => f[1] === "id");
    expect(id).toEqual(["field", "id", ["string", "m-a"], true]);
  });
  test("a field without the bang keeps its three-element shape", () => {
    const [, items] = validate(edict('(rule :id "m-a" :text "t")'), "Mustfile.deed");
    expect(items.find((it) => it[1] === "rule")[2][0]).toEqual(["field", "id", ["string", "m-a"]]);
  });
  test("the bang may close the clause or follow a comment", () => {
    expect(verdict(edict('(rule :id "m-a" !)'), "Mustfile.deed")).toBeNull();
    expect(verdict(edict('(rule :id "m-a" ; why\n    ! :text "t")'), "Mustfile.deed")).toBeNull();
  });
  test("anywhere else it is refused", () => {
    const bad = /'!' is allowed only directly after a rule's :id value in a contractile-deed/;
    expect(verdict(edict('(rule :id "m-a" :text "t" !)'), "Mustfile.deed")).toMatch(bad);
    expect(verdict(edict('(group (rule :id "m-a" !))'), "Mustfile.deed")).toMatch(bad);
    expect(verdict(edict('(edict :id "m-a" !)'), "Mustfile.deed")).toMatch(bad);
    expect(verdict(`${HDR}(praxis-deed :schema-version "1.0.0"\n  (rule :id "p" !))\n`, "x_praxis.deed")).toMatch(bad);
  });
  test("a glued or doubled bang is not the token", () => {
    expect(verdict(edict('(rule :id "m-a"!)'), "Mustfile.deed")).toMatch(/needs a separator/);
    expect(verdict(edict('(rule :id "m-a" !x)'), "Mustfile.deed")).not.toBeNull();
    expect(verdict(edict('(rule :id "m-a" ! !)'), "Mustfile.deed")).not.toBeNull();
  });
  test("a symbol may still end in '!'", () => {
    expect(verdict(edict('(rule :id "m-a" :mode strict!)'), "Mustfile.deed")).toBeNull();
  });
});

// A7 8.1, 8.4, 8.5: the edict form of a contractile-deed (clauses/edict.abnf),
// and the J13 registry generated from the edicts (deed_lint.js --contractile-registry).
const FIX_EDICT = join(FIX, "edict");

describe("edict fixtures", () => {
  test("--edict-fixtures passes on the corpus", () => {
    const r = cli("--edict-fixtures", FIX_EDICT);
    expect(r.code).toBe(0);
    expect(r.out).toContain("EDICT FIXTURES OK");
  });
  test("a deed that is not a contractile-deed is outside the profile", () => {
    const p = join(FIX, "contractiles", "valid", "minimal_chora.deed");
    expect(checkEdict(readFileSync(p, "utf8"), p)).toBeNull();
  });
  test("the summary lists the rules and their bangs", () => {
    const p = join(FIX_EDICT, "valid", "adjust-sample", "Adjustfile.deed");
    const r = checkEdict(readFileSync(p, "utf8"), p);
    expect(r.verb).toBe("adjust");
    expect(r.rules.map((x) => [x.id, x.bang])).toEqual([["adj-alt-text", true], ["adj-contrast", false]]);
  });
  test("the file name fixes the verb, intend included", () => {
    expect(verbOfFilename("x/Intentfile.deed")).toBe("intend");
    expect(verbOfFilename("x/Intendfile.deed")).toBeNull();
    expect(verbOfFilename("x/Mustfile.deed")).toBe("must");
  });
  test("a clade selector is refused (W10)", () => {
    const p = join(FIX_EDICT, "invalid", "clade-selector", "Trustfile.deed");
    expect(() => checkEdict(readFileSync(p, "utf8"), p)).toThrow(EdictError);
  });
});

describe("contractile registry (J13)", () => {
  const root = join(FIX_EDICT, "registry", "root");
  const committed = join(root, ".machine_readable", "contractiles", "contractile_rules_praxis.deed");
  test("the committed fixture registry matches a fresh generation", () => {
    expect(generateRegistry(root, "metadatastician/standards")).toBe(readFileSync(committed, "utf8"));
  });
  test("class follows the verb and the bang; Bust carries the floor", () => {
    const t = generateRegistry(root, "metadatastician/standards");
    const [, items] = validate(t, "contractile_rules_praxis.deed");
    const defs = items.find((it) => it[1] === "rules")[2].map((d) => Object.fromEntries(d[2].map((f) => [f[1], f[2][1]])));
    const by = Object.fromEntries(defs.map((d) => [d.id, d]));
    expect(by["contractile/must/must-tests"].class).toBe("gate");
    expect(by["contractile/adjust/adj-alt-text"].class).toBe("gate");
    expect(by["contractile/adjust/adj-contrast"].class).toBe("advisory");
    expect(by["contractile/bust/bust-oob-parser"].floor).toBe("A7 8.5");
    expect(by["contractile/adjust/adj-contrast"].floor).toBeUndefined();
  });
  test("the committed fixture registry is its own fixed point", () => {
    const have = readFileSync(committed, "utf8");
    expect(generateRegistry(root, "metadatastician/standards", have)).toBe(have);
  });
  test("every one of the six edicts is required (J13)", () => {
    const tmp = mkdtempSync(join(tmpdir(), "registry-"));
    try {
      cpSync(root, tmp, { recursive: true });
      rmSync(join(tmp, ".machine_readable", "contractiles", "trust", "Trustfile.deed"));
      expect(() => generateRegistry(tmp, "metadatastician/standards")).toThrow(/missing: .*Trustfile\.deed/);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
  test("a rule that leaves the edicts is retired, not deleted, and its id is not reused (A5 3.2)", () => {
    const tmp = mkdtempSync(join(tmpdir(), "registry-"));
    try {
      cpSync(root, tmp, { recursive: true });
      const must = join(tmp, ".machine_readable", "contractiles", "must", "Mustfile.deed");
      const src = readFileSync(must, "utf8");
      const kept = src.replace(/\n  \(rule :id "must-fmt"[^\n]*\)$/m, ")");
      writeFileSync(must, kept);
      const first = generateRegistry(tmp, "metadatastician/standards", readFileSync(committed, "utf8"));
      const [, items] = validate(first, "contractile_rules_praxis.deed");
      const defs = items.find((it) => it[1] === "rules")[2].map((d) => Object.fromEntries(d[2].map((x) => [x[1], x[2][1]])));
      const by = Object.fromEntries(defs.map((d) => [d.id, d]));
      expect(by["contractile/must/must-fmt"].status).toBe("retired");
      expect(by["contractile/must/must-tests"].status).toBe("active");
      expect(generateRegistry(tmp, "metadatastician/standards", first)).toBe(first);
      writeFileSync(must, src);
      expect(() => generateRegistry(tmp, "metadatastician/standards", first)).toThrow(/never reused/);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
  test("--check fails when the registry is stale", () => {
    const tmp = mkdtempSync(join(tmpdir(), "registry-"));
    try {
      const out = join(tmp, "rules_praxis.deed");
      writeFileSync(out, "stale\n");
      const r = Bun.spawnSync(["bun", join(HERE, "deed_lint.js"), "--contractile-registry", "--root", root, "--out", out, "--check"]);
      expect(r.exitCode).toBe(1);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
});

// A7 7.3, 8.5: the six verb descriptiles (clauses/verb-descriptile.abnf).
const FIX_VD = join(FIX, "verb-descriptile");

describe("verb descriptile fixtures", () => {
  test("--verb-descriptile-fixtures passes on the corpus", () => {
    const r = cli("--verb-descriptile-fixtures", FIX_VD);
    expect(r.code).toBe(0);
    expect(r.out).toContain("VERB DESCRIPTILE FIXTURES OK");
  });
  test("the file name fixes the verb, INTENT included", () => {
    expect(verbOfDescriptile("x/INTENT.deed")).toBe("intend");
    expect(verbOfDescriptile("x/INTEND.deed")).toBeNull();
    expect(verbOfDescriptile("x/BUST.deed")).toBe("bust");
    expect(verbOfDescriptile("x/STATE.deed")).toBeNull();
  });
  test("another descriptile is outside the profile", () => {
    const t = readFileSync(join(FIX_VD, "valid", "dust-empty", "DUST.deed"), "utf8");
    expect(checkVerbDescriptile(t, "STATE.deed")).toBeNull();
  });
  test("the summary lists each fact's witness and evidence", () => {
    const p = join(FIX_VD, "valid", "adjust-expires", "ADJUST.deed");
    const r = checkVerbDescriptile(readFileSync(p, "utf8"), p);
    expect(r.verb).toBe("adjust");
    expect(r.facts).toEqual([{ witnesses: "adj-alt-text", evidence: "measured" }, { witnesses: "adj-contrast", evidence: "measured" }]);
  });
  test("with the edict's rule ids, an unknown witness is refused (YD02)", () => {
    const p = join(FIX_VD, "invalid", "witness-unknown", "MUST.deed");
    const t = readFileSync(p, "utf8");
    expect(checkVerbDescriptile(t, p).facts.length).toBe(1);
    expect(() => checkVerbDescriptile(t, p, { ruleIds: new Set(["must-tests", "must-fmt"]) })).toThrow(VerbDescriptileError);
  });
  test(":of-chora must equal the chora deed's :repo-uuid (YD08)", () => {
    const p = join(FIX_VD, "valid", "must-with-edict", "MUST.deed");
    const t = readFileSync(p, "utf8");
    expect(choraRepoUuid(join(FIX_VD, "valid", "must-with-edict"))).toBe("00000000-0000-8000-8000-0000000000a1");
    expect(checkVerbDescriptile(t, p, { repoUuid: "00000000-0000-8000-8000-0000000000a1" }).facts.length).toBe(2);
    expect(() => checkVerbDescriptile(t, p, { repoUuid: "00000000-0000-8000-8000-0000000000b2" })).toThrow(/YD08/);
  });
  test("--root without a directory is a usage error, not a skipped check", () => {
    const r = cli("--verb-descriptile", join(FIX_VD, "valid", "intent-basic", "INTENT.deed"), "--root");
    expect(r.code).toBe(2);
    expect(r.out).toContain("--root requires a DIR argument");
  });
  test("an empty --root is a usage error too", () => {
    const r = cli("--verb-descriptile", join(FIX_VD, "valid", "intent-basic", "INTENT.deed"), "--root", "");
    expect(r.code).toBe(2);
    expect(r.out).toContain("--root requires a DIR argument");
  });
  test("a Bust fact carries grades, not a value (8.5)", () => {
    const p = join(FIX_VD, "invalid", "bust-value", "BUST.deed");
    expect(() => checkVerbDescriptile(readFileSync(p, "utf8"), p)).toThrow(/no :value/);
  });
});

// A7 7.2, YD07: ECOSYSTEM.deed (clauses/ecosystem.abnf).
const FIX_ECO = join(FIX, "ecosystem");

describe("ecosystem fixtures", () => {
  test("--ecosystem-fixtures passes on the corpus", () => {
    const r = cli("--ecosystem-fixtures", FIX_ECO);
    expect(r.code).toBe(0);
    expect(r.out).toContain("ECOSYSTEM FIXTURES OK");
  });
  test("another descriptile is outside the profile", () => {
    const t = readFileSync(join(FIX_ECO, "valid", "minimal", "ECOSYSTEM.deed"), "utf8");
    expect(checkEcosystem(t, "STATE.deed")).toBeNull();
  });
  test("the closed relationship list has the 7 mapped terms and DESCRIPTILE-SPEC's 4", () => {
    expect(ECOSYSTEM_RELATIONSHIPS.size).toBe(11);
    for (const t of ["standard-source", "minted-from", "registry", "parent", "downstream-consumer"]) expect(ECOSYSTEM_RELATIONSHIPS.has(t)).toBe(true);
  });
  test("the summary lists project and related entries", () => {
    const p = join(FIX_ECO, "valid", "template-model", "ECOSYSTEM.deed");
    const r = checkEcosystem(readFileSync(p, "utf8"), p);
    expect(r.project).toBe("example-game");
    expect(r.related.map((x) => x.relationship)).toEqual(["standard-source", "minted-from", "registry"]);
  });
  test("strict mode requires (related :uuid) (J12)", () => {
    const p = join(FIX_ECO, "invalid", "strict-no-uuid", "ECOSYSTEM.deed");
    const t = readFileSync(p, "utf8");
    expect(checkEcosystem(t, p).related.length).toBe(1);
    expect(() => checkEcosystem(t, p, { strict: true })).toThrow(EcosystemError);
  });
  test(":project must equal the chora deed's :canonical-name with --root (YD07)", () => {
    const r = cli("--ecosystem", "--root", join(FIX_ECO, "invalid", "project-not-chora"), join(FIX_ECO, "invalid", "project-not-chora", "ECOSYSTEM.deed"));
    expect(r.code).toBe(1);
    expect(r.out).toContain("YD07");
  });
  test("--root without a directory is a usage error", () => {
    const r = cli("--ecosystem", join(FIX_ECO, "valid", "minimal", "ECOSYSTEM.deed"), "--root");
    expect(r.code).toBe(2);
  });
});
