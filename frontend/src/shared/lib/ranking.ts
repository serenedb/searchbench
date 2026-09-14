/* Which engines are shown and in what order. ui/index.html:402-433.

   `orderedVisible` is the one every panel wants: it applies the hidden set, the
   engine-tag filter and then either the manual column order or the current sort
   row. `universeOrder` is the same order over *all* engines including hidden
   ones — the participants list and the drag-reorder handler need that, because
   hiding an engine must not renumber the rest. */

import { DEFAULT_SORT_ROW, type BenchState } from '../model/state';
import { coverageMap, geomeanMap, metricValue } from './metrics';
import { passesTagFilter, type BenchRow } from './rows';

/** What `sortKeyMap` reads. `BenchState` satisfies it. */
export type SortKeyOpts = Pick<BenchState, 'sortRow' | 'metric'>;
/** What `metricSorted` reads. */
export type SortOpts = Pick<BenchState, 'sortRow' | 'sortDir' | 'metric'>;
/** What `orderedVisible` / `universeOrder` read. */
export type OrderOpts = Pick<
  BenchState,
  'sortRow' | 'sortDir' | 'metric' | 'hidden' | 'activeTags' | 'manualOrder'
>;

/**
 * system → the number the current sort row ranks it by. Missing values sort
 * last (`Infinity`); an unknown row key ranks everything equal, which leaves
 * the name tiebreak in `metricSorted` as the only ordering.
 *
 * `DEFAULT_SORT_ROW` is among the keys that rank everything equal here, and
 * deliberately: it is three keys, not one number, so `metricSorted` intercepts
 * it before this is called. Nothing else reads it, which is why there is no
 * fourth branch below.
 */
export function sortKeyMap(
  list: BenchRow[],
  ids: readonly string[],
  opts: SortKeyOpts,
): Map<string, number> {
  const k = opts.sortRow;
  const m = new Map<string, number>();
  if (k === 'geomean') {
    const g = geomeanMap(list, ids, opts.metric);
    for (const r of list) {
      const v = g.get(r.system);
      m.set(r.system, v == null ? Infinity : v);
    }
  } else if (k === 'load') {
    for (const r of list) m.set(r.system, typeof r.load_time === 'number' ? r.load_time : Infinity);
  } else if (k === 'size') {
    for (const r of list) m.set(r.system, typeof r.data_size === 'number' ? r.data_size : Infinity);
  } else if (k && k.startsWith('q:')) {
    const id = k.slice(2);
    for (const r of list) {
      const v = metricValue(r, id, opts.metric);
      m.set(r.system, v == null ? Infinity : v);
    }
  } else {
    for (const r of list) m.set(r.system, 0);
  }
  return m;
}

/**
 * The default order: most of the workload supported first, then most of it
 * finished, then fastest — `DEFAULT_SORT_ROW` spelled out.
 *
 * The two counts are descending and the geomean ascending, because "better" is
 * up for one and down for the other; `sortDir` flips all three together, so a
 * descending default is the worst engine first by the same three questions.
 * The name tiebreak stays ascending, as it is in `metricSorted`.
 *
 * A geomean of `null` — an engine that finished nothing — sorts last among
 * engines it is tied with on both counts, the same `Infinity` a missing value
 * gets in `sortKeyMap`.
 */
function coverageSorted<R extends BenchRow>(
  list: R[],
  ids: readonly string[],
  opts: SortOpts,
): R[] {
  const cov = coverageMap(list, ids, opts.metric);
  const geo = geomeanMap(list, ids, opts.metric);
  const dir = opts.sortDir;
  const zero = { supported: 0, completed: 0 };
  return [...list].sort((a, b) => {
    const ca = cov.get(a.system) ?? zero;
    const cb = cov.get(b.system) ?? zero;
    if (ca.supported !== cb.supported) return (cb.supported - ca.supported) * dir;
    if (ca.completed !== cb.completed) return (cb.completed - ca.completed) * dir;
    const ga = geo.get(a.system) ?? Infinity;
    const gb = geo.get(b.system) ?? Infinity;
    if (ga !== gb) return ga < gb ? -dir : dir;
    return a.system.localeCompare(b.system);
  });
}

/** `list` sorted by the current row, name-tiebroken. Does not mutate `list`. */
export function metricSorted<R extends BenchRow>(
  list: R[],
  ids: readonly string[],
  opts: SortOpts,
): R[] {
  if (opts.sortRow === DEFAULT_SORT_ROW) return coverageSorted(list, ids, opts);
  const km = sortKeyMap(list, ids, opts);
  return [...list].sort((a, b) => {
    const va = km.get(a.system)!;
    const vb = km.get(b.system)!;
    return va < vb ? -opts.sortDir : va > vb ? opts.sortDir : a.system.localeCompare(b.system);
  });
}

/**
 * The engines the table and the charts draw, in column order.
 *
 * With no sort of the reader's own — a fresh view, or the one a dataset switch
 * returns to — that is `coverageSorted`: coverage, completion, speed. See
 * `DEFAULT_SORT_ROW`.
 *
 * @param rows every row for the current dataset — `rowsFor(ds)`
 * @param ids  the visible query ids — `visibleQIDS(state.activeQTasks)`
 */
export function orderedVisible<R extends BenchRow>(
  rows: R[],
  ids: readonly string[],
  opts: OrderOpts,
): R[] {
  const vis = rows.filter(
    (r) => !opts.hidden.has(r.system) && passesTagFilter(r, opts.activeTags),
  );
  if (opts.manualOrder) {
    const order = opts.manualOrder;
    const idx = (s: string) => {
      const i = order.indexOf(s);
      return i < 0 ? 1e9 : i;
    };
    return [...vis].sort((a, b) => idx(a.system) - idx(b.system) || a.system.localeCompare(b.system));
  }
  return metricSorted(vis, ids, opts);
}

/**
 * The same order over every engine in the dataset, hidden ones included —
 * systems only. Engines absent from `manualOrder` keep a stable name-sorted
 * tail, so dragging one column never reshuffles the others.
 */
export function universeOrder(
  rows: BenchRow[],
  ids: readonly string[],
  opts: OrderOpts,
): string[] {
  const all = rows.map((r) => r.system);
  if (opts.manualOrder) {
    const present = opts.manualOrder.filter((s) => all.includes(s));
    return present.concat(all.filter((s) => !present.includes(s)).sort());
  }
  return metricSorted(rows, ids, opts).map((e) => e.system);
}
