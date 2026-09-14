/* The shareable-link codec — ui/index.html:196-276, ported byte-for-byte.

   People quote SearchBench results by pasting the URL, so a link minted by the
   standalone page has to open the same view here and a link minted here has to
   be the same string the standalone would have produced. That makes this file
   a wire format, not an implementation detail:

     - key order in the packed object is `put()` call order, because
       JSON.stringify writes string keys in insertion order and the base64 of
       {"v":1,"t":"charts"} is not the base64 of {"t":"charts","v":1};
     - `csv()` sorts with the default comparator (UTF-16 code units), not
       localeCompare;
     - the `!== default && != null && !== ''` test in `put()` is what keeps the
       default link at `?s=eyJ2IjoxfQ` instead of a full dump;
     - base64url padding is `"===".slice((value.length + 3) % 4)`.

   Change any of those and every link in every issue thread decodes to a
   different view. The standalone browser check also exercises this URL round-trip.

   The one field that moved: `th`. `state.theme` is gone — the platform owns the
   theme — so the codec takes the current `useTheme()` value as an argument and
   hands a restored one back to the caller to apply via `setTheme`. The slot,
   its name and its default ("dark") are unchanged, so the bytes are unchanged. */

import type { BenchState, Metric, PanelId, Scale, SortDir, Tab, ValueMode } from './state';
import { HIDEABLE_PANELS } from './state';

/** Mirrors @serenedb/ui's `Theme`, without importing it into a pure module. */
export type ThemeName = 'dark' | 'light';

/** Everything the codec has to validate against, supplied by entities/results. */
export interface CodecEnv {
  /** Dataset names, in display order — `datasets[0]` is the encoding default. */
  datasets: readonly string[];
  /** Every `system` present in the data; unknown engines are dropped on restore. */
  systems: readonly string[];
  /** Every `query_tags[].task`; unknown categories are dropped on restore. */
  qTasks: readonly string[];
}

/** The decoded `?s=` payload. Short keys, `v` is the format version. */
export type PackedState = Record<string, unknown> & { v?: unknown };

export interface RestoredState {
  /** Applied over INITIAL_STATE by the caller. */
  patch: Partial<BenchState>;
  /** Non-null when the link pins a theme; apply with `useTheme().setTheme`. */
  theme: ThemeName | null;
}

function csv(values: Iterable<string>): string {
  return [...values].filter(Boolean).sort().join(',');
}

