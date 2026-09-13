/* The benchmark, indexed once at module load. ui/index.html:135-176, 279-289.

   Handed in, not fetched here and not read off `window`: the shell loads the
   right results file and calls provideResults() before it imports this product,
   so these stay ordinary top-level constants. That is why this page still has no
   loading state and no backend — every number on screen is already in memory by
   the time the first component renders. See ./source.ts for why the rows travel
   that way rather than as a bundled import.

   Keyed by query tag id (Q01, …), NOT by position: engines omit queries they
   cannot express, so aligning by position would mismatch columns. `query_tags[i]`
   gives {id,task,filter,freq}; tag-less results fall back to Q1..QN by position. */

import { takeResults } from './source';
import type { EngineRow, QueryTag, RawEngineRow } from './types';

const RAW: RawEngineRow[] = takeResults();

/** Every (engine, dataset) row, with its query index attached. */
export const DATA: EngineRow[] = (RAW || [])
  .filter((d) => d && Array.isArray(d.result))
  .map((d) => {
    const byId: Record<string, number> = {};
    const qt = Array.isArray(d.query_tags) ? d.query_tags : [];
    for (let i = 0; i < d.result.length; i++) {
      const id = qt[i] && qt[i].id ? (qt[i].id as string) : 'Q' + (i + 1);
      byId[id] = i;
    }
    return { ...d, byId };
  });

/** Once any engine ships tags, an untagged engine no longer injects Q1..QN rows. */
const HAS_TAGS = DATA.some(
  (d) => Array.isArray(d.query_tags) && d.query_tags.some((t) => t && t.id),
);

/** "Q12" → 12. Used to order query ids numerically rather than as strings. */
export function qnumOf(id: string | null | undefined): number {
  const m = /(\d+)/.exec(id || '');
  return m ? +m[1] : 1e9;
}

/**
 * How many items a dataset name announces — `otel_logs_100m` → 100000000.
 * `null` when the name carries no size, which sorts it last.
 */
export function datasetItems(ds: string | null | undefined): number | null {
  const m = /(?:_|^)(\d+)([kmb])(?:_|$)/i.exec(ds || '');
  if (!m) return null;
  const unit = ({ k: 1e3, m: 1e6, b: 1e9 } as Record<string, number>)[m[2].toLowerCase()];
  return unit ? +m[1] * unit : null;
}

function buildQueries(): { qids: string[]; qtags: Record<string, QueryTag> } {
  const qids: string[] = [];
  const qtags: Record<string, QueryTag> = {};
  const seen = new Set<string>();
  for (const d of DATA) {
    const qt = Array.isArray(d.query_tags) ? d.query_tags : [];
    for (let i = 0; i < d.result.length; i++) {
      const t = qt[i] || {};
      if (HAS_TAGS && !t.id) continue;
      const id = t.id || 'Q' + (i + 1);
      if (!seen.has(id)) {
        seen.add(id);
        qids.push(id);
      }
      if (!qtags[id] && (t.task || t.filter || t.freq)) qtags[id] = t;
    }
  }
  qids.sort((a, b) => qnumOf(a) - qnumOf(b) || a.localeCompare(b));
  return { qids, qtags };
}

const built = buildQueries();

/** Every query id in the benchmark, numerically ordered. */
export const QIDS: readonly string[] = built.qids;

/** Query id → its tag object. Ids with no task/filter/freq are absent. */
export const QTAGS: Readonly<Record<string, QueryTag>> = built.qtags;

/** Total query count — the denominator in "18 of 92 queries". */
export const NQ = QIDS.length;

/** Every dataset, largest first, ties broken by name. */
export const DATASETS: readonly string[] = [...new Set(DATA.map((d) => d.dataset))].sort((a, b) => {
  const sizeA = datasetItems(a) ?? -1;
  const sizeB = datasetItems(b) ?? -1;
  return sizeB - sizeA || a.localeCompare(b);
});

/** Every `system` in the benchmark. Used to validate `?hidden=` / `?order=`. */
export const SYSTEMS: readonly string[] = [...new Set(DATA.map((d) => d.system))];

/** Every system except SereneDB, sorted — the palette-slot order. */
export const OTHER_SYSTEMS: readonly string[] = [...new Set(DATA.map((d) => d.system))]
  .filter((s) => s !== 'SereneDB')
  .sort();
