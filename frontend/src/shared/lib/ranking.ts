/* Which engines are shown and in what order. ui/index.html:402-433.

   `orderedVisible` is the one every panel wants: it applies the hidden set, the
   engine-tag filter and then either the manual column order or the current sort
   row. `universeOrder` is the same order over *all* engines including hidden
   ones — the participants list and the drag-reorder handler need that, because
   hiding an engine must not renumber the rest. */

import type { BenchState } from '../model/state';
import { geomeanMap, metricValue } from './metrics';
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

/** `list` sorted by the current row, name-tiebroken. Does not mutate `list`. */
export function metricSorted<R extends BenchRow>(
  list: R[],
  ids: readonly string[],
  opts: SortOpts,
): R[] {
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
