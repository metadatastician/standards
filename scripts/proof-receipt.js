#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// proof-receipt.js: write and check a proof receipt (PROOF-POLICY §8.5) from
// a hand-kept source file, the same way in every repository.
//
// A repository keeps one TOML *receipt source* that holds only what a person
// types: the claims and their legs, the run ledger (each row copied from the
// CI log of the run), the echoes of history rewrites, the prover's trusted
// base, and the rules that name each leg's input set. Everything else is
// derived here from git and written into the receipt:
//
//   * each current receipt's input set, (inputs-manifest …) and :inputs-sha256,
//     by the reference script scripts/proof-inputs-sha256.sh at the receipt's
//     :commit (§8.5.1), and the (import …) of each pinned sibling the Agda cone
//     reaches;
//   * each echo's witness digests at its source and its image, which must be
//     equal (§8.5.2);
//   * the :source-commit, the end of the echo chain from the current receipts;
//   * each claim's :pwg and :foundation-diverse, by deriveProofGrade, the
//     function the reader itself uses (§8.2 to §8.4). A grade is never typed.
//
// The written receipt is then read back by readProofReceipt, which must accept
// it. `check` regenerates the receipt and refuses any difference, refuses a
// current receipt whose inputs have changed since its run, runs the git checks
// of §8.5.3 (scripts/check-proof-receipt.sh) and a negative control on the
// reader.
//
// Usage:
//   bun scripts/proof-receipt.js write  [-C REPO] [--runs ROWS.toml] [--out FILE] SOURCE
//   bun scripts/proof-receipt.js check  [-C REPO] [--branch REF] [--at COMMIT] SOURCE
//   bun scripts/proof-receipt.js inputs [-C REPO] [--commit COMMIT] [--control PATH] SOURCE PROVER
//   bun scripts/proof-receipt.js digest [-C REPO] [--commit COMMIT] [--control PATH] SOURCE PROVER
//   bun scripts/proof-receipt.js row    [-C REPO] --prover P --run URL --commit SHA
//                                       --checker TEXT --invocation TEXT
//                                       [--reported TEXT] [--control PATH] SOURCE
//
//   REPO    the home repository (default: the git top level of the working
//           directory). Paths in SOURCE are relative to it.
//   --runs  rows of a run that just passed, as [[run]] tables: they become
//           current, and the earlier current receipt of each of their legs
//           becomes superseded. A CI job writes the receipt of its own run so.
//   row     print the [[run]] table of a run that just passed, with its
//           derived :inputs-sha256, to paste into the run ledger.
//
// The receipt source (TOML) is documented in
// 3-practice/PROOF-RECEIPT-SOURCE.adoc; scripts/tests/proof-receipt-test.sh
// tests this script on scratch repositories.
//
// Exit: 0 success; 1 the source, the tree or the receipt is wrong (each
// failure is named); 2 usage error or a tool is missing.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { dirname, join, resolve, isAbsolute } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  readProofReceipt, deriveProofGrade, PROOF_RECEIPT_VOCABULARY as V,
} from "../1-formats/deed/tools/deed_lint.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const DIGEST = join(HERE, "proof-inputs-sha256.sh");
const CHECKER = join(HERE, "check-proof-receipt.sh");
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const AGDA_EXTENSIONS = [".agda", ".lagda.md", ".lagda", ".lagda.tex", ".lagda.rst", ".lagda.org"];

class Refusal extends Error {}
class UsageError extends Error {}
const refuse = (m) => { throw new Refusal(m); };

// ── git ─────────────────────────────────────────────────────────────────────
const run = (cmd, opts = {}) => {
  const p = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe", ...opts });
  return { code: p.exitCode, out: p.stdout.toString(), err: p.stderr.toString() };
};
const git = (dir, ...args) => run(["git", "-C", dir, ...args]);
const haveCommit = (dir, c) => git(dir, "cat-file", "-e", `${c}^{commit}`).code === 0;

const treeCache = new Map();
/** The blob paths of COMMIT in DIR (gitlinks left out), as a Set. */
function treeAt(dir, commit) {
  const key = `${dir}\0${commit}`;
  if (treeCache.has(key)) return treeCache.get(key);
  const r = git(dir, "ls-tree", "-r", "-z", "--full-tree", commit);
  if (r.code !== 0) refuse(`cannot list the tree of ${commit} in ${dir}: ${r.err.trim()}`);
  const files = new Set();
  for (const entry of r.out.split("\0")) {
    if (!entry) continue;
    const tab = entry.indexOf("\t");
    const [, type] = entry.slice(0, tab).split(" ");
    if (type === "blob") files.add(entry.slice(tab + 1));
  }
  treeCache.set(key, files);
  return files;
}
function blobAt(dir, commit, path) {
  const r = git(dir, "cat-file", "blob", `${commit}:${path}`);
  if (r.code !== 0) refuse(`cannot read ${path} at ${commit} in ${dir}`);
  return r.out;
}
/** The §8.5.1 manifest of PATHS at COMMIT, by the reference script. */
function manifestAt(dir, commit, paths) {
  const r = run(["bash", DIGEST, "-C", dir, "--manifest", commit, ...paths]);
  if (r.code !== 0) refuse(`the reference digest script refused ${commit} in ${dir}: ${r.err.trim()}`);
  const files = r.out.split("\n").filter(Boolean).map((line) => {
    const m = /^([0-9a-f]{64})  (.+)$/.exec(line);
    if (!m) refuse(`unexpected manifest line from the reference script: ${line}`);
    return { path: m[2], sha256: m[1] };
  });
  return { files, digest: sha256(files.map((f) => `${f.sha256}  ${f.path}\n`).join("")) };
}
const sha256 = (text) => createHash("sha256").update(text, "utf8").digest("hex");
function treeDigestAt(dir, commit) {
  const r = run(["bash", DIGEST, "-C", dir, commit]);
  if (r.code !== 0) refuse(`the reference digest script refused ${commit} in ${dir}: ${r.err.trim()}`);
  return r.out.trim();
}

