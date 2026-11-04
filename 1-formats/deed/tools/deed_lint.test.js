// SPDX-License-Identifier: MPL-2.0
// bun test for deed_lint.js (port of deed_lint.py). Run: bun test 1-formats/deed/tools/
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { validate, LintError, SELF_TEST_CASES, checkEgress, EgressError, readMustfileChecks, MustfileError } from "./deed_lint.js";

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
  "inu7_chora.deed": /unrecognised #-form/,
  "inu8-empty-domain_chora.deed": /uuid8 domain '' must be non-empty/,
  "inu8-no-colon_chora.deed": /has no ":"/,
  "inu8-no-string_chora.deed": /uuid8 must be followed immediately by a string/,
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
    expect(() => readMustfileChecks(doc(':canonical-name "must" :beholding-chora #u5"estate/chora" ' + one), "test_praxis.deed")).not.toThrow();
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
