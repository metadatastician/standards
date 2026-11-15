// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
// hypatia: allow cicd_rules/javascript_detected -- Bun/GitHub JSON reporting boundary; zero dependencies.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

export const VERSION = 1;
const titles = { deed: 'DEED syntax', typecheck: 'K9 contract typecheck', selftest: 'K9 validator self-test', fixtures: 'K9 positive/negative controls', corpus: 'K9 live corpus (L0–L2)' };
const marker = '<!-- k9-contractile-report: regenerated on every run -->';
const clean = s => String(s).replace(/\x1b\[[0-9;]*m/g, '');
const item = (id, status, reason = '', advisory = false) => ({ id, status, reason, advisory });
const read = p => fs.readFileSync(p, 'utf8');
export function counts(items) {
  const c = { passed: 0, failed: 0, indeterminate: 0, not_applicable: 0, advisory: 0 };
  for (const i of items) {
    if (i.status === 'pass') c.passed++;
    else if (i.status === 'fail') { c.failed++; if (i.advisory) c.advisory++; }
    else if (i.status === 'not_applicable') c.not_applicable++;
    else c.indeterminate++;
  }
  return c;
}
export function state(items) {
  if (!items.length) return 'orange';
  if (items.some(i => i.status === 'fail' && !i.advisory)) return 'red';
  if (items.some(i => i.status === 'indeterminate')) return 'orange';
  if (items.some(i => i.advisory)) return 'yellow';
  return items.every(i => i.status === 'not_applicable') ? 'grey' : 'green';
}
export function assertions(output) {
  return clean(output).split('\n').flatMap(line => {
    const m = /^(ok|FAIL|SKIP)\s+(.+)$/.exec(line);
    return m ? [item(m[2], m[1] === 'ok' ? 'pass' : m[1] === 'FAIL' ? 'fail' : 'indeterminate', m[1] === 'ok' ? '' : m[2])] : [];
  });
}
export function checkedAssertions(output, code, expected) {
  const rows = assertions(output);
  if (!rows.length) rows.push(item('check execution', 'indeterminate', 'No assertion evidence was produced.'));
  if (expected !== undefined && rows.length !== expected) rows.push(item('coverage', 'indeterminate', `Expected ${expected} controls, received ${rows.length} results.`));
  if (code !== 0 && !rows.some(i => i.status !== 'pass')) rows.push(item('check execution', 'indeterminate', `Process exited ${code} despite passing assertion lines.`));
  return rows;
}
// The coordination validator's verdict rules, the same as scripts/conformance-k9.sh cmd_coord:
// PASS needs exit 0 plus a `PASS ` line; FAIL needs exit 1 plus a `FAIL ` line (exit 1 is also
// what Bun uses for a crash); anything else is no verdict.
export function coordVerdict(code, output) {
  const lines = clean(output).split('\n');
  if (code === 0 && lines.some(l => l.startsWith('PASS '))) return { verdict: 'pass', message: '' };
  if (code === 1 && lines.some(l => l.startsWith('FAIL '))) return { verdict: 'fail', message: clean(output).trim() };
  return { verdict: 'none', message: `Coordination validator gave no verdict (exit ${code}).` };
}
export function corpusItems(text, expected, ledger, changed, coord = new Map()) {
  const rows = [], seen = new Set();
  for (const line of text.trim().split('\n').filter(Boolean)) {
    let r;
    try { r = JSON.parse(line); } catch { rows.push(item('validator output', 'indeterminate', 'Malformed JSON result.')); continue; }
    if (!expected.includes(r.file) || seen.has(r.file) || !['pass', 'fail', 'error', 'routed'].includes(r.verdict) || !Array.isArray(r.findings)) {
      rows.push(item(String(r.file ?? 'validator output'), 'indeterminate', 'Unexpected, duplicate or invalid result.')); continue;
    }
    seen.add(r.file);
    const unavailable = r.findings.filter(f => f.severity === 'skipped');
    const errors = r.findings.filter(f => f.severity === 'error');
    const warnings = r.findings.filter(f => f.severity === 'warning');
    const reason = r.findings.map(f => `${f.rule}: ${f.message}`).join('; ');
    if (r.verdict === 'routed') {
      const c = coord.get(r.file);
      const listed = ledger.has(r.file) && !changed.has(r.file);
      if (!c || c.verdict === 'none') rows.push(item(r.file, 'indeterminate', c ? c.message : 'Routed to the coordination dialect but no coordination validator result was produced.'));
      else if (c.verdict === 'fail') rows.push(item(r.file, 'fail', c.message, listed));
      else if (ledger.has(r.file)) rows.push(item(r.file, 'fail', 'Stale debt exemption: this file now conforms.'));
      else rows.push(item(r.file, 'pass'));
    }
    else if (errors.some(f => f.rule === 'K9-N002') && !errors.some(f => f.rule !== 'K9-N002')) rows.push(item(r.file, 'indeterminate', reason));
    else if (errors.length || r.verdict === 'fail' || r.verdict === 'error') rows.push(item(r.file, 'fail', reason, ledger.has(r.file) && !changed.has(r.file)));
    else if (unavailable.length) rows.push(item(r.file, 'indeterminate', reason));
    else if (ledger.has(r.file)) rows.push(item(r.file, 'fail', 'Stale debt exemption: this file now conforms.'));
    else rows.push(item(r.file, 'pass', warnings.length ? reason : '', warnings.length > 0));
  }
  for (const f of expected) if (!seen.has(f)) rows.push(item(f, 'indeterminate', 'Validator did not return a result for this file.'));
  if (!expected.length) rows.push(item('live corpus', 'not_applicable', 'No tracked live K9 contracts or routing files.'));
  return rows;
}
function walk(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => e.isDirectory() ? walk(path.join(dir, e.name)) : [path.join(dir, e.name)]);
}
// Keep this allowance outside Hypatia's file-wide header exemption window.
// hypatia: allow code_safety/js_exec_sync -- spawnSync passes argv arrays without shell evaluation.
import { spawnSync } from 'node:child_process';
function execute(root, command, args, env = {}, cwd = root) {
  const r = spawnSync(command, args, { cwd, env: { ...process.env, ...env }, encoding: 'utf8', timeout: 180000, maxBuffer: 32 * 1024 * 1024 });
  return { code: r.error || r.signal ? null : r.status, output: clean((r.stdout ?? '') + (r.stderr ?? '') + (r.error ? `\n${r.error.message}` : '')) };
}
// `root` is the tree examined (cwd, git ls-files, ledger); `opts.tools` is where the checker lives
// (default: the same tree). A base run examines the base commit's tree with the PR's own checker, so
// both sides of the comparison are graded by one toolchain. `opts.treeOnly` skips the categories that
// grade the checker itself (typecheck, self-test, fixtures): they do not depend on the tree.
function coordinate(root, T, files, runtime, directory) {
  const out = new Map();
  if (!files.length) return out;
  const V = path.join(T, '2-protocols/k9-coordination/tools/validate');
  const log = [];
  const inst = execute(root, runtime, ['install', '--frozen-lockfile'], {}, V);
  log.push(`install exit ${inst.code}\n${inst.output}`);
  for (const f of files) {
    if (inst.code !== 0) { out.set(f, { verdict: 'none', message: 'Coordination validator dependencies did not install.' }); continue; }
    // validate.js reads a leading `-` as an option; `./` keeps a tracked file named `-x.k9` a path.
    const r = execute(root, runtime, [path.join(V, 'validate.js'), `./${f}`]);
    log.push(`== ${f} exit ${r.code}\n${r.output}`);
    out.set(f, coordVerdict(r.code, r.output));
  }
  fs.writeFileSync(path.join(directory, 'coordination.log'), log.join('\n'));
  return out;
}
// The PR's own checker, run on the merge base's tree: a like-for-like baseline by construction.
// Never throws and never fabricates: any failure is reported as `error`.
export function collectBase(root, directory, env = process.env) {
  const baseSha = env.K9_BASE_SHA, head = env.K9_HEAD_SHA || 'HEAD';
  if (!baseSha || /^0+$/.test(baseSha)) return null;
  const git = args => execute(root, 'git', args);
  const mb = git(['merge-base', baseSha, head]);
  if (mb.code !== 0 || !mb.output.trim()) return { sha: baseSha, error: `cannot resolve the merge base of ${baseSha.slice(0, 12)} and the head` };
  const sha = mb.output.trim();
  const tree = fs.mkdtempSync(path.join(env.RUNNER_TEMP || os.tmpdir(), 'k9-base-'));
  try {
    const add = git(['worktree', 'add', '--detach', '--force', tree, sha]);
    if (add.code !== 0) return { sha, error: `cannot check out ${sha.slice(0, 12)}: ${add.output.trim().split('\n').pop()}` };
    const { K9_BASE_SHA, K9_HEAD_SHA, ...rest } = env;
    const r = collect(tree, path.join(directory, 'base'), rest, { tools: root, treeOnly: true });
    return { sha, categories: r.categories.map(c => ({ id: c.id, counts: c.counts })) };
  } catch (e) { return { sha, error: String(e.message || e) };
  } finally { git(['worktree', 'remove', '--force', tree]); fs.rmSync(tree, { recursive: true, force: true }); }
}
export function collect(root, directory, env = process.env, opts = {}) {
  fs.mkdirSync(directory, { recursive: true });
  const T = opts.tools ?? root;
  const t = rel => path.join(T, rel);
  const run = (name, cmd, args, extra = {}) => {
    const r = execute(root, cmd, args, extra);
    fs.writeFileSync(path.join(directory, `${name}.log`), r.output);
    return r;
  };
  const categories = [];
  const add = (id, items, tree = true) => categories.push({ id, title: titles[id], tree, items, counts: counts(items), state: state(items) });
  const tracked = execute(root, 'git', ['ls-files', '-z']);
  if (tracked.code !== 0) throw Error('Cannot enumerate the tracked corpus.');
  const files = tracked.output.split('\0').filter(Boolean);
  const deeds = files.filter(f => !f.startsWith('9-archive/') && !f.includes('/fixtures/') && f.endsWith('.deed'));
  if (!deeds.some(f => /^[^/]+_chora\.deed$/.test(f))) deeds.push('__missing_repo_deed__');
  const runtime = env.BUN_BIN || 'bun';
  const tools = { runtime: process.version, bun: execute(root, runtime, ['--version']).output.trim(), nickel: execute(root, 'nickel', ['--version']).output.trim() };
  fs.writeFileSync(path.join(directory, 'tools.json'), JSON.stringify(tools, null, 2) + '\n');
  const deedRows = [];
  for (const f of deeds) {
    if (f === '__missing_repo_deed__') { deedRows.push(item('repo deed', 'indeterminate', 'No tracked root <repo>_chora.deed found.')); continue; }
    const r = run(`deed-${deedRows.length}`, runtime, [t('1-formats/deed/tools/deed_lint.js'), f]);
    const ok = r.code === 0 && r.output.includes(`OK   ${f}`);
    deedRows.push(item(f, ok ? 'pass' : r.code === 1 && r.output.includes(`FAIL ${f}`) ? 'fail' : 'indeterminate', ok ? '' : r.output.trim() || 'No DEED validator evidence.'));
  }
  add('deed', deedRows);
  const contract = '1-formats/k9/spec/contract/k9_contract.ncl';
  const validator = '1-formats/k9/tools/k9-validate.sh';
  const fixtures = walk(t('1-formats/k9/tools/fixtures')).filter(f => /\.(k9|ncl)$/.test(f));
  const names = fixtures.map(f => path.basename(f));
  if (!opts.treeOnly) {
    const nr = run('typecheck', 'nickel', ['typecheck', t(contract)]);
    add('typecheck', [item(contract, nr.code === 0 ? 'pass' : nr.code === null ? 'indeterminate' : 'fail', nr.code === 0 ? '' : nr.output.trim())], false);
    const sr = run('selftest', 'bash', [t(validator), '--self-test']);
    let self = checkedAssertions(sr.output, sr.code);
    if (sr.code === 0 && !sr.output.includes('self-test: all assertions passed')) self.push(item('completion', 'indeterminate', 'Missing self-test completion evidence.'));
    add('selftest', self, false);
    const fr = run('fixtures', 'bash', [t(validator), '--strict', '--fixtures', t('1-formats/k9/tools/fixtures')]);
    let controls = checkedAssertions(fr.output, fr.code, fixtures.length);
    for (const name of names) if (!controls.some(r => r.id === name || r.id.startsWith(name + ' '))) controls.push(item(name, 'indeterminate', 'Expected control has no result.'));
    if (new Set(names).size !== names.length) controls.push(item('fixture identity', 'indeterminate', 'Duplicate fixture basenames cannot be attributed uniquely.'));
    if (state(categories.find(c => c.id === 'typecheck').items) !== 'green') {
      controls = controls.map(i => item(i.id, 'indeterminate', 'Normative contract did not typecheck; fixture verdict is not established. See fixtures.log.'));
    }
    add('fixtures', controls, false);
  }
  const expected = files.filter(f => /\.(k9|k9\.ncl)$/.test(f) && !f.startsWith('9-archive/') && !f.startsWith('1-formats/k9/tools/fixtures/') && !f.startsWith('2-protocols/k9-coordination/tools/validate/fixtures/'));
  const ledgerFile = path.join(root, '.machine_readable/k9-contract-debt.txt');
  const ledger = new Set(fs.existsSync(ledgerFile) ? read(ledgerFile).split('\n').filter(l => l && !/^\s*#/.test(l)) : []);
  let changed = new Set(), baseResolved = true;
  if (env.K9_BASE_SHA && !opts.tools) {
    const diff = execute(root, 'git', ['diff', '--name-only', '-z', `${env.K9_BASE_SHA}...${env.K9_HEAD_SHA || 'HEAD'}`]);
    baseResolved = diff.code === 0;
    changed = new Set(diff.output.split('\0').filter(Boolean));
  }
  const jsonFile = path.join(directory, 'corpus.jsonl');
  const cr = run('corpus', 'bash', [t('.githooks/validate-k9.sh')], { K9_VALIDATE_LAYER: 'L2', K9_JSON_REPORT: jsonFile, K9_CHANGED_FILES: [...changed].join('\n'), K9_VALIDATOR: t(validator), INPUT_PATH: root });
  const corpusText = fs.existsSync(jsonFile) ? read(jsonFile) : '';
  // Files the K9 validator routes to the coordination dialect are validated by that dialect's own
  // validator, as scripts/conformance-k9.sh cmd_coord does.
  const routed = corpusText.split('\n').flatMap(l => { try { const r = JSON.parse(l); return r.verdict === 'routed' && typeof r.file === 'string' ? [r.file] : []; } catch { return []; } });
  const coord = coordinate(root, T, routed, runtime, directory);
  const corpus = corpusItems(corpusText, expected, ledger, changed, coord);
  if (!baseResolved) corpus.push(item('change scope', 'indeterminate', 'Cannot resolve the PR base/head range; debt exemptions cannot be determined.'));
  if (cr.code !== 0 && !corpus.some(i => i.status === 'indeterminate' || i.status === 'fail' && !i.advisory)) corpus.push(item('corpus gate', 'indeterminate', `Gate exited ${cr.code}; inspect corpus.log.`));
  add('corpus', corpus);
  const coordDir = '2-protocols/k9-coordination';
  const profileFiles = [contract, validator, '.githooks/validate-k9.sh', '1-formats/deed/tools/deed_lint.js', '1-formats/deed/spec/abnf/deed.abnf', '1-formats/k9/tools/conformance-report.mjs',
    `${coordDir}/tools/validate/validate.js`, `${coordDir}/tools/validate/package.json`, `${coordDir}/tools/validate/bun.lock`, `${coordDir}/spec/abnf/coordination-k9-grammar_v1.2.abnf`];
  const fixtureDefinitions = fixtures.sort().map(f => path.relative(T, f) + '\0' + read(f)).join('\0');
  const profile = crypto.createHash('sha256').update(profileFiles.map(f => f + '\0' + read(t(f))).join('\0') + fixtureDefinitions + (fs.existsSync(ledgerFile) ? read(ledgerFile) : '') + JSON.stringify({ tools, fixtures: names.sort(), expected: expected.sort(), deeds: deeds.sort() })).digest('hex');
  const all = categories.flatMap(c => c.items);
  const dirty = execute(root, 'git', ['diff', '--quiet', 'HEAD']).code !== 0;
  return { schema: VERSION, profile, tools, dirty, generated: new Date().toISOString(), sha: env.K9_HEAD_SHA || execute(root, 'git', ['rev-parse', 'HEAD']).output.trim(), run: env.GITHUB_RUN_ID || 'local', pr: env.PR_NUMBER || 'local', url: env.GITHUB_RUN_ID ? `https://github.com/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}` : '', categories, state: state(all), counts: counts(all) };
}
const escape = s => String(s).replace(/[&<>|`]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '|': '&#124;', '`': '&#96;' }[c])).replace(/\r?\n/g, ' ');
export function delta(base, category) {
  if (!base) return '— no base (not a pull request)';
  if (base.error) return `— base not checkable: ${base.error}`;
  if (category.tree === false) return '— checker only; same toolchain as base';
  const before = base.categories.find(c => c.id === category.id);
  if (!before) return '— base not checkable: no result for this category';
  if (before.counts.indeterminate || category.counts.indeterminate) return '— indeterminate';
  if (before.counts.not_applicable !== category.counts.not_applicable) return '— scope changed';
  // Blocking failures first: a ledgered failure the PR now touches moves from advisory to blocking.
  const bb = before.counts.failed - before.counts.advisory, cb = category.counts.failed - category.counts.advisory;
  if (bb !== cb) return cb < bb ? `↑ improved (${bb - cb} fewer blocking failures)` : `↓ regressed (${cb - bb} more blocking failures)`;
  const a = before.counts.failed, c = category.counts.failed;
  if (a !== c) return c < a ? `↑ improved (${a - c} fewer failures)` : `↓ regressed (${c - a} more failures)`;
  const aw = before.counts.advisory, bw = category.counts.advisory;
  return bw < aw ? '↑ fewer advisories' : bw > aw ? '↓ more advisories' : '↔ unchanged';
}
export function render(report) {
  const labels = { red: '🔴 failing', orange: '🟠 indeterminate', yellow: '🟡 advisory', green: '🟢 conformant', grey: '⚪ not applicable' };
  const colour = { red: 'red', orange: 'orange', yellow: 'yellow', green: 'brightgreen', grey: 'lightgrey' };
  const badge = `https://img.shields.io/badge/DEED_syntax_%2B_K9_L0%E2%80%93L2-${encodeURIComponent(report.state)}-${colour[report.state]}`;
  let out = `${marker}\n![DEED–K9 ${report.state}](${badge})\n\n${labels[report.state]} · commit \`${escape(report.sha.slice(0, 12))}\` · ${report.url ? `[run ${escape(report.run)}](${report.url})` : 'local run'}${report.dirty ? ' · working tree modified' : ''}\n\n`;
  out += '| Category | Status | Pass | Fail | Indeterminate | N/A | This PR vs its base |\n|---|---|---:|---:|---:|---:|---|\n';
  for (const c of report.categories) out += `| ${c.title} | ${labels[c.state]} | ${c.counts.passed} | ${c.counts.failed}${c.counts.advisory ? ` (${c.counts.advisory} advisory)` : ''} | ${c.counts.indeterminate} | ${c.counts.not_applicable} | ${escape(delta(report.base, c)).slice(0, 160)} |\n`;
  for (const c of report.categories) {
    const findings = c.items.filter(i => i.status !== 'pass' || i.advisory);
    if (!findings.length) continue;
    out += `\n<details>\n<summary>${c.title}: ${findings.length} finding(s) / scope notes</summary>\n\n`;
    for (const i of findings.slice(0, 20)) out += `- **${escape(i.id).slice(0, 240)}** — ${escape(i.status)}${i.advisory ? ' (advisory)' : ''}: ${escape(i.reason).slice(0, 280)}\n`;
    if (findings.length > 20) out += `- ${findings.length - 20} more; see the structured report and logs.\n`;
    out += '\n</details>\n';
  }
  out += '\nScope: DEED syntax and K9 contracts L0–L2. L3 signature verification and routed coordination files are checked by the coordination validator only. Green is limited to this scope. Orange is missing evidence; grey is an explicit scope exclusion. Logs and report.json are in the dated conformance-evidence artifact on the linked run.\n';
  if (report.base) out += `\nBase: ${escape(report.base.sha.slice(0, 12))} (merge base), graded by this revision's checker. Checker-only categories do not depend on the tree.\n`;
  return out;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = process.cwd();
  const safe = x => String(x || 'local').replace(/[^a-zA-Z0-9_-]/g, '_');
  const date = new Date().toISOString().slice(0, 10);
  const relative = `tests/conformance/${date}/pr-${safe(process.env.PR_NUMBER)}/run-${safe(process.env.GITHUB_RUN_ID)}-${safe(process.env.GITHUB_RUN_ATTEMPT || '1')}`;
  const directory = path.resolve(root, relative);
  let report;
  try { report = collect(root, directory); }
  catch (e) { const items = [item('report collection', 'indeterminate', e.message)]; report = { schema: VERSION, profile: '', sha: process.env.K9_HEAD_SHA || '', pr: process.env.PR_NUMBER || 'local', run: process.env.GITHUB_RUN_ID || 'local', url: '', categories: [{ id: 'corpus', title: 'Collection', items, counts: counts(items), state: 'orange' }], state: 'orange', counts: counts(items) }; }
  fs.mkdirSync(directory, { recursive: true });
  if (report.profile) report.base = collectBase(root, directory);
  fs.writeFileSync(path.join(directory, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  const markdown = render(report);
  fs.writeFileSync(path.join(directory, 'report.md'), markdown);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, markdown);
  if (process.env.GITHUB_ENV) fs.appendFileSync(process.env.GITHUB_ENV, `K9_REPORT_DIR=${relative}\n`);
  console.log(markdown);
  process.exitCode = report.state === 'red' ? 1 : report.state === 'orange' ? 2 : 0;
}