// ── The receipt source ──────────────────────────────────────────────────────
// A strict reader: an unknown key, a missing key or a value of the wrong type
// is refused, so a typo cannot drop a fact silently.
function fields(where, obj, spec) {
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) refuse(`${where} must be a table`);
  for (const k of Object.keys(obj)) if (!Object.hasOwn(spec, k)) refuse(`unknown key "${k}" in ${where}`);
  const out = {};
  for (const [k, [type, required, dflt]] of Object.entries(spec)) {
    if (!Object.hasOwn(obj, k)) {
      if (required) refuse(`${where} is missing "${k}"`);
      out[k] = dflt;
      continue;
    }
    const v = obj[k];
    const ok = type === "string" ? typeof v === "string" && v !== ""
      : type === "strings" ? Array.isArray(v) && v.every((x) => typeof x === "string" && x !== "")
        : type === "table" ? v !== null && typeof v === "object" && !Array.isArray(v)
          : type === "tables" ? Array.isArray(v) && v.every((x) => x !== null && typeof x === "object" && !Array.isArray(x))
            : false;
    if (!ok) refuse(`"${k}" in ${where} must be ${type === "strings" ? "an array of non-empty strings" : type === "tables" ? "an array of tables" : `a non-empty ${type}`}`);
    out[k] = v;
  }
  return out;
}
const RECHECK = ["rocq", "lean"]; // §2: every theorem is rechecked in both
const proverOrder = (a, b) => {
  const rank = (p) => (p === "agda" ? 0 : p === "rocq" ? 1 : p === "lean" ? 2 : 3);
  return rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0);
};
const PROVER = /^[a-z][a-z0-9-]*$/;

