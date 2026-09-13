/* The rows of the results grid, in the order they are drawn.
   ui/index.html:565-595 (`metricRows`).

   Three summary rows and then one row per visible query. The per-query block is
   re-sorted when an engine column is the sort key, and the row that ends up
   first carries the section caption — which is why the caption is a field on a
   row rather than a separate list: the original wrote it onto `q[0]` after
   sorting (ui/index.html:585-589) and the divider is drawn from there.

   The original tagged rows with two booleans, `query` and `geomean`, and left
   `get`/`fmt` undefined on the ones that did not need them. Here that is a
   discriminated union, so `row.get` cannot be called on the geomean row and
   `row.id` cannot be read off a summary row. The mapping is exact:

       row.query    ↔ row.kind === 'query'
       row.geomean  ↔ row.kind === 'geomean'
       row.get/fmt  ↔ row.kind === 'summary'

   Nothing else about the shape changed, and the values are computed by the same
   expressions in the same order. */

import { qnumOf, rowFor, tagsForQuery, type EngineRow, type QueryTag } from '../../../entities/results';
import { fmtBytes, fmtSec } from '../../../shared/lib/format';
import { fastestForQuery, metricValue, ratioOf } from '../../../shared/lib/metrics';
import type { BenchState } from '../../../shared/model';

/** What a row needs to draw its divider, if it is the first of a block. */
interface RowBase {
  /** Sort key, and React key: 'load' | 'size' | 'geomean' | `q:${id}`. */
  key: string;
  /** Text of the row label button. */
  label: string;
  /** Caption of the section divider drawn *above* this row, or null. */
  section: string | null;
}

/** Load time / on-disk size: read a field, print it with its own formatter. */
export interface SummaryRow extends RowBase {
  kind: 'summary';
  get: (r: EngineRow) => number | null | undefined;
  fmt: (v: number) => string;
}

/** Geomean of the per-query ratios; its value comes from `geomeanMap`. */
export interface GeomeanRow extends RowBase {
  kind: 'geomean';
}

/** One benchmark query. */
export interface QueryRow extends RowBase {
  kind: 'query';
  /** Query id — 'Q42'. */
  id: string;
  /** task · filter · freq, printed next to the label. */
  tag: QueryTag | null;
}

export type MetricRow = SummaryRow | GeomeanRow | QueryRow;

/** What `metricRows` reads off the state object. `BenchState` satisfies it. */
export type MetricRowOpts = Pick<
  BenchState,
  'valueMode' | 'metric' | 'sortByEngine' | 'sortByEngineDir'
>;

/**
 * @param ds      the resolved dataset — the original called `curDataset()` here
 *                (`state.dataset || curDataset()`, ui/index.html:572, which is
 *                the same value)
 * @param engines the visible engines, in column order — the denominator of the
 *                relative sort, so hiding an engine re-sorts the query rows
 * @param ids     the visible query ids, `visibleQIDS(state.activeQTasks)`
 */
export function metricRows(
  ds: string | null,
  engines: EngineRow[],
  ids: readonly string[],
  state: MetricRowOpts,
): MetricRow[] {
  const relative = state.valueMode === 'relative';
  const q: QueryRow[] = ids.map((id) => ({
    kind: 'query',
    key: 'q:' + id,
    id,
    label: id,
    tag: tagsForQuery(id),
    section: null,
  }));

  let sortedBy: string | null = null;
  if (state.sortByEngine) {
    // Deliberately every row of the dataset, not just the visible ones: an
    // engine can sort the table and then be hidden, and the order it produced
    // survives that.
    const eng = rowFor(ds, state.sortByEngine);
    if (eng) {
      sortedBy = state.sortByEngine;
      const key = (id: string) => {
        const v = metricValue(eng, id, state.metric);
        if (typeof v !== 'number') return Infinity;
        if (!relative) return v;
        const r = ratioOf(v, fastestForQuery(engines, id, state.metric));
        return typeof r === 'number' ? r : Infinity;
      };
      // Ties — and two queries neither engine ran are a tie at Infinity — fall
      // back to query order, so the block never shuffles arbitrarily.
      q.sort((a, b) => {
        const na = key(a.id);
        const nb = key(b.id);
        return na === nb ? qnumOf(a.id) - qnumOf(b.id) : (na - nb) * state.sortByEngineDir;
      });
    }
  }

  if (q.length) {
    q[0].section = sortedBy
      ? `per-query · sorted by ${sortedBy} ${relative ? 'relative coef' : 'latency'} (${
          state.sortByEngineDir === 1 ? 'fastest first' : 'slowest first'
        })`
      : `per-query · ${
          relative
            ? 'relative to fastest engine'
            : state.valueMode === 'ms'
              ? 'absolute milliseconds'
              : 'absolute seconds'
        }`;
  }

  return [
    {
      kind: 'summary',
      key: 'load',
      label: 'Load time',
      section: 'summary',
      get: (r) => r.load_time,
      fmt: fmtSec,
    },
    {
      kind: 'summary',
      key: 'size',
      label: 'On-disk size',
      section: null,
      get: (r) => r.data_size,
      fmt: fmtBytes,
    },
    // The original also carried `fmt: fmtRatio` here; the cell branch for a
    // geomean row formats with fmtRatio directly and never reads it.
    { kind: 'geomean', key: 'geomean', label: 'Geomean', section: null },
    ...q,
  ];
}
