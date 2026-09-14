/* The query panel's view-model — ui/index.html:770-796, `queryPanelData(ds)`.
 *
 * One selected cell (engine × query) turned into the six strings the panel and
 * the explain overlay print. It is the only place in the port that reads
 * `queries` / `explains` / `explain_analyzes` off a row, and it is a plain
 * function rather than a hook because the original recomputed it on every
 * `render()` and it costs one `find` over nine rows.
 *
 * It lives in the widget slice, not in shared/lib, because it needs
 * entities/results (`rowsFor`, the query tags) — shared may not import upward.
 * Both consumers, the panel and the modal, are in this slice, and the page
 * computes it once and passes it to both exactly as `render()` did (:863, :870).
 *
 * Changes from the original, all mechanical:
 *   - `state.metric` / `state.hidden` / `state.activeTags` / `state.sel` arrive
 *     as `opts` instead of off the module-global, so `metricValue`,
 *     `fastestForQuery` and `passesTagFilter` take their extra argument;
 *   - `r._byId` is `r.byId` (entities/results builds it under the public name).
 *
 * Nothing else moved. In particular the `plan === ea` test that picks the
 * label is copied as-is: it reads "EXPLAIN ANALYZE" when both plans are null,
 * which is unreachable because the modal is gated on `hasPlan`.
 */

import { rowsFor, tagsForQuery } from '../../entities/results';
import { fmtRatio, fmtSec } from '../../shared/lib/format';
import {
  TIMEOUT_CAP,
  fastestForQuery,
  isTimeout,
  metricValue,
  ratioOf,
} from '../../shared/lib/metrics';
import { passesTagFilter } from '../../shared/lib/rows';
import type { BenchState } from '../../shared/model';

export interface QueryPanelData {
  /** "SereneDB — Q17 · join · term · hi" */
  title: string;
  /** The run line: metric, value, ratio-or-timeout, the three runs, the cold one. */
  meta: string;
  /** The executed statement, or the stand-in for a query the engine cannot express. */
  sql: string;
  /** Whether the ▚ Explain button is drawn and the modal can open. */
  hasPlan: boolean;
  plan: string | null;
  /** "EXPLAIN ANALYZE · actual timings" when the row carried actual timings. */
  planLabel: string;
}

/** Everything `queryPanelData` reads off the state. `BenchState` satisfies it. */
export type QueryPanelOpts = Pick<BenchState, 'sel' | 'hidden' | 'activeTags' | 'metric'>;

export function queryPanelData(
  ds: string | null,
  opts: QueryPanelOpts,
): QueryPanelData | null {
  const sel = opts.sel;
  if (!sel) return null;
  const r = rowsFor(ds).find((x) => x.system === sel.sys);
  // The selection survives a dataset switch only in theory — `dataset` clears
  // it — but an `?s=` link can name an engine that did not run this dataset.
  if (!r) return null;
  const id = sel.id;
  const qi = r.byId ? r.byId[id] : undefined;
  const arr = qi != null && Array.isArray(r.result[qi]) ? r.result[qi] : [];
  const v = metricValue(r, id, opts.metric);
  // "Fastest" is over the engines currently on screen, so hiding an engine
  // rewrites the ratio here the same way it rewrites the cells.
  const best = fastestForQuery(
    rowsFor(ds).filter((x) => !opts.hidden.has(x.system) && passesTagFilter(x, opts.activeTags)),
    id,
    opts.metric,
  );
  const rt = ratioOf(v, best);
  const tg = tagsForQuery(id);
  const title = `${r.system} — ${id}${
    tg ? ' · ' + [tg.task, tg.filter, tg.freq].filter(Boolean).join(' · ') : ''
  }`;
  const cold = typeof arr[0] === 'number' ? fmtSec(arr[0]) + ' s' : '—';
  const runs = arr
    .map((x) => (typeof x !== 'number' ? 'null' : (isTimeout(x) ? '💀' : '') + fmtSec(x)))
    .join(', ');
  const meta =
    `${opts.metric} ${v == null ? '—' : (isTimeout(v) ? '💀 ' : '') + fmtSec(v) + ' s'}` +
    (isTimeout(v)
      ? ` (timed out — killed at the ${TIMEOUT_CAP}s cap)`
      : rt != null
        ? ` (${fmtRatio(rt)} vs fastest)`
        : '') +
    ` · runs [${runs}] · cold ${cold}`;
  const q = (qi != null && r.queries && r.queries[qi]) || null;
  let sql: string;
  if (!q) sql = '(query text unavailable — re-run ./frontend/build_results)';
  else if (q.startsWith('UNSUPPORTED:')) sql = 'Not supported by this engine.\n\n' + q;
  else sql = q;
  const ea = Array.isArray(r.explain_analyzes) && qi != null ? r.explain_analyzes[qi] : null;
  const ex = Array.isArray(r.explains) && qi != null ? r.explains[qi] : null;
  // An actual-timings plan wins over a static one; whitespace is not a plan.
  const plan = ea && String(ea).trim() ? ea : ex && String(ex).trim() ? ex : null;
  return {
    title,
    meta,
    sql,
    hasPlan: !!plan,
    plan,
    planLabel: plan === ea ? 'EXPLAIN ANALYZE · actual timings' : 'EXPLAIN',
  };
}