function readSource(path) {
  let raw;
  try { raw = Bun.TOML.parse(readFileSync(path, "utf8")); } catch (e) { refuse(`${path} is not TOML: ${e.message}`); }
  const top = fields(path, raw, {
    "schema-version": ["string", false, "1.0.0"],
    repository: ["string", true],
    receipt: ["string", true],
    "canonical-name": ["string", true],
    "default-branch": ["string", false, "main"],
    spdx: ["string", true],
    copyright: ["string", true],
    header: ["strings", false, []],
    "trusted-base": ["tables", false, []],
    inputs: ["table", true],
    claim: ["tables", true],
    run: ["tables", false, []],
    echo: ["tables", false, []],
  });
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(top.repository)) refuse(`repository must be OWNER/REPO, got "${top.repository}"`);
  const trustedBase = top["trusted-base"].map((t, i) => fields(`trusted-base[${i}]`, t, {
    prover: ["string", true], module: ["string", true], name: ["string", true], binding: ["string", true],
  }));

  const inputs = {};
  for (const [prover, spec] of Object.entries(top.inputs)) {
    if (!PROVER.test(prover)) refuse(`inputs.${prover}: a prover name is lowercase letters, digits and "-"`);
    const agda = prover === "agda";
    // Agda finds its files through include directories; any other prover's
    // files are named by glob patterns, at home and in each import.
    const p = fields(`inputs.${prover}`, spec, agda
      ? { roots: ["strings", true], include: ["strings", true], paths: ["strings", false, []], import: ["tables", false, []] }
      : { paths: ["strings", true], import: ["tables", false, []] });
    p.import = p.import.map((im, i) => {
      const where = `inputs.${prover}.import[${i}]`;
      const f = fields(where, im, {
        repository: ["string", true], commit: ["string", true], checkout: ["string", true],
        ...(agda ? { include: ["strings", true] } : { paths: ["strings", true] }), pin: ["table", false, null],
      });
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(f.repository)) refuse(`${where}: repository must be OWNER/REPO`);
      if (!HEX40.test(f.commit)) refuse(`${where}: commit must be the full 40-character lowercase commit`);
      if (f.pin) f.pin = fields(`${where}.pin`, f.pin, { file: ["string", true], pattern: ["string", true] });
      return f;
    });
    const repos = p.import.map((im) => im.repository.toLowerCase());
    if (new Set(repos).size !== repos.length) refuse(`inputs.${prover}: a repository is imported twice (one pin per repository)`);
    if (repos.includes(top.repository.toLowerCase())) refuse(`inputs.${prover}: a repository does not import itself`);
    inputs[prover] = p;
  }
  // Two provers may import one repository, but only at one pin and from one
  // checkout, because the git checks of §8.5.3 take one clone per repository.
  const pinOf = new Map();
  for (const p of Object.values(inputs)) for (const im of p.import) {
    const k = im.repository.toLowerCase(), v = `${im.commit} ${im.checkout}`;
    if (pinOf.has(k) && pinOf.get(k) !== v) refuse(`${im.repository} is imported at two pins or from two checkouts`);
    pinOf.set(k, v);
  }
  if (!inputs.agda) refuse("inputs.agda is required: every claim has an Agda leg (§8.5.1)");

  const ids = new Set();
  const claims = top.claim.map((c, i) => {
    const where = `claim[${i}]`;
    const known = { id: ["string", true], token: ["string", true], "agda-state": ["string", false, "AGDA-VERIFIED"], control: ["tables", false, []] };
    for (const k of Object.keys(c)) if (!Object.hasOwn(known, k) && PROVER.test(k) && k !== "agda") known[k] = ["table", false, null];
    const f = fields(where, c, known);
    if (ids.has(f.id)) refuse(`claim "${f.id}" is listed twice`);
    ids.add(f.id);
    if (!V.token.includes(f.token)) refuse(`claim "${f.id}": token "${f.token}" is not one of ${V.token.join(", ")}`);
    if (!V.state.includes(f["agda-state"])) refuse(`claim "${f.id}": agda-state "${f["agda-state"]}" is not a §2.2 state`);
    const legs = [];
    for (const prover of [...RECHECK, ...Object.keys(f).filter((k) => !Object.hasOwn({ id: 1, token: 1, "agda-state": 1, control: 1 }, k) && !RECHECK.includes(k))]) {
      if (!f[prover]) {
        if (RECHECK.includes(prover)) refuse(`claim "${f.id}" has no ${prover} leg: record it, as unavailable or waived with its reason if need be (§2, §8.5.1)`);
        continue;
      }
      const l = fields(`the ${prover} leg of claim "${f.id}"`, f[prover], {
        route: ["string", true], state: ["string", false, null], token: ["string", false, null], reason: ["string", false, null],
      });
      if (!V.route.includes(l.route) || l.route === "source") refuse(`claim "${f.id}": the ${prover} leg's route must be transported, re-proved, waived or unavailable`);
      const discharged = l.route === "transported" || l.route === "re-proved";
      if (discharged) {
        if (!l.state || !V.state.includes(l.state)) refuse(`claim "${f.id}": a ${l.route} ${prover} leg needs a §2.2 state`);
        if (l.reason) refuse(`claim "${f.id}": a ${l.route} ${prover} leg carries no reason`);
        if (l.token && !V.token.includes(l.token)) refuse(`claim "${f.id}": the ${prover} token "${l.token}" is not a §5 token`);
        if (!inputs[prover]) refuse(`claim "${f.id}": a ${l.route} ${prover} leg needs inputs.${prover}`);
      } else {
        if (!l.reason) refuse(`claim "${f.id}": a ${l.route} ${prover} leg needs a reason`);
        if (l.state || l.token) refuse(`claim "${f.id}": a ${l.route} ${prover} leg carries no state or token`);
      }
      // A RECONCILED re-proof or transport passed its kernel with no axiom
      // outside disposition (c) (the leg gate refuses any), so it is proven;
      // any other state is open, unless the source says otherwise.
      legs.push({ prover, ...l, token: discharged ? (l.token ?? (l.state === "RECONCILED" ? "proven" : "open")) : null });
    }
    const controls = f.control.map((k, j) => {
      const kf = fields(`${where}.control[${j}]`, k, { path: ["string", true], prover: ["string", true] });
      if (!inputs[kf.prover]) refuse(`claim "${f.id}": a ${kf.prover} control needs inputs.${kf.prover}`);
      return kf;
    });
    return { id: f.id, token: f.token, agdaState: f["agda-state"], legs, controls };
  });
  if (claims.length === 0) refuse("the source lists no [[claim]]");

  const runs = top.run.map((r, i) => readRun(`run[${i}]`, r, ids));
  const echoes = top.echo.map((e, i) => {
    const f = fields(`echo[${i}]`, e, {
      source: ["string", true], image: ["string", true], witness: ["string", true], fetch: ["string", false, null],
    });
    if (!HEX40.test(f.source) || !HEX40.test(f.image)) refuse(`echo[${i}]: source and image must be full 40-character lowercase commits`);
    if (f.source === f.image) refuse(`echo[${i}] joins a commit to itself`);
    if (!V.echoWitness.includes(f.witness)) refuse(`echo[${i}]: witness must be one of ${V.echoWitness.join(", ")}`);
    if (f.fetch && !f.fetch.startsWith("refs/")) refuse(`echo[${i}]: fetch must be a forge reference (refs/…)`);
    return f;
  });
  if (new Set(echoes.map((e) => e.source)).size !== echoes.length) refuse("an echo source has two images (the rewrite is a function)");
  return { ...top, trustedBase, inputs, claims, runs, echoes };
}

function readRun(where, r, ids) {
  const f = fields(where, r, {
    prover: ["string", true], run: ["string", true], commit: ["string", true], checker: ["string", true],
    invocation: ["string", true], state: ["string", true], reason: ["string", false, null],
    reported: ["string", false, null], "inputs-sha256": ["string", false, null], axioms: ["tables", false, []],
    control: ["string", false, null], claims: ["strings", false, null],
  });
  if (!PROVER.test(f.prover)) refuse(`${where}: unknown prover "${f.prover}"`);
  if (!HEX40.test(f.commit)) refuse(`${where}: commit must be the full 40-character lowercase commit`);
  if (!V.receiptState.includes(f.state)) refuse(`${where}: state must be one of ${V.receiptState.join(", ")}`);
  if (f.state === "current" && f.reason) refuse(`${where}: a current run carries no reason`);
  if (f.state !== "current" && !f.reason) refuse(`${where}: a ${f.state} run needs a reason`);
  if (f["inputs-sha256"] && !HEX64.test(f["inputs-sha256"])) refuse(`${where}: inputs-sha256 must be 64 lowercase hex digits`);
  for (const id of f.claims ?? []) if (ids && !ids.has(id)) refuse(`${where}: claim "${id}" is not in the source`);
  f.axioms = f.axioms.map((a, j) => {
    const af = fields(`${where}.axioms[${j}]`, a, { name: ["string", true], disposition: ["string", true] });
    if (!V.disposition.includes(af.disposition)) refuse(`${where}: axiom "${af.name}" disposition must be one of ${V.disposition.join(", ")}`);
    return af;
  });
  return f;
}