export function base64UrlEncode(value: unknown): string {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = '';
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function base64UrlDecode(value: string | null): PackedState | null {
  if (!value) return null;
  try {
    const padded =
      value.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((value.length + 3) % 4);
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    const parsed = JSON.parse(new TextDecoder().decode(bytes)) as PackedState | null;
    return parsed && parsed.v === 1 ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * Keep only deviations from the initial UI. The common default link is thus
 * `?s=eyJ2IjoxfQ` instead of a full JSON dump of empty/default fields.
 *
 * `theme` stands in for the standalone's `state.theme`.
 */
export function shortState(state: BenchState, env: CodecEnv, theme: ThemeName): PackedState {
  const compact: PackedState = { v: 1 };
  const put = (key: string, value: unknown, defaultValue: unknown) => {
    if (value !== defaultValue && value != null && value !== '') compact[key] = value;
  };
  put('d', state.dataset ?? env.datasets[0] ?? null, env.datasets[0] || null);
  put('t', state.tab, 'table');
  put('r', state.metric, 'hot');
  put('c', state.valueMode, 'relative');
  put('l', state.scale, 'log');
  put('q', csv(state.activeQTasks), '');
  put('h', csv(state.hidden), '');
  put('s', state.sortRow, 'geomean');
  put('sd', state.sortDir, 1);
  put('e', state.sortByEngine, null);
  put('ed', state.sortByEngineDir, 1);
  put('o', (state.manualOrder || []).join(','), '');
  put('th', theme, 'dark');
  put('x', state.max ? 1 : 0, 0);
  put('p', csv(state.hiddenPanels), '');
  return compact;
}

/**
 * Canonicalise the address bar to a single `?s=` parameter.
 *
 * Deliberately `history.replaceState` and not react-router's `navigate`, as in
 * the standalone: this fires on every state change (a chip, a sort, a cell) and
 * must not push a route transition or re-render the tree through the router.
 * `window.location.pathname` is `/searchbench` here, so the ported line needs no
 * change; the router's own location goes stale, which is harmless because this
 * product has no nested routes and every link the shell renders is absolute.
 */
export function syncUrlState(state: BenchState, env: CodecEnv, theme: ThemeName): void {
  try {
    const p = new URLSearchParams();
    p.set('s', base64UrlEncode(shortState(state, env, theme)));
    const query = p.toString();
    const next = window.location.pathname + (query ? '?' + query : '') + window.location.hash;
    window.history.replaceState(null, '', next);
  } catch {
    /* history is unavailable (sandboxed iframe) — the view still works */
  }
}

/** Readable parameter name → its slot in the packed payload. */
const FIELDS: Record<string, string> = {
  dataset: 'd',
  view: 't',
  run: 'r',
  cells: 'c',
  scale: 'l',
  categories: 'q',
  hidden: 'h',
  sort: 's',
  sortDir: 'sd',
  sortEngine: 'e',
  sortEngineDir: 'ed',
  order: 'o',
  theme: 'th',
  expanded: 'x',
  hide: 'p',
};

/**
 * Read `?s=` plus the readable overrides next to it.
 *
 * A packed short state is the baseline, while readable parameters next to it
 * are intentional overrides. This makes links like `?s=…&hide=header` practical
 * for embeds; the next render canonicalizes them back to `?s=`.
 *
 * @param search `window.location.search`
 * @param initial defaults every unset field falls back to (INITIAL_STATE)
 */
export function restoreUrlState(
  search: string,
  env: CodecEnv,
  initial: BenchState,
): RestoredState {
  const patch: Partial<BenchState> = {};
  let theme: ThemeName | null = null;
  try {
    const p = new URLSearchParams(search);
    const packed = base64UrlDecode(p.get('s'));
    const get = (key: string): unknown =>
      p.has(key) ? p.get(key) : packed ? packed[FIELDS[key]] : null;
    const oneOf = <T extends string>(key: string, allowed: readonly T[], fallback: T | null) => {
      const v = get(key);
      return allowed.includes(v as T) ? (v as T) : fallback;
    };
    const validSystems = new Set(env.systems);
    const split = (key: string) => String(get(key) || '').split(',').filter(Boolean);

    const dataset = get('dataset');
    if (typeof dataset === 'string' && env.datasets.includes(dataset)) patch.dataset = dataset;
    patch.tab = oneOf<Tab>('view', ['table', 'charts'], initial.tab)!;
    patch.metric = oneOf<Metric>('run', ['cold', 'hot'], initial.metric)!;
    patch.valueMode = oneOf<ValueMode>('cells', ['relative', 'sec', 'ms'], initial.valueMode)!;
    patch.scale = oneOf<Scale>('scale', ['log', 'linear'], initial.scale)!;
    patch.activeQTasks = new Set(split('categories').filter((t) => env.qTasks.includes(t)));
    patch.hidden = new Set(split('hidden').filter((s) => validSystems.has(s)));
    const sort = get('sort');
    patch.sortRow = (typeof sort === 'string' ? sort : '') || initial.sortRow;
    patch.sortDir = (String(get('sortDir')) === '-1' ? -1 : 1) as SortDir;
    const engine = get('sortEngine');
    patch.sortByEngine = typeof engine === 'string' && validSystems.has(engine) ? engine : null;
    patch.sortByEngineDir = (String(get('sortEngineDir')) === '-1' ? -1 : 1) as SortDir;
    const order = split('order').filter((s) => validSystems.has(s));
    patch.manualOrder = order.length ? order : null;
    patch.max = String(get('expanded')) === '1';
    patch.hiddenPanels = new Set(
      split('hide').filter((id): id is PanelId => HIDEABLE_PANELS.has(id as PanelId)),
    );
    theme = oneOf<ThemeName>('theme', ['dark', 'light'], null);
  } catch {
    /* a malformed link opens the default view rather than a blank page */
  }
  return { patch, theme };
}
