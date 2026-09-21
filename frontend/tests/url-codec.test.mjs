import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';

// Exercise the source codec without requiring a browser or a frontend build.
const modules = new Map();
function load(name) {
  if (modules.has(name)) return modules.get(name);
  const source = readFileSync(new URL(`../src/shared/model/${name}.ts`, import.meta.url), 'utf8');
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  });
  const exports = {};
  vm.runInNewContext(outputText, {
    exports, require: (path) => load(path.replace('./', '')),
    TextEncoder, TextDecoder, URLSearchParams, btoa, atob,
  });
  modules.set(name, exports);
  return exports;
}
const { INITIAL_STATE } = load('state');
const { restoreUrlState, shortState, base64UrlEncode } = load('url-codec');
const { benchReducer } = load('reducer');
const env = { datasets: ['otel_logs_100m'], systems: ['SereneDB', 'ArangoDB', 'NewEngine'], qTasks: [] };
const restore = (search, environment = env) => ({
  ...INITIAL_STATE, ...restoreUrlState(search, environment, INITIAL_STATE).patch,
});
const shown = (state, environment = env) => environment.systems.filter((s) => !state.hidden.has(s));
const packedUrl = (packed) => `?s=${base64UrlEncode(packed)}`;

test('include selects exact system names and overrides legacy exclusions', () => {
  assert.deepEqual(shown(restore('?include=SereneDB,ArangoDB&hidden=SereneDB')), ['SereneDB', 'ArangoDB']);
  assert.deepEqual(shown(restore('?include=SereneDB,Unknown')), ['SereneDB']);
  assert.deepEqual(shown(restore('?include=Serene')), []);
  assert.deepEqual(shown(restore(packedUrl({ v: 1, i: 'ArangoDB', h: 'ArangoDB' }))), ['ArangoDB']);
});

test('allowlist survives sharing and excludes results added later', () => {
  const state = restore('?include=SereneDB,ArangoDB');
  const packed = shortState(state, env, 'dark');
  assert.equal(packed.i, 'ArangoDB,SereneDB');
  assert.equal(packed.h, undefined);
  const expanded = { ...env, systems: [...env.systems, 'AnotherEngine'] };
  assert.deepEqual(shown(restore(packedUrl(packed), expanded), expanded), ['SereneDB', 'ArangoDB']);
});

test('all, empty and unknown-only allowlists remain explicit after sharing', () => {
  for (const include of [env.systems.join(','), '', 'Unknown']) {
    const state = restore(`?include=${include}`);
    const packed = shortState(state, env, 'light');
    assert.equal(typeof packed.i, 'string');
    const expanded = { ...env, systems: [...env.systems, 'AnotherEngine'] };
    assert.deepEqual(shown(restore(packedUrl(packed), expanded), expanded), shown(state));
  }
});

test('participant controls update the shared allowlist', () => {
  let state = restore('?include=SereneDB');
  state = benchReducer(state, { type: 'part', sys: 'ArangoDB', visibleCount: 1 });
  assert.equal(shortState(state, env, 'light').i, 'ArangoDB,SereneDB');
  state = benchReducer(state, { type: 'toggle-all', present: env.systems });
  state = benchReducer(state, { type: 'toggle-all', present: env.systems });
  assert.equal(shortState(state, env, 'light').i, '');
});

test('old links and explicit themes retain their behavior', () => {
  assert.deepEqual(shown(restore('?hidden=ArangoDB')), ['SereneDB', 'NewEngine']);
  assert.deepEqual(shown(restore(packedUrl({ v: 1, h: 'ArangoDB' }))), ['SereneDB', 'NewEngine']);
  assert.equal(JSON.stringify(shortState(INITIAL_STATE, env, 'dark')), '{"v":1}');
  for (const theme of ['dark', 'light']) {
    assert.equal(restoreUrlState(`?theme=${theme}`, env, INITIAL_STATE).theme, theme);
  }
  const url = `${packedUrl({ v: 1, i: 'NewEngine', th: 'light' })}&include=SereneDB&theme=dark`;
  assert.deepEqual(shown(restore(url)), ['SereneDB']);
  assert.equal(restoreUrlState(url, env, INITIAL_STATE).theme, 'dark');
});

test('legacy UI uses the same allowlist wire format', () => {
  const html = readFileSync(new URL('../../ui/index.html', import.meta.url), 'utf8');
  const source = html.slice(html.indexOf('const state = {'), html.indexOf('// ---- data helpers'));
  const context = vm.createContext({
    DATA: env.systems.map(system => ({ system })), datasets: env.datasets,
    TextEncoder, TextDecoder, URLSearchParams, btoa, atob,
    qTasksFor: () => [], curDataset: () => env.datasets[0],
    window: { location: { search: '?include=SereneDB,ArangoDB&theme=dark' } },
  });
  vm.runInContext(source + '\nrestoreUrlState();', context);
  assert.equal(vm.runInContext('shortState().i', context), 'ArangoDB,SereneDB');
  assert.equal(vm.runInContext('state.hidden.has("NewEngine")', context), true);
});