// ── Input sets (§8.5.1) ─────────────────────────────────────────────────────
// Agda: the cone of the roots through the include directories, scanned from
// the files at the commit. A module found in no include directory must be one
// the prover supplies (Agda.*); any other is refused. The scan strips nested
// block comments and pragmas, and line comments; a gate that has Agda checks
// the cone against `agda --dependency-graph`.
function stripAgdaComments(text) {
  let out = "", depth = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.startsWith("{-", i)) { depth++; i++; continue; }
    if (depth > 0 && text.startsWith("-}", i)) { depth--; i++; continue; }
    if (depth === 0) out += text[i];
    else if (text[i] === "\n") out += "\n";
  }
  return out.split("\n").map((l) => l.replace(/(^|\s)--+(?=$|[\s\p{L}\p{N}_'"(])[^\n]*$/u, "$1")).join("\n");
}
const IMPORT = /(?:^|[\s;{}()])import\s+([^\s;{}()]+)/gu;
function importsOf(text) {
  return [...stripAgdaComments(text).matchAll(IMPORT)].map((m) => m[1]);
}

/** The Agda input set at COMMIT: { home: [path], imports: [{ config, paths }] }. */
function agdaInputs(ctx, commit, roots) {
  const a = ctx.src.inputs.agda;
  const homeTree = treeAt(ctx.repo, commit);
  const places = [
    ...a.include.map((dir) => ({ where: "home", dir: dir.replace(/\/$/, ""), tree: homeTree, gitDir: ctx.repo, commit })),
    ...a.import.flatMap((im) => {
      const { gitDir, tree } = importTree(ctx, im);
      return im.include.map((dir) => ({ where: im, dir: dir.replace(/\/$/, ""), tree, gitDir, commit: im.commit }));
    }),
  ];
  const home = new Set();
  const byImport = new Map(a.import.map((im) => [im, new Set()]));
  const seen = new Set();
  const queue = [];
  for (const r of roots) {
    if (!homeTree.has(r)) refuse(`the Agda root ${r} is not a file at ${commit}`);
    queue.push({ place: { where: "home", gitDir: ctx.repo, commit }, path: r });
  }
  while (queue.length) {
    const { place, path } = queue.shift();
    const key = `${place.gitDir}\0${path}`;
    if (seen.has(key)) continue;
    seen.add(key);
    (place.where === "home" ? home : byImport.get(place.where)).add(path);
    for (const mod of importsOf(blobAt(place.gitDir, place.commit, path))) {
      const rel = mod.split(".").join("/");
      const hits = [];
      for (const p of places) for (const ext of AGDA_EXTENSIONS) {
        const cand = `${p.dir === "." || p.dir === "" ? "" : `${p.dir}/`}${rel}${ext}`;
        if (p.tree.has(cand)) hits.push({ place: p, path: cand });
      }
      if (hits.length > 1) refuse(`module ${mod} (imported by ${path}) resolves to more than one file: ${hits.map((h) => h.path).join(", ")}`);
      if (hits.length === 0) {
        if (mod === "Agda" || mod.startsWith("Agda.")) continue; // supplied with the prover (§8.4)
        refuse(`module ${mod} (imported by ${path}) is in no include directory at ${commit}`);
      }
      queue.push(hits[0]);
    }
  }
  for (const p of globPaths(homeTree, a.paths, commit, "inputs.agda.paths")) home.add(p);
  return {
    home: [...home].sort(byteOrder),
    imports: a.import.filter((im) => byImport.get(im).size).map((im) => ({ config: im, paths: [...byImport.get(im)].sort(byteOrder) })),
  };
}
/** The clone of an imported repository, which must hold its pinned commit. */
function importTree(ctx, im) {
  const gitDir = resolve(ctx.repo, im.checkout);
  if (!existsSync(gitDir)) refuse(`the checkout of ${im.repository} is missing at ${im.checkout}: fetch it at ${im.commit} first`);
  if (!haveCommit(gitDir, im.commit)) refuse(`the checkout ${im.checkout} does not hold ${im.repository} at ${im.commit}`);
  return { gitDir, tree: treeAt(gitDir, im.commit) };
}
const byteOrder = (x, y) => Buffer.compare(Buffer.from(x, "utf8"), Buffer.from(y, "utf8"));
function globPaths(tree, patterns, commit, where) {
  const out = new Set();
  for (const pat of patterns) {
    const g = new Bun.Glob(pat);
    let n = 0;
    for (const p of tree) if (g.match(p)) { out.add(p); n++; }
    if (n === 0) refuse(`${where}: "${pat}" matches no file at ${commit}`);
  }
  return [...out];
}

/** The input set of PROVER at COMMIT (of a control when CONTROL is a path). */
function inputSet(ctx, prover, commit, control = null) {
  const spec = ctx.src.inputs[prover];
  if (!spec) refuse(`the source has no inputs.${prover}`);
  if (prover === "agda") {
    const roots = control ? [control] : spec.roots;
    return agdaInputs(ctx, commit, roots);
  }
  const tree = treeAt(ctx.repo, commit);
  const paths = new Set(globPaths(tree, spec.paths, commit, `inputs.${prover}.paths`));
  if (control) {
    if (!tree.has(control)) refuse(`the control ${control} is not a file at ${commit}`);
    paths.add(control);
  }
  const imports = spec.import.map((im) => ({
    config: im,
    paths: globPaths(importTree(ctx, im).tree, im.paths, `${im.repository}@${im.commit}`, `inputs.${prover}.import ${im.repository}`).sort(byteOrder),
  }));
  return { home: [...paths].sort(byteOrder), imports };
}

/** Make COMMIT available in the home clone, fetching REF when it is not. */
function ensureCommit(ctx, commit, ref) {
  if (haveCommit(ctx.repo, commit)) return;
  if (!ref) refuse(`commit ${commit} is not in ${ctx.repo} and no forge reference keeps it (add fetch = "refs/pull/<n>/head" to its echo)`);
  const r = git(ctx.repo, "fetch", "-q", "origin", `+${ref}:refs/remotes/origin/receipt-fetch/${commit.slice(0, 12)}`);
  if (r.code !== 0 || !haveCommit(ctx.repo, commit)) refuse(`cannot fetch ${commit} by ${ref}: ${r.err.trim()}`);
}

/** The evidence of one current receipt: its manifest, digest and imports. */
function evidence(ctx, prover, commit, control) {
  const key = `${prover}\0${commit}\0${control ?? ""}`;
  if (ctx.evidence.has(key)) return ctx.evidence.get(key);
  const set = inputSet(ctx, prover, commit, control);
  const manifest = manifestAt(ctx.repo, commit, set.home);
  const imports = set.imports.map(({ config, paths }) => {
    if (config.pin) {
      const text = blobAt(ctx.repo, commit, config.pin.file);
      const m = new RegExp(config.pin.pattern, "u").exec(text);
      if (!m || !m[1]) refuse(`the pin pattern of ${config.repository} finds no commit in ${config.pin.file} at ${commit}`);
      if (m[1] !== config.commit) refuse(`${config.pin.file} pins ${config.repository} at ${m[1]} at ${commit}, but the source says ${config.commit}`);
      if (!set.home.includes(config.pin.file)) refuse(`${config.pin.file} holds the pin of ${config.repository}, so it must be in the ${prover} input set (add it to inputs.${prover}.paths, §8.5.1)`);
    }
    const m = manifestAt(resolve(ctx.repo, config.checkout), config.commit, paths);
    return { repository: config.repository, commit: config.commit, digest: m.digest, files: m.files };
  });
  const ev = { manifest: manifest.files, digest: manifest.digest, imports };
  ctx.evidence.set(key, ev);
  return ev;
}

// ── Derive ──────────────────────────────────────────────────────────────────
function ledger(src, extra) {
  const rows = [...src.runs];
  for (const x of extra) {
    if (x.state !== "current") refuse(`a --runs row must be current: ${x.run}`);
    for (const r of rows) {
      if (r.state === "current" && r.prover === x.prover && (r.control ?? null) === (x.control ?? null)) {
        r.state = "superseded";
        r.reason = `replaced by the later run ${x.run}`;
      }
    }
  }
  return [...extra, ...rows];
}

function derive(ctx, extraRuns = [], fallbackCommit = null) {
  const src = ctx.src;
  const rows = ledger(src, extraRuns);
  // One current receipt per leg and per control.
  const currentOf = new Map();
  for (const r of rows.filter((r) => r.state === "current")) {
    const key = `${r.prover}\0${r.control ?? ""}`;
    if (currentOf.has(key)) refuse(`the ${r.prover}${r.control ? ` control ${r.control}` : " leg"} has more than one current run`);
    currentOf.set(key, r);
  }
  const fetchRef = new Map(src.echoes.filter((e) => e.fetch).map((e) => [e.source, e.fetch]));
  // Echoes: the witness must hold, so the digests are computed at both ends.
  const echoOf = new Map(src.echoes.map((e) => [e.source, e]));
  const echoes = src.echoes.map((e) => {
    ensureCommit(ctx, e.source, e.fetch);
    ensureCommit(ctx, e.image, `refs/heads/${src["default-branch"]}`);
    const rec = { source: e.source, image: e.image, witness: e.witness, fetch: e.fetch, tree_sha256: null, inputs: {} };
    if (e.witness === "tree-sha256") {
      const a = treeDigestAt(ctx.repo, e.source), b = treeDigestAt(ctx.repo, e.image);
      if (a !== b) refuse(`echo ${e.source} -> ${e.image}: the trees differ (${a} at the source, ${b} at the image)`);
      rec.tree_sha256 = a;
    } else {
      for (const p of Object.keys(src.inputs).sort(proverOrder)) {
        const a = manifestAt(ctx.repo, e.source, inputSet(ctx, p, e.source).home).digest;
        const b = manifestAt(ctx.repo, e.image, inputSet(ctx, p, e.image).home).digest;
        if (a !== b) refuse(`echo ${e.source} -> ${e.image}: the ${p} inputs differ (${a} at the source, ${b} at the image)`);
        rec.inputs[p] = a;
      }
    }
    return rec;
  });
  // Each current receipt's evidence, at its commit.
  for (const r of currentOf.values()) {
    ensureCommit(ctx, r.commit, fetchRef.get(r.commit));
    const ev = evidence(ctx, r.prover, r.commit, r.control);
    if (r["inputs-sha256"] && r["inputs-sha256"] !== ev.digest) {
      refuse(`run ${r.run}: the ${r.prover} inputs digest it records (${r["inputs-sha256"]}) is not the digest at ${r.commit} (${ev.digest})`);
    }
    r.evidence = ev;
  }
  // The :source-commit: where the echo chain from the current leg receipts ends.
  const ends = new Set();
  for (const r of currentOf.values()) {
    if (r.control) continue;
    let c = r.commit;
    for (let steps = 0; echoOf.has(c); steps++) {
      if (steps > echoOf.size) refuse("the echoes form a cycle");
      c = echoOf.get(c).image;
    }
    ends.add(c);
  }
  if (ends.size > 1) refuse(`the current receipts describe different commits: ${[...ends].join(", ")}`);
  const sourceCommit = [...ends][0] ?? fallbackCommit;
  if (!sourceCommit || !HEX40.test(sourceCommit)) refuse("no current receipt names a commit; give --source-commit");

  const receiptsFor = (prover, id, control = null) => {
    const mine = rows.filter((r) => r.prover === prover && (r.control ?? null) === control
      && (control !== null || !r.claims || r.claims.includes(id)));
    return [...mine.filter((r) => r.state === "current"), ...mine.filter((r) => r.state !== "current")];
  };
  const claims = src.claims.map((c) => {
    const legs = [
      { prover: "agda", route: "source", token: c.token, state: c.agdaState, reason: null, receipts: receiptsFor("agda", c.id) },
      ...c.legs.map((l) => ({ ...l, receipts: l.route === "transported" || l.route === "re-proved" ? receiptsFor(l.prover, c.id) : [] })),
    ];
    const model = legs.map((l) => ({
      ...l,
      receipts: l.receipts.map((r) => ({ state: r.state, commit: r.commit, invocation: r.invocation, axioms: r.axioms, "inputs-sha256": r.evidence?.digest })),
    }));
    const { pwg, foundation_diverse } = deriveProofGrade(model, sourceCommit, echoes);
    const controls = c.controls.map((k) => {
      const receipts = receiptsFor(k.prover, c.id, k.path);
      if (receipts.length === 0) refuse(`claim "${c.id}": the control ${k.path} has no run`);
      return { ...k, receipts };
    });
    return { id: c.id, pwg, foundation_diverse, legs, controls };
  });
  for (const r of rows) {
    if (r.control && !src.claims.some((c) => c.controls.some((k) => k.path === r.control && k.prover === r.prover))) {
      refuse(`run ${r.run} is of the control ${r.control}, which no claim declares`);
    }
  }
  return { sourceCommit, echoes, claims, rows, currentOf };
}

// ── Emit ────────────────────────────────────────────────────────────────────
const str = (s) => {
  if (/[\r\u0000-\u0008\u000b-\u001f\u007f]/.test(s)) refuse(`a value holds a control character: ${JSON.stringify(s)}`);
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\t/g, "\\t")}"`;
};
const comment = (s) => {
  if (/[\n\r]/.test(s)) refuse(`a comment holds a line break: ${JSON.stringify(s)}`);
  return s;
};
/** The lines of one (receipt …), its closing parenthesis included. */
function receiptLines(r) {
  const L = [];
  const I = "               ";
  if (r.reported) L.push(`      ; the run reported: ${comment(r.reported)}`);
  L.push(`      (receipt :run ${str(r.run)}`);
  L.push(`${I}:commit ${str(r.commit)}`);
  L.push(`${I}:checker ${str(r.checker)}`);
  L.push(`${I}:invocation ${str(r.invocation)}`);
  if (r.state === "current") {
    L.push(`${I}:inputs-sha256 ${str(r.evidence.digest)}`);
    L.push(`${I}:state current`);
    L.push(`${I}(inputs-manifest`);
    r.evidence.manifest.forEach((f, i, a) => L.push(`${I}  (file :path ${str(f.path)} :sha256 ${str(f.sha256)})${i === a.length - 1 ? ")" : ""}`));
    for (const im of r.evidence.imports) {
      L.push(`${I}(import :repository ${str(im.repository)} :commit ${str(im.commit)} :inputs-sha256 ${str(im.digest)}`);
      im.files.forEach((f, i, a) => L.push(`${I}  (file :path ${str(f.path)} :sha256 ${str(f.sha256)})${i === a.length - 1 ? ")" : ""}`));
    }
    if (r.axioms.length === 0) L.push(`${I}(axioms))`);
    else {
      L.push(`${I}(axioms`);
      r.axioms.forEach((a, i, all) => L.push(`${I}  (axiom :name ${str(a.name)} :disposition ${a.disposition})${i === all.length - 1 ? "))" : ""}`));
    }
  } else {
    L.push(`${I}:state ${r.state}`);
    L.push(`${I}:reason ${str(r.reason)})`);
  }
  return L;
}
/** Close the last line of LINES with CLOSE. */
const close = (lines, c) => { lines[lines.length - 1] += c; return lines; };

function emit(src, d) {
  const L = [];
  L.push(`;; SPDX-License-Identifier: ${comment(src.spdx)}`);
  L.push(`;; SPDX-FileCopyrightText: ${comment(src.copyright)}`);
  for (const h of src.header) L.push(`;; ${comment(h)}`.trimEnd());
  L.push("(praxis-deed");
  L.push(`  :schema-version ${str(src["schema-version"])}`);
  L.push(`  :canonical-name ${str(src["canonical-name"])}`);
  L.push("  :profile proof-receipt");
  L.push(`  :repository ${str(src.repository)}`);
  L.push(`  :source-commit ${str(d.sourceCommit)}`);
  if (src.trustedBase.length) {
    L.push("  (trusted-base");
    src.trustedBase.forEach((t, i, a) => L.push(`    (primitive :prover ${t.prover} :module ${str(t.module)} :name ${str(t.name)} :binding ${str(t.binding)})${i === a.length - 1 ? ")" : ""}`));
  }
  for (const e of d.echoes) {
    L.push(`  ; ${e.source.slice(0, 12)} was rewritten into ${e.image.slice(0, 12)} on ${src["default-branch"]}${e.fetch ? `; ${e.fetch} keeps it` : ""}.`);
    if (e.witness === "tree-sha256") {
      L.push(`  (echo :source ${str(e.source)} :image ${str(e.image)} :witness tree-sha256 :tree-sha256 ${str(e.tree_sha256)})`);
    } else {
      L.push(`  (echo :source ${str(e.source)} :image ${str(e.image)} :witness inputs-sha256`);
      close(Object.entries(e.inputs).map(([p, s]) => `    (inputs :prover ${p} :sha256 ${str(s)})`), ")").forEach((l) => L.push(l));
    }
  }
  for (const c of d.claims) {
    L.push(`  (claim :id ${str(c.id)} :pwg ${c.pwg} :foundation-diverse ${c.foundation_diverse ? "#t" : "#f"}`);
    const parts = [];
    for (const l of c.legs) {
      if (l.route === "waived" || l.route === "unavailable") {
        parts.push([`    (leg :prover ${l.prover} :route ${l.route} :reason ${str(l.reason)})`]);
        continue;
      }
      const head = `    (leg :prover ${l.prover} :route ${l.route} :token ${l.token} :state ${l.state}`;
      parts.push(l.receipts.length ? [head, ...close(l.receipts.flatMap(receiptLines), ")")] : [`${head})`]);
    }
    for (const k of c.controls) {
      parts.push([`    (control :path ${str(k.path)} :prover ${k.prover} :expect refused`,
        ...close(k.receipts.flatMap(receiptLines), ")")]);
    }
    close(parts[parts.length - 1], ")");
    for (const p of parts) L.push(...p);
  }
  L.push(")");
  return L.join("\n") + "\n";
}

// ── Modes ───────────────────────────────────────────────────────────────────
function context(opts, sourcePath) {
  let repo = opts.repo;
  if (!repo) {
    const r = run(["git", "rev-parse", "--show-toplevel"]);
    if (r.code !== 0) throw new UsageError("not in a git repository; give -C REPO");
    repo = r.out.trim();
  }
  repo = resolve(repo);
  if (git(repo, "rev-parse", "--git-dir").code !== 0) throw new UsageError(`${repo} is not a git clone`);
  return { repo, src: readSource(sourcePath), evidence: new Map() };
}
const readRuns = (path) => {
  let raw;
  try { raw = Bun.TOML.parse(readFileSync(path, "utf8")); } catch (e) { refuse(`${path} is not TOML: ${e.message}`); }
  const top = fields(path, raw, { run: ["tables", true] });
  return top.run.map((r, i) => readRun(`${path} run[${i}]`, r, null));
};
const receiptPath = (ctx, opts) => (opts.out ? resolve(opts.out) : resolve(ctx.repo, ctx.src.receipt));
const HEAD = (ctx) => git(ctx.repo, "rev-parse", "HEAD").out.trim();

function generate(ctx, opts, fallback) {
  const d = derive(ctx, opts.runs ? readRuns(opts.runs) : [], fallback);
  const text = emit(ctx.src, d);
  let read;
  try { read = readProofReceipt(text, "receipt_praxis.deed"); } catch (e) { refuse(`the reader refuses the generated receipt: ${e.message ?? e}`); }
  for (const c of d.claims) {
    const r = read.claims.find((x) => x.id === c.id);
    if (!r || r.pwg !== c.pwg) refuse(`the reader derives another grade for claim "${c.id}"`);
  }
  return { d, text, read };
}

function modeWrite(ctx, opts) {
  const { d, text, read } = generate(ctx, opts, opts.sourceCommit ?? HEAD(ctx));
  const out = receiptPath(ctx, opts);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, text);
  console.log(`WROTE ${out} (source-commit ${d.sourceCommit})`);
  for (const c of read.claims) console.log(`  ${c.id}  ${c.pwg}  foundation-diverse ${c.foundation_diverse}`);
}

