// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
// hypatia: allow cicd_rules/javascript_detected -- Bun reporting boundary regression tests.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { counts, state, checkedAssertions, corpusItems, render, delta, coordVerdict, collectBase } from './conformance-report.mjs';
const row = (status, advisory = false) => ({ id: 'x', status, advisory, reason: '' });
const json = (file, verdict = 'pass', findings = []) => JSON.stringify({ file, verdict, findings });
test('known blocking failure remains red when other evidence is missing', () => {
  assert.equal(state([row('fail'), row('indeterminate')]), 'red');
  assert.equal(state([row('fail', true)]), 'yellow');
  assert.equal(state([row('fail', true), row('indeterminate')]), 'orange');
  assert.equal(state([row('not_applicable')]), 'grey');
  assert.equal(state([row('pass'), row('not_applicable')]), 'green');
  assert.equal(state([]), 'orange');
});
test('empty, partial and interrupted assertion streams never become a pass', () => {
  assert.equal(state(checkedAssertions('', 0)), 'orange');
  assert.equal(state(checkedAssertions('ok   one', 0, 2)), 'orange');
  assert.equal(state(checkedAssertions('ok   one', 1)), 'orange');
  assert.equal(state(checkedAssertions('FAIL one', 0)), 'red');
  assert.equal(state(checkedAssertions('ok   one\nSKIP two', 0)), 'orange');
});
test('missing or malformed per-file evidence is indeterminate', () => {
  assert.equal(state(corpusItems('', ['a'], new Set(), new Set())), 'orange');
  assert.equal(state(corpusItems('not json', ['a'], new Set(), new Set())), 'orange');
  assert.equal(state(corpusItems(json('a') + '\n' + json('a'), ['a'], new Set(), new Set())), 'orange');
  assert.equal(state(corpusItems(json('b'), ['a'], new Set(), new Set())), 'orange');
});
test('missing semantic verifier is not a conformance pass', () => {
  const result = corpusItems(json('a', 'pass', [{ severity: 'skipped', rule: 'K9-N000', message: 'no nickel' }]), ['a'], new Set(), new Set());
  assert.equal(state(result), 'orange');
  assert.equal(counts(result).indeterminate, 1);
});
test('debt is advisory only while untouched, and conforming exemptions fail', () => {
  const data = json('a', 'fail', [{ severity: 'error', rule: 'K9-E001', message: 'invalid' }]);
  assert.equal(state(corpusItems(data, ['a'], new Set(['a']), new Set())), 'yellow');
  assert.equal(state(corpusItems(data, ['a'], new Set(['a']), new Set(['a']))), 'red');
  assert.equal(state(corpusItems(json('a'), ['a'], new Set(['a']), new Set())), 'red');
});
const coordOf = (file, verdict, message = '') => new Map([[file, { verdict, message }]]);
test('routed coordination files are graded by the coordination validator', () => {
  const routed = json('coordination.k9', 'routed');
  const run = (coord, ledger = new Set(), changed = new Set()) => corpusItems(routed, ['coordination.k9'], ledger, changed, coord);
  const pass = run(coordOf('coordination.k9', 'pass'));
  assert.equal(counts(pass).passed, 1);
  assert.equal(counts(pass).not_applicable, 0);
  assert.equal(state(run(coordOf('coordination.k9', 'fail', 'FAIL coordination.k9: bad'))), 'red');
  assert.equal(state(run(coordOf('coordination.k9', 'none', 'no verdict'))), 'orange');
  assert.equal(state(run(new Map())), 'orange');
  assert.equal(state(run(coordOf('coordination.k9', 'fail', 'x'), new Set(['coordination.k9']))), 'yellow');
  assert.equal(state(run(coordOf('coordination.k9', 'pass'), new Set(['coordination.k9']))), 'red');
});
test('coordination verdict rules match conformance-k9.sh cmd_coord', () => {
  assert.equal(coordVerdict(0, 'PASS ./a.k9').verdict, 'pass');
  assert.equal(coordVerdict(1, 'FAIL ./a.k9: x').verdict, 'fail');
  assert.equal(coordVerdict(1, 'error: Cannot find module').verdict, 'none');
  assert.equal(coordVerdict(0, 'ok').verdict, 'none');
  assert.equal(coordVerdict(0, 'FAIL ./a.k9').verdict, 'none');
  assert.equal(coordVerdict(1, 'PASS ./a.k9').verdict, 'none');
  assert.equal(coordVerdict(null, '').verdict, 'none');
});
const cat = (items, tree = true) => ({ id: 'corpus', tree, counts: counts(items) });
const baseOf = items => ({ sha: 'b', categories: [{ id: 'corpus', counts: counts(items) }] });
test('delta compares this PR with its base', () => {
  assert.match(delta(baseOf([row('fail')]), cat([row('pass')])), /improved/);
  assert.match(delta(baseOf([row('pass')]), cat([row('fail')])), /regressed/);
  assert.match(delta(baseOf([row('pass')]), cat([row('pass')])), /unchanged/);
  assert.match(delta(baseOf([row('fail', true)]), cat([row('fail')])), /regressed \(1 more blocking/);
  assert.match(delta(baseOf([row('pass')]), cat([row('fail', true)])), /more advisories|regressed/);
  assert.match(delta({ sha: 'b', error: 'boom' }, cat([row('pass')])), /^— base not checkable: boom/);
  assert.match(delta({ sha: 'b', categories: [] }, cat([row('pass')])), /^— base not checkable/);
  assert.match(delta(baseOf([row('indeterminate')]), cat([row('pass')])), /indeterminate/);
  assert.match(delta(baseOf([row('pass')]), cat([row('indeterminate')])), /indeterminate/);
  assert.match(delta(baseOf([row('pass'), row('not_applicable')]), cat([row('pass')])), /scope changed/);
  assert.match(delta(baseOf([row('pass')]), cat([row('pass')], false)), /checker only/);
  assert.match(delta(null, cat([row('pass')])), /no base/);
});
test('report renders the base column and never reads a previous comment', () => {
  const items = [row('pass')];
  const r = { schema: 1, state: 'green', sha: 'abc', profile: 'p', pr: '1', run: 'local', url: '', base: { sha: 'b'.repeat(40), error: 'a | b <x>' }, categories: [{ id: 'corpus', title: 'Corpus', items, counts: counts(items), state: 'green' }] };
  const body = render(r);
  assert.ok(body.includes('This PR vs its base'));
  assert.ok(body.includes('base not checkable: a &#124; b &lt;x&gt;'));
  assert.ok(!body.includes('k9-baseline'));
  assert.ok(body.startsWith('<!-- k9-contractile-report:'));
});
test('report escapes untrusted evidence', () => {
  const items = [{ id: '</details><script>x</script>', status: 'indeterminate', reason: 'bad | value\nnext' }];
  const r = { schema: 1, state: 'orange', sha: 'abc', profile: 'p', pr: '1', run: 'local', url: '', categories: [{ id: 'corpus', title: 'Corpus', items, counts: counts(items), state: 'orange' }] };
  const body = render(r);
  assert.ok(!body.includes('<script>'));
  assert.ok(body.includes('&#124;'));
});
// Keep this allowance outside Hypatia's file-wide header exemption window.
// hypatia: allow code_safety/js_exec_sync -- spawnSync runs fixed test programs with argv arrays and no shell evaluation.
import { spawnSync } from 'node:child_process';
test('the actual corpus shell gate rejects empty output and unattributed failure', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'k9-report-'));
  try {
    for (const dir of ['.githooks', '1-formats/k9/tools']) fs.mkdirSync(path.join(tmp, dir), { recursive: true });
    fs.copyFileSync(new URL('../../../.githooks/validate-k9.sh', import.meta.url), path.join(tmp, '.githooks/validate-k9.sh'));
    fs.writeFileSync(path.join(tmp, 'a.k9.ncl'), 'K9!\n');
    spawnSync('git', ['init', '-q'], { cwd: tmp });
    spawnSync('git', ['add', 'a.k9.ncl'], { cwd: tmp });
    const validator = path.join(tmp, '1-formats/k9/tools/k9-validate.sh');
    for (const body of ['exit 0', 'exit 1', `echo '${json('a.k9.ncl')}'\nexit 1`]) {
      fs.writeFileSync(validator, '#!/bin/bash\n' + body + '\n');
      const r = spawnSync('bash', ['.githooks/validate-k9.sh'], { cwd: tmp, encoding: 'utf8' });
      assert.notEqual(r.status, 0, r.stdout + r.stderr);
    }
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});
test('lock membership generator adds direct references and is idempotent', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'k9-lock-'));
  try {
    const wf = path.join(tmp, '.github/workflows');
    fs.mkdirSync(wf, { recursive: true });
    fs.writeFileSync(path.join(wf, 'test.yml'), 'jobs:\n  test:\n    steps:\n      - uses: owner/action@' + 'a'.repeat(40) + '\n');
    const lock = path.join(wf, 'actions.lock');
    fs.writeFileSync(lock, "version: 'v0.0.2'\nworkflows:\n    '.github/workflows/test.yml': []\ndependencies: {}\n");
    const script = new URL('../../../scripts/complete-job-refs.sh', import.meta.url).pathname;
    const r = spawnSync('bash', [script, wf], { cwd: tmp, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const first = fs.readFileSync(lock, 'utf8');
    assert.ok(first.includes('owner/action@' + 'a'.repeat(40)));
    const again = spawnSync('bash', [script, wf], { cwd: tmp, encoding: 'utf8' });
    assert.equal(again.status, 0, again.stderr);
    assert.equal(fs.readFileSync(lock, 'utf8'), first);
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});

// hypatia: allow code_safety/js_exec_sync -- spawnSync runs git with argv arrays and no shell evaluation.
test('collectBase reports an unresolvable base instead of faking one', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'k9-base-'));
  try {
    spawnSync('git', ['init', '-q'], { cwd: tmp });
    assert.equal(collectBase(tmp, path.join(tmp, 'out'), { K9_BASE_SHA: '' }), null);
    const r = collectBase(tmp, path.join(tmp, 'out'), { K9_BASE_SHA: 'a'.repeat(40), K9_HEAD_SHA: 'b'.repeat(40) });
    assert.match(r.error, /cannot resolve the merge base/);
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});
