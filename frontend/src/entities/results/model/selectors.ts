/* Reads over the indexed benchmark. ui/index.html:290-324.

   All pure and all cheap — nine rows and ninety-two queries — so they are called
   straight from render rather than memoised behind a store. Anything that also
   needs UI state (which engines are hidden, which row sorts) lives in
   shared/lib/ranking.ts instead; these only know the data. */

import { colorOf } from '../../../shared/lib/color';
import { tagsOf } from '../../../shared/lib/rows';
import { DATA, DATASETS, OTHER_SYSTEMS, QIDS, QTAGS } from './dataset';
import type { EngineRow, QueryTag } from './types';

/** Every engine that ran `ds`, in file order. */
export function rowsFor(ds: string | null | undefined): EngineRow[] {
  return DATA.filter((d) => d.dataset === ds);
}

/** One engine's row for a dataset, or undefined if it did not run it. */
export function rowFor(ds: string | null | undefined, system: string): EngineRow | undefined {
  return DATA.find((d) => d.dataset === ds && d.system === system);
}

/** Every engine tag present in a dataset, minus each engine's own name. */
export function tagsFor(ds: string | null | undefined): string[] {
  const set = new Set<string>();
  rowsFor(ds).forEach((r) => tagsOf(r).forEach((t) => set.add(t)));
  return [...set].sort((a, b) => a.localeCompare(b));
}

/** Every query category in the benchmark — the chips in the categories panel. */
export function qTasksFor(): string[] {
  const set = new Set<string>();
  QIDS.forEach((id) => {
    const t = QTAGS[id];
    if (t && t.task) set.add(t.task);
  });
  return [...set].sort((a, b) => a.localeCompare(b));
}

/** Empty filter passes everything; an untagged query never passes a filter. */
export function queryPasses(id: string, activeQTasks: ReadonlySet<string>): boolean {
  if (activeQTasks.size === 0) return true;
  const t = QTAGS[id];
  return !!(t && t.task && activeQTasks.has(t.task));
}

/**
 * The query ids the table rows, the charts and the geomean are computed over.
 * Pass `state.activeQTasks`.
 */
export function visibleQIDS(activeQTasks: ReadonlySet<string>): string[] {
  return QIDS.filter((id) => queryPasses(id, activeQTasks));
}

/** Tags for one query id, or null. */
export function tagsForQuery(id: string): QueryTag | null {
  return QTAGS[id] ?? null;
}

/** This engine's colour, everywhere it appears. `colorOf` bound to the data. */
export function engineColor(sys: string): string {
  return colorOf(sys, OTHER_SYSTEMS);
}

/** Re-exported so callers get the list and the resolver from one place. */
export { DATASETS as datasets };