function modeCheck(ctx, opts) {
  const out = receiptPath(ctx, opts);
  if (!existsSync(out)) refuse(`${out} is missing: write it first`);
  const have = readFileSync(out, "utf8");
  const recorded = /^\s*:source-commit "([0-9a-f]{40})"/m.exec(have)?.[1] ?? null;
  const { d, text } = generate(ctx, opts, recorded);
  let failures = 0;
  const fail = (m) => { failures++; console.log(`FAIL ${m}`); };
  const ok = (m) => console.log(`ok   ${m}`);
  if (have === text) ok(`${out} is what the source and the tree give`);
  else {
    fail(`${out} is not what the source and the tree give: regenerate with \`proof-receipt.js write\``);
    const tmp = mkdtempSync(join(tmpdir(), "proof-receipt-"));
    writeFileSync(join(tmp, "want"), text);
    console.log(run(["diff", "-u", out, join(tmp, "want")]).out.split("\n").slice(0, 40).map((l) => `     ${l}`).join("\n"));
    rmSync(tmp, { recursive: true, force: true });
  }
  // Currency: each current leg receipt still describes the tree at --at.
  const at = opts.at ?? HEAD(ctx);
  for (const r of d.currentOf.values()) {
    if (r.control) continue;
    const now = evidence(ctx, r.prover, at, null);
    const what = `the ${r.prover} receipt of run ${r.run}`;
    if (now.digest !== r.evidence.digest) {
      fail(`${what}: the inputs changed since that run (recorded ${r.evidence.digest}, ${at.slice(0, 12)} gives ${now.digest}); record a new run, or mark the row superseded or regressed with its reason`);
      continue;
    }
    const dirty = git(ctx.repo, "status", "--porcelain", "--", ...now.manifest.map((f) => f.path)).out.trim();
    if (at === HEAD(ctx) && dirty) fail(`${what}: inputs differ from HEAD in the working tree:\n${dirty}`);
    else ok(`${what} describes ${at.slice(0, 12)}`);
  }
  // §8.5.3, by the shared checker.
  const branchRef = opts.branch
    ?? [`refs/remotes/origin/${ctx.src["default-branch"]}`, `refs/heads/${ctx.src["default-branch"]}`]
      .find((r) => git(ctx.repo, "rev-parse", "-q", "--verify", r).code === 0) ?? "HEAD";
  const importClones = new Map(Object.values(ctx.src.inputs).flatMap((p) => p.import).map((im) => [im.repository.toLowerCase(), `${im.repository}=${resolve(ctx.repo, im.checkout)}`]));
  const imports = [...importClones.values()].flatMap((x) => ["--import", x]);
  const chk = run(["bash", CHECKER, "--branch", branchRef, ...imports, out, ctx.repo]);
  process.stdout.write(chk.out.split("\n").filter(Boolean).map((l) => `     ${l}\n`).join(""));
  if (chk.code === 0) ok(`the git checks of §8.5.3 hold (--branch ${branchRef})`);
  else fail(`the git checks of §8.5.3 fail: ${chk.err.trim() || "see above"}`);
  // Negative control: the first claim with another grade must be refused.
  const first = d.claims[0];
  const wrong = first.pwg === "PWG-1" ? "PWG-2ii" : "PWG-1";
  const forged = text.replace(/:pwg [A-Za-z0-9-]+/, `:pwg ${wrong}`);
  try {
    readProofReceipt(forged, "control_praxis.deed");
    fail(`negative control: the reader accepted claim "${first.id}" recorded as :pwg ${wrong}`);
  } catch (e) {
    if (String(e.message ?? e).includes("records :pwg")) ok(`negative control: claim "${first.id}" recorded as :pwg ${wrong} is refused (its legs support ${first.pwg})`);
    else fail(`negative control: refused for another reason: ${e.message ?? e}`);
  }
  if (failures) { console.log(`proof-receipt check: ${failures} check(s) failed`); return 1; }
  console.log(`proof-receipt check: every check holds (source-commit ${d.sourceCommit})`);
  return 0;
}

