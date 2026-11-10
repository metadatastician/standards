// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
// hypatia: allow cicd_rules/javascript_detected -- Bun/GitHub JSON reporting boundary; zero dependencies.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
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
export function corpusItems(text, expected, ledger, changed) {
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
    if (r.verdict === 'routed') rows.push(item(r.file, 'not_applicable', 'Routed to another dialect; not validated as a K9 contract.'));
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
function execute(root, command, args, env = {}) {
  const r = spawnSync(command, args, { cwd: root, env: { ...process.env, ...env }, encoding: 'utf8', timeout: 180000, maxBuffer: 32 * 1024 * 1024 });
  return { code: r.error || r.signal ? null : r.status, output: clean((r.stdout ?? '') + (r.stderr ?? '') + (r.error ? `\n${r.error.message}` : '')) };
}
export function collect(root, directory, env = process.env) {
  fs.mkdirSync(directory, { recursive: true });
  const run = (name, cmd, args, extra = {}) => {
    const r = execute(root, cmd, args, extra);
    fs.writeFileSync(path.join(directory, `${name}.log`), r.output);
    return r;
  };
  const categories = [];
  const add = (id, items) => categories.push({ id, title: titles[id], items, counts: counts(items), state: state(items) });
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
    const r = run(`deed-${deedRows.length}`, runtime, ['1-formats/deed/tools/deed_lint.js', f]);
    const ok = r.code === 0 && r.output.includes(`OK   ${f}`);
    deedRows.push(item(f, ok ? 'pass' : r.code === 1 && r.output.includes(`FAIL ${f}`) ? 'fail' : 'indeterminate', ok ? '' : r.output.trim() || 'No DEED validator evidence.'));
  }
  add('deed', deedRows);
  const contract = '1-formats/k9/spec/contract/k9_contract.ncl';
  const nr = run('typecheck', 'nickel', ['typecheck', contract]);
  add('typecheck', [item(contract, nr.code === 0 ? 'pass' : nr.code === null ? 'indeterminate' : 'fail', nr.code === 0 ? '' : nr.output.trim())]);
  const validator = '1-formats/k9/tools/k9-validate.sh';
  const sr = run('selftest', 'bash', [validator, '--self-test']);
  let self = checkedAssertions(sr.output, sr.code);
  if (sr.code === 0 && !sr.output.includes('self-test: all assertions passed')) self.push(item('completion', 'indeterminate', 'Missing self-test completion evidence.'));
  add('selftest', self);
  const fixtures = walk(path.join(root, '1-formats/k9/tools/fixtures')).filter(f => /\.(k9|ncl)$/.test(f));
  const fr = run('fixtures', 'bash', [validator, '--strict', '--fixtures', '1-formats/k9/tools/fixtures']);
  let controls = checkedAssertions(fr.output, fr.code, fixtures.length);
  const names = fixtures.map(f => path.basename(f));
  for (const name of names) if (!controls.some(r => r.id === name || r.id.startsWith(name + ' '))) controls.push(item(name, 'indeterminate', 'Expected control has no result.'));
  if (new Set(names).size !== names.length) controls.push(item('fixture identity', 'indeterminate', 'Duplicate fixture basenames cannot be attributed uniquely.'));
  if (state(categories.find(c => c.id === 'typecheck').items) !== 'green') {
    controls = controls.map(i => item(i.id, 'indeterminate', 'Normative contract did not typecheck; fixture verdict is not established. See fixtures.log.'));
  }
  add('fixtures', controls);
  const expected = files.filter(f => /\.(k9|k9\.ncl)$/.test(f) && !f.startsWith('9-archive/') && !f.startsWith('1-formats/k9/tools/fixtures/') && !f.startsWith('2-protocols/k9-coordination/tools/validate/fixtures/'));
  const ledgerFile = path.join(root, '.machine_readable/k9-contract-debt.txt');
  const ledger = new Set(fs.existsSync(ledgerFile) ? read(ledgerFile).split('\n').filter(l => l && !/^\s*#/.test(l)) : []);
  let changed = new Set(), baseResolved = true;
  if (env.K9_BASE_SHA) {
    const diff = execute(root, 'git', ['diff', '--name-only', '-z', `${env.K9_BASE_SHA}...${env.K9_HEAD_SHA || 'HEAD'}`]);
    baseResolved = diff.code === 0;
    changed = new Set(diff.output.split('\0').filter(Boolean));
  }
  const jsonFile = path.join(directory, 'corpus.jsonl');
  const cr = run('corpus', 'bash', ['.githooks/validate-k9.sh'], { K9_VALIDATE_LAYER: 'L2', K9_JSON_REPORT: jsonFile, K9_CHANGED_FILES: [...changed].join('\n') });
  const corpus = corpusItems(fs.existsSync(jsonFile) ? read(jsonFile) : '', expected, ledger, changed);
  if (!baseResolved) corpus.push(item('change scope', 'indeterminate', 'Cannot resolve the PR base/head range; debt exemptions cannot be determined.'));
  if (cr.code !== 0 && !corpus.some(i => i.status === 'indeterminate' || i.status === 'fail' && !i.advisory)) corpus.push(item('corpus gate', 'indeterminate', `Gate exited ${cr.code}; inspect corpus.log.`));
  add('corpus', corpus);
  const profileFiles = [contract, validator, '.githooks/validate-k9.sh', '1-formats/deed/tools/deed_lint.js', '1-formats/deed/spec/abnf/deed.abnf', '1-formats/k9/tools/conformance-report.mjs'];
  const fixtureDefinitions = fixtures.sort().map(f => path.relative(root, f) + '\0' + read(f)).join('\0');
  const profile = crypto.createHash('sha256').update(profileFiles.map(f => f + '\0' + read(path.join(root, f))).join('\0') + fixtureDefinitions + (fs.existsSync(ledgerFile) ? read(ledgerFile) : '') + JSON.stringify({ tools, fixtures: names.sort(), expected: expected.sort(), deeds: deeds.sort() })).digest('hex');
  const all = categories.flatMap(c => c.items);
  const dirty = execute(root, 'git', ['diff', '--quiet', 'HEAD']).code !== 0;
  return { schema: VERSION, profile, tools, dirty, generated: new Date().toISOString(), sha: env.K9_HEAD_SHA || execute(root, 'git', ['rev-parse', 'HEAD']).output.trim(), run: env.GITHUB_RUN_ID || 'local', pr: env.PR_NUMBER || 'local', url: env.GITHUB_RUN_ID ? `https://github.com/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}` : '', categories, state: state(all), counts: counts(all) };
}
const escape = s => String(s).replace(/[&<>|`]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '|': '&#124;', '`': '&#96;' }[c])).replace(/\r?\n/g, ' ');
export function delta(current, previous, category) {
  if (!previous || previous.schema !== VERSION || previous.profile !== current.profile || previous.sha === current.sha || previous.pr !== current.pr) return '— no comparable baseline';
  const before = previous.categories.find(c => c.id === category.id);
  if (!before || before.counts.indeterminate || category.counts.indeterminate) return '— indeterminate';
  if (before.counts.not_applicable !== category.counts.not_applicable) return '— scope changed';
  const a = before.counts.failed, b = category.counts.failed;
  if (a !== b) return b < a ? `↑ improved (${a - b} fewer failures)` : `↓ regressed (${b - a} more failures)`;
  const aw = before.counts.advisory, bw = category.counts.advisory;
  return bw < aw ? '↑ fewer advisories' : bw > aw ? '↓ more advisories' : '↔ unchanged';
}
export function render(report, previous = null) {
  const labels = { red: '🔴 failing', orange: '🟠 indeterminate', yellow: '🟡 advisory', green: '🟢 conformant', grey: '⚪ not applicable' };
  const colour = { red: 'red', orange: 'orange', yellow: 'yellow', green: 'brightgreen', grey: 'lightgrey' };
  const badge = `https://img.shields.io/badge/DEED_syntax_%2B_K9_L0%E2%80%93L2-${encodeURIComponent(report.state)}-${colour[report.state]}`;
  let out = `${marker}\n![DEED–K9 ${report.state}](${badge})\n\n${labels[report.state]} · commit \`${escape(report.sha.slice(0, 12))}\` · ${report.url ? `[run ${escape(report.run)}](${report.url})` : 'local run'}${report.dirty ? ' · working tree modified' : ''}\n\n`;
  out += '| Category | Status | Pass | Fail | Indeterminate | N/A | Since previous revision |\n|---|---|---:|---:|---:|---:|---|\n';
  for (const c of report.categories) out += `| ${c.title} | ${labels[c.state]} | ${c.counts.passed} | ${c.counts.failed}${c.counts.advisory ? ` (${c.counts.advisory} advisory)` : ''} | ${c.counts.indeterminate} | ${c.counts.not_applicable} | ${delta(report, previous, c)} |\n`;
  for (const c of report.categories) {
    const findings = c.items.filter(i => i.status !== 'pass' || i.advisory);
    if (!findings.length) continue;
    out += `\n<details>\n<summary>${c.title}: ${findings.length} finding(s) / scope notes</summary>\n\n`;
    for (const i of findings.slice(0, 20)) out += `- **${escape(i.id).slice(0, 240)}** — ${escape(i.status)}${i.advisory ? ' (advisory)' : ''}: ${escape(i.reason).slice(0, 280)}\n`;
    if (findings.length > 20) out += `- ${findings.length - 20} more; see the structured report and logs.\n`;
    out += '\n</details>\n';
  }
  out += '\nScope: DEED syntax and K9 contracts L0–L2. L3 signature verification and routed coordination dialects are not certified. Green is limited to this scope. Orange is missing evidence; grey is an explicit scope exclusion. Logs and report.json are in the dated conformance-evidence artifact on the linked run.\n';
  const baseline = { schema: report.schema, profile: report.profile, pr: report.pr, sha: report.sha, categories: report.categories.map(c => ({ id: c.id, counts: c.counts })) };
  out += `\n<!-- k9-baseline:${Buffer.from(JSON.stringify(baseline)).toString('base64')} -->\n`;
  return out;
}
export function baseline(body) {
  try {
    const m = /<!-- k9-baseline:([A-Za-z0-9+/=]+) -->/.exec(body);
    if (!m || m[1].length > 32000) return null;
    const p = JSON.parse(Buffer.from(m[1], 'base64').toString());
    if (!Array.isArray(p.categories) || !p.categories.every(c => c.counts && ['passed','failed','indeterminate','not_applicable','advisory'].every(k => Number.isSafeInteger(c.counts[k]) && c.counts[k] >= 0))) return null;
    return p;
  } catch { return null; }
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
  fs.writeFileSync(path.join(directory, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  const previous = process.env.K9_PREVIOUS_REPORT && fs.existsSync(process.env.K9_PREVIOUS_REPORT) ? baseline(read(process.env.K9_PREVIOUS_REPORT)) : null;
  const markdown = render(report, previous);
  fs.writeFileSync(path.join(directory, 'report.md'), markdown);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, markdown);
  if (process.env.GITHUB_ENV) fs.appendFileSync(process.env.GITHUB_ENV, `K9_REPORT_DIR=${relative}\n`);
  console.log(markdown);
  process.exitCode = report.state === 'red' ? 1 : report.state === 'orange' ? 2 : 0;
}
