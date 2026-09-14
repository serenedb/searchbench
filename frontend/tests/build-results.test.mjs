import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

test('assembler includes query text and provenance, and preserves output on failure', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'searchbench-results-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'frontend'));
  mkdirSync(join(root, 'engine/results'), { recursive: true });
  const script = join(root, 'frontend/build_results');
  copyFileSync(new URL('../build_results', import.meta.url), script);
  writeFileSync(join(root, 'engine/queries.sql'), '-- comment\nSELECT default_query;\n');
  writeFileSync(join(root, 'engine/results/engine_sql_otel_logs_1m.json'), JSON.stringify({
    dataset: 'otel_logs_1m', result: [[1, 2, 3]], load_time: 999, data_size: 999,
  }));
  execFileSync('bash', [script], { cwd: tmpdir() });
  const output = join(root, 'frontend/results.json');
  const before = readFileSync(output, 'utf8');
  const rows = JSON.parse(before);
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].queries, ['SELECT default_query;']);
  assert.equal(rows[0].load_time, 999);
  assert.equal(rows[0].data_size, 999);
  assert.equal(rows[0]._source, 'engine/results/engine_sql_otel_logs_1m.json');
  writeFileSync(join(root, 'engine/results/broken.json'), '{');
  assert.notEqual(spawnSync('bash', [script]).status, 0);
  assert.equal(readFileSync(output, 'utf8'), before);
});