function modeInputs(ctx, opts, prover, digestOnly) {
  const commit = opts.commit ?? HEAD(ctx);
  if (digestOnly) { console.log(evidence(ctx, prover, commit, opts.control).digest); return; }
  const set = inputSet(ctx, prover, commit, opts.control);
  for (const p of set.home) console.log(p);
  for (const im of set.imports) for (const p of im.paths) console.log(`${im.config.repository}@${im.config.commit}:${p}`);
}

function modeRow(ctx, opts) {
  for (const k of ["prover", "run", "commit", "checker", "invocation"]) if (!opts[k]) throw new UsageError(`row needs --${k}`);
  if (!HEX40.test(opts.commit)) refuse("--commit must be the full 40-character lowercase commit");
  const ev = evidence(ctx, opts.prover, opts.commit, opts.control);
  const q = (s) => JSON.stringify(s);
  const lines = ["[[run]]", `prover = ${q(opts.prover)}`, `run = ${q(opts.run)}`, `commit = ${q(opts.commit)}`,
    `checker = ${q(opts.checker)}`, `invocation = ${q(opts.invocation)}`, `inputs-sha256 = ${q(ev.digest)}`];
  if (opts.reported) lines.push(`reported = ${q(opts.reported)}`);
  if (opts.control) lines.push(`control = ${q(opts.control)}`);
  lines.push('state = "current"', "axioms = []");
  // The row must read back as a run.
  readRun("the printed row", Bun.TOML.parse(lines.slice(1).join("\n")), null);
  console.log(lines.join("\n"));
}

function main(argv) {
  const mode = argv[0];
  const opts = {};
  const pos = [];
  const valued = new Set(["-C", "--runs", "--out", "--branch", "--at", "--commit", "--control", "--prover", "--run",
    "--checker", "--invocation", "--reported", "--source-commit"]);
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (valued.has(a)) {
      if (i + 1 >= argv.length) throw new UsageError(`${a} needs a value`);
      const v = argv[++i];
      const key = a === "-C" ? "repo" : a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      opts[key] = v;
    } else if (a.startsWith("-")) throw new UsageError(`unknown option ${a}`);
    else pos.push(a);
  }
  const need = { write: 1, check: 1, inputs: 2, digest: 2, row: 1 }[mode];
  if (!need || pos.length !== need) throw new UsageError("usage: proof-receipt.js write|check|inputs|digest|row [options] SOURCE [PROVER] (see the header of scripts/proof-receipt.js)");
  const ctx = context(opts, isAbsolute(pos[0]) ? pos[0] : resolve(pos[0]));
  switch (mode) {
    case "write": modeWrite(ctx, opts); return 0;
    case "check": return modeCheck(ctx, opts);
    case "inputs": modeInputs(ctx, opts, pos[1], false); return 0;
    case "digest": modeInputs(ctx, opts, pos[1], true); return 0;
    case "row": modeRow(ctx, opts); return 0;
  }
  return 2;
}

for (const tool of ["git", "bash", "sha256sum"]) {
  if (!Bun.which(tool)) { console.error(`cannot run: ${tool} is not installed`); process.exit(2); }
}
try {
  process.exit(main(process.argv.slice(2)));
} catch (e) {
  if (e instanceof UsageError) { console.error(e.message); process.exit(2); }
  if (e instanceof Refusal) { console.error(`ERROR: ${e.message}`); process.exit(1); }
  throw e;
}
